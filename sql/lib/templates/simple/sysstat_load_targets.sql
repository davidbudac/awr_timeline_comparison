--
-- sql/lib/templates/simple/sysstat_load_targets.sql
--
-- Body of a "load_targets AS (...)" CTE: a small triage-friendly
-- subset of DBA_HIST_SYSSTAT cumulative-counter stat_names for the
-- AWR Load Profile under the SIMPLE template.
--
-- These nine stats deliberately overlap with the metric names that
-- section 08 (hero strip) hard-references, so the headline cards in
-- 'simple' mode keep rendering (DB time, redo size, session logical
-- reads, parse count (hard)) instead of falling back to "n/a".
--
-- 'DB time' and 'DB CPU' are TIME MODEL names: sql/lib/load_pairs_cte.sql
-- reads those two from DBA_HIST_SYS_TIME_MODEL (DBA_HIST_SYSSTAT has no
-- 'DB CPU' row), converted to centiseconds like SYSSTAT's DB time.
--
            SELECT 'DB time'                       stat_name FROM dual UNION ALL
            SELECT 'DB CPU'                                  FROM dual UNION ALL
            SELECT 'redo size'                               FROM dual UNION ALL
            SELECT 'session logical reads'                   FROM dual UNION ALL
            SELECT 'physical reads'                          FROM dual UNION ALL
            SELECT 'physical writes'                         FROM dual UNION ALL
            SELECT 'user calls'                              FROM dual UNION ALL
            SELECT 'user commits'                            FROM dual UNION ALL
            SELECT 'parse count (hard)'                      FROM dual
