// chat-client.ts
// 채팅 전용 클라이언트 — REST API 호출 + WebSocket 실시간 메시지 처리

// ─── 타입 정의 ────────────────────────────────────────────────────────────────

// 채팅 메시지 데이터 (서버 응답 구조)
export interface ChatMessageData {
  id: string;
  chatRoomId: string;
  senderId: string;
  senderType: "host" | "viewer" | "system" | "bot";
  content: string;
  messageType: "text" | "system" | "file";
  createdAt: string;
  // 스레드(답글) 정보
  parentMessageId: string | null;  // null이면 일반 메시지(스레드 루트)
  replyCount: number;              // 부모 메시지일 때 답글 수, 답글은 항상 0
}

// 채팅방 정보 (REST 응답 구조)
export interface ChatRoomData {
  id: string;
  sessionId: string;
  roomType: "direct" | "group";
  name: string | null;
  createdAt: string;
  lastMessage?: string;
  lastMessageAt?: string;
  unreadCount: number;
}

// 서버 broadcast 메시지 (WebSocket 수신)
interface ChatMessageBroadcast {
  type: "chat-message-broadcast";
  chatRoomId: string;
  messageId: string;
  senderId: string;
  senderType: string;
  content: string;
  messageType: string;
  createdAt: string;
  // 스레드 답글 정보
  parentMessageId?: string | null;
  replyCount?: number;
}

interface ChatReadBroadcast {
  type: "chat-read-broadcast";
  chatRoomId: string;
  userId: string;
  lastReadAt: string;
}

interface ChatTypingBroadcast {
  type: "chat-typing-broadcast";
  chatRoomId: string;
  userId: string;
}

// ─── ChatClient 클래스 ────────────────────────────────────────────────────────

export class ChatClient {
  private serverUrl: string;       // HTTP 베이스 URL (예: http://localhost:8080)
  private wsUrl: string;           // WebSocket URL (예: ws://localhost:8080)
  private ws: WebSocket | null = null;
  private chatRoomId: string | null = null;
  readonly userId: string;
  readonly userType: "host" | "viewer";

  // 이벤트 콜백 — 외부에서 할당
  onMessage?: (msg: ChatMessageData) => void;
  onReadUpdate?: (chatRoomId: string, userId: string) => void;
  onTyping?: (chatRoomId: string, userId: string) => void;
  onConnected?: () => void;

  constructor(serverUrl: string, userId: string, userType: "host" | "viewer") {
    this.serverUrl = serverUrl;
    // http:// → ws://, https:// → wss:// 변환
    this.wsUrl = serverUrl.replace(/^http/, "ws");
    this.userId = userId;
    this.userType = userType;
  }

  // ─── WebSocket 관리 ─────────────────────────────────────────────────────────

  // 채팅 전용 WebSocket 연결 (시그널링 서버 재사용)
  // 서버의 handleChatWebSocket이 chat-* 타입 메시지를 처리
  connect(): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;

    this.ws = new WebSocket(this.wsUrl);

    this.ws.onopen = () => {
      this.onConnected?.();
    };

