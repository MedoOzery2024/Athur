-- =============================================================================
-- ATHUR · Migration 0007 — Social: posts, comments, stories, live, releases
-- =============================================================================
-- Domain: the social/feed layer, temporary Stories, live sessions, saved
-- content, hashtags/mentions, and the self-hosted APK release manifest.
--
-- Key design decisions:
--   * Posts, Stories, Short Videos and Live are SEPARATE models with their own
--     lifecycles (spec §13) — they are not overloaded onto one table.
--   * Reactions are stored as text in a generic table so new reaction types
--     never require a migration (spec §16).
--   * Media is referenced via `media`, never duplicated: sharing a post inside
--     a chat stores a structured reference, not a copy (spec §17).
-- =============================================================================

BEGIN;

-- --- Posts ------------------------------------------------------------------
CREATE TABLE posts (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'text' | 'image' | 'video' | 'short_video' | 'poll' | 'link' | 'audio'
    post_type       text        NOT NULL DEFAULT 'text',
    body            text,
    -- Structured extras: poll definition, link preview, location, mentions.
    payload         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Visibility (server-enforced, spec §14):
    --   'public' | 'contacts' | 'selected' | 'private'
    visibility      text        NOT NULL DEFAULT 'contacts',
    -- Original author when this is a repost (quoted reference, not a copy).
    repost_of_id    uuid        REFERENCES posts(id) ON DELETE SET NULL,
    -- Denormalised counters for fast feed rendering. Maintained transactionally
    -- by the service layer; the reaction/comment tables remain the authority.
    reaction_count  integer     NOT NULL DEFAULT 0,
    comment_count   integer     NOT NULL DEFAULT 0,
    share_count     integer     NOT NULL DEFAULT 0,
    -- Pinned posts appear first on a profile.
    is_pinned       boolean     NOT NULL DEFAULT false,
    -- Comments may be disabled per post.
    comments_enabled boolean    NOT NULL DEFAULT true,
    edited_at       timestamptz,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT posts_type_check CHECK (post_type IN
        ('text', 'image', 'video', 'short_video', 'poll', 'link', 'audio')),
    CONSTRAINT posts_visibility_check
        CHECK (visibility IN ('public', 'contacts', 'selected', 'private')),
    -- A non-repost post must carry some content.
    CONSTRAINT posts_has_content
        CHECK (body IS NOT NULL OR payload <> '{}'::jsonb OR post_type <> 'text'),
    CONSTRAINT posts_body_len
        CHECK (body IS NULL OR char_length(body) <= 20000),
    CONSTRAINT posts_counters_non_negative
        CHECK (reaction_count >= 0 AND comment_count >= 0 AND share_count >= 0)
);

CREATE INDEX posts_author_idx ON posts (author_id, created_at DESC)
    WHERE deleted_at IS NULL;
-- Global feed: newest public/contacts posts.
CREATE INDEX posts_feed_idx ON posts (created_at DESC)
    WHERE deleted_at IS NULL;
-- Short-video discovery feed.
CREATE INDEX posts_short_video_idx ON posts (created_at DESC)
    WHERE post_type = 'short_video' AND deleted_at IS NULL;
-- Full-text search over post bodies.
CREATE INDEX posts_body_trgm
    ON posts USING gin (body gin_trgm_ops) WHERE body IS NOT NULL;

SELECT attach_updated_at('posts');

-- --- Post media (ordered; albums supported) ---------------------------------
CREATE TABLE post_media (
    post_id         uuid        NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    media_id        uuid        NOT NULL REFERENCES media(id) ON DELETE RESTRICT,
    position        smallint    NOT NULL DEFAULT 0,
    -- Optional per-item caption.
    caption         text,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, media_id),
    CONSTRAINT post_media_position_check CHECK (position >= 0)
);

CREATE INDEX post_media_post_idx ON post_media (post_id, position);

