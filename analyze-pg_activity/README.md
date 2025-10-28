# PostgreSQL Activity Snapshot Extractor

Extract pg_activity snapshots from PostgreSQL servers via SSH for any time interval.

## Setup

```bash
# Copy and configure SSH settings
cp ../.env.example ../.env
# Edit .env with your PostgreSQL SSH credentials (pg00/pg01)
```

## Commands

```bash
# Extract pg_activity snapshots for a time period
./extract_pg_activity_interval.sh <start_time> <end_time> <pg00|pg01> [output_file]

# Examples:
./extract_pg_activity_interval.sh "2025-10-27T16:00" "2025-10-27T16:05" pg00
./extract_pg_activity_interval.sh "2025-10-27T10:00" "2025-10-27T10:05" pg01 normal.json
./extract_pg_activity_interval.sh "2025-10-27T15:00" "2025-10-27T17:00" pg00 long-period.json
```

## Output

Generates JSON files with pg_activity snapshots including:
- System load averages (1m/5m/15m)
- Active query count
- Individual query details (duration, wait events, application name)
- Query preview (first 1000 chars)
- Backend type and state
