# PostgreSQL Activity Snapshot System

Système de capture continue de `pg_stat_activity` pour analyse post-mortem des CPU bursts.

## Objectif

Capturer automatiquement les queries PostgreSQL toutes les 5 secondes pour analyser les incidents après coup.

## Architecture

```
Serveur PostgreSQL
    ↓
systemd timer (toutes les 5s)
    ↓
snapshot-pg-activity.sh
    ↓
INSERT INTO pg_activity_snapshots
    ↓
Table PostgreSQL (retention 24h)
```

## Installation

```bash
# 1. Créer la table PostgreSQL
sudo -u postgres psql -d postgres -f setup-activity-snapshots.sql

# 2. Installer le script
sudo cp snapshot-pg-activity.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/snapshot-pg-activity.sh

# 3. Installer systemd timer
sudo cp pg-activity-snapshot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pg-activity-snapshot.timer
```

## Utilisation

```bash
# Analyser les 5 dernières minutes
./analyze-cpu-burst.sh

# Analyser un moment précis
./analyze-cpu-burst.sh "2025-10-25 14:30"
```

## Résultat

```
=== Top Applications ===
update-wallet-positions: 320 snapshots, avg 45s
swap-handler: 180 snapshots, avg 120s

=== Wait Events ===
Lock/transactionid: 320 occurrences
IO/DataFileRead: 120 occurrences
```

## Performance

- CPU: ~0.1% par snapshot
- Storage: ~500 MB/jour (auto-nettoyé)
- Fréquence: Toutes les 5s
# Script-postgre-analyze-cpu
