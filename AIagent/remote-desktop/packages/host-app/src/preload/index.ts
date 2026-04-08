import { contextBridge, ipcRenderer } from "electron";
import type { InputMessage, HostSystemInfo, SystemDiagnostics } from "@remote-desktop/shared";
import type { ScreenSource } from "../main/capture";
import type { HostAPI } from "../shared-types";

contextBridge.exposeInMainWorld("hostAPI", {
  getScreenSources: (): Promise<ScreenSource[]> =>
    ipcRenderer.invoke("get-screen-sources"),

  getSystemInfo: (): Promise<HostSystemInfo> =>
    ipcRenderer.invoke("get-system-info"),

  getSystemDiagnostics: (): Promise<SystemDiagnostics> =>
    ipcRenderer.invoke("get-system-diagnostics"),

  injectInput: (msg: InputMessage): void =>
    ipcRenderer.send("inject-input", msg),

  setActiveBounds: (bounds: { x: number; y: number; width: number; height: number }, scaleFactor: number): void =>
    ipcRenderer.send("set-active-bounds", { bounds, scaleFactor }),

  onViewerJoined: (cb: (data: { viewerId: string }) => void): (() => void) => {
    const handler = (_: Electron.IpcRendererEvent, data: { viewerId: string }): void => cb(data);
    ipcRenderer.on("viewer-joined", handler);
    return () => ipcRenderer.removeListener("viewer-joined", handler);
  },

  onViewerLeft: (cb: (data: { viewerId: string }) => void): (() => void) => {
    const handler = (_: Electron.IpcRendererEvent, data: { viewerId: string }): void => cb(data);
    ipcRenderer.on("viewer-left", handler);
    return () => ipcRenderer.removeListener("viewer-left", handler);
  },

  executeCommand: (data: { command: string; commandType: string }): Promise<{ success: boolean; output: string; error?: string }> =>
    ipcRenderer.invoke("execute-command", data),
} satisfies HostAPI);
