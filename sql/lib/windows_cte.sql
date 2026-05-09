--
-- sql/lib/windows_cte.sql
--
-- Canonical CTE chain that resolves the current + ~weeks_back prior
-- comparison windows from dba_hist_snapshot. Sections @@-include this
-- under their `WITH` clause instead of carrying their own copy.
--
-- Usage from a section file. NOTE: SQL*Plus @@ in nested scripts is
-- resolved relative to the OUTERMOST caller's directory (verified on
-- Oracle 19c sqlplus), so the include path must be the full path from
-- awr_trend.sql's directory:
--
--   FOR r IN (
--       WITH
--       @@sql/lib/windows_cte.sql
--       SELECT ... FROM windows;            -- (no extra CTEs)
--   ) LOOP ... END LOOP;
--
--   FOR r IN (
--       WITH
--       @@sql/lib/windows_cte.sql
--       , my_extra AS ( SELECT ... FROM valid_windows )
--       SELECT ... FROM my_extra;           -- (extra CTEs)
--   ) LOOP ... END LOOP;
--
-- Provides (in order):
--   run_params      single-row driver inputs (dbid, instance_number,
--                   target_end_ts, win_hours, weeks_back, top_n)
--   offsets         rows for each week_offset 0..weeks_back
--   raw_windows     unsnapped time bounds per offset
--   snaps           candidate snaps within each window's bracket,
--                   carrying instance_number
--   begin_snap      resolved begin snap per (offset, instance_number)
--   end_snap        resolved end snap per (offset, instance_number)
--   instance_pairs  FULL OUTER JOIN of begin/end on
--                   (offset, instance_number), so an instance with
--                   only one of the two snaps still surfaces (and
--                   gets flagged invalid below)
--   windows         per (offset, instance_number) metadata + valid_flag
--                   + skip_reason. RAC: one row per instance per offset.
--                   Single-instance: one row per offset.
--   valid_windows   only valid_flag='Y' rows + dur_sec, per
--                   (offset, instance_number). Downstream cumulative
--                   sections SUM(end - begin) GROUP BY offset, which
--                   correctly aggregates only valid instance pairs.
--   windows_rollup  per (offset) summary used by display sections
--                   (01, 09): valid_flag = 'Y' iff at least one
--                   instance is valid; begin/end snap range; first
--                   non-null skip_reason. Preserves single-instance
--                   byte-identity.
--
-- Substitution variables consumed (resolved once by awr_trend.sql):
--   ~dbid ~inst_num ~target_end_resolved
--   ~win_hours ~weeks_back ~top_n ~step_hours
--
        run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours,
                   ~weeks_back AS weeks_back,
                   ~top_n      AS top_n
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset
            FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        raw_windows AS (
            SELECT r.dbid, r.instance_number, o.week_offset,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset - r.win_hours/24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset                   AS win_end_dt
            FROM run_params r CROSS JOIN offsets o
        ),
        snaps AS (
            SELECT w.week_offset, w.win_start_dt, w.win_end_dt, w.dbid,
                   s.instance_number,
                   s.snap_id, s.end_interval_time, s.startup_time
            FROM   raw_windows w
            JOIN   dba_hist_snapshot s
              ON   s.dbid = w.dbid
             AND   (w.instance_number IS NULL OR s.instance_number = w.instance_number)
             AND   s.end_interval_time BETWEEN
                        CAST(w.win_start_dt - 1 AS TIMESTAMP)
                    AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
        ),
        begin_snap AS (
            SELECT week_offset, instance_number,
                   MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS snap_id,
                   MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
            GROUP BY week_offset, instance_number
        ),
        end_snap AS (
            SELECT week_offset, instance_number,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
            GROUP BY week_offset, instance_number
        ),
        instance_pairs AS (
            SELECT NVL(bs.week_offset,     es.week_offset)     AS week_offset,
                   NVL(bs.instance_number, es.instance_number) AS instance_number,
                   bs.snap_id      AS begin_snap_id,
                   bs.startup_time AS begin_startup_time,
                   es.snap_id      AS end_snap_id,
                   es.startup_time AS end_startup_time
            FROM   begin_snap bs
            FULL OUTER JOIN end_snap es
              ON  es.week_offset     = bs.week_offset
             AND  es.instance_number = bs.instance_number
        ),
        windows AS (
            SELECT
                w.week_offset, w.dbid,
                ip.instance_number,
                CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
                CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts,
                ip.begin_snap_id,
                ip.end_snap_id,
                CASE
                    WHEN ip.instance_number IS NULL                    THEN 'N'
                    WHEN ip.begin_snap_id IS NULL                      THEN 'N'
                    WHEN ip.end_snap_id   IS NULL                      THEN 'N'
                    WHEN ip.begin_snap_id = ip.end_snap_id             THEN 'N'
                    WHEN ip.begin_startup_time <> ip.end_startup_time  THEN 'N'
                    ELSE 'Y'
                END AS valid_flag,
                CASE
                    WHEN ip.instance_number IS NULL THEN 'no snapshots in window for any instance'
                    WHEN ip.begin_snap_id IS NULL THEN 'no snapshot at/before window start'
                    WHEN ip.end_snap_id   IS NULL THEN 'no snapshot at/after window end'
                    WHEN ip.begin_snap_id = ip.end_snap_id THEN 'begin and end snapshot identical (window shorter than AWR interval)'
                    WHEN ip.begin_startup_time <> ip.end_startup_time THEN 'instance restarted inside window'
                    ELSE NULL
                END AS skip_reason
            FROM   raw_windows w
            LEFT JOIN instance_pairs ip ON ip.week_offset = w.week_offset
        ),
        valid_windows AS (
            SELECT week_offset, dbid, instance_number,
                   win_start_ts, win_end_ts,
                   begin_snap_id, end_snap_id,
                   (CAST(win_end_ts AS DATE) - CAST(win_start_ts AS DATE)) * 86400 AS dur_sec
            FROM   windows
            WHERE  valid_flag = 'Y'
        ),
        windows_rollup AS (
            SELECT week_offset,
                   MAX(win_start_ts) AS win_start_ts,
                   MAX(win_end_ts)   AS win_end_ts,
                   MIN(begin_snap_id) AS begin_snap_id,
                   MAX(end_snap_id)   AS end_snap_id,
                   CASE WHEN SUM(CASE WHEN valid_flag = 'Y' THEN 1 ELSE 0 END) > 0
                        THEN 'Y' ELSE 'N' END AS valid_flag,
                   MIN(skip_reason) KEEP (DENSE_RANK FIRST
                       ORDER BY CASE WHEN skip_reason IS NULL THEN 1 ELSE 0 END,
                                skip_reason) AS skip_reason
            FROM   windows
            GROUP BY week_offset
        )
