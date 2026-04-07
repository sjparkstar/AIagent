import type { SignalingMessage } from "@remote-desktop/shared";

type SignalingEventMap = {
  "host-ready": (roomId: string) => void;
  "viewer-joined": (viewerId: string) => void;
  answer: (sdp: RTCSessionDescriptionInit, viewerId: string) => void;
  "ice-candidate": (candidate: RTCIceCandidateInit, viewerId: string) => void;
  error: (code: string, message: string) => void;
  close: () => void;
};

export class SignalingClient {
  private ws: WebSocket | null = null;
  private handlers: Partial<{ [K in keyof SignalingEventMap]: SignalingEventMap[K] }> = {};

  constructor(private readonly serverUrl: string) {}

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.serverUrl);
      let settled = false;

      const timeout = setTimeout(() => {
        if (!settled) {
          settled = true;
          this.ws?.close();
          reject(new Error("연결 타임아웃"));
        }
      }, 5000);

      this.ws.onopen = () => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          resolve();
        }
      };

      this.ws.onerror = () => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          reject(new Error("WebSocket 연결 실패"));
        }
      };

      this.ws.onclose = (e) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          reject(new Error("연결 닫힘 (code: " + e.code + ")"));
        }
        this.handlers.close?.();
      };

      this.ws.onmessage = (event: MessageEvent) => {
        let msg: SignalingMessage;
        try {
          msg = JSON.parse(event.data as string) as SignalingMessage;
        } catch {
          return;
        }
        this.handleMessage(msg);
      };
    });
  }

  private handleMessage(msg: SignalingMessage): void {
    switch (msg.type) {
      case "host-ready":
        this.handlers["host-ready"]?.(msg.roomId);
        break;
      case "viewer-joined":
        this.handlers["viewer-joined"]?.(msg.viewerId);
        break;
      case "answer":
        this.handlers["answer"]?.(msg.sdp, msg.viewerId);
        break;
      case "ice-candidate":
        this.handlers["ice-candidate"]?.(msg.candidate, msg.viewerId);
        break;
      case "error":
        this.handlers["error"]?.(msg.code, msg.message);
        break;
    }
  }

  register(passwordHash: string): void {
    this.send({ type: "register", passwordHash });
  }

  sendOffer(sdp: RTCSessionDescriptionInit, viewerId: string): void {
    this.send({ type: "offer", sdp, viewerId });
  }

  sendIceCandidate(candidate: RTCIceCandidateInit, viewerId: string): void {
    this.send({ type: "ice-candidate", candidate, viewerId });
  }

  on<K extends keyof SignalingEventMap>(event: K, handler: SignalingEventMap[K]): void {
    this.handlers[event] = handler;
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
  }

  private send(msg: SignalingMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }
}
