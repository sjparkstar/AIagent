// AI 어시스턴트 패널을 별도 팝업 창으로 분리하거나 복귀시키는 로직
import { searchDocuments, askAssistant } from "./assistant-search.js";

let widgetWindow: Window | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
let onReturnCallback: (() => void) | null = null;

// 위젯 내부 DOM 참조 (팝업이 열린 동안 유지)
let wMessages: HTMLDivElement | null = null;
let wInput: HTMLInputElement | null = null;
let wHostInput: HTMLInputElement | null = null;

/** CSS 변수 + 어시스턴트 관련 스타일을 문자열로 생성 */
function buildWidgetCSS(): string {
  return `
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg-primary: #0f1117; --bg-secondary: #1a1d27; --bg-card: #1e2130;
      --border-color: #2e3347; --text-primary: #e8eaf0; --text-secondary: #8b90a4;
      --accent: #4f8ef7; --accent-hover: #6ba3ff; --danger: #e05252;
      --radius: 8px; --transition: 150ms ease;
    }
    html, body {
      height: 100%; margin: 0; background: var(--bg-secondary);
      color: var(--text-primary);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      font-size: 14px; line-height: 1.5;
    }
    .widget-root {
      display: flex; flex-direction: column; height: 100vh; overflow: hidden;
    }
    .btn { cursor: pointer; border: none; border-radius: var(--radius); font-size: 14px; font-weight: 500; transition: background var(--transition), opacity var(--transition); }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-primary { background: var(--accent); color: #fff; padding: 11px 20px; }
    .btn-primary:hover:not(:disabled) { background: var(--accent-hover); }
    .btn-icon { background: transparent; color: var(--text-secondary); padding: 6px 10px; font-size: 18px; line-height: 1; }
    .btn-icon:hover { color: var(--text-primary); }
    .assistant-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 0 12px; height: 44px; background: var(--bg-card);
      border-bottom: 1px solid var(--border-color); flex-shrink: 0;
    }
    .assistant-header-title { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; color: var(--text-primary); }
    .assistant-icon { color: var(--accent); font-size: 15px; }
    .assistant-action-btn { font-size: 16px; padding: 4px 8px; color: var(--text-secondary); transition: color var(--transition), background var(--transition); border-radius: 4px; cursor: pointer; background: transparent; border: none; }
    .assistant-action-btn:hover { color: var(--text-primary); background: var(--border-color); }
    .host-command-bar {
      padding: 10px 12px; border-bottom: 1px solid var(--border-color);
      background: var(--bg-card); display: flex; flex-direction: column; gap: 8px; flex-shrink: 0;
    }
    .host-command-input-row { display: flex; gap: 6px; align-items: center; }
    .assistant-text-input {
      flex: 1; background: var(--bg-secondary); border: 1px solid var(--border-color);
      border-radius: var(--radius); color: var(--text-primary); font-size: 12px;
      padding: 7px 10px; outline: none; transition: border-color var(--transition); min-width: 0;
    }
    .assistant-text-input:focus { border-color: var(--accent); }
    .assistant-text-input::placeholder { color: var(--text-secondary); opacity: 0.7; }
    .btn-send { padding: 7px 12px; font-size: 11px; white-space: nowrap; border-radius: var(--radius); flex-shrink: 0; }
    .quick-command-buttons { display: flex; gap: 4px; flex-wrap: wrap; }
    .quick-cmd-btn {
      background: var(--bg-secondary); border: 1px solid var(--border-color); border-radius: 4px;
      color: var(--text-secondary); font-size: 10px; padding: 3px 8px; cursor: pointer;
      transition: background var(--transition), color var(--transition), border-color var(--transition); white-space: nowrap;
    }
    .quick-cmd-btn:hover { background: var(--border-color); color: var(--text-primary); border-color: var(--text-secondary); }
    .assistant-messages {
      flex: 1; overflow-y: auto; padding: 12px; display: flex;
      flex-direction: column; gap: 10px; min-height: 0;
    }
    .assistant-messages::-webkit-scrollbar { width: 4px; }
    .assistant-messages::-webkit-scrollbar-track { background: transparent; }
    .assistant-messages::-webkit-scrollbar-thumb { background: var(--border-color); border-radius: 2px; }
    .message-row { display: flex; flex-direction: column; gap: 4px; max-width: 100%; }
    .message-row.assistant { align-items: flex-start; }
    .message-row.user { align-items: flex-end; }
    .message-row.system { align-items: center; }
    .message-sender { display: flex; align-items: center; gap: 5px; font-size: 10px; font-weight: 600; color: var(--text-secondary); padding: 0 2px; }
    .message-sender .sender-icon { color: var(--accent); font-size: 11px; }
    .message-bubble { padding: 8px 12px; border-radius: 10px; font-size: 12px; line-height: 1.55; word-break: break-word; white-space: pre-wrap; max-width: 92%; }
    .message-row.assistant .message-bubble { background: var(--bg-card); border: 1px solid var(--border-color); color: var(--text-primary); border-radius: 2px 10px 10px 10px; }
    .message-row.user .message-bubble { background: var(--accent); color: #fff; border-radius: 10px 2px 10px 10px; }
    .message-row.system .message-bubble { background: transparent; color: var(--text-secondary); font-size: 11px; font-style: italic; border: none; padding: 2px 8px; }
    .message-loading { display: flex; align-items: center; gap: 4px; padding: 8px 12px; background: var(--bg-card); border: 1px solid var(--border-color); border-radius: 2px 10px 10px 10px; }
    .loading-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text-secondary); animation: dotBounce 1.2s ease-in-out infinite; }
    .loading-dot:nth-child(2) { animation-delay: 0.2s; }
    .loading-dot:nth-child(3) { animation-delay: 0.4s; }
    @keyframes dotBounce { 0%, 80%, 100% { transform: translateY(0); opacity: 0.4; } 40% { transform: translateY(-5px); opacity: 1; } }
    .assistant-input-bar {
      display: flex; align-items: center; gap: 4px; padding: 10px 10px;
      border-top: 1px solid var(--border-color); background: var(--bg-card); flex-shrink: 0;
    }
    .assistant-input-icons { display: flex; align-items: center; gap: 0; }
    .assistant-icon-btn { font-size: 14px; padding: 4px 5px; opacity: 0.6; transition: opacity var(--transition); cursor: pointer; background: transparent; border: none; color: var(--text-secondary); }
    .assistant-icon-btn:hover { opacity: 1; }
    .assistant-send-btn { font-size: 18px; padding: 4px 10px; color: var(--accent); transition: color var(--transition), transform var(--transition); flex-shrink: 0; }
    .assistant-send-btn:hover { color: var(--accent-hover); transform: translateX(2px); }
  `;
}

