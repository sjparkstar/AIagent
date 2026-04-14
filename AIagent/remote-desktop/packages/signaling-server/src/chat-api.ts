// chat-api.ts
// RemoteCall-mini 채팅 REST API
// 기존 패턴(CORS_HEADERS, readBody, sendJson, Supabase REST 직접 호출) 그대로 따름
import type { IncomingMessage, ServerResponse } from "http";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "@remote-desktop/shared";
import { log } from "./logger.js";

// ─── CORS 헤더 (다른 API 파일과 동일한 패턴) ─────────────────────────────────
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

// ─── 공통 유틸 ────────────────────────────────────────────────────────────────

// JSON 응답 전송
function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { ...CORS_HEADERS, "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

// 요청 바디 읽기
function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

// Supabase REST 공통 헤더
const SUPABASE_HEADERS = {
  "apikey": SUPABASE_ANON_KEY,
  "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
  "Content-Type": "application/json",
};

// ─── Supabase 헬퍼 ────────────────────────────────────────────────────────────

// 채팅방 생성
async function dbCreateChatRoom(
  sessionId: string | undefined,
  roomType: string,
  name: string | undefined,
): Promise<Record<string, unknown>> {
  const body: Record<string, unknown> = { room_type: roomType };
  if (sessionId) body.session_id = sessionId;
  if (name) body.name = name;

  const res = await fetch(`${SUPABASE_URL}/rest/v1/chat_rooms`, {
    method: "POST",
    headers: { ...SUPABASE_HEADERS, "Prefer": "return=representation" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase chat_rooms insert 실패: ${res.status} ${text}`);
  }
  const rows = await res.json() as Record<string, unknown>[];
  return rows[0];
}

// 채팅방 참여자 추가 (배치 upsert)
async function dbAddParticipants(
  chatRoomId: string,
  participantIds: string[],
): Promise<void> {
  const rows = participantIds.map((userId) => ({
    chat_room_id: chatRoomId,
    user_id: userId,
    user_type: userId === "host" ? "host" : "viewer",
  }));

  const res = await fetch(`${SUPABASE_URL}/rest/v1/chat_participants`, {
    method: "POST",
    headers: { ...SUPABASE_HEADERS, "Prefer": "resolution=ignore-duplicates" },
    body: JSON.stringify(rows),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase chat_participants insert 실패: ${res.status} ${text}`);
  }
}

// 사용자가 참여 중인 채팅방 목록 + 마지막 메시지 + 안읽은 수
async function dbGetRoomsForUser(userId: string): Promise<unknown[]> {
  // 참여 중인 채팅방 ID 조회
  const participantRes = await fetch(
    `${SUPABASE_URL}/rest/v1/chat_participants?user_id=eq.${encodeURIComponent(userId)}&select=chat_room_id,last_read_at`,
    { headers: SUPABASE_HEADERS },
  );
  if (!participantRes.ok) return [];
  const participants = await participantRes.json() as { chat_room_id: string; last_read_at: string | null }[];
  if (!participants.length) return [];

  // 참여 중인 채팅방 상세 조회
  const roomIds = participants.map((p) => p.chat_room_id).join(",");
  const roomsRes = await fetch(
    `${SUPABASE_URL}/rest/v1/chat_rooms?id=in.(${roomIds})&select=*`,
    { headers: SUPABASE_HEADERS },
  );
  if (!roomsRes.ok) return [];
  const rooms = await roomsRes.json() as Record<string, unknown>[];

  // 각 채팅방에 마지막 메시지 + 안읽은 수 첨부
  const result = await Promise.all(
    rooms.map(async (room) => {
      const chatRoomId = room.id as string;
      const participant = participants.find((p) => p.chat_room_id === chatRoomId);
      const lastReadAt = participant?.last_read_at ?? null;

      // 마지막 메시지 조회
      const lastMsgRes = await fetch(
        `${SUPABASE_URL}/rest/v1/chat_messages?chat_room_id=eq.${chatRoomId}&order=created_at.desc&limit=1&select=content,created_at,sender_id`,
        { headers: SUPABASE_HEADERS },
      );
      const lastMsgs = lastMsgRes.ok ? await lastMsgRes.json() as unknown[] : [];
      const lastMessage = lastMsgs[0] ?? null;

      // 안읽은 수 조회 (내가 보낸 메시지 제외, last_read_at 이후)
      const afterTs = lastReadAt ?? "1970-01-01T00:00:00Z";
      const unreadRes = await fetch(
        `${SUPABASE_URL}/rest/v1/chat_messages?chat_room_id=eq.${chatRoomId}&created_at=gt.${afterTs}&sender_id=neq.${encodeURIComponent(userId)}&select=id`,
        { headers: { ...SUPABASE_HEADERS, "Prefer": "count=exact" } },
      );
      // Content-Range 헤더에서 count 추출 (Supabase 패턴)
      const contentRange = unreadRes.headers.get("content-range") ?? "0-0/0";
      const totalMatch = /\/(\d+)$/.exec(contentRange);
      const unreadCount = totalMatch ? parseInt(totalMatch[1], 10) : 0;

      return { ...room, lastMessage, unreadCount };
    }),
  );

  return result;
}

// 메시지 목록 조회 (커서 페이징 — before 타임스탬프 기준)
// 메인 채팅에는 스레드 루트(parent_message_id IS NULL)만 표시한다.
// 답글은 별도 엔드포인트 /messages/:id/replies 로 조회.
async function dbGetMessages(
  chatRoomId: string,
  before: string | undefined,
  limit: number,
): Promise<unknown[]> {
  let url = `${SUPABASE_URL}/rest/v1/chat_messages?chat_room_id=eq.${chatRoomId}&parent_message_id=is.null&order=created_at.desc&limit=${limit}&select=*`;
  if (before) {
    url += `&created_at=lt.${encodeURIComponent(before)}`;
  }

  const res = await fetch(url, { headers: SUPABASE_HEADERS });
  if (!res.ok) return [];
  const rows = await res.json() as unknown[];
  // 오래된 순으로 반환 (화면 위에서 아래로 시간순)
  return (rows as unknown[]).reverse();
}

// 특정 메시지의 답글 목록 조회 (스레드 패널용)
async function dbGetReplies(parentMessageId: string): Promise<unknown[]> {
  const url = `${SUPABASE_URL}/rest/v1/chat_messages?parent_message_id=eq.${parentMessageId}&order=created_at.asc&select=*`;
  const res = await fetch(url, { headers: SUPABASE_HEADERS });
  if (!res.ok) return [];
  return await res.json() as unknown[];
}

// 메시지 저장 후 저장된 row 반환
export async function dbInsertChatMessage(data: {
  chatRoomId: string;
  senderId: string;
  senderType: string;
  content: string;
  messageType?: string;
  metadata?: Record<string, unknown>;
  // 스레드 답글: 부모 메시지 ID (null/undefined면 일반 메시지)
  parentMessageId?: string | null;
}): Promise<Record<string, unknown>> {
  const body: Record<string, unknown> = {
    chat_room_id: data.chatRoomId,
    sender_id: data.senderId,
    sender_type: data.senderType,
    content: data.content,
    message_type: data.messageType ?? "text",
  };
  if (data.metadata) body.metadata = data.metadata;
  if (data.parentMessageId) body.parent_message_id = data.parentMessageId;

  const res = await fetch(`${SUPABASE_URL}/rest/v1/chat_messages`, {
    method: "POST",
    headers: { ...SUPABASE_HEADERS, "Prefer": "return=representation" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase chat_messages insert 실패: ${res.status} ${text}`);
  }
  const rows = await res.json() as Record<string, unknown>[];
  return rows[0];
}

// 읽음 처리 — last_read_at을 현재 시각으로 갱신
async function dbMarkAsRead(chatRoomId: string, userId: string): Promise<string> {
  const now = new Date().toISOString();

  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/chat_participants?chat_room_id=eq.${chatRoomId}&user_id=eq.${encodeURIComponent(userId)}`,
    {
      method: "PATCH",
      headers: { ...SUPABASE_HEADERS, "Prefer": "return=minimal" },
      body: JSON.stringify({ last_read_at: now }),
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase chat_participants update 실패: ${res.status} ${text}`);
  }
  return now;
}

// ─── 라우트 핸들러 ─────────────────────────────────────────────────────────────

// POST /api/chat/rooms — 채팅방 생성
async function handleCreateRoom(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    sessionId?: string;
    roomType?: string;
    name?: string;
    participantIds?: string[];
  };

  const { sessionId, roomType = "direct", name, participantIds = [] } = body;

  if (!participantIds.length) {
    sendJson(res, 400, { error: "participantIds가 필요합니다" });
    return;
  }

  const room = await dbCreateChatRoom(sessionId, roomType, name);
  const chatRoomId = room.id as string;

  // 참여자 등록
  await dbAddParticipants(chatRoomId, participantIds);

  log(`[chat-api] 채팅방 생성: ${chatRoomId} (type=${roomType}, participants=${participantIds.join(",")})`);
  sendJson(res, 201, room);
}

// GET /api/chat/rooms?userId=xxx — 채팅방 목록
async function handleGetRooms(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "", `http://localhost`);
  const userId = url.searchParams.get("userId");

  if (!userId) {
    sendJson(res, 400, { error: "userId 파라미터가 필요합니다" });
    return;
  }

  const rooms = await dbGetRoomsForUser(userId);
  sendJson(res, 200, rooms);
}

// GET /api/chat/rooms/:roomId/messages — 메시지 목록
async function handleGetMessages(req: IncomingMessage, res: ServerResponse, chatRoomId: string): Promise<void> {
  const url = new URL(req.url ?? "", `http://localhost`);
  const before = url.searchParams.get("before") ?? undefined;
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "30", 10), 100);

  const messages = await dbGetMessages(chatRoomId, before, limit);
  sendJson(res, 200, messages);
}

// POST /api/chat/rooms/:roomId/messages — 메시지 전송 (REST 경로)
async function handleSendMessage(req: IncomingMessage, res: ServerResponse, chatRoomId: string): Promise<void> {
  const body = JSON.parse(await readBody(req)) as {
    senderId?: string;
    senderType?: string;
    content?: string;
    messageType?: string;
    metadata?: Record<string, unknown>;
  };

  const { senderId, senderType = "viewer", content, messageType, metadata } = body;

  if (!senderId || !content) {
    sendJson(res, 400, { error: "senderId와 content가 필요합니다" });
    return;
  }

  const saved = await dbInsertChatMessage({
    chatRoomId,
    senderId,
    senderType,
    content,
    messageType,
    metadata,
  });

  log(`[chat-api] 메시지 저장: room=${chatRoomId} sender=${senderId}`);
  sendJson(res, 201, saved);
}

// GET /api/chat/messages/:messageId/replies — 특정 메시지의 답글 목록
async function handleGetReplies(req: IncomingMessage, res: ServerResponse, parentMessageId: string): Promise<void> {
  const replies = await dbGetReplies(parentMessageId);
  sendJson(res, 200, replies);
}

// PUT /api/chat/rooms/:roomId/read — 읽음 처리
async function handleMarkRead(req: IncomingMessage, res: ServerResponse, chatRoomId: string): Promise<void> {
  const body = JSON.parse(await readBody(req)) as { userId?: string };
  const { userId } = body;

  if (!userId) {
    sendJson(res, 400, { error: "userId가 필요합니다" });
    return;
  }

  const lastReadAt = await dbMarkAsRead(chatRoomId, userId);
  log(`[chat-api] 읽음 처리: room=${chatRoomId} user=${userId} at=${lastReadAt}`);
  sendJson(res, 200, { lastReadAt });
}

// ─── 메인 라우터 ──────────────────────────────────────────────────────────────
// index.ts에서 호출: if (handleChatRoutes(req, res)) return;

export function handleChatRoutes(req: IncomingMessage, res: ServerResponse): boolean {
  const url = req.url ?? "";
  const method = req.method ?? "GET";

  // OPTIONS preflight 처리 (채팅 경로 전체 — /api/chat/rooms 및 /api/chat/messages 포함)
  if (method === "OPTIONS" && url.startsWith("/api/chat/")) {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return true;
  }

  // POST /api/chat/rooms
  if (method === "POST" && url === "/api/chat/rooms") {
    handleCreateRoom(req, res).catch((err) => {
      log(`[chat-api] createRoom 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // GET /api/chat/rooms (쿼리스트링 포함)
  if (method === "GET" && (url === "/api/chat/rooms" || url.startsWith("/api/chat/rooms?"))) {
    handleGetRooms(req, res).catch((err) => {
      log(`[chat-api] getRooms 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // /api/chat/rooms/:roomId/... 패턴 추출
  const roomMsgMatch = /^\/api\/chat\/rooms\/([^/]+)\/messages(\?.*)?$/.exec(url);
  const roomReadMatch = /^\/api\/chat\/rooms\/([^/]+)\/read$/.exec(url);
  // 스레드 답글 조회
  const repliesMatch = /^\/api\/chat\/messages\/([^/]+)\/replies(\?.*)?$/.exec(url);

  // GET /api/chat/messages/:messageId/replies
  if (method === "GET" && repliesMatch) {
    const parentMessageId = decodeURIComponent(repliesMatch[1]);
    handleGetReplies(req, res, parentMessageId).catch((err) => {
      log(`[chat-api] getReplies 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // GET /api/chat/rooms/:roomId/messages
  if (method === "GET" && roomMsgMatch) {
    const chatRoomId = decodeURIComponent(roomMsgMatch[1]);
    handleGetMessages(req, res, chatRoomId).catch((err) => {
      log(`[chat-api] getMessages 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // POST /api/chat/rooms/:roomId/messages
  if (method === "POST" && roomMsgMatch) {
    const chatRoomId = decodeURIComponent(roomMsgMatch[1]);
    handleSendMessage(req, res, chatRoomId).catch((err) => {
      log(`[chat-api] sendMessage 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // PUT /api/chat/rooms/:roomId/read
  if (method === "PUT" && roomReadMatch) {
    const chatRoomId = decodeURIComponent(roomReadMatch[1]);
    handleMarkRead(req, res, chatRoomId).catch((err) => {
      log(`[chat-api] markRead 오류: ${String(err)}`);
      sendJson(res, 500, { error: String(err) });
    });
    return true;
  }

  // 매칭되지 않으면 다음 핸들러로
  return false;
}
