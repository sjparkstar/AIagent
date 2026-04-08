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
import { startSession, updateHostInfo, recordStats, endSession, logAssistantMessage } from "./session-logger.js";
import { loadDashboardStats, renderDashboard, loadSessionDetail } from "./dashboard-stats.js";
import { runDiagnosis, resetDiagnosis } from "./auto-diagnosis.js";
import type { DiagnosisResult } from "./auto-diagnosis.js";
import { fetchMacros, createMacro, updateMacro, deleteMacro, renderMacroList } from "./macro-manager.js";
import type { Macro } from "./macro-manager.js";
import { fetchPlaybooks, createPlaybook, updatePlaybook, deletePlaybook } from "./playbook-manager.js";
import type { Playbook } from "./playbook-manager.js";
import { initMacroTab, resolveMacroResult, setTabSwitcher, sendMacroCommand, executePlaybook } from "./macro-tab.js";

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
  resetDiagnosis();
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
    } else if (msg.type === "host-diagnostics") {
      updateDiagnosticsUI(msg.diagnostics);
      renderDiagnosisAlerts(runDiagnosis(msg.diagnostics));
      const osStr = msg.diagnostics.system.os.toLowerCase();
      if (osStr.includes("windows")) hostPlatform = "win32";
      else if (osStr.includes("darwin")) hostPlatform = "darwin";
      else if (osStr.includes("linux")) hostPlatform = "linux";
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

// 매크로 탭 컨테이너 (세션 모드에서 재사용)
const macroTabContainer = document.createElement("div");
macroTabContainer.className = "macro-tab-container";
macroTabContainer.style.cssText = "flex:1;overflow-y:auto;";
let currentTab = "ai";

function switchTab(tab: string): void {
  currentTab = tab;
  macroTabContainer.remove();
  tabPlaceholder.remove();

  if (tab === "ai") {
    aiContentEls.forEach((el) => { el.style.display = ""; });
  } else if (tab === "macro") {
    aiContentEls.forEach((el) => { el.style.display = "none"; });
    const navBar = document.querySelector(".assistant-nav-bar");
    if (navBar) navBar.parentElement!.insertBefore(macroTabContainer, navBar);
    initMacroTab(macroTabContainer, ui, () => peer);
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

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    teardown();
  });
}
