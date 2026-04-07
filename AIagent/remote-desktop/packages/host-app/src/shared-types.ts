import type { InputMessage, HostSystemInfo } from "@remote-desktop/shared";
import type { ScreenSource } from "./main/capture";

export type HostAPI = {
  getScreenSources: () => Promise<ScreenSource[]>;
  getSystemInfo: () => Promise<HostSystemInfo>;
  injectInput: (msg: InputMessage) => void;
  setActiveBounds: (bounds: { x: number; y: number; width: number; height: number }, scaleFactor: number) => void;
  onViewerJoined: (cb: (data: { viewerId: string }) => void) => () => void;
  onViewerLeft: (cb: (data: { viewerId: string }) => void) => () => void;
};
