1. 목표 정의

구현하려는 기능을 한 줄로 정리하면:

뷰어가 호스트 상태 이상을 확인하고 승인하면, 호스트의 로컬 에이전트가 상세 진단과 자동 복구 플레이북을 수행하고 결과를 다시 뷰어에 보고하는 구조

즉, 단순 원격제어가 아니라
“원격지원 + 승인형 자동진단 + 안전한 자동복구” 구조.

2. 전체 아키텍처

구성 요소는 6개로 나누는 게 좋아.

1) Viewer Client

flutter 뷰어, 웹뷰어

역할:
호스트 화면/상태 보기
이상 상태 알림 받기
진단 요청 승인
복구 실행 승인
결과 확인
수동 개입 전환

2) Host Agent

호스트 PC/단말에 설치되는 로컬 에이전트

flutter 호스트, 웹 호스트

역할:

시스템 상태 수집
이상 징후 감지
상세 진단 수행
복구 액션 실행
실행 결과 검증
감사로그 생성

실제 진단과 복구는 여기서 돌아가야 해.

1) Relay / Control Server

중계서버 + 제어 오케스트레이션 서버

역할:
뷰어와 호스트 연결 관리
승인 요청/응답 전달
작업 세션 관리
정책 검증
로그 저장
플레이북 실행 이력 관리

4) Diagnostic Engine

호스트 에이전트 내부 또는 서버 정책 기반 진단 엔진

역할:
문제 유형 분류
진단 항목 선택
진단 결과 구조화
복구 후보 산출

예:
네트워크 오류
앱 응답 없음
서비스 중지
CPU/메모리 과부하
디스크 부족
화면 캡처 불가
프로세스 비정상 종료

5) Recovery Playbook Engine

복구 절차를 실행하는 엔진

역할:
사전 정의된 플레이북 실행
단계별 안전조건 확인
실패 시 롤백 또는 대체 경로 실행
고위험 액션은 재승인 요구

6) Audit / Policy Engine

보안과 추적성 담당

역할:
어떤 진단이 허용되는지 관리
어떤 복구가 승인 필요인지 관리
누가 언제 승인했는지 기록
민감 액션 제한
사후 감사를 위한 증적 저장

3. 권장 동작 흐름

가장 현실적인 흐름은 아래야.
단계 1. 이상 징후 감지
호스트 에이전트가 이상을 감지

예:
CPU 95% 이상 3분 지속
특정 서비스 중지
앱 프로세스 무응답
디스크 여유 5% 미만
네트워크 단절
검은 화면
캡처 권한 오류
에이전트 자체 모듈 오류

에이전트는 이걸 즉시 복구하지 말고, 먼저 이벤트를 올림.
예:
issue_detected
severity=medium
category=network
summary=인터넷 연결 불안정 감지
단계 2. Viewer에 진단 요청 표시
뷰어에 카드 형태로 표시
예:
문제 유형: 네트워크 연결 불안정
영향도: 중간
권장 조치: 상세 진단 실행
예상 수행 항목:
NIC 상태 점검
DNS 확인
gateway ping
adapter reset 가능성 있음

버튼:
상세 진단 승인
무시
수동 지원 전환
단계 3. Viewer 승인
뷰어가 승인하면 서버가 승인 토큰 발급

중요 포인트:
승인에는 scope가 있어야 함
“무슨 항목까지 허용되는지” 제한해야 함

예:
진단만 허용
비파괴 복구까지 허용
네트워크 리셋까지 허용
재부팅은 미허용

즉 승인 자체가 세분화되어야 해.
단계 4. Host Agent 상세 진단 수행
호스트 에이전트가 승인 범위 안에서 상세 진단 수행

예: 네트워크 문제라면
NIC up/down
IP 주소 상태
DHCP 여부
gateway ping
DNS resolve test
특정 서비스 endpoint 접속
proxy/firewall 상태
VPN 상태
최근 네트워크 오류 로그

결과는 구조화해서 반환

예:
root_cause_candidates
confidence
recommended_actions
risk_level
needs_additional_approval
단계 5. Viewer에 진단 결과 표시

뷰어에 상세 진단 결과를 사람이 이해할 수 있게 보여줘야 해.
예:
추정 원인 1: DNS 해석 실패
추정 원인 2: 어댑터 설정 이상
권장 복구:
DNS 캐시 초기화
네트워크 어댑터 재시작
Winsock reset
위험도:
1번 낮음
2번 중간
3번 중간
예상 영향:
네트워크 순간 끊김 가능

버튼:
권장 복구 실행
단계별 선택 실행
수동 처리
단계 6. 복구 실행 승인

복구는 진단 승인과 분리하는 게 좋아.
왜냐면 진단은 읽기 위주지만, 복구는 시스템 변경이니까.

예:
진단 승인: 이미 받음
복구 승인: 별도 필요

특히 아래는 재승인 필수:

서비스 재시작
프로세스 강제 종료
레지스트리 수정
네트워크 reset
앱 재설치
시스템 재부팅
단계 7. Playbook 실행

