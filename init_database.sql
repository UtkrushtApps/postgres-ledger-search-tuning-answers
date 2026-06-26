CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SET client_min_messages = warning;
SET search_path = public;

CREATE TABLE tenants (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_key text NOT NULL UNIQUE,
    legal_name text NOT NULL,
    status text NOT NULL CHECK (status IN ('active', 'suspended', 'closed')),
    plan_tier text NOT NULL CHECK (plan_tier IN ('startup', 'growth', 'enterprise')),
    created_at timestamptz NOT NULL
);

CREATE TABLE tenant_settings (
    tenant_id integer PRIMARY KEY REFERENCES tenants(id),
    default_currency char(3) NOT NULL,
    timezone_name text NOT NULL,
    reconciliation_cutoff_hour integer NOT NULL CHECK (reconciliation_cutoff_hour BETWEEN 0 AND 23),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE merchant_categories (
    id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    display_name text NOT NULL
);

CREATE TABLE merchants (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    category_id smallint NOT NULL REFERENCES merchant_categories(id),
    legal_name text NOT NULL,
    risk_score integer NOT NULL CHECK (risk_score BETWEEN 1 AND 100),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE account_holders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    external_ref text NOT NULL,
    full_name text NOT NULL,
    risk_tier text NOT NULL CHECK (risk_tier IN ('low', 'medium', 'high')),
    created_at timestamptz NOT NULL,
    UNIQUE (tenant_id, external_ref)
);

CREATE TABLE ledger_accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    holder_id bigint NOT NULL REFERENCES account_holders(id),
    currency char(3) NOT NULL,
    account_type text NOT NULL CHECK (account_type IN ('cash', 'card', 'reserve')),
    status text NOT NULL CHECK (status IN ('open', 'frozen', 'closed')),
    opened_at timestamptz NOT NULL
);

CREATE TABLE ledger_entries (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    account_id bigint NOT NULL REFERENCES ledger_accounts(id),
    merchant_id bigint NOT NULL REFERENCES merchants(id),
    posted_at timestamptz NOT NULL,
    amount_cents integer NOT NULL,
    currency char(3) NOT NULL,
    status text NOT NULL CHECK (status IN ('posted', 'pending', 'reversed', 'voided')),
    direction text NOT NULL CHECK (direction IN ('debit', 'credit')),
    metadata jsonb NOT NULL,
    description text NOT NULL,
    created_at timestamptz NOT NULL
);

CREATE TABLE ledger_entry_audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ledger_entry_id bigint NOT NULL REFERENCES ledger_entries(id),
    tenant_id integer NOT NULL REFERENCES tenants(id),
    action text NOT NULL CHECK (action IN ('created', 'posted', 'adjusted', 'reviewed')),
    actor text NOT NULL,
    changed_at timestamptz NOT NULL,
    diff jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE ledger_saved_filters (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    filter_name text NOT NULL,
    created_by text NOT NULL,
    criteria jsonb NOT NULL,
    created_at timestamptz NOT NULL
);

CREATE TABLE ledger_search_requests (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL REFERENCES tenants(id),
    business_date date NOT NULL,
    requested_category text NOT NULL,
    requested_status text NOT NULL,
    observed_latency_ms integer NOT NULL,
    result_count integer NOT NULL,
    requested_at timestamptz NOT NULL
);

INSERT INTO tenants (tenant_key, legal_name, status, plan_tier, created_at)
SELECT
    'tenant_' || lpad(g::text, 3, '0'),
    'Utkrusht Ledger Tenant ' || g,
    CASE WHEN g IN (77, 78) THEN 'suspended' ELSE 'active' END,
    CASE WHEN g = 1 THEN 'enterprise' WHEN g % 5 = 0 THEN 'growth' ELSE 'startup' END,
    '2022-01-01 00:00:00+00'::timestamptz + (g * interval '3 days')
FROM generate_series(1, 80) AS g;

INSERT INTO tenant_settings (tenant_id, default_currency, timezone_name, reconciliation_cutoff_hour, metadata)
SELECT
    id,
    'USD',
    CASE WHEN id % 3 = 0 THEN 'America/New_York' WHEN id % 3 = 1 THEN 'UTC' ELSE 'America/Los_Angeles' END,
    18 + (id % 5),
    jsonb_build_object('region', CASE WHEN id % 2 = 0 THEN 'north_america' ELSE 'global' END, 'reconcile_daily', true)
FROM tenants;

