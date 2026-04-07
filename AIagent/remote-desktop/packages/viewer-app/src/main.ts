import "./style.css";
import { SignalingClient } from "./signaling.js";
import { PeerConnection } from "./peer.js";
import { InputCapture } from "./input-capture.js";
import { StreamDisplay } from "./stream-display.js";
import { UI } from "./ui.js";

const SIGNALING_URL = `ws://${window.location.hostname}:8080`;
const DUMMY_PASS = "nopass";
const RECONNECT_TIMEOUT_MS = 30_000;
const RECONNECT_INTERVAL_MS = 3_000;

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

function teardown(): void {
  stopReconnect();
  cleanupPeer();
  signaling?.close();
  signaling = null;
  currentRoomId = "";
  isReconnecting = false;
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

  peer.on("track", (stream) => {
    display!.attachStream(stream);
    display!.startStats(peer!, (text) => ui.updateStats(text));
    ui.hideReconnectOverlay();
    isReconnecting = false;
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
      ui.updateScreenSources(msg.sources, lastSourceId || undefined);
      if (lastSourceId) {
        peer?.sendMessage({ type: "switch-source", sourceId: lastSourceId });
      }
    } else if (msg.type === "source-changed") {
      lastSourceId = msg.sourceId;
      ui.setActiveMonitor(msg.sourceId);
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
      teardown();
      ui.showCreateScreen();
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
  });

  signaling.register(DUMMY_PASS);
}

// ── 이벤트 바인딩 ────────────────────────────────────

ui.createBtn.addEventListener("click", () => {
  createRoom().catch((err) => {
    ui.showError("대기실 생성 중 오류: " + (err instanceof Error ? err.message : String(err)));
    ui.setCreateLoading(false);
  });
});

ui.cancelBtn.addEventListener("click", () => {
  teardown();
  ui.showCreateScreen();
});

ui.disconnectBtn.addEventListener("click", () => {
  teardown();
  ui.showCreateScreen();
});

ui.fullscreenBtn.addEventListener("click", () => {
  display?.toggleFullscreen();
});

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    teardown();
  });
}
