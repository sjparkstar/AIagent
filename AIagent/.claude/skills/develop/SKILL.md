---
name: develop
description: "서브에이전트를 활용한 기능 구현 워크플로우. 요구사항 분석 → 코드베이스 탐색 → 구현 → 검증까지 전체 개발 파이프라인을 자동 실행한다. 사용자가 기능 구현, 버그 수정, 리팩터링 등 개발 작업을 요청할 때 이 스킬을 사용한다. /develop 명령으로 실행하며, '구현해줘', '만들어줘', '수정해줘', '추가해줘' 등의 요청에도 반드시 트리거한다."
user_invocable: true
---

# /develop - 기능 구현 워크플로우

사용자가 `/develop` 뒤에 요구사항을 입력하면 아래 워크플로우를 실행한다.

**모든 설명과 안내는 반드시 한국어로 작성한다.**

## 실행 규칙

- `.claude/skills/code.rules.md`의 코딩 규칙을 먼저 읽고 적용한다
- 서브에이전트 사용 시 반드시 이전 단계의 결과를 컨텍스트로 전달한다
- 독립적인 작업은 에이전트를 병렬로 실행한다
- 최소 수정 원칙: 기존 코드를 존중하고, 요청된 기능만 구현한다
- **Serena MCP 도구를 적극 활용한다** (아래 Serena 활용 가이드 참조)

## 워크플로우

### Phase 1: 요구사항 분석
- 요구사항이 모호하거나 고수준이면 → `requirement-planner` 에이전트(subagent_type=requirement-planner)로 요구사항 구체화 + 실행 계획 수립
- 요구사항이 명확하면 → Phase 2로 바로 진행

### Phase 2: 코드베이스 탐색
- `Explore` 에이전트(subagent_type=Explore)로 관련 파일, 기존 패턴, 프로젝트 구조 파악
- **Serena MCP 활용**: 심볼 검색(`serena_search_symbols`), 정의 찾기(`serena_find_definition`), 참조 찾기(`serena_find_references`)로 코드 관계를 시맨틱하게 분석
- 변경 대상 파일과 영향 범위를 식별

### Phase 3: 구현
- `senior-code-architect` 에이전트(subagent_type=senior-code-architect)로 코드 구현
- 에이전트에게 전달할 정보:
  - Phase 1의 요구사항/계획
  - Phase 2에서 파악한 프로젝트 구조, 관련 파일 경로, 기존 패턴
  - `.claude/skills/code.rules.md`의 코딩 규칙
- **Serena MCP 활용**: 심볼 수준 편집(`serena_edit_symbol`)으로 함수/클래스 단위 정밀 수정, 파일 전체를 건드리지 않고 타겟 수정 수행
- 구현 완료 후 빌드/타입 체크 수행

### Phase 4: 검증
- **Serena MCP 활용**: 진단(`serena_get_diagnostics`)으로 코드 오류/경고 확인, 참조 찾기로 변경의 영향 범위 검증
- 코드 품질 검토: 중복, 불필요한 복잡성, 보안 취약점 확인
- 테스트 가능한 경우 테스트 명령 제안
- 변경 사항 요약을 사용자에게 보고

## Serena MCP 활용 가이드

Serena MCP는 LSP 기반 시맨틱 코드 분석 도구로, 각 Phase에서 다음과 같이 활용한다:

| Phase | Serena 도구 | 용도 |
|-------|------------|------|
| Phase 2 (탐색) | `serena_search_symbols` | 함수/클래스/변수를 이름으로 검색 |
| Phase 2 (탐색) | `serena_find_definition` | 심볼의 정의 위치 탐색 |
| Phase 2 (탐색) | `serena_find_references` | 심볼이 사용되는 모든 위치 탐색 |
| Phase 3 (구현) | `serena_edit_symbol` | 함수/클래스 단위 정밀 코드 수정 |
| Phase 3 (구현) | `serena_get_symbol_content` | 특정 심볼의 전체 내용 확인 |
| Phase 4 (검증) | `serena_get_diagnostics` | 코드 오류/경고/린트 문제 확인 |
| Phase 4 (검증) | `serena_find_references` | 변경된 심볼의 영향 범위 검증 |

**활용 원칙:**
- Grep/Glob 같은 텍스트 검색보다 Serena의 시맨틱 검색을 우선 사용한다
- 코드 수정 시 파일 전체가 아닌 심볼 단위 편집을 선호한다
- 구현 완료 후 반드시 `serena_get_diagnostics`로 오류 여부를 확인한다
- Serena MCP 연결 실패 시 기존 도구(Grep, Glob, Read, Edit)로 폴백한다

## 사용 예시

```
/develop 사용자 로그인 기능을 추가해줘
/develop REST API로 게시판 CRUD를 만들어줘
/develop 뷰어에서 호스트 화면이 안보이는 버그를 수정해줘
```
