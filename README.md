# PostgreSQL CPU Burst Analysis (Datadog)

Système de monitoring pour identifier les requêtes responsables des CPU bursts sur une replica PostgreSQL.

## Problème résolu

**Avant** : CPU bursts sur la replica → impossible d'identifier les requêtes responsables car le burst est terminé quand tu te connectes.

**Maintenant** : Capture de `pg_stat_activity` toutes les 5 secondes → analyse post-mortem dans Datadog même des heures/jours après.

## Architecture

```
PostgreSQL Replica (postgres-prod-1)
    ↓ (toutes les 5 secondes)
systemd timer exécute snapshot-pg-activity-datadog.sh
    ↓
Capture: load average + pg_stat_activity (queries actives)
    ↓
Écrit JSON dans /var/log/pg-activity-snapshots/snapshots.log
    ↓
Agent Datadog lit le fichier
    ↓
Datadog Logs + Dashboard
```

## Installation

### 1. Copier les fichiers sur le serveur

```bash
scp snapshot-pg-activity-datadog.sh \
    pg-activity-snapshot-datadog.service \
    pg-activity-snapshot-datadog.timer \
    datadog-logs-config.yaml \
    florent.tapponnier@35.240.242.47:/tmp/
```

### 2. Installer sur le serveur

```bash
ssh florent.tapponnier@35.240.242.47 'sudo mkdir -p /var/log/pg-activity-snapshots && \
sudo chown postgres:postgres /var/log/pg-activity-snapshots && \
sudo cp /tmp/snapshot-pg-activity-datadog.sh /usr/local/bin/ && \
sudo chmod +x /usr/local/bin/snapshot-pg-activity-datadog.sh && \
sudo cp /tmp/pg-activity-snapshot-datadog.{service,timer} /etc/systemd/system/ && \
sudo mkdir -p /etc/datadog-agent/conf.d/pg_activity_snapshot.d && \
sudo cp /tmp/datadog-logs-config.yaml /etc/datadog-agent/conf.d/pg_activity_snapshot.d/conf.yaml && \
sudo systemctl daemon-reload && \
sudo systemctl enable --now pg-activity-snapshot-datadog.timer && \
sudo systemctl restart datadog-agent'
```

### 3. Importer le dashboard Datadog

1. Va sur https://app.datadoghq.com/dashboard/lists
2. Clique **"New Dashboard"** → **"Import Dashboard JSON"**
3. Copie-colle le contenu de `datadog-dashboard.json`
4. Save

## Ce qui est capturé (toutes les 5 secondes)

Pour chaque snapshot :
- **System load** : `load_avg_1m`, `load_avg_5m`, `load_avg_15m`
- **Active query count** : nombre total de requêtes actives
- **Pour chaque requête active** :
  - `application_name` : quelle app fait la requête
  - `query_duration_sec` : depuis combien de temps la query tourne
  - `wait_event_type` : pourquoi elle est bloquée (CPU, Lock, IO, etc.)
  - `wait_event` : détail du wait event
  - `query_preview` : le texte de la query (1000 premiers chars)

## Dashboard Datadog

Le dashboard inclut :
- **Load Average** : graphique en temps réel avec seuils warning/critical
- **Active Query Count** : nombre de requêtes actives
- **Current Load & Queries** : valeurs actuelles avec code couleur
- **Peak Load & Queries** : pics de la dernière heure
- **Top Applications** : quelles apps font le plus de requêtes
- **Top Wait Events** : pourquoi les requêtes sont bloquées (CPU/Lock/IO)
- **High Load Events** : liste des moments avec >50 queries actives
- **Long Running Queries** : queries qui durent >60 secondes

## Utilisation - Analyser un CPU burst

### Scénario : Alerte CPU burst à 14:30

**Dans le dashboard Datadog** :

1. Ouvre le dashboard "PostgreSQL CPU Burst Analysis"
2. Zoom sur la période 14:28 - 14:33
3. Regarde le graphique **Load Average** → tu vois le pic exact
4. Regarde **Active Query Count** → combien de queries actives au pic
5. Regarde **Top Applications** → quelle app est responsable
6. Regarde **Top Wait Events** → pourquoi les queries étaient lentes
7. Clique sur **High Load Events** → voir les snapshots exacts
8. Clique sur un snapshot → voir les queries complètes avec leur texte

**Dans Datadog Logs Explorer** :

