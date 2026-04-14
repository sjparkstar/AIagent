---
name: remote-desktop Phase 1~7
description: WebRTC 원격 데스크톱 제어 시스템 Phase 1~7 - 모노레포 구조, 시그널링 서버, 뷰어 앱, 호스트 Electron 앱, 뷰어 주도 화면 소스 선택, AI 어시스턴트 사이드 패널, Flutter 뷰어 앱 구현 현황
type: project
---

pnpm workspace 모노레포로 Phase 1~6 구현 완료 (2026-04-06).

Phase 7 - Flutter 뷰어 앱 (packages/viewer-app-flutter, 2026-04-07):
- flutter create --org com.remotecall --project-name viewer_app_flutter
- 의존성: flutter_webrtc ^1.4.1, web_socket_channel ^3.0.3, supabase_flutter ^2.8.4, http ^1.2.2
- PointerScrollEvent는 package:flutter/gestures.dart import 필요 (material.dart만으로는 부족)
- 기본 생성된 test/widget_test.dart는 MyApp 참조 → ViewerApp으로 교체하거나 placeholder test로 교체 필수 (analyze 오류 원인)
- 파일 구조:
  - lib/main.dart — ViewerApp, onGenerateRoute (/, /waiting)
  - lib/app_theme.dart — 색상 상수 + buildAppTheme()
  - lib/signaling.dart — ViewerSignaling (register/sendOffer/sendIceCandidate + 콜백)
  - lib/peer_connection.dart — ViewerPeerConnection (startOffer/setAnswer/addIceCandidate/sendMessage)
  - lib/screens/dashboard_screen.dart — Supabase 통계 + 세션 이력
  - lib/screens/waiting_screen.dart — 접속번호 표시 + 호스트 대기
  - lib/screens/streaming_screen.dart — RTCVideoView + Listener 입력 캡처 + AI 어시스턴트 패널
  - lib/services/supabase_service.dart — SupabaseService 싱글톤 (loadStats/loadRecentSessions/startSession/endSession)
  - lib/services/assistant_service.dart — document_chunks ILIKE 검색 + HTTP LLM 프록시
- 뷰어가 offer 생성, 호스트가 answer 반환 (기존 프로토콜과 동일)
- DataChannel: negotiated:true, id:0, ordered:true

위치: d:\vibecoding\AIagent\remote-desktop\

**Why:** 뷰어는 순수 웹 브라우저, 호스트 1:N 구조, 시그널링 서버는 VPS 배포 예정.

**How to apply:** 추가 Phase 작업 시 packages/ 하위에 신규 패키지 추가.

Phase 1 - 시그널링 서버 (packages/signaling-server):
- bcrypt → bcryptjs 교체 (로컬 환경 node-gyp 빌드 도구 없음)
- WebSocket + HTTP 서버를 동일 포트에서 처리 (ws 라이브러리 + http.createServer)
- pnpm-workspace.yaml에 allowBuilds: bcrypt: true, esbuild: true 설정 필요
- 서버 기동 명령: node packages/signaling-server/dist/index.js (PORT 8080)
- 헬스체크: GET http://localhost:8080/health

Phase 4 - 호스트 Electron 앱 (packages/host-app):
- electron-vite 2.x + TypeScript, electron 31
- @jitsi/robotjs (원본 robotjs의 Node 22 대응 포크) → pnpm-workspace.yaml allowBuilds에 추가
- 파일 구조: src/main/, src/preload/, src/renderer/ (electron-vite 관례)
  - preload는 반드시 src/preload/index.ts에 위치 (electron-vite 자동 탐지 경로)
  - src/main/preload.ts로 두면 electron-vite가 preload entry를 못 찾음
- HostAPI 타입은 src/shared-types.ts로 분리 (main/preload/renderer 공유)
- tsconfig.node.json / tsconfig.web.json 이중 tsconfig (rootDir: "../../" 로 shared 소스 포함)
- 렌더러에서 비밀번호 해시: bcryptjs 대신 Web Crypto API (crypto.subtle.digest SHA-256)
  - 시그널링 서버가 passwordHash를 받아서 bcrypt 재해시하므로 어떤 문자열이든 허용
