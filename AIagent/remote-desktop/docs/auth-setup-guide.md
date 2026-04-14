# 뷰어 로그인 — Supabase 콘솔 설정 가이드

이 문서는 [create_auth_schema.sql](../sql/create_auth_schema.sql) 적용 후 Supabase 콘솔에서 수동으로 진행해야 하는 설정을 정리한 것이다.

## 0. 사전 준비

- Supabase 프로젝트 URL: `https://xrvbktzsxtgadrcwhxkl.supabase.co`
- 콘솔 URL: <https://supabase.com/dashboard/project/xrvbktzsxtgadrcwhxkl>

## 1. SQL 스키마 적용

1. 콘솔 좌측 메뉴 → **SQL Editor** → **+ New query**
2. [create_auth_schema.sql](../sql/create_auth_schema.sql) 전체 내용 붙여넣기
3. **Run** 클릭 → 에러 없이 완료되는지 확인
4. **Table Editor**에서 `profiles`, `passkey_credentials`, `webauthn_challenges` 테이블 생성 확인

## 2. 이메일 인증 활성화

1. 콘솔 → **Authentication** → **Providers** → **Email**
2. 다음 옵션 설정:
   - ✅ **Enable Email provider**
   - ✅ **Confirm email** (인증 메일 클릭해야 로그인 가능)
   - ❌ Secure email change (선택)
   - **Minimum password length**: `8`
3. **Save**

### 이메일 템플릿 한국어화 (선택)

**Authentication → Email Templates → Confirm signup**:

```html
<h2>RemoteCall-mini 가입을 환영합니다</h2>
<p>아래 버튼을 눌러 이메일 인증을 완료해주세요.</p>
<p><a href="{{ .ConfirmationURL }}">이메일 인증하기</a></p>
<p>이 메일을 요청하지 않으셨다면 무시하세요.</p>
```

다른 템플릿(`Reset Password`, `Magic Link` 등)도 동일 패턴으로 변경 가능.

## 3. 리다이렉트 URL 등록

**Authentication → URL Configuration**:

- **Site URL**: 운영 도메인 (예: `https://viewer.example.com`)
- **Redirect URLs** (한 줄씩 추가):
  ```
  http://localhost:5173/**
  http://localhost:5173/auth/callback
  http://localhost:8080/auth/callback
  remotecall://auth/callback
  ```
  - `localhost:5173`: Vite dev 서버 (웹 뷰어)
  - `localhost:8080`: 시그널링 서버 (콜백 중계)
  - `remotecall://`: Flutter/Electron 커스텀 프로토콜

## 4. 환경변수 설정

### 시그널링 서버 — `.env`

```env
# 기존 변수
SUPABASE_URL=https://xrvbktzsxtgadrcwhxkl.supabase.co
SUPABASE_ANON_KEY=sb_publishable_aL9Oh6wdJEdE_xO8lC3hHA_yx-ac2YQ

# 신규 추가
SUPABASE_SERVICE_ROLE_KEY=<콘솔 → Settings → API → service_role 키>
SUPABASE_JWT_SECRET=<콘솔 → Settings → API → JWT Secret>

# WebAuthn (패스키) RP 설정
WEBAUTHN_RP_NAME=RemoteCall-mini
WEBAUTHN_RP_ID=localhost          # 운영 시: viewer.example.com
WEBAUTHN_ORIGIN=http://localhost:5173  # 운영 시: https://viewer.example.com
```

> ⚠️ **service_role 키는 절대 클라이언트에 노출하면 안 됨**. 서버 환경변수로만 사용.

### 웹 뷰어 — `.env` (Vite는 `VITE_` 접두사 필요)

```env
VITE_SUPABASE_URL=https://xrvbktzsxtgadrcwhxkl.supabase.co
VITE_SUPABASE_ANON_KEY=sb_publishable_aL9Oh6wdJEdE_xO8lC3hHA_yx-ac2YQ
VITE_SIGNALING_URL=ws://localhost:8080
```

### Flutter 뷰어 — `--dart-define`로 빌드/실행 시 주입

```bash
flutter run -d windows \
  --dart-define=SUPABASE_URL=https://xrvbktzsxtgadrcwhxkl.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_aL9Oh6wdJEdE_xO8lC3hHA_yx-ac2YQ \
  --dart-define=SIGNALING_URL=ws://localhost:8080
```

## 5. 패스키(WebAuthn) RP 정책

WebAuthn은 **RP ID가 도메인과 일치**해야 동작한다.

| 환경 | RP_ID | ORIGIN |
|------|-------|--------|
| 로컬 개발 (웹) | `localhost` | `http://localhost:5173` |
| 운영 (웹) | `viewer.example.com` | `https://viewer.example.com` |
| Electron 데스크톱 | `localhost` (파일 프로토콜은 패스키 미지원, 내장 서버 통해 우회) | `http://localhost:PORT` |
| Flutter Windows/macOS | 네이티브 OS API 사용. RP_ID는 서버와 동일하게 설정. |

> 📌 Electron의 `file://` 프로토콜에서는 WebAuthn이 동작하지 않으므로, Electron이 내부적으로 작은 HTTP 서버를 띄우거나, Renderer를 `http://localhost:PORT`에서 제공해야 한다. 향후 6단계에서 처리.

## 6. 적용 후 점검 (체크리스트)

- [ ] SQL 스크립트 실행 완료
- [ ] `profiles`, `passkey_credentials`, `webauthn_challenges` 테이블 생성 확인
- [ ] Email confirm 활성화 확인 (Supabase Auth 설정)
- [ ] Redirect URLs 등록
- [ ] 시그널링 서버 `.env`에 service_role / JWT_SECRET / WEBAUTHN_* 추가
- [ ] 웹 뷰어 / Flutter 뷰어에 env 전달 방식 정해짐

## 7. 이후 단계

설정 완료 후 다음 단계로 진행:

- **3단계**: LoginScreen / SignupScreen + 이메일/비번 동작 (양쪽 뷰어)
- **4단계**: AuthGuard + 시그널링 서버 WS JWT 검증
- **5단계**: 시그널링 서버에 패스키 엔드포인트 추가
- **6단계**: 패스키 등록/로그인 UI