-- --- Post visibility exceptions ('selected' visibility) ---------------------
CREATE TABLE post_visibility_exceptions (
    post_id         uuid        NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'allow' | 'deny' — same semantics as story exceptions.
    rule            text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, user_id),
    CONSTRAINT post_visibility_exceptions_rule_check
        CHECK (rule IN ('allow', 'deny'))
);

-- --- Post reactions (extensible text reaction) ------------------------------
CREATE TABLE post_reactions (
    post_id         uuid        NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'like' | 'love' | 'laugh' | 'wow' | 'sad' | 'angry' | future values.
    reaction        text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    -- One reaction per user per post (changing it updates the row).
    PRIMARY KEY (post_id, user_id),
    CONSTRAINT post_reactions_len CHECK (char_length(reaction) BETWEEN 1 AND 32)
);

CREATE INDEX post_reactions_post_idx ON post_reactions (post_id);

-- --- Comments (threaded, paginated) -----------------------------------------
CREATE TABLE comments (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id         uuid        NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    author_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Parent comment for replies; NULL for top-level comments.
    parent_id       uuid        REFERENCES comments(id) ON DELETE CASCADE,
    body            text        NOT NULL,
    -- Denormalised counters/replies for fast rendering.
    reaction_count  integer     NOT NULL DEFAULT 0,
    reply_count     integer     NOT NULL DEFAULT 0,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT comments_body_len
        CHECK (char_length(body) BETWEEN 1 AND 4000),
    CONSTRAINT comments_counters_non_negative
        CHECK (reaction_count >= 0 AND reply_count >= 0)
);

