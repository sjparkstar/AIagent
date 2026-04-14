import "./style.css";
import { SignalingClient } from "./signaling.js";
import { PeerConnection } from "./peer.js";
import { InputCapture } from "./input-capture.js";
import { StreamDisplay } from "./stream-display.js";
import { UI } from "./ui.js";
// AI 어시스턴트 관련 모듈
import type { HostSystemInfo, SystemDiagnostics } from "@remote-desktop/shared";
import { searchDocuments, askAssistant } from "./assistant-search.js";
import { openAsWidget, isWidgetOpen } from "./assistant-widget.js";
import { startSession, updateHostInfo, recordStats, endSession, updateRecordingUrl, getSessionId, logAssistantMessage } from "./session-logger.js";
import { loadDashboardStats, renderDashboard, loadSessionDetail } from "./dashboard-stats.js";
import { runDiagnosis, resetDiagnosis } from "./auto-diagnosis.js";
import type { DiagnosisResult } from "./auto-diagnosis.js";
import { fetchMacros, createMacro, updateMacro, deleteMacro, renderMacroList } from "./macro-manager.js";
import type { Macro } from "./macro-manager.js";
import { fetchPlaybooks, createPlaybook, updatePlaybook, deletePlaybook } from "./playbook-manager.js";
import type { Playbook } from "./playbook-manager.js";
import { initMacroTab, resolveMacroResult, setTabSwitcher, sendMacroCommand, executePlaybook } from "./macro-tab.js";
import { startRecording, stopRecording, getIsRecording } from "./recording-manager.js";
import { ChatClient } from "./chat-client.js";
import type { ChatMessageData } from "./chat-client.js";
import { IssueService } from "./issue-service.js";
import type { IssueEvent, IssuePlaybook } from "./issue-service.js";

const SIGNALING_URL = `ws://${window.location.hostname}:8080`;
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
let currentStream: MediaStream | null = null;

// 채팅 클라이언트 — 뷰어 ID는 localStorage에 영구 저장 (세션 간 동일 ID 유지)
const VIEWER_ID_KEY = "viewerId";
function getOrCreateViewerId(): string {
  let id = localStorage.getItem(VIEWER_ID_KEY);
  if (!id) {
    id = "viewer-" + Math.random().toString(36).slice(2, 10);
    localStorage.setItem(VIEWER_ID_KEY, id);
  }
  return id;
}
const SERVER_HTTP_URL = `http://${window.location.hostname}:8080`;
const chatClient = new ChatClient(SERVER_HTTP_URL, getOrCreateViewerId(), "viewer");

function cleanupPeer(): void {
  inputCapture.detach();
  display?.detach();
  peer?.close();
  display = null;
  peer = null;
}

function updateRecordingButton(): void {
  const btn = document.getElementById("recording-btn");
  if (!btn) return;
  const recording = getIsRecording();
  btn.textContent = recording ? "⏹" : "⏺";
  btn.title = recording ? "녹화 중단" : "녹화 시작";
  btn.classList.toggle("recording-active", recording);
}

function notifyHostRecordingState(recording: boolean): void {
  peer?.sendMessage({ type: "recording-state", recording });
}

function teardown(reason = "manual"): void {
  // 녹화 종료 및 업로드 (비차단)
  stopRecording()
    .then((url) => { if (url) updateRecordingUrl(url).catch(() => {}); })
    .catch(() => {});

  endSession(reason).catch(() => {});
  resetDiagnosis();
  stopReconnect();
  cleanupPeer();
  signaling?.close();
  signaling = null;
  currentRoomId = "";
  isReconnecting = false;
  currentStream = null;
  updateRecordingButton();
  // 채팅 WebSocket 종료 (채팅방 이력은 서버에 유지)
  chatClient.disconnect();
  // 스레드 패널이 열려 있으면 닫기
  closeThreadPanel();
  // 위젯 메시지 영역 초기화
  chatWidgetMessages.innerHTML = "";
  chatWidgetTyping.textContent = "";
  chatWidgetBadge.textContent = "0";
  chatWidgetBadge.classList.add("hidden");
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

    // 녹화: 자동 시작 설정이 켜져있으면 자동 시작
    currentStream = stream;
    if (localStorage.getItem("autoRecord") !== "false") {
      const sid = getSessionId();
      if (sid) {
        startRecording(stream, sid);
        updateRecordingButton();
        notifyHostRecordingState(true);
      }
    }

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
      try {
        if (msg.info) {
          updateHostInfoUI(msg.info);
          updateHostInfo(msg.info).catch(() => {});
        }
      } catch (e) {
        console.error("[main] host-info 처리 오류:", e);
      }
    } else if (msg.type === "host-diagnostics") {
      try {
        const diag = msg.diagnostics;
        if (diag?.system) {
          updateDiagnosticsUI(diag);
          renderDiagnosisAlerts(runDiagnosis(diag));
          const osStr = (diag.system.os ?? "").toLowerCase();
          if (osStr.includes("windows")) hostPlatform = "win32";
          else if (osStr.includes("darwin")) hostPlatform = "darwin";
          else if (osStr.includes("linux")) hostPlatform = "linux";
        }
      } catch (e) {
        console.error("[main] host-diagnostics 처리 오류:", e);
      }
    } else if (msg.type === "macro-result") {
      resolveMacroResult(msg.macroId, { success: msg.success, output: msg.output, error: msg.error });
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

  // 호스트 앱이 접속 요청을 보내면 승인 다이얼로그를 띄운다
  signaling.on("host-join-request", (viewerId) => {
    const approved = confirm("호스트 앱에서 접속 요청이 왔습니다.\n\n원격 지원을 허용하시겠습니까?");
    signaling?.sendApproveHost(viewerId, approved);
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
    // 채팅 WebSocket 연결 + 채팅방 생성 (연결 성공 시)
    chatClient.connect();
    chatClient.createOrJoinRoom(currentRoomId, [chatClient.userId, "host"])
      .then((room) => {
        chatClient.setChatRoom(room.id);
        // 입장 직후 기존 메시지 로드
        renderChatMessages(room.id, true);
      })
      .catch(() => {});
    // 자동진단 이슈 서비스 초기화
    initIssueService(viewerId);
  });

  // 시그널링 WS의 커스텀 메시지 (진단/복구 브로드캐스트) 라우팅
  signaling.onCustomMessage = (msg) => {
    const type = msg["type"];
    if (type === "issue.notified") {
      issueService?.handleNotified(msg);
    } else if (type === "diagnostic.result") {
      renderDiagnosticResult(msg);
    } else if (type === "recovery.result") {
      renderRecoveryResult(msg);
    } else if (type === "verification.result") {
      const success = msg["success"] === true;
      console.log(`[verification] ${success ? "통과" : "실패"}`);
    }
  };

  // password 방식 폐지 — register 시 인자 없이 방만 생성
  signaling.register();
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

  if (osEl) osEl.textContent = `${info.os ?? "--"} ${info.version ?? ""}`;
  if (cpuEl) cpuEl.textContent = `${info.cpuUsage ?? 0}% (${(info.cpuModel ?? "").split(" ").slice(0, 3).join(" ")})`;
  if (memEl) memEl.textContent = `${info.memUsed ?? 0}MB / ${info.memTotal ?? 0}MB (${info.memTotal ? Math.round((info.memUsed ?? 0) / info.memTotal * 100) : 0}%)`;
  if (uptimeEl) uptimeEl.textContent = formatUptime(info.uptime);
}