INSERT INTO merchant_categories (code, display_name) VALUES
('groceries', 'Groceries'),
('fuel', 'Fuel'),
('travel', 'Travel'),
('software', 'Software'),
('healthcare', 'Healthcare'),
('restaurants', 'Restaurants'),
('utilities', 'Utilities'),
('education', 'Education'),
('insurance', 'Insurance'),
('marketplace', 'Marketplace'),
('cash_advance', 'Cash Advance'),
('other', 'Other');

INSERT INTO merchants (tenant_id, category_id, legal_name, risk_score, metadata)
SELECT
    t.id,
    c.id,
    'Merchant ' || t.id || '-' || c.code || '-' || n,
    10 + ((t.id * c.id * n) % 85),
    jsonb_build_object('category_code', c.code, 'onboarded_by', CASE WHEN n = 1 THEN 'batch' ELSE 'ops' END)
FROM tenants t
CROSS JOIN merchant_categories c
CROSS JOIN generate_series(1, 2) AS n;

INSERT INTO account_holders (tenant_id, external_ref, full_name, risk_tier, created_at)
SELECT
    t.id,
    'CUST-' || t.id || '-' || lpad(n::text, 6, '0'),
    'Customer ' || t.id || '-' || n,
    CASE WHEN n % 31 = 0 THEN 'high' WHEN n % 7 = 0 THEN 'medium' ELSE 'low' END,
    '2023-01-01 00:00:00+00'::timestamptz + ((n % 365) * interval '1 day')
FROM tenants t
CROSS JOIN LATERAL generate_series(1, CASE WHEN t.id = 1 THEN 2500 ELSE 80 END) AS n;

INSERT INTO ledger_accounts (tenant_id, holder_id, currency, account_type, status, opened_at)
SELECT
    ah.tenant_id,
    ah.id,
    'USD',
    CASE WHEN slot = 1 THEN 'cash' ELSE 'card' END,
    CASE WHEN ah.id % 113 = 0 THEN 'frozen' ELSE 'open' END,
    ah.created_at + (slot * interval '1 hour')
FROM account_holders ah
CROSS JOIN generate_series(1, 2) AS slot;

CREATE TEMP TABLE tenant_account_bounds AS
SELECT tenant_id, min(id) AS min_account_id, count(*)::bigint AS account_count
FROM ledger_accounts
GROUP BY tenant_id;

CREATE TEMP TABLE tenant_merchant_bounds AS
SELECT tenant_id, min(id) AS min_merchant_id, count(*)::bigint AS merchant_count
FROM merchants
GROUP BY tenant_id;

INSERT INTO ledger_entries (
    tenant_id,
    account_id,
    merchant_id,
    posted_at,
    amount_cents,
    currency,
    status,
    direction,
    metadata,
    description,
    created_at
)
SELECT
    r.tenant_id,
    tab.min_account_id + (r.g % tab.account_count),
    tmb.min_merchant_id + (r.g % tmb.merchant_count),
    '2025-02-01 00:00:00+00'::timestamptz - ((r.g % 120) * interval '1 day') + ((r.g % 86400) * interval '1 second'),
    ((r.g * 137) % 250000) - 5000,
    'USD',
    CASE WHEN r.g % 20 = 0 THEN 'pending' WHEN r.g % 29 = 0 THEN 'voided' WHEN r.g % 997 = 0 THEN 'reversed' ELSE 'posted' END,
    CASE WHEN r.g % 4 = 0 THEN 'credit' ELSE 'debit' END,
    jsonb_build_object(
        'merchant_category', mc.code,
        'payment_rail', CASE WHEN r.g % 5 = 0 THEN 'ach' WHEN r.g % 5 = 1 THEN 'card' WHEN r.g % 5 = 2 THEN 'wire' ELSE 'internal' END,
        'device_country', CASE WHEN r.g % 11 = 0 THEN 'CA' WHEN r.g % 13 = 0 THEN 'GB' ELSE 'US' END,
        'statement_descriptor', 'LEDGER-' || mc.code || '-' || (r.g % 1000),
        'risk_flags', CASE WHEN r.g % 47 = 0 THEN jsonb_build_array('manual_review') ELSE '[]'::jsonb END
    ),
    'Ledger movement ' || r.g || ' for ' || mc.code,
    '2025-02-01 00:00:00+00'::timestamptz - ((r.g % 120) * interval '1 day') + ((r.g % 86400) * interval '1 second') + interval '2 minutes'
FROM (
    SELECT
        g,
        CASE WHEN g <= 160000 THEN 1 ELSE 2 + (g % 79) END AS tenant_id,
        ((g % 12) + 1)::smallint AS category_id
    FROM generate_series(1, 300000) AS g
) r
JOIN tenant_account_bounds tab ON tab.tenant_id = r.tenant_id
JOIN tenant_merchant_bounds tmb ON tmb.tenant_id = r.tenant_id
JOIN merchant_categories mc ON mc.id = r.category_id;