/** 위젯 HTML 구조 생성 */
function buildWidgetHTML(): string {
  return `
    <div class="widget-root">
      <div class="assistant-header">
        <div class="assistant-header-title">
          <span class="assistant-icon">✦</span>
          <span>AI Assistant</span>
        </div>
        <button id="w-dock-btn" class="assistant-action-btn" title="사이드 패널로 복귀">⧉</button>
      </div>

      <div class="host-command-bar">
        <div class="host-command-input-row">
          <input type="text" id="w-host-command-input" class="assistant-text-input" placeholder="호스트에게 명령 입력..." />
          <button id="w-host-command-send-btn" class="btn btn-primary btn-send">Send to Host</button>
        </div>
        <div class="quick-command-buttons">
          <button class="btn quick-cmd-btn" data-cmd="report">Generate System Report</button>
          <button class="btn quick-cmd-btn" data-cmd="cache">Clear Cache</button>
          <button class="btn quick-cmd-btn" data-cmd="reboot">Reboot Instance</button>
        </div>
      </div>

      <div id="w-messages" class="assistant-messages"></div>

      <div class="assistant-input-bar">
        <div class="assistant-input-icons">
          <button class="btn btn-icon assistant-icon-btn" data-action="file" title="파일 첨부">📎</button>
          <button class="btn btn-icon assistant-icon-btn" data-action="image" title="이미지">🖼</button>
          <button class="btn btn-icon assistant-icon-btn" data-action="mic" title="마이크">🎤</button>
        </div>
        <input type="text" id="w-input" class="assistant-text-input" placeholder="검색어를 입력하세요..." />
        <button id="w-send-btn" class="btn btn-icon assistant-send-btn" title="전송">→</button>
      </div>
    </div>
  `;
}

