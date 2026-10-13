-- =============================================================================
-- Load-test weight data: run
--
-- Prerequisite: 00-setup.sql. Run with psql in autocommit mode against the
-- cluster writer endpoint, e.g.
--   psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" \
--        -f loadtest/10-run.sql
--
-- Each original migrated_customers row yields 4 synthetic migrated_customers
-- rows and 4 synthetic customer rows. Both loads read only original (non-LT)
-- rows, so their order does not matter. Safe to stop and re-run: chunks that
-- already contain LT rows are skipped. A chunk interrupted mid-insert rolls
-- back as a unit and is redone on the next run.
--
-- Trial run first on one month to check timing:
--   CALL sentinel.lt_load_migrated_customers(4, '1990-01-01', '1990-02-01', false);
--   CALL sentinel.lt_load_customer(4, '1990-01-01', '1990-02-01', false);
-- A later full run skips the trial month automatically.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on
SET statement_timeout = 0;

CALL sentinel.lt_load_migrated_customers(4);
CALL sentinel.lt_load_customer(4);

ANALYZE sentinel.migrated_customers;
ANALYZE sentinel.customer;

-- Spot checks (each scans the table; run individually as needed):
--   SELECT count(*) FROM sentinel.migrated_customers WHERE name_suffix = 'LT';
--   SELECT count(*) FROM sentinel.customer
--    WHERE name_suffix = 'LT' AND created_at = '1999-01-01 00:00:00+00';
--   SELECT tableoid::regclass AS partition, count(*) FILTER (WHERE name_suffix = 'LT') AS lt,
--          count(*) FILTER (WHERE name_suffix IS DISTINCT FROM 'LT') AS original
--     FROM sentinel.migrated_customers GROUP BY 1 ORDER BY 1;
--   SELECT indexrelid::regclass, pg_size_pretty(pg_relation_size(indexrelid))
--     FROM pg_index
--    WHERE indrelid IN ('sentinel.customer'::regclass)
--       OR indrelid IN (SELECT inhrelid FROM pg_inherits
--                        WHERE inhparent = 'sentinel.migrated_customers'::regclass)
--    ORDER BY 1;
