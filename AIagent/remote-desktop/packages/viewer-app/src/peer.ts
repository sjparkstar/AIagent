import type { ControlMessage, DataChannelMessage } from "@remote-desktop/shared";
import type { SignalingClient } from "./signaling.js";

const ICE_SERVERS: RTCIceServer[] = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
];

type PeerEventMap = {
  track: (stream: MediaStream) => void;
  "channel-open": (channel: RTCDataChannel) => void;
  "connection-state": (state: RTCPeerConnectionState) => void;
  "control-message": (msg: ControlMessage) => void;
};

export class PeerConnection {
  private pc: RTCPeerConnection;
  private inputChannel: RTCDataChannel | null = null;
  private viewerId = "";
  private handlers: Partial<{ [K in keyof PeerEventMap]: PeerEventMap[K] }> = {};

  constructor(private readonly signaling: SignalingClient) {
    this.pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    this.setupPeerEvents();
  }

  private setupPeerEvents(): void {
    this.pc.onicecandidate = ({ candidate }) => {
      if (candidate) {
        this.signaling.sendIceCandidate(candidate.toJSON(), this.viewerId);
      }
    };

    this.pc.ontrack = ({ streams, track }) => {
      console.log("[peer] ontrack fired - kind:", track.kind, "streams:", streams.length);
      if (streams[0]) {
        this.handlers.track?.(streams[0]);
      }
    };

    this.pc.onconnectionstatechange = () => {
      this.handlers["connection-state"]?.(this.pc.connectionState);
    };

    this.signaling.on("answer", async (sdp) => {
      await this.pc.setRemoteDescription(sdp);
    });

    this.signaling.on("ice-candidate", async (candidate) => {
      try {
        await this.pc.addIceCandidate(candidate);
      } catch {
        // remote description이 아직 설정되지 않은 경우 무시
      }
    });
  }

  async startOffer(viewerId: string): Promise<void> {
    this.viewerId = viewerId;

    this.pc.addTransceiver("video", { direction: "recvonly" });

    this.inputChannel = this.pc.createDataChannel("input", { negotiated: true, id: 0, ordered: true });

    this.inputChannel.onopen = () => {
      console.log("[peer] DataChannel open, readyState:", this.inputChannel?.readyState);
      if (this.inputChannel) {
        this.handlers["channel-open"]?.(this.inputChannel);
      }
    };

    this.inputChannel.onmessage = (event: MessageEvent) => {
      try {
        const msg = JSON.parse(event.data as string) as DataChannelMessage;
        const controlTypes = new Set(["screen-sources", "switch-source", "source-changed", "host-info"]);
        if (controlTypes.has(msg.type)) {
          this.handlers["control-message"]?.(msg as ControlMessage);
        }
      } catch (err) {
        console.error("[peer] DataChannel message parse error:", err);
      }
    };

    this.inputChannel.onerror = (e) => {
      console.error("[peer] DataChannel error:", e);
    };

    this.inputChannel.onclose = () => {
      console.log("[peer] DataChannel closed");
    };

    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this.signaling.sendOffer(offer, viewerId);
  }

  sendMessage(msg: DataChannelMessage): void {
    if (this.inputChannel?.readyState === "open") {
      this.inputChannel.send(JSON.stringify(msg));
    }
  }

  on<K extends keyof PeerEventMap>(event: K, handler: PeerEventMap[K]): void {
    this.handlers[event] = handler;
  }

  getStats(): Promise<RTCStatsReport> {
    return this.pc.getStats();
  }

  close(): void {
    this.inputChannel?.close();
    this.pc.close();
  }
}
