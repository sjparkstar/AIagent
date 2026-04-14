-- ============================================================
-- PLAN.md 섹션 14: 1차 권장 플레이북 10종 시드
-- 기존 playbooks 테이블 스키마 + 확장 컬럼 사용
-- required_approval_level: 1=읽기, 2=안전, 3=파괴적, 4=고위험
-- risk_level: low | medium | high | critical
-- ============================================================

INSERT INTO playbooks (
  name, description, steps, enabled, sort_order,
  required_approval_level, risk_level, category,
  preconditions, success_criteria, rollback_steps
) VALUES

-- 1. 네트워크 기본 진단 (읽기 전용)
(
  '네트워크 기본 진단',
  '게이트웨이/DNS/외부 연결 상태를 점검합니다.',
  '[
    {"name":"ipconfig","command":"ipconfig /all","commandType":"cmd"},
    {"name":"gateway-ping","command":"ping -n 2 8.8.8.8","commandType":"cmd","validateContains":"TTL="},
    {"name":"dns-test","command":"nslookup google.com","commandType":"cmd","validateContains":"Addresses"}
  ]'::jsonb,
  true, 10,
  1, 'low', 'network',
  null,
  '[{"name":"네트워크 정상","command":"ping -n 1 8.8.8.8","commandType":"cmd","expected":"TTL="}]'::jsonb,
  null
),

-- 2. DNS 장애 복구 (DNS 캐시 초기화)
(
  'DNS 장애 복구',
  'DNS 캐시를 비우고 resolver를 재시작합니다.',
  '[
    {"name":"flushdns","command":"ipconfig /flushdns","commandType":"cmd","validateContains":"Successfully"},
    {"name":"verify","command":"nslookup google.com","commandType":"cmd","validateContains":"Addresses"}
  ]'::jsonb,
  true, 20,
  2, 'medium', 'network',
  '[{"name":"관리자 권한 확인","command":"net session","commandType":"cmd","expected":""}]'::jsonb,
  '[{"name":"DNS 복구 검증","command":"nslookup google.com","commandType":"cmd","expected":"Addresses"}]'::jsonb,
  null
),

-- 3. 앱 무응답 진단/재실행 (예: chrome)
(
  '앱 무응답 진단/재실행',
  '지정된 앱의 상태를 확인하고 필요 시 재실행합니다. 명령 변수: $APP (기본: chrome.exe)',
  '[
    {"name":"프로세스 확인","command":"tasklist | findstr chrome","commandType":"cmd"},
    {"name":"정상 종료 시도","command":"taskkill /IM chrome.exe /T","commandType":"cmd"},
    {"name":"프로세스 재실행","command":"start chrome","commandType":"cmd"}
  ]'::jsonb,
  true, 30,
  3, 'high', 'process',
  null,
  '[{"name":"프로세스 실행 확인","command":"tasklist | findstr chrome","commandType":"cmd","expected":"chrome.exe"}]'::jsonb,
  null
),

-- 4. 필수 서비스 중지 복구 (Spooler 예시)
(
  '필수 서비스 재시작',
  '중지된 서비스(Spooler 예시)를 재시작합니다. 실제 서비스명은 플레이북 실행 시 확인.',
  '[
    {"name":"서비스 상태","command":"sc query Spooler","commandType":"cmd"},
    {"name":"서비스 시작","command":"sc start Spooler","commandType":"cmd"}
  ]'::jsonb,
  true, 40,
  3, 'high', 'service',
  '[{"name":"관리자 권한","command":"net session","commandType":"cmd","expected":""}]'::jsonb,
  '[{"name":"서비스 실행","command":"sc query Spooler","commandType":"cmd","expected":"RUNNING"}]'::jsonb,
  null
),

