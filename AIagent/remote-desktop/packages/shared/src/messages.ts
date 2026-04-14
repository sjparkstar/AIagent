export type SignalingMessage =
  // 뷰어 등록: 더 이상 password 사용하지 않음 (뷰어 승인 방식으로 전환됨)
  | { type: "register"; roomId?: string }
  // 호스트 접속 시도: password 불필요. 서버가 뷰어에게 승인 요청 전달
  | { type: "join"; roomId: string }
  | { type: "offer"; sdp: RTCSessionDescriptionInit; viewerId: string }
  | { type: "answer"; sdp: RTCSessionDescriptionInit; viewerId: string }
  | { type: "ice-candidate"; candidate: RTCIceCandidateInit; viewerId: string }
  | { type: "viewer-joined"; viewerId: string }
  | { type: "viewer-left"; viewerId: string }
  | { type: "host-ready"; roomId: string }
  | { type: "error"; code: string; message: string }
  | { type: "room-info"; roomId: string; viewerCount: number; viewerId: string }
  // 서버 → 뷰어: 호스트가 접속 요청을 보냈음을 알림 (승인 다이얼로그 표시용)
  | { type: "host-join-request"; viewerId: string }
  // 뷰어 → 서버: 호스트의 접속 요청을 승인/거부
  | { type: "approve-host"; viewerId: string; approved: boolean };

export type InputMessage =
  | { type: "mousemove"; x: number; y: number }
  | { type: "mousedown"; button: number }
  | { type: "mouseup"; button: number }
  | { type: "keydown"; key: string; code: string; modifiers: string[] }
  | { type: "keyup"; key: string; code: string }
  | { type: "scroll"; deltaX: number; deltaY: number }
  | { type: "text-input"; text: string }
  | { type: "clipboard-sync"; text: string };

export interface HostSystemInfo {
  os: string;
  version: string;
  cpuModel: string;
  cpuUsage: number;
  memTotal: number;
  memUsed: number;
  uptime: number;
}

export interface SystemDiagnostics {
  system: {
    os: string;
    version: string;
    build: string;
    pcName: string;
    userName: string;
    bootTime: string;
    uptime: number;
    cpuModel: string;
    cpuUsage: number;
    cpuCores: number;
    memTotal: number;
    memUsed: number;
    memUsage: number;
    disks: { drive: string; total: number; used: number; usage: number }[];
    battery: { hasBattery: boolean; percent: number; charging: boolean } | null;
    isAdmin: boolean;
  };
  processes: {
    topCpu: { name: string; pid: number; cpu: number; mem: number }[];
    services: { name: string; displayName: string; status: string; startType: string }[];
  };
  network: {
    interfaces: { name: string; ip: string; mac: string; type: string }[];
    gateway: string;
    dns: string[];
    internetConnected: boolean;
    wifi: { ssid: string; signal: number } | null;
    vpnConnected: boolean;
  };
  security: {
    firewallEnabled: boolean;
    defenderEnabled: boolean;
    uacEnabled: boolean;
    antivirusProducts: string[];
  };
  userEnv: {
    monitors: { width: number; height: number; scaleFactor: number }[];
    defaultBrowser: string;
    printers: string[];
  };
  recentEvents: { time: string; source: string; message: string; level: string }[];
}

export type ControlMessage =
  | { type: "screen-sources"; sources: { id: string; name: string }[]; activeSourceId?: string }
  | { type: "switch-source"; sourceId: string }
  | { type: "source-changed"; sourceId: string; name: string }
  | { type: "host-info"; info: HostSystemInfo }
  | { type: "host-diagnostics"; diagnostics: SystemDiagnostics }
  | { type: "execute-macro"; macroId: string; command: string; commandType: string }
  | { type: "macro-result"; macroId: string; success: boolean; output: string; error?: string }
  | { type: "recording-state"; recording: boolean }
  // 뷰어 → 호스트: Supabase 세션 UUID 전달 (채팅방 같은 sessionId로 연결되도록)
  | { type: "session-info"; sessionId: string };

export type DataChannelMessage = InputMessage | ControlMessage;

export type AnyMessage = SignalingMessage | InputMessage;

export function isSignalingMessage(msg: unknown): msg is SignalingMessage {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  const signalingTypes = new Set([
    "register",
    "join",
    "offer",
    "answer",
    "ice-candidate",
    "viewer-joined",
    "viewer-left",
    "host-ready",
    "error",
    "room-info",
    "host-join-request",
    "approve-host",
  ]);
  return typeof m["type"] === "string" && signalingTypes.has(m["type"]);
}

// ─── 채팅 메시지 타입 ─────────────────────────────────────────────────────────

