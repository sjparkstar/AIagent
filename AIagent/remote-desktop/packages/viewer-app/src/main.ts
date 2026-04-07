import "./style.css";
import { SignalingClient } from "./signaling.js";
import { PeerConnection } from "./peer.js";
import { InputCapture } from "./input-capture.js";
import { StreamDisplay } from "./stream-display.js";
import { UI } from "./ui.js";
// AI 어시스턴트 관련 모듈
import type { HostSystemInfo } from "@remote-desktop/shared";
import { searchDocuments, askAssistant } from "./assistant-search.js";
import { openAsWidget, isWidgetOpen } from "./assistant-widget.js";
import { startSession, updateHostInfo, recordStats, endSession, logAssistantMessage } from "./session-logger.js";
import { loadDashboardStats, renderDashboard, loadSessionDetail } from "./dashboard-stats.js";

const SIGNALING_URL = `ws://${window.location.hostname}:8080`;
const DUMMY_PASS = "nopass";
const RECONNECT_TIMEOUT_MS = 30_000;
const RECONNECT_INTERVAL_MS = 3_000;
const isSessionMode = new URLSearchParams(window.location.search).has("mode");

const ui = new UI();
const inputCapture = new InputCapture();

let signaling: SignalingClient | null = null;
let peer: PeerConnection | null = null;
let display: StreamDisplay | null = null;
let currentRoomId = "";
let isReconnecting = false;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDeadline = 0;
let lastSourceId = "";

function cleanupPeer(): void {
  inputCapture.detach();
  display?.detach();
  peer?.close();
  display = null;
  peer = null;
}

function teardown(reason = "manual"): void {
  endSession(reason).catch(() => {});
  stopReconnect();
  cleanupPeer();
  signaling?.close();
  signaling = null;
  currentRoomId = "";
  isReconnecting = false;
}

function showEndOrHome(): void {
  if (isSessionMode) {
    ui.showEndScreen();
  } else {
    ui.showCreateScreen();
  }
}