/** 위젯 메시지 영역에 메시지 추가 */
function addWidgetMessage(type: "assistant" | "user" | "system", text: string): HTMLDivElement | null {
  if (!wMessages) return null;
  const row = wMessages.ownerDocument.createElement("div");
  row.className = `message-row ${type}`;

  if (type === "assistant") {
    const sender = wMessages.ownerDocument.createElement("div");
    sender.className = "message-sender";
    sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
    row.appendChild(sender);
  }

  const bubble = wMessages.ownerDocument.createElement("div");
  bubble.className = "message-bubble";
  bubble.textContent = text;
  row.appendChild(bubble);

  wMessages.appendChild(row);
  wMessages.scrollTop = wMessages.scrollHeight;
  return row;
}

/** 위젯에 로딩 메시지 추가 */
function addWidgetLoadingMessage(): HTMLDivElement | null {
  if (!wMessages) return null;
  const doc = wMessages.ownerDocument;
  const row = doc.createElement("div");
  row.className = "message-row assistant";

  const sender = doc.createElement("div");
  sender.className = "message-sender";
  sender.innerHTML = `<span class="sender-icon">✦</span><span>AI Assistant</span>`;
  row.appendChild(sender);

  const loading = doc.createElement("div");
  loading.className = "message-loading";
  loading.innerHTML = `<span class="loading-dot"></span><span class="loading-dot"></span><span class="loading-dot"></span>`;
  row.appendChild(loading);

  wMessages.appendChild(row);
  wMessages.scrollTop = wMessages.scrollHeight;
  return row;
}

/** 위젯 검색 처리: Supabase 검색 → Claude API로 답변 생성 */
async function handleWidgetSearch(query: string): Promise<void> {
  const trimmed = query.trim();
  if (!trimmed) return;

  addWidgetMessage("user", trimmed);
  if (wInput) wInput.value = "";

  const loadingRow = addWidgetLoadingMessage();

  let context: string | undefined;
  try {
    const results = await searchDocuments(trimmed);
    if (results.length > 0) {
      context = results.map((r, i) => `[${i + 1}] ${r.title}\n${r.content}`).join("\n\n---\n\n");
    }
  } catch (err) {
    console.error("[widget] Supabase search failed:", err);
  }

  if (!context) {
    addWidgetMessage("system", "내부 문서에서 결과를 찾지 못해 AI에게 질문합니다...");
  }

  try {
    const response = await askAssistant(trimmed, context);
    loadingRow?.remove();

    const sourceLabel = response.source === "supabase" ? "📄 내부 문서 기반" : "🤖 AI 답변";
    addWidgetMessage("assistant", `${sourceLabel}\n\n${response.answer}`);
  } catch (err) {
    loadingRow?.remove();
    console.error("[widget] Claude API call failed:", err);
    addWidgetMessage("system", "AI 응답을 가져오는 중 오류가 발생했습니다. 시그널링 서버 연결을 확인해주세요.");
  }
}

/** 메인 패널의 메시지를 위젯으로 복사 */
function copyMessagesToWidget(panelMessages: HTMLDivElement): void {
  if (!wMessages || !widgetWindow) return;
  const doc = widgetWindow.document;
  Array.from(panelMessages.children).forEach((child) => {
    const clone = doc.importNode(child, true);
    wMessages!.appendChild(clone);
  });
  wMessages.scrollTop = wMessages.scrollHeight;
}

/** 위젯의 메시지를 메인 패널로 동기화 */
function syncMessagesToPanel(panelMessages: HTMLDivElement): void {
  if (!wMessages) return;
  panelMessages.innerHTML = "";
  Array.from(wMessages.children).forEach((child) => {
    const clone = document.importNode(child, true);
    panelMessages.appendChild(clone);
  });
  panelMessages.scrollTop = panelMessages.scrollHeight;
}

/**
 * 사이드 패널 내용을 별도 팝업 창으로 분리한다.
 * 팝업에 사이드패널과 동일한 UI와 기능을 구현한다.
 */
