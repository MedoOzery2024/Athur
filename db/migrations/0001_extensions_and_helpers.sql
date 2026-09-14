-- =============================================================================
-- ATHUR · Migration 0001 — Extensions, shared helpers, migration bookkeeping
-- =============================================================================
-- This migration establishes the primitives every later migration relies on:
--   * extensions (UUID generation, trigram/partial search, crypto)
--   * a shared `set_updated_at()` trigger so updated_at is always truthful
--   * the migration ledger table
--
-- Conventions used across ALL Athur migrations:
--   * Primary keys are UUID v4 (`gen_random_uuid()`), never serial ints, so IDs
--     are safe to expose to clients and never leak row counts.
--   * Timestamps are `timestamptz` (UTC). Never naive `timestamp`.
--   * `created_at` defaults to now(); `updated_at` is maintained by trigger.
--   * Soft delete uses a nullable `deleted_at` column where retention matters.
--   * Every foreign key is explicit with an intentional ON DELETE action.
-- =============================================================================

BEGIN;

-- --- Extensions ------------------------------------------------------------
-- pgcrypto provides gen_random_uuid() on older servers; pg_trgm powers the
-- indexed fuzzy search required by the "advanced search" requirement.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- citext: case-insensitive text, used for usernames and email addresses so
-- 'Ahmed' and 'ahmed' cannot both be registered.
CREATE EXTENSION IF NOT EXISTS citext;

-- --- Migration ledger -------------------------------------------------------
-- Records exactly which migrations have run, so scripts are idempotent and the
-- CI pipeline can verify schema state (project spec §62).
CREATE TABLE IF NOT EXISTS schema_migrations (
    version      text        PRIMARY KEY,
    description  text        NOT NULL,
    applied_at   timestamptz NOT NULL DEFAULT now()
);

-- --- Shared trigger function: keep updated_at accurate ----------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- --- Helper: attach the standard updated_at trigger -------------------------
-- Usage: SELECT attach_updated_at('users');
CREATE OR REPLACE FUNCTION attach_updated_at(target_table regclass)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format(
        'DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON %1$s;
         CREATE TRIGGER trg_%1$s_updated_at
         BEFORE UPDATE ON %1$s
         FOR EACH ROW EXECUTE FUNCTION set_updated_at();',
        target_table
    );
END;
$$;

INSERT INTO schema_migrations (version, description)
VALUES ('0001', 'extensions, migration ledger, shared helpers')
ON CONFLICT (version) DO NOTHING;

COMMIT;
