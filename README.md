# PostgreSQL Monitoring Stack

> **Production-grade observability for PostgreSQL** — metrics, dashboards, alerting, and DBA tooling assembled into a single `docker compose up` stack.

---

## Architecture

```
                        ┌──────────────────────────────────┐
                        │         Grafana :3000            │
                        │  5 custom dashboards             │
                        │  • DB Health Overview            │
                        │  • Query Performance             │
                        │  • Locks & Blocking              │
                        │  • PgBouncer Pool                │
                        │  • Replication & Storage         │
                        └──────────────┬───────────────────┘
                                       │ queries
                        ┌──────────────▼───────────────────┐
                        │        Prometheus :9090          │
                        │  30-day metric retention         │
                        │  20+ alert rules                 │
                        └──────────┬──────────┬────────────┘
                                   │ scrape   │ scrape
              ┌────────────────────▼──┐   ┌───▼─────────────────────┐
              │  postgres_exporter    │   │   pgbouncer_exporter     │
              │         :9187        │   │         :9127            │
              └────────────┬──────────┘   └───────────┬─────────────┘
                           │                          │
              ┌────────────▼──────────┐  ┌────────────▼─────────────┐
              │   PostgreSQL :5432   │  │    PgBouncer :6432       │
              │   pg_stat_statements │  │   transaction pool       │
              │   pg_stat_activity   │  │   max 200 client conns   │
              └──────────────────────┘  └──────────────────────────┘
                           │
              ┌────────────▼──────────────────┐
              │       Alertmanager :9093      │
              │  routing: critical / warning  │
              │  receivers: webhook / email   │
              └───────────────────────────────┘
```

---

## Repository Layout

```
postgres-monitoring-stack/
│
├── docker-compose.yml              # Full stack definition (7 services)
│
├── postgres/
│   ├── postgresql.conf             # Tuned config: pg_stat_statements, slow log
│   └── queries.yaml                # Custom postgres_exporter metrics
│
├── prometheus/
│   ├── prometheus.yml              # Scrape config: postgres, pgbouncer, alertmanager
│   └── alert_rules.yml             # 20 alert rules across 6 categories
│
├── alertmanager/
│   └── alertmanager.yml            # Routing: critical → PagerDuty, DBA → Slack
│
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/            # Auto-provision Prometheus datasource
│   │   └── dashboards/             # Auto-load dashboards from /dashboards
│   └── dashboards/
│       ├── 01_overview.json        # DB health, connections, TPS, cache, sizes
│       ├── 02_query_performance.json  # pg_stat_statements deep dive
│       ├── 03_locks_blocking.json  # Blocking queries, wait events, deadlocks
│       ├── 04_pgbouncer.json       # Pool utilisation, wait queue, throughput
│       └── 05_replication_storage.json  # WAL, lag, vacuum, bloat
│
├── pgbouncer/
│   ├── pgbouncer.ini               # Transaction pooling config
│   └── userlist.txt                # Auth credentials
│
├── sql/
│   ├── init.sql                    # Schema, extensions, seed data, views, auto-kill fn
│   └── performance_queries.sql     # 17 DBA investigation queries
│
└── scripts/
    ├── load_test.sh                 # 7 stress scenarios (slow/connections/locks/...)
    ├── auto_kill.sh                 # Cron-safe stuck-query reaper
    └── parse_slow_logs.py           # Slow query log analyser
```

---

## Quick Start

### Prerequisites

- Docker ≥ 24 and Docker Compose v2
- Ports available: `5432`, `6432`, `3000`, `9090`, `9093`, `9127`, `9187`

### Start the Stack

```bash
git clone https://github.com/yourname/postgres-monitoring-stack
cd postgres-monitoring-stack

chmod +x scripts/*.sh

docker compose up -d
```

Wait ~30 seconds for all services to initialise, then verify:

```bash
docker compose ps
# All services should show "healthy" or "running"
```

### Access the UIs

