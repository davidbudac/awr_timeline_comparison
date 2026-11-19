--
-- sql/lib/loadresp_cte.sql
--
-- Private to section 20 (Load vs response time): the per-snapshot points
-- of the scatter, from DBA_HIST_SYSMETRIC_SUMMARY, across the full report
-- span (the earliest compared window start to the Current window end).
-- Continues a WITH clause that already holds sql/lib/windows_cte.sql:
--
--   WITH
--   @@sql/lib/windows_cte.sql
--   ,
--   @@sql/lib/loadresp_cte.sql
--   SELECT ... FROM lr_pts ...
--
-- Provides:
--   lr_span   one row: t_lo / t_hi = the span bounds (requested edges,
--             t_hi plus 15 min so the Current end snap is inside)
--   lr_snaps  every snapshot of the span whose PREVIOUS snapshot (same
--             dbid, instance) has the same startup_time: the restart
--             guard of sections 00 / 10 (a first interval after a bounce
--             is partial and left out)
--   lr_cur    the Current window's valid (dbid, instance, snap range)
--   lr_pts    one row per (dbid, snap_id): end_ts, cur (1 = inside the
--             Current window), and the five metrics rolled up across
--             instances the way the templates tag them: the rates
--             (User Calls / Executions / Logical Reads / Database Time
--             Per Sec) SUM, SQL Service Response Time (a ratio) AVG.
--
-- The metric list is fixed here (template-independent, like section 13):
-- the section must have the same axes under every template.
-- Substitution variables: dbid_list, inst_num (via the parent's CTE).
-- No tilde-words in comments below.
--
        lr_span AS (
            SELECT CAST(MIN(win_start_dt) AS TIMESTAMP) AS t_lo,
                   CAST(MAX(win_end_dt) AS TIMESTAMP) + INTERVAL '15' MINUTE AS t_hi
            FROM   raw_windows
        ),
        lr_snaps AS (
            SELECT dbid, instance_number, snap_id, end_ts
            FROM (
                SELECT s.dbid, s.instance_number, s.snap_id,
                       s.end_interval_time AS end_ts, s.startup_time,
                       LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                                 ORDER BY s.snap_id) AS prev_startup
                FROM   dba_hist_snapshot s
                CROSS JOIN lr_span p
                WHERE  s.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
                  AND  s.end_interval_time >  p.t_lo - INTERVAL '1' DAY
                  AND  s.end_interval_time <= p.t_hi
            ) x
            CROSS JOIN lr_span p
            WHERE  x.prev_startup IS NOT NULL
              AND  x.startup_time = x.prev_startup
              AND  x.end_ts > p.t_lo
        ),
        lr_cur AS (
            SELECT dbid, instance_number, begin_snap_id, end_snap_id
            FROM   valid_windows
            WHERE  week_offset = 0
        ),
        lr_pts AS (
            SELECT sn.dbid, sn.snap_id,
                   MIN(sn.end_ts) AS end_ts,
                   MAX(CASE WHEN c.end_snap_id IS NOT NULL THEN 1 ELSE 0 END) AS cur,
                   SUM(CASE WHEN sm.metric_name = 'User Calls Per Sec'    THEN sm.average END) AS uc,
                   SUM(CASE WHEN sm.metric_name = 'Executions Per Sec'    THEN sm.average END) AS ex,
                   SUM(CASE WHEN sm.metric_name = 'Logical Reads Per Sec' THEN sm.average END) AS lr,
                   AVG(CASE WHEN sm.metric_name = 'SQL Service Response Time' THEN sm.average END) AS srt,
                   SUM(CASE WHEN sm.metric_name = 'Database Time Per Sec' THEN sm.average END) AS dbt
            FROM   lr_snaps sn
            JOIN   dba_hist_sysmetric_summary sm
              ON   sm.dbid = sn.dbid
             AND   sm.snap_id = sn.snap_id
             AND   sm.instance_number = sn.instance_number
             AND   sm.metric_name IN ('User Calls Per Sec', 'Executions Per Sec',
                                      'Logical Reads Per Sec', 'SQL Service Response Time',
                                      'Database Time Per Sec')
            LEFT JOIN lr_cur c
              ON   c.dbid = sn.dbid
             AND   c.instance_number = sn.instance_number
             AND   sn.snap_id BETWEEN c.begin_snap_id + 1 AND c.end_snap_id
            GROUP BY sn.dbid, sn.snap_id
        )
