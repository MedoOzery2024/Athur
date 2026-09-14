-- =============================================================================
-- ATHUR · Migration 0004 — Messaging core
-- =============================================================================
-- Domain: conversations, their members, and every message lifecycle event.
--
-- Key design decisions:
--   * `chats` covers BOTH 1:1 and group conversations (a single abstraction),
--     distinguished by `chat_type`. Group-specific data lives in migration 0005.
--   * For 1:1 chats a `direct_key` (sorted user-id pair) guarantees only one
--     conversation can ever exist between two people — enforced by a unique
--     index rather than application logic.
--   * Messages are immutable rows. Edits, deletions and replies are SEPARATE
--     tables so the original is never overwritten and the revision history
--     requirement (spec §20 J) is satisfiable.
--   * Delivery/read state is per-recipient, not a single column, so group
--     reads are correct.
--   * `client_message_id` makes sends IDEMPOTENT: a retried send after a
--     network blip cannot create a duplicate (spec §24).
-- =============================================================================

BEGIN;

-- --- Chats ------------------------------------------------------------------
CREATE TABLE chats (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 'direct' | 'group'
    chat_type       text        NOT NULL,
    -- For direct chats: the two member ids sorted ascending and joined, e.g.
    -- '<lower-uuid>:<higher-uuid>'. NULL for groups. Guarantees uniqueness.
    direct_key      text,
    -- Group metadata lives in the `groups` table (migration 0005) for groups;
    -- for direct chats we still store a display title for convenience.
    title           text,
    -- Object-storage key for a group avatar (direct chats use the peer avatar).
    avatar_key      text,
    -- Denormalised pointer to the newest message for fast chat-list rendering.
    -- FK added after `messages` exists (circular reference handled below).
    last_message_id uuid,
    last_message_at timestamptz,
    -- When set, new messages in this chat self-destruct after this interval
    -- (disappearing messages, spec §13).
    disappearing_seconds integer,
    created_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    CONSTRAINT chats_type_check CHECK (chat_type IN ('direct', 'group')),
    -- Direct chats MUST have a direct_key; group chats MUST NOT.
    CONSTRAINT chats_direct_key_required
        CHECK ((chat_type = 'direct') = (direct_key IS NOT NULL)),
    CONSTRAINT chats_disappearing_positive
        CHECK (disappearing_seconds IS NULL OR disappearing_seconds > 0)
);

-- Exactly one direct chat per unordered user pair.
CREATE UNIQUE INDEX chats_direct_key_unique
    ON chats (direct_key)
    WHERE direct_key IS NOT NULL;
-- Order the chat list by recency efficiently.
CREATE INDEX chats_last_message_at_idx
    ON chats (last_message_at DESC NULLS LAST)
    WHERE deleted_at IS NULL;

SELECT attach_updated_at('chats');

-- --- Chat members -----------------------------------------------------------
CREATE TABLE chat_members (
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Role within this chat. Direct chats always use 'member'.
    role            text        NOT NULL DEFAULT 'member',
    -- Membership lifecycle.
    joined_at       timestamptz NOT NULL DEFAULT now(),
    left_at         timestamptz,
    -- Per-member chat organisation (spec §20 H).
    is_pinned       boolean     NOT NULL DEFAULT false,
    is_archived     boolean     NOT NULL DEFAULT false,
    is_favorite     boolean     NOT NULL DEFAULT false,
    is_muted        boolean     NOT NULL DEFAULT false,
    mute_until      timestamptz,
    -- Cached unread counter; the authority is still message_delivery_status,
    -- but this keeps the chat list cheap to render (spec §20 performance).
    unread_count    integer     NOT NULL DEFAULT 0,
    -- Last message this member has read (for unread computation + receipts).
    last_read_message_id uuid,
    last_read_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (chat_id, user_id),
    CONSTRAINT chat_members_role_check
        CHECK (role IN ('member', 'moderator', 'admin', 'owner')),
    CONSTRAINT chat_members_unread_non_negative CHECK (unread_count >= 0)
);

