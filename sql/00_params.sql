--
-- 00_params.sql
-- Emits the report <header> (editorial masthead) and <nav> TOC,
-- using substitution variables already resolved by the driver.
-- No DML, no tables.
--
-- Also recomputes z-scores in-flight to produce the one-line
-- "verdict" punchline at the top of the masthead. The recompute
-- mirrors the LOAD / METRIC / WAIT shape from sql/07_summary.sql:
-- per the "Findings are recomputed, not shared" convention in
-- CLAUDE.md, every consumer of findings owns its own recompute.
-- The verdict needs to be visible before section 07 runs, so we
-- duplicate the relevant query here (narrower projection -- just
-- z_score, pct_delta and n_prior per metric).
--
-- Expects these substitution variables from awr_trend.sql:
--   ~run_id               17-digit timestamp run identifier
--   dbid                 current container DBID via SYS_CONTEXT CON_DBID (int)
--   ~db_name              v$database.name (trimmed; + " / <CON_NAME>" in a PDB)
--   ~host_name            v$instance.host_name
--   ~db_version           v$instance.version
--   ~caller_user          USER
--   ~generated_at_s       'YYYY-MM-DD HH24:MI:SS TZR'
--   ~target_end_resolved  'YYYY-MM-DD HH24:MI:SS'
--   ~dow_name             trimmed day-of-week name of target_end
--   ~step_hours           cadence between adjacent windows, in hours
--   ~period_unit_long     'hour' | 'day' | 'week'
--   ~period_step_label    e.g. 'w', '2d', '6h'
--   ~win_label            compact width of one window (e.g. '15m', '1h')
--   ~step_label           compact cadence between windows (e.g. '15m', '1w')
--   ~report_path          output filename (relative)
--   ~template_name        active template name ('comprehensive', 'simple')
--   ~template_dir         path under sql/lib/templates/ for the active template
--
-- Run parameters (from defaults.sql or caller):
--   ~target_end, ~win_hours, ~weeks_back, ~top_n, ~inst_num,
--   ~step, ~step_unit, ~template
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Section boundary marker (HTML comment, invisible in browser).  Lets a
-- failed run be localized: grep the spool for the last "BEGIN" marker
-- without a matching "END" -- that section is the one that aborted.
BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 00_params BEGIN -->'); END;
/

DECLARE
    TYPE mover_rec IS RECORD (
        metric_domain VARCHAR2(16),
        metric_name   VARCHAR2(120),
        z_score       NUMBER,
        pct_delta     NUMBER,
        n_prior       NUMBER,
        change_bucket VARCHAR2(40),
        cur_val       NUMBER,
        prior_mean    NUMBER,
        family        VARCHAR2(64),
        canonical     VARCHAR2(1),
        prior_sd      NUMBER,
        share         NUMBER
    );
    TYPE mover_t IS TABLE OF mover_rec INDEX BY PLS_INTEGER;
    TYPE seen_t  IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);

    v_scored     mover_t;
    v_top        mover_t;
    v_seen       seen_t;        -- families already represented in v_top
    v_fams       seen_t;        -- families with a canonical large / moderate row
    v_n_movers   PLS_INTEGER := 0;   -- = v_fams.COUNT: one finding per family
    v_n_moved    PLS_INTEGER := 0;   -- every flagged row, twins included
    v_n_impr     PLS_INTEGER := 0;   -- canonical improved
    v_n_usable   PLS_INTEGER := 0;
    v_max_n      NUMBER      := 0;
    @@sql/lib/metric_policy.plsql
    v_pol        policy_rec;   -- declared after the include (policy_rec lives there)

    v_clean_name VARCHAR2(160);
    v_pct_cls    VARCHAR2(8);
    -- Wide enough for the F5 direction-glyph markup wrapped around the
    -- percentage (a bare signed number used to fit in 24 bytes).
    v_pct_txt    VARCHAR2(200);
    v_z_txt      VARCHAR2(24);

    -- Masthead DB-time timeline strip: per-snap total DB time over the
    -- full compared span, with markArea bands for the windows. Same
    -- LAG-delta pattern as sql/10_db_time_summary.sql, flattened to a
    -- single total line (no wait_class stacking) for an at-a-glance
    -- overview right under the headline.
    -- TIME-bounded span (not a single snap_id range): snap_ids reset per
    -- DBID, so after a non-CDB->PDB migration one snap_id range can't cover
    -- both eras.  v_range_start/v_range_end are the actual snap times of the
    -- earliest begin and latest end across valid windows; scans filter
    -- end_interval_time BETWEEN them with dbid IN (dbid_list).  Single-DBID:
    -- selects exactly the old snap_id range, so output is unchanged.
    v_range_start  TIMESTAMP;
    v_range_end    TIMESTAMP;
    v_buckets      PLS_INTEGER := 0;
    -- v_times_json / v_vals_json are CLOBs so a long, dense compared
    -- span (e.g. weeks_back=4 with 15-min AWR snaps -> 2700+ buckets)
    -- cannot overflow the 32767-byte PL/SQL VARCHAR2 limit and abort
    -- the masthead with ORA-06502.  v_windows_json stays VARCHAR2 --
    -- it has one entry per compared window (bounded by weeks_back+1).
    v_times_json   CLOB;
    v_vals_json    CLOB;
    v_windows_json VARCHAR2(4000);
    v_buf          VARCHAR2(64);
    TYPE t_idx_tab IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
    v_snap_idx     t_idx_tab;
    TYPE t_num_arr IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_vals         t_num_arr;
    @@sql/lib/put_clob_chunked.plsql
