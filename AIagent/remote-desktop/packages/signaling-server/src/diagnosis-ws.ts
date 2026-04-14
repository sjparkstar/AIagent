// 자동진단/복구 WebSocket 핸들러
// 호스트↔뷰어간 진단/복구 이벤트 라우팅 + DB 기록
// 보안: 뷰어가 보내는 명령 내용을 믿지 않고, 서버가 DB에서 직접 조회하여 호스트에 전달

import type { WebSocket } from "ws";
import type { DiagnosisMessage } from "@remote-desktop/shared";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@remote-desktop/shared";
import { log } from "./logger.js";
import { getRoomByHost, getViewerRoom } from "./room.js";
import {
  createIssueEvent,
  validateApprovalToken,
  consumeApprovalToken,
  createDiagnosticJob,
  updateDiagnosticJob,
  createRecoveryJob,
  updateRecoveryJob,
  auditLog,
} from "./diagnosis-api.js";

// 카테고리별 읽기 전용 진단 스텝 정의 (서버 측 고정 — 뷰어가 조작 불가)
// PLAN.md Level 1 (Read-only Diagnostic)에 해당
const DIAGNOSTIC_STEPS_BY_CATEGORY: Record<
  string,
  { name: string; command: string; commandType: string }[]
> = {
  network: [
    { name: "IP 설정", command: "ipconfig /all", commandType: "cmd" },
    { name: "게이트웨이 ping", command: "ping -n 2 8.8.8.8", commandType: "cmd" },
    { name: "DNS 확인", command: "nslookup google.com", commandType: "cmd" },
  ],
  system: [
    { name: "메모리 상태", command: "wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /format:list", commandType: "cmd" },
    { name: "CPU 상위 프로세스", command: "powershell -Command \"Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name,Id,CPU | Format-Table\"", commandType: "powershell" },
  ],
  cleanup: [
    { name: "디스크 사용률", command: "wmic logicaldisk get DeviceID,FreeSpace,Size /format:list", commandType: "cmd" },
  ],
  service: [
    { name: "서비스 상태 조회", command: "sc query state= all | findstr STATE", commandType: "cmd" },
  ],
  security: [
    { name: "현재 사용자", command: "whoami /user", commandType: "cmd" },
    { name: "관리자 권한 확인", command: "whoami /groups | findstr \"S-1-5-32-544\"", commandType: "cmd" },
  ],
  process: [
    { name: "프로세스 목록", command: "tasklist | findstr /v /i \"svchost\"", commandType: "cmd" },
  ],
};

