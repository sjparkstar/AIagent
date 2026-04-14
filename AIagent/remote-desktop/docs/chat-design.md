# RemoteCall-mini 채팅 기능 설계서

> 작성일: 2026-04-10  
> 대상 시스템: remote-desktop 모노레포 (signaling-server + Supabase)

---

## 1. 전체 아키텍처

### 설계 원칙
기존 시그널링 서버의 WebSocket 연결을 **그대로 재사용**하여 채팅 메시지를 라우팅한다.
별도의 채팅 서버나 연결 없이 단일 WebSocket으로 WebRTC 시그널링과 채팅을 동시에 처리한다.

```
[뷰어 웹/Flutter]          [호스트 Electron/Flutter]
       |                              |
       |  WebSocket (포트 8080)       |
       +----------[시그널링 서버]------+
                       |
              채팅 메시지 감지
              (chat-* type)
                       |
          +------------------+------------------+
          |                                     |
   같은 roomId의                        Supabase REST API
   모든 참여자에게 브로드캐스트             (영구 저장)
   (host.ws + viewers.ws)
```

### 계층 구조
```
Presentation   : 뷰어 웹 UI / Flutter 채팅 패널
Application    : chat-api.ts (REST) + chat-ws.ts (WS 핸들러)
Domain         : 채팅 메시지 브로드캐스트 로직 (roomId 기반 라우팅)
Infrastructure : Supabase (PostgreSQL) — 메시지 영구 저장
```

### 하이브리드 흐름
1. 클라이언트가 `chat-message` WebSocket 메시지 전송
2. 서버: 같은 roomId의 모든 참여자에게 `chat-message-broadcast` 전송 (실시간)
3. 서버: Supabase `chat_messages` 테이블에 INSERT (영구 저장)
4. 클라이언트 초기 진입 시 REST API `GET /api/chat/rooms/:roomId/messages`로 이전 메시지 불러오기

---

## 2. DB 테이블 설계

### ERD
```
chat_rooms
  id (PK)
  session_id → connection_sessions.id (FK, nullable)
  room_type: 'direct' | 'group'
  name
  created_at

chat_participants
  id (PK)
  chat_room_id → chat_rooms.id (FK)
  user_id (text: viewerId 또는 'host')
  user_type: 'host' | 'viewer'
  last_read_at (timestamptz)
  joined_at

chat_messages
  id (PK)
  chat_room_id → chat_rooms.id (FK)
  sender_id (text: viewerId 또는 'host')
  sender_type: 'host' | 'viewer' | 'system' | 'bot'
  content (text)
  message_type: 'text' | 'system' | 'file'
  metadata (jsonb, nullable) — 파일 첨부 확장용
  created_at
```

### 컬럼 상세

#### chat_rooms
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid, PK, default gen_random_uuid() | 채팅방 고유 ID |
| session_id | uuid, FK, nullable | 연결된 원격 세션 ID |
| room_type | text, check('direct','group') | 채팅방 유형 |
| name | text, nullable | 그룹 채팅방 이름 |
| created_at | timestamptz, default now() | 생성 시각 |

#### chat_messages
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid, PK | 메시지 고유 ID |
| chat_room_id | uuid, FK → chat_rooms | 소속 채팅방 |
| sender_id | text | 발신자 ID (viewerId 또는 'host') |
| sender_type | text | 발신자 유형 |
| content | text | 메시지 본문 |
| message_type | text, default 'text' | 메시지 유형 |
| metadata | jsonb, nullable | 파일 URL 등 확장 데이터 |
| created_at | timestamptz, default now() | 전송 시각 |

#### chat_participants
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | uuid, PK | 참여자 레코드 ID |
| chat_room_id | uuid, FK → chat_rooms | 소속 채팅방 |
| user_id | text | 참여자 ID |
| user_type | text | 참여자 유형 |
| last_read_at | timestamptz, nullable | 마지막으로 읽은 시각 |
| joined_at | timestamptz, default now() | 입장 시각 |

---

## 3. API 설계

### REST 엔드포인트 목록

| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | /api/chat/rooms | 채팅방 생성 |
| GET | /api/chat/rooms?userId=xxx | 참여 중인 채팅방 목록 (마지막 메시지 + 안읽은 수 포함) |
| GET | /api/chat/rooms/:roomId/messages | 메시지 목록 (커서 페이징) |
| POST | /api/chat/rooms/:roomId/messages | 메시지 전송 (REST 경로, WS 미사용 시 대비) |
| PUT | /api/chat/rooms/:roomId/read | 읽음 처리 |

### 요청/응답 예시

#### POST /api/chat/rooms
```json
// 요청
{
  "sessionId": "uuid-of-session",
  "roomType": "direct",
  "name": null,
  "participantIds": ["host", "viewer-uuid-1"]
}
// 응답
{
  "id": "chat-room-uuid",
  "room_type": "direct",
  "created_at": "2026-04-10T00:00:00Z"
}
```

