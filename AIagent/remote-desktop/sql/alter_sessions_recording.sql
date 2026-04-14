-- connection_sessions 테이블에 녹화 및 PDF URL 컬럼 추가
ALTER TABLE connection_sessions
  ADD COLUMN IF NOT EXISTS recording_url TEXT,
  ADD COLUMN IF NOT EXISTS pdf_url TEXT;

COMMENT ON COLUMN connection_sessions.recording_url IS '세션 녹화 파일 URL';
COMMENT ON COLUMN connection_sessions.pdf_url IS '세션 요약 PDF 파일 URL';
