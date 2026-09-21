--
-- 07_summary.sql
-- For every scalar metric rendered by sections 02-04, compute the z-score
-- of the current window against the mean/stddev of the prior valid windows,
-- bucket the change magnitude (large / moderate / improved / typical) and
-- render the "Biggest movers" table + per-domain findings detail tables.
-- Buckets describe how far the current value sits from its baseline of
-- prior comparison windows; "large" is not a value judgement, just a
-- |z| > 3 outlier that also clears the materiality floor (see below).
--
-- Fewer findings, same information (v1.5.0):
--   - z uses a sigma floor, GREATEST(sd, 2% of |mean|), so a dead-flat
--     baseline cannot blow a trivial wobble up to |z| > 99;
--   - a row is large / moderate only when the move is MATERIAL: |%-delta|
--     >= 10 and, for wait classes, >= 2% of the Current window's total
--     non-idle wait time (an immaterial |z| > 2 renders as typical with an
--     "immaterial" badge);
--   - names are grouped into families via sql/lib/finding_family.plsql:
--     the SYSMETRIC rate twin of a SYSSTAT counter, and the CPU half of the
--     CPU/wait ratio pair, are non-canonical -- scored and shown (muted,
--     class "twin") but never counted, and "Biggest movers" shows one lead
--     row per family with its flagged relatives folded under an expander;
--   - a material drop in a cost-type name (waits, latency, hard parses) is
--     "improved" (class info), excluded from the crit / warn counts.
-- The same rule lives in sql/lib/score_cells.plsql (04/05/06/14/15/18),
-- sql/00_params.sql (verdict), sql/08_overview.sql (hero cards),
-- sql/lib/day_profile_cte.sql (16) and sql/17_narrative.sql -- kept in
-- sync by inspection, per the "findings are recomputed, not shared" rule.
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- persist anything.
--
-- Implementation note: the same set of findings drives two views (the
-- "Biggest movers" top-8-by-|z| table and the per-domain detail tables),
-- each with a different ordering.  We BULK COLLECT the unified
-- LOAD/METRIC/WAIT recompute exactly once into a PL/SQL collection, attach
-- the detail-table view position via ROW_NUMBER(), and then walk the
-- collection: once to build tallies / the table-order index / the top-8
-- "movers" shortlist (all in the same pass, so no second query is ever
-- run), and again per domain to emit the detail tables in table order.
--
-- Display-only rules layered on top of the scoring above (do not change
-- change_bucket / severity):
--   - |z| > 99 is clamped to "&gt;+99" / "&lt;&minus;99" for display.
--   - A near-zero baseline sigma (sd < 1% of |mean|, or both exactly 0)
--     gets a "sigma approx 0" badge next to the z value and a bold %-delta
--     cell, nudging the reader toward %-delta instead of an inflated z.
--   - Every displayed %-delta carries a leading up/down triangle instead of
--     a signed number; no per-direction color class is used (severity
--     color stays on .badge only).
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
        share          NUMBER
    );
    TYPE findings_t  IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    TYPE idx_t       IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    TYPE fam_idx_t   IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);

    v_findings   findings_t;
    v_table_idx  idx_t;
    f            finding_rec;

    v_total      NUMBER := 0;
    v_crit       NUMBER := 0;
    v_warn       NUMBER := 0;
    v_impr       NUMBER := 0;
    v_noted      NUMBER := 0;
    v_folded     NUMBER := 0;
    v_typical    NUMBER := 0;
    v_n_tbl      PLS_INTEGER := 0;
    v_n_fam      PLS_INTEGER := 0;   -- families whose lead is large / moderate
    -- family -> index (in v_findings) of the family's lead row: the
    -- canonical member with the largest |z|.
    v_lead       fam_idx_t;
    v_fam        VARCHAR2(64);
    v_weeks_back NUMBER := ~weeks_back;

    -- "Biggest movers" (T6): top 8 FAMILY LEADS by |z| across all domains,
    -- tracked via a tiny sorted array while the SAME collection above is
    -- walked -- no second cursor/query.
    v_top        findings_t;
    v_top_n      PLS_INTEGER := 0;
    v_tmp        finding_rec;
    v_az         NUMBER;
    v_bar_w      PLS_INTEGER;
    v_members    PLS_INTEGER := 0;
    j            PLS_INTEGER;

    @@sql/lib/is_essential.plsql
    @@sql/lib/metric_policy.plsql
    v_pol        policy_rec;      -- declared after the include (policy_rec lives there)
    @@sql/lib/fmt_num.plsql
    @@sql/lib/anchor_id.plsql

    -- Phase 3 cross-links: the id of THIS finding's row, and a link to the
    -- source row in 02 / 03 / 04 that produced it (same anchor_id rule).
    FUNCTION find_id(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN anchor_id('find-' || LOWER(p_dom), p_name);
    END find_id;

    FUNCTION src_link(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN ' <a class="xlink" href="#'
            || CASE p_dom
                   WHEN 'LOAD'   THEN anchor_id('load', p_name)
                   WHEN 'METRIC' THEN anchor_id('metric', p_name)
                   ELSE anchor_id('fgc', REGEXP_REPLACE(p_name, '^Wait class: ', ''))
               END
            || '" title="Go to this metric''s row in '
            || CASE p_dom WHEN 'LOAD' THEN 'Load profile'
                          WHEN 'METRIC' THEN 'System metrics'
                          ELSE 'Foreground waits' END
            || '">&#8599; row</a>';
    END src_link;

    -- Detail-table order: severity rank, |z| DESC, |pct| DESC, name.
    -- Computed here (not by ROW_NUMBER in the SQL) because the 'improved'
    -- bucket needs finding_family()'s direction flag, a PL/SQL function.
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

    -- "immaterial": |z| cleared 2 but the materiality floor held it back.
    FUNCTION imm_badge(p_bucket VARCHAR2, p_z NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_bucket = 'typical' AND p_z IS NOT NULL AND ABS(p_z) > 2 THEN
            RETURN ' <span class="badge sig" title="|z| above 2 but the move is below '
                || 'this metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">'
                || 'immaterial</span>';
        END IF;
        RETURN '';
    END imm_badge;

    -- Shared display-only formatting (B5/F5): clamp |z|>99, flag a
    -- near-zero baseline sigma, and render %-delta with a direction glyph.
    -- Duplicated (not shared) with sql/lib/score_cells.plsql on purpose --
    -- same "findings are recomputed, not shared" convention as the scoring
    -- above; the two stay in sync by inspection, not by a shared function.
    FUNCTION fmt_z(p_z NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_z IS NULL THEN '&mdash;'
            WHEN p_z > 99    THEN '&gt;+99'
            WHEN p_z < -99   THEN '&lt;&minus;99'
            ELSE TO_CHAR(p_z, 'FMS99990D00')
        END;
    END fmt_z;

    FUNCTION fmt_pct(p_pct NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_pct IS NULL THEN '&mdash;'
            WHEN p_pct < 0     THEN '&#9660; ' || TO_CHAR(ABS(p_pct), 'FM99990D0') || '%'
            ELSE '&#9650; ' || TO_CHAR(p_pct, 'FM99990D0') || '%'
        END;
    END fmt_pct;

    FUNCTION is_sig(p_mu NUMBER, p_sd NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_mu IS NOT NULL AND p_sd IS NOT NULL THEN
            IF (p_mu = 0 AND p_sd = 0)
               OR (p_mu <> 0 AND p_sd < 0.01 * ABS(p_mu)) THEN
                RETURN 'Y';
            END IF;
        END IF;
        RETURN 'N';
    END is_sig;

    PROCEDURE emit_domain_table(p_dom VARCHAR2, p_title VARCHAR2) IS
        v_row      VARCHAR2(32767);
        v_sev      VARCHAR2(40);
        v_cls      VARCHAR2(10);
        v_imp      VARCHAR2(1);
        v_sig      VARCHAR2(1);
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
                -- or insufficient history are tail candidates the sidebar
                -- toggle collapses behind an expander.
                IF rec.change_bucket IN ('typical', 'flat baseline', 'insufficient history',
                                         'improved', 'noted') THEN
                    v_tail_cnt := v_tail_cnt + 1;
                END IF;
            END IF;
        END LOOP;
        IF v_count = 0 THEN RETURN; END IF;

        v_tbl_id := 'findings-' || LOWER(p_dom);

        -- detail-only: the per-domain detail tables (and their
        -- headings/expanders) when the triage view is on; only the
        -- "Biggest movers" table stays visible there.
        DBMS_OUTPUT.PUT_LINE('<h3 class="detail-only">' || p_title || '</h3>');
        DBMS_OUTPUT.PUT_LINE('<table id="' || v_tbl_id || '" class="detail-only">'
            || '<thead><tr>'
            || '<th>Change</th>'
            || '<th>Metric</th>'
            || '<th class="num">Current</th>'
            || '<th class="num">Prior mean</th>'
            || '<th class="num">Prior sd</th>'
            || '<th class="num">n</th>'
            || '<th class="num">z-score</th>'
            || '<th class="num">% &Delta;</th>'
            || '</tr></thead><tbody>');

        FOR p IN 1 .. v_table_idx.COUNT LOOP
            rec := v_findings(v_table_idx(p));
            IF rec.metric_domain = p_dom THEN
                v_sev := rec.change_bucket;
                v_cls := bucket_cls(v_sev);
                -- WAIT rows here are rolled up to wait_class (e.g. "Wait
                -- class: User I/O") -- already a compact high-level
                -- rollup, so they deliberately carry NO data-imp attribute
                -- and stay visible in Essential mode (untagged rows are
                -- never hidden by the CSS rule and never counted by the
                -- pill JS, which both select only rows with data-imp).
                -- LOAD/METRIC names are raw stat/metric names and match
                -- is_essential() directly.
                v_imp := CASE WHEN rec.metric_domain = 'WAIT' THEN NULL
                              ELSE is_essential(rec.metric_domain, rec.metric_name) END;
                v_sig := is_sig(rec.prior_mean, rec.prior_sd);
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
                    || '<td><span class="badge ' || v_cls || '">' || v_sev || '</span></td>'
                    || '<td>' || DBMS_XMLGEN.CONVERT(rec.metric_name)
                        || CASE WHEN rec.canonical = 'N'
                                THEN ' <span class="chip" title="same quantity as a counted '
                                     || 'row; not counted again">twin</span>'
                                ELSE '' END
                        || src_link(rec.metric_domain, rec.metric_name)
                        || '</td>'
                    || '<td class="num"' || fmt_num_title(rec.cur_val) || '>'
                        || fmt_num(rec.cur_val) || '</td>'
                    || '<td class="num">' || fmt_num(rec.prior_mean) || '</td>'
                    || '<td class="num">' || fmt_num(rec.prior_sd) || '</td>'
                    || '<td class="num">' || NVL(TO_CHAR(rec.n_prior), '0') || '</td>'
                    || '<td class="num">' || fmt_z(rec.z_score)
                        || CASE WHEN v_sig = 'Y' THEN
                               ' <span class="badge sig" title="baseline barely moved: '
                               || '&sigma; below 1% of mean (floored to 2% for z); read the % delta instead">'
                               || '&sigma;&approx;0</span>'
                           END
                        || imm_badge(v_sev, rec.z_score)
                        || '</td>'
                    || '<td class="num">'
                        || CASE WHEN v_sig = 'Y' THEN '<b>' || fmt_pct(rec.pct_delta) || '</b>'
                                ELSE fmt_pct(rec.pct_delta) END
                        || '</td>'
                    || '</tr>';
                DBMS_OUTPUT.PUT_LINE(v_row);
            END IF;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');

        IF v_tail_cnt > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<span class="expander detail-only" data-for="' || v_tbl_id
                || '" data-n="' || v_tail_cnt || '" data-noun="typical / improved / flat rows">'
                || '&#9656; Show ' || v_tail_cnt || ' typical / improved / flat rows</span>');
        END IF;
    END emit_domain_table;
BEGIN
    -- data-normal="Y" keeps this section in the Normal view; the
    -- per-domain detail tables/headings/expanders carry class
    -- "detail-only" and show only in the Detailed view.
    DBMS_OUTPUT.PUT_LINE('<section id="findings" data-normal="Y"><h2 id="findings-heading">Findings summary</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'z = (current &minus; &mu;) &divide; max(&sigma;, 2% of &mu;) over prior valid windows. '
        || '|z|&gt;3 large, |z|&gt;2 moderate, else typical &mdash; but only when the move is material: '
        || '|%-delta| &ge; 10 and, for wait classes, &ge; 2% of the Current window''s wait time '
        || '(otherwise typical, tagged immaterial). '
        || 'Each metric has its own direction and floors (sql/lib/metric_policy.plsql): '
        || 'a move in the good direction is <b>improved</b>, an informational counter is <b>noted</b> '
        || '&mdash; neither is highlighted or counted. '
        || 'Twins &mdash; the SYSMETRIC rate of a SYSSTAT counter, the CPU half of the CPU/wait ratio '
        || '&mdash; are shown muted and never counted. '
        || 'n&lt;3 &rarr; %-delta only. '
        || '|z| beyond &plusmn;99 is capped for display; '
        || '&sigma;&approx;0 flags a baseline that barely moved &mdash; read the %-delta there instead.</p>');

    --
    -- Recompute LOAD / METRIC / WAIT values per (week_offset, metric) from
    -- the AWR views, pivot to cur vs prior AVG/STDDEV, derive the change
    -- bucket, and tag each row with its detail-table view position via
    -- ROW_NUMBER.  Bulk-collected once; every view below iterates the
    -- collection.
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
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END) AS n
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
        SELECT p.metric_domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n,
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
               END AS share
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
               share
        FROM   measured
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    ),
    ranked AS (
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket, share,
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
           share
    BULK COLLECT INTO v_findings
    FROM   ranked
    ORDER  BY heat_pos;

    --
    -- Single pass over the bulk-collected findings: tallies (large/
    -- moderate/typical), the detail-table order index, and the "Biggest
    -- movers" top-8-by-|z| shortlist (kept sorted in a tiny array as we go,
    -- so no second query is ever issued against v_findings).
    --
    -- Pass 1: per-metric policy (family / canonical / direction) and the
    -- change bucket per row, tallies over CANONICAL rows only, the
    -- per-family lead, and the detail-table order (insertion sort on
    -- tbl_before).  'improved' / 'noted' rows are counted separately and
    -- never highlighted.
    FOR i IN 1 .. v_findings.COUNT LOOP
        v_pol := metric_policy(v_findings(i).metric_domain, v_findings(i).metric_name);
        v_findings(i).family    := finding_family(v_findings(i).metric_domain,
                                                  v_findings(i).metric_name);
        v_findings(i).canonical := v_pol.canonical;
        v_findings(i).dir       := v_pol.dir;
        v_findings(i).change_bucket :=
            policy_bucket(v_findings(i).metric_domain, v_findings(i).metric_name, NULL,
                          v_findings(i).cur_val, v_findings(i).prior_mean,
                          v_findings(i).prior_sd, v_findings(i).n_prior,
                          v_findings(i).share);
        f := v_findings(i);
        v_total := v_total + 1;
        IF f.change_bucket IN ('large', 'moderate', 'improved', 'noted') THEN
            IF f.canonical = 'N' THEN
                v_folded := v_folded + 1;
            ELSIF f.change_bucket = 'large'    THEN v_crit := v_crit + 1;
            ELSIF f.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
            ELSIF f.change_bucket = 'improved' THEN v_impr := v_impr + 1;
            ELSE                                    v_noted := v_noted + 1;
            END IF;
        END IF;

        -- family lead = canonical LARGE / MODERATE member with the largest
        -- |z| (improved / noted / typical rows never lead a family, so
        -- "Biggest movers" lists real findings only)
        IF f.canonical = 'Y' AND f.change_bucket IN ('large', 'moderate') THEN
            IF NOT v_lead.EXISTS(f.family)
               OR ABS(NVL(f.z_score, 0)) > ABS(NVL(v_findings(v_lead(f.family)).z_score, 0)) THEN
                v_lead(f.family) := i;
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

    -- Pass 2: "Biggest movers" = the top 8 family leads by |z|; the
    -- number of flagged families is the report's headline finding count.
    v_fam := v_lead.FIRST;
    WHILE v_fam IS NOT NULL LOOP
        f := v_findings(v_lead(v_fam));
        IF f.change_bucket IN ('large', 'moderate') THEN
            v_n_fam := v_n_fam + 1;
        END IF;
        v_az := ABS(NVL(f.z_score, 0));
        j := 0;
        IF v_top_n < 8 THEN
            v_top_n := v_top_n + 1;
            v_top(v_top_n) := f;
            j := v_top_n;
        ELSIF v_az > ABS(NVL(v_top(8).z_score, 0)) THEN
            v_top(8) := f;
            j := 8;
        END IF;
        WHILE j > 1 AND ABS(NVL(v_top(j - 1).z_score, 0)) < ABS(NVL(v_top(j).z_score, 0)) LOOP
            v_tmp := v_top(j - 1);
            v_top(j - 1) := v_top(j);
            v_top(j) := v_tmp;
            j := j - 1;
        END LOOP;
        v_fam := v_lead.NEXT(v_fam);
    END LOOP;

    v_typical := v_total - v_crit - v_warn - v_impr - v_noted - v_folded;

    -- B4: rewrite the heading now that we have the counters.  Counts are
    -- canonical rows only; folded twins get their own muted badge.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var h=document.getElementById("findings-heading");'
        || 'if(h)h.innerHTML=''Findings summary '
        || '<span class="badge crit" title="families with a large or moderate lead; the '
        || 'verdict counts the same">' || v_n_fam || ' finding'
        || CASE WHEN v_n_fam = 1 THEN '' ELSE 's' END || '</span> '
        || '<span class="badge crit">' || v_crit || ' large</span> '
        || '<span class="badge warn">' || v_warn || ' moderate</span> '
        || CASE WHEN v_impr > 0
                THEN '<span class="badge info" title="moved in the good direction; not counted">'
                     || v_impr || ' improved</span> ' ELSE '' END
        || CASE WHEN v_noted > 0
                THEN '<span class="badge note" title="informational counters that moved; not counted">'
                     || v_noted || ' noted</span> ' ELSE '' END
        || '<span class="badge skip">' || v_typical || ' typical</span>'
        || CASE WHEN v_folded > 0
                THEN ' <span class="badge skip" title="flagged twins of a counted row '
                     || '(SYSMETRIC rate of a SYSSTAT counter, CPU half of the CPU/wait ratio)">'
                     || v_folded || ' folded</span>' ELSE '' END
        || ''';})();</script>');

    --
    -- T6: "Biggest movers" -- top 8 flagged family leads by |z| across all
    -- domains, replacing the old ECharts findings heatmap with a plain HTML
    -- table so it degrades with body.no-charts like everything else and
    -- never needs a chart lib.  Improved / noted rows never appear here.
    --
    IF v_top_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">No material regression: nothing moved beyond its '
            || 'own floors in the bad direction'
            || CASE WHEN v_impr > 0 THEN ' (' || v_impr || ' improved)' ELSE '' END
            || '. The per-domain tables below list every scored metric.</p>');
    END IF;
    IF v_top_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<h3>Biggest movers</h3>');
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
            || 'one lead row per family (top ' || v_top_n || ' by |z|); '
            || 'flagged relatives and twins fold under the expander; '
            || 'bar = |%-delta|, log-scaled</p>');
        DBMS_OUTPUT.PUT_LINE('<table id="findings-movers" data-nocount data-nosort><thead><tr>'
            || '<th>Metric</th>'
            || '<th>Domain</th>'
            || '<th class="num">z</th>'
            || '<th class="num">Current</th>'
            || '<th class="num">Prior mean</th>'
            || '<th class="num">% &Delta;</th>'
            || '</tr></thead><tbody>');

        FOR i IN 1 .. v_top_n LOOP
            f := v_top(i);
            -- The lead row, then every other flagged member of its family
            -- (twins included) as a muted, collapsed "member" row.
            FOR m IN 0 .. v_findings.COUNT LOOP
                IF m = 0 THEN
                    f := v_top(i);
                ELSE
                    f := v_findings(m);
                    IF f.family <> v_top(i).family
                       OR f.metric_name = v_top(i).metric_name
                       OR f.change_bucket NOT IN ('large', 'moderate') THEN
                        CONTINUE;
                    END IF;
                    v_members := v_members + 1;
                END IF;
                DECLARE
                    v_cls     VARCHAR2(10);
                    v_sig     VARCHAR2(1);
                    v_bar_col VARCHAR2(20);
                    v_apct    NUMBER;
                BEGIN
                    v_cls := bucket_cls(f.change_bucket);
                    v_sig := is_sig(f.prior_mean, f.prior_sd);
                    v_apct := ABS(f.pct_delta);
                    -- Log-scaled |%-delta| bar, capped at 150px (a 10% move
                    -- is a stub, 100% about a third, 500%+ full width).
                    IF v_apct IS NULL THEN
                        v_bar_w := 0;
                    ELSE
                        v_bar_w := LEAST(150, ROUND(20 + 40 * LN(1 + v_apct / 50)));
                    END IF;
                    v_bar_col := CASE v_cls WHEN 'crit' THEN 'var(--crit)'
                                            WHEN 'warn' THEN 'var(--warn)'
                                            ELSE             'var(--skip)' END;

                    DBMS_OUTPUT.PUT_LINE('<tr class="' || v_cls
                        || CASE WHEN m > 0 THEN ' member' ELSE '' END
                        || CASE WHEN f.canonical = 'N' THEN ' twin' ELSE '' END
                        || '" data-family="' || f.family || '"'
                        || CASE WHEN m > 0 THEN ' data-tail="Y"' ELSE '' END || '>'
                        || '<td>' || DBMS_XMLGEN.CONVERT(f.metric_name)
                        || CASE WHEN f.canonical = 'N'
                                THEN ' <span class="chip" title="same quantity as the lead; '
                                     || 'not counted again">twin</span>'
                                ELSE '' END
                        || ' <a class="xlink" href="#' || find_id(f.metric_domain, f.metric_name)
                        || '" title="Go to this finding''s detail row">&#8599; detail</a>'
                        || '</td>'
                        || '<td><span class="chip">' || f.metric_domain || '</span></td>'
                        || '<td class="num">'
                        || fmt_z(f.z_score)
                        || CASE WHEN v_sig = 'Y' THEN
                               ' <span class="badge sig" title="baseline barely moved: '
                               || '&sigma; below 1% of mean (floored to 2% for z); read the % delta instead">'
                               || '&sigma;&approx;0</span>'
                           END
                        || '</td>'
                        || '<td class="num"' || fmt_num_title(f.cur_val) || '>'
                            || fmt_num(f.cur_val) || '</td>'
                        || '<td class="num">' || fmt_num(f.prior_mean) || '</td>'
                        || '<td class="num">'
                            || CASE WHEN v_bar_w > 0 THEN
                                   '<span class="zbar" style="width:' || v_bar_w || 'px;'
                                   || 'background-color:' || v_bar_col || '"></span>'
                               END
                            || CASE WHEN v_sig = 'Y' THEN '<b>' || fmt_pct(f.pct_delta) || '</b>'
                                    ELSE fmt_pct(f.pct_delta) END
                            || '</td>'
                        || '</tr>');
                END;
            END LOOP;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        IF v_members > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<span class="expander" data-for="findings-movers"'
                || ' data-n="' || v_members || '" data-noun="related metrics">'
                || '&#9656; Show ' || v_members || ' related metrics</span>');
        END IF;
    END IF;

    --
    -- Detail tables: one per domain, ordered by sev / |z| / |pct| / name.
    -- v_table_idx[p] -> index in v_findings, populated above.  Hidden under
    -- the Normal view (class "detail-only") -- only "Biggest movers" shows.
    --
    emit_domain_table('LOAD',   'Load profile');
    emit_domain_table('METRIC', 'System metrics');
    emit_domain_table('WAIT',   'Wait classes');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 07_summary END -->'); END;
/
