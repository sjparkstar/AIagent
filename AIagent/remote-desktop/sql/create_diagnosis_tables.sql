-- ============================================================
-- RemoteCall-mini 자동진단/복구 시스템 테이블
-- PLAN.md 기반 구현: 이슈 이벤트, 승인 토큰, 진단/복구 작업, 감사 로그
-- 작성일: 2026-04-13
-- ============================================================

-- ----------------------------------------------------------
-- 1. issue_events: 호스트 이상 감지 이벤트
--    호스트 Detector 모듈이 이상 감지 시 생성
--    status: detected → acknowledged → diagnosed → recovered → closed
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS issue_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      UUID REFERENCES connection_sessions(id) ON DELETE SET NULL,
  host_id         TEXT NOT NULL,                       -- 호스트 식별자 (roomId 또는 host name)
  category        TEXT NOT NULL                        -- 이슈 카테고리
                    CHECK (category IN ('network', 'process', 'cleanup', 'diagnostic',
                                        'security', 'system', 'general', 'screen', 'service')),
  severity        TEXT NOT NULL DEFAULT 'warning'      -- 심각도
                    CHECK (severity IN ('critical', 'warning', 'info')),
  summary         TEXT NOT NULL,                       -- 간단한 요약 (뷰어 카드 제목)
  detail          TEXT,                                -- 상세 설명
  detected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  status          TEXT NOT NULL DEFAULT 'detected'     -- 처리 상태
                    CHECK (status IN ('detected', 'acknowledged', 'diagnosed',
                                      'recovered', 'dismissed', 'closed')),
  metadata        JSONB,                               -- 원본 진단 데이터
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_issue_events_session
  ON issue_events (session_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_issue_events_status
  ON issue_events (status, detected_at DESC);

-- ----------------------------------------------------------
-- 2. approval_tokens: 승인 토큰 (TTL 포함)
--    뷰어가 진단/복구를 승인하면 발급되는 제한된 권한 토큰
--    scope_level: 1(읽기) ~ 4(고위험)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS approval_tokens (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id          UUID,                            -- 어떤 세션에서 발급된 승인인지
  issue_event_id      UUID REFERENCES issue_events(id) ON DELETE CASCADE,
  approver_id         TEXT NOT NULL,                   -- viewerId
  approval_type       TEXT NOT NULL                    -- 승인 유형
                        CHECK (approval_type IN ('diagnostic', 'recovery')),
  scope_level         INT  NOT NULL                    -- PLAN.md 4단계 승인
                        CHECK (scope_level BETWEEN 1 AND 4),
  allowed_action_ids  TEXT[],                          -- 허용된 매크로/플레이북 ID 화이트리스트
  issued_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at          TIMESTAMPTZ NOT NULL,            -- TTL (기본 5분)
  consumed_at         TIMESTAMPTZ,                     -- 사용된 시각
  status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'consumed', 'expired', 'revoked'))
);

CREATE INDEX IF NOT EXISTS idx_approval_tokens_issue
  ON approval_tokens (issue_event_id);
CREATE INDEX IF NOT EXISTS idx_approval_tokens_status
  ON approval_tokens (status, expires_at);

-- ----------------------------------------------------------
-- 3. diagnostic_jobs: 진단 작업 이력
--    승인 후 호스트가 상세 진단을 수행한 결과
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS diagnostic_jobs (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_event_id          UUID NOT NULL REFERENCES issue_events(id) ON DELETE CASCADE,
  approval_token_id       UUID REFERENCES approval_tokens(id),
  started_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at                TIMESTAMPTZ,
  status                  TEXT NOT NULL DEFAULT 'running'
                            CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
  root_cause_candidates   JSONB,   -- [{cause, confidence, evidence}, ...]
  recommended_actions     JSONB,   -- [{playbook_id, title, risk_level}, ...]
  raw_result              JSONB    -- 진단 단계별 원본 출력
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_jobs_issue
  ON diagnostic_jobs (issue_event_id);

-- ----------------------------------------------------------
-- 4. recovery_jobs: 복구 작업 이력
--    플레이북 실행 결과 및 단계별 로그
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS recovery_jobs (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  diagnostic_job_id       UUID REFERENCES diagnostic_jobs(id) ON DELETE SET NULL,
  issue_event_id          UUID REFERENCES issue_events(id) ON DELETE CASCADE,
  playbook_id             UUID,                                -- playbooks 테이블 FK (nullable: 즉석 매크로)
  approval_token_id       UUID REFERENCES approval_tokens(id),
  started_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at                TIMESTAMPTZ,
  status                  TEXT NOT NULL DEFAULT 'running'
                            CHECK (status IN ('running', 'completed', 'failed', 'rolled_back', 'cancelled')),
  step_results            JSONB,   -- [{step_name, status, output, duration_ms, error?}, ...]
  verification_result     JSONB    -- 복구 후 검증 결과
);

CREATE INDEX IF NOT EXISTS idx_recovery_jobs_issue
  ON recovery_jobs (issue_event_id);

-- ----------------------------------------------------------
-- 5. audit_logs: 감사 로그 (모든 승인/실행 기록)
--    PLAN.md 보안 요구사항: 책임 소재 확인용 영속 기록
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_type      TEXT NOT NULL                        -- 행위자 유형
                    CHECK (actor_type IN ('viewer', 'host', 'system', 'server')),
  actor_id        TEXT NOT NULL,                       -- viewerId / hostId / 'system'
  host_id         TEXT,
  session_id      UUID,
  action_type     TEXT NOT NULL,                       -- 액션 식별자 (issue_detected, approval_granted, ...)
  action_detail   JSONB,                               -- 액션 상세 (마스킹된 데이터)
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_session
  ON audit_logs (session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action
  ON audit_logs (action_type, created_at DESC);

-- ----------------------------------------------------------
-- 6. 기존 macros/playbooks 테이블 확장
--    승인 레벨, 위험도, pre/post-check, rollback 컬럼 추가
-- ----------------------------------------------------------
ALTER TABLE macros
  ADD COLUMN IF NOT EXISTS required_approval_level INT DEFAULT 2
    CHECK (required_approval_level BETWEEN 1 AND 4);

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS required_approval_level INT DEFAULT 2
    CHECK (required_approval_level BETWEEN 1 AND 4);

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS risk_level TEXT DEFAULT 'medium'
    CHECK (risk_level IN ('low', 'medium', 'high', 'critical'));

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS preconditions JSONB;   -- [{name, check_command, expected}, ...]

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS success_criteria JSONB; -- [{name, check_command, expected}, ...]

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS rollback_steps JSONB;  -- [{name, command, command_type}, ...]

ALTER TABLE playbooks
  ADD COLUMN IF NOT EXISTS category TEXT DEFAULT 'general';

-- ----------------------------------------------------------
-- RLS 비활성화 (서버 API에서만 접근)
-- ----------------------------------------------------------
ALTER TABLE issue_events       DISABLE ROW LEVEL SECURITY;
ALTER TABLE approval_tokens    DISABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_jobs    DISABLE ROW LEVEL SECURITY;
ALTER TABLE recovery_jobs      DISABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs         DISABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------
-- 이슈 이벤트 상태 변경 시 updated_at 자동 갱신 트리거
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION update_issue_events_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_issue_events_updated_at ON issue_events;
CREATE TRIGGER trg_issue_events_updated_at
  BEFORE UPDATE ON issue_events
  FOR EACH ROW
  EXECUTE FUNCTION update_issue_events_updated_at();
