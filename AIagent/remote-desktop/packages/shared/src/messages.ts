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

export interface SystemDiagnostics {
  system: {
    os: string;
    version: string;
    build: string;
    pcName: string;
    userName: string;
    bootTime: string;
    uptime: number;
    cpuModel: string;
    cpuUsage: number;
    cpuCores: number;
    memTotal: number;
    memUsed: number;
    memUsage: number;
    disks: { drive: string; total: number; used: number; usage: number }[];
    battery: { hasBattery: boolean; percent: number; charging: boolean } | null;
    isAdmin: boolean;
  };
  processes: {
    topCpu: { name: string; pid: number; cpu: number; mem: number }[];
    services: { name: string; displayName: string; status: string; startType: string }[];
  };
  network: {
    interfaces: { name: string; ip: string; mac: string; type: string }[];
    gateway: string;
    dns: string[];
    internetConnected: boolean;
    wifi: { ssid: string; signal: number } | null;
    vpnConnected: boolean;
  };
  security: {
    firewallEnabled: boolean;
    defenderEnabled: boolean;
    uacEnabled: boolean;
    antivirusProducts: string[];
  };
  userEnv: {
    monitors: { width: number; height: number; scaleFactor: number }[];
    defaultBrowser: string;
    printers: string[];
  };
  recentEvents: { time: string; source: string; message: string; level: string }[];
}

export type ControlMessage =
  | { type: "screen-sources"; sources: { id: string; name: string }[]; activeSourceId?: string }
  | { type: "switch-source"; sourceId: string }
  | { type: "source-changed"; sourceId: string; name: string }
  | { type: "host-info"; info: HostSystemInfo }
  | { type: "host-diagnostics"; diagnostics: SystemDiagnostics }
  | { type: "execute-macro"; macroId: string; command: string; commandType: string }
  | { type: "macro-result"; macroId: string; success: boolean; output: string; error?: string };

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