    this.ws.onmessage = (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data as string) as unknown;
        this.handleWsMessage(data);
      } catch {
        // JSON 파싱 실패 시 무시
      }
    };

    this.ws.onclose = () => {
      // 연결 종료 시 재연결 시도 (5초 후)
      setTimeout(() => {
        if (this.chatRoomId) this.connect();
      }, 5000);
    };
  }

  disconnect(): void {
    this.ws?.close();
    this.ws = null;
  }

  // ─── REST API 호출 ──────────────────────────────────────────────────────────

  // 채팅방 생성 — POST /api/chat/rooms
  async createOrJoinRoom(sessionId: string, participantIds: string[]): Promise<ChatRoomData> {
    const res = await fetch(`${this.serverUrl}/api/chat/rooms`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sessionId,
        roomType: "direct",
        participantIds,
      }),
    });

    if (!res.ok) {
      throw new Error(`채팅방 생성 실패: ${res.status}`);
    }

    const room = await res.json() as Record<string, unknown>;
    this.chatRoomId = String(room["id"] ?? "");

    return {
      id: String(room["id"] ?? ""),
      sessionId: String(room["session_id"] ?? sessionId),
      roomType: (room["room_type"] as "direct" | "group") ?? "direct",
      name: room["name"] as string | null ?? null,
      createdAt: String(room["created_at"] ?? ""),
      unreadCount: 0,
    };
  }

  // 메시지 목록 조회 — GET /api/chat/rooms/:roomId/messages
  async loadMessages(
    chatRoomId: string,
    before?: string,
    limit = 30,
  ): Promise<ChatMessageData[]> {
    const params = new URLSearchParams({ limit: String(limit) });
    if (before) params.set("before", before);

    const res = await fetch(
      `${this.serverUrl}/api/chat/rooms/${encodeURIComponent(chatRoomId)}/messages?${params}`,
    );

    if (!res.ok) return [];

    const rows = await res.json() as Record<string, unknown>[];
    return rows.map((r) => ({
      id: String(r["id"] ?? ""),
      chatRoomId: String(r["chat_room_id"] ?? chatRoomId),
      senderId: String(r["sender_id"] ?? ""),
      senderType: (r["sender_type"] as ChatMessageData["senderType"]) ?? "viewer",
      content: String(r["content"] ?? ""),
      messageType: (r["message_type"] as ChatMessageData["messageType"]) ?? "text",
      createdAt: String(r["created_at"] ?? ""),
      parentMessageId: (r["parent_message_id"] as string | null) ?? null,
      replyCount: Number(r["reply_count"] ?? 0),
    }));
  }

  // 특정 메시지의 답글 목록 조회 — GET /api/chat/messages/:messageId/replies
  async loadReplies(parentMessageId: string): Promise<ChatMessageData[]> {
    const res = await fetch(
      `${this.serverUrl}/api/chat/messages/${encodeURIComponent(parentMessageId)}/replies`,
    );
    if (!res.ok) return [];
    const rows = await res.json() as Record<string, unknown>[];
    return rows.map((r) => ({
      id: String(r["id"] ?? ""),
      chatRoomId: String(r["chat_room_id"] ?? ""),
      senderId: String(r["sender_id"] ?? ""),
      senderType: (r["sender_type"] as ChatMessageData["senderType"]) ?? "viewer",
      content: String(r["content"] ?? ""),
      messageType: (r["message_type"] as ChatMessageData["messageType"]) ?? "text",
      createdAt: String(r["created_at"] ?? ""),
      parentMessageId: (r["parent_message_id"] as string | null) ?? null,
      replyCount: 0,  // 답글은 항상 0
    }));
  }

  // ─── WebSocket 메시지 전송 ──────────────────────────────────────────────────

  // 채팅 메시지 전송 (parentMessageId 지정 시 답글로 전송)
  sendMessage(content: string, parentMessageId?: string | null): void {
    if (!this.chatRoomId) return;
    this.wsSend({
      type: "chat-message",
      chatRoomId: this.chatRoomId,
      senderId: this.userId,
      senderType: this.userType,
      content,
      messageType: "text",
      parentMessageId: parentMessageId ?? null,
    });
  }

  // 읽음 처리 알림
  sendRead(): void {
    if (!this.chatRoomId) return;
    this.wsSend({
      type: "chat-read",
      chatRoomId: this.chatRoomId,
      userId: this.userId,
    });
  }

  // 타이핑 중 알림
  sendTyping(): void {
    if (!this.chatRoomId) return;
    this.wsSend({
      type: "chat-typing",
      chatRoomId: this.chatRoomId,
      userId: this.userId,
    });
  }

  // ─── WebSocket 수신 처리 ────────────────────────────────────────────────────

  // 채팅 메시지면 true 반환, 아니면 false
  handleWsMessage(data: unknown): boolean {
    if (typeof data !== "object" || data === null) return false;
    const msg = data as Record<string, unknown>;

    switch (msg["type"]) {
      case "chat-message-broadcast": {
        const m = msg as unknown as ChatMessageBroadcast;
        this.onMessage?.({
          id: m.messageId,
          chatRoomId: m.chatRoomId,
          senderId: m.senderId,
          senderType: m.senderType as ChatMessageData["senderType"],
          content: m.content,
          messageType: m.messageType as ChatMessageData["messageType"],
          createdAt: m.createdAt,
          parentMessageId: m.parentMessageId ?? null,
          replyCount: m.replyCount ?? 0,
        });
        return true;
      }

      case "chat-read-broadcast": {
        const m = msg as unknown as ChatReadBroadcast;
        this.onReadUpdate?.(m.chatRoomId, m.userId);
        return true;
      }

      case "chat-typing-broadcast": {
        const m = msg as unknown as ChatTypingBroadcast;
        this.onTyping?.(m.chatRoomId, m.userId);
        return true;
      }

      default:
        return false;
    }
  }

  // ─── 유틸 ───────────────────────────────────────────────────────────────────

  setChatRoom(roomId: string): void {
    this.chatRoomId = roomId;
  }

  getChatRoomId(): string | null {
    return this.chatRoomId;
  }

  private wsSend(msg: unknown): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }
}
