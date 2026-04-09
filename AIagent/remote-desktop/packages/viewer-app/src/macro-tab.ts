import { fetchMacros, renderMacroList } from "./macro-manager.js";
import type { Macro } from "./macro-manager.js";
import { fetchPlaybooks } from "./playbook-manager.js";
import type { Playbook, PlaybookStep } from "./playbook-manager.js";
import type { PeerConnection } from "./peer.js";
import { logAssistantMessage } from "./session-logger.js";
import type { UI } from "./ui.js";

// PlaybookStep, Playbook 타입은 playbook-manager.ts에서 import

// macro-result 콜백 맵: macroId → resolve/reject
const pendingMacros = new Map<string, (result: { success: boolean; output: string; error?: string }) => void>();

export function resolveMacroResult(macroId: string, result: { success: boolean; output: string; error?: string }): void {
  const cb = pendingMacros.get(macroId);
  if (cb) {
    pendingMacros.delete(macroId);
    cb(result);
  }
}

export function sendMacroCommand(
  getPeer: () => PeerConnection | null,
  macroId: string,
  command: string,
  commandType: string
): Promise<{ success: boolean; output: string; error?: string }> {
  return new Promise((resolve, reject) => {
    const p = getPeer();
    if (!p) {
      reject(new Error("peer not connected"));
      return;
    }
    pendingMacros.set(macroId, resolve);
    p.sendMessage({ type: "execute-macro", macroId, command, commandType });

    // 30초 타임아웃
    setTimeout(() => {
      if (pendingMacros.has(macroId)) {
        pendingMacros.delete(macroId);
        reject(new Error("macro execution timeout"));
      }
    }, 30000);
  });
}

export async function executePlaybook(
  playbook: Playbook,
  sendCommand: (command: string, commandType: string) => Promise<{ success: boolean; output: string }>,
  onProgress: (stepName: string, status: "running" | "success" | "failed" | "skipped", output?: string) => void
): Promise<void> {
  const results = new Map<string, string>();

  for (const step of playbook.steps) {
    onProgress(step.name, "running");

    const result = await sendCommand(step.command, step.commandType);
    results.set(step.name, result.output);

    if (!result.success) {
      onProgress(step.name, "failed", result.output);
      return;
    }

    if (step.validateContains && !result.output.includes(step.validateContains)) {
      onProgress(step.name, "failed", `검증 실패: ${result.output.slice(0, 100)}`);
      return;
    }

    onProgress(step.name, "success", result.output.slice(0, 100));
  }
}

let switchToAiTab: (() => void) | null = null;

export function setTabSwitcher(fn: () => void): void {
  switchToAiTab = fn;
}

export function initMacroTab(
  container: HTMLElement,
  ui: UI,
  getPeer: () => PeerConnection | null
): void {
  container.innerHTML = `
    <div class="macro-tab-inner">
      <div class="macro-tab-section">
        <div class="macro-section-header">매크로 목록</div>
        <div id="macro-tab-list" class="macro-tab-list"></div>
      </div>
      <div class="macro-tab-section">
        <div class="macro-section-header">플레이북</div>
        <div id="macro-tab-playbooks" class="macro-tab-playbooks"></div>
      </div>
    </div>`;

  const listEl = container.querySelector<HTMLElement>("#macro-tab-list")!;
  const playbooksEl = container.querySelector<HTMLElement>("#macro-tab-playbooks")!;

  fetchMacros().then((macros) => {
    if (macros.length === 0) {
      listEl.innerHTML = `<p class="session-empty">등록된 매크로가 없습니다.</p>`;
    } else {
      renderMacroList(
        listEl,
        macros,
        () => {},
        () => {},
        (m) => runMacro(m, getPeer, ui),
        "run-only"
      );
    }
  }).catch(() => {
    listEl.innerHTML = `<p class="session-empty">매크로를 불러올 수 없습니다.</p>`;
  });

  renderPlaybooks(playbooksEl, getPeer, ui);
}

