--
-- 21_volume_cost.sql
-- Volume vs unit cost: for each statement (and each foreground wait
-- event) that got more expensive, did it RUN MORE OFTEN or did EACH RUN
-- GET SLOWER?  The two have different owners (the application vs the
-- database: plan, I/O, locks).
--
-- One log-log plane per kind (client half: sql/lib/js_volcost.plsql):
--   Top SQL      x = executions in Current / the statement's prior mean,
--                y = elapsed per execution in Current / its prior mean,
--                dot area = elapsed time in Current.
--   Wait events  x = foreground waits in Current / prior mean,
--                y = average foreground wait in Current / prior mean,
--                dot area = foreground time waited in Current.
-- The normal is taken over the VALID prior windows in which the item
-- completed at least one execution (had at least one wait): normal
-- executions = their mean, normal total = the mean total, normal per run
-- = normal total / normal executions, so x times y is exactly the total
-- ratio and the diagonals of equal total time read true.  A statement no valid prior
-- window saw is "new in Current" (a skipped window is unknown, so it
-- never makes a statement new); one with no completed execution in
-- Current cannot be placed and is only counted.
--
-- Data: DBA_HIST_SQLSTAT *_DELTA columns joined to valid_windows exactly
-- like 06 (statements = Current's top by elapsed, headroom past top_n,
-- bounded at 60); DBA_HIST_SYSTEM_EVENT foreground columns (*_FG) through
-- pairs -> bounds -> deltas with the template wait-list idiom, the event
-- set = 04's (top_n by time waited in any valid window, so every event
-- links to an emitted we- row).  Explains only: no scoring, no severity.
-- Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 21_volume_cost BEGIN -->'); END;
/

