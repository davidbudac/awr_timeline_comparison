--
-- 29_who.sql
-- "Who added the load" (plan 045): the compared windows' FOREGROUND active
-- sessions broken down by service, module, machine, program, user and
-- (when the samples carry more than one) PDB.  The verdict splits the
-- extra DB time by wait class, the Activity charts by wait event and Top
-- SQL by statement; this section answers WHO for the whole workload,
-- statements outside every top N included.  A breakdown, not a filter.
--
-- Counted: DBA_HIST_ACTIVE_SESS_HISTORY samples with session_type
-- 'FOREGROUND', ON CPU or in a non-idle wait (section 09's predicate), so
-- the totals are comparable with DB time and the verdict's rise.  One
-- persisted sample stands for 10 s of a session's time; AAS per window =
-- samples / 360 / win_hours (section 09's win).  A sample counts toward
-- EVERY compared window that holds it (overlapping windows each count it).
-- Only VALID windows (valid_windows, per instance: snapshot range + sample
-- time, section 24's join); a skipped window is unknown (an empty slot in
-- the Trend), a valid window without a sample for a value is 0.
--
-- ONE bounded ASH scan, aggregated first to (window, service, module,
-- machine, program, user, container) and then multiplied by a 6-row
-- generator (one row per dimension) -- not GROUPING SETS (its rewrite
-- raises ORA-00905 on the # column names in 19c, see section 24).  Per
-- dimension the query keeps the 40 values with the most samples over all
-- compared windows (analytic DENSE_RANK) and sums the rest into one
-- "(others)" value, so the fetch stays small whatever the cardinality:
-- at most 6 x 41 x (weeks_back + 1) rows.
--
-- Program names are folded IN THE SQL, before the cut (on the grouped rows,
-- not per sample): a parallel or job
-- slave's number ("oracle@host (P003)", "(J001)", "(PZ99)") becomes
-- "(Pnnn)" / "(Jnnn)", so 80 PX slaves do not take the 40 slots.  The rule
-- is one REGEXP_REPLACE (a block-local PL/SQL function cannot be called
-- from SQL):  \(([A-Z])([0-9]{3}|[A-Z][0-9]{2})\)$  ->  (\1nnn).  Twin:
-- demo/awrdemo/sections/s29_who.py norm_program.
--
-- Shown per dimension: the values whose time ROSE (Current minus the mean
-- of the valid prior windows), largest rise first, at most 8; the rest
-- under "+ n more" (a <details>).  When no value rose (or the rise is
-- unknown) the 8 largest by Current lead instead.  Plain delta, a share of
-- the total foreground rise (number + CSS bar) and a micro strip; never a
-- severity, a count or a crit / warn row (tables data-nocount).
--
-- Names.  ALL_USERS (public) for user_id, as section 24 ("user id N
-- (container c)" for a user of another container).  Service and PDB names
-- come from views the README lists as OPTIONAL grants, read only through
-- dynamic SQL inside a handler for ORA-00942 / ORA-01031 (lint check 35):
-- DBA_HIST_SERVICE_NAME (service_name_hash -> service_name) and
-- DBA_HIST_PDB_INSTANCE (con_id -> pdb_name, the latest open_time).
-- Without them a service reads "service hash 123456" and a PDB "con_id 3".
--
-- The DB time card (07 ran before this section) gets one evidence row when
-- one module (else service, else machine, else user) value carries at
-- least 30% of a total foreground rise of at least 0.1 AAS: a hidden
-- div#who-ev-src and a one-line script that APPENDS it to #f-dbtime dl.ev
-- while the page parses (plan 043's pattern in section 02).  Placeholders
-- ("(no module)") and "(others)" are never cited there.
--
-- Read-only: SELECT only.  Explains only: no finding, count or severity.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 29_who BEGIN -->'); END;
/

DECLARE
    TYPE t_ntab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_stab IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    TYPE t_kn   IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    TYPE t_ks   IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(200);

    c_keep   CONSTANT PLS_INTEGER := 40;     -- values kept per dimension (the SQL's literal 40)
    c_show   CONSTANT PLS_INTEGER := 8;      -- rows shown before "+ n more"
    c_dom    CONSTANT NUMBER      := 0.5;    -- one value carries half the rise: named
    c_card   CONSTANT NUMBER      := 0.3;    -- the DB time card's row
    c_min    CONSTANT NUMBER      := 0.1;    -- AAS: a rise worth attributing
    c_spa    CONSTANT NUMBER      := 360 * ~win_hours;   -- samples per AAS in one window

    -- windows
    v_wvalid t_stab;
    v_wskip  t_stab;
    v_np     PLS_INTEGER := 0;               -- valid prior windows
    v_curok  BOOLEAN := FALSE;

    -- the dimensions
    d_code   t_stab;
    d_word   t_stab;
    d_head   t_stab;
    d_on     t_stab;                         -- 'Y' = shown

    -- the values, 1 .. x_n
    x_n      PLS_INTEGER := 0;
    x_dim    t_ntab;
    x_rk     t_ntab;
    x_key    t_stab;
    x_nam    t_stab;                         -- display text (not escaped)
    x_ph     t_stab;                         -- 'P' placeholder, 'O' (others), 'N' a real name
    x_cs     t_ntab;                         -- Current samples
    x_ps     t_ntab;                         -- samples summed over the valid prior windows
    x_ri     t_ntab;                         -- integer rise key: cs x np - ps
    x_cur    t_ntab;
    x_mu     t_ntab;
    x_rise   t_ntab;
    x_sd     t_ntab;                         -- sample sd over the valid prior windows (the card's dot)
    x_id     t_stab;
    v_ix     t_kn;                           -- 'g|rk' -> value index
    v_sm     t_kn;                           -- 'i|wk' -> samples
    v_nk     t_ntab;                         -- distinct values per dimension

    -- totals (dimension 1: every sample has exactly one service key)
    v_tcs    NUMBER := 0;
    v_tps    NUMBER := 0;
    v_tcur   NUMBER;
    v_tmu    NUMBER;
    v_trise  NUMBER;

    -- names
    v_svc    t_ks;
    v_pdb    t_ks;
    v_unames t_ks;
    v_mycon  NUMBER;
    v_nosvc  VARCHAR2(4000);
    v_nopdb  VARCHAR2(4000);
    v_rc     SYS_REFCURSOR;
    v_sql    VARCHAR2(4000);
    v_hn     t_stab;
    v_hs     t_stab;

    -- output
    v_ord    t_ntab;
    v_memo   CLOB;
    v_rd     VARCHAR2(32767);
    v_ls     VARCHAR2(32767);
    v_dm     VARCHAR2(32767);
    v_sp     VARCHAR2(32767);
    v_head   VARCHAR2(4000);
    v_open   BOOLEAN := FALSE;
    v_attr   BOOLEAN := FALSE;               -- the rise can be attributed
    v_pick   PLS_INTEGER;
    v_best   PLS_INTEGER;
    v_bshr   NUMBER;
    v_ndom   PLS_INTEGER := 0;
    v_shown  PLS_INTEGER;
    v_byrise BOOLEAN;
    v_t      PLS_INTEGER;
    v_k      VARCHAR2(200);
    v_i      PLS_INTEGER;
    v_ss     NUMBER;

    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql

    -- a 6-decimal number token for data-* / data-spark (dot decimal)
    FUNCTION wt(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN NULL; END IF;
        RETURN TO_CHAR(ROUND(p, 6), 'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END wt;

    -- a share of the rise as text: "74%", "&lt;1%", "&gt;100%"
    FUNCTION pct_txt(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p >= 100.5 THEN '&gt;100%'
                    WHEN p < 0.5 THEN '&lt;1%'
                    ELSE TO_CHAR(ROUND(p)) || '%' END;
    END pct_txt;

    -- a signed AAS amount: "+6.700", "&minus;0.2500"
    FUNCTION sgn(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        IF p < 0 THEN RETURN '&minus;' || fmt_num(-p); END IF;
        RETURN '+' || fmt_num(p);
    END sgn;

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

    -- the display text of value key p_k of dimension p_g
    FUNCTION val_name(p_g PLS_INTEGER, p_k VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(4000) := SUBSTR(p_k, 2);
    BEGIN
        IF p_k = 'o' THEN
            RETURN '(' || TO_CHAR(v_nk(p_g) - c_keep) || CASE WHEN v_nk(p_g) - c_keep = 1 THEN ' other)' ELSE ' others)' END;
        END IF;
        IF p_k = 'n' THEN
            RETURN CASE p_g WHEN 1 THEN '(no service)' WHEN 2 THEN '(no module)' WHEN 3 THEN '(no machine)'
                            WHEN 4 THEN '(no program)' WHEN 5 THEN '(no user)' ELSE '(no container)' END;
        END IF;
        IF p_g = 1 THEN
            RETURN CASE WHEN v_svc.EXISTS(v) THEN v_svc(v) ELSE 'service hash ' || v END;
        ELSIF p_g = 5 THEN
            RETURN usr_name(TO_NUMBER(SUBSTR(v, 1, INSTR(v, ',') - 1)), TO_NUMBER(SUBSTR(v, INSTR(v, ',') + 1)));
        ELSIF p_g = 6 THEN
            RETURN CASE WHEN v_pdb.EXISTS(v) THEN v_pdb(v) WHEN v = '1' THEN 'CDB$ROOT' ELSE 'con_id ' || v END;
        END IF;
        RETURN v;
    END val_name;

    -- value a goes before value b in its dimension's table
    FUNCTION goes_first(a PLS_INTEGER, b PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN
        IF v_byrise THEN
            RETURN x_ri(a) > x_ri(b) OR (x_ri(a) = x_ri(b) AND x_cs(a) > x_cs(b))
                OR (x_ri(a) = x_ri(b) AND x_cs(a) = x_cs(b) AND x_rk(a) < x_rk(b));
        END IF;
        RETURN x_cs(a) > x_cs(b) OR (x_cs(a) = x_cs(b) AND x_rk(a) < x_rk(b));
    END goes_first;

    -- one table row of value i
    FUNCTION row_html(i PLS_INTEGER) RETURN VARCHAR2 IS
        v_s   NUMBER;
        v_csv VARCHAR2(32767);
    BEGIN
        IF v_attr AND x_rise(i) > 0 THEN v_s := x_rise(i) / v_trise * 100; END IF;
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_csv := v_csv || CASE WHEN k < ~weeks_back THEN ',' END
                || CASE WHEN v_wvalid.EXISTS(k) AND v_wvalid(k) = 'Y'
                        THEN wt(CASE WHEN v_sm.EXISTS(i || '|' || k) THEN v_sm(i || '|' || k) ELSE 0 END / c_spa) END;
        END LOOP;
        RETURN '<tr id="' || x_id(i) || '" data-cur="' || wt(x_cur(i)) || '" data-mu="' || wt(x_mu(i))
            || '" data-rise="' || wt(x_rise(i)) || '" data-shr="'
            || CASE WHEN v_s IS NOT NULL THEN TO_CHAR(LEAST(100, ROUND(v_s))) END || '"'
            || CASE WHEN x_ph(i) <> 'N' THEN ' data-ph="' || x_ph(i) || '"' END || '>'
            || '<td class="who-v">' || DBMS_XMLGEN.CONVERT(x_nam(i)) || '</td>'
            || '<td class="num" data-w="0"><b>' || fmt_num(x_cur(i)) || '</b></td>'
            || '<td class="num">' || fmt_num(x_mu(i)) || '</td>'
            || '<td class="num">' || sgn(x_rise(i)) || '</td>'
            || '<td class="num">' || delta_span(x_cur(i), x_mu(i), NULL, 'Y') || '</td>'
            || '<td class="who-sh">'
            || CASE WHEN v_s IS NOT NULL
                    THEN '<span class="who-bar"><i style="--w:' || TO_CHAR(LEAST(100, ROUND(v_s))) || '%"></i></span>'
                         || '<span class="who-p">' || pct_txt(v_s) || '</span>'
                    ELSE '<span class="who-p">&mdash;</span>' END || '</td>'
            || '<td class="trend" data-spark="' || v_csv || '" data-spark-title="'
            || d_head(x_dim(i)) || ' ' || DBMS_XMLGEN.CONVERT(x_nam(i)) || ' (AAS)"></td></tr>';
    END row_html;
BEGIN
    v_mycon := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));
    d_code(1) := 'svc'; d_word(1) := 'service'; d_head(1) := 'Service';
    d_code(2) := 'mod'; d_word(2) := 'module';  d_head(2) := 'Module';
    d_code(3) := 'mch'; d_word(3) := 'machine'; d_head(3) := 'Machine';
    d_code(4) := 'prg'; d_word(4) := 'program'; d_head(4) := 'Program';
    d_code(5) := 'usr'; d_word(5) := 'user';    d_head(5) := 'User';
    d_code(6) := 'pdb'; d_word(6) := 'PDB';     d_head(6) := 'PDB';
    FOR g IN 1 .. 6 LOOP v_nk(g) := 0; d_on(g) := 'Y'; END LOOP;

    -- the compared windows (validity, skip reason)
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag, skip_reason FROM windows_rollup
    ) LOOP
        v_wvalid(r.week_offset) := r.valid_flag;
        v_wskip(r.week_offset)  := r.skip_reason;
        IF r.valid_flag = 'Y' THEN
            IF r.week_offset = 0 THEN v_curok := TRUE; ELSE v_np := v_np + 1; END IF;
        END IF;
    END LOOP;

    --
    -- ONE bounded ASH scan over the valid compared windows (per instance),
    -- FOREGROUND samples ON CPU or in a non-idle wait.  Keys carry a one-
    -- letter prefix: 'v' + the value, 'n' = NULL; the cut turns every
    -- value past the 40th of its dimension into 'o' (others).
    --
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        wa AS (
            SELECT vw.week_offset AS wk,
                   CASE WHEN ash.service_hash IS NULL THEN 'n' ELSE 'v' || TO_CHAR(ash.service_hash) END AS k1,
                   CASE WHEN ash.module IS NULL THEN 'n' ELSE 'v' || ash.module END AS k2,
                   CASE WHEN ash.machine IS NULL THEN 'n' ELSE 'v' || ash.machine END AS k3,
                   CASE WHEN ash.program IS NULL THEN 'n' ELSE 'v' || ash.program END AS k4,
                   CASE WHEN ash.user_id IS NULL THEN 'n'
                        ELSE 'v' || TO_CHAR(ash.user_id) || ',' || TO_CHAR(NVL(ash.con_id, 0)) END AS k5,
                   CASE WHEN ash.con_id IS NULL THEN 'n' ELSE 'v' || TO_CHAR(ash.con_id) END AS k6
            FROM   valid_windows vw
            JOIN   dba_hist_active_sess_history ash
              ON   ash.dbid = vw.dbid
             AND   ash.instance_number = vw.instance_number
             AND   ash.snap_id BETWEEN vw.begin_snap_id AND vw.end_snap_id + 1
             AND   ash.sample_time >= vw.win_start_ts
             AND   ash.sample_time <  vw.win_end_ts
            WHERE  ash.dbid IN (~dbid_list)
              AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
              AND  ash.session_type = 'FOREGROUND'
              AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
        ),
        wt6 AS (
            SELECT wk, k1, k2, k3, k4, k5, k6, COUNT(*) AS n
            FROM   wa
            GROUP BY wk, k1, k2, k3, k4, k5, k6
        ),
        -- one row per dimension (a 6-row generator, not GROUPING SETS); the
        -- program fold runs here, once per grouped row
        wx AS (
            SELECT gs.g, wt6.wk,
                   CASE gs.g WHEN 1 THEN wt6.k1 WHEN 2 THEN wt6.k2 WHEN 3 THEN wt6.k3
                             WHEN 4 THEN REGEXP_REPLACE(wt6.k4, '\(([A-Z])([0-9]{3}|[A-Z][0-9]{2})\)$', '(\1nnn)')
                             WHEN 5 THEN wt6.k5 ELSE wt6.k6 END AS k,
                   wt6.n
            FROM   wt6
            CROSS JOIN (SELECT LEVEL AS g FROM dual CONNECT BY LEVEL <= 6) gs
        ),
        wg AS (
            SELECT g, k, wk, SUM(n) AS n
            FROM   wx
            GROUP BY g, k, wk
        ),
        wr AS (
            SELECT g, k, wk, n,
                   DENSE_RANK() OVER (PARTITION BY g ORDER BY kt DESC, k) AS rk,
                   COUNT(DISTINCT k) OVER (PARTITION BY g) AS nk
            FROM  (SELECT g, k, wk, n, SUM(n) OVER (PARTITION BY g, k) AS kt FROM wg)
        )
        SELECT g,
               CASE WHEN rk <= 40 THEN rk ELSE 41 END AS rk2,
               MAX(CASE WHEN rk <= 40 THEN k ELSE 'o' END) AS kk,
               MAX(nk) AS nk,
               wk,
               SUM(n) AS n
        FROM   wr
        GROUP BY g, CASE WHEN rk <= 40 THEN rk ELSE 41 END, wk
        ORDER BY g, rk2, wk
    ) LOOP
        v_k := r.g || '|' || r.rk2;
        IF NOT v_ix.EXISTS(v_k) THEN
            x_n := x_n + 1;
            v_ix(v_k) := x_n;
            x_dim(x_n) := r.g; x_rk(x_n) := r.rk2; x_key(x_n) := r.kk;
            x_ph(x_n) := CASE r.kk WHEN 'o' THEN 'O' WHEN 'n' THEN 'P' ELSE 'N' END;
            v_nk(r.g) := r.nk;
        END IF;
        v_sm(v_ix(v_k) || '|' || r.wk) := r.n;
    END LOOP;

    -- names of services and containers (optional grants: dynamic SQL)
    IF x_n > 0 THEN
        v_sql := 'SELECT TO_CHAR(service_name_hash), MIN(service_name) FROM dba_hist_service_name'
            || ' WHERE dbid IN (~dbid_list) GROUP BY service_name_hash';
        BEGIN
            OPEN v_rc FOR v_sql;
            FETCH v_rc BULK COLLECT INTO v_hn, v_hs;
            CLOSE v_rc;
            FOR j IN 1 .. v_hn.COUNT LOOP
                IF v_hn(j) IS NOT NULL THEN v_svc(v_hn(j)) := v_hs(j); END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE IN (-942, -1031) THEN
                    IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                    v_nosvc := SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END IF;
    IF v_nk(6) <= 1 THEN d_on(6) := 'N'; END IF;
    IF x_n > 0 AND d_on(6) = 'Y' THEN
        v_hn.DELETE; v_hs.DELETE;
        v_sql := 'SELECT TO_CHAR(con_id), MAX(pdb_name) KEEP (DENSE_RANK LAST ORDER BY open_time) FROM dba_hist_pdb_instance'
            || ' WHERE dbid IN (~dbid_list) GROUP BY con_id';
        BEGIN
            OPEN v_rc FOR v_sql;
            FETCH v_rc BULK COLLECT INTO v_hn, v_hs;
            CLOSE v_rc;
            FOR j IN 1 .. v_hn.COUNT LOOP
                IF v_hn(j) IS NOT NULL AND v_hs(j) IS NOT NULL THEN v_pdb(v_hn(j)) := v_hs(j); END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE IN (-942, -1031) THEN
                    IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                    v_nopdb := SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END IF;

    -- per value: Current, prior mean, rise (a valid window without a
    -- sample for the value is 0; skipped windows are left out)
    FOR i IN 1 .. x_n LOOP
        x_nam(i) := val_name(x_dim(i), x_key(i));
        x_cs(i) := CASE WHEN v_curok AND v_sm.EXISTS(i || '|0') THEN v_sm(i || '|0') ELSE 0 END;
        x_ps(i) := 0;
        FOR k IN 1 .. ~weeks_back LOOP
            IF v_wvalid.EXISTS(k) AND v_wvalid(k) = 'Y' AND v_sm.EXISTS(i || '|' || k) THEN
                x_ps(i) := x_ps(i) + v_sm(i || '|' || k);
            END IF;
        END LOOP;
        x_ri(i) := x_cs(i) * v_np - x_ps(i);
        x_cur(i) := CASE WHEN v_curok THEN x_cs(i) / c_spa END;
        x_mu(i) := CASE WHEN v_np > 0 THEN x_ps(i) / v_np / c_spa END;
        x_rise(i) := CASE WHEN v_curok AND v_np > 0 THEN x_cur(i) - x_mu(i) END;
        v_ss := 0;
        FOR k IN 1 .. ~weeks_back LOOP
            IF v_wvalid.EXISTS(k) AND v_wvalid(k) = 'Y' THEN
                v_ss := v_ss + POWER(CASE WHEN v_sm.EXISTS(i || '|' || k) THEN v_sm(i || '|' || k) ELSE 0 END / c_spa - x_mu(i), 2);
            END IF;
        END LOOP;
        x_sd(i) := CASE WHEN v_np > 1 THEN SQRT(v_ss / (v_np - 1)) END;
        x_id(i) := anchor_uniq(anchor_id('who', d_code(x_dim(i)) || '-' || x_nam(i)),
                               d_code(x_dim(i)) || ':' || x_key(i), v_memo);
        IF x_dim(i) = 1 THEN v_tcs := v_tcs + x_cs(i); v_tps := v_tps + x_ps(i); END IF;
    END LOOP;
    v_tcur := CASE WHEN v_curok THEN v_tcs / c_spa END;
    v_tmu := CASE WHEN v_np > 0 THEN v_tps / v_np / c_spa END;
    v_trise := CASE WHEN v_curok AND v_np > 0 THEN v_tcur - v_tmu END;
    v_attr := v_curok AND v_np >= 3 AND x_n > 0 AND v_trise >= c_min;

    -- the reads-as sentence, the library row text, the card's row
    IF NOT v_curok THEN
        v_rd := 'The Current window was skipped ('
            || DBMS_XMLGEN.CONVERT(NVL(CASE WHEN v_wskip.EXISTS(0) THEN v_wskip(0) END, 'no valid snapshots'))
            || '), so who was active in it is unknown.';
        v_ls := 'Current window skipped';
    ELSIF x_n = 0 THEN
        v_rd := 'No foreground ASH samples in the compared windows.';
        v_ls := 'no foreground ASH samples';
    ELSIF v_np < 3 THEN
        v_rd := CASE WHEN v_np = 0 THEN 'No valid prior window' ELSE 'Only ' || v_np || ' valid prior '
                     || CASE WHEN v_np = 1 THEN 'window' ELSE 'windows' END END
            || ': too few to say who added load. Foreground activity in the Current window: '
            || fmt_num(v_tcur) || '&nbsp;AAS.';
        v_ls := 'too few prior windows (' || v_np || ')';
    ELSIF v_trise <= 0 THEN
        v_rd := 'Foreground activity did not rise: ' || fmt_num(v_tcur) || '&nbsp;AAS in the Current window against a prior mean of '
            || fmt_num(v_tmu) || '&nbsp;AAS over ' || v_np || ' valid prior windows.';
        v_ls := 'foreground activity did not rise (' || fmt_num(v_tcur) || '&nbsp;AAS)';
    ELSIF v_trise < c_min THEN
        v_rd := 'Foreground activity rose by only ' || sgn(v_trise) || '&nbsp;AAS (' || fmt_num(v_tcur)
            || '&nbsp;AAS against a prior mean of ' || fmt_num(v_tmu) || '): too little to attribute.';
        v_ls := 'foreground activity about normal (' || sgn(v_trise) || '&nbsp;AAS)';
    ELSE
        v_rd := 'Foreground activity rose by ' || sgn(v_trise) || '&nbsp;AAS (' || fmt_num(v_tcur)
            || '&nbsp;AAS in the Current window against a prior mean of ' || fmt_num(v_tmu) || ' over '
            || v_np || ' valid prior windows).';
        v_ls := sgn(v_trise) || '&nbsp;AAS foreground';
        v_dm := NULL; v_sp := NULL; v_ndom := 0; v_best := NULL; v_bshr := NULL;
        FOR g IN 1 .. 6 LOOP
            IF d_on(g) = 'Y' THEN
                -- the value with the largest rise in this dimension (not "(others)")
                v_pick := NULL;
                FOR i IN 1 .. x_n LOOP
                    IF x_dim(i) = g AND x_ph(i) <> 'O' AND x_rise(i) > 0
                       AND (v_pick IS NULL OR x_ri(i) > x_ri(v_pick)
                            OR (x_ri(i) = x_ri(v_pick) AND x_rk(i) < x_rk(v_pick))) THEN
                        v_pick := i;
                    END IF;
                END LOOP;
                IF v_pick IS NOT NULL THEN
                    IF v_best IS NULL OR x_rise(v_pick) / v_trise > v_bshr THEN
                        v_best := v_pick; v_bshr := x_rise(v_pick) / v_trise;
                    END IF;
                    IF x_rise(v_pick) >= c_dom * v_trise THEN
                        v_ndom := v_ndom + 1;
                        v_dm := v_dm || CASE WHEN v_ndom = 1
                                             THEN ' ' || sgn(x_rise(v_pick)) || ' of it came from ' || d_word(g)
                                                  || ' <b>' || DBMS_XMLGEN.CONVERT(x_nam(v_pick)) || '</b>'
                                             ELSE '; ' || d_word(g) || ' <b>' || DBMS_XMLGEN.CONVERT(x_nam(v_pick))
                                                  || '</b> ' || sgn(x_rise(v_pick)) END;
                        IF v_ndom <= 2 THEN
                            v_ls := v_ls || CASE WHEN v_ndom = 1 THEN '; ' ELSE ', ' END || d_word(g) || ' '
                                || DBMS_XMLGEN.CONVERT(x_nam(v_pick)) || ' ' || sgn(x_rise(v_pick))
                                || ' (' || pct_txt(x_rise(v_pick) / v_trise * 100) || ')';
                        END IF;
                    ELSE
                        v_sp := v_sp || CASE WHEN v_sp IS NOT NULL THEN '; ' END || 'the largest ' || d_word(g) || ' is <b>'
                            || DBMS_XMLGEN.CONVERT(x_nam(v_pick)) || '</b> ' || sgn(x_rise(v_pick))
                            || ' (' || pct_txt(x_rise(v_pick) / v_trise * 100) || ')';
                    END IF;
                END IF;
            END IF;
        END LOOP;
        IF v_ndom > 0 THEN
            v_rd := v_rd || v_dm || '.'
                || CASE WHEN v_sp IS NOT NULL THEN ' Spread over several values: ' || v_sp || '.' END;
            v_open := TRUE;
        ELSIF v_best IS NOT NULL THEN
            v_rd := v_rd || ' The rise is spread: no single value carries half of it; the largest is '
                || d_word(x_dim(v_best)) || ' <b>' || DBMS_XMLGEN.CONVERT(x_nam(v_best)) || '</b> '
                || sgn(x_rise(v_best)) || ' (' || pct_txt(v_bshr * 100) || ').';
            v_ls := v_ls || '; spread, largest ' || d_word(x_dim(v_best)) || ' '
                || DBMS_XMLGEN.CONVERT(x_nam(v_best)) || ' ' || sgn(x_rise(v_best))
                || ' (' || pct_txt(v_bshr * 100) || ')';
        END IF;
    END IF;

    -- ---- markup --------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<section id="who" class="vw in-s in-a lib' || CASE WHEN v_open THEN ' lopen' END
        || '" style="--os:19"><h2>Who added the load'
        || '<small class="h2sub">Foreground active sessions by service, module, machine, program and user (ASH)</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('who', v_ls));

    IF v_curok AND x_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="who-tot" data-cur="' || wt(v_tcur) || '" data-mu="' || wt(v_tmu)
            || '" data-rise="' || wt(v_trise) || '" data-np="' || v_np || '">Foreground activity (ASH, '
            || 'sessions on CPU or in a non-idle wait): <b>' || fmt_num(v_tcur) || '&nbsp;AAS</b> in the Current window, '
            || CASE WHEN v_np > 0 THEN 'prior mean ' || fmt_num(v_tmu) || '&nbsp;AAS over ' || v_np || ' valid prior '
                    || CASE WHEN v_np = 1 THEN 'window' ELSE 'windows' END || ', rise ' || sgn(v_trise) || '&nbsp;AAS.'
                    ELSE 'no valid prior window.' END
            || '</p>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('<p class="who-rd"><b>Reads as:</b> ' || v_rd || '</p>');

    IF v_curok AND x_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div class="who-grid">');
        FOR g IN 1 .. 6 LOOP
            IF d_on(g) = 'Y' THEN
                -- this dimension's values in display order
                v_ord.DELETE;
                v_byrise := FALSE;
                FOR i IN 1 .. x_n LOOP
                    IF x_dim(i) = g THEN
                        v_ord(v_ord.COUNT + 1) := i;
                        IF v_np > 0 AND x_ri(i) > 0 THEN v_byrise := TRUE; END IF;
                    END IF;
                END LOOP;
                FOR a IN 1 .. v_ord.COUNT LOOP
                    FOR b IN a + 1 .. v_ord.COUNT LOOP
                        IF goes_first(v_ord(b), v_ord(a)) THEN
                            v_t := v_ord(a); v_ord(a) := v_ord(b); v_ord(b) := v_t;
                        END IF;
                    END LOOP;
                END LOOP;
                v_shown := 0;
                FOR a IN 1 .. v_ord.COUNT LOOP
                    IF v_shown < c_show AND (NOT v_byrise OR x_ri(v_ord(a)) > 0) THEN v_shown := v_shown + 1; END IF;
                END LOOP;
                v_head := '<thead><tr><th>' || d_head(g) || '</th><th class="num" data-w="0">Current (AAS)</th>'
                    || '<th class="num">Prior mean</th><th class="num" title="Current minus the mean of the valid prior windows">Rise</th>'
                    || '<th class="num">&Delta; vs mean</th>'
                    || '<th title="this value&#39;s rise as a share of the rise in all foreground activity">Share of the rise</th>'
                    || '<th class="trend">Trend</th></tr></thead>';
                DBMS_OUTPUT.PUT_LINE('<div class="who-dim" id="who-d-' || d_code(g) || '" data-dim="' || d_code(g) || '">'
                    || '<h3>' || d_head(g) || '<span class="who-nv">' || v_nk(g)
                    || CASE WHEN v_nk(g) = 1 THEN ' value' ELSE ' values' END
                    || CASE WHEN v_nk(g) > c_keep THEN ', the ' || c_keep || ' busiest kept' END || '</span></h3>');
                DBMS_OUTPUT.PUT_LINE('<table class="who-tbl" data-nocount>' || v_head || '<tbody>');
                FOR a IN 1 .. v_shown LOOP DBMS_OUTPUT.PUT_LINE(row_html(v_ord(a))); END LOOP;
                DBMS_OUTPUT.PUT_LINE('</tbody><tfoot><tr class="who-all" data-cur="' || wt(v_tcur) || '"><td>All foreground</td>'
                    || '<td class="num" data-w="0"><b>' || fmt_num(v_tcur) || '</b></td><td class="num">' || fmt_num(v_tmu)
                    || '</td><td class="num">' || sgn(v_trise) || '</td><td class="num">' || delta_span(v_tcur, v_tmu, NULL, 'Y')
                    || '</td><td></td><td></td></tr></tfoot></table>');
                IF v_ord.COUNT > v_shown THEN
                    DBMS_OUTPUT.PUT_LINE('<details class="who-more"><summary>+ ' || (v_ord.COUNT - v_shown) || ' more</summary>'
                        || '<table class="who-tbl" data-nocount>' || v_head || '<tbody>');
                    FOR a IN v_shown + 1 .. v_ord.COUNT LOOP DBMS_OUTPUT.PUT_LINE(row_html(v_ord(a))); END LOOP;
                    DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
                END IF;
                DBMS_OUTPUT.PUT_LINE('</div>');
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p class="note who-meth">One ASH sample = 10 s of a foreground session&#39;s time; AAS per window = '
        || 'samples &times; 10 s &divide; the window&#39;s length. Counted: FOREGROUND sessions on CPU or in a non-idle wait, in the '
        || 'valid compared windows (a sample in two overlapping windows counts for both), so the total compares with DB time. '
        || 'Per dimension the ' || c_keep || ' values with the most samples are kept and the rest summed as &ldquo;others&rdquo;; '
        || 'the table lists the values whose time rose, the ' || c_show || ' largest rises first, the rest under &ldquo;+ n more&rdquo;. '
        || 'A parallel or job slave&#39;s number is folded: (P003) &rarr; (Pnnn). Rise = Current minus the mean of the valid prior '
        || 'windows. Evidence, not a finding: nothing here is scored or counted.'
        || CASE WHEN v_nosvc IS NOT NULL THEN ' Service names need SELECT on <code>DBA_HIST_SERVICE_NAME</code>; shown as hashes.' END
        || CASE WHEN v_nopdb IS NOT NULL THEN ' PDB names need SELECT on <code>DBA_HIST_PDB_INSTANCE</code>; shown as con_id.' END
        || '</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');

    -- the DB time card's evidence row: one module (else service, machine,
    -- user) value carrying at least 30% of the rise (hidden here; moved)
    IF v_attr THEN
        v_best := NULL;
        FOR p IN 1 .. 4 LOOP
            v_t := CASE p WHEN 1 THEN 2 WHEN 2 THEN 1 WHEN 3 THEN 3 ELSE 5 END;
            v_pick := NULL;
            FOR i IN 1 .. x_n LOOP
                IF x_dim(i) = v_t AND x_ph(i) = 'N' AND x_rise(i) > 0
                   AND (v_pick IS NULL OR x_ri(i) > x_ri(v_pick)
                        OR (x_ri(i) = x_ri(v_pick) AND x_rk(i) < x_rk(v_pick))) THEN
                    v_pick := i;
                END IF;
            END LOOP;
            IF v_pick IS NOT NULL AND x_rise(v_pick) >= c_card * v_trise THEN
                v_best := v_pick;
                EXIT;
            END IF;
        END LOOP;
        IF v_best IS NOT NULL THEN
            v_i := v_best;
            DBMS_OUTPUT.PUT_LINE('<div id="who-ev-src" hidden><div class="evr ev-who" data-who="' || x_id(v_i)
                || '" data-cur="' || wt(x_cur(v_i)) || '" data-mu="' || wt(x_mu(v_i)) || '" data-rise="' || wt(x_rise(v_i))
                || '" data-trise="' || wt(v_trise)
                || '" title="Who added the load (foreground ASH): the ' || d_word(x_dim(v_i))
                || ' whose active sessions rose most. Its share is of the rise in all foreground activity. Not scored.">'
                || '<dt>Who</dt><dd><span class="id txt">' || d_word(x_dim(v_i)) || ' '
                || ent(DBMS_XMLGEN.CONVERT(x_nam(v_i)), x_id(v_i), 'who')
                || '</span><span class="de">'
                || nbu(sgn(x_rise(v_i)) || ' AAS (' || pct_txt(x_rise(v_i) / v_trise * 100)
                       || ' of the rise in foreground activity)')
                || '</span></dd><div class="m">' || delta_span(x_cur(v_i), x_mu(v_i), NULL, 'Y')
                || band_span(band_z(x_cur(v_i), x_mu(v_i), x_sd(v_i)), NULL, 'sm', 'N', 10)
                || '<span class="ns">not scored</span></div></div></div>');
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,x=d.getElementById("who-ev-src");if(!x)return;'
                || 'var c=d.getElementById("f-dbtime"),dl=c?c.querySelector("dl.ev"):null;'
                || 'if(dl){while(x.firstChild)dl.appendChild(x.firstChild);}x.parentNode.removeChild(x);})();</script>');
        END IF;
    END IF;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 29_who END -->'); END;
/
