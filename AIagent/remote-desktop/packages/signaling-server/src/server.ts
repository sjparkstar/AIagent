import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "http";
import type { SignalingMessage } from "@remote-desktop/shared";
import { isSignalingMessage, isChatMessage, isDiagnosisMessage, ERROR_CODES } from "@remote-desktop/shared";
import { handleChatWebSocket } from "./chat-ws.js";
import { handleDiagnosisWebSocket } from "./diagnosis-ws.js";
import { log } from "./logger.js";
import {
  // rate limit은 미승인 접속 시도 카운트에 재활용
  checkRateLimit,
  recordFailedAttempt,
  clearAttempts,
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

// register한 쪽 = 원격지원을 받는 뷰어 앱 (방을 생성하고 접속번호를 발급받는다)
function handleRegister(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "register" }>
): void {
  if (msg.roomId && getRoom(msg.roomId)) {
    sendError(ws, ERROR_CODES.ROOM_ALREADY_EXISTS, "Room already exists");
    return;
  }

  // 비밀번호 방식 폐지 — passwordHash 자리는 빈 문자열로 유지 (스키마 최소 변경)
  const host = { ws, roomId: "", connectedAt: Date.now() };
  const room = createRoom(host, "", msg.roomId);

  log(`Room created: ${room.roomId}`);
  send(ws, { type: "host-ready", roomId: room.roomId });
}

// join한 쪽 = 원격지원을 제공하는 호스트 앱 (접속번호를 입력해서 방에 참가한다)
// 새 흐름: 즉시 입장이 아니라 pending 상태로 등록 후 뷰어 앱의 승인을 기다린다
function handleJoin(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "join" }>,
  ip: string
): void {
  // 과거에는 비밀번호 실패 횟수를 rate limit에 썼다.
  // 지금은 미승인 접속 시도 횟수 제한으로 용도를 바꿔서 그대로 유지한다.
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
    recordFailedAttempt(ip); // 없는 방 접속 시도도 카운트
    sendError(ws, ERROR_CODES.ROOM_NOT_FOUND, "Room not found");
    return;
  }

  // pending 상태로 viewer 등록 (approved=false 기본값)
  const viewer = addViewer(room, ws);
  log(`Host app joined room ${room.roomId} as viewer ${viewer.viewerId} — awaiting approval`);

  // 뷰어 앱(= register한 쪽 = room.host.ws)에게 승인 요청 알림 발송
  send(room.host.ws, { type: "host-join-request", viewerId: viewer.viewerId });
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

// approve-host: 뷰어 앱이 호스트의 접속 요청을 승인/거부한다
// ws = 뷰어 앱의 WebSocket (register한 쪽 = room.host)
function handleApproveHost(
  ws: WebSocket,
  msg: Extract<SignalingMessage, { type: "approve-host" }>
): void {
  // 뷰어 앱은 서버 내부에서 room.host로 관리된다
  const room = getRoomByHost(ws);
  if (!room) return;

  const viewer = room.viewers.get(msg.viewerId);
  if (!viewer) {
    sendError(ws, ERROR_CODES.VIEWER_NOT_FOUND, "Viewer not found");
    return;
  }

  if (!msg.approved) {
    // 거부: 호스트 앱에 에러 전송 후 연결 제거
    recordFailedAttempt(viewer.ws.url ?? "unknown"); // rate limit 카운트
    sendError(viewer.ws, ERROR_CODES.UNAUTHORIZED, "접속이 거부되었습니다");
    viewer.ws.close();
    removeViewer(room, msg.viewerId);
    log(`Host app ${msg.viewerId} rejected by viewer in room ${room.roomId}`);
    return;
  }

  // 승인: 이제 정식 입장 처리
  viewer.approved = true;
  clearAttempts(viewer.ws.url ?? "unknown");
  log(`Host app ${msg.viewerId} approved in room ${room.roomId}`);

  // 호스트 앱(join한 쪽)에게 room-info 전송 — 연결 성공 신호
  send(viewer.ws, {
    type: "room-info",
    roomId: room.roomId,
    viewerCount: room.viewers.size,
    viewerId: msg.viewerId,
  });

  // 뷰어 앱(register한 쪽)에게 viewer-joined 전송 — WebRTC 시작 신호
  send(room.host.ws, { type: "viewer-joined", viewerId: msg.viewerId });
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
  // 15초마다 모든 클라이언트에 ping 전송 — 연결 유지 및 죽은 연결 감지
  const PING_INTERVAL_MS = 15_000;
  const aliveMap = new WeakMap<WebSocket, boolean>();

  const pingTimer = setInterval(() => {
    for (const ws of wss.clients) {
      if (aliveMap.get(ws) === false) {
        // 이전 ping에 pong 응답이 없으면 연결 종료
        ws.terminate();
        continue;
      }
      aliveMap.set(ws, false);
      ws.ping();
    }
  }, PING_INTERVAL_MS);

  wss.on("close", () => clearInterval(pingTimer));

  wss.on("connection", (ws: WebSocket, req: IncomingMessage) => {
    const ip = getClientIp(req);
    log(`Client connected: ${ip}`);

    aliveMap.set(ws, true);
    ws.on("pong", () => aliveMap.set(ws, true));

    ws.on("message", (data) => {
      // 수신된 메시지도 살아있음의 증거
      aliveMap.set(ws, true);

      let msg: unknown;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        sendError(ws, ERROR_CODES.INVALID_MESSAGE, "Invalid JSON");
        return;
      }

      // 채팅 메시지 먼저 확인 — 시그널링과 별도 처리
      if (isChatMessage(msg)) {
        handleChatWebSocket(ws, msg);
        return;
      }

      // 자동진단/복구 메시지 처리
      if (isDiagnosisMessage(msg)) {
        void handleDiagnosisWebSocket(ws, msg);
        return;
      }

      if (!isSignalingMessage(msg)) {
        // "ping" 타입 메시지는 응용 레벨 하트비트로 허용 (무시)
        const rawType = (msg as Record<string, unknown>)?.type;
        if (rawType === "ping") return;
        sendError(ws, ERROR_CODES.INVALID_MESSAGE, "Unknown message type");
        return;
      }

      switch (msg.type) {
        case "register":
          // register = 뷰어 앱이 방을 만들 때 보내는 메시지
          handleRegister(ws, msg);
          break;
        case "join":
          // join = 호스트 앱이 접속번호를 입력해 방에 참가할 때
          handleJoin(ws, msg, ip);
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
        case "approve-host":
          // approve-host = 뷰어 앱이 호스트의 접속 요청을 승인/거부
          handleApproveHost(ws, msg);
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
