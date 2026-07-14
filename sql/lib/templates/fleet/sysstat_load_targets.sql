--
-- sql/lib/templates/fleet/sysstat_load_targets.sql
--
-- Body of a "load_targets AS (...)" CTE: the same 9-stat curated subset of
-- DBA_HIST_SYSSTAT cumulative-counter stat_names as the LOAD domain of
-- sql/lib/is_essential.plsql, used as the FLEET template's triage list.
--
-- These nine stats deliberately overlap with the metric names section 08 /
-- the fleet headline strip hard-reference, so the six hero cards keep
-- rendering (DB time, redo size, session logical reads, parse count (hard))
-- instead of falling back to "n/a".
--
            SELECT 'DB time'                       stat_name FROM dual UNION ALL
            SELECT 'DB CPU'                                  FROM dual UNION ALL
            SELECT 'redo size'                               FROM dual UNION ALL
            SELECT 'session logical reads'                   FROM dual UNION ALL
            SELECT 'physical reads'                          FROM dual UNION ALL
            SELECT 'physical writes'                         FROM dual UNION ALL
            SELECT 'execute count'                           FROM dual UNION ALL
            SELECT 'user commits'                            FROM dual UNION ALL
            SELECT 'parse count (hard)'                      FROM dual
