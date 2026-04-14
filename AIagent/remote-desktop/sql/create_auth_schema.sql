-- ============================================================================
-- 뷰어 로그인 시스템 - 인증 스키마
-- ============================================================================
-- 사용 정책:
--   1) 셀프 가입 (누구나)
--   2) 이메일 인증 필수 (Supabase 콘솔에서 Confirm Email = ON)
--   3) 로그인 방식: 이메일/비번 OR 패스키 (택1)
--   4) 호스트는 인증 불필요, 뷰어만 로그인 요구
--   5) 패스키만으로는 가입 불가. 이메일/비번으로 가입한 사용자가 패스키를 추가 등록.
-- ============================================================================

-- ── 1. profiles : auth.users 1:1 확장 ──────────────────────────────────────
-- Supabase auth.users는 시스템 테이블이므로 부가 정보는 별도 테이블에 저장한다.
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT UNIQUE NOT NULL,
  display_name TEXT,
  avatar_url TEXT,
  -- 뷰어 권한 구분 (필요 시 'admin' 추가). 기본값은 일반 상담원.
  role TEXT NOT NULL DEFAULT 'agent' CHECK (role IN ('agent', 'admin')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profiles_email ON public.profiles(email);

-- ── 2. passkey_credentials : WebAuthn 자격증명 ─────────────────────────────
-- 한 사용자가 여러 기기에서 패스키를 등록할 수 있다 (예: 노트북, 휴대폰).
CREATE TABLE IF NOT EXISTS public.passkey_credentials (
  -- credential_id (base64url 인코딩 문자열) — WebAuthn 표준 식별자
  id TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- 공개키 (CBOR 또는 PEM 형식 바이너리)
  public_key BYTEA NOT NULL,
  -- 인증기 카운터 (재사용 공격 방지용, 매 인증마다 증가)
  counter BIGINT NOT NULL DEFAULT 0,
  -- 전송 방식 ('internal' = OS 내장, 'hybrid' = QR 휴대폰, 'usb', 'nfc', 'ble')
  transports TEXT[],
  -- 사용자 친화적 기기 이름 ("MacBook Touch ID", "Windows Hello" 등)
  device_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_passkey_user_id ON public.passkey_credentials(user_id);

-- ── 3. webauthn_challenges : 임시 challenge 저장 ───────────────────────────
-- WebAuthn은 등록/로그인마다 서버가 생성한 nonce(challenge)를 사용한다.
-- 5분 TTL로 자동 만료되며, 사용 후에는 정리되어야 한다.
CREATE TABLE IF NOT EXISTS public.webauthn_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge TEXT NOT NULL UNIQUE,
  -- 등록 시에는 user_id가 채워짐 (이미 로그인된 사용자)
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  -- 로그인 시에는 email로 사용자를 식별 (아직 인증 전이므로 user_id 없음)
  email TEXT,
  type TEXT NOT NULL CHECK (type IN ('register', 'login')),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '5 minutes'),
  consumed BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_webauthn_challenges_expires ON public.webauthn_challenges(expires_at);
CREATE INDEX IF NOT EXISTS idx_webauthn_challenges_email ON public.webauthn_challenges(email);

-- ── 4. 기존 sessions에 user_id 컬럼 추가 (뷰어 식별용) ─────────────────────
-- connection_sessions가 기존 테이블명. 뷰어 로그인 후 본인 세션만 조회 가능하게.
ALTER TABLE public.connection_sessions
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_connection_sessions_user_id ON public.connection_sessions(user_id);

-- ── 5. 신규 가입 시 자동으로 profiles 생성하는 트리거 ──────────────────────
-- auth.users에 INSERT가 발생하면 profiles에 동일 id로 행을 생성한다.
-- SECURITY DEFINER 권한으로 실행되어야 auth 스키마에 접근 가능.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    -- 가입 시 display_name이 없으면 이메일 prefix 사용 ("foo@bar.com" → "foo")
    COALESCE(
      NEW.raw_user_meta_data->>'name',
      split_part(NEW.email, '@', 1)
    )
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- ── 6. updated_at 자동 갱신 트리거 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_updated_at ON public.profiles;
CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) 정책
-- ============================================================================
-- 모든 테이블에 RLS를 활성화하여 자기 데이터만 접근 가능하게 강제한다.
-- 서버(시그널링)는 service_role 키로 RLS를 우회하여 직접 조작한다.

-- profiles: 본인만 조회/수정 가능
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles_self_read" ON public.profiles;
CREATE POLICY "profiles_self_read"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_self_update" ON public.profiles;
CREATE POLICY "profiles_self_update"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- passkey_credentials: 본인 자격증명만 관리
ALTER TABLE public.passkey_credentials ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "passkey_self_manage" ON public.passkey_credentials;
CREATE POLICY "passkey_self_manage"
  ON public.passkey_credentials FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- webauthn_challenges: 클라이언트 직접 접근 불가 (서버 service_role 전용)
ALTER TABLE public.webauthn_challenges ENABLE ROW LEVEL SECURITY;
-- 정책 없음 = 모든 일반 사용자 접근 차단. service_role만 사용.

-- connection_sessions: 본인 세션만 조회
-- (기존 정책이 있다면 harden_rls_production.sql 참조하여 통합 관리)
ALTER TABLE public.connection_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sessions_self_read" ON public.connection_sessions;
CREATE POLICY "sessions_self_read"
  ON public.connection_sessions FOR SELECT
  USING (auth.uid() = user_id OR user_id IS NULL);
  -- user_id IS NULL은 마이그레이션 이전 데이터 호환성을 위한 임시 허용.
  -- 마이그레이션 완료 후 제거 권장.

-- ============================================================================
-- 만료된 challenge 정리용 함수 (선택적: pg_cron으로 주기 실행)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cleanup_expired_challenges()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM public.webauthn_challenges
  WHERE expires_at < now() OR consumed = true;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

-- 권한 부여 (anon/authenticated가 자기 프로필 조회 가능하도록)
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.passkey_credentials TO authenticated;

-- ============================================================================
-- 적용 후 확인 쿼리
-- ============================================================================
-- SELECT * FROM public.profiles LIMIT 5;
-- SELECT * FROM public.passkey_credentials LIMIT 5;
-- SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname = 'public';
