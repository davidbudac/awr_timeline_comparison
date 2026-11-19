--
-- sql/lib/onset_cte.sql
-- Private CTE chain of section 25 (Onset): every snapshot pair of the
-- report span and its cumulative-counter deltas, for the section's fixed,
-- template-independent metric list.  @@-included right after WITH, twice
-- by sql/25_onset.sql (once to measure the snapshot interval, once for
-- the series).  Pure SELECT, read-only.
--
-- The LAG-delta time-range scan of sql/lib/day_profile_cte.sql (which is
-- fixed to 24 hourly cells, so it cannot be reused unedited):
--   on_targets  the metric list (DB time / DB CPU in centiseconds, from
--               the time model; the rest per second, from SYSSTAT) and
--               the display scale
--   on_snaps    every snapshot ending in [v_t0 - 2 h, v_t1 + 5 min], with
--               its predecessor via LAG (per dbid + instance)
--   on_pairs    consecutive pairs that survive the restart guard
--               (LAG(startup_time) = startup_time) and overlap
--               [v_t0, v_t1); begin / end as DATE, span in seconds
--   on_src      DBA_HIST_SYSSTAT rows, DB time / DB CPU from
--               DBA_HIST_SYS_TIME_MODEL / 1e4 (SYSSTAT has no DB CPU row;
--               the routing of sql/lib/load_pairs_cte.sql)
--   on_deltas   value - LAG(value) per (dbid, instance, stat) with the
--               LAG snap id, so a consumer can require the stat's
--               predecessor to be the pair's own (prev_snap_id match: a
--               missing row never widens a delta across a gap)
--
-- Consumed PL/SQL variables (the section's DECLARE): v_t0, v_t1 (DATE).
-- Consumed substitution vars: dbid_list, inst_num.
--
on_targets AS (
    SELECT 'DB time'               AS stat_name, 1 AS ord, 0.01 AS scale FROM dual UNION ALL
    SELECT 'DB CPU'                , 2, 0.01 FROM dual UNION ALL
    SELECT 'user calls'            , 3, 1    FROM dual UNION ALL
    SELECT 'execute count'         , 4, 1    FROM dual UNION ALL
    SELECT 'session logical reads' , 5, 1    FROM dual UNION ALL
    SELECT 'physical reads'        , 6, 1    FROM dual UNION ALL
    SELECT 'redo size'             , 7, 1    FROM dual
),
on_snaps AS (
    SELECT s.dbid, s.snap_id, s.instance_number, s.startup_time,
           CAST(s.end_interval_time AS DATE)                       AS end_dt,
           LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                     ORDER BY s.snap_id)           AS prev_startup,
           LAG(CAST(s.end_interval_time AS DATE))
               OVER (PARTITION BY s.dbid, s.instance_number
                     ORDER BY s.snap_id)                           AS prev_end_dt,
           LAG(s.snap_id) OVER (PARTITION BY s.dbid, s.instance_number
                                ORDER BY s.snap_id)                AS prev_snap_id
    FROM   dba_hist_snapshot s
    WHERE  s.dbid IN (~dbid_list)
      AND  s.end_interval_time BETWEEN CAST(v_t0 - 2/24 AS TIMESTAMP)
                                   AND CAST(v_t1 + 5/1440 AS TIMESTAMP)
      AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
),
on_pairs AS (
    SELECT dbid, snap_id, instance_number, prev_snap_id,
           prev_end_dt                                              AS beg_dt,
           end_dt,
           (end_dt - prev_end_dt) * 86400                           AS span_sec
    FROM   on_snaps
    WHERE  prev_snap_id IS NOT NULL
      AND  startup_time = prev_startup            -- restart guard
      AND  end_dt > prev_end_dt
      AND  end_dt > v_t0
      AND  prev_end_dt < v_t1
),
on_src AS (
    SELECT ss.dbid, ss.snap_id, ss.instance_number, ss.stat_name, ss.value
    FROM   dba_hist_sysstat ss
    JOIN   on_snaps s
      ON   s.dbid = ss.dbid
     AND   s.snap_id = ss.snap_id
     AND   s.instance_number = ss.instance_number
    WHERE  ss.stat_name IN (SELECT stat_name FROM on_targets)
      AND  ss.stat_name NOT IN ('DB time', 'DB CPU')
    UNION ALL
    SELECT tm.dbid, tm.snap_id, tm.instance_number, tm.stat_name, tm.value / 1e4
    FROM   dba_hist_sys_time_model tm
    JOIN   on_snaps s
      ON   s.dbid = tm.dbid
     AND   s.snap_id = tm.snap_id
     AND   s.instance_number = tm.instance_number
    WHERE  tm.stat_name IN ('DB time', 'DB CPU')
),
on_deltas AS (
    SELECT dbid, snap_id, instance_number, stat_name,
           value - LAG(value) OVER (PARTITION BY dbid, instance_number, stat_name
                                    ORDER BY snap_id)              AS delta,
           LAG(snap_id) OVER (PARTITION BY dbid, instance_number, stat_name
                              ORDER BY snap_id)                    AS prev_snap_id
    FROM   on_src
)
