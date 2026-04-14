const UPLOAD_URL = `${window.location.protocol}//${window.location.hostname}:8080/api/upload-recording`;

let mediaRecorder: MediaRecorder | null = null;
let chunks: Blob[] = [];
let currentSessionId = "";
let isRecording = false;

function pickMimeType(): string {
  const types = [
    "video/webm;codecs=vp9,opus",
    "video/webm;codecs=vp8,opus",
    "video/webm;codecs=vp9",
    "video/webm;codecs=vp8",
    "video/webm",
  ];
  for (const t of types) {
    if (MediaRecorder.isTypeSupported(t)) return t;
  }
  return "";
}

export function startRecording(stream: MediaStream, sessionId: string): void {
  if (isRecording) return;

  const mimeType = pickMimeType();
  if (!mimeType) {
    console.warn("[recording] MediaRecorder not supported");
    return;
  }

  currentSessionId = sessionId;
  chunks = [];

  try {
    mediaRecorder = new MediaRecorder(stream, {
      mimeType,
      videoBitsPerSecond: 1_000_000,
    });
  } catch (e) {
    console.error("[recording] MediaRecorder init failed:", e);
    return;
  }

  mediaRecorder.ondataavailable = (e) => {
    if (e.data.size > 0) chunks.push(e.data);
  };

  mediaRecorder.onstop = () => {
    isRecording = false;
  };

  mediaRecorder.onerror = () => {
    isRecording = false;
  };

  mediaRecorder.start(5000);
  isRecording = true;
  console.log("[recording] started", mimeType);
}

export async function stopRecording(): Promise<string | null> {
  if (!mediaRecorder || mediaRecorder.state === "inactive") return null;

  return new Promise<string | null>((resolve) => {
    mediaRecorder!.ondataavailable = (e) => {
      if (e.data.size > 0) chunks.push(e.data);
    };

    mediaRecorder!.onstop = async () => {
      isRecording = false;
      if (chunks.length === 0) {
        resolve(null);
        return;
      }

      const blob = new Blob(chunks, { type: mediaRecorder!.mimeType || "video/webm" });
      chunks = [];
      console.log(`[recording] stopped, size=${Math.round(blob.size / 1024)}KB`);

      try {
        const url = await uploadRecording(blob, currentSessionId);
        resolve(url);
      } catch (e) {
        console.error("[recording] upload failed:", e);
        downloadLocally(blob);
        resolve(null);
      }
    };

    mediaRecorder!.stop();
  });
}

async function uploadRecording(blob: Blob, sessionId: string): Promise<string> {
  const formData = new FormData();
  formData.append("file", blob, `${sessionId}.webm`);
  formData.append("sessionId", sessionId);

  const res = await fetch(UPLOAD_URL, { method: "POST", body: formData });
  if (!res.ok) throw new Error(`Upload failed: ${res.status}`);

  const data = await res.json() as { url: string };
  console.log("[recording] uploaded:", data.url);
  return data.url;
}

function downloadLocally(blob: Blob): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `recording-${currentSessionId || "session"}.webm`;
  a.click();
  URL.revokeObjectURL(url);
}

export function getIsRecording(): boolean {
  return isRecording;
}
