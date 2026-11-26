--
-- 07_summary.sql
-- For every scalar metric rendered by sections 02-04, compute the z-score
-- of the current window against the mean/stddev of the prior valid windows,
-- bucket the change magnitude (large / moderate / improved / typical) and
-- render (v1.6.0, Mock D):
--   Summary view   one finding CARD per card group of metric_policy
--                  families (sql/lib/finding_cards.plsql: Physical I/O,
--                  DB time, Network, Commit, ...), each with its headline,
--                  Current value and normal range, the band glyph, a
--                  window chart (sql/lib/wingrid.plsql), up to four
--                  evidence rows, the "N related metrics" fold and a
--                  "Timeline ->" link; then "What changed around it" (an
--                  empty slot sections 12 fills with its configuration card)
--                  and "Checked and normal" (every scored metric that did
--                  not move: a calm grid, "moved, too small to matter",
--                  "improved").
--   All sections   the per-domain detail tables (every scored row, band
--                  cells, prior mean / sd / n) -- the anchors every entity
--                  link to a metric lands on (fr-<l|m|w>-<name>).
-- v1.5.0's "Biggest movers" table is gone: its rows are the card leads and
-- their related metrics; every number stays in the detail tables.
--
-- Buckets describe how far the current value sits from its baseline of
-- prior comparison windows; "large" is not a value judgement, just a
-- |z| > 3 outlier that also clears the materiality floor.  The ONE rule is
-- policy_bucket() in sql/lib/metric_policy.plsql (sigma floor 2% of |mean|,
-- per-metric materiality floors and direction); twins (canonical = 'N')
-- are scored and shown muted but never counted.
--
-- Card order and lead (shared with the verdict in 00_params.sql through
-- sql/lib/finding_cards.plsql): a card is led by its loudest large (else
-- moderate) member of the card's primary family, else of any family;
-- cards whose time measure rose by 0.01 AAS or more come first, by the AAS added (impact,
-- v1.7; a wait class counts its foreground time only, read from the same
-- DBA_HIST_SYSTEM_EVENT rows as its all-session class row); then DB time;
-- then the rest, large before moderate and by the largest |z| of any
-- member; then a flagged DB time card moves up to second place.
--
-- Implementation note: the unified LOAD/METRIC/WAIT recompute is
-- BULK COLLECTed exactly once into a PL/SQL collection; every view below
-- walks it (no second recompute).  The card evidence adds ONE bounded
-- event-level DBA_HIST_SYSTEM_EVENT scan (the top events of each flagged
-- wait class), same pairs -> bounds -> deltas shape as 04.
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- persist anything.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 07_summary BEGIN -->'); END;
/

