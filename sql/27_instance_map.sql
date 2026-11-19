--
-- 27_instance_map.sql
-- Instance map (v1.7.0): the findings of section 07 drawn on a picture of
-- an Oracle instance, for the reader who is not a DBA ("WHERE in the
-- database is the problem?").  One inline SVG emitted here (complete with
-- JS off): Clients and network -> Sessions and CPU (+ Locks) -> SGA
-- (shared pool, buffer cache) -> background writers (DBWR, LGWR) ->
-- Storage (datafiles, redo logs, temp), plus "Other waits"; arrows for the
-- flows (calls, parse, reads, writes, redo).  The script
-- (sql/lib/js_instmap.plsql) only adds the popover, focus and the jump to
-- the finding card.
--
-- Each AREA is coloured by the worst bucket among the CANONICAL scored
-- metrics mapped to it (a twin never colours a box): large > moderate >
-- improved > normal > not measured.  The scoring is section 07's pass 1
-- verbatim -- the same LOAD (load_pairs_cte.sql) / METRIC (additive rule)
-- / WAIT (class rollup, template wait list) recompute, bucketed ONLY
-- through policy_bucket() -- and the mapping is ONE table below
-- (im_comp: policy family -> area).  A flagged area links to the finding
-- card of its lead metric's card group (card_id(card_group(family))):
-- 07 emits a card for every group with a canonical large / moderate row,
-- so the same condition here guarantees the target exists.  Agreement:
-- every card group maps to an area, an area's worst bucket is the worst
-- of its rows, each of which is on its card (verified on the DOM by the
-- owner's Playwright script: data-sev / data-cards vs article.fc).
--
-- Fewer than 3 valid prior windows (or no valid Current window): every
-- area "not measured", with the note; the recompute is skipped.
--
-- Read-only: SELECT only, the same views and grants as 07.  Cost: one
-- bounded scan per domain over the compared windows' snaps (07's query
-- without its per-window LISTAGG).
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 27_instance_map BEGIN -->'); END;
/

