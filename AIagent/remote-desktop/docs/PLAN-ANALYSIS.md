# PLAN.md 기능 분석 보고서

작성일: 2026-04-13
문서: `remote-desktop/PLAN.md` ↔ 현재 구현 상태 비교

---

## 1. 요약

**목표 기능**: "원격지원 + 승인형 자동진단 + 안전한 자동복구"

```
호스트 이상 감지 → 뷰어 알림 → 승인 → 상세 진단 → 결과 표시
→ 복구 승인 → 플레이북 실행 → 단계별 검증 → 결과 리포트 → 감사 기록
```

**현재 구현 커버리지**: **약 40%** (부분 구현됨)

- ✅ 기본 이상 징후 감지 (CPU/메모리/디스크/네트워크)
- ✅ 매크로/플레이북 정의 및 실행
- ✅ DataChannel 기반 원격 명령 실행
- ❌ 4단계 승인 모델
- ❌ 승인 토큰/스코프 바인딩
- ❌ 이슈 이벤트 생명주기 관리
- ❌ 감사 로그 영속화
- ❌ 복구 후 자동 검증
- ❌ 단계별 승인 UX 분리

---

## 2. 구성 요소별 현황

### 2.1 Viewer Client (뷰어)

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 호스트 상태 보기 | ✓ | ✅ 대시보드 패널 | - |
| 이상 알림 수신 | ✓ | ⚠️ 자동진단 결과 표시만 | 이슈 이벤트 시스템 없음 |
| 진단 요청 승인 UI | ✓ | ❌ 없음 | 승인 카드 UI 필요 |
| 복구 실행 승인 UI | ✓ | ⚠️ confirm() 다이얼로그만 | 스코프별 승인 UI 필요 |
| 결과 확인 패널 | ✓ | ⚠️ 채팅으로만 표시 | 전용 결과 리포트 UI 필요 |
| 수동 개입 전환 | ✓ | ⚠️ 일반 원격제어로 가능 | 명시적 전환 기능 필요 |

### 2.2 Host Agent (호스트)

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 시스템 상태 수집 (Collector) | ✓ | ✅ `system_diagnostics.dart` | - |
| 이상 탐지 (Detector) | ✓ | ⚠️ 뷰어 측에서만 판정 | 호스트 측 이상 탐지 엔진 필요 |
| 상세 진단 (Diagnostic Runner) | ✓ | ❌ 없음 | 진단 전용 모듈 필요 |
| 복구 실행 (Playbook Runner) | ✓ | ✅ `command_executor.dart` | pre/post-check 없음 |
| 승인 가드 (Approval Guard) | ✓ | ❌ 없음 | 토큰 검증 로직 필요 |
| 검증 (Verifier) | ✓ | ⚠️ `validateContains`만 | 구조화된 검증 로직 필요 |
| 리포터 (Reporter) | ✓ | ⚠️ DataChannel로 단순 전송 | 구조화된 보고서 포맷 필요 |

### 2.3 Relay / Control Server (중계 서버)

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 연결 관리 | ✓ | ✅ `server.ts` WebSocket | - |
| 승인 요청/응답 전달 | ✓ | ❌ 없음 | `approval-request/response` 핸들러 필요 |
| 작업 세션 관리 | ✓ | ⚠️ `connection_sessions` | 진단/복구 작업 추적 없음 |
| 정책 검증 | ✓ | ❌ 없음 | Allowlist/스코프 검증 없음 |
| 로그 저장 | ✓ | ⚠️ `assistant_logs` | 구조화된 감사 로그 없음 |
| 플레이북 실행 이력 | ✓ | ❌ 없음 | `recovery_jobs` 테이블 필요 |

### 2.4 Diagnostic Engine

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 문제 유형 분류 | ✓ | ✅ category 필드 (network/process 등) | - |
| 진단 항목 선택 | ✓ | ❌ 고정 진단만 | 이슈별 동적 선택 없음 |
| 진단 결과 구조화 | ✓ | ⚠️ DiagnosisResult 있음 | root_cause_candidates, confidence 없음 |
| 복구 후보 산출 | ✓ | ❌ 없음 | 진단 → 플레이북 매핑 필요 |