- 화면 캡처: desktopCapturer → getUserMedia chromeMediaSource: 'desktop'
- 입력 주입: @jitsi/robotjs, 다국어 텍스트는 클립보드 경유 Ctrl+V 시뮬레이션
- 빌드 출력: packages/host-app/out/ (main/preload/renderer 분리)
- 기동 명령: pnpm --filter @remote-desktop/host-app dev

Phase 5 - 뷰어 주도 화면 소스 선택 (2026-04-06):
- shared/messages.ts에 ControlMessage (screen-sources, switch-source, source-changed) + DataChannelMessage 유니온 추가
- shared 수정 후 반드시 pnpm --filter @remote-desktop/shared build 실행
- host peer-manager.ts: peers Map 값을 {pc, dc} 구조체로 변경, sendToViewer/broadcastToViewers/replaceVideoTrack 메서드 추가
  - DataChannel onopen 시 hostAPI.getScreenSources()로 소스 목록을 해당 뷰어에게 전송
  - DataChannel onmessage에서 switch-source 수신 시 onSwitchSource 콜백 호출
- host app.ts: room-info 수신 즉시 자동으로 첫 번째 소스로 공유 시작, 수동 소스 선택 UI 제거
  - switchSource() 함수: 새 스트림 캡처 → replaceVideoTrack → broadcastToViewers(source-changed)
- viewer peer.ts: DataChannel onmessage 추가, control-message 이벤트를 PeerEventMap에 추가
  - sendMessage(msg) 메서드로 DataChannel로 메시지 전송
- viewer ui.ts: updateScreenSources(), setActiveMonitor(), setOnMonitorClick() 메서드 추가
  - monitorButtons 컨테이너 참조, 동적 버튼 생성
- viewer index.html: status-right 내부에 <div id="monitor-buttons"> 추가
- viewer style.css: .monitor-btn, .monitor-btn.active 스타일 추가
- viewer tsconfig.json: "types": ["vite/client"] 추가 (import.meta.hot 타입 해소)

Phase 6 - AI 어시스턴트 사이드 패널 (2026-04-06):
- stream-screen을 stream-main(flex-row) + video-area + assistant-panel(width:380px)으로 재구성
- 신규 파일: src/assistant-search.ts (Supabase document_chunks ILIKE 검색)
- 신규 파일: src/assistant-widget.ts (window.open 팝업 분리, setInterval 폴링으로 닫힘 감지)
- ui.ts: MessageType 타입 추가, 어시스턴트 DOM 참조 9개 추가
  - addAssistantMessage(type, text), addLoadingMessage(), toggleAssistantPanel(), setAssistantPanelVisible(visible) 메서드 추가
- main.ts: handleAssistantSearch() async 함수 — user 메시지 → 로딩 → searchDocuments → 결과 표시
- index.html: assistant-panel 구조 (헤더+위젯분리버튼+접기버튼 / 호스트명령바 / 메시지영역 / 입력바)
  - status-bar에 #assistant-open-btn 추가 (패널 접힌 상태에서 복원)
- 호스트 명령 바 및 아이콘 버튼은 UI만 구현, 클릭 시 "추후 구현 예정" system 메시지 표시
- CSS: .stream-main, .video-area, .assistant-panel, 메시지 버블, 로딩 점 애니메이션 추가

Phase 3 - 뷰어 웹 앱 (packages/viewer-app):
- Vite + TypeScript, 개발 서버 포트 3000
- tsconfig moduleResolution: bundler (Vite 호환, NodeNext 아님)
- vite.config.ts에서 @remote-desktop/shared를 shared/src/index.ts로 alias (빌드 없이 직접 참조)
- RTCDataChannel ordered:true 단일 채널 (input 채널)
- IME compositionend 이벤트로 한/영/일/중 다국어 입력 처리
- video 요소 tabindex="0" + crosshair cursor
- 기동: pnpm --filter @remote-desktop/viewer-app dev
