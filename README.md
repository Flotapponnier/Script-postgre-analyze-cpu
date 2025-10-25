# PostgreSQL Activity Snapshot System

Continuous capture of `pg_stat_activity` for post-mortem analysis of CPU bursts.

## What does this do?

This system automatically takes a "snapshot" of all active PostgreSQL queries **every 5 seconds** and stores them in a table. When you have a CPU burst or incident, you can look back and see exactly which queries were running at that moment.

**Think of it like a black box for your database** - even if the problem only lasted 1 minute, you have a complete recording of what happened.

## How it works

```
PostgreSQL Server
    ↓
systemd timer runs every 5 seconds
    ↓
snapshot-pg-activity.sh captures:
    - Load average (CPU usage)
    - All active queries from pg_stat_activity
    ↓
INSERT INTO pg_activity_snapshots table
    ↓
Data kept for 24 hours (auto-cleaned)
```

**Example:**
- 10:00:00 → Snapshot (load: 5.2, 12 active queries)
- 10:00:05 → Snapshot (load: 5.4, 15 active queries)
- 10:00:10 → Snapshot (load: 25.8, 45 active queries) ← Burst starts
- 10:00:15 → Snapshot (load: 61.9, 102 active queries) ← Peak
- 10:00:20 → Snapshot (load: 48.2, 85 active queries)
- 10:00:25 → Snapshot (load: 12.1, 28 active queries) ← Burst ends

Later, you can analyze what happened at 10:00:15 even if you check hours later.

## Installation (on PostgreSQL server)

**Run these commands on your PostgreSQL server:**

```bash
# 1. Create the snapshot table in PostgreSQL
sudo -u postgres psql -d postgres -f setup-activity-snapshots.sql

# 2. Install the snapshot script
sudo cp snapshot-pg-activity.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/snapshot-pg-activity.sh

# 3. Install and start the systemd timer (runs every 5s automatically)
sudo cp pg-activity-snapshot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pg-activity-snapshot.timer

# 4. Verify it's running
sudo systemctl status pg-activity-snapshot.timer
```

**What happens after installation:**
- The systemd timer starts running in the background
- Every 5 seconds, it captures pg_stat_activity and inserts it into the table
- Data is automatically cleaned after 24 hours
- You don't need to do anything - it runs automatically!

## Checking if it's working

**After installation, verify snapshots are being collected:**

```bash
# On the server, check snapshot count (should increase every 5s)
sudo -u postgres psql -d postgres -c "
SELECT COUNT(*), MIN(snapshot_time), MAX(snapshot_time)
FROM pg_activity_snapshots;
"

# See recent snapshots with load average
sudo -u postgres psql -d postgres -c "
SELECT
    snapshot_time,
    load_avg_1m,
    COUNT(*) as active_queries
FROM pg_activity_snapshots
WHERE snapshot_time >= NOW() - INTERVAL '1 minute'
GROUP BY snapshot_time, load_avg_1m
ORDER BY snapshot_time DESC;
"
```

**Expected output:**
- You should see snapshots being added every 5 seconds
- Each snapshot shows the load average and number of active queries at that moment

## Analyzing CPU bursts

**Scenario:** You got an alert about a CPU burst at 14:30. You want to know what caused it.

### Option 1: Install analysis script on server (recommended)

```bash
# Copy analysis script to server
scp analyze-cpu-burst.sh user@your-server:/tmp/
ssh user@your-server 'sudo cp /tmp/analyze-cpu-burst.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/analyze-cpu-burst.sh'

# Then use it anytime
ssh user@your-server '/usr/local/bin/analyze-cpu-burst.sh "2025-10-25 14:30"'
```

### Option 2: Run from local machine via SSH

```bash
# Analyze last 5 minutes
ssh user@your-server 'bash -s' < analyze-cpu-burst.sh

# Analyze specific time (e.g., when CPU burst happened)
ssh user@your-server 'bash -s -- "2025-10-25 14:30"' < analyze-cpu-burst.sh
```

### Option 3: Manual SQL queries

```bash
# Connect to PostgreSQL and query directly
ssh user@your-server "sudo -u postgres psql -d postgres -c \"
SELECT
    application_name,
    COUNT(*) as snapshot_count,
    AVG(EXTRACT(EPOCH FROM query_duration)) as avg_duration_sec
FROM pg_activity_snapshots
WHERE snapshot_time BETWEEN '14:28' AND '14:33'
GROUP BY application_name
ORDER BY snapshot_count DESC;
\""
```

## What the analysis shows you

When you run the analysis script, you get a complete report:

```
=== Load Average Summary ===
avg_load_1m | max_load_1m | snapshot_count
------------|-------------|---------------
45.2        | 61.9        | 60

→ Confirms there was a CPU burst (load peaked at 61.9)

=== Top Applications ===
application_name         | snapshot_count | avg_duration_sec
------------------------|----------------|------------------
update-wallet-positions | 320            | 45.2
swap-handler            | 180            | 120.5

→ Shows which apps ran the most queries during the burst

=== Top Queries ===
count | wait_event    | query_preview
------|---------------|--------------------------------
85    | LockManager   | UPDATE balances SET amount = ...
60    | transactionid | INSERT INTO swaps (pool_id, ...)

→ The actual queries that were running

=== Wait Events ===
wait_event_type | wait_event    | occurrences
----------------|---------------|-------------
Lock            | transactionid | 320
IO              | DataFileRead  | 120

→ Why queries were blocked (lock contention, I/O waits, etc.)

=== Long-Running Queries ===
pid   | duration_sec | query_preview
------|--------------|---------------------------
12345 | 46800        | VACUUM warehouse.balances_new
67890 | 120          | UPDATE balances SET...

→ Queries that were running for a long time
```

**From this report, you can immediately see:**
- What caused the CPU burst (e.g., too many update-wallet-positions queries)
- Why queries were slow (e.g., lock contention on transactionid)
- What to optimize (e.g., reduce concurrent updates on balances table)

## Performance Impact

- **CPU**: ~0.1% per snapshot (negligible)
- **Storage**: ~500 MB/day (auto-cleaned after 24h)
- **Frequency**: Every 5 seconds
- **Query impact**: None (only reads pg_stat_activity system view)

## Troubleshooting

### Check if timer is running

```bash
sudo systemctl status pg-activity-snapshot.timer
```

### View logs

```bash
sudo journalctl -u pg-activity-snapshot.service -n 50
```

### Stop/restart timer

```bash
# Stop
sudo systemctl stop pg-activity-snapshot.timer

# Start
sudo systemctl start pg-activity-snapshot.timer
```

### Check table size

```bash
sudo -u postgres psql -d postgres -c "
SELECT
    pg_size_pretty(pg_total_relation_size('pg_activity_snapshots')) as size,
    COUNT(*) as rows
FROM pg_activity_snapshots;
"
```

## Use Case Example

**Problem:** CPU burst on replica at 14:30 causing replication lag

**Without this system:**
- At 14:35, you check `pg_stat_activity` → Nothing, burst is over ❌
- No idea what caused it

**With this system:**
```bash
# Run analysis (even hours later)
./analyze-cpu-burst.sh "2025-10-25 14:30"

# Result shows:
# - update-wallet-positions: 85 queries with LockManager waits
# - autovacuum running for 13 hours on balances_new
# - 45 queries blocked on transaction locks

# → Action: Optimize update-wallet-positions to reduce lock contention
```

✅ You can identify and fix the root cause