// Supabase에서 playbook을 직접 조회 (뷰어의 playbookDef를 신뢰하지 않음)
async function fetchPlaybookById(playbookId: string): Promise<Record<string, unknown> | null> {
  try {
    // UUID 형식만 허용하여 쿼리 주입 방어
    if (!/^[a-f0-9-]{36}$/i.test(playbookId)) {
      log(`[diagnosis] 잘못된 playbookId 형식: ${playbookId}`);
      return null;
    }
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/playbooks?id=eq.${playbookId}&select=*`,
      {
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        },
      },
    );
    if (!res.ok) return null;
    const rows = (await res.json()) as Record<string, unknown>[];
    if (rows.length === 0) return null;
    const pb = rows[0];
    if (pb["enabled"] !== true) {
      log(`[diagnosis] 비활성 playbook 요청: ${playbookId}`);
      return null;
    }
    return pb;
  } catch (e) {
    log(`[diagnosis] playbook 조회 실패: ${e}`);
    return null;
  }
}

function send(ws: WebSocket, msg: unknown): void {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(msg));
  }
}

/**
 * 진단/복구 WebSocket 메시지 라우팅
 * - 호스트 → 서버: 이슈 탐지, 진행률, 결과 → DB 저장 + 뷰어들에게 브로드캐스트
 * - 뷰어 → 서버: 승인 후 호스트에 실행 지시 (승인 토큰 검증)
 */
export async function handleDiagnosisWebSocket(
  ws: WebSocket,
  msg: DiagnosisMessage,
): Promise<void> {
  try {
    switch (msg.type) {
      case "issue.detected":
        await handleIssueDetected(ws, msg);
        break;
      case "approve.diagnostic":
        await handleApproveDiagnostic(ws, msg);
        break;
      case "approve.recovery":
        await handleApproveRecovery(ws, msg);
        break;
      case "diagnostic.progress":
      case "recovery.progress":
        // 호스트 → 뷰어 브로드캐스트 (DB 저장 불필요)
        broadcastToViewers(ws, msg);
        break;
      case "diagnostic.result":
        await handleDiagnosticResult(ws, msg);
        break;
      case "recovery.result":
        await handleRecoveryResult(ws, msg);
        break;
      case "verification.result":
        await handleVerificationResult(ws, msg);
        break;
      case "abort.operation":
        // 뷰어 → 호스트로 중단 요청 전달
        forwardToHost(ws, msg);
        break;
      default:
        log(`[diagnosis-ws] 처리되지 않은 메시지: ${(msg as { type: string }).type}`);
    }
  } catch (e) {
    log(`[diagnosis-ws] 오류: ${e}`);
  }
}

// 호스트가 같은 방의 모든 뷰어에게 브로드캐스트
function broadcastToViewers(ws: WebSocket, msg: unknown): void {
  const room = getRoomByHost(ws);
  if (!room) return;
  for (const viewer of room.viewers.values()) {
    send(viewer.ws, msg);
  }
}

// 뷰어가 호스트로 메시지 전달
function forwardToHost(ws: WebSocket, msg: unknown): void {
  const result = getViewerRoom(ws);
  if (!result) return;
  send(result.room.host.ws, msg);
}

// ─── 호스트 → 서버: 이슈 탐지 ───────────────────────────────────────────
async function handleIssueDetected(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "issue.detected" }>,
): Promise<void> {
  const room = getRoomByHost(ws);
  const hostId = room?.roomId ?? "unknown";

  const issue = await createIssueEvent({
    sessionId: undefined, // 서버에서 현재 세션 ID를 알 수 없으므로 host가 로컬로 보관
    hostId,
    category: msg.category,
    severity: msg.severity,
    summary: msg.summary,
    detail: msg.detail,
    metadata: msg.metadata,
  });

  // 뷰어들에게 이슈 알림
  broadcastToViewers(ws, {
    type: "issue.notified",
    issueId: issue.id,
    category: msg.category,
    severity: msg.severity,
    summary: msg.summary,
    detail: msg.detail,
    detectedAt: issue.detected_at,
  });

  log(`[diagnosis] 이슈 생성: ${issue.id} (${msg.category}/${msg.severity})`);
}

// ─── 뷰어 → 서버: 진단 승인 → 서버가 토큰 검증 + 서버 고정 스텝으로 호스트 디스패치 ─
// 보안: 뷰어가 전달한 diagnosticSteps는 무시하고, 서버가 카테고리별로 고정된 스텝만 실행
// msg 안에 approvalToken이 포함되어야 함 (REST /api/diagnosis/approve로 먼저 발급)
async function handleApproveDiagnostic(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "approve.diagnostic" }>,
): Promise<void> {
  const result = getViewerRoom(ws);
  if (!result) return;

  // 승인 토큰은 msg에 포함되어 있어야 함 (뷰어가 REST로 받은 tokenId)
  const tokenId = (msg as unknown as { approvalToken?: string }).approvalToken;
  if (!tokenId || typeof tokenId !== "string") {
    log("[diagnosis] approve.diagnostic: approvalToken 누락");
    return;
  }

  const token = await validateApprovalToken(tokenId, "diagnostic", 1);
  if (!token) {
    log(`[diagnosis] 진단 토큰 검증 실패: ${tokenId}`);
    return;
  }

  // 이슈 카테고리 조회 → 서버 고정 스텝 선택
  const issueRows = await fetchIssueById(msg.issueId);
  const category = issueRows?.category ?? "general";
  const steps = DIAGNOSTIC_STEPS_BY_CATEGORY[category] ??
    [{ name: "시스템 정보", command: "systeminfo", commandType: "cmd" }];

  // 진단 작업 레코드 생성
  const job = await createDiagnosticJob({
    issueEventId: msg.issueId,
    approvalTokenId: tokenId,
  });
  await consumeApprovalToken(tokenId);

  // 호스트에 실행 지시 (서버 고정 스텝)
  send(result.room.host.ws, {
    type: "run.diagnostic",
    jobId: job["id"],
    issueId: msg.issueId,
    approvalToken: tokenId,
    diagnosticSteps: steps,
  });

  await auditLog(
    "server",
    "system",
    "diagnostic_dispatched",
    { issueId: msg.issueId, jobId: job["id"], tokenId, stepCount: steps.length },
    result.room.roomId,
    result.room.roomId,
  );
  log(`[diagnosis] 진단 디스패치: issue=${msg.issueId}, job=${job["id"]}, steps=${steps.length}`);
}

// ─── 뷰어 → 서버: 복구 승인 → 서버가 DB에서 playbook 조회 + 호스트 디스패치 ─────
// 보안: 뷰어는 playbookId만 전달. 서버가 DB에서 playbook 정의를 가져와서 호스트에 보냄.
async function handleApproveRecovery(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "approve.recovery" }>,
): Promise<void> {
  const result = getViewerRoom(ws);
  if (!result) return;

  const tokenId = (msg as unknown as { approvalToken?: string }).approvalToken;
  if (!tokenId || typeof tokenId !== "string" || !msg.playbookId) {
    log("[diagnosis] approve.recovery: approvalToken 또는 playbookId 누락");
    return;
  }

  // playbook을 DB에서 직접 조회 (뷰어가 보낸 playbookDef는 무시)
  const playbook = await fetchPlaybookById(msg.playbookId);
  if (!playbook) {
    log(`[diagnosis] playbook 조회 실패: ${msg.playbookId}`);
    return;
  }

  const requiredLevel = (playbook["required_approval_level"] as number) ?? 2;

  // 토큰 검증 — playbook이 요구하는 레벨 이상이어야 함
  const token = await validateApprovalToken(tokenId, "recovery", requiredLevel);
  if (!token) {
    log(`[diagnosis] 복구 토큰 검증 실패: ${tokenId} (필요 레벨: ${requiredLevel})`);
    return;
  }

  // allowed_action_ids 화이트리스트 강제
  const allowed = token.allowed_action_ids;
  if (allowed && allowed.length > 0 && !allowed.includes(msg.playbookId)) {
    log(`[diagnosis] playbook ${msg.playbookId}는 허용되지 않음`);
    return;
  }

  // 복구 작업 레코드 생성
  const job = await createRecoveryJob({
    issueEventId: msg.issueId,
    diagnosticJobId: msg.diagnosticJobId,
    playbookId: msg.playbookId,
    approvalTokenId: tokenId,
  });
  await consumeApprovalToken(tokenId);

  // playbookDef를 서버가 조립 (DB 값만 사용)
  const playbookDef = {
    title: (playbook["name"] as string) ?? "복구",
    preconditions: (playbook["preconditions"] as unknown[]) ?? [],
    actions: (playbook["steps"] as unknown[]) ?? [],
    successCriteria: (playbook["success_criteria"] as unknown[]) ?? [],
    rollbackSteps: (playbook["rollback_steps"] as unknown[]) ?? [],
  };

  send(result.room.host.ws, {
    type: "run.recovery",
    jobId: job["id"],
    issueId: msg.issueId,
    approvalToken: tokenId,
    playbookId: msg.playbookId,
    playbookDef,
  });

  await auditLog(
    "server",
    "system",
    "recovery_dispatched",
    {
      issueId: msg.issueId,
      jobId: job["id"],
      playbookId: msg.playbookId,
      tokenId,
      riskLevel: playbook["risk_level"],
    },
    result.room.roomId,
    result.room.roomId,
  );
  log(`[diagnosis] 복구 디스패치: issue=${msg.issueId}, job=${job["id"]}, playbook=${playbook["name"]}`);
}

// 이슈 조회 헬퍼 (category 추출용)
async function fetchIssueById(issueId: string): Promise<{ category: string } | null> {
  try {
    if (!/^[a-f0-9-]{36}$/i.test(issueId)) return null;
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/issue_events?id=eq.${issueId}&select=category`,
      {
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        },
      },
    );
    if (!res.ok) return null;
    const rows = (await res.json()) as { category: string }[];
    return rows[0] ?? null;
  } catch {
    return null;
  }
}