export function openAsWidget(
  panel: HTMLDivElement,
  onReturn: () => void
): void {
  if (widgetWindow && !widgetWindow.closed) {
    widgetWindow.focus();
    return;
  }

  onReturnCallback = onReturn;

  const left = Math.round(screen.width / 2 - 200);
  const top = Math.round(screen.height / 2 - 350);
  widgetWindow = window.open(
    "",
    "ai-assistant-widget",
    `width=400,height=700,left=${left},top=${top},resizable=yes,scrollbars=no`
  );

  if (!widgetWindow) {
    alert("팝업이 차단되었습니다. 브라우저 설정에서 팝업을 허용해주세요.");
    return;
  }

  // 팝업에 CSS와 HTML 구성
  const doc = widgetWindow.document;
  doc.open();
  doc.write(`<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><title>AI Assistant</title><style>${buildWidgetCSS()}</style></head><body>${buildWidgetHTML()}</body></html>`);
  doc.close();

  // DOM 참조 획득
  wMessages = doc.getElementById("w-messages") as HTMLDivElement;
  wInput = doc.getElementById("w-input") as HTMLInputElement;
  wHostInput = doc.getElementById("w-host-command-input") as HTMLInputElement;

  const wSendBtn = doc.getElementById("w-send-btn") as HTMLButtonElement;
  const wHostSendBtn = doc.getElementById("w-host-command-send-btn") as HTMLButtonElement;
  const wDockBtn = doc.getElementById("w-dock-btn") as HTMLButtonElement;

  // 메인 패널의 메시지를 위젯으로 복사
  const panelMessages = panel.querySelector("#assistant-messages") as HTMLDivElement;
  if (panelMessages) copyMessagesToWidget(panelMessages);

  // 검색 입력: Enter
  wInput.addEventListener("keydown", (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleWidgetSearch(wInput!.value).catch(() => {});
    }
  });

  // 검색 전송 버튼
  wSendBtn.addEventListener("click", () => {
    handleWidgetSearch(wInput!.value).catch(() => {});
  });

  // 호스트 명령 (추후 구현 예정)
  const handleHostCmd = (source: string) => {
    addWidgetMessage("system", `[${source}] 호스트 명령 기능은 추후 구현 예정입니다.`);
  };

  wHostSendBtn.addEventListener("click", () => {
    const cmd = wHostInput!.value.trim();
    handleHostCmd(cmd || "Send to Host");
    wHostInput!.value = "";
  });

  wHostInput.addEventListener("keydown", (e: KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault();
      const cmd = wHostInput!.value.trim();
      handleHostCmd(cmd || "Send to Host");
      wHostInput!.value = "";
    }
  });

  // 빠른 명령 버튼
  doc.querySelectorAll<HTMLButtonElement>(".quick-cmd-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      handleHostCmd(btn.textContent ?? "명령");
    });
  });

  // 아이콘 버튼 (파일/이미지/마이크)
  doc.querySelectorAll<HTMLButtonElement>(".assistant-icon-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const action = btn.dataset["action"] ?? "기능";
      addWidgetMessage("system", `[${action}] 기능은 추후 구현 예정입니다.`);
    });
  });

  // 사이드패널 복귀 버튼
  wDockBtn.addEventListener("click", () => {
    widgetWindow?.close();
  });

  // 패널을 완전히 숨겨 비디오가 전체 너비를 차지하도록
  panel.classList.add("collapsed");

  // 팝업 닫힘 감지
  pollTimer = setInterval(() => {
    if (widgetWindow?.closed) {
      stopPoll();
      // 위젯 메시지를 패널로 동기화
      if (panelMessages) syncMessagesToPanel(panelMessages);
      returnToPanel(panel);
    }
  }, 500);
}

function returnToPanel(panel: HTMLDivElement): void {
  wMessages = null;
  wInput = null;
  wHostInput = null;
  widgetWindow = null;
  panel.classList.remove("collapsed");
  onReturnCallback?.();
  onReturnCallback = null;
}

function stopPoll(): void {
  if (pollTimer !== null) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}


export function isWidgetOpen(): boolean {
  return !!(widgetWindow && !widgetWindow.closed);
}
