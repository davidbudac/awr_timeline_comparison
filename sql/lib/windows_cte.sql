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
--   dbid_list ~inst_num ~target_end_resolved
--   ~win_hours ~weeks_back ~top_n ~step_hours
-- (dbid_list is the comma set of all visible DBIDs; snaps are resolved by
--  time across it so a window straddling a DBID change is detected.  Each
--  resolved snap/window carries its own dbid -- begin_snap/end_snap expose
--  dbid + end_ts, and windows / valid_windows / windows_rollup expose a
--  per-window dbid.  With one DBID this is byte-identical to pinning dbid.)
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
        -- Candidate snaps are resolved BY TIME across every visible DBID
        -- (dbid IN (dbid_list)), NOT pinned to a single dbid.  We carry the
        -- snapshot's own s.dbid forward so each window's begin/end snap -- and
        -- thus the window itself -- is tagged with the DBID that actually owns
        -- it.  A window fully before a non-CDB->PDB migration resolves to the
        -- old DBID, one fully after to the new DBID, and a window straddling
        -- the boundary is caught and invalidated below (begin_dbid<>end_dbid).
        -- With a single DBID, dbid IN (dbid_list) == dbid = dbid and s.dbid
        -- is constant, so this is byte-identical to the pinned-DBID resolution.
        snaps AS (
            SELECT w.week_offset, w.win_start_dt, w.win_end_dt,
                   s.dbid,
                   s.instance_number,
                   s.snap_id, s.end_interval_time, s.startup_time
            FROM   raw_windows w
            JOIN   dba_hist_snapshot s
              ON   s.dbid IN (~dbid_list)
             AND   (w.instance_number IS NULL OR s.instance_number = w.instance_number)
             AND   s.end_interval_time BETWEEN
                        CAST(w.win_start_dt - 1 AS TIMESTAMP)
                    AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
        ),
        -- begin_snap / end_snap also carry the resolved snap's DBID and its
        -- end_interval_time (end_ts).  dbid lets us detect a window that
        -- straddles a DBID change; end_ts lets the time-axis sections (00, 10)
        -- bound their scans by the actual snap times across DBIDs instead of a
        -- single contiguous snap_id range (snap_ids reset per DBID).
        begin_snap AS (
            SELECT week_offset, instance_number,
                   MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS snap_id,
                   MAX(dbid)    KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS dbid,
                   MAX(end_interval_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS end_ts,
                   MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
            GROUP BY week_offset, instance_number
        ),
        end_snap AS (
            SELECT week_offset, instance_number,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   MIN(dbid)    KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS dbid,
                   MIN(end_interval_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS end_ts,
                   MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
            GROUP BY week_offset, instance_number
        ),
        instance_pairs AS (
            SELECT NVL(bs.week_offset,     es.week_offset)     AS week_offset,
                   NVL(bs.instance_number, es.instance_number) AS instance_number,
                   bs.snap_id      AS begin_snap_id,
                   bs.dbid         AS begin_dbid,
                   bs.startup_time AS begin_startup_time,
                   es.snap_id      AS end_snap_id,
                   es.dbid         AS end_dbid,
                   es.startup_time AS end_startup_time
            FROM   begin_snap bs
            FULL OUTER JOIN end_snap es
              ON  es.week_offset     = bs.week_offset
             AND  es.instance_number = bs.instance_number
        ),
        windows AS (
            SELECT
                w.week_offset,
                -- DBID is now per-window, taken from the window's own resolved
                -- snaps (begin preferred, else end), NOT a single global dbid.
                NVL(ip.begin_dbid, ip.end_dbid) AS dbid,
                ip.instance_number,
                CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
                CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts,
                ip.begin_snap_id,
                ip.end_snap_id,
                CASE
                    WHEN ip.begin_snap_id IS NULL                      THEN 'N'
                    WHEN ip.end_snap_id   IS NULL                      THEN 'N'
                    WHEN ip.begin_snap_id = ip.end_snap_id             THEN 'N'
                    -- begin and end snaps under different DBIDs => the window
                    -- straddles a DBID change (e.g. the non-CDB->PDB migration
                    -- itself).  A delta across that boundary is meaningless, so
                    -- the window is dropped (the adjacent fully-old and
                    -- fully-new windows still report).
                    WHEN ip.begin_dbid <> ip.end_dbid                  THEN 'N'
                    WHEN ip.begin_startup_time <> ip.end_startup_time  THEN 'N'
                    ELSE 'Y'
                END AS valid_flag,
                CASE
                    WHEN ip.begin_snap_id IS NULL THEN 'no snapshot at/before window start'
                    WHEN ip.end_snap_id   IS NULL THEN 'no snapshot at/after window end'
                    WHEN ip.begin_snap_id = ip.end_snap_id THEN 'begin and end snapshot identical (window shorter than AWR interval)'
                    WHEN ip.begin_dbid <> ip.end_dbid THEN 'DBID changed inside window (non-CDB->PDB migration or DB rename)'
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
                   -- one DBID per offset: every valid instance in a window
                   -- shares the same DBID, so MAX collapses them.  Consumers
                   -- that resolve rows by end_snap_id (e.g. section 12) join on
                   -- this so the snap_id is qualified by its owning DBID.
                   MAX(dbid)          AS dbid,
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
