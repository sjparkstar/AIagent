import type { SignalingMessage } from "@remote-desktop/shared";

type SignalingEventMap = {
  "host-ready": (roomId: string) => void;
  "viewer-joined": (viewerId: string) => void;
  // 호스트 앱이 접속 요청을 보냈을 때 — 승인 다이얼로그 표시용
  "host-join-request": (viewerId: string) => void;
  answer: (sdp: RTCSessionDescriptionInit, viewerId: string) => void;
  "ice-candidate": (candidate: RTCIceCandidateInit, viewerId: string) => void;
  error: (code: string, message: string) => void;
  close: () => void;
};

export class SignalingClient {
  private ws: WebSocket | null = null;
  private handlers: Partial<{ [K in keyof SignalingEventMap]: SignalingEventMap[K] }> = {};
  // 알려지지 않은 메시지(진단/복구/채팅 브로드캐스트 등)를 외부에서 처리할 수 있도록 공개
  onCustomMessage?: (msg: Record<string, unknown>) => void;

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
        let msg: Record<string, unknown>;
        try {
          msg = JSON.parse(event.data as string) as Record<string, unknown>;
        } catch {
          return;
        }
        // 알려진 시그널링 메시지는 내부 handler로, 나머지는 onCustomMessage로
        const knownTypes = new Set([
          "host-ready", "viewer-joined", "host-join-request", "answer", "ice-candidate", "error",
        ]);
        if (typeof msg["type"] === "string" && knownTypes.has(msg["type"])) {
          this.handleMessage(msg as unknown as SignalingMessage);
        } else {
          this.onCustomMessage?.(msg);
        }
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
      case "host-join-request":
        // 호스트 앱이 접속 요청을 보냈음 — main.ts에서 승인 다이얼로그를 띄운다
        this.handlers["host-join-request"]?.(msg.viewerId);
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

  // password 방식 폐지 — register 시 password 없이 방만 생성
  register(): void {
    this.send({ type: "register" });
  }

  // 호스트 접속 요청에 대한 승인/거부 응답
  sendApproveHost(viewerId: string, approved: boolean): void {
    this.send({ type: "approve-host", viewerId, approved });
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

  // 외부에서 범용 메시지 전송 (진단/복구/채팅 등)
  sendRaw(msg: Record<string, unknown>): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }
}
