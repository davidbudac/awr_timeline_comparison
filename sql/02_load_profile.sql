--
-- 02_load_profile.sql
-- Per-window deltas from DBA_HIST_SYSSTAT for a curated set of stats that
-- make up the classic AWR Load Profile (redo, DB time, CPU, reads, parses,
-- transactions, sorts, etc.).  Renders as a pivot: metric x week.  DB time
-- and DB CPU come from DBA_HIST_SYS_TIME_MODEL instead (SYSSTAT has no
-- 'DB CPU' row), via sql/lib/load_pairs_cte.sql, in centiseconds.
--
-- For cumulative counters we compute end - begin.  Rates are derived from
-- the window duration in seconds.  Read-only: no scratch table.
--
-- Plan 043: a second table, "Time model: what the sessions were doing"
-- (table#load-time-model), from DBA_HIST_SYS_TIME_MODEL: a FIXED,
-- template-independent list (like section 13; no *_targets.sql, lint
-- check 2), one row per statistic in the tree order of the 19c Reference
-- (V$SESS_TIME_MODEL: "two trees in which all the time reported by a
-- child is contained within the parent"; children overlap and need not
-- add up), as AAS (microseconds / 1e6 / window seconds) and, for the
-- DB time tree, as a share of Current DB time.  Unscored: band_cells with
-- a NULL bucket and a plain Delta, no crit / warn, data-nocount.  Names
-- are matched case-insensitively (the Reference spells 'sql execute
-- elapsed time' / 'background cpu time' both ways).  A row that is zero
-- in every window is left out and named in the closing note; a row with
-- no AWR row at all is named separately ("not found"), so a misspelt
-- name never disappears silently.  Row ids anchor_id('tm', name).
-- The statistic other than DB time, DB CPU and SQL execution with the
-- largest rise (at least 0.01 AAS and 5% of a positive DB-time rise)
-- becomes one evidence row on the DB time card (#f-dbtime, section 07,
-- which runs before this section): a hidden source block plus a one-line
-- script that appends it to the card's dl.ev while the page parses
-- (before js_timeline's Peak / CPU rows, added at DOMContentLoaded).
-- Twin: demo/awrdemo/sections/s02_load_profile.py.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 02_load_profile BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_header     VARCHAR2(32767);   -- one th (about 45 bytes) per window
    v_row        VARCHAR2(32767);
    v_label      VARCHAR2(120);
    v_per_sec    NUMBER;
    v_per_sec_s  VARCHAR2(64);
    v_row_max    NUMBER;
    v_pct        NUMBER;

    v_unit       VARCHAR2(16);
    v_bucket     VARCHAR2(40);
    v_nrows      PLS_INTEGER := 0;

    -- plan 043: the time model rows, fetched first (the share of DB time,
    -- the dropped rows and the card row need every row before emitting)
    TYPE tm_rec IS RECORD (
        ord     PLS_INTEGER,
        lvl     PLS_INTEGER,
        nm      VARCHAR2(64),
        par     VARCHAR2(64),
        fg      VARCHAR2(1),
        wd      VARCHAR2(20),
        n_found NUMBER,
        cur     NUMBER,
        mu      NUMBER,
        sd      NUMBER,
        n_prior NUMBER,
        amax    NUMBER,
        spark   VARCHAR2(4000),
        wv      VARCHAR2(4000));
    TYPE tm_tab IS TABLE OF tm_rec INDEX BY PLS_INTEGER;
    v_tm        tm_tab;
    v_tm_dbt    PLS_INTEGER;          -- index of the DB time row
    v_tm_rise   NUMBER;               -- DB time Current minus prior mean, AAS
    v_tm_pick   PLS_INTEGER;          -- the card row's statistic
    v_tm_best   NUMBER;
    v_tm_ch     PLS_INTEGER;
    v_tm_chr    NUMBER;
    v_tm_zero   VARCHAR2(4000);
    v_tm_miss   VARCHAR2(4000);
    v_tm_shown  PLS_INTEGER := 0;
    v_tm_bg1    BOOLEAN := TRUE;
    v_tm_ls     VARCHAR2(1000);
    v_tm_shr    NUMBER;
    v_tm_pct    VARCHAR2(200);
    -- Subprogram includes go LAST, metric_policy first (it opens with a
    -- TYPE; lint checks 14 / 16), fmt_num before band_glyph (check 17) and
    -- before finding_cards (check 20).
    @@sql/lib/metric_policy.plsql
    @@sql/lib/nth_csv.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/finding_cards.plsql

    -- plan 043: a number as a data-* token ('.' decimal, 6 places)
    FUNCTION tm_tok(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p, 'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END tm_tok;

    -- the rise a time model row may cite on the DB time card: Current minus
    -- the prior mean, AAS; NULL when it may not (DB time itself, DB CPU and
    -- SQL execution -- the card already tells those --, background rows)
    FUNCTION tm_rise(i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF v_tm(i).fg <> 'F' OR v_tm(i).lvl < 2
           OR LOWER(v_tm(i).nm) IN ('db cpu', 'sql execute elapsed time')
           OR v_tm(i).cur IS NULL OR v_tm(i).mu IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN v_tm(i).cur - v_tm(i).mu;
    END tm_rise;

    -- the card's rule: at least 0.01 AAS and 5% of the (positive) DB-time rise
    FUNCTION tm_ok(i PLS_INTEGER) RETURN BOOLEAN IS
        v NUMBER := tm_rise(i);
    BEGIN
        RETURN v IS NOT NULL AND v_tm_rise IS NOT NULL AND v_tm_rise > 0
           AND v >= 0.01 AND v >= 0.05 * v_tm_rise;
    END tm_ok;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="load" class="vw in-s in-a lib" style="--os:7"><h2>Load profile'
        || '<small class="h2sub">System statistics per second, Current against its normal range</small></h2>');

    -- v1.6.0: Current, then the baseline band (normal range | band | z |
    -- Delta, sql/lib/band_glyph.plsql) scored by the per-metric policy --
    -- the same bucket 07 gives the row -- then the trend and the prior
    -- windows (plain values; the heat tints are gone).
    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th class="num" data-w="0">Current</th>'
        || band_head || '<th class="trend">Trend</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num" data-w="' || k || '">&minus;'
            || off_label(k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table id="load-profile">' || v_header || '<tbody>');

    FOR m IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        load_targets AS (
            @@~template_dir/sysstat_load_targets.sql
        ),
        -- SYSSTAT counters, with DB time / DB CPU from the time model
        @@sql/lib/load_pairs_cte.sql
        ,
        bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   load_pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        deltas AS (
            -- Sum the cross-instance delta, then divide by ONE window span.
            -- dur_sec is per-instance (each instance's resolved snaps jitter);
            -- MAX collapses them to the full wall-clock span covered.  Grouping
            -- no longer keys on dur_sec, else differing per-instance spans would
            -- split a RAC week into partial rows.  Single-instance: dur_sec is
            -- constant, so MAX and the narrower GROUP BY are byte-identical.
            SELECT week_offset, stat_name,
                   SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS stat_value,
                   MAX(dur_sec) AS dur_sec
            FROM   bounds
            GROUP BY week_offset, stat_name
        ),
        facts AS (
            SELECT week_offset, stat_name,
                   CASE WHEN dur_sec > 0 THEN stat_value / dur_sec END AS per_sec
            FROM   deltas
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT t.stat_name, w.week_offset, f.per_sec
            FROM   load_targets t
            CROSS JOIN all_weeks w
            LEFT JOIN facts f
                   ON f.stat_name   = t.stat_name
                  AND f.week_offset = w.week_offset
        )
        SELECT stat_name,
               MAX(CASE WHEN week_offset = 0 THEN per_sec END) AS cur_ps,
               MAX(per_sec) AS row_max,
               -- prior-window baseline for the band (valid windows only:
               -- facts come from valid_windows, so a skipped window is NULL)
               AVG(CASE WHEN week_offset > 0 THEN per_sec END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN per_sec END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN per_sec END)  AS n_prior,
               -- ','||token + SUBSTR: LISTAGG drops NULL measures (and their
               -- delimiter), which would left-compact the CSV and misalign
               -- the positional slots; ','||NULL = ',' keeps the empty slot.
               SUBSTR(LISTAGG(',' || TO_CHAR(per_sec, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_vals,
               SUBSTR(LISTAGG(',' || TO_CHAR(per_sec, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals
        FROM   grid
        GROUP BY stat_name
        ORDER BY CASE stat_name
            WHEN 'DB time'                    THEN 1
            WHEN 'DB CPU'                     THEN 2
            WHEN 'redo size'                  THEN 3
            WHEN 'session logical reads'      THEN 4
            WHEN 'physical reads'             THEN 5
            WHEN 'physical read total bytes'  THEN 6
            WHEN 'physical writes'            THEN 7
            WHEN 'physical write total bytes' THEN 8
            WHEN 'user calls'                 THEN 9
            WHEN 'execute count'              THEN 10
            WHEN 'user commits'               THEN 11
            WHEN 'user rollbacks'             THEN 12
            WHEN 'parse count (total)'        THEN 13
            WHEN 'parse count (hard)'         THEN 14
            WHEN 'parse count (failures)'     THEN 15
            WHEN 'logons cumulative'          THEN 16
            WHEN 'opened cursors cumulative'  THEN 17
            WHEN 'redo writes'                THEN 18
            WHEN 'sorts (memory)'             THEN 19
            WHEN 'sorts (disk)'               THEN 20
            WHEN 'sorts (rows)'               THEN 21
            WHEN 'table scans (long tables)'  THEN 22
            WHEN 'table fetch by rowid'       THEN 23
            ELSE 99 END,
            stat_name
    ) LOOP
        v_label := m.stat_name;
        IF m.stat_name IN ('redo size', 'physical read total bytes', 'physical write total bytes',
                           'bytes sent via SQL*Net to client', 'bytes received via SQL*Net from client') THEN
            v_unit := 'bytes/s';
        ELSIF m.stat_name IN ('DB time', 'DB CPU', 'CPU used by this session') THEN
            v_unit := 'cs/s';
        ELSE
            v_unit := '/s';
        END IF;

        v_row := '<tr id="' || anchor_id('load', m.stat_name)
              || '" data-imp="' || is_essential('LOAD', m.stat_name)
              || '"><td>' || DBMS_XMLGEN.CONVERT(v_label) || '</td>'
              || '<td' || CASE WHEN v_unit = 'cs/s'
                               THEN ' title="centiseconds per second (1/100 s of DB time per elapsed second)"'
                               ELSE '' END
              || '>' || v_unit || '</td>';

        v_row_max := NVL(m.row_max, 0);

        IF v_row_max > 0 AND m.cur_ps IS NOT NULL THEN
            v_pct := LEAST(100, ABS(m.cur_ps) / v_row_max * 100);
        ELSE
            v_pct := 0;
        END IF;

        v_row := v_row || '<td class="num cell-bar" data-w="0"' || fmt_num_title(m.cur_ps) || '>'
              || '<span class="bg" style="width:' || TO_CHAR(v_pct, 'FM990D0') || '%"></span>'
              || '<span class="v"><b>' || fmt_num(m.cur_ps)
              || '</b></span></td>';

        v_bucket := policy_bucket('LOAD', m.stat_name, NULL, m.cur_ps, m.mu, m.sd, m.n_prior);
        v_row := v_row || band_cells(m.cur_ps, m.mu, m.sd, m.n_prior, v_bucket);

        v_row := v_row || '<td class="trend" data-spark="'
              || NVL(m.spark_vals, '') || '" data-spark-title="'
              || DBMS_XMLGEN.CONVERT(v_label) || '"></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_per_sec_s := nth_csv(m.week_vals, k + 1);
            IF v_per_sec_s IS NULL OR v_per_sec_s = '' THEN
                v_row := v_row || '<td class="num" data-w="' || k || '">&mdash;</td>';
            ELSE
                v_per_sec := TO_NUMBER(v_per_sec_s, 'FM99999999990D000000',
                                       'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num" data-w="' || k || '">'
                      || fmt_num(v_per_sec) || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
        v_nrows := v_nrows + 1;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    ------------------------------------------------------------------
    -- plan 043: the time model, what the sessions were doing.  The same
    -- pairs -> bounds -> deltas shape as above over valid_windows (a
    -- skipped window is NULL, never 0); the cross-instance delta is summed
    -- and divided by MAX(dur_sec), dur_sec out of the second GROUP BY.
    ------------------------------------------------------------------
    FOR tmr IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- Fixed, template-independent: the two trees of the 19c Reference
        -- (V$SESS_TIME_MODEL), in tree order.  lvl = depth in its tree,
        -- par = parent, fg F = inside DB time / B = background, wd = the
        -- word that heads the DB time card's evidence row.
        tm_targets AS (
            SELECT  1 AS ord, 1 AS lvl, 'DB time' AS nm, CAST(NULL AS VARCHAR2(64)) AS par, 'F' AS fg, 'DB time' AS wd FROM dual UNION ALL
            SELECT  2, 2, 'DB CPU'                                           , 'DB time'                                   , 'F', 'CPU'        FROM dual UNION ALL
            SELECT  3, 2, 'sql execute elapsed time'                         , 'DB time'                                   , 'F', 'SQL'        FROM dual UNION ALL
            SELECT  4, 2, 'parse time elapsed'                               , 'DB time'                                   , 'F', 'Parse'      FROM dual UNION ALL
            SELECT  5, 3, 'hard parse elapsed time'                          , 'parse time elapsed'                        , 'F', 'Parse'      FROM dual UNION ALL
            SELECT  6, 4, 'hard parse (sharing criteria) elapsed time'       , 'hard parse elapsed time'                   , 'F', 'Parse'      FROM dual UNION ALL
            SELECT  7, 5, 'hard parse (bind mismatch) elapsed time'          , 'hard parse (sharing criteria) elapsed time', 'F', 'Parse'      FROM dual UNION ALL
            SELECT  8, 3, 'failed parse elapsed time'                        , 'parse time elapsed'                        , 'F', 'Parse'      FROM dual UNION ALL
            SELECT  9, 4, 'failed parse (out of shared memory) elapsed time' , 'failed parse elapsed time'                 , 'F', 'Parse'      FROM dual UNION ALL
            SELECT 10, 2, 'PL/SQL execution elapsed time'                    , 'DB time'                                   , 'F', 'PL/SQL'     FROM dual UNION ALL
            SELECT 11, 2, 'PL/SQL compilation elapsed time'                  , 'DB time'                                   , 'F', 'PL/SQL'     FROM dual UNION ALL
            SELECT 12, 2, 'inbound PL/SQL rpc elapsed time'                  , 'DB time'                                   , 'F', 'PL/SQL'     FROM dual UNION ALL
            SELECT 13, 2, 'Java execution elapsed time'                      , 'DB time'                                   , 'F', 'Java'       FROM dual UNION ALL
            SELECT 14, 2, 'connection management call elapsed time'          , 'DB time'                                   , 'F', 'Connection' FROM dual UNION ALL
            SELECT 15, 2, 'sequence load elapsed time'                       , 'DB time'                                   , 'F', 'Sequence'   FROM dual UNION ALL
            SELECT 16, 2, 'repeated bind elapsed time'                       , 'DB time'                                   , 'F', 'Bind'       FROM dual UNION ALL
            SELECT 17, 1, 'background elapsed time'                          , NULL                                        , 'B', 'Background' FROM dual UNION ALL
            SELECT 18, 2, 'background cpu time'                              , 'background elapsed time'                   , 'B', 'Background' FROM dual UNION ALL
            SELECT 19, 3, 'RMAN cpu time (backup/restore)'                   , 'background cpu time'                       , 'B', 'Background' FROM dual
        ),
        tm_pairs AS (
            SELECT w.week_offset, w.dur_sec, t.nm, tm.instance_number,
                   tm.snap_id, tm.value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sys_time_model tm
                ON tm.dbid = w.dbid
               AND tm.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND tm.instance_number = w.instance_number
            JOIN   tm_targets t
                ON LOWER(tm.stat_name) = LOWER(t.nm)
        ),
        tm_bounds AS (
            SELECT week_offset, dur_sec, nm, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   tm_pairs
            GROUP BY week_offset, dur_sec, nm, instance_number
        ),
        tm_deltas AS (
            SELECT week_offset, nm,
                   SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS us,
                   MAX(dur_sec) AS dur_sec
            FROM   tm_bounds
            GROUP BY week_offset, nm
        ),
        tm_facts AS (
            -- microseconds per second / 1e6 = seconds per second = AAS
            SELECT week_offset, nm,
                   CASE WHEN dur_sec > 0 THEN us / 1e6 / dur_sec END AS aas
            FROM   tm_deltas
        ),
        tm_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        tm_grid AS (
            SELECT t.ord, t.lvl, t.nm, t.par, t.fg, t.wd, w.week_offset,
                   f.aas, f.week_offset AS f_wk
            FROM   tm_targets t
            CROSS JOIN tm_weeks w
            LEFT JOIN tm_facts f
                   ON f.nm          = t.nm
                  AND f.week_offset = w.week_offset
        )
        SELECT ord, lvl, nm, par, fg, wd,
               COUNT(f_wk) AS n_found,
               MAX(CASE WHEN week_offset = 0 THEN aas END)      AS cur_v,
               AVG(CASE WHEN week_offset > 0 THEN aas END)      AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN aas END)   AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN aas END)    AS n_prior,
               MAX(ABS(aas))                                    AS amax,
               -- ','||token + SUBSTR: the listagg-null-token rule (a NULL
               -- token keeps its empty slot)
               SUBSTR(LISTAGG(',' || TO_CHAR(aas, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_vals,
               SUBSTR(LISTAGG(',' || TO_CHAR(aas, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals
        FROM   tm_grid
        GROUP BY ord, lvl, nm, par, fg, wd
        ORDER BY ord
    ) LOOP
        v_tm(tmr.ord).ord := tmr.ord;
        v_tm(tmr.ord).lvl := tmr.lvl;
        v_tm(tmr.ord).nm := tmr.nm;
        v_tm(tmr.ord).par := tmr.par;
        v_tm(tmr.ord).fg := tmr.fg;
        v_tm(tmr.ord).wd := tmr.wd;
        v_tm(tmr.ord).n_found := tmr.n_found;
        v_tm(tmr.ord).cur := tmr.cur_v;
        v_tm(tmr.ord).mu := tmr.mu;
        v_tm(tmr.ord).sd := tmr.sd;
        v_tm(tmr.ord).n_prior := tmr.n_prior;
        v_tm(tmr.ord).amax := tmr.amax;
        v_tm(tmr.ord).spark := tmr.spark_vals;
        v_tm(tmr.ord).wv := tmr.week_vals;
        IF tmr.nm = 'DB time' THEN v_tm_dbt := tmr.ord; END IF;
    END LOOP;

    -- the DB-time rise (AAS) the card row's share is a part of
    IF v_tm_dbt IS NOT NULL AND v_tm(v_tm_dbt).cur IS NOT NULL AND v_tm(v_tm_dbt).mu IS NOT NULL THEN
        v_tm_rise := v_tm(v_tm_dbt).cur - v_tm(v_tm_dbt).mu;
    END IF;
    -- the card row: the largest rise (ties: the deeper row); then, as
    -- wording only, the child that carries at least 80% of that rise and
    -- meets the rule too (parse time elapsed -> hard parse elapsed time)
    IF v_tm.COUNT > 0 THEN
        FOR i IN v_tm.FIRST .. v_tm.LAST LOOP
            IF v_tm.EXISTS(i) AND tm_ok(i) THEN
                IF v_tm_pick IS NULL OR tm_rise(i) > v_tm_best
                   OR (tm_rise(i) = v_tm_best AND v_tm(i).lvl > v_tm(v_tm_pick).lvl) THEN
                    v_tm_pick := i;
                    v_tm_best := tm_rise(i);
                END IF;
            END IF;
        END LOOP;
        WHILE v_tm_pick IS NOT NULL LOOP
            v_tm_ch := NULL;
            v_tm_chr := NULL;
            FOR i IN v_tm.FIRST .. v_tm.LAST LOOP
                IF v_tm.EXISTS(i) AND v_tm(i).par = v_tm(v_tm_pick).nm AND tm_ok(i)
                   AND tm_rise(i) >= 0.8 * tm_rise(v_tm_pick)
                   AND (v_tm_chr IS NULL OR tm_rise(i) > v_tm_chr) THEN
                    v_tm_ch := i;
                    v_tm_chr := tm_rise(i);
                END IF;
            END LOOP;
            EXIT WHEN v_tm_ch IS NULL;
            v_tm_pick := v_tm_ch;
        END LOOP;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<h3 id="load-tm-h">Time model: what the sessions were doing</h3>');
    IF v_tm.COUNT = 0 OR v_tm_dbt IS NULL OR v_tm(v_tm_dbt).n_found = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note tm-none">No time model rows (<code>DBA_HIST_SYS_TIME_MODEL</code>) for the compared windows.</p>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p class="note tm-intro">Where DB time went by activity, from the time model'
            || ' (<code>DBA_HIST_SYS_TIME_MODEL</code>), in average active sessions. The rows <b>overlap</b>:'
            || ' an indented row is part of the row above it, and the rows under DB time neither add up to it'
            || ' nor exclude each other, so never add them up. Background rows are outside DB time. Not scored.</p>');
        v_header := '<thead><tr><th>Statistic</th><th class="num" data-w="0">Current (AAS)</th>'
            || '<th class="num" title="Current, as a share of the Current window&#39;s DB time; the rows overlap, so the shares never add up to 100%">% of DB time</th>'
            || band_head || '<th class="trend">Trend</th>';
        FOR k IN 1 .. v_weeks_back LOOP
            v_header := v_header || '<th class="num" data-w="' || k || '">&minus;'
                || off_label(k) || '</th>';
        END LOOP;
        v_header := v_header || '</tr></thead>';
        DBMS_OUTPUT.PUT_LINE('<table id="load-time-model" class="tm-tbl" data-nocount data-nosort>'
            || v_header || '<tbody>');
        FOR i IN v_tm.FIRST .. v_tm.LAST LOOP
            IF NOT v_tm.EXISTS(i) THEN
                NULL;
            ELSIF v_tm(i).n_found = 0 THEN
                v_tm_miss := v_tm_miss || CASE WHEN v_tm_miss IS NOT NULL THEN ', ' END
                    || '<code>' || DBMS_XMLGEN.CONVERT(v_tm(i).nm) || '</code>';
            ELSIF NVL(v_tm(i).amax, 0) = 0 THEN
                v_tm_zero := v_tm_zero || CASE WHEN v_tm_zero IS NOT NULL THEN ', ' END
                    || '<code>' || DBMS_XMLGEN.CONVERT(v_tm(i).nm) || '</code>';
            ELSE
                v_tm_pct := NULL;
                IF v_tm(i).fg = 'B' THEN
                    v_tm_pct := '<td class="num tm-pct" title="background time is outside DB time">&mdash;</td>';
                ELSIF v_tm(i).cur IS NULL OR NVL(v_tm(v_tm_dbt).cur, 0) <= 0 THEN
                    v_tm_pct := '<td class="num tm-pct">&mdash;</td>';
                ELSE
                    v_tm_shr := v_tm(i).cur / v_tm(v_tm_dbt).cur * 100;
                    v_tm_pct := '<td class="num tm-pct">'
                        || CASE WHEN v_tm_shr = 0 THEN '0%'
                                WHEN v_tm_shr < 0.05 THEN '&lt;0.1%'
                                ELSE TO_CHAR(ROUND(v_tm_shr, 1), 'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || '%' END
                        || '</td>';
                END IF;
                v_row := '<tr id="' || anchor_id('tm', v_tm(i).nm) || '" class="tm-l' || v_tm(i).lvl
                    || CASE WHEN v_tm(i).fg = 'B' THEN ' tm-bg' || CASE WHEN v_tm_bg1 THEN ' tm-bg1' END END
                    || '" data-lvl="' || v_tm(i).lvl || '" data-fg="' || v_tm(i).fg || '"'
                    || CASE WHEN v_tm(i).par IS NOT NULL THEN ' data-par="' || anchor_id('tm', v_tm(i).par) || '"' END
                    || ' data-cur="' || tm_tok(v_tm(i).cur) || '" data-mu="' || tm_tok(v_tm(i).mu) || '">'
                    || '<td><span class="tm-n">' || DBMS_XMLGEN.CONVERT(v_tm(i).nm) || '</span></td>'
                    || '<td class="num" data-w="0"' || fmt_num_title(v_tm(i).cur) || '><b>'
                    || fmt_num(v_tm(i).cur) || '</b></td>'
                    || v_tm_pct
                    || band_cells(v_tm(i).cur, v_tm(i).mu, v_tm(i).sd, v_tm(i).n_prior, NULL, 'N', NULL, 'Y')
                    || '<td class="trend" data-spark="' || v_tm(i).spark || '" data-spark-title="'
                    || DBMS_XMLGEN.CONVERT(v_tm(i).nm) || ' (AAS)"></td>';
                IF v_tm(i).fg = 'B' THEN v_tm_bg1 := FALSE; END IF;
                FOR k IN 1 .. v_weeks_back LOOP
                    v_per_sec_s := nth_csv(v_tm(i).wv, k + 1);
                    IF v_per_sec_s IS NULL THEN
                        v_row := v_row || '<td class="num" data-w="' || k || '">&mdash;</td>';
                    ELSE
                        v_per_sec := TO_NUMBER(v_per_sec_s, 'FM99999999990D000000',
                                               'NLS_NUMERIC_CHARACTERS=''.,''');
                        v_row := v_row || '<td class="num" data-w="' || k || '">'
                              || fmt_num(v_per_sec) || '</td>';
                    END IF;
                END LOOP;
                DBMS_OUTPUT.PUT_LINE(v_row || '</tr>');
                v_tm_shown := v_tm_shown + 1;
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        IF v_tm_zero IS NOT NULL OR v_tm_miss IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note tm-drop">'
                || CASE WHEN v_tm_zero IS NOT NULL THEN 'Not shown, zero in every window: ' || v_tm_zero || '.' END
                || CASE WHEN v_tm_zero IS NOT NULL AND v_tm_miss IS NOT NULL THEN ' ' END
                || CASE WHEN v_tm_miss IS NOT NULL
                        THEN 'Not found in <code>DBA_HIST_SYS_TIME_MODEL</code> for the compared windows: '
                             || v_tm_miss || '.' END
                || '</p>');
        END IF;

        -- the DB time card's evidence row (hidden here; moved by the script)
        IF v_tm_pick IS NOT NULL THEN
            v_tm_shr := ROUND(tm_rise(v_tm_pick) / v_tm_rise * 100);
            DBMS_OUTPUT.PUT_LINE('<div id="tm-ev-src" hidden><div class="evr ev-tm" data-tm="'
                || anchor_id('tm', v_tm(v_tm_pick).nm) || '" data-cur="' || tm_tok(v_tm(v_tm_pick).cur)
                || '" data-mu="' || tm_tok(v_tm(v_tm_pick).mu) || '" data-rise="' || tm_tok(v_tm_rise)
                || '" title="Time model (DBA_HIST_SYS_TIME_MODEL): the activity whose time rose most, besides DB CPU and SQL execution.'
                || ' Its time is part of DB time and overlaps the other rows of the time model. Not scored.">'
                || '<dt>' || DBMS_XMLGEN.CONVERT(v_tm(v_tm_pick).wd) || '</dt><dd><span class="id txt">'
                || ent(DBMS_XMLGEN.CONVERT(v_tm(v_tm_pick).nm), anchor_id('tm', v_tm(v_tm_pick).nm), 'metric')
                || '</span><span class="de">'
                || nbu(fv(v_tm(v_tm_pick).cur, 'AAS') || ', was ' || fv(v_tm(v_tm_pick).mu, 'AAS') || '; '
                       || CASE WHEN v_tm_shr > 100 THEN 'more than the whole DB-time rise'
                               WHEN v_tm_shr < 1 THEN 'under 1% of the DB-time rise'
                               ELSE TO_CHAR(v_tm_shr) || '% of the DB-time rise' END)
                || '</span></dd><div class="m">' || delta_span(v_tm(v_tm_pick).cur, v_tm(v_tm_pick).mu, NULL, 'Y')
                || band_span(band_z(v_tm(v_tm_pick).cur, v_tm(v_tm_pick).mu, v_tm(v_tm_pick).sd), NULL, 'sm', 'N', 10)
                || '<span class="ns">not scored</span></div></div></div>');
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,x=d.getElementById("tm-ev-src");if(!x)return;'
                || 'var c=d.getElementById("f-dbtime"),dl=c?c.querySelector("dl.ev"):null;'
                || 'if(dl){while(x.firstChild)dl.appendChild(x.firstChild);}x.parentNode.removeChild(x);})();</script>');
            v_tm_ls := '; time model: ' || DBMS_XMLGEN.CONVERT(v_tm(v_tm_pick).nm) || ' +'
                || fmt_num(tm_rise(v_tm_pick)) || '&nbsp;AAS';
        END IF;
    END IF;

    -- the evidence library's row text (Summary view)
    DBMS_OUTPUT.PUT_LINE(lib_ls('load', v_nrows || ' counters per second' || v_tm_ls) || '</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 02_load_profile END -->'); END;
/
