-- =============================================================================
-- ATHUR · Schema verification test (run AFTER migrations)
-- =============================================================================
-- Verifies the schema's real guarantees, not just that objects exist:
--   * required tables/columns present
--   * unique constraints actually reject duplicates
--   * CHECK constraints actually reject invalid data
--   * foreign keys actually enforce referential integrity
--   * cascade behaviour is what we expect
--
-- Run with:
--   psql "<url>" -v ON_ERROR_STOP=1 -f db/scripts/schema_test.sql
--
-- The script raises an exception on the FIRST failure, so a non-zero exit code
-- means the schema is not behaving as specified. Every test runs inside one
-- transaction that is rolled back at the end, so it leaves no data behind.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    missing text;
    cnt int;
BEGIN
    -- --- 1. All domain tables must exist -----------------------------------
    SELECT string_agg(t, ', ') INTO missing
    FROM (VALUES
        ('users'), ('user_profiles'), ('auth_identities'), ('phone_numbers'),
        ('email_addresses'), ('password_credentials'), ('otp_challenges'),
        ('devices'), ('sessions'), ('refresh_tokens'), ('security_events'),
        ('contacts'), ('friend_requests'), ('blocked_users'),
        ('privacy_settings'), ('story_privacy_exceptions'),
        ('notification_settings'), ('chat_notification_overrides'),
        ('user_settings'), ('account_deletion_requests'),
        ('chats'), ('chat_members'), ('messages'), ('message_edits'),
        ('message_deletions'), ('message_visibility'), ('message_reactions'),
        ('message_delivery_status'), ('pinned_messages'), ('starred_messages'),
        ('chat_folders'), ('chat_folder_items'),
        ('groups'), ('group_role_assignments'), ('group_invites'),
        ('group_join_requests'),
        ('media'), ('message_attachments'), ('presence'), ('typing_indicators'),
        ('calls'), ('call_participants'), ('call_events'),
        ('call_quality_samples'), ('call_summaries'),
        ('push_tokens'), ('notifications'), ('reports'),
        ('posts'), ('post_media'), ('post_visibility_exceptions'),
        ('post_reactions'), ('comments'), ('comment_reactions'),
        ('saved_folders'), ('saved_items'), ('hashtags'), ('post_hashtags'),
        ('mentions'), ('stories'), ('story_media'), ('story_views'),
        ('story_reactions'), ('live_sessions'), ('live_viewers'),
        ('live_comments'), ('live_reactions'), ('app_releases'), ('audit_logs'),
        ('schema_migrations')
    ) AS needed(t)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = needed.t
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing tables: %', missing;
    END IF;

    -- --- 2. All migrations recorded ----------------------------------------
    SELECT count(*) INTO cnt FROM schema_migrations;
    IF cnt < 7 THEN
        RAISE EXCEPTION 'Expected >=7 applied migrations, found %', cnt;
    END IF;

    RAISE NOTICE 'OK: all tables present, % migrations recorded', cnt;
END $$;

-- =============================================================================
-- 3. Constraint behaviours — proven with real INSERT attempts
-- =============================================================================
DO $$
DECLARE
    u1 uuid := gen_random_uuid();
    u2 uuid := gen_random_uuid();
    c1 uuid := gen_random_uuid();
    m1 uuid := gen_random_uuid();
    cnt int;