function stopReconnect(): void {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function setupPeer(viewerId: string): void {
  cleanupPeer();

  peer = new PeerConnection(signaling!);
  display = new StreamDisplay(ui.remoteVideo);

  let prevBytesReceived = 0;
  let prevTimestamp = 0;

  peer.on("track", (stream) => {
    display!.attachStream(stream);
    display!.startStats(peer!, (text) => ui.updateStats(text));
    ui.hideReconnectOverlay();
    isReconnecting = false;

    // WebRTC 통계를 5초마다 세션 로거에 기록
    const statsLogger = setInterval(async () => {
      if (!peer) { clearInterval(statsLogger); return; }
      try {
        const stats = await peer.getStats();
        let fps = 0, rtt = 0, packetsLost = 0, bytesReceived = 0;
        stats.forEach((r) => {
          if (r.type === "inbound-rtp" && (r as RTCInboundRtpStreamStats).kind === "video") {
            const s = r as RTCInboundRtpStreamStats & { framesPerSecond?: number };
            if (s.framesPerSecond != null) fps = Math.round(s.framesPerSecond);
            packetsLost = s.packetsLost ?? 0;
            bytesReceived = Number(s.bytesReceived ?? 0);
          }
          if (r.type === "candidate-pair") {
            const s = r as RTCIceCandidatePairStats & { currentRoundTripTime?: number };
            if (s.currentRoundTripTime != null) rtt = Math.round(s.currentRoundTripTime * 1000);
          }
        });
        const now = Date.now();
        const elapsed = prevTimestamp > 0 ? (now - prevTimestamp) / 1000 : 5;
        const bitrateKbps = prevTimestamp > 0 ? Math.round((bytesReceived - prevBytesReceived) * 8 / elapsed / 1000) : 0;
        prevBytesReceived = bytesReceived;
        prevTimestamp = now;
        recordStats({ bitrateKbps, framerate: fps, rttMs: rtt, packetsLost, bytesReceived });
      } catch {}
    }, 5000);
  });

  peer.on("connection-state", (state) => {
    if (state === "connected") {
      ui.setConnectionState("connected");
      ui.hideReconnectOverlay();
      isReconnecting = false;
    } else if (state === "disconnected" || state === "failed") {
      startReconnectWait();
    }
  });

  peer.on("channel-open", (channel) => {
    inputCapture.attach(ui.remoteVideo, channel);
  });

  peer.on("control-message", (msg) => {
    if (msg.type === "screen-sources") {
      const activeId = lastSourceId || msg.activeSourceId;
      ui.updateScreenSources(msg.sources, activeId);
      if (activeId) lastSourceId = activeId;
      if (lastSourceId) {
        peer?.sendMessage({ type: "switch-source", sourceId: lastSourceId });
      }
    } else if (msg.type === "source-changed") {
      lastSourceId = msg.sourceId;
      ui.setActiveMonitor(msg.sourceId);
    } else if (msg.type === "host-info") {
      updateHostInfoUI(msg.info);
      updateHostInfo(msg.info).catch(() => {});
    }
  });

  ui.setOnMonitorClick((sourceId) => {
    lastSourceId = sourceId;
    peer?.sendMessage({ type: "switch-source", sourceId });
  });

  peer.startOffer(viewerId).catch(() => {});
}

function startReconnectWait(): void {
  if (isReconnecting) return;
  isReconnecting = true;
  reconnectDeadline = Date.now() + RECONNECT_TIMEOUT_MS;

  ui.setConnectionState("disconnected");
  ui.showReconnectOverlay("재연결 대기 중...");

  tickReconnect();
}

function tickReconnect(): void {
  const remaining = reconnectDeadline - Date.now();

  if (remaining <= 0) {
    ui.showReconnectOverlay("재연결 시간 초과");
    isReconnecting = false;
    setTimeout(() => {
      teardown("reconnect_timeout");
      showEndOrHome();
    }, 2000);
    return;
  }

  const sec = Math.ceil(remaining / 1000);
  ui.showReconnectOverlay(`재연결 대기 중... (${sec}초)`);

  reconnectTimer = setTimeout(tickReconnect, 1000);
}

async function createRoom(): Promise<void> {
  ui.setCreateLoading(true);
  ui.clearError();
  teardown();

  try {
    signaling = new SignalingClient(SIGNALING_URL);
    await signaling.connect();
  } catch {
    ui.showError("시그널링 서버에 연결할 수 없습니다.");
    ui.setCreateLoading(false);
    return;
  }

  signaling.on("error", (code, message) => {
    ui.showError(`서버 오류 (${code}): ${message}`);
    ui.setCreateLoading(false);
    ui.showCreateScreen();
  });

  signaling.on("close", () => {
    if (!isReconnecting) {
      ui.setConnectionState("disconnected");
    }
  });

  signaling.on("host-ready", (roomId) => {
    currentRoomId = roomId;
    ui.showWaitingScreen(roomId);
  });

  signaling.on("viewer-joined", (viewerId) => {
    if (isReconnecting) {
      stopReconnect();
      isReconnecting = false;
      ui.hideReconnectOverlay();
    } else {
      ui.showStreamScreen(currentRoomId);
    }
    setupPeer(viewerId);
    startSession(currentRoomId, viewerId).catch(() => {});
  });

  signaling.register(DUMMY_PASS);
}

// ── 호스트 시스템 정보 UI 업데이트 ───────────────────────

function formatUptime(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function updateHostInfoUI(info: HostSystemInfo): void {
  const osEl = document.getElementById("host-os");
  const cpuEl = document.getElementById("host-cpu");
  const memEl = document.getElementById("host-mem");
  const uptimeEl = document.getElementById("host-uptime");

  if (osEl) osEl.textContent = `${info.os} ${info.version}`;
  if (cpuEl) cpuEl.textContent = `${info.cpuUsage}% (${info.cpuModel.split(" ").slice(0, 3).join(" ")})`;
  if (memEl) memEl.textContent = `${info.memUsed}MB / ${info.memTotal}MB (${Math.round(info.memUsed / info.memTotal * 100)}%)`;
  if (uptimeEl) uptimeEl.textContent = formatUptime(info.uptime);
}

// ── AI 어시스턴트 초기화 ──────────────────────────────

/**
 * 검색 입력 처리:
 * 1) Supabase document_chunks에서 텍스트 검색
 * 2) 결과 있으면 → 컨텍스트와 함께 Claude에게 요약 요청
 * 3) 결과 없으면 → Claude 일반 지식으로 답변
 */
async function handleAssistantSearch(query: string): Promise<void> {
  const trimmed = query.trim();
  if (!trimmed) return;

  ui.addAssistantMessage("user", trimmed);
  logAssistantMessage("user", trimmed, { query: trimmed }).catch(() => {});
  ui.assistantInput.value = "";
  const loadingRow = ui.addLoadingMessage();
  const startTime = Date.now();

  // 1단계: Supabase에서 관련 문서 검색
  let context: string | undefined;
  let docCount = 0;
  try {
    const results = await searchDocuments(trimmed);
    docCount = results.length;
    if (results.length > 0) {
      context = results.map((r, i) => `[${i + 1}] ${r.title}\n${r.content}`).join("\n\n---\n\n");
    }
  } catch (err) {
    console.error("[assistant] Supabase search failed:", err);
  }

  if (!context) {
    ui.addAssistantMessage("system", "내부 문서에서 결과를 찾지 못해 AI에게 질문합니다...");
  }

  // 2단계: 시그널링 서버를 통해 LLM API 호출
  try {
    const response = await askAssistant(trimmed, context);
    loadingRow.remove();
    const elapsed = Date.now() - startTime;

    const sourceLabel = response.source === "supabase" ? "📄 내부 문서 기반" : "🤖 AI 답변";
    const answerText = `${sourceLabel}\n\n${response.answer}`;
    ui.addAssistantMessage("assistant", answerText);
    logAssistantMessage("assistant", answerText, {
      source: response.source,
      query: trimmed,
      docResultsCount: docCount,
      responseTimeMs: elapsed,
    }).catch(() => {});
  } catch (err) {
    loadingRow.remove();
    console.error("[assistant] Claude API call failed:", err);
    ui.addAssistantMessage("system", "AI 응답을 가져오는 중 오류가 발생했습니다. 시그널링 서버 연결을 확인해주세요.");
  }
}

// 어시스턴트 패널 초기 메시지
ui.addAssistantMessage("assistant", "안녕하세요! 리모트콜 도움말을 검색해보세요.");

// 세션 모드: 새 창으로 열렸을 때 자동 연결 시작
if (isSessionMode) {
  createRoom().catch((err) => {
    ui.showError("상담 연결 중 오류: " + (err instanceof Error ? err.message : String(err)));
    ui.setCreateLoading(false);
  });
}

// 검색 입력창: Enter 키 전송
ui.assistantInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    handleAssistantSearch(ui.assistantInput.value).catch(() => {});
  }
});

