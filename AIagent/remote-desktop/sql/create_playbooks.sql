-- 플레이북 테이블
CREATE TABLE IF NOT EXISTS playbooks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  steps JSONB NOT NULL DEFAULT '[]'::jsonb,
  enabled BOOLEAN DEFAULT true,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_playbooks_enabled ON playbooks(enabled);

ALTER TABLE playbooks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow anonymous all" ON playbooks FOR ALL TO anon USING (true) WITH CHECK (true);

-- steps JSONB 구조 예시:
-- [
--   { "name": "단계명", "command": "명령어", "commandType": "cmd", "validateContains": "TTL=" },
--   { "name": "단계명", "command": "명령어", "commandType": "powershell" }
-- ]

INSERT INTO playbooks (name, description, steps, sort_order) VALUES
(
  '네트워크 기본 복구',
  'DNS/Winsock 초기화 후 재접속 테스트',
  '[
    {"name":"네트워크 상태 점검","command":"ipconfig /all","commandType":"cmd"},
    {"name":"DNS 캐시 초기화","command":"ipconfig /flushdns","commandType":"cmd"},
    {"name":"Winsock 초기화","command":"netsh winsock reset","commandType":"cmd"},
    {"name":"서버 접속 테스트","command":"ping 8.8.8.8 -n 3","commandType":"cmd","validateContains":"TTL="},
    {"name":"결과 보고","command":"echo 네트워크 복구 완료","commandType":"cmd"}
  ]'::jsonb,
  10
),
(
  '시스템 정리',
  '임시 파일, 브라우저 캐시 정리',
  '[
    {"name":"임시 파일 삭제","command":"del /q/f/s %TEMP%\\* 2>nul & echo done","commandType":"cmd"},
    {"name":"브라우저 캐시 삭제","command":"rd /s /q \"%LOCALAPPDATA%\\Google\\Chrome\\User Data\\Default\\Cache\" 2>nul & echo done","commandType":"cmd"},
    {"name":"DNS 캐시 초기화","command":"ipconfig /flushdns","commandType":"cmd"},
    {"name":"결과 보고","command":"echo 시스템 정리 완료","commandType":"cmd"}
  ]'::jsonb,
  20
),
(
  '보안 점검',
  'Defender 상태 확인 및 방화벽 점검',
  '[
    {"name":"Defender 상태 확인","command":"sc query WinDefend","commandType":"cmd"},
    {"name":"방화벽 상태 확인","command":"netsh advfirewall show allprofiles state","commandType":"cmd"},
    {"name":"결과 보고","command":"echo 보안 점검 완료","commandType":"cmd"}
  ]'::jsonb,
  30
);
