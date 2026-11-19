--
-- 22_wait_histogram.sql
-- Wait latency histograms: the SHAPE of the top foreground waits, Current
-- window vs the prior valid windows.  An average of 4 ms can hide 2% of
-- reads taking 500 ms; this section shows whether every wait got a little
-- slower, or a slow tail appeared.
--
-- Source: DBA_HIST_EVENT_HISTOGRAM (cumulative wait_count per power-of-two
-- latency bucket since instance startup; wait_time_milli = the bucket's
-- upper bound in ms, 19c also carries the sub-ms buckets down to about
-- 1 microsecond).  Per compared window: pairs -> bounds -> deltas per
-- (event, bucket), end minus begin per instance (a bucket missing from
-- one snapshot never yields a negative delta: GREATEST(0, ...)), summed
-- across instances, valid windows only.
--
-- THE VIEW IS NOT IN THE README GRANT LIST, so it is read through dynamic
-- SQL with binds inside a block that catches ORA-00942 / ORA-01031 and
-- renders a "needs SELECT on" note; a missing grant never aborts the
-- report.  The windows (windows_cte) and the event list (section 04's
-- ranking over DBA_HIST_SYSTEM_EVENT, template wait list, Idle excluded)
-- are resolved first with static SQL.
--
-- Events: the top foreground events of the Current window by time waited,
-- section 04's order, at most LEAST(8, top_n), each linked to its 04 row.
-- Per event: Current share per bucket vs the mean share over the prior
-- valid windows with at least 30 waits (the normal shape) and their
-- min-max band, by count and by approximate time (count x bucket
-- midpoint).  Fixed classification rules on the COUNT percentile buckets
-- (one bucket = a factor of two):
--   too few      Current < 30 waits
--   no prior     fewer than 2 prior valid windows with >= 30 waits
--   tail         p95 bucket >= 2 above normal, median moved <= 1
--   slower       median bucket >= 2 above normal
--   faster       median bucket >= 2 below normal
--   tail gone    p95 bucket >= 2 below normal, median moved <= 1
--   volume       otherwise, count ratio >= 2 or <= 0.5
--   same         otherwise
-- It explains; it adds no finding and no severity.
--
-- Payload: window.AWR_DATA.waithist (see sql/lib/src/js_waithist.js).
-- Twin: demo/awrdemo/sections/s22_wait_histogram.py.  Read-only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 22_wait_histogram BEGIN -->'); END;
/

