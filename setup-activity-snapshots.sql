-- Table pour stocker les snapshots de pg_stat_activity
-- Permet l'analyse post-mortem des CPU bursts sur la replica

CREATE TABLE IF NOT EXISTS public.pg_activity_snapshots (
    snapshot_id BIGSERIAL PRIMARY KEY,
    snapshot_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    load_avg_1m NUMERIC(10,2),
    load_avg_5m NUMERIC(10,2),
    load_avg_15m NUMERIC(10,2),

    -- Snapshot de la query active
    pid INTEGER,
    usename TEXT,
    application_name TEXT,
    client_addr INET,
    backend_start TIMESTAMPTZ,
    xact_start TIMESTAMPTZ,
    query_start TIMESTAMPTZ,
    state_change TIMESTAMPTZ,
    state TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    query TEXT,
    backend_type TEXT,

    -- Durée de la query au moment du snapshot
    query_duration INTERVAL GENERATED ALWAYS AS (snapshot_time - query_start) STORED
);

-- Index pour recherche rapide par timestamp
CREATE INDEX IF NOT EXISTS idx_snapshots_time ON public.pg_activity_snapshots(snapshot_time DESC);

-- Index pour recherche par application
CREATE INDEX IF NOT EXISTS idx_snapshots_app ON public.pg_activity_snapshots(application_name, snapshot_time DESC);

-- Index pour recherche par état
CREATE INDEX IF NOT EXISTS idx_snapshots_state ON public.pg_activity_snapshots(state, snapshot_time DESC);

-- Index pour recherche par wait_event
CREATE INDEX IF NOT EXISTS idx_snapshots_wait ON public.pg_activity_snapshots(wait_event_type, wait_event, snapshot_time DESC);

-- Partition par jour pour meilleure performance (optionnel si beaucoup de données)
-- CREATE TABLE pg_activity_snapshots_template (LIKE pg_activity_snapshots INCLUDING ALL);

-- Fonction de nettoyage automatique (garde 24h de données)
CREATE OR REPLACE FUNCTION public.cleanup_old_snapshots()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM public.pg_activity_snapshots
    WHERE snapshot_time < NOW() - INTERVAL '24 hours';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Vue pour analyser les queries actives pendant une période donnée
CREATE OR REPLACE VIEW public.v_activity_analysis AS
SELECT
    snapshot_time,
    load_avg_1m,
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    query_duration,
    LEFT(query, 200) as query_preview,
    query as full_query
FROM public.pg_activity_snapshots
WHERE state != 'idle'
  AND backend_type = 'client backend'
ORDER BY snapshot_time DESC, query_duration DESC;

-- Vue pour identifier les top queries pendant les CPU bursts
CREATE OR REPLACE VIEW public.v_burst_culprits AS
SELECT
    snapshot_time,
    load_avg_1m,
    application_name,
    wait_event_type,
    wait_event,
    state,
    COUNT(*) as snapshot_count,
    AVG(EXTRACT(EPOCH FROM query_duration)) as avg_duration_sec,
    MAX(EXTRACT(EPOCH FROM query_duration)) as max_duration_sec,
    LEFT(MIN(query), 300) as sample_query
FROM public.pg_activity_snapshots
WHERE state != 'idle'
  AND backend_type = 'client backend'
  AND load_avg_1m > 10  -- Considère comme burst si load > 10
GROUP BY
    snapshot_time,
    load_avg_1m,
    application_name,
    wait_event_type,
    wait_event,
    state,
    query
ORDER BY snapshot_time DESC, snapshot_count DESC;

COMMENT ON TABLE public.pg_activity_snapshots IS
'Snapshots continus de pg_stat_activity pour analyse post-mortem des CPU bursts. Retention: 24h.';

COMMENT ON VIEW public.v_activity_analysis IS
'Vue simplifiée pour analyser les queries actives à un moment donné.';

COMMENT ON VIEW public.v_burst_culprits IS
'Identifie les queries les plus fréquentes pendant les périodes de CPU burst (load > 10).';
