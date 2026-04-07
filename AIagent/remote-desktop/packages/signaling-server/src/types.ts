import type { WebSocket } from "ws";

export interface HostClient {
  ws: WebSocket;
  roomId: string;
  connectedAt: number;
}

export interface ViewerClient {
  ws: WebSocket;
  viewerId: string;
  roomId: string;
  connectedAt: number;
  approved: boolean;
}

export interface Room {
  roomId: string;
  passwordHash: string;
  host: HostClient;
  viewers: Map<string, ViewerClient>;
  createdAt: number;
}

export interface AttemptRecord {
  count: number;
  blockedUntil: number | null;
}
