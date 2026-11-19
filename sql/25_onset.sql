--
-- 25_onset.sql
-- Onset: "the Current window is abnormal -- WHEN did it start?"  The main
-- comparison sees one hour against the same hour in earlier periods, so a
-- shift that began three days ago looks the same as one that began ten
-- minutes ago.  This section follows a few headline metrics through EVERY
-- snapshot interval of the report span (start of the earliest compared
-- window to target_end), compares each point with its seasonal normal and
-- runs a one-sided CUSUM in each direction to date the change.
--
-- Data: sql/lib/onset_cte.sql (snapshot pairs with the restart guard,
-- SYSSTAT deltas, DB time / DB CPU from the time model), on a regular
-- grid that ends at target_end.  Bucket = the median snapshot interval,
-- coarsened (30 min, 1 h, 2 h ...) only when the span would pass 3000
-- points.  Each pair's rate is spread over the buckets it overlaps,
-- weighted by the overlap (a loaded system stretches its snapshots to
-- 18-24 min; a midpoint rule left holes).  A pair longer than 1.9
-- snapshot intervals is a gap (a missed snapshot), a bucket covered for
-- less than half its length is a gap, a restart drops the pair across
-- it: a gap is NULL, never zero.
--
-- Seasonal normal (one SQL pass, a self-join on the phase):
--   span >= 21 days  phase = hour of the WEEK, the other weeks
--   span >= 3 days   phase = hour of the day, the other days
--   otherwise        flat: every point before the Current window
-- median and interquartile range of the same-phase points, the point's own
-- day / week excluded.  Spread = max(IQR / 1.349, 2% of |median|, the
-- metric's materiality floor from sql/lib/metric_policy.plsql).  A point
-- needs 3 same-phase points from 2 other periods (flat: 8 baseline
-- points), else it is "too little history" and the CUSUM holds.  When
-- fewer than half the points can be judged, the next coarser normal is
-- used (hour of the week -> hour of the day -> flat) and the caption says
-- so (a restart-ridden month leaves too few same-hour weeks).
--
-- Change point (PL/SQL, cusum_scan): z = (x - median) / spread, clipped
-- to +/- 3; a two-sided CUSUM of z against the current LEVEL (0 = the
-- normal) with slack 0.5: S+ = max(0, S+ + (z - level) - 0.5), S- the
-- mirror.  When a sum passes 5 a STEP is recorded: onset = the first
-- point after that sum last stood at zero, new level = the median z from
-- the onset to the detection, and both sums restart from the new level --
-- so a shift on top of an earlier one is dated from its own start (a
-- plain CUSUM stays saturated by the first and never sees the second).
-- A run = consecutive levels on the same side, more than 0.5 away.  The
-- run still going at target_end is the OPEN shift when the Current
-- window's median z agrees (beyond 0.5 on that side); its onset is the
-- run's latest step away from the normal ("on top of" the run's first
-- one when they differ).  Otherwise the latest finished run is reported
-- as the most recent closed excursion.  The sentence (Reads as + the
-- evidence library row) is computed here, so it exists with JS off.
-- Release markers are known only to the client: sql/lib/js_onset.plsql
-- adds "2 h after Release 4.2" to the sentence.
--
-- Template-independent (fixed metric list), ungraded (no policy bucket:
-- the section dates a change, it does not score one).  Read-only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 25_onset BEGIN -->'); END;
/