// ─── 호스트 → 서버: 진단 결과 ───────────────────────────────────────
async function handleDiagnosticResult(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "diagnostic.result" }>,
): Promise<void> {
  await updateDiagnosticJob(msg.jobId, {
    ended_at: new Date().toISOString(),
    status: msg.success ? "completed" : "failed",
    root_cause_candidates: msg.rootCauseCandidates,
    recommended_actions: msg.recommendedActions,
    raw_result: msg.rawResult ?? null,
  });

  broadcastToViewers(ws, msg);
  log(`[diagnosis] 진단 완료: ${msg.jobId} (success=${msg.success})`);
}

// ─── 호스트 → 서버: 복구 결과 ───────────────────────────────────────
async function handleRecoveryResult(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "recovery.result" }>,
): Promise<void> {
  await updateRecoveryJob(msg.jobId, {
    ended_at: new Date().toISOString(),
    status: msg.rolledBack ? "rolled_back" : msg.success ? "completed" : "failed",
    step_results: msg.stepResults,
  });

  broadcastToViewers(ws, msg);
  log(`[diagnosis] 복구 완료: ${msg.jobId} (success=${msg.success})`);
}

// ─── 호스트 → 서버: 검증 결과 ───────────────────────────────────────
async function handleVerificationResult(
  ws: WebSocket,
  msg: Extract<DiagnosisMessage, { type: "verification.result" }>,
): Promise<void> {
  await updateRecoveryJob(msg.jobId, {
    verification_result: {
      success: msg.success,
      criteria: msg.criteria,
    },
  });

  broadcastToViewers(ws, msg);
  log(`[diagnosis] 검증 완료: ${msg.jobId} (success=${msg.success})`);
}