-- 5. 디스크 부족 안전 정리 (임시 파일만)
(
  '디스크 부족 안전 정리',
  '임시 파일과 브라우저 캐시만 안전하게 정리합니다.',
  '[
    {"name":"임시파일 크기","command":"powershell -Command \"Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum\"","commandType":"powershell"},
    {"name":"임시파일 삭제","command":"powershell -Command \"Remove-Item $env:TEMP\\* -Recurse -Force -ErrorAction SilentlyContinue\"","commandType":"powershell"}
  ]'::jsonb,
  true, 50,
  3, 'high', 'cleanup',
  null,
  '[{"name":"디스크 여유 확인","command":"wmic logicaldisk get DeviceID,FreeSpace,Size /format:list","commandType":"cmd","expected":"FreeSpace"}]'::jsonb,
  null
),

-- 6. 에이전트 통신 복구 (네트워크 인터페이스 재활성화)
(
  '에이전트 통신 복구',
  'IP 갱신 + winsock reset으로 네트워크 스택을 복구합니다.',
  '[
    {"name":"DHCP 갱신 (release)","command":"ipconfig /release","commandType":"cmd"},
    {"name":"DHCP 갱신 (renew)","command":"ipconfig /renew","commandType":"cmd"},
    {"name":"DNS flush","command":"ipconfig /flushdns","commandType":"cmd"}
  ]'::jsonb,
  true, 60,
  3, 'high', 'network',
  '[{"name":"관리자 권한","command":"net session","commandType":"cmd","expected":""}]'::jsonb,
  '[{"name":"인터넷 복구","command":"ping -n 2 8.8.8.8","commandType":"cmd","expected":"TTL="}]'::jsonb,
  null
),

-- 7. 화면 캡처 모듈 복구 (그래픽 드라이버 재시작은 위험하므로 세션 전환 안내만)
(
  '화면 캡처 모듈 점검',
  '화면 캡처 관련 프로세스 및 세션 상태를 점검합니다.',
  '[
    {"name":"활성 세션","command":"query session","commandType":"cmd"},
    {"name":"DWM 상태","command":"tasklist | findstr dwm","commandType":"cmd"}
  ]'::jsonb,
  true, 70,
  1, 'low', 'screen',
  null,
  '[{"name":"DWM 실행 확인","command":"tasklist | findstr dwm","commandType":"cmd","expected":"dwm.exe"}]'::jsonb,
  null
),

-- 8. CPU/메모리 과부하 원인 진단 (읽기 전용)
(
  'CPU/메모리 과부하 원인 진단',
  '상위 리소스 점유 프로세스를 조회합니다.',
  '[
    {"name":"CPU 상위","command":"powershell -Command \"Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name,Id,CPU,WS | Format-Table\"","commandType":"powershell"},
    {"name":"메모리 상위","command":"powershell -Command \"Get-Process | Sort-Object WS -Descending | Select-Object -First 10 Name,Id,WS | Format-Table\"","commandType":"powershell"}
  ]'::jsonb,
  true, 80,
  1, 'low', 'system',
  null,
  null,
  null
),

-- 9. 로그인 세션 이상 진단
(
  '로그인 세션 이상 진단',
  '현재 로그인 사용자 및 세션 상태를 확인합니다.',
  '[
    {"name":"현재 사용자","command":"whoami /user","commandType":"cmd"},
    {"name":"세션 목록","command":"query session","commandType":"cmd"},
    {"name":"최근 로그인","command":"powershell -Command \"Get-EventLog -LogName Security -InstanceId 4624 -Newest 5 -ErrorAction SilentlyContinue | Format-List\"","commandType":"powershell"}
  ]'::jsonb,
  true, 90,
  1, 'low', 'security',
  null,
  null,
  null
),

-- 10. 원격제어 권한 상태 진단
(
  '원격제어 권한 상태 진단',
  '원격제어에 필요한 권한 및 정책을 확인합니다.',
  '[
    {"name":"관리자 권한","command":"whoami /groups | findstr \"S-1-5-32-544\"","commandType":"cmd"},
    {"name":"UAC 상태","command":"reg query \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\" /v EnableLUA","commandType":"cmd"},
    {"name":"원격 데스크톱 정책","command":"reg query \"HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\" /v fDenyTSConnections","commandType":"cmd"}
  ]'::jsonb,
  true, 100,
  1, 'low', 'security',
  null,
  null,
  null
)
ON CONFLICT DO NOTHING;
