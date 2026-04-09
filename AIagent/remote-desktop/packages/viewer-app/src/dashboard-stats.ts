import { getSupabase } from "@remote-desktop/shared";

interface DashboardData {
  totalSessions: number;
  todaySessions: number;
  avgDurationMin: number;
  avgRttMs: number;
  macroCount: number;
  playbookCount: number;
  recentSessions: {
    id: string;
    roomId: string;
    connectedAt: string;
    hostOs: string | null;
    avgRttMs: number | null;
    disconnectReason: string | null;
  }[];
}

export async function loadDashboardStats(): Promise<DashboardData> {
  const supabase = getSupabase();
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  const [totalRes, todayRes, recentRes, macroRes, playbookRes] = await Promise.all([
    supabase.from("connection_sessions").select("id", { count: "exact", head: true }),
    supabase
      .from("connection_sessions")
      .select("id", { count: "exact", head: true })
      .gte("connected_at", today.toISOString()),
    supabase
      .from("connection_sessions")
      .select("id, room_id, connected_at, disconnected_at, host_os, avg_rtt_ms, disconnect_reason")
      .order("connected_at", { ascending: false })
      .limit(10),
    supabase
      .from("assistant_logs")
      .select("id", { count: "exact", head: true })
      .ilike("content", "%매크로 실행 중%"),
    supabase
      .from("assistant_logs")
      .select("id", { count: "exact", head: true })
      .ilike("content", "%플레이북 시작%"),
  ]);

  const recent = recentRes.data ?? [];

  // 평균 계산
  let avgDuration = 0;
  let avgRtt = 0;
  let durationCount = 0;
  let rttCount = 0;

  for (const s of recent) {
    if (s.connected_at && s.disconnected_at) {
      const dur = (new Date(s.disconnected_at).getTime() - new Date(s.connected_at).getTime()) / 60000;
      avgDuration += dur;
      durationCount++;
    }
    if (s.avg_rtt_ms != null) {
      avgRtt += Number(s.avg_rtt_ms);
      rttCount++;
    }
  }

  return {
    totalSessions: totalRes.count ?? 0,
    todaySessions: todayRes.count ?? 0,
    avgDurationMin: durationCount > 0 ? Math.round(avgDuration / durationCount * 10) / 10 : 0,
    avgRttMs: rttCount > 0 ? Math.round(avgRtt / rttCount) : 0,
    macroCount: macroRes.count ?? 0,
    playbookCount: playbookRes.count ?? 0,
    recentSessions: recent.map((s) => ({
      id: s.id,
      roomId: s.room_id,
      connectedAt: s.connected_at,
      hostOs: s.host_os,
      avgRttMs: s.avg_rtt_ms != null ? Math.round(Number(s.avg_rtt_ms)) : null,
      disconnectReason: s.disconnect_reason,
    })),
  };
}

export function renderDashboard(data: DashboardData): void {
  const el = (id: string) => document.getElementById(id);

  el("stat-total")!.textContent = String(data.totalSessions);
  el("stat-today")!.textContent = String(data.todaySessions);
  el("stat-avg-duration")!.textContent = data.avgDurationMin > 0 ? `${data.avgDurationMin}m` : "-";
  el("stat-avg-rtt")!.textContent = data.avgRttMs > 0 ? `${data.avgRttMs}ms` : "-";

  const list = el("session-list")!;

  if (data.recentSessions.length === 0) {
    list.innerHTML = `<p class="session-empty">상담 이력이 없습니다.</p>`;
    return;
  }

  list.innerHTML = data.recentSessions
    .map((s) => {
      const time = new Date(s.connectedAt).toLocaleString("ko-KR", {
        month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
      });
      const os = s.hostOs ?? "-";
      const rtt = s.avgRttMs != null ? `${s.avgRttMs}ms` : "-";
      return `
        <div class="session-item" data-session-id="${s.id}" style="cursor:pointer">
          <div class="session-item-left">
            <span class="session-room">#${s.roomId}</span>
            <span class="session-time">${time}</span>
          </div>
          <div class="session-item-right">
            <span>${os}</span>
            <span>${rtt}</span>
          </div>
        </div>`;
    })
    .join("");
}

