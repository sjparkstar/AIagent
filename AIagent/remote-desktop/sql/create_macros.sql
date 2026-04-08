-- 매크로 관리 테이블
CREATE TABLE IF NOT EXISTS macros (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  category TEXT NOT NULL DEFAULT 'general',
  command_type TEXT NOT NULL, -- 'cmd' | 'powershell' | 'shell'
  command TEXT NOT NULL,
  os TEXT NOT NULL DEFAULT 'all', -- 'win32' | 'darwin' | 'linux' | 'all'
  requires_admin BOOLEAN DEFAULT false,
  is_dangerous BOOLEAN DEFAULT false,
  enabled BOOLEAN DEFAULT true,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_macros_category ON macros(category);
CREATE INDEX IF NOT EXISTS idx_macros_enabled ON macros(enabled);

ALTER TABLE macros ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anonymous all" ON macros FOR ALL TO anon USING (true) WITH CHECK (true);

-- 시드 데이터: 기본 매크로
INSERT INTO macros (name, description, category, command_type, command, os, requires_admin, is_dangerous, sort_order) VALUES

-- 네트워크
('DNS 캐시 초기화', 'DNS 캐시를 비워 DNS 오류를 해결합니다.', 'network', 'cmd', 'ipconfig /flushdns', 'win32', true, false, 10),
('DNS 캐시 초기화 (macOS)', 'DNS 캐시를 초기화합니다.', 'network', 'shell', 'sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder', 'darwin', true, false, 11),
('DNS 캐시 초기화 (Linux)', 'systemd-resolved DNS 캐시를 초기화합니다.', 'network', 'shell', 'sudo systemd-resolve --flush-caches', 'linux', true, false, 12),
('네트워크 초기화', 'TCP/IP 및 Winsock을 초기화합니다.', 'network', 'cmd', 'netsh winsock reset && netsh int ip reset', 'win32', true, true, 20),
('IP 갱신', 'DHCP IP를 해제하고 다시 받습니다.', 'network', 'cmd', 'ipconfig /release && ipconfig /renew', 'win32', false, false, 30),
('방화벽 상태 확인', 'Windows 방화벽 프로파일 상태를 확인합니다.', 'network', 'cmd', 'netsh advfirewall show allprofiles state', 'win32', false, false, 40),

-- 프로세스/서비스
('프로세스 종료 (이름 지정)', '지정한 프로세스를 강제 종료합니다. 프로세스 이름을 입력하세요.', 'process', 'cmd', 'taskkill /F /IM {process_name}', 'win32', false, true, 50),
('프로세스 종료 (macOS/Linux)', '지정한 프로세스를 종료합니다.', 'process', 'shell', 'pkill -f {process_name}', 'darwin', false, true, 51),
('서비스 재시작', 'Windows 서비스를 재시작합니다. 서비스 이름을 입력하세요.', 'process', 'cmd', 'net stop {service_name} && net start {service_name}', 'win32', true, false, 60),
('서비스 상태 확인', 'Windows 서비스 상태를 조회합니다.', 'process', 'cmd', 'sc query {service_name}', 'win32', false, false, 65),

-- 시스템 정리
('임시 파일 삭제', 'Windows 임시 폴더를 정리합니다.', 'cleanup', 'cmd', 'del /q/f/s %TEMP%\* 2>nul', 'win32', false, false, 70),
('임시 파일 삭제 (macOS)', '~/Library/Caches를 정리합니다.', 'cleanup', 'shell', 'rm -rf ~/Library/Caches/*', 'darwin', false, false, 71),
('브라우저 캐시 삭제 (Chrome)', 'Chrome 브라우저 캐시를 삭제합니다.', 'cleanup', 'cmd', 'rd /s /q "%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache" 2>nul', 'win32', false, false, 75),
('Windows 업데이트 캐시 정리', 'SoftwareDistribution 폴더를 정리합니다.', 'cleanup', 'cmd', 'net stop wuauserv && del /q/f/s %WINDIR%\SoftwareDistribution\Download\* && net start wuauserv', 'win32', true, true, 80),
('휴지통 비우기', '휴지통을 비웁니다.', 'cleanup', 'cmd', 'rd /s /q C:\$Recycle.Bin 2>nul', 'win32', true, false, 85),

-- 진단/로그
('시스템 정보 수집', 'systeminfo를 텍스트로 저장합니다.', 'diagnostic', 'cmd', 'systeminfo > %USERPROFILE%\Desktop\systeminfo.txt', 'win32', false, false, 90),
('이벤트 로그 수집', '최근 시스템 이벤트 100건을 저장합니다.', 'diagnostic', 'powershell', 'Get-WinEvent -LogName System -MaxEvents 100 | Export-Csv $env:USERPROFILE\Desktop\events.csv', 'win32', false, false, 95),
('네트워크 진단 수집', 'ipconfig, route, netstat 정보를 수집합니다.', 'diagnostic', 'cmd', '(ipconfig /all & route print & netstat -an) > %USERPROFILE%\Desktop\network_diag.txt', 'win32', false, false, 100),
('Ping 테스트', '8.8.8.8에 ping 테스트를 실행합니다.', 'diagnostic', 'cmd', 'ping 8.8.8.8 -n 10', 'all', false, false, 105),

-- 보안/정책
('Windows Defender 검사', '빠른 검사를 실행합니다.', 'security', 'powershell', 'Start-MpScan -ScanType QuickScan', 'win32', true, false, 110),
('Windows Defender 업데이트', '바이러스 정의를 업데이트합니다.', 'security', 'powershell', 'Update-MpSignature', 'win32', true, false, 115),
('그룹 정책 강제 동기화', '그룹 정책을 즉시 적용합니다.', 'security', 'cmd', 'gpupdate /force', 'win32', true, false, 120),

-- 시스템 제어
('시스템 재부팅', '1분 후 시스템을 재부팅합니다.', 'system', 'cmd', 'shutdown /r /t 60 /c "원격 관리자에 의한 재부팅"', 'win32', true, true, 130),
('재부팅 취소', '예약된 재부팅을 취소합니다.', 'system', 'cmd', 'shutdown /a', 'win32', true, false, 131),
('디스크 검사 예약', '다음 재부팅 시 디스크 검사를 예약합니다.', 'system', 'cmd', 'chkdsk C: /F /R /X', 'win32', true, true, 140),
('SFC 시스템 파일 검사', '손상된 시스템 파일을 복구합니다.', 'system', 'cmd', 'sfc /scannow', 'win32', true, false, 145);