### 2.5 Recovery Playbook Engine

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 사전 정의 플레이북 실행 | ✓ | ✅ `playbooks` 테이블 | - |
| 단계별 안전조건 확인 | ✓ | ⚠️ validateContains만 | pre-check 단계 없음 |
| 실패 시 롤백 | ✓ | ❌ 없음 | rollback 단계 정의 필요 |
| 고위험 재승인 | ✓ | ❌ 없음 | risk_level 기반 재승인 게이트 필요 |

### 2.6 Audit / Policy Engine

| 기능 | PLAN.md 요구 | 현재 상태 | Gap |
|------|-------------|----------|-----|
| 진단 허용 정책 | ✓ | ❌ 없음 | 전면 구현 필요 |
| 복구 승인 정책 | ✓ | ❌ 없음 | 전면 구현 필요 |
| 승인자/시각 기록 | ✓ | ❌ 없음 | `audit_logs` 테이블 필요 |
| 민감 액션 제한 | ✓ | ❌ 없음 | 명령 allowlist 필요 |
| 증적 저장 | ✓ | ⚠️ assistant_logs만 | 전용 감사 테이블 필요 |

---

## 3. 동작 흐름 Gap 분석 (9단계)

| 단계 | 설명 | 구현 여부 | 필요 작업 |
|------|------|----------|-----------|
| 1. 이상 징후 감지 | 호스트가 이벤트 생성 | ❌ | `issue.detected` 이벤트, `issue_events` 테이블 |
| 2. 뷰어에 진단 요청 표시 | 카드 UI | ❌ | 승인 카드 위젯, 진단 항목 목록 |
| 3. 뷰어 승인 | 스코프 토큰 발급 | ❌ | `approval_tokens` 테이블, TTL, scope 제한 |
| 4. 상세 진단 수행 | 승인 범위 내 실행 | ⚠️ | Diagnostic Runner, 승인 가드 |
| 5. 결과 표시 | root_cause_candidates | ❌ | 구조화된 결과 포맷 + 전용 UI |
| 6. 복구 승인 | 재승인 (진단과 분리) | ❌ | 별도 승인 플로우 |
| 7. 플레이북 실행 | 단계별 실행 | ⚠️ | pre/post-check, rollback 추가 |
| 8. 결과 검증 | 자동 헬스체크 | ⚠️ | Verifier 모듈 |
| 9. 결과 리포트 | 종합 리포트 UI | ❌ | 상세 리포트 위젯 |

---

## 4. 승인 모델 (Level 1~4) 구현 계획

현재 구현: 단순 confirm() 다이얼로그 (이진 승인)
PLAN.md 요구: 4단계 스코프 기반 승인

| Level | 설명 | 예시 액션 | 승인 UX |
|-------|------|-----------|---------|
| 1 | Read-only Diagnostic | 상태 조회, 로그 조회, ping | 간단 승인 |
| 2 | Safe Recovery | 서비스 재시작, DNS flush | 표준 승인 |
| 3 | Disruptive Recovery | adapter reset, force kill | 강조 경고 + 명시 승인 |
| 4 | High-risk Recovery | 파일 삭제, 재부팅, 레지스트리 | 이중 확인 + 사유 입력 |

**구현 필요 사항**:
- `macros`/`playbooks` 테이블에 `required_approval_level` 컬럼 추가
- `approval_tokens` 테이블: `{token, session_id, host_id, issue_id, scope_level, allowed_action_ids, expires_at}`
- 서버 측 승인 토큰 발급 및 검증 로직
- 클라이언트 측 레벨별 UX 분기

---

## 5. 필요한 DB 스키마 신규

