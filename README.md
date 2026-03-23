# 🐘 PostgreSQL Monitoring Stack

> **Production-grade observability for PostgreSQL** — metrics collection, 5 custom Grafana dashboards, 17 alert rules, connection pooling, and DBA automation. Everything runs with a single `docker compose up`.

<br>

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?style=flat-square&logo=postgresql&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-latest-E6522C?style=flat-square&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-latest-F46800?style=flat-square&logo=grafana&logoColor=white)
![PgBouncer](https://img.shields.io/badge/PgBouncer-latest-008BB9?style=flat-square)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=flat-square&logo=docker&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

<br>

---

## 📋 Table of Contents

- [Architecture](#architecture)
- [What's Inside](#whats-inside)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Service Overview](#service-overview)
- [Project Structure](#project-structure)
- [Dashboards](#dashboards)
- [Metrics Collected](#metrics-collected)
- [Alert Rules](#alert-rules)
- [Load Testing](#load-testing)
- [DBA Runbook](#dba-runbook)
- [Auto-Kill Script](#auto-kill-script)
- [Slow Query Log Parser](#slow-query-log-parser)
- [Configuration Reference](#configuration-reference)
- [Production Checklist](#production-checklist)
- [Performance Tuning Guide](#performance-tuning-guide)

---

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Grafana  :3000                  │
                    │         5 custom hand-built dashboards       │
                    │  DB Health │ Queries │ Locks │ Pool │ Replic │
                    └───────────────────┬─────────────────────────┘
                                        │  PromQL queries
                    ┌───────────────────▼─────────────────────────┐
                    │            Prometheus  :9090                 │
                    │    30-day retention · 17 alert rules         │
                    │    scrape interval: 15s                      │
                    └──────────┬─────────────────┬────────────────┘
                               │ scrape           │ scrape
            ┌──────────────────▼──────┐  ┌────────▼─────────────────┐
            │   postgres_exporter     │  │   pgbouncer_exporter     │
            │        :9187            │  │        :9127             │
            │  200+ metrics per scrape│  │   pool & queue metrics   │
            └──────────┬──────────────┘  └──────────┬──────────────┘
                       │ reads                       │ reads
            ┌──────────▼──────────────┐  ┌──────────▼──────────────┐
            │     PostgreSQL  :5432   │  │    PgBouncer  :6432     │
            │  pg_stat_statements     │  │  transaction pool mode  │
            │  pg_stat_activity       │  │  200 client → 25 server │
            │  custom queries.yaml    │  └─────────────────────────┘
            └─────────────────────────┘
                                        ┌─────────────────────────┐
                    Prometheus ────────►│   Alertmanager  :9093   │
                                        │  routing: severity +    │
                                        │  category · inhibitions │
                                        │  → Slack/PagerDuty/email│
                                        └─────────────────────────┘
```

---

## What's Inside

| Component | Count | Details |
|-----------|-------|---------|
| Docker services | **7** | postgres, pgbouncer, postgres_exporter, pgbouncer_exporter, prometheus, alertmanager, grafana |
| Grafana dashboards | **5** | All hand-built from scratch, auto-provisioned on boot |
| Prometheus alert rules | **17** | Across 6 categories: connections, performance, locking, replication, storage, availability |
| Custom exporter queries | **8** | `pg_stat_statements`, long-running queries, blocking pairs, bloat, index usage, vacuum, replication lag |
| DBA investigation queries | **17** | Copy-paste ready SQL for every common incident |
| Load test scenarios | **7** | slow queries, connection flood, lock contention, deadlock, index vs seq scan, insert burst, cache pressure |
| Automation scripts | **3** | auto-kill stuck queries, slow log parser, load tester |

---

## Prerequisites

| Requirement | Minimum Version |
|-------------|----------------|
| Docker | 24.0 |
| Docker Compose | v2.0 (plugin, not standalone) |
| Free RAM | 2 GB |
| Free disk | 5 GB |

**Ports that must be free:**

```
5432  — PostgreSQL (direct)
6432  — PgBouncer (pooled)
9090  — Prometheus
9093  — Alertmanager
9127  — pgbouncer_exporter
9187  — postgres_exporter
3000  — Grafana
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/yourname/postgres-monitoring-stack.git
cd postgres-monitoring-stack
```

### 2. Make scripts executable

```bash
chmod +x scripts/*.sh
```

### 3. Start the entire stack

```bash
docker compose up -d
```

Wait ~30 seconds for all services to become healthy, then verify:

```bash
docker compose ps
```

Expected output:

```
NAME                   STATUS          PORTS
postgres_primary       healthy         0.0.0.0:5432->5432/tcp
pgbouncer              running         0.0.0.0:6432->6432/tcp
postgres_exporter      running         0.0.0.0:9187->9187/tcp
pgbouncer_exporter     running         0.0.0.0:9127->9127/tcp
prometheus             running         0.0.0.0:9090->9090/tcp
alertmanager           running         0.0.0.0:9093->9093/tcp
grafana                running         0.0.0.0:3000->3000/tcp
```

### 4. Open the UIs

| Service | URL | Credentials |
|---------|-----|-------------|
| **Grafana** | http://localhost:3000 | `admin` / `admin` |
| **Prometheus** | http://localhost:9090 | — |
| **Alertmanager** | http://localhost:9093 | — |
| **Metrics (raw)** | http://localhost:9187/metrics | — |

> Grafana dashboards are auto-provisioned. Navigate to **Dashboards → PostgreSQL** to find all 5 dashboards immediately after startup. No manual import needed.

### 5. Run a load test to see everything in action

```bash
# Open Grafana first, set refresh to 5s, then:
./scripts/load_test.sh all
```

---

## Service Overview

### PostgreSQL 16
The primary database. Configured with:
- `pg_stat_statements` extension enabled at boot — **critical for query-level monitoring**
- Slow query logging at `1000ms` threshold
- `track_io_timing = on` for block-level I/O stats
- WAL level set to `replica` to enable replication monitoring metrics
- Auto-vacuum tuned for faster dead tuple cleanup

Connection strings:
```
# Direct
postgresql://pguser:pgpassword@localhost:5432/appdb

# Via PgBouncer (recommended for applications)
postgresql://pguser:pgpassword@localhost:6432/appdb
```

### PgBouncer
Connection pooler in **transaction mode**. Absorbs up to 200 client connections and multiplexes them onto 25 server connections to PostgreSQL. This is the layer that prevents connection exhaustion under load.

Key settings:
```ini
pool_mode          = transaction
max_client_conn    = 200
default_pool_size  = 25
reserve_pool_size  = 5
```

### postgres_exporter
Bridges PostgreSQL metrics into Prometheus format. Exposes 200+ default metrics plus 8 custom collectors defined in `postgres/queries.yaml`:

| Custom Collector | What it measures |
|-----------------|-----------------|
| `pg_stat_statements` | Per-query execution time, call count, cache hits |
| `pg_active_connections` | Connection count by state and wait event type |
| `pg_long_running_queries` | Count and max age of queries running >5s |
| `pg_blocking_queries` | Number of active blocking query pairs |
| `pg_table_bloat` | Table and index sizes for top 20 tables |
| `pg_index_usage` | Index scan counts to find unused indexes |
| `pg_vacuum_stats` | Dead tuple counts and autovacuum timing |
| `pg_replication_lag` | Replica lag in seconds and bytes |

### Prometheus
Time-series metrics store. Configuration:
- **Retention:** 30 days
- **Scrape interval:** 15 seconds
- **Alert evaluation:** 15 seconds
- **Admin API:** enabled

### Alertmanager
Routes fired alerts to the right channel based on `severity` and `category` labels. Includes inhibition rules to prevent alert floods when an exporter goes down.

### Grafana
Dashboards are provisioned automatically at startup from `grafana/provisioning/`. No manual datasource registration or dashboard import required.

---

## Project Structure

```
postgres-monitoring-stack/
│
├── docker-compose.yml                   # All 7 services with networks, volumes, healthchecks
├── README.md                            # This file
│
├── postgres/
│   ├── postgresql.conf                  # Tuned for observability: pg_stat_statements, slow log, WAL
│   └── queries.yaml                     # 8 custom postgres_exporter metric collectors
│
├── prometheus/
│   ├── prometheus.yml                   # Scrape jobs: postgres, pgbouncer, alertmanager
│   └── alert_rules.yml                  # 17 alert rules across 6 categories
│
├── alertmanager/
│   └── alertmanager.yml                 # Routing, inhibitions, receiver templates
│
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── prometheus.yml           # Auto-register Prometheus datasource
│   │   └── dashboards/
│   │       └── dashboards.yml           # Load dashboards from /dashboards folder
│   └── dashboards/
│       ├── 01_overview.json             # DB health: connections, TPS, cache hit, sizes
│       ├── 02_query_performance.json    # pg_stat_statements deep dive
│       ├── 03_locks_blocking.json       # Blocking pairs, wait events, deadlocks
│       ├── 04_pgbouncer.json            # Pool utilisation, client queue, wait time
│       └── 05_replication_storage.json  # WAL, replica lag, vacuum, bloat
│
├── pgbouncer/
│   ├── pgbouncer.ini                    # Pool config: transaction mode, 200 client / 25 server
│   └── userlist.txt                     # Auth credentials
│
├── sql/
│   ├── init.sql                         # Schema, extensions, 160K seed rows, views, auto-kill fn
│   └── performance_queries.sql          # 17 DBA investigation queries
│
└── scripts/
    ├── load_test.sh                      # 7 stress scenarios to validate dashboards and alerts
    ├── auto_kill.sh                      # Cron-safe stuck query reaper
    └── parse_slow_logs.py               # Slow query log pattern analyser
```

---

## Dashboards

![Screenshot_23-3-2026_2066_](https://github.com/user-attachments/assets/e01a4b93-b803-4c8c-b9f3-e0d188c53d16)

All 5 dashboards are hand-built JSON — not imported from Grafana's public library. They are provisioned automatically and appear under **Dashboards → PostgreSQL** immediately after `docker compose up`.

---

### Dashboard 1 — DB Health Overview

**URL:** `http://localhost:3000/d/postgres-overview`
**Refresh:** 30 seconds | **Time range:** Last 1 hour

The top-level health screen. Answers "is the database healthy right now?" in a single glance.

**Stat panels (top row):**

| Panel | Metric | 🟢 Green | 🟡 Yellow | 🔴 Red |
|-------|--------|----------|-----------|--------|
| PostgreSQL Status | `pg_up` | UP | — | DOWN |
| Active Connections | `pg_stat_database_numbackends` | <100 | <160 | >160 |
| Connection Usage % | connections / max_connections | <70% | <85% | >85% |
| Cache Hit Ratio | blks_hit / (blks_hit + blks_read) | >95% | >85% | <85% |
| Deadlocks (5m) | `pg_stat_database_deadlocks` | 0 | — | >0 |
| Long-Running Queries | `pg_long_running_queries_count` | 0 | >1 | >5 |



**Timeseries panels:**
- **Connections Over Time** — per-database with an 80% threshold reference line
- **Transactions Per Second** — commit rate and rollback rate side by side
- **Cache Hit Ratio Over Time** — with a 90% warning threshold line
- **Deadlocks & Rollbacks** — both rates on one chart

**Additional panels:**
- **Connection State Breakdown** — donut: active / idle / idle-in-transaction / aborted
- **Database Sizes** — horizontal bar gauge, top 10 databases

> **Key signal:** The `idle in transaction` slice of the donut. If it is growing, sessions are holding locks and blocking other queries. The auto-kill script eliminates these after 2 minutes.

---

### Dashboard 2 — Query Performance

![Screenshot_23-3-2026_20745_](https://github.com/user-attachments/assets/8e3188a3-f165-4c3f-8316-b820fd08c709)


**URL:** `http://localhost:3000/d/postgres-query-perf`
**Refresh:** 1 minute | **Requires:** `pg_stat_statements` (enabled by default)

The performance engineering dashboard. This is where you identify which queries are costing the most database time.

**Top 15 Queries table — columns:**

| Column | What it means |
|--------|--------------|
| `query` | Normalised SQL with literals replaced by `$1` |
| `calls` | Total times executed since last reset |
| `total_ms` | Cumulative execution time — **sort by this first** |
| `mean_ms` | Average execution time |
| `max_ms` | Worst single execution ever |
| `cache_hit_pct` | % of reads served from RAM buffer cache |

**How to read it:**
1. Sort by `total_ms` — this is what's consuming the most database CPU overall
2. A query with low `mean_ms` but high `total_ms` is called very frequently — worth optimising
3. High `max_ms` relative to `mean_ms` means inconsistent performance — usually a missing index causing occasional seq scans
4. `cache_hit_pct` below 90% for a specific query means it is regularly reading from disk — investigate indexes or `shared_buffers`

**Other panels:**
- **Execution Time Distribution** — mean, mean+stddev spread, and worst-query max over time
- **Query Call Rate** — top 5 most frequently executed queries
- **Temp Block Writes** — disk spills when `work_mem` is insufficient
- **Cache Efficiency** — shared block hits vs disk reads over time

---

### Dashboard 3 — Locks & Blocking

![Screenshot_23-3-2026_20822_](https://github.com/user-attachments/assets/9d7de84c-bb6a-4dd3-9511-483196c36111)


**URL:** `http://localhost:3000/d/postgres-locks`
**Refresh:** 15 seconds | **Time range:** Last 30 minutes

Open this dashboard when something is blocking production. At 15-second refresh, blocking pairs appear within one scrape cycle of forming.

**Stat panels:**

| Panel | 🟢 Healthy | 🟡 Warning | 🔴 Critical |
|-------|-----------|-----------|------------|
| Blocking Query Pairs | 0 | — | >0 |
| Lock-Waiting Connections | 0 | >2 | >10 |
| Deadlocks (1h) | 0 | >0 | >5 |

**Most important timeseries:**

The **Connection States Over Time** chart. Watch for the `idle in transaction` line (shown in red). A rising `idle in transaction` line *before* the blocking pairs counter rises tells the complete story: a session opened a transaction and stopped working, then other sessions piled up behind the lock it was holding.

**Immediate actions when blocking pairs > 0:**

```sql
-- See who is blocking whom
SELECT * FROM public.v_blocking_queries;

-- Kill the blocker (confirm with team first in production)
SELECT pg_terminate_backend(<blocking_pid>);
```

---

### Dashboard 4 — PgBouncer Pool

![Screenshot_23-3-2026_20857_](https://github.com/user-attachments/assets/6bfa2ce1-813f-489b-9a85-09f374727860)


**URL:** `http://localhost:3000/d/pgbouncer-overview`
**Refresh:** 15 seconds

The single most important number: **Waiting Clients**. Zero is healthy. Any value above zero means applications are waiting for a connection slot and experiencing added latency.

**Stat panels:**

| Panel | 🟢 Green | 🟡 Warning | 🔴 Critical |
|-------|---------|-----------|------------|
| PgBouncer Status | UP | — | DOWN |
| **Waiting Clients** | **0** | **>0** | **>10** |
| Pool Utilisation % | <75% | <90% | >90% |

**Timeseries panels:**
- **Active vs Waiting clients** — the waiting line should stay flat at zero
- **Server Pool Usage** — active, idle, and login-in-progress server connections
- **Query Throughput** — queries/s and transactions/s passing through the bouncer
- **Average Wait Time** — time clients spend queuing for a server connection (healthy: <1ms)

**When pool is saturated:**
1. Check Dashboard 3 for `idle in transaction` sessions — they hold server connections while doing nothing
2. Increase `default_pool_size` in `pgbouncer/pgbouncer.ini`
3. Review application code for connection leaks

---

### Dashboard 5 — Replication & Storage

**URL:** `http://localhost:3000/d/postgres-replication-storage`
**Refresh:** 30 seconds | **Time range:** Last 3 hours

WAL throughput, replica lag, checkpoint health, table sizes, and vacuum pressure.

**Key stat panels:**

| Panel | 🟢 Green | 🟡 Warning | 🔴 Critical |
|-------|---------|-----------|------------|
| Replication Lag (s) | <3s | <10s | >10s |
| Checkpoint Warning % | <20% | <50% | >50% |

> **Checkpoint Warning %** = requested checkpoints / total checkpoints. High values mean WAL is filling up faster than `checkpoint_timeout` can drain it. Fix: increase `max_wal_size`.

**Bar gauge panels:**
- **Top 15 Tables by Total Size** — where disk space is going
- **Top 15 Tables by Dead Tuples** — vacuum pressure; tables with >1M dead tuples trigger an alert

**BGWriter Activity panel:**

| Line | Meaning |
|------|---------|
| BGWriter (clean) | Normal background writes ✓ |
| **Backend writes ⚠** | **Backends writing directly = `shared_buffers` too small** |
| Checkpoint writes | Normal checkpoint activity ✓ |

---

## Metrics Collected

### Connection Metrics

| Metric | Prometheus Name | Alert Threshold |
|--------|----------------|-----------------|
| Active connections per database | `pg_stat_database_numbackends` | >80% max_connections |
| Connections by state + wait event | `pg_active_connections_count` | idle >50 |

### Performance Metrics

| Metric | Prometheus Name | Alert Threshold |
|--------|----------------|-----------------|
| Transactions committed/s | `pg_stat_database_xact_commit` | — |
| Rollbacks/s | `pg_stat_database_xact_rollback` | rollback% >10% |
| Buffer cache hit ratio | derived from blks_hit / blks_read | <90% |
| Temp file bytes written | `pg_stat_database_temp_bytes` | >10MB/s |
| Deadlocks | `pg_stat_database_deadlocks` | >0 |
| Long-running query count | `pg_long_running_queries_count` | >0 for 1m |
| Longest active query age | `pg_long_running_queries_max_age_seconds` | >300s |

### Query-Level Metrics (pg_stat_statements)

| Metric | Prometheus Name |
|--------|----------------|
| Total calls | `pg_stat_statements_calls` |
| Total execution time | `pg_stat_statements_total_exec_time` |
| Mean execution time | `pg_stat_statements_mean_exec_time` |
| Max execution time | `pg_stat_statements_max_exec_time` |
| Shared block cache hits | `pg_stat_statements_shared_blks_hit` |
| Shared block disk reads | `pg_stat_statements_shared_blks_read` |
| Temp blocks written | `pg_stat_statements_temp_blks_written` |

### Lock Metrics

| Metric | Prometheus Name | Alert Threshold |
|--------|----------------|-----------------|
| Blocking query pairs | `pg_blocking_queries_blocking_count` | >0 for 2m |
| Lock-waiting connections | `pg_active_connections_count{wait_event_type="Lock"}` | >5 |

### Replication Metrics

| Metric | Prometheus Name | Alert Threshold |
|--------|----------------|-----------------|
| Replay lag (seconds) | `pg_replication_lag_replay_lag_seconds` | >5s warning, >30s critical |
| Write lag (bytes) | `pg_replication_lag_write_lag_bytes` | — |

### Storage Metrics

| Metric | Prometheus Name | Alert Threshold |
|--------|----------------|-----------------|
| Database size (bytes) | `pg_database_size_bytes` | growth >1GB/hr |
| Dead tuple count | `pg_vacuum_stats_n_dead_tup` | >1M |

---

## Alert Rules

### Routing

```
All alerts
├── severity=critical  ──► critical-receiver  (repeat every 30 minutes)
├── category=replication ► dba-receiver       (repeat every 1 hour)
├── category=performance ► dba-receiver       (repeat every 2 hours)
└── default            ──► default-receiver   (repeat every 4 hours)
```

### Inhibition Rules

- `PostgresExporterDown` fires → suppress all other `Postgres*` alerts for that instance (no alert flood when DB is unreachable)
- `severity=critical` fires → suppress `severity=warning` for the same `instance` + `alertname`

### Full Alert Table

| Alert Name | Severity | Condition | For |
|------------|----------|-----------|-----|
| `PostgresConnectionExhaustion` | 🔴 CRITICAL | connections > 95% of max | 1m |
| `PostgresHighConnectionUsage` | 🟡 WARNING | connections > 80% of max | 2m |
| `PostgresIdleConnections` | 🟡 WARNING | idle connections > 50 | 5m |
| `PostgresLongRunningQueryCritical` | 🔴 CRITICAL | any query running > 5 minutes | 2m |
| `PostgresLongRunningQueries` | 🟡 WARNING | queries running > 5 seconds | 1m |
| `PostgresLowCacheHitRatio` | 🟡 WARNING | cache hit ratio < 90% | 5m |
| `PostgresHighDeadlocks` | 🟡 WARNING | deadlock rate > 0/s | 1m |
| `PostgresHighRollbackRate` | 🟡 WARNING | rollbacks > 10% of total TPS | 5m |
| `PostgresHighTempFileUsage` | 🟡 WARNING | temp writes > 10 MB/s | 5m |
| `PostgresBlockingQueriesDetected` | 🟡 WARNING | blocking pairs > 0 | 2m |
| `PostgresExcessiveLockWaits` | 🟡 WARNING | lock-waiting connections > 5 | 2m |
| `PostgresReplicationLagCritical` | 🔴 CRITICAL | replica lag > 30 seconds | 2m |
| `PostgresReplicationLagHigh` | 🟡 WARNING | replica lag > 5 seconds | 2m |
| `PostgresDatabaseSizeGrowthHigh` | 🟡 WARNING | DB growing > 1 GB/hour | 30m |
| `PostgresHighDeadTuples` | 🟡 WARNING | dead tuples > 1M in one table | 30m |
| `PostgresExporterDown` | 🔴 CRITICAL | postgres_exporter unreachable | 1m |
| `PgBouncerDown` | 🔴 CRITICAL | pgbouncer_exporter unreachable | 1m |

### Configuring Notification Receivers

Edit `alertmanager/alertmanager.yml` and uncomment the appropriate block:

**Slack:**
```yaml
slack_configs:
  - api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
    channel:  '#dba-alerts'
    title:    '{{ .CommonAnnotations.summary }}'
    text:     '{{ .CommonAnnotations.description }}'
    send_resolved: true
```

**PagerDuty:**
```yaml
pagerduty_configs:
  - routing_key: 'YOUR_PAGERDUTY_ROUTING_KEY'
    description: '{{ .CommonAnnotations.summary }}'
```

**Email:**
```yaml
email_configs:
  - to: 'dba-team@yourcompany.com'
    subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
    send_resolved: true
```

Reload Alertmanager after changes (no restart needed):
```bash
curl -X POST http://localhost:9093/-/reload
```

---

## Load Testing

`scripts/load_test.sh` simulates 7 real-world stress scenarios to validate dashboards and alert rules.

### Usage

```bash
./scripts/load_test.sh slow          # 3 parallel 3-second queries
./scripts/load_test.sh connections   # 40 concurrent connections for 8s
./scripts/load_test.sh locks         # Two sessions contend on the same row
./scripts/load_test.sh deadlock      # Force a PostgreSQL deadlock
./scripts/load_test.sh index         # Seq scan vs index scan comparison
./scripts/load_test.sh insert        # 100,000 row insert burst
./scripts/load_test.sh cache         # Large join queries to stress buffer cache
./scripts/load_test.sh all           # All scenarios in sequence
```

### Scenario Details

**`slow`** — Fires 3 parallel queries each sleeping for 3 seconds.
Watch: Dashboard 2 → "Long-Running Queries Now" stat. After 1 minute, the `PostgresLongRunningQueries` alert fires.

**`connections`** — Opens 40 concurrent connections holding for 8 seconds.
Watch: Dashboard 1 → "Active Connections" timeseries and "Connection Usage %" stat.

**`locks`** — Session A holds a row lock for 15 seconds. Session B blocks trying to update the same row.
Watch: Dashboard 3 → "Blocking Query Pairs" (goes to 1), "Lock-Waiting Connections" (goes to 1), `idle in transaction` line rising.

**`deadlock`** — Session A locks row 1 then tries row 2. Session B locks row 2 then tries row 1. PostgreSQL detects the cycle and rolls one back.
Watch: Dashboard 1 → "Deadlocks (5m)" counter, Dashboard 3 → "Deadlock Rate" chart.

**`index`** — Runs `EXPLAIN ANALYZE` on a date-range query without an index (sequential scan), creates the index, then re-runs (index scan). Typical speedup: **62×**.

```
BEFORE:  Seq Scan   — Execution Time: 318.7 ms
AFTER:   Index Scan — Execution Time:   5.1 ms
```

**`insert`** — Inserts 100,000 rows in one transaction.
Watch: Dashboard 1 → "Transactions Per Second" spike, Dashboard 5 → "Database Sizes" growing.

**`cache`** — Runs 3 parallel large JOIN queries.
Watch: Dashboard 1 → "Cache Hit Ratio" dip, Dashboard 2 → "Shared Block Reads" spike.

### Recommended Workflow

1. Open the relevant Grafana dashboard
2. Set refresh to **5 seconds** (top-right dropdown)
3. Run the scenario in a terminal
4. Watch panels update in real time

---

## DBA Runbook

Run all queries via:
```bash
psql -h localhost -p 5432 -U pguser -d appdb
```

---

### "Something is blocking production"

```sql
-- Step 1: See who is blocking whom
SELECT * FROM public.v_blocking_queries;

-- Step 2: Get detail on the blocker
SELECT pid, usename, application_name, client_addr,
       now() - query_start AS duration, query
FROM pg_stat_activity
WHERE pid = <blocking_pid>;

-- Step 3: Kill the blocker
SELECT pg_terminate_backend(<blocking_pid>);
```

---

### "Queries are slow, unclear why"

```sql
-- Reset stats for a clean baseline
SELECT pg_stat_statements_reset();

-- Run workload for 10-15 minutes, then:
SELECT * FROM public.v_top_queries LIMIT 10;

-- Get the EXPLAIN plan for the slow query
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
<paste slow query here>;
-- Look for "Buffers: shared read" in the output — that means disk reads
-- Look for "Seq Scan" where you expect an "Index Scan"
```

---

### "Too many connections"

```sql
-- Breakdown by state
SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY count DESC;

-- Find oldest idle connections
SELECT pid, usename, application_name, client_addr,
       now() - state_change AS idle_duration
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY idle_duration DESC LIMIT 20;

-- Kill idle connections from a specific app idle for >10 minutes
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND application_name = 'your_app_name'
  AND state_change < NOW() - INTERVAL '10 minutes';
```

---

### "High dead tuple count / table bloat"

```sql
-- Find tables needing vacuum
SELECT schemaname, tablename, n_live_tup, n_dead_tup,
       ROUND(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
       last_autovacuum, last_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;

-- Force vacuum
VACUUM (ANALYZE, VERBOSE) app.users;

-- Monitor vacuum progress while it runs
SELECT p.pid, v.relid::regclass AS table, p.phase,
       ROUND(p.heap_blks_scanned::numeric / NULLIF(p.heap_blks_total, 0) * 100, 1) AS pct_done
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity v ON p.pid = v.pid;
```

---

### "Replication is lagging"

```sql
-- Check from primary
SELECT application_name, client_addr, state, sync_state,
       sent_lsn - replay_lsn AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- Check lag from the standby itself
SELECT now() - pg_last_xact_replay_timestamp() AS replication_delay;
```

---

### "Cache hit ratio dropped"

```sql
-- Overall ratio
SELECT * FROM public.v_cache_hit_ratio;

-- Per-table breakdown — find the cold tables
SELECT schemaname, relname AS table_name,
       ROUND(heap_blks_hit::numeric / NULLIF(heap_blks_hit + heap_blks_read, 0) * 100, 2) AS hit_pct
FROM pg_statio_user_tables
WHERE heap_blks_read > 100
ORDER BY heap_blks_read DESC LIMIT 20;
```

---

### "Find unused indexes wasting space"

```sql
SELECT schemaname, tablename, indexname,
       pg_size_pretty(pg_relation_size(schemaname || '.' || indexname)) AS size,
       idx_scan AS times_used
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(schemaname || '.' || indexname) DESC;
```

> Review before dropping — some unused indexes may exist to enforce constraints or support rare reports.

---

## Auto-Kill Script

`scripts/auto_kill.sh` automatically terminates stuck queries and idle-in-transaction sessions. Logs every kill with full context. Safe to run as a cron job.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_HOST` | `localhost` | PostgreSQL host |
| `PG_PORT` | `5432` | PostgreSQL port |
| `PG_USER` | `pguser` | Database user |
| `PG_PASS` | `pgpassword` | Password |
| `PG_DB` | `appdb` | Database name |
| `KILL_THRESHOLD` | `300` | Kill active queries older than N seconds |
| `WARN_THRESHOLD` | `60` | Log a warning for queries older than N seconds |
| `IDLE_TX_THRESHOLD` | `120` | Kill idle-in-transaction sessions older than N seconds |
| `DRY_RUN` | `false` | Set to `true` to log without killing anything |
| `WHITELIST` | `pg_dump\|pg_restore\|pgbouncer\|replication` | Regex of application names to never kill |

### Usage

```bash
# Test mode — log what would be killed without doing anything
DRY_RUN=true ./scripts/auto_kill.sh

# Default thresholds (5min active, 2min idle-in-tx)
./scripts/auto_kill.sh

# Aggressive — kill anything stuck over 2 minutes
KILL_THRESHOLD=120 IDLE_TX_THRESHOLD=60 ./scripts/auto_kill.sh

# Protect migration tools from being killed
WHITELIST="pg_dump|pgbouncer|flyway|liquibase" ./scripts/auto_kill.sh
```

### Deploy as a Cron Job

```bash
crontab -e

# Add this line (runs every minute):
* * * * * PG_HOST=localhost PG_PASS=pgpassword KILL_THRESHOLD=300 /opt/scripts/auto_kill.sh >> /var/log/pg_autokill.log 2>&1
```

### Sample Log Output

```
[2024-01-15 14:32:01] [INFO]  === Auto-Kill Run Start (dry_run=false) ===
[2024-01-15 14:32:01] [INFO]  Thresholds: active>300s  warn>60s  idle_tx>120s
[2024-01-15 14:32:01] [INFO]  Connections — total=47 active=12 idle=31 idle_in_tx=4
[2024-01-15 14:32:02] [WARN]  Slow queries detected (>60s):
[2024-01-15 14:32:02] [WARN]    PID=18422 user=pguser app=python age=74s query='SELECT COUNT(*) FROM...'
[2024-01-15 14:32:02] [KILL]  Killing idle-in-tx PID=18105 user=pguser app=rails idle=184s
[2024-01-15 14:32:02] [KILL]  Killing idle-in-tx PID=17998 user=pguser app=rails idle=210s
[2024-01-15 14:32:02] [INFO]  === Auto-Kill Run Complete ===
```

---

## Slow Query Log Parser

`scripts/parse_slow_logs.py` reads PostgreSQL log files, groups queries by normalised pattern (literals replaced), and prints a ranked slow-query report.

### Usage

```bash
# Parse logs from the running container
docker exec postgres_primary cat /var/lib/postgresql/data/log/postgresql-*.log \
  | python3 scripts/parse_slow_logs.py -

# Parse a local log file
python3 scripts/parse_slow_logs.py /var/log/postgresql/postgresql.log

# Adjust threshold and result count
python3 scripts/parse_slow_logs.py postgresql.log --threshold 500 --top 20

# Only queries slower than 5 seconds
python3 scripts/parse_slow_logs.py postgresql.log --threshold 5000
```

### Sample Output

```
================================================================================
  POSTGRESQL SLOW QUERY REPORT  (threshold: 1000ms)
================================================================================
  Unique query patterns: 47
  Showing top 15 by total execution time

────────────────────────────────────────────────────────────────────────────────
  #1  calls=4120  total=1828.44s  avg=444ms  max=3142ms  min=88ms
  Query: SELECT COUNT(*) FROM app.events WHERE created_at > ? AND event_type = ?
  Last seen: 2024-01-15 14:28:41  (1840ms)

────────────────────────────────────────────────────────────────────────────────
  #2  calls=28441  total=892.31s  avg=31ms  max=412ms  min=2ms
  Query: SELECT o.*, u.email FROM app.orders o JOIN app.users u ON o.user_id = u.id
  Last seen: 2024-01-15 14:31:02  (148ms)
```

---

## Configuration Reference

### `postgres/postgresql.conf` — Key Settings

```ini
# CRITICAL: enables per-query statistics
shared_preload_libraries  = 'pg_stat_statements'
pg_stat_statements.track  = all       # track all queries including nested
pg_stat_statements.max    = 10000     # track up to 10,000 unique query patterns
track_io_timing           = on        # enables block-level I/O timing in pg_stat_statements

# Slow query logging
log_min_duration_statement = 1000     # log queries taking > 1 second
log_lock_waits             = on       # log lock waits exceeding deadlock_timeout
log_autovacuum_min_duration = 250ms   # log autovacuums taking > 250ms

# Replication monitoring (required for replication metrics)
wal_level = replica
```

### `pgbouncer/pgbouncer.ini` — Key Settings

```ini
pool_mode          = transaction  # Best for most web apps
default_pool_size  = 25           # Server connections per user+database pair
max_client_conn    = 200          # Total client connections accepted
reserve_pool_size  = 5            # Emergency extra server connections
client_idle_timeout = 600         # Disconnect idle clients after 10 minutes
```

> **Pool mode warning:** `transaction` mode is incompatible with `SET` commands, advisory locks, and `LISTEN/NOTIFY`. If your app uses these, switch to `session` mode.

### `prometheus/prometheus.yml` — Key Settings

```yaml
global:
  scrape_interval:     15s   # how often to scrape each target
  evaluation_interval: 15s   # how often to evaluate alert rules
  scrape_timeout:      10s   # per-scrape timeout

# storage set via CLI flag in docker-compose.yml:
# --storage.tsdb.retention.time=30d
```

---

## Production Checklist

**Security**
- [ ] Change `POSTGRES_PASSWORD` in `docker-compose.yml` from `pgpassword`
- [ ] Change Grafana admin password from `admin` (Settings → Change Password)
- [ ] Replace plain-text credentials in `pgbouncer/userlist.txt` with SCRAM-SHA-256 hashes
- [ ] Enable SSL in PostgreSQL and set `sslmode=require` in exporter connection strings
- [ ] Restrict `postgres_exporter` and `pgbouncer_exporter` to the monitoring network only

**Alerting**
- [ ] Configure at least one real receiver in `alertmanager/alertmanager.yml`
- [ ] Test by temporarily setting `for: 0m` on one rule and triggering it manually
- [ ] Adjust thresholds to match your actual `max_connections` and SLA requirements

**Automation**
- [ ] Deploy `auto_kill.sh` as a cron job
- [ ] Run with `DRY_RUN=true` for 24 hours before enabling live kills
- [ ] Tune `KILL_THRESHOLD` and `IDLE_TX_THRESHOLD` to match your SLA

**Capacity**
- [ ] Set `shared_buffers` to 25% of available RAM
- [ ] Set `effective_cache_size` to 75% of available RAM
- [ ] Set `max_connections` based on actual load + PgBouncer pool size

**Verification**
- [ ] Confirm all Prometheus targets are green at http://localhost:9090/targets
- [ ] Run `./scripts/load_test.sh all` and confirm every alert fires
- [ ] Set up external uptime monitoring for Grafana and Alertmanager URLs

---

## Performance Tuning Guide

### Cache Hit Ratio Below 90%

Increase `shared_buffers` to 25% of available RAM:

```ini
# postgres/postgresql.conf
shared_buffers   = 4GB    # for a 16 GB server
effective_cache_size = 12GB
```

```bash
docker compose restart postgres
```

### High Temp File Usage (Disk Spills)

Increase `work_mem`. Be careful: this is per sort/hash operation, per connection:

```ini
# postgres/postgresql.conf
work_mem = 32MB    # up from 16MB
```

Apply per-session without restart:
```sql
SET work_mem = '64MB';

-- Or per-role:
ALTER ROLE reporting_user SET work_mem = '128MB';
```

### Requested Checkpoints Exceeding Timed Checkpoints

```ini
# postgres/postgresql.conf
max_wal_size       = 4GB     # up from 2GB
checkpoint_timeout = 15min   # up from 10min
```

### PgBouncer Pool Saturation (Waiting Clients > 0)

```ini
# pgbouncer/pgbouncer.ini
default_pool_size = 40    # up from 25
reserve_pool_size = 10    # up from 5
```

> Monitor `pg_stat_activity` after increasing pool size to confirm PostgreSQL can handle the extra server connections.

### BGWriter Backend Writes Too High

```ini
# postgres/postgresql.conf
bgwriter_lru_maxpages = 200      # up from 100 (pages cleaned per round)
bgwriter_delay        = 100ms    # down from 200ms (more frequent runs)
```

---

## Stopping the Stack

```bash
# Stop services, preserve data volumes
docker compose down

# Stop and wipe all data (fresh start)
docker compose down -v

# Restart a single service after a config change
docker compose restart postgres

# Tail logs for a specific service
docker compose logs -f grafana
docker compose logs -f postgres_exporter
```

---

## Tech Stack

| Component | Image | Role |
|-----------|-------|------|
| PostgreSQL | `postgres:16-alpine` | Primary database |
| PgBouncer | `pgbouncer/pgbouncer:latest` | Connection pooling — transaction mode |
| postgres_exporter | `prometheuscommunity/postgres-exporter:latest` | PostgreSQL → Prometheus bridge |
| pgbouncer_exporter | `prometheuscommunity/pgbouncer-exporter:latest` | PgBouncer → Prometheus bridge |
| Prometheus | `prom/prometheus:latest` | Metrics store + alert evaluation |
| Alertmanager | `prom/alertmanager:latest` | Alert routing and deduplication |
| Grafana | `grafana/grafana:latest` | Dashboards and visualisation |

---



*All Grafana dashboards are hand-built (not imported from the Grafana library). All alert thresholds reflect real-world PostgreSQL operational experience.*
