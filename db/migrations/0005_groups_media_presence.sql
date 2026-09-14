-- =============================================================================
-- ATHUR · Migration 0005 — Groups, media, presence
-- =============================================================================
-- Domain: group-specific data, media/attachment metadata, and presence.
--
-- Key design decisions:
--   * Group data extends `chats` (migration 0004) with a 1:1 `groups` row.
--     Permissions are stored as a structured jsonb with a documented shape so
--     new toggles can be added without schema churn (spec §17).
--   * Media binaries live in object storage (S3-compatible). PostgreSQL stores
--     ONLY metadata: storage key, MIME, size, dimensions, duration, hash.
--   * Presence is derived from heartbeats + WebSocket connection state, never a
--     permanent boolean (spec §1 & §19).
-- =============================================================================

BEGIN;

-- --- Groups (1:1 extension of a chat with chat_type='group') ----------------
CREATE TABLE groups (
    chat_id         uuid        PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
    name            text        NOT NULL,
    description     text,
    -- Group avatar object-storage key.
    avatar_key      text,
    -- Who created it.
    owner_id        uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Structured permission policy. Shape (documented, validated in service):
    -- {
    --   "send_messages": "all"|"admins",
    --   "send_media": "all"|"admins",
    --   "add_members": "all"|"admins",
    --   "edit_group_info": "all"|"admins",
    --   "pin_messages": "admins",
    --   "mention_everyone": "admins"
    -- }
    permissions     jsonb       NOT NULL DEFAULT jsonb_build_object(
        'send_messages', 'all',
        'send_media', 'all',
        'add_members', 'all',
        'edit_group_info', 'admins',
        'pin_messages', 'admins',
        'mention_everyone', 'admins'
    ),
    -- Whether members see each other's phone numbers.
    is_public       boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT groups_name_len CHECK (char_length(name) BETWEEN 1 AND 80),
    CONSTRAINT groups_description_len
        CHECK (description IS NULL OR char_length(description) <= 512)
);

-- Search groups by name (spec §32).
CREATE INDEX groups_name_trgm ON groups USING gin (name gin_trgm_ops);

SELECT attach_updated_at('groups');

-- --- Group roles (explicit admin/moderator assignments) ---------------------
-- `chat_members.role` is the fast path; this table records role change history
-- and the granting admin, which is required for a trustworthy audit trail.
CREATE TABLE group_role_assignments (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            text        NOT NULL,
    granted_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    revoked_at      timestamptz,

    CONSTRAINT group_role_assignments_role_check
        CHECK (role IN ('moderator', 'admin', 'owner'))
);

CREATE INDEX group_role_assignments_live_idx
    ON group_role_assignments (chat_id, user_id)
    WHERE revoked_at IS NULL;

-- --- Group invite links -----------------------------------------------------
CREATE TABLE group_invites (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    -- Opaque, unguessable token embedded in the invite link.
    token           text        NOT NULL,
    created_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Optional expiry and usage cap.
    expires_at      timestamptz,
    max_uses        integer,
    use_count       integer     NOT NULL DEFAULT 0,
    is_revoked      boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT group_invites_use_count_check
        CHECK (use_count >= 0 AND (max_uses IS NULL OR use_count <= max_uses))
);

CREATE UNIQUE INDEX group_invites_token_unique ON group_invites (token);
CREATE INDEX group_invites_chat_idx ON group_invites (chat_id) WHERE NOT is_revoked;

SELECT attach_updated_at('group_invites');

-- --- Group join requests (for invite links requiring approval) --------------
CREATE TABLE group_join_requests (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invite_id       uuid        REFERENCES group_invites(id) ON DELETE SET NULL,
    status          text        NOT NULL DEFAULT 'pending',
    reviewed_by     uuid        REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT group_join_requests_status_check
        CHECK (status IN ('pending', 'approved', 'rejected'))
);

CREATE UNIQUE INDEX group_join_requests_one_pending
    ON group_join_requests (chat_id, user_id)
    WHERE status = 'pending';

-- --- Media (metadata only; binaries live in object storage) -----------------
CREATE TABLE media (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Uploader.
    owner_id        uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Which subsystem owns it: 'message' | 'avatar' | 'story' | 'post'
    -- | 'group_avatar' | 'call_recording'
    context         text        NOT NULL,
    -- Object-storage key (provider-agnostic; never a full public URL with
    -- credentials). A signed URL is generated on demand.
    storage_key     text        NOT NULL,
    -- Which bucket/region, for multi-provider deployments.
    storage_bucket  text,
    -- Validated MIME type (server-verified, not client-trusted — spec §29).
    mime_type       text        NOT NULL,
    -- Byte size, validated against per-context limits.
    byte_size       bigint      NOT NULL,
    -- Content hash for integrity checks and deduplication.
    sha256          text        NOT NULL,
    -- Media-specific dimensions (images/video).
    width           integer,
    height          integer,
    -- Duration for audio/video (seconds, fractional allowed).
    duration_ms     integer,
    -- Thumbnail/blurhash for progressive loading (performance, spec §20).
    thumbnail_key   text,
    blurhash        text,
    -- Original client filename — stored for UX only, NEVER used as a path.
    original_filename text,
    -- Lifecycle: 'pending' | 'ready' | 'failed' | 'deleted'
    status          text        NOT NULL DEFAULT 'pending',
    -- For secure temporary media (spec §20 I): auto-expire after a policy.
    expires_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT media_context_check CHECK (context IN
        ('message', 'avatar', 'cover', 'story', 'post', 'group_avatar',
         'call_recording', 'video_post', 'short_video')),
    CONSTRAINT media_status_check
        CHECK (status IN ('pending', 'ready', 'failed', 'deleted')),
    CONSTRAINT media_byte_size_positive CHECK (byte_size > 0),
    CONSTRAINT media_sha256_format CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT media_dimensions_positive
        CHECK ((width IS NULL OR width > 0) AND (height IS NULL OR height > 0)),
    CONSTRAINT media_duration_positive
        CHECK (duration_ms IS NULL OR duration_ms > 0)
);

