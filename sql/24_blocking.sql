--
-- 24_blocking.sql
-- Blocking (viz item 5): sessions waited behind a holder.  WHO held them,
-- how many sessions were stuck behind each holder, and is this much
-- blocking normal for this hour?
--
-- Part 1, "is it normal": blocked time per compared window on the window
-- component (sql/lib/wingrid.plsql): ASH samples whose
-- blocking_session_status is VALID (a real holder known by session),
-- times 10 seconds (one DBA_HIST ASH sample stands for about 10 s of a
-- session's time).  Unscored: no line of sql/lib/metric_policy.plsql
-- fits ASH blocked time (the WAIT domain is a share of the Current wait
-- total), so the gutter shows the plain Delta vs the prior mean and no
-- severity.  A skipped window has no value (unknown), a valid window
-- without a blocked sample is 0.
--
-- Part 2, "who blocked whom" in the Current window: every blocked
-- sample's chain is followed up to its FINAL holder inside the same ASH
-- sample (instance, sample_id): waiter -> holder -> the holder's own
-- holder ... until a holder that is not waiting on anyone in that sample
-- (sessions keyed by instance, sid AND serial#: a sid is reused).  A
-- visited set stops a cycle (a deadlock caught by the sampler: the chain
-- ends at the last session before the repeat, marked "cycle").  The
-- resolved paths form a prefix tree: root = final holder, level 1 = its
-- direct waiters, level 2 = theirs; a deeper waiter is summed into its
-- level-2 ancestor.  Drawn: top 5 roots by blocked time behind them, 6
-- direct waiters each, 3 under each of those, the rest "+ n more".  The
-- layout is client-side (sql/lib/js_blocking.plsql,
-- window.AWR_DATA.blocking); the tables below the graph carry every
-- number with JS off.  A holder on another instance is the end of its
-- chain (samples of two instances are not aligned).
--
-- Not counted: NO HOLDER, NOT IN WAIT, UNKNOWN.  GLOBAL (the holder sits
-- on another RAC instance and is not known by session) is counted in its
-- own column of the per-window table, never in the blocked time or the
-- graph.  Every wait with a known holder counts (row locks, but also a
-- log file switch behind LGWR or a buffer busy wait).
--
-- Source: ONE bounded scan of DBA_HIST_ACTIVE_SESS_HISTORY over the
-- compared (valid) windows only (snap range + sample time per window; a
-- sample in two overlapping windows counts for each), aggregated by
-- a 4-row generator (one pass): per window, per Current edge, per Current
-- session, per blocked Current sample.
-- Names: ALL_USERS (public) for user_id when the sample's container is
-- this session's, DBA_HIST_SEG_STAT_OBJ (granted) for current_obj#; else
-- the number.  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 24_blocking BEGIN -->'); END;
/

DECLARE
    TYPE t_ntab  IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_stab  IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    TYPE t_lstab IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    TYPE t_kn    IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    TYPE t_ks    IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(200);
    TYPE t_node  IS RECORD (n NUMBER, usr NUMBER, con NUMBER, mdl VARCHAR2(200),
                            prg VARCHAR2(200), sqlid VARCHAR2(30), ev VARCHAR2(200),
                            obj NUMBER, styp VARCHAR2(30));
    TYPE t_nodes IS TABLE OF t_node INDEX BY VARCHAR2(200);

    c_maxe   CONSTANT PLS_INTEGER := 3000;    -- edges kept for their event / SQL / object
    c_maxs   CONSTANT PLS_INTEGER := 500000;  -- blocked Current samples walked
    c_roots  CONSTANT PLS_INTEGER := 5;       -- roots drawn
    c_kids1  CONSTANT PLS_INTEGER := 6;       -- direct waiters drawn per root
    c_kids2  CONSTANT PLS_INTEGER := 3;       -- waiters drawn per direct waiter
    c_open   CONSTANT NUMBER      := 300;     -- lopen floor, blocked seconds

    -- windows
    v_wvalid t_stab;
    v_wskip  t_stab;
    v_wblk   t_ntab;     -- VALID samples
    v_wglob  t_ntab;     -- GLOBAL samples
    v_wnw    t_ntab;     -- distinct waiting sessions
    v_wnb    t_ntab;     -- distinct holders
    v_pairs  VARCHAR2(32767);
    v_cur    NUMBER;
    v_mu     NUMBER;
    v_sd     NUMBER;
    v_n      NUMBER := 0;
    v_sum    NUMBER := 0;
    v_sq     NUMBER := 0;
    v_curok  BOOLEAN := FALSE;

    -- Current edges (event / SQL / object of a waiter behind a holder)
    e_ev     t_stab;
    e_sql    t_stab;
    e_obj    t_ntab;
    e_cnt    PLS_INTEGER := 0;
    v_ek     t_kn;               -- 'waiter|holder' -> edge index
    v_nodes  t_nodes;
    v_insts  t_kn;
    v_multi  BOOLEAN := FALSE;
    v_mycon  NUMBER;

    -- one ASH sample being resolved (waiter -> holder)
    s_key    VARCHAR2(200);
    s_w      t_stab;
    s_b      t_stab;
    s_ev     t_stab;
    s_sql    t_stab;
    s_n      PLS_INTEGER := 0;
    s_m      t_ks;
    s_rows   NUMBER := 0;
    s_left   NUMBER := 0;        -- samples past c_maxs (not walked)

    -- the path tree: one node per (root, level-1 waiter, level-2 waiter)
    pa_key   t_stab;             -- the session at this node
    pa_par   t_ntab;
    pa_lv    t_ntab;
    pa_s     t_ntab;             -- samples this session waited behind its parent
    pa_bs    t_ntab;             -- samples of everyone below
    pa_bn    t_ntab;             -- distinct sessions below
    pa_kids  t_lstab;            -- ',id,id,'
    pa_cyc   t_stab;
    pa_n     PLS_INTEGER := 0;
    v_pid    t_kn;               -- 'parent>key' -> id
    v_seen   t_kn;               -- 'id|waiter' -> 1
    v_rev    t_kn;               -- 'root id|event' -> samples
    v_rsql   t_kn;               -- 'root id|sql_id' -> samples
    v_ch     t_stab;
    v_vis    t_kn;

    -- roots, ranked
    r_key    t_stab;
    r_id     t_ntab;
    r_tot    t_ntab;
    r_cnt    t_ntab;
    r_ev     t_stab;
    r_sql    t_stab;
    r_cyc    t_stab;
    r_n      PLS_INTEGER := 0;
    r_ord    t_ntab;
    r_bn     t_ntab;             -- best tally per root id (event, sql)
    r_bsn    t_ntab;

    -- caches
    v_unames t_ks;
    v_onames t_ks;

    -- output
    v_js     t_lstab;
    v_js_n   PLS_INTEGER := 0;
    v_er     t_lstab;            -- edge table rows
    v_er_n   PLS_INTEGER := 0;
    v_di     PLS_INTEGER := 0;   -- display node index
    v_rd     VARCHAR2(32767);
    v_ls     VARCHAR2(32767);
    v_lab    VARCHAR2(32767);
    v_gut    VARCHAR2(32767);
    v_ratio  VARCHAR2(4000);
    v_tmp    VARCHAR2(32767);
    v_i      PLS_INTEGER;
    v_k      PLS_INTEGER;
    v_open   BOOLEAN := FALSE;
    v_cur_s  NUMBER := 0;

    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/json_escape.plsql

    FUNCTION k_part(p_key VARCHAR2, p_i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_SUBSTR(p_key, '[^,]+', 1, p_i);
    END k_part;

    -- "SID 412,3391" (+ "@2" when the Current window saw several instances)
    FUNCTION k_lab(p_key VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'SID ' || k_part(p_key, 2) || ',' || k_part(p_key, 3)
            || CASE WHEN v_multi THEN '@' || k_part(p_key, 1) END;
    END k_lab;

    FUNCTION dur_txt(p_s NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_s IS NULL THEN RETURN '&mdash;'; END IF;
        IF p_s < 120 THEN RETURN TO_CHAR(ROUND(p_s)) || ' s'; END IF;
        IF p_s < 600 THEN
            RETURN TO_CHAR(ROUND(p_s / 60, 1), 'FM9990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' min';
        END IF;
        IF p_s < 7200 THEN RETURN TO_CHAR(ROUND(p_s / 60)) || ' min'; END IF;
        RETURN TO_CHAR(ROUND(p_s / 3600, 1), 'FM999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' h';
    END dur_txt;

    FUNCTION usr_name(p_usr NUMBER, p_con NUMBER) RETURN VARCHAR2 IS
        v_k VARCHAR2(200) := TO_CHAR(p_usr) || '|' || TO_CHAR(p_con);
        v_u VARCHAR2(200);
    BEGIN
        IF p_usr IS NULL THEN RETURN NULL; END IF;
        IF v_unames.EXISTS(v_k) THEN RETURN v_unames(v_k); END IF;
        IF p_usr = 0 THEN
            v_u := 'SYS';                -- user id 0 is SYS in every container
        ELSIF NVL(p_con, 0) = NVL(v_mycon, 0) OR NVL(p_con, 0) = 0 THEN
            BEGIN
                SELECT username INTO v_u FROM all_users WHERE user_id = p_usr;
            EXCEPTION WHEN NO_DATA_FOUND THEN v_u := NULL;
            END;
        END IF;
        v_unames(v_k) := NVL(v_u, 'user id ' || TO_CHAR(p_usr)
            || CASE WHEN NVL(p_con, 0) <> NVL(v_mycon, 0) THEN ' (container ' || p_con || ')' END);
        RETURN v_unames(v_k);
    END usr_name;

    FUNCTION obj_name(p_obj NUMBER) RETURN VARCHAR2 IS
        v_k VARCHAR2(200) := TO_CHAR(p_obj);
        v_o VARCHAR2(4000);
    BEGIN
        IF p_obj IS NULL THEN RETURN NULL; END IF;
        IF v_onames.EXISTS(v_k) THEN RETURN v_onames(v_k); END IF;
        BEGIN
            SELECT owner || '.' || object_name
                   || CASE WHEN subobject_name IS NOT NULL THEN '.' || subobject_name END
            INTO   v_o
            FROM   dba_hist_seg_stat_obj
            WHERE  dbid IN (~dbid_list) AND obj# = p_obj AND ROWNUM = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_o := NULL;
        END;
        v_onames(v_k) := NVL(v_o, 'obj# ' || TO_CHAR(p_obj));
        RETURN v_onames(v_k);
    END obj_name;

    -- "BATCH / InventorySync" (user / module, else the program's short
    -- name: "oracle@host (LGWR)" -> LGWR); NULL = never sampled
    FUNCTION who(p_key VARCHAR2) RETURN VARCHAR2 IS
        v_p VARCHAR2(200);
    BEGIN
        IF NOT v_nodes.EXISTS(p_key) THEN RETURN NULL; END IF;
        v_p := v_nodes(p_key).mdl;
        IF v_p IS NULL THEN
            v_p := NVL(REGEXP_SUBSTR(v_nodes(p_key).prg, '\(([A-Za-z0-9_]+)\)$', 1, 1, NULL, 1),
                       v_nodes(p_key).prg);
        END IF;
        RETURN SUBSTR(NVL(usr_name(v_nodes(p_key).usr, v_nodes(p_key).con), '?')
            || CASE WHEN v_p IS NOT NULL THEN ' / ' || v_p END, 1, 80);
    END who;

    PROCEDURE bump(p_t IN OUT NOCOPY t_kn, p_k VARCHAR2, p_v NUMBER) IS
    BEGIN
        IF p_k IS NULL THEN RETURN; END IF;
        IF p_t.EXISTS(p_k) THEN p_t(p_k) := p_t(p_k) + p_v; ELSE p_t(p_k) := p_v; END IF;
    END bump;

    -- the path-tree node under p_par for session p_key (created on first use)
    FUNCTION node_id(p_par PLS_INTEGER, p_key VARCHAR2) RETURN PLS_INTEGER IS
        v_k VARCHAR2(200) := TO_CHAR(p_par) || '>' || p_key;
    BEGIN
        IF v_pid.EXISTS(v_k) THEN RETURN v_pid(v_k); END IF;
        pa_n := pa_n + 1;
        pa_key(pa_n) := p_key; pa_par(pa_n) := p_par;
        pa_lv(pa_n) := CASE WHEN p_par = 0 THEN 0 ELSE pa_lv(p_par) + 1 END;
        pa_s(pa_n) := 0; pa_bs(pa_n) := 0; pa_bn(pa_n) := 0; pa_kids(pa_n) := ','; pa_cyc(pa_n) := 'N';
        IF p_par > 0 THEN
            -- a child list holds at most about 4000 ids (32767 bytes);
            -- past that a child still counts, it is only never drawn
            IF LENGTH(pa_kids(p_par)) < 32000 THEN
                pa_kids(p_par) := pa_kids(p_par) || pa_n || ',';
            END IF;
        END IF;
        v_pid(v_k) := pa_n;
        RETURN pa_n;
    END node_id;

    -- resolve the buffered sample: every waiter's chain up to its final
    -- holder IN THIS SAMPLE (visited set: a cycle stops the walk)
    PROCEDURE flush_sample IS
        v_c   VARCHAR2(200);
        v_b   VARCHAR2(200);
        v_n   PLS_INTEGER;
        v_d   PLS_INTEGER;
        v_cyc BOOLEAN;
        v_id  t_ntab;
        v_x   VARCHAR2(200);
    BEGIN
        FOR i IN 1 .. s_n LOOP
            v_vis.DELETE; v_ch.DELETE;
            v_c := s_w(i); v_n := 1; v_ch(1) := v_c; v_vis(v_c) := 1;
            v_b := s_b(i); v_cyc := FALSE;
            LOOP
                IF v_vis.EXISTS(v_b) THEN v_cyc := TRUE; EXIT; END IF;
                v_n := v_n + 1; v_ch(v_n) := v_b; v_vis(v_b) := 1;
                EXIT WHEN NOT s_m.EXISTS(v_b) OR v_n >= 50;
                v_b := s_m(v_b);
            END LOOP;
            -- v_ch = waiter, its holder, ..., the final holder
            v_d := v_n - 1;
            v_id.DELETE;
            v_id(0) := node_id(0, v_ch(v_n));
            IF v_cyc THEN pa_cyc(v_id(0)) := 'Y'; END IF;
            FOR l IN 1 .. LEAST(v_d, 2) LOOP
                v_id(l) := node_id(v_id(l - 1), v_ch(v_n - l));
            END LOOP;
            IF v_d <= 2 THEN pa_s(v_id(v_d)) := pa_s(v_id(v_d)) + 1; END IF;
            FOR l IN 0 .. LEAST(v_d - 1, 2) LOOP
                pa_bs(v_id(l)) := pa_bs(v_id(l)) + 1;
                v_x := TO_CHAR(v_id(l)) || '|' || s_w(i);
                IF NOT v_seen.EXISTS(v_x) THEN v_seen(v_x) := 1; pa_bn(v_id(l)) := pa_bn(v_id(l)) + 1; END IF;
            END LOOP;
            IF s_ev(i) IS NOT NULL THEN bump(v_rev, TO_CHAR(v_id(0)) || '|' || s_ev(i), 1); END IF;
            IF s_sql(i) IS NOT NULL THEN bump(v_rsql, TO_CHAR(v_id(0)) || '|' || s_sql(i), 1); END IF;
        END LOOP;
        s_n := 0; s_m.DELETE; s_w.DELETE; s_b.DELETE; s_ev.DELETE; s_sql.DELETE;
    END flush_sample;

    -- the children of path node p_id, by the blocked time each carries
    -- (its own + everyone behind it), largest first, ties by session key
    PROCEDURE kids_of(p_id PLS_INTEGER, p_arr IN OUT NOCOPY t_ntab) IS
        v_list VARCHAR2(32767) := pa_kids(p_id);
        v_p    PLS_INTEGER := 2;
        v_q    PLS_INTEGER;
        v_t    PLS_INTEGER;
    BEGIN
        p_arr.DELETE;
        LOOP
            v_q := INSTR(v_list, ',', v_p);
            EXIT WHEN v_q = 0;
            p_arr(p_arr.COUNT + 1) := TO_NUMBER(SUBSTR(v_list, v_p, v_q - v_p));
            v_p := v_q + 1;
        END LOOP;
        FOR a IN 1 .. p_arr.COUNT LOOP
            FOR b IN a + 1 .. p_arr.COUNT LOOP
                IF pa_s(p_arr(b)) + pa_bs(p_arr(b)) > pa_s(p_arr(a)) + pa_bs(p_arr(a))
                   OR (pa_s(p_arr(b)) + pa_bs(p_arr(b)) = pa_s(p_arr(a)) + pa_bs(p_arr(a))
                       AND pa_key(p_arr(b)) < pa_key(p_arr(a))) THEN
                    v_t := p_arr(a); p_arr(a) := p_arr(b); p_arr(b) := v_t;
                END IF;
            END LOOP;
        END LOOP;
    END kids_of;

    -- one display node as a JSON line (+ its edge-table row)
    PROCEDURE js_node(p_id PLS_INTEGER, p_par PLS_INTEGER, p_r PLS_INTEGER, p_deep BOOLEAN) IS
        v_k  VARCHAR2(200) := pa_key(p_id);
        v_wh VARCHAR2(4000) := who(v_k);
        v_hk VARCHAR2(200);
        v_ev VARCHAR2(4000);
        v_sq VARCHAR2(4000);
        v_ob VARCHAR2(4000);
        v_e  PLS_INTEGER;
    BEGIN
        IF pa_lv(p_id) = 0 THEN
            IF v_nodes.EXISTS(v_k) THEN
                v_ev := v_nodes(v_k).ev; v_sq := v_nodes(v_k).sqlid; v_ob := obj_name(v_nodes(v_k).obj);
            END IF;
        ELSE
            v_hk := pa_key(pa_par(p_id));
            IF v_ek.EXISTS(v_k || '|' || v_hk) THEN
                v_e := v_ek(v_k || '|' || v_hk);
                v_ev := e_ev(v_e); v_sq := e_sql(v_e); v_ob := obj_name(e_obj(v_e));
            END IF;
        END IF;
        v_di := v_di + 1;
        v_js_n := v_js_n + 1;
        v_js(v_js_n) := CASE WHEN v_di > 1 THEN ',' END
            || '{"i":' || v_di || ',"p":' || p_par || ',"lv":' || pa_lv(p_id) || ',"r":' || p_r
            || ',"k":"' || CASE WHEN pa_lv(p_id) = 0 THEN 'r' ELSE 'w' END || '","id":"' || k_lab(v_k) || '"'
            || ',"who":"' || json_escape(v_wh) || '","ns":' || CASE WHEN v_wh IS NULL THEN 1 ELSE 0 END
            || ',"sql":"' || json_escape(v_sq) || '","ev":"' || json_escape(v_ev) || '"'
            || ',"obj":"' || json_escape(v_ob) || '"'
            || ',"s":' || TO_CHAR(pa_s(p_id) * 10)
            || ',"bn":' || pa_bn(p_id) || ',"bs":' || TO_CHAR(pa_bs(p_id) * 10)
            || ',"cyc":' || CASE WHEN pa_cyc(p_id) = 'Y' THEN 1 ELSE 0 END
            || ',"deep":' || CASE WHEN p_deep THEN 1 ELSE 0 END || '}';
        IF pa_lv(p_id) > 0 THEN
            v_er_n := v_er_n + 1;
            v_er(v_er_n) := '<tr><td>' || k_lab(v_k)
                || CASE WHEN v_wh IS NOT NULL THEN ' <span class="bk-who">' || DBMS_XMLGEN.CONVERT(v_wh) || '</span>' END
                || '</td><td>' || k_lab(v_hk) || '</td>'
                || '<td class="num">' || pa_lv(p_id) || '</td>'
                || '<td class="num">' || fmt_int(pa_s(p_id) * 10) || '</td>'
                || '<td>' || DBMS_XMLGEN.CONVERT(v_ev) || '</td>'
                || '<td>' || CASE WHEN v_sq IS NOT NULL THEN ent(v_sq, anchor_id('sq-elapsed', v_sq), 'sql') END || '</td>'
                || '<td>' || DBMS_XMLGEN.CONVERT(v_ob) || '</td>'
                || '<td class="num">' || CASE WHEN pa_bn(p_id) > 0 THEN fmt_int(pa_bn(p_id)) || ' &middot; '
                       || fmt_int(pa_bs(p_id) * 10) || ' s' END || '</td></tr>';
        END IF;
    END js_node;

    -- "+ n more sessions, m s" under display node p_par
    PROCEDURE js_more(p_par PLS_INTEGER, p_lv PLS_INTEGER, p_r PLS_INTEGER, p_n NUMBER, p_s NUMBER) IS
    BEGIN
        v_di := v_di + 1;
        v_js_n := v_js_n + 1;
        v_js(v_js_n) := ',{"i":' || v_di || ',"p":' || p_par || ',"lv":' || p_lv || ',"r":' || p_r
            || ',"k":"m","n":' || p_n || ',"s":' || TO_CHAR(p_s * 10) || '}';
    END js_more;

    PROCEDURE draw_root(p_r PLS_INTEGER) IS
        v_k1   t_ntab;
        v_k2   t_ntab;
        v_d1   PLS_INTEGER;
        v_root PLS_INTEGER;
        v_mn   NUMBER;
        v_ms   NUMBER;
    BEGIN
        js_node(r_id(r_ord(p_r)), 0, p_r, FALSE);
        v_root := v_di;
        kids_of(r_id(r_ord(p_r)), v_k1);
        v_mn := 0; v_ms := 0;
        FOR a IN 1 .. v_k1.COUNT LOOP
            IF a <= c_kids1 THEN
                js_node(v_k1(a), v_root, p_r, FALSE);
                v_d1 := v_di;
                kids_of(v_k1(a), v_k2);
                FOR b IN 1 .. LEAST(v_k2.COUNT, c_kids2) LOOP
                    js_node(v_k2(b), v_d1, p_r, pa_bn(v_k2(b)) > 0);
                END LOOP;
                IF v_k2.COUNT > c_kids2 THEN
                    DECLARE
                        v_xn NUMBER := 0;
                        v_xs NUMBER := 0;
                    BEGIN
                        FOR b IN c_kids2 + 1 .. v_k2.COUNT LOOP
                            v_xn := v_xn + 1 + pa_bn(v_k2(b));
                            v_xs := v_xs + pa_s(v_k2(b)) + pa_bs(v_k2(b));
                        END LOOP;
                        js_more(v_d1, 2, p_r, v_xn, v_xs);
                    END;
                END IF;
            ELSE
                v_mn := v_mn + 1 + pa_bn(v_k1(a));
                v_ms := v_ms + pa_s(v_k1(a)) + pa_bs(v_k1(a));
            END IF;
        END LOOP;
        IF v_k1.COUNT > c_kids1 THEN
            js_more(v_root, 1, p_r, v_mn, v_ms);
        END IF;
    END draw_root;
BEGIN
    v_mycon := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));

    -- the compared windows (validity, skip reason)
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag, skip_reason FROM windows_rollup
    ) LOOP
        v_wvalid(r.week_offset) := r.valid_flag;
        v_wskip(r.week_offset)  := r.skip_reason;
        v_wblk(r.week_offset) := 0; v_wglob(r.week_offset) := 0;
        v_wnw(r.week_offset) := 0;  v_wnb(r.week_offset) := 0;
    END LOOP;

    --
    -- ONE bounded ASH scan: the valid compared windows (per instance)
    -- only; outside the Current window only samples with a holder status
    -- worth counting.  Four groupings in one pass: 1 per window, 2 per
    -- Current waiter -> holder edge, 3 per Current session (what the
    -- holders were doing), 4 per blocked Current sample (inst,sample_id:
    -- chains are resolved inside one sample).  Keys: inst,sid,serial#.
    --
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        bka AS (
            SELECT vw.week_offset AS wk,
                   ash.instance_number || ',' || ash.session_id || ',' || ash.session_serial# AS nk,
                   NVL(ash.blocking_inst_id, ash.instance_number) || ',' || ash.blocking_session
                       || ',' || ash.blocking_session_serial# AS bkey,
                   CASE WHEN ash.blocking_session_status = 'VALID'
                         AND ash.blocking_session IS NOT NULL
                         AND NOT (ash.blocking_session = ash.session_id
                              AND NVL(ash.blocking_session_serial#, -1) = ash.session_serial#
                              AND NVL(ash.blocking_inst_id, ash.instance_number) = ash.instance_number)
                        THEN 1 ELSE 0 END AS isv,
                   CASE WHEN ash.blocking_session_status = 'GLOBAL' THEN 1 ELSE 0 END AS isg,
                   ash.instance_number || ',' || ash.sample_id AS sk,
                   CASE WHEN ash.session_state = 'ON CPU' THEN 'ON CPU' ELSE ash.event END AS ev,
                   ash.sql_id, ash.user_id, ash.con_id, ash.module, ash.program, ash.session_type,
                   CASE WHEN ash.current_obj# > 0 THEN ash.current_obj# END AS cobj
            FROM   valid_windows vw
            JOIN   dba_hist_active_sess_history ash
              ON   ash.dbid = vw.dbid
             AND   ash.instance_number = vw.instance_number
             AND   ash.snap_id BETWEEN vw.begin_snap_id AND vw.end_snap_id + 1
             AND   ash.sample_time >= vw.win_start_ts
             AND   ash.sample_time <  vw.win_end_ts
            WHERE  ash.dbid IN (~dbid_list)
              AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
              AND  (vw.week_offset = 0 OR ash.blocking_session_status IN ('VALID', 'GLOBAL'))
        ),
        -- the groupings in one pass: the scan's rows times a 4-row
        -- generator (GROUPING SETS is avoided: its rewrite fails with
        -- ORA-00905 on the # column names in 19c)
        bkx AS (
            SELECT bka.*, gs.g AS gid
            FROM   bka
            CROSS JOIN (SELECT LEVEL AS g FROM dual CONNECT BY LEVEL <= 4) gs
            WHERE  gs.g = 1 OR (gs.g IN (2, 4) AND bka.wk = 0 AND bka.isv = 1) OR (gs.g = 3 AND bka.wk = 0)
        ),
        bkg AS (
            SELECT gid,
                   CASE WHEN gid = 1 THEN wk END   AS wk2,
                   CASE WHEN gid IN (2, 4) THEN nk END   AS ew,
                   CASE WHEN gid IN (2, 4) THEN bkey END AS eb,
                   CASE WHEN gid = 3 THEN nk END   AS nk2,
                   CASE WHEN gid = 4 THEN sk END   AS sk2,
                   SUM(isv) AS nv, SUM(isg) AS ng, COUNT(*) AS nall,
                   COUNT(DISTINCT CASE WHEN isv = 1 THEN nk END)   AS nw,
                   COUNT(DISTINCT CASE WHEN isv = 1 THEN bkey END) AS nb,
                   STATS_MODE(CASE WHEN isv = 1 THEN ev END)     AS bev,
                   STATS_MODE(CASE WHEN isv = 1 THEN sql_id END) AS bsql,
                   STATS_MODE(CASE WHEN isv = 1 THEN cobj END)   AS bobj,
                   STATS_MODE(ev) AS nev, STATS_MODE(sql_id) AS nsql, STATS_MODE(user_id) AS nusr,
                   MAX(con_id) AS ncon, STATS_MODE(module) AS nmod, STATS_MODE(program) AS nprg,
                   MAX(session_type) AS nst, STATS_MODE(cobj) AS nobj
            FROM   bkx
            GROUP BY gid,
                   CASE WHEN gid = 1 THEN wk END,
                   CASE WHEN gid IN (2, 4) THEN nk END,
                   CASE WHEN gid IN (2, 4) THEN bkey END,
                   CASE WHEN gid = 3 THEN nk END,
                   CASE WHEN gid = 4 THEN sk END
        )
        SELECT * FROM bkg
        ORDER BY gid, sk2, nv DESC, wk2, ew, eb, nk2
    ) LOOP
        IF r.gid = 1 THEN
            v_wblk(r.wk2) := r.nv; v_wglob(r.wk2) := r.ng;
            v_wnw(r.wk2) := r.nw;  v_wnb(r.wk2) := r.nb;
        ELSIF r.gid = 2 THEN
            v_insts(k_part(r.ew, 1)) := 1;
            v_insts(k_part(r.eb, 1)) := 1;
            IF e_cnt < c_maxe THEN
                e_cnt := e_cnt + 1;
                e_ev(e_cnt) := r.bev; e_sql(e_cnt) := r.bsql; e_obj(e_cnt) := r.bobj;
                v_ek(r.ew || '|' || r.eb) := e_cnt;
            END IF;
        ELSIF r.gid = 3 THEN
            v_nodes(r.nk2).n := r.nall;     v_nodes(r.nk2).usr := r.nusr;
            v_nodes(r.nk2).con := r.ncon;   v_nodes(r.nk2).mdl := r.nmod;
            v_nodes(r.nk2).prg := r.nprg;   v_nodes(r.nk2).sqlid := r.nsql;
            v_nodes(r.nk2).ev := r.nev;     v_nodes(r.nk2).obj := r.nobj;
            v_nodes(r.nk2).styp := r.nst;
        ELSE
            IF s_rows < c_maxs THEN
                IF s_key IS NULL OR r.sk2 <> s_key THEN flush_sample; s_key := r.sk2; END IF;
                s_rows := s_rows + 1;
                s_n := s_n + 1;
                s_w(s_n) := r.ew; s_b(s_n) := r.eb; s_ev(s_n) := r.bev; s_sql(s_n) := r.bsql;
                s_m(r.ew) := r.eb;
            ELSE
                s_left := s_left + r.nv;
            END IF;
        END IF;
    END LOOP;
    flush_sample;
    v_multi := v_insts.COUNT > 1;

    -- Part 1 numbers: blocked seconds per valid window, prior mean / sd
    v_i := v_wvalid.FIRST;
    WHILE v_i IS NOT NULL LOOP
        IF v_wvalid(v_i) = 'Y' THEN
            v_pairs := v_pairs || CASE WHEN v_pairs IS NOT NULL THEN ';' END
                || v_i || ':' || wg_tok(v_wblk(v_i) * 10);
            IF v_i = 0 THEN
                v_curok := TRUE; v_cur := v_wblk(0) * 10;
            ELSE
                v_n := v_n + 1; v_sum := v_sum + v_wblk(v_i) * 10;
            END IF;
        END IF;
        v_i := v_wvalid.NEXT(v_i);
    END LOOP;
    IF v_n > 0 THEN
        v_mu := v_sum / v_n;
        v_i := v_wvalid.FIRST;
        WHILE v_i IS NOT NULL LOOP
            IF v_wvalid(v_i) = 'Y' AND v_i > 0 THEN v_sq := v_sq + POWER(v_wblk(v_i) * 10 - v_mu, 2); END IF;
            v_i := v_wvalid.NEXT(v_i);
        END LOOP;
        v_sd := CASE WHEN v_n > 1 THEN SQRT(v_sq / (v_n - 1)) END;
    END IF;
    v_cur_s := NVL(v_cur, 0);

    -- Part 2: the roots (final holders), their totals, top event / SQL
    FOR i IN 1 .. pa_n LOOP
        IF pa_lv(i) = 0 THEN
            r_n := r_n + 1;
            r_key(r_n) := pa_key(i); r_id(r_n) := i; r_tot(r_n) := pa_bs(i); r_cnt(r_n) := pa_bn(i);
            r_cyc(r_n) := pa_cyc(i); r_bn(i) := -1; r_bsn(i) := -1;
        END IF;
    END LOOP;
    v_tmp := v_rev.FIRST;
    WHILE v_tmp IS NOT NULL LOOP
        v_i := TO_NUMBER(SUBSTR(v_tmp, 1, INSTR(v_tmp, '|') - 1));
        IF v_rev(v_tmp) > r_bn(v_i) THEN r_bn(v_i) := v_rev(v_tmp); r_ev(v_i) := SUBSTR(v_tmp, INSTR(v_tmp, '|') + 1); END IF;
        v_tmp := v_rev.NEXT(v_tmp);
    END LOOP;
    v_tmp := v_rsql.FIRST;
    WHILE v_tmp IS NOT NULL LOOP
        v_i := TO_NUMBER(SUBSTR(v_tmp, 1, INSTR(v_tmp, '|') - 1));
        IF v_rsql(v_tmp) > r_bsn(v_i) THEN r_bsn(v_i) := v_rsql(v_tmp); r_sql(v_i) := SUBSTR(v_tmp, INSTR(v_tmp, '|') + 1); END IF;
        v_tmp := v_rsql.NEXT(v_tmp);
    END LOOP;
    -- r_ev / r_sql are keyed by path id: re-key them by root index
    FOR a IN 1 .. r_n LOOP
        r_ord(a) := a;
    END LOOP;
    DECLARE
        v_e2 t_stab;
        v_s2 t_stab;
    BEGIN
        FOR a IN 1 .. r_n LOOP
            v_e2(a) := CASE WHEN r_ev.EXISTS(r_id(a)) THEN r_ev(r_id(a)) END;
            v_s2(a) := CASE WHEN r_sql.EXISTS(r_id(a)) THEN r_sql(r_id(a)) END;
        END LOOP;
        r_ev := v_e2; r_sql := v_s2;
    END;
    -- rank roots: blocked time behind them, then key (deterministic)
    FOR a IN 1 .. r_n LOOP
        FOR b IN a + 1 .. r_n LOOP
            IF r_tot(r_ord(b)) > r_tot(r_ord(a))
               OR (r_tot(r_ord(b)) = r_tot(r_ord(a)) AND r_key(r_ord(b)) < r_key(r_ord(a))) THEN
                v_k := r_ord(a); r_ord(a) := r_ord(b); r_ord(b) := v_k;
            END IF;
        END LOOP;
    END LOOP;
    FOR a IN 1 .. LEAST(r_n, c_roots) LOOP draw_root(a); END LOOP;

    -- the reads-as sentence + the library row text
    IF v_n >= 3 THEN
        IF v_mu = 0 THEN
            v_ratio := CASE WHEN v_cur_s > 0 THEN 'none in the ' || v_n || ' prior windows'
                            ELSE 'none in the ' || v_n || ' prior windows either' END;
        ELSIF v_cur_s / v_mu >= 2 THEN
            v_ratio := CASE WHEN v_cur_s / v_mu < 100
                            THEN TO_CHAR(v_cur_s / v_mu, 'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                            ELSE TO_CHAR(ROUND(v_cur_s / v_mu), 'FM999999999990') END
                || '&times; the prior mean for this hour (' || dur_txt(v_mu) || ')';
        ELSE
            v_ratio := CASE WHEN v_cur_s >= v_mu THEN '&#9650; ' ELSE '&#9660; ' END
                || TO_CHAR(ABS(v_cur_s - v_mu) / v_mu * 100, 'FM9999990', 'NLS_NUMERIC_CHARACTERS=''.,''')
                || '% vs the prior mean for this hour (' || dur_txt(v_mu) || ')';
        END IF;
    ELSE
        v_ratio := 'too few prior windows (' || v_n || ') to call it normal or not';
    END IF;

    IF NOT v_curok THEN
        v_rd := 'the Current window was skipped ('
            || DBMS_XMLGEN.CONVERT(NVL(v_wskip(0), 'no valid snapshots')) || '), so its blocking is unknown'
            || CASE WHEN v_n > 0 THEN '; the ' || v_n || ' valid prior windows averaged ' || dur_txt(v_mu) || ' of blocked time' END
            || '.';
        v_ls := 'Current window skipped';
    ELSIF v_cur_s = 0 OR r_n = 0 THEN
        v_rd := 'no blocking sampled in the Current window'
            || CASE WHEN v_n > 0 AND v_mu > 0 THEN '; the ' || v_n || ' prior windows averaged ' || dur_txt(v_mu)
                    WHEN v_n > 0 THEN '; none in the ' || v_n || ' prior windows either' END || '.';
        v_ls := 'no blocking sampled in the Current window';
    ELSE
        v_tmp := who(r_key(r_ord(1)));
        v_rd := '1 session (' || k_lab(r_key(r_ord(1)))
            || CASE WHEN v_tmp IS NOT NULL THEN ', ' || DBMS_XMLGEN.CONVERT(v_tmp) ELSE ', not sampled' END
            || ') held ' || r_cnt(r_ord(1)) || CASE WHEN r_cnt(r_ord(1)) = 1 THEN ' session' ELSE ' sessions' END
            || ' for ' || dur_txt(r_tot(r_ord(1)) * 10) || ' in total'
            || CASE WHEN r_ev(r_ord(1)) IS NOT NULL THEN ', mostly on ' || DBMS_XMLGEN.CONVERT(r_ev(r_ord(1))) END
            || CASE WHEN r_n > 1 THEN '; ' || (r_n - 1) || ' other '
                    || CASE WHEN r_n = 2 THEN 'holder' ELSE 'holders' END || ': ' || dur_txt((v_cur_s / 10 - r_tot(r_ord(1))) * 10) END
            || '. All blocked time in the Current window: ' || dur_txt(v_cur_s) || ', ' || v_ratio || '.';
        v_ls := dur_txt(v_cur_s) || ' blocked, ' || dur_txt(r_tot(r_ord(1)) * 10) || ' behind '
            || k_lab(r_key(r_ord(1)))
            || CASE WHEN v_tmp IS NOT NULL THEN ' (' || DBMS_XMLGEN.CONVERT(v_tmp) || ')' END
            || '; ' || v_ratio;
    END IF;
    v_open := v_curok AND v_cur_s >= c_open AND (v_n < 3 OR v_mu = 0 OR v_cur_s >= 2 * v_mu);

    -- ---- markup --------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<section id="blocking" class="vw in-s in-a lib' || CASE WHEN v_open THEN ' lopen' END
        || '" style="--os:14"><h2>Blocking'
        || '<small class="h2sub">Who held the sessions that waited, and is this much blocking normal for this hour</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('blocking', v_ls));

    -- Part 1: blocked time per window
    v_lab := '<div class="l" role="rowheader"><span class="big">'
        || CASE WHEN v_curok THEN fmt_num(v_cur_s / 60) ELSE '&ndash;' END
        || '<span class="u">min</span></span>'
        || '<span class="sub">prior mean ' || CASE WHEN v_mu IS NULL THEN '&mdash;' ELSE fmt_num(v_mu / 60) || ' min' END
        || '</span></div>';
    v_gut := '<div class="g" role="cell"><div class="gl1">'
        || REPLACE(delta_span(v_cur, v_mu, NULL, 'Y'), 'class="d ', 'class="d d1 ')
        || '</div><span class="bk-ns">not scored</span></div>';
    DBMS_OUTPUT.PUT_LINE('<div class="panel bk-strip"><div class="wg fit hov"' || wg_attr
        || ' role="table" aria-label="Blocked time per compared window">');
    wg_ruler_put(NULL, '<span class="ct">Blocked time per window</span>'
        || '<span class="cs">minutes sessions waited behind a holder</span>',
        '<span class="gt">vs prior mean</span>');
    DBMS_OUTPUT.PUT_LINE(wg_bars(v_pairs, 1/60, v_mu, v_sd, NULL, v_lab, v_gut, 'bk-bars'));
    DBMS_OUTPUT.PUT_LINE('</div></div>');

    -- Part 2: the graph
    IF v_curok AND r_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div class="bk-lg" aria-hidden="true">'
            || '<span><i class="bk-k bk-kr"></i>final holder (waits on no one)</span>'
            || '<span><i class="bk-k bk-kw"></i>waiting session</span>'
            || '<span><i class="bk-k bk-kn"></i>holder not sampled</span>'
            || '<span><i class="bk-k bk-ke"></i>arrow from holder to waiter, width = seconds behind it</span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="bk-plot" id="bk-plot"><p class="note bk-nojs">The graph needs JavaScript; '
            || 'the tables below hold every number.</p></div>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('<p class="bk-rd"><b>Reads as:</b> ' || UPPER(SUBSTR(v_rd, 1, 1)) || SUBSTR(v_rd, 2) || '</p>');

    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.blocking={"cur":'
        || CASE WHEN v_curok THEN TO_CHAR(v_cur_s) ELSE 'null' END
        || ',"roots":' || r_n || ',"shown":' || LEAST(r_n, c_roots) || ',"nodes":[');
    FOR a IN 1 .. v_js_n LOOP DBMS_OUTPUT.PUT_LINE(v_js(a)); END LOOP;
    DBMS_OUTPUT.PUT_LINE(']};</script>');

    -- holders table (every root, capped at 50)
    IF v_curok AND r_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<table class="bk-tbl" id="bk-holders"><caption>Holders in the Current window, '
            || 'by blocked time behind them</caption><thead><tr><th>#</th><th>Holder</th><th>What it was doing</th>'
            || '<th class="num">Sessions held</th><th class="num">Blocked s</th><th>Top event</th>'
            || '<th>Top waiter SQL</th></tr></thead><tbody>');
        FOR a IN 1 .. LEAST(r_n, 50) LOOP
            v_tmp := who(r_key(r_ord(a)));
            DBMS_OUTPUT.PUT_LINE('<tr><td class="num">' || a || '</td><td>' || k_lab(r_key(r_ord(a)))
                || CASE WHEN r_cyc(r_ord(a)) = 'Y' THEN ' <span class="imm" title="a chain came back to a session already in it '
                        || '(a cycle, e.g. a deadlock caught by the sampler); it ends here">cycle</span>' END
                || CASE WHEN v_tmp IS NOT NULL THEN ' <span class="bk-who">' || DBMS_XMLGEN.CONVERT(v_tmp) || '</span>' END
                || '</td><td>'
                || CASE WHEN v_tmp IS NULL THEN 'holder not sampled (idle in transaction?)'
                        ELSE DBMS_XMLGEN.CONVERT(v_nodes(r_key(r_ord(a))).ev)
                             || CASE WHEN v_nodes(r_key(r_ord(a))).sqlid IS NOT NULL THEN ', '
                                     || ent(v_nodes(r_key(r_ord(a))).sqlid, anchor_id('sq-elapsed', v_nodes(r_key(r_ord(a))).sqlid), 'sql') END
                             || ', sampled ' || fmt_int(v_nodes(r_key(r_ord(a))).n * 10) || ' s' END
                || '</td><td class="num">' || fmt_int(r_cnt(r_ord(a)))
                || '</td><td class="num">' || fmt_int(r_tot(r_ord(a)) * 10)
                || '</td><td>' || DBMS_XMLGEN.CONVERT(r_ev(r_ord(a)))
                || '</td><td>' || CASE WHEN r_sql(r_ord(a)) IS NOT NULL
                                       THEN ent(r_sql(r_ord(a)), anchor_id('sq-elapsed', r_sql(r_ord(a))), 'sql') END
                || '</td></tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        IF r_n > 50 THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note">' || (r_n - 50) || ' smaller holders not listed.</p>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<details class="bk-fold"><summary>Every waiter the graph draws ('
            || v_er_n || ')</summary><table class="bk-tbl" id="bk-edges"><thead><tr><th>Waiter</th><th>Blocked by</th>'
            || '<th class="num">Level</th><th class="num">s behind it</th><th>Event</th>'
            || '<th>SQL</th><th>Object</th><th class="num">Behind this waiter</th></tr></thead><tbody>');
        FOR a IN 1 .. v_er_n LOOP DBMS_OUTPUT.PUT_LINE(v_er(a)); END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
    END IF;

    -- per-window numbers
    DBMS_OUTPUT.PUT_LINE('<details class="bk-fold"><summary>Blocked time per window</summary>'
        || '<table class="bk-tbl" id="bk-windows"><thead><tr><th>Window</th><th class="num">Blocked s</th>'
        || '<th class="num">Blocked min</th><th class="num">Waiting sessions</th><th class="num">Holders</th>'
        || '<th class="num" title="samples whose holder is on another RAC instance, not known by session">GLOBAL samples</th>'
        || '</tr></thead><tbody>');
    FOR k IN 0 .. ~weeks_back LOOP
        IF v_wvalid.EXISTS(k) AND v_wvalid(k) = 'Y' THEN
            DBMS_OUTPUT.PUT_LINE('<tr><td data-w="' || k || '">' || wg_title(k) || ' <span class="bk-off">'
                || wg_off(k) || '</span></td><td class="num" data-w="' || k || '">' || fmt_int(v_wblk(k) * 10)
                || '</td><td class="num">' || fmt_num(v_wblk(k) * 10 / 60)
                || '</td><td class="num">' || fmt_int(v_wnw(k)) || '</td><td class="num">' || fmt_int(v_wnb(k))
                || '</td><td class="num">' || fmt_int(v_wglob(k)) || '</td></tr>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<tr class="bk-skip"><td data-w="' || k || '">' || wg_title(k) || ' <span class="bk-off">'
                || wg_off(k) || '</span></td><td colspan="5">skipped: '
                || DBMS_XMLGEN.CONVERT(NVL(CASE WHEN v_wskip.EXISTS(k) THEN v_wskip(k) END, 'no snapshots'))
                || '</td></tr>');
        END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
    DBMS_OUTPUT.PUT_LINE('<p class="note bk-meth">One ASH sample = 10 s of a session&#39;s time. Counted: samples '
        || 'whose holder is known by session (status VALID), any event (row locks, but also log file switches '
        || 'behind LGWR or buffer busy waits). Holders on another RAC instance that ASH cannot name (GLOBAL) are '
        || 'only counted in the per-window table. Not scored: no metric policy line fits.'
        || CASE WHEN s_left > 0 THEN ' ' || fmt_int(s_left * 10) || ' s of blocked samples past the first '
                || c_maxs || ' are left out of the graph.' END || '</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

@@sql/lib/js_blocking.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 24_blocking END -->'); END;
/