function setText(id: string, text: string): void {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function updateDiagnosticsUI(diag: SystemDiagnostics): void {
  const s = diag.system;

  // 시스템 섹션
  setText("diag-os", `${s.os} (빌드 ${s.build})`);
  setText("diag-pc", `${s.pcName} / ${s.userName}${s.isAdmin ? " [관리자]" : ""}`);
  setText("diag-cpu", `${s.cpuModel.split(" ").slice(0, 3).join(" ")} — ${s.cpuCores}코어 ${s.cpuUsage}%`);
  setText("diag-mem", `${s.memUsed}MB / ${s.memTotal}MB (${s.memUsage}%)`);
  setText("diag-uptime", formatUptime(s.uptime));
  const diskText = s.disks.map((d) => `${d.drive} ${d.used}/${d.total}GB (${d.usage}%)`).join("  ");
  setText("diag-disks", diskText || "--");
  if (s.battery) {
    setText("diag-battery", `${s.battery.percent}% ${s.battery.charging ? "(충전 중)" : ""}`);
  } else {
    setText("diag-battery", "배터리 없음");
  }

  // 프로세스 섹션
  const topCpuEl = document.getElementById("diag-top-cpu");
  if (topCpuEl) {
    topCpuEl.innerHTML = diag.processes.topCpu
      .map((p) => `<span class="diag-proc-row"><span class="diag-proc-name">${p.name}</span><span class="diag-proc-val">${p.cpu}%</span></span>`)
      .join("");
  }
  const topMemEl = document.getElementById("diag-top-mem");
  if (topMemEl) {
    const byMem = [...diag.processes.topCpu].sort((a, b) => b.mem - a.mem).slice(0, 5);
    topMemEl.innerHTML = byMem
      .map((p) => `<span class="diag-proc-row"><span class="diag-proc-name">${p.name}</span><span class="diag-proc-val">${p.mem}MB</span></span>`)
      .join("");
  }
  const svcEl = document.getElementById("diag-services");
  if (svcEl) {
    svcEl.innerHTML = diag.processes.services
      .map((s) => `<span class="diag-proc-row"><span class="diag-proc-name">${s.displayName}</span><span class="diag-proc-val diag-svc-${s.status.toLowerCase()}">${s.status}</span></span>`)
      .join("");
  }

  // 네트워크 섹션
  const ifaceEl = document.getElementById("diag-ifaces");
  if (ifaceEl) {
    ifaceEl.innerHTML = diag.network.interfaces
      .map((i) => `<span class="diag-proc-row"><span class="diag-proc-name">${i.name}</span><span class="diag-proc-val">${i.ip}</span></span>`)
      .join("");
  }
  setText("diag-gateway", diag.network.gateway || "--");
  setText("diag-dns", diag.network.dns.slice(0, 3).join(", ") || "--");
  setText("diag-internet", diag.network.internetConnected ? "연결됨" : "연결 안 됨");
  setText("diag-wifi", diag.network.wifi ? `${diag.network.wifi.ssid} (${diag.network.wifi.signal}%)` : "--");
  setText("diag-vpn", diag.network.vpnConnected ? "연결됨" : "--");

  // 보안 섹션 — 데이터가 있을 때만 표시
  const secBody = document.getElementById("diag-sec-body");
  const hasSecurity = diag.security.firewallEnabled || diag.security.defenderEnabled || diag.security.antivirusProducts.length > 0;
  if (secBody) {
    (secBody.closest(".diag-section") as HTMLElement).style.display = hasSecurity ? "" : "none";
    if (hasSecurity) {
      setText("diag-firewall", diag.security.firewallEnabled ? "활성" : "비활성");
      setText("diag-defender", diag.security.defenderEnabled ? "활성" : "비활성");
      setText("diag-uac", diag.security.uacEnabled ? "활성" : "비활성");
      setText("diag-av", diag.security.antivirusProducts.join(", ") || "--");
    }
  }

  // 사용자 환경 섹션
  const monEl = document.getElementById("diag-monitors");
  if (monEl) {
    monEl.innerHTML = diag.userEnv.monitors
      .map((m, i) => `<span class="diag-proc-row"><span class="diag-proc-name">모니터 ${i + 1}</span><span class="diag-proc-val">${m.width}×${m.height} (x${m.scaleFactor})</span></span>`)
      .join("");
  }
  setText("diag-browser", diag.userEnv.defaultBrowser || "--");
  setText("diag-printers", diag.userEnv.printers.slice(0, 3).join(", ") || "--");

  // 최근 이벤트 섹션 — 데이터가 있을 때만 표시
  const evtBody = document.getElementById("diag-evt-body");
  if (evtBody) {
    (evtBody.closest(".diag-section") as HTMLElement).style.display = diag.recentEvents.length > 0 ? "" : "none";
    if (diag.recentEvents.length > 0) {
      const evtEl = document.getElementById("diag-events");
      if (evtEl) {
        evtEl.innerHTML = diag.recentEvents
          .map((e) => `<span class="diag-proc-row diag-event-row"><span class="diag-event-level diag-level-${e.level.toLowerCase()}">${e.level}</span><span class="diag-proc-name">${e.source}</span><span class="diag-proc-val">${e.message.slice(0, 80)}</span></span>`)
          .join("");
      }
    }
  }
}

// ── 자동 진단 알림 ────────────────────────────────────

let diagAlertEl: HTMLDivElement | null = null;
let lastDiagKey = "";
let hostPlatform = ""; // "win32" | "darwin" | "linux" (from host-diagnostics)

function renderDiagnosisAlerts(results: DiagnosisResult[]): void {
  // 진단 결과를 고유 키로 비교해서 변경 시에만 업데이트
  const key = results.map((r) => `${r.severity}:${r.title}`).join("|");
  if (key === lastDiagKey) return;
  lastDiagKey = key;

  if (!diagAlertEl) {
    diagAlertEl = document.createElement("div");
    diagAlertEl.className = "diag-alerts";
    ui.assistantMessages.parentElement!.insertBefore(diagAlertEl, ui.assistantMessages);
  }

  const severityOrder: Record<string, number> = { critical: 0, warning: 1, info: 2, ok: 3 };
  const sorted = [...results].sort((a, b) => severityOrder[a.severity] - severityOrder[b.severity]);

  const iconMap: Record<string, string> = { critical: "🔴", warning: "🟡", info: "🔵", ok: "🟢" };

  diagAlertEl.innerHTML = sorted
    .map((r) => `<div class="diag-alert diag-alert-${r.severity}">
      <span class="diag-alert-icon">${iconMap[r.severity]}</span>
      <div class="diag-alert-content">
        <span class="diag-alert-title">[${r.category}] ${r.title}</span>
        <span class="diag-alert-detail">${r.detail}</span>
      </div>
    </div>`)
    .join("");
}

// ── /macro 명령 처리 ─────────────────────────────────

async function showMacroListInChat(): Promise<void> {
  const allMacros = await fetchMacros();
  const macros = hostPlatform
    ? allMacros.filter((m) => m.os === "all" || m.os === hostPlatform)
    : allMacros;
  if (macros.length === 0) {
    ui.addAssistantMessage("assistant", "호스트 OS에 해당하는 매크로가 없습니다.");
    return;
  }

  const row = document.createElement("div");
  row.className = "message-row assistant";

  const sender = document.createElement("div");
  sender.className = "message-sender";
  sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
  row.appendChild(sender);

  const bubble = document.createElement("div");
  bubble.className = "message-bubble";
  bubble.innerHTML = `<div style="margin-bottom:6px;font-weight:600;">매크로 목록 (${macros.length}개)</div>` +
    macros.map((m) =>
      `<div style="display:flex;align-items:center;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--border-color);">
        <span style="font-size:11px;">${m.name}</span>
        <button class="macro-chat-run" data-id="${m.id}" style="background:var(--accent);color:#fff;border:none;border-radius:4px;padding:2px 8px;font-size:10px;cursor:pointer;">실행</button>
      </div>`
    ).join("");
  row.appendChild(bubble);

  ui.assistantMessages.appendChild(row);
  ui.assistantMessages.scrollTop = ui.assistantMessages.scrollHeight;

  row.querySelectorAll<HTMLButtonElement>(".macro-chat-run").forEach((btn) => {
    btn.addEventListener("click", () => {
      const m = macros.find((x) => x.id === btn.dataset["id"]);
      if (!m) return;
      if (!peer) { ui.addAssistantMessage("system", "원격 세션 연결 후 실행 가능합니다."); return; }
      if (!confirm(`"${m.name}" 매크로를 실행하시겠습니까?`)) return;

      const macroId = `${m.id}-${Date.now()}`;
      ui.addAssistantMessage("system", `매크로 실행 중: ${m.name}`);
      sendMacroCommand(() => peer, macroId, m.command, m.command_type)
        .then((result) => {
          if (result.success) {
            ui.addAssistantMessage("assistant", `✅ ${m.name} 완료\n\n${result.output.slice(0, 500)}`);
          } else {
            ui.addAssistantMessage("system", `❌ ${m.name} 실패\n\n${result.error ?? result.output}`);
          }
        })
        .catch((err: unknown) => {
          ui.addAssistantMessage("system", `매크로 실행 오류: ${err instanceof Error ? err.message : String(err)}`);
        });
    });
  });
}

async function showPlaybookListInChat(): Promise<void> {
  const allPlaybooks = await fetchPlaybooks();
  const playbooks = hostPlatform
    ? allPlaybooks.filter((pb) => {
        const types = pb.steps.map((s) => s.commandType);
        if (hostPlatform === "win32") return !types.some((t) => t === "shell");
        return !types.some((t) => t === "cmd" || t === "powershell");
      })
    : allPlaybooks;
  if (playbooks.length === 0) {
    ui.addAssistantMessage("assistant", "호스트 OS에 해당하는 플레이북이 없습니다.");
    return;
  }

  const row = document.createElement("div");
  row.className = "message-row assistant";

  const sender = document.createElement("div");
  sender.className = "message-sender";
  sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
  row.appendChild(sender);

  const bubble = document.createElement("div");
  bubble.className = "message-bubble";
  bubble.innerHTML = `<div style="margin-bottom:6px;font-weight:600;">플레이북 목록 (${playbooks.length}개)</div>` +
    playbooks.map((pb) =>
      `<div style="display:flex;align-items:center;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--border-color);">
        <div style="font-size:11px;"><strong>${pb.name}</strong><br><span style="color:var(--text-secondary);font-size:10px;">${pb.description ?? ""} (${pb.steps.length}단계)</span></div>
        <button class="pb-chat-run" data-id="${pb.id}" style="background:var(--accent);color:#fff;border:none;border-radius:4px;padding:2px 8px;font-size:10px;cursor:pointer;flex-shrink:0;">실행</button>
      </div>`
    ).join("");
  row.appendChild(bubble);

  ui.assistantMessages.appendChild(row);
  ui.assistantMessages.scrollTop = ui.assistantMessages.scrollHeight;

  row.querySelectorAll<HTMLButtonElement>(".pb-chat-run").forEach((btn) => {
    btn.addEventListener("click", () => {
      const pb = playbooks.find((x) => x.id === btn.dataset["id"]);
      if (!pb) return;
      if (!peer) { ui.addAssistantMessage("system", "원격 세션 연결 후 실행 가능합니다."); return; }
      if (!confirm(`"${pb.name}" 플레이북을 실행하시겠습니까?\n\n${pb.description ?? ""}`)) return;

      btn.disabled = true;
      ui.addAssistantMessage("system", `▶ 플레이북 시작: ${pb.name}`);

      const send = (command: string, commandType: string) => {
        const macroId = `pb-chat-${pb.id}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        return sendMacroCommand(() => peer, macroId, command, commandType);
      };

      executePlaybook(pb, send, (stepName, status, output) => {
        const icons: Record<string, string> = { running: "⏳", success: "✅", failed: "❌", skipped: "⏭️" };
        const detail = output ? `\n${output}` : "";
        ui.addAssistantMessage(status === "failed" ? "system" : "assistant", `${icons[status] ?? ""} ${stepName}${detail}`);
      }).then(() => {
        ui.addAssistantMessage("assistant", `플레이북 완료: ${pb.name}`);
      }).catch((err: unknown) => {
        ui.addAssistantMessage("system", `플레이북 오류: ${err instanceof Error ? err.message : String(err)}`);
      }).finally(() => {
        btn.disabled = false;
      });
    });
  });
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

  // 슬래시 명령 처리
  if (trimmed.toLowerCase() === "/macro") {
    ui.addAssistantMessage("user", trimmed);
    ui.assistantInput.value = "";
    showMacroListInChat();
    return;
  }
  if (trimmed.toLowerCase() === "/playbook") {
    ui.addAssistantMessage("user", trimmed);
    ui.assistantInput.value = "";
    showPlaybookListInChat();
    return;
  }

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
ui.addAssistantMessage("assistant", "안녕하세요. 상담 지원 정보를 검색해 보세요.");

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

// 설정 탭 컨테이너
const settingsContainer = document.createElement("div");
settingsContainer.className = "settings-tab-container";
settingsContainer.style.cssText = "flex:1;overflow-y:auto;padding:16px;";
settingsContainer.innerHTML = `
  <div style="font-size:14px;font-weight:600;margin-bottom:16px;color:var(--text-primary);">환경설정</div>
  <div class="settings-group">
    <div class="settings-item">
      <div>
        <div style="font-size:13px;font-weight:500;color:var(--text-primary);">녹화 자동 시작</div>
        <div style="font-size:11px;color:var(--text-secondary);margin-top:2px;">상담 연결 시 화면 녹화를 자동으로 시작합니다.</div>
      </div>
      <label class="toggle-switch">
        <input type="checkbox" id="setting-auto-record" ${localStorage.getItem("autoRecord") !== "false" ? "checked" : ""} />
        <span class="toggle-slider"></span>
      </label>
    </div>
  </div>
`;

settingsContainer.querySelector("#setting-auto-record")?.addEventListener("change", (e) => {
  const checked = (e.target as HTMLInputElement).checked;
  localStorage.setItem("autoRecord", String(checked));
});

// 매크로 탭 컨테이너 (세션 모드에서 재사용)
const macroTabContainer = document.createElement("div");
macroTabContainer.className = "macro-tab-container";
macroTabContainer.style.cssText = "flex:1;overflow-y:auto;";

// ── 채팅 탭 UI ──────────────────────────────────────────────────────────────

// 채팅 전체 컨테이너 DOM 생성 (오른쪽 패널 탭용)
const chatContainer = document.createElement("div");
chatContainer.className = "chat-container";
chatContainer.innerHTML = `
  <div class="chat-messages" id="chat-messages"></div>
  <div class="chat-typing-indicator" id="chat-typing-indicator"></div>
  <div class="chat-input-bar">
    <input type="text" class="chat-text-input" id="chat-input" placeholder="메시지를 입력하세요..." />
    <button class="btn chat-send-btn" id="chat-send-btn" title="전송">&#8594;</button>
  </div>
`;

// ── 스레드 패널 상태 ──────────────────────────────────────────────────────────

// 현재 열린 스레드의 부모 메시지 (null이면 일반 채팅 뷰)
let activeThreadMsg: ChatMessageData | null = null;
// 스레드 패널에 로드된 답글 목록 (실시간 추가에 활용)
let activeThreadReplies: ChatMessageData[] = [];

// 왼쪽 채팅 위젯 DOM 레퍼런스
const chatWidgetEl = document.getElementById("chat-widget")!;
const chatWidgetMessages = document.getElementById("chat-widget-messages")!;
const chatWidgetInput = document.getElementById("chat-widget-input") as HTMLInputElement;
const chatWidgetSendBtn = document.getElementById("chat-widget-send-btn")!;
const chatWidgetBadge = document.getElementById("chat-widget-badge")!;
const chatWidgetCollapseBtn = document.getElementById("chat-widget-collapse-btn")!;
const chatWidgetTyping = document.getElementById("chat-widget-typing")!;

// 채팅 위젯 접기/펼기 상태
let chatWidgetCollapsed = false;

// 접기/펼기 버튼 클릭
chatWidgetCollapseBtn.addEventListener("click", () => {
  chatWidgetCollapsed = !chatWidgetCollapsed;
  chatWidgetEl.classList.toggle("collapsed", chatWidgetCollapsed);
  chatWidgetCollapseBtn.textContent = chatWidgetCollapsed ? "▸" : "◂";
  if (!chatWidgetCollapsed) {
    // 펼칠 때 배지 초기화 + 읽음 처리 + 스크롤 하단
    chatWidgetBadge.textContent = "0";
    chatWidgetBadge.classList.add("hidden");
    chatClient.sendRead();
    chatWidgetMessages.scrollTop = chatWidgetMessages.scrollHeight;
  }
});

// 위젯 전송 버튼 / Enter 이벤트
chatWidgetSendBtn.addEventListener("click", () => sendChatMessageFromWidget());
chatWidgetInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    sendChatMessageFromWidget();
  } else {
    chatClient.sendTyping();
  }
});

// 위젯 전송 함수 — 스레드 패널이 열려 있으면 답글로 전송
function sendChatMessageFromWidget(): void {
  const content = chatWidgetInput.value.trim();
  if (!content) return;
  if (!chatClient.getChatRoomId()) return;
  // 스레드 패널이 열려 있는 경우 해당 패널의 입력창에서 전송해야 하므로
  // 위젯 입력창은 스레드 닫힌 상태에서만 동작
  chatClient.sendMessage(content);
  chatWidgetInput.value = "";
}

// 타이핑 타이머 (일정 시간 후 자동 숨김)
let typingHideTimer: ReturnType<typeof setTimeout> | null = null;

// 단일 버블 DOM을 만들어 반환하는 헬퍼 (탭/위젯 양쪽 재사용)
// isThreadView=true이면 스레드 패널 안에서 렌더링 — 답글 배지/버튼 표시 안 함
function buildChatBubble(msg: ChatMessageData, isThreadView = false): HTMLElement {
  const isSelf = msg.senderId === chatClient.userId;
  const isSystem = msg.senderType === "system" || msg.messageType === "system";

  const bubble = document.createElement("div");
  bubble.className = `chat-bubble ${isSystem ? "system" : isSelf ? "self" : "other"}`;
  bubble.dataset["msgId"] = msg.id;

  if (!isSelf && !isSystem) {
    const nameEl = document.createElement("div");
    nameEl.className = "chat-sender-name";
    nameEl.textContent = msg.senderType === "host" ? "호스트" : msg.senderId;
    bubble.appendChild(nameEl);
  }

  const contentEl = document.createElement("div");
  contentEl.className = "chat-content";
  contentEl.textContent = msg.content;
  bubble.appendChild(contentEl);

  if (!isSystem) {
    const metaEl = document.createElement("div");
    metaEl.className = "chat-meta";
    const timeEl = document.createElement("span");
    timeEl.className = "chat-time";
    try {
      timeEl.textContent = new Date(msg.createdAt).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit" });
    } catch {
      timeEl.textContent = "";
    }
    metaEl.appendChild(timeEl);
    bubble.appendChild(metaEl);

    // 스레드 패널 안(답글 뷰)에서는 배지/버튼 추가 안 함 (1단계 깊이 정책)
    if (!isThreadView) {
      // 답글이 1개 이상이면 "답글 N개" 배지 표시
      if (msg.replyCount > 0) {
        const badge = document.createElement("button");
        badge.className = "thread-badge";
        badge.dataset["parentId"] = msg.id;
        badge.textContent = `💬 답글 ${msg.replyCount}개`;
        badge.addEventListener("click", () => openThreadPanel(msg));
        bubble.appendChild(badge);
      }

      // 호버 시 나타나는 "답글 달기" 버튼 (답글 0개여도 스레드 시작 가능)
      const replyBtn = document.createElement("button");
      replyBtn.className = "reply-btn";
      replyBtn.textContent = "↩ 답글";
      replyBtn.addEventListener("click", () => openThreadPanel(msg));
      bubble.appendChild(replyBtn);
    }
  }
  return bubble;
}

// 채팅 메시지 1개를 DOM에 추가 (탭 영역 + 위젯 영역 동시 렌더링)
// 답글(parentMessageId가 있는 경우)은 메인 채팅에 추가하지 않고 스레드 처리만 함
function appendChatBubble(msg: ChatMessageData): void {
  // 답글이면 메인 채팅에 추가하지 않고 스레드 처리
  if (msg.parentMessageId) {
    // 부모 메시지의 replyCount 배지를 갱신 (위젯과 탭 양쪽)
    incrementReplyBadge(msg.parentMessageId);
    // 스레드 패널이 열려 있고 같은 부모 메시지이면 패널에 추가
    if (activeThreadMsg?.id === msg.parentMessageId) {
      appendReplyToThreadPanel(msg);
    }
    return;
  }

  // 일반 메시지: 탭용 메시지 영역에 추가
  const messagesEl = document.getElementById("chat-messages");
  if (messagesEl) {
    messagesEl.appendChild(buildChatBubble(msg));
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  // 위젯 메시지 영역에도 추가 (스레드 패널 모드가 아닐 때만 스크롤)
  const widgetBody = document.querySelector<HTMLElement>(".chat-widget-body");
  // 스레드 패널이 위젯을 점유 중이면 추가는 하되 스크롤은 스킵
  if (widgetBody && !activeThreadMsg) {
    chatWidgetMessages.appendChild(buildChatBubble(msg));
    chatWidgetMessages.scrollTop = chatWidgetMessages.scrollHeight;
  } else if (!activeThreadMsg) {
    chatWidgetMessages.appendChild(buildChatBubble(msg));
    chatWidgetMessages.scrollTop = chatWidgetMessages.scrollHeight;
  }
  // 스레드 패널이 열려 있는 경우에도 위젯 메시지에는 추가해 두지만
  // 패널이 닫힌 후 보여야 하므로 hidden parent에 미리 넣어둠
  if (activeThreadMsg) {
    chatWidgetMessages.appendChild(buildChatBubble(msg));
  }
}

// 부모 메시지의 답글 배지 카운트를 +1 업데이트 (위젯 + 탭 양쪽)
function incrementReplyBadge(parentId: string): void {
  // 위젯과 탭 양쪽에서 해당 부모 메시지 버블을 찾아 배지 갱신
  const selectors = [
    `#chat-widget-messages .chat-bubble[data-msg-id="${CSS.escape(parentId)}"]`,
    `#chat-messages .chat-bubble[data-msg-id="${CSS.escape(parentId)}"]`,
  ];
  for (const selector of selectors) {
    const bubble = document.querySelector<HTMLElement>(selector);
    if (!bubble) continue;

    let badge = bubble.querySelector<HTMLButtonElement>(".thread-badge");
    if (badge) {
      // 기존 배지에서 숫자 파싱 후 +1
      const m = badge.textContent?.match(/\d+/);
      const newCount = m ? parseInt(m[0], 10) + 1 : 1;
      badge.textContent = `💬 답글 ${newCount}개`;
    } else {
      // 배지가 없으면 새로 생성 (replyCount가 0이었던 메시지에 첫 답글이 달린 경우)
      badge = document.createElement("button");
      badge.className = "thread-badge";
      badge.dataset["parentId"] = parentId;
      badge.textContent = "💬 답글 1개";
      // 클릭하면 스레드 패널 열기 — 부모 메시지 데이터를 버블에서 복원
      badge.addEventListener("click", () => {
        // 현재 로컬 chatWidgetMessages에서 부모 메시지 데이터를 찾을 수 없으므로
        // replyCount를 1로 임시 세팅한 객체로 패널을 열고 서버에서 답글 로드
        const parentMsg: ChatMessageData = {
          id: parentId,
          chatRoomId: chatClient.getChatRoomId() ?? "",
          senderId: bubble.querySelector<HTMLElement>(".chat-sender-name")?.textContent ?? "",
          senderType: "viewer",
          content: bubble.querySelector<HTMLElement>(".chat-content")?.textContent ?? "",
          messageType: "text",
          createdAt: new Date().toISOString(),
          parentMessageId: null,
          replyCount: 1,
        };
        openThreadPanel(parentMsg);
      });
      // 답글 달기 버튼 앞에 삽입 (또는 metaEl 다음)
      const replyBtn = bubble.querySelector(".reply-btn");
      if (replyBtn) bubble.insertBefore(badge, replyBtn);
      else bubble.appendChild(badge);
    }
  }
}

// ── 스레드 패널 오픈/클로즈 ─────────────────────────────────────────────────

// 스레드 패널 열기: 위젯 바디를 스레드 뷰로 교체
function openThreadPanel(parentMsg: ChatMessageData): void {
  activeThreadMsg = parentMsg;
  activeThreadReplies = [];

  // 위젯 바디를 스레드 패널로 교체
  const widgetBody = document.querySelector<HTMLElement>(".chat-widget-body");
  const widgetInputBar = document.querySelector<HTMLElement>(".chat-widget-input-bar");
  if (!widgetBody) return;

  // 기존 바디 숨기기
  widgetBody.style.display = "none";
  if (widgetInputBar) widgetInputBar.style.display = "none";

  // 스레드 패널 DOM 생성
  const panel = document.createElement("div");
  panel.id = "thread-panel";
  panel.className = "thread-panel";

  // 발신 시간 포맷
  let timeStr = "";
  try { timeStr = new Date(parentMsg.createdAt).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit" }); } catch { /* 무시 */ }

  panel.innerHTML = `
    <div class="thread-panel-header">
      <button class="thread-back-btn" title="채팅으로 돌아가기">← 채팅</button>
      <span class="thread-panel-title">스레드</span>
    </div>
    <div class="thread-panel-body" id="thread-panel-body">
      <div class="thread-origin">
        <div class="thread-origin-label">${parentMsg.senderType === "host" ? "호스트" : "뷰어"} · ${timeStr}</div>
        <div class="thread-origin-content">${escapeHtml(parentMsg.content)}</div>
      </div>
      <div class="thread-divider">
        <div class="thread-divider-line"></div>
        <span class="thread-divider-label" id="thread-reply-count">답글 불러오는 중...</span>
        <div class="thread-divider-line"></div>
      </div>
    </div>
    <div class="thread-input-bar">
      <input type="text" class="chat-text-input" id="thread-input" placeholder="답글 입력..." autocomplete="off" />
      <button class="chat-send-btn thread-send-btn" id="thread-send-btn" title="전송">&#8594;</button>
    </div>
  `;

  // 뒤로 가기 버튼
  panel.querySelector(".thread-back-btn")!.addEventListener("click", closeThreadPanel);

  // 답글 전송 버튼 / Enter
  const threadInput = panel.querySelector<HTMLInputElement>("#thread-input")!;
  panel.querySelector("#thread-send-btn")!.addEventListener("click", () => sendThreadReply(threadInput));
  threadInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendThreadReply(threadInput);
    }
  });

  // 위젯 헤더 다음에 패널 삽입
  const chatWidgetEl = document.getElementById("chat-widget");
  chatWidgetEl?.appendChild(panel);

  // 서버에서 답글 로드
  loadThreadReplies(parentMsg.id);
}

// 스레드 패널 닫기: 위젯 바디 복원
function closeThreadPanel(): void {
  activeThreadMsg = null;
  activeThreadReplies = [];

  const panel = document.getElementById("thread-panel");
  panel?.remove();

  const widgetBody = document.querySelector<HTMLElement>(".chat-widget-body");
  const widgetInputBar = document.querySelector<HTMLElement>(".chat-widget-input-bar");
  if (widgetBody) widgetBody.style.display = "";
  if (widgetInputBar) widgetInputBar.style.display = "";
}

// 서버에서 답글 목록 로드 후 패널에 렌더링
async function loadThreadReplies(parentId: string): Promise<void> {
  const replies = await chatClient.loadReplies(parentId);
  activeThreadReplies = replies;

  const countEl = document.getElementById("thread-reply-count");
  if (countEl) countEl.textContent = replies.length > 0 ? `답글 ${replies.length}개` : "아직 답글이 없습니다";

  const body = document.getElementById("thread-panel-body");
  if (!body) return;

  replies.forEach((r) => {
    body.appendChild(buildChatBubble(r, true)); // 스레드 뷰이므로 배지 없음
  });

  body.scrollTop = body.scrollHeight;
}

// 스레드 패널에 실시간으로 도착한 답글 추가
function appendReplyToThreadPanel(msg: ChatMessageData): void {
  activeThreadReplies.push(msg);

  const countEl = document.getElementById("thread-reply-count");
  if (countEl) countEl.textContent = `답글 ${activeThreadReplies.length}개`;

  const body = document.getElementById("thread-panel-body");
  if (!body) return;

  body.appendChild(buildChatBubble(msg, true));
  body.scrollTop = body.scrollHeight;
}

// 스레드 답글 전송
function sendThreadReply(input: HTMLInputElement): void {
  const content = input.value.trim();
  if (!content || !activeThreadMsg) return;
  chatClient.sendMessage(content, activeThreadMsg.id);
  input.value = "";
}

// HTML 이스케이프 유틸 (XSS 방지)
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// 채팅방 입장 직후 기존 메시지 로드
async function renderChatMessages(chatRoomId: string, initialLoad: boolean): Promise<void> {
  const messagesEl = document.getElementById("chat-messages");

  // 서버는 스레드 루트(parent_message_id IS NULL)만 반환
  const messages = await chatClient.loadMessages(chatRoomId);

  if (initialLoad) {
    // 탭 영역 초기화
    if (messagesEl) {
      messagesEl.innerHTML = "";
      if (messages.length >= 30) {
        const loadMoreBtn = document.createElement("button");
        loadMoreBtn.className = "chat-load-more";
        loadMoreBtn.textContent = "이전 메시지 불러오기";
        loadMoreBtn.addEventListener("click", () => {
          const firstMsg = messagesEl.querySelector<HTMLElement>(".chat-bubble[data-msg-id]");
          const firstCreatedAt = firstMsg ? (firstMsg.querySelector(".chat-time") as HTMLElement | null)?.title : undefined;
          void loadOlderMessages(firstCreatedAt);
        });
        messagesEl.prepend(loadMoreBtn);
      }
    }
    // 위젯 영역 초기화
    chatWidgetMessages.innerHTML = "";
  }

  messages.forEach((msg) => appendChatBubble(msg));

  // 최초 로드 후 읽음 처리
  if (initialLoad) chatClient.sendRead();
}

// 위로 스크롤 시 과거 메시지 로드 (루트 메시지만 — 서버가 보장)
async function loadOlderMessages(before?: string): Promise<void> {
  const roomId = chatClient.getChatRoomId();
  if (!roomId) return;
  const messagesEl = document.getElementById("chat-messages");
  if (!messagesEl) return;

  const prevScrollHeight = messagesEl.scrollHeight;
  const older = await chatClient.loadMessages(roomId, before);

  // 기존 버튼 제거 후 buildChatBubble로 일관된 렌더링
  messagesEl.querySelector(".chat-load-more")?.remove();
  const fragment = document.createDocumentFragment();
  older.forEach((msg) => fragment.appendChild(buildChatBubble(msg)));
  messagesEl.prepend(fragment);
  // 스크롤 위치 유지
  messagesEl.scrollTop = messagesEl.scrollHeight - prevScrollHeight;
}

// 채팅 메시지 수신 콜백 등록
chatClient.onMessage = (msg: ChatMessageData) => {
  // appendChatBubble 내부에서 답글/루트 분기 처리
  appendChatBubble(msg);

  const isFromOther = msg.senderId !== chatClient.userId;

  if (isFromOther) {
    // 답글 수신은 배지/읽음에 합산 (별도 카운트 없이 단순화)
    // 위젯이 접혀있으면 위젯 배지 증가
    if (chatWidgetCollapsed) {
      const count = parseInt(chatWidgetBadge.textContent ?? "0", 10) + 1;
      chatWidgetBadge.textContent = String(count);
      chatWidgetBadge.classList.remove("hidden");
    } else {
      // 위젯이 열려있으면 읽음 처리
      chatClient.sendRead();
    }

    // 오른쪽 패널 채팅 탭이 아닌 경우 탭 배지도 증가
    if (currentTab !== "chat") {
      const tabBadge = document.getElementById("chat-unread-badge");
      if (tabBadge) {
        const count = parseInt(tabBadge.textContent ?? "0", 10) + 1;
        tabBadge.textContent = String(count);
        tabBadge.classList.remove("hidden");
      }
    }
  }
};

// 타이핑 수신 콜백 등록
chatClient.onTyping = (_chatRoomId: string, userId: string) => {
  if (userId === chatClient.userId) return;
  const typingText = "상대방이 입력 중...";

  // 탭 영역 인디케이터
  const indicator = document.getElementById("chat-typing-indicator");
  if (indicator) indicator.textContent = typingText;

  // 위젯 인디케이터
  chatWidgetTyping.textContent = typingText;

  if (typingHideTimer) clearTimeout(typingHideTimer);
  typingHideTimer = setTimeout(() => {
    if (indicator) indicator.textContent = "";
    chatWidgetTyping.textContent = "";
  }, 3000);
};

// 채팅 전송 버튼 / Enter 이벤트
chatContainer.querySelector<HTMLButtonElement>("#chat-send-btn")?.addEventListener("click", () => {
  sendChatMessage();
});
chatContainer.querySelector<HTMLInputElement>("#chat-input")?.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    sendChatMessage();
  } else {
    // 타이핑 중 알림 (100ms debounce는 생략, 키 입력마다 전송)
    chatClient.sendTyping();
  }
});