### 5.1 issue_events (이상 감지 이벤트)
```sql
CREATE TABLE issue_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES connection_sessions(id),
  host_id TEXT NOT NULL,
  category TEXT NOT NULL,  -- network, process, system, ...
  severity TEXT NOT NULL,  -- critical, warning, info
  summary TEXT NOT NULL,
  detected_at TIMESTAMPTZ DEFAULT now(),
  status TEXT DEFAULT 'detected',  -- detected, acknowledged, diagnosed, recovered, dismissed
  metadata JSONB
);
```

### 5.2 approval_tokens (승인 토큰)
```sql
CREATE TABLE approval_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL,
  issue_event_id UUID REFERENCES issue_events(id),
  approver_id TEXT NOT NULL,  -- viewer_id
  scope_level INT NOT NULL CHECK (scope_level BETWEEN 1 AND 4),
  allowed_action_ids TEXT[],  -- 허용된 매크로/플레이북 ID 배열
  issued_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  status TEXT DEFAULT 'active'  -- active, consumed, expired, revoked
);
```

### 5.3 diagnostic_jobs (진단 작업)
```sql
CREATE TABLE diagnostic_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_event_id UUID REFERENCES issue_events(id),
  approval_token_id UUID REFERENCES approval_tokens(id),
  started_at TIMESTAMPTZ DEFAULT now(),
  ended_at TIMESTAMPTZ,
  status TEXT,  -- running, completed, failed
  root_cause_candidates JSONB,  -- [{cause, confidence, evidence}]
  recommended_actions JSONB,  -- [{playbook_id, risk_level}]
  raw_result JSONB
);
```

### 5.4 recovery_jobs (복구 작업)
```sql
CREATE TABLE recovery_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  diagnostic_job_id UUID REFERENCES diagnostic_jobs(id),
  playbook_id UUID REFERENCES playbooks(id),
  approval_token_id UUID REFERENCES approval_tokens(id),
  started_at TIMESTAMPTZ DEFAULT now(),
  ended_at TIMESTAMPTZ,
  status TEXT,  -- running, completed, failed, rolled_back
  step_results JSONB,  -- [{step, status, output, duration_ms}]
  verification_result JSONB
);
```

