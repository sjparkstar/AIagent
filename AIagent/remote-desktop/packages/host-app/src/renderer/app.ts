import { SignalingClient } from "./signaling";
import { PeerManager } from "./peer-manager";
import type { ScreenSource } from "../main/capture";
import { DEFAULT_PORT } from "@remote-desktop/shared";

const DUMMY_PASS = "nopass";

const signaling = new SignalingClient();
const peerManager = new PeerManager(signaling);

let currentStream: MediaStream | null = null;
let currentSourceId: string | null = null;

const serverUrlInput = document.getElementById("server-url") as HTMLInputElement;
const roomIdInput = document.getElementById("room-id-input") as HTMLInputElement;
const connectBtn = document.getElementById("connect-btn") as HTMLButtonElement;
const connectError = document.getElementById("connect-error") as HTMLDivElement;
const shareSection = document.getElementById("share-section") as HTMLDivElement;
const disconnectBtn = document.getElementById("disconnect-btn") as HTMLButtonElement;
const statusText = document.getElementById("status-text") as HTMLSpanElement;
const previewVideo = document.getElementById("preview-video") as HTMLVideoElement;
const sharingSourceName = document.getElementById("sharing-source-name") as HTMLSpanElement;
const confirmOverlay = document.getElementById("confirm-overlay") as HTMLDivElement;
const confirmCancel = document.getElementById("confirm-cancel") as HTMLButtonElement;
const confirmOk = document.getElementById("confirm-ok") as HTMLButtonElement;

function setStatus(text: string): void {
  statusText.textContent = text;
}

function showError(message: string): void {
  connectError.textContent = message;
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
    peerManager.setStream(currentStream);
    previewVideo.srcObject = currentStream;
    previewVideo.play();
    stopShareBtn.style.display = "inline-block";
    if (window.hostAPI) window.hostAPI.setActiveBounds(firstSource.bounds, firstSource.scaleFactor);
    if (sharingSourceName) {
      sharingSourceName.textContent = firstSource.name;
    }
    setStatus(`화면 공유 중: ${firstSource.name}`);
  } catch (err) {
    showError("화면 캡처 실패: " + String(err));
  }
}

async function switchSource(sourceId: string): Promise<void> {
  if (sourceId === currentSourceId) return;

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

connectBtn.addEventListener("click", async () => {
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
});

signaling.onMessage((msg) => {
  peerManager.handleSignalingMessage(msg);

  switch (msg.type) {
    case "room-info":
      shareSection.style.display = "block";
      connectBtn.disabled = false;
      setStatus("연결됨 - 화면 공유 시작 중...");
      startSharingFirstSource();
      break;

    case "error":
      showError(`오류: ${msg.message}`);
      connectBtn.disabled = false;
      setStatus("대기 중");
      break;
  }
});

peerManager.setOnViewerConnected((_viewerId) => {
  setStatus("뷰어 연결됨 - 화면 공유 중");
});

peerManager.setOnViewerDisconnected((_viewerId) => {
  setStatus("뷰어 연결 끊김");
});

function disconnectAll(): void {
  if (currentStream) {
    currentStream.getTracks().forEach((t) => t.stop());
    currentStream = null;
    currentSourceId = null;
  }
  previewVideo.srcObject = null;
  peerManager.closeAll();
  signaling.disconnect();
  shareSection.style.display = "none";
  connectBtn.disabled = false;
  if (sharingSourceName) {
    sharingSourceName.textContent = "";
  }
  setStatus("대기 중");
}

disconnectBtn.addEventListener("click", () => {
  confirmOverlay.style.display = "flex";
});

confirmCancel.addEventListener("click", () => {
  confirmOverlay.style.display = "none";
});

confirmOk.addEventListener("click", () => {
  confirmOverlay.style.display = "none";
  disconnectAll();
});