function sendChatMessage(): void {
  const input = chatContainer.querySelector<HTMLInputElement>("#chat-input");
  const content = input?.value.trim() ?? "";
  if (!content) return;
  if (!chatClient.getChatRoomId()) {
    appendChatBubble({
      id: "err-" + Date.now(),
      chatRoomId: "",
      senderId: chatClient.userId,
      senderType: "system",
      content: "채팅방에 연결되어 있지 않습니다.",
      messageType: "system",
      createdAt: new Date().toISOString(),
      parentMessageId: null,
      replyCount: 0,
    });
    return;
  }
  chatClient.sendMessage(content);
  if (input) input.value = "";
}

let currentTab = "ai";

function switchTab(tab: string): void {
  currentTab = tab;
  macroTabContainer.remove();
  tabPlaceholder.remove();
  settingsContainer.remove();
  chatContainer.remove();

  if (tab === "ai") {
    aiContentEls.forEach((el) => { el.style.display = ""; });
  } else if (tab === "macro") {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(macroTabContainer, navBar);
    initMacroTab(macroTabContainer, ui, () => peer);
  } else if (tab === "settings") {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    settingsContainer.remove();
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(settingsContainer, navBar);
  } else if (tab === "chat") {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(chatContainer, navBar);
    // 탭 열 때 안읽음 배지 초기화 + 읽음 처리
    const badge = document.getElementById("chat-unread-badge");
    if (badge) { badge.textContent = "0"; badge.classList.add("hidden"); }
    chatClient.sendRead();
    // 채팅방이 연결된 경우 스크롤 하단으로
    const messagesEl = document.getElementById("chat-messages");
    if (messagesEl) messagesEl.scrollTop = messagesEl.scrollHeight;
    else if (chatClient.getChatRoomId()) {
      // 탭 첫 진입 시 메시지 로드
      renderChatMessages(chatClient.getChatRoomId()!, false).catch(() => {});
    }
  } else {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    tabPlaceholder.textContent = `[${tab}] 추후 구현 예정입니다.`;
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(tabPlaceholder, navBar);
  }
}

