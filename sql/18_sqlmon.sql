--
-- 18_sqlmon.sql
-- SQL Monitor summaries: per-sql_id comparison across the compared windows,
-- an execution scatter over the full span, and narrative-feeding flags --
-- all from DBA_HIST_REPORTS' persisted "sqlmonitor" report_summary XML. This
-- section reads only DBA_HIST_REPORTS.report_summary (a VARCHAR2 XML) --
-- never DBA_HIST_REPORTS_DETAILS (the multi-KB per-execution plan CLOB).
--
-- Plan-hash awareness: the per-statement table's "Plan hash" column compares
-- the plan_hash of the Current window's slowest execution against the most
-- frequent (dominant) plan_hash across the prior valid windows, and flags a
-- mismatch with a "plan changed" badge -- see the cur_plan/prior_plan CTEs
-- below and metric_policy-independent score_cells() call for the row.
--
-- Template-INDEPENDENT (like 13-16): SQL Monitor coverage doesn't depend on
-- which triage template the caller picked. Always on, no DEFINE -- unlike
-- section 16 (profile_days), this section still renders (with a one-line
-- note) when there is nothing to show, because "SQL Monitor persisted
-- nothing this run" is itself useful information, not a feature the caller
-- opted out of.
--
-- Source: DBA_HIST_REPORTS WHERE component_name = 'sqlmonitor'. key1 =
-- sql_id, key2 = sql_exec_id, key3 = sql_exec_start as the STRING
-- 'MM:DD:YYYY HH24:MI:SS' (numeric-only, so NLS-safe; parsed with an
-- explicit TO_DATE mask, never trusted as a DATE). report_summary is a
-- VARCHAR2 XML parsed via XMLTABLE (see the base_execs CTE below for the
-- exact column list). dbid is the CDB dbid, so dbid IN (dbid_list) applies
-- unchanged; instance_number/con filtering follows every other section.
--
-- Noise floor (sql_id level): a sql_id is included in the comparison table
-- only if ANY of its captured executions across the full span has
-- elapsed_time >= 1,000,000 microseconds (1 s), OR status = 'DONE (ERROR)',
-- OR more than one distinct non-zero plan_hash appears in the span. All
-- executions of an included sql_id are then aggregated (no per-execution
-- floor -- a tiny DOP-2 execution of an otherwise-expensive statement still
-- counts). This keeps the table from being 90% tiny parallel emagent noise
-- on a lightly-loaded instance while never hiding a real regression. The
-- caption states the raw captured-execution count vs. the count actually
-- shown. The execution SCATTER chart plots every captured execution in the
-- full span regardless of the floor (capped at 3,000 most-recent points) --
-- the floor only shapes the summary table and its ranking.
--
-- Window attribution: an execution is attributed to a compared window by
-- its parsed sql_exec_start (key3) falling in [win_start_ts, win_end_ts) of
-- a *valid* row from sql/lib/windows_cte.sql's windows_rollup (same
-- valid-only convention as the cumulative-counter sections 02-08). An
-- execution outside every window (or inside a skipped one) still appears in
-- the full-span scatter but is excluded from the per-window table numbers.
--
-- Scoring: max elapsed time, Current vs. prior *valid* windows, using
-- section 07's `scored` CASE verbatim (z-score / %-delta / change bucket),
-- via the shared sql/lib/score_cells.plsql function.
--
-- Sampling caveats (also stated in the section's caption -- see
-- design/SQLMON_DESIGN.md "Sampling caveats"): only completed, "expensive
-- enough" or parallel executions are ever persisted by MMON's SQL Monitor
-- repository capture policy, so absence of a sql_id here does NOT mean it
-- ran fast, and row counts are not execution-rate counts (never read `n` as
-- a throughput number). An execution still running at target_end has no
-- final report yet, so the Current window can under-report its slowest
-- statement. Attribution is by execution START time, so a long-running
-- execution can be attributed to a window it only partly overlaps.
--
-- Read-only: two independent SELECTs (one feeds the per-sql_id table, one
-- feeds the scatter payload), both bounded by the resolved window span and
-- dbid IN (dbid_list). No scratch table, no DBA_HIST_REPORTS_DETAILS access.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 18_sqlmon BEGIN -->'); END;
/