에이전트가 복구 플레이북 실행

예: 앱 무응답
프로세스 상태 확인
덤프 수집 옵션 확인
grace close 시도
실패 시 force kill
앱 재실행
헬스체크
화면/UI 정상 여부 확인

복구는 반드시 단계별 검증 구조여야 해.

단계 8. 결과 검증

복구 후 바로 끝내면 안 되고 검증이 필요해.

검증 방식:
프로세스 정상 실행 여부
서비스 health endpoint 체크
CPU/메모리 정상화 여부
네트워크 통신 복구 여부
UI 화면 정상 표시 여부
사용자 입력 가능 여부
단계 9. 결과 리포트

뷰어에 아래 형태로 표시

문제 요약
원인 후보
수행한 진단 항목
수행한 복구 항목
성공/실패
남은 위험
수동 확인 필요 사항
상세 로그 보기

4. 권장 모듈 구조
Host Agent 내부 모듈

1) Collector

상태 수집 모듈

수집 예:
CPU, 메모리, 디스크
프로세스 상태
서비스 상태
네트워크 상태
이벤트 로그
앱 로그
화면 캡처 상태
권한 상태
원격 세션 상태

2) Detector

이상 징후 탐지

예:
threshold rule
heartbeat missing
process crash
repeated reconnect
screen freeze
no input response
service unhealthy

3) Diagnostic Runner

승인된 범위 내 상세 진단 수행

특징:
읽기 전용 진단과 변경형 진단 분리
타임아웃
단계별 결과 구조화
리소스 제한

4) Playbook Runner

복구 실행 엔진

필수 기능:
step 기반 실행
pre-check
action
post-check
rollback(optional)
stop-on-failure
manual-handoff

5) Approval Guard

승인 범위 확인

예:
viewer 승인 토큰 검증
허용된 액션인지 검사
만료 시간 확인
정책 범위 확인

6) Verifier
복구 후 결과 확인

7) Reporter
서버/뷰어에 결과 전송

5. 문제 유형별 설계 예시
A. 네트워크 문제

진단:
물리 NIC 상태
IP/DHCP
gateway ping
DNS resolve
지정 endpoint 연결
proxy/VPN

복구:
DNS flush
adapter disable/enable
IP renew
winsock reset
agent reconnect

검증:
서버 heartbeat 정상
endpoint 연결 성공
B. 앱 무응답

진단:
프로세스 존재 여부
CPU hang 상태
window response check
최근 크래시 로그
의존 서비스 상태

복구:
정상 종료 시도
강제 종료
프로세스 재실행
캐시 정리
dependency service restart

검증:
프로세스 재기동
헬스체크
UI 정상 렌더링
C. 디스크 부족

진단:

드라이브 사용률
대용량 로그/임시파일
최근 급증 원인
필수 파티션 여유

복구:
임시파일 정리
오래된 로그 압축/삭제
캐시 정리
앱 임시 폴더 정리

주의:
삭제는 매우 위험하므로 범위 제한 필수
D. 서비스 중지

진단:
서비스 상태
시작 유형
의존 서비스
최근 종료 코드
포트 충돌 여부

복구:
서비스 재시작
의존 서비스 선기동
포트 충돌 프로세스 확인
설정 무결성 체크
E. 화면 캡처/원격제어 불가

진단:
권한 상태
그래픽 세션 상태
secure desktop 전환 여부
캡처 프로세스 상태

복구:
캡처 모듈 재시작
권한 상태 안내
세션 재연결
그래픽 파이프라인 복구

6. 승인 모델 설계

이 부분이 매우 중요해.

승인 레벨을 나눠야 해
Level 1: Read-only Diagnostic

변경 없는 진단만 허용

예:
상태 조회
로그 조회
프로세스/서비스 확인
네트워크 테스트
Level 2: Safe Recovery

비파괴 복구 허용

예:
서비스 재시작
앱 재실행
agent reconnect
DNS flush
Level 3: Disruptive Recovery

사용자 영향 가능 액션

예:
네트워크 adapter reset
프로세스 force kill
브라우저 강제 종료
세션 재생성
Level 4: High-risk Recovery

매우 신중해야 하는 액션

예:
파일 삭제
레지스트리 수정
방화벽 규칙 변경
재부팅
업데이트/재설치

레벨별로 승인 UX를 구분해서 진행되게 해야 해.

7. 플레이북 구조 예시

플레이북은 JSON/YAML/DB 기반으로 관리하면 좋아.

예시 구조:
{
  "playbookId": "recover_network_dns_001",
  "category": "network",
  "title": "DNS 장애 복구",
  "riskLevel": "medium",
  "requiresApprovalLevel": 2,
  "preconditions": [
    "agent_online",
    "viewer_approved",
    "os=windows"
  ],
  "diagnostics": [
    "check_adapter_status",
    "check_ip_config",
    "dns_resolve_test"
  ],
  "actions": [
    "flush_dns",
    "retry_dns_resolve",
    "verify_server_reachability"
  ],
  "rollback": [],
  "successCriteria": [
    "dns_resolve_success=true",
    "server_reachable=true"
  ]
}