setTabSwitcher(() => {
  switchTab("ai");
  document.querySelectorAll(".assistant-nav-item").forEach((b) => b.classList.remove("active"));
  const aiBtn = document.querySelector<HTMLButtonElement>('.assistant-nav-item[data-tab="ai"]');
  aiBtn?.classList.add("active");
});

document.querySelectorAll<HTMLButtonElement>(".assistant-nav-item").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".assistant-nav-item").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    switchTab(btn.dataset["tab"] ?? "ai");
  });
});

// ── 대시보드 환경설정 모달 ─────────────────────────────────

const settingsModal = document.getElementById("settings-modal");
const dashboardAutoRecord = document.getElementById("dashboard-auto-record") as HTMLInputElement | null;

if (dashboardAutoRecord) {
  dashboardAutoRecord.checked = localStorage.getItem("autoRecord") !== "false";
  dashboardAutoRecord.addEventListener("change", () => {
    localStorage.setItem("autoRecord", String(dashboardAutoRecord.checked));
    // AI Assistant 설정 탭의 토글과 동기화
    const aiToggle = document.getElementById("setting-auto-record") as HTMLInputElement | null;
    if (aiToggle) aiToggle.checked = dashboardAutoRecord.checked;
  });
}

document.getElementById("dashboard-settings-btn")?.addEventListener("click", () => {
  if (settingsModal) {
    if (dashboardAutoRecord) dashboardAutoRecord.checked = localStorage.getItem("autoRecord") !== "false";
    settingsModal.classList.remove("hidden");
  }
});
document.getElementById("settings-modal-close")?.addEventListener("click", () => {
  settingsModal?.classList.add("hidden");
});
settingsModal?.addEventListener("click", (e) => {
  if (e.target === settingsModal) settingsModal.classList.add("hidden");
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
        attachRecordingHandlers(modalBody, sid);
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

  // 매크로 관리 로딩
  const macroListEl = document.getElementById("macro-list")!;
  const macroModal = document.getElementById("macro-modal")!;
  const macroFormId = document.getElementById("macro-form-id") as HTMLInputElement;
  const macroFormName = document.getElementById("macro-form-name") as HTMLInputElement;
  const macroFormDesc = document.getElementById("macro-form-desc") as HTMLInputElement;
  const macroFormCategory = document.getElementById("macro-form-category") as HTMLSelectElement;
  const macroFormType = document.getElementById("macro-form-type") as HTMLSelectElement;
  const macroFormCommand = document.getElementById("macro-form-command") as HTMLTextAreaElement;
  const macroFormOs = document.getElementById("macro-form-os") as HTMLSelectElement;
  const macroFormAdmin = document.getElementById("macro-form-admin") as HTMLInputElement;
  const macroFormDangerous = document.getElementById("macro-form-dangerous") as HTMLInputElement;
  const macroModalTitle = document.getElementById("macro-modal-title")!;

  let allMacros: Macro[] = [];

  async function loadMacros(): Promise<void> {
    allMacros = await fetchMacros();
    renderMacroList(macroListEl, allMacros,
      (m) => openMacroForm(m),
      async (m) => { if (confirm(`"${m.name}" 매크로를 삭제하시겠습니까?`)) { await deleteMacro(m.id); await loadMacros(); } },
      (m) => { alert(`매크로 실행은 원격 세션 중에만 가능합니다.\n\n명령어: ${m.command}`); }
    );
    if (allMacros.length === 0) macroListEl.innerHTML = `<p class="session-empty">등록된 매크로가 없습니다.</p>`;
  }

  function openMacroForm(m?: Macro): void {
    macroModalTitle.textContent = m ? "매크로 수정" : "매크로 추가";
    macroFormId.value = m?.id ?? "";
    macroFormName.value = m?.name ?? "";
    macroFormDesc.value = m?.description ?? "";
    macroFormCategory.value = m?.category ?? "general";
    macroFormType.value = m?.command_type ?? "cmd";
    macroFormCommand.value = m?.command ?? "";
    macroFormOs.value = m?.os ?? "all";
    macroFormAdmin.checked = m?.requires_admin ?? false;
    macroFormDangerous.checked = m?.is_dangerous ?? false;
    macroModal.classList.remove("hidden");
  }

  document.getElementById("macro-add-btn")?.addEventListener("click", () => openMacroForm());
  document.getElementById("macro-modal-close")?.addEventListener("click", () => macroModal.classList.add("hidden"));
  macroModal.addEventListener("click", (e) => { if (e.target === macroModal) macroModal.classList.add("hidden"); });

  document.getElementById("macro-form-submit")?.addEventListener("click", async () => {
    const fields = {
      name: macroFormName.value.trim(),
      description: macroFormDesc.value.trim(),
      category: macroFormCategory.value,
      command_type: macroFormType.value,
      command: macroFormCommand.value.trim(),
      os: macroFormOs.value,
      requires_admin: macroFormAdmin.checked,
      is_dangerous: macroFormDangerous.checked,
      enabled: true,
      sort_order: 0,
    };
    if (!fields.name || !fields.command) { alert("이름과 명령어는 필수입니다."); return; }

    if (macroFormId.value) {
      await updateMacro(macroFormId.value, fields);
    } else {
      await createMacro(fields);
    }
    macroModal.classList.add("hidden");
    await loadMacros();
  });

  loadMacros().catch(() => {
    macroListEl.innerHTML = `<p class="session-empty">매크로를 불러올 수 없습니다.</p>`;
  });

  // ── 플레이북 관리 ─────────────────────────────────────
  const pbListEl = document.getElementById("playbook-list")!;
  const pbModal = document.getElementById("playbook-modal")!;
  const pbFormId = document.getElementById("pb-form-id") as HTMLInputElement;
  const pbFormName = document.getElementById("pb-form-name") as HTMLInputElement;
  const pbFormDesc = document.getElementById("pb-form-desc") as HTMLInputElement;
  const pbFormSteps = document.getElementById("pb-form-steps") as HTMLTextAreaElement;
  const pbModalTitle = document.getElementById("playbook-modal-title")!;

  let allPlaybooks: Playbook[] = [];

  async function loadPlaybooks(): Promise<void> {
    allPlaybooks = await fetchPlaybooks();
    if (allPlaybooks.length === 0) {
      pbListEl.innerHTML = `<p class="session-empty">등록된 플레이북이 없습니다.</p>`;
      return;
    }
    pbListEl.innerHTML = allPlaybooks.map((pb) => `
      <div class="macro-item" data-pb-id="${pb.id}">
        <div class="macro-item-info">
          <span class="macro-item-name">${pb.name}</span>
          <span class="macro-item-desc">${pb.description ?? ""} (${pb.steps.length}단계)</span>
        </div>
        <div class="macro-item-actions">
          <button class="btn macro-btn macro-edit-btn" data-action="edit" title="수정">✎</button>
          <button class="btn macro-btn macro-del-btn" data-action="delete" title="삭제">✕</button>
        </div>
      </div>`).join("");

    pbListEl.querySelectorAll<HTMLButtonElement>(".macro-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const item = btn.closest<HTMLElement>("[data-pb-id]");
        if (!item) return;
        const pb = allPlaybooks.find((p) => p.id === item.dataset["pbId"]);
        if (!pb) return;
        if (btn.dataset["action"] === "edit") openPbForm(pb);
        else if (btn.dataset["action"] === "delete") {
          if (confirm(`"${pb.name}" 플레이북을 삭제하시겠습니까?`)) {
            deletePlaybook(pb.id).then(() => loadPlaybooks());
          }
        }
      });
    });
  }

  function openPbForm(pb?: Playbook): void {
    pbModalTitle.textContent = pb ? "플레이북 수정" : "플레이북 추가";
    pbFormId.value = pb?.id ?? "";
    pbFormName.value = pb?.name ?? "";
    pbFormDesc.value = pb?.description ?? "";
    pbFormSteps.value = pb ? JSON.stringify(pb.steps, null, 2) : "[]";
    pbModal.classList.remove("hidden");
  }

  document.getElementById("playbook-add-btn")?.addEventListener("click", () => openPbForm());
  document.getElementById("playbook-modal-close")?.addEventListener("click", () => pbModal.classList.add("hidden"));
  pbModal.addEventListener("click", (e) => { if (e.target === pbModal) pbModal.classList.add("hidden"); });

  document.getElementById("pb-form-submit")?.addEventListener("click", async () => {
    const name = pbFormName.value.trim();
    let steps: Playbook["steps"] = [];
    try { steps = JSON.parse(pbFormSteps.value); } catch { alert("단계 JSON 형식이 올바르지 않습니다."); return; }
    if (!name) { alert("이름은 필수입니다."); return; }

    if (pbFormId.value) {
      await updatePlaybook(pbFormId.value, { name, description: pbFormDesc.value.trim(), steps });
    } else {
      await createPlaybook({ name, description: pbFormDesc.value.trim(), steps, enabled: true, sort_order: 0 });
    }
    pbModal.classList.add("hidden");
    await loadPlaybooks();
  });

  loadPlaybooks().catch(() => {
    pbListEl.innerHTML = `<p class="session-empty">플레이북을 불러올 수 없습니다.</p>`;
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
  if (!confirm("상담 연결을 종료하시겠습니까?")) return;
  teardown();
  showEndOrHome();
});