DECLARE
    v_top_n      NUMBER := ~top_n;
    -- statements read: Current's top by elapsed, past top_n for headroom
    v_cap        NUMBER := LEAST(60, GREATEST(2 * ~top_n, ~top_n + 10));
    v_thr        NUMBER := 1.5;      -- "more" / "slower" / "costs more" threshold
    v_floor      NUMBER := 0.02;     -- share of the plotted Current total to be named
    v_cur_valid  VARCHAR2(1) := 'N';
    v_cur_skip   VARCHAR2(400);
    v_nprior     PLS_INTEGER := 0;   -- valid prior windows
    v_row        VARCHAR2(32767);
    v_line       VARCHAR2(32767);
    v_seen_ev    CLOB;               -- anchor_uniq memo (sql/lib/anchor_id.plsql)
    v_rd_sql     VARCHAR2(4000);
    v_rd_ev      VARCHAR2(4000);
    v_ls         VARCHAR2(4000);
    v_new_sql    VARCHAR2(32767);
    v_new_ev     VARCHAR2(32767);
    v_open       VARCHAR2(10) := '';
    v_mode       VARCHAR2(3) := 'sql';
    -- per kind: counts for the sentence and the library row
    v_up_s  PLS_INTEGER := 0; v_m_s PLS_INTEGER := 0; v_sl_s PLS_INTEGER := 0; v_b_s PLS_INTEGER := 0;
    v_dn_s  PLS_INTEGER := 0; v_pl_s PLS_INTEGER := 0; v_nw_s PLS_INTEGER := 0;
    v_z_s   PLS_INTEGER := 0; v_nb_s PLS_INTEGER := 0;
    v_up_e  PLS_INTEGER := 0; v_m_e PLS_INTEGER := 0; v_sl_e PLS_INTEGER := 0; v_b_e PLS_INTEGER := 0;
    v_dn_e  PLS_INTEGER := 0; v_pl_e PLS_INTEGER := 0; v_nw_e PLS_INTEGER := 0;
    v_z_e   PLS_INTEGER := 0; v_nb_e PLS_INTEGER := 0;
    v_tot_s NUMBER := 0;
    v_tot_e NUMBER := 0;
    -- the biggest mover (extra time) of each category: index into the collection
    v_bm_s PLS_INTEGER; v_bs_s PLS_INTEGER; v_bm_e PLS_INTEGER; v_bs_e PLS_INTEGER;
    v_parts VARCHAR2(4000);
    v_st    VARCHAR2(1);
    v_ct    VARCHAR2(1);

    TYPE t_it IS RECORD (
        nm    VARCHAR2(128),   -- sql_id / event name
        wc    VARCHAR2(64),    -- wait class (events)
        in_t  NUMBER,          -- 1 = 06 / 04 emits this item's row
        ec    NUMBER,          -- executions / waits, Current
        ep    NUMBER,          -- the same, prior mean
        pc    NUMBER,          -- ms per execution / per wait, Current
        pp    NUMBER,          -- the same, normal = tp / ep (in ms)
        tc    NUMBER,          -- seconds elapsed / waited, Current
        tp    NUMBER,          -- the same, prior mean
        nrun  NUMBER,          -- prior valid windows with a completed run (wait)
        nseen NUMBER           -- prior valid windows that saw the item at all
    );
    TYPE t_its IS TABLE OF t_it;
    v_sql  t_its;
    v_ev   t_its;
    TYPE t_lab IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    v_lab_s t_lab;               -- label rank per item (1 = biggest mover)
    v_lab_e t_lab;

    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/json_escape.plsql

    -- a ratio as "x6.1" (HTML); NULL -> an em dash
    FUNCTION rx(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        IF p < 0.005 THEN RETURN '&times;&lt;0.01'; END IF;
        RETURN '&times;' || CASE
            WHEN p >= 9.95  THEN TO_CHAR(ROUND(p), 'FM999G999G990')
            WHEN p >= 0.095 THEN TO_CHAR(ROUND(p, 1), 'FM990D0')
            ELSE TO_CHAR(ROUND(p, 2), 'FM0D00') END;
    END rx;

    -- a JSON number (6 decimals, trailing zeros trimmed); NULL -> null
    FUNCTION jn(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        RETURN RTRIM(RTRIM(TO_CHAR(ROUND(p, 6), 'FM99999999999990D999999'), '0'), '.');
    END jn;

    FUNCTION ratio(a NUMBER, b NUMBER) RETURN NUMBER IS
    BEGIN
        IF a IS NULL OR b IS NULL OR b <= 0 OR a < 0 THEN RETURN NULL; END IF;
        RETURN a / b;
    END ratio;

    -- placement state: P placed, N new in Current, Z nothing now, B no prior run
    FUNCTION state_of(r t_it) RETURN VARCHAR2 IS
    BEGIN
        IF NVL(r.ec, 0) <= 0 OR NVL(r.pc, 0) <= 0 OR NVL(r.tc, 0) <= 0 THEN RETURN 'Z'; END IF;
        IF NVL(r.nseen, 0) = 0 THEN RETURN 'N'; END IF;
        IF NVL(r.nrun, 0) = 0 OR NVL(r.ep, 0) <= 0 OR NVL(r.pp, 0) <= 0 OR NVL(r.tp, 0) <= 0 THEN RETURN 'B'; END IF;
        RETURN 'P';
    END state_of;

    -- total cost: u at least thr x normal, d at most 1/thr, e in between
    FUNCTION cost_of(r t_it) RETURN VARCHAR2 IS
        t NUMBER := ratio(r.tc, r.tp);
    BEGIN
        RETURN CASE WHEN t >= v_thr THEN 'u' WHEN t <= 1 / v_thr THEN 'd' ELSE 'e' END;
    END cost_of;

    -- why it costs more: m more often, s slower each time, b both (or a bit of each)
    FUNCTION cat_of(r t_it) RETURN VARCHAR2 IS
        x NUMBER := ratio(r.ec, r.ep);
        y NUMBER := ratio(r.pc, r.pp);
    BEGIN
        RETURN CASE WHEN x >= v_thr AND y < v_thr THEN 'm'
                    WHEN y >= v_thr AND x < v_thr THEN 's'
                    ELSE 'b' END;
    END cat_of;

    FUNCTION pl(n PLS_INTEGER, one VARCHAR2, many VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN n || ' ' || CASE WHEN n = 1 THEN one ELSE many END;
    END pl;

    FUNCTION why_txt(r t_it, p_kind VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF state_of(r) = 'N' THEN RETURN 'new in Current'; END IF;
        IF state_of(r) <> 'P' THEN RETURN 'no prior baseline'; END IF;
        IF cost_of(r) = 'd' THEN RETURN 'costs less'; END IF;
        IF cost_of(r) = 'e' THEN RETURN 'about the same'; END IF;
        RETURN CASE cat_of(r)
            WHEN 'm' THEN CASE WHEN p_kind = 'sql' THEN 'runs more often' ELSE 'more waits' END
            WHEN 's' THEN CASE WHEN p_kind = 'sql' THEN 'slower per run' ELSE 'longer waits' END
            ELSE 'both' END;
    END why_txt;

    FUNCTION name_html(r t_it, p_kind VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_kind = 'sql' THEN
            RETURN CASE WHEN r.in_t = 1 THEN ent(r.nm, anchor_id('sq-elapsed', r.nm), 'sql')
                        ELSE r.nm END;
        END IF;
        RETURN ent(DBMS_XMLGEN.CONVERT(r.nm), anchor_id('we', r.nm), 'event');
    END name_html;

    -- the table of one kind (the numbers the plot draws)
    PROCEDURE put_table(p_its t_its, p_kind VARCHAR2) IS
        r  t_it;
        id VARCHAR2(200);
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<h3>' || CASE WHEN p_kind = 'sql' THEN 'Top SQL' ELSE 'Wait events (foreground)' END
            || '</h3>');
        DBMS_OUTPUT.PUT_LINE('<table class="vc-t" id="vc-t-' || p_kind || '"><thead><tr><th>'
            || CASE WHEN p_kind = 'sql' THEN 'Statement' ELSE 'Event' END || '</th>'
            || '<th class="num" data-w="0">' || CASE WHEN p_kind = 'sql' THEN 'Executions' ELSE 'Waits' END || '</th>'
            || '<th class="num">normal</th><th class="num">vs normal</th>'
            || '<th class="num" data-w="0">' || CASE WHEN p_kind = 'sql' THEN 'Per run (ms)' ELSE 'Avg wait (ms)' END || '</th>'
            || '<th class="num">normal</th><th class="num">vs normal</th>'
            || '<th class="num" data-w="0">' || CASE WHEN p_kind = 'sql' THEN 'Elapsed (s)' ELSE 'Waited (s)' END || '</th>'
            || '<th class="num">normal</th><th class="num">vs normal</th>'
            || '<th class="num">Prior windows</th><th>Reads as</th></tr></thead><tbody>');
        FOR i IN 1 .. NVL(p_its.COUNT, 0) LOOP
            r := p_its(i);
            IF state_of(r) <> 'Z' THEN
                id := CASE WHEN p_kind = 'sql' THEN anchor_id('vc-sq', r.nm)
                           ELSE anchor_uniq(anchor_id('vc-ev', r.nm), r.nm, v_seen_ev) END;
                DBMS_OUTPUT.PUT_LINE('<tr id="' || id || '"><td' || CASE WHEN p_kind = 'sql' THEN ' class="mono"' END || '>'
                    || name_html(r, p_kind) || '</td>'
                    || '<td class="num" data-w="0"' || fmt_num_title(r.ec) || '>' || fmt_num(r.ec) || '</td>'
                    || '<td class="num">' || fmt_num(r.ep) || '</td>'
                    || '<td class="num">' || rx(ratio(r.ec, r.ep)) || '</td>'
                    || '<td class="num" data-w="0"' || fmt_num_title(r.pc) || '>' || fmt_num(r.pc) || '</td>'
                    || '<td class="num">' || fmt_num(r.pp) || '</td>'
                    || '<td class="num">' || rx(ratio(r.pc, r.pp)) || '</td>'
                    || '<td class="num" data-w="0"' || fmt_num_title(r.tc) || '>' || fmt_num(r.tc) || '</td>'
                    || '<td class="num">' || fmt_num(r.tp) || '</td>'
                    || '<td class="num">' || rx(ratio(r.tc, r.tp)) || '</td>'
                    || '<td class="num">' || fmt_int(r.nrun) || '</td>'
                    || '<td>' || why_txt(r, p_kind) || '</td></tr>');
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    END put_table;

    -- one item of the payload
    FUNCTION item_json(r t_it, p_kind VARCHAR2, p_lab PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '{"n":"' || json_escape(r.nm) || '"'
            || ',"l":"' || CASE WHEN p_kind = 'sql' AND r.in_t = 1 THEN anchor_id('sq-elapsed', r.nm)
                                WHEN p_kind = 'ev' THEN anchor_id('we', r.nm) END || '"'
            || ',"r":"' || CASE WHEN p_kind = 'sql' THEN anchor_id('vc-sq', r.nm)
                                ELSE anchor_uniq(anchor_id('vc-ev', r.nm), r.nm, v_seen_ev) END || '"'
            || ',"ec":' || jn(r.ec) || ',"ep":' || jn(r.ep)
            || ',"pc":' || jn(r.pc) || ',"pp":' || jn(r.pp)
            || ',"tc":' || jn(r.tc) || ',"tp":' || jn(r.tp)
            || ',"k":"' || cost_of(r) || cat_of(r) || '","g":' || NVL(p_lab, 0) || '}';
    END item_json;
BEGIN
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag, skip_reason FROM windows_rollup
    ) LOOP
        IF r.week_offset = 0 THEN
            v_cur_valid := r.valid_flag;
            v_cur_skip  := r.skip_reason;
        ELSIF r.valid_flag = 'Y' THEN
            v_nprior := v_nprior + 1;
        END IF;
    END LOOP;

    IF v_cur_valid = 'Y' AND v_nprior > 0 THEN
        -- Statements: Current's top v_cap by elapsed, each against its own
        -- prior valid windows.  in_t = 1 when 06 emits its sq-elapsed row
        -- (top_n by elapsed, elapsed > 0, in some valid window).
        WITH
        @@sql/lib/windows_cte.sql
        ,
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   SUM(NVL(s.executions_delta, 0))   AS ex,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS ela
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
            GROUP BY w.week_offset, s.sql_id
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset ORDER BY ela DESC, sql_id) AS r_ela
            FROM   agg a
        ),
        cand AS (
            SELECT sql_id, r_ela FROM ranked
            WHERE  week_offset = 0 AND ela > 0 AND r_ela <= v_cap
        )
        SELECT r.sql_id, NULL,
               MAX(CASE WHEN r.r_ela <= (SELECT top_n FROM run_params) AND r.ela > 0 THEN 1 ELSE 0 END),
               MAX(CASE WHEN r.week_offset = 0 THEN r.ex END),
               AVG(CASE WHEN r.week_offset > 0 AND r.ex > 0 THEN r.ex END),
               MAX(CASE WHEN r.week_offset = 0 AND r.ex > 0 THEN r.ela / r.ex / 1e3 END),
               AVG(CASE WHEN r.week_offset > 0 AND r.ex > 0 THEN r.ela END)
                 / NULLIF(AVG(CASE WHEN r.week_offset > 0 AND r.ex > 0 THEN r.ex END), 0) / 1e3,
               MAX(CASE WHEN r.week_offset = 0 THEN r.ela / 1e6 END),
               AVG(CASE WHEN r.week_offset > 0 AND r.ex > 0 THEN r.ela / 1e6 END),
               COUNT(CASE WHEN r.week_offset > 0 AND r.ex > 0 THEN 1 END),
               COUNT(CASE WHEN r.week_offset > 0 AND (r.ex > 0 OR r.ela > 0) THEN 1 END)
        BULK COLLECT INTO v_sql
        FROM   ranked r
        JOIN   cand c ON c.sql_id = r.sql_id
        GROUP BY r.sql_id
        ORDER BY MIN(c.r_ela), r.sql_id;

        -- Wait events: 04's event set (top_n by all-session time waited in
        -- any valid window, after the template's wait list), measured on
        -- the foreground columns.
        WITH
        @@sql/lib/windows_cte.sql
        ,
        wait_targets AS (
            @@~template_dir/wait_event_targets.sql
        ),
        pairs AS (
            SELECT w.week_offset, se.event_name, se.wait_class,
                   se.snap_id, se.instance_number,
                   se.time_waited_micro, se.total_waits_fg, se.time_waited_micro_fg,
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
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END)    AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END)    AS end_us,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits_fg END)       AS beg_wf,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits_fg END)       AS end_wf,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro_fg END) AS beg_uf,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro_fg END) AS end_uf
            FROM   pairs
            GROUP BY week_offset, instance_number, event_name, wait_class
        ),
        deltas AS (
            SELECT week_offset, event_name, wait_class,
                   SUM(NVL(end_us, 0) - NVL(beg_us, 0)) AS us,
                   SUM(NVL(end_wf, 0) - NVL(beg_wf, 0)) AS wf,
                   SUM(NVL(end_uf, 0) - NVL(beg_uf, 0)) AS uf
            FROM   bounds
            GROUP BY week_offset, event_name, wait_class
        ),
        ranked AS (
            SELECT d.event_name,
                   RANK() OVER (PARTITION BY week_offset ORDER BY us DESC) AS rnk
            FROM   deltas d
            WHERE  us > 0
        ),
        ev04 AS (
            SELECT DISTINCT event_name FROM ranked
            WHERE  rnk <= (SELECT top_n FROM run_params)
        )
        SELECT d.event_name, MAX(d.wait_class), 1,
               MAX(CASE WHEN d.week_offset = 0 THEN d.wf END),
               AVG(CASE WHEN d.week_offset > 0 AND d.wf > 0 AND d.uf > 0 THEN d.wf END),
               MAX(CASE WHEN d.week_offset = 0 AND d.wf > 0 THEN d.uf / d.wf / 1e3 END),
               AVG(CASE WHEN d.week_offset > 0 AND d.wf > 0 AND d.uf > 0 THEN d.uf END)
                 / NULLIF(AVG(CASE WHEN d.week_offset > 0 AND d.wf > 0 AND d.uf > 0 THEN d.wf END), 0) / 1e3,
               MAX(CASE WHEN d.week_offset = 0 THEN d.uf / 1e6 END),
               AVG(CASE WHEN d.week_offset > 0 AND d.wf > 0 AND d.uf > 0 THEN d.uf / 1e6 END),
               COUNT(CASE WHEN d.week_offset > 0 AND d.wf > 0 AND d.uf > 0 THEN 1 END),
               COUNT(CASE WHEN d.week_offset > 0 AND (d.wf > 0 OR d.uf > 0) THEN 1 END)
        BULK COLLECT INTO v_ev
        FROM   deltas d
        JOIN   ev04 e ON e.event_name = d.event_name
        GROUP BY d.event_name
        ORDER BY MAX(CASE WHEN d.week_offset = 0 THEN d.uf END) DESC NULLS LAST, d.event_name;
    END IF;
    IF v_sql IS NULL THEN v_sql := t_its(); END IF;
    IF v_ev  IS NULL THEN v_ev  := t_its(); END IF;

    -- counts, totals and the biggest mover of each category ----------------
    FOR i IN 1 .. v_sql.COUNT LOOP
        v_st := state_of(v_sql(i));
        IF v_st = 'P' THEN v_pl_s := v_pl_s + 1; v_tot_s := v_tot_s + v_sql(i).tc;
        ELSIF v_st = 'N' THEN v_nw_s := v_nw_s + 1;
        ELSIF v_st = 'Z' THEN v_z_s := v_z_s + 1;
        ELSE v_nb_s := v_nb_s + 1; END IF;
    END LOOP;
    FOR i IN 1 .. v_ev.COUNT LOOP
        v_st := state_of(v_ev(i));
        IF v_st = 'P' THEN v_pl_e := v_pl_e + 1; v_tot_e := v_tot_e + v_ev(i).tc;
        ELSIF v_st = 'N' THEN v_nw_e := v_nw_e + 1;
        ELSIF v_st = 'Z' THEN v_z_e := v_z_e + 1;
        ELSE v_nb_e := v_nb_e + 1; END IF;
    END LOOP;
    FOR i IN 1 .. v_sql.COUNT LOOP
        IF state_of(v_sql(i)) = 'P' THEN
            IF cost_of(v_sql(i)) = 'd' THEN v_dn_s := v_dn_s + 1; END IF;
            IF cost_of(v_sql(i)) = 'u' AND v_sql(i).tc >= v_floor * v_tot_s THEN
                v_up_s := v_up_s + 1;
                v_ct := cat_of(v_sql(i));
                IF v_ct = 'm' THEN
                    v_m_s := v_m_s + 1;
                    IF v_bm_s IS NULL OR v_sql(i).tc - v_sql(i).tp > v_sql(v_bm_s).tc - v_sql(v_bm_s).tp THEN v_bm_s := i; END IF;
                ELSIF v_ct = 's' THEN
                    v_sl_s := v_sl_s + 1;
                    IF v_bs_s IS NULL OR v_sql(i).tc - v_sql(i).tp > v_sql(v_bs_s).tc - v_sql(v_bs_s).tp THEN v_bs_s := i; END IF;
                ELSE v_b_s := v_b_s + 1; END IF;
            END IF;
        END IF;
    END LOOP;
    FOR i IN 1 .. v_ev.COUNT LOOP
        IF state_of(v_ev(i)) = 'P' THEN
            IF cost_of(v_ev(i)) = 'd' THEN v_dn_e := v_dn_e + 1; END IF;
            IF cost_of(v_ev(i)) = 'u' AND v_ev(i).tc >= v_floor * v_tot_e THEN
                v_up_e := v_up_e + 1;
                v_ct := cat_of(v_ev(i));
                IF v_ct = 'm' THEN
                    v_m_e := v_m_e + 1;
                    IF v_bm_e IS NULL OR v_ev(i).tc - v_ev(i).tp > v_ev(v_bm_e).tc - v_ev(v_bm_e).tp THEN v_bm_e := i; END IF;
                ELSIF v_ct = 's' THEN
                    v_sl_e := v_sl_e + 1;
                    IF v_bs_e IS NULL OR v_ev(i).tc - v_ev(i).tp > v_ev(v_bs_e).tc - v_ev(v_bs_e).tp THEN v_bs_e := i; END IF;
                ELSE v_b_e := v_b_e + 1; END IF;
            END IF;
        END IF;
    END LOOP;

    -- label ranks: the placed items whose total moved past the threshold,
    -- by the size of the move (seconds), at most 6 per kind
    DECLARE
        best PLS_INTEGER;
        bv   NUMBER;
        dv   NUMBER;
    BEGIN
        FOR n IN 1 .. 6 LOOP
            best := NULL; bv := NULL;
            FOR i IN 1 .. v_sql.COUNT LOOP
                IF state_of(v_sql(i)) = 'P' AND cost_of(v_sql(i)) <> 'e' AND NOT v_lab_s.EXISTS(i) THEN
                    dv := ABS(v_sql(i).tc - v_sql(i).tp);
                    IF bv IS NULL OR dv > bv THEN best := i; bv := dv; END IF;
                END IF;
            END LOOP;
            EXIT WHEN best IS NULL;
            v_lab_s(best) := n;
        END LOOP;
        FOR n IN 1 .. 6 LOOP
            best := NULL; bv := NULL;
            FOR i IN 1 .. v_ev.COUNT LOOP
                IF state_of(v_ev(i)) = 'P' AND cost_of(v_ev(i)) <> 'e' AND NOT v_lab_e.EXISTS(i) THEN
                    dv := ABS(v_ev(i).tc - v_ev(i).tp);
                    IF bv IS NULL OR dv > bv THEN best := i; bv := dv; END IF;
                END IF;
            END LOOP;
            EXIT WHEN best IS NULL;
            v_lab_e(best) := n;
        END LOOP;
    END;

    -- "Reads as:" sentences ----------------------------------------------
    IF v_pl_s > 0 THEN
        IF v_up_s = 0 THEN
            v_rd_sql := 'No statement costs at least ' || rx(v_thr) || ' its normal total elapsed time ('
                || pl(v_pl_s, 'statement', 'statements') || ' compared'
                || CASE WHEN v_dn_s > 0 THEN ', ' || v_dn_s || ' cost less' END || ').';
        ELSE
            v_parts := NULL;
            IF v_m_s > 0 THEN
                v_parts := pl(v_m_s, 'runs', 'run') || ' more often (biggest: <b class="mono">' || v_sql(v_bm_s).nm
                    || '</b>, ' || rx(ratio(v_sql(v_bm_s).ec, v_sql(v_bm_s).ep)) || ' the executions)';
            END IF;
            IF v_sl_s > 0 THEN
                v_parts := CASE WHEN v_parts IS NOT NULL THEN v_parts || ', ' END
                    || CASE WHEN v_sl_s = 1 THEN '1 is' ELSE v_sl_s || ' are' END
                    || ' slower per run (biggest: <b class="mono">' || v_sql(v_bs_s).nm || '</b>, '
                    || rx(ratio(v_sql(v_bs_s).pc, v_sql(v_bs_s).pp)) || ' per run)';
            END IF;
            IF v_b_s > 0 THEN
                v_parts := CASE WHEN v_parts IS NOT NULL THEN v_parts || ', ' END
                    || pl(v_b_s, 'runs', 'run') || ' more often and ' || CASE WHEN v_b_s = 1 THEN 'takes' ELSE 'take' END || ' longer';
            END IF;
            v_rd_sql := pl(v_up_s, 'statement costs', 'statements cost') || ' at least ' || rx(v_thr)
                || CASE WHEN v_up_s = 1 THEN ' its' ELSE ' their' END
                || ' normal total elapsed time: ' || v_parts || '.';
        END IF;
    END IF;
    IF v_pl_e > 0 THEN
        IF v_up_e = 0 THEN
            v_rd_ev := 'No wait event costs at least ' || rx(v_thr) || ' its normal time waited ('
                || pl(v_pl_e, 'event', 'events') || ' compared'
                || CASE WHEN v_dn_e > 0 THEN ', ' || v_dn_e || ' cost less' END || ').';
        ELSE
            v_parts := NULL;
            IF v_m_e > 0 THEN
                v_parts := pl(v_m_e, 'happens', 'happen') || ' more often (biggest: <b>' || DBMS_XMLGEN.CONVERT(v_ev(v_bm_e).nm)
                    || '</b>, ' || rx(ratio(v_ev(v_bm_e).ec, v_ev(v_bm_e).ep)) || ' the waits)';
            END IF;
            IF v_sl_e > 0 THEN
                v_parts := CASE WHEN v_parts IS NOT NULL THEN v_parts || ', ' END
                    || pl(v_sl_e, 'lasts', 'last') || ' longer per wait (biggest: <b>' || DBMS_XMLGEN.CONVERT(v_ev(v_bs_e).nm) || '</b>, '
                    || rx(ratio(v_ev(v_bs_e).pc, v_ev(v_bs_e).pp)) || ' per wait)';
            END IF;
            IF v_b_e > 0 THEN
                v_parts := CASE WHEN v_parts IS NOT NULL THEN v_parts || ', ' END
                    || pl(v_b_e, 'happens', 'happen') || ' more often and ' || CASE WHEN v_b_e = 1 THEN 'lasts' ELSE 'last' END || ' longer';
            END IF;
            v_rd_ev := pl(v_up_e, 'wait event costs', 'wait events cost') || ' at least ' || rx(v_thr)
                || CASE WHEN v_up_e = 1 THEN ' its' ELSE ' their' END
                || ' normal time waited: ' || v_parts || '.';
        END IF;
    END IF;

    -- the evidence library's row text ------------------------------------
    IF v_cur_valid <> 'Y' THEN
        v_ls := 'Current window skipped: nothing to compare';
    ELSIF v_nprior = 0 THEN
        v_ls := 'no valid prior window: nothing to compare';
    ELSIF v_pl_s + v_pl_e = 0 THEN
        v_ls := 'nothing with a prior baseline to compare';
    ELSIF v_up_s = 0 AND v_up_e = 0 THEN
        v_ls := 'no statement or wait costs ' || rx(v_thr) || ' its normal';
    ELSE
        IF v_up_s > 0 THEN
            v_ls := pl(v_up_s, 'statement costs', 'statements cost') || ' more: '
                || CASE WHEN v_m_s > 0 THEN v_m_s || ' run' || CASE WHEN v_m_s = 1 THEN 's' END || ' more often' END
                || CASE WHEN v_m_s > 0 AND v_sl_s > 0 THEN ', ' END
                || CASE WHEN v_sl_s > 0 THEN v_sl_s || CASE WHEN v_sl_s = 1 THEN ' is ' ELSE ' are ' END
                        || 'slower per run (' || v_sql(v_bs_s).nm || ' ' || rx(ratio(v_sql(v_bs_s).pc, v_sql(v_bs_s).pp)) || ')' END
                || CASE WHEN (v_m_s > 0 OR v_sl_s > 0) AND v_b_s > 0 THEN ', ' END
                || CASE WHEN v_b_s > 0 THEN v_b_s || ' both' END;
        END IF;
        IF v_up_e > 0 THEN
            v_ls := CASE WHEN v_ls IS NOT NULL THEN v_ls || '; ' END
                || pl(v_up_e, 'wait event costs', 'wait events cost') || ' more';
        END IF;
        IF v_sl_s > 0 OR v_b_s > 0 THEN v_open := ' lopen'; END IF;
    END IF;
    IF v_pl_s = 0 AND v_pl_e > 0 THEN v_mode := 'ev'; END IF;

    -- markup -------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<section id="volume-cost" class="vw in-s in-a lib' || v_open
        || '" style="--os:11" data-mode="' || v_mode || '"><h2>Volume vs unit cost'
        || '<small class="h2sub">Ran more often, or each run got slower?</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('volume-cost', v_ls));

    IF v_cur_valid <> 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">The Current window was skipped ('
            || DBMS_XMLGEN.CONVERT(NVL(v_cur_skip, 'no valid snapshots'))
            || '), so there is nothing to place.</p>');
    ELSIF v_nprior = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">No valid prior window: there is no normal to compare'
            || ' Current with. Try more <code>weeks_back</code> or another <code>target_end</code>.</p>');
    ELSIF v_sql.COUNT + v_ev.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">No statement in DBA_HIST_SQLSTAT and no foreground wait'
            || ' event in DBA_HIST_SYSTEM_EVENT for the Current window.</p>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p class="vc-q">Each dot is one statement (or wait event), Current against its'
            || ' own normal: the mean of the prior valid windows it ran in. Right = runs more often,'
            || ' up = each run is slower; the diagonals join points of equal total time.</p>');
        DBMS_OUTPUT.PUT_LINE('<div class="vc-bar vc-js"><span class="seg vc-seg" role="group" aria-label="Show">'
            || '<button type="button" data-k="sql" aria-pressed="' || CASE WHEN v_mode = 'sql' THEN 'true' ELSE 'false' END
            || '">Top SQL</button><button type="button" data-k="ev" aria-pressed="'
            || CASE WHEN v_mode = 'ev' THEN 'true' ELSE 'false' END || '">Wait events</button></span>'
            || '<span class="vc-lg"><span><i class="vc-k vc-u"></i>total &ge; ' || rx(v_thr) || ' normal</span>'
            || '<span><i class="vc-k vc-d"></i>&le; ' || rx(1 / v_thr) || '</span>'
            || '<span><i class="vc-k vc-e"></i>in between</span>'
            || '<span><i class="vc-k vc-o"></i>past the axis end</span>'
            || '<span>area = time in Current</span></span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="vc-wrap vc-js"><div class="vc-main">'
            || '<div class="vc-yt" data-vk="sql">Time per run vs normal <b>&uarr; each run slower</b> (plan, I/O, locks: database side)</div>'
            || '<div class="vc-yt" data-vk="ev">Time per wait vs normal <b>&uarr; each wait longer</b> (device, contention)</div>'
            || '<div class="vc-plot" id="vc-plot"></div>'
            || '<div class="vc-xt" data-vk="sql">Executions vs normal <b>&rarr; runs more often</b> (callers, batch size: application side)</div>'
            || '<div class="vc-xt" data-vk="ev">Number of waits vs normal <b>&rarr; waits more often</b> (more work reaching it)</div>'
            || '</div>');
        -- the "new in Current" strips (no normal to place them against)
        FOR i IN 1 .. v_sql.COUNT LOOP
            IF state_of(v_sql(i)) = 'N' AND NVL(LENGTH(v_new_sql), 0) < 30000 THEN
                v_new_sql := v_new_sql || '<li><span class="mono">' || name_html(v_sql(i), 'sql')
                    || '</span> <span class="vc-nv">' || fmt_num(v_sql(i).tc) || ' s</span></li>';
            END IF;
        END LOOP;
        FOR i IN 1 .. v_ev.COUNT LOOP
            IF state_of(v_ev(i)) = 'N' AND NVL(LENGTH(v_new_ev), 0) < 30000 THEN
                v_new_ev := v_new_ev || '<li>' || name_html(v_ev(i), 'ev')
                    || ' <span class="vc-nv">' || fmt_num(v_ev(i).tc) || ' s</span></li>';
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('<aside class="vc-new" data-vk="sql"><h4>New in Current</h4>'
            || CASE WHEN v_new_sql IS NULL THEN '<p>none: every statement ran in an earlier valid window</p>'
                    ELSE '<ul>' || v_new_sql || '</ul><p>no valid prior window saw them, so they cannot be placed</p>' END
            || '</aside>');
        DBMS_OUTPUT.PUT_LINE('<aside class="vc-new" data-vk="ev"><h4>New in Current</h4>'
            || CASE WHEN v_new_ev IS NULL THEN '<p>none: every event was waited on before</p>'
                    ELSE '<ul>' || v_new_ev || '</ul><p>no valid prior window saw them, so they cannot be placed</p>' END
            || '</aside></div>');
        DBMS_OUTPUT.PUT_LINE('<p class="vc-rd" data-vk="sql"><b>Reads as:</b> '
            || NVL(v_rd_sql, 'No statement in Current has a prior baseline to compare with.') || '</p>');
        DBMS_OUTPUT.PUT_LINE('<p class="vc-rd" data-vk="ev"><b>Reads as:</b> '
            || NVL(v_rd_ev, 'No foreground wait event in Current has a prior baseline to compare with.') || '</p>');
        IF v_z_s + v_nb_s + v_z_e + v_nb_e > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<p class="vc-drop">Not placed: '
                || RTRIM(
                       CASE WHEN v_z_s > 0 THEN pl(v_z_s, 'statement', 'statements')
                            || ' with no completed execution in Current (still running at the window end, or idle), ' END
                    || CASE WHEN v_nb_s > 0 THEN pl(v_nb_s, 'statement', 'statements')
                            || ' seen before but never completed a run in a prior valid window, ' END
                    || CASE WHEN v_z_e > 0 THEN pl(v_z_e, 'event', 'events') || ' with no foreground wait in Current, ' END
                    || CASE WHEN v_nb_e > 0 THEN pl(v_nb_e, 'event', 'events') || ' with no prior foreground wait time, ' END,
                   ', ') || '.</p>');
        END IF;

        -- the payload, one item per line
        DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.volcost={thr:' || jn(v_thr)
            || ',top:' || v_top_n || ',sql:[');
        v_line := NULL;
        FOR i IN 1 .. v_sql.COUNT LOOP
            IF state_of(v_sql(i)) = 'P' THEN
                DBMS_OUTPUT.PUT_LINE(v_line || item_json(v_sql(i), 'sql',
                    CASE WHEN v_lab_s.EXISTS(i) THEN v_lab_s(i) END));
                v_line := ',';
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],ev:[');
        v_line := NULL;
        FOR i IN 1 .. v_ev.COUNT LOOP
            IF state_of(v_ev(i)) = 'P' THEN
                DBMS_OUTPUT.PUT_LINE(v_line || item_json(v_ev(i), 'ev',
                    CASE WHEN v_lab_e.EXISTS(i) THEN v_lab_e(i) END));
                v_line := ',';
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(']};</script>');

        IF v_sql.COUNT > 0 THEN put_table(v_sql, 'sql'); END IF;
        IF v_ev.COUNT > 0 THEN put_table(v_ev, 'ev'); END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

@@sql/lib/js_volcost.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 21_volume_cost END -->'); END;
/
