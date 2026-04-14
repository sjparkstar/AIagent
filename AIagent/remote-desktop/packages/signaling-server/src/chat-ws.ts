// chat-ws.ts
// RemoteCall-mini 채팅 WebSocket 핸들러
// 기존 시그널링 WebSocket(호스트/뷰어) + 채팅 전용 WS를 모두 지원
// 채팅 전용 WS는 chat_room_id로 매핑하여 브로드캐스트
import { WebSocket } from "ws";
import type { ChatMessage } from "@remote-desktop/shared";
import { getRoomByHost, getViewerRoom } from "./room.js";
import { dbInsertChatMessage } from "./chat-api.js";
import { log } from "./logger.js";

// ─── 채팅 전용 WS room 레지스트리 ───────────────────────────────────────────
// chatRoomId → Set<WebSocket>
// chat-message를 처음 받는 순간 해당 WS를 자동으로 chatRoomId에 등록
const chatRoomSubscribers = new Map<string, Set<WebSocket>>();

function subscribeToChatRoom(chatRoomId: string, ws: WebSocket): void {
  let set = chatRoomSubscribers.get(chatRoomId);
  if (!set) {
    set = new Set();
    chatRoomSubscribers.set(chatRoomId, set);
  }
  if (!set.has(ws)) {
    set.add(ws);
    ws.on("close", () => {
      set!.delete(ws);
      if (set!.size === 0) chatRoomSubscribers.delete(chatRoomId);
    });
  }
}

// 채팅방 구독자에게 브로드캐스트 (발신자 제외 옵션)
function broadcastToChatRoom(
  chatRoomId: string,
  msg: unknown,
  excludeWs?: WebSocket,
): void {
  const subscribers = chatRoomSubscribers.get(chatRoomId);
  if (!subscribers) return;
  for (const ws of subscribers) {
    if (ws === excludeWs) continue;
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg));
    }
  }
}

// ─── 공통 전송 헬퍼 ──────────────────────────────────────────────────────────