ui.fullscreenBtn.addEventListener("click", () => {
  display?.toggleFullscreen();
});

// 녹화 시작/중단 버튼
document.getElementById("recording-btn")?.addEventListener("click", async () => {
  if (getIsRecording()) {
    const url = await stopRecording();
    if (url) updateRecordingUrl(url).catch(() => {});
    notifyHostRecordingState(false);
    updateRecordingButton();
  } else {
    const sid = getSessionId();
    if (!sid || !currentStream) return;
    startRecording(currentStream, sid);
    notifyHostRecordingState(true);
    updateRecordingButton();
  }
});

// 상담 종료 화면 — 확인 버튼
document.getElementById("end-close-btn")?.addEventListener("click", () => {
  window.close();
});

// ── 진단 패널 접기/펼치기 ──────────────────────────────

const diagToggleBtn = document.getElementById("diag-toggle-btn");
const diagDetail = document.getElementById("diag-detail");

diagToggleBtn?.addEventListener("click", () => {
  if (!diagDetail) return;
  const isHidden = diagDetail.style.display === "none";
  diagDetail.style.display = isHidden ? "block" : "none";
  if (diagToggleBtn) diagToggleBtn.textContent = isHidden ? "▴ 접기" : "▾ 상세";
});

document.querySelectorAll<HTMLElement>(".diag-section-header").forEach((header) => {
  header.addEventListener("click", () => {
    const targetId = header.dataset["target"];
    if (!targetId) return;
    const body = document.getElementById(targetId);
    if (!body) return;
    const isHidden = body.style.display === "none";
    body.style.display = isHidden ? "block" : "none";
    header.textContent = header.textContent?.replace(isHidden ? "▸" : "▾", isHidden ? "▾" : "▸") ?? header.textContent;
  });
});

