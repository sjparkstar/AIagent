import { ipcMain, BrowserWindow } from "electron";
import type { InputMessage, HostSystemInfo } from "@remote-desktop/shared";

// Node.js built-in을 require로 사용해 esbuild 번들 충돌 방지
const os = require("os") as typeof import("os");
const childProcess = require("child_process") as typeof import("child_process");
import { getScreenSources } from "./capture";
import { injectInput, setActiveBounds } from "./input";
import { collectDiagnostics } from "./system-diagnostics";

let prevCpuTimes: { idle: number; total: number } | null = null;

const MAX_COMMAND_LENGTH = 2000;
const DANGEROUS_COMMAND_PATTERNS: RegExp[] = [
  /\brm\s+-rf\b/i,
  /\bremove-item\b[\s\S]*-recurse/i,
  /\bdel\b[\s\S]*\/[pqsf]/i,
  /\berase\b/i,
  /\brd\b[\s\S]*\/s\b/i,
  /\brmdir\b[\s\S]*\/s\b/i,
  /\bformat\b/i,
  /\bdiskpart\b/i,
  /\bshutdown\b/i,
  /\brestart-computer\b/i,
  /\bstop-computer\b/i,
  /\breg\b[\s\S]*\bdelete\b/i,
  /\bsc\b[\s\S]*\bdelete\b/i,
  /\bvssadmin\b[\s\S]*\bdelete\b/i,
  /\bwbadmin\b[\s\S]*\bdelete\b/i,
  /\bcipher\b[\s\S]*\/w\b/i,
  /\bmkfs\b/i,
  /\bdd\b[\s\S]*if=/i,
];

function getCpuUsage(): number {
  const cpus = os.cpus();
  let idle = 0;
  let total = 0;
  for (const cpu of cpus) {
    idle += cpu.times.idle;
    total +=
      cpu.times.user +
      cpu.times.nice +
      cpu.times.sys +
      cpu.times.irq +
      cpu.times.idle;
  }
  if (!prevCpuTimes) {
    prevCpuTimes = { idle, total };
    return 0;
  }
  const idleDiff = idle - prevCpuTimes.idle;
  const totalDiff = total - prevCpuTimes.total;
  prevCpuTimes = { idle, total };
  return totalDiff > 0 ? Math.round((1 - idleDiff / totalDiff) * 100) : 0;
}

function validateCommand(command: string, commandType: string): string | null {
  const trimmed = command.trim();
  if (!trimmed) return "Command is empty";
  if (trimmed.length > MAX_COMMAND_LENGTH) {
    return `Command exceeds ${MAX_COMMAND_LENGTH} characters`;
  }
  if (!["cmd", "powershell", "shell"].includes(commandType)) {
    return `Unsupported commandType: ${commandType}`;
  }
  if (
    commandType === "shell" &&
    process.platform === "win32" &&
    /[;&><]/.test(trimmed)
  ) {
    return "Shell commands with chained operators are blocked on Windows";
  }
  for (const pattern of DANGEROUS_COMMAND_PATTERNS) {
    if (pattern.test(trimmed)) {
      return "Blocked potentially destructive command";
    }
  }
  return null;
}

export function registerIpcHandlers(): void {
  ipcMain.handle("get-screen-sources", async () => {
    return getScreenSources();
  });

  ipcMain.handle("get-system-info", (): HostSystemInfo => {
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    return {
      os: `${os.type()} ${os.arch()}`,
      version: os.release(),
      cpuModel: os.cpus()[0]?.model ?? "Unknown",
      cpuUsage: getCpuUsage(),
      memTotal: Math.round(totalMem / 1024 / 1024),
      memUsed: Math.round((totalMem - freeMem) / 1024 / 1024),
      uptime: Math.round(os.uptime()),
    };
  });

  ipcMain.handle("get-system-diagnostics", async () => {
    return collectDiagnostics();
  });

  ipcMain.on("inject-input", (_event, msg: InputMessage) => {
    injectInput(msg).catch((err) => {
      console.error("[ipc] inject-input error:", err);
    });
  });

  ipcMain.on(
    "set-active-bounds",
    (
      _event,
      data: {
        bounds: { x: number; y: number; width: number; height: number };
        scaleFactor: number;
      }
    ) => {
      setActiveBounds(data.bounds, data.scaleFactor);
    }
  );

  ipcMain.handle(
    "execute-command",
    async (
      _event,
      data: { command: string; commandType: string }
    ): Promise<{ success: boolean; output: string; error?: string }> => {
      const validationError = validateCommand(data.command, data.commandType);
      if (validationError) {
        return { success: false, output: "", error: validationError };
      }

      return new Promise((resolve) => {
        let shellCmd: string;
        if (data.commandType === "powershell") {
          const encoded = Buffer.from(data.command, "utf16le").toString(
            "base64"
          );
          shellCmd = `chcp 65001 >nul && powershell -NoProfile -EncodedCommand ${encoded}`;
        } else if (data.commandType === "shell") {
          shellCmd = data.command;
        } else {
          shellCmd = `chcp 65001 >nul && cmd /c ${data.command}`;
        }

        childProcess.exec(
          shellCmd,
          { timeout: 15000, windowsHide: true, encoding: "utf8" },
          (err, stdout, stderr) => {
            const output = (stdout ?? "").trim();
            if (err && !output) {
              resolve({
                success: false,
                output: "",
                error: (stderr ?? "").trim() || err.message,
              });
            } else {
              resolve({
                success: true,
                output,
                error: (stderr ?? "").trim() || undefined,
              });
            }
          }
        );
      });
    }
  );
}

export function notifyViewerJoined(win: BrowserWindow, viewerId: string): void {
  win.webContents.send("viewer-joined", { viewerId });
}

export function notifyViewerLeft(win: BrowserWindow, viewerId: string): void {
  win.webContents.send("viewer-left", { viewerId });
}
