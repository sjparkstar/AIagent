-- ============================================================
-- 운영 배포 시 실행할 RLS 강화 스크립트
-- 전제조건: 시그널링 서버가 SUPABASE_SERVICE_KEY 환경변수를 사용 중이어야 함
-- (service_role 키는 RLS를 우회하므로 서버 API는 영향 없음)
-- anon key로 접근하는 모든 클라이언트는 이 정책에 따라 제한됨
-- 작성일: 2026-04-13
-- ============================================================

-- ----------------------------------------------------------
-- 1) 자동진단/복구 테이블 — anon key로는 읽기만 허용, 쓰기 전면 차단
--    (서버 API가 service_role key로 접근하므로 정상 동작)
-- ----------------------------------------------------------
ALTER TABLE issue_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_tokens    ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_jobs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE recovery_jobs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs         ENABLE ROW LEVEL SECURITY;

-- 기존 정책 제거 (있는 경우)
DROP POLICY IF EXISTS "anon_read_issues"       ON issue_events;
DROP POLICY IF EXISTS "anon_read_diag_jobs"    ON diagnostic_jobs;
DROP POLICY IF EXISTS "anon_read_rec_jobs"     ON recovery_jobs;
DROP POLICY IF EXISTS "anon_read_audit"        ON audit_logs;

-- issue_events: anon은 세션에 속한 이슈만 SELECT 가능 (INSERT/UPDATE/DELETE는 서버만)
CREATE POLICY "anon_read_issues"
  ON issue_events FOR SELECT TO anon
  USING (true);  -- 현재는 전체 공개. 운영 전환 시 세션 토큰 기반 필터 적용 필요

-- diagnostic_jobs / recovery_jobs: anon은 읽기만 가능 (대시보드 표시용)
CREATE POLICY "anon_read_diag_jobs"
  ON diagnostic_jobs FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon_read_rec_jobs"
  ON recovery_jobs FOR SELECT TO anon
  USING (true);

-- audit_logs: anon은 읽기만 가능, 수정/삭제 불가 (감사 무결성 보장)
CREATE POLICY "anon_read_audit"
  ON audit_logs FOR SELECT TO anon
  USING (true);

-- approval_tokens: anon 접근 전면 차단 (토큰 탈취 방지)
-- 정책을 만들지 않으면 RLS가 활성화된 상태에서 anon은 아무것도 못함

-- ----------------------------------------------------------
-- 2) chat_* 테이블도 동일하게 강화
-- ----------------------------------------------------------
ALTER TABLE chat_rooms         ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_participants  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_read_chat_rooms"      ON chat_rooms;
DROP POLICY IF EXISTS "anon_read_chat_messages"   ON chat_messages;
DROP POLICY IF EXISTS "anon_read_chat_parts"      ON chat_participants;

CREATE POLICY "anon_read_chat_rooms"
  ON chat_rooms FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon_read_chat_messages"
  ON chat_messages FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon_read_chat_parts"
  ON chat_participants FOR SELECT TO anon
  USING (true);

-- ----------------------------------------------------------
-- 3) macros / playbooks — anon은 읽기만 허용
--    (관리자 UI를 쓰더라도 UI에서 service_role 써야 함)
-- ----------------------------------------------------------
ALTER TABLE macros    ENABLE ROW LEVEL SECURITY;
ALTER TABLE playbooks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_read_macros"    ON macros;
DROP POLICY IF EXISTS "anon_read_playbooks" ON playbooks;

CREATE POLICY "anon_read_macros"
  ON macros FOR SELECT TO anon
  USING (enabled = true);

CREATE POLICY "anon_read_playbooks"
  ON playbooks FOR SELECT TO anon
  USING (enabled = true);

-- ----------------------------------------------------------
-- 4) connection_sessions / assistant_logs도 동일
-- ----------------------------------------------------------
ALTER TABLE connection_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE assistant_logs      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_read_sessions" ON connection_sessions;
DROP POLICY IF EXISTS "anon_read_logs"     ON assistant_logs;

CREATE POLICY "anon_read_sessions"
  ON connection_sessions FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon_read_logs"
  ON assistant_logs FOR SELECT TO anon
  USING (true);

-- ============================================================
-- 운영 배포 체크리스트:
-- [ ] 시그널링 서버 .env에 SUPABASE_SERVICE_KEY 설정
-- [ ] shared/src/supabase.ts가 서버에서는 service_role key 사용하도록 수정
-- [ ] 클라이언트(Flutter, Web)는 anon key만 사용 — 읽기 전용 조회만
-- [ ] 모든 쓰기(INSERT/UPDATE/DELETE)는 서버 REST API 경유
-- [ ] 이 SQL을 Supabase에 적용
-- [ ] 스모크 테스트: anon 클라이언트에서 approval_tokens INSERT가 거부되는지 확인
-- ============================================================
