\timing on

-- Tenant 1 is intentionally the high-volume tenant.
SELECT tenant_id, count(*) AS entries
FROM ledger_entries
GROUP BY tenant_id
ORDER BY entries DESC
LIMIT 10;

-- Saved workload history shows tenant 1 has slow posted-category ledger searches.
SELECT requested_category, count(*) AS requests, round(avg(observed_latency_ms), 1) AS avg_observed_latency_ms
FROM ledger_search_requests
WHERE tenant_id = 1
GROUP BY requested_category
ORDER BY requests DESC;

-- Optimized representative application path. The plan should use
-- idx_ledger_entries_search_tenant_category_posted_at and read a small ordered range.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT *
FROM find_ledger_entries(1, DATE '2025-01-20', 'groceries', 100);

-- Equivalent expanded SQL for easier plan inspection.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    le.id,
    le.account_id,
    le.posted_at,
    le.amount_cents,
    le.currency,
    le.status,
    le.direction,
    le.metadata->>'merchant_category' AS merchant_category,
    le.description
FROM ledger_entries le
WHERE le.tenant_id = 1
  AND le.posted_at >= DATE '2025-01-20'::timestamptz
  AND le.posted_at <  (DATE '2025-01-20' + 1)::timestamptz
  AND le.status = 'posted'
  AND le.metadata->>'merchant_category' = 'groceries'
ORDER BY le.posted_at DESC, le.id DESC
LIMIT 100;

-- Correctness guard: the rewritten, sargable date range must return exactly the same
-- first page as the original date(le.posted_at) predicate in the current session time zone.
WITH old_page AS (
    SELECT
        le.id,
        le.account_id,
        le.posted_at,
        le.amount_cents,
        le.currency,
        le.status,
        le.direction,
        le.metadata->>'merchant_category' AS merchant_category,
        le.description,
        row_number() OVER (ORDER BY le.posted_at DESC, le.id DESC) AS rn
    FROM ledger_entries le
    WHERE le.tenant_id = 1
      AND date(le.posted_at) = DATE '2025-01-20'
      AND le.status = 'posted'
      AND le.metadata->>'merchant_category' = 'groceries'
    ORDER BY le.posted_at DESC, le.id DESC
    LIMIT 100
), new_page AS (
    SELECT
        fle.*,
        row_number() OVER (ORDER BY fle.posted_at DESC, fle.entry_id DESC) AS rn
    FROM find_ledger_entries(1, DATE '2025-01-20', 'groceries', 100) AS fle
)
SELECT
    (SELECT count(*) FROM old_page) AS old_count,
    (SELECT count(*) FROM new_page) AS new_count,
    NOT EXISTS (
        SELECT entry_id, account_id, posted_at, amount_cents, currency, status, direction, merchant_category, description, rn
        FROM new_page
        EXCEPT
        SELECT id, account_id, posted_at, amount_cents, currency, status, direction, merchant_category, description, rn
        FROM old_page
    )
    AND NOT EXISTS (
        SELECT id, account_id, posted_at, amount_cents, currency, status, direction, merchant_category, description, rn
        FROM old_page
        EXCEPT
        SELECT entry_id, account_id, posted_at, amount_cents, currency, status, direction, merchant_category, description, rn
        FROM new_page
    ) AS first_page_matches;

SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('ledger_entries', 'ledger_entry_audit', 'ledger_accounts', 'merchants')
ORDER BY tablename, indexname;

SELECT relname, n_live_tup, n_dead_tup, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname IN ('ledger_entries', 'ledger_entry_audit', 'ledger_search_requests')
ORDER BY relname;

SELECT attname, n_distinct, most_common_vals, most_common_freqs
FROM pg_stats
WHERE schemaname = 'public'
  AND tablename = 'ledger_entries'
  AND attname IN ('tenant_id', 'status', 'posted_at');

SELECT statistics_name, attnames, exprs, kinds
FROM pg_stats_ext
WHERE schemaname = 'public'
  AND statistics_name = 'st_ledger_entries_tenant_status_category';
