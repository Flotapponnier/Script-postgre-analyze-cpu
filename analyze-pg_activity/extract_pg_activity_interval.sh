#!/bin/bash
# Extract pg_activity snapshots for a given time interval
# Usage: ./extract_pg_activity_interval.sh <start_time> <end_time> <server> [output_file]
# Example: ./extract_pg_activity_interval.sh "2025-10-27T16:00" "2025-10-27T16:05" pg00

set -euo pipefail

# Get script directory to find .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env file
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
else
    echo "⚠️  Warning: .env file not found. Using default values."
    echo "   Copy .env.example to .env and configure your SSH settings."
    echo ""
fi

# Display usage
usage() {
    echo "Usage: $0 <start_time> <end_time> <server> [output_file]"
    echo ""
    echo "Arguments:"
    echo "  start_time   - Start time in format: 2025-10-27T16:00"
    echo "  end_time     - End time in format: 2025-10-27T16:05"
    echo "  server       - pg00 or pg01"
    echo "  output_file  - (optional) Output file path, default: pg_activity_<server>_<start>_<end>.json"
    echo ""
    echo "Examples:"
    echo "  # Extract spike period from pg00"
    echo "  $0 '2025-10-27T16:00' '2025-10-27T16:05' pg00"
    echo ""
    echo "  # Extract normal period from pg01 to custom file"
    echo "  $0 '2025-10-27T10:00' '2025-10-27T10:05' pg01 normal-pg01.json"
    echo ""
    echo "  # Extract a full hour"
    echo "  $0 '2025-10-27T15:00' '2025-10-27T16:00' pg00"
    exit 1
}

# Check arguments
if [ $# -lt 3 ]; then
    usage
fi

START_TIME="$1"
END_TIME="$2"
SERVER="$3"

# Determine SSH host from .env or use defaults
case "$SERVER" in
    pg00|pg0)
        SSH_USER="${PG00_SSH_USER:-florent.tapponnier}"
        SSH_HOST_IP="${PG00_SSH_HOST:-35.198.220.217}"
        SSH_PORT="${PG00_SSH_PORT:-22}"
        LOG_PATH="${PG00_LOG_PATH:-/var/log/pg-activity-snapshots/snapshots.log}"
        SSH_HOST="${SSH_USER}@${SSH_HOST_IP}"
        SERVER_NAME="pg00"
        ;;
    pg01|pg1)
        SSH_USER="${PG01_SSH_USER:-florent.tapponnier}"
        SSH_HOST_IP="${PG01_SSH_HOST:-35.240.242.47}"
        SSH_PORT="${PG01_SSH_PORT:-22}"
        LOG_PATH="${PG01_LOG_PATH:-/var/log/pg-activity-snapshots/snapshots.log}"
        SSH_HOST="${SSH_USER}@${SSH_HOST_IP}"
        SERVER_NAME="pg01"
        ;;
    *)
        echo "❌ Error: Invalid server '$SERVER'. Must be pg00 or pg01"
        exit 1
        ;;
esac