function runMacro(m: Macro, getPeer: () => PeerConnection | null, ui: UI): void {
  if (!getPeer()) {
    ui.addAssistantMessage("system", "원격 세션 연결 후 매크로를 실행할 수 있습니다.");
    return;
  }

  const warningPrefix = m.is_dangerous ? "[위험] " : "";
  const msg = `${warningPrefix}"${m.name}" 매크로를 실행하시겠습니까?\n\n명령어: ${m.command}`;
  if (!confirm(msg)) return;

  switchToAiTab?.();
  const macroId = `${m.id}-${Date.now()}`;

  const statusMsg = m.is_dangerous ? `⚠️ 위험 매크로 실행 중: ${m.name}` : `매크로 실행 중: ${m.name}`;
  ui.addAssistantMessage("system", statusMsg);
  logAssistantMessage("system", statusMsg).catch(() => {});

  sendMacroCommand(getPeer, macroId, m.command, m.command_type)
    .then((result) => {
      if (result.success) {
        const msg = `✅ ${m.name} 완료\n\n${result.output.slice(0, 500)}`;
        ui.addAssistantMessage("assistant", msg);
        logAssistantMessage("assistant", msg).catch(() => {});
      } else {
        const msg = `❌ ${m.name} 실패\n\n${result.error ?? result.output}`;
        ui.addAssistantMessage("system", msg);
        logAssistantMessage("system", msg).catch(() => {});
      }
    })
    .catch((err: unknown) => {
      const msg = `매크로 실행 오류: ${err instanceof Error ? err.message : String(err)}`;
      ui.addAssistantMessage("system", msg);
      logAssistantMessage("system", msg).catch(() => {});
    });
}

async function renderPlaybooks(
  container: HTMLElement,
  getPeer: () => PeerConnection | null,
  ui: UI
): Promise<void> {
  let playbooks: Playbook[] = [];
  try {
    playbooks = await fetchPlaybooks();
  } catch {}

  if (playbooks.length === 0) {
    container.innerHTML = `<p class="session-empty">등록된 플레이북이 없습니다.</p>`;
    return;
  }

  container.innerHTML = playbooks.map((pb) => `
    <div class="playbook-item" data-id="${pb.id}">
      <div class="playbook-info">
        <span class="playbook-name">${pb.name}</span>
        <span class="playbook-desc">${pb.description ?? ""} (${pb.steps.length}단계)</span>
      </div>
      <button class="btn macro-btn playbook-run-btn" data-id="${pb.id}">▶ 실행</button>
    </div>`).join("");

  container.querySelectorAll<HTMLButtonElement>(".playbook-run-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const pb = playbooks.find((p) => p.id === btn.dataset["id"]);
      if (!pb) return;
      runPlaybook(pb, getPeer, ui, btn);
    });
  });
}

function runPlaybook(
  playbook: Playbook,
  getPeer: () => PeerConnection | null,
  ui: UI,
  triggerBtn: HTMLButtonElement
): void {
  if (!getPeer()) {
    ui.addAssistantMessage("system", "원격 세션 연결 후 플레이북을 실행할 수 있습니다.");
    return;
  }
  if (!confirm(`"${playbook.name}" 플레이북을 실행하시겠습니까?\n\n${playbook.description}`)) return;

  switchToAiTab?.();
  triggerBtn.disabled = true;
  const startMsg = `▶ 플레이북 시작: ${playbook.name}`;
  ui.addAssistantMessage("system", startMsg);
  logAssistantMessage("system", startMsg).catch(() => {});

  const sendCommand = (command: string, commandType: string) => {
    const macroId = `pb-${playbook.id}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return sendMacroCommand(getPeer, macroId, command, commandType);
  };

  executePlaybook(
    playbook,
    sendCommand,
    (stepName, status, output) => {
      const statusLabel: Record<string, string> = {
        running: "⏳",
        success: "✅",
        failed: "❌",
        skipped: "⏭️",
      };
      const label = statusLabel[status] ?? "";
      const detail = output ? `\n${output}` : "";
      const stepMsg = `${label} ${stepName}${detail}`;
      ui.addAssistantMessage(status === "failed" ? "system" : "assistant", stepMsg);
      logAssistantMessage(status === "failed" ? "system" : "assistant", stepMsg).catch(() => {});
    }
  ).then(() => {
    const doneMsg = `플레이북 완료: ${playbook.name}`;
    ui.addAssistantMessage("assistant", doneMsg);
    logAssistantMessage("assistant", doneMsg).catch(() => {});
  }).catch((err: unknown) => {
    const errMsg = `플레이북 오류: ${err instanceof Error ? err.message : String(err)}`;
    ui.addAssistantMessage("system", errMsg);
    logAssistantMessage("system", errMsg).catch(() => {});
  }).finally(() => {
    triggerBtn.disabled = false;
  });
}