이렇게 정의형으로 두면

관리 쉬움
버전 관리 가능
위험도 통제 가능
새 복구 시나리오 추가 쉬움

8. 통신 구조
Viewer ↔ Server ↔ Host Agent

권장 채널 분리:
원격제어/영상 채널
상태/이벤트 채널
승인/명령 채널
로그/결과 채널

이유:
진단 트래픽과 화면 제어를 분리해야 안정적
장애 시 재시도 정책 अलग하게 가능
예시 이벤트
Host → Server
issue.detected
diagnostic.progress
diagnostic.result
recovery.progress
recovery.result
verification.result
Viewer → Server
approve.diagnostic
approve.recovery
cancel.operation
request.manual_mode
Server → Host
run.diagnostic
run.recovery
abort.operation

9. 데이터 모델 예시
issue_event
id
host_id
category
severity
summary
detected_at
status
current_session_id
diagnostic_job
id
issue_event_id
approved_by
approval_scope
started_at
ended_at
result_status
root_cause_summary
raw_result_json
recovery_job
id
diagnostic_job_id
playbook_id
approved_by
risk_level
started_at
ended_at
result_status
raw_result_json
audit_log
id
actor_type
actor_id
host_id
action_type
action_detail
created_at
playbook
id
version
category
title
risk_level
definition_json
enabled

10. UI 설계
Viewer 화면 구성

1) 실시간 상태 패널
CPU
Memory
Disk
Network
Agent health
주요 서비스 상태

2) 문제 감지 알림 패널
문제 유형
심각도
감지 시간
영향도
추천 조치

3) 진단 승인 패널
수행될 진단 목록
읽기 전용 여부
예상 시간
수집 데이터 범위

4) 복구 승인 패널
수행 액션 목록
잠재 영향
중단 가능 여부
재승인 필요 여부

5) 작업 진행 패널
현재 단계
성공/실패
로그
재시도
수동 전환
11. 보안 설계

이 기능은 꼭 강하게 막아야 해.
필수 원칙
최소 권한

에이전트는 필요한 권한만 가져야 함
명령 allowlist
허용된 플레이북/액션만 실행
임의 쉘 명령 금지
뷰어 승인했다고 해서 임의 명령 실행 허용하면 위험
승인 토큰 만료
짧은 TTL 필요
세션 바인딩
승인은 특정 세션/특정 호스트/특정 이슈에만 유효
감사로그 강제
모든 진단/복구/승인은 남겨야 함
민감정보 마스킹
로그/스크린샷/설정 정보 중 비밀번호, 토큰, 키 마스킹

12. 추천 실행 방식
좋은 방식
사전 등록된 진단 모듈
사전 등록된 복구 플레이북
단계별 승인
자동 검증
실패 시 수동 전환
위험한 방식
에이전트가 임의 PowerShell/CMD/Shell 실행
뷰어가 자유 텍스트 명령 입력
승인 없이 자동 복구
파일 삭제/레지스트리 수정 기본 허용
13. 실제 권장 기술 구조

사용자 환경 기준으로 추천하면:

호스트 에이전트
Windows: 서비스 + 보조 프로세스
Android Host: foreground service + accessibility / device admin 정책 범위 내
진단 모듈: plugin 방식
서버
Session Orchestrator
Policy Engine
Approval Service
Job Queue
Audit Service
저장소
PostgreSQL: 메타데이터, 작업 이력
Redis: 세션 상태, 실시간 작업 상태
Object storage: 진단 리포트, 스크린샷, 로그 번들

14. 추천 플레이북 1차 세트

처음에는 아래 정도만 만드는 게 좋아.

네트워크 기본 진단
DNS 장애 진단/복구
앱 무응답 진단/재실행
필수 서비스 중지 복구
디스크 부족 안전 정리
에이전트 통신 복구
화면 캡처 모듈 복구
CPU/메모리 과부하 원인 프로세스 진단
로그인 세션 이상 진단
원격제어 권한 상태 진단

15. 최종 권장 아키텍처 요약

가장 현실적인 설계는 이거야.

핵심 흐름
호스트 에이전트가 이상 탐지
서버로 이벤트 전송
뷰어에 “상세 진단 승인” 표시
승인 후 호스트 에이전트가 읽기 진단 수행
원인/권장 복구안을 뷰어에 표시
복구는 별도 승인 후 플레이북 실행
단계별 검증 수행
결과/로그/감사기록 저장
실패 시 수동 원격제어로 전환
16. 네 제품 기준으로 한 줄 추천

네가 만들려는 제품이 뷰어-호스트 원격제어 + 자동진단/복구라면,
구조는 반드시:

“호스트 로컬 에이전트 중심 진단/복구 + 서버 오케스트레이션 + 뷰어 승인 기반 플레이북 실행"
"뷰어의 ai assistant에서 진행/승인/결과 등 모든 정보를 보여줘"

이렇게 잡아야 해.