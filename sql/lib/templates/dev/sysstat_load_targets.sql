--
-- sql/lib/templates/dev/sysstat_load_targets.sql
--
-- Body of a "load_targets AS (...)" CTE: the DBA_HIST_SYSSTAT
-- cumulative-counter stat_names tracked by the AWR Load Profile under
-- the DEV template.
--
-- DEV is an application-developer's view: it keeps the stats that
-- reflect what the *application* does to the database -- transaction
-- throughput (commits/rollbacks/executions/user calls), query work
-- (logical/physical reads, full table scans vs rowid fetches),
-- cursor/parse behaviour, sorting, and SQL*Net chattiness -- and drops
-- the storage-engine internals a DBA cares about (redo internals, lost
-- write detection, physical write bytes, redo writes, per-session CPU,
-- parse failures, etc.).
--
-- Deliberately retains the four LOAD names section 08's hero strip
-- hard-references -- 'DB time', 'redo size', 'session logical reads',
-- 'parse count (hard)' -- so the headline cards keep rendering instead
-- of falling back to "n/a".
--
-- The driver resolves ~template_dir = sql/lib/templates/<template>
-- once up front, so consumers write the include as
--   @@~template_dir/sysstat_load_targets.sql
--
            SELECT 'DB time'                                stat_name FROM dual UNION ALL
            SELECT 'DB CPU'                                           FROM dual UNION ALL
            SELECT 'redo size'                                        FROM dual UNION ALL
            SELECT 'session logical reads'                            FROM dual UNION ALL
            SELECT 'physical reads'                                   FROM dual UNION ALL
            SELECT 'user calls'                                       FROM dual UNION ALL
            SELECT 'user commits'                                     FROM dual UNION ALL
            SELECT 'user rollbacks'                                   FROM dual UNION ALL
            SELECT 'execute count'                                    FROM dual UNION ALL
            SELECT 'parse count (total)'                              FROM dual UNION ALL
            SELECT 'parse count (hard)'                               FROM dual UNION ALL
            SELECT 'sorts (memory)'                                   FROM dual UNION ALL
            SELECT 'sorts (disk)'                                     FROM dual UNION ALL
            SELECT 'table scans (long tables)'                        FROM dual UNION ALL
            SELECT 'table fetch by rowid'                             FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'                 FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client'           FROM dual
