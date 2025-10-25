#!/bin/bash
# Script to analyze CPU bursts from pg_activity_snapshots
# Usage:
#   ./analyze-cpu-burst.sh                    # Last 5 minutes
#   ./analyze-cpu-burst.sh "2025-10-25 14:30" # Specific time (5 min window)
#   ./analyze-cpu-burst.sh 15                 # Last N minutes

set -euo pipefail

# PostgreSQL connection parameters
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-postgres}"

# Parse time window
if [ $# -eq 0 ]; then
    # Default: last 5 minutes
    TIME_CONDITION="snapshot_time >= NOW() - INTERVAL '5 minutes'"
    TITLE="Last 5 minutes"
elif [[ "$1" =~ ^[0-9]+$ ]]; then
    # Numeric argument: last N minutes
    TIME_CONDITION="snapshot_time >= NOW() - INTERVAL '$1 minutes'"
    TITLE="Last $1 minutes"
else
    # Specific timestamp: 5-minute window around it
    TIME_CONDITION="snapshot_time BETWEEN '$1'::timestamptz - INTERVAL '2 minutes' AND '$1'::timestamptz + INTERVAL '3 minutes'"
    TITLE="Around $1"
fi

echo "=== CPU Burst Analysis - $TITLE ==="
echo ""

# 1. Overall load average during period
echo "--- Load Average Summary ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT
    MIN(snapshot_time) as period_start,
    MAX(snapshot_time) as period_end,
    COUNT(DISTINCT snapshot_time) as snapshot_count,
    ROUND(AVG(load_avg_1m)::numeric, 2) as avg_load_1m,
    ROUND(MAX(load_avg_1m)::numeric, 2) as max_load_1m,
    ROUND(MIN(load_avg_1m)::numeric, 2) as min_load_1m
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
"

echo ""
echo "--- Top Applications by Query Count ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT
    application_name,
    COUNT(*) as total_snapshots,
    COUNT(DISTINCT pid) as distinct_pids,
    ROUND(AVG(EXTRACT(EPOCH FROM (snapshot_time - query_start)))::numeric, 2) as avg_duration_sec,
    ROUND(MAX(EXTRACT(EPOCH FROM (snapshot_time - query_start)))::numeric, 2) as max_duration_sec
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
  AND state != 'idle'
  AND backend_type = 'client backend'
GROUP BY application_name
ORDER BY total_snapshots DESC
LIMIT 10
"

echo ""
echo "--- Top Queries by Frequency ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT
    COUNT(*) as snapshot_count,
    LEFT(application_name, 40) as app_name,
    state,
    COALESCE(wait_event_type, '') as wait_type,
    COALESCE(wait_event, '') as wait_event,
    ROUND(AVG(EXTRACT(EPOCH FROM (snapshot_time - query_start)))::numeric, 2) as avg_sec,
    REGEXP_REPLACE(LEFT(query, 100), E'[\\n\\r\\t]+', ' ', 'g') as query_preview
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
  AND state != 'idle'
  AND backend_type = 'client backend'
GROUP BY application_name, state, wait_event_type, wait_event, query
ORDER BY snapshot_count DESC
LIMIT 15
"

echo ""
echo "--- Wait Events Summary ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT
    wait_event_type,
    wait_event,
    COUNT(*) as occurrence_count,
    COUNT(DISTINCT application_name) as distinct_apps,
    ROUND(AVG(EXTRACT(EPOCH FROM (snapshot_time - query_start)))::numeric, 2) as avg_duration_sec
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
  AND state != 'idle'
  AND backend_type = 'client backend'
  AND wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY occurrence_count DESC
LIMIT 10
"

echo ""
echo "--- Long-Running Queries (>30s) ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT DISTINCT ON (pid, query_start)
    pid,
    LEFT(application_name, 35) as app_name,
    query_start,
    ROUND(EXTRACT(EPOCH FROM (snapshot_time - query_start))::numeric, 2) as duration_sec,
    state,
    COALESCE(wait_event_type, '') as wait_type,
    COALESCE(wait_event, '') as wait_event,
    REGEXP_REPLACE(LEFT(query, 120), E'[\\n\\r\\t]+', ' ', 'g') as query_preview
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
  AND (snapshot_time - query_start) > INTERVAL '30 seconds'
  AND backend_type = 'client backend'
ORDER BY pid, query_start, snapshot_time DESC
LIMIT 20
"

echo ""
echo "--- Correlation: Load vs Active Queries ---"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
SELECT
    snapshot_time,
    load_avg_1m,
    COUNT(*) as active_query_count,
    COUNT(*) FILTER (WHERE wait_event_type = 'Lock') as lock_waits,
    COUNT(*) FILTER (WHERE wait_event_type = 'IO') as io_waits,
    COUNT(*) FILTER (WHERE state = 'active') as active_state
FROM public.pg_activity_snapshots
WHERE $TIME_CONDITION
  AND backend_type = 'client backend'
GROUP BY snapshot_time, load_avg_1m
ORDER BY load_avg_1m DESC
LIMIT 20
"

echo ""
echo "=== Analysis Complete ==="
