#!/usr/bin/env bash
set -euo pipefail

cd /root/task

echo "Starting PostgreSQL assessment environment..."
docker compose up -d

echo "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 60); do
  if docker exec utkrusht_pg_ledger pg_isready -U assessment_user -d fintech_ledger >/dev/null 2>&1; then
    echo "PostgreSQL is ready."
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "PostgreSQL did not become ready in time." >&2
    docker compose ps >&2
    docker compose logs postgres >&2
    exit 1
  fi

  sleep 2
done

echo "Validating database connectivity..."
docker exec utkrusht_pg_ledger psql -U assessment_user -d fintech_ledger -v ON_ERROR_STOP=1 -c "SELECT current_database(), current_user, now();" >/dev/null

echo "Checking initialized schema..."
docker exec utkrusht_pg_ledger psql -U assessment_user -d fintech_ledger -v ON_ERROR_STOP=1 -c "SELECT count(*) AS ledger_entries FROM ledger_entries;"

echo "Applying idempotent ledger search performance remediation..."
docker exec -i utkrusht_pg_ledger psql -U assessment_user -d fintech_ledger -v ON_ERROR_STOP=1 <<'SQL'
SET search_path = public;

-- Target the hot tenant-scoped search shape:
--   tenant_id = ?
--   status = 'posted'
--   metadata->>'merchant_category' = ?
--   posted_at in one business-day range
--   ORDER BY posted_at DESC, id DESC LIMIT ?
--
-- CONCURRENTLY makes this safe to apply to an already-initialized writable database.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ledger_entries_search_tenant_category_posted_at
ON ledger_entries (
    tenant_id,
    ((metadata->>'merchant_category')),
    posted_at DESC,
    id DESC
)
INCLUDE (account_id, amount_cents, currency, status, direction, description)
WHERE status = 'posted';

CREATE STATISTICS IF NOT EXISTS st_ledger_entries_tenant_status_category (mcv, dependencies)
ON tenant_id, status, ((metadata->>'merchant_category'))
FROM ledger_entries;

CREATE OR REPLACE FUNCTION find_ledger_entries(
    p_tenant_id integer,
    p_business_date date,
    p_category text,
    p_limit integer DEFAULT 100
)
RETURNS TABLE (
    entry_id bigint,
    account_id bigint,
    posted_at timestamptz,
    amount_cents integer,
    currency char(3),
    status text,
    direction text,
    merchant_category text,
    description text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        le.id,
        le.account_id,
        le.posted_at,
        le.amount_cents,
        le.currency,
        le.status,
        le.direction,
        le.metadata->>'merchant_category',
        le.description
    FROM ledger_entries le
    WHERE le.tenant_id = p_tenant_id
      AND le.posted_at >= p_business_date::timestamptz
      AND le.posted_at <  (p_business_date + 1)::timestamptz
      AND le.status = 'posted'
      AND le.metadata->>'merchant_category' = p_category
    ORDER BY le.posted_at DESC, le.id DESC
    LIMIT p_limit;
$$;

ANALYZE ledger_entries;
SQL

echo "Database environment is deployed, optimized, and ready."
