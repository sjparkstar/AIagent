import { ipcMain, BrowserWindow } from "electron";
import type { InputMessage } from "@remote-desktop/shared";
import { getScreenSources } from "./capture";
import { injectInput, setActiveBounds } from "./input";

export function registerIpcHandlers(): void {
  ipcMain.handle("get-screen-sources", async () => {
    return getScreenSources();
  });

  ipcMain.on("inject-input", (_event, msg: InputMessage) => {
    injectInput(msg).catch((err) => {
      console.error("[ipc] inject-input error:", err);
    });
  });

  ipcMain.on("set-active-bounds", (_event, data: { bounds: { x: number; y: number; width: number; height: number }; scaleFactor: number }) => {
    setActiveBounds(data.bounds, data.scaleFactor);
  });
}

export function notifyViewerJoined(win: BrowserWindow, viewerId: string): void {
  win.webContents.send("viewer-joined", { viewerId });
}

export function notifyViewerLeft(win: BrowserWindow, viewerId: string): void {
  win.webContents.send("viewer-left", { viewerId });
}