### 5.5 audit_logs (감사 로그)
```sql
CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_type TEXT NOT NULL,  -- viewer, host, system
  actor_id TEXT NOT NULL,
  host_id TEXT,
  session_id UUID,
  action_type TEXT NOT NULL,  -- issue_detected, approval_granted, diagnostic_run, ...
  action_detail JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### 5.6 macros / playbooks 컬럼 추가
```sql
ALTER TABLE macros ADD COLUMN required_approval_level INT DEFAULT 2;
ALTER TABLE playbooks ADD COLUMN required_approval_level INT DEFAULT 2;
ALTER TABLE playbooks ADD COLUMN risk_level TEXT DEFAULT 'medium';
ALTER TABLE playbooks ADD COLUMN preconditions JSONB;
ALTER TABLE playbooks ADD COLUMN success_criteria JSONB;
ALTER TABLE playbooks ADD COLUMN rollback_steps JSONB;
```

---

## 6. 필요한 메시지 타입 신규

### 6.1 Host → Server
- `issue.detected` — 이상 감지 알림
- `diagnostic.progress` — 진단 진행률
- `diagnostic.result` — 진단 결과 (root_cause_candidates 포함)
- `recovery.progress` — 복구 단계별 진행
- `recovery.result` — 복구 완료 결과
- `verification.result` — 복구 후 검증 결과

### 6.2 Viewer → Server
- `approve.diagnostic` — 진단 승인 (issue_id, scope_level)
- `approve.recovery` — 복구 승인 (diagnostic_id, playbook_id, scope_level)
- `cancel.operation` — 진행 중 작업 취소
- `request.manual_mode` — 수동 제어 전환 요청

### 6.3 Server → Host
- `run.diagnostic` — 진단 실행 지시 (approval_token 포함)
- `run.recovery` — 복구 실행 지시 (approval_token 포함)
- `abort.operation` — 작업 중단 지시

---

## 7. 구현 로드맵 (권장 순서)

### Phase A: 기반 인프라 (1주)
1. DB 스키마 생성 (issue_events, approval_tokens, diagnostic_jobs, recovery_jobs, audit_logs)
2. 기존 macros/playbooks에 required_approval_level, risk_level 컬럼 추가
3. Shared 메시지 타입 추가
4. 서버 측 REST API 및 WebSocket 핸들러 스켈레톤

### Phase B: 이슈 → 승인 플로우 (1주)
1. 호스트: Detector 모듈 (이상 이벤트 생성)
2. 서버: 승인 토큰 발급/검증 로직
3. 뷰어: 승인 카드 UI (Flutter + Web)
4. 이슈 상태 전환 흐름 (detected → acknowledged → diagnosed → recovered)

### Phase C: 진단 실행 (1주)
1. 호스트: Diagnostic Runner 모듈 (승인 가드 포함)
2. 호스트: 이슈 카테고리별 진단 항목 매핑
3. 뷰어: 진단 진행률 + 결과 상세 UI
4. 서버: 진단 작업 이력 저장

### Phase D: 복구 실행 + 검증 (1주)
1. 플레이북 스키마 확장 (preconditions, success_criteria, rollback_steps)
2. 호스트: Playbook Runner의 pre-check/post-check/rollback 지원
3. Verifier 모듈 (복구 후 자동 재진단)
4. 뷰어: 복구 승인 UI + 결과 리포트 UI

### Phase E: 감사 + 정책 (1주)
1. 감사 로그 영속화 (모든 승인/실행/결과)
2. 서버 측 명령 allowlist 검증
3. 뷰어: 감사 로그 열람 UI
4. 민감 정보 마스킹 로직

### Phase F: 플레이북 1차 세트 (PLAN.md 섹션 14)
1. 네트워크 기본 진단
2. DNS 장애 진단/복구
3. 앱 무응답 진단/재실행
4. 필수 서비스 중지 복구
5. 디스크 부족 안전 정리
6. 에이전트 통신 복구
7. 화면 캡처 모듈 복구
8. CPU/메모리 과부하 원인 프로세스 진단
9. 로그인 세션 이상 진단
10. 원격제어 권한 상태 진단

**총 예상 공수**: 5~6주 (Phase A~F)

---

## 8. AI Assistant 통합 (PLAN.md 요청 사항)

> "뷰어의 ai assistant에서 진행/승인/결과 등 모든 정보를 보여줘"

현재 AI 어시스턴트 패널 구조 활용 방안:

- **AI 탭**: 기존 Kimi 챗 + 이슈 발생 시 시스템 메시지 카드 삽입
- **진단 카드**: 인라인 "상세 진단 실행" 버튼
- **결과 카드**: 원인 후보 + 권장 복구 리스트
- **복구 카드**: 각 액션별 재승인 버튼
- **로그 뷰**: 우측 하단 토글로 상세 로그 펼침

AI 어시스턴트가 **진단 안내자** 역할을 수행:
```
[AI] 🔴 CPU 과부하 감지됨 (98% 3분 지속)
     상세 진단을 실행할까요?
     예상 수행: 프로세스 목록 조회, 서비스 상태 확인
     ↳ [진단 승인] [무시] [수동 지원]

[사용자 승인 후]

[AI] 진단 결과:
     원인 1: chrome.exe가 80% 점유 (신뢰도 85%)
     권장 복구:
     1. chrome 프로세스 강제 종료 [위험도: 중간, Level 3]
     2. chrome 정상 재시작 [위험도: 낮음, Level 2]
     ↳ [권장 복구 실행] [개별 선택] [수동]
