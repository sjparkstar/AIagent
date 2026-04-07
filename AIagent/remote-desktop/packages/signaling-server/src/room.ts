import { v4 as uuidv4 } from "uuid";
import {
  ROOM_ID_LENGTH,
  ROOM_ID_CHARSET,
  ROOM_CLEANUP_INTERVAL_MS,
} from "@remote-desktop/shared";
import type { Room, HostClient, ViewerClient } from "./types.js";

const rooms = new Map<string, Room>();

function generateRoomId(): string {
  let id = "";
  for (let i = 0; i < ROOM_ID_LENGTH; i++) {
    id += ROOM_ID_CHARSET[Math.floor(Math.random() * ROOM_ID_CHARSET.length)];
  }
  return id;
}

function generateUniqueRoomId(): string {
  let id = generateRoomId();
  let attempts = 0;
  while (rooms.has(id) && attempts < 100) {
    id = generateRoomId();
    attempts++;
  }
  return id;
}

export function createRoom(
  host: HostClient,
  passwordHash: string,
  requestedRoomId?: string
): Room {
  const roomId = requestedRoomId ?? generateUniqueRoomId();

  const room: Room = {
    roomId,
    passwordHash,
    host,
    viewers: new Map(),
    createdAt: Date.now(),
  };

  host.roomId = roomId;
  rooms.set(roomId, room);
  return room;
}

export function getRoom(roomId: string): Room | undefined {
  return rooms.get(roomId);
}

export function addViewer(room: Room, viewerWs: ViewerClient["ws"]): ViewerClient {
  const viewerId = uuidv4();
  const viewer: ViewerClient = {
    ws: viewerWs,
    viewerId,
    roomId: room.roomId,
    connectedAt: Date.now(),
    approved: false,
  };
  room.viewers.set(viewerId, viewer);
  return viewer;
}

export function removeViewer(room: Room, viewerId: string): boolean {
  return room.viewers.delete(viewerId);
}

export function removeRoom(roomId: string): boolean {
  return rooms.delete(roomId);
}

export function getRoomByHost(ws: HostClient["ws"]): Room | undefined {
  for (const room of rooms.values()) {
    if (room.host.ws === ws) return room;
  }
  return undefined;
}

export function getViewerRoom(
  ws: ViewerClient["ws"]
): { room: Room; viewer: ViewerClient } | undefined {
  for (const room of rooms.values()) {
    for (const viewer of room.viewers.values()) {
      if (viewer.ws === ws) return { room, viewer };
    }
  }
  return undefined;
}

setInterval(() => {
  const now = Date.now();
  for (const [roomId, room] of rooms.entries()) {
    if (room.host.ws.readyState !== 1) {
      rooms.delete(roomId);
      continue;
    }
    for (const [viewerId, viewer] of room.viewers.entries()) {
      if (viewer.ws.readyState !== 1) {
        room.viewers.delete(viewerId);
      }
    }
    void now;
  }
}, ROOM_CLEANUP_INTERVAL_MS);