DECLARE
    c_min_n   CONSTANT PLS_INTEGER := 30;     -- waits needed to compare a shape
    c_kmin    CONSTANT PLS_INTEGER := -10;    -- lowest bucket (about 1 us)
    c_kmax    CONSTANT PLS_INTEGER := 40;     -- buckets above fold into this one
    v_top_n   NUMBER := ~top_n;
    v_cap     PLS_INTEGER;

    TYPE t_win_rec IS RECORD (
        wo    NUMBER, dbid NUMBER, inst NUMBER, b_snap NUMBER, e_snap NUMBER);
    TYPE t_win_tab IS TABLE OF t_win_rec;
    v_wins    t_win_tab;

    TYPE t_ev_rec IS RECORD (
        event_name VARCHAR2(64), wait_class VARCHAR2(64),
        cur_waits NUMBER, cur_us NUMBER, avg_nrm_ms NUMBER);
    TYPE t_ev_tab IS TABLE OF t_ev_rec;
    v_evs     t_ev_tab;

    TYPE t_num_map IS TABLE OF NUMBER INDEX BY VARCHAR2(40);
    TYPE t_idx_map IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);
    TYPE t_arr     IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_lines   IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    v_h       t_num_map;          -- 'e|wo|k' -> waits in that bucket
    v_ix      t_idx_map;          -- event name -> index in v_evs
    v_offs    t_arr;              -- distinct valid offsets, ascending
    v_n_offs  PLS_INTEGER := 0;
    v_n_prior PLS_INTEGER := 0;   -- valid prior offsets
    v_cur_ok  BOOLEAN := FALSE;   -- Current window valid

    v_evlist  sys.odcivarchar2list := sys.odcivarchar2list();
    v_sql     VARCHAR2(4000);
    v_cur     SYS_REFCURSOR;
    v_names   sys.odcivarchar2list;
    v_milli   sys.odcinumberlist;
    v_beg     sys.odcinumberlist;
    v_end     sys.odcinumberlist;
    v_nogrant VARCHAR2(200);
    v_key     VARCHAR2(40);
    v_k       PLS_INTEGER;
    v_d       NUMBER;

    -- per-event work arrays (k = c_kmin .. c_kmax)
    a_cc t_arr; a_ct t_arr; a_nc t_arr; a_nt t_arr;
    a_lc t_arr; a_hc t_arr; a_lt t_arr; a_ht t_arr;
    a_wc t_arr; a_wt t_arr;
    v_tot     NUMBER;
    v_ttot    NUMBER;
    v_cur_n   NUMBER;
    v_cur_t   NUMBER;
    v_np      PLS_INTEGER;
    v_sum_n   NUMBER;             -- prior waits summed over every valid prior window
    v_nrm_n   NUMBER;
    v_ratio   NUMBER;
    v_cp50    PLS_INTEGER; v_cp95 PLS_INTEGER;
    v_np50    PLS_INTEGER; v_np95 PLS_INTEGER;
    v_cls     VARCHAR2(10);
    v_word    VARCHAR2(400);
    v_head    VARCHAR2(1000);
    v_glyph   VARCHAR2(20);
    v_lo      PLS_INTEGER;
    v_hi      PLS_INTEGER;
    v_m       NUMBER;
    v_avg_cur NUMBER;
    v_sub     VARCHAR2(1000);
    v_id      VARCHAR2(100);
    v_json    VARCHAR2(32767);
    v_labs    VARCHAR2(4000);
    v_rngs    VARCHAR2(4000);
    v_jcc VARCHAR2(4000); v_jct VARCHAR2(4000); v_jnc VARCHAR2(4000); v_jnt VARCHAR2(4000);
    v_jlc VARCHAR2(4000); v_jhc VARCHAR2(4000); v_jlt VARCHAR2(4000); v_jht VARCHAR2(4000);
    s_cc NUMBER; s_ct NUMBER; s_nc NUMBER; s_nt NUMBER;
    s_lc NUMBER; s_hc NUMBER; s_lt NUMBER; s_ht NUMBER;
    v_cards   t_lines;
    v_rows    t_lines;
    v_jsons   t_lines;
    v_n_rows  PLS_INTEGER := 0;
    v_changed VARCHAR2(4000);     -- lib_ls / reads-as: the changed events
    v_n_chg   PLS_INTEGER := 0;
    v_n_same  PLS_INTEGER := 0;
    v_n_vol   PLS_INTEGER := 0;
    v_n_few   PLS_INTEGER := 0;
    v_n_nop   PLS_INTEGER := 0;
    v_reads   VARCHAR2(4000);
    v_first   BOOLEAN;

    -- include order: fmt_num -> band_glyph -> anchor_id -> finding_cards
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/json_escape.plsql

    -- NLS-safe JSON number (4 decimals for shares, rounded otherwise)
    FUNCTION jn(p NUMBER, p_dec PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        RETURN RTRIM(TO_CHAR(ROUND(p, p_dec), 'FM999999999999990D99999',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END jn;
    -- a share as a percentage with one decimal ("12.3%")
    FUNCTION pc(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        RETURN RTRIM(TO_CHAR(ROUND(p * 100, 1), 'FM9990D0',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.') || '%';
    END pc;
    -- a bucket bound 2^k ms as text; p_mu = the micro sign (HTML entity or
    -- a JS escape, so the emitted text stays ASCII)
    FUNCTION bnd(p_k PLS_INTEGER, p_mu VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_k < 0 THEN
            RETURN TO_CHAR(ROUND(1000 * POWER(2, p_k))) || ' ' || p_mu || 's';
        ELSIF p_k < 10 THEN
            RETURN TO_CHAR(POWER(2, p_k)) || ' ms';
        END IF;
        RETURN TO_CHAR(POWER(2, p_k - 10)) || ' s';
    END bnd;
    -- the bucket ending at 2^k as a range ("4-8 ms", "500 us-1 ms")
    FUNCTION brng(p_k PLS_INTEGER, p_mu VARCHAR2) RETURN VARCHAR2 IS
        v_a VARCHAR2(40) := bnd(p_k - 1, p_mu);
        v_b VARCHAR2(40) := bnd(p_k, p_mu);
    BEGIN
        IF p_k <= c_kmin THEN RETURN 'under ' || v_b; END IF;
        IF SUBSTR(v_a, INSTR(v_a, ' ')) = SUBSTR(v_b, INSTR(v_b, ' ')) THEN
            v_a := SUBSTR(v_a, 1, INSTR(v_a, ' ') - 1);
        END IF;
        RETURN v_a || '-' || v_b;
    END brng;
    -- an average wait in ms, as ms or s
    FUNCTION fms(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        IF p >= 1000 THEN RETURN fmt_num(p / 1000) || ' s'; END IF;
        RETURN fmt_num(p) || ' ms';
    END fms;
    -- a ratio as "2.3x" (two significant digits, whole numbers past 10)
    FUNCTION rx(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p >= 10 THEN fmt_int(ROUND(p))
                    WHEN p >= 1  THEN TO_CHAR(ROUND(p, 1), 'FM990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                    ELSE TO_CHAR(ROUND(p, 2), 'FM0D00', 'NLS_NUMERIC_CHARACTERS=''.,''') END || 'x';
    END rx;
    -- approximate wait of one wait in bucket k (ms): the bucket midpoint
    FUNCTION mid(p_k PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        RETURN CASE WHEN p_k <= c_kmin THEN 0.5 ELSE 0.75 END * POWER(2, LEAST(p_k, 22));
    END mid;
BEGIN
    v_cap := LEAST(8, v_top_n);

    -- ---- 1. the compared windows (static SQL)
    SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
    BULK COLLECT INTO v_wins
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
        FROM   valid_windows
    )
    ORDER BY week_offset, instance_number;
    FOR i IN 1 .. v_wins.COUNT LOOP
        IF v_n_offs = 0 OR v_offs(v_n_offs) <> v_wins(i).wo THEN
            v_n_offs := v_n_offs + 1;
            v_offs(v_n_offs) := v_wins(i).wo;
            IF v_wins(i).wo = 0 THEN v_cur_ok := TRUE; ELSE v_n_prior := v_n_prior + 1; END IF;
        END IF;
    END LOOP;

    -- ---- 2. the events: section 04's Current ranking (static SQL)
    WITH
    @@sql/lib/windows_cte.sql
    ,
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    pairs AS (
        SELECT w.week_offset, se.event_name, se.wait_class,
               se.snap_id, se.instance_number,
               se.total_waits, se.time_waited_micro,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
           AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                 OR se.event_name IN (SELECT event_name FROM wait_targets) )
    ),
    bounds AS (
        SELECT week_offset, instance_number, event_name, wait_class,
               SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
               SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   pairs
        GROUP BY week_offset, instance_number, event_name, wait_class
    ),
    deltas AS (
        SELECT week_offset, event_name, wait_class,
               SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
               SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
        FROM   bounds
        GROUP BY week_offset, event_name, wait_class
    ),
    cur AS (
        SELECT event_name, wait_class, total_waits, time_waited_us,
               RANK() OVER (ORDER BY time_waited_us DESC) AS rnk
        FROM   deltas
        WHERE  week_offset = 0 AND time_waited_us > 0
    ),
    pick AS (
        SELECT event_name, wait_class, total_waits, time_waited_us
        FROM   cur
        WHERE  rnk <= (SELECT top_n FROM run_params)
        ORDER BY time_waited_us DESC, event_name
        FETCH FIRST 8 ROWS ONLY
    )
    SELECT p.event_name, p.wait_class, p.total_waits, p.time_waited_us,
           (SELECT AVG(d.time_waited_us / d.total_waits / 1000)
            FROM   deltas d
            WHERE  d.event_name = p.event_name AND d.week_offset > 0
              AND  d.total_waits > 0) AS avg_nrm_ms
    BULK COLLECT INTO v_evs
    FROM   pick p
    ORDER BY p.time_waited_us DESC, p.event_name;
    WHILE v_evs.COUNT > v_cap LOOP v_evs.TRIM; END LOOP;

    FOR i IN 1 .. v_evs.COUNT LOOP
        v_ix(v_evs(i).event_name) := i;
        v_evlist.EXTEND;
        v_evlist(i) := v_evs(i).event_name;
    END LOOP;

    -- ---- 3. the histograms (dynamic SQL: the view may not be granted)
    IF v_evs.COUNT > 0 THEN
        v_sql := 'SELECT event_name, wait_time_milli,'
            || ' SUM(CASE WHEN snap_id = :1 THEN wait_count END),'
            || ' SUM(CASE WHEN snap_id = :2 THEN wait_count END)'
            || ' FROM dba_hist_event_histogram'
            || ' WHERE dbid = :3 AND instance_number = :4 AND snap_id IN (:5, :6)'
            || ' AND event_name IN (SELECT column_value FROM TABLE(:7))'
            || ' GROUP BY event_name, wait_time_milli';
        BEGIN
            FOR i IN 1 .. v_wins.COUNT LOOP
                OPEN v_cur FOR v_sql USING v_wins(i).b_snap, v_wins(i).e_snap,
                    v_wins(i).dbid, v_wins(i).inst, v_wins(i).b_snap, v_wins(i).e_snap, v_evlist;
                FETCH v_cur BULK COLLECT INTO v_names, v_milli, v_beg, v_end;
                CLOSE v_cur;
                FOR j IN 1 .. v_names.COUNT LOOP
                    v_d := GREATEST(0, NVL(v_end(j), 0) - NVL(v_beg(j), 0));
                    IF v_d > 0 AND v_milli(j) > 0 THEN
                        v_k := GREATEST(c_kmin, LEAST(c_kmax, ROUND(LN(v_milli(j)) / LN(2))));
                        v_key := v_ix(v_names(j)) || '|' || v_wins(i).wo || '|' || v_k;
                        IF v_h.EXISTS(v_key) THEN v_h(v_key) := v_h(v_key) + v_d;
                        ELSE v_h(v_key) := v_d; END IF;
                    END IF;
                END LOOP;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE IN (-942, -1031) THEN
                    IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                    v_nogrant := SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END IF;

    -- ---- 4. per event: shapes, percentiles, classification, markup
    IF v_nogrant IS NULL AND v_cur_ok THEN
    FOR e IN 1 .. v_evs.COUNT LOOP
        FOR k IN c_kmin .. c_kmax LOOP
            a_cc(k) := 0; a_ct(k) := 0; a_nc(k) := 0; a_nt(k) := 0;
            a_lc(k) := NULL; a_hc(k) := NULL; a_lt(k) := NULL; a_ht(k) := NULL;
        END LOOP;
        v_np := 0; v_sum_n := 0; v_cur_n := 0; v_cur_t := 0;
        FOR o IN 1 .. v_n_offs LOOP
            v_tot := 0; v_ttot := 0;
            FOR k IN c_kmin .. c_kmax LOOP
                v_key := e || '|' || v_offs(o) || '|' || k;
                a_wc(k) := CASE WHEN v_h.EXISTS(v_key) THEN v_h(v_key) ELSE 0 END;
                a_wt(k) := a_wc(k) * mid(k);
                v_tot := v_tot + a_wc(k); v_ttot := v_ttot + a_wt(k);
            END LOOP;
            IF v_offs(o) = 0 THEN
                FOR k IN c_kmin .. c_kmax LOOP a_cc(k) := a_wc(k); a_ct(k) := a_wt(k); END LOOP;
                v_cur_n := v_tot; v_cur_t := v_ttot;
            ELSE
                -- a valid prior window without a row is zero waits (counts
                -- toward the volume); its shape needs c_min_n waits
                v_sum_n := v_sum_n + v_tot;
                IF v_tot >= c_min_n THEN
                    v_np := v_np + 1;
                    FOR k IN c_kmin .. c_kmax LOOP
                        a_nc(k) := a_nc(k) + a_wc(k) / v_tot;
                        a_nt(k) := a_nt(k) + a_wt(k) / v_ttot;
                        a_lc(k) := LEAST(NVL(a_lc(k), 1), a_wc(k) / v_tot);
                        a_hc(k) := GREATEST(NVL(a_hc(k), 0), a_wc(k) / v_tot);
                        a_lt(k) := LEAST(NVL(a_lt(k), 1), a_wt(k) / v_ttot);
                        a_ht(k) := GREATEST(NVL(a_ht(k), 0), a_wt(k) / v_ttot);
                    END LOOP;
                END IF;
            END IF;
        END LOOP;
        IF v_np > 0 THEN
            FOR k IN c_kmin .. c_kmax LOOP
                a_nc(k) := a_nc(k) / v_np; a_nt(k) := a_nt(k) / v_np;
            END LOOP;
        END IF;
        v_nrm_n := CASE WHEN v_n_prior > 0 THEN v_sum_n / v_n_prior END;
        v_ratio := CASE WHEN v_nrm_n > 0 THEN v_cur_n / v_nrm_n END;

        -- percentile buckets (count): first bucket whose cumulative share
        -- reaches 50% / 95%
        v_cp50 := NULL; v_cp95 := NULL; v_np50 := NULL; v_np95 := NULL;
        s_cc := 0; s_nc := 0;
        FOR k IN c_kmin .. c_kmax LOOP
            s_cc := s_cc + a_cc(k); s_nc := s_nc + a_nc(k);
            IF v_cur_n > 0 THEN
                IF v_cp50 IS NULL AND s_cc >= 0.5  * v_cur_n THEN v_cp50 := k; END IF;
                IF v_cp95 IS NULL AND s_cc >= 0.95 * v_cur_n THEN v_cp95 := k; END IF;
            END IF;
            IF v_np > 0 THEN
                IF v_np50 IS NULL AND s_nc >= 0.5  - 1e-9 THEN v_np50 := k; END IF;
                IF v_np95 IS NULL AND s_nc >= 0.95 - 1e-9 THEN v_np95 := k; END IF;
            END IF;
        END LOOP;

        -- classification (fixed rules, see the header)
        IF v_cur_n < c_min_n THEN
            v_cls := 'few';  v_glyph := '&middot;';
            v_word := 'too few waits';
            v_head := 'too few waits to compare shapes (' || fmt_int(v_cur_n) || ' in the Current window)';
            v_n_few := v_n_few + 1;
        ELSIF v_np < 2 THEN
            v_cls := 'nop';  v_glyph := '&middot;';
            v_word := 'no prior shape';
            v_head := CASE WHEN v_np = 0 THEN 'no prior window'
                           ELSE 'only one prior window' END
                || ' with ' || c_min_n || ' or more waits: too little history to call a change';
            v_n_nop := v_n_nop + 1;
        ELSIF v_cp95 - v_np95 >= 2 AND ABS(v_cp50 - v_np50) <= 1 THEN
            v_cls := 'tail'; v_glyph := '&#9650;'; v_word := 'slow tail';
            v_head := 'a slow tail appeared: p95 moved from the ' || brng(v_np95, '&micro;')
                || ' bucket to the ' || brng(v_cp95, '&micro;') || ' bucket, the median stayed at '
                || brng(v_cp50, '&micro;');
        ELSIF v_cp50 - v_np50 >= 2 THEN
            v_cls := 'up';   v_glyph := '&#9650;'; v_word := 'shifted slower';
            v_head := 'the whole distribution moved slower: median from ' || brng(v_np50, '&micro;')
                || ' to ' || brng(v_cp50, '&micro;') || ', p95 from ' || brng(v_np95, '&micro;')
                || ' to ' || brng(v_cp95, '&micro;');
        ELSIF v_np50 - v_cp50 >= 2 THEN
            v_cls := 'down'; v_glyph := '&#9660;'; v_word := 'shifted faster';
            v_head := 'the whole distribution moved faster: median from ' || brng(v_np50, '&micro;')
                || ' to ' || brng(v_cp50, '&micro;') || ', p95 from ' || brng(v_np95, '&micro;')
                || ' to ' || brng(v_cp95, '&micro;');
        ELSIF v_np95 - v_cp95 >= 2 THEN
            v_cls := 'gone'; v_glyph := '&#9660;'; v_word := 'tail gone';
            v_head := 'the slow tail went away: p95 moved from the ' || brng(v_np95, '&micro;')
                || ' bucket to the ' || brng(v_cp95, '&micro;') || ' bucket';
        ELSIF v_ratio >= 2 OR v_ratio <= 0.5 THEN
            v_cls := 'vol';  v_glyph := '&times;'; v_word := 'volume only';
            v_head := 'shape unchanged, ' || rx(v_ratio) || ' '
                || CASE WHEN v_ratio >= 2 THEN 'more waits' ELSE 'the waits' END
                || ' (p95 in the ' || brng(v_cp95, '&micro;') || ' bucket)';
            v_n_vol := v_n_vol + 1;
        ELSE
            v_cls := 'same'; v_glyph := '='; v_word := 'shape unchanged';
            v_head := 'shape unchanged: median ' || brng(v_cp50, '&micro;') || ', p95 '
                || brng(v_cp95, '&micro;');
            v_n_same := v_n_same + 1;
        END IF;
        IF v_cls IN ('tail', 'up', 'down', 'gone') THEN
            v_n_chg := v_n_chg + 1;
            IF v_n_chg <= 2 THEN
                v_changed := v_changed || CASE WHEN v_n_chg > 1 THEN '; ' END
                    || '<b>' || DBMS_XMLGEN.CONVERT(v_evs(e).event_name) || '</b>: '
                    || CASE v_cls WHEN 'tail' THEN 'a slow tail appeared (p95 '
                                  WHEN 'up'   THEN 'every wait got slower (median '
                                  WHEN 'down' THEN 'every wait got faster (median '
                                  ELSE 'the slow tail went away (p95 ' END
                    || CASE WHEN v_cls IN ('tail', 'gone')
                            THEN bnd(v_np95, '&micro;') || ' &rarr; ' || bnd(v_cp95, '&micro;')
                            ELSE bnd(v_np50, '&micro;') || ' &rarr; ' || bnd(v_cp50, '&micro;') END
                    || ')';
            END IF;
        END IF;

        -- display range: the buckets that hold anything worth seeing, at
        -- least 8 wide, at most 20; everything outside folds into the ends
        v_lo := NULL; v_hi := NULL;
        FOR k IN c_kmin .. c_kmax LOOP
            v_m := GREATEST(CASE WHEN v_cur_n > 0 THEN a_cc(k) / v_cur_n ELSE 0 END,
                            CASE WHEN v_cur_t > 0 THEN a_ct(k) / v_cur_t ELSE 0 END,
                            a_nc(k), a_nt(k), NVL(a_hc(k), 0), NVL(a_ht(k), 0));
            IF v_m >= 0.002 AND v_lo IS NULL THEN v_lo := k; END IF;
            IF v_m >= 0.001 THEN v_hi := k; END IF;
        END LOOP;
        v_lo := NVL(v_lo, 0); v_hi := GREATEST(NVL(v_hi, v_lo), v_lo);
        IF v_cp50 IS NOT NULL THEN v_lo := LEAST(v_lo, v_cp50); v_hi := GREATEST(v_hi, v_cp95); END IF;
        IF v_np50 IS NOT NULL THEN v_lo := LEAST(v_lo, v_np50); v_hi := GREATEST(v_hi, v_np95); END IF;
        IF v_hi - v_lo > 19 THEN v_lo := v_hi - 19; END IF;
        WHILE v_hi - v_lo < 7 LOOP
            IF v_hi < c_kmax THEN v_hi := v_hi + 1; ELSE v_lo := v_lo - 1; END IF;
        END LOOP;

        -- payload arrays + table rows over the display buckets
        v_id := anchor_id('we', v_evs(e).event_name);
        v_labs := ''; v_rngs := '';
        v_jcc := ''; v_jct := ''; v_jnc := ''; v_jnt := '';
        v_jlc := ''; v_jhc := ''; v_jlt := ''; v_jht := '';
        FOR b IN v_lo .. v_hi LOOP
            s_cc := 0; s_ct := 0; s_nc := 0; s_nt := 0;
            s_lc := 0; s_hc := 0; s_lt := 0; s_ht := 0;
            FOR k IN CASE WHEN b = v_lo THEN c_kmin ELSE b END
                  .. CASE WHEN b = v_hi THEN c_kmax ELSE b END LOOP
                s_cc := s_cc + a_cc(k); s_ct := s_ct + a_ct(k);
                s_nc := s_nc + a_nc(k); s_nt := s_nt + a_nt(k);
                s_lc := s_lc + NVL(a_lc(k), 0); s_hc := s_hc + NVL(a_hc(k), 0);
                s_lt := s_lt + NVL(a_lt(k), 0); s_ht := s_ht + NVL(a_ht(k), 0);
            END LOOP;
            -- (a folded end's band is the sum of its buckets' min / max: a
            -- bound, not one window's value; capped at 100%)
            s_hc := LEAST(s_hc, 1); s_ht := LEAST(s_ht, 1);
            v_first := (b = v_lo);
            v_labs := v_labs || CASE WHEN NOT v_first THEN ',' END || '"'
                || CASE WHEN b = v_lo THEN '<' || bnd(b, '\' || 'u00b5')
                        WHEN b = v_hi THEN '>' || bnd(b - 1, '\' || 'u00b5')
                        ELSE bnd(b, '\' || 'u00b5') END || '"';
            v_rngs := v_rngs || CASE WHEN NOT v_first THEN ',' END || '"'
                || CASE WHEN b = v_lo THEN 'under ' || bnd(b, '\' || 'u00b5')
                        WHEN b = v_hi THEN 'at least ' || bnd(b - 1, '\' || 'u00b5')
                        ELSE brng(b, '\' || 'u00b5') END || '"';
            v_jcc := v_jcc || CASE WHEN NOT v_first THEN ',' END || jn(s_cc, 0);
            v_jct := v_jct || CASE WHEN NOT v_first THEN ',' END || jn(s_ct, 3);
            v_jnc := v_jnc || CASE WHEN NOT v_first THEN ',' END || jn(s_nc, 5);
            v_jnt := v_jnt || CASE WHEN NOT v_first THEN ',' END || jn(s_nt, 5);
            v_jlc := v_jlc || CASE WHEN NOT v_first THEN ',' END || jn(s_lc, 5);
            v_jhc := v_jhc || CASE WHEN NOT v_first THEN ',' END || jn(s_hc, 5);
            v_jlt := v_jlt || CASE WHEN NOT v_first THEN ',' END || jn(s_lt, 5);
            v_jht := v_jht || CASE WHEN NOT v_first THEN ',' END || jn(s_ht, 5);
            v_n_rows := v_n_rows + 1;
            v_rows(v_n_rows) := '<tr' || CASE WHEN v_first THEN ' class="whfirst"' END || '><td>'
                || CASE WHEN v_first
                        THEN ent(DBMS_XMLGEN.CONVERT(v_evs(e).event_name), v_id, 'event')
                        ELSE '<span class="whdim">' || DBMS_XMLGEN.CONVERT(v_evs(e).event_name) || '</span>' END
                || '</td><td>'
                || CASE WHEN b = v_lo THEN 'under ' || bnd(b, '&micro;')
                        WHEN b = v_hi THEN 'at least ' || bnd(b - 1, '&micro;')
                        ELSE brng(b, '&micro;') END
                || '</td><td class="num" data-w="0">' || fmt_int(s_cc)
                || '</td><td class="num" data-w="0">' || CASE WHEN v_cur_n > 0 THEN pc(s_cc / v_cur_n) ELSE '&mdash;' END
                || '</td><td class="num">' || CASE WHEN v_np > 0 THEN pc(s_nc) ELSE '&mdash;' END
                || '</td><td class="num">' || CASE WHEN v_np > 0 THEN pc(s_lc) || '&ndash;' || pc(s_hc) ELSE '&mdash;' END
                || '</td><td class="num" data-w="0">' || CASE WHEN v_cur_t > 0 THEN pc(s_ct / v_cur_t) ELSE '&mdash;' END
                || '</td><td class="num">' || CASE WHEN v_np > 0 THEN pc(s_nt) ELSE '&mdash;' END
                || '</td></tr>';
        END LOOP;

        v_avg_cur := CASE WHEN v_evs(e).cur_waits > 0
                          THEN v_evs(e).cur_us / v_evs(e).cur_waits / 1000 END;
        v_sub := 'avg ' || CASE WHEN v_evs(e).avg_nrm_ms IS NOT NULL
                                THEN fms(v_evs(e).avg_nrm_ms) || ' &rarr; ' END
            || fms(v_avg_cur) || ' &middot; ' || fmt_int(v_cur_n) || ' waits'
            || CASE WHEN v_ratio IS NOT NULL THEN ' (' || rx(v_ratio) || ' normal)' END
            || CASE WHEN v_np > 0 THEN ' &middot; normal from ' || v_np || ' prior window'
                    || CASE WHEN v_np > 1 THEN 's' END END;

        v_cards(e) := '<article class="whc whc-' || v_cls || '" data-i="' || (e - 1) || '">'
            || '<h3>' || ent(DBMS_XMLGEN.CONVERT(v_evs(e).event_name), v_id, 'event')
            || ' <small>' || DBMS_XMLGEN.CONVERT(v_evs(e).wait_class) || '</small></h3>'
            || '<p class="whs">' || v_sub || '</p>'
            || '<p class="whw"><span class="whk"><i>' || v_glyph || '</i> ' || v_word || '</span> '
            || v_head || '</p>'
            || '<div class="whp"></div></article>';

        v_jsons(e) := '{"n":"' || json_escape(v_evs(e).event_name) || '","cl":"'
            || json_escape(v_evs(e).wait_class) || '","k":"' || v_cls
            || '","nc":' || jn(v_cur_n, 0) || ',"nn":' || jn(v_nrm_n, 1)
            || ',"np":' || v_np
            || ',"lab":[' || v_labs || '],"rg":[' || v_rngs || ']'
            || ',"cc":[' || v_jcc || '],"ct":[' || v_jct || ']'
            || ',"mc":[' || v_jnc || '],"mt":[' || v_jnt || ']'
            || ',"lc":[' || v_jlc || '],"hc":[' || v_jhc || ']'
            || ',"lt":[' || v_jlt || '],"ht":[' || v_jht || ']}';
    END LOOP;
    END IF;

    -- ---- 5. emit
    DBMS_OUTPUT.PUT_LINE('<section id="wait-hist" class="vw in-s in-a lib'
        || CASE WHEN v_n_chg > 0 THEN ' lopen' END
        || '" style="--os:12"><h2>Wait latency histograms'
        || '<small class="h2sub">The shape of each wait the averages hide</small></h2>');

    IF v_nogrant IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">The latency histograms need SELECT on '
            || '<code>DBA_HIST_EVENT_HISTOGRAM</code> (' || DBMS_XMLGEN.CONVERT(v_nogrant)
            || '). Every other section is unaffected.</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('wait-hist', 'needs SELECT on DBA_HIST_EVENT_HISTOGRAM'));
    ELSIF NOT v_cur_ok THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">The Current window was skipped (see Windows), '
            || 'so there is no Current shape to compare.</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('wait-hist', 'Current window skipped'));
    ELSIF v_evs.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">No foreground wait time in the Current window.</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('wait-hist', 'no foreground waits in the Current window'));
    ELSE
        -- the reads-as sentence (also the library row text)
        IF v_n_chg > 0 THEN
            v_reads := v_changed
                || CASE WHEN v_n_chg > 2 THEN '; ' || (v_n_chg - 2) || ' more changed shape' END
                || CASE WHEN v_n_same + v_n_vol > 0
                        THEN '; ' || (v_n_same + v_n_vol) || ' other event'
                             || CASE WHEN v_n_same + v_n_vol > 1 THEN 's' END
                             || ' unchanged in shape' END;
        ELSIF v_n_same + v_n_vol > 0 THEN
            v_reads := 'the top ' || CASE WHEN v_n_same + v_n_vol > 1 THEN (v_n_same + v_n_vol) || ' ' END
                || 'wait' || CASE WHEN v_n_same + v_n_vol > 1 THEN 's' END
                || ' kept ' || CASE WHEN v_n_same + v_n_vol > 1 THEN 'their' ELSE 'its' END || ' shape'
                || CASE WHEN v_n_vol > 0 THEN ' (' || v_n_vol || ' changed only in volume)' END;
        ELSIF v_n_nop > 0 THEN
            v_reads := 'too little prior history to compare shapes';
        ELSE
            v_reads := 'too few waits in the Current window to compare shapes';
        END IF;
        IF v_n_few > 0 AND (v_n_chg > 0 OR v_n_same + v_n_vol > 0) THEN
            v_reads := v_reads || '; ' || v_n_few || ' with too few waits';
        END IF;
        DBMS_OUTPUT.PUT_LINE(lib_ls('wait-hist', v_reads));

        DBMS_OUTPUT.PUT_LINE('<div class="whbar"><div class="whseg" role="group" aria-label="Weight the buckets by" hidden>'
            || '<button type="button" data-m="c" aria-pressed="true">By count</button>'
            || '<button type="button" data-m="t" aria-pressed="false">By time</button></div>'
            || '<span class="whlg"><i class="whsw whsw-c"></i>Current window</span>'
            || '<span class="whlg"><i class="whsw whsw-n"></i>normal (mean of prior windows)</span>'
            || '<span class="whlg"><i class="whsw whsw-b"></i>prior min&ndash;max</span>'
            || '<span class="whlg"><i class="whsw whsw-p"></i>median and p95</span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="whg">');
        FOR e IN 1 .. v_evs.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE(v_cards(e));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
        DBMS_OUTPUT.PUT_LINE('<p class="whr"><b>Reads as:</b> ' || v_reads || '.</p>');
        DBMS_OUTPUT.PUT_LINE('<p class="whn">Buckets are Oracle&rsquo;s power-of-two latency bins '
            || '(each twice as wide as the one before; &ldquo;8 ms&rdquo; = 4&ndash;8 ms). '
            || 'By time weights each bucket by its waits &times; its midpoint, an approximation of where the time went. '
            || 'Normal = the mean share over the prior valid windows with ' || c_min_n
            || ' or more waits; a valid prior window without the event counts as zero waits, a skipped one is left out.</p>');

        DBMS_OUTPUT.PUT_LINE('<details class="whd"><summary>Every bucket, every event (' || v_n_rows
            || ' rows)</summary><div class="whsc"><table class="whtbl" data-nosort data-nocount><thead><tr><th>Event</th><th>Wait time</th>'
            || '<th class="num" data-w="0">Current waits</th><th class="num" data-w="0">Current share</th>'
            || '<th class="num">Normal share</th><th class="num">Prior range</th>'
            || '<th class="num" data-w="0">Current time share</th><th class="num">Normal time share</th></tr></thead><tbody>');
        FOR r IN 1 .. v_n_rows LOOP
            DBMS_OUTPUT.PUT_LINE(v_rows(r));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div></details>');

        DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.waithist={"min":'
            || c_min_n || ',"ev":[');
        FOR e IN 1 .. v_evs.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE(v_jsons(e) || CASE WHEN e < v_evs.COUNT THEN ',' END);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(']};</script>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

@@sql/lib/js_waithist.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 22_wait_histogram END -->'); END;
/
