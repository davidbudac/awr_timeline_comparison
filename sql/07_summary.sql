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
-- cards are ordered large before moderate, then by the largest |z| of any
-- member, and a flagged DB time card moves up to second place.
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
        grp            VARCHAR2(64)
    );
    TYPE findings_t  IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    TYPE idx_t       IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    TYPE fam_idx_t   IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);
    TYPE gz_t        IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    TYPE ord_t       IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
    -- one foreground event of a flagged wait class (card evidence)
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
    v_order      ord_t;
    v_g          VARCHAR2(64);
    v_tmp        VARCHAR2(64);
    v_wait_flag  BOOLEAN := FALSE;
    v_dbt        PLS_INTEGER;
    v_cpu        PLS_INTEGER;
    v_meta       VARCHAR2(4000);

    @@sql/lib/metric_policy.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql

    -- Entity anchors (v1.6.0): the id of THIS finding's row is
    -- finding_anchor(domain, name) = fr-<l|m|w>-<name> (sql/lib/anchor_id
    -- .plsql), the target of every entity link to a metric; src_link()
    -- points at the source row in 02 / 03 / 04 that produced it.
    FUNCTION find_id(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN finding_anchor(p_dom, p_name);
    END find_id;

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
            || '<span class="de">' || p_de || '</span></dd>'
            || '<div class="m">' || delta_span(p_cur, p_mu, p_bucket)
            || band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm') || '</div></div>';
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
            || band_span(r.z_score, r.change_bucket, 'sm', CASE WHEN r.canonical = 'N' THEN 'Y' ELSE 'N' END)
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
    BEGIN
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
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h">'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span></div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg') || band_axis || '</div></header>');
        DBMS_OUTPUT.PUT_LINE('<h3 id="' || v_id || '-h">' || f_ent(r) || ' '
            || move_txt(r.cur_val, r.prior_mean, v_sev)
            || CASE WHEN r.metric_name = 'DB time' THEN
                   CASE v_split WHEN 'W' THEN ', all of it wait' WHEN 'w' THEN ', mostly wait'
                                WHEN 'c' THEN ', mostly CPU' WHEN 'm' THEN ', CPU and wait alike' END END
            || '</h3>');
        DBMS_OUTPUT.PUT_LINE('<div class="fc-b"><div class="fc-main">'
            || '<div class="big"><span class="v">' || fv_num(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="u">' || fv_unit(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="nrm" title="prior mean ' || fv(r.prior_mean * v_s, v_u) || '">normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
            || wg_bars(r.wv, v_s, r.prior_mean, r.prior_sd, v_sev) || wg_dates(TRUE) || '</div></div>');
        DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>');
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
    -- LOAD domain: DBA_HIST_SYSSTAT cumulative counters, per-sec deltas.
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    load_pairs AS (
        SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
               ss.snap_id, ss.value,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_sysstat ss
            ON ss.dbid = w.dbid
           AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND ss.instance_number = w.instance_number
           AND ss.stat_name IN (SELECT stat_name FROM load_targets)
    ),
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
    SELECT metric_domain, metric_name,
           cur_val, prior_mean, prior_sd, n_prior,
           z_score, pct_delta, change_bucket,
           heat_pos,
           -- family / canonical / dir are filled in by the PL/SQL pass below
           CAST(NULL AS VARCHAR2(64)) AS family,
           CAST(NULL AS VARCHAR2(1))  AS canonical,
           CAST(NULL AS VARCHAR2(4))  AS dir,
           shr,
           pairs                      AS wv,
           CAST(NULL AS VARCHAR2(64)) AS grp
    BULK COLLECT INTO v_findings
    FROM   ranked
    ORDER  BY heat_pos;


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
    -- large before moderate, then the loudest |z|; then a flagged DB time
    -- card moves up to second place.
    v_g := v_glead.FIRST;
    WHILE v_g IS NOT NULL LOOP
        j := v_order.COUNT;
        WHILE j >= 1 AND card_before(v_gsev(v_g), v_gz(v_g), v_gsev(v_order(j)), v_gz(v_order(j))) LOOP
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

    --
    -- Card evidence: the top 2 foreground events (by Current time waited
    -- per second) of every wait class, with their prior mean / sd / n and
    -- share of the Current wait -- one bounded scan, only when a wait
    -- class is flagged.  Same pairs -> bounds -> deltas shape and template
    -- filter as 04.
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
    -- Section header: title, a one-line subtitle per view, the counts.
    -- Counts are canonical rows only; folded twins get their own muted
    -- count.  The "N findings" = cards (card groups of families), the same
    -- number the verdict pills show.
    --
    v_meta := '<span class="meta">'
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
        || v_meta
        || '<small class="h2sub"><span class="vw in-s">'
        || CASE WHEN v_order.COUNT > 0
                THEN (v_crit + v_warn) || ' metric' || CASE WHEN v_crit + v_warn = 1 THEN '' ELSE 's' END
                     || ' moved, in ' || v_order.COUNT || ' famil'
                     || CASE WHEN v_order.COUNT = 1 THEN 'y' ELSE 'ies' END
                ELSE 'Every scored metric against its prior windows' END
        || '</span><span class="vw in-a">Every scored metric against its prior windows; one table per domain</span>'
        || '</small></h2>');

    IF v_order.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div class="cards vw in-s">');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_card(v_order(k), k);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<div class="panel calm vw in-s"><p class="calm-empty">'
            || CASE WHEN v_normal = 0
                    THEN 'Nothing could be scored: a metric needs at least 3 valid prior windows.'
                    ELSE 'No finding: every scored metric sits inside its normal range, or moved too little to matter.'
               END || '</p></div>');
    END IF;

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
        || '<h2>What changed around it<small class="h2sub">Configuration that differs across the '
        || 'compared windows, under the release flags</small></h2>'
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
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<section id="s-normal" class="vw in-s sumsec"><h2>Checked and normal'
            || '<span class="meta"><span><i class="dotk typical"></i>' || v_normal || ' normal</span></span>'
            || '<small class="h2sub">Every other scored metric, against the same prior windows</small></h2>');
        IF v_normal = 0 THEN
            DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><p class="calm-empty">'
                || 'Nothing could be scored as normal: a metric needs at least 3 valid prior windows.'
                || '</p></div>');
        ELSE
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
        END IF;
        DBMS_OUTPUT.PUT_LINE('</section>');
    END;
    emit_timeline;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 07_summary END -->'); END;
/
