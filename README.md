# Load-Test Weight Data

SQL scripts that inflate `sentinel.migrated_customers` and `sentinel.customer` with synthetic rows so the trigram GIN indexes (`first_name`, `last_name`, `full_name`) and the birth-date partitions carry production-scale weight. The rows are not meant to be searched.

SIT and non-production environments only.

## How it works

The loader copies rows that already exist. For every original `migrated_customers` row it writes N synthetic `migrated_customers` rows and N synthetic `customer` rows born in the same month. It does not create a starting data set.

| Column | Synthetic value |
| --- | --- |
| `first_name`, `last_name` | Random, realistic Filipino names (~5M possible given names, ~2.9M possible surnames, weighted toward common names) |
| `name_suffix` | `LT` (load-test marker, also visible in `full_name`) |
| `full_name` | Recomputed from the new names |
| `birth_date` | Same month as the original, random day. Partition distribution is preserved, and copies spread across the month's days instead of stacking on one date |
| `gov_id_type` / `gov_id_number` | Type copied; digits in the number randomized, format kept |
| `ucms_record_hash`, `legacy_ids`, `email`, `mobile_number` | NULL on `migrated_customers` |
| `customer.created_at` / `updated_at` | `1999-01-01 00:00:00+00`, which keeps synthetic rows out of every FinCense EOD export window |
| Everything else | Copied |

The load runs one birth month at a time (1945-01 to 2014-12, plus one chunk for NULL or out-of-range dates) and commits after each month. A month that already contains `LT` rows is skipped, so the load can be stopped and re-run without duplicating rows.

## Files

| File | Purpose |
| --- | --- |
| `00-setup.sql` | Creates the name generators, gov-ID scrambler, and the load and cleanup procedures in the `sentinel` schema |
| `10-run.sql` | Runs both loads at 4 copies per original row, then `ANALYZE` |
| `99-cleanup.sql` | Deletes every synthetic row, vacuums both tables, drops the helper objects |

## Prerequisites

- `psql` connected to the Aurora **writer endpoint**, not RDS Proxy. The procedures commit inside `CALL`, which requires a direct session.
- Autocommit mode (psql default). Do not wrap `CALL` in `BEGIN`.
- A role with `CREATE` on schema `sentinel` and `SELECT`, `INSERT`, `DELETE` on both tables.
- `migrated_customers` already holds the original rows to multiply.

## Running

Set up the helpers once:

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/00-setup.sql
```

Trial one month first to check timing on the target instance:

```sql
CALL sentinel.lt_load_migrated_customers(4, '1990-01-01', '1990-02-01', false);
CALL sentinel.lt_load_customer(4, '1990-01-01', '1990-02-01', false);
```

Run the full load (the trial month is skipped automatically):

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/10-run.sql
```

### Parameters

Both procedures take `(p_copies, p_from, p_to, p_include_outside)`:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `p_copies` | 4 | Synthetic rows per original row |
| `p_from` | `1945-01-01` | First birth month to load |
| `p_to` | `2015-01-01` | Exclusive end birth month |
| `p_include_outside` | `true` | Also load NULL and out-of-range birth dates |

To reach a target size, set `p_copies` to (target ÷ originals) − 1. For example, 1M originals to 20M total is `CALL sentinel.lt_load_migrated_customers(19);`. Edit the `CALL` lines in `10-run.sql` or run the procedures directly.

## Timings

Measured on a local PostgreSQL 16 container (2 vCPU, 4 GiB, `fsync=off`), `migrated_customers` only, indexes absent during the load. Aurora timings will differ; use the one-month trial to calibrate.

| Step | 1M to 20M (19 copies) |
| --- | --- |
| `migrated_customers` load, all partitions | 4 min 46 s |
| `migrated_customers` load, one partition | 6 min 29 s to 7 min 33 s |
| `first_name` GIN build | 40 s |
| `last_name` GIN build | 29 to 36 s |
| `full_name` GIN build | 85 to 94 s |
| `birth_date` btree build | 13 s |
| `VACUUM ANALYZE` | 20 s |

The `customer` load was not timed at 20M. It writes the same row count with fewer columns, so expect a similar order of magnitude.

Loading into tables whose trigram indexes already exist is slower, because every insert updates three GIN indexes. For the fastest load, build the post-batch-load indexes after loading. To measure insert-time index cost, load with indexes in place.

## Verifying

```sql
SELECT count(*) FROM sentinel.migrated_customers WHERE name_suffix = 'LT';
SELECT count(*) FROM sentinel.customer
 WHERE name_suffix = 'LT' AND created_at = '1999-01-01 00:00:00+00';
SELECT tableoid::regclass AS partition,
       count(*) FILTER (WHERE name_suffix = 'LT') AS synthetic,
       count(*) FILTER (WHERE name_suffix IS DISTINCT FROM 'LT') AS original
  FROM sentinel.migrated_customers GROUP BY 1 ORDER BY 1;
```

Each partition should hold `p_copies` × its original count in synthetic rows.

## Cleanup

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/99-cleanup.sql
```

A row is deleted only when every marker matches:

- `migrated_customers`: `name_suffix = 'LT'`, `ucms_record_hash IS NULL`, `legacy_ids IS NULL`
- `customer`: `name_suffix = 'LT'`, `created_at = 1999-01-01 00:00:00+00`

GIN indexes keep their bloat after a mass delete. Rebuild them with `REINDEX INDEX CONCURRENTLY` to return to pre-load size (on `migrated_customers`, reindex each partition's index individually).

## Known limitations

- Synthetic first and last names can coincide with a real person's name and birth date and appear as SIT search candidates. The `LT` suffix lowers full-name similarity only.
- `customer` is not partitioned in the current schema, so only `migrated_customers` gains partition weight.
- The skip check for the NULL and out-of-range chunk on `customer` is a sequential scan.