DECLARE
    TYPE finding_rec IS RECORD (
        metric_domain  VARCHAR2(16),
        metric_name    VARCHAR2(120),
        cur_val        NUMBER,
        prior_mean     NUMBER,
        prior_sd       NUMBER,
        n_prior        NUMBER,
        z_score        NUMBER,
        pct_delta      NUMBER,
        change_bucket  VARCHAR2(40),
        heat_pos       NUMBER,
        family         VARCHAR2(64),
        canonical      VARCHAR2(1),
        dir            VARCHAR2(4),
        shr            NUMBER,
        wv             VARCHAR2(4000),
        grp            VARCHAR2(64),
        fg_d           NUMBER         -- wait-class rows: foreground Current - prior mean, AAS (impact)
    );
    TYPE findings_t  IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    TYPE idx_t       IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    TYPE fam_idx_t   IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);
    TYPE gz_t        IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    TYPE ord_t       IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
    -- one event of a flagged wait class (card evidence, all sessions)
    TYPE ev_rec IS RECORD (
        wclass  VARCHAR2(64),
        event   VARCHAR2(128),
        cur_val NUMBER,
        mu      NUMBER,
        sd      NUMBER,
        n       NUMBER,
        shr     NUMBER
    );
    TYPE ev_t IS TABLE OF ev_rec INDEX BY PLS_INTEGER;
    -- v1.7 "Where the extra DB time went" (plan 021): one part per wait
    -- class and one for DB CPU, in AAS above the prior mean
    TYPE part_rec IS RECORD (
        lab VARCHAR2(64),     -- 'CPU' or the wait class name
        d   NUMBER,           -- Current - prior mean, AAS (may be negative)
        grp VARCHAR2(64),     -- the card group this part is the time measure of
        aid VARCHAR2(200)     -- link target: the card, else the detail row
    );
    TYPE part_t IS TABLE OF part_rec INDEX BY PLS_INTEGER;

    v_findings   findings_t;
    v_table_idx  idx_t;
    f            finding_rec;
    v_evs        ev_t;
    v_flagcls    fam_idx_t;     -- wait classes with a flagged class row

    v_total      NUMBER := 0;
    v_crit       NUMBER := 0;
    v_warn       NUMBER := 0;
    v_impr       NUMBER := 0;
    v_noted      NUMBER := 0;
    v_folded     NUMBER := 0;
    v_normal     NUMBER := 0;
    v_n_tbl      PLS_INTEGER := 0;
    v_weeks_back NUMBER := ~weeks_back;
    j            PLS_INTEGER;

    -- cards: group -> lead index / severity / loudest |z|; v_order = card order
    v_glead      fam_idx_t;
    v_gsev       fam_idx_t;
    v_gz         gz_t;
    v_gimp       gz_t;          -- card group -> impact, AAS added above normal (v1.7)
    v_ig         VARCHAR2(64);
    v_order      ord_t;
    v_g          VARCHAR2(64);
    v_tmp        VARCHAR2(64);
    v_wait_flag  BOOLEAN := FALSE;
    v_dbt        PLS_INTEGER;
    v_cpu        PLS_INTEGER;
    v_meta       VARCHAR2(4000);
    v_cw_dbid    NUMBER;   -- plan 033: the Current window's DBID and snapshot range,
    v_cw_b       NUMBER;   --   for the cards' read-only "Next step" queries
    v_cw_e       NUMBER;
    v_cw_t0      VARCHAR2(19);    -- its nominal start / end (ASH queries: sample_time)
    v_cw_t1      VARCHAR2(19);
    v_cw_inst    VARCHAR2(4000);  -- its valid instances, only when one was skipped (RAC)
    v_open_g     VARCHAR2(64);   -- plan 025: the one card that starts open (Summary)
    v_parts      part_t;
    v_ncl        PLS_INTEGER := 0;   -- large finding cards (v1.7: a finding is a card)
    v_ncm        PLS_INTEGER := 0;   -- moderate finding cards

    @@sql/lib/metric_policy.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/baseline_conf.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql
    @@sql/lib/finding_hints.plsql
    @@sql/lib/json_escape.plsql

    -- plan 040: a number as a JSON token: '.' decimal, no exponent, no
    -- leading-dot form (TO_CHAR of 0.5 can read '.5'), null for NULL or a
    -- value past 15 integer digits
    FUNCTION json_num(p_v NUMBER, p_dec PLS_INTEGER DEFAULT 6) RETURN VARCHAR2 IS
    BEGIN
        IF p_v IS NULL OR ABS(p_v) >= 1e15 THEN RETURN 'null'; END IF;
        RETURN RTRIM(TO_CHAR(ROUND(p_v, p_dec), 'FM999999999999990D999999',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END json_num;

    -- Entity anchors (v1.6.0): the id of THIS finding's row is
    -- finding_anchor(domain, name) = fr-<l|m|w>-<name> (sql/lib/anchor_id
    -- .plsql), the target of every entity link to a metric; src_link()
    -- points at the source row in 02 / 03 / 04 that produced it.
    FUNCTION find_id(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN finding_anchor(p_dom, p_name);
    END find_id;

    -- a card's impact (AAS its time measure added above its prior mean), NULL when none
    FUNCTION g_imp(p_g VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF v_gimp.EXISTS(p_g) THEN RETURN v_gimp(p_g); END IF;
        RETURN NULL;
    END g_imp;

    -- a card's share of the DB-time rise, integer percent; NULL when the
    -- card added less than 0.01 AAS (imp_on), DB time did not rise, or the
    -- share passes 100 (up to 100.5% is kept, shown as 100: never "101%")
    FUNCTION g_shr(p_g VARCHAR2) RETURN NUMBER IS
        v_i NUMBER := g_imp(p_g);
        v_d NUMBER := g_imp('DBTIME');
    BEGIN
        IF imp_on(v_i) AND v_d > 0 AND v_i <= v_d * 1.005 THEN
            RETURN LEAST(100, ROUND(v_i / v_d * 100));
        END IF;
        RETURN NULL;
    END g_shr;

    FUNCTION src_link(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN ' <a class="xlink" href="#'
            || CASE p_dom
                   WHEN 'LOAD'   THEN anchor_id('load', p_name)
                   WHEN 'METRIC' THEN anchor_id('metric', p_name)
                   ELSE anchor_id('wc', REGEXP_REPLACE(p_name, '^Wait class: ', ''))
               END
            || '" title="Go to this metric''s row in '
            || CASE p_dom WHEN 'LOAD' THEN 'Load profile'
                          WHEN 'METRIC' THEN 'System metrics'
                          ELSE 'Foreground waits' END
            || '">&#8599; row</a>';
    END src_link;

    -- Detail-table order: severity rank, |z| DESC, |pct| DESC, name.
    FUNCTION tbl_rank(p_bucket VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE p_bucket WHEN 'large'                THEN 1
                             WHEN 'moderate'             THEN 2
                             WHEN 'improved'             THEN 3
                             WHEN 'noted'                THEN 3
                             WHEN 'insufficient history' THEN 4
                             WHEN 'n/a'                  THEN 4
                             WHEN 'flat baseline'        THEN 5
                             ELSE 6 END;
    END tbl_rank;

    FUNCTION tbl_before(a finding_rec, b finding_rec) RETURN BOOLEAN IS
    BEGIN
        IF tbl_rank(a.change_bucket) <> tbl_rank(b.change_bucket) THEN
            RETURN tbl_rank(a.change_bucket) < tbl_rank(b.change_bucket);
        END IF;
        IF ABS(NVL(a.z_score, 0)) <> ABS(NVL(b.z_score, 0)) THEN
            RETURN ABS(NVL(a.z_score, 0)) > ABS(NVL(b.z_score, 0));
        END IF;
        IF ABS(NVL(a.pct_delta, 0)) <> ABS(NVL(b.pct_delta, 0)) THEN
            RETURN ABS(NVL(a.pct_delta, 0)) > ABS(NVL(b.pct_delta, 0));
        END IF;
        RETURN a.metric_name < b.metric_name;
    END tbl_before;

    FUNCTION bucket_cls(p_bucket VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_bucket WHEN 'large'    THEN 'crit'
                             WHEN 'moderate' THEN 'warn'
                             WHEN 'typical'  THEN 'ok'
                             WHEN 'improved' THEN 'imp'
                             WHEN 'noted'    THEN 'note'
                             ELSE 'skip' END;
    END bucket_cls;

    -- a metric's value / scale / unit helpers over one finding
    FUNCTION f_scale(r finding_rec) RETURN NUMBER IS
    BEGIN
        RETURN metric_scale(r.metric_domain, r.metric_name);
    END f_scale;

    FUNCTION f_unit(r finding_rec) RETURN VARCHAR2 IS
    BEGIN
        RETURN metric_unit(r.metric_domain, r.metric_name);
    END f_unit;

    FUNCTION f_label(r finding_rec) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_XMLGEN.CONVERT(metric_label(r.metric_domain, r.metric_name));
    END f_label;

    FUNCTION f_ent(r finding_rec) RETURN VARCHAR2 IS
    BEGIN
        RETURN ent(f_label(r), find_id(r.metric_domain, r.metric_name), 'metric');
    END f_ent;

    FUNCTION dom_word(p_dom VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_dom WHEN 'LOAD' THEN 'Load' WHEN 'METRIC' THEN 'Metric' ELSE 'Wait' END;
    END dom_word;

    -- one evidence row of a card: kind | name + description | Delta + band
    FUNCTION ev_row(p_dt VARCHAR2, p_id VARCHAR2, p_txt BOOLEAN, p_de VARCHAR2,
                    p_cur NUMBER, p_mu NUMBER, p_sd NUMBER, p_bucket VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="evr"><dt>' || p_dt || '</dt><dd><span class="id'
            || CASE WHEN p_txt THEN ' txt' END || '">' || p_id || '</span>'
            || '<span class="de">' || nbu(p_de) || '</span></dd>'
            || '<div class="m">' || delta_span(p_cur, p_mu, p_bucket)
            || band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm', 'N', 10) || '</div></div>';
    END ev_row;

    -- the band glyph's axis under a card's large band
    FUNCTION band_axis RETURN VARCHAR2 IS
    BEGIN
        RETURN '<span class="bd-ax" aria-hidden="true"><em style="--x:.167">&minus;2</em>'
            || '<em style="--x:.333">0</em><em style="--x:.500">+2</em>'
            || '<em style="--x:.583">+3</em><em class="end" style="--x:1">+8&sigma;</em></span>';
    END band_axis;

    -- a "checked and normal" row: name + normal range | band | value + Delta
    FUNCTION nr_row(r finding_rec) RETURN VARCHAR2 IS
        v_s NUMBER := f_scale(r);
        v_u VARCHAR2(20) := f_unit(r);
    BEGIN
        RETURN '<div class="nr"><div class="l" title="' || DBMS_XMLGEN.CONVERT(r.metric_name) || '">'
            || f_ent(r) || '<small>normal ' || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u)
            || '</small></div>'
            || band_span(r.z_score, r.change_bucket, 'sm', CASE WHEN r.canonical = 'N' THEN 'Y' ELSE 'N' END, 10)
            || '<div class="vv">' || fv(r.cur_val * v_s, v_u)
            || '<small>' || delta_span(r.cur_val, r.prior_mean, r.change_bucket) || '</small></div></div>';
    END nr_row;

    PROCEDURE emit_domain_table(p_dom VARCHAR2, p_title VARCHAR2) IS
        v_row      VARCHAR2(32767);
        v_sev      VARCHAR2(40);
        v_cls      VARCHAR2(10);
        v_imp      VARCHAR2(1);
        v_count    PLS_INTEGER := 0;
        v_tail_cnt PLS_INTEGER := 0;
        v_tbl_id   VARCHAR2(30);
        rec        finding_rec;
    BEGIN
        FOR p IN 1 .. v_table_idx.COUNT LOOP
            rec := v_findings(v_table_idx(p));
            IF rec.metric_domain = p_dom THEN
                v_count := v_count + 1;
                -- T1: rows whose severity is "typical" (OK), flat baseline
                -- or insufficient history are tail candidates the
                -- expander collapses.
                IF rec.change_bucket IN ('typical', 'flat baseline', 'insufficient history',
                                         'improved', 'noted') THEN
                    v_tail_cnt := v_tail_cnt + 1;
                END IF;
            END IF;
        END LOOP;
        IF v_count = 0 THEN RETURN; END IF;

        v_tbl_id := 'findings-' || LOWER(p_dom);

        -- All sections only (class "vw in-a"): the per-domain detail
        -- tables, their headings and expanders.  The bucket is drawn by
        -- the band glyph (sql/lib/band_glyph.plsql); the row keeps its
        -- crit / warn / ... class (2px marker, rail counts, J / K).
        DBMS_OUTPUT.PUT_LINE('<h3 class="vw in-a">' || p_title || '</h3>');
        DBMS_OUTPUT.PUT_LINE('<table id="' || v_tbl_id || '" class="vw in-a">'
            || '<thead><tr>'
            || '<th>Metric</th>'
            || '<th class="num cur-col">Current</th>'
            || band_head
            || '<th class="num">Prior mean</th>'
            || '<th class="num">Prior sd</th>'
            || '<th class="num">n</th>'
            || '</tr></thead><tbody>');

        FOR p IN 1 .. v_table_idx.COUNT LOOP
            rec := v_findings(v_table_idx(p));
            IF rec.metric_domain = p_dom THEN
                v_sev := rec.change_bucket;
                v_cls := bucket_cls(v_sev);
                -- WAIT rows are wait-class rollups and carry NO data-imp.
                v_imp := CASE WHEN rec.metric_domain = 'WAIT' THEN NULL
                              ELSE is_essential(rec.metric_domain, rec.metric_name) END;
                v_row := '<tr id="' || find_id(rec.metric_domain, rec.metric_name)
                    || '" data-metric="'
                    || REPLACE(DBMS_XMLGEN.CONVERT(rec.metric_name), '"', '&quot;')
                    || '" data-family="' || rec.family || '"'
                    || CASE WHEN v_imp IS NOT NULL
                            THEN ' data-imp="' || v_imp || '"' END
                    || CASE WHEN v_sev IN ('typical', 'flat baseline', 'insufficient history',
                                           'improved', 'noted')
                            THEN ' data-tail="Y"' END
                    || ' class="' || v_cls
                    || CASE WHEN rec.canonical = 'N' THEN ' twin' ELSE '' END || '">'
                    || '<td>' || DBMS_XMLGEN.CONVERT(rec.metric_name)
                        || CASE WHEN rec.canonical = 'N'
                                THEN ' <span class="chip" title="same quantity as a counted '
                                     || 'row; not counted again">twin</span>'
                                ELSE '' END
                        || src_link(rec.metric_domain, rec.metric_name)
                        || '</td>'
                    || '<td class="num" data-w="0"' || fmt_num_title(rec.cur_val) || '>'
                        || fmt_num(rec.cur_val) || '</td>'
                    || band_cells(rec.cur_val, rec.prior_mean, rec.prior_sd, rec.n_prior,
                                  v_sev, CASE WHEN rec.canonical = 'N' THEN 'Y' ELSE 'N' END)
                    || '<td class="num">' || fmt_num(rec.prior_mean) || '</td>'
                    || '<td class="num">' || fmt_num(rec.prior_sd) || '</td>'
                    || '<td class="num">' || NVL(TO_CHAR(rec.n_prior), '0') || '</td>'
                    || '</tr>';
                DBMS_OUTPUT.PUT_LINE(v_row);
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');

        IF v_tail_cnt > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<span class="expander vw in-a" data-for="' || v_tbl_id
                || '" data-n="' || v_tail_cnt || '" data-noun="normal / improved / flat rows">'
                || '&#9656; Show ' || v_tail_cnt || ' normal / improved / flat rows</span>');
        END IF;
    END emit_domain_table;

    -- plan 033: a scored row moved up AND is a finding (large / moderate)
    FUNCTION f_up(p_dom VARCHAR2, p_name VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. v_findings.COUNT LOOP
            IF v_findings(i).metric_domain = p_dom AND v_findings(i).metric_name = p_name THEN
                IF v_findings(i).change_bucket IN ('large', 'moderate')
                   AND v_findings(i).cur_val > v_findings(i).prior_mean THEN
                    RETURN TRUE;
                END IF;
                RETURN FALSE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END f_up;

    -- plan 033: one of the card evidence events (the top 2 of a class,
    -- v_evs) moved up and is a finding by the wait policy
    FUNCTION ev_up(p_event VARCHAR2) RETURN BOOLEAN IS
        v_b VARCHAR2(40);
    BEGIN
        FOR e IN 1 .. v_evs.COUNT LOOP
            IF v_evs(e).event = p_event THEN
                v_b := policy_bucket('WAIT', v_evs(e).event, v_evs(e).wclass, v_evs(e).cur_val,
                                     v_evs(e).mu, v_evs(e).sd, v_evs(e).n, v_evs(e).shr);
                IF v_b IN ('large', 'moderate') AND v_evs(e).cur_val > NVL(v_evs(e).mu, 0) THEN
                    RETURN TRUE;
                END IF;
            END IF;
        END LOOP;
        RETURN FALSE;
    END ev_up;

    -- review follow-up R2: COMMIT_LAT claims each commit waited longer, so
    -- it checks exactly that: log file sync flagged up AND its time per
    -- commit (wait AAS / user commits per second) at least 1.5x the prior
    -- windows' (mean wait / mean commit rate, the ratio of the means)
    FUNCTION commit_lat_up RETURN BOOLEAN IS
    BEGIN
        IF NOT ev_up('log file sync') THEN RETURN FALSE; END IF;
        FOR i IN 1 .. v_findings.COUNT LOOP
            IF v_findings(i).metric_domain = 'LOAD' AND v_findings(i).metric_name = 'user commits' THEN
                FOR e IN 1 .. v_evs.COUNT LOOP
                    IF v_evs(e).event = 'log file sync' AND v_evs(e).mu IS NOT NULL
                       AND v_findings(i).cur_val > 0 AND v_findings(i).prior_mean > 0
                       AND v_evs(e).cur_val / v_findings(i).cur_val
                           >= 1.5 * v_evs(e).mu / v_findings(i).prior_mean THEN
                        RETURN TRUE;
                    END IF;
                END LOOP;
                RETURN FALSE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END commit_lat_up;

    -- plan 033: which rule of sql/lib/finding_hints.plsql a card gets
    -- (NULL = none); the table of rules is in that file's header.  A rule
    -- fires only on what its sentence claims (review follow-up R2):
    -- IO_SCANS on any one of its signals (the sentence says "or"),
    -- COMMIT_LAT on the time per commit, DBTIME_CPU only when CPU took at
    -- least 60% of the rise (time_split 'c', the headline's "mostly CPU")
    FUNCTION pick_hint(p_g VARCHAR2) RETURN VARCHAR2 IS
        v_split VARCHAR2(1);
    BEGIN
        IF p_g = 'IO' THEN
            IF f_up('LOAD', 'table scans (long tables)') OR ev_up('db file scattered read')
               OR ev_up('direct path read') THEN
                RETURN 'IO_SCANS';
            END IF;
            IF ev_up('db file sequential read') THEN RETURN 'IO_SINGLE'; END IF;
        ELSIF p_g = 'COMMIT' THEN
            IF commit_lat_up THEN RETURN 'COMMIT_LAT'; END IF;
        ELSIF p_g = 'NET' THEN
            IF ev_up('SQL*Net more data to client')
               OR f_up('LOAD', 'bytes sent via SQL*Net to client') THEN
                RETURN 'NET_PAYLOAD';
            END IF;
        ELSIF p_g = 'PARSE' THEN
            IF f_up('LOAD', 'parse count (hard)') THEN RETURN 'HARD_PARSE'; END IF;
        ELSIF p_g = 'DBTIME' THEN
            IF v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
                v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                      v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
                IF v_split = 'c' THEN RETURN 'DBTIME_CPU'; END IF;
            END IF;
        ELSIF p_g = 'WAIT:Application' THEN
            IF ev_up('enq: TX - row lock contention') THEN RETURN 'ROW_LOCK'; END IF;
        END IF;
        RETURN NULL;
    END pick_hint;

    -- the card headline after the metric name: "5.4x normal", "up 79.7%,
    -- mostly wait" (the DB time lead adds where the extra time went).
    -- Shared by the card's h3 and its triage row (plan 025).
    FUNCTION head_txt(r finding_rec) RETURN VARCHAR2 IS
        v_split VARCHAR2(1);
    BEGIN
        IF r.metric_name = 'DB time' AND v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
            v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                  v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
        END IF;
        RETURN move_txt(r.cur_val, r.prior_mean, r.change_bucket)
            || CASE v_split WHEN 'W' THEN ', all of it wait' WHEN 'w' THEN ', mostly wait'
                            WHEN 'c' THEN ', mostly CPU' WHEN 'm' THEN ', CPU and wait alike' END;
    END head_txt;

    -- One finding card (Summary view): kicker + band, headline, Current and
    -- normal range, the window chart, evidence rows, the related-metrics
    -- fold and the footer links.  p_pos = 1 is the lead card (bigger).
    PROCEDURE emit_card(p_g VARCHAR2, p_pos PLS_INTEGER) IS
        r       finding_rec := v_findings(v_glead(p_g));
        m       finding_rec;
        v_s     NUMBER := metric_scale(r.metric_domain, r.metric_name);
        v_u     VARCHAR2(20) := metric_unit(r.metric_domain, r.metric_name);
        v_id    VARCHAR2(80) := card_id(p_g);
        v_sev   VARCHAR2(40) := r.change_bucket;
        v_ev    VARCHAR2(32767);
        v_nev   PLS_INTEGER := 0;
        v_cap   PLS_INTEGER := CASE WHEN p_g = 'IO' THEN 2 ELSE 4 END;
        v_rel   VARCHAR2(32767);
        v_nrel  PLS_INTEGER := 0;
        v_ntw   PLS_INTEGER := 0;
        v_split VARCHAR2(1);
        v_links VARCHAR2(2000);
        v_ms    NUMBER;
        v_mu    VARCHAR2(20);
        v_eb    VARCHAR2(40);
        v_rule  VARCHAR2(20);
        v_imp   NUMBER := g_imp(p_g);
        v_shr   NUMBER;
    BEGIN
        -- impact chip (v1.7): the card's share of the DB-time rise, left out
        -- past 100% (a part is measured apart from DB time and can pass it)
        v_shr := g_shr(p_g);
        IF p_g = 'DBTIME' AND v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
            v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                  v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
        END IF;

        -- evidence 1: for DB time, where the CPU went (the other half)
        IF p_g = 'DBTIME' AND v_cpu IS NOT NULL AND v_cpu <> v_glead(p_g) THEN
            m := v_findings(v_cpu);
            v_ev := v_ev || ev_row('CPU', f_ent(m), TRUE,
                fv(m.cur_val * 0.01, 'AAS') || ', normal ' || fv(m.prior_mean * 0.01, 'AAS')
                || CASE WHEN v_split IN ('W', 'w') THEN '; the rise is wait' END,
                m.cur_val, m.prior_mean, m.prior_sd, m.change_bucket);
            v_nev := v_nev + 1;
        END IF;
        -- evidence 2: the top events of every flagged wait class on the card
        FOR e IN 1 .. v_evs.COUNT LOOP
            EXIT WHEN v_nev >= v_cap;
            IF card_group('WAIT:' || v_evs(e).wclass) = p_g
               AND v_flagcls.EXISTS(v_evs(e).wclass) THEN
                v_eb := policy_bucket('WAIT', v_evs(e).event, v_evs(e).wclass, v_evs(e).cur_val,
                                      v_evs(e).mu, v_evs(e).sd, v_evs(e).n, v_evs(e).shr);
                v_ev := v_ev || ev_row('Event',
                    ent(DBMS_XMLGEN.CONVERT(v_evs(e).event), anchor_id('we', v_evs(e).event), 'event'),
                    TRUE, fv(v_evs(e).cur_val, 'AAS') || ', normal ' || fv(v_evs(e).mu, 'AAS'),
                    v_evs(e).cur_val, v_evs(e).mu, v_evs(e).sd, v_eb);
                v_nev := v_nev + 1;
            END IF;
        END LOOP;
        -- evidence 3: the card's other flagged metrics, loudest first; and the
        -- related-metrics fold (every other flagged member, twins muted)
        FOR p IN 1 .. v_table_idx.COUNT LOOP
            m := v_findings(v_table_idx(p));
            IF m.grp = p_g AND m.change_bucket IN ('large', 'moderate')
               AND v_table_idx(p) <> v_glead(p_g) THEN
                v_ms := metric_scale(m.metric_domain, m.metric_name);
                v_mu := metric_unit(m.metric_domain, m.metric_name);
                IF m.canonical = 'Y' AND v_nev < v_cap THEN
                    v_ev := v_ev || ev_row(dom_word(m.metric_domain), f_ent(m), TRUE,
                        fv(m.cur_val * v_ms, v_mu) || ', normal ' || fv(m.prior_mean * v_ms, v_mu),
                        m.cur_val, m.prior_mean, m.prior_sd, m.change_bucket);
                    v_nev := v_nev + 1;
                END IF;
                IF m.canonical = 'N' THEN v_ntw := v_ntw + 1; ELSE v_nrel := v_nrel + 1; END IF;
                v_rel := v_rel || '<tr class="' || bucket_cls(m.change_bucket)
                    || CASE WHEN m.canonical = 'N' THEN ' twin' END || '"><td>' || f_ent(m)
                    || CASE WHEN m.canonical = 'N'
                            THEN ' <span class="chip" title="same quantity as a counted row; not counted again">twin</span>' END
                    || '</td><td class="num" data-w="0">' || fv(m.cur_val * v_ms, v_mu) || '</td>'
                    || band_cells(m.cur_val * v_ms, m.prior_mean * v_ms, m.prior_sd * v_ms, m.n_prior,
                                  m.change_bucket, CASE WHEN m.canonical = 'N' THEN 'Y' ELSE 'N' END)
                    || '</tr>';
            END IF;
        END LOOP;

        v_links := CASE
            WHEN p_g = 'IO'     THEN '<a href="#segment-io">Segment I/O</a><a href="#topsql">Top SQL</a>'
            WHEN p_g = 'DBTIME' THEN '<a href="#waits-fg">Foreground waits</a>'
                                     || CASE WHEN ~profile_days > 0 THEN '<a href="#day-profile">Day profile</a>'
                                             ELSE '<a href="#ash-timeline">ASH timeline</a>' END
            WHEN p_g = 'WRITE'  THEN '<a href="#file-io">File I/O</a><a href="#load">Load profile</a>'
            WHEN p_g IN ('NET', 'COMMIT') OR p_g LIKE 'WAIT:%' THEN '<a href="#waits-fg">Foreground waits</a>'
            WHEN r.metric_domain = 'METRIC' THEN '<a href="#metrics">System metrics</a>'
            ELSE '<a href="#load">Load profile</a>' END;

        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h"'
            || ' data-impact="' || imp_tok(v_imp) || '" data-share="' || v_shr || '"'
            || CASE WHEN p_g <> v_open_g THEN ' data-fold="Y"' END || '>'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span>'
            || CASE WHEN imp_on(v_imp) THEN '<span class="fc-imp" title="Time added: Current minus the prior'
                    || ' mean of this card&#39;s time measure (DB time, DB CPU or the foreground time of its'
                    || ' wait class), in average active sessions">' || imp_txt(v_imp)
                    || CASE WHEN p_g = 'DBTIME' THEN ' above normal'
                            WHEN v_shr IS NOT NULL THEN ' &middot; '
                                 || CASE WHEN v_shr < 1 THEN '&lt;1' ELSE TO_CHAR(v_shr) END
                                 || '% of the DB-time rise' END
                    || '</span>' END
            || '<span class="fc-sum"' || CASE WHEN conf_mod(r.n_prior) IS NOT NULL
                    THEN ' data-n="' || TO_CHAR(TRUNC(r.n_prior)) || '"' END || '>'
            || fv(r.cur_val * v_s, v_u) || ' &middot; normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</span>'
            || '<span class="fc-tags"></span></div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg', 'N', 10) || band_axis || '</div></header>');
        DBMS_OUTPUT.PUT_LINE('<h3 id="' || v_id || '-h">' || f_ent(r) || ' '
            || head_txt(r) || '</h3>');
        DBMS_OUTPUT.PUT_LINE('<div class="fc-b"><div class="fc-main">'
            || '<div class="big"><span class="v">' || fv_num(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="u">' || fv_unit(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="nrm"' || CASE WHEN conf_mod(r.n_prior) IS NOT NULL
                    THEN ' data-n="' || TO_CHAR(TRUNC(r.n_prior)) || '"' END
            || ' title="prior mean ' || fv(r.prior_mean * v_s, v_u)
            || CASE WHEN conf_mod(r.n_prior) IS NOT NULL THEN '. ' || conf_title(r.n_prior) END
            || '">normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="wg bare hov qf"' || wg_attr || '>' || wg_flags(TRUE)
            || wg_bars(r.wv, v_s, r.prior_mean, r.prior_sd, v_sev) || wg_dates(TRUE) || '</div></div>');
        DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>');
        -- plan 033: what this usually means, and a read-only next query
        v_rule := pick_hint(p_g);
        IF v_rule IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE(hint_block(v_rule, v_id,
                CASE WHEN v_cw_b IS NOT NULL
                     THEN hint_fill(hint_sql(v_rule), v_cw_dbid, v_cw_b, v_cw_e, ~inst_num,
                                    p_insts => v_cw_inst, p_t0 => v_cw_t0, p_t1 => v_cw_t1) END));
        END IF;
        IF v_nrel + v_ntw > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<details class="rel"><summary>'
                || CASE WHEN v_nrel > 0 THEN v_nrel || ' related metric' || CASE WHEN v_nrel = 1 THEN '' ELSE 's' END END
                || CASE WHEN v_nrel > 0 AND v_ntw > 0 THEN ', ' END
                || CASE WHEN v_ntw > 0 THEN v_ntw || ' twin' || CASE WHEN v_ntw = 1 THEN '' ELSE 's' END END
                || '</summary><div class="tw"><table data-nocount data-notools data-nosort><thead><tr>'
                || '<th>Metric</th><th class="num cur-col">Current</th>' || band_head
                || '</tr></thead><tbody>');
            DBMS_OUTPUT.PUT_LINE(v_rel);
            DBMS_OUTPUT.PUT_LINE('</tbody></table></div></details>');
        END IF;
        -- "Timeline ->": phase 3's grid row for this metric (data-tl) when it
        -- exists, else the Timeline view itself (sql/lib/js_wingrid.plsql)
        DBMS_OUTPUT.PUT_LINE('<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
            || find_id(r.metric_domain, r.metric_name) || '">Timeline &rarr;</a>'
            || '<span class="evl">' || v_links || '</span></footer></article>');
    END emit_card;

    -- One row of the Summary triage list (plan 025): severity, card name
    -- (a link to the card), the headline, Current value and normal range,
    -- an empty impact cell that the inline script after the cards fills
    -- from the card's data-impact / data-share (plan 020), the lead
    -- metric's windows as a micro strip (js_microstrip; data-spark-dense:
    -- past about 45 windows one gapless silhouette instead of nothing), and
    -- the empty span.tri-tags that plan 027 fills.
    PROCEDURE emit_tri_row(p_g VARCHAR2) IS
        r    finding_rec  := v_findings(v_glead(p_g));
        v_s  NUMBER       := metric_scale(r.metric_domain, r.metric_name);
        v_u  VARCHAR2(20) := metric_unit(r.metric_domain, r.metric_name);
        v_id VARCHAR2(80) := card_id(p_g);
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<div class="tri-row" role="listitem" data-card="' || v_id || '">'
            || '<span class="tri-f"><i class="dotk ' || r.change_bucket || '" aria-hidden="true"></i>'
            || '<a class="tri-go" href="#' || v_id || '">' || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '</a>'
            || '<span class="tri-m">' || f_label(r) || ' ' || head_txt(r) || '</span>'
            || '<span class="tri-tags"></span></span>'
            || '<span class="tri-nv"><b>' || fv(r.cur_val * v_s, v_u) || '</b><small>normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</small></span>'
            || '<span class="tri-imp"></span>'
            || '<span class="tri-spark" data-spark-dense data-spark="' || wg_csv(r.wv, v_s)
            || '" data-spark-title="' || f_label(r) || '"></span></div>');
    END emit_tri_row;

    -- v1.6.0 Timeline: the "Headline and load" lane -- the headline
    -- metrics in Mock D's order, then every other flagged canonical load /
    -- metric row (a card lead is always canonical; twins stay in the
    -- tables) -- and the flagged wait classes at the top of the "Waits" lane.
    -- One grid row each from the collection the tables walk (never a
    -- separate slice), id tl-fr-<d>-<name> = the "Timeline ->" target of
    -- the finding cards (sql/lib/timeline.plsql).
    FUNCTION hl_rank(p_dom VARCHAR2, p_name VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE p_dom || ':' || p_name
            WHEN 'LOAD:DB time'                      THEN 1
            WHEN 'LOAD:DB CPU'                       THEN 2
            WHEN 'METRIC:Database Wait Time Ratio'   THEN 3
            WHEN 'LOAD:session logical reads'        THEN 4
            WHEN 'LOAD:physical reads'               THEN 5
            WHEN 'LOAD:physical read total bytes'    THEN 6
            WHEN 'LOAD:table scans (long tables)'    THEN 7
            WHEN 'METRIC:SQL Service Response Time'  THEN 8
            WHEN 'METRIC:Host CPU Utilization (%)'   THEN 9
            WHEN 'LOAD:redo size'                    THEN 10
            WHEN 'LOAD:parse count (hard)'           THEN 11 END;
    END hl_rank;

    FUNCTION tl_row(r finding_rec, p_cls VARCHAR2) RETURN VARCHAR2 IS
        v_s  NUMBER       := metric_scale(r.metric_domain, r.metric_name);
        v_u  VARCHAR2(20) := metric_unit(r.metric_domain, r.metric_name);
        v_tw VARCHAR2(1)  := CASE WHEN r.canonical = 'N' THEN 'Y' ELSE 'N' END;
    BEGIN
        RETURN tl_bars(wg_csv(r.wv, v_s), r.prior_mean * v_s, r.prior_sd * v_s,
            CASE WHEN v_tw = 'N' THEN r.change_bucket END,
            tl_lab(f_ent(r),
                   CASE WHEN r.metric_domain = 'WAIT' THEN 'wait class, ' || v_u ELSE v_u END
                   || CASE WHEN v_tw = 'Y' THEN ', twin' END,
                   DBMS_XMLGEN.CONVERT(r.metric_name),
                   CASE WHEN r.metric_domain = 'WAIT'
                        THEN REGEXP_REPLACE(r.metric_name, '^Wait class: ', '') END),
            tl_gut(r.cur_val * v_s, r.prior_mean * v_s, r.prior_sd * v_s, r.change_bucket, NULL, v_tw),
            'tl-' || find_id(r.metric_domain, r.metric_name),
            TRIM(p_cls || CASE WHEN v_tw = 'Y' THEN ' twin' END),
            f_label(r), v_u);
    END tl_row;

    PROCEDURE emit_timeline IS
        rec finding_rec;
        v_n PLS_INTEGER := 0;
    BEGIN
        FOR h IN 1 .. 11 LOOP
            FOR p IN 1 .. v_table_idx.COUNT LOOP
                rec := v_findings(v_table_idx(p));
                IF hl_rank(rec.metric_domain, rec.metric_name) = h THEN
                    DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 0 THEN tl_open('metrics') END || tl_row(rec, NULL));
                    v_n := v_n + 1;
                END IF;
            END LOOP;
        END LOOP;
        FOR p IN 1 .. v_table_idx.COUNT LOOP
            rec := v_findings(v_table_idx(p));
            IF rec.metric_domain IN ('LOAD', 'METRIC') AND hl_rank(rec.metric_domain, rec.metric_name) IS NULL
               AND rec.change_bucket IN ('large', 'moderate') AND rec.canonical = 'Y' THEN
                DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 0 THEN tl_open('metrics') END || tl_row(rec, NULL));
                v_n := v_n + 1;
            END IF;
        END LOOP;
        IF v_n > 0 THEN DBMS_OUTPUT.PUT_LINE(tl_close); END IF;
        v_n := 0;
        FOR p IN 1 .. v_table_idx.COUNT LOOP
            rec := v_findings(v_table_idx(p));
            IF rec.metric_domain = 'WAIT' AND rec.change_bucket IN ('large', 'moderate') THEN
                DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 0 THEN tl_open('waits') END || tl_row(rec, 'w'));
                v_n := v_n + 1;
            END IF;
        END LOOP;
        IF v_n > 0 THEN DBMS_OUTPUT.PUT_LINE(tl_close); END IF;
    END emit_timeline;
BEGIN
    --
    -- Recompute LOAD / METRIC / WAIT values per (week_offset, metric) from
    -- the AWR views, pivot to cur vs prior AVG/STDDEV (+ every window as
    -- offset-keyed pairs for the card charts), and tag each row with its
    -- detail-table view position via ROW_NUMBER.  Bulk-collected once;
    -- every view below iterates the collection.
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    -- LOAD domain: DBA_HIST_SYSSTAT cumulative counters (DB time / DB CPU from
    -- the time model, sql/lib/load_pairs_cte.sql), per-sec deltas.
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    -- SYSSTAT counters, with DB time / DB CPU from the time model
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
        -- Divide the summed cross-instance delta by ONE window span
        -- (MAX(dur_sec) = full wall-clock covered).  dur_sec dropped from the
        -- GROUP BY so differing per-instance spans can't split a RAC week;
        -- single-instance is byte-identical (dur_sec constant).
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, stat_name
    ),
    -- METRIC domain: DBA_HIST_SYSMETRIC_SUMMARY averages over window.
    -- Per-snap cluster value: SUM across instances for additive metrics,
    -- AVG for ratios. See sql/lib/sysmetric_targets.sql for the rationale.
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
    -- WAIT domain: DBA_HIST_SYSTEM_EVENT time-waited per wait_class, as rate.
    -- wait_targets honors the template's wait_event_targets.sql; '*' sentinel
    -- preserves the comprehensive-template firehose behavior byte-for-byte.
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.event_name,
               se.snap_id,
               se.time_waited_micro,
               se.time_waited_micro_fg,
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
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro_fg END) AS beg_fg,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro_fg END) AS end_fg
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
    ),
    wait_rows AS (
        -- Same single-span divisor as load_rows; MAX(dur_sec) over the
        -- per-instance spans, dur_sec dropped from the GROUP BY.
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    -- v1.7 impact (owner decision 2026-11-20): the same class rows,
    -- FOREGROUND sessions only (time_waited_micro_fg, the wait time inside
    -- DB time), Current minus the prior mean in AAS.  Never scored: the
    -- class rows above stay all sessions; this feeds only the cards' impact
    -- and the DB-time breakdown (finding_cards.plsql time_added).  Same
    -- windows (the same wait_bounds rows), template wait list and Idle
    -- exclusion; 00_params.sql computes it the same way.
    wait_fg_rows AS (
        SELECT week_offset, wait_class,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_fg, 0) - NVL(beg_fg, 0)) / MAX(dur_sec) / 1e6
               END AS fg_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    wait_fg AS (
        SELECT 'Wait class: ' || wait_class AS metric_name,
               MAX(CASE WHEN week_offset = 0 THEN fg_value END)
             - AVG(CASE WHEN week_offset > 0 THEN fg_value END) AS fg_d
        FROM   wait_fg_rows
        WHERE  fg_value IS NOT NULL
        GROUP BY wait_class
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
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)  AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)  AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END) AS n,
               -- v1.6.0: every window's value as offset-keyed 'k:v' pairs
               -- (sql/lib/wingrid.plsql wg_tok format) for the card charts
               LISTAGG(week_offset || ':' ||
                   CASE WHEN metric_value = 0 THEN '0'
                        ELSE TO_CHAR(ROUND(metric_value, 6 - FLOOR(LOG(10, ABS(metric_value)))),
                                     'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''') END, ';')
                   WITHIN GROUP (ORDER BY week_offset) AS pairs
        FROM   unified
        GROUP BY metric_domain, metric_name
    ),
    -- Materiality denominator for wait rows: the Current window's total
    -- non-idle wait time across every class (s/s).
    wait_total AS (
        SELECT SUM(metric_value) AS tot
        FROM   wait_rows
        WHERE  week_offset = 0
    ),
    measured AS (
        SELECT p.metric_domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n, p.pairs,
               -- sigma floor: 2% of |mean| (see header comment)
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.sd IS NULL THEN NULL
                   WHEN GREATEST(p.sd, 0.02 * ABS(p.mu)) = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / GREATEST(p.sd, 0.02 * ABS(p.mu))
               END AS z_score,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.mu = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / ABS(p.mu) * 100
               END AS pct_delta,
               CASE
                   WHEN p.metric_domain = 'WAIT' AND t.tot > 0 THEN p.cur_val / t.tot
               END AS shr
        FROM   pivoted p
        CROSS JOIN wait_total t
    ),
    scored AS (
        SELECT metric_domain, metric_name,
               cur_val,
               mu       AS prior_mean,
               sd       AS prior_sd,
               n        AS n_prior,
               z_score, pct_delta,
               -- the bucket is assigned by policy_bucket() in the PL/SQL
               -- pass below (per-metric direction and floors); the share
               -- rides along for the WAIT rows' materiality test.
               CAST(NULL AS VARCHAR2(40)) AS change_bucket,
               shr, pairs
        FROM   measured
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    ),
    ranked AS (
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket, shr, pairs,
               ROW_NUMBER() OVER (
                   ORDER BY metric_domain,
                            ABS(NVL(z_score, 0)) DESC,
                            metric_name) AS heat_pos
        FROM   scored
    )
    SELECT r.metric_domain, r.metric_name,
           r.cur_val, r.prior_mean, r.prior_sd, r.n_prior,
           r.z_score, r.pct_delta, r.change_bucket,
           r.heat_pos,
           -- family / canonical / dir are filled in by the PL/SQL pass below
           CAST(NULL AS VARCHAR2(64)) AS family,
           CAST(NULL AS VARCHAR2(1))  AS canonical,
           CAST(NULL AS VARCHAR2(4))  AS dir,
           r.shr,
           r.pairs                    AS wv,
           CAST(NULL AS VARCHAR2(64)) AS grp,
           g.fg_d
    BULK COLLECT INTO v_findings
    FROM   ranked r
    LEFT JOIN wait_fg g
           ON r.metric_domain = 'WAIT'
          AND g.metric_name = r.metric_name
    ORDER  BY r.heat_pos;


    --
    -- Pass 1: per-metric policy (family / canonical / direction) and the
    -- change bucket per row, tallies over CANONICAL rows only, the card
    -- group of every row and each card's lead, severity and loudest |z|,
    -- and the detail-table order (insertion sort on tbl_before).
    -- 'improved' / 'noted' rows are counted separately and never
    -- highlighted.
    --
    FOR i IN 1 .. v_findings.COUNT LOOP
      DECLARE
        -- policy_rec lives in the include, which also declares functions,
        -- so a variable of that type can only be declared in a nested block.
        v_pol policy_rec;
      BEGIN
        v_pol := metric_policy(v_findings(i).metric_domain, v_findings(i).metric_name);
        v_findings(i).family    := finding_family(v_findings(i).metric_domain,
                                                  v_findings(i).metric_name);
        v_findings(i).canonical := v_pol.canonical;
        v_findings(i).dir       := v_pol.dir;
      END;
        v_findings(i).change_bucket :=
            policy_bucket(v_findings(i).metric_domain, v_findings(i).metric_name, NULL,
                          v_findings(i).cur_val, v_findings(i).prior_mean,
                          v_findings(i).prior_sd, v_findings(i).n_prior,
                          v_findings(i).shr);
        v_findings(i).grp := card_group(v_findings(i).family);
        f := v_findings(i);
        v_total := v_total + 1;
        IF f.metric_domain = 'LOAD' AND f.metric_name = 'DB time' THEN v_dbt := i; END IF;
        IF f.metric_domain = 'LOAD' AND f.metric_name = 'DB CPU'  THEN v_cpu := i; END IF;
        -- impact (v1.7, sql/lib/finding_cards.plsql impact_group / time_added;
        -- a wait class counts its foreground time only)
        v_ig := impact_group(f.metric_domain, f.metric_name, f.family);
        IF v_ig IS NOT NULL
           AND time_added(f.metric_domain, f.metric_name, f.cur_val, f.prior_mean, f.fg_d) IS NOT NULL THEN
            v_gimp(v_ig) := time_added(f.metric_domain, f.metric_name, f.cur_val, f.prior_mean, f.fg_d);
        END IF;
        IF f.change_bucket IN ('large', 'moderate', 'improved', 'noted') THEN
            IF f.canonical = 'N' THEN
                v_folded := v_folded + 1;
            ELSIF f.change_bucket = 'large'    THEN v_crit := v_crit + 1;
            ELSIF f.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
            ELSIF f.change_bucket = 'improved' THEN v_impr := v_impr + 1;
            ELSE                                    v_noted := v_noted + 1;
            END IF;
        END IF;
        IF f.canonical = 'Y' AND f.change_bucket IN ('typical', 'improved', 'noted', 'flat baseline') THEN
            v_normal := v_normal + 1;
        END IF;

        -- the card this row belongs to (sql/lib/finding_cards.plsql)
        IF f.canonical = 'Y' AND f.change_bucket IN ('large', 'moderate') THEN
            v_g := f.grp;
            IF NOT v_glead.EXISTS(v_g) THEN
                v_glead(v_g) := i;
                v_gsev(v_g)  := 0;
                v_gz(v_g)    := 0;
            ELSIF lead_better(v_g, f.change_bucket, f.family, f.z_score,
                              v_findings(v_glead(v_g)).change_bucket,
                              v_findings(v_glead(v_g)).family,
                              v_findings(v_glead(v_g)).z_score,
                              metric_label(f.metric_domain, f.metric_name),
                              metric_label(v_findings(v_glead(v_g)).metric_domain,
                                           v_findings(v_glead(v_g)).metric_name)) THEN
                v_glead(v_g) := i;
            END IF;
            v_gsev(v_g) := GREATEST(v_gsev(v_g), sev_rank(f.change_bucket));
            v_gz(v_g)   := GREATEST(v_gz(v_g), ABS(NVL(f.z_score, 0)));
            IF f.metric_domain = 'WAIT' THEN
                v_flagcls(REGEXP_REPLACE(f.metric_name, '^Wait class: ', '')) := i;
                v_wait_flag := TRUE;
            END IF;
        END IF;

        -- detail-table order
        j := v_n_tbl;
        WHILE j >= 1 AND tbl_before(f, v_findings(v_table_idx(j))) LOOP
            v_table_idx(j + 1) := v_table_idx(j);
            j := j - 1;
        END LOOP;
        v_table_idx(j + 1) := i;
        v_n_tbl := v_n_tbl + 1;
    END LOOP;

    -- Card order (00_params.sql's verdict applies the same two steps):
    -- cards whose time measure rose by 0.01 AAS or more, by the AAS added; then DB time; then
    -- the rest, large before moderate and by |z|; then a flagged DB time
    -- card moves up to second place.
    v_g := v_glead.FIRST;
    WHILE v_g IS NOT NULL LOOP
        j := v_order.COUNT;
        WHILE j >= 1 AND card_before_imp(v_g, v_gsev(v_g), v_gz(v_g), g_imp(v_g), v_order(j), v_gsev(v_order(j)), v_gz(v_order(j)), g_imp(v_order(j))) LOOP
            v_order(j + 1) := v_order(j);
            j := j - 1;
        END LOOP;
        v_order(j + 1) := v_g;
        v_g := v_glead.NEXT(v_g);
    END LOOP;
    FOR k IN 3 .. v_order.COUNT LOOP
        IF v_order(k) = 'DBTIME' THEN
            FOR m IN REVERSE 3 .. k LOOP
                v_tmp := v_order(m); v_order(m) := v_order(m - 1); v_order(m - 1) := v_tmp;
            END LOOP;
            EXIT;
        END IF;
    END LOOP;
    -- plan 025: in the Summary view every card but one starts folded; the
    -- open one is the first card that is not DB time (the verdict and its
    -- DB-time breakdown already say what DB time did), else the only card
    FOR k IN 1 .. v_order.COUNT LOOP
        IF v_order(k) <> 'DBTIME' THEN
            v_open_g := v_order(k);
            EXIT;
        END IF;
    END LOOP;
    IF v_open_g IS NULL AND v_order.COUNT > 0 THEN
        v_open_g := v_order(1);
    END IF;

    --
    -- Card evidence: the top 2 events (by Current time waited per second,
    -- all sessions like the class rows) of every wait class, with their
    -- prior mean / sd / n and share of the Current wait -- one bounded
    -- scan, only when a wait class is flagged.  Same pairs -> bounds ->
    -- deltas shape and template filter as 04.
    --
    IF v_wait_flag THEN
        WITH
        @@sql/lib/windows_cte.sql
        ,
        wait_targets AS (
            @@~template_dir/wait_event_targets.sql
        ),
        ev_pairs AS (
            SELECT w.week_offset, w.dur_sec, se.wait_class, se.event_name,
                   se.snap_id, se.time_waited_micro, se.instance_number,
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
        ev_bounds AS (
            SELECT week_offset, dur_sec, wait_class, event_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   ev_pairs
            GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
        ),
        ev_rows AS (
            SELECT week_offset, wait_class, event_name,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
                   END AS v
            FROM   ev_bounds
            GROUP BY week_offset, wait_class, event_name
        ),
        ev_tot AS (
            SELECT SUM(v) AS tot FROM ev_rows WHERE week_offset = 0
        ),
        ev_piv AS (
            SELECT wait_class, event_name,
                   MAX(CASE WHEN week_offset = 0 THEN v END)    AS cur_val,
                   AVG(CASE WHEN week_offset > 0 THEN v END)    AS mu,
                   STDDEV(CASE WHEN week_offset > 0 THEN v END) AS sd,
                   COUNT(CASE WHEN week_offset > 0 THEN v END)  AS n
            FROM   ev_rows
            WHERE  v IS NOT NULL
            GROUP BY wait_class, event_name
        ),
        ev_rank AS (
            SELECT p.wait_class, p.event_name, p.cur_val, p.mu, p.sd, p.n,
                   CASE WHEN t.tot > 0 THEN p.cur_val / t.tot END AS shr,
                   ROW_NUMBER() OVER (PARTITION BY p.wait_class
                                      ORDER BY p.cur_val DESC, p.event_name) AS rn
            FROM   ev_piv p
            CROSS JOIN ev_tot t
            WHERE  p.cur_val > 0
        )
        SELECT wait_class, event_name, cur_val, mu, sd, n, shr
        BULK COLLECT INTO v_evs
        FROM   ev_rank
        WHERE  rn <= 2
        ORDER  BY wait_class, rn;
    END IF;

    --
    -- v1.7: "Where the extra DB time went" (plan 021).  The DB-time rise
    -- split into DB CPU and the wait classes' FOREGROUND time -- the same
    -- numbers as the cards' impact (impact_group / time_added,
    -- sql/lib/finding_cards.plsql), largest first.  Solid = the part's
    -- card is a finding; hatched = it grew but
    -- stayed inside its normal range.  Printed hidden and moved into 00's
    -- #att-slot by the script below (JavaScript off: it stays hidden; every
    -- number is in the Wait classes table and the DB CPU row).  Only when
    -- there is at least one finding card.
    --
    DECLARE
        v_dd    NUMBER := g_imp('DBTIME');
        v_p     part_rec;
        v_pos   NUMBER := 0;      -- sum of the parts that rose
        v_neg   NUMBER := 0;      -- sum of the parts that fell (as a positive number)
        v_base  NUMBER;           -- the bar's 100%: the rises plus the rest, GREATEST(rise + falls, rises)
        v_small NUMBER := 0;      -- parts under 1% of the base, merged
        v_nsm   PLS_INTEGER := 0;
        v_rest  NUMBER;
        v_pct   NUMBER;
        v_fl    BOOLEAN;
        v_bar   VARCHAR2(32767);
        v_lg    VARCHAR2(32767);
        v_fell  VARCHAR2(4000);
        v_nfell PLS_INTEGER := 0;
        v_note  VARCHAR2(4000);
        k       PLS_INTEGER;
    BEGIN
      IF v_order.COUNT > 0 AND v_dd IS NOT NULL AND v_dbt IS NOT NULL THEN
        -- the parts, largest rise first (insertion sort, stable)
        FOR i IN 1 .. v_findings.COUNT LOOP
            f := v_findings(i);
            IF (f.metric_domain = 'WAIT'
                OR (f.metric_domain = 'LOAD' AND f.metric_name = 'DB CPU'))
               AND time_added(f.metric_domain, f.metric_name, f.cur_val, f.prior_mean, f.fg_d) IS NOT NULL THEN
                v_p.lab := CASE WHEN f.metric_domain = 'LOAD' THEN 'CPU'
                                ELSE REGEXP_REPLACE(f.metric_name, '^Wait class: ', '') END;
                v_p.d   := time_added(f.metric_domain, f.metric_name, f.cur_val, f.prior_mean, f.fg_d);
                v_p.grp := impact_group(f.metric_domain, f.metric_name, f.family);
                v_p.aid := CASE WHEN v_glead.EXISTS(v_p.grp) THEN card_id(v_p.grp)
                                ELSE find_id(f.metric_domain, f.metric_name) END;
                k := v_parts.COUNT;
                WHILE k >= 1 AND v_p.d > v_parts(k).d LOOP
                    v_parts(k + 1) := v_parts(k);
                    k := k - 1;
                END LOOP;
                v_parts(k + 1) := v_p;
                IF v_p.d > 0 THEN v_pos := v_pos + v_p.d;
                ELSIF v_p.d < 0 THEN v_neg := v_neg - v_p.d;
                END IF;
            END IF;
        END LOOP;

        IF v_dd > 0 THEN
            -- the rest is what the parts, falls netted, leave of the rise:
            -- v_dd - (v_pos - v_neg); the bar draws the rises and that rest
            v_base := GREATEST(v_dd + v_neg, v_pos);
            FOR k2 IN 1 .. v_parts.COUNT LOOP
                v_p := v_parts(k2);
                -- a part needs the cards' 0.01 AAS floor (imp_on, owner
                -- decision 2026-11-21) and 1% of the bar; a smaller rise
                -- goes into "+ n smaller"
                IF imp_on(v_p.d) AND v_p.d >= 0.01 * v_base THEN
                    v_fl  := v_glead.EXISTS(v_p.grp);
                    -- the share, left out past 100% like the cards' impact chip
                    v_pct := CASE WHEN v_p.d <= v_dd * 1.005 THEN LEAST(100, ROUND(v_p.d / v_dd * 100)) END;
                    v_bar := v_bar || '<i class="att-s' || CASE WHEN NOT v_fl THEN ' nf' END
                        || '" data-wc="' || DBMS_XMLGEN.CONVERT(v_p.lab)
                        || '" style="flex-grow:' || imp_tok(v_p.d) || '" title="'
                        || DBMS_XMLGEN.CONVERT(v_p.lab) || ': +' || fmt_num(v_p.d) || ' AAS'
                        || CASE WHEN v_pct IS NOT NULL THEN ', ' || v_pct || '% of the DB-time rise' END
                        || CASE WHEN NOT v_fl THEN ', inside its normal range' END || '">'
                        || CASE WHEN v_p.d >= 0.18 * v_base
                                THEN '<span>' || DBMS_XMLGEN.CONVERT(v_p.lab) || ' +' || fmt_num(v_p.d) || '</span>' END
                        || '</i>';
                    v_lg := v_lg || '<li><i class="sw' || CASE WHEN NOT v_fl THEN ' nf' END
                        || '" data-wc="' || DBMS_XMLGEN.CONVERT(v_p.lab) || '" aria-hidden="true"></i>'
                        || ent(DBMS_XMLGEN.CONVERT(v_p.lab), v_p.aid, CASE WHEN v_fl THEN 'card' ELSE 'metric' END)
                        || ' <b>+' || fmt_num(v_p.d) || '</b>'
                        || CASE WHEN v_pct IS NOT NULL THEN ' <span class="sh">'
                                || CASE WHEN v_pct < 1 THEN '&lt;1' ELSE TO_CHAR(v_pct) END || '%</span>' END
                        || CASE WHEN v_fl
                                THEN ' <span class="st"><i class="dotk '
                                     || CASE WHEN v_gsev(v_p.grp) = 2 THEN 'large' ELSE 'moderate' END
                                     || '" aria-hidden="true"></i>finding</span>'
                                ELSE ' <span class="st nf">inside normal</span>' END
                        || '</li>';
                ELSIF v_p.d > 0 THEN
                    v_small := v_small + v_p.d;
                    v_nsm   := v_nsm + 1;
                END IF;
            END LOOP;
            IF v_nsm > 0 THEN
                v_bar := v_bar || '<i class="att-s att-small" style="flex-grow:' || imp_tok(v_small)
                    || '" title="' || v_nsm || ' smaller part' || CASE WHEN v_nsm > 1 THEN 's' END
                    || ': +' || fmt_num(v_small) || ' AAS"></i>';
                v_lg := v_lg || '<li class="att-more">+ ' || v_nsm || ' smaller ('
                    || fmt_num(v_small) || ' AAS)</li>';
            END IF;
            -- a fall offsets a rise: with DB time +10, CPU +8 and Commit -5
            -- the parts net to +3, so 7 is unexplained (not 10 - 8 = 2)
            v_rest := v_dd - (v_pos - v_neg);
            IF v_rest > 0.01 * v_dd THEN
                v_bar := v_bar || '<i class="att-s att-rest" style="flex-grow:' || imp_tok(v_rest)
                    || '" title="Not in the parts above'
                    || CASE WHEN v_neg > 0 THEN ', net of the falls' END
                    || ' (DB time that no wait class records, such as'
                    || ' waiting for a CPU, or waits outside this template&#39;s event list): +'
                    || fmt_num(v_rest) || ' AAS"></i>';
            END IF;
            -- the largest drops: the parts are sorted largest first, so walk backwards
            FOR k2 IN REVERSE 1 .. v_parts.COUNT LOOP
                EXIT WHEN v_parts(k2).d >= 0 OR v_nfell >= 3;
                IF -v_parts(k2).d >= 0.01 * v_dd THEN
                    v_fell := v_fell || CASE WHEN v_nfell > 0 THEN ', ' END
                        || DBMS_XMLGEN.CONVERT(v_parts(k2).lab) || ' &minus;' || fmt_num(-v_parts(k2).d);
                    v_nfell := v_nfell + 1;
                END IF;
            END LOOP;
            IF v_fell IS NOT NULL THEN
                v_note := v_note || 'Fell: ' || v_fell || ' AAS. ';
            END IF;
            -- falls offset rises.  The parts are foreground time like DB time,
            -- so they roughly add up to the rise; an excess past 2% of it is
            -- the gap between two separately kept counters (a shortfall is
            -- the hatched rest above), never background time
            IF v_pos - v_neg > v_dd * 1.02 THEN
                v_note := v_note || 'The parts add up to ' || imp_txt(v_pos - v_neg)
                    || CASE WHEN v_neg > 0 THEN ' net of the falls' END || ', more than the DB-time'
                    || ' rise: DB time comes from the time model, the parts from the wait interface'
                    || ' and DB CPU, which Oracle keeps separately, so they need not add up exactly.';
            END IF;
            DBMS_OUTPUT.PUT_LINE('<div id="att-src" hidden><div class="att-h"><b>Where the extra DB time went</b>'
                || '<span>DB time ' || fmt_num(v_findings(v_dbt).prior_mean * 0.01) || ' &rarr; '
                || fmt_num(v_findings(v_dbt).cur_val * 0.01) || ' AAS, <b>' || imp_txt(v_dd) || '</b></span></div>');
            DBMS_OUTPUT.PUT_LINE('<div class="att-bar" role="img" aria-label="The DB-time rise by wait class and CPU,'
                || ' largest part first">' || v_bar || '</div>');
            DBMS_OUTPUT.PUT_LINE('<ul class="att-lg">' || v_lg || '</ul>'
                || CASE WHEN v_note IS NOT NULL THEN '<p class="att-n">' || RTRIM(v_note) || '</p>' END
                || '</div>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<div id="att-src" hidden><p class="att-n"><b>DB time</b> did not rise: '
                || fmt_num(v_findings(v_dbt).cur_val * 0.01) || ' AAS, against a prior mean of '
                || fmt_num(v_findings(v_dbt).prior_mean * 0.01) || ' AAS.</p></div>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,s=d.getElementById("att-src"),'
            || 't=d.getElementById("att-slot"),c=window.AWR_WAIT_COLORS||{};if(!s)return;'
            || 's.querySelectorAll("[data-wc]").forEach(function(e){var k=e.getAttribute("data-wc");'
            || 'if(c[k])e.style.setProperty("--c",c[k]);});'
            || 'if(t){while(s.firstChild)t.appendChild(s.firstChild);t.hidden=false;}'
            || 's.parentNode.removeChild(s);})();</script>');
      END IF;
    END;

    --
    -- Section header: title, a one-line subtitle per view, the counts.
    -- Counts: in Summary the finding CARDS by severity (the verdict pill
    -- and the rail count the same cards); in All sections the canonical
    -- flagged ROWS of the detail tables, folded twins apart.
    --
    v_ncl := 0; v_ncm := 0;
    FOR k IN 1 .. v_order.COUNT LOOP
        IF v_gsev(v_order(k)) = 2 THEN v_ncl := v_ncl + 1; ELSE v_ncm := v_ncm + 1; END IF;
    END LOOP;
    v_meta := '<span class="meta' || CASE WHEN v_order.COUNT > 0 THEN ' vw in-a' END || '">'
        || CASE WHEN v_crit > 0 THEN '<span><i class="dotk large"></i>' || v_crit || ' large</span>' END
        || CASE WHEN v_warn > 0 THEN '<span><i class="dotk moderate"></i>' || v_warn || ' moderate</span>' END
        || '<span><i class="dotk typical"></i>' || v_normal || ' normal</span>'
        || CASE WHEN v_impr > 0
                THEN '<span title="moved in the good direction; not counted">' || v_impr || ' improved</span>' END
        || CASE WHEN v_noted > 0
                THEN '<span title="informational counters that moved; not counted">' || v_noted || ' noted</span>' END
        || CASE WHEN v_folded > 0
                THEN '<span title="flagged twins of a counted row (SYSMETRIC rate of a SYSSTAT counter, '
                     || 'CPU half of the CPU/wait ratio)">' || v_folded || ' folded</span>' END
        || '</span>';
    -- class "vw in-s in-a": in both views; the cards are Summary only, the
    -- per-domain detail tables All sections only.  "sumsec": no panel in
    -- the Summary view (the cards are the panels).
    DBMS_OUTPUT.PUT_LINE('<section id="findings" class="vw in-s in-a sumsec"><h2 id="findings-heading">'
        || CASE WHEN v_order.COUNT > 0
                THEN '<span class="vw in-s">' || v_order.COUNT || ' finding'
                     || CASE WHEN v_order.COUNT = 1 THEN '' ELSE 's' END || '</span>'
                     || '<span class="vw in-a">Findings</span>'
                ELSE 'Findings' END
        || CASE WHEN v_order.COUNT > 0
                THEN '<span class="meta vw in-s" title="finding cards by severity">'
                     || CASE WHEN v_ncl > 0 THEN '<span><i class="dotk large"></i>' || v_ncl || ' large</span>' END
                     || CASE WHEN v_ncm > 0 THEN '<span><i class="dotk moderate"></i>' || v_ncm || ' moderate</span>' END
                     || '</span>' END
        || v_meta
        || '<small class="h2sub"><span class="vw in-s">'
        || CASE WHEN v_order.COUNT > 0
                THEN 'From ' || (v_crit + v_warn) || ' flagged metric'
                     || CASE WHEN v_crit + v_warn = 1 THEN '' ELSE 's' END
                     || '; ordered by the DB time each card added'
                ELSE 'Every scored metric against its prior windows' END
        || '</span><span class="vw in-a">Every scored metric against its prior windows; one table per domain</span>'
        || '</small></h2>');

    -- plan 033: the Current window's DBID, snapshot range and nominal
    -- start / end, for the cards' read-only "Next step" queries (one row:
    -- MIN / MAX over its VALID instances; all NULL when it is not valid).
    -- When the report skipped an instance for it (RAC, a restart inside
    -- it), the queries keep to the valid ones (v_cw_inst), like the report.
    IF v_order.COUNT > 0 THEN
        FOR cw IN (
            WITH
            @@sql/lib/windows_cte.sql
            SELECT MIN(CASE WHEN valid_flag = 'Y' THEN dbid END)          AS dbid,
                   MIN(CASE WHEN valid_flag = 'Y' THEN begin_snap_id END) AS b,
                   MAX(CASE WHEN valid_flag = 'Y' THEN end_snap_id END)   AS e,
                   TO_CHAR(MIN(CASE WHEN valid_flag = 'Y' THEN win_start_ts END),
                           'YYYY-MM-DD HH24:MI:SS') AS t0,
                   TO_CHAR(MAX(CASE WHEN valid_flag = 'Y' THEN win_end_ts END),
                           'YYYY-MM-DD HH24:MI:SS') AS t1,
                   COUNT(CASE WHEN valid_flag = 'N' AND instance_number IS NOT NULL THEN 1 END) AS n_skip,
                   LISTAGG(CASE WHEN valid_flag = 'Y' THEN TO_CHAR(instance_number) END, ', ')
                       WITHIN GROUP (ORDER BY instance_number) AS insts
            FROM   windows
            WHERE  week_offset = 0
        ) LOOP
            v_cw_dbid := cw.dbid;
            v_cw_b    := cw.b;
            v_cw_e    := cw.e;
            v_cw_t0   := cw.t0;
            v_cw_t1   := cw.t1;
            IF cw.n_skip > 0 AND cw.b IS NOT NULL THEN
                v_cw_inst := cw.insts;
            END IF;
        END LOOP;
    END IF;

    IF v_order.COUNT > 0 THEN
        -- plan 025: the triage list (Summary): every finding on one screen
        DBMS_OUTPUT.PUT_LINE('<div id="triage" class="panel tri vw in-s" role="list" aria-label="Findings in card order">'
            || '<div class="tri-hd" aria-hidden="true"><span>Finding</span><span>Now &middot; normal</span>'
            || '<span>Share of the DB-time rise</span><span>' || TO_CHAR(v_weeks_back + 1) || ' windows</span></div>');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_tri_row(v_order(k));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
        DBMS_OUTPUT.PUT_LINE('<div class="cards vw in-s">');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_card(v_order(k), k);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
        -- the rail's sub-links, one per card, right under "Findings"
        -- (inserted while the page parses, before the rail JS counts links)
        DECLARE
            v_js VARCHAR2(4000);
        BEGIN
            FOR k IN 1 .. v_order.COUNT LOOP
                v_js := v_js || CASE WHEN k > 1 THEN ',' END || '["' || card_id(v_order(k)) || '","'
                    || REPLACE(REPLACE(card_label(v_order(k)), '"', ''), '<', '') || '","'
                    || CASE WHEN v_order(k) <> 'DBTIME' THEN TO_CHAR(g_shr(v_order(k))) END || '"]';
            END LOOP;
            -- v1.7: each card's share of the DB-time rise rides on data-shr,
            -- drawn by CSS ::after -- never a child element: the link's
            -- text names the card (00's data-label, the dashboard design)
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var n=document.querySelector(''nav.toc a[href="#findings"]'');'
                || 'if(!n)return;[' || v_js || '].forEach(function(c){var a=document.createElement("a");'
                || 'a.className="sub";a.href="#"+c[0];a.setAttribute("data-nodot","");a.textContent=c[1];'
                || 'if(c[2]){var p=(c[2]==="0"?"<1":c[2])+"%";a.setAttribute("data-shr",p);a.title=c[1]+": "+p+" of the DB-time rise";}'
                || 'n.parentNode.insertBefore(a,n.nextSibling);n=a;});})();</script>');
        END;
        -- plan 025: fill the triage list's impact cells from each card's
        -- data-impact / data-share (plan 020), make a row click open its
        -- card, and fold every card that carries data-fold (Summary; with
        -- JavaScript off nothing is folded).  window.AWR_fcOpen(card) is
        -- what the chrome's reveal() calls for a link into a folded card;
        -- window.AWR_fcFold(card) makes any card foldable and folds it (17's
        -- plan card under a folded I/O card, plan 026).  A card folds and
        -- unfolds the foldable card right after it that explains it
        -- (data-explains = its id), which keeps its own toggle.  Print
        -- (G4): beforeprint opens every folded card and the closed "Checked
        -- and normal" fold, afterprint folds back exactly those (and reopens
        -- a card that was open but folded with the card it explains).
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,tri=d.getElementById("triage");');
        DBMS_OUTPUT.PUT_LINE('function n2(v){var a=Math.abs(v);return (v<0?"-":"+")+(a>=10?a.toFixed(1):a>=1?a.toFixed(2):a.toFixed(3));}');
        DBMS_OUTPUT.PUT_LINE('if(tri)tri.querySelectorAll(".tri-row[data-card]").forEach(function(r){var id=r.getAttribute("data-card"),c=d.getElementById(id),x=r.querySelector(".tri-imp");if(!c||!x)return;var im=c.getAttribute("data-impact"),sh=c.getAttribute("data-share");if(im===null||im===""){x.innerHTML="<small>no time measure</small>";return;}if(Math.abs(+im)<0.01){x.innerHTML="<small>under 0.01 AAS</small>";return;}var v=+im,s=(sh===null||sh==="")?null:+sh,tot=id==="f-dbtime",w=tot?100:Math.max(0,Math.min(100,s||0));x.innerHTML="<i class=\"tri-bar\"><i style=\"width:"+w+"%\"></i></i><small><b>"+n2(v)+" AAS</b> "+(tot?"total":(s===null?"":(s<1?"&lt;1":s)+"%"))+"</small>";});');
        DBMS_OUTPUT.PUT_LINE('if(tri)tri.addEventListener("click",function(ev){var r=ev.target.closest(".tri-row");if(!r||ev.target.closest("a"))return;var a=r.querySelector("a.tri-go");if(a)a.click();});');
        DBMS_OUTPUT.PUT_LINE('function setF(c,on){c.classList.toggle("fold",on);var b=c.querySelector(".fc-tg");if(b){b.setAttribute("aria-expanded",on?"false":"true");b.textContent=on?"Show card":"Fold";}if(!on&&window.AWR_WG)setTimeout(function(){AWR_WG.render(c);},20);'
            || 'var x=c.nextElementSibling;if(x&&c.id&&x.__fc&&x.getAttribute("data-explains")===c.id&&x.classList.contains("fold")!==on)setF(x,on);}');
        DBMS_OUTPUT.PUT_LINE('function mkF(c){if(c.__fc)return true;var k=c.querySelector(".fc-h .fc-k");if(!k)return false;c.__fc=1;var b=d.createElement("button");b.type="button";b.className="fc-tg";k.appendChild(b);b.addEventListener("click",function(ev){ev.stopPropagation();setF(c,!c.classList.contains("fold"));});c.addEventListener("click",function(ev){if(c.classList.contains("fold")&&!ev.target.closest("a,button"))setF(c,false);});return true;}');
        DBMS_OUTPUT.PUT_LINE('window.AWR_fcOpen=function(c){if(c&&c.classList.contains("fold"))setF(c,false);};');
        DBMS_OUTPUT.PUT_LINE('window.AWR_fcFold=function(c){if(c&&mkF(c))setF(c,true);};');
        DBMS_OUTPUT.PUT_LINE('d.querySelectorAll("#findings .cards > article.fc[data-fold]").forEach(function(c){if(mkF(c))setF(c,true);});');
        DBMS_OUTPUT.PUT_LINE('var pr=null;window.addEventListener("beforeprint",function(){if(pr)return;var cf=d.querySelector("#s-normal details.calm-fold");pr={c:[].slice.call(d.querySelectorAll("article.fc.fold")),o:[].slice.call(d.querySelectorAll("article.fc:not(.fold)")),n:cf&&!cf.open?cf:null};pr.c.forEach(function(c){setF(c,false);});if(pr.n)pr.n.open=true;if(window.AWR_WG)pr.c.forEach(function(c){AWR_WG.render(c);});});');
        DBMS_OUTPUT.PUT_LINE('window.addEventListener("afterprint",function(){if(!pr)return;pr.c.forEach(function(c){setF(c,true);});pr.o.forEach(function(c){if(c.classList.contains("fold"))setF(c,false);});if(pr.n)pr.n.open=false;pr=null;});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<div class="panel calm vw in-s"><p class="calm-empty">'
            || CASE WHEN v_normal = 0
                    THEN 'Nothing could be scored: a metric needs at least 3 valid prior windows.'
                    ELSE 'No finding: every scored metric sits inside its normal range, or moved too little to matter.'
               END || '</p></div>');
    END IF;

    --
    -- Plan 040: the machine-readable result.  ONE script block of type
    -- application/json (data, never executed; nothing in the page reads it),
    -- schema 1: the report's identity and window settings, the card counts
    -- and one object per finding card, in card order, with the numbers the
    -- card shows (lead metric in its base unit, the card's impact and
    -- share as data-impact / data-share).  Always emitted: no card gives
    -- "cards":[], and so does the too-little-history path.  Plan-change and
    -- configuration cards belong to sections 18 / 12 / 17 and are not in
    -- schema 1.  Every string goes through json_escape (which also writes
    -- a less-than sign as backslash-u003c, so no closing script tag can
    -- appear inside the block); one line per card.
    --
    DECLARE
        v_nvp   PLS_INTEGER := 0;     -- valid prior windows
        r       finding_rec;
        v_gc    VARCHAR2(64);
        v_gs    NUMBER;
        v_gu    VARCHAR2(20);
        v_gsh   NUMBER;
    BEGIN
        FOR wr IN (
            WITH
            @@sql/lib/windows_cte.sql
            SELECT week_offset, valid_flag FROM windows_rollup
        ) LOOP
            IF wr.week_offset > 0 AND wr.valid_flag = 'Y' THEN v_nvp := v_nvp + 1; END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('<script type="application/json" id="awr-findings">{"schema":1,"report":{'
            || '"version":"' || json_escape('~awr_version') || '"'
            || ',"run_id":"' || json_escape('~run_id') || '"'
            || ',"db_name":"' || json_escape('~db_name') || '"'
            || ',"dbid":' || json_num(TO_NUMBER('~dbid'), 0)
            || ',"host":"' || json_escape('~host_name') || '"'
            || ',"target_end":"' || json_escape('~target_end_resolved') || '"'
            || ',"win_hours":' || json_num(TO_NUMBER('~win_hours'))
            || ',"step_hours":' || json_num(TO_NUMBER('~step_hours'))
            || ',"weeks_back":' || json_num(v_weeks_back, 0)
            || ',"valid_prior_windows":' || v_nvp
            || ',"template":"' || json_escape('~template_name') || '"'
            || ',"inst_num":' || json_num(~inst_num, 0)
            || '},"counts":{"cards":' || v_order.COUNT || ',"large":' || v_ncl
            || ',"moderate":' || v_ncm || '},"cards":[');
        FOR k IN 1 .. v_order.COUNT LOOP
            v_gc  := v_order(k);
            r     := v_findings(v_glead(v_gc));
            v_gs  := metric_scale(r.metric_domain, r.metric_name);
            v_gu  := metric_unit(r.metric_domain, r.metric_name);
            v_gsh := g_shr(v_gc);
            DBMS_OUTPUT.PUT_LINE('{"id":"' || json_escape(card_id(v_gc)) || '"'
                || ',"group":"' || json_escape(v_gc) || '"'
                || ',"label":"' || json_escape(card_label(v_gc)) || '"'
                || ',"severity":"' || json_escape(r.change_bucket) || '"'
                || ',"domain":"' || json_escape(r.metric_domain) || '"'
                || ',"metric":"' || json_escape(r.metric_name) || '"'
                || ',"unit":"' || json_escape(v_gu) || '"'
                || ',"current":' || json_num(r.cur_val * v_gs)
                || ',"mean":' || json_num(r.prior_mean * v_gs)
                || ',"sd":' || json_num(r.prior_sd * v_gs)
                || ',"n":' || json_num(r.n_prior, 0)
                || ',"z":' || json_num(r.z_score, 3)
                || ',"impact_aas":' || json_num(g_imp(v_gc), 3)
                || ',"share_pct":' || json_num(v_gsh, 0)
                || '}' || CASE WHEN k < v_order.COUNT THEN ',' END);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(']}</script>');
    END;

    --
    -- Detail tables: one per domain, ordered by sev / |z| / |pct| / name.
    -- All sections only (class "vw in-a").
    --
    emit_domain_table('LOAD',   'Load profile');
    emit_domain_table('METRIC', 'System metrics');
    emit_domain_table('WAIT',   'Wait classes');

    DBMS_OUTPUT.PUT_LINE('</section>');

    --
    -- "What changed around it" (Summary): an empty slot; section 12 moves
    -- its configuration card in here (and unhides the section) when a
    -- parameter differs across the compared windows.
    --
    DBMS_OUTPUT.PUT_LINE('<section id="s-changes" class="vw in-s sumsec" hidden>'
        || '<h2>What changed around it<small class="h2sub">Plan and configuration changes '
        || 'under the release flags</small></h2>'
        || '<div class="cards" id="changes-slot"></div></section>');

    --
    -- "Checked and normal" (Summary): every other canonical scored row --
    -- a calm grid of the normal ones (loudest first, then flat baselines),
    -- the ones past a z threshold but under their materiality floor (and
    -- the informational "noted" ones), and the improved ones.
    --
    DECLARE
        v_grid  PLS_INTEGER := 0;
        v_more  PLS_INTEGER := 0;
        v_small VARCHAR2(32767);
        v_ns    PLS_INTEGER := 0;
        v_imp   VARCHAR2(32767);
        v_ni    PLS_INTEGER := 0;
        v_first VARCHAR2(16);
        v_cg    PLS_INTEGER := 0;   -- plan 032: rows in the calm grid (typical |z| <= 2, flat)
        v_cs    PLS_INTEGER := 0;   -- plan 032: moved, too small to matter (typical |z| > 2, noted)
        v_ci    PLS_INTEGER := 0;   -- plan 032: improved
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<section id="s-normal" class="vw in-s sumsec"><h2>Checked and normal'
            || '<span class="meta"><span><i class="dotk typical"></i>' || v_normal || ' normal</span></span>'
            || '<small class="h2sub">Every other scored metric, against the same prior windows</small></h2>');
        IF v_normal = 0 THEN
            DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><p class="calm-empty">'
                || 'Nothing could be scored as normal: a metric needs at least 3 valid prior windows.'
                || '</p></div>');
        ELSE
            -- plan 032: count the three groups first, so the folded summary
            -- line can name them; they add up to v_normal
            FOR p IN 1 .. v_table_idx.COUNT LOOP
                f := v_findings(v_table_idx(p));
                IF f.canonical = 'Y' THEN
                    IF (f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) <= 2)
                       OR f.change_bucket = 'flat baseline' THEN
                        v_cg := v_cg + 1;
                    ELSIF (f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) > 2)
                          OR f.change_bucket = 'noted' THEN
                        v_cs := v_cs + 1;
                    ELSIF f.change_bucket = 'improved' THEN
                        v_ci := v_ci + 1;
                    END IF;
                END IF;
            END LOOP;
            -- plan 032: the body folds to one line in the Summary view; open
            -- when there is no finding card (then this section is the story)
            DBMS_OUTPUT.PUT_LINE('<details class="calm-fold"'
                || CASE WHEN v_order.COUNT = 0 THEN ' open' END || '>'
                || '<summary class="calm-sum"><span><b>' || v_cg || '</b> metric'
                || CASE WHEN v_cg = 1 THEN '' ELSE 's' END || ' within the normal range</span>'
                || '<span>&middot; <b>' || v_cs || '</b> moved too little to matter</span>'
                || '<span>&middot; '
                || CASE WHEN v_ci = 0 THEN 'nothing improved materially'
                        ELSE '<b>' || v_ci || '</b> improved' END
                || '</span></summary>');
            DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><div class="ngrid">');
            -- the calm grid: typical within 2 sigma (loudest first), then flat baselines
            FOR pass IN 1 .. 2 LOOP
                FOR p IN 1 .. v_table_idx.COUNT LOOP
                    f := v_findings(v_table_idx(p));
                    IF f.canonical = 'Y'
                       AND ((pass = 1 AND f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) <= 2)
                         OR (pass = 2 AND f.change_bucket = 'flat baseline')) THEN
                        IF v_first IS NULL THEN v_first := LOWER(f.metric_domain); END IF;
                        IF v_grid < 18 THEN
                            DBMS_OUTPUT.PUT_LINE(nr_row(f));
                            v_grid := v_grid + 1;
                        ELSE
                            v_more := v_more + 1;
                        END IF;
                    END IF;
                END LOOP;
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('</div>'
                || CASE WHEN v_more > 0
                        THEN '<p class="calm-more">and ' || v_more || ' more normal row'
                             || CASE WHEN v_more = 1 THEN '' ELSE 's' END || ' in the '
                             || '<a href="#findings-' || v_first || '">Findings tables</a> (All sections).</p>' END
                || '</div>');
            FOR p IN 1 .. v_table_idx.COUNT LOOP
                f := v_findings(v_table_idx(p));
                IF f.canonical = 'Y' THEN
                    IF (f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) > 2)
                       OR f.change_bucket = 'noted' THEN
                        IF v_ns < 6 THEN v_small := v_small || nr_row(f); END IF;
                        v_ns := v_ns + 1;
                    ELSIF f.change_bucket = 'improved' THEN
                        IF v_ni < 6 THEN v_imp := v_imp || nr_row(f); END IF;
                        v_ni := v_ni + 1;
                    END IF;
                END IF;
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('<div class="calm-notes">'
                || '<div class="panel note"><h3 title="Past a z threshold but under the metric''s '
                || 'materiality floor (sql/lib/metric_policy.plsql), or an informational counter">'
                || 'Moved, too small to matter</h3>'
                || CASE WHEN v_ns = 0 THEN '<p>Nothing crossed a threshold without clearing its floor.</p>'
                        ELSE v_small END
                || CASE WHEN v_ns > 6 THEN '<p class="calm-more">and ' || (v_ns - 6) || ' more</p>' END
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="panel note improved"><h3 title="A material move in the '
                || 'good direction: not a finding, not counted">'
                || CASE WHEN v_ni = 0 THEN 'Improved: none material' ELSE 'Improved' END || '</h3>'
                || CASE WHEN v_ni = 0 THEN '<p>Nothing moved materially in the good direction.</p>'
                        ELSE v_imp END
                || CASE WHEN v_ni > 6 THEN '<p class="calm-more">and ' || (v_ni - 6) || ' more</p>' END
                || '</div></div>');
            DBMS_OUTPUT.PUT_LINE('</details>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('</section>');
    END;
    --
    -- The evidence library's heading (Summary): every section with class
    -- "lib" follows it as one collapsible row (00's chrome JS, _style.sql).
    --
    DBMS_OUTPUT.PUT_LINE('<section id="s-lib" class="vw in-s vhead"><h2>Evidence library'
        || '<small class="h2sub">Every other section, one line each; open a row to read it here</small></h2></section>');
    emit_timeline;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 07_summary END -->'); END;
/
