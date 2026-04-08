import type { InputMessage, HostSystemInfo, SystemDiagnostics } from "@remote-desktop/shared";
import type { ScreenSource } from "./main/capture";

export type HostAPI = {
  getScreenSources: () => Promise<ScreenSource[]>;
  getSystemInfo: () => Promise<HostSystemInfo>;
  getSystemDiagnostics: () => Promise<SystemDiagnostics>;
  injectInput: (msg: InputMessage) => void;
  setActiveBounds: (bounds: { x: number; y: number; width: number; height: number }, scaleFactor: number) => void;
  executeCommand: (data: { command: string; commandType: string }) => Promise<{ success: boolean; output: string; error?: string }>;
  onViewerJoined: (cb: (data: { viewerId: string }) => void) => () => void;
  onViewerLeft: (cb: (data: { viewerId: string }) => void) => () => void;
};
