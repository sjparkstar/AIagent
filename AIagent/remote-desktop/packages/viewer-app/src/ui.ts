type ConnectionState = "connecting" | "connected" | "disconnected";

export class UI {
  readonly createScreen = document.getElementById("create-screen") as HTMLDivElement;
  readonly waitingScreen = document.getElementById("waiting-screen") as HTMLDivElement;
  readonly streamScreen = document.getElementById("stream-screen") as HTMLDivElement;

  readonly createBtn = document.getElementById("create-btn") as HTMLButtonElement;
  readonly createError = document.getElementById("create-error") as HTMLDivElement;

  readonly roomIdDisplay = document.getElementById("room-id-display") as HTMLSpanElement;
  readonly waitingStatus = document.getElementById("waiting-status") as HTMLSpanElement;
  readonly cancelBtn = document.getElementById("cancel-btn") as HTMLButtonElement;

  readonly remoteVideo = document.getElementById("remote-video") as HTMLVideoElement;
  readonly connectionBadge = document.getElementById("connection-badge") as HTMLSpanElement;
  readonly roomIdLabel = document.getElementById("room-id-label") as HTMLSpanElement;
  readonly statsDisplay = document.getElementById("stats-display") as HTMLSpanElement;
  readonly fullscreenBtn = document.getElementById("fullscreen-btn") as HTMLButtonElement;
  readonly disconnectBtn = document.getElementById("disconnect-btn") as HTMLButtonElement;
  readonly monitorButtons = document.getElementById("monitor-buttons") as HTMLDivElement;
  readonly reconnectOverlay = document.getElementById("reconnect-overlay") as HTMLDivElement;
  readonly reconnectText = document.getElementById("reconnect-text") as HTMLSpanElement;

  private onMonitorClick: ((sourceId: string) => void) | null = null;

  showCreateScreen(): void {
    this.waitingScreen.classList.add("hidden");
    this.streamScreen.classList.add("hidden");
    this.createScreen.classList.remove("hidden");
    this.clearError();
    this.setCreateLoading(false);
    this.clearMonitorButtons();
  }

  showWaitingScreen(roomId: string): void {
    this.createScreen.classList.add("hidden");
    this.streamScreen.classList.add("hidden");
    this.waitingScreen.classList.remove("hidden");
    this.roomIdDisplay.textContent = roomId;
    this.waitingStatus.textContent = "호스트 대기 중...";
  }

  showStreamScreen(roomId: string): void {
    this.createScreen.classList.add("hidden");
    this.waitingScreen.classList.add("hidden");
    this.streamScreen.classList.remove("hidden");
    this.roomIdLabel.textContent = `접속번호: ${roomId}`;
    this.setConnectionState("connecting");
    this.remoteVideo.focus();
  }

  setConnectionState(state: ConnectionState): void {
    const badge = this.connectionBadge;
    badge.className = "badge";

    const labels: Record<ConnectionState, [string, string]> = {
      connecting: ["badge-connecting", "연결 중"],
      connected: ["badge-connected", "연결됨"],
      disconnected: ["badge-disconnected", "끊김"],
    };

    const [cls, text] = labels[state];
    badge.classList.add(cls);
    badge.textContent = text;
  }

  showError(message: string): void {
    this.createError.textContent = message;
  }

  clearError(): void {
    this.createError.textContent = "";
  }

  setCreateLoading(loading: boolean): void {
    this.createBtn.disabled = loading;
    this.createBtn.textContent = loading ? "생성 중..." : "대기실 생성";
  }

  updateStats(text: string): void {
    this.statsDisplay.textContent = text;
  }

  setOnMonitorClick(cb: (sourceId: string) => void): void {
    this.onMonitorClick = cb;
  }

  updateScreenSources(sources: { id: string; name: string }[], activeId?: string): void {
    this.monitorButtons.innerHTML = "";

    sources.forEach((source, index) => {
      const btn = document.createElement("button");
      btn.className = "monitor-btn" + (source.id === activeId ? " active" : "");
      btn.textContent = `모니터 ${index + 1}`;
      btn.title = source.name;
      btn.dataset["sourceId"] = source.id;
      btn.addEventListener("click", () => {
        this.onMonitorClick?.(source.id);
      });
      this.monitorButtons.appendChild(btn);
    });
  }

  setActiveMonitor(sourceId: string): void {
    this.monitorButtons.querySelectorAll<HTMLButtonElement>(".monitor-btn").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset["sourceId"] === sourceId);
    });
  }

  showReconnectOverlay(text: string): void {
    this.reconnectText.textContent = text;
    this.reconnectOverlay.classList.remove("hidden");
  }

  hideReconnectOverlay(): void {
    this.reconnectOverlay.classList.add("hidden");
  }

  private clearMonitorButtons(): void {
    this.monitorButtons.innerHTML = "";
  }
}
