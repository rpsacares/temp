-- =============================================================================
-- Load-test weight data: cleanup
--
-- Deletes every synthetic row from sentinel.migrated_customers and
-- sentinel.customer (chunked by birth month, one commit per chunk), reclaims
-- space, then drops all lt_ helper objects. Run with psql in autocommit mode
-- against the cluster writer endpoint.
--
-- Deletion requires all markers:
--   migrated_customers: name_suffix = 'LT' AND ucms_record_hash IS NULL
--                       AND legacy_ids IS NULL
--   customer:           name_suffix = 'LT'
--                       AND created_at = 1999-01-01 00:00:00+00
--
-- GIN indexes keep bloat after mass deletes. To return trigram indexes to
-- their pre-load size, rebuild them after VACUUM, e.g.
--   REINDEX INDEX CONCURRENTLY sentinel.ix_customer_full_name_trgm;
-- (for migrated_customers, reindex each partition's index individually).
-- =============================================================================

\set ON_ERROR_STOP on
\timing on
SET statement_timeout = 0;

CALL sentinel.lt_cleanup();

VACUUM (ANALYZE) sentinel.migrated_customers;
VACUUM (ANALYZE) sentinel.customer;

DROP PROCEDURE IF EXISTS sentinel.lt_cleanup();
DROP PROCEDURE IF EXISTS sentinel.lt_load_customer(int, date, date, boolean);
DROP PROCEDURE IF EXISTS sentinel.lt_load_migrated_customers(int, date, date, boolean);
DROP FUNCTION  IF EXISTS sentinel.lt_chunks(date, date, boolean);
DROP FUNCTION  IF EXISTS sentinel.lt_jitter_day(date);
DROP FUNCTION  IF EXISTS sentinel.lt_scramble_id(text);
DROP FUNCTION  IF EXISTS sentinel.lt_last_name();
DROP FUNCTION  IF EXISTS sentinel.lt_first_name();
