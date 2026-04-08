import { SignalingClient } from "./signaling";
import { PeerManager } from "./peer-manager";
import type { ScreenSource } from "../main/capture";
import { DEFAULT_PORT } from "@remote-desktop/shared";

const DUMMY_PASS = "nopass";
const RECONNECT_TIMEOUT_MS = 30_000;

const signaling = new SignalingClient();
const peerManager = new PeerManager(signaling);

let currentStream: MediaStream | null = null;
let currentSourceId: string | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let isConnected = false;
let sysInfoTimer: ReturnType<typeof setInterval> | null = null;

function setConnectBtnState(connected: boolean): void {
  isConnected = connected;
  connectBtn.dataset["state"] = connected ? "connected" : "disconnected";
  connectBtn.style.display = connected ? "inline-block" : "none";
  connectBtn.textContent = "연결 종료";
  connectBtn.className = "btn-danger";
  connectBtn.disabled = false;
}

const serverUrlInput = document.getElementById("server-url") as HTMLInputElement;
const roomIdInput = document.getElementById("room-id-input") as HTMLInputElement;
const connectBtn = document.getElementById("connect-btn") as HTMLButtonElement;
const connectError = document.getElementById("connect-error") as HTMLDivElement;
const shareSection = document.getElementById("share-section") as HTMLDivElement;
const statusText = document.getElementById("status-text") as HTMLSpanElement;
const previewVideo = document.getElementById("preview-video") as HTMLVideoElement;
const sharingSourceName = document.getElementById("sharing-source-name") as HTMLSpanElement;
const confirmOverlay = document.getElementById("confirm-overlay") as HTMLDivElement;
const confirmCancel = document.getElementById("confirm-cancel") as HTMLButtonElement;
const confirmOk = document.getElementById("confirm-ok") as HTMLButtonElement;
const errorOverlay = document.getElementById("error-overlay") as HTMLDivElement;
const errorPopupMsg = document.getElementById("error-popup-msg") as HTMLParagraphElement;
const errorPopupOk = document.getElementById("error-popup-ok") as HTMLButtonElement;

function setStatus(text: string): void {
  statusText.textContent = text;
}

function showError(message: string): void {
  connectError.textContent = message;
}

function showErrorPopup(message: string): void {
  errorPopupMsg.textContent = message;
  errorOverlay.style.display = "flex";
  roomIdInput.value = "";
}

function clearError(): void {
  connectError.textContent = "";
}

async function startScreenCapture(sourceId: string): Promise<MediaStream> {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: "desktop",
        chromeMediaSourceId: sourceId,
      },
    } as MediaTrackConstraints,
  });
  return stream;
}

async function startSharingFirstSource(): Promise<void> {
  if (!window.hostAPI) return;

  let sources: ScreenSource[];
  try {
    sources = await window.hostAPI.getScreenSources();
  } catch (err) {
    showError("화면 소스를 가져올 수 없습니다: " + String(err));
    return;
  }

  if (sources.length === 0) {
    showError("사용 가능한 화면 소스가 없습니다.");
    return;
  }

  const firstSource = sources[0];
  try {
    if (currentStream) {
      currentStream.getTracks().forEach((t) => t.stop());
    }
    currentStream = await startScreenCapture(firstSource.id);
    currentSourceId = firstSource.id;
    peerManager.setActiveSourceId(currentSourceId);
    peerManager.setStream(currentStream);
    previewVideo.srcObject = currentStream;
    previewVideo.play();
    stopShareBtn.style.display = "inline-block";
    if (window.hostAPI) window.hostAPI.setActiveBounds(firstSource.bounds, firstSource.scaleFactor);
    if (sharingSourceName) {
      sharingSourceName.textContent = firstSource.name;
    }
    peerManager.broadcastToViewers({
      type: "source-changed",
      sourceId: firstSource.id,
      name: firstSource.name,
    });
    setStatus(`화면 공유 중: ${firstSource.name}`);
  } catch (err) {
    showError("화면 캡처 실패: " + String(err));
  }
}

async function switchSource(sourceId: string): Promise<void> {
  if (sourceId === currentSourceId) {
    // 같은 소스여도 bounds를 재설정하고 뷰어에 응답
    if (window.hostAPI) {
      try {
        const sources = await window.hostAPI.getScreenSources();
        const current = sources.find((s) => s.id === sourceId);
        if (current) {
          window.hostAPI.setActiveBounds(current.bounds, current.scaleFactor);
          peerManager.broadcastToViewers({ type: "source-changed", sourceId: current.id, name: current.name });
        }
      } catch {}
    }
    return;
  }

  let sources: ScreenSource[];
  try {
    sources = await window.hostAPI.getScreenSources();
  } catch {
    return;
  }

  const target = sources.find((s) => s.id === sourceId);
  if (!target) return;

  let newStream: MediaStream;
  try {
    newStream = await startScreenCapture(sourceId);
  } catch (err) {
    console.error("[app] switchSource capture failed:", err);
    return;
  }

  const newTrack = newStream.getVideoTracks()[0];
  if (!newTrack) {
    newStream.getTracks().forEach((t) => t.stop());
    return;
  }

  if (currentStream) {
    currentStream.getTracks().forEach((t) => t.stop());
  }
  currentStream = newStream;
  currentSourceId = sourceId;
  peerManager.setActiveSourceId(currentSourceId);

  await peerManager.replaceVideoTrack(newTrack);

  peerManager.setStream(currentStream);
  previewVideo.srcObject = currentStream;
  if (window.hostAPI) window.hostAPI.setActiveBounds(target.bounds, target.scaleFactor);

  peerManager.broadcastToViewers({
    type: "source-changed",
    sourceId: target.id,
    name: target.name,
  });

  if (sharingSourceName) {
    sharingSourceName.textContent = target.name;
  }
  setStatus(`화면 공유 중: ${target.name}`);
}