// ─── 뷰어용 헬퍼: 승인 토큰 발급 후 호스트에 실행 지시 전송 ─────────
// REST API의 /api/diagnosis/run-with-token에서 사용 가능하지만,
// 현재 구현은 뷰어가 승인 후 REST로 토큰 받고, 별도 WebSocket 메시지로
// 호스트에 직접 run.diagnostic / run.recovery를 보내는 구조.
export async function validateAndDispatchDiagnostic(
  viewerWs: WebSocket,
  tokenId: string,
  issueId: string,
  diagnosticSteps: { name: string; command: string; commandType: string }[],
): Promise<{ jobId: string } | null> {
  const token = await validateApprovalToken(tokenId, "diagnostic", 1);
  if (!token) return null;

  const result = getViewerRoom(viewerWs);
  if (!result) return null;

  const job = await createDiagnosticJob({
    issueEventId: issueId,
    approvalTokenId: tokenId,
  });
  await consumeApprovalToken(tokenId);

  // 호스트에 실행 지시 전송
  send(result.room.host.ws, {
    type: "run.diagnostic",
    jobId: job.id,
    issueId,
    approvalToken: tokenId,
    diagnosticSteps,
  });

  return { jobId: job.id as string };
}

export async function validateAndDispatchRecovery(
  viewerWs: WebSocket,
  tokenId: string,
  issueId: string,
  playbookId: string,
  playbookDef: {
    title: string;
    preconditions?: { name: string; command: string; expected: string }[];
    actions: { name: string; command: string; commandType: string }[];
    successCriteria?: { name: string; command: string; expected: string }[];
    rollbackSteps?: { name: string; command: string; commandType: string }[];
  },
  requiredLevel: number,
  diagnosticJobId?: string,
): Promise<{ jobId: string } | null> {
  const token = await validateApprovalToken(tokenId, "recovery", requiredLevel);
  if (!token) return null;

  const result = getViewerRoom(viewerWs);
  if (!result) return null;

  const job = await createRecoveryJob({
    issueEventId: issueId,
    diagnosticJobId,
    playbookId,
    approvalTokenId: tokenId,
  });
  await consumeApprovalToken(tokenId);

  send(result.room.host.ws, {
    type: "run.recovery",
    jobId: job.id,
    issueId,
    approvalToken: tokenId,
    playbookId,
    playbookDef,
  });

  return { jobId: job.id as string };
}