```

---

## 9. 보안 고려사항

PLAN.md 섹션 11 원칙에 맞춰 다음이 **필수 구현 사항**:

- ✅ **최소 권한**: 호스트 에이전트는 허용된 플레이북만 실행
- ✅ **명령 allowlist**: 뷰어에서 임의 쉘 명령 입력 불가 (현재는 매크로 DB 기반이라 OK)
- ❌ **승인 토큰 TTL**: 현재 없음 → 5분 TTL 권장
- ❌ **세션 바인딩**: 승인은 세션/호스트/이슈에만 유효 → 구현 필요
- ❌ **감사 로그 강제**: 모든 액션 기록 → 구현 필요
- ❌ **민감정보 마스킹**: 비밀번호/토큰/키 자동 마스킹 → 구현 필요

---

## 10. 결론 및 권장사항

### 10.1 현재 시스템의 강점
- 매크로/플레이북 DB 기반 관리 시스템이 이미 구축됨
- DataChannel을 통한 실시간 명령 전송 파이프라인 안정적
- 자동 진단 엔진 (뷰어 측) 이미 동작 중
- 30개의 시드 매크로 및 예제 플레이북 존재

### 10.2 주요 공백
1. **이슈 생명주기 관리 부재** — 이상 감지 후 처리 흐름이 없음
2. **승인 모델 부재** — 모든 명령이 즉시 실행되는 구조
3. **감사 추적 부재** — 책임 소재 확인 불가
4. **검증 단계 부재** — 복구 후 결과 확인 로직 없음

### 10.3 즉시 착수 권장 순서 (우선순위)

| 우선순위 | 작업 | 예상 공수 | 영향 |
|---------|------|----------|------|
| **P0** | DB 스키마 확장 (5개 신규 테이블) | 반일 | 모든 후속 작업의 기반 |
| **P0** | approval_tokens 발급/검증 로직 | 1일 | 보안 강화 |
| **P1** | 이슈 이벤트 생명주기 | 2일 | 워크플로우 자동화 |
| **P1** | 뷰어 승인 카드 UI | 2일 | 사용자 경험 핵심 |
| **P2** | Playbook pre/post-check/rollback | 2일 | 복구 안정성 |
| **P2** | 감사 로그 + 마스킹 | 1일 | 규제 대응 |
| **P3** | 1차 플레이북 10종 | 3일 | 실전 활용도 |

**MVP 최소 기간**: P0+P1 (1주) → 기본 승인 플로우 동작
**풀셋 완성**: P0~P3 (3~4주)

### 10.4 기술 스택 권장

PLAN.md 섹션 13 기술 권장과 현 시스템 비교:

| 요소 | PLAN.md | 현재 | 유지/변경 |
|------|---------|------|-----------|
| 호스트 에이전트 | Windows 서비스 + 보조 프로세스 | Flutter Windows 데스크톱 | 유지 (서비스화는 나중에) |
| 서버 | Session Orchestrator + Policy + Approval + Job Queue + Audit | Node.js 단일 서버 | 유지 (모놀리식 확장) |
| 메타데이터 저장소 | PostgreSQL | Supabase PostgreSQL | ✅ 그대로 |
| 실시간 상태 | Redis | 메모리 + DataChannel | Redis는 아직 불필요 |
| 오브젝트 저장소 | S3/GCS | Supabase Storage 또는 로컬 파일 | 현재 로컬 유지 |

**결론**: 현재 기술 스택으로 PLAN.md 구현 가능. 별도 인프라 투자 불필요.

---

## 11. 제안

**1회 세션 구현은 무리**이므로 다음 접근을 권장합니다:

### Option 1: MVP만 (추천)
- Phase A + B의 핵심만 (DB + 승인 토큰 + 이슈 카드 UI)
- 2~3일 집중 작업으로 "승인 기반 매크로 실행" 데모 가능
- 이후 점진적으로 확장

### Option 2: 프레임워크만
- DB 스키마 + 메시지 타입 + 서버 API 스켈레톤만 구축
- UI/실제 로직은 후속 작업

### Option 3: 문서화 우선 (현재 선택)
- 이 분석 보고서 완성 + 상세 설계서 작성
- 구현은 후속 세션에서 단계별로 진행

---

**작성자**: Claude Opus 4.6
**참고 문서**:
- `remote-desktop/PLAN.md` (원본 요구사항)
- `docs/chat-design.md` (채팅 설계 참고)
- 기존 매크로/플레이북 구현 (`macro-manager.ts`, `playbook-manager.ts`)