CREATE INDEX chat_members_user_idx ON chat_members (user_id);
CREATE INDEX chat_members_pinned_idx ON chat_members (user_id) WHERE is_pinned;
CREATE INDEX chat_members_archived_idx ON chat_members (user_id) WHERE is_archived;

SELECT attach_updated_at('chat_members');

-- Now that chats + members exist, wire the notification override FK.
ALTER TABLE chat_notification_overrides
    ADD CONSTRAINT chat_notification_overrides_chat_fk
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE;

-- --- Messages (immutable rows) ----------------------------------------------
CREATE TABLE messages (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id             uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    sender_id           uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Content kind: 'text' | 'image' | 'video' | 'audio' | 'voice' | 'document'
    -- | 'sticker' | 'gif' | 'contact' | 'location' | 'system'
    message_type        text        NOT NULL DEFAULT 'text',
    -- Text body (used for 'text' and as a caption for media).
    body                text,
    -- Structured, non-binary payload for special types (location coords,
    -- shared-contact reference, link preview metadata…). Never binary media.
    payload             jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Client-generated idempotency key: a retried send reuses the same value,
    -- and the unique index below makes the duplicate a no-op (spec §24).
    client_message_id   text,
    -- Threading: set when this message is a reply to another.
    reply_to_id         uuid        REFERENCES messages(id) ON DELETE SET NULL,
    -- Forward provenance: which original message this was forwarded from.
    forwarded_from_id   uuid        REFERENCES messages(id) ON DELETE SET NULL,
    -- When this message should disappear (disappearing messages).
    expires_at          timestamptz,
    -- Soft delete: the row survives so replies/receipts stay valid.
    deleted_at          timestamptz,
    -- Metadata: link previews, mentions, edit flag.
    metadata            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- True once an edit exists (kept in sync by the service layer).
    is_edited           boolean     NOT NULL DEFAULT false,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT messages_type_check CHECK (message_type IN
        ('text', 'image', 'video', 'audio', 'voice', 'document',
         'sticker', 'gif', 'contact', 'location', 'system')),
    -- Text messages must have a body; others may rely on payload.
    CONSTRAINT messages_text_has_body
        CHECK (message_type <> 'text' OR (body IS NOT NULL AND char_length(body) > 0)),
    -- Guard against absurdly long bodies before the service-layer check.
    CONSTRAINT messages_body_len
        CHECK (body IS NULL OR char_length(body) <= 8000)
);

-- Idempotency: one row per (chat, sender, client_message_id).
CREATE UNIQUE INDEX messages_client_id_unique
    ON messages (chat_id, sender_id, client_message_id)
    WHERE client_message_id IS NOT NULL;

-- Primary read path: newest-first pagination of a chat's messages.
-- (Cursor pagination uses created_at + id, per spec §55.)
CREATE INDEX messages_chat_created_idx
    ON messages (chat_id, created_at DESC, id DESC);

CREATE INDEX messages_sender_idx ON messages (sender_id, created_at DESC);
CREATE INDEX messages_reply_to_idx ON messages (reply_to_id) WHERE reply_to_id IS NOT NULL;
-- Expiry sweeper for disappearing messages.
CREATE INDEX messages_expiry_idx ON messages (expires_at) WHERE expires_at IS NOT NULL;

-- Full-text search over message bodies (spec §32).
CREATE INDEX messages_body_trgm
    ON messages USING gin (body gin_trgm_ops)
    WHERE body IS NOT NULL;

SELECT attach_updated_at('messages');

-- Complete the circular reference: chats.last_message_id → messages.id.
ALTER TABLE chats
    ADD CONSTRAINT chats_last_message_fk
    FOREIGN KEY (last_message_id) REFERENCES messages(id) ON DELETE SET NULL;

-- Same for the "last read" pointer.
ALTER TABLE chat_members
    ADD CONSTRAINT chat_members_last_read_fk
    FOREIGN KEY (last_read_message_id) REFERENCES messages(id) ON DELETE SET NULL;

