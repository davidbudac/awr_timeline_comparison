--
-- sql/lib/day_profile_cte.sql
-- Shared CTE chain for the "Day profile": every hour of the 24 h ending at
-- target_end, scored against the SAME hour-of-day on the profile_days prior
-- days (1-day cadence, independent of step / step_unit).  @@-included right
-- after WITH by sql/16_day_profile.sql (single-DB report) and
-- sql/fleet/06_day_profile.sql (fleet detail band) so the two can never
-- drift.  Pure SELECT, read-only.
--
-- Consumed substitution vars: profile_days, target_end_resolved, dbid_list,
-- inst_num.
--
-- Method (the LAG-delta time-range scan of sections 00/10, NOT windows_cte,
-- which only yields weeks_back+1 windows of win_hours each):
--   dp_snaps   every snapshot in [target_end - (N+1) days, target_end],
--              plus its predecessor via LAG (per dbid + instance)
--   dp_pairs   consecutive snap pairs that survive the restart guard
--              (LAG(startup_time) = startup_time) -- same idea as the
--              pair_keys CTE in 00_params.  Each pair carries its span in
--              seconds and its midpoint.
--   dp_deltas  DBA_HIST_SYSSTAT cumulative-counter deltas for the fixed,
--              template-independent stat list below, restricted to those
--              pairs (the stat's LAG row must be the SAME predecessor snap
--              the pair was built from, so a missing sysstat row can never
--              silently widen a delta across a gap)
--   dp_cells   one cell per (stat, day_off 0..N, hour_slot 0..23): the pair
--              lands in the cell that contains its midpoint; the cell value
--              is the per-second rate SUM(delta)/SUM(span), summed across
--              instances (additive counters, like section 02).
--              COVERAGE GUARD: a cell whose pairs cover < 30 min of the hour
--              is NULL (2-h snap intervals, snapshot gaps, restart-dropped
--              pairs) -- never a misleading 0.
--   dp_grid    dense 9 x 24 x (N+1) frame so every slot exists
--   dp_pivot   per (stat, hour): cur (day 0), mu / sd / n over days 1..N,
--              and a positional per-day CSV (oldest day first, current last)
--   dp_scored  z / pct / bucket using exactly section 07's rules
--
-- hour_slot 0 is the most recent hour (ending at target_end); consumers
-- ORDER BY hour_slot DESC to read the axis chronologically.  hour_label is
-- the HH24:MI at which that hour STARTS.  Snapshot intervals of 1 h or
-- finer fill every cell; coarser intervals leave cells NULL by the guard.
--
dp_params AS (
    SELECT TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS t_end,
           ~profile_days                                             AS n_days
    FROM dual
),
-- Fixed target list.  scale converts the raw per-second rate into the
-- displayed unit (DB time / DB CPU are centiseconds: /100 gives average
-- active sessions / average CPUs busy).  Template-independent on purpose:
-- a day profile should look the same whichever triage template ran.
dp_targets AS (
    SELECT 'DB time'               AS stat_name, 1 AS ord, 'DB time (avg active sessions)' AS label, 0.01 AS scale FROM dual UNION ALL
    SELECT 'DB CPU'                , 2, 'DB CPU (avg CPUs busy)'   , 0.01 FROM dual UNION ALL
    SELECT 'user calls'            , 3, 'user calls/s'             , 1    FROM dual UNION ALL
    SELECT 'execute count'         , 4, 'executions/s'             , 1    FROM dual UNION ALL
    SELECT 'session logical reads' , 5, 'logical reads/s'          , 1    FROM dual UNION ALL
    SELECT 'physical reads'        , 6, 'physical reads/s'         , 1    FROM dual UNION ALL
    SELECT 'physical writes'       , 7, 'physical writes/s'        , 1    FROM dual UNION ALL
    SELECT 'redo size'             , 8, 'redo bytes/s'             , 1    FROM dual UNION ALL
    SELECT 'user commits'          , 9, 'commits/s'                , 1    FROM dual
),
dp_snaps AS (
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
    CROSS JOIN dp_params p
    WHERE  s.dbid IN (~dbid_list)
      -- one extra hour of lead-in so the first in-range snap has a LAG row
      AND  s.end_interval_time BETWEEN CAST(p.t_end - (p.n_days + 1) - 1/24 AS TIMESTAMP)
                                   AND CAST(p.t_end + 5/1440 AS TIMESTAMP)
      AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
),
dp_pairs AS (
    SELECT dbid, snap_id, instance_number, prev_snap_id,
           (end_dt - prev_end_dt) * 86400                           AS span_sec,
           prev_end_dt + (end_dt - prev_end_dt) / 2                 AS mid_dt
    FROM   dp_snaps
    WHERE  prev_snap_id IS NOT NULL
      AND  startup_time = prev_startup            -- restart guard
      AND  end_dt > prev_end_dt
),
dp_deltas AS (
    SELECT ss.dbid, ss.snap_id, ss.instance_number, ss.stat_name,
           ss.value - LAG(ss.value) OVER (PARTITION BY ss.dbid, ss.instance_number, ss.stat_name
                                          ORDER BY ss.snap_id)     AS delta,
           LAG(ss.snap_id) OVER (PARTITION BY ss.dbid, ss.instance_number, ss.stat_name
                                 ORDER BY ss.snap_id)              AS prev_snap_id
    FROM   dba_hist_sysstat ss
    JOIN   dp_snaps s
      ON   s.dbid = ss.dbid
     AND   s.snap_id = ss.snap_id
     AND   s.instance_number = ss.instance_number
    WHERE  ss.stat_name IN (SELECT stat_name FROM dp_targets)
),
dp_cells_raw AS (
    SELECT d.stat_name,
           FLOOR(p.t_end - pr.mid_dt)                               AS day_off,
           FLOOR((p.t_end - pr.mid_dt) * 24)
             - 24 * FLOOR(p.t_end - pr.mid_dt)                      AS hour_slot,
           GREATEST(d.delta, 0)                                     AS delta,
           pr.span_sec
    FROM   dp_deltas d
    JOIN   dp_pairs pr
      ON   pr.dbid = d.dbid
     AND   pr.snap_id = d.snap_id
     AND   pr.instance_number = d.instance_number
     AND   pr.prev_snap_id = d.prev_snap_id
    CROSS JOIN dp_params p
    WHERE  pr.mid_dt <  p.t_end
      AND  pr.mid_dt >= p.t_end - (p.n_days + 1)
),
dp_cells AS (
    SELECT stat_name, day_off, hour_slot,
           CASE WHEN SUM(span_sec) >= 1800
                THEN SUM(delta) / SUM(span_sec) END                 AS rate
    FROM   dp_cells_raw
    GROUP BY stat_name, day_off, hour_slot
),
dp_grid AS (
    SELECT t.stat_name, t.ord, t.label, t.scale, h.hour_slot, d.day_off
    FROM   dp_targets t
    CROSS JOIN (SELECT LEVEL - 1 AS hour_slot FROM dual CONNECT BY LEVEL <= 24) h
    CROSS JOIN (SELECT LEVEL - 1 AS day_off   FROM dual CONNECT BY LEVEL <= ~profile_days + 1) d
),
dp_pivot AS (
    SELECT g.stat_name, g.ord, g.label, g.hour_slot,
           MAX(CASE WHEN g.day_off = 0 THEN c.rate * g.scale END)     AS cur_val,
           AVG(CASE WHEN g.day_off > 0 THEN c.rate * g.scale END)     AS mu,
           STDDEV(CASE WHEN g.day_off > 0 THEN c.rate * g.scale END)  AS sd,
           COUNT(CASE WHEN g.day_off > 0 THEN c.rate END)             AS n,
           -- positional CSV, oldest day first ... current day last.  The
           -- delimiter is folded into the token so a NULL cell keeps its
           -- slot (LISTAGG drops NULL measures AND their delimiter).
           SUBSTR(LISTAGG(',' || TO_CHAR(c.rate * g.scale, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,'''))
                      WITHIN GROUP (ORDER BY g.day_off DESC), 2)     AS day_vals
    FROM   dp_grid g
    LEFT JOIN dp_cells c
      ON   c.stat_name = g.stat_name
     AND   c.day_off   = g.day_off
     AND   c.hour_slot = g.hour_slot
    GROUP BY g.stat_name, g.ord, g.label, g.hour_slot
),
dp_scored AS (
    SELECT pv.stat_name, pv.ord, pv.label, pv.hour_slot,
           TO_CHAR(p.t_end - (pv.hour_slot + 1) / 24, 'HH24:MI')       AS hour_label,
           TO_CHAR(p.t_end - (pv.hour_slot + 1) / 24, 'YYYY-MM-DD HH24:MI') AS hour_start,
           pv.cur_val, pv.mu, pv.sd, pv.n, pv.day_vals,
           CASE WHEN pv.cur_val IS NULL OR pv.mu IS NULL
                     OR pv.sd IS NULL OR pv.sd = 0 THEN NULL
                ELSE (pv.cur_val - pv.mu) / pv.sd END                AS z_score,
           CASE WHEN pv.cur_val IS NULL OR pv.mu IS NULL OR pv.mu = 0 THEN NULL
                ELSE (pv.cur_val - pv.mu) / ABS(pv.mu) * 100 END     AS pct_delta,
           CASE
               WHEN pv.cur_val IS NULL          THEN 'n/a'
               WHEN pv.n < 3                    THEN 'insufficient history'
               WHEN pv.sd IS NULL OR pv.sd = 0  THEN 'flat baseline'
               WHEN ABS((pv.cur_val - pv.mu) / pv.sd) > 3 THEN 'large'
               WHEN ABS((pv.cur_val - pv.mu) / pv.sd) > 2 THEN 'moderate'
               ELSE 'typical'
           END                                                       AS change_bucket
    FROM   dp_pivot pv
    CROSS JOIN dp_params p
)