DECLARE
    v_top_n       NUMBER := ~top_n;
    v_weeks_back  NUMBER := ~weeks_back;

    v_span_start  DATE;
    v_span_end    DATE;

    v_raw_total   NUMBER := 0;
    v_shown_total NUMBER := 0;
    v_sqlid_count NUMBER := 0;
    v_tail_cnt    NUMBER := 0;
    v_nocur_cnt   NUMBER := 0;
    v_normal      BOOLEAN := FALSE;   -- section opted into the Summary view
    v_any_row     BOOLEAN := FALSE;
    v_n_pchg      PLS_INTEGER := 0;   -- Current-window statements: plan changed /
    v_n_dop       PLS_INTEGER := 0;   -- DOP downgrade / an error (library row text)
    v_n_err       PLS_INTEGER := 0;

    v_header      VARCHAR2(32767);   -- one th (about 45 bytes) per window
    v_row         VARCHAR2(32767);
    v_flags       VARCHAR2(400);
    v_plancell    VARCHAR2(400);

    v_windows_json    VARCHAR2(32767);
    v_weeks_iso_json  VARCHAR2(4000);
    v_top_ids_json    VARCHAR2(4000);

    -- Scatter payload: up to 3000 points, each a small JSON object, so a
    -- CLOB accumulator (like section 09's ASH hour grid) keeps this well
    -- clear of PL/SQL's 32767-byte VARCHAR2 cap.
    v_points_clob CLOB;
    v_pt_buf      VARCHAR2(2000);
    v_first_pt    BOOLEAN := TRUE;
    v_points_total  NUMBER := 0;
    v_points_shown  NUMBER := 0;
    v_capped        VARCHAR2(1) := 'N';
    -- v1.6.0 Timeline: SQL Monitor rows of the SQL lane (a plan change or
    -- a DOP downgrade on a Current-window statement, at most three), each
    -- placed under its Top SQL row when 06 emitted one
    TYPE t_tl_rows IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    v_tl            t_tl_rows;
    v_tl_csv        VARCHAR2(4000);
    v_tl_b          VARCHAR2(40);
    -- v1.6.0 Summary: the plan-change cards ("What changed around it"),
    -- one per plan-changed statement with a Current-window execution in
    -- the top N (at most three), buffered during the table loop
    TYPE t_pc_rec IS RECORD (
        sql_id     VARCHAR2(13),
        usr        VARCHAR2(128),
        modl       VARCHAR2(64),
        prior_ph   NUMBER,
        cur_ph     NUMBER,
        cur_val    NUMBER,
        mu         NUMBER,
        sd         NUMBER,
        n_prior    NUMBER,
        rnk        NUMBER,
        detail_csv VARCHAR2(32767),
        ela_csv    VARCHAR2(4000));
    TYPE t_pc_tab IS TABLE OF t_pc_rec INDEX BY PLS_INTEGER;
    v_pc            t_pc_tab;

    @@sql/lib/metric_policy.plsql
    @@sql/lib/nth_csv.plsql
    @@sql/lib/json_escape.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/score_cells.plsql
    @@sql/lib/is_oracle_schema.plsql
    @@sql/lib/put_clob_chunked.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="sqlmon" class="vw in-s in-a lib" style="--os:2"><h2>SQL Monitor'
        || '<small class="h2sub">Captured executions per statement; a sample, not every execution</small></h2>');

    ------------------------------------------------------------------
    -- Resolve the full compared span (earliest window start .. target_end),
    -- shared by both the table cursor and the scatter cursor below.
    ------------------------------------------------------------------
    SELECT MIN(win_start_ts), MAX(win_end_ts)
    INTO   v_span_start, v_span_end
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts, win_end_ts FROM windows_rollup
    );

    SELECT COUNT(*)
    INTO   v_raw_total
    FROM   dba_hist_reports r
    WHERE  r.component_name = 'sqlmonitor'
      AND  r.dbid IN (~dbid_list)
      AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
      AND  r.report_summary IS NOT NULL
      AND  r.key1 IS NOT NULL
      AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
      AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
      AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
      AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end;

    IF v_raw_total = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
            || 'No SQL Monitor reports persisted in the compared windows '
            || '(' || TO_CHAR(CAST(v_span_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
            || ' &rarr; ' || TO_CHAR(CAST(v_span_end AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
            || '). SQL Monitor only persists completed executions that ran long enough '
            || 'or in parallel. Try a wider <code>win_hours</code>, more <code>weeks_back</code>, or a busier <code>target_end</code>.</p>'
            || lib_ls('sqlmon', 'nothing persisted in the compared windows') || '</section>');
        -- The closing AWR-SECTION marker is emitted by this file's own
        -- trailing block, so nothing else to do here.
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- Per-sql_id comparison table.
    ------------------------------------------------------------------
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        base_execs AS (
            SELECT r.report_id, r.key1 AS sql_id, r.instance_number,
                   TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                   x.status, x.username, x.module, x.plan_hash,
                   x.px_req, x.px_alloc,
                   NVL(x.elapsed_us, 0) AS elapsed_us,
                   NVL(x.read_bytes, 0) + NVL(x.write_bytes, 0) AS io_bytes
            FROM   dba_hist_reports r,
                   XMLTABLE('/report_repository_summary/sql'
                       PASSING XMLTYPE(r.report_summary)
                       COLUMNS
                           status   VARCHAR2(30)  PATH 'status',
                           username VARCHAR2(128) PATH 'user',
                           module   VARCHAR2(64)  PATH 'module',
                           plan_hash NUMBER       PATH 'plan_hash',
                           px_req   NUMBER        PATH 'px_servers_requested',
                           px_alloc NUMBER        PATH 'px_servers_allocated',
                           elapsed_us NUMBER      PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]',
                           read_bytes  NUMBER     PATH 'stats[@type="monitor"]/stat[@name="read_bytes"]',
                           write_bytes NUMBER     PATH 'stats[@type="monitor"]/stat[@name="write_bytes"]'
                   ) x
            WHERE  r.component_name = 'sqlmonitor'
              AND  r.dbid IN (~dbid_list)
              AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
              AND  r.report_summary IS NOT NULL
              AND  r.key1 IS NOT NULL
              AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
              AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
              AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
              AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end
        ),
        with_offset AS (
            SELECT e.*, wr.week_offset
            FROM   base_execs e
            LEFT JOIN windows_rollup wr
                ON  wr.valid_flag = 'Y'
               AND  e.exec_start >= wr.win_start_ts
               AND  e.exec_start <  wr.win_end_ts
        ),
        sqlid_span_stats AS (
            SELECT sql_id,
                   MAX(CASE WHEN elapsed_us >= 1000000 THEN 1 ELSE 0 END) AS has_long,
                   MAX(CASE WHEN status = 'DONE (ERROR)' THEN 1 ELSE 0 END) AS has_error,
                   COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) AS distinct_plans,
                   MAX(CASE WHEN px_alloc < px_req THEN 1 ELSE 0 END) AS has_downgrade,
                   COUNT(*) AS total_execs,
                   MAX(elapsed_us) / 1e6 AS span_max_all,
                   MAX(username) KEEP (DENSE_RANK LAST ORDER BY exec_start) AS last_username,
                   MAX(module)   KEEP (DENSE_RANK LAST ORDER BY exec_start) AS last_module
            FROM   with_offset
            GROUP BY sql_id
        ),
        included AS (
            SELECT sql_id FROM sqlid_span_stats
            WHERE  has_long = 1 OR has_error = 1 OR distinct_plans > 1
        ),
        -- "new" = no capture anywhere in the span BEFORE the Current window
        -- starts (not merely "absent from the prior compared windows": with
        -- sparse capture a statement can easily miss a 1-h slot on every
        -- prior day yet run all week, and calling that "first seen" would
        -- be exactly the sampling trap the caption warns about).
        cur_start AS (
            SELECT MIN(win_start_ts) AS ts FROM windows_rollup WHERE week_offset = 0
        ),
        new_flag AS (
            SELECT w.sql_id,
                   CASE WHEN SUM(CASE WHEN w.week_offset = 0 THEN 1 ELSE 0 END) > 0
                         AND SUM(CASE WHEN w.exec_start < c.ts THEN 1 ELSE 0 END) = 0
                        THEN 'Y' ELSE 'N' END AS is_new
            FROM   with_offset w CROSS JOIN cur_start c
            GROUP BY w.sql_id
        ),
        -- Per-window plan_hash list: distinct non-zero hashes seen in that
        -- window, most frequent first, capped at 5 with a trailing ellipsis
        -- when more were seen. Feeds per_window.plan_list below (replaces
        -- the plain distinct-count "Plans" column).
        window_plan_counts AS (
            SELECT sql_id, week_offset, plan_hash, COUNT(*) AS cnt
            FROM   with_offset
            WHERE  week_offset IS NOT NULL AND plan_hash <> 0
              AND  sql_id IN (SELECT sql_id FROM included)
            GROUP BY sql_id, week_offset, plan_hash
        ),
        window_plan_ranked AS (
            SELECT sql_id, week_offset, plan_hash,
                   ROW_NUMBER() OVER (PARTITION BY sql_id, week_offset
                       ORDER BY cnt DESC, plan_hash) AS rn,
                   COUNT(*) OVER (PARTITION BY sql_id, week_offset) AS total_plans
            FROM   window_plan_counts
        ),
        window_plan_agg AS (
            SELECT sql_id, week_offset,
                   LISTAGG(TO_CHAR(plan_hash), ' ') WITHIN GROUP (ORDER BY rn)
                       || CASE WHEN MAX(total_plans) > 5 THEN '&hellip;' ELSE '' END AS plan_list
            FROM   window_plan_ranked
            WHERE  rn <= 5
            GROUP BY sql_id, week_offset
        ),
        per_window AS (
            SELECT wo.sql_id, wo.week_offset,
                   COUNT(*) AS n,
                   MAX(wo.elapsed_us) / 1e6    AS max_elapsed_s,
                   MEDIAN(wo.elapsed_us) / 1e6 AS median_elapsed_s,
                   MAX(wo.io_bytes)   AS max_io_bytes,
                   MAX(wo.px_req)     AS max_px_req,
                   MAX(wo.px_alloc)   AS max_px_alloc,
                   MAX(wpa.plan_list) AS plan_list,
                   SUM(CASE WHEN wo.status = 'DONE (ERROR)' THEN 1 ELSE 0 END) AS err_cnt
            FROM   with_offset wo
            LEFT JOIN window_plan_agg wpa
                   ON wpa.sql_id = wo.sql_id AND wpa.week_offset = wo.week_offset
            WHERE  wo.week_offset IS NOT NULL
              AND  wo.sql_id IN (SELECT sql_id FROM included)
            GROUP BY wo.sql_id, wo.week_offset
        ),
        pivoted AS (
            SELECT sql_id,
                   MAX(CASE WHEN week_offset = 0 THEN max_elapsed_s END) AS cur_val,
                   AVG(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS mu,
                   STDDEV(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS sd,
                   COUNT(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS n_prior,
                   MAX(max_elapsed_s) AS span_max
            FROM   per_window
            GROUP BY sql_id
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT i.sql_id, w.week_offset, pw.n, pw.max_elapsed_s, pw.median_elapsed_s,
                   pw.max_io_bytes, pw.max_px_req, pw.max_px_alloc, pw.plan_list, pw.err_cnt
            FROM   included i CROSS JOIN all_weeks w
            LEFT JOIN per_window pw
                   ON pw.sql_id = i.sql_id AND pw.week_offset = w.week_offset
        ),
        per_sql_csv AS (
            SELECT sql_id,
                   -- ','||token + SUBSTR: LISTAGG drops a NULL measure (and
                   -- its delimiter) outright, which would left-compact the
                   -- CSV and misalign the positional per-week slots.
                   SUBSTR(LISTAGG(',' || TO_CHAR(max_elapsed_s, 'FM99999999990D000000',
                                                 'NLS_NUMERIC_CHARACTERS=''.,'''))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2)  AS elapsed_asc_csv,
                   SUBSTR(LISTAGG(',' || TO_CHAR(max_elapsed_s, 'FM99999999990D000000',
                                                 'NLS_NUMERIC_CHARACTERS=''.,'''))
                       WITHIN GROUP (ORDER BY week_offset DESC), 2) AS elapsed_spark_csv,
                   -- Composite per-window slot: every field NVL'd to '' first,
                   -- so the joined string itself is never NULL and plain
                   -- LISTAGG (no fold trick needed) never drops a slot; split
                   -- back out with REGEXP_SUBSTR('[^^]*', ...) at render time.
                   -- About 40 bytes a captured window (more with several
                   -- plans), so a statement SQL Monitor caught in most of
                   -- 100+ windows passes SQL's 4000-byte LISTAGG limit: ON
                   -- OVERFLOW TRUNCATE drops whole slots from the END -- the
                   -- OLDEST windows, the order is Current first -- and ends
                   -- on an empty slot, so those windows render as "not
                   -- captured" instead of ORA-01489 aborting the run.
                   LISTAGG(
                       NVL(TO_CHAR(n), '') || '^' ||
                       NVL(TO_CHAR(median_elapsed_s, 'FM99999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,'''), '') || '^' ||
                       NVL(TO_CHAR(max_io_bytes), '') || '^' ||
                       NVL(TO_CHAR(max_px_req), '') || '^' ||
                       NVL(TO_CHAR(max_px_alloc), '') || '^' ||
                       NVL(plan_list, '') || '^' ||
                       NVL(TO_CHAR(err_cnt), ''),
                       ',' ON OVERFLOW TRUNCATE '^^^^^^' WITHOUT COUNT)
                       WITHIN GROUP (ORDER BY week_offset ASC) AS detail_csv
            FROM   grid
            GROUP BY sql_id
        ),
        slowest_cur AS (
            SELECT sql_id, report_id,
                   ROW_NUMBER() OVER (PARTITION BY sql_id
                       ORDER BY elapsed_us DESC NULLS LAST, report_id) AS rn
            FROM   with_offset WHERE week_offset = 0
        ),
        slowest_any AS (
            SELECT sql_id, report_id,
                   ROW_NUMBER() OVER (PARTITION BY sql_id
                       ORDER BY elapsed_us DESC NULLS LAST, report_id) AS rn
            FROM   with_offset
        ),
        drill AS (
            SELECT i.sql_id,
                   NVL((SELECT sc.report_id FROM slowest_cur sc
                        WHERE sc.sql_id = i.sql_id AND sc.rn = 1),
                       (SELECT sa.report_id FROM slowest_any sa
                        WHERE sa.sql_id = i.sql_id AND sa.rn = 1)) AS drill_report_id
            FROM   included i
        ),
        -- Plan-hash column: cur_plan is the plan_hash of the Current
        -- window's slowest execution (falling back to the most-frequent
        -- non-zero plan_hash in the Current window when that execution's
        -- own plan_hash is 0); prior_plan is the most-frequent non-zero
        -- plan_hash across the prior VALID windows (tie -> most recent).
        cur_plan AS (
            SELECT sql_id, plan_hash AS cur_plan_hash
            FROM (
                SELECT sql_id, plan_hash,
                       ROW_NUMBER() OVER (PARTITION BY sql_id
                           ORDER BY CASE WHEN plan_hash <> 0 THEN 0 ELSE 1 END,
                                    elapsed_us DESC NULLS LAST, report_id) AS rn
                FROM   with_offset
                WHERE  week_offset = 0
            )
            WHERE  rn = 1 AND plan_hash <> 0
        ),
        prior_plan_counts AS (
            SELECT sql_id, plan_hash, COUNT(*) AS cnt, MAX(exec_start) AS last_ts
            FROM   with_offset
            WHERE  week_offset > 0 AND plan_hash <> 0
            GROUP BY sql_id, plan_hash
        ),
        prior_plan AS (
            SELECT sql_id, plan_hash AS prior_plan_hash
            FROM (
                SELECT sql_id, plan_hash,
                       ROW_NUMBER() OVER (PARTITION BY sql_id
                           ORDER BY cnt DESC, last_ts DESC) AS rn
                FROM   prior_plan_counts
            )
            WHERE  rn = 1
        )
        SELECT s.sql_id, st.last_username, st.last_module,
               st.distinct_plans, st.has_downgrade, st.has_error, st.total_execs,
               NVL(nf.is_new, 'N') AS is_new,
               p.cur_val, p.mu, p.sd, p.n_prior, p.span_max,
               c.elapsed_asc_csv, c.elapsed_spark_csv, c.detail_csv,
               d.drill_report_id,
               cp.cur_plan_hash, pp.prior_plan_hash,
               CASE WHEN cp.cur_plan_hash IS NOT NULL AND pp.prior_plan_hash IS NOT NULL
                         AND cp.cur_plan_hash <> pp.prior_plan_hash THEN 'Y' ELSE 'N' END AS plan_changed,
               ROW_NUMBER() OVER (ORDER BY p.cur_val DESC NULLS LAST,
                                  st.span_max_all DESC NULLS LAST, s.sql_id) AS rnk,
               COUNT(*) OVER () AS total_sqlids
        FROM   included s
        JOIN   sqlid_span_stats st ON st.sql_id = s.sql_id
        -- LEFT: a statement whose every capture sits in a skipped window
        -- (or outside all windows) has no per-window row at all, but it
        -- still cleared the floor (e.g. it errored) -- keep it, with empty
        -- window cells, so its flags and drill line are not lost.
        LEFT JOIN pivoted p        ON p.sql_id  = s.sql_id
        JOIN   per_sql_csv c       ON c.sql_id  = s.sql_id
        JOIN   drill d             ON d.sql_id  = s.sql_id
        LEFT JOIN new_flag nf      ON nf.sql_id = s.sql_id
        LEFT JOIN cur_plan   cp    ON cp.sql_id = s.sql_id
        LEFT JOIN prior_plan pp    ON pp.sql_id = s.sql_id
        ORDER BY rnk
    ) LOOP
        IF NOT v_any_row THEN
            v_any_row     := TRUE;
            v_sqlid_count := s.total_sqlids;

            DBMS_OUTPUT.PUT_LINE('<h3>Per-statement comparison (top ' || v_top_n || ')</h3>');
            v_header := '<thead><tr><th>SQL ID</th><th>User / module</th>'
                || '<th title="plan_hash_value of the slowest Current-window execution; '
                || 'prior = the most frequent plan in the prior compared windows">Plan hash</th>'
                || '<th class="num" data-w="0">Current max elapsed (s)</th>'
                || band_head
                || '<th class="trend">Trend</th>'
                || '<th class="num">Prior mean (s)</th>'
                || '<th>Flags</th></tr></thead>';
            -- data-nosort: every statement row is paired with a detail row right
            -- below it, so click-to-sort would tear the pairs apart;
            -- data-notools: a CSV/MD export of that pairing would be junk.
            DBMS_OUTPUT.PUT_LINE('<table id="sqlmon-pool" data-nosort data-notools>' || v_header || '<tbody>');
        END IF;

        v_shown_total := v_shown_total + NVL(s.total_execs, 0);

        v_flags := '';
        IF s.plan_changed = 'Y' THEN
            v_flags := v_flags || '<span class="chip" title="Current plan differs from the prior windows'' dominant plan">plan changed</span> ';
        ELSIF s.distinct_plans > 1 THEN
            v_flags := v_flags || '<span class="chip" title="more than one execution plan seen in the compared span">plan change</span> ';
        END IF;
        IF s.has_downgrade = 1 THEN
            v_flags := v_flags || '<span class="chip" title="an execution got fewer parallel servers than requested">DOP downgrade</span> ';
        END IF;
        IF s.has_error = 1 THEN
            v_flags := v_flags || '<span class="chip" title="at least one execution ended DONE (ERROR)">error</span> ';
        END IF;
        IF s.is_new = 'Y' THEN
            v_flags := v_flags || '<span class="chip" title="no captured execution anywhere in the span before the Current window">new</span> ';
        END IF;
        -- Summary view: an error or a DOP downgrade on a statement that ran
        -- in the Current window opens the section's row of the evidence
        -- library (a plan change has its own card in "What changed around
        -- it"); plain slow-vs-baseline rows leave it shut.
        IF s.cur_val IS NOT NULL AND s.rnk <= v_top_n
           AND (s.has_error = 1 OR s.has_downgrade = 1)
           AND NOT v_normal THEN
            v_normal := TRUE;
            DBMS_OUTPUT.PUT_LINE('<script>document.getElementById("sqlmon").classList.add("lopen");</script>');
        END IF;
        IF s.cur_val IS NOT NULL THEN
            IF s.plan_changed = 'Y' THEN v_n_pchg := v_n_pchg + 1; END IF;
            IF s.has_downgrade = 1 THEN v_n_dop := v_n_dop + 1; END IF;
            IF s.has_error = 1 THEN v_n_err := v_n_err + 1; END IF;
        END IF;

        -- Phase 5: a statement with no Current-window execution folds under
        -- the expander too (its flags / drill still survive there).
        IF s.rnk > v_top_n OR s.cur_val IS NULL THEN
            v_tail_cnt := v_tail_cnt + 1;
            IF s.cur_val IS NULL THEN v_nocur_cnt := v_nocur_cnt + 1; END IF;
        END IF;
        v_plancell := CASE
            WHEN s.plan_changed = 'Y' THEN
                '<span class="badge warn" title="plan changed vs. the prior windows'' dominant plan">plan changed</span> <s>'
                || TO_CHAR(s.prior_plan_hash) || '</s> &rarr; <b>' || TO_CHAR(s.cur_plan_hash) || '</b>'
            WHEN s.cur_plan_hash IS NOT NULL THEN
                TO_CHAR(s.cur_plan_hash)
                || CASE WHEN s.distinct_plans > 1 AND s.cur_plan_hash = s.prior_plan_hash
                        THEN ' <span class="badge note" title="another plan was also seen in the span">+other</span>'
                        ELSE '' END
            WHEN s.prior_plan_hash IS NOT NULL THEN
                '<span style="color:var(--muted)">' || TO_CHAR(s.prior_plan_hash) || '</span>'
            ELSE '&mdash;'
        END;

        -- entity anchor sm-<sql_id> (sql/lib/anchor_id.plsql's rule; a
        -- sql_id is already lower-case [0-9a-z], so the slug is the id)
        v_row := '<tr id="sm-' || s.sql_id || '" data-sys="' || is_oracle_schema(s.last_username) || '"'
            || CASE WHEN s.rnk > v_top_n OR s.cur_val IS NULL THEN ' data-tail="Y" hidden' ELSE '' END
            || '>'
            || '<td class="mono">' || s.sql_id
            || ' <a class="xlink" href="#sql-' || s.sql_id
            || '" title="This SQL in the Top SQL pool">&#8599; Top SQL</a></td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(s.last_username, '?'))
                || ' / ' || DBMS_XMLGEN.CONVERT(NVL(s.last_module, '?')) || '</td>'
            || '<td class="mono">' || v_plancell || '</td>'
            || '<td class="num" data-w="0"' || fmt_num_title(s.cur_val) || '><b>'
                || fmt_num(s.cur_val) || '</b></td>'
            || score_cells(s.cur_val, s.mu, s.sd, s.n_prior)
            || '<td class="trend" data-spark="' || NVL(s.elapsed_spark_csv, '')
                || '" data-spark-title="max elapsed (s), ' || s.sql_id || '"></td>'
            || '<td class="num">' || fmt_num(s.mu) || '</td>'
            || '<td>' || v_flags || '</td>'
            || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);

        -- Paired detail row: native <details> per-window sub-table + the
        -- copyable SQL Monitor Active Report drill line (C4 codewrap/copy-btn
        -- markup, same pattern as sql/01_windows.sql's AWR-report listing).
        DBMS_OUTPUT.PUT_LINE('<tr class="sqlmon-detail" data-sys="' || is_oracle_schema(s.last_username) || '"'
            || CASE WHEN s.rnk > v_top_n OR s.cur_val IS NULL THEN ' data-tail="Y" hidden' ELSE '' END
            || '><td colspan="11">');
        DBMS_OUTPUT.PUT_LINE('<details><summary>Per-window detail &amp; drill</summary>');
        v_header := '<table data-notools><thead><tr><th>Window</th><th class="num">n</th>'
            || '<th class="num">Max elapsed (s)</th><th class="num">Median elapsed (s)</th>'
            || '<th class="num" title="largest read + write bytes of one execution">Max I/O (bytes)</th>'
            || '<th class="num" title="parallel servers requested / allocated (max per execution)">DOP req/alloc</th>'
            || '<th title="distinct plan_hash_values in the window, most frequent first">Plan hash(es)</th>'
            || '<th class="num" title="executions that ended DONE (ERROR)">Errors</th></tr></thead><tbody>';
        DBMS_OUTPUT.PUT_LINE(v_header);
        FOR k IN 0 .. v_weeks_back LOOP
            DECLARE
                -- Token k of the '^'-joined slot: the pattern always consumes
                -- the delimiter, so an empty field never yields a zero-length
                -- match that would shift every later occurrence by one
                -- (a bare '[^^]*' does exactly that).
                v_slot  VARCHAR2(400) := nth_csv(s.detail_csv, k + 1);
                v_n_s   VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 1), '^');
                v_med_s VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 2), '^');
                v_io_s  VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 3), '^');
                v_dr_s  VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 4), '^');
                v_da_s  VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 5), '^');
                v_pl_s  VARCHAR2(80)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 6), '^');
                v_er_s  VARCHAR2(40)  := RTRIM(REGEXP_SUBSTR(v_slot || '^', '[^^]*\^', 1, 7), '^');
                v_me_s  VARCHAR2(40)  := nth_csv(s.elapsed_asc_csv, k + 1);
                v_label VARCHAR2(20)  := CASE WHEN k = 0 THEN 'Current'
                    ELSE '&minus;' || off_label(k) END;
            BEGIN
                DBMS_OUTPUT.PUT_LINE('<tr' || CASE WHEN k = 0 THEN ' class="cur"' ELSE '' END || '>'
                    || '<td data-w="' || k || '">' || v_label || '</td>'
                    || '<td class="num">' || fmt_int(TO_NUMBER(NULLIF(v_n_s, ''))) || '</td>'
                    || '<td class="num">'
                        || fmt_num(TO_NUMBER(NULLIF(v_me_s, ''), 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''')) || '</td>'
                    || '<td class="num">'
                        || fmt_num(TO_NUMBER(NULLIF(v_med_s, ''), 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''')) || '</td>'
                    || '<td class="num">' || fmt_num(TO_NUMBER(NULLIF(v_io_s, ''))) || '</td>'
                    || '<td class="num">'
                        || CASE WHEN v_dr_s IS NULL OR v_dr_s = '' THEN '&mdash;'
                                ELSE fmt_int(TO_NUMBER(v_dr_s)) || '/' || fmt_int(TO_NUMBER(NULLIF(v_da_s, '')))
                                     || CASE WHEN TO_NUMBER(NULLIF(v_da_s,'')) < TO_NUMBER(v_dr_s)
                                             THEN ' <span class="badge warn">downgrade</span>' ELSE '' END
                           END
                        || '</td>'
                    || '<td class="mono">' || CASE WHEN v_pl_s IS NULL OR v_pl_s = ''
                            THEN '&mdash;' ELSE v_pl_s END || '</td>'
                    || '<td class="num">'
                        || CASE WHEN TO_NUMBER(NULLIF(v_er_s, '')) > 0
                                THEN '<span class="badge crit">' || v_er_s || '</span>'
                                ELSE fmt_int(TO_NUMBER(NULLIF(v_er_s, ''))) END
                        || '</td>'
                    || '</tr>');
            END;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');

        DBMS_OUTPUT.PUT_LINE('<div class="codewrap" style="position:relative">');
        DBMS_OUTPUT.PUT_LINE('<button type="button" class="copy-btn" '
            || 'data-copy="#sqlmon-drill-' || s.sql_id || '">Copy</button>');
        DBMS_OUTPUT.PUT_LINE('<pre id="sqlmon-drill-' || s.sql_id || '" class="sql">'
            || DBMS_XMLGEN.CONVERT('SELECT DBMS_AUTO_REPORT.REPORT_REPOSITORY_DETAIL(rid=>'
               || TO_CHAR(s.drill_report_id) || ', type=>''ACTIVE'') FROM dual;')
            || '</pre></div>');
        DBMS_OUTPUT.PUT_LINE('</details></td></tr>');

        -- v1.6.0 Summary: buffer a plan-change card (emitted after the table)
        IF s.plan_changed = 'Y' AND s.cur_val IS NOT NULL AND s.rnk <= v_top_n
           AND v_pc.COUNT < 3 THEN
            v_pc(v_pc.COUNT + 1).sql_id := s.sql_id;
            v_pc(v_pc.COUNT).usr        := s.last_username;
            v_pc(v_pc.COUNT).modl       := s.last_module;
            v_pc(v_pc.COUNT).prior_ph   := s.prior_plan_hash;
            v_pc(v_pc.COUNT).cur_ph     := s.cur_plan_hash;
            v_pc(v_pc.COUNT).cur_val    := s.cur_val;
            v_pc(v_pc.COUNT).mu         := s.mu;
            v_pc(v_pc.COUNT).sd         := s.sd;
            v_pc(v_pc.COUNT).n_prior    := s.n_prior;
            v_pc(v_pc.COUNT).rnk        := s.rnk;
            v_pc(v_pc.COUNT).detail_csv := s.detail_csv;
            v_pc(v_pc.COUNT).ela_csv    := s.elapsed_asc_csv;
        END IF;

        -- v1.6.0 Timeline: max elapsed per window, scored like the table
        IF s.cur_val IS NOT NULL AND v_tl.COUNT < 3
           AND (s.plan_changed = 'Y' OR s.has_downgrade = 1) THEN
            v_tl_csv := tl_csv(s.elapsed_spark_csv);
            v_tl_b   := score_bucket(s.cur_val, s.mu, s.sd, s.n_prior);
            v_tl(v_tl.COUNT + 1) := tl_bars(v_tl_csv, s.mu, s.sd, v_tl_b,
                tl_lab(ent('SQL Monitor', anchor_id('sm', s.sql_id), 'sql'),
                       s.sql_id || ', max elapsed'),
                tl_gut(s.cur_val, s.mu, s.sd, v_tl_b,
                       CASE WHEN s.plan_changed = 'Y' THEN '<span class="z"><b>&#9670;</b> new plan</span>'
                            ELSE '<span class="z"><b>&#9661;</b> DOP</span>' END),
                'tl-' || anchor_id('sm', s.sql_id), 'q sub', s.sql_id || ', SQL Monitor max elapsed', 's',
                0, CASE WHEN s.plan_changed = 'Y'
                        THEN '<b class="glf gp" title="Plan changed: ' || TO_CHAR(s.prior_plan_hash)
                             || ' &rarr; ' || TO_CHAR(s.cur_plan_hash) || '">&#9670;</b>'
                        ELSE '<b class="glf gd" title="DOP downgrade on a Current-window execution">&#9661;</b>' END,
                'tl-' || anchor_id('sq-elapsed', s.sql_id));
        END IF;
    END LOOP;

    IF v_any_row THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        IF v_tail_cnt > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<span class="expander" data-for="sqlmon-pool" data-n="'
                || v_tail_cnt || '" data-noun="more statements'
                || CASE WHEN v_nocur_cnt > 0
                        THEN ' (' || v_nocur_cnt || ' without a Current-window execution)'
                        ELSE '' END || '">'
                || '&#9656; Show ' || v_tail_cnt || ' more statements'
                || CASE WHEN v_nocur_cnt > 0
                        THEN ' (' || v_nocur_cnt || ' without a Current-window execution)'
                        ELSE '' END || '</span>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:11px;color:var(--muted);margin:6px 0 0">'
            || fmt_int(v_raw_total) || ' execution' || CASE WHEN v_raw_total = 1 THEN '' ELSE 's' END
            || ' captured in the compared span; ' || fmt_int(v_shown_total)
            || ' across ' || v_sqlid_count || ' statement'
            || CASE WHEN v_sqlid_count = 1 THEN '' ELSE 's' END
            || ' met the inclusion floor (elapsed &ge; 1&nbsp;s, an error, or more than one '
            || 'execution plan) and are shown above.</p>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
            || fmt_int(v_raw_total) || ' execution' || CASE WHEN v_raw_total = 1 THEN '' ELSE 's'
            END || ' captured in the compared span, but none met the inclusion floor '
            || '(elapsed &ge; 1&nbsp;s, an error, or more than one execution plan). '
            || 'The scatter below still plots every captured execution.</p>');
    END IF;
    -- the Timeline rows ride after the table (never inside a <tbody>)
    FOR i IN 1 .. v_tl.COUNT LOOP
        DBMS_OUTPUT.PUT_LINE(CASE WHEN i = 1 THEN tl_open('sql') END || v_tl(i)
            || CASE WHEN i = v_tl.COUNT THEN tl_close END);
    END LOOP;

    ------------------------------------------------------------------
    -- v1.6.0 Summary: one plan-change card per buffered statement (a
    -- Current-window execution in the top N whose plan differs from the
    -- prior windows' dominant plan).  Findings are recomputed, not
    -- shared: the plan per window is this section's own per-window plan
    -- list (the most frequent non-zero plan_hash captured in the window,
    -- carried forward over windows with no capture), the bars are the
    -- statement's elapsed seconds per VALID window from one bounded
    -- DBA_HIST_SQLSTAT read (06's window join, this sql_id only; SQL
    -- Monitor's max elapsed when AWR kept no SQLSTAT row for Current),
    -- and the header band is this table's own scored max elapsed.  Top SQL
    -- stays ranked, not scored: the SQLSTAT evidence rows carry a plain
    -- Delta and a hollow (unscored) dot.  Emitted hidden and moved into
    -- 07's #changes-slot (like 12's configuration card, which follows).
    ------------------------------------------------------------------
    FOR c IN 1 .. v_pc.COUNT LOOP
        DECLARE
            TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
            v_id     VARCHAR2(13) := v_pc(c).sql_id;
            v_cid    VARCHAR2(40) := 'f-plan-' || v_pc(c).sql_id;
            v_pairs  VARCHAR2(4000);
            v_ea     t_num;
            v_ca     t_num;
            v_ga     t_num;
            v_ta     t_num;
            v_e_cur  NUMBER;
            v_c_cur  NUMBER;
            v_g_cur  NUMBER;
            v_t_cur  NUMBER;
            v_e_mu   NUMBER;
            v_e_sd   NUMBER;
            v_c_mu   NUMBER;
            v_c_sd   NUMBER;
            v_g_mu   NUMBER;
            v_t_mu   NUMBER;
            v_src    VARCHAR2(8) := 'sqlstat';
            v_z      NUMBER;
            v_b      VARCHAR2(40);
            v_first  PLS_INTEGER;
            v_ph     VARCHAR2(40);
            v_prev   VARCHAR2(40);
            v_lvl    VARCHAR2(2);
            v_start  BOOLEAN;
            v_cells  VARCHAR2(32767);
            v_ev     VARCHAR2(32767);
            v_tok    VARCHAR2(200);

            FUNCTION a_mean(a t_num) RETURN NUMBER IS
                v_s NUMBER := 0;
            BEGIN
                IF a.COUNT = 0 THEN RETURN NULL; END IF;
                FOR i IN 1 .. a.COUNT LOOP v_s := v_s + a(i); END LOOP;
                RETURN v_s / a.COUNT;
            END a_mean;

            -- sample standard deviation (n - 1), NULL below two values
            FUNCTION a_sd(a t_num, p_mu NUMBER) RETURN NUMBER IS
                v_s NUMBER := 0;
            BEGIN
                IF a.COUNT < 2 THEN RETURN NULL; END IF;
                FOR i IN 1 .. a.COUNT LOOP v_s := v_s + (a(i) - p_mu) * (a(i) - p_mu); END LOOP;
                RETURN SQRT(v_s / (a.COUNT - 1));
            END a_sd;

            -- one evidence row (07's ev_row shape); p_plain 'Y' = ranked,
            -- not scored: plain Delta, hollow dot
            FUNCTION pc_ev(p_dt VARCHAR2, p_idt VARCHAR2, p_de VARCHAR2,
                           p_cur NUMBER, p_mu NUMBER, p_sd NUMBER,
                           p_bucket VARCHAR2, p_plain VARCHAR2,
                           p_band VARCHAR2 DEFAULT 'Y') RETURN VARCHAR2 IS
            BEGIN
                -- plain-text values (class "txt", as the spec's plan card);
                -- a value and its unit never part at a line break
                RETURN '<div class="evr"><dt>' || p_dt || '</dt><dd><span class="id txt">'
                    || REGEXP_REPLACE(p_idt, '([0-9]) ', '\1&nbsp;')
                    || '</span><span class="de">' || REGEXP_REPLACE(p_de, '([0-9]) ', '\1&nbsp;')
                    || '</span></dd>'
                    || '<div class="m"' || CASE WHEN p_plain = 'Y' THEN ' title="Ranked, not scored"' END || '>'
                    || delta_span(p_cur, p_mu, p_bucket, p_plain)
                    || CASE WHEN p_band = 'Y' THEN band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm') END
                    || '</div></div>';
            END pc_ev;
        BEGIN
            FOR r IN (
                WITH
                @@sql/lib/windows_cte.sql
                SELECT w.week_offset,
                       SUM(NVL(s.elapsed_time_delta, 0)) / 1e6 AS ela_s,
                       SUM(NVL(s.cpu_time_delta, 0)) / 1e6     AS cpu_s,
                       SUM(NVL(s.executions_delta, 0))         AS execs,
                       SUM(NVL(s.buffer_gets_delta, 0))        AS gets
                FROM   valid_windows w
                JOIN   dba_hist_sqlstat s
                    ON s.dbid = w.dbid
                   AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                   AND s.instance_number = w.instance_number
                WHERE  s.sql_id = v_id
                GROUP BY w.week_offset
                ORDER BY w.week_offset
            ) LOOP
                v_pairs := v_pairs || CASE WHEN v_pairs IS NOT NULL THEN ';' END
                    || r.week_offset || ':' || wg_tok(r.ela_s);
                IF r.week_offset = 0 THEN
                    v_e_cur := r.ela_s;
                    v_c_cur := r.cpu_s;
                    IF r.execs > 0 THEN
                        v_g_cur := r.gets / r.execs;
                        v_t_cur := r.ela_s * 1000 / r.execs;
                    END IF;
                ELSE
                    v_ea(v_ea.COUNT + 1) := r.ela_s;
                    v_ca(v_ca.COUNT + 1) := r.cpu_s;
                    IF r.execs > 0 THEN
                        v_ga(v_ga.COUNT + 1) := r.gets / r.execs;
                        v_ta(v_ta.COUNT + 1) := r.ela_s * 1000 / r.execs;
                    END IF;
                END IF;
            END LOOP;
            v_e_mu := a_mean(v_ea);  v_e_sd := a_sd(v_ea, v_e_mu);
            v_c_mu := a_mean(v_ca);  v_c_sd := a_sd(v_ca, v_c_mu);
            v_g_mu := a_mean(v_ga);  v_t_mu := a_mean(v_ta);
            IF v_e_cur IS NULL THEN
                -- AWR kept no SQLSTAT row for the Current window: draw SQL
                -- Monitor's max elapsed per window instead (ASC CSV, token
                -- k + 1 = window k)
                v_src := 'sqlmon';
                v_pairs := NULL;
                FOR k IN 0 .. v_weeks_back LOOP
                    v_tok := nth_csv(v_pc(c).ela_csv, k + 1);
                    IF v_tok IS NOT NULL THEN
                        v_pairs := v_pairs || CASE WHEN v_pairs IS NOT NULL THEN ';' END
                            || k || ':' || wg_tok(TO_NUMBER(v_tok));
                    END IF;
                END LOOP;
                v_e_cur := v_pc(c).cur_val;
                v_e_mu  := v_pc(c).mu;
                v_e_sd  := v_pc(c).sd;
            END IF;
            v_z := band_z(v_pc(c).cur_val, v_pc(c).mu, v_pc(c).sd);
            v_b := score_bucket(v_pc(c).cur_val, v_pc(c).mu, v_pc(c).sd, v_pc(c).n_prior);

            -- the plan step line, oldest first; v_first = the window the
            -- Current plan took over (its release flag, if any, is named)
            FOR k IN REVERSE 0 .. v_weeks_back LOOP
                v_tok := nth_csv(v_pc(c).detail_csv, k + 1);
                v_ph := REGEXP_SUBSTR(RTRIM(REGEXP_SUBSTR(v_tok || '^', '[^^]*\^', 1, 6), '^'), '[0-9]+');
                IF v_ph IS NULL THEN v_ph := v_prev; END IF;
                -- the Current cell is the Plan hash column's plan (the
                -- slowest Current execution's), not the window's most
                -- frequent one
                IF k = 0 THEN v_ph := TO_CHAR(v_pc(c).cur_ph); END IF;
                v_start := v_ph IS NOT NULL AND (v_prev IS NULL OR v_ph <> v_prev);
                IF v_ph = TO_CHAR(v_pc(c).cur_ph) AND (v_prev IS NULL OR v_prev <> v_ph) THEN
                    v_first := k;
                END IF;
                IF v_ph IS NULL THEN
                    v_cells := v_cells || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                        || '" data-w="' || k || '"></div>';
                ELSE
                    v_lvl := CASE WHEN v_ph = TO_CHAR(v_pc(c).prior_ph) THEN 'lo' ELSE 'hi' END;
                    v_cells := v_cells || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                        || '" data-w="' || k || '"><i class="st ' || v_lvl
                        || CASE WHEN v_start AND v_prev IS NOT NULL THEN ' rise' END || '" aria-hidden="true"></i>'
                        || CASE WHEN v_start AND v_prev IS NOT NULL THEN '<i class="nd" aria-hidden="true"></i>' END
                        || CASE WHEN v_start OR k = 0
                                THEN '<span class="pv ' || v_lvl || '" title="plan hash ' || v_ph || '">'
                                     || v_ph || '</span>' END
                        || '</div>';
                END IF;
                v_prev := v_ph;
            END LOOP;

            IF v_src = 'sqlstat' AND v_g_cur IS NOT NULL AND v_g_mu IS NOT NULL THEN
                v_ev := v_ev || pc_ev('Per exec',
                    fmt_num(v_g_cur) || ' gets, was ' || fmt_num(v_g_mu),
                    -- elapsed per execution in ms, or in s once either side reaches 1 s
                    CASE WHEN GREATEST(NVL(v_t_cur, 0), NVL(v_t_mu, 0)) >= 1000
                         THEN fmt_num(v_t_cur / 1000) || ' s, was ' || fmt_num(v_t_mu / 1000) || ' s'
                         ELSE fmt_num(v_t_cur) || ' ms, was ' || fmt_num(v_t_mu) || ' ms' END,
                    v_g_cur, v_g_mu, NULL, NULL, 'Y', 'N');
            END IF;
            v_ev := v_ev || pc_ev(ent('SQL Monitor', anchor_id('sm', v_id), 'sql'),
                'max ' || fmt_num(v_pc(c).cur_val) || ' s',
                'normal ' || fmt_num(v_pc(c).mu) || ' s',
                v_pc(c).cur_val, v_pc(c).mu, v_pc(c).sd, v_b, 'N');
            IF v_src = 'sqlstat' AND v_c_mu IS NOT NULL THEN
                v_ev := v_ev || pc_ev('CPU', fmt_num(v_c_cur) || ' s',
                    'normal ' || fmt_num(v_c_mu) || ' s'
                    || CASE WHEN v_e_mu IS NOT NULL AND v_e_cur > v_e_mu
                                 AND NVL(v_c_cur, 0) - v_c_mu <= 0.1 * (v_e_cur - v_e_mu)
                            THEN '; the rise is wait' END,
                    v_c_cur, v_c_mu, v_c_sd, NULL, 'Y');
            END IF;

            DBMS_OUTPUT.PUT_LINE('<article class="panel fc chg" id="' || v_cid
                || '" aria-labelledby="' || v_cid || '-h" hidden>'
                || '<header class="fc-h"><div class="fc-k"><span class="sv" title="SQL Monitor, #'
                || v_pc(c).rnk || ' by Current-window max elapsed"><b class="gk">&#9670;</b>Plan change</span></div>'
                || '<div class="fc-band" title="SQL Monitor max elapsed, z ' || band_ztxt(v_z)
                || ' against the prior normal">' || band_span(v_z, v_b, 'lg')
                || '<span class="bd-ax" aria-hidden="true"><em style="--x:.167">&minus;2</em>'
                || '<em style="--x:.333">0</em><em style="--x:.500">+2</em>'
                || '<em style="--x:.583">+3</em><em class="end" style="--x:1">+8&sigma;</em></span>'
                || '</div></header>');
            DBMS_OUTPUT.PUT_LINE('<h3 id="' || v_cid || '-h">'
                || ent('<code>' || v_id || '</code>', anchor_id('sq-elapsed', v_id), 'sql')
                || ' new plan' || CASE WHEN v_first > 0 THEN ' since ' || wg_date(v_first) END
                || CASE WHEN v_first < v_weeks_back
                        THEN '<span data-mk-at="' || v_first || '" data-mk-pre=" after " hidden></span>' END
                || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<div class="fc-b"><div class="fc-main">'
                || '<p class="whereln" title="plan ' || TO_CHAR(v_pc(c).prior_ph) || ' &rarr; '
                || TO_CHAR(v_pc(c).cur_ph) || '">'
                || DBMS_XMLGEN.CONVERT(NVL(v_pc(c).usr, '?')) || ' &middot; '
                || DBMS_XMLGEN.CONVERT(NVL(v_pc(c).modl, '?')) || '</p>'
                || '<div class="big"><span class="v">' || fmt_num(v_e_cur) || '</span>'
                || '<span class="u">' || CASE WHEN v_src = 'sqlstat' THEN 's elapsed'
                                              ELSE 's max elapsed (SQL Monitor)' END || '</span>'
                || '<span class="nrm" title="prior mean ' || fmt_num(v_e_mu) || ' s">normal '
                || fv_range(v_e_mu, v_e_sd, 's') || '</span></div>');
            DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
                || wg_bars(v_pairs, 1, v_e_mu, v_e_sd, NULL));
            DBMS_OUTPUT.PUT_LINE('<div class="r p" data-name="Plan hash" role="row">' || v_cells || '</div>'
                || wg_dates(TRUE) || '</div></div>');
            DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>'
                || '<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
                || anchor_id('sm', v_id) || '">Timeline &rarr;</a>'
                || '<span class="evl"><a href="#topsql">Top SQL</a><a href="#sqlmon">SQL Monitor</a></span>'
                || '</footer></article>');
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var s=document.getElementById("changes-slot"),'
                || 'c=document.getElementById("' || v_cid || '");if(!s||!c)return;s.appendChild(c);c.hidden=false;'
                || 'var x=document.getElementById("s-changes");if(x)x.hidden=false;})();</script>');
        END;
    END LOOP;

    ------------------------------------------------------------------
    -- Execution scatter over the full span.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<h3>Execution scatter (full compared span)</h3>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
        || 'Every captured execution, x = start time, y = elapsed (log scale). '
        || 'Diamond = error, triangle = a plan different from that sql_id''s most '
        || 'common plan, size &prop; requested DOP. Colored series are the top '
        || v_top_n || ' statements by Current-window max elapsed; grey = everything else.</p>');
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="sqlmon-scatter"></div>');

    -- Compared-window shading + marker-snap categories, same JSON shape as
    -- section 09's ASH timeline (calendar charts), sourced from
    -- windows_rollup so skipped windows render as grey "skipped" bands.
    -- Built in PL/SQL, not LISTAGG (about 50 bytes a window: SQL's
    -- 4000-byte LISTAGG limit would abort the run past about 78 windows).
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts, win_end_ts, valid_flag FROM windows_rollup
        ORDER BY week_offset DESC
    ) LOOP
        v_windows_json := v_windows_json || CASE WHEN v_windows_json IS NOT NULL THEN ',' END
            || '["' || TO_CHAR(r.win_start_ts, 'YYYY-MM-DD HH24:MI') || '","'
            || TO_CHAR(r.win_end_ts, 'YYYY-MM-DD HH24:MI') || '","'
            || CASE WHEN r.week_offset = 0 THEN 'current' ELSE 'w-' || r.week_offset END || '",'
            || CASE WHEN r.valid_flag = 'Y' THEN '"1"' ELSE '"0"' END || ']';
    END LOOP;
    v_windows_json := '[' || v_windows_json || ']';

    SELECT '[' || LISTAGG('"' || TO_CHAR(win_start_ts, 'YYYY-MM-DD HH24:MI') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset ASC) || ']'
    INTO   v_weeks_iso_json
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts FROM windows_rollup
    );

    -- Top-N sql_ids by Current-window max elapsed among the same
    -- noise-floor-included set as the table above (recomputed here rather
    -- than shared -- this section's own convention, mirrored from
    -- "findings are recomputed, not shared").
    v_top_ids_json := '[';
    FOR t IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        base_execs AS (
            SELECT r.key1 AS sql_id, r.instance_number,
                   TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                   x.status, x.plan_hash,
                   NVL(x.elapsed_us, 0) AS elapsed_us
            FROM   dba_hist_reports r,
                   XMLTABLE('/report_repository_summary/sql'
                       PASSING XMLTYPE(r.report_summary)
                       COLUMNS
                           status     VARCHAR2(30) PATH 'status',
                           plan_hash  NUMBER       PATH 'plan_hash',
                           elapsed_us NUMBER       PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]'
                   ) x
            WHERE  r.component_name = 'sqlmonitor'
              AND  r.dbid IN (~dbid_list)
              AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
              AND  r.report_summary IS NOT NULL
              AND  r.key1 IS NOT NULL
              AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
              AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
              AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
              AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end
        ),
        by_sql AS (
            SELECT be.sql_id,
                   MAX(CASE WHEN wr.week_offset = 0 THEN be.elapsed_us END) AS cur_elapsed,
                   MAX(be.elapsed_us) AS span_elapsed,
                   MAX(CASE WHEN be.elapsed_us >= 1000000 THEN 1 ELSE 0 END) AS has_long,
                   MAX(CASE WHEN be.status = 'DONE (ERROR)' THEN 1 ELSE 0 END) AS has_error,
                   COUNT(DISTINCT CASE WHEN be.plan_hash <> 0 THEN be.plan_hash END) AS distinct_plans
            FROM   base_execs be
            LEFT JOIN windows_rollup wr
                   ON wr.valid_flag = 'Y'
                  AND be.exec_start >= wr.win_start_ts
                  AND be.exec_start <  wr.win_end_ts
            GROUP BY be.sql_id
        )
        SELECT sql_id
        FROM   by_sql
        WHERE  has_long = 1 OR has_error = 1 OR distinct_plans > 1
        ORDER BY cur_elapsed DESC NULLS LAST, span_elapsed DESC
        FETCH FIRST ~top_n ROWS ONLY
    ) LOOP
        v_top_ids_json := v_top_ids_json || CASE WHEN v_top_ids_json = '[' THEN '' ELSE ',' END
            || '"' || json_escape(t.sql_id) || '"';
    END LOOP;
    v_top_ids_json := v_top_ids_json || ']';

    -- Points: every captured execution, capped to the most recent 3000.
    DBMS_LOB.CREATETEMPORARY(v_points_clob, TRUE);
    FOR p IN (
        -- ONE scan of dba_hist_reports: the per-sql_id mode plan (the
        -- plan_hash with the most captured executions, ties to the lowest
        -- hash, NULL when every capture has plan_hash 0) is an analytic
        -- over the same row set, not a second XML-parsing self-join.  The
        -- LEFT JOIN this replaced was pushed into a nested loop on dbmint
        -- (WRP$_REPORTS stats say 1 row), re-parsing every report's XML
        -- once per outer row -- 10+ minutes over a 4-week span.
        SELECT * FROM (
            SELECT be.sql_id, be.exec_start, be.elapsed_us, be.status,
                   be.plan_hash, be.px_req,
                   CASE WHEN be.mode_plan IS NOT NULL AND be.plan_hash <> 0
                             AND be.plan_hash <> be.mode_plan
                        THEN 'Y' ELSE 'N' END AS plan_mismatch,
                   ROW_NUMBER() OVER (ORDER BY be.exec_start DESC) AS rn_recent,
                   COUNT(*) OVER () AS n_total
            FROM (
                SELECT b.sql_id, b.exec_start, b.elapsed_us, b.status,
                       b.plan_hash, b.px_req,
                       MAX(CASE WHEN b.plan_hash <> 0 THEN b.plan_hash END)
                           KEEP (DENSE_RANK FIRST
                                 ORDER BY CASE WHEN b.plan_hash <> 0 THEN b.plan_cnt END DESC NULLS LAST,
                                          CASE WHEN b.plan_hash <> 0 THEN b.plan_hash END)
                           OVER (PARTITION BY b.sql_id) AS mode_plan
                FROM (
                    SELECT be0.*,
                           COUNT(*) OVER (PARTITION BY be0.sql_id, be0.plan_hash) AS plan_cnt
                    FROM (
                        SELECT r.key1 AS sql_id, r.instance_number,
                               TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                               x.status, x.plan_hash, x.px_req,
                               NVL(x.elapsed_us, 0) AS elapsed_us
                        FROM   dba_hist_reports r,
                               XMLTABLE('/report_repository_summary/sql'
                                   PASSING XMLTYPE(r.report_summary)
                                   COLUMNS
                                       status     VARCHAR2(30) PATH 'status',
                                       plan_hash  NUMBER       PATH 'plan_hash',
                                       px_req     NUMBER       PATH 'px_servers_requested',
                                       elapsed_us NUMBER       PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]'
                               ) x
                        WHERE  r.component_name = 'sqlmonitor'
                          AND  r.dbid IN (~dbid_list)
                          AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
                          AND  r.report_summary IS NOT NULL
                          AND  r.key1 IS NOT NULL
                          AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
                          AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
                          AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
                          AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end
                    ) be0
                ) b
            ) be
        )
        WHERE  rn_recent <= 3000
        ORDER  BY exec_start ASC
    ) LOOP
        v_points_total := p.n_total;
        v_points_shown := v_points_shown + 1;

        v_pt_buf := (CASE WHEN v_first_pt THEN '' ELSE ',' END)
            || '{"t":"' || TO_CHAR(p.exec_start, 'YYYY-MM-DD HH24:MI:SS') || '"'
            || ',"e":' || TO_CHAR(GREATEST(p.elapsed_us / 1e6, 0.0001), 'FM99999999990D0000',
                                  'NLS_NUMERIC_CHARACTERS=''.,''')
            || ',"id":"' || json_escape(p.sql_id) || '"'
            || ',"st":"' || json_escape(NVL(p.status, '?')) || '"'
            || ',"ph":' || NVL(TO_CHAR(p.plan_hash), '0')
            || ',"dop":' || NVL(TO_CHAR(p.px_req), '0')
            || ',"pm":"' || p.plan_mismatch || '"}';
        DBMS_LOB.WRITEAPPEND(v_points_clob, LENGTH(v_pt_buf), v_pt_buf);
        v_first_pt := FALSE;
    END LOOP;
    IF v_points_total > 3000 THEN
        v_capped := 'Y';
    END IF;

    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.sqlmon = {spanStart:"'
        || TO_CHAR(CAST(v_span_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || '",spanEnd:"' || TO_CHAR(CAST(v_span_end AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || '",topIds:' || v_top_ids_json
        || ',windows:' || v_windows_json
        || ',weeksIso:' || v_weeks_iso_json
        || ',capped:' || CASE WHEN v_capped = 'Y' THEN 'true' ELSE 'false' END
        || ',totalRaw:' || v_points_total
        || ',shown:' || v_points_shown
        || ',points:[');
    put_clob_chunked(v_points_clob);
    DBMS_OUTPUT.PUT_LINE(']};');
    IF v_capped = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('var el0=document.getElementById("sqlmon-scatter");');
        DBMS_OUTPUT.PUT_LINE('if(el0){var note=document.createElement("p");'
            || 'note.style.cssText="font-size:11px;color:var(--muted);margin:-2px 0 6px;font-style:italic";'
            || 'note.textContent="Capped to the most recent 3,000 of "+AWR_DATA.sqlmon.totalRaw+" captured executions.";'
            || 'el0.parentNode.insertBefore(note, el0);}');
    END IF;
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("sqlmon-scatter"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.sqlmon;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9"];');
    DBMS_OUTPUT.PUT_LINE('function ts(s){return Date.parse(String(s).replace(" ","T"));}');
    DBMS_OUTPUT.PUT_LINE('function sizeOf(dop){return Math.max(5,Math.min(18,5+2*(dop||1)));}');
    DBMS_OUTPUT.PUT_LINE('function symOf(pt){return pt.st==="DONE (ERROR)"?"diamond":(pt.pm==="Y"?"triangle":"circle");}');
    DBMS_OUTPUT.PUT_LINE('var groups={}; (d.points||[]).forEach(function(pt){');
    DBMS_OUTPUT.PUT_LINE('  var key=(d.topIds||[]).indexOf(pt.id)>=0?pt.id:"Other";');
    DBMS_OUTPUT.PUT_LINE('  (groups[key]=groups[key]||[]).push(pt);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var names=(d.topIds||[]).filter(function(id){return groups[id];});');
    DBMS_OUTPUT.PUT_LINE('if(groups["Other"]) names=names.concat(["Other"]);');
    -- Markers: this is a real time axis (not the category axis of 09/10),
    -- so a marker sits at its exact timestamp instead of snapping to the
    -- nearest window start as AWR_markLine would; same dashed style.
    DBMS_OUTPUT.PUT_LINE('function markersLine(){var ms=window.AWR_MARKERS||[];var lo=ts(d.spanStart),hi=ts(d.spanEnd);var ink=cs.getPropertyValue("--ink").trim()||"#333",paper=cs.getPropertyValue("--paper").trim()||"#fff";var data=[];ms.forEach(function(m){var t=ts(m.t);if(isNaN(t)||t<lo||t>hi)return;data.push({xAxis:t,label:{show:true,formatter:(function(l){return function(){return l;};})(m.label),rotate:90,position:"end",color:ink,fontSize:9,backgroundColor:paper,padding:[1,2,1,2],borderRadius:2,distance:3}});});if(!data.length)return null;return {symbol:["none","none"],silent:true,emphasis:{disabled:true},lineStyle:{type:"dashed",width:1,color:ink,opacity:0.75},data:data};}');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('function buildMarkAreas(hiSlot){return (d.windows||[]).map(function(w){var valid=w[3]!=="0";var hi=(hiSlot!=null)&&((hiSlot===0&&w[2]==="current")||("w-"+hiSlot===w[2]));var a={xAxis:ts(w[0]),itemStyle:{color:valid?(w[2]==="current"?"rgba(37,99,235,0.22)":"rgba(37,99,235,0.10)"):"rgba(148,163,175,0.12)",opacity:hi?1:(hiSlot!=null?0.35:1),borderColor:hi?fg:null,borderWidth:hi?1.5:0}};if(!valid){a.label={show:true,position:"insideTop",color:mu,fontSize:9,formatter:"skipped",distance:1};}return [a,{xAxis:ts(w[1])}];});}');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"item",formatter:function(p){var pt=p.data;return "<b>"+pt.id+"</b><br/>"+pt.t+"<br/>elapsed: "+(+pt.e).toFixed(2)+" s<br/>status: "+pt.st+"<br/>plan_hash: "+pt.ph+"<br/>DOP req: "+pt.dop;}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:56,right:20,top:16,bottom:44,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"time",axisLabel:{color:mu,fontSize:10}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"log",name:"elapsed (s)",nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  dataZoom:[{type:"inside"},{type:"slider",bottom:22,height:14,textStyle:{color:mu,fontSize:9}}],');
    DBMS_OUTPUT.PUT_LINE('  series:names.map(function(name,i){');
    DBMS_OUTPUT.PUT_LINE('    var pts=groups[name]||[];');
    DBMS_OUTPUT.PUT_LINE('    var color=name==="Other"?"#9AA3AD":palette[i%palette.length];');
    DBMS_OUTPUT.PUT_LINE('    var s={name:name,type:"scatter",');
    DBMS_OUTPUT.PUT_LINE('      symbolSize:function(v,p){return sizeOf(p.data.dop);},');
    DBMS_OUTPUT.PUT_LINE('      symbol:function(v,p){return p&&p.data?symOf(p.data):"circle";},');
    DBMS_OUTPUT.PUT_LINE('      itemStyle:{color:color,opacity:name==="Other"?0.35:0.85},');
    DBMS_OUTPUT.PUT_LINE('      emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('      data:pts.map(function(pt){return Object.assign({value:[ts(pt.t),+pt.e]},pt);})};');
    DBMS_OUTPUT.PUT_LINE('    if(i===0){');
    DBMS_OUTPUT.PUT_LINE('      s.markArea={silent:true,data:buildMarkAreas(null)};');
    DBMS_OUTPUT.PUT_LINE('      var ml=markersLine(); if(ml) s.markLine=ml;');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('    return s;');
    DBMS_OUTPUT.PUT_LINE('  })');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:theme",function(){var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888",gr2=c2.getPropertyValue("--border").trim()||"#e0e0e0";'
        || 'chart.setOption({legend:{textStyle:{color:fg2}},xAxis:{axisLabel:{color:mu2}},yAxis:{nameTextStyle:{color:mu2},axisLabel:{color:mu2},splitLine:{lineStyle:{color:gr2}}}});});');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:window",function(e){var w=e.detail?e.detail.w:null;chart.setOption({series:[{markArea:{data:buildMarkAreas(w)}}]});});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    DBMS_LOB.FREETEMPORARY(v_points_clob);

    -- the evidence library's row text (Summary view)
    DBMS_OUTPUT.PUT_LINE(lib_ls('sqlmon', fmt_int(v_raw_total) || ' captured execution'
        || CASE WHEN v_raw_total = 1 THEN '' ELSE 's' END
        || CASE WHEN v_n_pchg + v_n_dop + v_n_err = 0 THEN '; nothing unusual in Current'
                ELSE ';' || CASE WHEN v_n_pchg > 0 THEN ' <b>' || v_n_pchg || '</b> plan change'
                                                     || CASE WHEN v_n_pchg = 1 THEN '' ELSE 's' END END
                     || CASE WHEN v_n_dop > 0 THEN CASE WHEN v_n_pchg > 0 THEN ',' END || ' <b>' || v_n_dop
                                                     || '</b> DOP downgrade' || CASE WHEN v_n_dop = 1 THEN '' ELSE 's' END END
                     || CASE WHEN v_n_err > 0 THEN CASE WHEN v_n_pchg + v_n_dop > 0 THEN ',' END || ' <b>' || v_n_err
                                                     || '</b> with errors' END END)
        || '</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 18_sqlmon END -->'); END;
/
