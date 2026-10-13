# Load-Test Weight Data

SQL scripts that inflate `sentinel.migrated_customers` and `sentinel.customer` with synthetic rows so the trigram GIN indexes (`first_name`, `last_name`, `full_name`) and the birth-date partitions carry production-scale weight. The rows are not meant to be searched.

SIT and non-production environments only.

## How it works

The loader copies rows that already exist in `migrated_customers` (the ones carrying a `ucms_record_hash`). It does not create a starting data set.

The birth-year spread of the synthetic rows follows an **age curve**, not the original rows' spread. `p_copies` is the *average* number of synthetic rows per original row. Each birth year gets as many copies per original as its share of the curve needs, so the total stays `p_copies` × originals, and a year with few original rows gets more copies of each.

| Column | Synthetic value |
| --- | --- |
| `first_name`, `last_name` | Random, realistic Filipino names (~5M possible given names, ~2.9M possible surnames, weighted toward common names) |
| `full_name` | Recomputed from the new names |
| `name_suffix` | Copied |
| `birth_date` | Same year as the original, random day. Partition distribution follows the curve, and every month and day of a populated year gets rows |
| `gov_id_type` / `gov_id_number` | Type copied; digits in the number randomized, format kept |
| `migrated_customers.raw_info` | Copied without `er_run_timestamp`, plus `"lt": true` (the marker) |
| `ucms_record_hash`, `legacy_ids`, `email`, `mobile_number` | NULL on `migrated_customers` |
| `customer.metadata` | `{"lt": true}` (the marker) |
| `customer.created_at` / `updated_at` | `1999-01-01 00:00:00+00`, which keeps synthetic rows out of every FinCense EOD export window |
| Everything else | Copied |

The load runs one birth year at a time (1945 to 2014, plus one chunk for NULL or out-of-range dates) and commits after each year. A year that already contains synthetic rows is skipped, so the load can be stopped and re-run without duplicating rows.

## The age curve

The curve is hardcoded in the **TUNABLES** section at the top of `00-setup.sql`. Edit it there and run `00-setup.sql` again.

- `sentinel.lt_age_curve()` lists age bands with a weight per year of age. To use a histogram, give each band its count divided by the number of ages in it. The current values come from PGC's age-group counts over 22,730,620 records.
- `target` is `both`, or `migrated_customers` / `customer` to give one table its own curve. A table's own rows replace the `both` rows for that table. Bands for one target must not overlap.
- If some years in a band have no original rows, the band's populated years take up its whole share, so each band keeps its weight.
- `sentinel.lt_unknown_share()` is the fraction of synthetic rows given to original rows with a NULL birth date or one outside 1945–2014. Those copies keep their original's date (NULL stays NULL), so this share lands wherever the original outside rows sit.

Preview what a load will insert, per birth year:

```sql
SELECT * FROM sentinel.lt_plan('migrated_customers', 12127);
SELECT * FROM sentinel.lt_plan('customer', 12127);
```

## Files

| File | Purpose |
| --- | --- |
| `00-setup.sql` | Holds the age curve, and creates the name generators, gov-ID scrambler, load plan, and the load and cleanup procedures in the `sentinel` schema |
| `10-run.sql` | Runs both loads at the multiplier in its `CALL` lines, then `ANALYZE` |
| `99-cleanup.sql` | Deletes every synthetic row, vacuums both tables, drops the helper objects |

## Prerequisites

- `psql` connected to the Aurora **writer endpoint**, not RDS Proxy. The procedures commit inside `CALL`, which requires a direct session.
- Autocommit mode (psql default). Do not wrap `CALL` in `BEGIN`.
- A role with `CREATE` on schema `sentinel` and `SELECT`, `INSERT`, `DELETE` on both tables.
- PostgreSQL 13 or later.
- `migrated_customers` already holds the original rows to multiply.
- **Upgrading from the version that marked rows with `name_suffix = 'LT'`:** run that version's `99-cleanup.sql` first. This version's cleanup looks for the new markers and will not find the old rows.

## Running

