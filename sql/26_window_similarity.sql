--
-- 26_window_similarity.sql
-- Window similarity (v1.7.0 visualization #7): is the baseline itself
-- sound?  Every verdict rests on the prior windows being a fair picture of
-- normal; this section asks whether they are, and what the findings would
-- be without a window that is not.
--
--   Part 1  the similarity matrix: windows x windows (oldest first, the
--           Current window last), cell = how far apart two windows are
--           over every metric, plus one bar per prior window, "distance
--           from the other prior windows", the odd ones out flagged.
--   Part 2  the what-if: drop prior windows (chips) and every metric is
--           re-scored in the browser against the remaining valid priors;
--           the finding count and the list of metrics whose bucket
--           changes update.  One click tries the windows Part 1 flags.
--
-- Data: the SAME per-window recompute as 07_summary.sql (the template's
-- LOAD rows through sql/lib/load_pairs_cte.sql, SYSMETRIC with the
-- additive-vs-ratio rule, the foreground wait-class rollup with its share
-- of the Current total), in the stored units, ONE bounded read per view
-- over the valid windows.  The PL/SQL bucket of every metric
-- (policy_bucket, the one rule) rides in the payload as "pb".
--
-- Distance (stated in 19's About note): for each canonical metric that
-- reaches its materiality floor in at least one window (twins left out so
-- a quantity is not counted twice; a metric that never clears min_abs
-- cannot change a finding), scale every window's value as
-- (value - median) / spread over the valid windows, spread = 1.4826 x MAD
-- (the robust sigma), floored at 2% of |median| like the policy's sigma
-- floor, else 1.2533 x the mean absolute deviation, else the metric is
-- constant and left out.  Two windows' distance = the mean over the
-- metrics both have of min(|scaled a - scaled b|, 5), i.e. "on average
-- this many robust spreads apart", capped so one metric alone cannot make
-- a window odd.  A prior window's distance from the other priors = the
-- median of its distances to them; it is odd when that is above
-- max(median + 3 x 1.4826 x MAD, 1.5 x median) of those distances.  A
-- mean absolute difference (not a correlation) because it reads in the
-- same unit as the band glyph (spreads) and a correlation is blind to a
-- window that is uniformly lower (a holiday).
--
-- The client re-scoring (sql/lib/src/js_winsim.js) is a TWIN of
-- policy_bucket() in sql/lib/metric_policy.plsql: same z over
-- max(sd, 2% of |mean|) with the SAMPLE sd, n < 3 insufficient history,
-- |z| > 3 large / > 2 moderate, materiality by min_pct / min_abs / share,
-- then the direction.  The two MUST stay in lockstep: with nothing
-- dropped the script compares its bucket with "pb" for every metric and
-- reports a mismatch on the console (window.AWR_WINSIM.check).  Card
-- counting follows card_group() (sql/lib/finding_cards.plsql), emitted
-- per metric as "g" so the client only counts.
--
-- Plan 038: also one "Baseline check" note in the verdict hero's notes
-- list (#narrative-slot) when a suggestion's drop changes a bucket, see the
-- markup block at the end.
--
-- Payload: window.AWR_DATA.winsim = {cap, thr, medd, cv, w:[{o, v, dd,
-- odd, top}], m:[{d, n, l, k, dir, p, a, sh, g, pb, vec, md, sp, lk, v}],
-- dm:[[...]], sug:{drop, chg, cb, ca}} -- w / v / dm oldest first like
-- AWR_WIN; dm row i holds the distances to windows 0 .. i-1 (null =
-- skipped).  Every per-window piece is built in a PL/SQL loop and put out
-- one line per metric / matrix row (169 windows stay far under 32767).
-- Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 26_window_similarity BEGIN -->'); END;
/

DECLARE
    TYPE row_rec IS RECORD (
        dom  VARCHAR2(16),
        nm   VARCHAR2(120),
        off  NUMBER,
        val  NUMBER,
        cur  NUMBER,
        mu   NUMBER,
        sd   NUMBER,
        n    NUMBER,
        tot  NUMBER,
        wtot NUMBER
    );
    TYPE rows_t IS TABLE OF row_rec INDEX BY PLS_INTEGER;
    TYPE num_t  IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE dbl_t  IS TABLE OF BINARY_DOUBLE INDEX BY PLS_INTEGER;
    TYPE str_t  IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    TYPE cnt_t  IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);
    TYPE met_rec IS RECORD (
        dom   VARCHAR2(16),
        nm    VARCHAR2(120),
        cur   NUMBER,
        mu    NUMBER,
        sd    NUMBER,
        n     NUMBER,
        shr   NUMBER,
        pb    VARCHAR2(40),
        fam   VARCHAR2(64),
        canon VARCHAR2(1),
        dir   VARCHAR2(4),
        minp  NUMBER,
        mina  NUMBER,
        grp   VARCHAR2(64),
        vec   VARCHAR2(1),
        md    NUMBER,
        sp    NUMBER
    );
    TYPE mets_t IS TABLE OF met_rec INDEX BY PLS_INTEGER;
    TYPE set_t  IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;     -- offset -> 1
    TYPE sets_t IS TABLE OF set_t INDEX BY PLS_INTEGER;

    v_rows   rows_t;
    v_m      mets_t;
    v_val    num_t;       -- metric m, offset k -> stored value, at m * v_w + k
    v_x      dbl_t;       -- the same slots, robust-scaled (vector metrics)
    v_valid  str_t;       -- offset -> Y / N
    v_wtot   num_t;       -- offset -> total non-idle foreground wait (s/s)
    v_d      dbl_t;       -- distance, at i * v_w + j
    v_dd     num_t;       -- offset -> distance from the other priors
    v_odd    num_t;       -- offset -> 1 = odd one out
    v_tops   str_t;       -- offset -> HTML "Logons (higher), ..."
    v_topj   str_t;       -- offset -> JSON [[metric index, contribution, sign], ...]
    v_prs    num_t;       -- dense list of the valid prior offsets
    v_tmp    num_t;
    v_tmp2   num_t;
    v_cb     cnt_t;       -- card group -> 1 (a finding card as reported)
    v_comp   num_t;       -- flagged offset -> its group (smallest member offset)
    v_csz    num_t;       -- group -> member count
    v_sets   sets_t;      -- suggestion s -> the offsets it drops
    v_skind  str_t;       -- suggestion s -> odd | grp
    v_schg   num_t;       -- suggestion s -> metrics whose bucket changes
    v_sca    num_t;       -- suggestion s -> finding cards without its windows
    v_sb     str_t;       -- m * 10 + s -> the bucket without suggestion s's windows
    v_gtop   str_t;       -- suggestion s -> what sets its windows apart (HTML)
    v_set    set_t;
    v_oth    set_t;
    v_ns     PLS_INTEGER := 0;
    v_nsg    PLS_INTEGER := 0;   -- single odd windows (not in a group)
    v_q      PLS_INTEGER;
    v_h      VARCHAR2(4000);
    v_j      VARCHAR2(4000);
    v_wb     PLS_INTEGER := ~weeks_back;
    v_w      PLS_INTEGER := ~weeks_back + 1;
    v_np     PLS_INTEGER := 0;
    v_nm     PLS_INTEGER := 0;
    v_nvec   PLS_INTEGER := 0;
    v_nodd   PLS_INTEGER := 0;
    v_cap    BINARY_DOUBLE := 5;
    v_medd   NUMBER;
    v_madd   NUMBER;
    v_thr    NUMBER;
    v_cv     NUMBER;
    v_maxk   PLS_INTEGER;
    v_cbn    PLS_INTEGER := 0;
    v_s      BINARY_DOUBLE;
    v_c      PLS_INTEGER;
    v_a      NUMBER;
    v_b      NUMBER;
    v_k      PLS_INTEGER;
    v_g      VARCHAR2(64);
    v_line   VARCHAR2(32767);
    v_reads  VARCHAR2(8000);
    v_ls     VARCHAR2(4000);
    v_oddl   VARCHAR2(4000);
    v_first  PLS_INTEGER;
    v_cls    VARCHAR2(400);
    v_bs     PLS_INTEGER;        -- plan 038: the suggestion the verdict note names
    v_bt     VARCHAR2(4000);     -- plan 038: that note's sentence (HTML)
    v_bw     VARCHAR2(4000);     -- plan 038: the windows it names

    @@sql/lib/metric_policy.plsql
    @@sql/lib/json_escape.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql

    -- median of a dense 1..n list (sorts a copy)
    FUNCTION med(p num_t) RETURN NUMBER IS
        a num_t := p;
        n PLS_INTEGER := p.COUNT;
        t NUMBER;
        j PLS_INTEGER;
    BEGIN
        IF n = 0 THEN RETURN NULL; END IF;
        FOR i IN 2 .. n LOOP
            t := a(i);
            j := i - 1;
            WHILE j >= 1 AND a(j) > t LOOP
                a(j + 1) := a(j);
                j := j - 1;
            END LOOP;
            a(j + 1) := t;
        END LOOP;
        IF MOD(n, 2) = 1 THEN RETURN a((n + 1) / 2); END IF;
        RETURN (a(n / 2) + a(n / 2 + 1)) / 2;
    END med;

    -- a number for the JS payload: p_dig significant digits, dot decimal,
    -- a leading zero, NULL -> null
    FUNCTION jn(p NUMBER, p_dig PLS_INTEGER DEFAULT 15) RETURN VARCHAR2 IS
        v VARCHAR2(100);
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        IF p = 0 THEN RETURN '0'; END IF;
        v := TO_CHAR(ROUND(p, p_dig - 1 - FLOOR(LOG(10, ABS(p)))), 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
        RETURN REGEXP_REPLACE(v, '^(-?)\.', '\10.');
    END jn;

    -- a short decimal for prose / tables (1 decimal, dot)
    FUNCTION d1(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        RETURN TO_CHAR(p, 'FM999999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END d1;

    FUNCTION d2(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        RETURN TO_CHAR(p, 'FM999999990D00', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END d2;

    -- a window's name: "&minus;5w (Mon 10 Aug)", the clock time for a
    -- sub-day cadence
    FUNCTION wdate(k PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF ~step_hours >= 24 THEN
            RETURN TO_CHAR(wg_start(k), 'Dy FMDD Mon', 'NLS_DATE_LANGUAGE=ENGLISH');
        END IF;
        RETURN TO_CHAR(wg_start(k), 'Dy FMDD FMMon HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH');
    END wdate;

    FUNCTION wname(k PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF k = 0 THEN RETURN 'Current (' || wdate(0) || ')'; END IF;
        RETURN '&minus;' || off_label(k) || ' (' || wdate(k) || ')';
    END wname;

    FUNCTION is_flag(p VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN p IN ('large', 'moderate');
    END is_flag;

    -- the three metrics that set the windows of p_a apart from those of
    -- p_b: per metric the median over every (a, b) pair of the capped
    -- scaled difference; the sign of median(x over p_a) - median(x over
    -- p_b).  Ties keep the earlier metric (ORDER BY domain, name).
    PROCEDURE top3(p_a set_t, p_b set_t, p_html OUT VARCHAR2, p_json OUT VARCHAR2) IS
        TYPE tm_t IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
        v_tm  tm_t;
        v_tc  num_t;
        v_tsg num_t;
        v_cs  num_t;
        v_xa  num_t;
        v_xb  num_t;
        v_nt  PLS_INTEGER := 0;
        v_n   PLS_INTEGER;
        v_na  PLS_INTEGER;
        v_nb  PLS_INTEGER;
        v_cc  NUMBER;
        v_sg  NUMBER;
        v_jj  PLS_INTEGER;
        a     PLS_INTEGER;
        b     PLS_INTEGER;
    BEGIN
        FOR m IN 1 .. v_nm LOOP
            IF v_m(m).vec = 'Y' THEN
                v_cs.DELETE; v_xa.DELETE; v_xb.DELETE;
                v_n := 0; v_na := 0; v_nb := 0;
                a := p_a.FIRST;
                WHILE a IS NOT NULL LOOP
                    IF v_x.EXISTS(m * v_w + a) THEN
                        v_na := v_na + 1;
                        v_xa(v_na) := v_x(m * v_w + a);
                        b := p_b.FIRST;
                        WHILE b IS NOT NULL LOOP
                            IF v_x.EXISTS(m * v_w + b) THEN
                                v_n := v_n + 1;
                                v_cs(v_n) := LEAST(ABS(v_x(m * v_w + a) - v_x(m * v_w + b)), v_cap);
                            END IF;
                            b := p_b.NEXT(b);
                        END LOOP;
                    END IF;
                    a := p_a.NEXT(a);
                END LOOP;
                b := p_b.FIRST;
                WHILE b IS NOT NULL LOOP
                    IF v_x.EXISTS(m * v_w + b) THEN
                        v_nb := v_nb + 1;
                        v_xb(v_nb) := v_x(m * v_w + b);
                    END IF;
                    b := p_b.NEXT(b);
                END LOOP;
                IF v_n > 0 THEN
                    v_cc := med(v_cs);
                    v_sg := SIGN(med(v_xa) - med(v_xb));
                    -- keep the three largest (insertion into a 3-slot list)
                    v_jj := v_nt;
                    WHILE v_jj >= 1 AND v_tc(v_jj) < v_cc LOOP
                        IF v_jj < 3 THEN
                            v_tm(v_jj + 1) := v_tm(v_jj); v_tc(v_jj + 1) := v_tc(v_jj); v_tsg(v_jj + 1) := v_tsg(v_jj);
                        END IF;
                        v_jj := v_jj - 1;
                    END LOOP;
                    IF v_jj < 3 AND v_cc > 0 THEN
                        v_tm(v_jj + 1) := m; v_tc(v_jj + 1) := v_cc; v_tsg(v_jj + 1) := v_sg;
                        v_nt := LEAST(v_nt + 1, 3);
                    END IF;
                END IF;
            END IF;
        END LOOP;
        p_html := NULL;
        p_json := NULL;
        FOR t IN 1 .. v_nt LOOP
            p_html := p_html
                || CASE WHEN t > 1 AND t = v_nt THEN ' and ' WHEN t > 1 THEN ', ' END
                || DBMS_XMLGEN.CONVERT(metric_label(v_m(v_tm(t)).dom, v_m(v_tm(t)).nm))
                || ' (' || CASE WHEN v_tsg(t) < 0 THEN 'lower' ELSE 'higher' END || ')';
            p_json := p_json || CASE WHEN t > 1 THEN ',' END
                || '[' || (v_tm(t) - 1) || ',' || jn(v_tc(t), 3) || ',' || NVL(v_tsg(t), 0) || ']';
        END LOOP;
    END top3;

    -- re-score every metric without suggestion s's windows
    PROCEDURE score_set(s PLS_INTEGER) IS
        v_sum NUMBER;
        v_n   PLS_INTEGER;
        v_mu  NUMBER;
        v_sq  NUMBER;
        v_sd  NUMBER;
        v_bk  VARCHAR2(40);
        v_cg  cnt_t;
    BEGIN
        v_schg(s) := 0;
        FOR m IN 1 .. v_nm LOOP
            v_sum := 0; v_n := 0; v_mu := NULL; v_sd := NULL; v_sq := 0;
            FOR q IN 1 .. v_np LOOP
                IF NOT v_sets(s).EXISTS(v_prs(q)) AND v_val.EXISTS(m * v_w + v_prs(q)) THEN
                    v_sum := v_sum + v_val(m * v_w + v_prs(q));
                    v_n := v_n + 1;
                END IF;
            END LOOP;
            IF v_n > 0 THEN
                v_mu := v_sum / v_n;
                FOR q IN 1 .. v_np LOOP
                    IF NOT v_sets(s).EXISTS(v_prs(q)) AND v_val.EXISTS(m * v_w + v_prs(q)) THEN
                        v_sq := v_sq + POWER(v_val(m * v_w + v_prs(q)) - v_mu, 2);
                    END IF;
                END LOOP;
                v_sd := CASE WHEN v_n > 1 THEN SQRT(v_sq / (v_n - 1)) ELSE 0 END;
            END IF;
            v_bk := policy_bucket(v_m(m).dom, v_m(m).nm, NULL, v_m(m).cur, v_mu, v_sd, v_n, v_m(m).shr);
            v_sb(m * 10 + s) := v_bk;
            IF v_bk <> v_m(m).pb THEN v_schg(s) := v_schg(s) + 1; END IF;
            IF v_m(m).canon = 'Y' AND is_flag(v_bk) THEN v_cg(v_m(m).grp) := 1; END IF;
        END LOOP;
        v_sca(s) := v_cg.COUNT;
    END score_set;

    -- suggestion s's windows by name, oldest first: "&minus;5w, &minus;3w"
    FUNCTION set_names(s PLS_INTEGER) RETURN VARCHAR2 IS
        v VARCHAR2(4000);
        k PLS_INTEGER := v_sets(s).LAST;
    BEGIN
        WHILE k IS NOT NULL LOOP
            v := v || CASE WHEN v IS NOT NULL THEN ', ' END || '&minus;' || off_label(k);
            k := v_sets(s).PRIOR(k);
        END LOOP;
        RETURN v;
    END set_names;

    -- a group's wording: p_what 'Y' = "The 4 most recent prior windows
    -- (&minus;4w to &minus;1w, Thu 13 Aug to Thu 3 Sep)", any other = the same
    -- without the range, 'O' = the others ("older ones"), 'E' = what it
    -- means (a change at either end, an episode inside, or a shared trait)
    FUNCTION grp_txt(s PLS_INTEGER, p_what VARCHAR2) RETURN VARCHAR2 IS
        v_lo   PLS_INTEGER := v_sets(s).FIRST;
        v_hi   PLS_INTEGER := v_sets(s).LAST;
        v_n    PLS_INTEGER := v_sets(s).COUNT;
        v_cont BOOLEAN := TRUE;
        v_rec  BOOLEAN;
        v_old  BOOLEAN;
        v_rng  VARCHAR2(4000);
    BEGIN
        FOR q IN 1 .. v_np LOOP
            IF v_prs(q) BETWEEN v_lo AND v_hi AND NOT v_sets(s).EXISTS(v_prs(q)) THEN v_cont := FALSE; END IF;
        END LOOP;
        v_rec := v_cont AND v_lo = v_prs(1);
        v_old := v_cont AND v_hi = v_prs(v_np) AND NOT v_rec;
        IF p_what = 'O' THEN
            RETURN CASE WHEN v_rec THEN 'older ones' WHEN v_old THEN 'more recent ones' ELSE 'other priors' END;
        ELSIF p_what = 'E' THEN
            RETURN CASE WHEN v_rec OR v_old THEN 'the baseline straddles a change'
                        WHEN v_cont THEN 'an episode inside the baseline'
                        ELSE 'they differ from the rest in the same way' END;
        END IF;
        v_rng := CASE WHEN v_cont THEN '&minus;' || off_label(v_hi) || ' to &minus;' || off_label(v_lo)
                           || ', ' || wdate(v_hi) || ' to ' || wdate(v_lo)
                      ELSE set_names(s) END;
        RETURN 'The ' || v_n || CASE WHEN v_rec THEN ' most recent' WHEN v_old THEN ' oldest' END
            || ' prior windows' || CASE WHEN p_what = 'Y' THEN ' (' || v_rng || ')' END;
    END grp_txt;
BEGIN
    -- the compared windows' validity
    FOR k IN 0 .. v_wb LOOP
        v_valid(k) := 'N';
    END LOOP;
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag FROM windows_rollup
    ) LOOP
        v_valid(r.week_offset) := r.valid_flag;
    END LOOP;
    FOR k IN 1 .. v_wb LOOP
        IF v_valid(k) = 'Y' THEN
            v_np := v_np + 1;
            v_prs(v_np) := k;
        END IF;
    END LOOP;

    --
    -- The per-window metric values: 07's unified recompute verbatim, plus
    -- the Current / prior statistics 07 pivots (analytic here, the same
    -- AVG / STDDEV / COUNT), the Current wait total (share denominator)
    -- and each window's wait total (the vector's materiality test).
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    @@sql/lib/load_pairs_cte.sql
    ,
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
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, stat_name
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
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.event_name,
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
           AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                 OR se.event_name IN (SELECT event_name FROM wait_targets) )
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, event_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
    ),
    wait_rows AS (
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    ),
    wait_total AS (
        SELECT SUM(metric_value) AS tot
        FROM   wait_rows
        WHERE  week_offset = 0
    )
    SELECT u.metric_domain, u.metric_name, u.week_offset, u.metric_value,
           MAX(CASE WHEN u.week_offset = 0 THEN u.metric_value END)
               OVER (PARTITION BY u.metric_domain, u.metric_name),
           AVG(CASE WHEN u.week_offset > 0 THEN u.metric_value END)
               OVER (PARTITION BY u.metric_domain, u.metric_name),
           STDDEV(CASE WHEN u.week_offset > 0 THEN u.metric_value END)
               OVER (PARTITION BY u.metric_domain, u.metric_name),
           COUNT(CASE WHEN u.week_offset > 0 THEN u.metric_value END)
               OVER (PARTITION BY u.metric_domain, u.metric_name),
           t.tot,
           SUM(CASE WHEN u.metric_domain = 'WAIT' THEN u.metric_value END)
               OVER (PARTITION BY u.week_offset)
    BULK COLLECT INTO v_rows
    FROM   unified u
    CROSS JOIN wait_total t
    ORDER  BY u.metric_domain, u.metric_name, u.week_offset;

    --
    -- One metric per (domain, name): its policy (family / canonical /
    -- direction / floors, from metric_policy, never re-typed), the bucket
    -- 07 reports (policy_bucket over the same statistics), its card group
    -- and every window's value.
    --
    FOR i IN 1 .. v_rows.COUNT LOOP
        IF v_nm = 0 OR v_rows(i).dom <> v_m(v_nm).dom OR v_rows(i).nm <> v_m(v_nm).nm THEN
            v_nm := v_nm + 1;
            v_m(v_nm).dom := v_rows(i).dom;
            v_m(v_nm).nm  := v_rows(i).nm;
            v_m(v_nm).cur := v_rows(i).cur;
            v_m(v_nm).mu  := v_rows(i).mu;
            v_m(v_nm).sd  := v_rows(i).sd;
            v_m(v_nm).n   := v_rows(i).n;
            v_m(v_nm).shr := CASE WHEN v_rows(i).dom = 'WAIT' AND v_rows(i).tot > 0
                                  THEN v_rows(i).cur / v_rows(i).tot END;
            DECLARE
                v_pol policy_rec;
            BEGIN
                v_pol := metric_policy(v_m(v_nm).dom, v_m(v_nm).nm);
                v_m(v_nm).canon := v_pol.canonical;
                v_m(v_nm).dir   := v_pol.dir;
                v_m(v_nm).minp  := v_pol.min_pct;
                v_m(v_nm).mina  := v_pol.min_abs;
            END;
            v_m(v_nm).fam := finding_family(v_m(v_nm).dom, v_m(v_nm).nm);
            v_m(v_nm).grp := card_group(v_m(v_nm).fam);
            v_m(v_nm).pb  := policy_bucket(v_m(v_nm).dom, v_m(v_nm).nm, NULL,
                                           v_m(v_nm).cur, v_m(v_nm).mu, v_m(v_nm).sd,
                                           v_m(v_nm).n, v_m(v_nm).shr);
            v_m(v_nm).vec := 'N';
        END IF;
        IF v_rows(i).off BETWEEN 0 AND v_wb THEN
            v_val(v_nm * v_w + v_rows(i).off) := v_rows(i).val;
            v_wtot(v_rows(i).off) := v_rows(i).wtot;
        END IF;
    END LOOP;

    --
    -- The vector: canonical metrics that clear their materiality floor in
    -- at least one valid window, robust-scaled.
    --
    FOR m IN 1 .. v_nm LOOP
        IF v_m(m).canon = 'Y' THEN
            v_tmp.DELETE;
            v_c := 0;
            v_b := 0;    -- 1 = material somewhere
            FOR k IN 0 .. v_wb LOOP
                IF v_valid(k) = 'Y' AND v_val.EXISTS(m * v_w + k) THEN
                    v_a := v_val(m * v_w + k);
                    v_c := v_c + 1;
                    v_tmp(v_c) := v_a;
                    IF v_m(m).dom = 'WAIT' THEN
                        IF v_wtot.EXISTS(k) AND v_wtot(k) > 0
                           AND v_a / v_wtot(k) >= NVL(v_m(m).mina, 0.02) THEN
                            v_b := 1;
                        END IF;
                    ELSIF v_m(m).mina IS NULL OR ABS(v_a) >= v_m(m).mina THEN
                        v_b := 1;
                    END IF;
                END IF;
            END LOOP;
            IF v_c >= 3 AND v_b = 1 THEN
                v_m(m).md := med(v_tmp);
                v_tmp2.DELETE;
                FOR q IN 1 .. v_c LOOP
                    v_tmp2(q) := ABS(v_tmp(q) - v_m(m).md);
                END LOOP;
                v_m(m).sp := GREATEST(1.4826 * med(v_tmp2), 0.02 * ABS(v_m(m).md));
                IF v_m(m).sp = 0 THEN
                    v_a := 0;
                    FOR q IN 1 .. v_c LOOP v_a := v_a + v_tmp2(q); END LOOP;
                    v_m(m).sp := 1.2533 * v_a / v_c;
                END IF;
                IF v_m(m).sp > 0 THEN
                    v_m(m).vec := 'Y';
                    v_nvec := v_nvec + 1;
                    FOR k IN 0 .. v_wb LOOP
                        IF v_valid(k) = 'Y' AND v_val.EXISTS(m * v_w + k) THEN
                            v_x(m * v_w + k) := (v_val(m * v_w + k) - v_m(m).md) / v_m(m).sp;
                        END IF;
                    END LOOP;
                END IF;
            END IF;
        END IF;
    END LOOP;

    --
    -- The matrix: every pair of valid windows.
    --
    IF v_np >= 3 AND v_nvec > 0 THEN
        FOR i IN 0 .. v_wb LOOP
            IF v_valid(i) = 'Y' THEN
                FOR j IN i + 1 .. v_wb LOOP
                    IF v_valid(j) = 'Y' THEN
                        v_s := 0;
                        v_c := 0;
                        FOR m IN 1 .. v_nm LOOP
                            IF v_m(m).vec = 'Y' AND v_x.EXISTS(m * v_w + i) AND v_x.EXISTS(m * v_w + j) THEN
                                v_s := v_s + LEAST(ABS(v_x(m * v_w + i) - v_x(m * v_w + j)), v_cap);
                                v_c := v_c + 1;
                            END IF;
                        END LOOP;
                        IF v_c > 0 THEN
                            v_d(i * v_w + j) := v_s / v_c;
                            v_d(j * v_w + i) := v_s / v_c;
                        END IF;
                    END IF;
                END LOOP;
            END IF;
        END LOOP;

        -- each prior's distance from the other priors (median), and the
        -- Current window's distance from the priors (context, never flagged)
        FOR q IN 1 .. v_np LOOP
            v_tmp.DELETE;
            v_c := 0;
            FOR r IN 1 .. v_np LOOP
                IF r <> q AND v_d.EXISTS(v_prs(q) * v_w + v_prs(r)) THEN
                    v_c := v_c + 1;
                    v_tmp(v_c) := v_d(v_prs(q) * v_w + v_prs(r));
                END IF;
            END LOOP;
            IF v_c > 0 THEN v_dd(v_prs(q)) := med(v_tmp); END IF;
        END LOOP;
        IF v_valid(0) = 'Y' THEN
            v_tmp.DELETE;
            v_c := 0;
            FOR r IN 1 .. v_np LOOP
                IF v_d.EXISTS(v_prs(r)) THEN
                    v_c := v_c + 1;
                    v_tmp(v_c) := v_d(v_prs(r));
                END IF;
            END LOOP;
            v_cv := med(v_tmp);
        END IF;

        -- the odd-one-out rule
        v_tmp.DELETE;
        v_c := 0;
        FOR q IN 1 .. v_np LOOP
            IF v_dd.EXISTS(v_prs(q)) THEN
                v_c := v_c + 1;
                v_tmp(v_c) := v_dd(v_prs(q));
            END IF;
        END LOOP;
        v_medd := med(v_tmp);
        v_tmp2.DELETE;
        FOR q IN 1 .. v_c LOOP
            v_tmp2(q) := ABS(v_tmp(q) - v_medd);
        END LOOP;
        v_madd := med(v_tmp2);
        IF v_medd IS NOT NULL THEN
            v_thr := GREATEST(v_medd + 3 * 1.4826 * v_madd, 1.5 * v_medd);
        END IF;
        v_maxk := NULL;
        FOR q IN 1 .. v_np LOOP
            v_k := v_prs(q);
            IF v_dd.EXISTS(v_k) THEN
                IF v_maxk IS NULL OR v_dd(v_k) > v_dd(v_maxk) THEN v_maxk := v_k; END IF;
                IF v_thr IS NOT NULL AND v_dd(v_k) > v_thr THEN
                    v_odd(v_k) := 1;
                    v_nodd := v_nodd + 1;
                END IF;
            END IF;
        END LOOP;

        -- flagged windows that are alike each other (distance at most the
        -- threshold) form a GROUP (a shift in the baseline, not an odd one
        -- out): connected components over that link, odd = 2 for members
        FOR q IN 1 .. v_np LOOP
            IF v_odd.EXISTS(v_prs(q)) THEN v_comp(v_prs(q)) := v_prs(q); END IF;
        END LOOP;
        LOOP
            v_c := 0;
            v_k := v_comp.FIRST;
            WHILE v_k IS NOT NULL LOOP
                v_q := v_comp.FIRST;
                WHILE v_q IS NOT NULL LOOP
                    IF v_q <> v_k AND v_d.EXISTS(v_k * v_w + v_q) AND v_d(v_k * v_w + v_q) <= v_thr
                       AND v_comp(v_q) < v_comp(v_k) THEN
                        v_comp(v_k) := v_comp(v_q);
                        v_c := v_c + 1;
                    END IF;
                    v_q := v_comp.NEXT(v_q);
                END LOOP;
                v_k := v_comp.NEXT(v_k);
            END LOOP;
            EXIT WHEN v_c = 0;
        END LOOP;
        v_k := v_comp.FIRST;
        WHILE v_k IS NOT NULL LOOP
            v_csz(v_comp(v_k)) := CASE WHEN v_csz.EXISTS(v_comp(v_k)) THEN v_csz(v_comp(v_k)) ELSE 0 END + 1;
            v_k := v_comp.NEXT(v_k);
        END LOOP;
        v_k := v_comp.FIRST;
        WHILE v_k IS NOT NULL LOOP
            IF v_csz(v_comp(v_k)) >= 2 THEN v_odd(v_k) := 2; ELSE v_nsg := v_nsg + 1; END IF;
            v_k := v_comp.NEXT(v_k);
        END LOOP;

        -- the suggestions: 1 = every single odd window, then one per group
        -- (the most recent first, at most 3)
        IF v_nsg > 0 THEN
            v_ns := 1;
            v_skind(1) := 'odd';
            v_set.DELETE;
            v_k := v_comp.FIRST;
            WHILE v_k IS NOT NULL LOOP
                IF v_odd(v_k) = 1 THEN v_set(v_k) := 1; END IF;
                v_k := v_comp.NEXT(v_k);
            END LOOP;
            v_sets(1) := v_set;
        END IF;
        v_q := v_csz.FIRST;
        WHILE v_q IS NOT NULL AND v_ns < 4 LOOP
            IF v_csz(v_q) >= 2 THEN
                v_ns := v_ns + 1;
                v_skind(v_ns) := 'grp';
                v_set.DELETE;
                v_k := v_comp.FIRST;
                WHILE v_k IS NOT NULL LOOP
                    IF v_comp(v_k) = v_q THEN v_set(v_k) := 1; END IF;
                    v_k := v_comp.NEXT(v_k);
                END LOOP;
                v_sets(v_ns) := v_set;
            END IF;
            v_q := v_csz.NEXT(v_q);
        END LOOP;

        -- what sets a window apart (every flagged window, and the most
        -- distant one when none is flagged, for the table) and each group
        FOR q IN 1 .. v_np LOOP
            v_k := v_prs(q);
            IF v_odd.EXISTS(v_k) OR v_k = v_maxk THEN
                v_set.DELETE;
                v_oth.DELETE;
                v_set(v_k) := 1;
                FOR r IN 1 .. v_np LOOP
                    IF r <> q THEN v_oth(v_prs(r)) := 1; END IF;
                END LOOP;
                top3(v_set, v_oth, v_h, v_j);
                v_tops(v_k) := v_h;
                v_topj(v_k) := v_j;
            END IF;
        END LOOP;
        FOR s IN 1 .. v_ns LOOP
            v_oth.DELETE;
            FOR r IN 1 .. v_np LOOP
                IF NOT v_sets(s).EXISTS(v_prs(r)) THEN v_oth(v_prs(r)) := 1; END IF;
            END LOOP;
            top3(v_sets(s), v_oth, v_h, v_j);
            v_gtop(s) := v_h;
        END LOOP;
    END IF;

    --
    -- The suggestions, scored here too (a JS-off fact and a second check
    -- of the client twin): drop the suggestion's windows, re-score every
    -- metric with policy_bucket over the remaining valid priors (mean and
    -- SAMPLE sd, as STDDEV), count the buckets that change and the cards.
    --
    FOR m IN 1 .. v_nm LOOP
        IF v_m(m).canon = 'Y' AND is_flag(v_m(m).pb) THEN
            v_cb(v_m(m).grp) := 1;
        END IF;
    END LOOP;
    v_cbn := v_cb.COUNT;
    FOR s IN 1 .. v_ns LOOP
        score_set(s);
    END LOOP;

    --
    -- Reads as / row text
    --
    IF v_np < 3 THEN
        v_reads := 'Only ' || v_np || ' valid prior window' || CASE WHEN v_np = 1 THEN '' ELSE 's' END
            || ': judging whether the baseline is sound needs at least 3, so there is nothing to compare.';
        v_ls := CASE WHEN v_np = 0 THEN 'no valid prior window' ELSE 'only ' || v_np || ' valid prior window'
                     || CASE WHEN v_np = 1 THEN '' ELSE 's' END END || ': nothing to compare';
    ELSIF v_nvec = 0 OR v_medd IS NULL THEN
        v_reads := 'No metric clears its materiality floor in enough windows to compare the windows.';
        v_ls := 'no material metric to compare the windows on';
    ELSIF v_nodd = 0 THEN
        v_reads := 'The ' || v_np || ' prior windows are alike: none stands out. The most distant, '
            || wname(v_maxk) || ', is ' || d1(v_dd(v_maxk)) || ' robust spreads from the others (odd past '
            || d1(v_thr) || ').'
            || CASE WHEN v_cv IS NOT NULL THEN ' The Current window, the one being judged, sits '
                    || d1(v_cv) || ' from the priors.' END;
        v_ls := 'the ' || v_np || ' prior windows are alike (no odd one out)';
    ELSE
        v_reads := NULL;
        v_first := NULL;
        IF v_nsg > 0 THEN
            v_oddl := NULL;
            v_c := 0;
            FOR q IN REVERSE 1 .. v_np LOOP
                IF v_odd.EXISTS(v_prs(q)) AND v_odd(v_prs(q)) = 1 THEN
                    v_c := v_c + 1;
                    v_oddl := v_oddl || CASE WHEN v_c > 1 AND v_c = v_nsg THEN ' and ' WHEN v_c > 1 THEN ', ' END
                        || wname(v_prs(q));
                    IF v_first IS NULL OR v_dd(v_prs(q)) > v_dd(v_first) THEN v_first := v_prs(q); END IF;
                END IF;
            END LOOP;
            v_reads := CASE WHEN v_nsg = 1 THEN 'Window ' ELSE 'Windows ' END || v_oddl
                || CASE WHEN v_nsg = 1 THEN ' is' ELSE ' are' END || ' unlike the other priors'
                || CASE WHEN v_tops(v_first) IS NOT NULL THEN
                       CASE WHEN v_nsg = 1 THEN ', mostly in ' ELSE ' (' || wname(v_first) || ' mostly in ' END
                       || v_tops(v_first) || CASE WHEN v_nsg > 1 THEN ')' END END
                || CASE WHEN v_nsg = 1 THEN '. Its' ELSE '. The largest' END || ' distance from the other priors is '
                || d1(v_dd(v_first)) || ' robust spreads (odd past ' || d1(v_thr) || ').';
        END IF;
        FOR s IN 1 .. v_ns LOOP
            IF v_skind(s) = 'grp' THEN
                v_reads := v_reads || CASE WHEN v_reads IS NOT NULL THEN ' ' END || grp_txt(s, 'Y')
                    || ' form a group of their own, unlike the ' || grp_txt(s, 'O')
                    || CASE WHEN v_gtop(s) IS NOT NULL THEN ', mostly in ' || v_gtop(s) END
                    || ': ' || grp_txt(s, 'E') || '.';
            END IF;
        END LOOP;
        FOR s IN 1 .. v_ns LOOP
            v_reads := v_reads || CASE WHEN s = 1 THEN ' Without ' ELSE '; without ' END
                || CASE WHEN v_skind(s) = 'odd' THEN set_names(s)
                        WHEN v_ns - CASE WHEN v_nsg > 0 THEN 1 ELSE 0 END = 1 THEN 'the group' ELSE 'the group ' || set_names(s) END || ', '
                || CASE WHEN v_schg(s) = 0 THEN 'no metric changes bucket'
                        WHEN v_schg(s) = 1 THEN '1 metric changes bucket'
                        ELSE v_schg(s) || ' metrics change bucket' END
                || ' and the findings go from ' || v_cbn || ' to ' || v_sca(s);
        END LOOP;
        v_reads := v_reads || '; the what-if below shows the details.';
        IF v_nsg > 0 AND v_ns = 1 THEN
            v_ls := wname(v_first) || ' is unlike the other priors'
                || CASE WHEN v_nsg > 1 THEN ' (' || v_nsg || ' odd windows)' END
                || CASE WHEN v_schg(1) = 0 THEN '; dropping it changes no finding'
                        ELSE '; the what-if shows what changes without it' END;
        ELSIF v_nsg > 0 THEN
            v_ls := wname(v_first) || ' is an odd one out and ' || v_sets(2).COUNT
                || ' prior windows form a group of their own';
        ELSE
            v_ls := v_sets(1).COUNT || ' prior windows form a group unlike the ' || grp_txt(1, 'O')
                || ' (' || grp_txt(1, 'E') || ')';
        END IF;
    END IF;

    --
    -- Markup.  The section opens its library row when a window is odd.
    --
    DBMS_OUTPUT.PUT_LINE('<section id="win-sim" class="vw in-s in-a lib'
        || CASE WHEN v_nodd > 0 THEN ' lopen' END || '" style="--os:16"><h2>Window similarity'
        || '<small class="h2sub">Is the baseline itself sound, and what if a window is dropped?</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('win-sim', v_ls));

    IF v_np < 3 OR v_nvec = 0 OR v_medd IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">' || v_reads || '</p></section>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p class="winsim-rd"><b>Reads as:</b> ' || v_reads || '</p>');
        DBMS_OUTPUT.PUT_LINE('<div class="winsim-app" id="winsim-app" hidden>'
            || '<div class="winsim-p1"><h3>How alike the windows are</h3>'
            || '<p class="winsim-cap">Each cell compares two windows over ' || v_nvec || ' metrics: '
            || 'the stronger the shade, the further apart (in robust spreads). Below, each window''s distance from the prior windows; '
            || 'the dashed line is the odd-one-out threshold.</p>'
            || '<div class="winsim-lg" aria-hidden="true"></div>'
            || '<div class="winsim-plot" id="winsim-mx"></div></div>'
            || '<div class="winsim-p2"><h3>What if a window is dropped?</h3>'
            || '<p class="winsim-cap">Click a prior window to take it out of the baseline; every metric is '
            || 're-scored against the windows left, with the same rule as the findings.</p>'
            || '<div class="winsim-chips" id="winsim-chips" role="group" aria-label="Prior windows in the baseline"></div>'
            || '<div class="winsim-act">'
            || '<button type="button" class="winsim-btn" id="winsim-reset" disabled>Reset</button></div>'
            || '<div class="winsim-res" id="winsim-res" aria-live="polite"></div></div></div>');
        DBMS_OUTPUT.PUT_LINE('<p class="note winsim-nojs">The matrix and the what-if are drawn by the page script; '
            || 'every distance is in the table below.</p>');

        -- the per-window table (oldest first)
        IF v_w > 20 THEN
            DBMS_OUTPUT.PUT_LINE('<details class="winsim-full"><summary>Distance from the priors, per window ('
                || v_w || ' windows)</summary>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<div class="winsim-tw"><table class="winsim-tbl" id="winsim-tbl" data-nosort data-nocount><thead><tr>'
            || '<th>Window</th><th>Start</th><th class="num">Distance from the priors</th>'
            || '<th>Status</th><th>Differs most in</th></tr></thead><tbody>');
        FOR k IN REVERSE 0 .. v_wb LOOP
            v_cls := CASE WHEN v_valid(k) = 'N' THEN 'skip' WHEN v_odd.EXISTS(k) THEN 'winsim-fl' END;
            DBMS_OUTPUT.PUT_LINE('<tr id="winsim-w' || k || '"'
                || CASE WHEN v_cls IS NOT NULL THEN ' class="' || v_cls || '"' END || '>'
                || '<td data-w="' || k || '">' || CASE WHEN k = 0 THEN 'Current' ELSE '&minus;' || off_label(k) END || '</td>'
                || '<td>' || TO_CHAR(wg_start(k), 'Dy DD Mon YYYY HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH') || '</td>'
                || '<td class="num">'
                || CASE WHEN v_valid(k) = 'N' THEN '&mdash;'
                        WHEN k = 0 THEN d2(v_cv)
                        WHEN v_dd.EXISTS(k) THEN d2(v_dd(k)) ELSE '&mdash;' END || '</td>'
                || '<td>' || CASE WHEN v_valid(k) = 'N' THEN 'skipped, not scored'
                                  WHEN k = 0 THEN 'Current, the window being judged'
                                  WHEN v_odd.EXISTS(k) AND v_odd(k) = 2 THEN '<span class="winsim-odd">&#9650; in a group unlike the rest</span>'
                                  WHEN v_odd.EXISTS(k) THEN '<span class="winsim-odd">&#9650; odd one out</span>'
                                  ELSE 'alike' END || '</td>'
                || '<td>' || CASE WHEN v_valid(k) = 'Y' AND k > 0 AND v_tops.EXISTS(k) THEN v_tops(k) END || '</td></tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');
        IF v_w > 20 THEN
            DBMS_OUTPUT.PUT_LINE('</details>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<p class="winsim-cap">Threshold: a prior window is odd when its distance is above '
            || d2(v_thr) || ' (the larger of the median ' || d2(v_medd) || ' + 3 &times; 1.4826 &times; MAD '
            || d2(v_madd) || ' and 1.5 &times; the median).</p>');

        -- the full matrix as a table, only when it stays readable
        IF v_w <= 20 THEN
            v_line := '<details class="winsim-full"><summary>The full matrix as a table (' || v_w || ' &times; '
                || v_w || ')</summary><div class="winsim-tw"><table class="winsim-mt" data-nosort data-notools><thead><tr><th></th>';
            FOR j IN REVERSE 0 .. v_wb LOOP
                v_line := v_line || '<th class="num" data-w="' || j || '">'
                    || CASE WHEN j = 0 THEN 'Cur' ELSE '&minus;' || off_label(j) END || '</th>';
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(v_line || '</tr></thead><tbody>');
            FOR i IN REVERSE 0 .. v_wb LOOP
                v_line := '<tr><th data-w="' || i || '">' || CASE WHEN i = 0 THEN 'Cur' ELSE '&minus;' || off_label(i) END || '</th>';
                FOR j IN REVERSE 0 .. v_wb LOOP
                    v_line := v_line || '<td class="num">'
                        || CASE WHEN i = j THEN '' WHEN v_d.EXISTS(i * v_w + j) THEN d2(v_d(i * v_w + j)) ELSE '&mdash;' END
                        || '</td>';
                END LOOP;
                DBMS_OUTPUT.PUT_LINE(v_line || '</tr>');
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('</tbody></table></div></details>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<p class="winsim-cap">The full ' || v_w || ' &times; ' || v_w
                || ' matrix is too large for a table; hover the chart for any pair (the per-window distances above '
                || 'are its summary).</p>');
        END IF;

        --
        -- The payload, one line per window list / metric / matrix row.
        --
        DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.winsim={"cap":' || jn(v_cap, 3)
            || ',"thr":' || jn(v_thr, 6) || ',"medd":' || jn(v_medd, 6) || ',"cv":' || jn(v_cv, 6) || ',"nvec":' || v_nvec || ',');
        v_line := '"w":[';
        FOR k IN REVERSE 0 .. v_wb LOOP
            v_line := v_line || CASE WHEN k < v_wb THEN ',' END
                || '{"o":' || k || ',"v":"' || v_valid(k) || '","dd":'
                || CASE WHEN k = 0 THEN jn(v_cv, 6) WHEN v_dd.EXISTS(k) THEN jn(v_dd(k), 6) ELSE 'null' END
                || ',"odd":' || CASE WHEN v_odd.EXISTS(k) THEN v_odd(k) ELSE 0 END
                || ',"top":[' || CASE WHEN v_topj.EXISTS(k) THEN v_topj(k) END || ']}';
            IF LENGTH(v_line) > 30000 THEN
                DBMS_OUTPUT.PUT_LINE(v_line);
                v_line := NULL;
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(v_line || '],');
        DBMS_OUTPUT.PUT_LINE('"m":[');
        FOR m IN 1 .. v_nm LOOP
            v_line := CASE WHEN m > 1 THEN ',' END
                || '{"d":"' || v_m(m).dom || '","n":"' || json_escape(v_m(m).nm) || '"'
                || ',"l":"' || json_escape(metric_label(v_m(m).dom, v_m(m).nm)) || '"'
                || ',"k":"' || v_m(m).canon || '","dir":"' || v_m(m).dir || '"'
                || ',"p":' || jn(v_m(m).minp) || ',"a":' || jn(v_m(m).mina)
                || ',"sh":' || jn(v_m(m).shr) || ',"g":"' || json_escape(v_m(m).grp) || '"'
                || ',"pb":"' || v_m(m).pb || '","sb":[';
            FOR s IN 1 .. v_ns LOOP
                v_line := v_line || CASE WHEN s > 1 THEN ',' END || '"' || v_sb(m * 10 + s) || '"';
            END LOOP;
            v_line := v_line || ']'
                || ',"vec":' || CASE WHEN v_m(m).vec = 'Y' THEN 1 ELSE 0 END
                || ',"md":' || jn(v_m(m).md) || ',"sp":' || jn(v_m(m).sp)
                || ',"lk":"' || json_escape(ent(DBMS_XMLGEN.CONVERT(metric_label(v_m(m).dom, v_m(m).nm)),
                                                 finding_anchor(v_m(m).dom, v_m(m).nm), 'metric')) || '"'
                || ',"v":[';
            FOR k IN REVERSE 0 .. v_wb LOOP
                v_line := v_line || CASE WHEN k < v_wb THEN ',' END
                    || CASE WHEN v_valid(k) = 'Y' AND v_val.EXISTS(m * v_w + k) THEN jn(v_val(m * v_w + k)) ELSE 'null' END;
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(v_line || ']}');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],"dm":[');
        v_c := 0;
        FOR i IN REVERSE 0 .. v_wb LOOP
            v_line := CASE WHEN i < v_wb THEN ',' END || '[';
            FOR j IN REVERSE i + 1 .. v_wb LOOP
                v_line := v_line || CASE WHEN j < v_wb THEN ',' END
                    || CASE WHEN v_d.EXISTS(i * v_w + j) THEN jn(v_d(i * v_w + j), 4) ELSE 'null' END;
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(v_line || ']');
        END LOOP;
        v_line := '],"cb":' || v_cbn || ',"sug":[';
        FOR t IN 1 .. v_ns LOOP
            v_line := v_line || CASE WHEN t > 1 THEN ',' END || '{"k":"' || v_skind(t) || '","drop":[';
            v_k := v_sets(t).LAST;
            v_c := 0;
            WHILE v_k IS NOT NULL LOOP
                v_line := v_line || CASE WHEN v_c > 0 THEN ',' END || v_k;
                v_c := v_c + 1;
                v_k := v_sets(t).PRIOR(v_k);
            END LOOP;
            v_line := v_line || '],"chg":' || v_schg(t) || ',"ca":' || v_sca(t) || '}';
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(v_line || ']};</script>');
        --
        -- Plan 038: one note in the verdict hero, "Baseline check".  Only
        -- when a suggestion's drop CHANGES something (a metric's bucket) and
        -- at least 3 valid prior windows would remain (with fewer every
        -- metric turns "insufficient history", which says nothing about
        -- the baseline).  The suggestion that changes the most metrics
        -- (the first on a tie).  The sentence is this section's own
        -- numbers (v_schg / v_sca / v_cbn, the "chg" / "ca" / "cb" of the
        -- payload); a relocation script moves the li into #narrative-slot
        -- while the page parses (17 runs after this and keeps this note
        -- last).  A note, never a finding: no count, pill or severity.
        --
        v_bs := NULL;
        FOR s IN 1 .. v_ns LOOP
            IF v_schg(s) > 0 AND v_np - v_sets(s).COUNT >= 3
               AND (v_bs IS NULL OR v_schg(s) > v_schg(v_bs)) THEN
                v_bs := s;
            END IF;
        END LOOP;
        IF v_bs IS NOT NULL THEN
            IF v_skind(v_bs) = 'grp' THEN
                v_bt := grp_txt(v_bs, 'Y') || ' form a group unlike the ' || grp_txt(v_bs, 'O') || '.';
            ELSIF v_sets(v_bs).COUNT = 1 THEN
                v_bt := 'The prior window ' || wname(v_sets(v_bs).FIRST) || ' is unlike the other prior windows.';
            ELSIF v_sets(v_bs).COUNT <= 6 THEN
                v_bw := NULL;
                v_c := 0;
                v_k := v_sets(v_bs).LAST;
                WHILE v_k IS NOT NULL LOOP
                    v_c := v_c + 1;
                    v_bw := v_bw || CASE WHEN v_c > 1 AND v_c = v_sets(v_bs).COUNT THEN ' and '
                                         WHEN v_c > 1 THEN ', ' END || wname(v_k);
                    v_k := v_sets(v_bs).PRIOR(v_k);
                END LOOP;
                v_bt := 'The prior windows ' || v_bw || ' are unlike the other prior windows.';
            ELSE
                v_bt := v_sets(v_bs).COUNT || ' prior windows (' || set_names(v_bs)
                    || ') are unlike the other prior windows.';
            END IF;
            v_bt := v_bt || ' Scored without ' || CASE WHEN v_sets(v_bs).COUNT = 1 THEN 'it' ELSE 'them' END || ', '
                || v_schg(v_bs) || CASE WHEN v_schg(v_bs) = 1 THEN ' metric changes' ELSE ' metrics change' END
                || ' bucket'
                || CASE WHEN v_sca(v_bs) > v_cbn THEN ' and the findings rise from ' || v_cbn || ' to ' || v_sca(v_bs)
                        WHEN v_sca(v_bs) < v_cbn THEN ' and the findings fall from ' || v_cbn || ' to ' || v_sca(v_bs)
                        ELSE ', though the findings stay at ' || v_cbn END
                || '.';
            DBMS_OUTPUT.PUT_LINE('<div id="base-src" hidden><ul><li class="hn-base" data-sug="' || (v_bs - 1)
                || '" data-chg="' || v_schg(v_bs) || '" data-cb="' || v_cbn || '" data-ca="' || v_sca(v_bs) || '">'
                || '<span class="hw"><b class="hl">Baseline check:</b> ' || v_bt
                || ' <a class="go" href="#win-sim">Window similarity&nbsp;&rarr;</a></span></li></ul></div>');
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,s=d.getElementById("base-src"),ns=d.getElementById("narrative-slot"),li=s?s.querySelector("li"):null;if(li&&ns){ns.appendChild(li);ns.hidden=false;}if(s&&s.parentNode)s.parentNode.removeChild(s);})();</script>');
            -- plan 040 follow-up: the row's news is this note; the chrome shuts
            -- the row when the verdict carries it (only emitted with the note)
            IF v_nodd > 0 THEN
                DBMS_OUTPUT.PUT_LINE(lib_news('win-sim', 'note:hn-base'));
            END IF;
        END IF;
        DBMS_OUTPUT.PUT_LINE('</section>');
    END IF;
END;
/

@@sql/lib/js_winsim.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 26_window_similarity END -->'); END;
/
