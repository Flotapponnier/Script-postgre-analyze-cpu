# PostgreSQL Activity Snapshot System

Continuous capture of `pg_stat_activity` for post-mortem analysis of CPU bursts.

## Objective

Automatically capture PostgreSQL queries every 5 seconds to analyze incidents after they occur.

## Architecture

```
PostgreSQL Server
    ↓
systemd timer (every 5s)
    ↓
snapshot-pg-activity.sh
    ↓
INSERT INTO pg_activity_snapshots
    ↓
PostgreSQL table (24h retention)
```

## Installation

```bash
# 1. Create PostgreSQL table
sudo -u postgres psql -d postgres -f setup-activity-snapshots.sql

# 2. Install script
sudo cp snapshot-pg-activity.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/snapshot-pg-activity.sh

# 3. Install systemd timer
sudo cp pg-activity-snapshot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pg-activity-snapshot.timer
```

## Usage

```bash
# Analyze last 5 minutes
./analyze-cpu-burst.sh

# Analyze specific time
./analyze-cpu-burst.sh "2025-10-25 14:30"
```

## Output

```
=== Top Applications ===
update-wallet-positions: 320 snapshots, avg 45s
swap-handler: 180 snapshots, avg 120s

=== Wait Events ===
Lock/transactionid: 320 occurrences
IO/DataFileRead: 120 occurrences
```

## Performance

- CPU: ~0.1% per snapshot
- Storage: ~500 MB/day (auto-cleaned)
- Frequency: Every 5s
# Script-postgre-analyze-cpu