INSERT INTO ledger_entry_audit (ledger_entry_id, tenant_id, action, actor, changed_at, diff)
SELECT
    le.id,
    le.tenant_id,
    CASE WHEN le.id % 17 = 0 THEN 'reviewed' ELSE 'posted' END,
    CASE WHEN le.id % 13 = 0 THEN 'ops_reviewer' ELSE 'ledger_service' END,
    le.created_at + interval '1 minute',
    jsonb_build_object('status', le.status, 'amount_cents', le.amount_cents)
FROM ledger_entries le
WHERE le.id <= 60000;

INSERT INTO ledger_saved_filters (tenant_id, filter_name, created_by, criteria, created_at)
SELECT
    t.id,
    'Daily posted ' || mc.code || ' review',
    'support_' || (t.id % 9),
    jsonb_build_object('status', 'posted', 'merchant_category', mc.code, 'days_back', (mc.id % 30)),
    '2025-01-01 00:00:00+00'::timestamptz + (mc.id * interval '1 day')
FROM tenants t
JOIN merchant_categories mc ON mc.id IN (1, 3, 4, 6)
WHERE t.id <= 20;

INSERT INTO ledger_search_requests (tenant_id, business_date, requested_category, requested_status, observed_latency_ms, result_count, requested_at)
SELECT
    CASE WHEN g <= 500 THEN 1 ELSE 2 + (g % 79) END,
    ('2025-02-01'::date - ((g % 60)::integer)),
    CASE WHEN g % 6 = 0 THEN 'groceries' WHEN g % 6 = 1 THEN 'travel' WHEN g % 6 = 2 THEN 'software' WHEN g % 6 = 3 THEN 'restaurants' WHEN g % 6 = 4 THEN 'fuel' ELSE 'marketplace' END,
    'posted',
    CASE WHEN g <= 500 THEN 3800 + (g % 2100) ELSE 300 + (g % 900) END,
    CASE WHEN g <= 500 THEN 100 ELSE 20 + (g % 80) END,
    '2025-02-02 00:00:00+00'::timestamptz + (g * interval '10 minutes')
FROM generate_series(1, 1200) AS g;

-- Baseline supporting indexes from the original schema.
CREATE INDEX idx_ledger_entries_posted_at ON ledger_entries (posted_at);
CREATE INDEX idx_ledger_entries_status ON ledger_entries (status);
CREATE INDEX idx_ledger_entries_account_id ON ledger_entries (account_id);
CREATE INDEX idx_ledger_entries_metadata_gin ON ledger_entries USING gin (metadata);
CREATE INDEX idx_ledger_audit_entry_id ON ledger_entry_audit (ledger_entry_id);
CREATE INDEX idx_merchants_tenant_id ON merchants (tenant_id);
CREATE INDEX idx_accounts_holder_id ON ledger_accounts (holder_id);

-- Targeted remediation for the production search path.
--
-- Root causes addressed:
--   1. The original function applied date(le.posted_at), so the plain posted_at index
--      could not be used to seek to a single day.
--   2. The JSONB GIN index is not useful for metadata->>'merchant_category' = text.
--   3. The status-only index is low-selectivity for a ledger where most entries are posted.
--   4. The query needs the newest first page, so the index order should match the ORDER BY.
--
-- The partial index only stores posted rows, which bounds write amplification compared with
-- indexing every status while still matching the customer-support/reconciliation workload.
CREATE INDEX idx_ledger_entries_search_tenant_category_posted_at
ON ledger_entries (
    tenant_id,
    ((metadata->>'merchant_category')),
    posted_at DESC,
    id DESC
)
INCLUDE (account_id, amount_cents, currency, status, direction, description)
WHERE status = 'posted';

CREATE STATISTICS st_ledger_entries_tenant_status_category (mcv, dependencies)
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
      -- Equivalent to date(le.posted_at) = p_business_date in the current session
      -- time zone, but sargable against the posted_at btree key.
      AND le.posted_at >= p_business_date::timestamptz
      AND le.posted_at <  (p_business_date + 1)::timestamptz
      AND le.status = 'posted'
      AND le.metadata->>'merchant_category' = p_category
    ORDER BY le.posted_at DESC, le.id DESC
    LIMIT p_limit;
$$;

VACUUM (ANALYZE) ledger_entries;
VACUUM (ANALYZE) ledger_entry_audit;
VACUUM (ANALYZE) ledger_search_requests;
ANALYZE;
