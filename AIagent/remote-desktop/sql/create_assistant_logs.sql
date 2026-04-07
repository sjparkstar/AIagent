-- AI Assistant 대화 로그 테이블
CREATE TABLE IF NOT EXISTS assistant_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES connection_sessions(id) ON DELETE CASCADE,

  -- 메시지 정보
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content TEXT NOT NULL,
  source TEXT,  -- 'supabase' | 'llm' | null

  -- 검색 메타
  query TEXT,
  doc_results_count INT,
  response_time_ms INT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_assistant_logs_session ON assistant_logs(session_id);
CREATE INDEX IF NOT EXISTS idx_assistant_logs_created ON assistant_logs(created_at DESC);

-- RLS
ALTER TABLE assistant_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anonymous insert" ON assistant_logs
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "Allow anonymous select" ON assistant_logs
  FOR SELECT TO anon USING (true);
