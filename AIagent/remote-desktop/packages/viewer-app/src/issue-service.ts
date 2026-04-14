// 자동진단/복구 이슈 관리 서비스 (웹 뷰어용)
// 시그널링 WS의 issue.notified 수신 + REST API로 승인

export interface IssueEvent {
  id: string;
  category: string;
  severity: "critical" | "warning" | "info";
  summary: string;
  detail?: string;
  detectedAt: string;
  status: string;
}

export interface ApprovalResult {
  tokenId: string;
  expiresAt: string;
  scopeLevel: number;
}

export interface IssuePlaybook {
  id: string;
  name: string;
  description: string;
  category: string;
  risk_level: string;
  required_approval_level: number;
  steps: { name: string; command: string; commandType: string }[];
  preconditions?: { name: string; command: string; expected: string }[];
  success_criteria?: { name: string; command: string; expected: string }[];
  rollback_steps?: { name: string; command: string; commandType: string }[];
}

export class IssueService {
  private serverUrl: string;
  private issues: IssueEvent[] = [];

  // UI 갱신 콜백
  onIssuesChanged?: () => void;

  constructor(serverUrl: string) {
    this.serverUrl = serverUrl;
  }

  getActiveIssues(): IssueEvent[] {
    return this.issues.filter(
      (i) => i.status !== "closed" && i.status !== "dismissed",
    );
  }

  // WS issue.notified 수신 처리
  handleNotified(msg: Record<string, unknown>): void {
    const issue: IssueEvent = {
      id: String(msg["issueId"] ?? ""),
      category: String(msg["category"] ?? "general"),
      severity: (msg["severity"] as "critical" | "warning" | "info") ?? "warning",
      summary: String(msg["summary"] ?? ""),
      detail: msg["detail"] ? String(msg["detail"]) : undefined,
      detectedAt: String(msg["detectedAt"] ?? new Date().toISOString()),
      status: "detected",
    };
    if (!issue.id) return;
    const idx = this.issues.findIndex((e) => e.id === issue.id);
    if (idx >= 0) this.issues[idx] = issue;
    else this.issues.unshift(issue);
    this.onIssuesChanged?.();
  }

  // 진단 승인 요청
  async approveDiagnostic(params: {
    issueId: string;
    approverId: string;
    scopeLevel?: number;
    sessionId?: string;
  }): Promise<ApprovalResult | null> {
    try {
      const resp = await fetch(`${this.serverUrl}/api/diagnosis/approve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          issueId: params.issueId,
          approvalType: "diagnostic",
          scopeLevel: params.scopeLevel ?? 1,
          approverId: params.approverId,
          sessionId: params.sessionId,
        }),
      });
      if (resp.status === 201) {
        const body = await resp.json();
        // 이슈 상태 갱신
        const idx = this.issues.findIndex((e) => e.id === params.issueId);
        if (idx >= 0) {
          this.issues[idx].status = "acknowledged";
          this.onIssuesChanged?.();
        }
        return body as ApprovalResult;
      }
    } catch (e) {
      console.error("[issue] 진단 승인 실패:", e);
    }
    return null;
  }

  // 복구 승인 요청
  async approveRecovery(params: {
    issueId: string;
    approverId: string;
    scopeLevel: number;
    allowedActionIds?: string[];
    sessionId?: string;
  }): Promise<ApprovalResult | null> {
    try {
      const resp = await fetch(`${this.serverUrl}/api/diagnosis/approve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          issueId: params.issueId,
          approvalType: "recovery",
          scopeLevel: params.scopeLevel,
          approverId: params.approverId,
          allowedActionIds: params.allowedActionIds,
          sessionId: params.sessionId,
        }),
      });
      if (resp.status === 201) return (await resp.json()) as ApprovalResult;
    } catch (e) {
      console.error("[issue] 복구 승인 실패:", e);
    }
    return null;
  }

  // 이슈 무시
  dismissIssue(issueId: string): void {
    const idx = this.issues.findIndex((e) => e.id === issueId);
    if (idx >= 0) {
      this.issues[idx].status = "dismissed";
      this.onIssuesChanged?.();
    }
  }

  // 카테고리별 권장 플레이북 조회
  async loadPlaybooks(category?: string, maxLevel = 4): Promise<IssuePlaybook[]> {
    try {
      let url = `${this.serverUrl}/api/diagnosis/playbooks?maxLevel=${maxLevel}`;
      if (category) url += `&category=${category}`;
      const resp = await fetch(url);
      if (resp.status === 200) return (await resp.json()) as IssuePlaybook[];
    } catch (e) {
      console.error("[issue] 플레이북 조회 실패:", e);
    }
    return [];
  }

  // 감사 로그 조회
  async loadAuditLogs(sessionId?: string, limit = 100): Promise<Record<string, unknown>[]> {
    try {
      let url = `${this.serverUrl}/api/diagnosis/audit?limit=${limit}`;
      if (sessionId) url += `&sessionId=${sessionId}`;
      const resp = await fetch(url);
      if (resp.status === 200) return (await resp.json()) as Record<string, unknown>[];
    } catch (e) {
      console.error("[issue] 감사 로그 조회 실패:", e);
    }
    return [];
  }
}
