--
-- 23_plan_flame.sql -- Plan shape, old vs new
--
-- The question: a statement changed plan and got slower -- WHERE inside
-- the new plan does the time go, compared with the old one?
--
-- Which statements (at most 3, biggest Current elapsed first): the
-- statements in the Current window's top N by elapsed time
-- (DBA_HIST_SQLSTAT elapsed_time_delta summed over the window's valid
-- snapshot pairs, ROW_NUMBER by elapsed DESC, sql_id -- section 06's
-- ranking) whose Current plan differs from their prior plan:
--   window plan  = the plan_hash_value of the window's LAST SQLSTAT row
--                  with a non-zero plan (06 takes the last row, zero
--                  included; 18 takes SQL Monitor's slowest execution)
--   Current plan = the window plan of the Current window
--   prior plan   = the most frequent window plan over the PRIOR VALID
--                  windows (tie: the most recent window)
-- None changed: the top statement by Current elapsed that has a non-zero
-- Current plan, drawn alone ("no plan change among the top N").
--
-- Where the time goes: DBA_HIST_ACTIVE_SESS_HISTORY for those sql_ids
-- only, joined to the valid windows by snapshot range (dbid, instance,
-- begin_snap_id + 1 .. end_snap_id, the SQLSTAT convention), Idle waits
-- dropped, grouped by window, plan hash, plan line and activity (ON CPU =
-- 'CPU', else the wait class).  New plan = Current plan samples inside the
-- Current window; old plan = prior plan samples inside the prior valid
-- windows, divided by the number of prior valid windows in which that
-- plan has samples (a typical prior window that ran it).  One DBA_HIST
-- ASH sample is about 10 s of DB time, so both sides read in seconds of
-- DB time per window.  A sample without a plan line (or with a line the
-- captured plan lacks) is put on the root step and counted in a note.
--
-- The plan tree comes from DBA_HIST_SQL_PLAN, which is NOT in the
-- README's grant list: it is read through dynamic SQL with binds, and a
-- missing grant (ORA-00942 / ORA-01031) becomes a note (the samples are
-- then listed by plan line only).  Several (dbid, con_dbid) copies of a
-- plan: the copy with the latest id-0 TIMESTAMP wins (then the lowest
-- dbid, con_dbid).  A plan of more than 60 lines keeps only the steps
-- with samples (and their ancestors, which then have samples below
-- them); the steps without samples under a step are folded into one
-- "+ n steps without samples" row.
--
-- Emits: section#plan-flame (lib row 13), one div.pf-st#pf-<sql_id> per
-- statement (headers, empty plots that js_planflame fills, the "Reads as"
-- sentence, the plan tables = every number with JS off), and
-- window.AWR_DATA.planflame (see js_planflame.js for the shape).
-- Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 23_plan_flame BEGIN -->'); END;
/

DECLARE
    c_max_st    CONSTANT PLS_INTEGER := 3;
    c_min_smp   CONSTANT PLS_INTEGER := 5;
    c_small     CONSTANT PLS_INTEGER := 60;
    c_spw       CONSTANT NUMBER      := 10;    -- seconds of DB time per DBA_HIST ASH sample
    c_kmul      CONSTANT PLS_INTEGER := 1000000;
    v_top_n     NUMBER := ~top_n;

    TYPE st_rec IS RECORD (
        sql_id   VARCHAR2(13),
        cur_phv  NUMBER,
        old_phv  NUMBER,
        cur_ela  NUMBER,
        rnk      NUMBER,
        txt      VARCHAR2(400)
    );
    TYPE st_tab  IS TABLE OF st_rec INDEX BY PLS_INTEGER;
    TYPE num_map IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE str_map IS TABLE OF VARCHAR2(400) INDEX BY PLS_INTEGER;
    TYPE num_vmap IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    TYPE cls_list IS TABLE OF VARCHAR2(30);

    v_st        st_tab;
    v_nst       PLS_INTEGER := 0;
    v_mode      VARCHAR2(3);                    -- 'chg' | 'top' | NULL
    v_cur_valid VARCHAR2(1) := 'N';
    v_cur_skip  VARCHAR2(200);
    v_n_prior   PLS_INTEGER := 0;

    -- per plan slot p (statement i: new = 2i - 1, old = 2i)
    p_phv    num_map;   -- plan hash
    p_role   str_map;   -- 'new' | 'old' | 'cur'
    p_div    num_map;   -- windows the samples are divided by
    p_tot    num_map;   -- samples
    p_nol    num_map;   -- samples without a usable plan line
    p_state  str_map;   -- 'Y' tree read | 'A' plan absent | 'G' no grant | 'X' not read
    p_lines  num_map;   -- plan lines
    p_maxid  num_map;
    p_marks  num_map;   -- "+ n steps without samples" rows
    v_wo_seen num_vmap; -- slot:week_offset -> 1 (old-plan windows with samples)

    -- per plan step, key = p * c_kmul + id
    s_par    num_map;
    s_dep    num_map;
    s_op     str_map;
    s_opt    str_map;
    s_own    str_map;
    s_obj    str_map;
    s_self   num_map;
    s_incl   num_map;
    s_sz     num_map;
    s_fc     num_map;   -- first child id
    s_ns     num_map;   -- next sibling id
    s_lc     num_map;   -- last child id (build only)
    s_zero   num_map;   -- steps without samples folded under this step (big plans)
    v_ash_line num_map; -- key -> samples on that plan line (before attribution)
    v_cls    num_vmap;  -- 'p:id:class' -> samples on the step itself
    v_ptot   num_vmap;  -- 'p:class' -> samples of the plan
    v_classes cls_list := cls_list('CPU', 'User I/O', 'System I/O', 'Commit', 'Application',
                                   'Concurrency', 'Network', 'Configuration', 'Scheduler',
                                   'Cluster', 'Administrative', 'Queueing', 'Other');

    v_cur    SYS_REFCURSOR;
    v_sql    VARCHAR2(4000);
    v_id     NUMBER;
    v_pid    NUMBER;
    v_dep    NUMBER;
    v_op     VARCHAR2(30);
    v_opt    VARCHAR2(30);
    v_own    VARCHAR2(128);
    v_obj    VARCHAR2(128);
    v_key    PLS_INTEGER;
    v_p      PLS_INTEGER;
    v_k      PLS_INTEGER;
    v_c      VARCHAR2(30);
    v_ln     NUMBER;
    v_n      NUMBER;
    v_s      VARCHAR2(32767);
    v_t      VARCHAR2(32767);
    v_rd     VARCHAR2(32767);
    v_ls     VARCHAR2(4000);
    v_note   VARCHAR2(4000);
    v_grant  BOOLEAN := FALSE;
    v_json   CLOB;
    v_any_draw BOOLEAN := FALSE;
    v_sids   VARCHAR2(13);
    v_s1     VARCHAR2(13);
    v_s2     VARCHAR2(13);
    v_s3     VARCHAR2(13);
    v_phv_txt VARCHAR2(40);

    @@sql/lib/json_escape.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/put_clob_chunked.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql

    FUNCTION kk(p PLS_INTEGER, id NUMBER) RETURN PLS_INTEGER IS
    BEGIN
        RETURN p * c_kmul + id;
    END kk;

    -- JSON string body: json_escape plus no comma (put_clob_chunked cuts
    -- its chunks at a comma, which must never sit inside a string)
    FUNCTION js(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(json_escape(p), ',', '\u002c');
    END js;

    PROCEDURE jw(p VARCHAR2) IS
    BEGIN
        IF p IS NOT NULL THEN
            DBMS_LOB.WRITEAPPEND(v_json, LENGTH(p), p);
        END IF;
    END jw;

    FUNCTION norm_cls(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        FOR i IN 1 .. v_classes.COUNT LOOP
            IF v_classes(i) = p THEN
                RETURN p;
            END IF;
        END LOOP;
        RETURN 'Other';
    END norm_cls;

    FUNCTION secs(p PLS_INTEGER, n NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN n * c_spw / GREATEST(NVL(p_div(p), 1), 1);
    END secs;

    -- seconds in prose: 360, 31.8, 0.6
    FUNCTION fs(n NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF n >= 100 THEN
            RETURN TO_CHAR(ROUND(n), 'FM999999999990');
        END IF;
        RETURN TO_CHAR(ROUND(n, 1), 'FM9999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END fs;

    FUNCTION step_txt(k PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(s_op(k) || ' ' || s_opt(k) || ' ' || s_obj(k));
    END step_txt;

    FUNCTION pct(n NUMBER, d NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF d IS NULL OR d = 0 THEN
            RETURN '0%';
        END IF;
        RETURN TO_CHAR(ROUND(100 * n / d)) || '%';
    END pct;

    -- the samples ON a step by class, biggest first: 'User I/O 80% &middot; CPU 20%'
    FUNCTION cls_txt(p PLS_INTEGER, id NUMBER, p_tot NUMBER) RETURN VARCHAR2 IS
        r   VARCHAR2(4000);
        TYPE ord_t IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        used ord_t;
        best PLS_INTEGER;
        bv   NUMBER;
        v    NUMBER;
    BEGIN
        IF p_tot IS NULL OR p_tot = 0 THEN
            RETURN '';
        END IF;
        FOR j IN 1 .. v_classes.COUNT LOOP
            best := NULL; bv := 0;
            FOR i IN 1 .. v_classes.COUNT LOOP
                IF NOT used.EXISTS(i) THEN
                    v := CASE WHEN v_cls.EXISTS(p || ':' || id || ':' || v_classes(i))
                              THEN v_cls(p || ':' || id || ':' || v_classes(i)) ELSE 0 END;
                    IF v > bv THEN
                        bv := v; best := i;
                    END IF;
                END IF;
            END LOOP;
            EXIT WHEN best IS NULL;
            used(best) := 1;
            r := r || CASE WHEN r IS NOT NULL THEN ' &middot; ' END
                   || v_classes(best) || ' ' || pct(bv, p_tot);
        END LOOP;
        RETURN r;
    END cls_txt;

    -- the class with the most samples on a step (NULL when none)
    FUNCTION dom_cls(p PLS_INTEGER, id NUMBER) RETURN VARCHAR2 IS
        best VARCHAR2(30);
        bv   NUMBER := 0;
        v    NUMBER;
    BEGIN
        FOR i IN 1 .. v_classes.COUNT LOOP
            v := CASE WHEN v_cls.EXISTS(p || ':' || id || ':' || v_classes(i))
                      THEN v_cls(p || ':' || id || ':' || v_classes(i)) ELSE 0 END;
            IF v > bv THEN
                bv := v; best := v_classes(i);
            END IF;
        END LOOP;
        RETURN best;
    END dom_cls;

    FUNCTION dom_cnt(p PLS_INTEGER, id NUMBER) RETURN NUMBER IS
        c VARCHAR2(30) := dom_cls(p, id);
    BEGIN
        IF c IS NULL THEN
            RETURN 0;
        END IF;
        RETURN v_cls(p || ':' || id || ':' || c);
    END dom_cnt;

    -- the step with the most samples on itself (ties: the lower line)
    FUNCTION hot_step(p PLS_INTEGER) RETURN NUMBER IS
        best NUMBER;
        bv   NUMBER := 0;
    BEGIN
        FOR id IN 0 .. NVL(p_maxid(p), -1) LOOP
            v_key := kk(p, id);
            IF s_dep.EXISTS(v_key) AND s_self(v_key) - CASE WHEN id = 0 THEN p_nol(p) ELSE 0 END > bv THEN
                bv := s_self(v_key) - CASE WHEN id = 0 THEN p_nol(p) ELSE 0 END; best := id;
            END IF;
        END LOOP;
        RETURN best;
    END hot_step;

    -- the deepest step that holds at least half of the plan's samples
    FUNCTION half_step(p PLS_INTEGER) RETURN NUMBER IS
        cur  NUMBER := 0;
        c    NUMBER;
        best NUMBER;
        bv   NUMBER;
    BEGIN
        LOOP
            best := NULL; bv := 0;
            IF s_fc.EXISTS(kk(p, cur)) THEN
                c := s_fc(kk(p, cur));
                WHILE c IS NOT NULL LOOP
                    IF s_incl(kk(p, c)) > bv THEN
                        bv := s_incl(kk(p, c)); best := c;
                    END IF;
                    c := CASE WHEN s_ns.EXISTS(kk(p, c)) THEN s_ns(kk(p, c)) END;
                END LOOP;
            END IF;
            EXIT WHEN best IS NULL OR bv * 2 < p_tot(p);
            cur := best;
        END LOOP;
        RETURN cur;
    END half_step;

    -- where the old plan touches the object of the new plan's hot step
    FUNCTION old_route(po PLS_INTEGER, pn PLS_INTEGER, hn NUMBER) RETURN VARCHAR2 IS
        best NUMBER;
        bv   NUMBER := -1;
        c    NUMBER;
        kn   PLS_INTEGER := kk(pn, hn);
        kb   PLS_INTEGER;
    BEGIN
        IF s_obj(kn) IS NULL OR p_state(po) <> 'Y' THEN
            RETURN NULL;
        END IF;
        FOR id IN 0 .. NVL(p_maxid(po), -1) LOOP
            v_key := kk(po, id);
            IF s_dep.EXISTS(v_key) AND s_obj(v_key) = s_obj(kn)
               AND NVL(s_own(v_key), '-') = NVL(s_own(kn), '-') AND s_incl(v_key) > bv THEN
                bv := s_incl(v_key); best := id;
            END IF;
        END LOOP;
        IF best IS NULL THEN
            RETURN '; the old plan has no step on ' || DBMS_XMLGEN.CONVERT(s_obj(kn));
        END IF;
        kb := kk(po, best);
        -- a table read by rowid: name the index that fed it
        IF s_op(kb) = 'TABLE ACCESS' AND s_opt(kb) LIKE 'BY%ROWID%' AND s_fc.EXISTS(kb) THEN
            c := s_fc(kb);
            WHILE c IS NOT NULL LOOP
                IF s_op(kk(po, c)) = 'INDEX' THEN
                    kb := kk(po, c); best := c;
                    EXIT;
                END IF;
                c := CASE WHEN s_ns.EXISTS(kk(po, c)) THEN s_ns(kk(po, c)) END;
            END LOOP;
        END IF;
        IF step_txt(kb) = step_txt(kn) THEN
            RETURN '; the old plan had the same step (line ' || best || ', '
                || fs(secs(po, s_incl(kb))) || ' s per window)';
        END IF;
        RETURN '; the old plan read ' || DBMS_XMLGEN.CONVERT(s_obj(kn)) || ' through '
            || DBMS_XMLGEN.CONVERT(CASE WHEN s_obj(kb) = s_obj(kn) THEN TRIM(s_op(kb) || ' ' || s_opt(kb))
                                        ELSE step_txt(kb) END) || ' (line ' || best || ', '
            || fs(secs(po, s_incl(kb))) || ' s per window)';
    END old_route;

    -- "83% of the new plan's time is User I/O on TABLE ACCESS FULL ORDERS (line 5)"
    FUNCTION where_txt(p PLS_INTEGER, p_noun VARCHAR2, p_short BOOLEAN) RETURN VARCHAR2 IS
        h  NUMBER := hot_step(p);
        hh NUMBER;
        c  VARCHAR2(30);
        n  NUMBER;
        cb VARCHAR2(30);
        cbv NUMBER := 0;
    BEGIN
        IF p_tot(p) = 0 THEN
            RETURN NULL;
        END IF;
        IF h IS NULL THEN
            -- every sample lacks a plan line: nothing to place on a step
            RETURN CASE WHEN p_short THEN 'no plan line in the samples'
                        ELSE 'none of ' || p_noun || ' samples carries a plan line, so its time cannot be placed on a step' END;
        END IF;
        c := dom_cls(p, h);
        n := dom_cnt(p, h);
        IF p_nol(p) * 2 >= p_tot(p) THEN
            -- most samples carry no plan line: say so first
            RETURN CASE WHEN p_short THEN 'mostly no plan line in the samples'
                        ELSE pct(p_nol(p), p_tot(p)) || ' of ' || p_noun || ' samples carry no plan line '
                             || '(drawn on the root step); the busiest step is '
                             || DBMS_XMLGEN.CONVERT(step_txt(kk(p, h))) || ' (line ' || h || ', '
                             || pct(s_self(kk(p, h)), p_tot(p)) || ')' END;
        END IF;
        IF n * 4 >= p_tot(p) THEN
            RETURN pct(n, p_tot(p)) || ' of ' || p_noun || ' time is ' || c || ' on '
                || DBMS_XMLGEN.CONVERT(step_txt(kk(p, h))) || ' (line ' || h || ')';
        END IF;
        FOR i IN 1 .. v_classes.COUNT LOOP
            IF v_ptot.EXISTS(p || ':' || v_classes(i)) AND v_ptot(p || ':' || v_classes(i)) > cbv THEN
                cbv := v_ptot(p || ':' || v_classes(i)); cb := v_classes(i);
            END IF;
        END LOOP;
        hh := half_step(p);
        IF p_short THEN
            RETURN p_noun || ' time is spread thin, ' || pct(cbv, p_tot(p)) || ' ' || cb;
        END IF;
        RETURN p_noun || ' time is spread thin (the busiest step, '
            || DBMS_XMLGEN.CONVERT(step_txt(kk(p, h))) || ' on line ' || h || ', holds '
            || pct(s_self(kk(p, h)), p_tot(p)) || ')'
            || CASE WHEN hh > 0 THEN '; ' || pct(s_incl(kk(p, hh)), p_tot(p)) || ' of it sits under '
                    || DBMS_XMLGEN.CONVERT(step_txt(kk(p, hh))) || ' (line ' || hh || ')' END
            || '; ' || pct(cbv, p_tot(p)) || ' of it is ' || cb;
    END where_txt;

BEGIN
    DBMS_LOB.CREATETEMPORARY(v_json, TRUE);

    -- 1. the windows -------------------------------------------------------
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag, skip_reason FROM windows_rollup
    ) LOOP
        IF r.week_offset = 0 THEN
            v_cur_valid := r.valid_flag;
            v_cur_skip  := r.skip_reason;
        ELSIF r.valid_flag = 'Y' THEN
            v_n_prior := v_n_prior + 1;
        END IF;
    END LOOP;

    -- 2. the statements ----------------------------------------------------
    IF v_cur_valid = 'Y' THEN
        FOR r IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            st AS (
                SELECT w.week_offset, s.sql_id, s.snap_id, s.plan_hash_value,
                       NVL(s.elapsed_time_delta, 0) AS ela
                FROM   valid_windows w
                JOIN   dba_hist_sqlstat s
                  ON   s.dbid = w.dbid
                 AND   s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                 AND   s.instance_number = w.instance_number
            ),
            cur AS (
                SELECT sql_id, SUM(ela) AS ela,
                       ROW_NUMBER() OVER (ORDER BY SUM(ela) DESC, sql_id) AS rnk
                FROM   st
                WHERE  week_offset = 0
                GROUP BY sql_id
            ),
            topn AS (
                SELECT sql_id, ela, rnk FROM cur
                WHERE  rnk <= (SELECT top_n FROM run_params) AND ela > 0
            ),
            wplan AS (
                SELECT week_offset, sql_id,
                       MAX(plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY snap_id) AS phv
                FROM   st
                WHERE  plan_hash_value > 0
                  AND  sql_id IN (SELECT sql_id FROM topn)
                GROUP BY week_offset, sql_id
            ),
            oldp AS (
                SELECT sql_id, phv FROM (
                    SELECT sql_id, phv,
                           ROW_NUMBER() OVER (PARTITION BY sql_id
                                              ORDER BY COUNT(*) DESC, MIN(week_offset)) AS rn
                    FROM   wplan
                    WHERE  week_offset > 0
                    GROUP BY sql_id, phv)
                WHERE rn = 1
            )
            SELECT t.sql_id, t.ela, t.rnk, c.phv AS cur_phv, o.phv AS old_phv,
                   CASE WHEN o.phv IS NOT NULL AND c.phv IS NOT NULL AND o.phv <> c.phv
                        THEN 'Y' ELSE 'N' END AS chg
            FROM   topn t
            LEFT JOIN wplan c ON c.sql_id = t.sql_id AND c.week_offset = 0
            LEFT JOIN oldp  o ON o.sql_id = t.sql_id
            ORDER BY t.ela DESC, t.sql_id
        ) LOOP
            IF r.chg = 'Y' AND v_nst < c_max_st THEN
                IF v_mode IS NULL OR v_mode = 'top' THEN
                    -- the first changed statement replaces a top-only pick
                    v_nst := 0;
                    v_mode := 'chg';
                END IF;
                v_nst := v_nst + 1;
                v_st(v_nst).sql_id  := r.sql_id;
                v_st(v_nst).cur_phv := r.cur_phv;
                v_st(v_nst).old_phv := r.old_phv;
                v_st(v_nst).cur_ela := r.ela / 1e6;
                v_st(v_nst).rnk     := r.rnk;
            ELSIF NVL(v_mode, 'top') = 'top' AND r.cur_phv IS NOT NULL AND v_nst < c_max_st THEN
                -- no change (yet): keep up to 3 candidates for the top-only view
                v_mode := 'top';
                v_nst := v_nst + 1;
                v_st(v_nst).sql_id  := r.sql_id;
                v_st(v_nst).cur_phv := r.cur_phv;
                v_st(v_nst).old_phv := NULL;
                v_st(v_nst).cur_ela := r.ela / 1e6;
                v_st(v_nst).rnk     := r.rnk;
            END IF;
        END LOOP;
    END IF;

    -- top-only: the highest-ranked candidate with enough Current samples
    IF v_mode = 'top' AND v_nst > 1 THEN
        v_k := 1;
        FOR i IN 1 .. v_nst LOOP
            SELECT COUNT(*) INTO v_n FROM (
                WITH
                @@sql/lib/windows_cte.sql
                SELECT 1 AS x
                FROM   valid_windows w
                JOIN   dba_hist_active_sess_history h
                  ON   h.dbid = w.dbid
                 AND   h.instance_number = w.instance_number
                 AND   h.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                WHERE  w.week_offset = 0
                  AND  h.sql_id = v_st(i).sql_id
                  AND  h.sql_plan_hash_value = v_st(i).cur_phv
                  AND  (h.session_state = 'ON CPU' OR NVL(h.wait_class, 'x') <> 'Idle'));
            IF v_n >= c_min_smp THEN
                v_k := i;
                EXIT;
            END IF;
        END LOOP;
        v_st(1) := v_st(v_k);
        v_nst := 1;
    END IF;

    -- slots
    FOR i IN 1 .. v_nst LOOP
        v_p := 2 * i - 1;
        p_phv(v_p) := v_st(i).cur_phv; p_role(v_p) := CASE WHEN v_mode = 'chg' THEN 'new' ELSE 'cur' END;
        p_div(v_p) := 1;
        IF v_mode = 'chg' THEN
            p_phv(v_p + 1) := v_st(i).old_phv; p_role(v_p + 1) := 'old'; p_div(v_p + 1) := 0;
        END IF;
        BEGIN
            SELECT MAX(REGEXP_REPLACE(DBMS_LOB.SUBSTR(t.sql_text, 160, 1), '\s+', ' '))
            INTO   v_st(i).txt
            FROM   dba_hist_sqltext t
            WHERE  t.sql_id = v_st(i).sql_id
              AND  t.dbid IN (~dbid_list);
        EXCEPTION WHEN NO_DATA_FOUND THEN v_st(i).txt := NULL;
        END;
    END LOOP;
    FOR p IN 1 .. 2 * v_nst LOOP
        IF p_phv.EXISTS(p) THEN
            p_tot(p) := 0; p_nol(p) := 0; p_state(p) := 'X'; p_lines(p) := 0;
            p_maxid(p) := -1; p_marks(p) := 0;
        END IF;
    END LOOP;

    -- 3. the samples (one bounded ASH scan) --------------------------------
    IF v_nst > 0 THEN
        v_s1 := v_st(1).sql_id;
        v_s2 := CASE WHEN v_nst >= 2 THEN v_st(2).sql_id ELSE v_s1 END;
        v_s3 := CASE WHEN v_nst >= 3 THEN v_st(3).sql_id ELSE v_s1 END;
        FOR a IN (
            WITH
            @@sql/lib/windows_cte.sql
            SELECT w.week_offset AS wo, h.sql_id, h.sql_plan_hash_value AS phv,
                   h.sql_plan_line_id AS ln,
                   CASE WHEN h.session_state = 'ON CPU' THEN 'CPU'
                        ELSE NVL(h.wait_class, 'Other') END AS cls,
                   COUNT(*) AS n
            FROM   valid_windows w
            JOIN   dba_hist_active_sess_history h
              ON   h.dbid = w.dbid
             AND   h.instance_number = w.instance_number
             AND   h.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
            WHERE  h.sql_id IN (v_s1, v_s2, v_s3)
              AND  h.sql_plan_hash_value > 0
              AND  (h.session_state = 'ON CPU' OR NVL(h.wait_class, 'x') <> 'Idle')
            GROUP BY w.week_offset, h.sql_id, h.sql_plan_hash_value, h.sql_plan_line_id,
                     CASE WHEN h.session_state = 'ON CPU' THEN 'CPU'
                          ELSE NVL(h.wait_class, 'Other') END
        ) LOOP
            FOR i IN 1 .. v_nst LOOP
                IF v_st(i).sql_id = a.sql_id THEN
                    v_p := NULL;
                    IF a.wo = 0 AND a.phv = v_st(i).cur_phv THEN
                        v_p := 2 * i - 1;
                    ELSIF a.wo > 0 AND v_mode = 'chg' AND a.phv = v_st(i).old_phv THEN
                        v_p := 2 * i;
                        IF NOT v_wo_seen.EXISTS(v_p || ':' || a.wo) THEN
                            v_wo_seen(v_p || ':' || a.wo) := 1;
                            p_div(v_p) := p_div(v_p) + 1;
                        END IF;
                    END IF;
                    IF v_p IS NOT NULL THEN
                        -- a sample without a plan line: line c_kmul - 1
                        v_ln := CASE WHEN a.ln IS NULL OR a.ln < 0 THEN c_kmul - 1 ELSE LEAST(a.ln, c_kmul - 2) END;
                        v_key := kk(v_p, v_ln);
                        v_ash_line(v_key) := CASE WHEN v_ash_line.EXISTS(v_key) THEN v_ash_line(v_key) ELSE 0 END + a.n;
                        v_c := norm_cls(a.cls);
                        v_cls(v_p || ':' || v_ln || ':' || v_c) :=
                            CASE WHEN v_cls.EXISTS(v_p || ':' || v_ln || ':' || v_c)
                                 THEN v_cls(v_p || ':' || v_ln || ':' || v_c) ELSE 0 END + a.n;
                        v_ptot(v_p || ':' || v_c) :=
                            CASE WHEN v_ptot.EXISTS(v_p || ':' || v_c) THEN v_ptot(v_p || ':' || v_c) ELSE 0 END + a.n;
                        p_tot(v_p) := p_tot(v_p) + a.n;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;
    END IF;

    -- 4. the plans (dynamic SQL: DBA_HIST_SQL_PLAN may not be granted) -------
    v_sql := 'SELECT id, parent_id, depth, operation, options, object_owner, object_name FROM ('
          || 'SELECT q.id, q.parent_id, q.depth, q.operation, q.options, q.object_owner, q.object_name, '
          || 'DENSE_RANK() OVER (ORDER BY q.ts0 DESC NULLS LAST, q.dbid, q.con_dbid) AS rk FROM ('
          || 'SELECT x.dbid, x.con_dbid, x.id, x.parent_id, x.depth, x.operation, x.options, '
          || 'x.object_owner, x.object_name, '
          || 'MAX(CASE WHEN x.id = 0 THEN x.timestamp END) OVER (PARTITION BY x.dbid, x.con_dbid) AS ts0 '
          || 'FROM dba_hist_sql_plan x WHERE x.sql_id = :1 AND x.plan_hash_value = :2 '
          || 'AND x.dbid IN (~dbid_list)) q) WHERE rk = 1 ORDER BY id';
    FOR p IN 1 .. 2 * v_nst LOOP
        CONTINUE WHEN NOT p_phv.EXISTS(p);
        v_sids := v_st(TRUNC((p + 1) / 2)).sql_id;
        IF v_grant THEN
            p_state(p) := 'G';
            CONTINUE;
        END IF;
        BEGIN
            OPEN v_cur FOR v_sql USING v_sids, p_phv(p);
            LOOP
                FETCH v_cur INTO v_id, v_pid, v_dep, v_op, v_opt, v_own, v_obj;
                EXIT WHEN v_cur%NOTFOUND;
                EXIT WHEN v_id >= c_kmul - 2;
                v_key := kk(p, v_id);
                s_par(v_key) := v_pid;
                s_dep(v_key) := NVL(v_dep, 0);
                s_op(v_key)  := v_op;
                s_opt(v_key) := v_opt;
                s_own(v_key) := v_own;
                s_obj(v_key) := v_obj;
                s_self(v_key) := 0;
                s_sz(v_key) := 1;
                s_zero(v_key) := 0;
                p_lines(p) := p_lines(p) + 1;
                p_maxid(p) := GREATEST(p_maxid(p), v_id);
            END LOOP;
            CLOSE v_cur;
            p_state(p) := CASE WHEN p_lines(p) > 0 AND s_dep.EXISTS(kk(p, 0)) THEN 'Y' ELSE 'A' END;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                IF SQLCODE IN (-942, -1031) THEN
                    v_grant := TRUE;
                    p_state(p) := 'G';
                ELSE
                    RAISE;
                END IF;
        END;
    END LOOP;

    -- 5. attribute the samples, build the tree ------------------------------
    FOR p IN 1 .. 2 * v_nst LOOP
        CONTINUE WHEN NOT p_phv.EXISTS(p) OR p_state(p) <> 'Y';
        -- samples on lines the plan lacks (or no line) go to the root
        v_key := v_ash_line.FIRST;
        WHILE v_key IS NOT NULL LOOP
            IF TRUNC(v_key / c_kmul) = p THEN
                v_ln := v_key - p * c_kmul;
                IF v_ln < c_kmul - 1 AND s_dep.EXISTS(v_key) THEN
                    s_self(v_key) := v_ash_line(v_key);
                ELSE
                    s_self(kk(p, 0)) := s_self(kk(p, 0)) + v_ash_line(v_key);
                    p_nol(p) := p_nol(p) + v_ash_line(v_key);
                    FOR i IN 1 .. v_classes.COUNT LOOP
                        IF v_cls.EXISTS(p || ':' || v_ln || ':' || v_classes(i)) THEN
                            v_cls(p || ':0:' || v_classes(i)) :=
                                CASE WHEN v_cls.EXISTS(p || ':0:' || v_classes(i))
                                     THEN v_cls(p || ':0:' || v_classes(i)) ELSE 0 END
                                + v_cls(p || ':' || v_ln || ':' || v_classes(i));
                        END IF;
                    END LOOP;
                END IF;
            END IF;
            v_key := v_ash_line.NEXT(v_key);
        END LOOP;
        -- children lists in id order (= Oracle's preorder)
        FOR id IN 1 .. p_maxid(p) LOOP
            v_key := kk(p, id);
            IF s_dep.EXISTS(v_key) AND s_par(v_key) IS NOT NULL AND s_dep.EXISTS(kk(p, s_par(v_key))) THEN
                v_k := kk(p, s_par(v_key));
                IF NOT s_fc.EXISTS(v_k) THEN
                    s_fc(v_k) := id;
                ELSE
                    s_ns(kk(p, s_lc(v_k))) := id;
                END IF;
                s_lc(v_k) := id;
            END IF;
        END LOOP;
        -- inclusive samples and subtree sizes, bottom up
        FOR id IN 0 .. p_maxid(p) LOOP
            v_key := kk(p, id);
            IF s_dep.EXISTS(v_key) THEN
                s_incl(v_key) := s_self(v_key);
            END IF;
        END LOOP;
        FOR id IN REVERSE 1 .. p_maxid(p) LOOP
            v_key := kk(p, id);
            IF s_dep.EXISTS(v_key) AND s_par(v_key) IS NOT NULL AND s_dep.EXISTS(kk(p, s_par(v_key))) THEN
                v_k := kk(p, s_par(v_key));
                s_incl(v_k) := s_incl(v_k) + s_incl(v_key);
                s_sz(v_k) := s_sz(v_k) + s_sz(v_key);
            END IF;
        END LOOP;
        -- big plans: fold the zero-sample subtrees under a sampled step
        IF p_lines(p) > c_small THEN
            FOR id IN 1 .. p_maxid(p) LOOP
                v_key := kk(p, id);
                IF s_dep.EXISTS(v_key) AND s_incl(v_key) = 0 AND s_par(v_key) IS NOT NULL
                   AND s_dep.EXISTS(kk(p, s_par(v_key))) AND s_incl(kk(p, s_par(v_key))) > 0 THEN
                    v_k := kk(p, s_par(v_key));
                    IF s_zero(v_k) = 0 THEN
                        p_marks(p) := p_marks(p) + 1;
                    END IF;
                    s_zero(v_k) := s_zero(v_k) + s_sz(v_key);
                END IF;
            END LOOP;
        END IF;
        IF p_tot(p) >= c_min_smp THEN
            v_any_draw := TRUE;
        END IF;
    END LOOP;

    -- 6. markup ------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<section id="plan-flame" class="vw in-s in-a lib'
        || CASE WHEN v_mode = 'chg' THEN ' lopen' END
        || '" style="--os:13"><h2>Plan shape, old vs new'
        || '<small class="h2sub">Where the time goes inside a changed plan, from ASH samples per plan line</small></h2>');

    IF v_nst = 0 THEN
        v_note := CASE WHEN v_cur_valid <> 'Y'
                       THEN 'The Current window was skipped (' || DBMS_XMLGEN.CONVERT(NVL(v_cur_skip, 'no valid snapshots'))
                            || '), so there is no Current top SQL to look at.'
                       ELSE 'No statement in the Current window''s top ' || v_top_n
                            || ' by elapsed time has a captured plan hash.' END;
        DBMS_OUTPUT.PUT_LINE('<p class="note">' || v_note || '</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('plan-flame', CASE WHEN v_cur_valid <> 'Y'
            THEN 'Current window skipped' ELSE 'no top statement with a plan' END));
        DBMS_OUTPUT.PUT_LINE('</section>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p class="pf-intro">'
            || CASE WHEN v_mode = 'chg'
                    THEN 'Statements in the Current window''s top ' || v_top_n
                         || ' by elapsed time whose plan differs from the plan they used most in the prior windows. '
                    ELSE '<b>No plan change among the top ' || v_top_n
                         || '</b>; this is where a top statement spends its time (the highest-ranked of the first three '
                         || 'with at least ' || c_min_smp || ' ASH samples, else the first). ' END
            || 'A step''s width is the DB time on that step and every step below it (ASH samples, about 10 s each, '
            || 'per window), so the widest path down is where the time goes; the colour is what the step itself was doing.</p>');
        DBMS_OUTPUT.PUT_LINE('<div class="pf-lg" aria-hidden="true"></div>');
        DBMS_OUTPUT.PUT_LINE('<p class="pf-nojs note">The drawing needs JavaScript; the plan tables below hold every number.</p>');
        IF v_grant THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note">Needs SELECT on DBA_HIST_SQL_PLAN to draw the plan tree; '
                || 'the samples are listed by plan line only.</p>');
        END IF;

        jw('{"spw":' || c_spw || ',"min":' || c_min_smp || ',"mode":"' || v_mode || '","st":[');
        FOR i IN 1 .. v_nst LOOP
            jw(CASE WHEN i > 1 THEN ',' END || '{"id":"' || anchor_id('pf', v_st(i).sql_id)
               || '","sql":"' || js(v_st(i).sql_id) || '","p":[');
            DBMS_OUTPUT.PUT_LINE('<div class="pf-st" id="' || anchor_id('pf', v_st(i).sql_id)
                || '" data-sql="' || DBMS_XMLGEN.CONVERT(v_st(i).sql_id) || '" data-k="' || (i - 1) || '">');
            DBMS_OUTPUT.PUT_LINE('<h3 class="pf-h">' || ent(DBMS_XMLGEN.CONVERT(v_st(i).sql_id),
                    anchor_id('sq-elapsed', v_st(i).sql_id), 'sql')
                || CASE WHEN v_mode = 'chg'
                        THEN ' <span class="pf-tag">plan ' || v_st(i).old_phv || ' &rarr; ' || v_st(i).cur_phv || '</span>'
                        ELSE ' <span class="pf-tag">plan ' || v_st(i).cur_phv || '</span>' END
                || ' <span class="pf-el">' || fmt_num(v_st(i).cur_ela) || ' s elapsed in the Current window, #'
                || v_st(i).rnk || ' by elapsed</span></h3>');
            IF v_st(i).txt IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('<p class="pf-sqlt" title="first 160 characters">'
                    || DBMS_XMLGEN.CONVERT(SUBSTR(v_st(i).txt, 1, 160)) || '</p>');
            END IF;
            DBMS_OUTPUT.PUT_LINE('<div class="pf-pair' || CASE WHEN v_mode = 'top' THEN ' one' END || '">');
            -- old first (left), then new
            FOR q IN 1 .. CASE WHEN v_mode = 'chg' THEN 2 ELSE 1 END LOOP
                v_p := CASE WHEN v_mode = 'chg' AND q = 1 THEN 2 * i ELSE 2 * i - 1 END;
                v_s := CASE p_role(v_p) WHEN 'old' THEN '<b>Before:</b> plan ' WHEN 'new' THEN '<b>Now:</b> plan '
                            ELSE '<b>Plan</b> ' END
                    || p_phv(v_p) || ', '
                    || fs(secs(v_p, p_tot(v_p)))
                    || ' s per window';
                v_t := CASE WHEN p_role(v_p) = 'old'
                            THEN CASE WHEN p_div(v_p) > 0
                                      THEN 'mean of the ' || CASE WHEN p_div(v_p) = 1 THEN 'one' ELSE TO_CHAR(p_div(v_p)) END
                                           || ' prior window' || CASE WHEN p_div(v_p) > 1 THEN 's' END || ' it ran in'
                                      ELSE 'no ASH samples in the ' || v_n_prior || ' prior windows' END
                            ELSE 'Current window' END
                    || ', ' || p_tot(v_p) || ' ASH sample' || CASE WHEN p_tot(v_p) <> 1 THEN 's' END;
                DBMS_OUTPUT.PUT_LINE('<div class="pf-side" data-r="' || p_role(v_p) || '">'
                    || '<div class="pf-hd">' || v_s || ' <small>' || v_t || '</small></div>');
                IF p_state(v_p) = 'Y' AND p_tot(v_p) >= c_min_smp THEN
                    DBMS_OUTPUT.PUT_LINE('<div class="pf-plot" data-q="' || (q - 1) || '"></div>');
                ELSE
                    DBMS_OUTPUT.PUT_LINE('<p class="pf-few">'
                        || CASE WHEN p_state(v_p) = 'G' THEN 'No plan tree (no SELECT on DBA_HIST_SQL_PLAN).'
                                WHEN p_state(v_p) = 'A' THEN 'Plan ' || p_phv(v_p) || ' is not in DBA_HIST_SQL_PLAN.'
                                WHEN p_tot(v_p) = 0 THEN 'No ASH samples of this plan.'
                                ELSE 'Too few ASH samples to draw (' || p_tot(v_p) || ').' END
                        || ' The table below lists the plan.</p>');
                END IF;
                IF p_nol(v_p) > 0 THEN
                    DBMS_OUTPUT.PUT_LINE('<p class="pf-nol">' || p_nol(v_p) || ' sample'
                        || CASE WHEN p_nol(v_p) <> 1 THEN 's' END
                        || CASE WHEN p_nol(v_p) <> 1 THEN ' without a plan line are' ELSE ' without a plan line is' END
                        || ' shown on the root step.</p>');
                END IF;
                IF p_marks(v_p) > 0 THEN
                    DBMS_OUTPUT.PUT_LINE('<p class="pf-nol">Plan of ' || p_lines(v_p)
                        || ' lines: only the steps with samples are drawn and listed.</p>');
                END IF;
                DBMS_OUTPUT.PUT_LINE('</div>');

                -- payload of this plan
                jw(CASE WHEN q > 1 THEN ',' END || '{"r":"' || p_role(v_p) || '","phv":' || p_phv(v_p)
                   || ',"div":' || GREATEST(p_div(v_p), 1) || ',"n":' || p_tot(v_p) || ',"nol":' || p_nol(v_p)
                   || ',"lines":' || p_lines(v_p) || ',"state":"' || p_state(v_p) || '","s":[');
                IF p_state(v_p) = 'Y' THEN
                    v_n := 0;
                    FOR id IN 0 .. p_maxid(v_p) LOOP
                        v_key := kk(v_p, id);
                        CONTINUE WHEN NOT s_dep.EXISTS(v_key);
                        CONTINUE WHEN p_lines(v_p) > c_small AND s_incl(v_key) = 0;
                        v_s := '';
                        FOR c IN 1 .. v_classes.COUNT LOOP
                            IF v_cls.EXISTS(v_p || ':' || id || ':' || v_classes(c)) AND s_self(v_key) > 0 THEN
                                v_s := v_s || CASE WHEN v_s IS NOT NULL THEN ',' END
                                    || '"' || v_classes(c) || '":' || v_cls(v_p || ':' || id || ':' || v_classes(c));
                            END IF;
                        END LOOP;
                        jw(CASE WHEN v_n > 0 THEN ',' END || '[' || id || ',' || NVL(TO_CHAR(s_par(v_key)), 'null')
                           || ',"' || js(s_op(v_key)) || '","' || js(s_opt(v_key)) || '","' || js(s_own(v_key))
                           || '","' || js(s_obj(v_key)) || '",' || s_self(v_key) || ',{' || v_s || '},'
                           || CASE WHEN s_incl(v_key) = 0 THEN s_sz(v_key) - 1 ELSE s_zero(v_key) END || ']');
                        v_n := v_n + 1;
                    END LOOP;
                END IF;
                jw(']}');
            END LOOP;
            jw(']}');
            DBMS_OUTPUT.PUT_LINE('</div>');

            -- the "Reads as" sentence
            v_p := 2 * i - 1;
            IF p_state(v_p) = 'Y' AND p_tot(v_p) > 0 THEN
                IF v_mode = 'chg' THEN
                    v_rd := where_txt(v_p, 'the new plan''s', FALSE);
                    IF dom_cnt(v_p, hot_step(v_p)) * 4 >= p_tot(v_p) THEN
                        v_rd := v_rd || NVL(old_route(2 * i, v_p, hot_step(v_p)), '');
                    END IF;
                    v_rd := v_rd || '. Per window: ' || fs(secs(v_p, p_tot(v_p))) || ' s now, '
                        || CASE WHEN p_tot(2 * i) > 0
                                THEN fs(secs(2 * i, p_tot(2 * i))) || ' s before ('
                                     || TO_CHAR(ROUND(secs(v_p, p_tot(v_p)) / secs(2 * i, p_tot(2 * i)), 1),
                                                'FM9999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || 'x).'
                                ELSE 'none sampled before.' END;
                ELSE
                    v_rd := where_txt(v_p, 'this plan''s', FALSE) || '.';
                END IF;
                v_rd := UPPER(SUBSTR(v_rd, 1, 1)) || SUBSTR(v_rd, 2);
            ELSIF p_tot(v_p) = 0 THEN
                v_rd := 'ASH holds no sample of plan ' || p_phv(v_p) || ' in the Current window.';
            ELSE
                v_rd := p_tot(v_p) || ' ASH sample' || CASE WHEN p_tot(v_p) <> 1 THEN 's' END
                    || ' of plan ' || p_phv(v_p) || ' in the Current window; see the table by plan line.';
            END IF;
            DBMS_OUTPUT.PUT_LINE('<p class="pf-rd"><b>Reads as:</b> ' || v_rd || '</p>');
            IF i = 1 THEN
                v_ls := DBMS_XMLGEN.CONVERT(v_st(1).sql_id) || ': '
                    || CASE WHEN v_mode = 'top' THEN 'no plan change in the top ' || v_top_n || '; ' END
                    || CASE WHEN p_state(v_p) = 'Y' AND p_tot(v_p) >= c_min_smp
                            THEN where_txt(v_p, CASE WHEN v_mode = 'chg' THEN 'new plan' ELSE 'its' END, TRUE)
                                 || CASE WHEN v_mode = 'chg' AND p_tot(2) > 0
                                         THEN ', ' || TO_CHAR(ROUND(secs(1, p_tot(1)) / secs(2, p_tot(2)), 1),
                                                     'FM9999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                                              || 'x the old plan per window' END
                            WHEN p_state(v_p) = 'G' THEN 'needs SELECT on DBA_HIST_SQL_PLAN to draw the plan'
                            WHEN p_state(v_p) = 'A' THEN 'plan not in DBA_HIST_SQL_PLAN'
                            ELSE 'too few ASH samples to draw' END
                    || CASE WHEN v_nst > 1 THEN ' (+' || (v_nst - 1) || ' more)' END;
            END IF;

            -- the plan tables (every number with JS off)
            DBMS_OUTPUT.PUT_LINE('<details class="pf-tbls"><summary>Plan table'
                || CASE WHEN v_mode = 'chg' THEN 's, old and new' END || '</summary>');
            FOR q IN 1 .. CASE WHEN v_mode = 'chg' THEN 2 ELSE 1 END LOOP
                v_p := CASE WHEN v_mode = 'chg' AND q = 1 THEN 2 * i ELSE 2 * i - 1 END;
                DBMS_OUTPUT.PUT_LINE('<table class="pf-tb" data-nosort="Y" data-nocount="Y" data-pl="' || (q - 1) || '">'
                    || '<caption>' || CASE p_role(v_p) WHEN 'old' THEN 'Before' WHEN 'new' THEN 'Now' ELSE 'Plan' END
                    || ': plan ' || p_phv(v_p) || ', seconds of DB time per window</caption>'
                    || '<thead><tr><th class="num">Line</th><th>Step</th><th>Object</th>'
                    || '<th class="num" title="samples on the step itself">On the step, s</th>'
                    || '<th class="num" title="the step and every step below it">With the steps below, s</th>'
                    || '<th class="num">Of the plan</th><th>What the step was doing</th></tr></thead><tbody>');
                IF p_state(v_p) = 'Y' AND p_lines(v_p) > c_small AND p_tot(v_p) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('<tr class="pf-z pf-mk"><td class="num"></td><td colspan="6">'
                        || 'A plan of ' || p_lines(v_p) || ' steps, none with samples</td></tr>');
                ELSIF p_state(v_p) = 'Y' THEN
                    FOR id IN 0 .. p_maxid(v_p) LOOP
                        v_key := kk(v_p, id);
                        CONTINUE WHEN NOT s_dep.EXISTS(v_key);
                        CONTINUE WHEN p_lines(v_p) > c_small AND s_incl(v_key) = 0;
                        DBMS_OUTPUT.PUT_LINE('<tr data-ln="' || id || '"'
                            || CASE WHEN s_incl(v_key) = 0 THEN ' class="pf-z"' END || '>'
                            || '<td class="num">' || id || '</td>'
                            || '<td><span class="pf-ind" style="--d:' || LEAST(s_dep(v_key), 24) || '"'
                            || CASE WHEN s_dep(v_key) > 24 THEN ' title="depth ' || s_dep(v_key) || '"' END || '>'
                            || DBMS_XMLGEN.CONVERT(TRIM(s_op(v_key) || ' ' || s_opt(v_key))) || '</span></td>'
                            || '<td' || CASE WHEN s_own(v_key) IS NOT NULL
                                             THEN ' title="' || DBMS_XMLGEN.CONVERT(s_own(v_key) || '.' || s_obj(v_key)) || '"' END
                            || '>' || DBMS_XMLGEN.CONVERT(s_obj(v_key)) || '</td>'
                            || '<td class="num">' || fmt_num(secs(v_p, s_self(v_key))) || '</td>'
                            || '<td class="num">' || fmt_num(secs(v_p, s_incl(v_key))) || '</td>'
                            || '<td class="num">' || pct(s_incl(v_key), p_tot(v_p)) || '</td>'
                            || '<td>' || cls_txt(v_p, id, s_self(v_key)) || '</td></tr>');
                        IF s_zero(v_key) > 0 THEN
                            DBMS_OUTPUT.PUT_LINE('<tr class="pf-z pf-mk"><td class="num"></td><td colspan="6">'
                                || '<span class="pf-ind" style="--d:' || LEAST(s_dep(v_key) + 1, 24) || '">+ '
                                || s_zero(v_key) || ' step' || CASE WHEN s_zero(v_key) <> 1 THEN 's' END
                                || ' without samples</span></td></tr>');
                        END IF;
                    END LOOP;
                ELSE
                    -- no tree: the samples by plan line
                    v_key := v_ash_line.FIRST;
                    v_n := 0;
                    WHILE v_key IS NOT NULL LOOP
                        IF TRUNC(v_key / c_kmul) = v_p THEN
                            v_ln := v_key - v_p * c_kmul;
                            DBMS_OUTPUT.PUT_LINE('<tr data-ln="' || v_ln || '"><td class="num">'
                                || CASE WHEN v_ln < c_kmul - 1 THEN TO_CHAR(v_ln) ELSE '&ndash;' END || '</td>'
                                || '<td>' || CASE WHEN v_ln = c_kmul - 1 THEN 'no plan line' ELSE 'line ' || v_ln END
                                || '</td><td></td>'
                                || '<td class="num">' || fmt_num(secs(v_p, v_ash_line(v_key))) || '</td>'
                                || '<td class="num"></td>'
                                || '<td class="num">' || pct(v_ash_line(v_key), p_tot(v_p)) || '</td>'
                                || '<td>' || cls_txt(v_p, v_ln, v_ash_line(v_key)) || '</td></tr>');
                            v_n := v_n + 1;
                        END IF;
                        v_key := v_ash_line.NEXT(v_key);
                    END LOOP;
                    IF v_n = 0 THEN
                        DBMS_OUTPUT.PUT_LINE('<tr><td class="num"></td><td colspan="6">No ASH samples.</td></tr>');
                    END IF;
                END IF;
                DBMS_OUTPUT.PUT_LINE('</tbody></table>');
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('</details></div>');
        END LOOP;
        jw(']}');

        DBMS_OUTPUT.PUT_LINE(lib_ls('plan-flame', v_ls));
        DBMS_OUTPUT.PUT_LINE('</section>');
        DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};window.AWR_DATA.planflame=');
        put_clob_chunked(v_json);
        DBMS_OUTPUT.PUT_LINE(';</script>');
    END IF;
    DBMS_LOB.FREETEMPORARY(v_json);
END;
/

@@sql/lib/js_planflame.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 23_plan_flame END -->'); END;
/
