#!/usr/bin/env bash
# ============================================================
#  PostgreSQL Auto-Kill — Stuck Query Reaper
#  Runs as a cron job or daemon. Logs kills, respects whitelist.
#  
#  Cron example (every minute):
#  * * * * * /path/to/auto_kill.sh >> /var/log/pg_autokill.log 2>&1
# ============================================================
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-pguser}"
PG_PASS="${PG_PASS:-pgpassword}"
PG_DB="${PG_DB:-appdb}"

# Thresholds (seconds)
KILL_THRESHOLD="${KILL_THRESHOLD:-300}"      # Kill queries running > 5 min
WARN_THRESHOLD="${WARN_THRESHOLD:-60}"       # Warn queries running > 1 min
IDLE_TX_THRESHOLD="${IDLE_TX_THRESHOLD:-120}" # Kill idle-in-transaction > 2 min

# Dry-run mode: set to "true" to log without killing
DRY_RUN="${DRY_RUN:-false}"

# Whitelisted applications (comma-separated, regex)
WHITELIST="${WHITELIST:-pg_dump|pg_restore|pgbouncer|replication}"

export PGPASSWORD="$PG_PASS"
PSQL="psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d $PG_DB -t -A"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
kill_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [KILL]  $*"; }

# ─── Warn about long-running queries ─────────────────────────
warn_slow_queries() {
  local query="
    SELECT pid, usename, application_name,
           EXTRACT(EPOCH FROM (NOW() - query_start))::INT AS age_s,
           LEFT(query, 100) AS query_snippet
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query_start < NOW() - make_interval(secs => $WARN_THRESHOLD)
      AND pid <> pg_backend_pid()
      AND application_name !~ '$WHITELIST'
      AND query NOT ILIKE '%auto_kill%'
    ORDER BY age_s DESC;
  "
  local results
  results=$($PSQL -c "$query" 2>/dev/null || echo "")

  if [[ -n "$results" ]]; then
    warn "Slow queries detected (>${WARN_THRESHOLD}s):"
    while IFS='|' read -r pid user app age snippet; do
      warn "  PID=$pid user=$user app=$app age=${age}s query='${snippet}'"
    done <<< "$results"
  fi
}

# ─── Kill long-running active queries ────────────────────────
kill_long_queries() {
  local query="
    SELECT pid, usename, application_name,
           EXTRACT(EPOCH FROM (NOW() - query_start))::INT AS age_s,
           LEFT(query, 100) AS query_snippet
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query_start < NOW() - make_interval(secs => $KILL_THRESHOLD)
      AND pid <> pg_backend_pid()
      AND application_name !~ '$WHITELIST'
      AND query NOT ILIKE '%auto_kill%'
    ORDER BY age_s DESC;
  "
  local results
  results=$($PSQL -c "$query" 2>/dev/null || echo "")

  if [[ -z "$results" ]]; then
    log "No queries exceed ${KILL_THRESHOLD}s threshold."
    return
  fi

  while IFS='|' read -r pid user app age snippet; do
    if [[ "$DRY_RUN" == "true" ]]; then
      kill_log "[DRY-RUN] Would kill PID=$pid user=$user age=${age}s query='${snippet}'"
    else
      kill_log "Killing PID=$pid user=$user app=$app age=${age}s query='${snippet}'"
      $PSQL -c "SELECT pg_terminate_backend($pid);" > /dev/null 2>&1 || true
    fi
  done <<< "$results"
}

# ─── Kill idle-in-transaction sessions ───────────────────────
kill_idle_in_transaction() {
  local query="
    SELECT pid, usename, application_name,
           EXTRACT(EPOCH FROM (NOW() - state_change))::INT AS idle_s,
           LEFT(query, 100) AS last_query
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND state_change < NOW() - make_interval(secs => $IDLE_TX_THRESHOLD)
      AND pid <> pg_backend_pid()
      AND application_name !~ '$WHITELIST'
    ORDER BY idle_s DESC;
  "
  local results
  results=$($PSQL -c "$query" 2>/dev/null || echo "")

  if [[ -z "$results" ]]; then
    return
  fi

  while IFS='|' read -r pid user app idle snippet; do
    if [[ "$DRY_RUN" == "true" ]]; then
      kill_log "[DRY-RUN] Would kill idle-in-tx PID=$pid user=$user idle=${idle}s last='${snippet}'"
    else
      kill_log "Killing idle-in-tx PID=$pid user=$user app=$app idle=${idle}s last='${snippet}'"
      $PSQL -c "SELECT pg_terminate_backend($pid);" > /dev/null 2>&1 || true
    fi
  done <<< "$results"
}

# ─── Connection summary ───────────────────────────────────────
connection_summary() {
  local total active idle idle_tx
  total=$($PSQL -c "SELECT COUNT(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid();" 2>/dev/null || echo "?")
  active=$($PSQL -c "SELECT COUNT(*) FROM pg_stat_activity WHERE state='active' AND pid <> pg_backend_pid();" 2>/dev/null || echo "?")
  idle=$($PSQL -c "SELECT COUNT(*) FROM pg_stat_activity WHERE state='idle' AND pid <> pg_backend_pid();" 2>/dev/null || echo "?")
  idle_tx=$($PSQL -c "SELECT COUNT(*) FROM pg_stat_activity WHERE state='idle in transaction' AND pid <> pg_backend_pid();" 2>/dev/null || echo "?")
  log "Connections — total=$total active=$active idle=$idle idle_in_tx=$idle_tx"
}

# ─── Main ─────────────────────────────────────────────────────
main() {
  log "=== Auto-Kill Run Start (dry_run=$DRY_RUN) ==="
  log "Thresholds: active>${KILL_THRESHOLD}s  warn>${WARN_THRESHOLD}s  idle_tx>${IDLE_TX_THRESHOLD}s"

  connection_summary
  warn_slow_queries
  kill_long_queries
  kill_idle_in_transaction

  log "=== Auto-Kill Run Complete ==="
}

main "$@"