CREATE UNIQUE INDEX media_storage_key_unique ON media (storage_key);
CREATE INDEX media_owner_idx ON media (owner_id, created_at DESC);
CREATE INDEX media_context_idx ON media (context, created_at DESC);
-- Deduplication / integrity lookups.
CREATE INDEX media_sha256_idx ON media (sha256);
-- Expiry sweeper for temporary media.
CREATE INDEX media_expiry_idx ON media (expires_at) WHERE expires_at IS NOT NULL;

SELECT attach_updated_at('media');

-- --- Message attachments (join between a message and its media) -------------
CREATE TABLE message_attachments (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    media_id        uuid        NOT NULL REFERENCES media(id) ON DELETE RESTRICT,
    -- Ordering when a message carries several files (albums).
    position        smallint    NOT NULL DEFAULT 0,
    -- Voice-message / audio specific: waveform samples for visualisation.
    -- Stored as a compact array of normalised amplitudes (0..1).
    waveform        real[],
    -- Transcript is intentionally NOT stored (no AI features by design).
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT message_attachments_position_check CHECK (position >= 0)
);

CREATE UNIQUE INDEX message_attachments_unique
    ON message_attachments (message_id, media_id);
CREATE INDEX message_attachments_message_idx
    ON message_attachments (message_id, position);
CREATE INDEX message_attachments_media_idx ON message_attachments (media_id);

-- --- Presence (heartbeat-based; NOT a permanent boolean) --------------------
-- One row per user. `status` is derived by the service layer from
-- `last_heartbeat_at`, the live WebSocket registry and `manual_status`.
CREATE TABLE presence (
    user_id             uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Server-maintained derived status. Kept for cheap reads; the service layer
    -- recomputes it from heartbeats and reconnects (spec §19).
    status              text        NOT NULL DEFAULT 'offline',
    -- User-chosen override: 'available' | 'do_not_disturb'.
    manual_status       text        NOT NULL DEFAULT 'available',
    -- Free-text status message.
    status_text         text,
    -- Last verified heartbeat. This is the real source of "last seen".
    last_heartbeat_at   timestamptz,
    -- Last time the user was definitively online (for "last seen" display).
    last_online_at      timestamptz,
    -- Connection bookkeeping.
    active_connection_count integer NOT NULL DEFAULT 0,
    -- Set while the user is a participant in a non-ended call.
    in_call             boolean     NOT NULL DEFAULT false,
    current_call_id     uuid,
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT presence_status_check
        CHECK (status IN ('online', 'offline', 'connecting', 'reconnecting',
                          'in_call', 'unavailable')),
    CONSTRAINT presence_manual_status_check
        CHECK (manual_status IN ('available', 'do_not_disturb')),
    CONSTRAINT presence_status_text_len
        CHECK (status_text IS NULL OR char_length(status_text) <= 140),
    CONSTRAINT presence_conn_non_negative CHECK (active_connection_count >= 0)
);

-- "Who is online now" and "recently online" queries.
CREATE INDEX presence_status_idx ON presence (status);
CREATE INDEX presence_last_heartbeat_idx ON presence (last_heartbeat_at DESC);

SELECT attach_updated_at('presence');

-- --- Typing indicators (EPHEMERAL — never persisted per keystroke) ----------
-- Written only to track an in-progress state with an expiry, and cleaned up by
-- the service layer. Message contents are never stored here (spec §2).
CREATE TABLE typing_indicators (
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- The activity being indicated: 'typing' | 'recording_voice'
    -- | 'recording_video' | 'uploading'
    activity        text        NOT NULL DEFAULT 'typing',
    started_at      timestamptz NOT NULL DEFAULT now(),
    -- The indicator is considered stale after this moment.
    expires_at      timestamptz NOT NULL,

    PRIMARY KEY (chat_id, user_id, activity),
    CONSTRAINT typing_indicators_activity_check
        CHECK (activity IN ('typing', 'recording_voice', 'recording_video', 'uploading'))
);

CREATE INDEX typing_indicators_expiry_idx ON typing_indicators (expires_at);

INSERT INTO schema_migrations (version, description)
VALUES ('0005', 'groups, media, presence, typing indicators')
ON CONFLICT (version) DO NOTHING;

COMMIT;
