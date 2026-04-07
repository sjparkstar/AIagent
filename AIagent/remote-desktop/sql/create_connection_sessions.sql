-- 연결 세션 히스토리 테이블
CREATE TABLE IF NOT EXISTS connection_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 세션 식별
  room_id TEXT NOT NULL,
  viewer_id TEXT,

  -- 시간 정보
  connected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  disconnected_at TIMESTAMPTZ,
  duration_seconds INT,
  disconnect_reason TEXT,

  -- 뷰어 정보
  viewer_user_agent TEXT,
  viewer_ip TEXT,
  viewer_screen_width INT,
  viewer_screen_height INT,
  viewer_language TEXT,

  -- 호스트 정보
  host_os TEXT,
  host_os_version TEXT,
  host_cpu_model TEXT,
  host_mem_total_mb INT,
  host_screen_source TEXT,

  -- 연결 품질 (마지막 스냅샷)
  avg_bitrate_kbps NUMERIC,
  avg_framerate NUMERIC,
  avg_rtt_ms NUMERIC,
  total_packets_lost INT,
  total_bytes_received BIGINT,

  -- 메타 정보
  reconnect_count INT DEFAULT 0,
  metadata JSONB DEFAULT '{}'::jsonb,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_sessions_room_id ON connection_sessions(room_id);
CREATE INDEX IF NOT EXISTS idx_sessions_connected_at ON connection_sessions(connected_at DESC);

-- RLS 활성화 (anon key로 insert/select 허용)
ALTER TABLE connection_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anonymous insert" ON connection_sessions
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "Allow anonymous select" ON connection_sessions
  FOR SELECT TO anon USING (true);

CREATE POLICY "Allow anonymous update" ON connection_sessions
  FOR UPDATE TO anon USING (true) WITH CHECK (true);
