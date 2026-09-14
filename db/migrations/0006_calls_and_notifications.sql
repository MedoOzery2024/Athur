-- =============================================================================
-- ATHUR · Migration 0006 — Calls & notifications
-- =============================================================================
-- Domain: call lifecycle, call quality/recovery statistics, push tokens and
-- the notification feed.
--
-- Key design decisions:
--   * A call is a first-class entity with explicit lifecycle states, so call
--     history, missed-call detection and analytics are all reliable.
--   * `call_events` records a REAL timeline (started, ice_connected, network
--     changed, ice_restart, recovered, ended …). This powers the unique
--     "Call Health Timeline" and "Recovery Score" features with real data
--     (spec §20 A/B) — no synthetic values.
--   * `call_quality_samples` stores periodic metric snapshots captured from
--     the WebRTC stats API, so post-call diagnostics are genuine.
--   * Push tokens are per-device; a device may have several (token rotation).
-- =============================================================================

BEGIN;

-- --- Calls ------------------------------------------------------------------
CREATE TABLE calls (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 'direct' | 'group' (schema ready for group calls, spec §18)
    call_type           text        NOT NULL,
    -- 'audio' | 'video'
    media_type          text        NOT NULL,
    -- Caller.
    initiator_id        uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- For direct calls: the single callee. NULL for group calls.
    callee_id           uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Associated chat (a call belongs to a conversation).
    chat_id             uuid        REFERENCES chats(id) ON DELETE SET NULL,
    -- Lifecycle state:
    --   'ringing'    → callee(s) being alerted
    --   'active'     → media flowing between at least two parties
    --   'ended'      → completed normally
    --   'missed'     → never answered before timeout
    --   'rejected'   → explicitly declined
    --   'cancelled'  → caller hung up before answer
    --   'failed'     → connection could not be established
    state               text        NOT NULL DEFAULT 'ringing',
    -- Who ended the call (for history rendering).
    ended_by            uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Why it ended: 'hangup' | 'rejected' | 'timeout' | 'cancelled' | 'failed'
    end_reason          text,
    started_at          timestamptz NOT NULL DEFAULT now(),
    -- When the first remote party's media was connected (real answer time).
    answered_at         timestamptz,
    ended_at            timestamptz,
    -- Seconds of actual conversation (computed on end; null while running).
    duration_seconds    integer,
    -- Ring timeout used for this call (so missed detection is reproducible).
    ring_timeout_seconds integer    NOT NULL DEFAULT 45,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT calls_type_check CHECK (call_type IN ('direct', 'group')),
    CONSTRAINT calls_media_check CHECK (media_type IN ('audio', 'video')),
    CONSTRAINT calls_state_check CHECK (state IN
        ('ringing', 'active', 'ended', 'missed', 'rejected', 'cancelled', 'failed')),
    CONSTRAINT calls_end_reason_check CHECK (end_reason IS NULL OR end_reason IN
        ('hangup', 'rejected', 'timeout', 'cancelled', 'failed')),
    -- A direct call must name exactly one callee.
    CONSTRAINT calls_direct_has_callee
        CHECK ((call_type = 'direct') = (callee_id IS NOT NULL)),
    -- Duration, once known, cannot be negative.
    CONSTRAINT calls_duration_non_negative
        CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

-- Call history: my calls, newest first (initiator or callee).
CREATE INDEX calls_initiator_idx ON calls (initiator_id, started_at DESC);
CREATE INDEX calls_callee_idx ON calls (callee_id, started_at DESC);
CREATE INDEX calls_chat_idx ON calls (chat_id, started_at DESC);
-- Find calls still ringing, so a timeout sweeper can mark them missed.
CREATE INDEX calls_pending_idx ON calls (started_at)
    WHERE state = 'ringing';

SELECT attach_updated_at('calls');

-- --- Call participants ------------------------------------------------------
CREATE TABLE call_participants (
    call_id         uuid        NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Per-participant lifecycle: 'invited' | 'ringing' | 'joined' | 'left'
    -- | 'declined' | 'missed' | 'failed'
    state           text        NOT NULL DEFAULT 'invited',
    -- 'caller' | 'callee'
    role            text        NOT NULL,
    joined_at       timestamptz,
    left_at         timestamptz,
    -- Per-participant duration (differs from call duration in group calls).
    duration_seconds integer,
    -- Whether this participant's mic/camera were on at the end.
    mic_enabled     boolean     NOT NULL DEFAULT true,
    camera_enabled  boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (call_id, user_id),
    CONSTRAINT call_participants_state_check CHECK (state IN
        ('invited', 'ringing', 'joined', 'left', 'declined', 'missed', 'failed')),
    CONSTRAINT call_participants_role_check CHECK (role IN ('caller', 'callee')),
    CONSTRAINT call_participants_duration_non_negative
        CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

CREATE INDEX call_participants_user_idx
    ON call_participants (user_id, created_at DESC);

SELECT attach_updated_at('call_participants');

-- --- Call events (REAL timeline powering the health timeline feature) -------
CREATE TABLE call_events (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id         uuid        NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    -- Which participant this event concerns (null = call-wide).
    user_id         uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Event kinds are deliberately specific so the timeline is informative:
    --   'call_started' | 'ringing' | 'answered' | 'ice_connected'
    --   | 'network_changed' | 'network_restored' | 'ice_disconnected'
    --   | 'ice_restart' | 'ice_failed' | 'reconnected' | 'quality_degraded'
    --   | 'call_ended' | 'turn_used' | 'selected_candidate_pair'
    event_type      text        NOT NULL,
    -- Structured detail: e.g. {"from":"wifi","to":"mobile"} for network_changed.
    detail          jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Offset from call start — makes the timeline renderable without clocks.
    offset_ms       integer,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT call_events_type_check CHECK (event_type IN
        ('call_started', 'ringing', 'answered', 'ice_connected',
         'selected_candidate_pair', 'turn_used', 'network_changed',
         'network_restored', 'ice_disconnected', 'ice_restart', 'ice_failed',
         'reconnected', 'quality_degraded', 'call_ended'))
);

CREATE INDEX call_events_call_idx ON call_events (call_id, created_at);

-- --- Call quality samples (periodic snapshots from WebRTC stats) ------------
-- Written every few seconds during an active call and once at the end. Every
-- column has a real source in the WebRTC statistics API (spec §7/§9).
CREATE TABLE call_quality_samples (
    id                  bigserial   PRIMARY KEY,
    call_id             uuid        NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    user_id             uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Offset from call start (ms) so samples form a genuine timeline.
    offset_ms           integer     NOT NULL,
    -- Connection state at sample time (mirrors RTCPeerConnectionState).
    peer_connection_state text,
    ice_connection_state  text,
    -- Network the device was on (from platform connectivity APIs).
    network_type        text,
    -- Candidate types of the SELECTED pair (host | srflx | prflx | relay).
    local_candidate_type  text,
    remote_candidate_type text,
    -- Whether a TURN relay candidate was in use for the selected pair.
    using_turn          boolean     NOT NULL DEFAULT false,
    -- Transport of the selected pair: 'udp' | 'tcp'.
    transport           text,
    -- Metrics from getStats(): all nullable because not every sample has them.
    rtt_ms              real,
    jitter_ms           real,
    packet_loss_ratio   real,
    packets_lost        integer,
    inbound_bitrate_bps integer,
    outbound_bitrate_bps integer,
    audio_codec         text,
    video_codec         text,
    video_width         integer,
    video_height        integer,
    video_fps           real,
    audio_level         real,
    -- Deterministic quality tier computed server- or client-side from
    -- documented thresholds (spec §9). Stored so history is reproducible.
    quality_tier        text,
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT call_quality_tier_check
        CHECK (quality_tier IS NULL OR quality_tier IN
               ('excellent', 'good', 'fair', 'poor', 'critical')),
    CONSTRAINT call_quality_loss_range
        CHECK (packet_loss_ratio IS NULL OR
               (packet_loss_ratio >= 0 AND packet_loss_ratio <= 1)),
    CONSTRAINT call_quality_transport_check
        CHECK (transport IS NULL OR transport IN ('udp', 'tcp'))
);

CREATE INDEX call_quality_call_idx
    ON call_quality_samples (call_id, offset_ms);

-- --- Call summary (post-call deterministic stats; powers Recovery Score) ----
CREATE TABLE call_summaries (
    call_id                 uuid        PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
    -- Counts of significant events (truthful aggregates of call_events).
    ice_restart_count       integer     NOT NULL DEFAULT 0,
    reconnection_count      integer     NOT NULL DEFAULT 0,
    network_change_count    integer     NOT NULL DEFAULT 0,
    -- Aggregate quality metrics across the call.
    avg_rtt_ms              real,
    max_rtt_ms              real,
    avg_jitter_ms           real,
    avg_packet_loss_ratio   real,
    max_packet_loss_ratio   real,
    avg_inbound_bitrate_bps integer,
    avg_outbound_bitrate_bps integer,
    -- Whether TURN was ever used (i.e. direct P2P was impossible).
    used_turn               boolean     NOT NULL DEFAULT false,
    -- Deterministic 0-100 stability score derived from the above metrics using
    -- documented weights. NOT machine learning, NOT AI (spec §20 B).
    recovery_score          integer,
    -- Time from call start until media first flowed (ms) — setup quality.
    connection_setup_ms     integer,
    created_at              timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT call_summaries_score_range
        CHECK (recovery_score IS NULL OR (recovery_score >= 0 AND recovery_score <= 100)),
    CONSTRAINT call_summaries_counts_non_negative
        CHECK (ice_restart_count >= 0 AND reconnection_count >= 0
               AND network_change_count >= 0)
);

-- --- Push tokens (per device; tokens rotate) --------------------------------
CREATE TABLE push_tokens (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id       uuid        REFERENCES devices(id) ON DELETE CASCADE,
    -- 'fcm' (Android/web) | 'apns' (iOS) — FCM covers both in practice.
    provider        text        NOT NULL DEFAULT 'fcm',
    -- The registration token. Treated as sensitive (it can push to the device).
    token           text        NOT NULL,
    -- Platform-specific project/sender id the token belongs to.
    app_id          text,
    is_active       boolean     NOT NULL DEFAULT true,
    last_used_at    timestamptz NOT NULL DEFAULT now(),
    -- FCM rotates tokens; the app uploads the new one and we deactivate the old.
    replaced_by_id  uuid        REFERENCES push_tokens(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT push_tokens_provider_check CHECK (provider IN ('fcm', 'apns'))
);

-- A token string is globally unique — it identifies one app install.
CREATE UNIQUE INDEX push_tokens_token_unique ON push_tokens (token);
CREATE INDEX push_tokens_user_active_idx
    ON push_tokens (user_id) WHERE is_active;

SELECT attach_updated_at('push_tokens');

-- --- Notifications (the user-visible feed) ----------------------------------
CREATE TABLE notifications (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Notification kind drives copy and deep-link target.
    kind            text        NOT NULL,
    -- Who caused it (for avatar rendering); null for system notifications.
    actor_id        uuid        REFERENCES users(id) ON DELETE SET NULL,
    -- Deep-link target. Exactly one of these is typically set.
    chat_id         uuid        REFERENCES chats(id) ON DELETE CASCADE,
    message_id      uuid        REFERENCES messages(id) ON DELETE CASCADE,
    call_id         uuid        REFERENCES calls(id) ON DELETE CASCADE,
    -- Additional structured payload (e.g. group name, reaction emoji).
    payload         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- Title/body are generated server-side so clients render consistently.
    title           text,
    body            text,
    -- Read state for the in-app notification centre.
    read_at         timestamptz,
    -- Whether a push was actually dispatched (for debugging duplicates).
    pushed_at       timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT notifications_kind_check CHECK (kind IN
        ('new_message', 'message_reply', 'message_reaction', 'mention',
         'incoming_call', 'missed_call', 'friend_request',
         'friend_request_accepted', 'group_event', 'story_reaction',
         'story_reply', 'post_reaction', 'post_comment', 'comment_reply',
         'live_started', 'security_alert', 'system'))
);

CREATE INDEX notifications_user_idx
    ON notifications (user_id, created_at DESC);
CREATE INDEX notifications_user_unread_idx
    ON notifications (user_id) WHERE read_at IS NULL;

-- --- Reports / moderation (spec §30) ----------------------------------------
CREATE TABLE reports (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- What is being reported: 'user' | 'message' | 'post' | 'comment'
    -- | 'story' | 'video' | 'group'
    target_type     text        NOT NULL,
    -- The id of the reported entity (polymorphic on purpose: reports span
    -- many tables, and a soft reference is correct here).
    target_id       uuid        NOT NULL,
    -- Reason codes are a fixed vocabulary so moderation is consistent.
    reason          text        NOT NULL,
    details         text,
    -- 'pending' | 'reviewing' | 'actioned' | 'dismissed'
    status          text        NOT NULL DEFAULT 'pending',
    reviewed_by     uuid        REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at     timestamptz,
    resolution_note text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT reports_target_type_check CHECK (target_type IN
        ('user', 'message', 'post', 'comment', 'story', 'video', 'group')),
    CONSTRAINT reports_reason_check CHECK (reason IN
        ('spam', 'harassment', 'hate_speech', 'violence', 'nudity',
         'misinformation', 'impersonation', 'scam', 'other')),
    CONSTRAINT reports_status_check
        CHECK (status IN ('pending', 'reviewing', 'actioned', 'dismissed')),
    CONSTRAINT reports_details_len
        CHECK (details IS NULL OR char_length(details) <= 1000)
);

-- One open report per (reporter, target) — prevents report flooding.
CREATE UNIQUE INDEX reports_one_open_per_target
    ON reports (reporter_id, target_type, target_id)
    WHERE status IN ('pending', 'reviewing');

CREATE INDEX reports_status_idx ON reports (status, created_at);

SELECT attach_updated_at('reports');

INSERT INTO schema_migrations (version, description)
VALUES ('0006', 'calls, call events/quality, push tokens, notifications, reports')
ON CONFLICT (version) DO NOTHING;

COMMIT;
