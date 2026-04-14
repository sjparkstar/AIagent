# RemoteCall-mini

WebRTC 기반 원격 데스크톱 시스템 + AI 어시스턴트 + 자동 진단/매크로 실행 플랫폼

## 아키텍처

```
┌─────────────┐     WebSocket      ┌──────────────────┐     WebSocket      ┌──────────────┐
│   Viewer    │◄──────────────────►│  Signaling Server │◄──────────────────►│   Host App   │
│  (Browser)  │     Signaling      │   (Node.js)       │     Signaling      │  (Electron)  │
│             │                    │                    │                    │              │
│             │◄═══════════════════╪════════════════════╪═══════════════════►│              │
│             │     WebRTC P2P     │  /api/assistant-   │     WebRTC P2P     │              │
│             │   DataChannel +    │  chat (LLM Proxy)  │   DataChannel +    │              │
│             │   Video Stream     │                    │   Video Stream     │              │
└──────┬──────┘                    └────────────────────┘                    └──────────────┘
       │
       │  Supabase (DB)
       ▼
┌──────────────────┐
│  documents       │  고객지원 도움말 검색
│  document_chunks │  벡터 임베딩
│  connection_     │  세션 히스토리
│    sessions      │
│  assistant_logs  │  AI 대화 기록
│  macros          │  매크로 관리
│  playbooks       │  플레이북 관리
└──────────────────┘
```

## 패키지 구조

```
remote-desktop/
├── packages/
│   ├── shared/              # 공통 타입, 메시지, Supabase 클라이언트
│   ├── signaling-server/    # WebSocket 시그널링 + LLM API 프록시
│   ├── host-app/            # Electron 호스트 (화면 공유, 입력 제어)
│   └── viewer-app/          # 브라우저 뷰어 (대시보드, AI 어시스턴트)
└── sql/                     # Supabase 테이블 생성 스크립트
```

## 주요 기능

### 원격 데스크톱
- WebRTC P2P 화면 공유 (비디오 스트리밍)
- 마우스/키보드 원격 제어 (DataChannel)
- 다중 모니터 전환
- 자동 재연결 (30초 타임아웃)

### AI 어시스턴트
- Supabase `documents` 테이블에서 키워드 검색 (OR 단어 분리)
- 검색 결과를 LLM(Kimi/Moonshot)이 정리하여 답변
- 내부 문서에 없으면 LLM 일반 지식으로 답변
- 위젯 모드 (별도 팝업 창)
- 대화 로그 DB 기록

### 호스트 시스템 진단
- 3초 단위 실시간 시스템 정보 수집 (OS/CPU/메모리/디스크/배터리/네트워크)
- OS별 수집 (Windows: wmic/ipconfig/netsh, macOS: pmset/airport, Linux: df/iwgetid)
- 프로세스 CPU Top 5 (두 번 샘플링 방식)
- 자동 진단 엔진 (CPU 과부하, 메모리 부족, 디스크 부족, 인터넷 불가, DNS 오류 등)
- 진단 결과를 AI 어시스턴트에 실시간 알림 배너로 표시

### 매크로 실행
- Supabase `macros` 테이블에서 매크로 CRUD 관리
- 뷰어에서 호스트로 DataChannel을 통해 명령 전송/실행
- PowerShell EncodedCommand 방식으로 안전한 명령 전달
- 실행 확인 팝업 + AI 어시스턴트에 결과 표시

### 플레이북
- Supabase `playbooks` 테이블에서 시퀀스 CRUD 관리
- 단계별 순차 실행 + 조건 검증 (`validateContains`)
- AI 어시스턴트에 단계별 진행 상태 표시

### 대시보드
- 통계 카드 (총 세션, 오늘 세션, 평균 시간, 평균 RTT)
- 최근 상담 이력 (클릭 시 세션 상세 모달)
- 매크로/플레이북 관리 (추가/수정/삭제)
- "상담 연결" → 새 탭에서 세션 시작

## 설치 및 실행

### 사전 요구사항
- Node.js 20+
- pnpm 10+

### 설치

```bash
cd remote-desktop
pnpm install
pnpm --filter @remote-desktop/shared build
```

### 환경 변수

`packages/signaling-server/.env`:
```
OPENAI_API_KEY=sk-...     # 또는
KIMI_API_KEY=sk-...        # Kimi(Moonshot) API 키
```

### 실행

```bash
# 1. 시그널링 서버
cd packages/signaling-server
pnpm dev

# 2. 뷰어 (브라우저)
cd packages/viewer-app
pnpm dev

# 3. 호스트 (Electron)
cd packages/host-app
pnpm dev
```

### Supabase 테이블 생성

Supabase SQL Editor에서 순서대로 실행:
```
sql/create_connection_sessions.sql
sql/create_assistant_logs.sql
sql/create_macros.sql
sql/create_playbooks.sql
```

## 기술 스택

| 영역 | 기술 |
|------|------|
| 호스트 앱 | Electron, TypeScript, esbuild |
| 뷰어 앱 | TypeScript, Vite |
| 시그널링 서버 | Node.js, ws, dotenv |
| 실시간 통신 | WebRTC (PeerConnection, DataChannel) |
| 데이터베이스 | Supabase (PostgreSQL) |
| LLM | Kimi (Moonshot AI) / OpenAI 호환 |
| 스타일 | CSS Variables, Dark Theme |

## DataChannel 메시지 타입

| 타입 | 방향 | 설명 |
|------|------|------|
| `screen-sources` | Host→Viewer | 화면 소스 목록 + 활성 소스 ID |
| `switch-source` | Viewer→Host | 모니터 전환 요청 |
| `source-changed` | Host→Viewer | 모니터 전환 완료 알림 |
| `host-info` | Host→Viewer | 기본 시스템 정보 (5초 주기) |
| `host-diagnostics` | Host→Viewer | 상세 진단 정보 (5초 주기) |
| `execute-macro` | Viewer→Host | 매크로 실행 요청 |
| `macro-result` | Host→Viewer | 매크로 실행 결과 |

## 라이선스

Private
