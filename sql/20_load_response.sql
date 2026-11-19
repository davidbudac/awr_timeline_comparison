--
-- 20_load_response.sql
-- Load vs response time: "is the database slower because it got MORE
-- LOAD, or is something BROKEN (same load, each call slower)?"
--
-- A scatter, x = load, y = response time, from DBA_HIST_SYSMETRIC_SUMMARY:
--   * one small dot per snapshot interval of the full span (the earliest
--     compared window start to the Current window end), restart-guarded
--     like sections 00 / 10 (sql/lib/loadresp_cte.sql);
--   * one dot per compared prior window and the Current window, the
--     window average computed exactly as section 03 does (per snap: SUM
--     across instances for a rate, AVG for the response-time ratio; then
--     AVG over the window's snaps), so a dot agrees with the Metrics table;
--   * the "normal for that load" curve: every interval OUTSIDE the Current
--     window, sorted by load and cut into at most 8 equal-count bins; the
--     dashed line joins each bin's median (load, response time), the band
--     is the bins' 25th-75th percentile of response time.
-- Three loads (User Calls / Executions / Logical Reads Per Sec) times two
-- responses (SQL Service Response Time, or Database Time Per Sec divided
-- by the load) = six pairs; the client switches them (segmented control),
-- the default is the pair with the most points.
--
-- The verdict is computed here (it exists with JS off and feeds the
-- library row): Current vs the prior VALID windows on both axes through
-- policy_bucket() (the report's z rule and materiality floors; the
-- response side always uses SQL Service Response Time's policy, in
-- centiseconds), and, when both rose, the Current response against the
-- curve's expectation at the Current load (its ratio to the curve vs the
-- prior windows' ratios, same rule).  The section explains; it never adds
-- a finding (no counts, no rail pill).
--
-- Fixed metric list (template-independent, like 13).  Read-only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 20_load_response BEGIN -->'); END;
/

DECLARE
    TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_str IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    v_wb      PLS_INTEGER := ~weeks_back;
    -- windows: offset k -> valid flag / reason; metrics at k*5 + m
    -- (m: 0 user calls/s, 1 executions/s, 2 logical reads/s,
    --  3 SQL service response time in ms, 4 DB time per sec in cs/s)
    w_v       t_str;
    w_rs      t_str;
    w_m       t_num;
    -- background points (index 1..v_nb): minutes since t0, Current flag,
    -- metrics at i*5 + m
    b_t       t_num;
    b_c       t_num;
    b_m       t_num;
    v_nb      PLS_INTEGER := 0;
    v_t0      DATE;
    v_stride  PLS_INTEGER := 1;
    -- the curve per pair p (0..5): bins at p*16 + b
    c_nb      t_num;
    c_mx      t_num;
    c_my      t_num;
    c_q1      t_num;
    c_q3      t_num;
    -- per pair: points, verdict html, library text, expected at Current
    p_cnt     t_num;
    p_r       t_str;
    p_ls      t_str;
    p_e       t_num;
    v_def     PLS_INTEGER := -1;
    v_best    NUMBER := 0;
    -- verdict work
    v_x       NUMBER;
    v_y       NUMBER;
    v_cx      NUMBER;
    v_cy      NUMBER;
    v_mux     NUMBER;
    v_muy     NUMBER;
    v_sdx     NUMBER;
    v_sdy     NUMBER;
    v_n       PLS_INTEGER;
    v_mur     NUMBER;
    v_sdr     NUMBER;
    v_nr      PLS_INTEGER;
    v_ec      NUMBER;
    v_bx      VARCHAR2(40);
    v_by      VARCHAR2(40);
    v_bz      VARCHAR2(40);
    v_vd      VARCHAR2(2000);
    v_det     VARCHAR2(2000);
    v_line    VARCHAR2(32767);
    v_tail    PLS_INTEGER := 0;
    v_rows    PLS_INTEGER := 0;
    v_clob    CLOB;
    v_tok     VARCHAR2(64);
    v_kept    PLS_INTEGER := 0;
    px_ok     t_num;
    py_ok     t_num;
    pr_ok     t_num;

    -- Subprogram includes go LAST, metric_policy first (lint 14 / 16);
    -- fmt_num before band_glyph (17); off_label before wingrid (29).
    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/json_escape.plsql
    @@sql/lib/put_clob_chunked.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql

    -- a JSON number (3 decimals, dot) or null
    FUNCTION jn(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        RETURN RTRIM(TO_CHAR(ROUND(p, 3), 'FM999999999990D999',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END jn;

    -- pair p: load index (0..2) and response kind (0 service time, 1 DB time per unit)
    FUNCTION lr_xi(p PLS_INTEGER) RETURN PLS_INTEGER IS BEGIN RETURN MOD(p, 3); END lr_xi;
    FUNCTION lr_yi(p PLS_INTEGER) RETURN PLS_INTEGER IS BEGIN RETURN TRUNC(p / 3); END lr_yi;

    -- x / y of pair p from the five metrics (uc, ex, lr, srt ms, dbt cs/s)
    FUNCTION lr_xv(p PLS_INTEGER, uc NUMBER, ex NUMBER, lr NUMBER) RETURN NUMBER IS
        v NUMBER := CASE lr_xi(p) WHEN 0 THEN uc WHEN 1 THEN ex ELSE lr END;
    BEGIN
        IF v IS NULL OR v <= 0 THEN RETURN NULL; END IF;
        RETURN v;
    END lr_xv;
    FUNCTION lr_yv(p PLS_INTEGER, uc NUMBER, ex NUMBER, lr NUMBER, srt NUMBER, dbt NUMBER) RETURN NUMBER IS
        v_x NUMBER := lr_xv(p, uc, ex, lr);
    BEGIN
        IF v_x IS NULL THEN RETURN NULL; END IF;
        IF lr_yi(p) = 0 THEN RETURN srt; END IF;
        IF dbt IS NULL THEN RETURN NULL; END IF;
        RETURN dbt * 10 / v_x * CASE lr_xi(p) WHEN 2 THEN 1000 ELSE 1 END;
    END lr_yv;

    FUNCTION lr_xname(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE lr_xi(p) WHEN 0 THEN 'User Calls Per Sec' WHEN 1 THEN 'Executions Per Sec'
                             ELSE 'Logical Reads Per Sec' END;
    END lr_xname;
    FUNCTION lr_xlab(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE lr_xi(p) WHEN 0 THEN 'User calls per second' WHEN 1 THEN 'Executions per second'
                             ELSE 'Logical reads per second' END;
    END lr_xlab;
    FUNCTION lr_xunit(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE lr_xi(p) WHEN 0 THEN 'calls/s' WHEN 1 THEN 'executions/s' ELSE 'logical reads/s' END;
    END lr_xunit;
    FUNCTION lr_noun(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF lr_yi(p) = 0 THEN RETURN 'call'; END IF;
        RETURN CASE lr_xi(p) WHEN 0 THEN 'call' WHEN 1 THEN 'execution' ELSE 'logical read' END;
    END lr_noun;
    FUNCTION lr_yunit(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF lr_yi(p) = 0 THEN RETURN 'ms per call'; END IF;
        RETURN CASE lr_xi(p) WHEN 0 THEN 'ms per call' WHEN 1 THEN 'ms per execution'
                             ELSE 'ms per 1,000 logical reads' END;
    END lr_yunit;
    FUNCTION lr_ylab(p PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF lr_yi(p) = 0 THEN RETURN 'SQL service response time (ms per call)'; END IF;
        RETURN 'DB time per ' || CASE lr_xi(p) WHEN 0 THEN 'call' WHEN 1 THEN 'execution'
                                               ELSE '1,000 logical reads' END || ' (ms)';
    END lr_ylab;

    -- the curve's response time at load x (linear between bin medians,
    -- flat past the first / last bin); NULL without a curve
    FUNCTION lr_exp(p PLS_INTEGER, x NUMBER) RETURN NUMBER IS
        n PLS_INTEGER;
        a PLS_INTEGER;
    BEGIN
        IF x IS NULL OR NOT c_nb.EXISTS(p) OR c_nb(p) < 2 THEN RETURN NULL; END IF;
        n := c_nb(p);
        IF x <= c_mx(p * 16) THEN RETURN c_my(p * 16); END IF;
        IF x >= c_mx(p * 16 + n - 1) THEN RETURN c_my(p * 16 + n - 1); END IF;
        FOR b IN 1 .. n - 1 LOOP
            a := p * 16 + b;
            IF x <= c_mx(a) THEN
                IF c_mx(a) = c_mx(a - 1) THEN RETURN c_my(a); END IF;
                RETURN c_my(a - 1) + (c_my(a) - c_my(a - 1)) * (x - c_mx(a - 1)) / (c_mx(a) - c_mx(a - 1));
            END IF;
        END LOOP;
        RETURN c_my(p * 16 + n - 1);
    END lr_exp;

    -- "2.4&times;" (one decimal)
    FUNCTION lr_q(q NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(q, 'FM99999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || '&times;';
    END lr_q;
    -- a load change: x n at 2x or more, else a signed percent (delta_span's rule)
    FUNCTION lr_chg(c NUMBER, m NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF c IS NULL OR m IS NULL OR m = 0 THEN RETURN NULL; END IF;
        IF c / m >= 2 THEN RETURN lr_q(c / m); END IF;
        RETURN CASE WHEN c >= m THEN '+' ELSE '&minus;' END
            || TO_CHAR(ABS(c - m) / m * 100, 'FM9999990', 'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
    END lr_chg;
BEGIN
    -- ---------------------------------------------------------------
    -- 1. the window averages (section 03's shape, fixed metric list)
    -- ---------------------------------------------------------------
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        lr_m AS (
            SELECT 'User Calls Per Sec' AS metric_name, 0 AS mi, 'Y' AS is_additive FROM dual UNION ALL
            SELECT 'Executions Per Sec',            1, 'Y' FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec',         2, 'Y' FROM dual UNION ALL
            SELECT 'SQL Service Response Time',     3, 'N' FROM dual UNION ALL
            SELECT 'Database Time Per Sec',         4, 'Y' FROM dual
        ),
        per_snap AS (
            SELECT w.week_offset, t.mi, sm.snap_id,
                   CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                                 ELSE AVG(sm.average) END AS snap_value
            FROM   valid_windows w
            CROSS JOIN lr_m t
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND sm.instance_number = w.instance_number
               AND sm.metric_name = t.metric_name
            GROUP BY w.week_offset, t.mi, t.is_additive, sm.snap_id
        ),
        facts AS (
            SELECT week_offset,
                   AVG(CASE WHEN mi = 0 THEN snap_value END) AS uc,
                   AVG(CASE WHEN mi = 1 THEN snap_value END) AS ex,
                   AVG(CASE WHEN mi = 2 THEN snap_value END) AS lr,
                   AVG(CASE WHEN mi = 3 THEN snap_value END) AS srt,
                   AVG(CASE WHEN mi = 4 THEN snap_value END) AS dbt
            FROM   per_snap
            GROUP BY week_offset
        )
        SELECT r.week_offset, r.valid_flag, r.skip_reason,
               f.uc, f.ex, f.lr, f.srt, f.dbt
        FROM   windows_rollup r
        LEFT JOIN facts f ON f.week_offset = r.week_offset
        ORDER BY r.week_offset
    ) LOOP
        w_v(r.week_offset)  := r.valid_flag;
        w_rs(r.week_offset) := r.skip_reason;
        w_m(r.week_offset * 5)     := r.uc;
        w_m(r.week_offset * 5 + 1) := r.ex;
        w_m(r.week_offset * 5 + 2) := r.lr;
        w_m(r.week_offset * 5 + 3) := r.srt * 10;
        w_m(r.week_offset * 5 + 4) := r.dbt;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 2. every snapshot interval of the span (the grey cloud)
    -- ---------------------------------------------------------------
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        @@sql/lib/loadresp_cte.sql
        SELECT CAST(p.t_lo AS DATE) AS t0, x.end_ts, x.cur,
               x.uc, x.ex, x.lr, x.srt, x.dbt
        FROM   lr_pts x
        CROSS JOIN lr_span p
        ORDER BY x.end_ts, x.dbid, x.snap_id
    ) LOOP
        v_nb := v_nb + 1;
        v_t0 := r.t0;
        b_t(v_nb) := ROUND((CAST(r.end_ts AS DATE) - r.t0) * 1440);
        b_c(v_nb) := r.cur;
        b_m(v_nb * 5)     := r.uc;
        b_m(v_nb * 5 + 1) := r.ex;
        b_m(v_nb * 5 + 2) := r.lr;
        b_m(v_nb * 5 + 3) := r.srt * 10;
        b_m(v_nb * 5 + 4) := r.dbt;
    END LOOP;

    -- points per pair (the default = the pair with the most points)
    FOR p IN 0 .. 5 LOOP
        p_cnt(p) := 0;
        FOR i IN 1 .. v_nb LOOP
            IF lr_yv(p, b_m(i * 5), b_m(i * 5 + 1), b_m(i * 5 + 2), b_m(i * 5 + 3), b_m(i * 5 + 4)) IS NOT NULL THEN
                p_cnt(p) := p_cnt(p) + 1;
            END IF;
        END LOOP;
        IF p_cnt(p) > v_best THEN
            v_best := p_cnt(p);
            v_def := p;
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 3. the normal curve: equal-count load bins of every interval
    --    outside the Current window, per pair
    -- ---------------------------------------------------------------
    IF v_best >= 12 THEN
        FOR r IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            @@sql/lib/loadresp_cte.sql
            ,
            lr_pid AS (
                SELECT LEVEL - 1 AS pid FROM dual CONNECT BY LEVEL <= 6
            ),
            lr_xy AS (
                SELECT q.pid, q.x,
                       CASE WHEN q.pid < 3 THEN q.srt * 10
                            WHEN q.dbt IS NULL THEN NULL
                            ELSE q.dbt * 10 / q.x * CASE MOD(q.pid, 3) WHEN 2 THEN 1000 ELSE 1 END
                       END AS y
                FROM (
                    SELECT d.pid, t.srt, t.dbt,
                           CASE MOD(d.pid, 3) WHEN 0 THEN t.uc WHEN 1 THEN t.ex ELSE t.lr END AS x
                    FROM   lr_pts t
                    CROSS JOIN lr_pid d
                    WHERE  t.cur = 0
                ) q
                WHERE  q.x > 0
            ),
            lr_rk AS (
                SELECT pid, x, y,
                       ROW_NUMBER() OVER (PARTITION BY pid ORDER BY x, y) AS rn,
                       COUNT(*)     OVER (PARTITION BY pid)               AS n
                FROM   lr_xy
                WHERE  y IS NOT NULL
            ),
            lr_bin AS (
                SELECT pid, x, y,
                       FLOOR((rn - 1) * LEAST(8, FLOOR(n / 6)) / n) AS b
                FROM   lr_rk
                WHERE  n >= 12
            )
            SELECT pid, b,
                   MEDIAN(x) AS mx,
                   MEDIAN(y) AS my,
                   PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY y) AS q1,
                   PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY y) AS q3
            FROM   lr_bin
            GROUP BY pid, b
            ORDER BY pid, b
        ) LOOP
            c_nb(r.pid) := r.b + 1;
            c_mx(r.pid * 16 + r.b) := r.mx;
            c_my(r.pid * 16 + r.b) := r.my;
            c_q1(r.pid * 16 + r.b) := r.q1;
            c_q3(r.pid * 16 + r.b) := r.q3;
        END LOOP;
    END IF;

    -- ---------------------------------------------------------------
    -- 4. the verdict per pair
    -- ---------------------------------------------------------------
    FOR p IN 0 .. 5 LOOP
        p_e(p) := NULL;
        p_r(p) := NULL;
        p_ls(p) := NULL;
        IF p_cnt(p) > 0 THEN
            v_cx := NULL; v_cy := NULL;
            IF w_v.EXISTS(0) AND w_v(0) = 'Y' THEN
                v_cx := lr_xv(p, w_m(0), w_m(1), w_m(2));
                v_cy := lr_yv(p, w_m(0), w_m(1), w_m(2), w_m(3), w_m(4));
            END IF;
            p_e(p) := lr_exp(p, v_cx);
            -- prior windows: mean, then sample sd (two passes)
            px_ok.DELETE; py_ok.DELETE; pr_ok.DELETE;
            v_n := 0; v_nr := 0;
            FOR k IN 1 .. v_wb LOOP
                IF w_v.EXISTS(k) AND w_v(k) = 'Y' THEN
                    v_x := lr_xv(p, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2));
                    v_y := lr_yv(p, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2), w_m(k * 5 + 3), w_m(k * 5 + 4));
                    IF v_x IS NOT NULL AND v_y IS NOT NULL THEN
                        v_n := v_n + 1;
                        px_ok(v_n) := v_x;
                        py_ok(v_n) := v_y;
                        v_ec := lr_exp(p, v_x);
                        IF v_ec > 0 THEN
                            v_nr := v_nr + 1;
                            pr_ok(v_nr) := v_y / v_ec;
                        END IF;
                    END IF;
                END IF;
            END LOOP;
            v_mux := NULL; v_muy := NULL; v_sdx := NULL; v_sdy := NULL; v_mur := NULL; v_sdr := NULL;
            IF v_n > 0 THEN
                v_mux := 0; v_muy := 0;
                FOR i IN 1 .. v_n LOOP v_mux := v_mux + px_ok(i); v_muy := v_muy + py_ok(i); END LOOP;
                v_mux := v_mux / v_n; v_muy := v_muy / v_n;
            END IF;
            IF v_n > 1 THEN
                v_sdx := 0; v_sdy := 0;
                FOR i IN 1 .. v_n LOOP
                    v_sdx := v_sdx + POWER(px_ok(i) - v_mux, 2);
                    v_sdy := v_sdy + POWER(py_ok(i) - v_muy, 2);
                END LOOP;
                v_sdx := SQRT(v_sdx / (v_n - 1)); v_sdy := SQRT(v_sdy / (v_n - 1));
            END IF;
            IF v_nr > 0 THEN
                v_mur := 0;
                FOR i IN 1 .. v_nr LOOP v_mur := v_mur + pr_ok(i); END LOOP;
                v_mur := v_mur / v_nr;
            END IF;
            IF v_nr > 1 THEN
                v_sdr := 0;
                FOR i IN 1 .. v_nr LOOP v_sdr := v_sdr + POWER(pr_ok(i) - v_mur, 2); END LOOP;
                v_sdr := SQRT(v_sdr / (v_nr - 1));
            END IF;

            v_bx := policy_bucket('METRIC', lr_xname(p), NULL, v_cx, v_mux, v_sdx, v_n);
            v_by := policy_bucket('METRIC', 'SQL Service Response Time', NULL,
                                  v_cy / 10, v_muy / 10, v_sdy / 10, v_n);
            IF v_cx IS NULL OR v_cy IS NULL THEN
                v_vd := 'no Current value: the Current window was skipped or has no system metrics';
            ELSIF v_n < 3 THEN
                v_vd := CASE WHEN v_n = 0 THEN 'no valid prior window'
                             ELSE 'only ' || v_n || ' valid prior window' || CASE WHEN v_n = 1 THEN '' ELSE 's' END END
                    || ': too little history to tell more load from slower calls';
            ELSIF v_bx IN ('large', 'moderate') AND v_cx > v_mux THEN
                IF v_by IN ('large', 'moderate') THEN
                    IF p_e(p) > 0 AND v_mur IS NOT NULL THEN
                        v_bz := policy_bucket('METRIC', 'SQL Service Response Time', NULL,
                                              v_cy / 10, p_e(p) * v_mur / 10, p_e(p) * v_sdr / 10, v_nr);
                        IF v_bz IN ('large', 'moderate') THEN
                            v_vd := 'more load (' || lr_chg(v_cx, v_mux) || ') <b>and</b> slower than that load explains: each '
                                || lr_noun(p) || ' <b>' || lr_q(v_cy / p_e(p)) || '</b> the normal for that load';
                        ELSE
                            v_vd := 'more load (' || lr_chg(v_cx, v_mux) || '), response time as expected for that load';
                        END IF;
                    ELSE
                        v_vd := 'more load (' || lr_chg(v_cx, v_mux) || ') and each ' || lr_noun(p) || ' <b>'
                            || lr_q(v_cy / v_muy) || '</b> slower (too few intervals to tell what that load explains)';
                    END IF;
                ELSE
                    v_vd := 'more load (' || lr_chg(v_cx, v_mux) || '), response time as expected for that load';
                END IF;
            ELSIF v_bx IN ('large', 'moderate') AND v_cx < v_mux THEN
                v_vd := 'less load (' || lr_chg(v_cx, v_mux) || ')'
                    || CASE WHEN v_by IN ('large', 'moderate')
                            THEN ', yet each ' || lr_noun(p) || ' <b>' || lr_q(v_cy / v_muy) || '</b> slower' END;
            ELSIF v_by IN ('large', 'moderate') THEN
                v_vd := 'load is normal, each ' || lr_noun(p) || ' <b>' || lr_q(v_cy / v_muy) || '</b> slower';
            ELSIF v_by = 'improved' THEN
                v_vd := 'load is normal, each ' || lr_noun(p) || ' faster than usual';
            ELSE
                v_vd := 'normal: load and response time both within their usual range';
            END IF;
            -- a release marker between the last prior window and Current
            -- (js_wingrid fills the slot: " after Release 4.2 (Tue 8 Sep)")
            IF v_n >= 3 AND v_cy IS NOT NULL AND v_by IN ('large', 'moderate') AND v_wb >= 1 THEN
                v_vd := v_vd || '<span data-mk-at="0" data-mk-pre=" after " hidden></span>';
            END IF;
            p_ls(p) := v_vd;
            v_det := NULL;
            IF v_cx IS NOT NULL AND v_cy IS NOT NULL THEN
                v_det := ' Current: ' || fmt_num(v_cx) || ' ' || lr_xunit(p)
                    || CASE WHEN v_n >= 2 THEN ' (normal ' || range_txt(v_mux, v_sdx) || ')' END
                    || ', ' || fmt_num(v_cy) || ' ' || lr_yunit(p)
                    || CASE WHEN v_n >= 2 THEN ' (normal ' || range_txt(v_muy, v_sdy) || ')' END
                    || CASE WHEN p_e(p) IS NOT NULL
                            THEN '; the curve expects ' || fmt_num(p_e(p)) || ' ms at that load' END
                    || '.';
            END IF;
            p_r(p) := UPPER(SUBSTR(v_vd, 1, 1)) || SUBSTR(v_vd, 2) || '.' || v_det;
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. markup
    -- ---------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<section id="load-response" class="vw in-s in-a lib" style="--os:10"><h2>Load vs response time'
        || '<small class="h2sub">More load, or something broken? Each snapshot interval as a dot: how busy against how long each call took</small></h2>');

    IF v_nb = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">No system metrics (DBA_HIST_SYSMETRIC_SUMMARY) in the report span, so there is nothing to plot.</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('load-response', 'no system metrics in the span') || '</section>');
    ELSIF v_best < 6 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">'
            || CASE WHEN v_best = 0 THEN 'No load in the span: every snapshot interval had zero user calls, executions and logical reads.'
                    ELSE 'Only ' || v_best || ' snapshot interval' || CASE WHEN v_best = 1 THEN '' ELSE 's' END
                         || ' with load in the span: too few to draw.' END
            || '</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('load-response', CASE WHEN v_best = 0 THEN 'no load in the span'
                                                          ELSE 'too few intervals with load' END) || '</section>');
    ELSE
        -- the chart (drawn by js_loadresp; hidden until it draws)
        v_line := '<div class="lr-chart" data-def="' || v_def || '">'
            || '<div class="lr-ctl"><span class="lr-seg" role="group" aria-label="Load measure">'
            || '<span class="lr-sl">Load</span>';
        FOR xi IN 0 .. 2 LOOP
            v_line := v_line || '<button type="button" data-x="' || xi || '" aria-pressed="'
                || CASE WHEN xi = lr_xi(v_def) THEN 'true' ELSE 'false' END || '"'
                || CASE WHEN p_cnt(xi) = 0 AND p_cnt(xi + 3) = 0 THEN ' disabled' END || '>'
                || CASE xi WHEN 0 THEN 'User calls' WHEN 1 THEN 'Executions' ELSE 'Logical reads' END
                || '</button>';
        END LOOP;
        v_line := v_line || '</span><span class="lr-seg" role="group" aria-label="Response measure">'
            || '<span class="lr-sl">Response</span>'
            || '<button type="button" data-y="0" aria-pressed="' || CASE WHEN lr_yi(v_def) = 0 THEN 'true' ELSE 'false' END
            || '" title="SQL Service Response Time: database time per user call, as SYSMETRIC reports it">Service time per call</button>'
            || '<button type="button" data-y="1" aria-pressed="' || CASE WHEN lr_yi(v_def) = 1 THEN 'true' ELSE 'false' END
            || '" title="Database Time Per Sec divided by the load: DB time per unit of the chosen load">DB time per unit</button>'
            || '</span></div>'
            || '<div class="lr-lg"><span><i class="lr-k kc"></i>Current window</span>'
            || '<span><i class="lr-k kp"></i>' || v_wb || ' prior window' || CASE WHEN v_wb = 1 THEN '' ELSE 's' END || '</span>'
            || '<span><i class="lr-k kb"></i>every snapshot interval in the span</span>'
            || '<span><i class="lr-k kn"></i>normal for that load</span>'
            || '<span><i class="lr-k kd"></i>middle half (25th&ndash;75th percentile)</span></div>'
            || '<div class="lr-plot"></div></div>';
        DBMS_OUTPUT.PUT_LINE(v_line);
        DBMS_OUTPUT.PUT_LINE('<p class="lr-rd"><b>Reads as:</b> <span class="lr-rt">' || p_r(v_def) || '</span></p>');
        IF v_nb > 6000 THEN
            v_stride := CEIL(v_nb / 6000);
        END IF;

        -- the per-window table, for the default pair
        DBMS_OUTPUT.PUT_LINE('<div class="lr-tw"><table id="lr-tbl" class="lr-tbl" data-nosort><caption>Per window, '
            || lr_xlab(v_def) || ' against ' || lr_ylab(v_def)
            || '. &ldquo;Normal for that load&rdquo; = the dashed curve at the window&#39;s load.</caption>'
            || '<thead><tr><th>Window</th><th>When</th><th class="num">Load (' || lr_xunit(v_def) || ')</th>'
            || '<th class="num">vs normal</th><th class="num">Response (' || lr_yunit(v_def) || ')</th>'
            || '<th class="num">vs normal</th><th class="num">Normal for that load</th></tr></thead><tbody>');
        -- the default pair's prior stats again (the loop above left the last pair's)
        v_n := 0; v_mux := 0; v_muy := 0; v_sdx := NULL; v_sdy := NULL;
        px_ok.DELETE; py_ok.DELETE;
        FOR k IN 1 .. v_wb LOOP
            IF w_v.EXISTS(k) AND w_v(k) = 'Y' THEN
                v_x := lr_xv(v_def, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2));
                v_y := lr_yv(v_def, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2), w_m(k * 5 + 3), w_m(k * 5 + 4));
                IF v_x IS NOT NULL AND v_y IS NOT NULL THEN
                    v_n := v_n + 1; px_ok(v_n) := v_x; py_ok(v_n) := v_y;
                    v_mux := v_mux + v_x; v_muy := v_muy + v_y;
                END IF;
            END IF;
        END LOOP;
        IF v_n > 0 THEN v_mux := v_mux / v_n; v_muy := v_muy / v_n; ELSE v_mux := NULL; v_muy := NULL; END IF;
        IF v_n > 1 THEN
            v_sdx := 0; v_sdy := 0;
            FOR i IN 1 .. v_n LOOP
                v_sdx := v_sdx + POWER(px_ok(i) - v_mux, 2);
                v_sdy := v_sdy + POWER(py_ok(i) - v_muy, 2);
            END LOOP;
            v_sdx := SQRT(v_sdx / (v_n - 1)); v_sdy := SQRT(v_sdy / (v_n - 1));
        END IF;
        FOR k IN 0 .. v_wb LOOP
            v_rows := v_rows + 1;
            v_x := NULL; v_y := NULL;
            IF w_v.EXISTS(k) AND w_v(k) = 'Y' THEN
                v_x := lr_xv(v_def, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2));
                v_y := lr_yv(v_def, w_m(k * 5), w_m(k * 5 + 1), w_m(k * 5 + 2), w_m(k * 5 + 3), w_m(k * 5 + 4));
            END IF;
            v_line := '<tr id="' || anchor_id('lr', 'w' || k) || '"'
                || CASE WHEN k = 0 THEN ' class="cur"' END
                || CASE WHEN v_rows > 13 THEN ' data-tail="Y"' END || '>'
                || '<td data-w="' || k || '">' || CASE WHEN k = 0 THEN '<b>Current</b>' ELSE wg_off(k) END || '</td>'
                || '<td data-w="' || k || '">' || wg_title(k) || '</td>';
            IF NOT (w_v.EXISTS(k) AND w_v(k) = 'Y') THEN
                v_line := v_line || '<td class="num" data-w="' || k || '" colspan="5"><span class="lr-sk">skipped'
                    || CASE WHEN w_rs.EXISTS(k) AND w_rs(k) IS NOT NULL
                            THEN ': ' || DBMS_XMLGEN.CONVERT(w_rs(k)) END || '</span></td>';
            ELSE
                IF k = 0 THEN
                    v_bx := policy_bucket('METRIC', lr_xname(v_def), NULL, v_x, v_mux, v_sdx, v_n);
                    v_by := policy_bucket('METRIC', 'SQL Service Response Time', NULL, v_y / 10, v_muy / 10, v_sdy / 10, v_n);
                END IF;
                v_line := v_line
                    || '<td class="num" data-w="' || k || '">' || fmt_num(v_x) || '</td>'
                    || '<td class="num" data-w="' || k || '">'
                    || CASE WHEN k = 0 THEN delta_span(v_x, v_mux, CASE WHEN v_bx IN ('large', 'moderate') THEN 'moderate' END)
                                || ' <span class="lr-z">' || band_ztxt(band_z(v_x, v_mux, v_sdx)) || '</span>'
                            ELSE delta_span(v_x, v_mux, NULL, 'Y') END || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(v_y) || '</td>'
                    || '<td class="num" data-w="' || k || '">'
                    || CASE WHEN k = 0 THEN delta_span(v_y, v_muy, v_by)
                                || ' <span class="lr-z">' || band_ztxt(band_z(v_y, v_muy, v_sdy)) || '</span>'
                            ELSE delta_span(v_y, v_muy, NULL, 'Y') END || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(lr_exp(v_def, v_x)) || '</td>';
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_line || '</tr>');
            IF v_rows > 13 THEN v_tail := v_tail + 1; END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('<tr class="lr-nrm"><td colspan="2">Normal (prior mean, ' || v_n || ' window'
            || CASE WHEN v_n = 1 THEN '' ELSE 's' END || ')</td>'
            || '<td class="num">' || fmt_num(v_mux) || '</td><td class="num">' || range_txt(v_mux, v_sdx) || '</td>'
            || '<td class="num">' || fmt_num(v_muy) || '</td><td class="num">' || range_txt(v_muy, v_sdy) || '</td>'
            || '<td></td></tr>');
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');
        IF v_tail > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<span class="expander" data-for="lr-tbl" data-n="' || v_tail
                || '" data-noun="older windows">&#9656; Show ' || v_tail || ' older windows</span>');
        END IF;

        -- every measure per window (the numbers every pair draws)
        DBMS_OUTPUT.PUT_LINE('<details class="lr-all"><summary>Every measure, per window</summary>'
            || '<div class="lr-tw"><table class="lr-tbl2" data-nosort><thead><tr><th>Window</th><th class="num">User calls/s</th>'
            || '<th class="num">Executions/s</th><th class="num">Logical reads/s</th>'
            || '<th class="num">SQL service response time (ms per call)</th>'
            || '<th class="num">DB time (average active sessions)</th></tr></thead><tbody>');
        FOR k IN 0 .. v_wb LOOP
            v_line := '<tr><td data-w="' || k || '">' || CASE WHEN k = 0 THEN 'Current' ELSE wg_off(k) END
                || ' <span class="lr-dt">' || wg_date(k) || '</span></td>';
            IF NOT (w_v.EXISTS(k) AND w_v(k) = 'Y') THEN
                v_line := v_line || '<td class="num" data-w="' || k || '" colspan="5"><span class="lr-sk">skipped</span></td>';
            ELSE
                v_line := v_line
                    || '<td class="num" data-w="' || k || '">' || fmt_num(w_m(k * 5)) || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(w_m(k * 5 + 1)) || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(w_m(k * 5 + 2)) || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(w_m(k * 5 + 3)) || '</td>'
                    || '<td class="num" data-w="' || k || '">' || fmt_num(w_m(k * 5 + 4) / 100) || '</td>';
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_line || '</tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div></details>');

        -- ---------------------------------------------------------------
        -- 6. the payload (strings on their own lines; the numeric arrays
        --    through put_clob_chunked, which splits only at commas)
        -- ---------------------------------------------------------------
        DBMS_OUTPUT.PUT_LINE('<script>(window.AWR_DATA=window.AWR_DATA||{}).loadresp={def:' || v_def
            || ',t0:"' || TO_CHAR(v_t0, 'YYYY-MM-DD HH24:MI') || '",n:' || v_nb || ',stride:' || v_stride || ',p:[');
        FOR p IN 0 .. 5 LOOP
            v_line := '{n:' || p_cnt(p) || ',xl:"' || lr_xlab(p) || '",yl:"' || json_escape(lr_ylab(p))
                || '",xu:"' || lr_xunit(p) || '",yu:"' || json_escape(lr_yunit(p)) || '",e:' || jn(p_e(p)) || ',c:[';
            IF c_nb.EXISTS(p) AND c_nb(p) >= 2 THEN
                FOR b IN 0 .. c_nb(p) - 1 LOOP
                    v_line := v_line || CASE WHEN b > 0 THEN ',' END || '[' || jn(c_mx(p * 16 + b)) || ','
                        || jn(c_my(p * 16 + b)) || ',' || jn(c_q1(p * 16 + b)) || ',' || jn(c_q3(p * 16 + b)) || ']';
                END LOOP;
            END IF;
            v_line := v_line || '],r:"' || json_escape(p_r(p)) || '"}' || CASE WHEN p < 5 THEN ',' END;
            DBMS_OUTPUT.PUT_LINE(v_line);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],w:[');
        -- windows, oldest first
        FOR k IN REVERSE 0 .. v_wb LOOP
            v_line := '{o:' || k || ',l:"' || CASE WHEN k = 0 THEN 'Current' ELSE json_escape(wg_off(k)) END
                || '",t:"' || json_escape(wg_title(k)) || '",v:"'
                || CASE WHEN w_v.EXISTS(k) THEN w_v(k) ELSE 'N' END || '",m:[';
            IF w_v.EXISTS(k) AND w_v(k) = 'Y' THEN
                v_line := v_line || jn(w_m(k * 5)) || ',' || jn(w_m(k * 5 + 1)) || ',' || jn(w_m(k * 5 + 2))
                    || ',' || jn(w_m(k * 5 + 3)) || ',' || jn(w_m(k * 5 + 4));
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_line || ']}' || CASE WHEN k > 0 THEN ',' END);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],');
        -- the cloud: times, Current flags, then one array per metric
        FOR a IN 0 .. 6 LOOP
            DBMS_LOB.CREATETEMPORARY(v_clob, TRUE);
            v_kept := 0;
            FOR i IN 1 .. v_nb LOOP
                IF MOD(i - 1, v_stride) = 0 OR b_c(i) = 1 THEN
                    v_kept := v_kept + 1;
                    v_tok := CASE WHEN v_kept > 1 THEN ',' END
                        || CASE a WHEN 0 THEN TO_CHAR(b_t(i)) WHEN 1 THEN TO_CHAR(b_c(i))
                                  ELSE jn(b_m(i * 5 + a - 2)) END;
                    DBMS_LOB.WRITEAPPEND(v_clob, LENGTH(v_tok), v_tok);
                END IF;
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(CASE a WHEN 0 THEN 'bt' WHEN 1 THEN 'bc' ELSE 'b' || (a - 2) END || ':[');
            put_clob_chunked(v_clob);
            DBMS_OUTPUT.PUT_LINE(']' || CASE WHEN a < 6 THEN ',' END);
            DBMS_LOB.FREETEMPORARY(v_clob);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('};</script>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('load-response', p_ls(v_def)) || '</section>');
    END IF;
END;
/

@@sql/lib/js_loadresp.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 20_load_response END -->'); END;
/