// 클라이언트 → 서버: 채팅 메시지 전송 요청
// 서버 → 클라이언트: 같은 room의 모든 참여자에게 브로드캐스트
// chat-read: 사용자가 메시지를 읽었음을 서버에 알림 (last_read_at 갱신)
// chat-typing: DB 저장 없이 타이핑 중 상태만 브로드캐스트
export type ChatMessage =
  | {
      type: "chat-message";
      chatRoomId: string;
      senderId: string;
      senderType: "host" | "viewer";
      content: string;
      messageType?: "text" | "system" | "file";
      // 답글 스레드: 부모 메시지 ID. null/undefined면 일반 메시지.
      parentMessageId?: string | null;
    }
  | {
      type: "chat-message-broadcast";
      chatRoomId: string;
      messageId: string;
      senderId: string;
      senderType: string;
      content: string;
      messageType: string;
      createdAt: string;
      // 답글 스레드 정보
      parentMessageId?: string | null;
      replyCount?: number;
    }
  | {
      type: "chat-read";
      chatRoomId: string;
      userId: string;
    }
  | {
      type: "chat-read-broadcast";
      chatRoomId: string;
      userId: string;
      lastReadAt: string;
    }
  | {
      type: "chat-typing";
      chatRoomId: string;
      userId: string;
    }
  | {
      type: "chat-typing-broadcast";
      chatRoomId: string;
      userId: string;
    };

// 채팅 메시지 타입 판별 — server.ts의 isSignalingMessage와 동일한 패턴
const CHAT_TYPES = new Set([
  "chat-message",
  "chat-message-broadcast",
  "chat-read",
  "chat-read-broadcast",
  "chat-typing",
  "chat-typing-broadcast",
]);

export function isChatMessage(msg: unknown): msg is ChatMessage {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  return typeof m["type"] === "string" && CHAT_TYPES.has(m["type"]);
}

// ─── 자동진단/복구 메시지 타입 (PLAN.md 기반) ──────────────────────────────
// 이슈 탐지 → 뷰어 승인 → 진단 실행 → 복구 승인 → 플레이북 실행 → 검증 → 리포트

export type DiagnosisMessage =
  // Host → Server: 이상 감지
  | {
      type: "issue.detected";
      issueId: string;
      category: string;
      severity: "critical" | "warning" | "info";
      summary: string;
      detail?: string;
      metadata?: Record<string, unknown>;
    }
  // Server → Viewer: 이슈 발생 알림 (브로드캐스트)
  | {
      type: "issue.notified";
      issueId: string;
      category: string;
      severity: string;
      summary: string;
      detail?: string;
      detectedAt: string;
    }
  // Viewer → Server: 진단 승인 완료 후 호스트 실행 요청
  // approvalToken은 REST POST /api/diagnosis/approve로 먼저 발급받아야 함
  // 주의: diagnosticSteps는 서버가 카테고리 기반으로 결정 — 뷰어가 지정하지 못함
  | {
      type: "approve.diagnostic";
      issueId: string;
      scopeLevel: number; // 1~4
      approverId: string;
      approvalToken: string;
    }
  // Viewer → Server: 복구 승인 완료 후 호스트 실행 요청
  // 주의: playbookDef는 서버가 DB에서 조회 — 뷰어는 playbookId만 전달
  | {
      type: "approve.recovery";
      issueId: string;
      diagnosticJobId?: string;
      playbookId: string;
      scopeLevel: number;
      approverId: string;
      approvalToken: string;
    }
  // Server → Host: 진단/복구 실행 지시 (승인 토큰 포함)
  | {
      type: "run.diagnostic";
      jobId: string;
      issueId: string;
      approvalToken: string;
      diagnosticSteps: { name: string; command: string; commandType: string }[];
    }
  | {
      type: "run.recovery";
      jobId: string;
      issueId: string;
      approvalToken: string;
      playbookId: string;
      playbookDef: {
        title: string;
        preconditions?: { name: string; command: string; expected: string }[];
        actions: { name: string; command: string; commandType: string }[];
        successCriteria?: { name: string; command: string; expected: string }[];
        rollbackSteps?: { name: string; command: string; commandType: string }[];
      };
    }
  // Host → Server: 진행률 보고
  | {
      type: "diagnostic.progress";
      jobId: string;
      stepName: string;
      progress: number; // 0-100
      message?: string;
    }
  | {
      type: "recovery.progress";
      jobId: string;
      stepName: string;
      progress: number;
      message?: string;
    }
  // Host → Server: 최종 결과
  | {
      type: "diagnostic.result";
      jobId: string;
      issueId: string;
      success: boolean;
      rootCauseCandidates: { cause: string; confidence: number; evidence: string }[];
      recommendedActions: { playbookId: string; title: string; riskLevel: string }[];
      rawResult?: Record<string, unknown>;
    }
  | {
      type: "recovery.result";
      jobId: string;
      issueId: string;
      success: boolean;
      stepResults: { stepName: string; status: string; output: string; durationMs: number; error?: string }[];
      rolledBack?: boolean;
    }
  | {
      type: "verification.result";
      jobId: string;
      issueId: string;
      success: boolean;
      criteria: { name: string; passed: boolean; actual: string }[];
    }
  // Viewer → Server → Host: 작업 중단
  | {
      type: "abort.operation";
      jobId: string;
      reason?: string;
    };

const DIAGNOSIS_TYPES = new Set([
  "issue.detected",
  "issue.notified",
  "approve.diagnostic",
  "approve.recovery",
  "run.diagnostic",
  "run.recovery",
  "diagnostic.progress",
  "recovery.progress",
  "diagnostic.result",
  "recovery.result",
  "verification.result",
  "abort.operation",
]);

export function isDiagnosisMessage(msg: unknown): msg is DiagnosisMessage {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  return typeof m["type"] === "string" && DIAGNOSIS_TYPES.has(m["type"]);
}