| Service       | URL                          | Credentials       |
|---------------|------------------------------|-------------------|
| Grafana       | http://localhost:3000        | admin / admin     |
| Prometheus    | http://localhost:9090        | —                 |
| Alertmanager  | http://localhost:9093        | —                 |
| pg_exporter   | http://localhost:9187/metrics | —                |

Grafana dashboards are auto-provisioned under **Dashboards → PostgreSQL**.

---

## Dashboards

### Dashboard 1 — DB Health Overview
The top-level health screen. Shows at a glance whether the database is healthy.

Key panels:
- PostgreSQL UP/DOWN status
- Active connections and % of max_connections
- Cache hit ratio (green ≥ 95%, red < 85%)
- TPS (commits/s)
- Deadlocks counter
- Long-running query count
- Per-database sizes
- Connection state breakdown (active/idle/idle-in-tx)

### Dashboard 2 — Query Performance
Deep dive into `pg_stat_statements`. This is your primary performance tuning tool.

Key panels:
- Top 15 queries by total execution time (table)
- Execution time distribution (mean ± stddev over time)
- Query call rate — most frequently executed
- Temp block writes (work_mem spills)
- Shared block cache efficiency

> **Interview tip**: This dashboard answers "which query is killing my database?" in under 10 seconds.

### Dashboard 3 — Locks & Blocking
Real-time lock contention monitoring.

Key panels:
- Blocking query pairs (fires alert if > 0 for 2m)
- Lock-waiting connections
- Connection state over time — `idle in transaction` is the red flag
- Deadlock rate over time
- Wait event type distribution (Lock / IO / IPC / Client)

### Dashboard 4 — PgBouncer Pool
Connection pool health. Add this to any production deployment.

Key panels:
- Active vs waiting clients (waiting > 0 = pool saturated)
- Server pool utilisation %
- Query throughput via bouncer (TPS)
- Average client wait time in queue

### Dashboard 5 — Replication & Storage
WAL throughput, replica lag, and storage health.

Key panels:
- Replication lag (s) per replica
- Checkpoint activity: timed vs requested (requested > timed = WAL too fast)
- Top 15 tables by size
- Top 15 tables by dead tuples (vacuum pressure)
- BGWriter buffer writes by source (backend writes = bad)

---

## Metrics Collected

### Core Database Health
| Metric | Source | Alert |
|--------|--------|-------|
| Active connections | pg_stat_database | > 80% max_connections |
| Idle connections | pg_stat_activity | > 50 idle |
| Transactions per second | pg_stat_database | — |
| Deadlocks | pg_stat_database | > 0 |
| Rollback rate | pg_stat_database | > 10% |

### Performance
| Metric | Source | Alert |
|--------|--------|-------|
| Query execution time | pg_stat_statements | mean > 2s |
| Long-running queries | pg_stat_activity | > 5s running |
| Cache hit ratio | pg_stat_database | < 90% |
| Temp file writes | pg_stat_database | > 10MB/s |

### Locking
| Metric | Source | Alert |
|--------|--------|-------|
| Blocking pairs | pg_stat_activity | > 0 for 2m |
| Lock wait connections | pg_stat_activity | > 5 |

### Replication
| Metric | Source | Alert |
|--------|--------|-------|
| Replay lag (s) | pg_stat_replication | > 5s |
| Write lag (bytes) | pg_stat_replication | — |

### Storage
| Metric | Source | Alert |
|--------|--------|-------|
| Database size | pg_database_size | growth > 1GB/hr |
| Dead tuple count | pg_stat_user_tables | > 1M |

---

## Alert Rules

Alerts are defined in `prometheus/alert_rules.yml` and routed via Alertmanager.

