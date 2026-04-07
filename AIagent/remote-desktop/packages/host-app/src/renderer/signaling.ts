import type { SignalingMessage } from "@remote-desktop/shared";

type MessageHandler = (msg: SignalingMessage) => void;

export class SignalingClient {
  private ws: WebSocket | null = null;
  private handlers: MessageHandler[] = [];
  private url = "";
  private intentionalClose = false;

  connect(url: string): Promise<void> {
    this.disconnect();
    this.url = url;
    this.intentionalClose = false;

    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);

      this.ws.onopen = () => resolve();

      this.ws.onerror = () => reject(new Error("WebSocket connection failed"));

      this.ws.onclose = () => {
        // intentionalClose이면 자동 재연결하지 않음
      };

      this.ws.onmessage = (event: MessageEvent) => {
        try {
          const msg = JSON.parse(event.data as string) as SignalingMessage;
          this.handlers.forEach((h) => h(msg));
        } catch {}
      };
    });
  }

  send(msg: SignalingMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  disconnect(): void {
    this.intentionalClose = true;
    if (this.ws) {
      this.ws.onclose = null;
      this.ws.onerror = null;
      this.ws.onmessage = null;
      this.ws.close();
      this.ws = null;
    }
  }

  get isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }
}
