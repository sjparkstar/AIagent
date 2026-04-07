import { contextBridge, ipcRenderer } from "electron";
import type { InputMessage, HostSystemInfo } from "@remote-desktop/shared";
import type { ScreenSource } from "../main/capture";
import type { HostAPI } from "../shared-types";

contextBridge.exposeInMainWorld("hostAPI", {
  getScreenSources: (): Promise<ScreenSource[]> =>
    ipcRenderer.invoke("get-screen-sources"),

  getSystemInfo: (): Promise<HostSystemInfo> =>
    ipcRenderer.invoke("get-system-info"),

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
} satisfies HostAPI);
