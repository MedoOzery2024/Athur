-- =============================================================================
-- ATHUR · Migration 0003 — Social graph, privacy & user settings
-- =============================================================================
-- Domain: relationships between users and the settings that govern them.
--
-- Key design decisions:
--   * A friendship/connection is represented by TWO rows in `contacts`
--     (one per direction). This makes per-direction state natural — each side
--     can mute, favourite or archive independently — and makes "list my
--     contacts" a single indexed lookup on user_id.
--   * `friend_requests` is directional and stateful, with a DB constraint that
--     prevents a user from requesting themselves.
--   * Blocks are directional and enforced by the server; blocking also drops
--     the contact rows via the service layer.
-- =============================================================================

BEGIN;

-- --- Contacts (directional edges = an accepted connection) ------------------
CREATE TABLE contacts (
    -- The owner of this edge.
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- The other party.
    contact_user_id uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Optional local label/nickname the owner set for this contact.
    local_name      text,
    -- Per-edge flags.
    is_favorite     boolean     NOT NULL DEFAULT false,
    is_muted        boolean     NOT NULL DEFAULT false,
    -- Optional per-contact custom ringtone reference (spec §20 D).
    custom_ringtone_key text,
    -- Where this contact came from: 'username' | 'phone_invite' | 'qr'
    -- | 'group' | 'request_accepted'
    source          text        NOT NULL DEFAULT 'request_accepted',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
-- Composite primary key (a user has at most one edge to any other user).
ALTER TABLE contacts ADD PRIMARY KEY (user_id, contact_user_id);
ALTER TABLE contacts
    ADD CONSTRAINT contacts_source_check
        CHECK (source IN ('username', 'phone_invite', 'qr', 'group', 'request_accepted'));
-- A user cannot be their own contact.
ALTER TABLE contacts
    ADD CONSTRAINT contacts_not_self CHECK (user_id <> contact_user_id);

-- Fast "my contacts" listing, ordered by favourite then name is done in SQL;
-- the index supports the lookup itself.
CREATE INDEX contacts_user_idx ON contacts (user_id);
CREATE INDEX contacts_favorites_idx ON contacts (user_id) WHERE is_favorite;

SELECT attach_updated_at('contacts');

-- --- Friend requests (directional, stateful) --------------------------------
CREATE TABLE friend_requests (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    receiver_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'pending' | 'accepted' | 'rejected' | 'cancelled'
    status          text        NOT NULL DEFAULT 'pending',
    -- Optional greeting/message attached to the request.
    message         text,
    responded_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT friend_requests_status_check
        CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled')),
    CONSTRAINT friend_requests_not_self CHECK (sender_id <> receiver_id),
    CONSTRAINT friend_requests_message_len
        CHECK (message IS NULL OR char_length(message) <= 200)
);

-- Only ONE pending request may exist from A to B at a time.
CREATE UNIQUE INDEX friend_requests_one_pending
    ON friend_requests (sender_id, receiver_id)
    WHERE status = 'pending';

-- Inbox lookup: pending requests addressed to me.
CREATE INDEX friend_requests_inbox_idx
    ON friend_requests (receiver_id, created_at DESC)
    WHERE status = 'pending';
CREATE INDEX friend_requests_outbox_idx
    ON friend_requests (sender_id, created_at DESC);

SELECT attach_updated_at('friend_requests');

-- --- Blocked users (directional, server-enforced) ---------------------------
CREATE TABLE blocked_users (
    blocker_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason          text,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT blocked_users_not_self CHECK (blocker_id <> blocked_id)
);

CREATE INDEX blocked_users_blocker_idx ON blocked_users (blocker_id);
-- Reverse lookup: "did X block me?" is needed when the server decides whether
-- I may message/call X.
CREATE INDEX blocked_users_blocked_idx ON blocked_users (blocked_id);

-- --- Privacy settings -------------------------------------------------------
-- One row per user. Defaults are privacy-respecting (spec §59).
CREATE TABLE privacy_settings (
    user_id                     uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- 'everyone' | 'contacts' | 'nobody'
    who_can_find_me             text        NOT NULL DEFAULT 'everyone',
    who_can_message_me          text        NOT NULL DEFAULT 'contacts',
    who_can_call_me             text        NOT NULL DEFAULT 'contacts',
    who_can_see_display_name    text        NOT NULL DEFAULT 'everyone',
    who_can_see_avatar          text        NOT NULL DEFAULT 'everyone',
    who_can_see_last_seen       text        NOT NULL DEFAULT 'contacts',
    who_can_see_online_status   text        NOT NULL DEFAULT 'contacts',
    who_can_see_stories         text        NOT NULL DEFAULT 'contacts',
    -- Read receipts are mutual: if disabled, the user also stops seeing others'.
    send_read_receipts          boolean     NOT NULL DEFAULT true,
    send_typing_indicators      boolean     NOT NULL DEFAULT true,
    -- Story privacy modes (spec §12): 'contacts' | 'selected' | 'everyone'
    story_privacy_mode          text        NOT NULL DEFAULT 'contacts',
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT privacy_audience_check_1
        CHECK (who_can_find_me IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_2
        CHECK (who_can_message_me IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_3
        CHECK (who_can_call_me IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_4
        CHECK (who_can_see_display_name IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_5
        CHECK (who_can_see_avatar IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_6
        CHECK (who_can_see_last_seen IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_7
        CHECK (who_can_see_online_status IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_audience_check_8
        CHECK (who_can_see_stories IN ('everyone', 'contacts', 'nobody')),
    CONSTRAINT privacy_story_mode_check
        CHECK (story_privacy_mode IN ('everyone', 'contacts', 'selected'))
);

SELECT attach_updated_at('privacy_settings');

-- Story privacy exceptions: hide from / show to specific users (spec §12).
CREATE TABLE story_privacy_exceptions (
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_user_id  uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'allow' (only these may see) | 'deny' (these may not see)
    rule            text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, target_user_id),
    CONSTRAINT story_privacy_exceptions_rule_check
        CHECK (rule IN ('allow', 'deny')),
    CONSTRAINT story_privacy_exceptions_not_self
        CHECK (user_id <> target_user_id)
);

-- --- Notification settings --------------------------------------------------
CREATE TABLE notification_settings (
    user_id                     uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    messages_enabled            boolean     NOT NULL DEFAULT true,
    groups_enabled              boolean     NOT NULL DEFAULT true,
    calls_enabled               boolean     NOT NULL DEFAULT true,
    stories_enabled             boolean     NOT NULL DEFAULT true,
    social_enabled              boolean     NOT NULL DEFAULT true,
    friend_requests_enabled     boolean     NOT NULL DEFAULT true,
    -- When true, group notifications for the same chat are combined (spec §19).
    group_similar_notifications boolean     NOT NULL DEFAULT true,
    -- In-app sound/vibration behaviour.
    sound_enabled               boolean     NOT NULL DEFAULT true,
    vibrate_enabled             boolean     NOT NULL DEFAULT true,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now()
);

SELECT attach_updated_at('notification_settings');

-- --- Per-chat / per-group notification overrides ----------------------------
CREATE TABLE chat_notification_overrides (
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Chat id (FK added in the messaging migration; nullable until then is
    -- avoided by creating this table AFTER chats — see migration 0004).
    chat_id         uuid        NOT NULL,
    is_muted        boolean     NOT NULL DEFAULT false,
    mute_until      timestamptz,
    custom_sound_key text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, chat_id)
);

SELECT attach_updated_at('chat_notification_overrides');

-- --- User settings (general app preferences) --------------------------------
CREATE TABLE user_settings (
    user_id             uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- 'en' | 'ar' | … — server-side record; the app also stores it locally.
    language            text        NOT NULL DEFAULT 'en',
    -- 'system' | 'light' | 'dark' (Athur is dark-first but the field exists).
    theme_mode          text        NOT NULL DEFAULT 'dark',
    -- Default media auto-download policy: 'wifi' | 'wifi_mobile' | 'never'.
    auto_download_media text        NOT NULL DEFAULT 'wifi',
    -- Call preferences.
    default_call_ringtone_key text,
    -- Whether the user has completed the guided setup.
    setup_completed_at  timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_settings_theme_check
        CHECK (theme_mode IN ('system', 'light', 'dark')),
    CONSTRAINT user_settings_auto_download_check
        CHECK (auto_download_media IN ('wifi', 'wifi_mobile', 'never'))
);

SELECT attach_updated_at('user_settings');

-- --- Account data export / deletion requests (spec §60) ---------------------
CREATE TABLE account_deletion_requests (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'pending' | 'completed' | 'cancelled'
    status          text        NOT NULL DEFAULT 'pending',
    -- Grace period before destructive execution, letting the user cancel.
    scheduled_for   timestamptz NOT NULL,
    completed_at    timestamptz,
    reason          text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT account_deletion_status_check
        CHECK (status IN ('pending', 'completed', 'cancelled'))
);

CREATE INDEX account_deletion_pending_idx
    ON account_deletion_requests (scheduled_for)
    WHERE status = 'pending';

SELECT attach_updated_at('account_deletion_requests');

INSERT INTO schema_migrations (version, description)
VALUES ('0003', 'social graph, privacy settings, notification settings, user settings')
ON CONFLICT (version) DO NOTHING;

COMMIT;
