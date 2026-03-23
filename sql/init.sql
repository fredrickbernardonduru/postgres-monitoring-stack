-- ============================================================
--  PostgreSQL Monitoring Stack — Database Initialisation
--  Runs on first container start via docker-entrypoint-initdb.d
-- ============================================================

\echo '>>> Installing extensions...'

-- CRITICAL: Enable query-level statistics
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Useful supplementary extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- ─── Monitoring Role ─────────────────────────────────────────
-- Least-privilege role for postgres_exporter
CREATE ROLE pg_monitor_user WITH LOGIN PASSWORD 'monitor_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;

-- Grant necessary permissions for the exporter
GRANT pg_monitor TO pg_monitor_user;
GRANT CONNECT ON DATABASE appdb TO pg_monitor_user;
GRANT USAGE ON SCHEMA public TO pg_monitor_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pg_monitor_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO pg_monitor_user;

-- ─── Application Schema ──────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS app;

-- Users table (primary workload simulation)
CREATE TABLE IF NOT EXISTS app.users (
    id          BIGSERIAL PRIMARY KEY,
    username    VARCHAR(100) NOT NULL UNIQUE,
    email       VARCHAR(255) NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ  DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  DEFAULT NOW(),
    status      VARCHAR(20)  DEFAULT 'active' CHECK (status IN ('active','inactive','banned')),
    metadata    JSONB
);

-- Orders table (join workload simulation)
CREATE TABLE IF NOT EXISTS app.orders (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES app.users(id),
    amount      NUMERIC(12, 2) NOT NULL,
    status      VARCHAR(20) DEFAULT 'pending',
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Events table (high-volume insert target)
CREATE TABLE IF NOT EXISTS app.events (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT,
    event_type  VARCHAR(50) NOT NULL,
    payload     JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Create partitions for current + next month
CREATE TABLE app.events_current
    PARTITION OF app.events
    FOR VALUES FROM (DATE_TRUNC('month', NOW()))
               TO   (DATE_TRUNC('month', NOW()) + INTERVAL '1 month');

CREATE TABLE app.events_next
    PARTITION OF app.events
    FOR VALUES FROM (DATE_TRUNC('month', NOW()) + INTERVAL '1 month')
               TO   (DATE_TRUNC('month', NOW()) + INTERVAL '2 months');

-- ─── Indexes ─────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_status     ON app.users(status);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_created    ON app.users(created_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_user_id   ON app.orders(user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_status    ON app.orders(status);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_created   ON app.orders(created_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_user      ON app.events(user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_type      ON app.events(event_type);
-- Intentionally omitting index on events.created_at for load-test demonstration

-- ─── Seed Data ───────────────────────────────────────────────
\echo '>>> Seeding sample data...'

INSERT INTO app.users (username, email, status, metadata)
SELECT
    'user_' || i,
    'user_' || i || '@example.com',
    (ARRAY['active','inactive','active','active','banned'])[1 + (i % 5)],
    jsonb_build_object('tier', (ARRAY['free','pro','enterprise'])[1 + (i % 3)], 'region', (ARRAY['us-east','us-west','eu-west','ap-south'])[1 + (i % 4)])
FROM generate_series(1, 10000) AS s(i)
ON CONFLICT DO NOTHING;

INSERT INTO app.orders (user_id, amount, status)
SELECT
    (random() * 9999 + 1)::BIGINT,
    (random() * 9999)::NUMERIC(12,2),
    (ARRAY['pending','processing','shipped','completed','cancelled'])[1 + floor(random() * 5)::INT]
FROM generate_series(1, 50000)
ON CONFLICT DO NOTHING;

INSERT INTO app.events (user_id, event_type, payload, created_at)
SELECT
    (random() * 9999 + 1)::BIGINT,
    (ARRAY['page_view','click','purchase','logout','error'])[1 + floor(random() * 5)::INT],
    jsonb_build_object('session', gen_random_uuid()::text, 'duration', floor(random() * 300)::INT),
    NOW() - (random() * INTERVAL '30 days')
FROM generate_series(1, 100000);

-- ─── Monitoring Helper Views ─────────────────────────────────
CREATE OR REPLACE VIEW public.v_long_running_queries AS
SELECT
    pid,
    now() - query_start AS duration,
    state,
    wait_event_type,
    wait_event,
    LEFT(query, 500) AS query,
    client_addr,
    application_name,
    usename
FROM pg_stat_activity
WHERE state <> 'idle'
  AND query_start < now() - INTERVAL '5 seconds'
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;

CREATE OR REPLACE VIEW public.v_blocking_queries AS
SELECT
    blocker.pid           AS blocking_pid,
    blocker.usename       AS blocking_user,
    blocker.query         AS blocking_query,
    blocked.pid           AS blocked_pid,
    blocked.usename       AS blocked_user,
    blocked.query         AS blocked_query,
    blocked.wait_event    AS wait_event
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

CREATE OR REPLACE VIEW public.v_top_queries AS
SELECT
    LEFT(query, 300)           AS query,
    calls,
    total_exec_time::BIGINT    AS total_ms,
    mean_exec_time::BIGINT     AS mean_ms,
    max_exec_time::BIGINT      AS max_ms,
    stddev_exec_time::BIGINT   AS stddev_ms,
    rows,
    ROUND((shared_blks_hit::NUMERIC / NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 2) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

CREATE OR REPLACE VIEW public.v_cache_hit_ratio AS
SELECT
    SUM(heap_blks_hit) AS heap_hits,
    SUM(heap_blks_read) AS heap_reads,
    ROUND(
        SUM(heap_blks_hit)::NUMERIC /
        NULLIF(SUM(heap_blks_hit) + SUM(heap_blks_read), 0) * 100, 4
    ) AS hit_ratio_pct
FROM pg_statio_user_tables;

GRANT SELECT ON public.v_long_running_queries TO pg_monitor_user;
GRANT SELECT ON public.v_blocking_queries TO pg_monitor_user;
GRANT SELECT ON public.v_top_queries TO pg_monitor_user;
GRANT SELECT ON public.v_cache_hit_ratio TO pg_monitor_user;
GRANT USAGE ON SCHEMA app TO pg_monitor_user;

-- ─── Auto-kill Function ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.kill_long_running_queries(threshold_seconds INT DEFAULT 300)
RETURNS TABLE(killed_pid INT, killed_query TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH killed AS (
        SELECT pid, query
        FROM pg_stat_activity
        WHERE state = 'active'
          AND query_start < NOW() - make_interval(secs => threshold_seconds)
          AND pid <> pg_backend_pid()
          AND query NOT ILIKE '%kill_long_running_queries%'
    )
    SELECT pid::INT, LEFT(query, 200)
    FROM killed
    WHERE pg_terminate_backend(pid);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.kill_long_running_queries(INT) TO pg_monitor_user;

\echo '>>> Database initialisation complete.'