| Alert | Severity | Condition |
|-------|----------|-----------|
| PostgresHighConnectionUsage | warning | connections > 80% max |
| PostgresConnectionExhaustion | **critical** | connections > 95% max |
| PostgresIdleConnections | warning | idle > 50 |
| PostgresLongRunningQueries | warning | active queries > 5s |
| PostgresLongRunningQueryCritical | **critical** | any query > 5 min |
| PostgresLowCacheHitRatio | warning | hit ratio < 90% |
| PostgresHighDeadlocks | warning | deadlock rate > 0 |
| PostgresHighRollbackRate | warning | rollbacks > 10% |
| PostgresHighTempFileUsage | warning | temp writes > 10MB/s |
| PostgresBlockingQueriesDetected | warning | blocking pairs > 0 for 2m |
| PostgresExcessiveLockWaits | warning | lock-waiting > 5 |
| PostgresReplicationLagHigh | warning | lag > 5s |
| PostgresReplicationLagCritical | **critical** | lag > 30s |
| PostgresDatabaseSizeGrowthHigh | warning | growth > 1GB/hr |
| PostgresHighDeadTuples | warning | dead tuples > 1M |
| PostgresExporterDown | **critical** | exporter unreachable |
| PgBouncerDown | **critical** | pgbouncer exporter down |

### Alertmanager Routing

```
All alerts
├── severity=critical  → critical-receiver  (30m repeat)
├── category=replication → dba-receiver     (1h repeat)
├── category=performance → dba-receiver     (2h repeat)
└── default            → default-receiver   (4h repeat)
```

Configure receivers in `alertmanager/alertmanager.yml`:
- Uncomment `slack_configs` for Slack
- Uncomment `pagerduty_configs` for PagerDuty
- Uncomment `email_configs` for email

---

## Load Testing

Simulate real-world database stress with the included script:

```bash
# Run all scenarios
./scripts/load_test.sh all

# Individual scenarios
./scripts/load_test.sh slow         # 3 × 3-second queries → watch Query Performance
./scripts/load_test.sh connections  # 40 concurrent connections → watch Overview
./scripts/load_test.sh locks        # Lock contention pair → watch Locks dashboard
./scripts/load_test.sh deadlock     # Force a deadlock → watch Deadlocks counter
./scripts/load_test.sh index        # Seq scan vs index scan comparison
./scripts/load_test.sh insert       # 100K row burst → watch TPS spike
./scripts/load_test.sh cache        # Large joins → watch Cache Hit Ratio drop
```

> Open Grafana before running scenarios. Set dashboard refresh to **5s** for best effect.

### Expected Observations

| Scenario | Dashboard to Watch | Panel |
|----------|--------------------|-------|
| `slow` | Query Performance | Long-Running Queries stat |
| `connections` | DB Health Overview | Active Connections timeseries |
| `locks` | Locks & Blocking | Blocking Query Pairs stat |
| `deadlock` | DB Health Overview | Deadlocks counter |
| `insert` | DB Health Overview | TPS panel spike |
| `cache` | Query Performance | Shared block reads spike |
| `index` | Terminal output | EXPLAIN cost comparison |

---

## Auto-Kill Script

The auto-kill script terminates stuck queries and idle-in-transaction sessions automatically.

```bash
# Dry run (logs what would be killed, no action)
DRY_RUN=true ./scripts/auto_kill.sh

# Kill queries running > 5 minutes
KILL_THRESHOLD=300 ./scripts/auto_kill.sh

# Kill idle-in-transaction sessions holding locks > 2 minutes
IDLE_TX_THRESHOLD=120 ./scripts/auto_kill.sh

# Protect specific apps from being killed
WHITELIST="pg_dump|pgbouncer|myapp_migration" ./scripts/auto_kill.sh
```

**As a cron job (every minute):**

```bash
* * * * * PG_HOST=localhost PG_PASS=pgpassword /opt/scripts/auto_kill.sh >> /var/log/pg_autokill.log 2>&1
```

---

## Slow Log Analysis

The log parser extracts and groups slow query patterns from PostgreSQL log files.

