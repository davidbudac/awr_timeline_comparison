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
-- Display (v1.6.0): every table row draws its bucket with the shared
-- baseline band (sql/lib/band_glyph.plsql band_cells: normal range | band |
-- z | Delta), the page's one current-vs-prior grammar; |z| beyond 99 is
-- clamped, a near-zero sigma is noted under the Delta, and the Delta reads
-- x n at twice the mean or more, else a percentage.  Row ids are the entity
-- anchors fr-<l|m|w>-<name> (finding_anchor).
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
        shr          NUMBER
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
    v_members    PLS_INTEGER := 0;
    j            PLS_INTEGER;

    @@sql/lib/metric_policy.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql

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

        -- All sections only (class "vw in-a"): the per-domain detail
        -- tables, their headings and expanders.  v1.6.0: the bucket is drawn
        -- by the band glyph (sql/lib/band_glyph.plsql); the row keeps its
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
                -- WAIT rows here are rolled up to wait_class (e.g. "Wait
                -- class: User I/O") -- already a compact high-level
                -- rollup, so they deliberately carry NO data-imp attribute.
                -- LOAD/METRIC names are raw stat/metric names and match
                -- is_essential() directly.
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
BEGIN
    -- class "vw in-s in-a": in the Summary and All sections views; the
    -- per-domain detail tables/headings/expanders carry "vw in-a" and show
    -- only in All sections.  The scoring note lives in the About fold.
    DBMS_OUTPUT.PUT_LINE('<section id="findings" class="vw in-s in-a"><h2 id="findings-heading">Findings'
        || '<small class="h2sub">Every scored metric against its prior windows; one lead row per family</small></h2>');

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
               shr
        FROM   measured
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    ),
    ranked AS (
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket, shr,
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
           shr
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

    -- B4: the header counts, now that we have the counters (the header's
    -- span.meta, before the subtitle).  Counts are canonical rows only;
    -- folded twins get their own muted badge.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var h=document.getElementById("findings-heading");'
        || 'if(!h)return;var m=document.createElement("span");m.className="meta";m.innerHTML='''
        || '<span class="badge ' || CASE WHEN v_n_fam > 0 THEN 'crit' ELSE 'skip' END
        || '" title="families with a large or moderate lead; the '
        || 'verdict counts the same">' || v_n_fam || ' finding'
        || CASE WHEN v_n_fam = 1 THEN '' ELSE 's' END || '</span> '
        || '<span class="badge ' || CASE WHEN v_crit > 0 THEN 'crit' ELSE 'skip' END || '">'
        || v_crit || ' large</span> '
        || '<span class="badge ' || CASE WHEN v_warn > 0 THEN 'warn' ELSE 'skip' END || '">'
        || v_warn || ' moderate</span> '
        || CASE WHEN v_impr > 0
                THEN '<span class="badge info" title="moved in the good direction; not counted">'
                     || v_impr || ' improved</span> ' ELSE '' END
        || CASE WHEN v_noted > 0
                THEN '<span class="badge note" title="informational counters that moved; not counted">'
                     || v_noted || ' noted</span> ' ELSE '' END
        || '<span class="badge skip">' || v_typical || ' normal</span>'
        || CASE WHEN v_folded > 0
                THEN ' <span class="badge skip" title="flagged twins of a counted row '
                     || '(SYSMETRIC rate of a SYSSTAT counter, CPU half of the CPU/wait ratio)">'
                     || v_folded || ' folded</span>' ELSE '' END
        || ''';h.insertBefore(m,h.querySelector(".h2sub"));})();</script>');

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
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:12.5px;color:var(--muted);margin:-4px 0 8px 0">'
            || 'Top ' || v_top_n || ' families by |z|; related metrics fold under the expander.</p>');
        DBMS_OUTPUT.PUT_LINE('<table id="findings-movers" data-nocount data-nosort><thead><tr>'
            || '<th>Metric</th>'
            || '<th>Domain</th>'
            || '<th class="num cur-col">Current</th>'
            || band_head
            || '<th class="num">Prior mean</th>'
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
                BEGIN
                    v_cls := bucket_cls(f.change_bucket);
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
                        || '<td class="num" data-w="0"' || fmt_num_title(f.cur_val) || '>'
                            || fmt_num(f.cur_val) || '</td>'
                        || band_cells(f.cur_val, f.prior_mean, f.prior_sd, f.n_prior,
                                      f.change_bucket, CASE WHEN f.canonical = 'N' THEN 'Y' ELSE 'N' END)
                        || '<td class="num">' || fmt_num(f.prior_mean) || '</td>'
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
    -- v_table_idx[p] -> index in v_findings, populated above.  Hidden in
    -- the Summary view (class "vw in-a") -- only "Biggest movers" shows.
    --
    emit_domain_table('LOAD',   'Load profile');
    emit_domain_table('METRIC', 'System metrics');
    emit_domain_table('WAIT',   'Wait classes');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 07_summary END -->'); END;
/
