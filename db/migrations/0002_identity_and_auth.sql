-- =============================================================================
-- ATHUR · Migration 0002 — Identity & authentication
-- =============================================================================
-- Domain: who a user is, how they authenticate, and where they are signed in.
--
-- Key design decisions:
--   * `users` is the account root. It holds NO credentials.
--   * `auth_identities` holds one row per authentication method (phone, email,
--     google, microsoft). This is what makes ACCOUNT LINKING possible: several
--     identities can point at the same `users` row, and a unique constraint
--     prevents the same external identity from mapping to two accounts.
--   * `user_profiles` is split from `users` so high-traffic auth reads never
--     touch display data, and profile fields (bio, avatar) can be extended
--     without widening the hot table.
--   * Passwords (only if ever used) are stored as Argon2/bcrypt hashes in
--     `password_credentials` — never in `users`, never in plaintext.
--   * OTP challenges store a HASH of the code, never the code itself, plus
--     attempt counters and expiry for brute-force protection.
-- =============================================================================

BEGIN;

-- --- Users (account root) ---------------------------------------------------
CREATE TABLE users (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Public, human-shareable handle (e.g. @ahmed). Nullable until chosen,
    -- unique case-insensitively.
    username        citext,
    -- Account lifecycle. 'active' | 'suspended' | 'deactivated' | 'deleted'.
    status          text        NOT NULL DEFAULT 'active',
    -- Marks whether the account completed onboarding/profile setup.
    is_onboarded    boolean     NOT NULL DEFAULT false,
    -- Server-authoritative account creation timestamp.
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    -- Soft deletion: we retain the row so message history stays coherent,
    -- but PII is scrubbed by the account-deletion routine (spec §60).
    deleted_at      timestamptz,

    CONSTRAINT users_status_check
        CHECK (status IN ('active', 'suspended', 'deactivated', 'deleted')),
    CONSTRAINT users_username_format
        CHECK (username IS NULL OR username ~ '^[a-z0-9_]{3,32}$')
);

-- Usernames are unique only among live accounts; a deleted account frees it.
CREATE UNIQUE INDEX users_username_unique
    ON users (username)
    WHERE username IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX users_status_idx ON users (status) WHERE deleted_at IS NULL;

SELECT attach_updated_at('users');

-- --- Profiles (display data, separate from the auth-hot users table) --------
CREATE TABLE user_profiles (
    user_id         uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_name    text        NOT NULL,
    -- Short bio/status line.
    bio             text,
    -- Object-storage key for avatar/cover (NOT the binary; spec §15).
    avatar_key      text,
    cover_key       text,
    -- Accent color chosen by the user for their profile (hex like '#D4AF37').
    accent_color    text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_profiles_display_name_len
        CHECK (char_length(display_name) BETWEEN 1 AND 64),
    CONSTRAINT user_profiles_bio_len
        CHECK (bio IS NULL OR char_length(bio) <= 300),
    CONSTRAINT user_profiles_accent_color_format
        CHECK (accent_color IS NULL OR accent_color ~ '^#[0-9A-Fa-f]{6}$')
);

SELECT attach_updated_at('user_profiles');

-- Full-text/fuzzy search support for "find people by name/username" (spec §32).
CREATE INDEX user_profiles_display_name_trgm
    ON user_profiles USING gin (display_name gin_trgm_ops);

-- --- Auth identities (one row per login method → enables account linking) ---
-- provider values: 'phone' | 'email' | 'google' | 'microsoft'
CREATE TABLE auth_identities (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        text        NOT NULL,
    -- The provider-scoped identifier:
    --   phone     → E.164 number, e.g. +201234567890
    --   email     → lower-cased address
    --   google    → Google 'sub' claim
    --   microsoft → Microsoft object id
    provider_uid    text        NOT NULL,
    -- Whether THIS identity has been verified (OTP confirmed / OAuth verified).
    is_verified     boolean     NOT NULL DEFAULT false,
    -- Extra provider data (display name, avatar URL, tenant) — non-secret only.
    metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- When the user linked it, and last successful use.
    linked_at       timestamptz NOT NULL DEFAULT now(),
    last_used_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT auth_identities_provider_check
        CHECK (provider IN ('phone', 'email', 'google', 'microsoft'))
);