CREATE INDEX comments_post_idx ON comments (post_id, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX comments_parent_idx ON comments (parent_id, created_at)
    WHERE parent_id IS NOT NULL;

SELECT attach_updated_at('comments');

CREATE TABLE comment_reactions (
    comment_id      uuid        NOT NULL REFERENCES comments(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reaction        text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (comment_id, user_id),
    CONSTRAINT comment_reactions_len CHECK (char_length(reaction) BETWEEN 1 AND 32)
);

CREATE INDEX comment_reactions_comment_idx ON comment_reactions (comment_id);

-- --- Saved content (with folders) -------------------------------------------
CREATE TABLE saved_folders (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            text        NOT NULL,
    position        integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT saved_folders_name_len CHECK (char_length(name) BETWEEN 1 AND 40)
);

CREATE UNIQUE INDEX saved_folders_user_name_unique ON saved_folders (user_id, name);

SELECT attach_updated_at('saved_folders');

CREATE TABLE saved_items (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'post' | 'video' | 'story' | 'message'
    item_type       text        NOT NULL,
    -- Polymorphic reference to the saved entity.
    item_id         uuid        NOT NULL,
    folder_id       uuid        REFERENCES saved_folders(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT saved_items_type_check
        CHECK (item_type IN ('post', 'video', 'story', 'message'))
);

CREATE UNIQUE INDEX saved_items_unique ON saved_items (user_id, item_type, item_id);
CREATE INDEX saved_items_user_idx ON saved_items (user_id, created_at DESC);

-- --- Hashtags ---------------------------------------------------------------
CREATE TABLE hashtags (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Stored lower-case without the leading '#'.
    tag             citext      NOT NULL,
    post_count      integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT hashtags_format CHECK (tag ~ '^[a-z0-9_]{1,64}$'),
    CONSTRAINT hashtags_post_count_non_negative CHECK (post_count >= 0)
);

CREATE UNIQUE INDEX hashtags_tag_unique ON hashtags (tag);

SELECT attach_updated_at('hashtags');

CREATE TABLE post_hashtags (
    post_id         uuid        NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    hashtag_id      uuid        NOT NULL REFERENCES hashtags(id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (post_id, hashtag_id)
);

CREATE INDEX post_hashtags_hashtag_idx
    ON post_hashtags (hashtag_id, created_at DESC);

-- --- Mentions (@username across posts/comments/messages) --------------------
CREATE TABLE mentions (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Who was mentioned.
    mentioned_user_id uuid      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Who wrote it.
    author_id       uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Where: 'message' | 'post' | 'comment' | 'story'
    context_type    text        NOT NULL,
    context_id      uuid        NOT NULL,
    -- Whether the mentioned user was notified (respects their settings).
    notified_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT mentions_context_type_check
        CHECK (context_type IN ('message', 'post', 'comment', 'story'))
);

CREATE INDEX mentions_user_idx ON mentions (mentioned_user_id, created_at DESC);
CREATE UNIQUE INDEX mentions_unique
    ON mentions (mentioned_user_id, context_type, context_id);

-- --- Stories (temporary content, default 24h) -------------------------------
CREATE TABLE stories (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- 'text' | 'image' | 'video'
    story_type      text        NOT NULL,
    -- Text content / caption / text-overlay payload.
    body            text,
    -- Styling for text stories: background, font, colour, position.
    payload         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Visibility (server-enforced, spec §12).
    visibility      text        NOT NULL DEFAULT 'contacts',
    -- When the story stops being visible (normally created_at + 24h).
    expires_at      timestamptz NOT NULL,
    -- Denormalised view counter.
    view_count      integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    CONSTRAINT stories_type_check CHECK (story_type IN ('text', 'image', 'video')),
    CONSTRAINT stories_visibility_check
        CHECK (visibility IN ('public', 'contacts', 'selected', 'private')),
    CONSTRAINT stories_view_count_non_negative CHECK (view_count >= 0),
    CONSTRAINT stories_expiry_after_creation CHECK (expires_at > created_at)
);

-- Active stories for a set of authors, newest first.
CREATE INDEX stories_author_idx ON stories (author_id, created_at DESC)
    WHERE deleted_at IS NULL;
-- Expiry sweeper.
CREATE INDEX stories_expiry_idx ON stories (expires_at)
    WHERE deleted_at IS NULL;

SELECT attach_updated_at('stories');

CREATE TABLE story_media (
    story_id        uuid        NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    media_id        uuid        NOT NULL REFERENCES media(id) ON DELETE RESTRICT,
    position        smallint    NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (story_id, media_id)
);

CREATE TABLE story_views (
    story_id        uuid        NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    viewer_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    viewed_at       timestamptz NOT NULL DEFAULT now(),
    -- How long the viewer watched (ms) — useful for the author's insight.
    watched_ms      integer,

    PRIMARY KEY (story_id, viewer_id),
    CONSTRAINT story_views_watched_non_negative
        CHECK (watched_ms IS NULL OR watched_ms >= 0)
);

CREATE INDEX story_views_story_idx ON story_views (story_id, viewed_at DESC);

CREATE TABLE story_reactions (
    story_id        uuid        NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reaction        text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (story_id, user_id),
    CONSTRAINT story_reactions_len CHECK (char_length(reaction) BETWEEN 1 AND 32)
);

-- --- Live sessions (schema ready for a scalable streaming backend) ----------
CREATE TABLE live_sessions (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    host_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           text,
    visibility      text        NOT NULL DEFAULT 'contacts',
    -- 'scheduled' | 'live' | 'ended' | 'cancelled'
    status          text        NOT NULL DEFAULT 'scheduled',
    -- Ingest/playback identifiers issued by the streaming provider.
    stream_key_ref  text,
    playback_ref    text,
    scheduled_for   timestamptz,
    started_at      timestamptz,
    ended_at        timestamptz,
    -- Denormalised counters.
    peak_viewers    integer     NOT NULL DEFAULT 0,
    viewer_count    integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT live_sessions_status_check
        CHECK (status IN ('scheduled', 'live', 'ended', 'cancelled')),
    CONSTRAINT live_sessions_visibility_check
        CHECK (visibility IN ('public', 'contacts', 'selected', 'private')),
    CONSTRAINT live_sessions_counters_non_negative
        CHECK (peak_viewers >= 0 AND viewer_count >= 0)
);

CREATE INDEX live_sessions_host_idx ON live_sessions (host_id, created_at DESC);
CREATE INDEX live_sessions_live_idx ON live_sessions (created_at DESC)
    WHERE status = 'live';

SELECT attach_updated_at('live_sessions');

CREATE TABLE live_viewers (
    live_id         uuid        NOT NULL REFERENCES live_sessions(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at       timestamptz NOT NULL DEFAULT now(),
    left_at         timestamptz,

    PRIMARY KEY (live_id, user_id)
);

CREATE TABLE live_comments (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    live_id         uuid        NOT NULL REFERENCES live_sessions(id) ON DELETE CASCADE,
    author_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body            text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT live_comments_body_len CHECK (char_length(body) BETWEEN 1 AND 500)
);

CREATE INDEX live_comments_live_idx ON live_comments (live_id, created_at DESC);

CREATE TABLE live_reactions (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    live_id         uuid        NOT NULL REFERENCES live_sessions(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reaction        text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX live_reactions_live_idx ON live_reactions (live_id, created_at DESC);

-- --- App releases (self-hosted APK update manifest, spec §37-§44) -----------
CREATE TABLE app_releases (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 'android' (primary) | 'ios' | 'windows'
    platform                text        NOT NULL,
    -- Semantic version of the release, e.g. '1.2.0'.
    version_name            text        NOT NULL,
    -- Monotonically increasing Android versionCode. NEVER reused (spec §43).
    version_code            integer     NOT NULL,
    -- Clients below this version must update (mandatory update, spec §40).
    minimum_supported_code  integer     NOT NULL DEFAULT 0,
    -- Download URL for the signed APK (HTTPS).
    apk_url                 text        NOT NULL,
    -- SHA-256 of the APK for integrity verification (spec §39).
    sha256                  text        NOT NULL,
    -- APK signing certificate digest, so the client can verify it is really us.
    signer_sha256           text,
    -- Size in bytes (for progress UI and sanity checks).
    byte_size               bigint      NOT NULL,
    release_notes           text,
    -- Whether this release is mandatory for users above the minimum.
    is_mandatory            boolean     NOT NULL DEFAULT false,
    -- 'draft' | 'published' | 'revoked'
    status                  text        NOT NULL DEFAULT 'draft',
    published_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT app_releases_platform_check
        CHECK (platform IN ('android', 'ios', 'windows')),
    CONSTRAINT app_releases_status_check
        CHECK (status IN ('draft', 'published', 'revoked')),
    CONSTRAINT app_releases_version_code_positive CHECK (version_code > 0),
    CONSTRAINT app_releases_sha256_format CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT app_releases_byte_size_positive CHECK (byte_size > 0)
);

-- A versionCode may never be published twice for the same platform.
CREATE UNIQUE INDEX app_releases_platform_version_code_unique
    ON app_releases (platform, version_code);
-- Fast "what is the latest published release?" lookup.
CREATE INDEX app_releases_latest_idx
    ON app_releases (platform, version_code DESC)
    WHERE status = 'published';

SELECT attach_updated_at('app_releases');

-- --- Audit log (cross-cutting, spec §27 & §59) ------------------------------
CREATE TABLE audit_logs (
    id              bigserial   PRIMARY KEY,
    -- Who performed the action (null for system actions).
    actor_id        uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- 'user' | 'system' | 'moderator'
    actor_type      text        NOT NULL DEFAULT 'user',
    -- What was done, namespaced, e.g. 'message.delete', 'session.revoke'.
    action          text        NOT NULL,
    -- The affected entity, if any.
    target_type     text,
    target_id       uuid,
    -- Non-secret context (IP is stored separately; never message contents).
    context         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    ip_address      inet,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT audit_logs_actor_type_check
        CHECK (actor_type IN ('user', 'system', 'moderator'))
);

CREATE INDEX audit_logs_actor_idx ON audit_logs (actor_id, created_at DESC);
CREATE INDEX audit_logs_action_idx ON audit_logs (action, created_at DESC);
CREATE INDEX audit_logs_target_idx ON audit_logs (target_type, target_id);

INSERT INTO schema_migrations (version, description)
VALUES ('0007', 'social (posts, comments, stories, live, saved, hashtags, releases, audit)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
