#!/bin/bash
# Script to snapshot pg_stat_activity and send to Datadog via local agent
# Captures load average and active queries for post-mortem CPU burst analysis

set -euo pipefail

# PostgreSQL connection parameters
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-postgres}"

# Datadog log configuration
DD_SERVICE="${DD_SERVICE:-postgresql-replica}"
DD_ENV="${DD_ENV:-production}"
DD_SOURCE="pg_activity_snapshot_postgres_prod_1"

# Capture load average from /proc/loadavg
read -r LOAD_1M LOAD_5M LOAD_15M _ _ < /proc/loadavg

# Get hostname
HOSTNAME=$(hostname)

# Capture timestamp in ISO8601 format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

# Capture active queries from pg_stat_activity as JSON array
QUERIES_JSON=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -t -A -c "
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
FROM (
    SELECT
        pid,
        usename,
        application_name,
        COALESCE(client_addr::text, 'local') as client_addr,
        ROUND(EXTRACT(EPOCH FROM (NOW() - backend_start))::numeric, 2) as backend_uptime_sec,
        ROUND(EXTRACT(EPOCH FROM (NOW() - xact_start))::numeric, 2) as transaction_duration_sec,
        ROUND(EXTRACT(EPOCH FROM (NOW() - query_start))::numeric, 2) as query_duration_sec,
        state,
        COALESCE(wait_event_type, 'CPU') as wait_event_type,
        COALESCE(wait_event, 'running') as wait_event,
        LEFT(query, 1000) as query_preview,
        backend_type
    FROM pg_stat_activity
    WHERE pid != pg_backend_pid()
      AND backend_type = 'client backend'
      AND state != 'idle'
    ORDER BY query_start ASC
    LIMIT 100
) t;
" 2>/dev/null)

# Fallback if query fails
if [ -z "$QUERIES_JSON" ] || [ "$QUERIES_JSON" = "null" ]; then
    QUERIES_JSON="[]"
fi

# Count active queries
QUERY_COUNT=$(echo "$QUERIES_JSON" | jq -r 'length' 2>/dev/null || echo "0")

# Build structured log entry in JSON format for Datadog (single line)
# IMPORTANT: Must be a single line for Datadog to parse correctly
LOG_ENTRY=$(jq -nc \
    --arg timestamp "$TIMESTAMP" \
    --arg hostname "$HOSTNAME" \
    --arg service "$DD_SERVICE" \
    --arg env "$DD_ENV" \
    --arg source "$DD_SOURCE" \
    --argjson load_1m "$LOAD_1M" \
    --argjson load_5m "$LOAD_5M" \
    --argjson load_15m "$LOAD_15M" \
    --argjson query_count "$QUERY_COUNT" \
    --argjson queries "$QUERIES_JSON" \
    '{
        timestamp: $timestamp,
        hostname: $hostname,
        service: $service,
        env: $env,
        source: $source,
        message: "PostgreSQL activity snapshot",
        load_avg_1m: $load_1m,
        load_avg_5m: $load_5m,
        load_avg_15m: $load_15m,
        active_query_count: $query_count,
        queries: $queries
    }')

# Write to file that Datadog agent tails (single line JSON per log)
LOG_DIR="/var/log/pg-activity-snapshots"
if [ -d "$LOG_DIR" ]; then
    echo "${LOG_ENTRY}" >> "${LOG_DIR}/snapshots.log"
fi