BEGIN
    -- --- users -------------------------------------------------------------
    INSERT INTO users (id, username) VALUES (u1, 'ahmed_test');
    INSERT INTO users (id, username) VALUES (u2, 'sara_test');

    -- Username uniqueness (case-insensitive via citext) must be enforced.
    BEGIN
        INSERT INTO users (id, username) VALUES (gen_random_uuid(), 'AHMED_TEST');
        RAISE EXCEPTION 'FAIL: duplicate username was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: duplicate username rejected';
    END;

    -- Username format CHECK must be enforced.
    BEGIN
        INSERT INTO users (id, username) VALUES (gen_random_uuid(), 'BAD NAME!');
        RAISE EXCEPTION 'FAIL: invalid username format was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: invalid username format rejected';
    END;

    -- Status CHECK must be enforced.
    BEGIN
        INSERT INTO users (id, status) VALUES (gen_random_uuid(), 'banana');
        RAISE EXCEPTION 'FAIL: invalid status was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: invalid user status rejected';
    END;

    -- --- auth_identities: linking guard -----------------------------------
    INSERT INTO auth_identities (user_id, provider, provider_uid)
    VALUES (u1, 'phone', '+201000001');
    -- The SAME phone identity cannot attach to a second account.
    BEGIN
        INSERT INTO auth_identities (user_id, provider, provider_uid)
        VALUES (u2, 'phone', '+201000001');
        RAISE EXCEPTION 'FAIL: same identity linked to two accounts';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: identity cannot be linked twice';
    END;

    -- --- phone E.164 CHECK -------------------------------------------------
    BEGIN
        INSERT INTO phone_numbers (user_id, e164) VALUES (u1, '0100001');
        RAISE EXCEPTION 'FAIL: non-E.164 phone number was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: non-E.164 phone rejected';
    END;

    -- --- chats: direct_key requirement + uniqueness ------------------------
    INSERT INTO chats (id, chat_type, direct_key, created_by)
    VALUES (c1, 'direct', least(u1,u2)::text || ':' || greatest(u1,u2)::text, u1);

    BEGIN
        INSERT INTO chats (chat_type, direct_key)
        VALUES ('direct', least(u1,u2)::text || ':' || greatest(u1,u2)::text);
        RAISE EXCEPTION 'FAIL: duplicate direct chat was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: duplicate direct chat rejected';
    END;

    -- A group chat must NOT have a direct_key.
    BEGIN
        INSERT INTO chats (chat_type, direct_key) VALUES ('group', 'x:y');
        RAISE EXCEPTION 'FAIL: group chat accepted a direct_key';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: group chat with direct_key rejected';
    END;

    -- --- messages: type + body CHECK + idempotency -------------------------
    INSERT INTO chat_members (chat_id, user_id) VALUES (c1, u1), (c1, u2);

    BEGIN
        INSERT INTO messages (id, chat_id, sender_id, message_type, body)
        VALUES (gen_random_uuid(), c1, u1, 'banana', 'hi');
        RAISE EXCEPTION 'FAIL: invalid message_type accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: invalid message type rejected';
    END;

    -- A text message with no body must be rejected.
    BEGIN
        INSERT INTO messages (chat_id, sender_id, message_type, body)
        VALUES (c1, u1, 'text', NULL);
        RAISE EXCEPTION 'FAIL: empty text message accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: text message without body rejected';
    END;

    -- client_message_id idempotency: same key twice must be rejected.
    INSERT INTO messages (id, chat_id, sender_id, message_type, body, client_message_id)
    VALUES (m1, c1, u1, 'text', 'hello', 'client-abc-1');
    BEGIN
        INSERT INTO messages (chat_id, sender_id, message_type, body, client_message_id)
        VALUES (c1, u1, 'text', 'hello again', 'client-abc-1');
        RAISE EXCEPTION 'FAIL: duplicate client_message_id accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: duplicate client_message_id rejected (idempotent send)';
    END;

    -- --- message_delivery_status: status CHECK ----------------------------
    BEGIN
        INSERT INTO message_delivery_status (message_id, recipient_id, status)
        VALUES (m1, u2, 'teleported');
        RAISE EXCEPTION 'FAIL: invalid delivery status accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: invalid delivery status rejected';
    END;

    -- --- FK enforcement: message in a non-existent chat --------------------
    BEGIN
        INSERT INTO messages (chat_id, sender_id, message_type, body)
        VALUES (gen_random_uuid(), u1, 'text', 'orphan');
        RAISE EXCEPTION 'FAIL: message accepted a missing chat FK';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: message foreign key enforced';
    END;

    -- --- calls: direct call must name a callee ----------------------------
    BEGIN
        INSERT INTO calls (call_type, media_type, initiator_id, callee_id)
        VALUES ('direct', 'audio', u1, NULL);
        RAISE EXCEPTION 'FAIL: direct call without callee accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: direct call without callee rejected';
    END;

    -- --- call_quality_samples: packet-loss range CHECK --------------------
    BEGIN
        INSERT INTO call_quality_samples (call_id, offset_ms, packet_loss_ratio)
        VALUES (gen_random_uuid(), 0, 5.0);
        RAISE EXCEPTION 'FAIL: out-of-range packet loss accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK: out-of-range metric rejected';
    END;

    -- --- app_releases: versionCode cannot repeat --------------------------
    INSERT INTO app_releases (
        platform, version_name, version_code, minimum_supported_code,
        apk_url, sha256, byte_size, status
    ) VALUES (
        'android', '1.0.0', 1, 0,
        'https://example.invalid/athur-1.0.0.apk',
        repeat('a', 64), 1000, 'published'
    );
    BEGIN
        INSERT INTO app_releases (
            platform, version_name, version_code, minimum_supported_code,
            apk_url, sha256, byte_size
        ) VALUES (
            'android', '1.0.0-dup', 1, 0,
            'https://example.invalid/other.apk', repeat('b', 64), 2000
        );
        RAISE EXCEPTION 'FAIL: duplicate versionCode accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: duplicate versionCode rejected';
    END;

    -- --- ON DELETE CASCADE: deleting a user removes their profile ----------
    INSERT INTO user_profiles (user_id, display_name) VALUES (u2, 'Sara');
    DELETE FROM users WHERE id = u2;
    SELECT count(*) INTO cnt FROM user_profiles WHERE user_id = u2;
    IF cnt <> 0 THEN
        RAISE EXCEPTION 'FAIL: profile was not cascade-deleted with the user';
    END IF;
    RAISE NOTICE 'OK: cascade delete works (profile removed with user)';

    RAISE NOTICE 'ALL SCHEMA TESTS PASSED';
END $$;

-- Leave no test data behind.
ROLLBACK;
