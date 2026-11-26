--
-- 30_host_memory.sql
-- "Host and memory" (plan 046): was the HOST out of CPU or swapping, did
-- memory change under the workload, any ORA-01555 / undo pressure, which
-- statement used the temp space and the PGA.  Four blocks, each a table in
-- section 13's house style (Current, the band cells with a NULL bucket, a
-- plain delta, a micro strip, one column per prior window).  Explains
-- only: nothing here is scored, counted or tinted.
--
-- Windows.  A window is KNOWN only when every instance row of it is valid
-- (plan 042's rule, section 09): the host and memory values are summed
-- over the instances, so a RAC window with one instance skipped would
-- read as a smaller host or a shrunken buffer cache.  Unknown windows are
-- empty slots (never 0) and stay out of the prior mean.
--
-- Sources and kinds (19c Reference; plans/046-host-memory-undo-temp.md):
--   DBA_HIST_OSSTAT (stat_name / value per snapshot and instance):
--     counters, hundredths of a second summed over CPUs: BUSY_TIME,
--       IDLE_TIME, USER_TIME, SYS_TIME, NICE_TIME, IOWAIT_TIME,
--       RSRC_MGR_CPU_WAIT_TIME; bytes: VM_IN_BYTES, VM_OUT_BYTES
--       -> end minus begin of the window's snapshot pair (valid windows
--       have no restart inside), summed over the instances;
--     gauges at the END snapshot: LOAD (the max over instances),
--       FREE_MEMORY_BYTES (not in the 19c Reference; shown when reported);
--     configuration at the END snapshot: NUM_CPUS, NUM_CPU_CORES,
--       NUM_CPU_SOCKETS, PHYSICAL_MEMORY_BYTES (summed; a change across
--       the windows is said in a note).
--   DBA_HIST_PGASTAT (name / value): gauges at the END snapshot 'total PGA
--     allocated', 'total PGA inuse'; configuration 'aggregate PGA target
--     parameter'; counter 'over allocation count'.  'cache hit percentage'
--     and 'maximum PGA allocated' are since instance startup: left out.
--   DBA_HIST_MEM_DYNAMIC_COMP (component / current_size): gauges at the
--     END snapshot, matched case-insensitively ('DEFAULT buffer cache',
--     'shared pool', 'large pool', 'SGA Target', 'PGA Target').
--   DBA_HIST_MEMORY_RESIZE_OPS: GROW / SHRINK operations that STARTED in
--     the Current window, bounded by dbid, instance and start_time only,
--     duplicates collapsed (DISTINCT over the natural key).
--   DBA_HIST_UNDOSTAT: 10-minute rows by begin_time / end_time, NOT
--     snapshot deltas.  A row counts toward every window it overlaps; per
--     (begin_time, con_id) the duplicates collapse (MAX), the containers
--     are summed (with local undo each PDB has its own undo tablespace);
--     rates are over the rows' covered time.  Per window: sums of the
--     counts, maxima of the maxima, the lowest tuned retention.
--   DBA_HIST_ACTIVE_SESS_HISTORY (required grant, static SQL): the temp /
--     PGA block, one bounded scan joined to valid_windows (section 24 / 29).
--   DBA_HIST_SYS_TIME_MODEL 'DB CPU' (required): the database's share of
--     the host's busy CPU, a small private read (section 09's idiom).
-- Per-container fan-out: OSSTAT, PGASTAT and MEM_DYNAMIC_COMP carry CON_ID;
-- the lowest con_id wins (the instance-level row, as section 12 does).
--
-- Optional grants.  OSSTAT, PGASTAT, MEM_DYNAMIC_COMP, MEMORY_RESIZE_OPS and
-- UNDOSTAT are not in the README's required list: each is read only
-- through dynamic SQL in its own block.  ORA-00942 / ORA-01031 -> "needs
-- SELECT on <view>"; ANY other error of that read -> "could not read
-- <view>: <message>" (a deliberate exception to the -942 / -1031-only
-- rule: these numbers are cosmetic to the rest of the report, so a wrong
-- name or an odd platform must never abort it).  Every read happens before
-- any markup is printed, so a failure never leaves a tag open.
--
-- Card pointers (relocation pattern, plan 043's append): the Physical I/O
-- card (#f-io) gets "Memory: buffer cache ..." when the Current buffer
-- cache is at least 10% below the prior mean; the DB time card
-- (#f-dbtime) "Host: CPU n% busy" at 90% or more and "Host: swapping"
-- when the Current window paged out at least c_swap (0.01 MB/s, about
-- 36 MB an hour; a few bytes a second is no swapping).  Plain, hollow dot,
-- "not scored", a link to the section's row.
--
-- Read-only: SELECT only.  Explains only: no finding, count or severity.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 30_host_memory BEGIN -->'); END;
/

DECLARE
    TYPE t_ntab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_stab IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    TYPE t_dtab IS TABLE OF DATE INDEX BY PLS_INTEGER;
    TYPE t_kn   IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    TYPE t_ks   IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(200);

    c_gb     CONSTANT NUMBER := 1073741824;
    c_mb     CONSTANT NUMBER := 1048576;
    c_busy   CONSTANT NUMBER := 90;          -- host CPU busy %: stands out
    c_swap   CONSTANT NUMBER := 0.01;        -- MB/s paged out in the Current window: swapping (about 36 MB an hour)
    c_bcdrop CONSTANT NUMBER := 0.9;         -- buffer cache at most 90% of the prior mean
    c_top    CONSTANT PLS_INTEGER := 5;      -- statements per temp / PGA table
    c_rsmax  CONSTANT PLS_INTEGER := 20;     -- resize operations listed

    -- the instance rows of the KNOWN windows (every instance row valid)
    i_n      PLS_INTEGER := 0;
    i_wk     t_ntab;
    i_dbid   t_ntab;
    i_inst   t_ntab;
    i_bs     t_ntab;
    i_es     t_ntab;
    i_dur    t_ntab;
    i_t0     t_dtab;
    i_t1     t_dtab;

    -- per window (week_offset)
    w_all    t_ntab;
    w_ok     t_ntab;
    w_known  t_stab;                         -- 'Y' = every instance row valid
    w_dur    t_ntab;                         -- MAX(dur_sec) over its instances
    w_lab    t_stab;                         -- 'Thu 16 Jul 09:00' (the window's start)
    w_skip   t_stab;
    v_np     PLS_INTEGER := 0;               -- known prior windows
    v_curok  BOOLEAN := FALSE;
    v_ninst  PLS_INTEGER := 0;

    -- raw accumulators per view: 'name|wk' -> value / instances that reported it
    os_a     t_kn;  os_c  t_kn;
    pg_a     t_kn;  pg_c  t_kn;
    mc_a     t_kn;  mc_c  t_kn;
    un_a     t_kn;  un_c  t_kn;
    un_q     t_ks;                           -- wk -> sql_id of the longest query
    un_ql    t_kn;                           -- wk -> its length
    tm_a     t_kn;  tm_c  t_kn;              -- DB CPU (s)
    as_a     t_kn;                           -- ASH peaks 'tp|wk', 'pp|wk'
    as_q     t_kn;                           -- ASH 'T|sql|wk', 'P|sql|wk' statement maxima
    as_seen  t_ks;                           -- 'sql|wk' -> 'Y'
    v_ash_ok BOOLEAN := FALSE;

    -- read status per view: NULL ok, 'G' no grant, else the error text
    e_os     VARCHAR2(400);
    e_pg     VARCHAR2(400);
    e_mc     VARCHAR2(400);
    e_rs     VARCHAR2(400);
    e_un     VARCHAR2(400);

    -- the resize operations inside the Current window
    rs_n     PLS_INTEGER := 0;
    rs_tot   PLS_INTEGER := 0;
    rs_comp  t_stab;
    rs_op    t_stab;
    rs_mode  t_stab;
    rs_ini   t_ntab;
    rs_tgt   t_ntab;
    rs_fin   t_ntab;
    rs_st    t_stab;
    rs_t0    t_dtab;
    rs_t1    t_dtab;
    rs_inst  t_ntab;

    -- the Current window's top statements by temp / PGA
    tq_t     t_stab;                         -- rank -> sql_id (temp)
    tq_p     t_stab;                         -- rank -> sql_id (PGA)

    -- the rows: code, block, label, unit, title, divisor of the raw value
    r_n      PLS_INTEGER := 0;
    r_code   t_stab;
    r_blk    t_stab;
    r_lab    t_stab;
    r_unit   t_stab;
    r_ttl    t_stab;
    r_on     t_stab;                         -- 'Y' = a value in some known window
    v_v      t_kn;                           -- 'code|wk' -> display value
    v_mu     t_kn;
    v_sd     t_kn;
    v_nn     t_kn;

    -- dynamic SQL
    v_rc     SYS_REFCURSOR;
    v_sql    VARCHAR2(4000);
    v_nm     t_stab;
    v_b      t_ntab;
    v_e      t_ntab;
    v_x1 NUMBER; v_x2 NUMBER; v_x3 NUMBER; v_x4 NUMBER; v_x5 NUMBER;
    v_x6 NUMBER; v_x7 NUMBER; v_x8 NUMBER; v_x9 NUMBER;
    v_xq     VARCHAR2(30);
    v_c1 VARCHAR2(200); v_c2 VARCHAR2(200); v_c3 VARCHAR2(200); v_c4 VARCHAR2(200);
    v_d1 DATE; v_d2 DATE;

    -- output
    v_hdr    VARCHAR2(32767);
    v_row    VARCHAR2(32767);
    v_csv    VARCHAR2(32767);
    v_rd     VARCHAR2(32767);
    v_ls     VARCHAR2(32767);
    v_why    VARCHAR2(4000);
    v_chg    VARCHAR2(32767);
    v_cfg    VARCHAR2(4000);
    v_miss   VARCHAR2(4000);
    v_ev_io  VARCHAR2(32767);
    v_ev_dbt VARCHAR2(32767);
    v_open   BOOLEAN := FALSE;
    v_k      VARCHAR2(200);
    v_val    NUMBER;
    v_prev   NUMBER;
    v_pwk    PLS_INTEGER;
    v_cur    NUMBER;
    v_m      NUMBER;
    v_s      NUMBER;
    v_pts    NUMBER;
    v_med    t_ntab;
    v_t      NUMBER;
    v_ss     NUMBER;
    v_n      PLS_INTEGER;
    v_i      PLS_INTEGER;
    v_blkx   VARCHAR2(1);

    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql

    -- a 6-decimal number token for data-* / data-spark (dot decimal)
    FUNCTION wt(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN NULL; END IF;
        RETURN TO_CHAR(ROUND(p, 6), 'FM99999999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END wt;

    -- bytes as text: "46 GB", "512 MB", "40 KB", "0 B"
    FUNCTION by_txt(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        IF p >= c_gb THEN RETURN fmt_num(p / c_gb) || '&nbsp;GB'; END IF;
        IF p >= c_mb THEN RETURN fmt_num(p / c_mb) || '&nbsp;MB'; END IF;
        IF p >= 1024 THEN RETURN fmt_num(p / 1024) || '&nbsp;KB'; END IF;
        RETURN fmt_num(p) || '&nbsp;B';
    END by_txt;

    -- a window's short label, its start: "Thu 16 Jul 09:00"
    FUNCTION wl(p_wk PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN w_lab.EXISTS(p_wk) THEN w_lab(p_wk) END;
    END wl;

    -- the error note of a view: NULL when it was read
    FUNCTION err_note(p_err VARCHAR2, p_view VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_err IS NULL THEN RETURN NULL; END IF;
        IF p_err = 'G' THEN RETURN 'needs SELECT on <code>' || p_view || '</code>'; END IF;
        RETURN 'could not read <code>' || p_view || '</code>: ' || DBMS_XMLGEN.CONVERT(p_err);
    END err_note;

    -- accumulate one instance's value of name p_k in window p_wk
    -- (p_how 'S' sum, 'X' max over the instances, 'N' min)
    PROCEDURE acc(p_a IN OUT NOCOPY t_kn, p_c IN OUT NOCOPY t_kn,
                  p_k VARCHAR2, p_wk PLS_INTEGER, p_v NUMBER, p_how VARCHAR2) IS
        v_key VARCHAR2(200) := p_k || '|' || p_wk;
    BEGIN
        IF p_v IS NULL THEN RETURN; END IF;
        IF NOT p_a.EXISTS(v_key) THEN
            p_a(v_key) := p_v; p_c(v_key) := 1;
        ELSE
            p_a(v_key) := CASE p_how WHEN 'X' THEN GREATEST(p_a(v_key), p_v)
                                     WHEN 'N' THEN LEAST(p_a(v_key), p_v)
                                     ELSE p_a(v_key) + p_v END;
            p_c(v_key) := p_c(v_key) + 1;
        END IF;
    END acc;

    -- the window's value of name p_k: known only when EVERY instance of the
    -- window reported it
    FUNCTION got(p_a t_kn, p_c t_kn, p_k VARCHAR2, p_wk PLS_INTEGER) RETURN NUMBER IS
        v_key VARCHAR2(200) := p_k || '|' || p_wk;
    BEGIN
        IF NOT p_a.EXISTS(v_key) OR NOT w_ok.EXISTS(p_wk) THEN RETURN NULL; END IF;
        IF p_c(v_key) < w_ok(p_wk) THEN RETURN NULL; END IF;
        RETURN p_a(v_key);
    END got;

    FUNCTION rdiv(p_a NUMBER, p_b NUMBER) RETURN NUMBER IS
    BEGIN
        IF p_a IS NULL OR p_b IS NULL OR p_b = 0 THEN RETURN NULL; END IF;
        RETURN p_a / p_b;
    END rdiv;

    PROCEDURE add_row(p_code VARCHAR2, p_blk VARCHAR2, p_lab VARCHAR2, p_unit VARCHAR2, p_ttl VARCHAR2) IS
    BEGIN
        r_n := r_n + 1;
        r_code(r_n) := p_code; r_blk(r_n) := p_blk; r_lab(r_n) := p_lab;
        r_unit(r_n) := p_unit; r_ttl(r_n) := p_ttl; r_on(r_n) := 'N';
    END add_row;

    PROCEDURE put(p_code VARCHAR2, p_wk PLS_INTEGER, p_v NUMBER) IS
    BEGIN
        IF p_v IS NOT NULL THEN v_v(p_code || '|' || p_wk) := p_v; END IF;
    END put;

    FUNCTION vv(p_code VARCHAR2, p_wk PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF v_v.EXISTS(p_code || '|' || p_wk) THEN RETURN v_v(p_code || '|' || p_wk); END IF;
        RETURN NULL;
    END vv;

    FUNCTION mu_of(p_code VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF v_mu.EXISTS(p_code) THEN RETURN v_mu(p_code); END IF;
        RETURN NULL;
    END mu_of;

    -- one table row of row index i
    FUNCTION row_html(i PLS_INTEGER) RETURN VARCHAR2 IS
        v_c   VARCHAR2(30) := r_code(i);
        v_out VARCHAR2(32767);
        v_sp  VARCHAR2(32767);
        v_cv  NUMBER := vv(r_code(i), 0);
        v_mx  NUMBER := mu_of(r_code(i));
        v_sx  NUMBER := CASE WHEN v_sd.EXISTS(r_code(i)) THEN v_sd(r_code(i)) END;
        v_nx  NUMBER := CASE WHEN v_nn.EXISTS(r_code(i)) THEN v_nn(r_code(i)) ELSE 0 END;
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_sp := v_sp || CASE WHEN k < ~weeks_back THEN ',' END || wt(vv(v_c, k));
        END LOOP;
        v_out := '<tr id="' || anchor_id('hm', v_c) || '" data-cur="' || wt(v_cv) || '" data-mu="' || wt(v_mx)
            || '" data-n="' || v_nx || '"><td><span title="' || r_ttl(i) || '">' || r_lab(i) || '</span></td>'
            || '<td>' || r_unit(i) || '</td>'
            || '<td class="num" data-w="0"' || fmt_num_title(v_cv) || '><b>' || fmt_num(v_cv) || '</b></td>'
            || band_cells(v_cv, v_mx, v_sx, v_nx, NULL, 'N', NULL, 'Y')
            || '<td class="trend" data-spark="' || v_sp || '" data-spark-title="' || r_lab(i) || '"></td>';
        FOR k IN 1 .. ~weeks_back LOOP
            v_out := v_out || '<td class="num" data-w="' || k || '">' || fmt_num(vv(v_c, k)) || '</td>';
        END LOOP;
        RETURN v_out || '</tr>';
    END row_html;

    -- the table of block p_b (rows that have a value somewhere)
    PROCEDURE put_table(p_b VARCHAR2, p_id VARCHAR2) IS
        v_any BOOLEAN := FALSE;
    BEGIN
        FOR i IN 1 .. r_n LOOP
            IF r_blk(i) = p_b AND r_on(i) = 'Y' THEN v_any := TRUE; END IF;
        END LOOP;
        IF NOT v_any THEN RETURN; END IF;
        DBMS_OUTPUT.PUT_LINE('<div class="hm-tw"><table id="' || p_id || '" class="hm-tbl" data-nocount>' || v_hdr || '<tbody>');
        FOR i IN 1 .. r_n LOOP
            IF r_blk(i) = p_b AND r_on(i) = 'Y' THEN DBMS_OUTPUT.PUT_LINE(row_html(i)); END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');
    END put_table;

    -- the rows of block p_b that the source never reported (comma list)
    FUNCTION miss_of(p_b VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. r_n LOOP
            IF r_blk(i) = p_b AND r_on(i) = 'N' THEN
                v := v || CASE WHEN v IS NOT NULL THEN ', ' END || r_lab(i);
            END IF;
        END LOOP;
        RETURN v;
    END miss_of;

    -- the median of v_med(1 .. p_n) (sorted in place)
    FUNCTION med(p_n PLS_INTEGER) RETURN NUMBER IS
        v_x NUMBER;
    BEGIN
        IF p_n = 0 THEN RETURN NULL; END IF;
        FOR a IN 2 .. p_n LOOP
            FOR b IN REVERSE 1 .. a - 1 LOOP
                IF v_med(b) > v_med(b + 1) THEN
                    v_x := v_med(b); v_med(b) := v_med(b + 1); v_med(b + 1) := v_x;
                END IF;
            END LOOP;
        END LOOP;
        IF MOD(p_n, 2) = 1 THEN RETURN v_med((p_n + 1) / 2); END IF;
        RETURN (v_med(p_n / 2) + v_med(p_n / 2 + 1)) / 2;
    END med;

    -- one statement table (p_kind 'T' temp, 'P' PGA) of the Current window
    PROCEDURE put_sql(p_kind VARCHAR2, p_tq t_stab, p_head VARCHAR2) IS
        v_q   VARCHAR2(30);
        v_c   NUMBER;
        v_mm  NUMBER;
        v_np2 PLS_INTEGER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<h4>' || p_head || '</h4>');
        IF p_tq.COUNT = 0 THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note">No statement in the Current window&rsquo;s ASH samples held '
                || CASE p_kind WHEN 'T' THEN 'temp space' ELSE 'PGA memory' END || '.</p>');
            RETURN;
        END IF;
        DBMS_OUTPUT.PUT_LINE('<div class="hm-tw"><table id="hm-sq-' || LOWER(p_kind) || '" class="hm-tbl hm-sq" data-nocount>'
            || '<thead><tr><th>#</th><th>SQL_ID</th><th class="num" data-w="0" title="the largest value at one sample instant, summed over the statement&#39;s sessions">Current max</th>'
            || '<th class="num" title="median of the statement&#39;s per-window maxima over the known prior windows in which ASH sampled it">Prior typical max</th>'
            || '<th class="num">&Delta; vs typical</th><th class="num" title="known prior windows in which ASH sampled the statement">Seen in prior windows</th></tr></thead><tbody>');
        FOR r IN 1 .. p_tq.COUNT LOOP
            v_q := p_tq(r);
            v_c := as_q(p_kind || '|' || v_q || '|0');
            v_np2 := 0;
            v_med.DELETE;
            FOR k IN 1 .. ~weeks_back LOOP
                IF w_known.EXISTS(k) AND w_known(k) = 'Y' AND as_seen.EXISTS(v_q || '|' || k) THEN
                    v_np2 := v_np2 + 1;
                    v_med(v_np2) := CASE WHEN as_q.EXISTS(p_kind || '|' || v_q || '|' || k)
                                         THEN as_q(p_kind || '|' || v_q || '|' || k) ELSE 0 END;
                END IF;
            END LOOP;
            v_mm := med(v_np2);
            DBMS_OUTPUT.PUT_LINE('<tr data-sql="' || v_q || '" data-cur="' || wt(v_c) || '" data-mu="' || wt(v_mm) || '">'
                || '<td class="num">' || r || '</td><td>' || ent(v_q, anchor_id('sq-elapsed', v_q), 'sql') || '</td>'
                || '<td class="num" data-w="0"><b>' || by_txt(v_c) || '</b></td><td class="num">' || by_txt(v_mm) || '</td>'
                || '<td class="num">' || CASE WHEN v_np2 = 0 THEN '<span class="d s-na">new</span>'
                                              ELSE delta_span(v_c, v_mm, NULL, 'Y') END || '</td>'
                || '<td class="num">' || v_np2 || ' of ' || v_np || '</td></tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');
    END put_sql;

    -- one evidence row for a finding card (hidden here, moved by the script)
    FUNCTION ev_row(p_dt VARCHAR2, p_code VARCHAR2, p_name VARCHAR2, p_de VARCHAR2, p_cur NUMBER, p_mu NUMBER,
                    p_ttl VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="evr ev-hm" data-hm="' || anchor_id('hm', p_code) || '" data-cur="' || wt(p_cur)
            || '" data-mu="' || wt(p_mu) || '" title="' || p_ttl || ' Not scored.">'
            || '<dt>' || p_dt || '</dt><dd><span class="id txt">' || ent(p_name, anchor_id('hm', p_code), 'metric')
            || '</span><span class="de">' || nbu(p_de) || '</span></dd><div class="m">'
            || delta_span(p_cur, p_mu, NULL, 'Y')
            || band_span(band_z(p_cur, p_mu, CASE WHEN v_sd.EXISTS(p_code) THEN v_sd(p_code) END), NULL, 'sm', 'N', 10)
            || '<span class="ns">not scored</span></div></div>';
    END ev_row;
BEGIN
    -- ---- 0. the compared windows ---------------------------------------
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, dbid, instance_number, valid_flag, skip_reason,
               begin_snap_id, end_snap_id,
               CAST(win_start_ts AS DATE) AS t0, CAST(win_end_ts AS DATE) AS t1,
               CASE WHEN valid_flag = 'Y'
                    THEN (CAST(end_end_ts AS DATE) - CAST(begin_end_ts AS DATE)) * 86400 END AS dur_sec,
               TO_CHAR(CAST(win_start_ts AS DATE), 'Dy DD Mon HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH') AS lab
        FROM   windows
        ORDER BY week_offset, instance_number
    ) LOOP
        IF NOT w_all.EXISTS(r.week_offset) THEN
            w_all(r.week_offset) := 0; w_ok(r.week_offset) := 0; w_dur(r.week_offset) := NULL;
            w_lab(r.week_offset) := r.lab; w_skip(r.week_offset) := NULL;
        END IF;
        w_all(r.week_offset) := w_all(r.week_offset) + 1;
        IF r.valid_flag = 'Y' THEN
            w_ok(r.week_offset) := w_ok(r.week_offset) + 1;
            w_dur(r.week_offset) := GREATEST(NVL(w_dur(r.week_offset), 0), r.dur_sec);
        ELSIF w_skip(r.week_offset) IS NULL THEN
            w_skip(r.week_offset) := NVL(r.skip_reason, 'no valid snapshots');
        END IF;
    END LOOP;
    FOR k IN 0 .. ~weeks_back LOOP
        w_known(k) := CASE WHEN w_all.EXISTS(k) AND w_ok(k) > 0 AND w_ok(k) = w_all(k) AND w_dur(k) > 0 THEN 'Y' ELSE 'N' END;
        IF w_known(k) = 'Y' THEN
            IF k = 0 THEN v_curok := TRUE; ELSE v_np := v_np + 1; END IF;
        END IF;
    END LOOP;
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec,
               CAST(win_start_ts AS DATE) AS t0, CAST(win_end_ts AS DATE) AS t1
        FROM   valid_windows
        ORDER BY week_offset, instance_number
    ) LOOP
        IF w_known(r.week_offset) = 'Y' THEN
            i_n := i_n + 1;
            i_wk(i_n) := r.week_offset; i_dbid(i_n) := r.dbid; i_inst(i_n) := r.instance_number;
            i_bs(i_n) := r.begin_snap_id; i_es(i_n) := r.end_snap_id; i_dur(i_n) := r.dur_sec;
            i_t0(i_n) := r.t0; i_t1(i_n) := r.t1;
        END IF;
    END LOOP;
    FOR k IN 0 .. ~weeks_back LOOP
        IF w_known(k) = 'Y' THEN v_ninst := GREATEST(v_ninst, w_ok(k)); END IF;
    END LOOP;

    -- ---- 1. host: DBA_HIST_OSSTAT (optional grant, dynamic SQL) ----------
    IF i_n > 0 THEN
        v_sql := 'SELECT stat_name,'
            || ' MAX(CASE WHEN snap_id = :1 THEN value END) KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0)),'
            || ' MAX(CASE WHEN snap_id = :2 THEN value END) KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0))'
            || ' FROM dba_hist_osstat WHERE dbid = :3 AND instance_number = :4 AND snap_id IN (:5, :6)'
            || ' AND stat_name IN (''NUM_CPUS'', ''NUM_CPU_CORES'', ''NUM_CPU_SOCKETS'', ''PHYSICAL_MEMORY_BYTES'','
            || ' ''FREE_MEMORY_BYTES'', ''LOAD'', ''BUSY_TIME'', ''IDLE_TIME'', ''USER_TIME'', ''SYS_TIME'','
            || ' ''NICE_TIME'', ''IOWAIT_TIME'', ''RSRC_MGR_CPU_WAIT_TIME'', ''VM_IN_BYTES'', ''VM_OUT_BYTES'')'
            || ' GROUP BY stat_name';
        BEGIN
            FOR i IN 1 .. i_n LOOP
                OPEN v_rc FOR v_sql USING i_bs(i), i_es(i), i_dbid(i), i_inst(i), i_bs(i), i_es(i);
                FETCH v_rc BULK COLLECT INTO v_nm, v_b, v_e;
                CLOSE v_rc;
                FOR j IN 1 .. v_nm.COUNT LOOP
                    IF v_nm(j) IN ('NUM_CPUS', 'NUM_CPU_CORES', 'NUM_CPU_SOCKETS', 'PHYSICAL_MEMORY_BYTES', 'FREE_MEMORY_BYTES') THEN
                        acc(os_a, os_c, v_nm(j), i_wk(i), v_e(j), 'S');
                    ELSIF v_nm(j) = 'LOAD' THEN
                        acc(os_a, os_c, v_nm(j), i_wk(i), v_e(j), 'X');
                    ELSIF v_b(j) IS NOT NULL AND v_e(j) >= v_b(j) THEN
                        acc(os_a, os_c, v_nm(j), i_wk(i), v_e(j) - v_b(j), 'S');
                    END IF;
                END LOOP;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                os_a.DELETE; os_c.DELETE;
                e_os := CASE WHEN SQLCODE IN (-942, -1031) THEN 'G' ELSE SUBSTRB(SQLERRM, 1, 300) END;
        END;
    END IF;

    -- DB CPU (time model, required grant): pairs -> bounds, as section 09
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT w.week_offset, w.instance_number,
               SUM(CASE WHEN tm.snap_id = w.begin_snap_id THEN tm.value END) AS beg_val,
               SUM(CASE WHEN tm.snap_id = w.end_snap_id   THEN tm.value END) AS end_val
        FROM   valid_windows w
        JOIN   dba_hist_sys_time_model tm
          ON   tm.dbid = w.dbid
         AND   tm.snap_id IN (w.begin_snap_id, w.end_snap_id)
         AND   tm.instance_number = w.instance_number
         AND   tm.stat_name = 'DB CPU'
        GROUP BY w.week_offset, w.instance_number
    ) LOOP
        IF w_known(r.week_offset) = 'Y' AND r.end_val >= r.beg_val THEN
            acc(tm_a, tm_c, 'dbcpu', r.week_offset, (r.end_val - r.beg_val) / 1e6, 'S');
        END IF;
    END LOOP;

    -- ---- 2. memory: DBA_HIST_PGASTAT, DBA_HIST_MEM_DYNAMIC_COMP ----------
    IF i_n > 0 THEN
        v_sql := 'SELECT name,'
            || ' MAX(CASE WHEN snap_id = :1 THEN value END) KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0)),'
            || ' MAX(CASE WHEN snap_id = :2 THEN value END) KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0))'
            || ' FROM dba_hist_pgastat WHERE dbid = :3 AND instance_number = :4 AND snap_id IN (:5, :6)'
            || ' AND name IN (''total PGA allocated'', ''total PGA inuse'', ''aggregate PGA target parameter'','
            || ' ''over allocation count'') GROUP BY name';
        BEGIN
            FOR i IN 1 .. i_n LOOP
                OPEN v_rc FOR v_sql USING i_bs(i), i_es(i), i_dbid(i), i_inst(i), i_bs(i), i_es(i);
                FETCH v_rc BULK COLLECT INTO v_nm, v_b, v_e;
                CLOSE v_rc;
                FOR j IN 1 .. v_nm.COUNT LOOP
                    IF v_nm(j) = 'over allocation count' THEN
                        IF v_b(j) IS NOT NULL AND v_e(j) >= v_b(j) THEN
                            acc(pg_a, pg_c, v_nm(j), i_wk(i), v_e(j) - v_b(j), 'S');
                        END IF;
                    ELSE
                        acc(pg_a, pg_c, v_nm(j), i_wk(i), v_e(j), 'S');
                    END IF;
                END LOOP;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                pg_a.DELETE; pg_c.DELETE;
                e_pg := CASE WHEN SQLCODE IN (-942, -1031) THEN 'G' ELSE SUBSTRB(SQLERRM, 1, 300) END;
        END;

        v_sql := 'SELECT LOWER(component), MAX(current_size) KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0))'
            || ' FROM dba_hist_mem_dynamic_comp WHERE dbid = :1 AND instance_number = :2 AND snap_id = :3'
            || ' AND LOWER(component) IN (''default buffer cache'', ''shared pool'', ''large pool'', ''sga target'', ''pga target'')'
            || ' GROUP BY LOWER(component)';
        BEGIN
            FOR i IN 1 .. i_n LOOP
                OPEN v_rc FOR v_sql USING i_dbid(i), i_inst(i), i_es(i);
                FETCH v_rc BULK COLLECT INTO v_nm, v_e;
                CLOSE v_rc;
                FOR j IN 1 .. v_nm.COUNT LOOP
                    acc(mc_a, mc_c, v_nm(j), i_wk(i), v_e(j), 'S');
                END LOOP;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                mc_a.DELETE; mc_c.DELETE;
                e_mc := CASE WHEN SQLCODE IN (-942, -1031) THEN 'G' ELSE SUBSTRB(SQLERRM, 1, 300) END;
        END;
    END IF;

    -- the resize operations that started inside the Current window
    IF v_curok THEN
        v_sql := 'SELECT component, oper_type, oper_mode, initial_size, target_size, final_size, status,'
            || ' start_time, end_time'
            || ' FROM (SELECT DISTINCT component, oper_type, oper_mode, initial_size, target_size, final_size, status,'
            || ' start_time, end_time FROM dba_hist_memory_resize_ops'
            || ' WHERE dbid = :1 AND instance_number = :2 AND start_time >= :3 AND start_time < :4'
            || ' AND oper_type IN (''GROW'', ''SHRINK''))'
            || ' ORDER BY start_time, component';
        BEGIN
            FOR i IN 1 .. i_n LOOP
                IF i_wk(i) = 0 THEN
                    OPEN v_rc FOR v_sql USING i_dbid(i), i_inst(i), i_t0(i), i_t1(i);
                    LOOP
                        FETCH v_rc INTO v_c1, v_c2, v_c3, v_x1, v_x2, v_x3, v_c4, v_d1, v_d2;
                        EXIT WHEN v_rc%NOTFOUND;
                        IF rs_n < c_rsmax THEN
                            rs_n := rs_n + 1;
                            rs_comp(rs_n) := v_c1; rs_op(rs_n) := v_c2; rs_mode(rs_n) := v_c3;
                            rs_ini(rs_n) := v_x1; rs_tgt(rs_n) := v_x2; rs_fin(rs_n) := v_x3; rs_st(rs_n) := v_c4;
                            rs_t0(rs_n) := v_d1; rs_t1(rs_n) := v_d2; rs_inst(rs_n) := i_inst(i);
                        END IF;
                        rs_tot := rs_tot + 1;
                    END LOOP;
                    CLOSE v_rc;
                END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                rs_n := 0; rs_tot := 0;
                e_rs := CASE WHEN SQLCODE IN (-942, -1031) THEN 'G' ELSE SUBSTRB(SQLERRM, 1, 300) END;
        END;
    END IF;

    -- ---- 3. undo: DBA_HIST_UNDOSTAT (10-minute rows, by time) ------------
    IF i_n > 0 THEN
        v_sql := 'SELECT SUM(ub), SUM(tx), MAX(mq), MAX(mqs) KEEP (DENSE_RANK LAST ORDER BY mq NULLS FIRST),'
            || ' MAX(mc), SUM(e1555), SUM(enos), MIN(tr), (MAX(et) - MIN(bt)) * 86400, COUNT(*)'
            || ' FROM (SELECT begin_time AS bt, NVL(con_id, 0) AS cid, MAX(end_time) AS et,'
            || ' MAX(undoblks) AS ub, MAX(txncount) AS tx, MAX(maxquerylen) AS mq,'
            || ' MAX(maxquerysqlid) KEEP (DENSE_RANK LAST ORDER BY maxquerylen NULLS FIRST) AS mqs,'
            || ' MAX(maxconcurrency) AS mc, MAX(ssolderrcnt) AS e1555, MAX(nospaceerrcnt) AS enos,'
            || ' MIN(tuned_undoretention) AS tr'
            || ' FROM dba_hist_undostat WHERE dbid = :1 AND instance_number = :2'
            || ' AND end_time > :3 AND begin_time < :4'
            || ' GROUP BY begin_time, NVL(con_id, 0))';
        BEGIN
            FOR i IN 1 .. i_n LOOP
                OPEN v_rc FOR v_sql USING i_dbid(i), i_inst(i), i_t0(i), i_t1(i);
                FETCH v_rc INTO v_x1, v_x2, v_x3, v_xq, v_x4, v_x5, v_x6, v_x7, v_x8, v_x9;
                CLOSE v_rc;
                IF v_x9 > 0 THEN
                    -- per instance: rates over the rows' covered time, then summed
                    IF v_x8 > 0 THEN
                        acc(un_a, un_c, 'ub', i_wk(i), v_x1 / v_x8, 'S');
                        acc(un_a, un_c, 'tx', i_wk(i), v_x2 / v_x8, 'S');
                    END IF;
                    acc(un_a, un_c, 'mq', i_wk(i), v_x3, 'X');
                    acc(un_a, un_c, 'mc', i_wk(i), v_x4, 'X');
                    acc(un_a, un_c, 'e1555', i_wk(i), NVL(v_x5, 0), 'S');
                    acc(un_a, un_c, 'enos', i_wk(i), NVL(v_x6, 0), 'S');
                    acc(un_a, un_c, 'tr', i_wk(i), v_x7, 'N');
                    IF v_x3 IS NOT NULL AND v_xq IS NOT NULL
                       AND (NOT un_ql.EXISTS(TO_CHAR(i_wk(i))) OR v_x3 > un_ql(TO_CHAR(i_wk(i)))) THEN
                        un_ql(TO_CHAR(i_wk(i))) := v_x3;
                        un_q(TO_CHAR(i_wk(i))) := v_xq;
                    END IF;
                END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_rc%ISOPEN THEN CLOSE v_rc; END IF;
                un_a.DELETE; un_c.DELETE; un_q.DELETE; un_ql.DELETE;
                e_un := CASE WHEN SQLCODE IN (-942, -1031) THEN 'G' ELSE SUBSTRB(SQLERRM, 1, 300) END;
        END;
    END IF;

    -- ---- 4. temp and PGA: ONE bounded ASH scan (required grant) ----------
    -- A statement's value at one sample instant = the sum over its sessions
    -- (parallel slaves included); its window value = the largest such sum;
    -- the window's peak = the largest sum over ALL sampled sessions at one
    -- sample instant, per instance, summed over the instances (RAC).
    -- Rows kept: one per (window, instance) for the peak (rn = 1) and every
    -- window of the Current window's top 5 statements by temp / by PGA.
    IF v_curok OR v_np > 0 THEN
        FOR r IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            wa AS (
                SELECT vw.week_offset AS wk, ash.instance_number AS inst, ash.sample_id AS smp,
                       NVL(ash.sql_id, '-') AS q,
                       NVL(ash.temp_space_allocated, 0) AS tb,
                       NVL(ash.pga_allocated, 0) AS pb
                FROM   valid_windows vw
                JOIN   dba_hist_active_sess_history ash
                  ON   ash.dbid = vw.dbid
                 AND   ash.instance_number = vw.instance_number
                 AND   ash.snap_id BETWEEN vw.begin_snap_id AND vw.end_snap_id + 1
                 AND   ash.sample_time >= vw.win_start_ts
                 AND   ash.sample_time <  vw.win_end_ts
                WHERE  ash.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
            ),
            ws AS (
                SELECT wk, inst, smp, q, SUM(tb) AS tb, SUM(pb) AS pb
                FROM   wa
                GROUP BY wk, inst, smp, q
            ),
            wt2 AS (
                SELECT wk, inst, q, tb, pb,
                       SUM(tb) OVER (PARTITION BY wk, inst, smp) AS st,
                       SUM(pb) OVER (PARTITION BY wk, inst, smp) AS sp
                FROM   ws
            ),
            wm AS (
                SELECT wk, inst, q, MAX(tb) AS tm, MAX(pb) AS pm, MAX(st) AS ist, MAX(sp) AS isp
                FROM   wt2
                GROUP BY wk, inst, q
            ),
            wq AS (
                SELECT wk, inst, q, tm, pm,
                       MAX(ist) OVER (PARTITION BY wk, inst) AS ipt,
                       MAX(isp) OVER (PARTITION BY wk, inst) AS ipp,
                       ROW_NUMBER() OVER (PARTITION BY wk, inst ORDER BY q) AS rn,
                       MAX(CASE WHEN wk = 0 AND q <> '-' THEN tm END) OVER (PARTITION BY q) AS ct,
                       MAX(CASE WHEN wk = 0 AND q <> '-' THEN pm END) OVER (PARTITION BY q) AS cp
                FROM   wm
            ),
            wr AS (
                SELECT wk, inst, q, tm, pm, ipt, ipp, rn, ct, cp,
                       DENSE_RANK() OVER (ORDER BY ct DESC NULLS LAST, q) AS rt,
                       DENSE_RANK() OVER (ORDER BY cp DESC NULLS LAST, q) AS rp
                FROM   wq
            )
            SELECT wk, inst, q, tm, pm, ipt, ipp, rn,
                   CASE WHEN ct > 0 AND rt <= 5 THEN rt END AS rt,
                   CASE WHEN cp > 0 AND rp <= 5 THEN rp END AS rp
            FROM   wr
            WHERE  rn = 1 OR (ct > 0 AND rt <= 5) OR (cp > 0 AND rp <= 5)
            ORDER BY wk, inst, q
        ) LOOP
            IF w_known(r.wk) = 'Y' THEN
                v_ash_ok := TRUE;
                IF r.rn = 1 THEN
                    v_k := 'tp|' || r.wk;
                    as_a(v_k) := CASE WHEN as_a.EXISTS(v_k) THEN as_a(v_k) ELSE 0 END + NVL(r.ipt, 0);
                    v_k := 'pp|' || r.wk;
                    as_a(v_k) := CASE WHEN as_a.EXISTS(v_k) THEN as_a(v_k) ELSE 0 END + NVL(r.ipp, 0);
                END IF;
                IF r.rt IS NOT NULL OR r.rp IS NOT NULL THEN
                    as_seen(r.q || '|' || r.wk) := 'Y';
                    v_k := 'T|' || r.q || '|' || r.wk;
                    as_q(v_k) := GREATEST(CASE WHEN as_q.EXISTS(v_k) THEN as_q(v_k) ELSE 0 END, NVL(r.tm, 0));
                    v_k := 'P|' || r.q || '|' || r.wk;
                    as_q(v_k) := GREATEST(CASE WHEN as_q.EXISTS(v_k) THEN as_q(v_k) ELSE 0 END, NVL(r.pm, 0));
                    IF r.wk = 0 AND r.rt IS NOT NULL THEN tq_t(r.rt) := r.q; END IF;
                    IF r.wk = 0 AND r.rp IS NOT NULL THEN tq_p(r.rp) := r.q; END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ---- 5. the rows, per window --------------------------------------
    add_row('busy', 'H', 'Host CPU busy', '%', 'BUSY_TIME / (BUSY_TIME + IDLE_TIME) over the window (DBA_HIST_OSSTAT, counters, summed over the instances)');
    add_row('user', 'H', 'User', '%', 'USER_TIME as a share of BUSY_TIME + IDLE_TIME');
    add_row('sys', 'H', 'System', '%', 'SYS_TIME (kernel) as a share of BUSY_TIME + IDLE_TIME');
    add_row('nice', 'H', 'Nice', '%', 'NICE_TIME (low-priority user code) as a share of BUSY_TIME + IDLE_TIME');
    add_row('iowait', 'H', 'I/O wait', '%', 'IOWAIT_TIME as a share of BUSY_TIME + IDLE_TIME: CPUs idle with I/O outstanding');
    add_row('dbshare', 'H', 'DB CPU share of host busy', '%',
        'Foreground DB CPU (DBA_HIST_SYS_TIME_MODEL) divided by the host&#39;s busy CPU time. The rest is background processes, other databases and software on the host, and the OS. It can pass 100 where the host counts CPU differently (virtual machines, SMT).');
    add_row('load', 'H', 'Load (end of window)', 'processes', 'LOAD at the window&#39;s end snapshot: processes running or ready to run (on many platforms the one-minute average); the largest instance');
    add_row('rsrc', 'H', 'Resource Manager CPU wait', 's/s', 'RSRC_MGR_CPU_WAIT_TIME: Oracle processes ready to run but held back by the resource plan, seconds per second');
    add_row('vmin', 'H', 'Paged in', 'MB/s', 'VM_IN_BYTES: bytes paged in through virtual memory paging, per second');
    add_row('vmout', 'H', 'Paged out (swap out)', 'MB/s', 'VM_OUT_BYTES: bytes paged out through virtual memory paging, per second');
    add_row('cpus', 'H', 'CPUs', 'count', 'NUM_CPUS at the window&#39;s end snapshot (configuration)');
    add_row('cores', 'H', 'CPU cores', 'count', 'NUM_CPU_CORES at the window&#39;s end snapshot (configuration)');
    add_row('sockets', 'H', 'CPU sockets', 'count', 'NUM_CPU_SOCKETS at the window&#39;s end snapshot (configuration)');
    add_row('physmem', 'H', 'Physical memory', 'GB', 'PHYSICAL_MEMORY_BYTES at the window&#39;s end snapshot (configuration)');
    add_row('freemem', 'H', 'Free memory (end of window)', 'GB', 'FREE_MEMORY_BYTES at the window&#39;s end snapshot (a gauge; not every platform reports it)');
    add_row('bc', 'M', 'Buffer cache', 'GB', 'DEFAULT buffer cache size at the window&#39;s end snapshot (DBA_HIST_MEM_DYNAMIC_COMP)');
    add_row('sp', 'M', 'Shared pool', 'GB', 'shared pool size at the window&#39;s end snapshot');
    add_row('lp', 'M', 'Large pool', 'GB', 'large pool size at the window&#39;s end snapshot');
    add_row('sgat', 'M', 'SGA target (component)', 'GB', 'SGA Target component size at the window&#39;s end snapshot (automatic memory management)');
    add_row('pgat', 'M', 'PGA target (component)', 'GB', 'PGA Target component size at the window&#39;s end snapshot (automatic memory management)');
    add_row('pgaprm', 'M', 'PGA aggregate target', 'GB', 'aggregate PGA target parameter at the window&#39;s end snapshot (DBA_HIST_PGASTAT, configuration)');
    add_row('pgaalloc', 'M', 'PGA allocated (end of window)', 'GB', 'total PGA allocated at the window&#39;s end snapshot (a gauge)');
    add_row('pgainuse', 'M', 'PGA in use (end of window)', 'GB', 'total PGA inuse at the window&#39;s end snapshot: PGA consumed by work areas');
    add_row('pgaover', 'M', 'PGA over-allocations', 'count', 'over allocation count, end minus begin of the window: PGA allocated beyond pga_aggregate_target');
    add_row('ub', 'U', 'Undo blocks', 'blocks/s', 'UNDOBLKS of the 10-minute DBA_HIST_UNDOSTAT rows overlapping the window, per second of the rows&#39; covered time');
    add_row('tx', 'U', 'Transactions', 'per s', 'TXNCOUNT of the overlapping 10-minute rows, per second');
    add_row('mq', 'U', 'Longest query', 's', 'MAXQUERYLEN: the longest query of the overlapping rows (cursor open to last fetch), seconds');
    add_row('mc', 'U', 'Most concurrent transactions', 'count', 'MAXCONCURRENCY: the highest number of transactions running at once');
    add_row('e1555', 'U', 'ORA-01555 (snapshot too old)', 'count', 'SSOLDERRCNT summed over the overlapping rows');
    add_row('enos', 'U', 'Undo out-of-space errors', 'count', 'NOSPACEERRCNT summed over the overlapping rows: no free space in the undo tablespace');
    add_row('tr', 'U', 'Tuned undo retention (lowest)', 's', 'TUNED_UNDORETENTION: the lowest value of the overlapping rows');
    add_row('tmppk', 'T', 'Peak temp space (ASH)', 'GB', 'the largest temp space held at one sample instant, summed over the sampled sessions (RAC: per instance, summed)');
    add_row('pgapk', 'T', 'Peak PGA of sampled sessions (ASH)', 'GB', 'the largest PGA held at one sample instant, summed over the sampled (active) sessions; idle sessions are not sampled');

    FOR k IN 0 .. ~weeks_back LOOP
        IF w_known(k) = 'Y' THEN
            DECLARE
                v_bu NUMBER := got(os_a, os_c, 'BUSY_TIME', k);
                v_id NUMBER := got(os_a, os_c, 'IDLE_TIME', k);
                v_to NUMBER;
                v_du NUMBER := w_dur(k);
                v_db NUMBER := got(tm_a, tm_c, 'dbcpu', k);
            BEGIN
                v_to := CASE WHEN v_bu IS NOT NULL AND v_id IS NOT NULL THEN v_bu + v_id END;
                put('busy', k, rdiv(v_bu * 100, v_to));
                put('user', k, rdiv(got(os_a, os_c, 'USER_TIME', k) * 100, v_to));
                put('sys', k, rdiv(got(os_a, os_c, 'SYS_TIME', k) * 100, v_to));
                put('nice', k, rdiv(got(os_a, os_c, 'NICE_TIME', k) * 100, v_to));
                put('iowait', k, rdiv(got(os_a, os_c, 'IOWAIT_TIME', k) * 100, v_to));
                -- DB CPU (s) over host busy (hundredths of a second)
                put('dbshare', k, rdiv(v_db * 100 * 100, v_bu));
                put('load', k, got(os_a, os_c, 'LOAD', k));
                put('rsrc', k, rdiv(got(os_a, os_c, 'RSRC_MGR_CPU_WAIT_TIME', k) / 100, v_du));
                put('vmin', k, rdiv(got(os_a, os_c, 'VM_IN_BYTES', k) / c_mb, v_du));
                put('vmout', k, rdiv(got(os_a, os_c, 'VM_OUT_BYTES', k) / c_mb, v_du));
                put('cpus', k, got(os_a, os_c, 'NUM_CPUS', k));
                put('cores', k, got(os_a, os_c, 'NUM_CPU_CORES', k));
                put('sockets', k, got(os_a, os_c, 'NUM_CPU_SOCKETS', k));
                put('physmem', k, got(os_a, os_c, 'PHYSICAL_MEMORY_BYTES', k) / c_gb);
                put('freemem', k, got(os_a, os_c, 'FREE_MEMORY_BYTES', k) / c_gb);
                put('bc', k, got(mc_a, mc_c, 'default buffer cache', k) / c_gb);
                put('sp', k, got(mc_a, mc_c, 'shared pool', k) / c_gb);
                put('lp', k, got(mc_a, mc_c, 'large pool', k) / c_gb);
                put('sgat', k, got(mc_a, mc_c, 'sga target', k) / c_gb);
                put('pgat', k, got(mc_a, mc_c, 'pga target', k) / c_gb);
                put('pgaprm', k, got(pg_a, pg_c, 'aggregate PGA target parameter', k) / c_gb);
                put('pgaalloc', k, got(pg_a, pg_c, 'total PGA allocated', k) / c_gb);
                put('pgainuse', k, got(pg_a, pg_c, 'total PGA inuse', k) / c_gb);
                put('pgaover', k, got(pg_a, pg_c, 'over allocation count', k));
                put('ub', k, got(un_a, un_c, 'ub', k));
                put('tx', k, got(un_a, un_c, 'tx', k));
                put('mq', k, got(un_a, un_c, 'mq', k));
                put('mc', k, got(un_a, un_c, 'mc', k));
                put('e1555', k, got(un_a, un_c, 'e1555', k));
                put('enos', k, got(un_a, un_c, 'enos', k));
                put('tr', k, got(un_a, un_c, 'tr', k));
                IF v_ash_ok THEN
                    put('tmppk', k, CASE WHEN as_a.EXISTS('tp|' || k) THEN as_a('tp|' || k) ELSE 0 END / c_gb);
                    put('pgapk', k, CASE WHEN as_a.EXISTS('pp|' || k) THEN as_a('pp|' || k) ELSE 0 END / c_gb);
                END IF;
            END;
        END IF;
    END LOOP;

    -- which rows have a value; the SGA / PGA Target components only when
    -- non-zero somewhere (zero = not under automatic memory management)
    FOR i IN 1 .. r_n LOOP
        FOR k IN 0 .. ~weeks_back LOOP
            v_val := vv(r_code(i), k);
            IF v_val IS NOT NULL AND (r_code(i) NOT IN ('sgat', 'pgat') OR v_val > 0) THEN r_on(i) := 'Y'; END IF;
        END LOOP;
    END LOOP;

    -- prior mean, sample sd, n over the known prior windows with a value
    FOR i IN 1 .. r_n LOOP
        v_n := 0; v_s := 0;
        FOR k IN 1 .. ~weeks_back LOOP
            v_val := vv(r_code(i), k);
            IF v_val IS NOT NULL THEN v_n := v_n + 1; v_s := v_s + v_val; END IF;
        END LOOP;
        v_nn(r_code(i)) := v_n;
        IF v_n > 0 THEN
            v_m := v_s / v_n;
            v_mu(r_code(i)) := v_m;
            IF v_n > 1 THEN
                v_ss := 0;
                FOR k IN 1 .. ~weeks_back LOOP
                    v_val := vv(r_code(i), k);
                    IF v_val IS NOT NULL THEN v_ss := v_ss + (v_val - v_m) * (v_val - v_m); END IF;
                END LOOP;
                v_sd(r_code(i)) := SQRT(v_ss / (v_n - 1));
            END IF;
        END IF;
    END LOOP;

    -- configuration lines: the Current host, and every change across the windows
    IF e_os IS NULL THEN
        IF vv('cpus', 0) IS NOT NULL THEN
            v_cfg := fmt_int(vv('cpus', 0)) || CASE WHEN vv('cpus', 0) = 1 THEN ' CPU' ELSE ' CPUs' END
                || CASE WHEN vv('cores', 0) IS NOT NULL OR vv('sockets', 0) IS NOT NULL THEN ' ('
                        || CASE WHEN vv('cores', 0) IS NOT NULL THEN fmt_int(vv('cores', 0))
                                || CASE WHEN vv('cores', 0) = 1 THEN ' core' ELSE ' cores' END END
                        || CASE WHEN vv('cores', 0) IS NOT NULL AND vv('sockets', 0) IS NOT NULL THEN ', ' END
                        || CASE WHEN vv('sockets', 0) IS NOT NULL THEN fmt_int(vv('sockets', 0))
                                || CASE WHEN vv('sockets', 0) = 1 THEN ' socket' ELSE ' sockets' END END
                        || ')' END
                || CASE WHEN vv('physmem', 0) IS NOT NULL THEN ', ' || fmt_num(vv('physmem', 0)) || '&nbsp;GB memory' END
                || CASE WHEN v_ninst > 1 THEN ', summed over ' || v_ninst || ' instances' END;
        END IF;
        FOR c IN 1 .. 4 LOOP
            v_k := CASE c WHEN 1 THEN 'cpus' WHEN 2 THEN 'cores' WHEN 3 THEN 'sockets' ELSE 'physmem' END;
            v_prev := NULL; v_pwk := NULL;
            FOR k IN REVERSE 0 .. ~weeks_back LOOP
                v_val := vv(v_k, k);
                IF v_val IS NOT NULL THEN
                    IF v_prev IS NOT NULL AND v_val <> v_prev THEN
                        v_chg := v_chg || CASE WHEN v_chg IS NOT NULL THEN '; ' END
                            || CASE c WHEN 1 THEN 'CPUs' WHEN 2 THEN 'CPU cores' WHEN 3 THEN 'CPU sockets' ELSE 'memory' END
                            || ' ' || CASE WHEN c = 4 THEN fmt_num(v_prev) ELSE fmt_int(v_prev) END || ' &rarr; '
                            || CASE WHEN c = 4 THEN fmt_num(v_val) || '&nbsp;GB' ELSE fmt_int(v_val) END
                            || ' between ' || wl(v_pwk) || ' and ' || wl(k);
                    END IF;
                    v_prev := v_val; v_pwk := k;
                END IF;
            END LOOP;
        END LOOP;
    END IF;

    -- ---- 6. what stands out (lopen), the sentence, the card rows --------
    IF v_curok THEN
        v_cur := vv('busy', 0);
        IF v_cur >= c_busy THEN
            v_open := TRUE; v_why := v_why || ' busy';
            v_ev_dbt := v_ev_dbt || ev_row('Host', 'busy', 'host CPU', fmt_int(v_cur) || '% busy' || CASE WHEN mu_of('busy') IS NOT NULL THEN ', was ' || fmt_int(mu_of('busy')) || '%' END,
                v_cur, mu_of('busy'), 'Host and memory: the host&#39;s CPU was at least 90% busy in the Current window.');
        END IF;
        v_cur := vv('vmout', 0);
        IF v_cur >= c_swap THEN
            v_open := TRUE; v_why := v_why || ' swap';
            v_ev_dbt := v_ev_dbt || ev_row('Host', 'vmout', 'swapping', fmt_num(v_cur) || ' MB/s paged out' || CASE WHEN mu_of('vmout') IS NOT NULL THEN ', was ' || fmt_num(mu_of('vmout')) || ' MB/s' END,
                v_cur, mu_of('vmout'), 'Host and memory: the host paged memory out (VM_OUT_BYTES) in the Current window.');
        END IF;
        IF v_chg IS NOT NULL THEN v_open := TRUE; v_why := v_why || ' resized'; END IF;
        IF rs_tot > 0 THEN v_open := TRUE; v_why := v_why || ' sgaresize'; END IF;
        v_cur := vv('bc', 0); v_m := mu_of('bc');
        IF v_cur IS NOT NULL AND v_m > 0 AND v_cur <= c_bcdrop * v_m THEN
            v_open := TRUE; v_why := v_why || ' bc';
            v_ev_io := ev_row('Memory', 'bc', 'buffer cache', fmt_num(v_cur) || ' GB, was ' || fmt_num(v_m) || ' GB (prior mean)',
                v_cur, v_m, 'Host and memory: the Current buffer cache is at least 10% below the prior windows&#39; mean; a smaller cache reads more from disk.');
        END IF;
        IF vv('pgaover', 0) > 0 THEN v_open := TRUE; v_why := v_why || ' pgaover'; END IF;
        IF vv('e1555', 0) > 0 THEN v_open := TRUE; v_why := v_why || ' ora1555'; END IF;
        IF vv('enos', 0) > 0 THEN v_open := TRUE; v_why := v_why || ' undospace'; END IF;

        -- the sentence, from the blocks that could be read
        v_cur := vv('busy', 0);
        IF v_cur IS NOT NULL THEN
            v_pts := CASE WHEN vv('dbshare', 0) IS NOT NULL THEN v_cur * vv('dbshare', 0) / 100 END;
            v_rd := 'Host CPU ' || fmt_int(v_cur) || '% busy'
                || CASE WHEN v_pts IS NOT NULL THEN ', the database (foreground DB CPU) about ' || fmt_int(v_pts) || ' points of it' END;
            v_ls := 'host CPU ' || fmt_int(v_cur) || '% busy';
        ELSIF e_os IS NOT NULL THEN
            v_rd := 'Host statistics: ' || err_note(e_os, 'DBA_HIST_OSSTAT');
            v_ls := 'host: ' || CASE WHEN e_os = 'G' THEN 'no grant' ELSE 'not readable' END;
        END IF;
        v_cur := vv('vmout', 0);
        IF v_cur IS NOT NULL THEN
            v_t := CASE WHEN v_cur >= c_swap THEN 1 WHEN v_cur > 0 THEN 2 ELSE 0 END;
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END
                || CASE v_t WHEN 1 THEN 'swapping, ' || fmt_num(v_cur) || '&nbsp;MB/s paged out'
                            WHEN 2 THEN 'little paging out (' || fmt_num(v_cur) || '&nbsp;MB/s)'
                            ELSE 'no swapping' END;
            IF v_t = 1 THEN v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END || 'swapping'; END IF;
        END IF;
        IF v_chg IS NOT NULL THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END || 'host resized (' || v_chg || ')';
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END || 'host resized';
        END IF;
        v_cur := vv('bc', 0); v_m := mu_of('bc');
        IF v_cur IS NOT NULL THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END || 'buffer cache '
                || CASE WHEN v_m IS NULL OR ABS(v_cur - v_m) < 0.1 * v_m THEN 'steady at ' || fmt_num(v_cur) || '&nbsp;GB'
                        ELSE fmt_num(v_cur) || '&nbsp;GB, was ' || fmt_num(v_m) || '&nbsp;GB on average' END;
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END || 'buffer cache ' || fmt_num(v_cur) || '&nbsp;GB';
        END IF;
        IF rs_tot > 0 THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END || rs_tot
                || CASE WHEN rs_tot = 1 THEN ' SGA / PGA resize operation' ELSE ' SGA / PGA resize operations' END || ' in the Current window';
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END || rs_tot || ' resize op' || CASE WHEN rs_tot > 1 THEN 's' END;
        END IF;
        IF vv('pgaover', 0) > 0 THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END || 'PGA over-allocated ' || fmt_int(vv('pgaover', 0))
                || CASE WHEN vv('pgaover', 0) = 1 THEN ' time' ELSE ' times' END;
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END || 'PGA over-allocation';
        END IF;
        IF vv('e1555', 0) IS NOT NULL THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END
                || CASE WHEN vv('e1555', 0) = 0 THEN 'no ORA-01555'
                        ELSE fmt_int(vv('e1555', 0)) || ' ORA-01555 (snapshot too old)' END
                || CASE WHEN vv('enos', 0) > 0 THEN ', ' || fmt_int(vv('enos', 0)) || ' undo out-of-space' END;
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END
                || CASE WHEN vv('e1555', 0) = 0 THEN 'no ORA-01555' ELSE fmt_int(vv('e1555', 0)) || ' ORA-01555' END;
        END IF;
        IF v_ash_ok AND vv('tmppk', 0) IS NOT NULL THEN
            v_rd := v_rd || CASE WHEN v_rd IS NOT NULL THEN '; ' END
                || CASE WHEN vv('tmppk', 0) > 0
                        THEN 'peak temp ' || by_txt(vv('tmppk', 0) * c_gb)
                             || CASE WHEN tq_t.EXISTS(1) THEN ' (largest: ' || ent(tq_t(1), anchor_id('sq-elapsed', tq_t(1)), 'sql') || ')' END
                        ELSE 'no temp space in the ASH samples' END;
            v_ls := v_ls || CASE WHEN v_ls IS NOT NULL THEN '; ' END
                || CASE WHEN vv('tmppk', 0) > 0 THEN 'peak temp ' || by_txt(vv('tmppk', 0) * c_gb) ELSE 'no temp' END;
        END IF;
        IF v_rd IS NULL THEN
            v_rd := 'Nothing could be read for the Current window.';
            v_ls := 'nothing readable';
        ELSE
            v_rd := UPPER(SUBSTR(v_rd, 1, 1)) || SUBSTR(v_rd, 2) || '.';
        END IF;
    ELSE
        v_rd := 'The Current window is unknown ('
            || DBMS_XMLGEN.CONVERT(NVL(CASE WHEN w_skip.EXISTS(0) THEN w_skip(0) END, 'an instance skipped'))
            || '), so its host and memory numbers are too.';
        v_ls := 'Current window skipped';
    END IF;

    -- ---- 7. markup ------------------------------------------------------
    v_hdr := '<thead><tr><th>Metric</th><th>Unit</th><th class="num" data-w="0">Current</th>'
        || band_head || '<th class="trend">Trend</th>';
    FOR k IN 1 .. ~weeks_back LOOP
        v_hdr := v_hdr || '<th class="num" data-w="' || k || '">&minus;' || off_label(k) || '</th>';
    END LOOP;
    v_hdr := v_hdr || '</tr></thead>';

    DBMS_OUTPUT.PUT_LINE('<section id="host-memory" class="vw in-s in-a lib' || CASE WHEN v_open THEN ' lopen' END
        || '" style="--os:20" data-open="' || TRIM(v_why) || '"><h2>Host and memory'
        || '<small class="h2sub">Host CPU and paging, SGA / PGA, undo, temp; not scored</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('host-memory', v_ls));
    DBMS_OUTPUT.PUT_LINE('<p class="hm-rd"><b>Reads as:</b> ' || v_rd || '</p>');

    -- host
    DBMS_OUTPUT.PUT_LINE('<div class="hm-blk" id="hm-host"><h3>Host CPU and paging</h3>');
    IF e_os IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-err">Host statistics ' || err_note(e_os, 'DBA_HIST_OSSTAT') || '.</p>');
    ELSE
        IF v_cfg IS NOT NULL THEN DBMS_OUTPUT.PUT_LINE('<p class="hm-cfg">Host in the Current window: ' || v_cfg || '.</p>'); END IF;
        IF v_chg IS NOT NULL THEN DBMS_OUTPUT.PUT_LINE('<p class="hm-chg"><b>Host resized:</b> ' || v_chg || '.</p>'); END IF;
        put_table('H', 'hm-t-host');
        v_miss := miss_of('H');
        IF v_miss IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note hm-miss">Not reported for the compared windows (platform or snapshots): ' || v_miss || '.</p>');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('</div>');

    -- memory
    DBMS_OUTPUT.PUT_LINE('<div class="hm-blk" id="hm-mem"><h3>Memory</h3>');
    IF e_mc IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-err">SGA component sizes ' || err_note(e_mc, 'DBA_HIST_MEM_DYNAMIC_COMP') || '.</p>');
    END IF;
    IF e_pg IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-err">PGA statistics ' || err_note(e_pg, 'DBA_HIST_PGASTAT') || '.</p>');
    END IF;
    put_table('M', 'hm-t-mem');
    IF e_mc IS NULL AND e_pg IS NULL THEN
        v_miss := miss_of('M');
        IF v_miss IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note hm-miss">Not reported or zero in every compared window: ' || v_miss || '.</p>');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('<h4>Resize operations in the Current window</h4>');
    IF e_rs IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-err">Resize operations ' || err_note(e_rs, 'DBA_HIST_MEMORY_RESIZE_OPS') || '.</p>');
    ELSIF NOT v_curok THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">The Current window is unknown.</p>');
    ELSIF rs_tot = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-rs0">No SGA / PGA grow or shrink operation started in the Current window.</p>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<div class="hm-tw"><table id="hm-rs" class="hm-tbl" data-nocount><thead><tr><th>Component</th>'
            || '<th>Operation</th><th class="num">From</th><th class="num">To</th><th class="num" title="the size requested">Target</th>'
            || '<th>Started</th><th>Ended</th><th>Status</th></tr></thead><tbody>');
        FOR i IN 1 .. rs_n LOOP
            DBMS_OUTPUT.PUT_LINE('<tr data-op="' || LOWER(rs_op(i)) || '"><td>' || DBMS_XMLGEN.CONVERT(rs_comp(i))
                || CASE WHEN v_ninst > 1 THEN ' (instance ' || rs_inst(i) || ')' END || '</td>'
                || '<td>' || LOWER(rs_op(i)) || CASE WHEN rs_mode(i) IS NOT NULL THEN ' (' || LOWER(rs_mode(i)) || ')' END || '</td>'
                || '<td class="num">' || by_txt(rs_ini(i)) || '</td><td class="num">' || by_txt(rs_fin(i)) || '</td>'
                || '<td class="num">' || by_txt(rs_tgt(i)) || '</td>'
                || '<td>' || TO_CHAR(rs_t0(i), 'HH24:MI:SS') || '</td><td>' || TO_CHAR(rs_t1(i), 'HH24:MI:SS') || '</td>'
                || '<td>' || DBMS_XMLGEN.CONVERT(LOWER(rs_st(i))) || '</td></tr>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');
        IF rs_tot > rs_n THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note">The first ' || rs_n || ' of ' || rs_tot || ' operations.</p>');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('</div>');

    -- undo
    DBMS_OUTPUT.PUT_LINE('<div class="hm-blk" id="hm-undo"><h3>Undo</h3>');
    IF e_un IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note hm-err">Undo statistics ' || err_note(e_un, 'DBA_HIST_UNDOSTAT') || '.</p>');
    ELSE
        put_table('U', 'hm-t-undo');
        IF un_q.EXISTS('0') THEN
            DBMS_OUTPUT.PUT_LINE('<p class="hm-mq">Longest query in the Current window: <b>' || fmt_num(un_ql('0')) || '&nbsp;s</b>, '
                || ent(DBMS_XMLGEN.CONVERT(un_q('0')), anchor_id('sq-elapsed', un_q('0')), 'sql') || '.</p>');
        END IF;
        v_miss := miss_of('U');
        IF v_miss IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<p class="note hm-miss">No <code>DBA_HIST_UNDOSTAT</code> rows for: ' || v_miss || '.</p>');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('</div>');

    -- temp and PGA by statement
    DBMS_OUTPUT.PUT_LINE('<div class="hm-blk" id="hm-temp"><h3>Temp and PGA by statement</h3>');
    IF NOT v_ash_ok THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">No ASH samples in the known compared windows.</p>');
    ELSE
        put_table('T', 'hm-t-temp');
        IF v_curok THEN
            put_sql('T', tq_t, 'Largest temp space in the Current window');
            put_sql('P', tq_p, 'Largest PGA in the Current window');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('<p class="note hm-ash">ASH (<code>DBA_HIST_ACTIVE_SESS_HISTORY</code>) keeps one in ten of the in-memory samples: '
        || 'a 10-second sample of ACTIVE sessions, so a short spill is easily missed and an idle session&rsquo;s PGA is not counted. '
        || 'A statement&rsquo;s value at one sample = the sum over its sessions (parallel slaves included); its window value = the largest '
        || 'such sum. Typical = the median of its maxima over the known prior windows in which ASH sampled it.</p>');
    DBMS_OUTPUT.PUT_LINE('</div>');

    DBMS_OUTPUT.PUT_LINE('<p class="note hm-meth">Counters (CPU times, paging, over-allocations) are end minus begin of the window&rsquo;s snapshots; '
        || 'gauges (load, sizes, PGA allocated) are read at the window&rsquo;s end snapshot; undo comes in 10-minute rows counted toward every '
        || 'window they overlap. Host values are summed over the instances. A window is used only when every instance of it is valid. '
        || 'Evidence, not a finding: nothing here is scored or counted.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');

    -- the card rows (hidden here; moved into the cards while the page parses)
    IF v_ev_io IS NOT NULL OR v_ev_dbt IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<div id="hm-ev-src" hidden>'
            || CASE WHEN v_ev_io IS NOT NULL THEN '<div data-for="f-io">' || v_ev_io || '</div>' END
            || CASE WHEN v_ev_dbt IS NOT NULL THEN '<div data-for="f-dbtime">' || v_ev_dbt || '</div>' END
            || '</div>');
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,x=d.getElementById("hm-ev-src");if(!x)return;'
            || '[].slice.call(x.children).forEach(function(g){var c=d.getElementById(g.getAttribute("data-for")),'
            || 'dl=c?c.querySelector("dl.ev"):null;if(dl){while(g.firstChild)dl.appendChild(g.firstChild);}});'
            || 'x.parentNode.removeChild(x);})();</script>');
    END IF;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 30_host_memory END -->'); END;
/