export async function loadSessionDetail(sessionId: string): Promise<string> {
  const supabase = getSupabase();

  const [sessionRes, logsRes] = await Promise.all([
    supabase.from("connection_sessions").select("*").eq("id", sessionId).single(),
    supabase.from("assistant_logs").select("*").eq("session_id", sessionId).order("created_at", { ascending: true }),
  ]);

  const s = sessionRes.data;
  if (!s) return `<p class="session-empty">세션 정보를 찾을 수 없습니다.</p>`;

  const fmt = (v: string | null) => v ? new Date(v).toLocaleString("ko-KR") : "-";
  const dur = s.connected_at && s.disconnected_at
    ? Math.round((new Date(s.disconnected_at).getTime() - new Date(s.connected_at).getTime()) / 1000)
    : null;
  const durStr = dur != null ? (dur >= 60 ? `${Math.floor(dur / 60)}분 ${dur % 60}초` : `${dur}초`) : "-";

  let html = `
    <div class="detail-section">
      <div class="detail-section-title">세션 정보</div>
      <div class="detail-grid">
        <div class="detail-row"><span class="detail-label">접속번호</span><span class="detail-value">${s.room_id}</span></div>
        <div class="detail-row"><span class="detail-label">연결 시간</span><span class="detail-value">${fmt(s.connected_at)}</span></div>
        <div class="detail-row"><span class="detail-label">종료 시간</span><span class="detail-value">${fmt(s.disconnected_at)}</span></div>
        <div class="detail-row"><span class="detail-label">지속 시간</span><span class="detail-value">${durStr}</span></div>
        <div class="detail-row"><span class="detail-label">종료 사유</span><span class="detail-value">${s.disconnect_reason ?? "-"}</span></div>
        <div class="detail-row"><span class="detail-label">재연결 수</span><span class="detail-value">${s.reconnect_count ?? 0}</span></div>
      </div>
    </div>
    <div class="detail-section">
      <div class="detail-section-title">뷰어 정보</div>
      <div class="detail-grid">
        <div class="detail-row"><span class="detail-label">브라우저</span><span class="detail-value">${(s.viewer_user_agent ?? "-").slice(0, 50)}</span></div>
        <div class="detail-row"><span class="detail-label">해상도</span><span class="detail-value">${s.viewer_screen_width ?? "-"} x ${s.viewer_screen_height ?? "-"}</span></div>
        <div class="detail-row"><span class="detail-label">언어</span><span class="detail-value">${s.viewer_language ?? "-"}</span></div>
      </div>
    </div>
    <div class="detail-section">
      <div class="detail-section-title">호스트 정보</div>
      <div class="detail-grid">
        <div class="detail-row"><span class="detail-label">OS</span><span class="detail-value">${s.host_os ?? "-"} ${s.host_os_version ?? ""}</span></div>
        <div class="detail-row"><span class="detail-label">CPU</span><span class="detail-value">${(s.host_cpu_model ?? "-").split(" ").slice(0, 3).join(" ")}</span></div>
        <div class="detail-row"><span class="detail-label">메모리</span><span class="detail-value">${s.host_mem_total_mb ? s.host_mem_total_mb + "MB" : "-"}</span></div>
      </div>
    </div>
    <div class="detail-section">
      <div class="detail-section-title">연결 품질</div>
      <div class="detail-grid">
        <div class="detail-row"><span class="detail-label">평균 비트레이트</span><span class="detail-value">${s.avg_bitrate_kbps ? s.avg_bitrate_kbps + " kbps" : "-"}</span></div>
        <div class="detail-row"><span class="detail-label">평균 FPS</span><span class="detail-value">${s.avg_framerate ?? "-"}</span></div>
        <div class="detail-row"><span class="detail-label">평균 RTT</span><span class="detail-value">${s.avg_rtt_ms ? s.avg_rtt_ms + " ms" : "-"}</span></div>
        <div class="detail-row"><span class="detail-label">패킷 손실</span><span class="detail-value">${s.total_packets_lost ?? "-"}</span></div>
        <div class="detail-row"><span class="detail-label">수신 바이트</span><span class="detail-value">${s.total_bytes_received ? Math.round(Number(s.total_bytes_received) / 1024) + " KB" : "-"}</span></div>
      </div>
    </div>`;

  const logs = logsRes.data ?? [];

  // 매크로/플레이북 실행 기록 필터링
  const macroLogs = logs.filter((l) =>
    l.content?.includes("매크로 실행 중") || l.content?.includes("매크로 완료") || l.content?.includes("매크로 실패") ||
    l.content?.includes("플레이북 시작") || l.content?.includes("플레이북 완료") || l.content?.includes("플레이북 오류") ||
    l.content?.startsWith("✅") || l.content?.startsWith("❌") || l.content?.startsWith("⏳") || l.content?.startsWith("⚠️")
  );

  if (macroLogs.length > 0) {
    const macroItems = macroLogs.map((l) => {
      const time = new Date(l.created_at).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      const preview = (l.content ?? "").length > 200 ? l.content.slice(0, 200) + "..." : l.content;
      return `<div class="ai-log-item ${l.role}"><div>${preview}</div><div class="ai-log-time">${time}</div></div>`;
    }).join("");

    html += `
      <div class="detail-section">
        <div class="detail-section-title">매크로/플레이북 실행 기록 (${macroLogs.length}건)</div>
        <div class="ai-log-list">${macroItems}</div>
      </div>`;
  }

  // AI 대화 기록 (매크로/플레이북 제외)
  const chatLogs = logs.filter((l) => !macroLogs.includes(l));
  if (chatLogs.length > 0) {
    const logItems = chatLogs.map((l) => {
      const time = new Date(l.created_at).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      const preview = (l.content ?? "").length > 300 ? l.content.slice(0, 300) + "..." : l.content;
      return `<div class="ai-log-item ${l.role}"><div>${preview}</div><div class="ai-log-time">${time}</div></div>`;
    }).join("");

    html += `
      <div class="detail-section">
        <div class="detail-section-title">AI Assistant 기록 (${chatLogs.length}건)</div>
        <div class="ai-log-list">${logItems}</div>
      </div>`;
  }

  return html;
}