peerManager.setOnSwitchSource((sourceId) => {
  switchSource(sourceId).catch((err) =>
    console.error("[app] switchSource error:", err)
  );
});

async function attemptConnect(): Promise<void> {
  if (isConnected) {
    confirmOverlay.style.display = "flex";
    return;
  }

  const serverUrl = serverUrlInput.value.trim() || `ws://localhost:${DEFAULT_PORT}`;
  const roomId = roomIdInput.value.trim();

  if (!roomId) {
    showError("접속번호를 입력하세요.");
    return;
  }

  clearError();
  connectBtn.disabled = true;
  setStatus("연결 중...");

  try {
    await signaling.connect(serverUrl);
  } catch {
    showError("시그널링 서버에 연결할 수 없습니다.");
    connectBtn.disabled = false;
    setStatus("대기 중");
    return;
  }

  signaling.send({ type: "join", roomId, password: DUMMY_PASS });
}

connectBtn.addEventListener("click", () => {
  if (isConnected) {
    confirmOverlay.style.display = "flex";
  }
});

// 접속번호 6자리 입력 시 자동 연결
roomIdInput.addEventListener("input", () => {
  const val = roomIdInput.value.trim();
  if (val.length === 6 && /^\d{6}$/.test(val) && !isConnected) {
    attemptConnect().catch(() => {});
  }
});

signaling.onMessage((msg) => {
  peerManager.handleSignalingMessage(msg);

  switch (msg.type) {
    case "room-info":
      shareSection.style.display = "block";
      setConnectBtnState(true);
      setStatus("연결됨 - 화면 공유 시작 중...");
      startSharingFirstSource();
      break;

    case "error":
      setConnectBtnState(false);
      setStatus("대기 중");
      showErrorPopup("접속번호를 확인하고 다시 입력해주세요.");
      break;
  }
});

function startSysInfoBroadcast(): void {
  stopSysInfoBroadcast();
  const send = async (): Promise<void> => {
    if (!window.hostAPI || peerManager.viewerCount === 0) return;
    try {
      const [info, diag] = await Promise.allSettled([
        window.hostAPI.getSystemInfo(),
        window.hostAPI.getSystemDiagnostics(),
      ]);
      if (info.status === "fulfilled") {
        peerManager.broadcastToViewers({ type: "host-info", info: info.value });
      }
      if (diag.status === "fulfilled") {
        peerManager.broadcastToViewers({ type: "host-diagnostics", diagnostics: diag.value });
      }
    } catch {}
  };
  send();
  sysInfoTimer = setInterval(send, 3000);
}

function stopSysInfoBroadcast(): void {
  if (sysInfoTimer) {
    clearInterval(sysInfoTimer);
    sysInfoTimer = null;
  }
}

peerManager.setOnViewerConnected((_viewerId) => {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  setStatus("뷰어 연결됨 - 화면 공유 중");
  startSysInfoBroadcast();
});

peerManager.setOnViewerDisconnected((_viewerId) => {
  // 아직 다른 뷰어가 연결되어 있으면 무시
  if (peerManager.viewerCount > 0) return;

  setStatus("뷰어 연결 끊김 - 재연결 대기 중...");

  // 이미 타이머가 돌고 있으면 중복 방지
  if (reconnectTimer) return;

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    // 대기 시간 내에 재연결이 없으면 초기 화면으로 복귀
    if (peerManager.viewerCount === 0) {
      disconnectAll();
    }
  }, RECONNECT_TIMEOUT_MS);
});

function disconnectAll(): void {
  stopSysInfoBroadcast();
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (currentStream) {
    currentStream.getTracks().forEach((t) => t.stop());
    currentStream = null;
    currentSourceId = null;
  }
  previewVideo.srcObject = null;
  peerManager.closeAll();
  signaling.disconnect();
  shareSection.style.display = "none";
  setConnectBtnState(false);
  if (sharingSourceName) {
    sharingSourceName.textContent = "";
  }
  setStatus("대기 중");
}

confirmCancel.addEventListener("click", () => {
  confirmOverlay.style.display = "none";
});

confirmOk.addEventListener("click", () => {
  confirmOverlay.style.display = "none";
  disconnectAll();
});

errorPopupOk.addEventListener("click", () => {
  errorOverlay.style.display = "none";
  roomIdInput.focus();
});
