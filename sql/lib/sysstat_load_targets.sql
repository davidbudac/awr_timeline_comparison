--
-- sql/lib/sysstat_load_targets.sql
--
-- Body of a "load_targets AS (...)" CTE: the curated list of
-- DBA_HIST_SYSSTAT cumulative-counter stat_names that make up the
-- AWR Load Profile.  Used by section 02 (load profile pivot) and
-- section 07 (findings z-score, LOAD domain).  Keeping a single
-- source of truth here means adding/removing a stat updates both
-- consumers in lock-step.
--
-- Usage (note path is from awr_trend.sql's directory):
--
--   WITH @@sql/lib/windows_cte.sql,
--        load_targets AS (
--            @@sql/lib/sysstat_load_targets.sql
--        ),
--        ...
--
            SELECT 'redo size'                              stat_name FROM dual UNION ALL
            SELECT 'redo size for lost write detection'               FROM dual UNION ALL
            SELECT 'DB time'                                          FROM dual UNION ALL
            SELECT 'DB CPU'                                           FROM dual UNION ALL
            SELECT 'CPU used by this session'                         FROM dual UNION ALL
            SELECT 'session logical reads'                            FROM dual UNION ALL
            SELECT 'physical reads'                                   FROM dual UNION ALL
            SELECT 'physical read total bytes'                        FROM dual UNION ALL
            SELECT 'physical writes'                                  FROM dual UNION ALL
            SELECT 'physical write total bytes'                       FROM dual UNION ALL
            SELECT 'user calls'                                       FROM dual UNION ALL
            SELECT 'user commits'                                     FROM dual UNION ALL
            SELECT 'user rollbacks'                                   FROM dual UNION ALL
            SELECT 'execute count'                                    FROM dual UNION ALL
            SELECT 'parse count (total)'                              FROM dual UNION ALL
            SELECT 'parse count (hard)'                               FROM dual UNION ALL
            SELECT 'parse count (failures)'                           FROM dual UNION ALL
            SELECT 'sorts (memory)'                                   FROM dual UNION ALL
            SELECT 'sorts (disk)'                                     FROM dual UNION ALL
            SELECT 'sorts (rows)'                                     FROM dual UNION ALL
            SELECT 'logons cumulative'                                FROM dual UNION ALL
            SELECT 'opened cursors cumulative'                        FROM dual UNION ALL
            SELECT 'redo writes'                                      FROM dual UNION ALL
            SELECT 'table scans (long tables)'                        FROM dual UNION ALL
            SELECT 'table fetch by rowid'                             FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'                 FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client'           FROM dual