// ── 녹화/PDF 이벤트 핸들러 ──────────────────────────────

function attachRecordingHandlers(container: HTMLElement, sessionId: string): void {
  // 재생 버튼
  container.querySelectorAll<HTMLButtonElement>(".btn-play-recording").forEach((btn) => {
    btn.addEventListener("click", () => {
      const section = container.querySelector(".recording-player-section") as HTMLElement | null;
      if (section) {
        const isVisible = section.style.display !== "none";
        section.style.display = isVisible ? "none" : "block";
        btn.textContent = isVisible ? "재생" : "닫기";
      }
    });
  });

  // 요약 버튼
  container.querySelectorAll<HTMLButtonElement>(".btn-summarize").forEach((btn) => {
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      btn.textContent = "요약 생성 중...";

      try {
        const baseUrl = `${window.location.protocol}//${window.location.hostname}:8080`;
        const res = await fetch(`${baseUrl}/api/summarize-session`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId }),
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json() as { pdfUrl: string };

        btn.textContent = "완료!";
        const pdfLink = document.createElement("a");
        pdfLink.href = `${baseUrl}${data.pdfUrl}`;
        pdfLink.target = "_blank";
        pdfLink.style.cssText = "color:var(--accent);text-decoration:none;margin-left:8px;";
        pdfLink.textContent = "PDF 다운로드";
        btn.parentElement?.appendChild(pdfLink);
      } catch (e) {
        btn.textContent = "요약 실패";
        btn.disabled = false;
        console.error("[summarize]", e);
      }
    });
  });
}

