import type { InputMessage } from "@remote-desktop/shared";
import type { ScreenSource } from "./main/capture";

export type HostAPI = {
  getScreenSources: () => Promise<ScreenSource[]>;
  injectInput: (msg: InputMessage) => void;
  setActiveBounds: (bounds: { x: number; y: number; width: number; height: number }, scaleFactor: number) => void;
  onViewerJoined: (cb: (data: { viewerId: string }) => void) => () => void;
  onViewerLeft: (cb: (data: { viewerId: string }) => void) => () => void;
};