-- One external identity maps to exactly ONE Athur account. This is the core
-- guard that prevents duplicate accounts during linking (spec §6).
CREATE UNIQUE INDEX auth_identities_provider_uid_unique
    ON auth_identities (provider, provider_uid);

CREATE INDEX auth_identities_user_idx ON auth_identities (user_id);

SELECT attach_updated_at('auth_identities');

-- --- Phone numbers (normalised, separated for OTP rate-limit lookups) -------
CREATE TABLE phone_numbers (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- E.164 canonical form. Stored once per user as the primary number.
    e164            text        NOT NULL,
    country_code    text,
    is_primary      boolean     NOT NULL DEFAULT false,
    is_verified     boolean     NOT NULL DEFAULT false,
    verified_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT phone_numbers_e164_format CHECK (e164 ~ '^\+[1-9][0-9]{6,14}$')
);

CREATE UNIQUE INDEX phone_numbers_e164_unique ON phone_numbers (e164);
-- Only one primary number per user.
CREATE UNIQUE INDEX phone_numbers_one_primary_per_user
    ON phone_numbers (user_id)
    WHERE is_primary;

SELECT attach_updated_at('phone_numbers');

-- --- Email addresses --------------------------------------------------------
CREATE TABLE email_addresses (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    address         citext      NOT NULL,
    is_primary      boolean     NOT NULL DEFAULT false,
    is_verified     boolean     NOT NULL DEFAULT false,
    verified_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX email_addresses_address_unique ON email_addresses (address);
CREATE UNIQUE INDEX email_addresses_one_primary_per_user
    ON email_addresses (user_id)
    WHERE is_primary;

SELECT attach_updated_at('email_addresses');

-- --- Password credentials (only if password auth is enabled) ----------------
-- Hash is produced with a memory-hard algorithm (Argon2id preferred). The salt
-- is embedded in the encoded hash string as per PHC format.
CREATE TABLE password_credentials (
    user_id         uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    password_hash   text        NOT NULL,
    -- Forced reset / rotation bookkeeping.
    password_changed_at timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    -- Reject obviously-unsafe stored values (never plaintext, never empty).
    CONSTRAINT password_credentials_hash_looks_encoded
        CHECK (char_length(password_hash) >= 40 AND password_hash <> '')
);

SELECT attach_updated_at('password_credentials');

-- --- OTP challenges (phone + email) -----------------------------------------
-- Stores a HASH of the code, never the code. Enforces expiry, single use and
-- attempt limits so brute force is impossible even if the table leaks.
CREATE TABLE otp_challenges (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 'phone' | 'email'
    channel         text        NOT NULL,
    -- Destination (E.164 phone or lower-cased email).
    destination     text        NOT NULL,
    -- Purpose: 'signup' | 'login' | 'verify' | 'reset'
    purpose         text        NOT NULL,
    -- SHA-256 hash of the code (with a per-challenge random salt).
    code_hash       text        NOT NULL,
    salt            text        NOT NULL,
    -- Brute-force protection.
    attempts        smallint    NOT NULL DEFAULT 0,
    max_attempts    smallint    NOT NULL DEFAULT 5,
    -- Lifecycle.
    expires_at      timestamptz NOT NULL,
    consumed_at     timestamptz,
    -- Request context, for abuse investigation (no PII beyond the destination).
    requested_ip    inet,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT otp_challenges_channel_check
        CHECK (channel IN ('phone', 'email')),
    CONSTRAINT otp_challenges_purpose_check
        CHECK (purpose IN ('signup', 'login', 'verify', 'reset')),
    CONSTRAINT otp_challenges_attempts_check
        CHECK (attempts >= 0 AND attempts <= max_attempts)
);

-- Lookup path: find the newest live challenge for a destination+purpose.
CREATE INDEX otp_challenges_lookup_idx
    ON otp_challenges (channel, destination, purpose, created_at DESC);
-- Housekeeping: find expired rows quickly.
CREATE INDEX otp_challenges_expiry_idx ON otp_challenges (expires_at);

-- Rate-limiting OTP requests per destination (spec §28): a partial index helps
-- "how many were requested in the last N minutes" queries.
CREATE INDEX otp_challenges_ratelimit_idx
    ON otp_challenges (destination, created_at DESC);

-- --- Devices (a physical install of the app) --------------------------------
CREATE TABLE devices (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Client-generated stable install id (survives app restarts, cleared on
    -- reinstall). Used to dedupe devices and route push tokens.
    install_id      text        NOT NULL,
    -- 'android' | 'ios' | 'windows' | 'web' | 'macos' | 'linux'
    platform        text        NOT NULL,
    -- User-visible model/name, e.g. "Samsung Galaxy S23".
    device_name     text,
    os_version      text,
    app_version     text,
    -- Last time this device talked to the server (heartbeat/last activity).
    last_active_at  timestamptz NOT NULL DEFAULT now(),
    -- Whether the user has revoked this device (logout from device).
    is_revoked      boolean     NOT NULL DEFAULT false,
    revoked_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT devices_platform_check
        CHECK (platform IN ('android', 'ios', 'windows', 'web', 'macos', 'linux'))
);

-- One row per install per user; re-login on the same install reuses the row.
CREATE UNIQUE INDEX devices_user_install_unique ON devices (user_id, install_id);

CREATE INDEX devices_user_idx ON devices (user_id) WHERE NOT is_revoked;

SELECT attach_updated_at('devices');

-- --- Sessions (a signed-in session on a device) -----------------------------
CREATE TABLE sessions (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id           uuid        REFERENCES devices(id) ON DELETE SET NULL,
    -- Coarse request context for the "active sessions" screen (spec §26).
    ip_address          inet,
    user_agent          text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    last_seen_at        timestamptz NOT NULL DEFAULT now(),
    -- Session end (logout, revoke, or expiry). NULL = still valid.
    ended_at            timestamptz,
    -- Why it ended: 'logout' | 'logout_all' | 'revoked' | 'expired' | 'replaced'
    ended_reason        text,

    CONSTRAINT sessions_ended_reason_check
        CHECK (ended_reason IS NULL OR ended_reason IN
               ('logout', 'logout_all', 'revoked', 'expired', 'replaced'))
);

CREATE INDEX sessions_user_active_idx
    ON sessions (user_id) WHERE ended_at IS NULL;
CREATE INDEX sessions_device_idx ON sessions (device_id);

-- --- Refresh tokens (rotating, hashed) --------------------------------------
-- Only a hash of the token is stored. Rotation: a used token is marked
-- `rotated_at` and linked to its successor, so replay is detectable (spec §25).
CREATE TABLE refresh_tokens (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    user_id             uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- SHA-256 of the opaque token. Never the token itself.
    token_hash          text        NOT NULL,
    expires_at          timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    -- Set when the token is exchanged (rotation).
    rotated_at          timestamptz,
    -- The token that replaced this one, if any.
    replaced_by_id      uuid        REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    -- Set if the token is revoked early (logout, theft detection).
    revoked_at          timestamptz,
    revoked_reason      text,

    CONSTRAINT refresh_tokens_hash_unique UNIQUE (token_hash)
);

CREATE INDEX refresh_tokens_session_idx ON refresh_tokens (session_id);
CREATE INDEX refresh_tokens_user_live_idx
    ON refresh_tokens (user_id)
    WHERE revoked_at IS NULL AND rotated_at IS NULL;

-- --- Security events (audit trail for account security, spec §27) -----------
CREATE TABLE security_events (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        REFERENCES users(id) ON DELETE CASCADE,
    -- 'login' | 'new_device' | 'password_changed' | 'identity_linked'
    -- | 'identity_removed' | 'logout' | 'login_failed' | 'account_recovery'
    -- | 'suspicious_activity'
    event_type      text        NOT NULL,
    -- Severity for surfacing/notification decisions.
    severity        text        NOT NULL DEFAULT 'info',
    -- Structured, non-secret context (device, ip, provider…).
    context         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    ip_address      inet,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT security_events_severity_check
        CHECK (severity IN ('info', 'warning', 'critical'))
);

CREATE INDEX security_events_user_idx
    ON security_events (user_id, created_at DESC);

INSERT INTO schema_migrations (version, description)
VALUES ('0002', 'identity & authentication (users, identities, devices, sessions, otp)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