BEGIN
    DBMS_LOB.CREATETEMPORARY(v_times_json, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_vals_json,  TRUE);
    DBMS_LOB.WRITEAPPEND(v_times_json, 1, '[');
    DBMS_LOB.WRITEAPPEND(v_vals_json,  1, '[');
    --
    -- Recompute LOAD / METRIC / WAIT z-scores. Same query shape as
    -- sql/07_summary.sql, just a narrower projection (we only need
    -- z_score, pct_delta, n_prior). Ordered by |z| DESC so the first
    -- usable rows are the top movers; we walk in PL/SQL to count
    -- movers above |z| > 2 and slice the first 3.
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    load_pairs AS (
        SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
               ss.snap_id, ss.value,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_sysstat ss
            ON ss.dbid = w.dbid
           AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND ss.instance_number = w.instance_number
           AND ss.stat_name IN (SELECT stat_name FROM load_targets)
    ),
    load_bounds AS (
        SELECT week_offset, dur_sec, stat_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   load_pairs
        GROUP BY week_offset, dur_sec, stat_name, instance_number
    ),
    load_rows AS (
        -- Cross-instance delta over ONE window span (MAX(dur_sec)); dur_sec out
        -- of the GROUP BY so per-instance resolved-span jitter can't split a RAC
        -- week.  Single-instance byte-identical (dur_sec constant).  Mirrors 07.
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, stat_name
    ),
    metric_targets AS (
        @@~template_dir/sysmetric_targets.sql
    ),
    metric_per_snap AS (
        SELECT w.week_offset, t.metric_name, sm.snap_id,
               t.is_additive,
               CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                             ELSE AVG(sm.average) END AS snap_value
        FROM   valid_windows w
        JOIN   metric_targets t ON 1 = 1
        JOIN   dba_hist_sysmetric_summary sm
            ON sm.dbid = w.dbid
           AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
           AND sm.instance_number = w.instance_number
           AND sm.metric_name = t.metric_name
        GROUP BY w.week_offset, t.metric_name, t.is_additive, sm.snap_id
    ),
    metric_rows AS (
        SELECT 'METRIC' AS metric_domain,
               metric_name,
               week_offset,
               AVG(snap_value) AS metric_value
        FROM   metric_per_snap
        GROUP BY week_offset, metric_name
    ),
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.snap_id,
               se.time_waited_micro,
               se.instance_number,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, instance_number
    ),
    wait_rows AS (
        -- Same single-span divisor as load_rows; MAX(dur_sec), dur_sec dropped
        -- from the GROUP BY.
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    ),
    pivoted AS (
        SELECT metric_domain, metric_name,
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)    AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END)  AS n
        FROM   unified
        GROUP BY metric_domain, metric_name
    ),
    -- Same sigma floor + materiality rule as sql/07_summary.sql (kept in
    -- sync by inspection): z over max(sd, 2% of |mu|); large / moderate
    -- only when |pct| >= 10 and, for wait classes, share of the Current
    -- window's total wait >= 2%.
    wait_total AS (
        SELECT SUM(metric_value) AS tot
        FROM   wait_rows
        WHERE  week_offset = 0
    ),
    measured AS (
        SELECT p.metric_domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.sd IS NULL THEN NULL
                   WHEN p.n < 3 THEN NULL
                   WHEN GREATEST(p.sd, 0.02 * ABS(p.mu)) = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / GREATEST(p.sd, 0.02 * ABS(p.mu))
               END AS z_score,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.mu = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / ABS(p.mu) * 100
               END AS pct_delta,
               CASE
                   WHEN p.metric_domain = 'WAIT' AND t.tot > 0 THEN p.cur_val / t.tot
               END AS share
        FROM   pivoted p
        CROSS JOIN wait_total t
    ),
    scored AS (
        -- the bucket is assigned by policy_bucket() in the PL/SQL pass
        -- below (per-metric direction and floors, sql/lib/metric_policy.plsql)
        SELECT metric_domain, metric_name, z_score, pct_delta,
               n AS n_prior,
               CAST(NULL AS VARCHAR2(40)) AS change_bucket,
               cur_val, mu AS prior_mean, sd AS prior_sd, share
        FROM   measured
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    )
    SELECT metric_domain, metric_name, z_score, pct_delta, n_prior,
           change_bucket, cur_val, prior_mean,
           CAST(NULL AS VARCHAR2(64)) AS family,
           CAST(NULL AS VARCHAR2(1))  AS canonical,
           prior_sd, share
    BULK COLLECT INTO v_scored
    FROM   scored
    ORDER  BY ABS(NVL(z_score, 0)) DESC, metric_name;

    -- Single pass: per-metric policy (family / canonical) and the change
    -- bucket per row, count the canonical large + moderate findings (the
    -- verdict number) and every large / moderate row (the "metrics moved"
    -- number; improved / noted rows are counted apart and never
    -- highlighted), remember max n_prior, and slice the first 3
    -- distinct-family canonical findings into v_top in the same |z| DESC
    -- order produced by the SQL.
    FOR i IN 1 .. v_scored.COUNT LOOP
        v_pol := metric_policy(v_scored(i).metric_domain, v_scored(i).metric_name);
        v_scored(i).family    := finding_family(v_scored(i).metric_domain, v_scored(i).metric_name);
        v_scored(i).canonical := v_pol.canonical;
        v_scored(i).change_bucket :=
            policy_bucket(v_scored(i).metric_domain, v_scored(i).metric_name, NULL,
                          v_scored(i).cur_val, v_scored(i).prior_mean,
                          v_scored(i).prior_sd, v_scored(i).n_prior, v_scored(i).share);
        IF NVL(v_scored(i).n_prior, 0) > v_max_n THEN
            v_max_n := v_scored(i).n_prior;
        END IF;
        IF v_scored(i).z_score IS NOT NULL THEN
            v_n_usable := v_n_usable + 1;
            IF v_scored(i).change_bucket = 'improved' AND v_scored(i).canonical = 'Y' THEN
                v_n_impr := v_n_impr + 1;
            ELSIF v_scored(i).change_bucket IN ('large', 'moderate') THEN
                v_n_moved := v_n_moved + 1;
                IF v_scored(i).canonical = 'Y' THEN
                    v_fams(v_scored(i).family) := i;
                    v_n_movers := v_fams.COUNT;
                    IF v_top.COUNT < 3 AND NOT v_seen.EXISTS(v_scored(i).family) THEN
                        v_top(v_top.COUNT + 1) := v_scored(i);
                        v_seen(v_scored(i).family) := i;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    -- =========================================================
    -- Masthead DB-time timeline strip recompute.
    --
    -- 1. Resolve the snap range covered by all valid compared windows
    --    (earliest begin -> latest end).
    -- 2. Build the markArea bands JSON (one band per resolved window).
    -- 3. Walk distinct same-startup_time snap pairs in chronological
    --    order to build v_times_json (x-axis) and a snap_id -> bucket
    --    index map.
    -- 4. Pull per-snap total DB time (CPU + non-Idle wait LAG deltas)
    --    and project into the bucket array.
    -- 5. Materialize v_vals_json (one number per bucket, zero if no
    --    DB time was recorded for that snap).
    --
    -- This is a third recompute (alongside sections 07 and 08) of the
    -- AWR delta math, per the "Findings are recomputed, not shared"
    -- convention in CLAUDE.md. The shape mirrors sql/10_db_time_summary
    -- .sql; just the cat dimension is collapsed.
    -- =========================================================
    SELECT MIN(begin_ts), MAX(end_ts)
    INTO   v_range_start, v_range_end
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT bs.end_ts AS begin_ts,
               es.end_ts AS end_ts
        FROM   raw_windows w
        JOIN   begin_snap bs ON bs.week_offset = w.week_offset
        JOIN   end_snap   es ON es.week_offset = w.week_offset
        WHERE  bs.snap_id IS NOT NULL
          AND  es.snap_id IS NOT NULL
          AND  bs.snap_id <> es.snap_id
          AND  bs.dbid = es.dbid
          AND  bs.startup_time = es.startup_time
    );

    -- Compared windows for the markArea bands (one per valid window).
    -- xAxis strings match the YYYY-MM-DD HH24:MI category labels used
    -- by the chart so ECharts can locate them by string equality.
    SELECT '['
           || LISTAGG(
                  '["'
                  || TO_CHAR(win_start_ts, 'YYYY-MM-DD HH24:MI') || '","'
                  || TO_CHAR(win_end_ts,   'YYYY-MM-DD HH24:MI') || '","'
                  || CASE WHEN week_offset = 0 THEN 'current'
                          ELSE 'w-' || week_offset END || '"]',
                  ',')
                  WITHIN GROUP (ORDER BY week_offset DESC)
           || ']'
    INTO   v_windows_json
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT w.week_offset,
               CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
               CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts
        FROM   raw_windows w
        JOIN   begin_snap bs ON bs.week_offset = w.week_offset
        JOIN   end_snap   es ON es.week_offset = w.week_offset
        WHERE  bs.snap_id IS NOT NULL
          AND  es.snap_id IS NOT NULL
          AND  bs.snap_id <> es.snap_id
          AND  bs.startup_time = es.startup_time
    );

    IF v_range_start IS NOT NULL AND v_range_end IS NOT NULL THEN
        -- Pass 1: chronological x-axis across all visible DBIDs. snap_id is
        -- identical across instances at the same point in time, so grouping
        -- collapses RAC duplicates; (dbid, snap_id) keeps the two eras of a
        -- migrated DB distinct.
        FOR s IN (
            WITH ordered AS (
                SELECT s.dbid, s.snap_id, s.instance_number, s.end_interval_time,
                       s.startup_time,
                       LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                                 ORDER BY s.snap_id) AS prev_startup
                FROM   dba_hist_snapshot s
                WHERE  s.dbid IN (~dbid_list)
                  AND  s.end_interval_time BETWEEN v_range_start AND v_range_end
                  AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
            )
            SELECT dbid, snap_id,
                   MIN(end_interval_time) AS end_ts
            FROM   ordered
            WHERE  prev_startup IS NOT NULL
              AND  startup_time = prev_startup
            GROUP BY dbid, snap_id
            ORDER BY MIN(end_interval_time)
        ) LOOP
            v_buckets := v_buckets + 1;
            v_snap_idx(s.dbid || '|' || s.snap_id) := v_buckets;
            v_vals(v_buckets) := 0;
            -- CLOB v_times_json was pre-seeded with '[' so every entry
            -- after the first is comma-separated.  WRITEAPPEND amount
            -- arg is in chars; LENGTH() of the buffer is correct
            -- regardless of NLS_CHARACTERSET (the strings are ASCII).
            IF v_buckets = 1 THEN
                v_buf := '"' || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
            ELSE
                v_buf := ',"' || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
            END IF;
            DBMS_LOB.WRITEAPPEND(v_times_json, LENGTH(v_buf), v_buf);
        END LOOP;

        -- Pass 2: per-snap total DB time = CPU + non-Idle wait LAG deltas
        -- across all valid (snap_id, instance_number) pair_keys.
        FOR r IN (
            WITH ordered_snaps AS (
                SELECT s.dbid, s.snap_id, s.instance_number, s.startup_time,
                       LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                                 ORDER BY s.snap_id) AS prev_startup
                FROM   dba_hist_snapshot s
                WHERE  s.dbid IN (~dbid_list)
                  AND  s.end_interval_time BETWEEN v_range_start AND v_range_end
                  AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
            ),
            pair_keys AS (
                SELECT dbid, snap_id, instance_number
                FROM   ordered_snaps
                WHERE  prev_startup IS NOT NULL
                  AND  startup_time = prev_startup
            ),
            cpu_d AS (
                -- joined to dba_hist_snapshot so the span is bounded by TIME
                -- (sys_time_model has no end_interval_time) and the LAG delta
                -- is partitioned per DBID so it never crosses a migration.
                SELECT stm.dbid, stm.snap_id, stm.instance_number,
                       GREATEST(stm.value
                           - LAG(stm.value) OVER (PARTITION BY stm.dbid, stm.instance_number
                                                  ORDER BY stm.snap_id), 0) AS micro
                FROM   dba_hist_sys_time_model stm
                JOIN   dba_hist_snapshot s2
                  ON   s2.dbid = stm.dbid
                 AND   s2.snap_id = stm.snap_id
                 AND   s2.instance_number = stm.instance_number
                WHERE  stm.dbid IN (~dbid_list)
                  AND  stm.stat_name = 'DB CPU'
                  AND  s2.end_interval_time BETWEEN v_range_start AND v_range_end
                  AND  (~inst_num = 0 OR stm.instance_number = ~inst_num)
            ),
            wait_d AS (
                SELECT se.dbid, se.snap_id, se.instance_number,
                       GREATEST(se.time_waited_micro
                           - LAG(se.time_waited_micro) OVER (
                               PARTITION BY se.dbid, se.instance_number, se.event_id
                               ORDER BY se.snap_id), 0) AS micro
                FROM   dba_hist_system_event se
                JOIN   dba_hist_snapshot s3
                  ON   s3.dbid = se.dbid
                 AND   s3.snap_id = se.snap_id
                 AND   s3.instance_number = se.instance_number
                WHERE  se.dbid IN (~dbid_list)
                  AND  NVL(se.wait_class, 'x') <> 'Idle'
                  AND  s3.end_interval_time BETWEEN v_range_start AND v_range_end
                  AND  (~inst_num = 0 OR se.instance_number = ~inst_num)
            ),
            all_d AS (
                SELECT dbid, snap_id, instance_number, micro FROM cpu_d
                UNION ALL
                SELECT dbid, snap_id, instance_number, micro FROM wait_d
            )
            SELECT a.dbid, a.snap_id, SUM(a.micro)/1e6 AS sec
            FROM   all_d a
            JOIN   pair_keys pk
              ON   pk.dbid = a.dbid
             AND   pk.snap_id = a.snap_id
             AND   pk.instance_number = a.instance_number
            GROUP BY a.dbid, a.snap_id
            HAVING SUM(a.micro) > 0
        ) LOOP
            IF v_snap_idx.EXISTS(r.dbid || '|' || r.snap_id) THEN
                v_vals(v_snap_idx(r.dbid || '|' || r.snap_id)) := r.sec;
            END IF;
        END LOOP;

        -- Materialize v_vals_json walking buckets 1..N (zero-fills the
        -- snaps that had no DB time so the line is continuous).  CLOB
        -- v_vals_json was pre-seeded with '['.
        FOR b IN 1 .. v_buckets LOOP
            IF b = 1 THEN
                v_buf := TO_CHAR(v_vals(b), 'FM99999990D000',
                                 'NLS_NUMERIC_CHARACTERS=''.,''');
            ELSE
                v_buf := ',' || TO_CHAR(v_vals(b), 'FM99999990D000',
                                        'NLS_NUMERIC_CHARACTERS=''.,''');
            END IF;
            DBMS_LOB.WRITEAPPEND(v_vals_json, LENGTH(v_buf), v_buf);
        END LOOP;
    END IF;

    -- Close the CLOB arrays now that all appends are done.
    DBMS_LOB.WRITEAPPEND(v_times_json, 1, ']');
    DBMS_LOB.WRITEAPPEND(v_vals_json,  1, ']');
    v_windows_json := NVL(v_windows_json, '[]');

    -- =========================================================
    -- Editorial masthead (header.report)
    -- =========================================================
    -- Early theme script: must run before the masthead chart IIFE below
    -- (which reads --accent/--muted via getComputedStyle) so charts pick
    -- up the correct palette at first paint. Applies the saved/preferred
    -- theme by toggling body.dark before any chart initializes.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>');
    -- Normal / Full view: body.normal is the default, body.full
    -- the full report.  Decided before first paint from localStorage
    -- "awr-mode" (a shared link's hash "!v=f" wins), so the short view
    -- never flashes the long one.  With JS off neither class exists and
    -- the CSS shows everything.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var m="normal";try{if(localStorage.getItem("awr-mode")==="full")m="full";}catch(e){}var h=location.hash||"",i=h.indexOf("!v=");if(i>=0&&h.slice(i+3).split("&")[0].split(",").indexOf("f")>=0)m="full";document.body.classList.add(m);})();</script>');
    -- Phase 4: skip link (visible on keyboard focus only) to the <main>
    -- landmark that opens right after this section's scripts and closes
    -- in the driver's epilogue, just before the footer.
    DBMS_OUTPUT.PUT_LINE('<a class="skip" href="#main-start">Skip to report</a>');
    -- The masthead is part of both views (the Normal view hide rule only
    -- targets main > section).
    DBMS_OUTPUT.PUT_LINE('<header class="report">');

    -- Brand line above the headline.
    DBMS_OUTPUT.PUT_LINE('  <div class="brandline">'
        || '<span class="dot">&#9679;</span> AWR '
        || '<span class="slash">/</span> TIMELINE COMPARISON'
        || '</div>');

    -- Top grid: big headline left, run metadata stacked on the right.
    DBMS_OUTPUT.PUT_LINE('  <div class="topgrid">');
    DBMS_OUTPUT.PUT_LINE('    <h1>'
        || DBMS_XMLGEN.CONVERT('~dow_name')
        || ' <em>' || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 12, 5)) || '</em>'
        || '<br>'
        || INITCAP('~period_unit_long') || '-over-' || '~period_unit_long' || ' trend'
        || ' <span class="badge info">run ' || '~run_id' || '</span>'
        || '</h1>');
    DBMS_OUTPUT.PUT_LINE('    <div class="meta">');
    -- Primary DBID label is emitted EXACTLY as before (the dbid NEW_VALUE,
    -- including its NUMBER-column padding) so single-DBID output stays
    -- byte-identical.  Only when the report actually spans more than one DBID
    -- (non-CDB->PDB migration: INSTR finds a comma in dbid_list) do we append
    -- the full set, making the crossed eras explicit without disturbing the
    -- common case.
    DBMS_OUTPUT.PUT_LINE('      <div><b>' || DBMS_XMLGEN.CONVERT('~db_name')
        || '</b> &middot; DBID ' || '~dbid'
        || CASE WHEN INSTR('~dbid_list', ',') > 0
                THEN ' &middot; all DBIDs ' || REPLACE('~dbid_list', ',', ', ')
                ELSE '' END
        || '</div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Host <b>' || DBMS_XMLGEN.CONVERT('~host_name')
        || '</b> &middot; ' || DBMS_XMLGEN.CONVERT('~db_version') || '</div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Generated <b>' || '~generated_at_s' || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Run by ' || DBMS_XMLGEN.CONVERT('~caller_user')
        || ' &middot; read-only, no scratch schema</div>');
    -- Only when the requested target_end had no snapshot within the 15-min
    -- edge guard does the resolving SELECT (in awr_trend.sql) snap it back
    -- to the last actual snapshot -- flag that adjustment here so it is
    -- never silent. When the two match (the common case, and every run
    -- that already worked before this feature), nothing is emitted and
    -- output stays byte-identical to before.
    IF '~target_end_requested' <> '~target_end_resolved' THEN
        DBMS_OUTPUT.PUT_LINE('      <div>Requested end '
            || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_requested', 1, 16))
            || ' had no snapshot within 15 min &mdash; snapped to last snapshot '
            || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 1, 16))
            || '</div>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('    </div>');
    DBMS_OUTPUT.PUT_LINE('  </div>');

    -- =========================================================
    -- One-line verdict: top movers above |z| > 2, or a quiet /
    -- short-baseline fallback. Recomputed above. Anchors to #findings
    -- so the reader can jump to the full detail in one click.
    -- =========================================================
    IF v_n_usable = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  <div class="verdict v-skip">');
        DBMS_OUTPUT.PUT_LINE('    <span class="label">Verdict</span>');
        DBMS_OUTPUT.PUT_LINE('    <span class="lede skip">Baseline too short</span>'
            || ' <span class="sep">/</span> '
            || '<span class="body">need at least 3 prior valid windows to score; '
            || 'only %-delta available in <a href="#findings">findings</a>.</span>');
    ELSIF v_n_movers = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  <div class="verdict v-ok">');
        DBMS_OUTPUT.PUT_LINE('    <span class="label">Verdict</span>');
        DBMS_OUTPUT.PUT_LINE('    <span class="lede ok">Quiet</span>'
            || ' <span class="sep">/</span> '
            || '<span class="body">no material regression vs the prior '
            || TO_CHAR(v_max_n) || ' window'
            || CASE WHEN v_max_n = 1 THEN '' ELSE 's' END
            || CASE WHEN v_n_impr > 0
                    THEN '; ' || v_n_impr || ' metric'
                         || CASE WHEN v_n_impr = 1 THEN '' ELSE 's' END
                         || ' <a href="#findings">improved</a>'
                    ELSE '' END
            || '.</span>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  <div class="verdict v-crit">');
        DBMS_OUTPUT.PUT_LINE('    <span class="label">Verdict</span>');
        DBMS_OUTPUT.PUT_LINE('    <a href="#findings" class="lede crit">'
            || v_n_movers || ' finding'
            || CASE WHEN v_n_movers = 1 THEN '' ELSE 's' END
            || '</a>'
            || ' <span class="sep">/</span> '
            || '<span class="body">' || v_n_moved || ' metric'
            || CASE WHEN v_n_moved = 1 THEN '' ELSE 's' END
            || ' moved vs prior ' || TO_CHAR(v_max_n) || ' window'
            || CASE WHEN v_max_n = 1 THEN '' ELSE 's' END
            || CASE WHEN v_n_impr > 0
                    THEN ' &middot; ' || v_n_impr || ' improved' ELSE '' END
            || '</span>');

        FOR i IN 1 .. v_top.COUNT LOOP
            v_clean_name := REGEXP_REPLACE(v_top(i).metric_name, '^Wait class: ', '');
            IF LENGTH(v_clean_name) > 36 THEN
                v_clean_name := SUBSTR(v_clean_name, 1, 34) || '&hellip;';
            END IF;

            -- F5: direction is a glyph, not a color.  The up/down class is
            -- kept (it is a stable hook) but both now render in --ink; only
            -- the leading triangle inside span.g carries a severity color,
            -- and only within the verdict block.
            IF v_top(i).pct_delta IS NULL THEN
                v_pct_cls := 'up';
                v_pct_txt := '&mdash;';
            ELSE
                v_pct_cls := CASE WHEN v_top(i).pct_delta >= 0 THEN 'up' ELSE 'down' END;
                v_pct_txt := '<span class="g">'
                             || CASE WHEN v_top(i).pct_delta >= 0
                                     THEN '&#9650;' ELSE '&#9660;' END
                             || '</span> '
                             || TO_CHAR(ABS(v_top(i).pct_delta),
                                        'FM999990',
                                        'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
            END IF;

            DBMS_OUTPUT.PUT_LINE('    <span class="mover">'
                || '<span class="name">' || DBMS_XMLGEN.CONVERT(v_clean_name) || '</span>'
                || ' <span class="pct ' || v_pct_cls || '">' || v_pct_txt || '</span>'
                || '</span>');
        END LOOP;
    END IF;
    DBMS_OUTPUT.PUT_LINE('  </div>');

    -- =========================================================
    -- Compact "all movers" list. The verdict above names only the
    -- top 3; this collapsible strip enumerates every metric beyond
    -- |z| > 2 in the same |z| DESC order produced by the recompute,
    -- in a smaller font, so the full set is one click away without
    -- leaving the masthead. Only emitted when there is a mover.
    -- =========================================================
    IF v_n_moved > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  <details class="movers-all">');
        DBMS_OUTPUT.PUT_LINE('    <summary>All ' || v_n_moved || ' moved metric'
            || CASE WHEN v_n_moved = 1 THEN '' ELSE 's' END
            || ' &middot; material, in the bad direction; twins muted'
            || CASE WHEN v_n_impr > 0
                    THEN '; ' || v_n_impr || ' improved not listed' ELSE '' END
            || '</summary>');
        DBMS_OUTPUT.PUT_LINE('    <ul class="movers-list">');
        FOR i IN 1 .. v_scored.COUNT LOOP
            IF v_scored(i).change_bucket IN ('large', 'moderate') THEN
                v_clean_name := REGEXP_REPLACE(v_scored(i).metric_name,
                                               '^Wait class: ', '');
                IF LENGTH(v_clean_name) > 48 THEN
                    v_clean_name := DBMS_XMLGEN.CONVERT(SUBSTR(v_clean_name, 1, 46))
                                    || '&hellip;';
                ELSE
                    v_clean_name := DBMS_XMLGEN.CONVERT(v_clean_name);
                END IF;

                v_z_txt := TO_CHAR(v_scored(i).z_score, 'FMS9990D0',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');

                -- Same F5 glyph treatment as the verdict movers above.
                IF v_scored(i).pct_delta IS NULL THEN
                    v_pct_cls := 'up';
                    v_pct_txt := '&mdash;';
                ELSE
                    v_pct_cls := CASE WHEN v_scored(i).pct_delta >= 0
                                      THEN 'up' ELSE 'down' END;
                    v_pct_txt := '<span class="g">'
                                 || CASE WHEN v_scored(i).pct_delta >= 0
                                         THEN '&#9650;' ELSE '&#9660;' END
                                 || '</span> '
                                 || TO_CHAR(ABS(v_scored(i).pct_delta), 'FM999990',
                                            'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
                END IF;

                DBMS_OUTPUT.PUT_LINE('      <li'
                    || CASE WHEN v_scored(i).canonical = 'N' THEN ' class="twin"'
                            ELSE '' END
                    || '>'
                    || '<span class="m-dom">' || v_scored(i).metric_domain || '</span>'
                    || '<span class="m-name">' || v_clean_name || '</span>'
                    || '<span class="m-z">z ' || v_z_txt || '</span>'
                    || '<span class="m-pct ' || v_pct_cls || '">' || v_pct_txt
                    || '</span>'
                    || '</li>');
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('    </ul>');
        DBMS_OUTPUT.PUT_LINE('  </details>');
    END IF;

    -- =========================================================
    -- Narrative slot (section 17).  Deliberately EMPTY here: section 17
    -- runs last (it needs its own file / segment / SQL / parameter
    -- queries and must not depend on any other section's PL/SQL state),
    -- emits its block at the end of the document and a one-line inline
    -- script moves the node in here.  Always emitted, even when the
    -- narrative turns out to have nothing to say -- an empty div has no
    -- box (no padding/border/margin of its own), so a silent run looks
    -- exactly as it did before.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('  <div id="narrative-slot"></div>');

    --
    -- Compared windows strip: a single very-narrow line chart of total
    -- DB time over the full compared span, with markArea bands marking
    -- each compared window (current = red tint, prior = neutral). Text
    -- fallback for body.no-charts mirrors the old <ul> list.
    --
    DBMS_OUTPUT.PUT_LINE('  <div class="windows-strip">');
    DBMS_OUTPUT.PUT_LINE('    <div class="strip-head">'
        || '<b>Compared windows</b>'
        || ' <span class="strip-meta">'
        || DBMS_XMLGEN.CONVERT('~dow_name')
        || ' &middot; ~win_label each &middot; every ~step_label'
        || ' &middot; DB time (s) over full span'
        || CASE WHEN '~template_name' = 'comprehensive' THEN ''
                ELSE ' &middot; template: <code>~template_name</code>'
           END
        || CASE WHEN ~profile_days > 0
                THEN ' &middot; day profile: ' || '~profile_days' || ' prior days'
                ELSE '' END
        || '</span>'
        || '</div>');
    -- X2: clickable window chips above the strip chart.  One chip per
    -- compared window, carrying data-w=<offset> -- the same attribute the
    -- per-window table columns use -- so a click lights that window up
    -- everywhere at once and broadcasts awr:window for the chart sections.
    -- Built from the same CONNECT BY grid as the offline fallback list
    -- below, so chips and fallback can never disagree.
    -- v1.5.0: the chip list sits behind a one-line summary (<details>):
    -- the current window's range, the oldest window's date, the count.
    -- Chips (and their highlight behaviour) are one click away.
    DBMS_OUTPUT.PUT_LINE('    <details class="windows-more">');
    DBMS_OUTPUT.PUT_LINE('      <summary>'
        || '<span class="wchip cur" data-w="0" title="click to highlight the Current window everywhere">'
        || '<b>current</b> <span>'
        || TO_CHAR(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') - ~win_hours/24,
                   'Dy DD Mon HH24:MI')
        || ' &rarr; '
        || TO_CHAR(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS'), 'HH24:MI')
        || '</span></span>'
        || '<span>vs ' || TO_CHAR(~weeks_back) || ' prior window'
        || CASE WHEN ~weeks_back = 1 THEN '' ELSE 's' END
        || ', every ~step_label, back to '
        || TO_CHAR(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                   - ~weeks_back*(~step_hours/24) - ~win_hours/24, 'Dy DD Mon')
        || '</span>'
        || '<span class="w-toggle"><span class="closed">show all windows &#9662;</span>'
        || '<span class="opened">hide windows &#9652;</span></span>'
        || '</summary>');
    DBMS_OUTPUT.PUT_LINE('    <div class="windows-chips">');
    -- Phase 3: each chip carries its DATE when the window starts on a
    -- different day than the Current window (weekly / daily cadence --
    -- every chip used to read the same clock range), and the full ISO
    -- range in its title.
    FOR w IN (
        SELECT LEVEL - 1 AS wk,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24) - ~win_hours/24,
                   'HH24:MI') AS w_start,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24),
                   'HH24:MI') AS w_end,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24) - ~win_hours/24,
                   'Dy DD Mon') AS w_day,
               CASE WHEN TRUNC(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                               - (LEVEL-1)*(~step_hours/24) - ~win_hours/24)
                       = TRUNC(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                               - ~win_hours/24)
                    THEN 'Y' ELSE 'N' END AS same_day,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24) - ~win_hours/24,
                   'YYYY-MM-DD HH24:MI') AS w_start_iso,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24),
                   'YYYY-MM-DD HH24:MI') AS w_end_iso
        FROM   dual
        CONNECT BY LEVEL <= ~weeks_back + 1
        ORDER  BY LEVEL - 1
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('      <button type="button" class="wchip'
            || CASE WHEN w.wk = 0 THEN ' cur' ELSE '' END
            || '" data-w="' || w.wk || '" title="' || w.w_start_iso || ' &rarr; '
            || w.w_end_iso || ' &middot; click to highlight this window everywhere">'
            || CASE WHEN w.wk = 0
                    THEN '<b>current</b>'
                    ELSE '<b>&minus;'
                         || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, w.wk)
                         || '</b>'
               END
            || ' <span>'
            || CASE WHEN w.same_day = 'N' THEN '<em>' || w.w_day || '</em> ' ELSE '' END
            || w.w_start || ' &rarr; ' || w.w_end || '</span>'
            || '</button>');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('    </div>');
    DBMS_OUTPUT.PUT_LINE('    <div class="windows-hint">click a window to '
        || 'highlight it everywhere &middot; Esc clears</div>');
    DBMS_OUTPUT.PUT_LINE('    </details>');
    DBMS_OUTPUT.PUT_LINE('    <div class="windows-chart" id="masthead-timeline"></div>');

    -- Plain-text fallback (visible only when body.no-charts hides the chart).
    DBMS_OUTPUT.PUT_LINE('    <div class="windows-fallback">');
    FOR w IN (
        SELECT LEVEL - 1 AS wk,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24) - ~win_hours/24,
                   'YYYY-MM-DD HH24:MI') AS w_start,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24),
                   'YYYY-MM-DD HH24:MI') AS w_end
        FROM   dual
        CONNECT BY LEVEL <= ~weeks_back + 1
        ORDER  BY LEVEL - 1
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('      <span class="win">'
            || CASE WHEN w.wk = 0
                    THEN '<b>current</b> '
                    ELSE '<b>&minus;'
                         || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, w.wk)
                         || '</b> '
               END
            || w.w_start || ' &rarr; ' || w.w_end
            || '</span>');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('    </div>');
    DBMS_OUTPUT.PUT_LINE('  </div>');
    DBMS_OUTPUT.PUT_LINE('</header>');

    -- ECharts init for the masthead timeline strip. Same offline
    -- pattern as every other chart in the report: if ECharts failed
    -- to load, body.no-charts hides .windows-chart and the
    -- .windows-fallback list takes over.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.mastheadTimeline={');
    -- v_times_json / v_vals_json are CLOBs that can exceed the 32767-byte
    -- per-PUT_LINE limit; emit each in 32500-char chunks (newlines between
    -- chunks are valid whitespace inside JS array literals).
    DBMS_OUTPUT.PUT_LINE('times:');
    put_clob_chunked(v_times_json);
    DBMS_OUTPUT.PUT_LINE(',');
    DBMS_OUTPUT.PUT_LINE('vals:');
    put_clob_chunked(v_vals_json);
    DBMS_OUTPUT.PUT_LINE(',');
    DBMS_OUTPUT.PUT_LINE('windows:' || v_windows_json);
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("masthead-timeline"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.mastheadTimeline;');
    DBMS_OUTPUT.PUT_LINE('if(!d.times.length){el.style.display="none"; return;}');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    -- paint() re-reads the CSS vars and theme-picks the hardcoded band/area
    -- rgba fills each call, so the awr:theme event (F14) re-styles the chart on
    -- a dark toggle instead of leaving it on the init-time palette.
    DBMS_OUTPUT.PUT_LINE('function paint(){');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var red=cs.getPropertyValue("--accent").trim()||"#1f5fa8";');
    DBMS_OUTPUT.PUT_LINE('var dark=document.body.classList.contains("dark");');
    DBMS_OUTPUT.PUT_LINE('var bandCurrent=dark?"rgba(91,155,216,0.20)":"rgba(31,95,168,0.18)";');
    DBMS_OUTPUT.PUT_LINE('var bandPrior=dark?"rgba(133,145,160,0.12)":"rgba(100,116,139,0.10)";');
    DBMS_OUTPUT.PUT_LINE('var areaFill=dark?"rgba(91,155,216,0.10)":"rgba(31,95,168,0.08)";');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=(d.windows||[]).map(function(w){return [');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[0],itemStyle:{color:w[2]==="current"?bandCurrent:bandPrior},');
    -- B1: label only the current band; the oldest band hugs the left grid
    -- edge and is narrower than its label, so a centered "w-4" bled past
    -- x=0 and rendered as a stray "-4".
    DBMS_OUTPUT.PUT_LINE('   label:w[2]==="current"?{show:true,position:"insideTop",color:mu,fontSize:9,formatter:w[2],distance:1}:{show:false}},');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[1]}];});');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  animation:false,');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('    valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(1)+" s";}},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:0,right:0,top:12,bottom:18,containLabel:false},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.times,boundaryGap:false,');
    DBMS_OUTPUT.PUT_LINE('    axisLine:{show:false},axisTick:{show:false},');
    DBMS_OUTPUT.PUT_LINE('    axisLabel:{color:mu,fontSize:9,hideOverlap:true,showMinLabel:false,showMaxLabel:false,');
    DBMS_OUTPUT.PUT_LINE('      interval:Math.max(0,Math.floor(d.times.length/8))}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",show:false},');
    DBMS_OUTPUT.PUT_LINE('  series:[{');
    DBMS_OUTPUT.PUT_LINE('    name:"DB time",type:"line",smooth:true,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('    data:d.vals,');
    DBMS_OUTPUT.PUT_LINE('    lineStyle:{width:1.2,color:red},');
    DBMS_OUTPUT.PUT_LINE('    areaStyle:{color:areaFill},');
    DBMS_OUTPUT.PUT_LINE('    markArea:{silent:true,data:markAreaData,itemStyle:{opacity:1},z:0},');
    DBMS_OUTPUT.PUT_LINE('    markLine:(window.AWR_markLine&&window.AWR_markLine(d.times))||{data:[]},');
    DBMS_OUTPUT.PUT_LINE('    z:5');
    DBMS_OUTPUT.PUT_LINE('  }]');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('paint();');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:theme",paint);');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- =========================================================
    -- Sticky table-of-contents nav. Same anchor IDs the dense
    -- design used; numerals match the per-section h2::before
    -- counters in _style.sql.
    -- =========================================================
    -- Grouped to match the visual section order set in _style.sql
    -- (Triage / Workload / SQL / Storage and config), so the scrollspy
    -- walks the rail top-to-bottom.  The hrefs are load-bearing: the
    -- Normal-view rail rule (norm-dim) keys on them.
    DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
        || '<div class="rail-brand"><span>AWR &middot; Timeline comparison</span>'
        -- Dark mode toggle: flips body.dark, which (via _style.sql) swaps
        -- every color token to the Slate Instrument dark palette. Rendered
        -- as a sun/moon icon button beside the rail's report-title row.
        -- Both icons ship inline; CSS shows only the one for the mode
        -- you'd switch TO (moon while light, sun while dark).
        || '<button type="button" id="theme-toggle" class="theme-icon-btn"'
        || ' aria-pressed="false"'
        || ' aria-label="Toggle dark mode"'
        || ' title="Switch between light and dark color theme">'
        || '<svg class="icon-sun" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">'
        || '<circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/>'
        || '<path d="M12 2.5v3M12 18.5v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1'
        || 'M2.5 12h3M18.5 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"'
        || ' stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
        || '</svg>'
        || '<svg class="icon-moon" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">'
        || '<path d="M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5a8.5 8.5 0 1 0 11.2 11.2z" fill="currentColor"/>'
        || '</svg>'
        || '</button>'
        || '</div>'
        -- B8 (narrow layout only, display:none on desktop): the current
        -- section name, kept in sync by the scrollspy, plus the hamburger
        -- that drops nav.toc .rail-list down as a panel.
        || '<span class="rail-cur"></span>'
        || '<button type="button" class="rail-menu-btn" id="rail-menu-btn"'
        || ' aria-expanded="false" aria-label="Show section list">&#9776;</button>'
        -- T4: row filter.  Narrows every section table to the rows whose
        -- first two cells match; Cmd/Ctrl-K focuses it, Esc clears it.
        || '<div class="rail-filter">'
        || '<input type="text" id="row-filter" autocomplete="off"'
        || ' placeholder="Filter rows&#8230;"'
        || ' aria-label="Filter table rows across the report">'
        || '<span class="kbd">&#8984;K</span>'
        || '</div>'
        -- The section links live in .rail-list so the narrow layout can
        -- turn them into a dropdown.  Every existing selector that targets
        -- them (nav.toc a / nav.toc b, the rail JS)
        -- is a descendant match, so desktop rendering is unchanged.
        || '<div class="rail-list">'
        || '<b>Triage</b>'
        -- Unhidden by the chrome JS when section 17 relocated a narrative
        -- block into the masthead slot.
        || '<a href="#narrative-slot" class="narr-link" hidden>What changed</a>'
        || '<a href="#db-time-summary">DB time</a>'
        || '<a href="#overview">Overview</a>'
        || '<a href="#ash-timeline">ASH timeline</a>'
        || '<a href="#findings">Findings</a>'
        || '<a href="#windows">Windows</a>'
        || '<b>Workload</b>'
        -- Day profile link only when the section exists (profile_days > 0);
        -- '' otherwise keeps the nav byte-identical.
        || CASE WHEN ~profile_days > 0
                THEN '<a href="#day-profile">Day profile</a>' ELSE '' END
        || '<a href="#utilization">Utilization</a>'
        || '<a href="#load">Load profile</a>'
        || '<a href="#metrics">Metrics</a>'
        || '<a href="#waits-fg">Waits &mdash; foreground</a>'
        || '<a href="#waits-bg">Waits &mdash; background</a>'
        || '<b>SQL</b>'
        || '<a href="#topsql">Top SQL</a>'
        || '<a href="#topsql-ash">Top SQL &mdash; ASH</a>'
        || '<a href="#sqlmon">SQL Monitor</a>'
        || '<b>Storage &amp; config</b>'
        || '<a href="#segment-io">Segment I/O</a>'
        || '<a href="#file-io">File I/O</a>'
        || '<a href="#param-changes">Parameters</a>'
        || '</div>'
        || '<div class="rail-foot">'
        -- Narrow-screen "View" button: opens .view-panel (the mode switch
        -- + next-finding) as a popover; display:none on
        -- desktop, where .view-panel is display:contents and the buttons
        -- sit in the rail.
        || '<button type="button" class="view-btn" id="view-btn"'
        || ' aria-expanded="false" aria-controls="view-panel"'
        || ' title="Report view options">View &#9662;</button>'
        || '<div class="view-panel" id="view-panel">'
        -- Normal / Full mode switch (body.normal / body.full, see
        -- _style.sql): Normal keeps the verdict, headline metrics,
        -- findings, ASH timeline and Top SQL (plus parameter changes, SQL
        -- Monitor and the day profile when they have something to say);
        -- Full is the whole report.  Persisted in localStorage.
        || '<div class="mode-switch" role="group" aria-label="Report detail level">'
        || '<button type="button" id="mode-normal" class="mode-btn" aria-pressed="true"'
        || ' title="Normal view: verdict, headline metrics, findings, ASH timeline, Top SQL">'
        || 'Normal</button>'
        || '<button type="button" id="mode-full" class="mode-btn" aria-pressed="false"'
        || ' title="Full view: every section and every scored row">'
        || 'Full</button>'
        || '</div>'
        -- C2: jump to the next crit finding (J / K also work from anywhere
        -- outside a text field).
        || '<button type="button" id="next-finding" class="next-finding"'
        || ' title="Jump to the next large (critical) finding">'
        || '<span>&darr; next large finding</span>'
        || '<span class="keys">J K</span>'
        || '</button>'
        || '</div>'
        || '</div>'
        || '</nav>');

    -- Wire the dark-mode toggle. The early theme script (before
    -- header.report) already applied body.dark from localStorage/OS
    -- preference at load; this just syncs the button state and persists
    -- future clicks. Icon visibility (sun vs moon) is pure CSS off
    -- body.dark, so there's no label/markup to swap here.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('var btn=document.getElementById("theme-toggle"); if(!btn) return;');
    DBMS_OUTPUT.PUT_LINE('function sync(on){btn.setAttribute("aria-pressed",on?"true":"false");}');
    DBMS_OUTPUT.PUT_LINE('sync(document.body.classList.contains("dark"));');
    DBMS_OUTPUT.PUT_LINE('btn.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('  var on=document.body.classList.toggle("dark");');
    DBMS_OUTPUT.PUT_LINE('  try{localStorage.setItem("awr-theme",on?"dark":"light");}catch(e){}');
    DBMS_OUTPUT.PUT_LINE('  sync(on);');
    -- ECharts read their axis/label colors from the CSS vars once at init, so
    -- a theme flip leaves every chart on the old palette.  Broadcast awr:theme
    -- (a document-level CustomEvent); each chart-init listens and re-applies its
    -- var-derived colors via setOption (F14).
    DBMS_OUTPUT.PUT_LINE('  document.dispatchEvent(new CustomEvent("awr:theme",{detail:{dark:on}}));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- Live status rail. Runs on DOMContentLoaded because this script is
    -- emitted before the data sections exist in the DOM.  Two jobs:
    --   1. Status dots: prepend a span.st to every rail link, graded from
    --      the severity classes the target section already carries in its
    --      HTML (worst wins: .crit > .warn > ok; td.chg counts as warn so
    --      changed parameters surface).  Sections whose only rows are
    --      skip/insufficient stay "na" (neutral dot).  Pure client-side --
    --      no extra SQL pass, and the dots always agree with the tables.
    --   2. Scrollspy: highlight the rail link of the last section whose
    --      top has passed the upper quarter of the viewport.  A plain
    --      throttled scroll listener, NOT IntersectionObserver or
    --      requestAnimationFrame: embedded webviews (and the Claude
    --      preview browser) throttle both to a standstill, and at 16
    --      sections the scan is trivially cheap.  Sections hidden by the
    --      Normal view (offsetParent null) are skipped.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("DOMContentLoaded",function(){');
    DBMS_OUTPUT.PUT_LINE('var nav=document.querySelector("nav.toc"); if(!nav) return;');
    DBMS_OUTPUT.PUT_LINE('var pairs=[];');
    DBMS_OUTPUT.PUT_LINE('nav.querySelectorAll(''a[href^="#"]'').forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('  var sec=document.getElementById(a.getAttribute("href").slice(1));');
    DBMS_OUTPUT.PUT_LINE('  if(!sec) return;');
    -- Capture the pristine link label BEFORE the status dot and the C2
    -- count pills are appended; the narrow-screen top bar (B8) shows it as
    -- the current-section name.
    DBMS_OUTPUT.PUT_LINE('  a.setAttribute("data-label",(a.textContent||"").trim());');
    DBMS_OUTPUT.PUT_LINE('  pairs.push([a,sec]);');
    DBMS_OUTPUT.PUT_LINE('  var dot=document.createElement("span"); dot.className="st";');
    -- skip/insufficient rows don't count as data: a findings table made
    -- entirely of INSUFFICIENT_HISTORY rows keeps the neutral dot.
    DBMS_OUTPUT.PUT_LINE('  if(sec.querySelector(".crit")) dot.className+=" crit";');
    DBMS_OUTPUT.PUT_LINE('  else if(sec.querySelector(".warn, td.chg")) dot.className+=" warn";');
    DBMS_OUTPUT.PUT_LINE('  else if(sec.querySelector("tbody tr:not(.skip) td, .hero-card, .ash-sql-card:not(.insufficient)")) dot.className+=" ok";');
    DBMS_OUTPUT.PUT_LINE('  a.insertBefore(dot,a.firstChild);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var pending=false;');
    DBMS_OUTPUT.PUT_LINE('function spy(){');
    DBMS_OUTPUT.PUT_LINE('  pending=false;');
    DBMS_OUTPUT.PUT_LINE('  var y=window.scrollY+window.innerHeight*0.25;');
    DBMS_OUTPUT.PUT_LINE('  var best=null, bestTop=-1, firstVis=null;');
    DBMS_OUTPUT.PUT_LINE('  pairs.forEach(function(p){');
    DBMS_OUTPUT.PUT_LINE('    if(p[1].offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    if(!firstVis) firstVis=p;');
    DBMS_OUTPUT.PUT_LINE('    var t=p[1].offsetTop;');
    DBMS_OUTPUT.PUT_LINE('    if(t<=y && t>bestTop){ best=p; bestTop=t; }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(!best) best=firstVis;');
    DBMS_OUTPUT.PUT_LINE('  pairs.forEach(function(p){ p[0].classList.toggle("on",p===best); });');
    -- B8: mirror the active section name into the narrow-screen top bar.
    DBMS_OUTPUT.PUT_LINE('  var cur=nav.querySelector(".rail-cur");');
    DBMS_OUTPUT.PUT_LINE('  if(cur) cur.textContent=best?(best[0].getAttribute("data-label")||""):"";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function onScroll(){ if(!pending){ pending=true; setTimeout(spy,80); } }');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("scroll",onScroll,{passive:true});');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",onScroll);');
    -- Fallback for embedded webviews that suppress scroll events
    -- entirely (observed in in-app preview browsers): poll scrollY and
    -- re-run the spy only when it actually changed.  One number
    -- comparison per 400ms; the scroll listener above still gives
    -- instant updates in normal browsers.
    DBMS_OUTPUT.PUT_LINE('var lastY=-1;');
    DBMS_OUTPUT.PUT_LINE('setInterval(function(){');
    DBMS_OUTPUT.PUT_LINE('  if(window.scrollY!==lastY){ lastY=window.scrollY; spy(); }');
    DBMS_OUTPUT.PUT_LINE('},400);');
    DBMS_OUTPUT.PUT_LINE('spy();');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- =========================================================
    -- Report chrome: the page-level JS half of the facelift hook
    -- contract.  Everything here is delegated / injected at
    -- DOMContentLoaded (this script is emitted before the data
    -- sections exist), CDN-free, and degrades to a plain readable
    -- report when it does not run.  What it wires up:
    --   T1  .expander[data-for] toggles .open on its table
    --       (tr[data-tail="Y"] rows are CSS-hidden until then)
    --   T2  --navh / --h2h so the sticky h2 + thead stack correctly
    --   T3  click-to-sort on section table thead th (data-nosort
    --       opts out; th[data-w] drives the window highlight instead)
    --   T4  #row-filter narrows every table by its first two cells
    --   T8  folds the section intro <p> into details.method and
    --       keeps its first sentence on the h2 as small.h2sub
    --   C1  .tabs[data-tabs] / .tabpanel switching (+ ECharts resize)
    --   C2  crit/warn count pills on the rail links, J / K jumping
    --   C4  copy buttons: .copy-btn, per-table CSV / MD toolbars,
    --       the h2 permalink anchor
    --   X2  window highlight: click a th[data-w] or a masthead
    --       .wchip to toggle .hl on every [data-w] element and
    --       broadcast the awr:window CustomEvent for chart sections
    --   the Normal / Full mode switch (body.normal / body.full)
    --   B8  the narrow-screen hamburger dropdown
    -- No literal tilde anywhere below: this file runs under
    -- SET DEFINE tilde (see the CLAUDE.md tilde gotcha).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("DOMContentLoaded",function(){');
    DBMS_OUTPUT.PUT_LINE('var doc=document, bd=doc.body, nav=doc.querySelector("nav.toc");');
    DBMS_OUTPUT.PUT_LINE('function closest(t,sel){return (t&&t.closest)?t.closest(sel):null;}');
    DBMS_OUTPUT.PUT_LINE('function cellText(td){');
    DBMS_OUTPUT.PUT_LINE('  var c=td.cloneNode(true);');
    DBMS_OUTPUT.PUT_LINE('  c.querySelectorAll("svg").forEach(function(s){s.parentNode.removeChild(s);});');
    DBMS_OUTPUT.PUT_LINE('  return (c.textContent||"").replace(/\s+/g," ").trim();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- clipboard (async API, hidden-textarea fallback) ---- */');
    DBMS_OUTPUT.PUT_LINE('function paste(s){');
    DBMS_OUTPUT.PUT_LINE('  try{');
    DBMS_OUTPUT.PUT_LINE('    var ta=doc.createElement("textarea");');
    DBMS_OUTPUT.PUT_LINE('    ta.value=s; ta.setAttribute("readonly","");');
    DBMS_OUTPUT.PUT_LINE('    ta.style.position="fixed"; ta.style.top="-1000px"; ta.style.opacity="0";');
    DBMS_OUTPUT.PUT_LINE('    bd.appendChild(ta); ta.select(); doc.execCommand("copy"); bd.removeChild(ta);');
    DBMS_OUTPUT.PUT_LINE('  }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function flash(el,done){');
    DBMS_OUTPUT.PUT_LINE('  if(!el||el.getAttribute("data-busy")) return;');
    DBMS_OUTPUT.PUT_LINE('  var old=el.textContent;');
    DBMS_OUTPUT.PUT_LINE('  el.setAttribute("data-busy","1");');
    DBMS_OUTPUT.PUT_LINE('  el.textContent=done||"Copied";');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){el.textContent=old;el.removeAttribute("data-busy");},1200);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function copyText(s,el,done){');
    DBMS_OUTPUT.PUT_LINE('  var ok=function(){flash(el,done);};');
    DBMS_OUTPUT.PUT_LINE('  try{');
    DBMS_OUTPUT.PUT_LINE('    if(navigator.clipboard&&navigator.clipboard.writeText){');
    DBMS_OUTPUT.PUT_LINE('      navigator.clipboard.writeText(s).then(ok,function(){paste(s);ok();});');
    DBMS_OUTPUT.PUT_LINE('      return;');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('  paste(s); ok();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- T8: fold each section intro into details.method ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section").forEach(function(sec){');
    DBMS_OUTPUT.PUT_LINE('  var h2=sec.querySelector(":scope > h2"); if(!h2) return;');
    DBMS_OUTPUT.PUT_LINE('  var p=h2.nextElementSibling;');
    DBMS_OUTPUT.PUT_LINE('  if(!p||p.tagName!=="P"||p.classList.contains("cdn-warn")) return;');
    DBMS_OUTPUT.PUT_LINE('  var t=(p.textContent||"").replace(/\s+/g," ").trim(); if(!t) return;');
    DBMS_OUTPUT.PUT_LINE('  var i=t.indexOf(". ");');
    DBMS_OUTPUT.PUT_LINE('  var sub=doc.createElement("small");');
    DBMS_OUTPUT.PUT_LINE('  sub.className="h2sub"; sub.textContent=(i>0?t.slice(0,i+1):t);');
    DBMS_OUTPUT.PUT_LINE('  h2.appendChild(sub);');
    DBMS_OUTPUT.PUT_LINE('  var d=doc.createElement("details"); d.className="method";');
    DBMS_OUTPUT.PUT_LINE('  var s=doc.createElement("summary"); s.textContent="How this is computed";');
    DBMS_OUTPUT.PUT_LINE('  d.appendChild(s);');
    DBMS_OUTPUT.PUT_LINE('  p.parentNode.insertBefore(d,p);');
    DBMS_OUTPUT.PUT_LINE('  p.removeAttribute("style");');
    DBMS_OUTPUT.PUT_LINE('  d.appendChild(p);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: permalink anchor on every section heading ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section > h2").forEach(function(h2){');
    DBMS_OUTPUT.PUT_LINE('  var sec=h2.parentNode; if(!sec.id) return;');
    DBMS_OUTPUT.PUT_LINE('  var a=doc.createElement("a");');
    DBMS_OUTPUT.PUT_LINE('  a.className="permalink"; a.href="#"+sec.id; a.textContent="#";');
    DBMS_OUTPUT.PUT_LINE('  a.title="Copy a link to this section";');
    DBMS_OUTPUT.PUT_LINE('  a.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('    ev.preventDefault();');
    DBMS_OUTPUT.PUT_LINE('    var st=stateStr();');
    DBMS_OUTPUT.PUT_LINE('    copyText(location.href.split("#")[0]+"#"+sec.id+(st?"!"+st:""),a,"\u2713");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  h2.appendChild(a);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: per-table CSV / Markdown copy toolbar ---- */');
    DBMS_OUTPUT.PUT_LINE('function visRows(tb){');
    DBMS_OUTPUT.PUT_LINE('  var out=[];');
    DBMS_OUTPUT.PUT_LINE('  tb.querySelectorAll("tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(tr.hidden) return;');
    DBMS_OUTPUT.PUT_LINE('    if(getComputedStyle(tr).display==="none") return;');
    DBMS_OUTPUT.PUT_LINE('    out.push(tr);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function tableRows(tb){');
    DBMS_OUTPUT.PUT_LINE('  var hr=tb.querySelectorAll("thead tr"), rows=[];');
    DBMS_OUTPUT.PUT_LINE('  if(hr.length){');
    DBMS_OUTPUT.PUT_LINE('    rows.push(Array.prototype.map.call(hr[hr.length-1].cells,cellText));');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  visRows(tb).forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    rows.push(Array.prototype.map.call(tr.cells,cellText));');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return rows;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function toCSV(tb){');
    DBMS_OUTPUT.PUT_LINE('  return tableRows(tb).map(function(r){');
    DBMS_OUTPUT.PUT_LINE('    return r.map(function(v){');
    DBMS_OUTPUT.PUT_LINE('      return /[",\n]/.test(v)?"\""+v.replace(/"/g,"\"\"")+"\"":v;');
    DBMS_OUTPUT.PUT_LINE('    }).join(",");');
    DBMS_OUTPUT.PUT_LINE('  }).join("\n");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function toMD(tb){');
    DBMS_OUTPUT.PUT_LINE('  var rows=tableRows(tb); if(!rows.length) return "";');
    DBMS_OUTPUT.PUT_LINE('  var esc=function(v){return v.replace(/\|/g,"\\|");};');
    DBMS_OUTPUT.PUT_LINE('  var out=["| "+rows[0].map(esc).join(" | ")+" |",');
    DBMS_OUTPUT.PUT_LINE('           "|"+rows[0].map(function(){return " --- |";}).join("")];');
    DBMS_OUTPUT.PUT_LINE('  rows.slice(1).forEach(function(r){');
    DBMS_OUTPUT.PUT_LINE('    out.push("| "+r.map(esc).join(" | ")+" |");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out.join("\n");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  if(!tb.querySelector("thead")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.hasAttribute("data-notools")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.closest("tr.sql-detail")||tb.closest("details")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.querySelectorAll("tbody tr").length<4) return;');
    DBMS_OUTPUT.PUT_LINE('  var bar=doc.createElement("div");');
    DBMS_OUTPUT.PUT_LINE('  bar.className="tbl-tools"+(tb.classList.contains("full-only")?" full-only":"");');
    DBMS_OUTPUT.PUT_LINE('  var mk=function(label,fn){');
    DBMS_OUTPUT.PUT_LINE('    var b=doc.createElement("button");');
    DBMS_OUTPUT.PUT_LINE('    b.type="button"; b.className="tool-btn"; b.textContent=label;');
    DBMS_OUTPUT.PUT_LINE('    b.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('      ev.stopPropagation();');
    DBMS_OUTPUT.PUT_LINE('      copyText(fn(tb),b,"Copied");');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('    bar.appendChild(b);');
    DBMS_OUTPUT.PUT_LINE('  };');
    DBMS_OUTPUT.PUT_LINE('  mk("\u29C9 CSV",toCSV); mk("\u29C9 MD",toMD);');
    DBMS_OUTPUT.PUT_LINE('  tb.parentNode.insertBefore(bar,tb);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: delegated .copy-btn (pre / code blocks) ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var b=closest(ev.target,".copy-btn"); if(!b) return;');
    DBMS_OUTPUT.PUT_LINE('  var sel=b.getAttribute("data-copy");');
    DBMS_OUTPUT.PUT_LINE('  var target=sel?doc.querySelector(sel):b.parentNode;');
    DBMS_OUTPUT.PUT_LINE('  if(!target) return;');
    DBMS_OUTPUT.PUT_LINE('  var c=target.cloneNode(true);');
    DBMS_OUTPUT.PUT_LINE('  c.querySelectorAll(".copy-btn").forEach(function(x){x.parentNode.removeChild(x);});');
    DBMS_OUTPUT.PUT_LINE('  copyText((c.textContent||"").replace(/^\s+|\s+$/g,""),b,"Copied");');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T1: long-tail expanders ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var e=closest(ev.target,".expander"); if(!e) return;');
    DBMS_OUTPUT.PUT_LINE('  var id=e.getAttribute("data-for");');
    DBMS_OUTPUT.PUT_LINE('  var tb=id?doc.getElementById(id):null; if(!tb) return;');
    DBMS_OUTPUT.PUT_LINE('  var on=tb.classList.toggle("open");');
    DBMS_OUTPUT.PUT_LINE('  var n=e.getAttribute("data-n")||"";');
    DBMS_OUTPUT.PUT_LINE('  var noun=e.getAttribute("data-noun")||"rows";');
    DBMS_OUTPUT.PUT_LINE('  e.textContent=(on?"\u25BE Hide ":"\u25B8 Show ")+n+" "+noun;');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C1: tabs ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=closest(ev.target,".tabs [data-t]"); if(!t) return;');
    DBMS_OUTPUT.PUT_LINE('  var bar=closest(t,".tabs"); if(!bar) return;');
    DBMS_OUTPUT.PUT_LINE('  var g=bar.getAttribute("data-tabs"), key=t.getAttribute("data-t");');
    DBMS_OUTPUT.PUT_LINE('  bar.querySelectorAll("[data-t]").forEach(function(x){var on=(x===t);x.classList.toggle("on",on);x.setAttribute("aria-selected",on?"true":"false");x.setAttribute("tabindex",on?"0":"-1");});');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll(".tabpanel[data-tabs=\""+g+"\"]").forEach(function(p){');
    DBMS_OUTPUT.PUT_LINE('    var on=p.getAttribute("data-t")===key;');
    DBMS_OUTPUT.PUT_LINE('    p.classList.toggle("on",on);');
    DBMS_OUTPUT.PUT_LINE('    if(on&&window.echarts){');
    DBMS_OUTPUT.PUT_LINE('      p.querySelectorAll("[_echarts_instance_]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('        var inst=echarts.getInstanceByDom(el); if(inst) inst.resize();');
    DBMS_OUTPUT.PUT_LINE('      });');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- P2: wide tables scroll inside their panel ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  var p=tb.parentNode; if(p&&p.classList&&p.classList.contains("tblwrap")) return;');
    DBMS_OUTPUT.PUT_LINE('  var w=doc.createElement("div"); w.className="tblwrap";');
    DBMS_OUTPUT.PUT_LINE('  p.insertBefore(w,tb); w.appendChild(tb);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('function fitTables(){');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll(".tblwrap").forEach(function(w){');
    DBMS_OUTPUT.PUT_LINE('    var tb=w.firstElementChild; if(!tb||w.offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    w.classList.remove("scroll");');
    DBMS_OUTPUT.PUT_LINE('    if(tb.scrollWidth>w.clientWidth+1) w.classList.add("scroll");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_fitTables=fitTables;');
    DBMS_OUTPUT.PUT_LINE('fitTables(); setTimeout(fitTables,400);');
    DBMS_OUTPUT.PUT_LINE('var ft=null;');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",function(){ if(ft) clearTimeout(ft); ft=setTimeout(fitTables,150); });');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){ if(closest(ev.target,".expander,.tabs [data-t],details > summary")) setTimeout(fitTables,50); });');
    DBMS_OUTPUT.PUT_LINE('/* ---- P2: narrow-screen "View" popover ---- */');
    DBMS_OUTPUT.PUT_LINE('var vb=doc.getElementById("view-btn"), vf=vb?closest(vb,".rail-foot"):null;');
    DBMS_OUTPUT.PUT_LINE('function closeView(){ if(vf){ vf.classList.remove("open"); vb.setAttribute("aria-expanded","false"); } }');
    DBMS_OUTPUT.PUT_LINE('if(vb&&vf){');
    DBMS_OUTPUT.PUT_LINE('  vb.addEventListener("click",function(ev){ ev.stopPropagation(); var on=vf.classList.toggle("open"); vb.setAttribute("aria-expanded",on?"true":"false"); if(nav) nav.classList.remove("menu-open"); });');
    DBMS_OUTPUT.PUT_LINE('  doc.addEventListener("click",function(ev){ if(vf.classList.contains("open")&&!closest(ev.target,".rail-foot")) closeView(); });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- X2: cross-report window highlight ---- */');
    DBMS_OUTPUT.PUT_LINE('var curW=null;');
    DBMS_OUTPUT.PUT_LINE('function applyW(){');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("[data-w]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    el.classList.toggle("hl",curW!==null&&el.getAttribute("data-w")===curW);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  doc.dispatchEvent(new CustomEvent("awr:window",');
    DBMS_OUTPUT.PUT_LINE('    {detail:{w:curW===null?null:Number(curW)}}));');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function setW(w){ curW=(w===curW)?null:w; applyW(); }');
    DBMS_OUTPUT.PUT_LINE('function clearW(){ if(curW!==null){ curW=null; applyW(); } }');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var el=closest(ev.target,"th[data-w],.wchip[data-w]"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  if(closest(el,"summary")) ev.preventDefault();');
    DBMS_OUTPUT.PUT_LINE('  setW(el.getAttribute("data-w"));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T3: click-to-sort ---- */');
    DBMS_OUTPUT.PUT_LINE('function numOf(s){');
    DBMS_OUTPUT.PUT_LINE('  var t=s.replace(/\u2212/g,"-")');
    DBMS_OUTPUT.PUT_LINE('         .replace(/[\u25B2\u25BC\u25B8\u25BE\u2191\u2193\u00A0]/g,"")');
    DBMS_OUTPUT.PUT_LINE('         .replace(/,/g,"").replace(/%/g,"").replace(/\+/g,"").replace(/\s/g,"");');
    DBMS_OUTPUT.PUT_LINE('  if(!t) return null;');
    DBMS_OUTPUT.PUT_LINE('  var m=/^(-?(?:\d+\.?\d*|\.\d+))([kMG])?$/.exec(t);');
    DBMS_OUTPUT.PUT_LINE('  if(!m) return null;');
    DBMS_OUTPUT.PUT_LINE('  var v=parseFloat(m[1]);');
    DBMS_OUTPUT.PUT_LINE('  if(m[2]==="k") v*=1e3; else if(m[2]==="M") v*=1e6; else if(m[2]==="G") v*=1e9;');
    DBMS_OUTPUT.PUT_LINE('  return v;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  if(closest(ev.target,".tool-btn")) return;');
    DBMS_OUTPUT.PUT_LINE('  var th=closest(ev.target,"section table thead th"); if(!th) return;');
    DBMS_OUTPUT.PUT_LINE('  if(th.hasAttribute("data-w")) return;');
    DBMS_OUTPUT.PUT_LINE('  var tb=closest(th,"table");');
    DBMS_OUTPUT.PUT_LINE('  if(!tb||tb.hasAttribute("data-nosort")) return;');
    DBMS_OUTPUT.PUT_LINE('  var body=tb.tBodies[0]; if(!body) return;');
    DBMS_OUTPUT.PUT_LINE('  var hr=th.parentNode;');
    DBMS_OUTPUT.PUT_LINE('  var idx=Array.prototype.indexOf.call(hr.cells,th);');
    DBMS_OUTPUT.PUT_LINE('  var desc=!th.classList.contains("desc");');
    DBMS_OUTPUT.PUT_LINE('  hr.querySelectorAll("th").forEach(function(x){x.classList.remove("asc","desc");x.removeAttribute("aria-sort");});');
    DBMS_OUTPUT.PUT_LINE('  th.classList.add(desc?"desc":"asc"); th.setAttribute("aria-sort",desc?"descending":"ascending");');
    DBMS_OUTPUT.PUT_LINE('  var dec=Array.prototype.slice.call(body.rows).map(function(r,i){');
    DBMS_OUTPUT.PUT_LINE('    var c=r.cells[idx], s=c?cellText(c):"";');
    DBMS_OUTPUT.PUT_LINE('    return {r:r,i:i,s:s,n:c?numOf(s):null};');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  var blank=function(d){return !d.s||d.s==="\u2014"||d.s==="\u2013"||d.s==="-";};');
    DBMS_OUTPUT.PUT_LINE('  dec.sort(function(a,b){');
    DBMS_OUTPUT.PUT_LINE('    var ab=blank(a), bb=blank(b);');
    DBMS_OUTPUT.PUT_LINE('    if(ab!==bb) return ab?1:-1;');
    DBMS_OUTPUT.PUT_LINE('    if(ab&&bb) return a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('    if(a.n!==null&&b.n!==null){');
    DBMS_OUTPUT.PUT_LINE('      if(a.n!==b.n) return desc?b.n-a.n:a.n-b.n;');
    DBMS_OUTPUT.PUT_LINE('      return a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('    if(a.n!==null) return -1;');
    DBMS_OUTPUT.PUT_LINE('    if(b.n!==null) return 1;');
    DBMS_OUTPUT.PUT_LINE('    var c=a.s.localeCompare(b.s);');
    DBMS_OUTPUT.PUT_LINE('    return c?(desc?-c:c):a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  dec.forEach(function(d){body.appendChild(d.r);});');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T4: row filter ---- */');
    DBMS_OUTPUT.PUT_LINE('var fi=doc.getElementById("row-filter");');
    DBMS_OUTPUT.PUT_LINE('function dimRail(){');
    DBMS_OUTPUT.PUT_LINE('  if(!nav) return;');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll("a[href^=\"#\"]").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    var sec=doc.getElementById(a.getAttribute("href").slice(1));');
    DBMS_OUTPUT.PUT_LINE('    if(!sec){ a.classList.remove("dim"); return; }');
    DBMS_OUTPUT.PUT_LINE('    var rows=sec.querySelectorAll("tbody tr");');
    DBMS_OUTPUT.PUT_LINE('    if(!rows.length){ a.classList.remove("dim"); return; }');
    DBMS_OUTPUT.PUT_LINE('    var vis=0;');
    DBMS_OUTPUT.PUT_LINE('    rows.forEach(function(r){ if(!r.hidden) vis++; });');
    DBMS_OUTPUT.PUT_LINE('    a.classList.toggle("dim",vis===0);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function applyFilter(){');
    DBMS_OUTPUT.PUT_LINE('  var q=((fi&&fi.value)||"").trim().toLowerCase();');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("section tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(!q){ tr.hidden=false; return; }');
    DBMS_OUTPUT.PUT_LINE('    var s="", n=Math.min(2,tr.cells.length);');
    DBMS_OUTPUT.PUT_LINE('    for(var i=0;i<n;i++) s+=" "+cellText(tr.cells[i]);');
    DBMS_OUTPUT.PUT_LINE('    tr.hidden=s.toLowerCase().indexOf(q)<0;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  dimRail();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('if(fi) fi.addEventListener("input",applyFilter);');
    DBMS_OUTPUT.PUT_LINE('/* ---- C2: per-section crit / warn counts on the rail links ---- */');
    DBMS_OUTPUT.PUT_LINE('if(nav){');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll("a[href^=\"#\"]").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    var id=a.getAttribute("href").slice(1);');
    DBMS_OUTPUT.PUT_LINE('    if(id==="overview") return;');
    DBMS_OUTPUT.PUT_LINE('    var sec=doc.getElementById(id); if(!sec) return;');
    DBMS_OUTPUT.PUT_LINE('    var c=0,w=0;');
    DBMS_OUTPUT.PUT_LINE('    sec.querySelectorAll("tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('      if(tr.closest("table[data-nocount]")) return;');
    DBMS_OUTPUT.PUT_LINE('      if(tr.classList.contains("twin")||tr.classList.contains("member")) return;');
    DBMS_OUTPUT.PUT_LINE('      if(tr.classList.contains("crit")||tr.querySelector(".badge.crit")) c++;');
    DBMS_OUTPUT.PUT_LINE('      else if(tr.classList.contains("warn")||tr.querySelector(".badge.warn")) w++;');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('    if(c){ var p=doc.createElement("span"); p.className="cnt c"; p.textContent=c; a.appendChild(p); }');
    DBMS_OUTPUT.PUT_LINE('    if(w){ var q=doc.createElement("span"); q.className="cnt w"; q.textContent=w; a.appendChild(q); }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- C2: next / previous large finding (J / K) ---- */');
    DBMS_OUTPUT.PUT_LINE('var jIdx=-1;');
    DBMS_OUTPUT.PUT_LINE('function findingRows(){');
    DBMS_OUTPUT.PUT_LINE('  var out=[];');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("section tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(tr.hidden||tr.offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    if(tr.classList.contains("twin")||tr.classList.contains("member")) return;');
    DBMS_OUTPUT.PUT_LINE('    if(tr.classList.contains("crit")||tr.querySelector(".badge.crit")) out.push(tr);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function jump(d){');
    DBMS_OUTPUT.PUT_LINE('  var list=findingRows(); if(!list.length) return;');
    DBMS_OUTPUT.PUT_LINE('  jIdx=(jIdx+d+list.length*2)%list.length;');
    DBMS_OUTPUT.PUT_LINE('  var tr=list[jIdx];');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("tr.jump-hi").forEach(function(x){x.classList.remove("jump-hi");});');
    DBMS_OUTPUT.PUT_LINE('  tr.scrollIntoView({block:"center"});');
    DBMS_OUTPUT.PUT_LINE('  tr.classList.add("jump-hi");');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){tr.classList.remove("jump-hi");},1600);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var nf=doc.getElementById("next-finding");');
    DBMS_OUTPUT.PUT_LINE('if(nf) nf.addEventListener("click",function(){jump(1);});');
    DBMS_OUTPUT.PUT_LINE('/* ---- Normal / Full view ---- */');
    -- Rail links whose target section is not part of the Normal view get
    -- .norm-dim (hidden in Normal); a group header whose every link is
    -- dimmed hides with them; one "+ N more sections" line replaces them.
    DBMS_OUTPUT.PUT_LINE('var hiddenSecs=[];');
    DBMS_OUTPUT.PUT_LINE('if(nav){');
    DBMS_OUTPUT.PUT_LINE('  var list=nav.querySelector(".rail-list")||nav, grp=null, gAll=true;');
    DBMS_OUTPUT.PUT_LINE('  Array.prototype.slice.call(list.children).forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    if(el.tagName==="B"){ if(grp&&gAll) grp.classList.add("norm-dim"); grp=el; gAll=true; return; }');
    DBMS_OUTPUT.PUT_LINE('    if(el.tagName!=="A") return;');
    DBMS_OUTPUT.PUT_LINE('    var id=(el.getAttribute("href")||"").slice(1), sec=id?doc.getElementById(id):null;');
    DBMS_OUTPUT.PUT_LINE('    if(sec&&sec.tagName==="SECTION"&&!sec.hasAttribute("data-normal")){ el.classList.add("norm-dim"); var cl=el.cloneNode(true); cl.querySelectorAll("span").forEach(function(x){x.parentNode.removeChild(x);}); hiddenSecs.push((cl.textContent||id).trim()); }');
    DBMS_OUTPUT.PUT_LINE('    else gAll=false;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(grp&&gAll) grp.classList.add("norm-dim");');
    DBMS_OUTPUT.PUT_LINE('  if(hiddenSecs.length){ var more=doc.createElement("a"); more.className="more-sections"; more.href="#"; more.textContent="+ "+hiddenSecs.length+" more in Full"; more.title=hiddenSecs.join(", "); more.addEventListener("click",function(ev){ ev.preventDefault(); setMode(true); }); list.appendChild(more); }');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function modeNote(){');
    DBMS_OUTPUT.PUT_LINE('  var mn=doc.getElementById("main-start"); if(!mn) return;');
    DBMS_OUTPUT.PUT_LINE('  var n=doc.getElementById("mode-note");');
    DBMS_OUTPUT.PUT_LINE('  if(!n){ n=doc.createElement("p"); n.id="mode-note"; n.className="mode-note"; mn.appendChild(n); }');
    DBMS_OUTPUT.PUT_LINE('  n.innerHTML="";');
    DBMS_OUTPUT.PUT_LINE('  n.appendChild(doc.createTextNode(hiddenSecs.length?("Normal view: "+hiddenSecs.length+" section"+(hiddenSecs.length===1?"":"s")+" and the per-metric detail tables are hidden ("+hiddenSecs.join(", ")+")."):"Normal view: the per-metric detail tables are hidden."));');
    DBMS_OUTPUT.PUT_LINE('  var b=doc.createElement("button"); b.type="button"; b.textContent="Show Full"; b.addEventListener("click",function(){ setMode(true); }); n.appendChild(b);');
    DBMS_OUTPUT.PUT_LINE('}');
    -- setMode(): flip the body classes, sync the switch, persist, and
    -- re-measure everything that was display:none (sticky offsets, table
    -- scroll wrappers, and every ECharts instance, which measured a zero
    -- width while hidden).
    DBMS_OUTPUT.PUT_LINE('function setMode(det,silent){');
    DBMS_OUTPUT.PUT_LINE('  bd.classList.toggle("full",!!det); bd.classList.toggle("normal",!det);');
    DBMS_OUTPUT.PUT_LINE('  var bn=doc.getElementById("mode-normal"), bdt=doc.getElementById("mode-full");');
    DBMS_OUTPUT.PUT_LINE('  if(bn) bn.setAttribute("aria-pressed",det?"false":"true");');
    DBMS_OUTPUT.PUT_LINE('  if(bdt) bdt.setAttribute("aria-pressed",det?"true":"false");');
    DBMS_OUTPUT.PUT_LINE('  if(!silent){ try{localStorage.setItem("awr-mode",det?"full":"normal");}catch(e){} }');
    DBMS_OUTPUT.PUT_LINE('  measure(); window.dispatchEvent(new Event("resize"));');
    DBMS_OUTPUT.PUT_LINE('  if(window.echarts&&echarts.getInstanceByDom){ doc.querySelectorAll("[_echarts_instance_]").forEach(function(el){ var c=echarts.getInstanceByDom(el); if(c) c.resize(); }); }');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(fitTables,60); closeView();');
    DBMS_OUTPUT.PUT_LINE('  doc.dispatchEvent(new CustomEvent("awr:mode",{detail:{full:!!det}}));');
    DBMS_OUTPUT.PUT_LINE('  if(!silent) pushState();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_setMode=setMode;');
    DBMS_OUTPUT.PUT_LINE('modeNote();');
    DBMS_OUTPUT.PUT_LINE('setMode(bd.classList.contains("full"),true);');
    DBMS_OUTPUT.PUT_LINE('var mbn=doc.getElementById("mode-normal"), mbd=doc.getElementById("mode-full");');
    DBMS_OUTPUT.PUT_LINE('if(mbn) mbn.addEventListener("click",function(){ setMode(false); });');
    DBMS_OUTPUT.PUT_LINE('if(mbd) mbd.addEventListener("click",function(){ setMode(true); });');
    -- inNormal(el): is this element visible in the Normal view?  Used by
    -- revealHash so a cross-link into hidden content flips to Full.
    DBMS_OUTPUT.PUT_LINE('function inNormal(el){ var sec=closest(el,"section"); if(sec&&sec.parentNode===doc.getElementById("main-start")&&!sec.hasAttribute("data-normal")) return false; return !closest(el,".full-only"); }');
    DBMS_OUTPUT.PUT_LINE('/* ---- B8: narrow-screen section dropdown ---- */');
    DBMS_OUTPUT.PUT_LINE('var mb=doc.getElementById("rail-menu-btn");');
    DBMS_OUTPUT.PUT_LINE('if(mb&&nav){');
    DBMS_OUTPUT.PUT_LINE('  mb.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('    var on=nav.classList.toggle("menu-open");');
    DBMS_OUTPUT.PUT_LINE('    mb.setAttribute("aria-expanded",on?"true":"false");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll(".rail-list a").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    a.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('      nav.classList.remove("menu-open");');
    DBMS_OUTPUT.PUT_LINE('      mb.setAttribute("aria-expanded","false");');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- T2: sticky offsets (--navh page-wide, --h2h per section) ---- */');
    DBMS_OUTPUT.PUT_LINE('function measure(){');
    DBMS_OUTPUT.PUT_LINE('  var navh=0;');
    DBMS_OUTPUT.PUT_LINE('  if(nav&&getComputedStyle(nav).position==="sticky") navh=nav.offsetHeight;');
    DBMS_OUTPUT.PUT_LINE('  bd.style.setProperty("--navh",navh+"px");');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("section").forEach(function(sec){');
    DBMS_OUTPUT.PUT_LINE('    var h=sec.querySelector(":scope > h2");');
    DBMS_OUTPUT.PUT_LINE('    sec.style.setProperty("--h2h",(h?h.offsetHeight:48)+"px");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var mt=null;');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",function(){');
    DBMS_OUTPUT.PUT_LINE('  if(mt) clearTimeout(mt);');
    DBMS_OUTPUT.PUT_LINE('  mt=setTimeout(measure,120);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('measure();');
    DBMS_OUTPUT.PUT_LINE('setTimeout(measure,300);');
    DBMS_OUTPUT.PUT_LINE('/* ---- P3: cross-links -- hide a link whose target does not exist, reveal a linked row ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("a.xlink").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('  var id=(a.getAttribute("href")||"").slice(1);');
    DBMS_OUTPUT.PUT_LINE('  if(!id||!doc.getElementById(id)) a.hidden=true;');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var nl=nav?nav.querySelector(".narr-link"):null;');
    DBMS_OUTPUT.PUT_LINE('if(nl&&doc.querySelector("#narrative-slot .narr")) nl.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('function revealHash(){');
    DBMS_OUTPUT.PUT_LINE('  var id=(location.hash||"").slice(1).split("!")[0]; if(!id) return;');
    DBMS_OUTPUT.PUT_LINE('  var el=doc.getElementById(id); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  if(bd.classList.contains("normal")&&!inNormal(el)){ setMode(true,true); setTimeout(function(){ el.scrollIntoView({block:"start"}); },30); }');
    DBMS_OUTPUT.PUT_LINE('  var tr=closest(el,"tr");');
    DBMS_OUTPUT.PUT_LINE('  if(tr&&tr.hasAttribute("data-tail")){');
    DBMS_OUTPUT.PUT_LINE('    var tb=closest(tr,"table");');
    DBMS_OUTPUT.PUT_LINE('    if(tb&&!tb.classList.contains("open")){');
    DBMS_OUTPUT.PUT_LINE('      tb.classList.add("open");');
    DBMS_OUTPUT.PUT_LINE('      var ex=tb.id?doc.querySelector(".expander[data-for=\""+tb.id+"\"]"):null;');
    DBMS_OUTPUT.PUT_LINE('      if(ex) ex.textContent="\u25BE Hide "+(ex.getAttribute("data-n")||"")+" "+(ex.getAttribute("data-noun")||"rows");');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('    tr.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var tp=closest(el,".tabpanel");');
    DBMS_OUTPUT.PUT_LINE('  if(tp&&!tp.classList.contains("on")){');
    DBMS_OUTPUT.PUT_LINE('    var t=doc.querySelector(".tabs[data-tabs=\""+tp.getAttribute("data-tabs")+"\"] [data-t=\""+tp.getAttribute("data-t")+"\"]");');
    DBMS_OUTPUT.PUT_LINE('    if(t) t.click();');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var dt=closest(el,"details"); while(dt){ dt.open=true; dt=dt.parentNode?closest(dt.parentNode,"details"):null; }');
    DBMS_OUTPUT.PUT_LINE('  var hi=tr||el; hi.classList.add("jump-hi"); setTimeout(function(){hi.classList.remove("jump-hi");},1600);');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(fitTables,60);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("hashchange",revealHash);');
    DBMS_OUTPUT.PUT_LINE('if(location.hash) setTimeout(revealHash,0);');
    DBMS_OUTPUT.PUT_LINE('/* ---- P3: shareable view state in the hash (#anchor!v=f&tab=CPU&w=3) ---- */');
    DBMS_OUTPUT.PUT_LINE('function stateStr(){');
    DBMS_OUTPUT.PUT_LINE('  var v=[]; if(bd.classList.contains("full")) v.push("f");');
    DBMS_OUTPUT.PUT_LINE('  var parts=[]; if(v.length) parts.push("v="+v.join(","));');
    DBMS_OUTPUT.PUT_LINE('  var tab=doc.querySelector(".tabs[data-tabs=\"topsql\"] [data-t].on");');
    DBMS_OUTPUT.PUT_LINE('  if(tab&&tab.getAttribute("data-t")!=="ELAPSED") parts.push("tab="+tab.getAttribute("data-t"));');
    DBMS_OUTPUT.PUT_LINE('  if(curW!==null&&curW!==undefined) parts.push("w="+curW);');
    DBMS_OUTPUT.PUT_LINE('  return parts.join("&");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var stTimer=null;');
    DBMS_OUTPUT.PUT_LINE('function pushState(){');
    DBMS_OUTPUT.PUT_LINE('  if(stTimer) clearTimeout(stTimer);');
    DBMS_OUTPUT.PUT_LINE('  stTimer=setTimeout(function(){');
    DBMS_OUTPUT.PUT_LINE('    var h=location.hash||"", anchor=h.slice(1).split("!")[0], st=stateStr();');
    DBMS_OUTPUT.PUT_LINE('    var nh=(anchor||st)?("#"+anchor+(st?"!"+st:"")):"";');
    DBMS_OUTPUT.PUT_LINE('    if(nh!==h){ try{ history.replaceState(null,"",location.pathname+location.search+nh); }catch(e){} }');
    DBMS_OUTPUT.PUT_LINE('  },60);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function applyState(){');
    DBMS_OUTPUT.PUT_LINE('  var h=location.hash||"", i=h.indexOf("!"); if(i<0) return;');
    DBMS_OUTPUT.PUT_LINE('  var q={}; h.slice(i+1).split("&").forEach(function(kv){var p=kv.split("="); if(p[0]) q[p[0]]=decodeURIComponent(p[1]||"");});');
    DBMS_OUTPUT.PUT_LINE('  var v=(q.v||"").split(",");');
    DBMS_OUTPUT.PUT_LINE('  if(v.indexOf("f")>=0&&!bd.classList.contains("full")) setMode(true,true);');
    DBMS_OUTPUT.PUT_LINE('  if(q.tab){ var t=doc.querySelector(".tabs[data-tabs=\"topsql\"] [data-t=\""+q.tab+"\"]"); if(t&&!t.classList.contains("on")) t.click(); }');
    DBMS_OUTPUT.PUT_LINE('  if(q.w!==undefined&&q.w!==""){ curW=String(q.w); applyW(); }');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){ if(closest(ev.target,".tabs [data-t]")) pushState(); });');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("awr:window",pushState);');
    DBMS_OUTPUT.PUT_LINE('applyState();');
    DBMS_OUTPUT.PUT_LINE('/* ---- P5: on phones the Top SQL detail tables open by default (the bump chart is unreadable there) ---- */');
    DBMS_OUTPUT.PUT_LINE('if(doc.documentElement.clientWidth<=700){ doc.querySelectorAll("#topsql .tabpanel > details").forEach(function(d){ d.open=true; }); }');
    DBMS_OUTPUT.PUT_LINE('/* ---- P4: keyboard-operable tabs, sortable headers and window chips; table captions ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table:not([data-nosort]) thead th").forEach(function(th){');
    DBMS_OUTPUT.PUT_LINE('  th.setAttribute("scope","col");');
    DBMS_OUTPUT.PUT_LINE('  if(!th.hasAttribute("tabindex")) th.setAttribute("tabindex","0");');
    DBMS_OUTPUT.PUT_LINE('  th.setAttribute("role","button");');
    DBMS_OUTPUT.PUT_LINE('  if(!th.getAttribute("title")) th.setAttribute("title",th.hasAttribute("data-w")?"Highlight this window everywhere":"Sort by this column");');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table[data-nosort] thead th").forEach(function(th){ th.setAttribute("scope","col"); });');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  if(tb.querySelector("caption")) return;');
    DBMS_OUTPUT.PUT_LINE('  var sec=closest(tb,"section"), h2=sec?sec.querySelector(":scope > h2"):null;');
    DBMS_OUTPUT.PUT_LINE('  var p=tb.parentNode&&tb.parentNode.classList.contains("tblwrap")?tb.parentNode:tb, h3=null, x=p.previousElementSibling;');
    DBMS_OUTPUT.PUT_LINE('  while(x&&!h3){ if(x.tagName==="H3") h3=x; else if(x.tagName==="TABLE"||x.classList.contains("tblwrap")) break; x=x.previousElementSibling; }');
    DBMS_OUTPUT.PUT_LINE('  var t=(h2?(h2.firstChild&&h2.firstChild.textContent||h2.textContent):"").trim();');
    DBMS_OUTPUT.PUT_LINE('  if(h3) t+=" \u2014 "+(h3.textContent||"").trim();');
    DBMS_OUTPUT.PUT_LINE('  if(!t) return;');
    DBMS_OUTPUT.PUT_LINE('  var c=doc.createElement("caption"); c.className="sr-only"; c.textContent=t; tb.insertBefore(c,tb.firstChild);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target;');
    DBMS_OUTPUT.PUT_LINE('  if(closest(t,".tabs [data-t]")){');
    DBMS_OUTPUT.PUT_LINE('    var tabs=Array.prototype.slice.call(closest(t,".tabs").querySelectorAll("[data-t]")), i=tabs.indexOf(closest(t,"[data-t]")), j=-1;');
    DBMS_OUTPUT.PUT_LINE('    if(ev.key==="ArrowRight") j=(i+1)%tabs.length; else if(ev.key==="ArrowLeft") j=(i-1+tabs.length)%tabs.length;');
    DBMS_OUTPUT.PUT_LINE('    else if(ev.key==="Home") j=0; else if(ev.key==="End") j=tabs.length-1;');
    DBMS_OUTPUT.PUT_LINE('    if(j>=0){ ev.preventDefault(); tabs[j].click(); tabs[j].focus(); }');
    DBMS_OUTPUT.PUT_LINE('    return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if((ev.key==="Enter"||ev.key===" ")&&t&&t.tagName==="TH"&&t.getAttribute("role")==="button"){ ev.preventDefault(); t.click(); }');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- P4: tap-to-pin tooltip for title-only data (touch / keyboard) ---- */');
    DBMS_OUTPUT.PUT_LINE('var tipEl=null;');
    DBMS_OUTPUT.PUT_LINE('function hideTip(){ if(tipEl&&tipEl.parentNode) tipEl.parentNode.removeChild(tipEl); tipEl=null; }');
    DBMS_OUTPUT.PUT_LINE('function showTip(t){');
    DBMS_OUTPUT.PUT_LINE('  var txt=t.getAttribute("title"); if(!txt) return;');
    DBMS_OUTPUT.PUT_LINE('  hideTip(); tipEl=doc.createElement("div"); tipEl.className="tip"; tipEl.setAttribute("role","status"); tipEl.textContent=txt;');
    DBMS_OUTPUT.PUT_LINE('  bd.appendChild(tipEl);');
    DBMS_OUTPUT.PUT_LINE('  var r=t.getBoundingClientRect(), cw=doc.documentElement.clientWidth;');
    DBMS_OUTPUT.PUT_LINE('  tipEl.style.top=(window.scrollY+r.bottom+6)+"px";');
    DBMS_OUTPUT.PUT_LINE('  tipEl.style.left=Math.max(8,Math.min(window.scrollX+r.left,window.scrollX+cw-tipEl.offsetWidth-8))+"px";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  if(closest(ev.target,".tip")) return;');
    DBMS_OUTPUT.PUT_LINE('  var t=closest(ev.target,"[title]");');
    DBMS_OUTPUT.PUT_LINE('  if(!t||closest(ev.target,"a,button,summary,input,select,th,.tabs,.wchip,tr.sql-row")||!closest(t,"section,header.report")){ hideTip(); return; }');
    DBMS_OUTPUT.PUT_LINE('  showTip(t);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){ if(ev.key==="Escape") hideTip(); });');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("scroll",function(){ if(tipEl) hideTip(); },{passive:true});');
    DBMS_OUTPUT.PUT_LINE('/* ---- keyboard: Cmd/Ctrl-K focus filter, Esc clears, J / K jump ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target||{}, tag=(t.tagName||"").toLowerCase();');
    DBMS_OUTPUT.PUT_LINE('  var typing=(tag==="input"||tag==="textarea"||tag==="select"||t.isContentEditable);');
    DBMS_OUTPUT.PUT_LINE('  if((ev.metaKey||ev.ctrlKey)&&(ev.key==="k"||ev.key==="K")){');
    DBMS_OUTPUT.PUT_LINE('    ev.preventDefault(); if(fi){ fi.focus(); fi.select(); } return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if(ev.key==="Escape"){');
    DBMS_OUTPUT.PUT_LINE('    clearW(); closeView();');
    DBMS_OUTPUT.PUT_LINE('    if(fi&&fi.value){ fi.value=""; applyFilter(); }');
    DBMS_OUTPUT.PUT_LINE('    if(typing&&t.blur) t.blur();');
    DBMS_OUTPUT.PUT_LINE('    if(nav) nav.classList.remove("menu-open");');
    DBMS_OUTPUT.PUT_LINE('    return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if(typing||ev.metaKey||ev.ctrlKey||ev.altKey) return;');
    DBMS_OUTPUT.PUT_LINE('  if(ev.key==="j"||ev.key==="J"){ ev.preventDefault(); jump(1); }');
    DBMS_OUTPUT.PUT_LINE('  else if(ev.key==="k"||ev.key==="K"){ ev.preventDefault(); jump(-1); }');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('</script>');
    -- Phase 4: the report body is one <main> landmark (display:contents,
    -- so the body flex layout is unchanged); closed in awr_trend.sql.
    DBMS_OUTPUT.PUT_LINE('<main id="main-start">');

    -- Temporary CLOBs are session-lived and will free at end-of-session,
    -- but free explicitly so the report can be regenerated in a loop
    -- without leaking locators.
    DBMS_LOB.FREETEMPORARY(v_times_json);
    DBMS_LOB.FREETEMPORARY(v_vals_json);
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 00_params END -->'); END;
/
