-- ============================================================
--  PostgreSQL Performance Investigation Queries
--  DBA Runbook — copy-paste ready
-- ============================================================

-- ─── 1. TOP SLOW QUERIES (Total time) ───────────────────────
SELECT
    LEFT(query, 300)            AS query,
    calls,
    total_exec_time::BIGINT     AS total_ms,
    mean_exec_time::BIGINT      AS mean_ms,
    max_exec_time::BIGINT       AS max_ms,
    rows,
    ROUND((shared_blks_hit::NUMERIC / NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 1) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- ─── 2. TOP SLOW QUERIES (Mean time — outliers) ─────────────
SELECT
    LEFT(query, 300)            AS query,
    calls,
    mean_exec_time::BIGINT      AS mean_ms,
    stddev_exec_time::BIGINT    AS stddev_ms,
    max_exec_time::BIGINT       AS max_ms,
    min_exec_time::BIGINT       AS min_ms
FROM pg_stat_statements
WHERE calls > 5
ORDER BY mean_exec_time DESC
LIMIT 20;

-- ─── 3. MOST FREQUENTLY CALLED QUERIES ──────────────────────
SELECT
    LEFT(query, 300)    AS query,
    calls,
    total_exec_time::BIGINT AS total_ms,
    mean_exec_time::BIGINT  AS mean_ms
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 20;

-- ─── 4. ACTIVE QUERIES RIGHT NOW ─────────────────────────────
SELECT
    pid,
    now() - query_start    AS duration,
    state,
    wait_event_type,
    wait_event,
    LEFT(query, 300)       AS query,
    client_addr,
    usename,
    application_name
FROM pg_stat_activity
WHERE state <> 'idle'
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;

-- ─── 5. BLOCKING QUERIES ─────────────────────────────────────
SELECT
    blocker.pid                 AS blocking_pid,
    blocker.usename             AS blocking_user,
    LEFT(blocker.query, 200)   AS blocking_query,
    blocked.pid                 AS blocked_pid,
    blocked.usename             AS blocked_user,
    LEFT(blocked.query, 200)   AS blocked_query,
    blocked.wait_event
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- ─── 6. LOCK DETAILS ─────────────────────────────────────────
SELECT
    l.pid,
    l.locktype,
    l.relation::REGCLASS AS table_name,
    l.mode,
    l.granted,
    a.query,
    a.state,
    now() - a.query_start AS lock_duration
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE NOT l.granted
ORDER BY lock_duration DESC NULLS LAST;

-- ─── 7. CACHE HIT RATIO PER TABLE ───────────────────────────
SELECT
    schemaname,
    relname AS table_name,
    heap_blks_hit,
    heap_blks_read,
    ROUND(
        heap_blks_hit::NUMERIC /
        NULLIF(heap_blks_hit + heap_blks_read, 0) * 100, 2
    ) AS cache_hit_pct
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC
LIMIT 20;

-- ─── 8. INDEX USAGE STATS ─────────────────────────────────────
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_size_pretty(pg_relation_size(schemaname || '.' || indexname)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC
LIMIT 30;

-- ─── 9. UNUSED INDEXES (candidates for removal) ─────────────
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(schemaname || '.' || indexname)) AS size,
    idx_scan AS times_used
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(schemaname || '.' || indexname) DESC;

-- ─── 10. TABLE BLOAT ESTIMATE ────────────────────────────────
SELECT
    schemaname,
    tablename,
    n_live_tup,
    n_dead_tup,
    ROUND(n_dead_tup::NUMERIC / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
    last_autovacuum,
    last_vacuum,
    autovacuum_count
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- ─── 11. REPLICATION STATUS ──────────────────────────────────
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sent_lsn - replay_lsn   AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- ─── 12. CONNECTIONS BREAKDOWN ───────────────────────────────
SELECT
    state,
    wait_event_type,
    wait_event,
    COUNT(*) AS count
FROM pg_stat_activity
GROUP BY state, wait_event_type, wait_event
ORDER BY count DESC;

-- ─── 13. DATABASE SIZES ──────────────────────────────────────
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size,
    pg_database_size(datname) AS bytes
FROM pg_database
ORDER BY bytes DESC;

-- ─── 14. TABLE SIZES (top 20) ────────────────────────────────
SELECT
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename)) AS indexes_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 20;

-- ─── 15. AUTO-KILL LONG-RUNNING QUERIES ──────────────────────
-- Kills queries running longer than 5 minutes
-- SELECT * FROM public.kill_long_running_queries(300);

-- ─── 16. RESET pg_stat_statements ────────────────────────────
-- Run this after a major change to get fresh baselines
-- SELECT pg_stat_statements_reset();

-- ─── 17. VACUUM PROGRESS ─────────────────────────────────────
SELECT
    p.pid,
    v.relid::REGCLASS AS table_name,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    ROUND(p.heap_blks_scanned::NUMERIC / NULLIF(p.heap_blks_total, 0) * 100, 1) AS pct_done
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity v ON p.pid = v.pid;