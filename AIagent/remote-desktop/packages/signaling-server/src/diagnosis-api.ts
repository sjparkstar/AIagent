// 자동진단/복구 시스템 REST API
// PLAN.md 기반: issue_events, approval_tokens, diagnostic_jobs, recovery_jobs, audit_logs

import type { IncomingMessage, ServerResponse } from "http";
import { log } from "./logger.js";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@remote-desktop/shared";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

const SUPABASE_HEADERS: Record<string, string> = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  "Content-Type": "application/json",
};

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { ...CORS_HEADERS, "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

// 요청 본문 읽기 — 1MB 크기 제한 (OOM 공격 방어)
const MAX_BODY_BYTES = 1024 * 1024;

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error("요청 본문이 너무 큽니다 (max 1MB)"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

// ─── Supabase 래퍼 ────────────────────────────────────────────────────────────

async function dbInsert<T = Record<string, unknown>>(
  table: string,
  data: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
    method: "POST",
    headers: { ...SUPABASE_HEADERS, Prefer: "return=representation" },
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase ${table} insert 실패: ${res.status} ${text}`);
  }
  const rows = (await res.json()) as T[];
  return rows[0];
}

async function dbUpdate(
  table: string,
  id: string,
  data: Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?id=eq.${id}`, {
    method: "PATCH",
    headers: { ...SUPABASE_HEADERS, Prefer: "return=minimal" },
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase ${table} update 실패: ${res.status} ${text}`);
  }
}

async function dbSelect<T = Record<string, unknown>>(
  table: string,
  query: string,
): Promise<T[]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
    headers: SUPABASE_HEADERS,
  });
  if (!res.ok) return [];
  return (await res.json()) as T[];
}

// ─── 감사 로그 (모든 액션 영속 기록) ─────────────────────────────────────────

export async function auditLog(
  actorType: "viewer" | "host" | "system" | "server",
  actorId: string,
  actionType: string,
  detail: Record<string, unknown>,
  sessionId?: string,
  hostId?: string,
): Promise<void> {
  try {
    await dbInsert("audit_logs", {
      actor_type: actorType,
      actor_id: actorId,
      host_id: hostId ?? null,
      session_id: sessionId ?? null,
      action_type: actionType,
      action_detail: maskSensitiveData(detail),
    });
  } catch (e) {
    log(`[audit] 감사 로그 저장 실패: ${e}`);
  }
}

// 민감정보 마스킹 (PLAN.md 보안 원칙)
function maskSensitiveData(data: Record<string, unknown>): Record<string, unknown> {
  const masked: Record<string, unknown> = {};
  const sensitiveKeys = ["password", "token", "secret", "key", "apikey", "credential"];
  for (const [k, v] of Object.entries(data)) {
    const lowerKey = k.toLowerCase();
    if (sensitiveKeys.some((s) => lowerKey.includes(s))) {
      masked[k] = "***";
    } else if (typeof v === "object" && v !== null && !Array.isArray(v)) {
      masked[k] = maskSensitiveData(v as Record<string, unknown>);
    } else {
      masked[k] = v;
    }
  }
  return masked;
}

// ─── 이슈 이벤트 관리 ────────────────────────────────────────────────────────

interface IssueEvent {
  id: string;
  session_id: string | null;
  host_id: string;
  category: string;
  severity: string;
  summary: string;
  detail: string | null;
  status: string;
  detected_at: string;
  metadata: Record<string, unknown> | null;
}

export async function createIssueEvent(data: {
  sessionId?: string;
  hostId: string;
  category: string;
  severity: string;
  summary: string;
  detail?: string;
  metadata?: Record<string, unknown>;
}): Promise<IssueEvent> {
  const row = await dbInsert<IssueEvent>("issue_events", {
    session_id: data.sessionId ?? null,
    host_id: data.hostId,
    category: data.category,
    severity: data.severity,
    summary: data.summary,
    detail: data.detail ?? null,
    metadata: data.metadata ?? null,
  });
  await auditLog("host", data.hostId, "issue_detected", {
    issueId: row.id,
    category: data.category,
    severity: data.severity,
  }, data.sessionId, data.hostId);
  return row;
}

// ─── 승인 토큰 관리 (PLAN.md 4단계 승인) ──────────────────────────────────

interface ApprovalToken {
  id: string;
  session_id: string | null;
  issue_event_id: string;
  approver_id: string;
  approval_type: string;
  scope_level: number;
  allowed_action_ids: string[] | null;
  issued_at: string;
  expires_at: string;
  status: string;
}

const APPROVAL_TTL_MS = 5 * 60 * 1000; // 5분

export async function issueApprovalToken(data: {
  sessionId?: string;
  issueEventId: string;
  approverId: string;
  approvalType: "diagnostic" | "recovery";
  scopeLevel: number;
  allowedActionIds?: string[];
}): Promise<ApprovalToken> {
  // NaN/undefined/부동소수는 false를 반환하여 우회되지 않도록 정수 검증 먼저
  if (!Number.isInteger(data.scopeLevel) || data.scopeLevel < 1 || data.scopeLevel > 4) {
    throw new Error(`잘못된 scope_level: ${data.scopeLevel} (정수 1~4 필요)`);
  }
  const expiresAt = new Date(Date.now() + APPROVAL_TTL_MS).toISOString();
  const row = await dbInsert<ApprovalToken>("approval_tokens", {
    session_id: data.sessionId ?? null,
    issue_event_id: data.issueEventId,
    approver_id: data.approverId,
    approval_type: data.approvalType,
    scope_level: data.scopeLevel,
    allowed_action_ids: data.allowedActionIds ?? null,
    expires_at: expiresAt,
  });
  await auditLog("viewer", data.approverId, "approval_granted", {
    tokenId: row.id,
    issueId: data.issueEventId,
    type: data.approvalType,
    scope: data.scopeLevel,
  }, data.sessionId);
  return row;
}

export async function validateApprovalToken(
  tokenId: string,
  requiredType: "diagnostic" | "recovery",
  requiredLevel: number,
): Promise<ApprovalToken | null> {
  const rows = await dbSelect<ApprovalToken>(
    "approval_tokens",
    `id=eq.${tokenId}&select=*`,
  );
  if (rows.length === 0) return null;
  const token = rows[0];
  if (token.status !== "active") return null;
  if (new Date(token.expires_at) < new Date()) {
    await dbUpdate("approval_tokens", tokenId, { status: "expired" });
    return null;
  }
  if (token.approval_type !== requiredType) return null;
  if (token.scope_level < requiredLevel) return null;
  return token;
}

export async function consumeApprovalToken(tokenId: string): Promise<void> {
  await dbUpdate("approval_tokens", tokenId, {
    consumed_at: new Date().toISOString(),
    status: "consumed",
  });
}

// ─── 진단/복구 작업 ─────────────────────────────────────────────────────────

export async function createDiagnosticJob(data: {
  issueEventId: string;
  approvalTokenId: string;
}): Promise<Record<string, unknown>> {
  return await dbInsert("diagnostic_jobs", {
    issue_event_id: data.issueEventId,
    approval_token_id: data.approvalTokenId,
  });
}

export async function updateDiagnosticJob(
  jobId: string,
  data: Record<string, unknown>,
): Promise<void> {
  await dbUpdate("diagnostic_jobs", jobId, data);
}

export async function createRecoveryJob(data: {
  issueEventId: string;
  diagnosticJobId?: string;
  playbookId?: string;
  approvalTokenId: string;
}): Promise<Record<string, unknown>> {
  return await dbInsert("recovery_jobs", {
    issue_event_id: data.issueEventId,
    diagnostic_job_id: data.diagnosticJobId ?? null,
    playbook_id: data.playbookId ?? null,
    approval_token_id: data.approvalTokenId,
  });
}

export async function updateRecoveryJob(
  jobId: string,
  data: Record<string, unknown>,
): Promise<void> {
  await dbUpdate("recovery_jobs", jobId, data);
}

// ─── REST API 라우터 ────────────────────────────────────────────────────────

export function handleDiagnosisRoutes(
  req: IncomingMessage,
  res: ServerResponse,
): boolean {
  const url = req.url ?? "";

  // CORS preflight
  if (req.method === "OPTIONS" && url.startsWith("/api/diagnosis/")) {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return true;
  }

  // GET /api/diagnosis/issues?sessionId=xxx — 이슈 목록
  if (req.method === "GET" && url.startsWith("/api/diagnosis/issues")) {
    handleListIssues(req, res).catch((e) => {
      log(`[diagnosis] list issues 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  // GET /api/diagnosis/issues/:id — 이슈 상세 (진단/복구 이력 포함)
  const detailMatch = url.match(/^\/api\/diagnosis\/issues\/([^/?]+)$/);
  if (req.method === "GET" && detailMatch) {
    const issueId = detailMatch[1];
    handleGetIssueDetail(res, issueId).catch((e) => {
      log(`[diagnosis] get issue 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  // POST /api/diagnosis/approve — 진단/복구 승인
  if (req.method === "POST" && url === "/api/diagnosis/approve") {
    handleApprove(req, res).catch((e) => {
      log(`[diagnosis] approve 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  // GET /api/diagnosis/audit?sessionId=xxx — 감사 로그
  if (req.method === "GET" && url.startsWith("/api/diagnosis/audit")) {
    handleListAudit(req, res).catch((e) => {
      log(`[diagnosis] audit 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  // GET /api/diagnosis/playbooks?category=network — 카테고리별 권장 플레이북 조회
  if (req.method === "GET" && url.startsWith("/api/diagnosis/playbooks")) {
    handleListPlaybooks(req, res).catch((e) => {
      log(`[diagnosis] playbooks 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  // POST /api/diagnosis/validate-token — 호스트가 수신한 토큰을 재검증 (보안 이중 방어)
  if (req.method === "POST" && url === "/api/diagnosis/validate-token") {
    handleValidateToken(req, res).catch((e) => {
      log(`[diagnosis] validate-token 오류: ${e}`);
      sendJson(res, 500, { error: String(e) });
    });
    return true;
  }

  return false;
}

// 호스트가 실행 직전에 호출 — 토큰이 consumed/expired가 아닌지 확인
async function handleValidateToken(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    tokenId: string;
    approvalType: "diagnostic" | "recovery";
  };
  if (!body.tokenId || typeof body.tokenId !== "string" ||
      (body.approvalType !== "diagnostic" && body.approvalType !== "recovery")) {
    sendJson(res, 400, { error: "tokenId, approvalType 필수" });
    return;
  }
  // 토큰 검증 (최소 scope 1로 존재/만료/소모 체크)
  const rows = await dbSelect<{ id: string; approval_type: string; scope_level: number; status: string; expires_at: string; allowed_action_ids: string[] | null }>(
    "approval_tokens",
    `id=eq.${encodeURIComponent(body.tokenId)}&select=id,approval_type,scope_level,status,expires_at,allowed_action_ids`,
  );
  if (rows.length === 0) {
    sendJson(res, 404, { valid: false, reason: "토큰 없음" });
    return;
  }
  const t = rows[0];
  if (t.approval_type !== body.approvalType) {
    sendJson(res, 200, { valid: false, reason: "타입 불일치" });
    return;
  }
  if (t.status === "consumed") {
    // 소모된 토큰이지만 방금 consume된 것일 수 있으므로 200으로 리턴
    sendJson(res, 200, {
      valid: true,
      consumed: true,
      scopeLevel: t.scope_level,
      allowedActionIds: t.allowed_action_ids,
    });
    return;
  }
  if (t.status !== "active") {
    sendJson(res, 200, { valid: false, reason: t.status });
    return;
  }
  if (new Date(t.expires_at) < new Date()) {
    sendJson(res, 200, { valid: false, reason: "만료됨" });
    return;
  }
  sendJson(res, 200, {
    valid: true,
    scopeLevel: t.scope_level,
    allowedActionIds: t.allowed_action_ids,
  });
}

// 카테고리별 플레이북 조회 (진단 결과에서 권장 복구로 제안)
async function handleListPlaybooks(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "", "http://localhost");
  const category = url.searchParams.get("category");
  const maxLevel = parseInt(url.searchParams.get("maxLevel") ?? "4");
  let query = "enabled=eq.true&order=sort_order.asc";
  if (category) query += `&category=eq.${category}`;
  query += `&required_approval_level=lte.${maxLevel}`;
  const rows = await dbSelect("playbooks", query);
  sendJson(res, 200, rows);
}

async function handleListIssues(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "", "http://localhost");
  const sessionId = url.searchParams.get("sessionId");
  const status = url.searchParams.get("status");
  let query = "order=detected_at.desc&limit=50";
  if (sessionId) query += `&session_id=eq.${sessionId}`;
  if (status) query += `&status=eq.${status}`;
  const rows = await dbSelect("issue_events", query);
  sendJson(res, 200, rows);
}

async function handleGetIssueDetail(res: ServerResponse, issueId: string): Promise<void> {
  const [issues, diagJobs, recJobs] = await Promise.all([
    dbSelect("issue_events", `id=eq.${issueId}&select=*`),
    dbSelect("diagnostic_jobs", `issue_event_id=eq.${issueId}&order=started_at.desc`),
    dbSelect("recovery_jobs", `issue_event_id=eq.${issueId}&order=started_at.desc`),
  ]);
  if (issues.length === 0) {
    sendJson(res, 404, { error: "Issue not found" });
    return;
  }
  sendJson(res, 200, {
    issue: issues[0],
    diagnosticJobs: diagJobs,
    recoveryJobs: recJobs,
  });
}

async function handleApprove(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    issueId: string;
    approvalType: "diagnostic" | "recovery";
    scopeLevel: number;
    approverId: string;
    sessionId?: string;
    allowedActionIds?: string[];
  };

  // 필수 필드 + 타입 검증 (NaN 우회 방지)
  if (!body.issueId || typeof body.issueId !== "string" ||
      !body.approverId || typeof body.approverId !== "string" ||
      (body.approvalType !== "diagnostic" && body.approvalType !== "recovery") ||
      !Number.isInteger(body.scopeLevel) || body.scopeLevel < 1 || body.scopeLevel > 4) {
    sendJson(res, 400, { error: "issueId, approvalType(diagnostic|recovery), approverId, scopeLevel(1~4) 필수" });
    return;
  }

  // 이슈가 실제 존재하는지 확인 (임의 UUID로 승인 토큰 발급 방지)
  const existing = await dbSelect("issue_events", `id=eq.${encodeURIComponent(body.issueId)}&select=id,session_id`);
  if (existing.length === 0) {
    sendJson(res, 404, { error: "존재하지 않는 이슈" });
    return;
  }

  const token = await issueApprovalToken({
    sessionId: body.sessionId,
    issueEventId: body.issueId,
    approverId: body.approverId,
    approvalType: body.approvalType,
    scopeLevel: body.scopeLevel,
    allowedActionIds: body.allowedActionIds,
  });

  // 이슈 상태 업데이트
  const newStatus =
    body.approvalType === "diagnostic" ? "acknowledged" : "diagnosed";
  await dbUpdate("issue_events", body.issueId, { status: newStatus });

  sendJson(res, 201, {
    tokenId: token.id,
    expiresAt: token.expires_at,
    scopeLevel: token.scope_level,
  });
}

async function handleListAudit(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "", "http://localhost");
  const sessionId = url.searchParams.get("sessionId");
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "100"), 500);
  let query = `order=created_at.desc&limit=${limit}`;
  if (sessionId) query += `&session_id=eq.${sessionId}`;
  const rows = await dbSelect("audit_logs", query);
  sendJson(res, 200, rows);
}