// ── 자동진단/복구 이슈 UI (PLAN.md 승인형 플로우) ────────────────
let issueService: IssueService | null = null;
let currentViewerId = "";

function initIssueService(viewerId: string): void {
  currentViewerId = viewerId;
  const serverUrl = `http://${window.location.hostname}:8080`;
  issueService = new IssueService(serverUrl);
  issueService.onIssuesChanged = renderIssueAlerts;
}

function renderIssueAlerts(): void {
  const container = document.getElementById("issue-alerts");
  if (!container || !issueService) return;
  const issues = issueService.getActiveIssues();
  if (issues.length === 0) {
    container.classList.add("hidden");
    container.innerHTML = "";
    return;
  }
  container.classList.remove("hidden");
  container.innerHTML = issues.map(renderIssueCard).join("");
  // 버튼 이벤트 연결
  container.querySelectorAll<HTMLButtonElement>("[data-approve]").forEach((btn) => {
    btn.addEventListener("click", () => onApproveDiagnostic(btn.dataset["approve"] ?? ""));
  });
  container.querySelectorAll<HTMLButtonElement>("[data-dismiss]").forEach((btn) => {
    btn.addEventListener("click", () => {
      issueService?.dismissIssue(btn.dataset["dismiss"] ?? "");
    });
  });
}

