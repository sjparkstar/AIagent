export type SignalingMessage =
  | { type: "register"; roomId?: string; passwordHash: string }
  | { type: "join"; roomId: string; password: string }
  | { type: "offer"; sdp: RTCSessionDescriptionInit; viewerId: string }
  | { type: "answer"; sdp: RTCSessionDescriptionInit; viewerId: string }
  | { type: "ice-candidate"; candidate: RTCIceCandidateInit; viewerId: string }
  | { type: "viewer-joined"; viewerId: string }
  | { type: "viewer-left"; viewerId: string }
  | { type: "host-ready"; roomId: string }
  | { type: "error"; code: string; message: string }
  | { type: "room-info"; roomId: string; viewerCount: number; viewerId: string }
  | { type: "approve-viewer"; viewerId: string; approved: boolean };

export type InputMessage =
  | { type: "mousemove"; x: number; y: number }
  | { type: "mousedown"; button: number }
  | { type: "mouseup"; button: number }
  | { type: "keydown"; key: string; code: string; modifiers: string[] }
  | { type: "keyup"; key: string; code: string }
  | { type: "scroll"; deltaX: number; deltaY: number }
  | { type: "text-input"; text: string }
  | { type: "clipboard-sync"; text: string };

export interface HostSystemInfo {
  os: string;
  version: string;
  cpuModel: string;
  cpuUsage: number;
  memTotal: number;
  memUsed: number;
  uptime: number;
}

export type ControlMessage =
  | { type: "screen-sources"; sources: { id: string; name: string }[]; activeSourceId?: string }
  | { type: "switch-source"; sourceId: string }
  | { type: "source-changed"; sourceId: string; name: string }
  | { type: "host-info"; info: HostSystemInfo };

export type DataChannelMessage = InputMessage | ControlMessage;

export type AnyMessage = SignalingMessage | InputMessage;

export function isSignalingMessage(msg: unknown): msg is SignalingMessage {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  const signalingTypes = new Set([
    "register",
    "join",
    "offer",
    "answer",
    "ice-candidate",
    "viewer-joined",
    "viewer-left",
    "host-ready",
    "error",
    "room-info",
    "approve-viewer",
  ]);
  return typeof m["type"] === "string" && signalingTypes.has(m["type"]);
}