DECLARE
    TYPE im_row IS RECORD (
        dom        VARCHAR2(16),
        name       VARCHAR2(120),
        cur_val    NUMBER,
        mu         NUMBER,
        sd         NUMBER,
        n          NUMBER,
        z          NUMBER,
        shr        NUMBER,
        bucket     VARCHAR2(40),
        family     VARCHAR2(64),
        canonical  VARCHAR2(1),
        grp        VARCHAR2(64),
        comp       PLS_INTEGER
    );
    TYPE im_rows_t IS TABLE OF im_row INDEX BY PLS_INTEGER;
    TYPE num_t     IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE txt_t     IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;

    c_n         CONSTANT PLS_INTEGER := 11;   -- number of areas
    v_rows      im_rows_t;
    r           im_row;
    v_csev      num_t;      -- 4 large, 3 moderate, 2 improved, 1 normal, 0 not measured
    v_clead     num_t;      -- row index of the area's lead metric (0 = none)
    v_cards     txt_t;      -- distinct card ids, space separated, leading/trailing space
    v_nprior    NUMBER := 0;
    v_curok     NUMBER := 0;
    v_ok        BOOLEAN;
    v_note      VARCHAR2(400);
    v_svg       VARCHAR2(32767);
    v_line      VARCHAR2(32767);
    v_rd        VARCHAR2(4000);
    v_ls        VARCHAR2(4000);
    v_flag      VARCHAR2(4000);
    v_norm      VARCHAR2(4000);
    v_impr      VARCHAR2(4000);
    v_nm        VARCHAR2(4000);
    v_nflag     PLS_INTEGER := 0;
    v_nnorm     PLS_INTEGER := 0;
    v_nimpr     PLS_INTEGER := 0;
    v_nnm       PLS_INTEGER := 0;
    v_json      VARCHAR2(32767);
    v_ord       num_t;
    v_tmp       NUMBER;
    v_k         PLS_INTEGER;

    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql

    -- ===================== THE family -> area table =====================
    -- One line per policy family (sql/lib/metric_policy.plsql); a family
    -- not listed (WAIT:Cluster / Scheduler / Configuration /
    -- Administrative / Queueing / Other, OTHER:<name>, ...) is area 11.
    FUNCTION im_comp(p_family VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE
            WHEN p_family IN ('NETWORK', 'WAIT:Network', 'CALLS', 'SESSIONS')   THEN 1  -- clients
            WHEN p_family IN ('DB_TIME', 'CPU', 'CPU_WAIT_RATIO', 'RESPONSE',
                              'EXEC', 'ROLLBACK', 'SORTS')                     THEN 2  -- sessions / CPU
            WHEN p_family IN ('WAIT:Application', 'WAIT:Concurrency')         THEN 3  -- locks
            WHEN p_family IN ('PARSE', 'HARD_PARSE', 'CURSORS')               THEN 4  -- shared pool
            WHEN p_family IN ('LOGICAL_IO')                                   THEN 5  -- buffer cache
            WHEN p_family IN ('WRITE_IO')                                     THEN 6  -- DBWR
            WHEN p_family IN ('REDO', 'COMMIT', 'WAIT:Commit')                THEN 7  -- LGWR
            WHEN p_family IN ('READ_IO', 'SCANS', 'WAIT:User I/O')            THEN 8  -- datafiles
            WHEN p_family IN ('WAIT:System I/O')                              THEN 9  -- redo logs
            WHEN p_family IN ('SORTS_DISK')                                   THEN 10 -- temp
            ELSE 11 END;
    END im_comp;

    -- area vocabulary: key, box title, the phrase of the "Reads as" line,
    -- what is mapped to it, the metric that speaks for it when it is normal
    FUNCTION im_key(i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 'clients' WHEN 2 THEN 'sessions' WHEN 3 THEN 'locks'
                      WHEN 4 THEN 'shpool' WHEN 5 THEN 'bufcache' WHEN 6 THEN 'dbwr'
                      WHEN 7 THEN 'lgwr' WHEN 8 THEN 'datafiles' WHEN 9 THEN 'redologs'
                      WHEN 10 THEN 'temp' ELSE 'other' END;
    END im_key;

    FUNCTION im_title(i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 'Clients and network' WHEN 2 THEN 'Sessions and CPU'
                      WHEN 3 THEN 'Locks and concurrency' WHEN 4 THEN 'Shared pool'
                      WHEN 5 THEN 'Buffer cache' WHEN 6 THEN 'DB writer (DBWR)'
                      WHEN 7 THEN 'Log writer (LGWR)' WHEN 8 THEN 'Datafiles'
                      WHEN 9 THEN 'Redo logs' WHEN 10 THEN 'Temp' ELSE 'Other waits' END;
    END im_title;

    FUNCTION im_phrase(i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 'network' WHEN 2 THEN 'DB time / CPU' WHEN 3 THEN 'locks'
                      WHEN 4 THEN 'parse' WHEN 5 THEN 'logical reads' WHEN 6 THEN 'datafile writes'
                      WHEN 7 THEN 'commits / redo' WHEN 8 THEN 'datafile reads'
                      WHEN 9 THEN 'background I/O' WHEN 10 THEN 'temp' ELSE 'other waits' END;
    END im_phrase;

    FUNCTION im_what(i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE i
            WHEN 1  THEN 'User calls, bytes to and from clients, Network waits, sessions and logons'
            WHEN 2  THEN 'DB time, DB CPU, host CPU, SQL response time, executions, rollbacks'
            WHEN 3  THEN 'Application (row lock) and Concurrency waits'
            WHEN 4  THEN 'Parses, hard parses, parse failures, cursors'
            WHEN 5  THEN 'Logical reads'
            WHEN 6  THEN 'Physical writes, write volume, write I/O requests'
            WHEN 7  THEN 'Redo generated, redo writes, user commits, Commit waits'
            WHEN 8  THEN 'Physical reads, read volume, read latency, long table scans, User I/O waits'
            WHEN 9  THEN 'System I/O waits (log file and control file writes by the background)'
            WHEN 10 THEN 'Sorts that spilled to disk'
            ELSE 'Cluster, Scheduler, Configuration, Administrative, Queueing and Other waits' END;
    END im_what;

    FUNCTION im_pref(i PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 'LOAD:user calls' WHEN 2 THEN 'LOAD:DB time'
                      WHEN 3 THEN 'WAIT:Wait class: Application' WHEN 4 THEN 'LOAD:parse count (hard)'
                      WHEN 5 THEN 'LOAD:session logical reads' WHEN 6 THEN 'LOAD:physical writes'
                      WHEN 7 THEN 'LOAD:redo size' WHEN 8 THEN 'LOAD:physical reads'
                      WHEN 9 THEN 'WAIT:Wait class: System I/O' WHEN 10 THEN 'LOAD:sorts (disk)'
                      ELSE NULL END;
    END im_pref;

    -- box geometry in the SVG's 1040 x 410 user space: x, y, width (height 64)
    FUNCTION im_x(i PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 12 WHEN 2 THEN 214 WHEN 3 THEN 214 WHEN 4 THEN 452
                      WHEN 5 THEN 452 WHEN 6 THEN 668 WHEN 7 THEN 668 WHEN 8 THEN 870
                      WHEN 9 THEN 870 WHEN 10 THEN 870 ELSE 12 END;
    END im_x;

    FUNCTION im_y(i PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 140 WHEN 2 THEN 140 WHEN 3 THEN 262 WHEN 4 THEN 46
                      WHEN 5 THEN 140 WHEN 6 THEN 250 WHEN 7 THEN 330 WHEN 8 THEN 140
                      WHEN 9 THEN 330 WHEN 10 THEN 46 ELSE 330 END;
    END im_y;

    FUNCTION im_w(i PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE i WHEN 1 THEN 160 WHEN 2 THEN 166 WHEN 3 THEN 166 WHEN 4 THEN 170
                      WHEN 5 THEN 170 WHEN 6 THEN 154 WHEN 7 THEN 154 WHEN 8 THEN 158
                      WHEN 9 THEN 158 WHEN 10 THEN 158 ELSE 160 END;
    END im_w;

    FUNCTION sev_word(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p WHEN 4 THEN 'large' WHEN 3 THEN 'moderate' WHEN 2 THEN 'improved'
                      WHEN 1 THEN 'normal' ELSE 'not measured' END;
    END sev_word;

    -- s-large | s-moderate | s-improved | s-typical | s-nm (the band classes)
    FUNCTION sev_cls(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p WHEN 4 THEN 's-large' WHEN 3 THEN 's-moderate' WHEN 2 THEN 's-improved'
                      WHEN 1 THEN 's-typical' ELSE 's-nm' END;
    END sev_cls;

    FUNCTION row_sev(p_bucket VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN CASE p_bucket WHEN 'large' THEN 4 WHEN 'moderate' THEN 3 WHEN 'improved' THEN 2
                             WHEN 'typical' THEN 1 WHEN 'noted' THEN 1 WHEN 'flat baseline' THEN 1
                             ELSE 0 END;
    END row_sev;

    FUNCTION lab(p im_row) RETURN VARCHAR2 IS
    BEGIN
        RETURN metric_label(p.dom, p.name);
    END lab;

    -- a label cut to fit its box (the full name is in the table / popover)
    FUNCTION fit(p_s VARCHAR2, p_n PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF LENGTH(p_s) > p_n THEN
            RETURN DBMS_XMLGEN.CONVERT(RTRIM(SUBSTR(p_s, 1, p_n - 1))) || '&hellip;';
        END IF;
        RETURN DBMS_XMLGEN.CONVERT(p_s);
    END fit;

    -- the Delta text of delta_span() without its span (for SVG text)
    FUNCTION dtxt(p im_row) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_REPLACE(delta_span(p.cur_val, p.mu, p.bucket), '<[^>]*>', '');
    END dtxt;

    -- the same for an aria-label: plain words, no entities
    FUNCTION dtxt_aria(p im_row) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(dtxt(p), '&#9650; ', 'up '), '&#9660; ', 'down '),
                               '&times;', 'x'), '&mdash;', '');
    END dtxt_aria;

    FUNCTION val_txt(p im_row) RETURN VARCHAR2 IS
        v_s NUMBER := metric_scale(p.dom, p.name);
        v_u VARCHAR2(20) := metric_unit(p.dom, p.name);
    BEGIN
        RETURN fv(p.cur_val * v_s, v_u);
    END val_txt;

    FUNCTION rng_txt(p im_row) RETURN VARCHAR2 IS
        v_s NUMBER := metric_scale(p.dom, p.name);
        v_u VARCHAR2(20) := metric_unit(p.dom, p.name);
    BEGIN
        RETURN fv_range(p.mu * v_s, p.sd * v_s, v_u);
    END rng_txt;

    FUNCTION row_ent(p im_row) RETURN VARCHAR2 IS
    BEGIN
        RETURN ent(DBMS_XMLGEN.CONVERT(lab(p)), finding_anchor(p.dom, p.name), 'metric');
    END row_ent;

    -- an arrow: an axis-aligned polyline "x,y x,y ..." whose LAST segment
    -- carries the head; coloured / widened by the area it feeds
    FUNCTION arrow(p_pts VARCHAR2, p_comp PLS_INTEGER, p_dash BOOLEAN DEFAULT FALSE) RETURN VARCHAR2 IS
        v_n   PLS_INTEGER := REGEXP_COUNT(p_pts, ' ') + 1;
        v_a   VARCHAR2(40) := REGEXP_SUBSTR(p_pts, '[^ ]+', 1, v_n - 1);
        v_b   VARCHAR2(40) := REGEXP_SUBSTR(p_pts, '[^ ]+', 1, v_n);
        v_x1  NUMBER := TO_NUMBER(REGEXP_SUBSTR(v_a, '[^,]+', 1, 1));
        v_y1  NUMBER := TO_NUMBER(REGEXP_SUBSTR(v_a, '[^,]+', 1, 2));
        v_x2  NUMBER := TO_NUMBER(REGEXP_SUBSTR(v_b, '[^,]+', 1, 1));
        v_y2  NUMBER := TO_NUMBER(REGEXP_SUBSTR(v_b, '[^,]+', 1, 2));
        v_sv  NUMBER := v_csev(p_comp);
        v_hs  NUMBER := CASE WHEN v_sv = 4 THEN 9 WHEN v_sv = 3 THEN 8 ELSE 6 END;
        v_dx  NUMBER := SIGN(v_x2 - v_x1);
        v_dy  NUMBER := SIGN(v_y2 - v_y1);
        v_bx  NUMBER := v_x2 - v_dx * v_hs;
        v_by  NUMBER := v_y2 - v_dy * v_hs;
        v_hw  NUMBER := CASE v_hs WHEN 9 THEN 5 WHEN 8 THEN 4.5 ELSE 3.5 END;
        v_pre VARCHAR2(4000);
    BEGIN
        -- the line stops at the head's base; the head is a triangle
        v_pre := SUBSTR(p_pts, 1, INSTR(p_pts, ' ', -1)) || v_bx || ',' || v_by;
        RETURN '<g class="im-a ' || sev_cls(v_sv) || CASE WHEN p_dash THEN ' dash' END
            || '" data-c="' || im_key(p_comp) || '"><polyline points="' || v_pre || '"/>'
            || '<polygon points="' || v_x2 || ',' || v_y2 || ' '
            || (v_bx - v_dy * v_hw) || ',' || (v_by - v_dx * v_hw) || ' '
            || (v_bx + v_dy * v_hw) || ',' || (v_by + v_dx * v_hw) || '"/></g>';
    END arrow;

    FUNCTION alab(p_x NUMBER, p_y NUMBER, p_txt VARCHAR2, p_anchor VARCHAR2 DEFAULT 'middle') RETURN VARCHAR2 IS
    BEGIN
        RETURN '<text class="im-al" x="' || p_x || '" y="' || p_y || '" text-anchor="' || p_anchor
            || '">' || p_txt || '</text>';
    END alab;

    -- which of two rows leads an area: the higher bucket, then a member of
    -- its card's primary family (finding_cards.plsql card_primary: the
    -- physical-read count heads the I/O story, as on 07's card), then the
    -- larger |z|, then the shorter label
    FUNCTION lead_before(a im_row, b im_row) RETURN BOOLEAN IS
        v_pa PLS_INTEGER := CASE WHEN a.family = card_primary(a.grp) THEN 1 ELSE 0 END;
        v_pb PLS_INTEGER := CASE WHEN b.family = card_primary(b.grp) THEN 1 ELSE 0 END;
        v_za NUMBER := ROUND(ABS(NVL(a.z, 0)), 6);
        v_zb NUMBER := ROUND(ABS(NVL(b.z, 0)), 6);
    BEGIN
        IF row_sev(a.bucket) <> row_sev(b.bucket) THEN RETURN row_sev(a.bucket) > row_sev(b.bucket); END IF;
        IF v_pa <> v_pb THEN RETURN v_pa > v_pb; END IF;
        IF v_za <> v_zb THEN RETURN v_za > v_zb; END IF;
        RETURN LENGTH(lab(a)) < LENGTH(lab(b));
    END lead_before;

    -- the "Reads as" list join: "a", "a and b", "a, b and c"
    FUNCTION add_item(p_list VARCHAR2, p_item VARCHAR2, p_last BOOLEAN) RETURN VARCHAR2 IS
    BEGIN
        IF p_list IS NULL THEN RETURN p_item; END IF;
        RETURN p_list || CASE WHEN p_last THEN ' and ' ELSE ', ' END || p_item;
    END add_item;

BEGIN
    FOR i IN 1 .. c_n LOOP
        v_csev(i) := 0; v_clead(i) := 0; v_cards(i) := ' ';
    END LOOP;

    -- valid windows: the Current and the prior ones
    FOR w IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT SUM(CASE WHEN week_offset > 0 AND valid_flag = 'Y' THEN 1 ELSE 0 END) AS np,
               SUM(CASE WHEN week_offset = 0 AND valid_flag = 'Y' THEN 1 ELSE 0 END) AS cv
        FROM   windows_rollup
    ) LOOP
        v_nprior := NVL(w.np, 0);
        v_curok  := NVL(w.cv, 0);
    END LOOP;
    v_ok := v_nprior >= 3 AND v_curok > 0;
    IF NOT v_ok THEN
        v_note := CASE WHEN v_curok = 0 THEN 'The Current window has no valid snapshot pair'
                       ELSE 'Only ' || v_nprior || ' valid prior window'
                            || CASE WHEN v_nprior = 1 THEN '' ELSE 's' END
                            || ' (a metric needs at least 3 to be scored)' END
            || ', so no area could be measured.';
    END IF;

    IF v_ok THEN
        --
        -- Section 07's unified recompute (its pass-1 inputs), verbatim but
        -- for the per-window LISTAGG this view does not draw.
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
            SELECT 'LOAD' AS metric_domain, stat_name AS metric_name, week_offset,
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
            SELECT w.week_offset, t.metric_name, sm.snap_id, t.is_additive,
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
            SELECT 'METRIC' AS metric_domain, metric_name, week_offset,
                   AVG(snap_value) AS metric_value
            FROM   metric_per_snap
            GROUP BY week_offset, metric_name
        ),
        wait_targets AS (
            @@~template_dir/wait_event_targets.sql
        ),
        wait_pairs AS (
            SELECT w.week_offset, w.dur_sec, se.wait_class, se.event_name, se.snap_id,
                   se.time_waited_micro, se.instance_number,
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
            SELECT 'WAIT' AS metric_domain, 'Wait class: ' || wait_class AS metric_name, week_offset,
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
        pivoted AS (
            SELECT metric_domain, metric_name,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END)    AS cur_val,
                   AVG(CASE WHEN week_offset > 0 THEN metric_value END)    AS mu,
                   STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
                   COUNT(CASE WHEN week_offset > 0 THEN metric_value END)  AS n
            FROM   unified
            GROUP BY metric_domain, metric_name
        ),
        wait_total AS (
            SELECT SUM(metric_value) AS tot FROM wait_rows WHERE week_offset = 0
        )
        SELECT p.metric_domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.sd IS NULL THEN NULL
                   WHEN GREATEST(p.sd, 0.02 * ABS(p.mu)) = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / GREATEST(p.sd, 0.02 * ABS(p.mu))
               END AS z,
               CASE WHEN p.metric_domain = 'WAIT' AND t.tot > 0 THEN p.cur_val / t.tot END AS shr,
               CAST(NULL AS VARCHAR2(40)) AS bucket,
               CAST(NULL AS VARCHAR2(64)) AS family,
               CAST(NULL AS VARCHAR2(1))  AS canonical,
               CAST(NULL AS VARCHAR2(64)) AS grp,
               CAST(NULL AS NUMBER)       AS comp
        BULK COLLECT INTO v_rows
        FROM   pivoted p
        CROSS JOIN wait_total t
        WHERE  p.cur_val IS NOT NULL OR p.mu IS NOT NULL
        ORDER  BY p.metric_domain, ABS(NVL(
                   CASE WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.sd IS NULL THEN NULL
                        WHEN GREATEST(p.sd, 0.02 * ABS(p.mu)) = 0 THEN NULL
                        ELSE (p.cur_val - p.mu) / GREATEST(p.sd, 0.02 * ABS(p.mu)) END, 0)) DESC,
                  p.metric_name;
    END IF;

    --
    -- Pass 1, as in 07: policy, bucket (policy_bucket ONLY), card group;
    -- then the area of every row and each area's worst bucket / lead.
    --
    FOR i IN 1 .. v_rows.COUNT LOOP
        v_rows(i).family    := finding_family(v_rows(i).dom, v_rows(i).name);
        v_rows(i).canonical := is_canonical(v_rows(i).dom, v_rows(i).name);
        v_rows(i).bucket    := policy_bucket(v_rows(i).dom, v_rows(i).name, NULL,
                                             v_rows(i).cur_val, v_rows(i).mu, v_rows(i).sd,
                                             v_rows(i).n, v_rows(i).shr);
        v_rows(i).grp       := card_group(v_rows(i).family);
        v_rows(i).comp      := im_comp(v_rows(i).family);
        r := v_rows(i);
        IF r.canonical = 'Y' THEN
            v_csev(r.comp) := GREATEST(v_csev(r.comp), row_sev(r.bucket));
            IF r.bucket IN ('large', 'moderate')
               AND INSTR(v_cards(r.comp), ' ' || card_id(r.grp) || ' ') = 0 THEN
                v_cards(r.comp) := v_cards(r.comp) || card_id(r.grp) || ' ';
            END IF;
        END IF;
    END LOOP;

    -- the lead of each area: flagged -> loudest flagged row (lead_before);
    -- improved -> the same rule over the improved rows; otherwise the area's speaking metric when present,
    -- else its measured row with the largest |z|
    FOR i IN 1 .. v_rows.COUNT LOOP
        r := v_rows(i);
        v_k := r.comp;
        IF r.canonical = 'Y' THEN
            IF v_csev(v_k) >= 2 THEN
                IF row_sev(r.bucket) = v_csev(v_k) OR (v_csev(v_k) >= 3 AND row_sev(r.bucket) >= 3) THEN
                    IF v_clead(v_k) = 0 THEN
                        v_clead(v_k) := i;
                    ELSIF lead_before(r, v_rows(v_clead(v_k))) THEN
                        v_clead(v_k) := i;
                    END IF;
                END IF;
            ELSIF r.dom || ':' || r.name = im_pref(v_k)
                  AND (row_sev(r.bucket) >= 1 OR v_csev(v_k) = 0) THEN
                v_clead(v_k) := i;
            END IF;
        END IF;
    END LOOP;
    FOR i IN 1 .. v_rows.COUNT LOOP
        r := v_rows(i);
        IF r.canonical = 'Y' AND v_clead(r.comp) = 0 AND row_sev(r.bucket) >= 1 THEN
            v_clead(r.comp) := i;
        END IF;
    END LOOP;

    --
    -- "Reads as": flagged areas loudest first, then improved, normal and
    -- not-measured areas in map order.
    --
    FOR i IN 1 .. c_n LOOP v_ord(i) := i; END LOOP;
    FOR i IN 2 .. c_n LOOP
        v_k := i;
        WHILE v_k > 1 AND (v_csev(v_ord(v_k)) > v_csev(v_ord(v_k - 1))
              OR (v_csev(v_ord(v_k)) = v_csev(v_ord(v_k - 1)) AND v_csev(v_ord(v_k)) >= 3
                  AND ABS(NVL(v_rows(v_clead(v_ord(v_k))).z, 0)) > ABS(NVL(v_rows(v_clead(v_ord(v_k - 1))).z, 0)))) LOOP
            v_tmp := v_ord(v_k); v_ord(v_k) := v_ord(v_k - 1); v_ord(v_k - 1) := v_tmp;
            v_k := v_k - 1;
        END LOOP;
    END LOOP;
    FOR p IN 1 .. c_n LOOP
        v_k := v_ord(p);
        IF v_csev(v_k) >= 3 THEN v_nflag := v_nflag + 1;
        ELSIF v_csev(v_k) = 2 THEN v_nimpr := v_nimpr + 1;
        ELSIF v_csev(v_k) = 1 THEN v_nnorm := v_nnorm + 1;
        ELSE v_nnm := v_nnm + 1; END IF;
    END LOOP;
    DECLARE
        a PLS_INTEGER := 0; b PLS_INTEGER := 0; c PLS_INTEGER := 0; d PLS_INTEGER := 0;
    BEGIN
        FOR p IN 1 .. c_n LOOP
            v_k := v_ord(p);
            IF v_csev(v_k) >= 3 THEN
                a := a + 1;
                v_flag := add_item(v_flag, '<b>' || im_phrase(v_k) || '</b> (' || sev_word(v_csev(v_k))
                    || ', ' || dtxt(v_rows(v_clead(v_k))) || ')', a = v_nflag);
            ELSIF v_csev(v_k) = 2 THEN
                b := b + 1; v_impr := add_item(v_impr, im_phrase(v_k), b = v_nimpr);
            ELSIF v_csev(v_k) = 1 THEN
                c := c + 1; v_norm := add_item(v_norm, im_phrase(v_k), c = v_nnorm);
            ELSE
                d := d + 1; v_nm := add_item(v_nm, im_phrase(v_k), d = v_nnm);
            END IF;
        END LOOP;
    END;
    IF NOT v_ok THEN
        v_rd := 'not measured: ' || v_note;
        v_ls := 'not measured, too little history';
    ELSIF v_nflag = 0 AND v_nnm = 0 AND v_nimpr = 0 THEN
        v_rd := 'all ' || c_n || ' areas normal.';
        v_ls := 'all ' || c_n || ' areas normal';
    ELSIF v_nflag = 0 THEN
        v_rd := 'no area flagged'
            || CASE WHEN v_nimpr > 0 THEN '; ' || v_impr || ' improved' END
            || CASE WHEN v_nnorm > 0 THEN '; ' || v_norm || CASE WHEN v_nnorm = 1 THEN ' is' ELSE ' are' END || ' normal' END
            || CASE WHEN v_nnm > 0 THEN '; not measured: ' || v_nm END || '.';
        v_ls := 'no area flagged' || CASE WHEN v_nnm > 0 THEN ', ' || v_nnm || ' not measured' END;
    ELSE
        v_rd := '<b>' || v_nflag || '</b> of ' || c_n || ' areas flagged: ' || v_flag
            || CASE WHEN v_nimpr > 0 THEN '; ' || v_impr || ' improved' END
            || CASE WHEN v_nnorm > 0 THEN '; ' || v_norm || CASE WHEN v_nnorm = 1 THEN ' is' ELSE ' are' END || ' normal' END
            || CASE WHEN v_nnm > 0 THEN '; not measured: ' || v_nm END || '.';
        v_ls := '<b>' || v_nflag || '</b> of ' || c_n || ' areas flagged: ';
        DECLARE a PLS_INTEGER := 0; BEGIN
            FOR p IN 1 .. c_n LOOP
                v_k := v_ord(p);
                IF v_csev(v_k) >= 3 THEN
                    a := a + 1;
                    v_ls := v_ls || CASE WHEN a > 1 THEN CASE WHEN a = v_nflag THEN ' and ' ELSE ', ' END END
                        || im_phrase(v_k);
                END IF;
            END LOOP;
        END;
    END IF;

    --
    -- Markup: heading, legend, the map, the popover sources, "Reads as",
    -- the table.
    --
    DBMS_OUTPUT.PUT_LINE('<section id="instance-map" class="vw in-s in-a lib'
        || CASE WHEN v_nflag > 0 THEN ' lopen' END || '" style="--os:17"><h2>Instance map'
        || '<small class="h2sub">Where in the database the findings sit: each area takes the worst score of the metrics behind it</small></h2>');
    DBMS_OUTPUT.PUT_LINE(lib_ls('instance-map', v_ls));
    DBMS_OUTPUT.PUT_LINE('<div class="im-wrap">');
    DBMS_OUTPUT.PUT_LINE('<ul class="im-lg" aria-label="Legend">'
        || '<li><i class="im-k s-large"></i>large</li><li><i class="im-k s-moderate"></i>moderate</li>'
        || '<li><i class="im-k s-improved"></i>improved</li><li><i class="im-k s-typical"></i>normal</li>'
        || '<li><i class="im-k s-nm"></i>not measured</li>'
        || '<li class="im-lgn">arrows: the flows; a thicker, coloured arrow feeds a flagged area</li></ul>');
    IF v_note IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">' || v_note || '</p>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('<div class="im-scroll"><svg class="im-svg" viewBox="0 0 1040 410" role="img" aria-label="'
        || 'Instance map: ' || REPLACE(REGEXP_REPLACE(v_rd, '<[^>]*>', ''), '"', '') || '">');
    -- containers
    DBMS_OUTPUT.PUT_LINE('<rect class="im-ct" x="440" y="16" width="194" height="200" rx="10"/>'
        || '<text class="im-cl" x="452" y="34">SGA (shared memory)</text>'
        || '<rect class="im-ct" x="858" y="16" width="176" height="388" rx="10"/>'
        || '<text class="im-cl" x="870" y="34">Storage</text>'
        || '<text class="im-cl" x="668" y="242">Background writers</text>'
        || '<text class="im-cl" x="214" y="128">Server processes</text>');
    -- arrows (under the boxes)
    DBMS_OUTPUT.PUT_LINE(arrow('172,172 212,172', 1) || alab(192, 164, 'calls')
        || arrow('380,164 450,164', 5) || alab(415, 156, 'reads')
        || arrow('340,140 340,78 450,78', 4) || alab(395, 70, 'parse')
        || arrow('868,172 624,172', 8) || alab(746, 164, 'physical reads')
        || arrow('537,204 537,282 666,282', 6) || alab(600, 274, 'writes')
        || arrow('822,282 949,282 949,206', 6)
        || arrow('380,196 400,196 400,362 666,362', 7) || alab(533, 354, 'redo')
        || arrow('822,362 868,362', 7)
        || arrow('297,204 297,260', 3, TRUE));
    -- the boxes
    FOR i IN 1 .. c_n LOOP
        DECLARE
            v_x   PLS_INTEGER := im_x(i);
            v_y   PLS_INTEGER := im_y(i);
            v_w   PLS_INTEGER := im_w(i);
            v_sv  NUMBER := v_csev(i);
            v_l   PLS_INTEGER := v_clead(i);
            v_c1  VARCHAR2(80) := TRIM(v_cards(i));
            v_c1a VARCHAR2(80);
            v_sub VARCHAR2(400);
            v_st  VARCHAR2(400);
            v_ar  VARCHAR2(1000);
            v_tag VARCHAR2(2000);
        BEGIN
            -- the card of the lead metric's group (07 emits it: the lead is
            -- a canonical large / moderate row of that group)
            IF v_sv >= 3 THEN
                v_c1a := card_id(v_rows(v_l).grp);
            END IF;
            IF v_l > 0 THEN
                v_sub := fit(lab(v_rows(v_l)), 24);
            ELSIF NOT v_ok THEN
                v_sub := 'too little history';
            ELSE
                v_sub := 'no data in this run';
            END IF;
            v_st := '<tspan class="im-sw">' || sev_word(v_sv) || '</tspan>'
                || CASE WHEN v_sv >= 2 AND v_l > 0 THEN ' &middot; ' || dtxt(v_rows(v_l)) END;
            v_ar := im_title(i) || ': ' || sev_word(v_sv)
                || CASE WHEN v_l > 0 THEN ', ' || lab(v_rows(v_l)) || ' ' || dtxt_aria(v_rows(v_l)) END;
            v_tag := ' class="im-n ' || sev_cls(v_sv) || '" data-c="' || im_key(i) || '" data-sev="'
                || sev_word(v_sv) || '" data-cards="' || v_c1 || '"';
            IF v_c1a IS NOT NULL THEN
                v_line := '<a href="#' || v_c1a || '"' || v_tag || ' aria-label="'
                    || DBMS_XMLGEN.CONVERT(v_ar) || '. Open its finding card">';
            ELSE
                v_line := '<g tabindex="0"' || v_tag || ' aria-label="' || DBMS_XMLGEN.CONVERT(v_ar) || '">';
            END IF;
            v_line := v_line
                || '<rect class="im-b" x="' || v_x || '" y="' || v_y || '" width="' || v_w
                || '" height="64" rx="8"/>'
                || '<text class="im-t" x="' || (v_x + 12) || '" y="' || (v_y + 21) || '">'
                || DBMS_XMLGEN.CONVERT(im_title(i)) || '</text>'
                || '<text class="im-m" x="' || (v_x + 12) || '" y="' || (v_y + 38) || '">' || v_sub || '</text>'
                || '<circle class="im-d" cx="' || (v_x + 16) || '" cy="' || (v_y + 51) || '" r="4"/>'
                || '<text class="im-s" x="' || (v_x + 26) || '" y="' || (v_y + 55) || '">' || v_st || '</text>'
                || CASE WHEN v_c1a IS NOT NULL THEN '</a>' ELSE '</g>' END;
            DBMS_OUTPUT.PUT_LINE(v_line);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</svg></div>');

    -- popover sources (hidden; js_instmap shows one beside its box)
    FOR i IN 1 .. c_n LOOP
        DECLARE
            v_l PLS_INTEGER := v_clead(i);
            v_n PLS_INTEGER := 0;
            v_c VARCHAR2(4000);
            v_g VARCHAR2(80);
        BEGIN
            v_line := '<div class="im-src" data-c="' || im_key(i) || '" hidden><b class="im-pt">'
                || DBMS_XMLGEN.CONVERT(im_title(i)) || '</b> <span class="im-st ' || sev_cls(v_csev(i))
                || '"><i class="im-k ' || sev_cls(v_csev(i)) || '"></i>' || sev_word(v_csev(i)) || '</span>'
                || '<p class="im-pw">' || DBMS_XMLGEN.CONVERT(im_what(i)) || '</p>';
            IF v_csev(i) >= 3 THEN
                v_line := v_line || '<ul class="im-pm">';
                FOR p IN 1 .. v_rows.COUNT LOOP
                    IF v_rows(p).comp = i AND v_rows(p).canonical = 'Y'
                       AND v_rows(p).bucket IN ('large', 'moderate') THEN
                        v_n := v_n + 1;
                        IF v_n <= 8 THEN
                            v_line := v_line || '<li>' || row_ent(v_rows(p)) || ' <span class="im-pv">'
                                || nbu(val_txt(v_rows(p))) || ', normal ' || rng_txt(v_rows(p)) || '</span> '
                                || delta_span(v_rows(p).cur_val, v_rows(p).mu, v_rows(p).bucket) || '</li>';
                        END IF;
                    END IF;
                END LOOP;
                IF v_n > 8 THEN
                    v_line := v_line || '<li class="im-pmore">and ' || (v_n - 8) || ' more (table below)</li>';
                END IF;
                v_line := v_line || '</ul><p class="im-pc">';
                -- one link per finding card behind the area, named like the card
                v_c := ' ';
                FOR p IN 1 .. v_rows.COUNT LOOP
                    IF v_rows(p).comp = i AND v_rows(p).canonical = 'Y'
                       AND v_rows(p).bucket IN ('large', 'moderate') THEN
                        v_g := card_id(v_rows(p).grp);
                        IF INSTR(v_c, ' ' || v_g || ' ') = 0 THEN
                            v_c := v_c || v_g || ' ';
                            v_line := v_line || '<a class="im-go" href="#' || v_g || '">'
                                || DBMS_XMLGEN.CONVERT(card_label(v_rows(p).grp)) || ' card &rarr;</a> ';
                        END IF;
                    END IF;
                END LOOP;
                v_line := v_line || '</p>';
            ELSIF v_l > 0 THEN
                v_line := v_line || '<ul class="im-pm"><li>' || row_ent(v_rows(v_l)) || ' <span class="im-pv">'
                    || nbu(val_txt(v_rows(v_l))) || ', normal ' || rng_txt(v_rows(v_l)) || '</span> '
                    || delta_span(v_rows(v_l).cur_val, v_rows(v_l).mu, v_rows(v_l).bucket) || '</li></ul>';
            ELSE
                v_line := v_line || '<p class="im-pw">' || NVL(v_note, 'No metric of this area has data in this run.') || '</p>';
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_line || '</div>');
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('<div class="im-pop" role="dialog" aria-label="Area details" hidden></div>');
    DBMS_OUTPUT.PUT_LINE('<p class="im-rd"><b>Reads as:</b> ' || v_rd || '</p>');
    DBMS_OUTPUT.PUT_LINE('</div>');

    -- the numbers behind the map
    DBMS_OUTPUT.PUT_LINE('<div class="im-tscroll"><table class="im-tbl" data-nocount><caption>The areas and their metrics</caption>'
        || '<thead><tr><th>Area</th><th>Status</th><th>Lead metric</th><th class="num cur-col">Current</th>'
        || '<th class="num">Normal range</th><th class="num">&Delta; vs mean</th><th>Other flagged metrics</th>'
        || '</tr></thead><tbody>');
    FOR i IN 1 .. c_n LOOP
        DECLARE
            v_l  PLS_INTEGER := v_clead(i);
            v_o  VARCHAR2(32767);
            v_no PLS_INTEGER := 0;
        BEGIN
            IF v_csev(i) >= 3 THEN
                FOR p IN 1 .. v_rows.COUNT LOOP
                    IF v_rows(p).comp = i AND v_rows(p).canonical = 'Y' AND p <> v_l
                       AND v_rows(p).bucket IN ('large', 'moderate') THEN
                        v_no := v_no + 1;
                        v_o := v_o || CASE WHEN v_no > 1 THEN ', ' END || row_ent(v_rows(p))
                            || ' ' || delta_span(v_rows(p).cur_val, v_rows(p).mu, v_rows(p).bucket);
                    END IF;
                END LOOP;
            END IF;
            v_line := '<tr data-c="' || im_key(i) || '"'
                || CASE v_csev(i) WHEN 4 THEN ' class="crit"' WHEN 3 THEN ' class="warn"' END || '>'
                || '<td title="' || DBMS_XMLGEN.CONVERT(im_what(i)) || '">' || DBMS_XMLGEN.CONVERT(im_title(i)) || '</td>'
                || '<td class="im-tst"><i class="im-k ' || sev_cls(v_csev(i)) || '"></i>' || sev_word(v_csev(i)) || '</td>';
            IF v_l > 0 THEN
                v_line := v_line || '<td>' || row_ent(v_rows(v_l)) || '</td>'
                    || '<td class="num" data-w="0">' || nbu(val_txt(v_rows(v_l))) || '</td>'
                    || '<td class="num">' || rng_txt(v_rows(v_l)) || '</td>'
                    || '<td class="num">' || delta_span(v_rows(v_l).cur_val, v_rows(v_l).mu, v_rows(v_l).bucket) || '</td>';
            ELSE
                v_line := v_line || '<td>&mdash;</td><td class="num" data-w="0">&mdash;</td>'
                    || '<td class="num">&mdash;</td><td class="num">&mdash;</td>';
            END IF;
            DBMS_OUTPUT.PUT_LINE(v_line || '<td>' || NVL(v_o, '&mdash;') || '</td></tr>');
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table></div>');

    -- payload: per area its bucket and the finding cards it stands for
    v_json := '<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.instmap={"areas":' || c_n
        || ',"measured":' || CASE WHEN v_ok THEN 'true' ELSE 'false' END || ',"comps":[';
    FOR i IN 1 .. c_n LOOP
        v_json := v_json || CASE WHEN i > 1 THEN ',' END || '{"k":"' || im_key(i) || '","sev":"'
            || sev_word(v_csev(i)) || '","cards":['
            || CASE WHEN TRIM(v_cards(i)) IS NOT NULL
                    THEN '"' || REPLACE(TRIM(v_cards(i)), ' ', '","') || '"' END || ']}';
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(v_json || ']};</script>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

@@sql/lib/js_instmap.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 27_instance_map END -->'); END;
/