// WebSocket이 열려있을 때만 전송 (기존 server.ts의 send 함수와 동일한 패턴)
function sendWs(ws: WebSocket, msg: unknown): void {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

// 같은 roomId에 속한 호스트 + 모든 뷰어에게 메시지 브로드캐스트 (시그널링 room 기반)
function broadcastToRoom(
  hostWs: WebSocket,
  viewerWsSet: WebSocket[],
  msg: unknown,
): void {
  sendWs(hostWs, msg);
  for (const viewerWs of viewerWsSet) {
    sendWs(viewerWs, msg);
  }
}

// ─── 채팅 메시지 처리 ─────────────────────────────────────────────────────────

// chat-message 처리: Supabase 저장 후 chatRoomId 기반 브로드캐스트
// 시그널링 room에 소속된 WS(호스트/뷰어) 또는 채팅 전용 WS 모두 지원
async function handleChatMessage(
  ws: WebSocket,
  msg: Extract<ChatMessage, { type: "chat-message" }>,
): Promise<void> {
  if (!msg.chatRoomId) {
    log(`[chat-ws] chat-message: chatRoomId 누락 (sender=${msg.senderId})`);
    return;
  }

  // 이 WS를 chatRoomId 구독자로 자동 등록 (채팅 전용 WS 지원)
  subscribeToChatRoom(msg.chatRoomId, ws);

  // Supabase에 메시지 영구 저장 (스레드 답글이면 parentMessageId 함께 저장)
  let savedMessage: Record<string, unknown>;
  try {
    savedMessage = await dbInsertChatMessage({
      chatRoomId: msg.chatRoomId,
      senderId: msg.senderId,
      senderType: msg.senderType,
      content: msg.content,
      messageType: msg.messageType ?? "text",
      parentMessageId: msg.parentMessageId ?? null,
    });
  } catch (err) {
    log(`[chat-ws] 메시지 저장 실패: ${String(err)}`);
    savedMessage = {
      id: `temp-${Date.now()}`,
      chat_room_id: msg.chatRoomId,
      sender_id: msg.senderId,
      sender_type: msg.senderType,
      content: msg.content,
      message_type: msg.messageType ?? "text",
      created_at: new Date().toISOString(),
      parent_message_id: msg.parentMessageId ?? null,
      reply_count: 0,
    };
  }

  const broadcast = {
    type: "chat-message-broadcast",
    chatRoomId: msg.chatRoomId,
    messageId: String(savedMessage.id ?? ""),
    senderId: msg.senderId,
    senderType: msg.senderType,
    content: msg.content,
    messageType: msg.messageType ?? "text",
    createdAt: String(savedMessage.created_at ?? new Date().toISOString()),
    // 스레드 정보: 답글이면 부모 ID, 아니면 null
    parentMessageId: (savedMessage.parent_message_id as string | null) ?? null,
    // 답글 본인은 항상 0, 트리거가 부모의 reply_count를 증가시켰지만
    // broadcast로는 본인 row의 reply_count 그대로 전달 (답글이면 0)
    replyCount: (savedMessage.reply_count as number | undefined) ?? 0,
  };

  // 두 경로(chatRoomId 구독자 + 시그널링 room 참여자)의 수신자를 합친다.
  // 같은 WS가 양쪽에 모두 등록되어 있으면 같은 메시지가 2번 가는 문제가 있어
  // Set으로 중복 제거 후 한 번만 전송한다.
  const recipients = new Set<WebSocket>();

  // 1. chatRoomId 구독자 (채팅 전용 WS 경로)
  const subscribers = chatRoomSubscribers.get(msg.chatRoomId);
  if (subscribers) {
    for (const sub of subscribers) recipients.add(sub);
  }

  // 2. 시그널링 room의 참여자 (호스트/뷰어 WS 경로 — 과도기적 호환성)
  const hostRoom = getRoomByHost(ws);
  const viewerResult = hostRoom ? undefined : getViewerRoom(ws);
  const room = hostRoom ?? viewerResult?.room;
  if (room) {
    recipients.add(room.host.ws);
    for (const viewer of room.viewers.values()) recipients.add(viewer.ws);
  }

  // 중복 없는 수신자 집합에 한 번씩만 전송
  for (const target of recipients) sendWs(target, broadcast);

  log(`[chat-ws] 브로드캐스트 완료: chatRoom=${msg.chatRoomId} sender=${msg.senderId} recipients=${recipients.size}`);
}

// chat-read 처리: chatRoomId 기반 브로드캐스트 (채팅 전용 WS 지원)
function handleChatRead(
  ws: WebSocket,
  msg: Extract<ChatMessage, { type: "chat-read" }>,
): void {
  if (!msg.chatRoomId) return;
  subscribeToChatRoom(msg.chatRoomId, ws);

  const broadcast = {
    type: "chat-read-broadcast",
    chatRoomId: msg.chatRoomId,
    userId: msg.userId,
    lastReadAt: new Date().toISOString(),
  };

  // 두 경로 수신자 합집합 (중복 제거)
  const recipients = new Set<WebSocket>();
  const subscribers = chatRoomSubscribers.get(msg.chatRoomId);
  if (subscribers) for (const sub of subscribers) recipients.add(sub);
  const hostRoom = getRoomByHost(ws);
  const viewerResult = hostRoom ? undefined : getViewerRoom(ws);
  const room = hostRoom ?? viewerResult?.room;
  if (room) {
    recipients.add(room.host.ws);
    for (const viewer of room.viewers.values()) recipients.add(viewer.ws);
  }
  for (const target of recipients) sendWs(target, broadcast);
}

// chat-typing 처리: DB 저장 없이 즉시 브로드캐스트 (타이핑 인디케이터, 발신자 제외)
function handleChatTyping(
  ws: WebSocket,
  msg: Extract<ChatMessage, { type: "chat-typing" }>,
): void {
  if (!msg.chatRoomId) return;
  subscribeToChatRoom(msg.chatRoomId, ws);

  const broadcast = {
    type: "chat-typing-broadcast",
    chatRoomId: msg.chatRoomId,
    userId: msg.userId,
  };

  // 두 경로 수신자 합집합 (발신자 ws 제외 후 중복 제거)
  const recipients = new Set<WebSocket>();
  const subscribers = chatRoomSubscribers.get(msg.chatRoomId);
  if (subscribers) for (const sub of subscribers) recipients.add(sub);
  const hostRoom = getRoomByHost(ws);
  const viewerResult = hostRoom ? undefined : getViewerRoom(ws);
  const room = hostRoom ?? viewerResult?.room;
  if (room) {
    recipients.add(room.host.ws);
    for (const viewer of room.viewers.values()) recipients.add(viewer.ws);
  }
  recipients.delete(ws); // 발신자 제외
  for (const target of recipients) sendWs(target, broadcast);
}

// ─── 메인 진입점 ─────────────────────────────────────────────────────────────
// server.ts의 ws.on('message') 핸들러에서 호출
// 반환값: true = 채팅 메시지로 처리됨, false = 채팅 메시지 아님

export function handleChatWebSocket(ws: WebSocket, msg: unknown): boolean {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  const type = m["type"];

  switch (type) {
    case "chat-message":
      void handleChatMessage(ws, msg as Extract<ChatMessage, { type: "chat-message" }>);
      return true;

    case "chat-read":
      handleChatRead(ws, msg as Extract<ChatMessage, { type: "chat-read" }>);
      return true;

    case "chat-typing":
      handleChatTyping(ws, msg as Extract<ChatMessage, { type: "chat-typing" }>);
      return true;

    default:
      return false;
  }
}
