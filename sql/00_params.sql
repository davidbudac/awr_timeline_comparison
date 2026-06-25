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
        n_prior       NUMBER
    );
    TYPE mover_t IS TABLE OF mover_rec INDEX BY PLS_INTEGER;

    v_scored     mover_t;
    v_top        mover_t;
    v_n_movers   PLS_INTEGER := 0;
    v_n_usable   PLS_INTEGER := 0;
    v_max_n      NUMBER      := 0;

    v_clean_name VARCHAR2(160);
    v_pct_cls    VARCHAR2(8);
    v_pct_txt    VARCHAR2(24);
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
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / dur_sec
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, dur_sec, stat_name
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
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / dur_sec / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, dur_sec, wait_class
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
    scored AS (
        SELECT metric_domain, metric_name,
               CASE
                   WHEN cur_val IS NULL OR mu IS NULL THEN NULL
                   WHEN n < 3                         THEN NULL
                   WHEN sd IS NULL OR sd = 0          THEN NULL
                   ELSE (cur_val - mu) / sd
               END AS z_score,
               CASE
                   WHEN cur_val IS NULL OR mu IS NULL OR mu = 0 THEN NULL
                   ELSE (cur_val - mu) / ABS(mu) * 100
               END AS pct_delta,
               n AS n_prior
        FROM   pivoted
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    )
    SELECT metric_domain, metric_name, z_score, pct_delta, n_prior
    BULK COLLECT INTO v_scored
    FROM   scored
    ORDER  BY ABS(NVL(z_score, 0)) DESC, metric_name;

    -- Single pass: count movers above |z| > 2, remember max n_prior
    -- (for the "vs prior N windows" phrasing), and slice the top 3
    -- into v_top in the same |z| DESC order produced by the SQL.
    FOR i IN 1 .. v_scored.COUNT LOOP
        IF NVL(v_scored(i).n_prior, 0) > v_max_n THEN
            v_max_n := v_scored(i).n_prior;
        END IF;
        IF v_scored(i).z_score IS NOT NULL THEN
            v_n_usable := v_n_usable + 1;
            IF ABS(v_scored(i).z_score) > 2 THEN
                v_n_movers := v_n_movers + 1;
                IF v_top.COUNT < 3 THEN
                    v_top(v_top.COUNT + 1) := v_scored(i);
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
            || '<span class="body">no metric moved beyond |z| &gt; 2 vs the prior '
            || TO_CHAR(v_max_n) || ' window'
            || CASE WHEN v_max_n = 1 THEN '' ELSE 's' END
            || '.</span>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  <div class="verdict v-crit">');
        DBMS_OUTPUT.PUT_LINE('    <span class="label">Verdict</span>');
        DBMS_OUTPUT.PUT_LINE('    <a href="#findings" class="lede crit">'
            || v_n_movers || ' mover'
            || CASE WHEN v_n_movers = 1 THEN '' ELSE 's' END
            || '</a>'
            || ' <span class="sep">/</span> '
            || '<span class="body">vs prior ' || TO_CHAR(v_max_n) || ' window'
            || CASE WHEN v_max_n = 1 THEN '' ELSE 's' END
            || '</span>');

        FOR i IN 1 .. v_top.COUNT LOOP
            v_clean_name := REGEXP_REPLACE(v_top(i).metric_name, '^Wait class: ', '');
            IF LENGTH(v_clean_name) > 36 THEN
                v_clean_name := SUBSTR(v_clean_name, 1, 34) || '&hellip;';
            END IF;

            IF v_top(i).pct_delta IS NULL THEN
                v_pct_cls := 'up';
                v_pct_txt := '&mdash;';
            ELSE
                v_pct_cls := CASE WHEN v_top(i).pct_delta >= 0 THEN 'up' ELSE 'down' END;
                v_pct_txt := TO_CHAR(v_top(i).pct_delta,
                                     'FMS999990',
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
    IF v_n_movers > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  <details class="movers-all">');
        DBMS_OUTPUT.PUT_LINE('    <summary>All ' || v_n_movers || ' mover'
            || CASE WHEN v_n_movers = 1 THEN '' ELSE 's' END
            || ' &middot; |z| &gt; 2</summary>');
        DBMS_OUTPUT.PUT_LINE('    <ul class="movers-list">');
        FOR i IN 1 .. v_scored.COUNT LOOP
            IF v_scored(i).z_score IS NOT NULL
               AND ABS(v_scored(i).z_score) > 2 THEN
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

                IF v_scored(i).pct_delta IS NULL THEN
                    v_pct_cls := 'up';
                    v_pct_txt := '&mdash;';
                ELSE
                    v_pct_cls := CASE WHEN v_scored(i).pct_delta >= 0
                                      THEN 'up' ELSE 'down' END;
                    v_pct_txt := TO_CHAR(v_scored(i).pct_delta, 'FMS999990',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
                END IF;

                DBMS_OUTPUT.PUT_LINE('      <li>'
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
        || '</span>'
        || '</div>');
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
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var red=cs.getPropertyValue("--red").trim()||"#e2231a";');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('var bandCurrent="rgba(226,35,26,0.22)", bandPrior="rgba(100,116,139,0.10)";');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=(d.windows||[]).map(function(w){return [');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[0],itemStyle:{color:w[2]==="current"?bandCurrent:bandPrior},');
    DBMS_OUTPUT.PUT_LINE('   label:{show:true,position:"insideTop",color:mu,fontSize:9,formatter:w[2],distance:1}},');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[1]}];});');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  animation:false,');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('    valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(1)+" s";}},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:0,right:0,top:12,bottom:18,containLabel:false},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.times,boundaryGap:false,');
    DBMS_OUTPUT.PUT_LINE('    axisLine:{show:false},axisTick:{show:false},');
    DBMS_OUTPUT.PUT_LINE('    axisLabel:{color:mu,fontSize:9,hideOverlap:true,showMinLabel:true,showMaxLabel:true,');
    DBMS_OUTPUT.PUT_LINE('      interval:Math.max(0,Math.floor(d.times.length/8))}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",show:false},');
    DBMS_OUTPUT.PUT_LINE('  series:[{');
    DBMS_OUTPUT.PUT_LINE('    name:"DB time",type:"line",smooth:true,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('    data:d.vals,');
    DBMS_OUTPUT.PUT_LINE('    lineStyle:{width:1.2,color:red},');
    DBMS_OUTPUT.PUT_LINE('    areaStyle:{color:"rgba(226,35,26,0.06)"},');
    DBMS_OUTPUT.PUT_LINE('    markArea:{silent:true,data:markAreaData,itemStyle:{opacity:1},z:0},');
    DBMS_OUTPUT.PUT_LINE('    markLine:(window.AWR_markLine&&window.AWR_markLine(d.times))||{data:[]},');
    DBMS_OUTPUT.PUT_LINE('    z:5');
    DBMS_OUTPUT.PUT_LINE('  }]');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- =========================================================
    -- Sticky table-of-contents nav. Same anchor IDs the dense
    -- design used; numerals match the per-section h2::before
    -- counters in _style.sql.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
        || '<b>Sections</b>'
        || '<a href="#db-time-summary">01 DB time</a>'
        || '<a href="#overview">02 Overview</a>'
        || '<a href="#utilization">03 Utilization</a>'
        || '<a href="#ash-timeline">04 ASH timeline</a>'
        || '<a href="#waits-fg">05 FG waits</a>'
        || '<a href="#waits-bg">06 BG waits</a>'
        || '<a href="#topsql">07 Top SQL</a>'
        || '<a href="#segment-io">08 Segment I/O</a>'
        || '<a href="#file-io">09 File I/O</a>'
        || '<a href="#findings">10 Findings</a>'
        || '<a href="#windows">11 Windows</a>'
        || '<a href="#load">12 Load profile</a>'
        || '<a href="#metrics">13 Metrics</a>'
        || '<a href="#topsql-ash">14 Top SQL ASH</a>'
        || '<a href="#param-changes">15 Parameters</a>'
        -- "Application only" toggle: flips body.app-only, which (via
        -- _style.sql) hides every system-wide section plus the masthead
        -- verdict / DB-time strip and the Oracle-internal SQL rows, leaving
        -- just application SQL and its related data on screen.
        || '<button type="button" id="app-filter-toggle" class="app-filter"'
        || ' aria-pressed="false"'
        || ' title="Hide system-wide sections and Oracle-internal SQL;'
        || ' show only application SQL and its related data">'
        || 'Application only</button>'
        || '</nav>');

    -- Wire the toggle. Toggling body.app-only does all the section/row
    -- hiding in CSS; the custom awr:appfilter event lets charts that
    -- aggregate many SQLs into one canvas (section 06's bump chart) re-render
    -- with the Oracle-internal series dropped. Per-SQL charts need no JS:
    -- their container card/details is hidden wholesale by CSS.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('var btn=document.getElementById("app-filter-toggle"); if(!btn) return;');
    DBMS_OUTPUT.PUT_LINE('btn.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('  var on=document.body.classList.toggle("app-only");');
    DBMS_OUTPUT.PUT_LINE('  btn.classList.toggle("active",on);');
    DBMS_OUTPUT.PUT_LINE('  btn.setAttribute("aria-pressed",on?"true":"false");');
    DBMS_OUTPUT.PUT_LINE('  btn.textContent=on?"Show all":"Application only";');
    DBMS_OUTPUT.PUT_LINE('  document.dispatchEvent(new CustomEvent("awr:appfilter",{detail:{appOnly:on}}));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- Temporary CLOBs are session-lived and will free at end-of-session,
    -- but free explicitly so the report can be regenerated in a loop
    -- without leaking locators.
    DBMS_LOB.FREETEMPORARY(v_times_json);
    DBMS_LOB.FREETEMPORARY(v_vals_json);
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 00_params END -->'); END;
/
