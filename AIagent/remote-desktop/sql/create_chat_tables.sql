-- ============================================================
-- RemoteCall-mini 채팅 테이블 생성 스크립트
-- 대상: Supabase PostgreSQL
-- 작성일: 2026-04-10
-- ============================================================

-- ----------------------------------------------------------
-- 1. chat_rooms: 채팅방 (1:1 또는 그룹)
--    session_id는 connection_sessions 테이블과 연결되며 nullable
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_rooms (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  UUID REFERENCES connection_sessions(id) ON DELETE SET NULL,
  room_type   TEXT NOT NULL DEFAULT 'direct'
                CHECK (room_type IN ('direct', 'group')),
  name        TEXT,                          -- 그룹 채팅방 이름 (direct면 null 허용)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- 2. chat_messages: 채팅 메시지
--    sender_type에 'system'/'bot'을 포함하여 자동 메시지도 지원
--    metadata JSONB: 파일 첨부 확장용 { url, filename, size, mimeType }
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_messages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_room_id  UUID NOT NULL REFERENCES chat_rooms(id) ON DELETE CASCADE,
  sender_id     TEXT NOT NULL,               -- viewerId 또는 'host'
  sender_type   TEXT NOT NULL DEFAULT 'viewer'
                  CHECK (sender_type IN ('host', 'viewer', 'system', 'bot')),
  content       TEXT NOT NULL CHECK (char_length(content) <= 4000),
  message_type  TEXT NOT NULL DEFAULT 'text'
                  CHECK (message_type IN ('text', 'system', 'file')),
  metadata      JSONB,                       -- 파일 첨부 등 확장 데이터 (nullable)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------
-- 3. chat_participants: 채팅방 참여자 + 읽음 위치
--    last_read_at: 이 시각보다 이후에 생성된 메시지 = 안읽음
--    (user_id, chat_room_id) 조합은 유니크
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_participants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_room_id  UUID NOT NULL REFERENCES chat_rooms(id) ON DELETE CASCADE,
  user_id       TEXT NOT NULL,               -- viewerId 또는 'host'
  user_type     TEXT NOT NULL DEFAULT 'viewer'
                  CHECK (user_type IN ('host', 'viewer')),
  last_read_at  TIMESTAMPTZ,                 -- nullable: 한 번도 읽지 않은 경우
  joined_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (chat_room_id, user_id)             -- 같은 채팅방에 동일 user 중복 방지
);

-- ----------------------------------------------------------
-- 인덱스
-- chat_messages: 채팅방별 시간순 조회가 가장 빈번한 쿼리
-- chat_participants: 채팅방 참여자 조회 + 읽음 위치 계산
-- ----------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_chat_messages_room_created
  ON chat_messages (chat_room_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_chat_participants_room_user
  ON chat_participants (chat_room_id, user_id);

-- 특정 사용자가 참여 중인 모든 채팅방 조회용
CREATE INDEX IF NOT EXISTS idx_chat_participants_user
  ON chat_participants (user_id);

-- ----------------------------------------------------------
-- RLS (Row Level Security) 설정
-- 참여자(chat_participants에 등록된 user_id)만 해당 채팅방 접근 가능
-- 주의: anon key 사용 시 RLS를 반드시 활성화해야 데이터 보호됨
-- ----------------------------------------------------------

-- RLS 활성화
ALTER TABLE chat_rooms        ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_messages     ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_participants ENABLE ROW LEVEL SECURITY;

-- chat_rooms: 내가 참여자로 등록된 채팅방만 조회 가능
CREATE POLICY "참여자만 채팅방 조회 가능"
  ON chat_rooms
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM chat_participants
      WHERE chat_participants.chat_room_id = chat_rooms.id
        AND chat_participants.user_id = current_setting('request.jwt.claims', true)::jsonb->>'sub'
    )
  );

-- chat_messages: 내가 참여자로 등록된 채팅방의 메시지만 조회/삽입 가능
CREATE POLICY "참여자만 메시지 조회 가능"
  ON chat_messages
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM chat_participants
      WHERE chat_participants.chat_room_id = chat_messages.chat_room_id
        AND chat_participants.user_id = current_setting('request.jwt.claims', true)::jsonb->>'sub'
    )
  );

CREATE POLICY "참여자만 메시지 전송 가능"
  ON chat_messages
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM chat_participants
      WHERE chat_participants.chat_room_id = chat_messages.chat_room_id
        AND chat_participants.user_id = current_setting('request.jwt.claims', true)::jsonb->>'sub'
    )
  );

-- chat_participants: 내 참여 정보만 수정 가능 (last_read_at 갱신)
CREATE POLICY "본인 참여 정보만 수정 가능"
  ON chat_participants
  FOR UPDATE
  USING (
    user_id = current_setting('request.jwt.claims', true)::jsonb->>'sub'
  );

-- ----------------------------------------------------------
-- 서버 사이드(service_role key)에서 RLS 우회하여 모든 작업 허용
-- chat-api.ts는 SUPABASE_SERVICE_KEY를 사용하여 RLS를 우회한다
-- (현재 구현에서는 anon key를 사용하므로 RLS 정책이 적용됨)
-- ----------------------------------------------------------

-- ----------------------------------------------------------
-- 안읽은 수 계산 뷰 (편의용)
-- 사용: SELECT * FROM chat_unread_counts WHERE user_id = 'host';
-- ----------------------------------------------------------
CREATE OR REPLACE VIEW chat_unread_counts AS
SELECT
  cp.user_id,
  cp.chat_room_id,
  COUNT(cm.id) AS unread_count
FROM chat_participants cp
LEFT JOIN chat_messages cm
  ON cm.chat_room_id = cp.chat_room_id
  -- last_read_at 이후에 생성된 메시지만 카운트
  AND cm.created_at > COALESCE(cp.last_read_at, '1970-01-01'::TIMESTAMPTZ)
  -- 내가 보낸 메시지는 항상 읽음으로 간주
  AND cm.sender_id <> cp.user_id
GROUP BY cp.user_id, cp.chat_room_id;
