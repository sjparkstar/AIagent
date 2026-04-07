import type { DataChannelMessage, InputMessage, SignalingMessage } from "@remote-desktop/shared";
import type { SignalingClient } from "./signaling";

type ViewerEventHandler = (viewerId: string) => void;
type SwitchSourceHandler = (sourceId: string) => void;

interface PeerEntry {
  pc: RTCPeerConnection;
  dc: RTCDataChannel;
}

export class PeerManager {
  private peers = new Map<string, PeerEntry>();
  private stream: MediaStream | null = null;
  private pendingOffers = new Map<string, RTCSessionDescriptionInit>();
  private onViewerConnected: ViewerEventHandler | null = null;
  private onViewerDisconnected: ViewerEventHandler | null = null;
  private onSwitchSource: SwitchSourceHandler | null = null;

  constructor(private readonly signaling: SignalingClient) {}

  setStream(stream: MediaStream): void {
    this.stream = stream;
    this.peers.forEach(({ pc }) => this.addStreamToPeer(pc));

    if (this.pendingOffers.size > 0) {
      console.log("[peer-manager] processing", this.pendingOffers.size, "pending offers");
      const pending = new Map(this.pendingOffers);
      this.pendingOffers.clear();
      pending.forEach((sdp, viewerId) => {
        this.handleOffer(viewerId, sdp).catch((err) =>
          console.error("[peer-manager] deferred handleOffer error:", err)
        );
      });
    }
  }

  setOnViewerConnected(cb: ViewerEventHandler): void {
    this.onViewerConnected = cb;
  }

  setOnViewerDisconnected(cb: ViewerEventHandler): void {
    this.onViewerDisconnected = cb;
  }

  setOnSwitchSource(cb: SwitchSourceHandler): void {
    this.onSwitchSource = cb;
  }

  sendToViewer(viewerId: string, msg: DataChannelMessage): void {
    const entry = this.peers.get(viewerId);
    if (entry?.dc.readyState === "open") {
      entry.dc.send(JSON.stringify(msg));
    }
  }

  broadcastToViewers(msg: DataChannelMessage): void {
    const payload = JSON.stringify(msg);
    this.peers.forEach(({ dc }) => {
      if (dc.readyState === "open") {
        dc.send(payload);
      }
    });
  }

  async handleOffer(viewerId: string, sdp: RTCSessionDescriptionInit): Promise<void> {
    // 스트림이 아직 없으면 대기 큐에 저장
    if (!this.stream) {
      this.pendingOffers.set(viewerId, sdp);
      return;
    }

    const pc = this.createPeerConnection(viewerId);

    await pc.setRemoteDescription(new RTCSessionDescription(sdp));
    this.addStreamToPeer(pc);

    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    this.signaling.send({
      type: "answer",
      sdp: pc.localDescription!,
      viewerId,
    });
  }

  async handleIceCandidate(viewerId: string, candidate: RTCIceCandidateInit): Promise<void> {
    const entry = this.peers.get(viewerId);
    if (!entry) return;
    try {
      await entry.pc.addIceCandidate(new RTCIceCandidate(candidate));
    } catch (err) {
      console.error(`[peer-manager] addIceCandidate error for ${viewerId}:`, err);
    }
  }

  removeViewer(viewerId: string): void {
    const entry = this.peers.get(viewerId);
    if (entry) {
      entry.pc.close();
      this.peers.delete(viewerId);
    }
  }

  get viewerCount(): number {
    return this.peers.size;
  }

  get viewerIds(): string[] {
    return Array.from(this.peers.keys());
  }

  closeAll(): void {
    this.peers.forEach(({ pc }) => pc.close());
    this.peers.clear();
    this.stream = null;
    this.pendingOffers.clear();
  }

  private createPeerConnection(viewerId: string): RTCPeerConnection {
    const existing = this.peers.get(viewerId);
    if (existing) {
      existing.pc.close();
    }

    const pc = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });

    const dataChannel = pc.createDataChannel("input", { negotiated: true, id: 0, ordered: true });

    this.peers.set(viewerId, { pc, dc: dataChannel });

    pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.signaling.send({
          type: "ice-candidate",
          candidate: event.candidate.toJSON(),
          viewerId,
        });
      }
    };

    pc.onconnectionstatechange = () => {
      console.log(`[peer-manager] ${viewerId} state: ${pc.connectionState}`);
      if (pc.connectionState === "connected") {
        this.onViewerConnected?.(viewerId);
      } else if (
        pc.connectionState === "disconnected" ||
        pc.connectionState === "failed" ||
        pc.connectionState === "closed"
      ) {
        this.removeViewer(viewerId);
        this.onViewerDisconnected?.(viewerId);
      }
    };

    dataChannel.onopen = () => {
      // DataChannel이 열리면 현재 화면 소스 목록을 전송
      this.sendScreenSourcesToViewer(viewerId);
    };

    dataChannel.onmessage = (event: MessageEvent) => {
      try {
        const msg = JSON.parse(event.data as string) as DataChannelMessage;
        if (msg.type === "switch-source") {
          this.onSwitchSource?.(msg.sourceId);
        } else {
          window.hostAPI.injectInput(msg as InputMessage);
        }
      } catch (err) {
        console.error("[peer-manager] data channel parse error:", err);
      }
    };

    return pc;
  }

  private sendScreenSourcesToViewer(viewerId: string): void {
    // app.ts에서 등록한 콜백이 없을 경우를 대비해 직접 소스를 가져옴
    if (!window.hostAPI) return;
    window.hostAPI.getScreenSources().then((sources) => {
      this.sendToViewer(viewerId, {
        type: "screen-sources",
        sources: sources.map((s) => ({ id: s.id, name: s.name })),
      });
    }).catch((err) => {
      console.error("[peer-manager] getScreenSources error:", err);
    });
  }

  private addStreamToPeer(pc: RTCPeerConnection): void {
    if (!this.stream) return;
    const senders = pc.getSenders();
    this.stream.getTracks().forEach((track) => {
      const hasSender = senders.some((s) => s.track === track);
      if (!hasSender) {
        pc.addTrack(track, this.stream!);
      }
    });
  }

  async replaceVideoTrack(newTrack: MediaStreamTrack): Promise<void> {
    const replacePromises = Array.from(this.peers.entries()).map(([viewerId, { pc }]) => {
      const senders = pc.getSenders();
      console.log(`[peer-manager] replaceTrack for ${viewerId}: senders=`, senders.map(s => ({ kind: s.track?.kind, readyState: s.track?.readyState })));
      const sender = senders.find((s) => s.track?.kind === "video") ?? senders.find((s) => s.track === null);
      if (sender) {
        console.log(`[peer-manager] replacing track, sender found`);
        return sender.replaceTrack(newTrack);
      }
      console.warn(`[peer-manager] no video sender found for ${viewerId}`);
      return Promise.resolve();
    });
    await Promise.all(replacePromises);
  }

  handleSignalingMessage(msg: SignalingMessage): void {
    switch (msg.type) {
      case "offer":
        this.handleOffer(msg.viewerId, msg.sdp).catch((err) =>
          console.error("[peer-manager] handleOffer error:", err)
        );
        break;
      case "ice-candidate":
        this.handleIceCandidate(msg.viewerId, msg.candidate).catch((err) =>
          console.error("[peer-manager] handleIceCandidate error:", err)
        );
        break;
      case "viewer-left":
        this.removeViewer(msg.viewerId);
        this.onViewerDisconnected?.(msg.viewerId);
        break;
    }
  }
}
