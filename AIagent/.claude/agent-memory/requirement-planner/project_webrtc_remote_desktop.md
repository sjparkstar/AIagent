---
name: WebRTC 원격 데스크톱 프로젝트
description: RemoteCall-mini — WebRTC P2P 원격 제어 + 화면 녹화/PDF 요약 기능 추가 중
type: project
---

프로젝트 경로: D:\vibecoding\AIagent\remote-desktop
패키지 구성: viewer-app (Vite+TS), signaling-server (Node.js HTTP+WS), shared, host-app, host-app-flutter

현재 구현 상태:
- WebRTC P2P 연결, 화면 스트리밍, 입력 제어 완성
- Supabase (connection_sessions, assistant_logs 테이블) 연동 완성
- AI 어시스턴트 (Kimi/moonshot-v1-128k) 연동 완성
- 대시보드 + 세션 상세 모달 구현 완성
- 매크로/플레이북 기능 구현 완성

2026-04-10 신규 기능 요청:
1. 화면 녹화 (MediaRecorder API, WebM, 뷰어 측 녹화)
2. 녹화파일 관리 (Supabase Storage 저장 + 세션 상세에서 다운로드/스트리밍)
3. PDF 요약 (상담사가 버튼 클릭 → 프레임 캡처 + AI 텍스트 요약 → PDF 생성 → 세션에 PDF 링크 추가)

핵심 기술 결정 사항:
- 녹화: 브라우저 MediaRecorder로 WebRTC MediaStream 직접 녹화 (별도 스트림 불필요)
- 저장: Supabase Storage (recordings 버킷) — 서버 저장소 대신 Supabase 선택
- DB 확장: connection_sessions에 recording_url, pdf_url 컬럼 추가
- PDF: jsPDF 라이브러리 + Canvas로 프레임 캡처, Kimi LLM으로 텍스트 요약 생성
- 시그널링 서버에 /api/summarize-session 엔드포인트 추가 필요

**Why:** 원격 상담 이력 관리 및 품질 관리 목적
**How to apply:** 녹화 → 저장 → PDF 순서로 Phase 분리. viewer-app 변경 최소화 원칙 유지

2026-04-10 채팅 기능 설계 결정:
- 통신: 시그널링 서버 WebSocket 경유 (호스트/뷰어 이미 연결됨, 그룹 채팅 지원)
- 저장: 하이브리드 — 세션 중 Room 메모리 보관, 세션 종료 시 Supabase connection_sessions.chat_log (JSONB) 일괄 저장
- 인증: roomId + viewerId 그대로 확장, 서버에서 senderId 강제 주입 (클라이언트 신뢰 안 함)
- 읽음 처리: lastReadTimestamp 방식 (개별 메시지 읽음 불필요)
- 추가 필요: shared/messages.ts에 chat 타입, Room 인터페이스에 chatLog 배열, SIGTERM graceful shutdown에 chatLog flush
