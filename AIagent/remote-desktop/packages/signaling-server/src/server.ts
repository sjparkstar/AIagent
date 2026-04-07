import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "http";
import type { SignalingMessage } from "@remote-desktop/shared";
import { isSignalingMessage, ERROR_CODES } from "@remote-desktop/shared";
import { log } from "./logger.js";
import {
  checkRateLimit,
  recordFailedAttempt,
  clearAttempts,
  verifyPassword,
  hashPassword,
} from "./auth.js";
import {
  createRoom,
  getRoom,
  addViewer,
  removeViewer,
  removeRoom,
  getRoomByHost,
  getViewerRoom,
} from "./room.js";

function send(ws: WebSocket, msg: SignalingMessage): void {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendError(ws: WebSocket, code: string, message: string): void {
  send(ws, { type: "error", code, message });
}

function getClientIp(req: IncomingMessage): string {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string") return forwarded.split(",")[0]!.trim();
  return req.socket.remoteAddress ?? "unknown";
}

async function handleRegister(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "register" }>
): Promise<void> {
  if (msg.roomId && getRoom(msg.roomId)) {
    sendError(ws, ERROR_CODES.ROOM_ALREADY_EXISTS, "Room already exists");
    return;
  }

  const passwordHash = await hashPassword(msg.passwordHash);
  const host = { ws, roomId: "", connectedAt: Date.now() };
  const room = createRoom(host, passwordHash, msg.roomId);

  log(`Room created: ${room.roomId}`);
  send(ws, { type: "host-ready", roomId: room.roomId });
}

async function handleJoin(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "join" }>,
  ip: string
): Promise<void> {
  const { allowed, errorCode } = checkRateLimit(ip);
  if (!allowed) {
    sendError(
      ws,
      errorCode ?? ERROR_CODES.TOO_MANY_ATTEMPTS,
      "Too many failed attempts. Try again later."
    );
    return;
  }

  const room = getRoom(msg.roomId);
  if (!room) {
    sendError(ws, ERROR_CODES.ROOM_NOT_FOUND, "Room not found");
    return;
  }

  const valid = await verifyPassword(msg.password, room.passwordHash);
  if (!valid) {
    recordFailedAttempt(ip);
    sendError(ws, ERROR_CODES.INVALID_PASSWORD, "Invalid password");
    return;
  }

  clearAttempts(ip);
  const viewer = addViewer(room, ws);

  log(`Viewer ${viewer.viewerId} joined room ${room.roomId}`);

  send(room.host.ws, { type: "viewer-joined", viewerId: viewer.viewerId });
  send(ws, {
    type: "room-info",
    roomId: room.roomId,
    viewerCount: room.viewers.size,
    viewerId: viewer.viewerId,
  });
}

function handleOffer(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "offer" }>
): void {
  // offer는 뷰어(offerer)로부터 호스트(answerer)로 전달
  const result = getViewerRoom(ws);
  if (result) {
    send(result.room.host.ws, {
      type: "offer",
      sdp: msg.sdp,
      viewerId: result.viewer.viewerId,
    });
    return;
  }

  // fallback: 호스트에서 보낸 경우 (일반적이지 않음)
  const room = getRoomByHost(ws);
  if (!room) return;
  const viewer = room.viewers.get(msg.viewerId);
  if (!viewer) {
    sendError(ws, ERROR_CODES.VIEWER_NOT_FOUND, "Viewer not found");
    return;
  }
  send(viewer.ws, { type: "offer", sdp: msg.sdp, viewerId: msg.viewerId });
}

function handleAnswer(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "answer" }>
): void {
  // answer는 호스트(answerer)가 뷰어(offerer)에게 보내는 것
  const room = getRoomByHost(ws);
  if (room) {
    const viewer = room.viewers.get(msg.viewerId);
    if (viewer) {
      send(viewer.ws, { type: "answer", sdp: msg.sdp, viewerId: msg.viewerId });
    }
    return;
  }

  // fallback: 뷰어가 보낸 경우 (일반적이지 않음)
  const result = getViewerRoom(ws);
  if (result) {
    send(result.room.host.ws, {
      type: "answer",
      sdp: msg.sdp,
      viewerId: result.viewer.viewerId,
    });
  }
}

function handleIceCandidate(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "ice-candidate" }>
): void {
  const hostRoom = getRoomByHost(ws);
  if (hostRoom) {
    const viewer = hostRoom.viewers.get(msg.viewerId);
    if (viewer) {
      send(viewer.ws, {
        type: "ice-candidate",
        candidate: msg.candidate,
        viewerId: msg.viewerId,
      });
    }
    return;
  }

  const result = getViewerRoom(ws);
  if (result) {
    send(result.room.host.ws, {
      type: "ice-candidate",
      candidate: msg.candidate,
      viewerId: result.viewer.viewerId,
    });
  }
}

function handleApproveViewer(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "approve-viewer" }>
): void {
  const room = getRoomByHost(ws);
  if (!room) return;

  const viewer = room.viewers.get(msg.viewerId);
  if (!viewer) {
    sendError(ws, ERROR_CODES.VIEWER_NOT_FOUND, "Viewer not found");
    return;
  }

  viewer.approved = msg.approved;

  if (!msg.approved) {
    sendError(viewer.ws, ERROR_CODES.UNAUTHORIZED, "Connection not approved");
    viewer.ws.close();
    removeViewer(room, msg.viewerId);
  }
}

function handleDisconnect(ws: WebSocket): void {
  const hostRoom = getRoomByHost(ws);
  if (hostRoom) {
    log(`Host disconnected, closing room ${hostRoom.roomId}`);
    for (const viewer of hostRoom.viewers.values()) {
      sendError(viewer.ws, ERROR_CODES.HOST_NOT_CONNECTED, "Host disconnected");
      viewer.ws.close();
    }
    removeRoom(hostRoom.roomId);
    return;
  }

  const result = getViewerRoom(ws);
  if (result) {
    log(
      `Viewer ${result.viewer.viewerId} disconnected from room ${result.room.roomId}`
    );
    removeViewer(result.room, result.viewer.viewerId);
    send(result.room.host.ws, {
      type: "viewer-left",
      viewerId: result.viewer.viewerId,
    });
  }
}

export function attachWebSocketHandlers(wss: WebSocketServer): void {
  wss.on("connection", (ws: WebSocket, req: IncomingMessage) => {
    const ip = getClientIp(req);
    log(`Client connected: ${ip}`);

    ws.on("message", (data) => {
      let msg: unknown;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        sendError(ws, ERROR_CODES.INVALID_MESSAGE, "Invalid JSON");
        return;
      }

      if (!isSignalingMessage(msg)) {
        sendError(ws, ERROR_CODES.INVALID_MESSAGE, "Unknown message type");
        return;
      }

      switch (msg.type) {
        case "register":
          void handleRegister(ws, msg);
          break;
        case "join":
          void handleJoin(ws, msg, ip);
          break;
        case "offer":
          handleOffer(ws, msg);
          break;
        case "answer":
          handleAnswer(ws, msg);
          break;
        case "ice-candidate":
          handleIceCandidate(ws, msg);
          break;
        case "approve-viewer":
          handleApproveViewer(ws, msg);
          break;
        default:
          break;
      }
    });

    ws.on("close", () => {
      log(`Client disconnected: ${ip}`);
      handleDisconnect(ws);
    });

    ws.on("error", (err) => {
      log(`WebSocket error from ${ip}: ${err.message}`);
    });
  });
}