# Generate output filename if not provided
if [ $# -ge 4 ]; then
    OUTPUT_FILE="$4"
else
    # Sanitize timestamps for filename
    START_CLEAN=$(echo "$START_TIME" | tr ':' '-')
    END_CLEAN=$(echo "$END_TIME" | tr ':' '-')
    OUTPUT_FILE="pg_activity_${SERVER_NAME}_${START_CLEAN}_${END_CLEAN}.json"
fi

echo "🔍 Extracting pg_activity snapshots"
echo "  Server: $SERVER_NAME ($SSH_HOST)"
echo "  Period: $START_TIME to $END_TIME"
echo "  Output: $OUTPUT_FILE"
echo ""

# Build grep pattern for time range
# Extract hour and minute ranges
START_HOUR=$(echo "$START_TIME" | cut -d'T' -f2 | cut -d':' -f1)
START_MIN=$(echo "$START_TIME" | cut -d'T' -f2 | cut -d':' -f2)
END_HOUR=$(echo "$END_TIME" | cut -d'T' -f2 | cut -d':' -f1)
END_MIN=$(echo "$END_TIME" | cut -d'T' -f2 | cut -d':' -f2)
DATE_PREFIX=$(echo "$START_TIME" | cut -d'T' -f1)

# Simple case: same hour
if [ "$START_HOUR" = "$END_HOUR" ]; then
    # Build minute range pattern
    MIN_PATTERN=""
    for min in $(seq -w "$START_MIN" "$END_MIN"); do
        if [ -z "$MIN_PATTERN" ]; then
            MIN_PATTERN="${min}"
        else
            MIN_PATTERN="${MIN_PATTERN}\\|${min}"
        fi
    done
    GREP_PATTERN="${DATE_PREFIX}T${START_HOUR}:\\(${MIN_PATTERN}\\)"
else
    # Multiple hours: extract each hour separately and combine
    TMP_FILE=$(mktemp)

    for hour in $(seq -w "$START_HOUR" "$END_HOUR"); do
        if [ "$hour" = "$START_HOUR" ]; then
            # First hour: from START_MIN to 59
            for min in $(seq -w "$START_MIN" 59); do
                ssh "$SSH_HOST" "grep '${DATE_PREFIX}T${hour}:${min}' $LOG_PATH || true" >> "$TMP_FILE"
            done
        elif [ "$hour" = "$END_HOUR" ]; then
            # Last hour: from 00 to END_MIN
            for min in $(seq -w 0 "$END_MIN"); do
                ssh "$SSH_HOST" "grep '${DATE_PREFIX}T${hour}:${min}' $LOG_PATH || true" >> "$TMP_FILE"
            done
        else
            # Middle hours: full hour
            ssh "$SSH_HOST" "grep '${DATE_PREFIX}T${hour}:' $LOG_PATH || true" >> "$TMP_FILE"
        fi
    done

    # Convert to JSON array and cleanup
    echo "[" > "$OUTPUT_FILE"
    cat "$TMP_FILE" | sed 's/$/,/' >> "$OUTPUT_FILE"
    # Remove trailing comma and close array
    sed -i '' '$ s/,$//' "$OUTPUT_FILE"
    echo "]" >> "$OUTPUT_FILE"
    rm "$TMP_FILE"

    LINE_COUNT=$(cat "$OUTPUT_FILE" | jq 'length')
    echo "✅ Extracted $LINE_COUNT snapshots to $OUTPUT_FILE"
    exit 0
fi

# For same-hour extraction, fetch directly
echo "  Fetching data from server..."
ssh "$SSH_HOST" "grep '$GREP_PATTERN' $LOG_PATH" > "${OUTPUT_FILE}.tmp" || {
    echo "❌ No data found for the specified time range"
    rm -f "${OUTPUT_FILE}.tmp"
    exit 1
}

# Convert to JSON array format
LINE_COUNT=$(wc -l < "${OUTPUT_FILE}.tmp" | tr -d ' ')

if [ "$LINE_COUNT" -eq 0 ]; then
    echo "❌ No snapshots found for the specified time range"
    rm -f "${OUTPUT_FILE}.tmp"
    exit 1
fi

echo "  Converting to JSON array format..."
echo "[" > "$OUTPUT_FILE"
cat "${OUTPUT_FILE}.tmp" | sed 's/$/,/' >> "$OUTPUT_FILE"
# Remove trailing comma from last line and close array
sed -i '' '$ s/,$//' "$OUTPUT_FILE"
echo "]" >> "$OUTPUT_FILE"

rm "${OUTPUT_FILE}.tmp"

# Validate JSON
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "❌ Error: Generated invalid JSON"
    exit 1
fi

SNAPSHOT_COUNT=$(jq 'length' "$OUTPUT_FILE")

echo "✅ Successfully extracted $SNAPSHOT_COUNT snapshots to $OUTPUT_FILE"
echo ""
echo "📊 Quick stats:"
jq '[.[] | .load_avg_1m] | {min: min, max: max, avg: (add/length)}' "$OUTPUT_FILE" 2>/dev/null || echo "  Could not compute stats"
echo ""
echo "💡 Use this file with analyze_pg_spike.py:"
echo "  ./analyze_pg_spike.py --normal-json <normal_file> --spike-json $OUTPUT_FILE --output report.md"