#### GET /api/chat/rooms?userId=host
```json
[
  {
    "id": "chat-room-uuid",
    "name": null,
    "room_type": "direct",
    "lastMessage": { "content": "안녕하세요", "created_at": "..." },
    "unreadCount": 3
  }
]
```

#### GET /api/chat/rooms/:roomId/messages?before=2026-04-10T00:00:00Z&limit=30
```json
[
  {
    "id": "msg-uuid",
    "sender_id": "host",
    "sender_type": "host",
    "content": "화면 공유 시작합니다",
    "message_type": "text",
    "created_at": "2026-04-10T00:00:00Z"
  }
]
```

---

## 4. WebSocket 이벤트 설계

### 채팅 관련 메시지 타입

| 타입 | 방향 | 설명 |
|------|------|------|
| `chat-message` | 클라이언트 → 서버 | 메시지 전송 요청 |
| `chat-message-broadcast` | 서버 → 클라이언트 | 동일 roomId 전체 브로드캐스트 |
| `chat-read` | 클라이언트 → 서버 | 읽음 처리 요청 |
| `chat-read-broadcast` | 서버 → 클라이언트 | 읽음 처리 알림 브로드캐스트 |
| `chat-typing` | 클라이언트 → 서버 | 타이핑 중 알림 (저장 없음) |
| `chat-typing-broadcast` | 서버 → 클라이언트 | 타이핑 알림 브로드캐스트 |

### 메시지 구조

```typescript
// 클라이언트가 서버로 보내는 메시지 전송 요청
{ type: 'chat-message', chatRoomId: string, senderId: string, senderType: 'host' | 'viewer', content: string, messageType?: 'text' | 'system' | 'file' }

// 서버가 같은 room의 모든 참여자에게 브로드캐스트
{ type: 'chat-message-broadcast', chatRoomId: string, messageId: string, senderId: string, senderType: string, content: string, createdAt: string }

// 읽음 처리 요청
{ type: 'chat-read', chatRoomId: string, userId: string }

// 읽음 처리 브로드캐스트 (안읽은 수 갱신용)
{ type: 'chat-read-broadcast', chatRoomId: string, userId: string, lastReadAt: string }

// 타이핑 알림 (DB 저장 없음, 브로드캐스트만)
{ type: 'chat-typing', chatRoomId: string, userId: string }
```

### 브로드캐스트 라우팅 로직
```
1. chat-* 타입 메시지 수신
2. 발신자의 ws로 room 조회 (getRoomByHost 또는 getViewerRoom)
3. room.host.ws + room.viewers의 모든 ws에 브로드캐스트
4. (chat-message인 경우) Supabase에 INSERT
```

---

## 5. 프론트 UI 구조

### 공통 컴포넌트 구조

```
ChatPanel (사이드 패널 또는 오버레이)
├── ChatHeader
│   └── 채팅방 이름 + 참여자 수
├── MessageList
│   ├── MessageBubble (내 메시지 / 상대 메시지 구분)
│   │   ├── 발신자 이름
│   │   ├── 메시지 본문
│   │   └── 전송 시각
│   └── SystemMessage (입장/퇴장 알림)
├── TypingIndicator (타이핑 중 표시)
└── ChatInput
    ├── 텍스트 입력창
    └── 전송 버튼
```

### 웹 (viewer-app) 구현 위치
- `src/chat-panel.ts` — ChatPanel 컴포넌트
- `style.css` — 채팅 패널 스타일 추가

### Flutter (viewer-app-flutter) 구현 위치
- `lib/widgets/chat_panel.dart` — ChatPanel 위젯
- `lib/services/chat_service.dart` — WebSocket 채팅 서비스

---

## 6. 서버/클라이언트 예제 코드

### 서버 — chat-ws.ts 핵심 흐름

```typescript
// 채팅 메시지 수신 → Supabase 저장 → 브로드캐스트
async function handleChatMessage(ws, msg, rooms) {
  // 1. 발신자의 room 찾기
  const room = findRoomByWs(ws, rooms);
  if (!room) return;

  // 2. Supabase에 메시지 저장
  const saved = await insertChatMessage({
    chatRoomId: msg.chatRoomId,
    senderId: msg.senderId,
    content: msg.content,
  });

  // 3. 같은 room의 모든 참여자에게 브로드캐스트
  const broadcast = { type: 'chat-message-broadcast', messageId: saved.id, ...saved };
  broadcastToRoom(room, broadcast);
}
```

### 클라이언트 — 메시지 전송

```typescript
// WebSocket으로 채팅 메시지 전송
ws.send(JSON.stringify({
  type: 'chat-message',
  chatRoomId: 'chat-room-uuid',
  senderId: 'host',
  senderType: 'host',
  content: '안녕하세요',
  messageType: 'text',
}));
```

