---
name: remote-desktop Phase 1~5
description: WebRTC 원격 데스크톱 제어 시스템 Phase 1~5 - 모노레포 구조, 시그널링 서버, 뷰어 앱, 호스트 Electron 앱, 뷰어 주도 화면 소스 선택 구현 현황
type: project
---

pnpm workspace 모노레포로 Phase 1~4 구현 완료 (2026-04-06).

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

Phase 3 - 뷰어 웹 앱 (packages/viewer-app):
- Vite + TypeScript, 개발 서버 포트 3000
- tsconfig moduleResolution: bundler (Vite 호환, NodeNext 아님)
- vite.config.ts에서 @remote-desktop/shared를 shared/src/index.ts로 alias (빌드 없이 직접 참조)
- RTCDataChannel ordered:true 단일 채널 (input 채널)
- IME compositionend 이벤트로 한/영/일/중 다국어 입력 처리
- video 요소 tabindex="0" + crosshair cursor
- 기동: pnpm --filter @remote-desktop/viewer-app dev