// 전송 버튼 클릭
ui.assistantSendBtn.addEventListener("click", () => {
  handleAssistantSearch(ui.assistantInput.value).catch(() => {});
});

// 아이콘 버튼 (파일/이미지/마이크) — UI만, 추후 구현 예정
document.querySelectorAll<HTMLButtonElement>(".assistant-icon-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    const action = btn.dataset["action"] ?? "기능";
    ui.addAssistantMessage("system", `[${action}] 기능은 추후 구현 예정입니다.`);
  });
});

// 패널 접기 버튼
ui.assistantCollapseBtn.addEventListener("click", () => {
  ui.toggleAssistantPanel();
});

// status-bar 패널 열기 버튼 (접힌 상태에서 복원)
ui.assistantOpenBtn.addEventListener("click", () => {
  ui.setAssistantPanelVisible(true);
});

// 위젯 분리 버튼
ui.assistantWidgetBtn.addEventListener("click", () => {
  if (isWidgetOpen()) return; // 이미 열려있으면 무시
  openAsWidget(ui.assistantPanel, () => {
    // 팝업 닫힘 → 패널 표시 복귀
    ui.setAssistantPanelVisible(true);
  });
});

// 네비게이션 바 탭 전환
// AI Assistant 콘텐츠 영역 (메시지 + 호스트정보 + 입력바)
const aiContentEls = [
  document.getElementById("host-info-bar"),
  ui.assistantMessages,
  document.querySelector(".assistant-input-bar"),
].filter(Boolean) as HTMLElement[];

