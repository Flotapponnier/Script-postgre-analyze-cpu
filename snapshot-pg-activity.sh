#!/bin/bash
# Script to snapshot pg_stat_activity every few seconds
# Captures load average and active queries for post-mortem CPU burst analysis

set -euo pipefail

# PostgreSQL connection parameters
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-postgres}"

# Capture load average from /proc/loadavg
read -r LOAD_1M LOAD_5M LOAD_15M _ _ < /proc/loadavg

# Capture active queries from pg_stat_activity
# Exclude:
# - Our own snapshot query
# - Idle connections
# - Background workers we don't care about (autovacuum, logical replication launcher, etc)
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
INSERT INTO public.pg_activity_snapshots (
    snapshot_time,
    load_avg_1m,
    load_avg_5m,
    load_avg_15m,
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    xact_start,
    query_start,
    state_change,
    state,
    wait_event_type,
    wait_event,
    query,
    backend_type
)
SELECT
    NOW() as snapshot_time,
    $LOAD_1M as load_avg_1m,
    $LOAD_5M as load_avg_5m,
    $LOAD_15M as load_avg_15m,
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    xact_start,
    query_start,
    state_change,
    state,
    wait_event_type,
    wait_event,
    query,
    backend_type
FROM pg_stat_activity
WHERE pid != pg_backend_pid()  -- Exclude this query
  AND backend_type = 'client backend'  -- Only client queries
  AND state != 'idle'  -- Only active queries
" -v LOAD_1M="$LOAD_1M" -v LOAD_5M="$LOAD_5M" -v LOAD_15M="$LOAD_15M" > /dev/null

# Cleanup old snapshots (keep last 24h) - run every hour only
CURRENT_MINUTE=$(date +%M)
if [ "$CURRENT_MINUTE" = "00" ]; then
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
        SELECT public.cleanup_old_snapshots();
    " > /dev/null
fi
