--
-- 08_overview.sql
-- The Summary view's hero strip (v1.6.0, Mock D): DB time per compared
-- window, one column per window on the report's window component
-- (sql/lib/wingrid.plsql + js_wingrid.plsql) -- the SAME ruler, columns
-- and release flags the finding cards and the Timeline view use, with the
-- Current window last, wider and in the accent.  Left: the Current value
-- in average active sessions and its normal range (prior mean +- 2 floored
-- sigma); right: the Delta vs the prior mean, z and the band glyph.
--
-- Replaces the v1.5.0 six headline tiles (DB time, redo, logical reads,
-- AAS, wait time ratio, hard parses): every one of those numbers is a
-- row of 02 Load profile / 03 System metrics (All sections), and the
-- finding cards (07) carry the ones that moved.
--
-- Scoring: the policy's bucket for the LOAD 'DB time' counter
-- (policy_bucket, sql/lib/metric_policy.plsql), same as 07; the value is
-- centiseconds per second, shown divided by 100 (= average active
-- sessions).  Summary view only.
--
-- Read-only: recomputes everything in-flight from the AWR views.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 08_overview BEGIN -->'); END;
/

DECLARE
    v_pairs  VARCHAR2(32767);
    v_cur    NUMBER;
    v_mu     NUMBER;
    v_sd     NUMBER;
    v_n      NUMBER;
    v_bucket VARCHAR2(40);
    v_z      NUMBER;
    v_gut    VARCHAR2(32767);
    v_lab    VARCHAR2(32767);

    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/wingrid.plsql
BEGIN
    --
    -- DB time (time model, cumulative) per valid window: pairs -> bounds ->
    -- deltas, the cross-instance delta over ONE window span (MAX(dur_sec)),
    -- then cur / prior mean / sd / n and the offset-keyed 'k:v' pairs the
    -- window component reads (a skipped window simply has no pair).
    --
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- DB time from the time model (microseconds / 1e4 = centiseconds),
        -- the same source as the LOAD 'DB time' row of 00 / 02 / 07
        -- (sql/lib/load_pairs_cte.sql), so this strip and the DB time card
        -- print the same number.
        load_pairs AS (
            SELECT w.week_offset, w.dur_sec, tm.instance_number,
                   tm.snap_id, tm.value / 1e4 AS value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sys_time_model tm
                ON tm.dbid = w.dbid
               AND tm.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND tm.instance_number = w.instance_number
               AND tm.stat_name = 'DB time'
        ),
        load_bounds AS (
            SELECT week_offset, dur_sec, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   load_pairs
            GROUP BY week_offset, dur_sec, instance_number
        ),
        load_rows AS (
            SELECT week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END AS val
            FROM   load_bounds
            GROUP BY week_offset
        )
        SELECT MAX(CASE WHEN week_offset = 0 THEN val END)    AS cur,
               AVG(CASE WHEN week_offset > 0 THEN val END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN val END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN val END)  AS n,
               LISTAGG(week_offset || ':' ||
                   CASE WHEN val = 0 THEN '0'
                        ELSE TO_CHAR(ROUND(val, 6 - FLOOR(LOG(10, ABS(val)))), 'TM9',
                                     'NLS_NUMERIC_CHARACTERS=''.,''') END, ';')
                   WITHIN GROUP (ORDER BY week_offset) AS pairs
        FROM   load_rows
        WHERE  val IS NOT NULL
    ) LOOP
        v_cur   := r.cur;
        v_mu    := r.mu;
        v_sd    := r.sd;
        v_n     := r.n;
        v_pairs := r.pairs;
    END LOOP;

    v_bucket := CASE WHEN v_cur IS NULL THEN 'n/a'
                     ELSE policy_bucket('LOAD', 'DB time', NULL, v_cur, v_mu, v_sd, v_n) END;
    v_z := band_z(v_cur, v_mu, v_sd);

    v_lab := '<div class="l" role="rowheader"><span class="big">' || fmt_num(v_cur / 100)
        || '<span class="u">AAS</span></span>'
        || '<span class="sub">normal ' || range_txt(v_mu / 100, v_sd / 100) || '</span></div>';
    v_gut := '<div class="g" role="cell"><div class="gl1">'
        || REPLACE(delta_span(v_cur, v_mu, v_bucket), 'class="d ', 'class="d d1 ')
        -- a pinned band (|z| past its -4 / +8 scale) prints its own z
        || CASE WHEN v_z IS NOT NULL AND v_z BETWEEN -4 AND 8
                THEN '<span class="z">z ' || band_ztxt(v_z) || '</span>' END
        || '</div>' || band_span(v_z, v_bucket, 'sm') || '</div>';

    DBMS_OUTPUT.PUT_LINE('<section id="overview" class="vw in-s strip-sec" aria-label="DB time per compared window">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel strip" id="s-strip"><div class="wg fit hov"' || wg_attr
        || ' role="table" aria-label="DB time per compared window">');
    DBMS_OUTPUT.PUT_LINE(wg_ruler('<span class="ct">DB time per window</span>'
        || '<span class="cs">average active sessions</span>',
        '<span class="gt">vs prior mean</span>'));
    DBMS_OUTPUT.PUT_LINE(wg_bars(v_pairs, 0.01, v_mu, v_sd, v_bucket, v_lab, v_gut, 'hero-dbt'));
    DBMS_OUTPUT.PUT_LINE('</div></div></section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 08_overview END -->'); END;
/