```
# Tous les snapshots pendant le burst
source:pg_activity_snapshot @timestamp:[2025-10-26T14:28:00 TO 2025-10-26T14:33:00]

# Snapshots avec load > 35
source:pg_activity_snapshot @load_avg_1m:>35

# Snapshots avec beaucoup de queries
source:pg_activity_snapshot @active_query_count:>50

# Queries longues (>60s)
source:pg_activity_snapshot @queries.query_duration_sec:>60

# Lock contention
source:pg_activity_snapshot @queries.wait_event_type:Lock

# Application spécifique
source:pg_activity_snapshot @queries.application_name:"stats-global-long*"
```

### Exemple d'analyse

Tu vois dans le dashboard :
- **Peak load : 62.1** à 14:29:10
- **100 queries actives** au pic
- **Top app : `holders-service-bnb`** (58 occurrences)
- **Top wait event : Lock** (45 occurrences)

→ **Conclusion** : `holders-service-bnb` fait trop de queries concurrentes qui se bloquent mutuellement sur des locks.

→ **Action** : Optimiser les queries de `holders-service-bnb` ou réduire la concurrence.

## Queries utiles dans Datadog

```
# Trouver tous les bursts de la journée
source:pg_activity_snapshot @load_avg_1m:>40

# Queries qui causent des lock waits
source:pg_activity_snapshot @queries.wait_event_type:Lock @queries.application_name:*

# Top applications pendant les bursts
source:pg_activity_snapshot @load_avg_1m:>30 | top @queries.application_name

# Timeline des wait events
source:pg_activity_snapshot | timeseries count by @queries.wait_event_type
```

## Vérifier que le système fonctionne

```bash
# Status du timer systemd
ssh florent.tapponnier@35.240.242.47 'sudo systemctl status pg-activity-snapshot-datadog.timer'

# Nombre de snapshots capturés
ssh florent.tapponnier@35.240.242.47 'sudo wc -l /var/log/pg-activity-snapshots/snapshots.log'

# Dernier snapshot
ssh florent.tapponnier@35.240.242.47 'sudo tail -1 /var/log/pg-activity-snapshots/snapshots.log | jq "{timestamp, load: .load_avg_1m, queries: .active_query_count}"'

# Status agent Datadog
ssh florent.tapponnier@35.240.242.47 'sudo datadog-agent status | grep -A 10 pg_activity_snapshot'
```

Dans Datadog :
```
source:pg_activity_snapshot
```
→ Tu devrais voir des logs arriver toutes les 5 secondes.

## Fichiers du projet

**Utilisés en production** :
- `snapshot-pg-activity-datadog.sh` : script de capture (installé dans `/usr/local/bin/`)
- `pg-activity-snapshot-datadog.service` : service systemd
- `pg-activity-snapshot-datadog.timer` : timer systemd (toutes les 5s)
- `datadog-logs-config.yaml` : config agent Datadog pour collecter les logs
- `datadog-dashboard.json` : dashboard Datadog à importer

## Avantages de cette solution

✅ **Fonctionne sur replica read-only** (pas de writes dans PostgreSQL)
✅ **Granularité 5 secondes** (vs 1 minute pour Datadog DBM standard)
✅ **Toutes les queries capturées** (pas d'échantillonnage)
✅ **Corrélation system load + queries PostgreSQL**
✅ **Retention 15+ jours** dans Datadog
✅ **Dashboard visuel** pour analyse rapide
✅ **Alerting possible** (monitor Datadog sur load > seuil)
✅ **Backup local** dans `/var/log/pg-activity-snapshots/` si Datadog down

## Performance

- **CPU impact** : ~0.1% par snapshot (négligeable)
- **Storage** : ~40 KB par snapshot → ~700 MB/jour
- **Fréquence** : Toutes les 5 secondes
- **Queries captées** : Max 100 queries par snapshot

## Désinstallation (si besoin)

```bash
ssh florent.tapponnier@35.240.242.47 'sudo systemctl stop pg-activity-snapshot-datadog.timer && \
sudo systemctl disable pg-activity-snapshot-datadog.timer && \
sudo rm /usr/local/bin/snapshot-pg-activity-datadog.sh && \
sudo rm /etc/systemd/system/pg-activity-snapshot-datadog.{service,timer} && \
sudo rm -rf /etc/datadog-agent/conf.d/pg_activity_snapshot.d && \
sudo systemctl daemon-reload && \
sudo systemctl restart datadog-agent'
```