// 탭 전환 시 표시할 플레이스홀더
const tabPlaceholder = document.createElement("div");
tabPlaceholder.className = "tab-placeholder";
tabPlaceholder.style.cssText = "flex:1;display:flex;align-items:center;justify-content:center;color:var(--text-secondary);font-size:13px;";

let currentTab = "ai";

function switchTab(tab: string): void {
  currentTab = tab;
  if (tab === "ai") {
    tabPlaceholder.remove();
    aiContentEls.forEach((el) => { el.style.display = ""; });
  } else {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    tabPlaceholder.textContent = `[${tab}] 추후 구현 예정입니다.`;
    // 네비게이션바 바로 앞에 삽입
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(tabPlaceholder, navBar);
  }
}

document.querySelectorAll<HTMLButtonElement>(".assistant-nav-item").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".assistant-nav-item").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    switchTab(btn.dataset["tab"] ?? "ai");
  });
});

// ── 대시보드 통계 로딩 ──────────────────────────────────

if (!isSessionMode) {
  loadDashboardStats().then((data) => {
    renderDashboard(data);

    // 세션 아이템 클릭 → 상세 모달
    const modal = document.getElementById("session-detail-modal")!;
    const modalBody = document.getElementById("modal-body")!;
    const modalTitle = document.getElementById("modal-title")!;
    const modalCloseBtn = document.getElementById("modal-close-btn")!;

    document.getElementById("session-list")!.addEventListener("click", (e) => {
      const item = (e.target as HTMLElement).closest<HTMLElement>("[data-session-id]");
      if (!item) return;
      const sid = item.dataset["sessionId"]!;
      const room = item.querySelector(".session-room")?.textContent ?? "";

      modalTitle.textContent = `세션 상세 ${room}`;
      modalBody.innerHTML = `<p class="session-empty">로딩 중...</p>`;
      modal.classList.remove("hidden");

      loadSessionDetail(sid).then((html) => {
        modalBody.innerHTML = html;
      }).catch(() => {
        modalBody.innerHTML = `<p class="session-empty">상세 정보를 불러올 수 없습니다.</p>`;
      });
    });

    modalCloseBtn.addEventListener("click", () => modal.classList.add("hidden"));
    modal.addEventListener("click", (e) => {
      if (e.target === modal) modal.classList.add("hidden");
    });
  }).catch(() => {
    const el = document.getElementById("session-list");
    if (el) el.innerHTML = `<p class="session-empty">통계를 불러올 수 없습니다.</p>`;
  });
}

// ── 이벤트 바인딩 ────────────────────────────────────

ui.createBtn.addEventListener("click", () => {
  if (!isSessionMode) {
    // 메인 대시보드에서 클릭 → 새 창으로 세션 시작
    window.open(`${window.location.origin}${window.location.pathname}?mode=session`, "_blank");
    return;
  }
  // 세션 모드에서 클릭 → 기존 createRoom 로직
  createRoom().catch((err) => {
    ui.showError("상담 연결 중 오류: " + (err instanceof Error ? err.message : String(err)));
    ui.setCreateLoading(false);
  });
});

ui.cancelBtn.addEventListener("click", () => {
  teardown();
  showEndOrHome();
});

ui.disconnectBtn.addEventListener("click", () => {
  teardown();
  showEndOrHome();
});

ui.fullscreenBtn.addEventListener("click", () => {
  display?.toggleFullscreen();
});

// 상담 종료 화면 — 확인 버튼
document.getElementById("end-close-btn")?.addEventListener("click", () => {
  window.close();
});

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    teardown();
  });
}