### 클라이언트 — 이전 메시지 불러오기

```typescript
// REST API로 페이지네이션
const messages = await fetch(`/api/chat/rooms/${chatRoomId}/messages?limit=30`)
  .then(r => r.json());
```

---

## 7. 읽음 처리 로직

### last_read_at 기반 읽음 처리

각 참여자별로 `chat_participants.last_read_at` 컬럼 하나만 유지한다.
개별 메시지마다 읽음 여부를 저장하지 않으므로 row 수가 폭발하지 않는다.

### 처리 흐름

```
1. 사용자가 채팅 패널을 열거나 스크롤을 내릴 때
   → PUT /api/chat/rooms/:roomId/read { userId: 'host' }
   → DB: UPDATE chat_participants SET last_read_at = now()
         WHERE chat_room_id = :roomId AND user_id = :userId

2. 서버가 chat-read-broadcast 전송
   → 다른 참여자 클라이언트가 UI 안읽은 수 갱신

3. 클라이언트 렌더링 시
   → message.created_at > participant.last_read_at  →  "안읽음" 표시
   → message.created_at <= participant.last_read_at →  "읽음" 표시
```

### 읽음 시각 업데이트 트리거
- 채팅 패널이 열릴 때 (포커스 진입)
- 새 메시지 수신 시 채팅 패널이 열려 있으면 즉시
- 스크롤이 최하단에 도달할 때

---

## 8. 안읽은 수 계산

### SQL

```sql
-- 특정 사용자의 채팅방별 안읽은 수
SELECT
  cp.chat_room_id,
  COUNT(cm.id) AS unread_count
FROM chat_participants cp
LEFT JOIN chat_messages cm
  ON cm.chat_room_id = cp.chat_room_id
  AND cm.created_at > COALESCE(cp.last_read_at, '1970-01-01')
  AND cm.sender_id <> cp.user_id  -- 내가 보낸 메시지는 항상 읽음 처리
WHERE cp.user_id = :userId
GROUP BY cp.chat_room_id;
```

### REST API 응답에 포함

`GET /api/chat/rooms?userId=xxx` 응답에 `unreadCount` 필드로 포함.
프론트에서는 이 값을 배지(badge)로 표시한다.

---

## 9. 추후 확장 포인트

### 9.1 AI 챗봇 응답
- `sender_type = 'bot'` 메시지 타입 이미 설계됨
- 특정 키워드(예: `@ai`)로 트리거 → Kimi API 호출 → system 메시지로 응답 삽입

### 9.2 파일 첨부
- `message_type = 'file'` 이미 설계됨
- `metadata` jsonb 컬럼에 `{ url, filename, size, mimeType }` 저장
- Supabase Storage 또는 `/api/upload-recording` 패턴 재사용 가능

### 9.3 푸시 알림
- `chat_participants` 테이블에 `fcm_token` 컬럼 추가
- 메시지 저장 시 수신자의 토큰으로 FCM 발송

### 9.4 메시지 검색
- Supabase Full-Text Search (`to_tsvector('korean', content)`) 적용 가능
- `chat_messages` 에 `content_tsv` GIN 인덱스 추가

### 9.5 그룹 채팅 멤버 권한
- `chat_participants.role` 컬럼 추가 (`admin` / `member`)
- 관리자만 멤버 추가/제거 가능

---

## 10. 운영 시 주의사항

### 10.1 성능
- `chat_messages` 테이블은 시간이 지날수록 빠르게 커진다.
  → `created_at` 기반 파티셔닝 또는 90일 이상 메시지 자동 삭제(pg_cron) 권장
- 브로드캐스트 시 room의 viewer 수가 많으면 루프 비용 증가
  → 현재 규모(동시 접속 < 50명)에서는 문제없으나 이상 시 점검

### 10.2 보안
- RLS 정책: `chat_participants`에 포함된 `user_id`만 해당 `chat_room_id`의 메시지 READ 가능
- WebSocket 채팅 메시지 수신 시 서버에서 `senderId`가 실제 room 참여자인지 검증
- `content` 길이 제한: 최대 4,000자 (DB CHECK CONSTRAINT)

### 10.3 메시지 정리
```sql
-- 90일 이상 된 메시지 삭제 (pg_cron 사용 시)
DELETE FROM chat_messages
WHERE created_at < now() - INTERVAL '90 days';
```

### 10.4 동시성
- 같은 `chat_room_id`에 대해 동시에 `last_read_at` 업데이트가 올 수 있다.
  → `UPDATE ... WHERE last_read_at IS NULL OR last_read_at < now()` 조건으로 역방향 업데이트 방지

### 10.5 연결 끊김 시 메시지 유실 방지
- 클라이언트 재연결 시 `GET /api/chat/rooms/:roomId/messages?after=lastReceivedAt` 로 누락 메시지 보충
- `after` 파라미터를 chat-api.ts에 추가해두면 충분
