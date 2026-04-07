type ConnectionState = "connecting" | "connected" | "disconnected";

// 메시지 타입: assistant(AI 봇), user(사용자), system(시스템 알림)
export type MessageType = "assistant" | "user" | "system";

export class UI {
  readonly createScreen = document.getElementById("create-screen") as HTMLDivElement;
  readonly waitingScreen = document.getElementById("waiting-screen") as HTMLDivElement;
  readonly streamScreen = document.getElementById("stream-screen") as HTMLDivElement;
  readonly endScreen = document.getElementById("end-screen") as HTMLDivElement;

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

  // AI 어시스턴트 패널 관련 DOM 참조
  readonly assistantPanel = document.getElementById("assistant-panel") as HTMLDivElement;
  readonly assistantMessages = document.getElementById("assistant-messages") as HTMLDivElement;
  readonly assistantInput = document.getElementById("assistant-input") as HTMLInputElement;
  readonly assistantSendBtn = document.getElementById("assistant-send-btn") as HTMLButtonElement;
  readonly assistantCollapseBtn = document.getElementById("assistant-collapse-btn") as HTMLButtonElement;
  readonly assistantWidgetBtn = document.getElementById("assistant-widget-btn") as HTMLButtonElement;
  readonly assistantOpenBtn = document.getElementById("assistant-open-btn") as HTMLButtonElement;
  private onMonitorClick: ((sourceId: string) => void) | null = null;
  // 패널 접힘 상태 추적
  private _isPanelCollapsed = false;

  showCreateScreen(): void {
    this.waitingScreen.classList.add("hidden");
    this.streamScreen.classList.add("hidden");
    this.endScreen.classList.add("hidden");
    this.createScreen.classList.remove("hidden");
    this.clearError();
    this.setCreateLoading(false);
    this.clearMonitorButtons();
  }

  showEndScreen(): void {
    this.createScreen.classList.add("hidden");
    this.waitingScreen.classList.add("hidden");
    this.streamScreen.classList.add("hidden");
    this.endScreen.classList.remove("hidden");
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
    this.createBtn.textContent = loading ? "연결 중..." : "상담 연결";
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

  // ── AI 어시스턴트 패널 메서드 ──────────────────────────

  /**
   * 메시지 영역에 새 메시지를 추가한다.
   * @param type - "assistant" | "user" | "system"
   * @param text - 표시할 텍스트
   * @returns 생성된 메시지 행 요소 (로딩 제거 등에 활용)
   */
  addAssistantMessage(type: MessageType, text: string): HTMLDivElement {
    const row = document.createElement("div");
    row.className = `message-row ${type}`;

    if (type === "assistant") {
      // AI 봇 발신자 표시
      const sender = document.createElement("div");
      sender.className = "message-sender";
      sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
      row.appendChild(sender);
    }

    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    bubble.textContent = text;
    row.appendChild(bubble);

    this.assistantMessages.appendChild(row);
    // 새 메시지가 추가될 때 자동 스크롤
    this.assistantMessages.scrollTop = this.assistantMessages.scrollHeight;
    return row;
  }

  /**
   * 로딩 중 점(...)을 메시지 영역에 표시한다.
   * @returns 생성된 로딩 행 요소 (검색 완료 후 제거할 때 사용)
   */
  addLoadingMessage(): HTMLDivElement {
    const row = document.createElement("div");
    row.className = "message-row assistant";

    const sender = document.createElement("div");
    sender.className = "message-sender";
    sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
    row.appendChild(sender);

    const loading = document.createElement("div");
    loading.className = "message-loading";
    loading.innerHTML = `
      <span class="loading-dot"></span>
      <span class="loading-dot"></span>
      <span class="loading-dot"></span>
    `;
    row.appendChild(loading);

    this.assistantMessages.appendChild(row);
    this.assistantMessages.scrollTop = this.assistantMessages.scrollHeight;
    return row;
  }

  /**
   * 패널 접기/펼치기 토글.
   * 접히면 비디오 영역이 전체 너비를 차지하고, status-bar에 열기 버튼이 나타난다.
   */
  toggleAssistantPanel(): void {
    this._isPanelCollapsed = !this._isPanelCollapsed;
    this.setAssistantPanelVisible(!this._isPanelCollapsed);
  }

  /**
   * 패널 표시/숨김을 직접 설정한다.
   * @param visible - true면 패널 표시, false면 패널 숨김
   */
  setAssistantPanelVisible(visible: boolean): void {
    this._isPanelCollapsed = !visible;
    if (visible) {
      this.assistantPanel.classList.remove("collapsed");
      // 패널 열기 버튼 숨김
      this.assistantOpenBtn.classList.add("hidden");
      // 접기 버튼 아이콘 방향 복원
      this.assistantCollapseBtn.title = "패널 접기";
      this.assistantCollapseBtn.textContent = "›";
    } else {
      this.assistantPanel.classList.add("collapsed");
      // status-bar에 패널 열기 버튼 표시
      this.assistantOpenBtn.classList.remove("hidden");
    }
  }
}