-- --- Message edits (revision history preserved) -----------------------------
CREATE TABLE message_edits (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    -- The body BEFORE this edit (so history can be reconstructed).
    previous_body   text,
    new_body        text        NOT NULL,
    edited_by       uuid        REFERENCES users(id) ON DELETE SET NULL,
    edited_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT message_edits_new_body_len
        CHECK (char_length(new_body) BETWEEN 1 AND 8000)
);

CREATE INDEX message_edits_message_idx
    ON message_edits (message_id, edited_at DESC);

-- --- Message deletions (audit of who deleted what, when) --------------------
CREATE TABLE message_deletions (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    deleted_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- 'for_me' (only hides for the actor) | 'for_everyone'
    scope           text        NOT NULL,
    deleted_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT message_deletions_scope_check
        CHECK (scope IN ('for_me', 'for_everyone'))
);

CREATE INDEX message_deletions_message_idx ON message_deletions (message_id);

-- --- Per-user hidden messages ("delete for me") -----------------------------
-- A single row per (message, user) that should no longer see the message.
CREATE TABLE message_visibility (
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hidden_at       timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (message_id, user_id)
);

-- --- Message reactions (extensible, no schema change for new emoji) ---------
CREATE TABLE message_reactions (
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- The reaction itself ('👍', 'heart', …). Stored as text so adding new
    -- reactions never requires a migration (spec §16).
    reaction        text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (message_id, user_id, reaction),
    CONSTRAINT message_reactions_len CHECK (char_length(reaction) BETWEEN 1 AND 32)
);

CREATE INDEX message_reactions_message_idx ON message_reactions (message_id);

-- --- Delivery & read status (per recipient) ---------------------------------
-- One row per (message, recipient). This is the authority for ✓/✓ states and
-- for unread counts — a single boolean column could not represent group state.
CREATE TABLE message_delivery_status (
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    recipient_id    uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'pending' | 'sent' | 'delivered' | 'read' | 'failed'
    status          text        NOT NULL DEFAULT 'pending',
    -- When the server accepted the message.
    sent_at         timestamptz,
    -- When the recipient's device acknowledged receipt.
    delivered_at    timestamptz,
    -- When the recipient opened the chat and saw it.
    read_at         timestamptz,
    -- Failure bookkeeping.
    failure_reason  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (message_id, recipient_id),
    CONSTRAINT message_delivery_status_check
        CHECK (status IN ('pending', 'sent', 'delivered', 'read', 'failed'))
);

-- Unread computation: count non-read rows for a recipient in a chat.
CREATE INDEX message_delivery_recipient_pending_idx
    ON message_delivery_status (recipient_id)
    WHERE status <> 'read';

SELECT attach_updated_at('message_delivery_status');

-- --- Pinned messages --------------------------------------------------------
CREATE TABLE pinned_messages (
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    pinned_by       uuid        REFERENCES users(id) ON DELETE SET NULL,
    pinned_at       timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (chat_id, message_id)
);

CREATE INDEX pinned_messages_chat_idx ON pinned_messages (chat_id, pinned_at DESC);

-- --- Starred / saved messages ----------------------------------------------
CREATE TABLE starred_messages (
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id      uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    starred_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, message_id)
);

CREATE INDEX starred_messages_user_idx
    ON starred_messages (user_id, starred_at DESC);

-- --- Chat folders / categories (spec §20 H) --------------------------------
CREATE TABLE chat_folders (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            text        NOT NULL,
    -- Deterministic display order chosen by the user.
    position        integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chat_folders_name_len CHECK (char_length(name) BETWEEN 1 AND 40)
);

CREATE UNIQUE INDEX chat_folders_user_name_unique ON chat_folders (user_id, name);

SELECT attach_updated_at('chat_folders');

CREATE TABLE chat_folder_items (
    folder_id       uuid        NOT NULL REFERENCES chat_folders(id) ON DELETE CASCADE,
    chat_id         uuid        NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    added_at        timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (folder_id, chat_id)
);

INSERT INTO schema_migrations (version, description)
VALUES ('0004', 'messaging core (chats, members, messages, reactions, receipts, folders)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