Set up the helpers:

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/00-setup.sql
```

Trial one birth year first to check timing on the target instance. The copies come from the full plan, so the trial inserts exactly what the full run would for that year:

```sql
CALL sentinel.lt_load_migrated_customers(12127, '1985-01-01', '1986-01-01', false);
CALL sentinel.lt_load_customer(12127, '1985-01-01', '1986-01-01', false);
```

Run the full load (the trial year is skipped automatically):

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/10-run.sql
```

To change the multiplier, run `99-cleanup.sql` and `00-setup.sql` first. Years that already hold synthetic rows are skipped, not topped up.

### Parameters

Both procedures take `(p_copies, p_from, p_to, p_include_outside)`:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `p_copies` | 4 | Average synthetic rows per original row |
| `p_from` | `1945-01-01` | First birth year to load |
| `p_to` | `2015-01-01` | Exclusive end; use 1 January of the year after the last one |
| `p_include_outside` | `true` | Also load NULL and out-of-range birth dates |

To reach a target size, set `p_copies` to (target ÷ originals) − 1. For example, 1,649 originals to 20M total is 12,127. Copies are rounded per year, so a small multiplier lands a little off its target (x4 inserted 6,476 rather than 6,596 in testing); at 12,127 the difference is a few hundred rows in 20M.

## Timings

UAT, `migrated_customers` only, indexes in place, the earlier month-by-month version: x1000 (1,649,000 rows) took 6 min 50 s, about 4,000 rows/s. At that rate x12127 takes about 83 minutes; allow longer, because inserts slow down as the GIN indexes grow.

Local PostgreSQL 16 container (2 vCPU, 4 GiB, `fsync=off`), `migrated_customers` only, indexes absent during the load:

| Step | 1M to 20M (19 copies) |
| --- | --- |
| `migrated_customers` load, all partitions | 4 min 46 s |
| `migrated_customers` load, one partition | 6 min 29 s to 7 min 33 s |
| `first_name` GIN build | 40 s |
| `last_name` GIN build | 29 to 36 s |
| `full_name` GIN build | 85 to 94 s |
| `birth_date` btree build | 13 s |
| `VACUUM ANALYZE` | 20 s |

Loading into tables whose trigram indexes already exist is slower, because every insert updates three GIN indexes. For the fastest load, build the post-batch-load indexes after loading. To measure insert-time index cost, load with indexes in place.

## Verifying

```sql
SELECT count(*) FROM sentinel.migrated_customers
 WHERE ucms_record_hash IS NULL AND raw_info ? 'lt';
SELECT count(*) FROM sentinel.customer
 WHERE created_at = '1999-01-01 00:00:00+00' AND metadata ? 'lt';
SELECT tableoid::regclass AS partition,
       count(*) FILTER (WHERE ucms_record_hash IS NULL) AS synthetic,
       count(*) FILTER (WHERE ucms_record_hash IS NOT NULL) AS original
  FROM sentinel.migrated_customers GROUP BY 1 ORDER BY 1;
```

Each year's synthetic rows should equal `synthetic_rows` in `lt_plan` for that year.

## Cleanup

```bash
psql "host=<writer-endpoint> dbname=<db> user=<role> sslmode=require" -f loadtest/99-cleanup.sql
```

A row is deleted only when every marker matches:

- `migrated_customers`: `raw_info ? 'lt'`, `ucms_record_hash IS NULL`, `legacy_ids IS NULL`
- `customer`: `metadata ? 'lt'`, `created_at = 1999-01-01 00:00:00+00`

Cleanup also drops the helper functions, so run `00-setup.sql` again before the next load.

GIN indexes keep their bloat after a mass delete. Rebuild them with `REINDEX INDEX CONCURRENTLY` to return to pre-load size (on `migrated_customers`, reindex each partition's index individually).

## Known limitations

- Synthetic names are realistic and carry no visible marker, so they can coincide with a real person's name and birth date and appear as search candidates.
- A birth year with no original rows gets no synthetic rows; its band's populated years take up its share.
- `customer` is not partitioned in the current schema, so only `migrated_customers` gains partition weight.
- The skip check for the NULL and out-of-range chunk on `customer` is a sequential scan.
