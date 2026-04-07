---
name: WebRTC 원격 데스크톱 프로젝트
description: WebRTC P2P 기반 원격 데스크톱 제어 시스템 — 뷰어/호스트 모듈, 시그널링 서버 포함
type: project
---

프로젝트 경로: D:\vibecoding\AIagent (기존 todo-app과 별도 모듈로 설계)
요청일: 2026-04-06

핵심 구성요소: 뷰어 모듈, 호스트 모듈, 시그널링 서버(WebSocket)
기술 선택 검토 대상: Electron vs 순수 웹 vs Node.js 네이티브
주요 관심사: 화면 캡처 방식, 입력 제어, NAT 통과, 보안 인증

**Why:** 실시간 P2P 원격 제어가 목표이므로 WebRTC DataChannel + MediaStream 조합이 핵심
**How to apply:** 구현 순서는 시그널링 서버 -> 호스트 -> 뷰어 순으로 제안할 것
