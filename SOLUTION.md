# Solution Steps

1. Start by profiling the existing workload with EXPLAIN (ANALYZE, BUFFERS). The slow predicate shape is tenant_id, date(posted_at), status='posted', metadata->>'merchant_category', ordered by posted_at DESC/id DESC with a small LIMIT.

2. Identify the root causes: date(posted_at) prevents an efficient btree range seek on posted_at; the existing JSONB GIN index does not support the metadata->>'merchant_category' text equality well; status is low-cardinality; and no index matches the tenant/category/date/order pattern.

3. Rewrite only the database function, not the application contract: replace date(le.posted_at) = p_business_date with a sargable half-open timestamp range, posted_at >= p_business_date::timestamptz and posted_at < (p_business_date + 1)::timestamptz. This preserves the same local-day semantics as date(timestamptz) in the current session time zone.

4. Add one targeted partial covering index for posted ledger searches: tenant_id, metadata->>'merchant_category', posted_at DESC, id DESC, with included projected columns, and predicate WHERE status='posted'. This lets PostgreSQL seek to one tenant/category/day and return rows already in the required order.

5. Create extended statistics on tenant_id, status, and metadata->>'merchant_category' so the planner has better selectivity estimates for the correlated multi-column search predicates.

6. Run ANALYZE, or VACUUM (ANALYZE) during fresh initialization, so PostgreSQL has current table/index/statistics metadata and can choose the new plan reliably.

7. For production-style idempotence, also apply the remediation from run.sh with CREATE INDEX CONCURRENTLY IF NOT EXISTS and CREATE OR REPLACE FUNCTION, so an already-initialized database can be fixed without a broad rewrite or long exclusive table lock.

8. Validate correctness by comparing the first page from the original date(le.posted_at) predicate with the new find_ledger_entries output using EXCEPT in both directions.

9. Validate performance by running EXPLAIN (ANALYZE, BUFFERS, VERBOSE) on find_ledger_entries(1, DATE '2025-01-20', 'groceries', 100). The expected plan should use idx_ledger_entries_search_tenant_category_posted_at, avoid scanning the full high-volume tenant partition, avoid an expensive sort, and complete under 500ms on the provided dataset.

