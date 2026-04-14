-- ============================================================
-- chat_messages 스레드(답글) 기능 추가
-- ============================================================
-- 정책:
--   - 1단계 깊이만 허용 (답글의 답글은 불가)
--   - 답글 N개 배지 표시를 위해 부모 메시지에 reply_count 캐시
--   - INSERT/DELETE 트리거로 카운트 자동 갱신
-- ============================================================

-- ── 1. 컬럼 추가 ──────────────────────────────────────────────
-- parent_message_id가 NULL이면 일반 메시지(스레드의 루트)
-- 값이 있으면 해당 메시지의 답글
ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS parent_message_id UUID
    REFERENCES chat_messages(id) ON DELETE CASCADE;

-- 부모 메시지에 답글 수를 캐시 (배지 렌더링 시 매번 COUNT 안 하도록)
-- 답글 본인은 항상 0 (1단계 깊이만 허용하므로)
ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS reply_count INTEGER NOT NULL DEFAULT 0;

-- ── 2. 인덱스 ────────────────────────────────────────────────
-- 스레드 답글 목록 조회: parent_message_id로 필터 + 시간순 정렬
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent_created
  ON chat_messages (parent_message_id, created_at ASC)
  WHERE parent_message_id IS NOT NULL;

-- ── 3. 1단계 깊이 강제 (답글의 답글 차단) ─────────────────────
-- INSERT 시 부모가 또 다른 부모의 답글이면 거부
CREATE OR REPLACE FUNCTION chat_messages_enforce_thread_depth()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  parent_is_reply BOOLEAN;
BEGIN
  IF NEW.parent_message_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- 부모 메시지가 이미 답글인 경우 차단
  SELECT (parent_message_id IS NOT NULL) INTO parent_is_reply
  FROM chat_messages
  WHERE id = NEW.parent_message_id;

  IF parent_is_reply THEN
    RAISE EXCEPTION '답글에는 다시 답글을 달 수 없습니다 (1단계 깊이만 허용)';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_messages_thread_depth ON chat_messages;
CREATE TRIGGER trg_chat_messages_thread_depth
  BEFORE INSERT ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION chat_messages_enforce_thread_depth();

-- ── 4. reply_count 자동 갱신 트리거 ──────────────────────────
-- 답글 INSERT 시 부모의 reply_count +1
-- 답글 DELETE 시 부모의 reply_count -1
CREATE OR REPLACE FUNCTION chat_messages_update_reply_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.parent_message_id IS NOT NULL THEN
    UPDATE chat_messages
    SET reply_count = reply_count + 1
    WHERE id = NEW.parent_message_id;
  ELSIF TG_OP = 'DELETE' AND OLD.parent_message_id IS NOT NULL THEN
    UPDATE chat_messages
    SET reply_count = GREATEST(reply_count - 1, 0)
    WHERE id = OLD.parent_message_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_messages_reply_count_ins ON chat_messages;
CREATE TRIGGER trg_chat_messages_reply_count_ins
  AFTER INSERT ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION chat_messages_update_reply_count();

DROP TRIGGER IF EXISTS trg_chat_messages_reply_count_del ON chat_messages;
CREATE TRIGGER trg_chat_messages_reply_count_del
  AFTER DELETE ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION chat_messages_update_reply_count();

-- ── 5. 기존 데이터 reply_count 백필 (한 번만 실행) ───────────
-- 만약 기존에 답글 없이 운영되었다면 모두 0으로 그대로.
-- 데이터가 섞여 있으면 아래 쿼리로 일괄 보정 가능.
-- UPDATE chat_messages parent
-- SET reply_count = (
--   SELECT COUNT(*) FROM chat_messages child
--   WHERE child.parent_message_id = parent.id
-- )
-- WHERE parent.parent_message_id IS NULL;

-- ============================================================
-- 적용 후 확인 쿼리
-- ============================================================
-- \d chat_messages
-- SELECT id, content, parent_message_id, reply_count FROM chat_messages LIMIT 10;