```bash
# Parse logs from running container
docker exec postgres_primary cat /var/lib/postgresql/data/log/postgresql-*.log \
  | python3 scripts/parse_slow_logs.py - --threshold 500 --top 20

# Parse a local log file
python3 scripts/parse_slow_logs.py /var/log/postgresql/postgresql.log

# Show only very slow queries (> 5s)
python3 scripts/parse_slow_logs.py postgresql.log --threshold 5000
```

---

## DBA Investigation Runbook

### "My queries are slow"

```sql
-- Find top offenders by cumulative time
SELECT * FROM public.v_top_queries;

-- Check for cache pressure
SELECT * FROM public.v_cache_hit_ratio;
```

### "Something is blocking production"

```sql
-- See blocking pairs
SELECT * FROM public.v_blocking_queries;

-- Kill the blocker (with care)
SELECT pg_terminate_backend(<blocking_pid>);
```

### "Too many connections"

```bash
# Check counts
psql -c "SELECT state, COUNT(*) FROM pg_stat_activity GROUP BY state;"

# PgBouncer is your friend — add more connections through the pool
# without touching max_connections
```

### "Database is slow, unclear why"

```sql
-- Reset stats for clean baseline
SELECT pg_stat_statements_reset();

-- Run workload for 10 minutes, then check
SELECT * FROM public.v_top_queries LIMIT 10;
```

### "High dead tuple count"

```sql
-- Find worst offenders
SELECT schemaname, tablename, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 10;

-- Force vacuum
VACUUM ANALYZE app.users;
```

### "Replication is lagging"

```sql
-- Check replica status from primary
SELECT application_name, replay_lag, write_lag, flush_lag
FROM pg_stat_replication;

-- Check standby is in recovery
SELECT pg_is_in_recovery();
```

---

## Tuning Recommendations

### When cache hit ratio < 90%
Increase `shared_buffers` in `postgres/postgresql.conf`:
```
shared_buffers = 512MB   # up from 256MB
```

### When temp file writes are high
Increase `work_mem`:
```
work_mem = 32MB   # per sort operation
```

### When checkpoint warnings fire
Increase `max_wal_size`:
```
max_wal_size = 4GB
```

### When connection count is consistently high
Lower `default_pool_size` in PgBouncer is wrong — instead, review application connection settings and ensure idle connections are released. Transaction pooling mode allows many more logical clients than physical server connections.

---

## Stopping the Stack

```bash
# Stop but preserve data volumes
docker compose down

# Stop and wipe all data (fresh start)
docker compose down -v
```

---

## Production Checklist

Before deploying to production:

- [ ] Change all default passwords (`pgpassword`, `monitor_password`, Grafana `admin`)
- [ ] Use SCRAM-SHA-256 in `pg_hba.conf` (not `trust`)
- [ ] Generate proper PgBouncer password hashes in `userlist.txt`
- [ ] Configure real alertmanager receivers (Slack/PagerDuty/email)
- [ ] Set `DRY_RUN=false` in `auto_kill.sh` only after testing thresholds
- [ ] Tune `KILL_THRESHOLD` and `IDLE_TX_THRESHOLD` for your SLA
- [ ] Set `log_min_duration_statement` appropriately (1000ms for most workloads)
- [ ] Review `max_connections` vs `default_pool_size` ratio
- [ ] Add TLS/SSL for PostgreSQL connections (`sslmode=require`)
- [ ] Restrict `postgres_exporter` network access to monitoring VLAN only

---

## Tech Stack

| Component | Version | Role |
|-----------|---------|------|
| PostgreSQL | 16 | Primary database |
| postgres_exporter | latest | Metrics bridge (Prometheus format) |
| pgbouncer_exporter | latest | PgBouncer metrics |
| Prometheus | latest | Time-series metrics store |
| Alertmanager | latest | Alert routing and deduplication |
| Grafana | latest | Dashboards and visualisation |
| PgBouncer | latest | Connection pooling |

---

*Built as a portfolio demonstration of senior DBA / backend infrastructure skills. All dashboards are hand-crafted (not imported) and all alert thresholds are derived from real-world PostgreSQL operational experience.*