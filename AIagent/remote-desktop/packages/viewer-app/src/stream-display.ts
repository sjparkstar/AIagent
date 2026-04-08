import type { PeerConnection } from "./peer.js";

const STATS_INTERVAL_MS = 2000;

export class StreamDisplay {
  private statsTimer: ReturnType<typeof setInterval> | null = null;
  private onStatsUpdate: ((text: string) => void) | null = null;

  constructor(private readonly videoEl: HTMLVideoElement) {}

  attachStream(stream: MediaStream): void {
    this.videoEl.srcObject = stream;
    this.videoEl.play().catch(() => {});
  }

  startStats(peer: PeerConnection, onUpdate: (text: string) => void): void {
    this.onStatsUpdate = onUpdate;
    this.statsTimer = setInterval(async () => {
      const stats = await peer.getStats();
      this.processStats(stats);
    }, STATS_INTERVAL_MS);
  }

  private processStats(stats: RTCStatsReport): void {
    let fps = 0;
    let rttMs = 0;

    stats.forEach((report) => {
      if (report.type === "inbound-rtp" && (report as RTCInboundRtpStreamStats).kind === "video") {
        const r = report as RTCInboundRtpStreamStats & { framesPerSecond?: number };
        if (r.framesPerSecond != null) fps = Math.round(r.framesPerSecond);
      }
      if (report.type === "candidate-pair") {
        const r = report as RTCIceCandidatePairStats & { currentRoundTripTime?: number };
        if (r.currentRoundTripTime != null) {
          rttMs = Math.round(r.currentRoundTripTime * 1000);
        }
      }
    });

    const parts: string[] = [];
    if (fps > 0) parts.push(`${fps} fps`);
    if (rttMs > 0) parts.push(`${rttMs} ms`);
    this.onStatsUpdate?.(parts.join("  |  "));
  }

  toggleFullscreen(): void {
    const container = this.videoEl.closest(".video-container") as HTMLElement | null;
    const target = container ?? this.videoEl;

    if (!document.fullscreenElement) {
      target.requestFullscreen().catch(() => {});
    } else {
      document.exitFullscreen().catch(() => {});
    }
  }

  stopStats(): void {
    if (this.statsTimer !== null) {
      clearInterval(this.statsTimer);
      this.statsTimer = null;
    }
  }

  detach(): void {
    this.stopStats();
    this.videoEl.srcObject = null;
  }
}