DECLARE
    TYPE row_rec IS RECORD (
        ord  NUMBER,
        b    NUMBER,
        v    NUMBER,
        tm   DATE,        -- bucket midpoint
        ph   NUMBER,      -- phase (hour of week / day, 0 flat)
        per  NUMBER,      -- period (week / day number; NULL flat)
        med  NUMBER,
        q1   NUMBER,
        q3   NUMBER,
        n    NUMBER,
        np   NUMBER
    );
    TYPE row_t IS TABLE OF row_rec INDEX BY PLS_INTEGER;
    TYPE num_t IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE str_t IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    TYPE idx_t IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    TYPE grp_t IS TABLE OF idx_t INDEX BY VARCHAR2(40);
    TYPE key_t IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(60);
    TYPE seen_t IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);

    c_k      CONSTANT NUMBER := 0.5;     -- CUSUM slack (sd units)
    c_h      CONSTANT NUMBER := 5;       -- CUSUM threshold (sd units)
    c_clip   CONSTANT NUMBER := 3;       -- residual clip (sd units)
    c_maxpts CONSTANT NUMBER := 3000;    -- points per metric, at most
    c_nmet   CONSTANT PLS_INTEGER := 7;
    c_mk     CONSTANT VARCHAR2(40) := '<span class="onset-mk"></span>';

    v_t1     DATE := TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS');
    v_span_h NUMBER := ~weeks_back * TO_NUMBER('~step_hours') + ~win_hours;
    v_t0     DATE;
    v_tc     DATE;
    v_ival   NUMBER;
    v_npairs NUMBER := 0;
    v_first  DATE;
    v_bmin   NUMBER;
    v_m      NUMBER;
    v_nb     PLS_INTEGER := 0;
    v_mode   VARCHAR2(1);
    v_mode0  VARCHAR2(1);
    v_eff_d  NUMBER;
    v_rows   row_t;
    v_grp    grp_t;     -- (metric, phase) -> row indices
    v_cache  key_t;     -- (metric, phase, period) -> the row holding its normal
    v_seen   seen_t;
    v_one    idx_t;
    v_key    VARCHAR2(60);
    v_gk     VARCHAR2(40);
    v_judged NUMBER;
    v_valued NUMBER;

    -- per metric (index 1 .. 7)
    m_name   str_t;     -- display label
    m_short  str_t;     -- name inside the sentence
    m_unit   str_t;
    m_floor  num_t;     -- spread floor, display unit
    m_dec    num_t;     -- payload decimals
    m_st     str_t;     -- open | closed | none | thin
    m_thin   num_t;     -- valued points with too little history
    m_valn   num_t;     -- valued points
    m_jn     num_t;     -- judged points
    m_odir   num_t;     -- open shift: direction, onset (its latest step away
    m_oon    num_t;     -- from normal), base (the run's first step), level
    m_obase  num_t;     -- at the end in spreads
    m_olev   num_t;
    m_cdir   num_t;     -- most recent closed excursion: direction, onset,
    m_con    num_t;     -- end, largest level in spreads
    m_cend   num_t;
    m_clev   num_t;
    m_first  num_t;     -- first judged point (an onset there is censored)
    m_bef    num_t;     -- level before / after (medians), of the reported excursion
    m_aft    num_t;

    -- per point of the metric being processed (index 0 .. nb-1)
    x        num_t;
    md       num_t;
    sp       num_t;
    zc       num_t;
    cc       num_t;     -- signed CUSUM (S+, or -S- when larger)
    tmp      num_t;
    -- the steps cusum_scan detected (1 .. v_ns): onset, detection point,
    -- direction, level before / after (spreads)
    s_a      num_t;
    s_i      num_t;
    s_dir    num_t;
    s_old    num_t;
    s_new    num_t;
    v_ns     PLS_INTEGER := 0;
    v_rs     PLS_INTEGER;
    v_rsg    NUMBER;
    v_rmax   NUMBER;
    v_rlast  PLS_INTEGER;

    v_ntmp   PLS_INTEGER;
    v_curz   NUMBER;
    v_a      PLS_INTEGER;
    v_e      PLS_INTEGER;
    v_mx     NUMBER;
    v_lead   PLS_INTEGER;
    v_nopen  PLS_INTEGER := 0;
    v_rec    PLS_INTEGER;
    v_sent   VARCHAR2(4000);
    v_ls     VARCHAR2(4000);
    v_phase  VARCHAR2(4000);
    v_phs    VARCHAR2(4000);
    v_html   VARCHAR2(32767);
    v_buf    VARCHAR2(32767);
    v_json   CLOB;
    v_tok    VARCHAR2(100);
    v_sx     VARCHAR2(32767);
    v_smd    VARCHAR2(32767);
    v_ssp    VARCHAR2(32767);
    v_sc     VARCHAR2(32767);
    v_cx     CLOB;
    v_cmd    CLOB;
    v_csp    CLOB;
    v_cc     CLOB;
    v_h2     VARCHAR2(400) := '<h2>Onset<small class="h2sub">When the shift started: every snapshot interval '
        || 'of the span against its seasonal normal, dated by a CUSUM change-point test</small></h2>';

    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/put_clob_chunked.plsql

    -- 'Tue 8 Sep 14:00' (English names: lint 28)
    FUNCTION dt_txt(p DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p, 'Dy fmDD Mon fmHH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH');
    END;
    -- '8 Nov 13:30' (the picker's short form)
    FUNCTION ds_txt(p DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p, 'fmDD Mon fmHH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH');
    END;
    FUNCTION hm_txt(p DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p, 'HH24:MI');
    END;
    -- a duration in minutes as '40 min' / '2.5 h' / '6 days'
    FUNCTION dur_txt(p_min NUMBER) RETURN VARCHAR2 IS
        v VARCHAR2(40);
    BEGIN
        IF p_min < 60 THEN
            RETURN ROUND(p_min) || ' min';
        ELSIF p_min < 2880 THEN
            v := TO_CHAR(ROUND(p_min / 60, CASE WHEN p_min < 600 THEN 1 ELSE 0 END),
                         'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''');
            RETURN RTRIM(RTRIM(v, '0'), '.') || ' h';
        END IF;
        RETURN ROUND(p_min / 1440) || ' days';
    END;
    -- a payload number with p_d decimals; '' for NULL (an empty array slot)
    FUNCTION tok(p NUMBER, p_d NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN NULL; END IF;
        IF p_d <= 0 THEN
            RETURN TO_CHAR(ROUND(p), 'FM999999999999990');
        END IF;
        RETURN RTRIM(TO_CHAR(ROUND(p, p_d), 'FM999999999999990D' || RPAD('9', p_d, '9'),
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END;
    -- median of tmp(1 .. p_n) (sorts tmp in place; shell sort)
    FUNCTION med_tmp(p_n PLS_INTEGER) RETURN NUMBER IS
        g PLS_INTEGER := 1;
        j PLS_INTEGER;
        t NUMBER;
    BEGIN
        IF p_n < 1 THEN RETURN NULL; END IF;
        WHILE g < p_n / 3 LOOP g := g * 3 + 1; END LOOP;
        WHILE g >= 1 LOOP
            FOR i IN g + 1 .. p_n LOOP
                t := tmp(i);
                j := i;
                WHILE j > g AND tmp(j - g) > t LOOP
                    tmp(j) := tmp(j - g);
                    j := j - g;
                END LOOP;
                tmp(j) := t;
            END LOOP;
            g := TRUNC(g / 3);
        END LOOP;
        IF MOD(p_n, 2) = 1 THEN RETURN tmp((p_n + 1) / 2); END IF;
        RETURN (tmp(p_n / 2) + tmp(p_n / 2 + 1)) / 2;
    END;
    -- bucket i (0 = oldest): start / end
    FUNCTION b_start(p_i PLS_INTEGER) RETURN DATE IS
    BEGIN
        RETURN v_t1 - (v_nb - p_i) * v_bmin / 1440;
    END;
    FUNCTION b_end(p_i PLS_INTEGER) RETURN DATE IS
    BEGIN
        RETURN v_t1 - (v_nb - p_i - 1) * v_bmin / 1440;
    END;
    -- median of x over [p_a, p_b] (non-NULL points), NULL when fewer than 2
    FUNCTION med_x(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        v_ntmp := 0;
        FOR i IN GREATEST(p_a, 0) .. LEAST(p_b, v_nb - 1) LOOP
            IF x.EXISTS(i) AND x(i) IS NOT NULL THEN
                v_ntmp := v_ntmp + 1;
                tmp(v_ntmp) := x(i);
            END IF;
        END LOOP;
        IF v_ntmp < 2 THEN RETURN NULL; END IF;
        RETURN med_tmp(v_ntmp);
    END;
    -- Oracle PERCENTILE_CONT(p) over tmp(1 .. p_n), already sorted
    FUNCTION pct_tmp(p_n PLS_INTEGER, p_p NUMBER) RETURN NUMBER IS
        rn NUMBER := 1 + p_p * (p_n - 1);
        lo PLS_INTEGER := FLOOR(1 + p_p * (p_n - 1));
        hi PLS_INTEGER := CEIL(1 + p_p * (p_n - 1));
    BEGIN
        IF lo = hi THEN RETURN tmp(lo); END IF;
        RETURN (hi - rn) * tmp(lo) + (rn - lo) * tmp(hi);
    END;
    -- the normal of every row for normal p_mode: W = same hour of the week
    -- in the other weeks, D = same hour of the day on the other days (the
    -- row's own period excluded), F = every point before the Current
    -- window.  One group per (metric, phase), one sort per (metric, phase,
    -- excluded period), cached: a few thousand small sorts at most.
    PROCEDURE normals(p_mode VARCHAR2) IS
        v_m  NUMBER;
        v_np PLS_INTEGER;
        v_j  PLS_INTEGER;
    BEGIN
        v_grp.DELETE;
        v_cache.DELETE;
        FOR r IN 1 .. v_rows.COUNT LOOP
            v_rows(r).ph := CASE p_mode
                WHEN 'W' THEN (TRUNC(v_rows(r).tm) - TRUNC(v_rows(r).tm, 'IW')) * 24 + TO_NUMBER(TO_CHAR(v_rows(r).tm, 'HH24'))
                WHEN 'D' THEN TO_NUMBER(TO_CHAR(v_rows(r).tm, 'HH24'))
                ELSE 0 END;
            v_rows(r).per := CASE p_mode
                WHEN 'W' THEN TRUNC(v_rows(r).tm, 'IW') - DATE '2000-01-03'
                WHEN 'D' THEN TRUNC(v_rows(r).tm) - DATE '2000-01-03' END;
            v_gk := v_rows(r).ord || '|' || v_rows(r).ph;
            IF p_mode <> 'F' OR v_rows(r).tm < v_tc THEN
                IF NOT v_grp.EXISTS(v_gk) THEN
                    v_one.DELETE; v_one(1) := r; v_grp(v_gk) := v_one;
                ELSE
                    v_grp(v_gk)(v_grp(v_gk).COUNT + 1) := r;
                END IF;
            END IF;
        END LOOP;
        FOR r IN 1 .. v_rows.COUNT LOOP
            v_gk := v_rows(r).ord || '|' || v_rows(r).ph;
            v_key := v_gk || '|' || v_rows(r).per;
            IF v_cache.EXISTS(v_key) THEN
                v_j := v_cache(v_key);
                v_rows(r).med := v_rows(v_j).med; v_rows(r).q1 := v_rows(v_j).q1; v_rows(r).q3 := v_rows(v_j).q3;
                v_rows(r).n := v_rows(v_j).n; v_rows(r).np := v_rows(v_j).np;
            ELSE
                v_ntmp := 0;
                v_seen.DELETE;
                IF v_grp.EXISTS(v_gk) THEN
                    FOR k IN 1 .. v_grp(v_gk).COUNT LOOP
                        v_j := v_grp(v_gk)(k);
                        IF p_mode = 'F' OR v_rows(v_j).per <> v_rows(r).per THEN
                            v_ntmp := v_ntmp + 1;
                            tmp(v_ntmp) := v_rows(v_j).v;
                            IF v_rows(v_j).per IS NOT NULL THEN v_seen(TO_CHAR(v_rows(v_j).per)) := 1; END IF;
                        END IF;
                    END LOOP;
                END IF;
                v_rows(r).n := v_ntmp;
                v_rows(r).np := v_seen.COUNT;
                IF v_ntmp > 0 THEN
                    v_m := med_tmp(v_ntmp);      -- sorts tmp
                    v_rows(r).med := v_m;
                    v_rows(r).q1 := pct_tmp(v_ntmp, 0.25);
                    v_rows(r).q3 := pct_tmp(v_ntmp, 0.75);
                ELSE
                    v_rows(r).med := NULL; v_rows(r).q1 := NULL; v_rows(r).q3 := NULL;
                END IF;
                v_cache(v_key) := r;
            END IF;
        END LOOP;
    END;
    -- The change-point scan over zc (0 .. v_nb - 1): a two-sided CUSUM of
    -- the residual against the current LEVEL (0 = the seasonal normal).
    -- When S+ or S- passes c_h, a step is recorded: onset = the first
    -- judged point after that side last stood at zero, new level = the
    -- median residual from the onset to the detection (at least c_k
    -- beyond the old level), and both sums restart from the new level.
    -- So a shift on top of an earlier one is dated from its own start
    -- (a plain CUSUM stays saturated by the first).  NULL points hold.
    PROCEDURE cusum_scan IS
        v_sp NUMBER := 0;
        v_sm NUMBER := 0;
        v_dl NUMBER := 0;
        v_lp PLS_INTEGER := -1;
        v_lm PLS_INTEGER := -1;
        v_aa PLS_INTEGER;
        v_r  NUMBER;
    BEGIN
        cc.DELETE;
        v_ns := 0;
        FOR i IN 0 .. v_nb - 1 LOOP
            cc(i) := NULL;
            IF zc.EXISTS(i) AND zc(i) IS NOT NULL THEN
                v_r := zc(i) - v_dl;
                v_sp := GREATEST(0, v_sp + v_r - c_k);
                v_sm := GREATEST(0, v_sm - v_r - c_k);
                cc(i) := CASE WHEN v_sp >= v_sm THEN v_sp ELSE -v_sm END;
                IF v_sp = 0 THEN v_lp := i; END IF;
                IF v_sm = 0 THEN v_lm := i; END IF;
                IF v_sp > c_h OR v_sm > c_h THEN
                    v_aa := CASE WHEN v_sp > c_h THEN v_lp ELSE v_lm END + 1;
                    WHILE v_aa < i AND (NOT zc.EXISTS(v_aa) OR zc(v_aa) IS NULL) LOOP v_aa := v_aa + 1; END LOOP;
                    v_ntmp := 0;
                    FOR j IN v_aa .. i LOOP
                        IF zc.EXISTS(j) AND zc(j) IS NOT NULL THEN
                            v_ntmp := v_ntmp + 1; tmp(v_ntmp) := zc(j);
                        END IF;
                    END LOOP;
                    v_ns := v_ns + 1;
                    s_a(v_ns) := v_aa;
                    s_i(v_ns) := i;
                    s_dir(v_ns) := CASE WHEN v_sp > c_h THEN 1 ELSE -1 END;
                    s_old(v_ns) := v_dl;
                    s_new(v_ns) := CASE WHEN s_dir(v_ns) > 0 THEN GREATEST(med_tmp(v_ntmp), v_dl + c_k)
                                        ELSE LEAST(med_tmp(v_ntmp), v_dl - c_k) END;
                    v_dl := s_new(v_ns);
                    v_sp := 0; v_sm := 0; v_lp := i; v_lm := i;
                END IF;
            END IF;
        END LOOP;
    END;
    PROCEDURE app(p_clob IN OUT NOCOPY CLOB, p_buf IN OUT NOCOPY VARCHAR2, p_s VARCHAR2) IS
    BEGIN
        IF LENGTH(p_buf) + NVL(LENGTH(p_s), 0) > 30000 THEN
            DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_buf), p_buf);
            p_buf := NULL;
        END IF;
        p_buf := p_buf || p_s;
    END;
    PROCEDURE app_flush(p_clob IN OUT NOCOPY CLOB, p_buf IN OUT NOCOPY VARCHAR2) IS
    BEGIN
        IF p_buf IS NOT NULL THEN
            DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_buf), p_buf);
            p_buf := NULL;
        END IF;
    END;
    PROCEDURE app_clob(p_dst IN OUT NOCOPY CLOB, p_src IN OUT NOCOPY CLOB) IS
    BEGIN
        IF DBMS_LOB.GETLENGTH(p_src) > 0 THEN
            DBMS_LOB.APPEND(p_dst, p_src);
        END IF;
    END;
    FUNCTION glyph(p_dir NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p_dir > 0 THEN '&#9650;' ELSE '&#9660;' END;
    END;
    FUNCTION dir_word(p_dir NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p_dir > 0 THEN 'up' ELSE 'down' END;
    END;
BEGIN
    v_t0 := v_t1 - v_span_h / 24;
    v_tc := v_t1 - ~win_hours / 24;

    m_name(1) := 'DB time';        m_short(1) := 'DB time';        m_unit(1) := 'avg active sessions';
    m_name(2) := 'DB CPU';         m_short(2) := 'DB CPU';         m_unit(2) := 'avg CPUs busy';
    m_name(3) := 'User calls';     m_short(3) := 'user calls';     m_unit(3) := 'calls/s';
    m_name(4) := 'Executions';     m_short(4) := 'executions';     m_unit(4) := 'executions/s';
    m_name(5) := 'Logical reads';  m_short(5) := 'logical reads';  m_unit(5) := 'blocks/s';
    m_name(6) := 'Physical reads'; m_short(6) := 'physical reads'; m_unit(6) := 'blocks/s';
    m_name(7) := 'Redo';           m_short(7) := 'redo';           m_unit(7) := 'bytes/s';
    -- spread floor = the policy's materiality floor in the display unit
    -- (DB time / DB CPU: centiseconds per second x 0.01 = sessions)
    m_floor(1) := NVL(metric_policy('LOAD', 'DB time').min_abs, 0) * 0.01;
    m_floor(2) := NVL(metric_policy('LOAD', 'DB CPU').min_abs, 0) * 0.01;
    m_floor(3) := NVL(metric_policy('LOAD', 'user calls').min_abs, 0);
    m_floor(4) := NVL(metric_policy('LOAD', 'execute count').min_abs, 0);
    m_floor(5) := NVL(metric_policy('LOAD', 'session logical reads').min_abs, 0);
    m_floor(6) := NVL(metric_policy('LOAD', 'physical reads').min_abs, 0);
    m_floor(7) := NVL(metric_policy('LOAD', 'redo size').min_abs, 0);

    -- 1. the snapshot interval and the first pair of the span
    WITH
    @@sql/lib/onset_cte.sql
    SELECT MEDIAN(span_sec), COUNT(*), MIN(GREATEST(beg_dt, v_t0))
    INTO   v_ival, v_npairs, v_first
    FROM   on_pairs;

    IF v_npairs = 0 OR v_ival IS NULL OR v_ival <= 0 THEN
        DBMS_OUTPUT.PUT_LINE('<section id="onset" class="vw in-s in-t in-a lib" style="--os:15">' || v_h2);
        DBMS_OUTPUT.PUT_LINE('<p class="note">No usable snapshot pairs between '
            || TO_CHAR(v_t0, 'YYYY-MM-DD HH24:MI') || ' and ' || TO_CHAR(v_t1, 'YYYY-MM-DD HH24:MI')
            || ' (restarts, or no AWR history), so there is no series to date a change on.</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('onset', 'no snapshot pairs in the span'));
        RETURN;
    END IF;

    -- 2. the bucket grid: the snapshot interval, coarsened past 3000 points
    v_bmin := GREATEST(1, ROUND(v_ival / 60));
    v_m := CEIL((v_t1 - v_first) * 1440 / v_bmin / c_maxpts);
    IF v_m > 1 THEN
        v_mx := v_bmin * v_m;
        v_bmin := CASE WHEN v_mx <= 30 THEN 30 WHEN v_mx <= 60 THEN 60 WHEN v_mx <= 120 THEN 120
                       WHEN v_mx <= 180 THEN 180 WHEN v_mx <= 360 THEN 360 WHEN v_mx <= 720 THEN 720
                       ELSE 1440 * CEIL(v_mx / 1440) END;
    END IF;
    v_nb := GREATEST(1, CEIL((v_t1 - v_first) * 1440 / v_bmin - 1e-6));
    v_eff_d := v_nb * v_bmin / 1440;
    v_mode := CASE WHEN v_eff_d >= 21 THEN 'W' WHEN v_eff_d >= 3 THEN 'D' ELSE 'F' END;
    v_mode0 := v_mode;

    -- 3. the series (one scan), then its normal; again with the next
    --    coarser normal when fewer than half the points could be judged
    WITH
    @@sql/lib/onset_cte.sql
    ,
    -- each pair's rate over every bucket it overlaps (at most 4: a pair
    -- is at most 1.9 snapshot intervals, a bucket at least one), weighted
    -- by the overlap in seconds; bucket b = 0 ends at v_t1
    on_rate AS (
        SELECT d.stat_name, d.instance_number, pr.beg_dt, pr.end_dt,
               GREATEST(d.delta, 0) / pr.span_sec                       AS rate,
               FLOOR((v_t1 - pr.end_dt) * 1440 / v_bmin)                AS b_lo,
               CEIL((v_t1 - pr.beg_dt) * 1440 / v_bmin) - 1             AS b_hi
        FROM   on_deltas d
        JOIN   on_pairs pr
          ON   pr.dbid = d.dbid
         AND   pr.snap_id = d.snap_id
         AND   pr.instance_number = d.instance_number
         AND   pr.prev_snap_id = d.prev_snap_id
        WHERE  pr.span_sec <= 1.9 * v_ival
    ),
    on_raw AS (
        SELECT r.stat_name, r.instance_number, r.b_lo + g.k             AS b, r.rate,
               (LEAST(r.end_dt, v_t1 - (r.b_lo + g.k) * v_bmin / 1440)
                - GREATEST(r.beg_dt, v_t1 - (r.b_lo + g.k + 1) * v_bmin / 1440)) * 86400 AS ov
        FROM   on_rate r
        JOIN   (SELECT LEVEL - 1 AS k FROM dual CONNECT BY LEVEL <= 4) g
          ON   g.k <= r.b_hi - r.b_lo
        WHERE  r.b_lo + g.k BETWEEN 0 AND v_nb - 1
    ),
    -- per instance first (a time-weighted rate and its coverage), then the
    -- rates add up across instances; a bucket that no instance covers for
    -- half its length is a gap
    on_inst AS (
        SELECT stat_name, b, instance_number,
               SUM(rate * ov) / SUM(ov) AS rate, SUM(ov) AS cov
        FROM   on_raw
        WHERE  ov > 0
        GROUP BY stat_name, b, instance_number
    ),
    on_pts AS (
        SELECT stat_name, b,
               CASE WHEN MAX(cov) >= 0.5 * v_bmin * 60 THEN SUM(rate) END AS rate
        FROM   on_inst
        GROUP BY stat_name, b
    )
    SELECT t.ord, p.b, p.rate * t.scale, v_t1 - (p.b + 0.5) * v_bmin / 1440,
           NULL, NULL, NULL, NULL, NULL, NULL, NULL
    BULK COLLECT INTO v_rows
    FROM   on_pts p
    JOIN   on_targets t ON t.stat_name = p.stat_name
    WHERE  p.rate IS NOT NULL
    ORDER BY t.ord, p.b DESC;

    LOOP
        normals(v_mode);
        v_judged := 0;
        v_valued := v_rows.COUNT;
        FOR r IN 1 .. v_rows.COUNT LOOP
            IF v_rows(r).med IS NOT NULL
               AND ((v_mode = 'F' AND v_rows(r).n >= 8)
                    OR (v_mode <> 'F' AND v_rows(r).n >= 3 AND v_rows(r).np >= 2)) THEN
                v_judged := v_judged + 1;
            ELSE
                v_rows(r).med := NULL;
            END IF;
        END LOOP;
        EXIT WHEN v_mode = 'F' OR v_judged * 2 >= v_valued;
        -- the week is too thin: try the day, then the flat baseline
        v_mode := CASE v_mode WHEN 'W' THEN 'D' ELSE 'F' END;
    END LOOP;

    -- 4. per metric: dense arrays, residuals, the two CUSUMs, excursions
    v_rec := 1;
    FOR o IN 1 .. c_nmet LOOP
        x.DELETE; md.DELETE; sp.DELETE; zc.DELETE;
        m_thin(o) := 0; m_valn(o) := 0; m_jn(o) := 0; v_mx := 0;
        m_odir(o) := NULL; m_oon(o) := NULL; m_obase(o) := NULL; m_olev(o) := NULL;
        m_cdir(o) := NULL; m_con(o) := NULL; m_cend(o) := NULL; m_clev(o) := NULL;
        m_bef(o) := NULL; m_aft(o) := NULL; m_first(o) := NULL;
        FOR i IN 0 .. v_nb - 1 LOOP
            x(i) := NULL; md(i) := NULL; sp(i) := NULL; zc(i) := NULL;
        END LOOP;
        WHILE v_rec <= v_rows.COUNT AND v_rows(v_rec).ord = o LOOP
            v_a := v_nb - 1 - v_rows(v_rec).b;
            IF v_a BETWEEN 0 AND v_nb - 1 THEN
                x(v_a) := v_rows(v_rec).v;
                m_valn(o) := m_valn(o) + 1;
                v_mx := GREATEST(v_mx, ABS(v_rows(v_rec).v));
                IF v_rows(v_rec).med IS NOT NULL THEN
                    md(v_a) := v_rows(v_rec).med;
                    sp(v_a) := GREATEST(NVL(v_rows(v_rec).q3 - v_rows(v_rec).q1, 0) / 1.349,
                                        0.02 * ABS(v_rows(v_rec).med), m_floor(o));
                    IF sp(v_a) > 0 THEN
                        zc(v_a) := GREATEST(-c_clip, LEAST(c_clip, (x(v_a) - md(v_a)) / sp(v_a)));
                        m_jn(o) := m_jn(o) + 1;
                    END IF;
                END IF;
                IF zc(v_a) IS NULL THEN m_thin(o) := m_thin(o) + 1;
                ELSIF m_first(o) IS NULL OR v_a < m_first(o) THEN m_first(o) := v_a;
                END IF;
            END IF;
            v_rec := v_rec + 1;
        END LOOP;
        -- payload decimals: 4 significant digits on the metric's largest value
        m_dec(o) := CASE WHEN v_mx <= 0 THEN 0
                         ELSE GREATEST(0, LEAST(6, 3 - FLOOR(LOG(10, v_mx)))) END;

        IF m_jn(o) < 8 THEN
            m_st(o) := 'thin';
            CONTINUE;
        END IF;

        -- the Current window's median residual
        v_ntmp := 0;
        FOR i IN 0 .. v_nb - 1 LOOP
            IF zc(i) IS NOT NULL AND b_start(i) + v_bmin / 2880 >= v_tc THEN
                v_ntmp := v_ntmp + 1; tmp(v_ntmp) := zc(i);
            END IF;
        END LOOP;
        v_curz := med_tmp(v_ntmp);

        -- steps, then runs: a run = consecutive levels on the same side of
        -- the normal, more than c_k away.  The run still going at the end
        -- is the open shift when the Current window agrees (its median
        -- residual beyond c_k on that side); the latest finished run is
        -- the most recent closed excursion.
        cusum_scan;
        m_st(o) := 'none';
        v_rs := NULL; v_rsg := 0; v_rmax := 0; v_rlast := NULL;
        FOR k IN 1 .. v_ns LOOP
            IF v_rs IS NOT NULL AND (ABS(s_new(k)) <= c_k OR SIGN(s_new(k)) <> v_rsg) THEN
                m_cdir(o) := v_rsg; m_con(o) := v_rs; m_cend(o) := s_a(k) - 1; m_clev(o) := v_rmax;
                v_rs := NULL;
            END IF;
            IF ABS(s_new(k)) > c_k THEN
                IF v_rs IS NULL THEN
                    v_rs := s_a(k); v_rsg := SIGN(s_new(k)); v_rmax := 0;
                END IF;
                v_rmax := GREATEST(v_rmax, ABS(s_new(k)));
                -- the latest step that moved further away from the normal
                IF v_rsg * s_new(k) > v_rsg * s_old(k) THEN v_rlast := s_a(k); END IF;
            END IF;
        END LOOP;
        IF v_rs IS NOT NULL THEN
            IF v_curz IS NOT NULL AND v_rsg * v_curz > c_k THEN
                m_odir(o) := v_rsg; m_oon(o) := v_rlast; m_obase(o) := v_rs; m_olev(o) := s_new(v_ns);
            ELSE
                -- the level never stepped back, but the Current window is
                -- normal again: closed at the last point still beyond c_k
                v_e := v_rs;
                FOR i IN v_rs .. v_nb - 1 LOOP
                    IF zc(i) IS NOT NULL AND v_rsg * zc(i) > c_k THEN v_e := i; END IF;
                END LOOP;
                m_cdir(o) := v_rsg; m_con(o) := v_rs; m_cend(o) := v_e; m_clev(o) := v_rmax;
            END IF;
        END IF;
        IF m_odir(o) IS NOT NULL THEN
            m_st(o) := 'open';
            v_nopen := v_nopen + 1;
            m_aft(o) := med_x(m_oon(o), v_nb - 1);
            m_bef(o) := med_x(m_oon(o) - (v_nb - m_oon(o)), m_oon(o) - 1);
        ELSIF m_cend(o) IS NOT NULL THEN
            m_st(o) := 'closed';
            m_aft(o) := med_x(m_con(o), m_cend(o));
            m_bef(o) := med_x(m_con(o) - (m_cend(o) - m_con(o) + 1), m_con(o) - 1);
        END IF;
    END LOOP;

    -- the lead metric: DB time when it has an open shift, else the earliest
    -- open onset; with none open, the most recent closed excursion
    v_lead := NULL;
    FOR o IN 1 .. c_nmet LOOP
        IF m_st(o) = 'open' AND (v_lead IS NULL OR (v_lead <> 1 AND m_oon(o) < m_oon(v_lead))) THEN
            v_lead := o;
        END IF;
    END LOOP;
    IF v_lead IS NULL THEN
        FOR o IN 1 .. c_nmet LOOP
            IF m_st(o) = 'closed' AND (v_lead IS NULL OR m_cend(o) > m_cend(v_lead)) THEN
                v_lead := o;
            END IF;
        END LOOP;
    END IF;

    -- the sentence (Reads as, evidence library row)
    v_a := 0;
    FOR o IN 1 .. c_nmet LOOP
        IF m_st(o) = 'thin' THEN v_a := v_a + 1; END IF;
    END LOOP;
    IF v_a = c_nmet THEN
        v_sent := 'too few points to judge an onset: no metric has 8 points with a normal (the span holds '
            || v_nb || ' snapshot interval' || CASE WHEN v_nb = 1 THEN '' ELSE 's' END || ')';
        v_ls := 'too few points to date a change';
    ELSIF v_nopen > 0 THEN
        -- c_mk: the client writes the marker relation there ("(2 h after
        -- Release 4.2)"); the library row text goes without it
        v_sent := '<b>' || m_short(v_lead) || '</b> '
            || CASE WHEN m_oon(v_lead) = m_first(v_lead)
                    THEN 'was already ' || dir_word(m_odir(v_lead)) || ' at the first point of the span ('
                         || dt_txt(b_start(m_oon(v_lead))) || ') and still is: the shift began before what this span can see'
                    WHEN b_start(m_oon(v_lead)) >= v_tc
                    THEN 'shifted ' || dir_word(m_odir(v_lead)) || ' from ' || hm_txt(b_start(m_oon(v_lead)))
                         || c_mk || ', inside the Current window'
                    ELSE 'shifted ' || dir_word(m_odir(v_lead)) || ' from ' || dt_txt(b_start(m_oon(v_lead)))
                         || c_mk || ', about ' || dur_txt((v_tc - b_start(m_oon(v_lead))) * 1440)
                         || ' before the Current window; sustained since' END;
        v_ls := REPLACE(v_sent, c_mk);
        IF m_obase(v_lead) < m_oon(v_lead) THEN
            v_sent := v_sent || ', on top of an earlier shift ' || dir_word(m_odir(v_lead)) || ' from '
                || CASE WHEN m_obase(v_lead) = m_first(v_lead) THEN 'the start of the span, ' END
                || dt_txt(b_start(m_obase(v_lead)));
        END IF;
        IF v_mode = 'F' THEN
            v_sent := v_sent || ' (against a flat baseline, so a daily rhythm can read as a shift)';
        END IF;
        IF v_nopen > 1 THEN
            v_buf := NULL;
            FOR o IN 1 .. c_nmet LOOP
                IF m_st(o) = 'open' AND o <> v_lead THEN
                    v_buf := v_buf || CASE WHEN v_buf IS NOT NULL THEN ', ' END || m_short(o) || ' '
                        || glyph(m_odir(o));
                END IF;
            END LOOP;
            v_sent := v_sent || '. Also open (onsets in the table): ' || v_buf;
            v_ls := v_ls || ' (+' || (v_nopen - 1) || ' more)';
        END IF;
    ELSE
        v_sent := 'no open shift: the Current window is not part of a sustained change';
        v_ls := 'no open shift';
        IF v_lead IS NOT NULL THEN
            v_sent := v_sent || '. The most recent excursion: ' || m_short(v_lead) || ' '
                || dir_word(m_cdir(v_lead)) || ' from '
                || CASE WHEN m_con(v_lead) = m_first(v_lead) THEN 'the start of the span, ' END
                || dt_txt(b_start(m_con(v_lead))) || c_mk
                || ' to ' || CASE WHEN TRUNC(b_end(m_cend(v_lead))) = TRUNC(b_start(m_con(v_lead)))
                                  THEN hm_txt(b_end(m_cend(v_lead)))
                                  ELSE dt_txt(b_end(m_cend(v_lead))) END;
            v_ls := v_ls || '; last: ' || m_short(v_lead) || ' ' || dir_word(m_cdir(v_lead))
                || ' ' || dt_txt(b_start(m_con(v_lead)));
        END IF;
    END IF;

    -- the phase used (caption + note)
    v_phase := CASE v_mode
        WHEN 'W' THEN 'Normal = the median of the same hour of the week in the other weeks of the span'
        WHEN 'D' THEN 'Normal = the median of the same hour of the day on the other days of the span'
             || CASE WHEN v_mode0 = 'W' THEN ' (the same hour of the week: fewer than half the points had '
                     || '3 same-hour points from 2 other weeks)' END
        ELSE 'Normal = the median of every point before the Current window (a flat baseline: '
             || CASE WHEN v_mode0 = 'F'
                     THEN 'the span, ' || dur_txt(v_eff_d * 1440) || ', is too short for a seasonal normal, which needs 3 days'
                     ELSE 'fewer than half the points had 3 same-hour points from 2 other '
                          || CASE v_mode0 WHEN 'W' THEN 'weeks' ELSE 'days' END END
             || ')' END
        || '; band = normal &plusmn; 2 spreads, spread = interquartile range / 1.349, at least 2% of the '
        || 'median and the metric''s materiality floor. One point per ' || dur_txt(v_bmin) || '.';
    v_phs := CASE v_mode
        WHEN 'W' THEN 'Normal = same hour of the week, other weeks'
        WHEN 'D' THEN 'Normal = same hour of the day, other days'
             || CASE WHEN v_mode0 = 'W' THEN ' (too few same-hour weeks)' END
        ELSE 'Normal = flat baseline before the Current window (no seasonal normal: '
             || CASE WHEN v_mode0 = 'F' THEN 'span under 3 days' ELSE 'too little same-hour history' END || ')' END
        || '; band &plusmn; 2 spreads; one point per ' || dur_txt(v_bmin) || '.';

    -- a section with an open shift opens its evidence-library row
    DBMS_OUTPUT.PUT_LINE('<section id="onset" class="vw in-s in-t in-a lib'
        || CASE WHEN v_nopen > 0 THEN ' lopen' END || '" style="--os:15">' || v_h2);

    -- the chart (built by the client script; hidden until it runs)
    v_html := '<div class="onset-viz" hidden><div class="onset-pick" role="tablist" aria-label="Onset metric">';
    FOR o IN 1 .. c_nmet LOOP
        v_html := v_html || '<button type="button" class="onset-b" role="tab" id="onset-b' || (o - 1)
            || '" data-i="' || (o - 1) || '" aria-controls="onset-plot" aria-selected="'
            || CASE WHEN o = NVL(v_lead, 1) THEN 'true" tabindex="0"' ELSE 'false" tabindex="-1"' END
            || '><span class="onset-bn">' || m_name(o) || '</span><span class="onset-bs">'
            || CASE m_st(o)
                   WHEN 'open'   THEN '<i class="onset-d crit" aria-hidden="true"></i>' || glyph(m_odir(o))
                                      || ' open since ' || ds_txt(b_start(m_oon(o)))
                   WHEN 'closed' THEN '<i class="onset-d warn" aria-hidden="true"></i>' || glyph(m_cdir(o))
                                      || ' closed, ended ' || ds_txt(b_end(m_cend(o)))
                   WHEN 'none'   THEN '<i class="onset-d ok" aria-hidden="true"></i>no shift'
                   ELSE '<i class="onset-d" aria-hidden="true"></i>too little history' END
            || '</span></button>';
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(v_html || '</div>');
    DBMS_OUTPUT.PUT_LINE('<div class="onset-lg" aria-hidden="true"><span><i class="onset-k k-ln"></i>observed</span>'
        || '<span><i class="onset-k k-md"></i>normal</span><span><i class="onset-k k-bd"></i>normal range</span>'
        || '<span><i class="onset-k k-lv"></i>step found by the scan</span>'
        || '<span><i class="onset-k k-cw"></i>Current window</span><span><i class="onset-k k-pw"></i>compared windows</span>'
        || '<span><i class="onset-k k-mk"></i>release marker</span><span><i class="onset-k k-on"></i>detected onset</span>'
        || '<span><i class="onset-k k-cu"></i>CUSUM, upward</span><span><i class="onset-k k-cd"></i>CUSUM, downward</span></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="onset-plot" id="onset-plot" role="tabpanel" tabindex="0" aria-label="The picked metric over the span"></div>');
    DBMS_OUTPUT.PUT_LINE('<p class="onset-cap">' || v_phs || ' CUSUM strip in spreads against the current level: '
        || 'residuals clipped to &plusmn;3, slack 0.5, a step counts past 5 and restarts it. Arrow keys move the cursor.</p></div>');
    DBMS_OUTPUT.PUT_LINE('<p class="onset-rd"><b>Reads as:</b> <span class="onset-s">' || v_sent || '</span>.</p>');

    -- the table: every number the chart dates
    IF v_a < c_nmet THEN
        DBMS_OUTPUT.PUT_LINE('<table class="onset-tbl" data-nocount><thead><tr><th>Metric</th><th>Status</th>'
            || '<th>Onset</th><th>Ended</th><th class="num">Before</th><th class="num">After</th>'
            || '<th class="num">Lasted</th><th class="num">Level shift</th><th class="num">Points judged</th></tr></thead><tbody>');
        FOR o IN 1 .. c_nmet LOOP
            v_html := '<tr data-i="' || (o - 1) || '"><td>' || m_name(o) || ' <small>' || m_unit(o) || '</small></td>';
            IF m_st(o) = 'open' THEN
                v_html := v_html || '<td><i class="onset-d crit" aria-hidden="true"></i>' || glyph(m_odir(o))
                    || ' open, ' || dir_word(m_odir(o)) || '</td>'
                    || '<td>' || CASE WHEN m_oon(o) = m_first(o) THEN 'at or before ' END
                    || dt_txt(b_start(m_oon(o)))
                    || CASE WHEN m_obase(o) < m_oon(o) THEN '<br><small>on top of a shift from '
                            || dt_txt(b_start(m_obase(o))) || '</small>' END
                    || '</td><td>still open</td>'
                    || '<td class="num">' || fmt_num(m_bef(o)) || '</td><td class="num">' || fmt_num(m_aft(o)) || '</td>'
                    || '<td class="num">' || dur_txt((v_t1 - b_start(m_oon(o))) * 1440) || '</td>'
                    || '<td class="num">' || TO_CHAR(m_olev(o), 'FMS990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' spreads</td>';
            ELSIF m_st(o) = 'closed' THEN
                v_html := v_html || '<td><i class="onset-d warn" aria-hidden="true"></i>' || glyph(m_cdir(o))
                    || ' closed, ' || dir_word(m_cdir(o)) || '</td>'
                    || '<td>' || CASE WHEN m_con(o) = m_first(o) THEN 'at or before ' END
                    || dt_txt(b_start(m_con(o))) || '</td><td>' || dt_txt(b_end(m_cend(o))) || '</td>'
                    || '<td class="num">' || fmt_num(m_bef(o)) || '</td><td class="num">' || fmt_num(m_aft(o)) || '</td>'
                    || '<td class="num">' || dur_txt((b_end(m_cend(o)) - b_start(m_con(o))) * 1440) || '</td>'
                    || '<td class="num">' || TO_CHAR(m_cdir(o) * m_clev(o), 'FMS990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' spreads</td>';
            ELSE
                v_html := v_html || '<td>' || CASE m_st(o) WHEN 'none'
                        THEN '<i class="onset-d ok" aria-hidden="true"></i>no shift'
                        ELSE '<i class="onset-d" aria-hidden="true"></i>too little history' END
                    || '</td><td>&mdash;</td><td>&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td>'
                    || '<td class="num">&mdash;</td><td class="num">&mdash;</td>';
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_html || '<td class="num">' || fmt_int(m_jn(o)) || ' of ' || fmt_int(m_valn(o)) || '</td></tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    END IF;
    v_a := 0;
    v_e := 0;
    FOR o IN 1 .. c_nmet LOOP
        v_a := v_a + m_thin(o);
        v_e := v_e + m_valn(o);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('<p class="note onset-note">' || v_phase || ' '
        || CASE WHEN v_a = 0 THEN 'Every point with a value had enough history to judge.'
                ELSE fmt_int(v_a) || ' of ' || fmt_int(v_e) || ' points (all metrics) had too little history to judge ('
                     || CASE WHEN v_mode = 'F' THEN 'fewer than 8 baseline points'
                             ELSE 'fewer than 3 same-hour points from 2 other ' || CASE v_mode WHEN 'W' THEN 'weeks' ELSE 'days' END END
                     || '); the CUSUM holds across them and across gaps.' END
        || ' Before / After = median level in as many points before the onset as the shift lasted, and since; '
        || 'Level shift = the level the change-point scan settled on, in spreads from the normal.</p>');

    -- 5. the payload: AWR_DATA.onset = {t1, bm, nb, tc, mode, k, h, lead,
    --    m:[{n, u, d, st, on:[onset, base, dir], cl:[onset, end, dir],
    --    sp:[[onset, detected, dir, level x 10], ...], x, md, s, c}]} --
    --    indices = buckets, oldest first; arrays: an empty slot = no value;
    --    c = the CUSUM in tenths, S+ positive, S- negative
    DBMS_LOB.CREATETEMPORARY(v_json, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_cx, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_cmd, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_csp, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_cc, TRUE);
    v_buf := '{t1:"' || TO_CHAR(v_t1, 'YYYY-MM-DD HH24:MI') || '",bm:' || v_bmin || ',nb:' || v_nb
        || ',tc:"' || TO_CHAR(v_tc, 'YYYY-MM-DD HH24:MI') || '",mode:"' || v_mode || '",k:0.5,h:5,lead:'
        || CASE WHEN v_lead IS NULL THEN 'null' ELSE TO_CHAR(v_lead - 1) END || ',m:[';
    v_rec := 1;
    FOR o IN 1 .. c_nmet LOOP
        -- rebuild the metric's arrays (cheap: one pass over its rows)
        x.DELETE; md.DELETE; sp.DELETE; zc.DELETE;
        WHILE v_rec <= v_rows.COUNT AND v_rows(v_rec).ord = o LOOP
            v_e := v_nb - 1 - v_rows(v_rec).b;
            x(v_e) := v_rows(v_rec).v;
            IF v_rows(v_rec).med IS NOT NULL THEN
                md(v_e) := v_rows(v_rec).med;
                sp(v_e) := GREATEST(NVL(v_rows(v_rec).q3 - v_rows(v_rec).q1, 0) / 1.349,
                                    0.02 * ABS(v_rows(v_rec).med), m_floor(o));
                IF sp(v_e) > 0 THEN
                    zc(v_e) := GREATEST(-c_clip, LEAST(c_clip, (x(v_e) - md(v_e)) / sp(v_e)));
                END IF;
            END IF;
            v_rec := v_rec + 1;
        END LOOP;
        app(v_json, v_buf, CASE WHEN o > 1 THEN ',' END || '{n:"' || m_name(o) || '",u:"' || m_unit(o)
            || '",d:' || m_dec(o) || ',st:"' || m_st(o) || '",on:'
            || CASE WHEN m_st(o) = 'open' THEN '[' || m_oon(o) || ',' || m_obase(o) || ',' || m_odir(o) || ']' ELSE 'null' END
            || ',cl:'
            || CASE WHEN m_cend(o) IS NOT NULL THEN '[' || m_con(o) || ',' || m_cend(o) || ',' || m_cdir(o) || ']' ELSE 'null' END
            || ',sp:[');
        IF m_st(o) <> 'thin' THEN
            cusum_scan;
            FOR k IN 1 .. v_ns LOOP
                app(v_json, v_buf, CASE WHEN k > 1 THEN ',' END || '[' || s_a(k) || ',' || s_i(k) || ','
                    || s_dir(k) || ',' || TO_CHAR(ROUND(s_new(k) * 10)) || ']');
            END LOOP;
        ELSE
            cc.DELETE;
        END IF;
        app(v_json, v_buf, ']');
        -- four arrays, one pass: x / md / s / c each into its own CLOB
        DBMS_LOB.TRIM(v_cx, 0); DBMS_LOB.TRIM(v_cmd, 0); DBMS_LOB.TRIM(v_csp, 0); DBMS_LOB.TRIM(v_cc, 0);
        v_sx := ',x:['; v_smd := '],md:['; v_ssp := '],s:['; v_sc := '],c:[';
        FOR i IN 0 .. v_nb - 1 LOOP
            v_tok := CASE WHEN i > 0 THEN ',' END;
            app(v_cx, v_sx, v_tok || CASE WHEN x.EXISTS(i) THEN tok(x(i), m_dec(o)) END);
            app(v_cmd, v_smd, v_tok || CASE WHEN md.EXISTS(i) THEN tok(md(i), m_dec(o)) END);
            app(v_csp, v_ssp, v_tok || CASE WHEN sp.EXISTS(i) THEN tok(sp(i), m_dec(o) + 1) END);
            app(v_cc, v_sc, v_tok || CASE WHEN cc.EXISTS(i) AND cc(i) IS NOT NULL THEN TO_CHAR(ROUND(cc(i) * 10)) END);
        END LOOP;
        app_flush(v_cx, v_sx); app_flush(v_cmd, v_smd); app_flush(v_csp, v_ssp);
        app(v_cc, v_sc, ']}');
        app_flush(v_cc, v_sc);
        app_flush(v_json, v_buf);
        app_clob(v_json, v_cx); app_clob(v_json, v_cmd); app_clob(v_json, v_csp); app_clob(v_json, v_cc);
    END LOOP;
    app(v_json, v_buf, ']}');
    app_flush(v_json, v_buf);
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.onset=');
    put_clob_chunked(v_json);
    DBMS_OUTPUT.PUT_LINE(';</script>');
    DBMS_LOB.FREETEMPORARY(v_json);
    DBMS_LOB.FREETEMPORARY(v_cx); DBMS_LOB.FREETEMPORARY(v_cmd);
    DBMS_LOB.FREETEMPORARY(v_csp); DBMS_LOB.FREETEMPORARY(v_cc);

    DBMS_OUTPUT.PUT_LINE(lib_ls('onset', v_ls));
END;
/

@@sql/lib/js_onset.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('</section>'); END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 25_onset END -->'); END;
/