function renderIssueCard(issue: IssueEvent): string {
  const icon = issue.severity === "critical" ? "🔴" : issue.severity === "warning" ? "🟡" : "🔵";
  const statusLabel = ({
    "detected": "승인 필요",
    "acknowledged": "진단 중",
    "diagnosed": "복구 대기",
    "recovered": "복구 완료",
  } as Record<string, string>)[issue.status] ?? issue.status;
  const actionable = issue.status === "detected";
  return `
    <div class="issue-card ${issue.severity}">
      <div class="issue-card-title">
        <span>${icon}</span>
        <span>[${issue.category}] ${issue.summary}</span>
        <span class="issue-card-status">${statusLabel}</span>
      </div>
      ${issue.detail ? `<div class="issue-card-detail">${issue.detail}</div>` : ""}
      ${actionable ? `
        <div class="issue-card-actions">
          <button class="issue-card-btn primary" data-approve="${issue.id}">상세 진단 승인</button>
          <button class="issue-card-btn secondary" data-dismiss="${issue.id}">무시</button>
        </div>
      ` : ""}
    </div>
  `;
}

async function onApproveDiagnostic(issueId: string): Promise<void> {
  if (!issueService || !signaling) return;
  const issue = issueService.getActiveIssues().find((i) => i.id === issueId);
  if (!issue) return;

  const result = await issueService.approveDiagnostic({
    issueId,
    approverId: currentViewerId,
    scopeLevel: 1,
    sessionId: getSessionId() ?? undefined,
  });
  if (!result) {
    alert("진단 승인 실패");
    return;
  }

  // 보안 강화: 서버가 카테고리별 고정 스텝으로 호스트 디스패치 — 뷰어는 approve만 보냄
  signaling.sendRaw({
    type: "approve.diagnostic",
    issueId,
    scopeLevel: 1,
    approverId: currentViewerId,
    approvalToken: result.tokenId,
  });
}

// 주의: 진단 스텝은 서버(diagnosis-ws.ts)에서 카테고리별 고정 정의.
// 뷰어가 임의 command를 주입하지 못하도록 뷰어 측 함수는 제거됨.

function renderDiagnosticResult(msg: Record<string, unknown>): void {
  const issueId = String(msg["issueId"] ?? "");
  const candidates = (msg["rootCauseCandidates"] as unknown[]) ?? [];
  let text = "🔍 진단 결과:\n";
  for (const c of candidates.slice(0, 3)) {
    const m = c as Record<string, unknown>;
    const confidencePct = Math.round(((m["confidence"] as number) ?? 0) * 100);
    text += `• ${m["cause"]} (신뢰도 ${confidencePct}%)\n`;
  }
  // AI 채팅에 시스템 메시지로 표시
  ui.addAssistantMessage("assistant", text.trim());

  // 권장 플레이북 로드 → AI 채팅에 권장 복구 카드 추가
  const issue = issueService?.getActiveIssues().find((i) => i.id === issueId);
  if (!issue) return;
  void issueService?.loadPlaybooks(issue.category).then((playbooks) => {
    if (playbooks.length === 0) return;
    const html = renderRecoveryCard(issue, playbooks);
    appendHtmlToChat(html);
    bindRecoveryButtons(issue);
  });
}

function renderRecoveryCard(_issue: IssueEvent, playbooks: IssuePlaybook[]): string {
  const rows = playbooks.slice(0, 5).map((p) => {
    const riskClass = p.risk_level ?? "medium";
    const riskLabel = ({ low: "낮음", medium: "중간", high: "높음", critical: "매우 높음" } as Record<string, string>)[p.risk_level] ?? p.risk_level;
    return `
      <div class="recovery-playbook-row">
        <div style="flex:1">
          <div class="recovery-playbook-name">${p.name}</div>
          <div class="recovery-playbook-badges">
            <span class="recovery-badge ${riskClass}">위험도 ${riskLabel}</span>
            <span class="recovery-badge level">Level ${p.required_approval_level}</span>
          </div>
        </div>
        <button class="issue-card-btn primary" data-recovery="${p.id}" style="flex:0 0 auto;width:auto;padding:5px 10px;">실행</button>
      </div>
    `;
  }).join("");
  return `<div class="recovery-card"><div class="recovery-card-title">🛠 권장 복구</div>${rows}</div>`;
}

function appendHtmlToChat(html: string): void {
  const container = document.getElementById("assistant-messages");
  if (!container) return;
  const div = document.createElement("div");
  div.innerHTML = html;
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

function bindRecoveryButtons(issue: IssueEvent): void {
  document.querySelectorAll<HTMLButtonElement>("[data-recovery]").forEach((btn) => {
    if (btn.dataset["bound"] === "1") return;
    btn.dataset["bound"] = "1";
    btn.addEventListener("click", () => {
      const pbId = btn.dataset["recovery"] ?? "";
      void onApproveRecovery(issue, pbId);
    });
  });
}

async function onApproveRecovery(issue: IssueEvent, pbId: string): Promise<void> {
  if (!issueService || !signaling) return;
  const playbooks = await issueService.loadPlaybooks(issue.category);
  const pb = playbooks.find((p) => p.id === pbId);
  if (!pb) return;

  // Level 3 이상은 재확인
  if (pb.required_approval_level >= 3) {
    const ok = confirm(
      `⚠️ ${pb.name}\n\n위험도: ${pb.risk_level}\n승인 Level ${pb.required_approval_level} 필요\n\n이 복구는 시스템에 영향을 줄 수 있습니다. 실행하시겠습니까?`,
    );
    if (!ok) return;
  }

  const result = await issueService.approveRecovery({
    issueId: issue.id,
    approverId: currentViewerId,
    scopeLevel: pb.required_approval_level,
    allowedActionIds: [pb.id],
    sessionId: getSessionId() ?? undefined,
  });
  if (!result) {
    alert("복구 승인 실패");
    return;
  }

  // 보안 강화: 뷰어는 playbookId만 전달 — 서버가 DB에서 조회 후 호스트에 명령 전송
  signaling.sendRaw({
    type: "approve.recovery",
    issueId: issue.id,
    playbookId: pb.id,
    scopeLevel: pb.required_approval_level,
    approverId: currentViewerId,
    approvalToken: result.tokenId,
  });
  ui.addAssistantMessage("assistant", `⏳ 복구 실행 중: ${pb.name}`);
}

function renderRecoveryResult(msg: Record<string, unknown>): void {
  const success = msg["success"] === true;
  const rolled = msg["rolledBack"] === true;
  const steps = (msg["stepResults"] as unknown[]) ?? [];
  let text = success ? "✅ 복구 완료\n" : (rolled ? "↩️ 롤백됨\n" : "❌ 복구 실패\n");
  for (const s of steps.slice(0, 5)) {
    const m = s as Record<string, unknown>;
    text += `  ${m["status"] === "success" ? "✓" : "✗"} ${m["stepName"]}\n`;
  }
  ui.addAssistantMessage("assistant", text.trim());
}

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    teardown();
  });
}
