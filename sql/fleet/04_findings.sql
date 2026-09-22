--
-- sql/fleet/04_findings.sql
-- "Findings" detail-block for the detail panel's right column: the unified
-- LOAD/METRIC/WAIT z-score compute is the same CTE chain as
-- sql/07_summary.sql (windows_cte -> load/metric/wait pairs -> bounds ->
-- deltas -> unified -> pivoted -> scored, using the FLEET template's curated
-- target lists via ~template_dir).  The SQL yields z (over the floored
-- sigma), %-delta and, for wait rows, the share of the Current total; the
-- change bucket is assigned in PL/SQL by policy_bucket() from the SHARED
-- sql/lib/metric_policy.plsql (a read-only @@ include -- the fleet reuses
-- lib fragments, it never edits them), so the fleet band applies exactly
-- the single-DB report's per-metric direction and materiality floors: a
-- drop in a cost-type name is 'improved', a bookkeeping counter that moved
-- is 'noted', and neither is printed or counted.  Only 'large' / 'moderate'
-- rows are printed (large first, then by |z|); everything else is counted
-- as suppressed and summarized in one muted line.
--
-- Ends with the machine-readable HTML comment (<!-- FLEET-COUNTS ... -->)
-- that is the PL/SQL -> bash handoff -- the wrapper's assembler regex-matches
-- "findings crit=<int> warn=<int> suppressed=<int>" out of the spooled
-- fragment to compute this DB's severity score and substitute the row
-- placeholders.  Keep the token format and spacing EXACT.
--
-- Read-only: recomputes everything in-flight from the AWR views.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_04 BEGIN -->'); END;
/

DECLARE
    v_crit       PLS_INTEGER := 0;
    v_warn       PLS_INTEGER := 0;
    v_improved   PLS_INTEGER := 0;
    v_suppressed PLS_INTEGER := 0;
    v_open_table BOOLEAN := FALSE;

    TYPE finding_rec IS RECORD (
        metric_domain VARCHAR2(16),
        metric_name   VARCHAR2(120),
        cur_val       NUMBER,
        prior_mean    NUMBER,
        prior_sd      NUMBER,
        n_prior       NUMBER,
        z_score       NUMBER,
        pct_delta     NUMBER,
        shr         NUMBER,
        change_bucket VARCHAR2(40)
    );
    TYPE findings_t IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    v_findings   findings_t;

    -- The per-metric policy + the scoring rule (policy_bucket), shared with
    -- the single-DB report.  Read-only reuse of a lib fragment.
    @@sql/lib/metric_policy.plsql

    -- F5: a fleet-local twin of sql/lib/score_cells.plsql's cell renderer
    -- (a SHARED lib file -- off limits to a fleet-only visual change per
    -- CLAUDE.md's cardinal no-touch rule).  The bucket comes in from the
    -- caller (policy_bucket); the z-score and %-delta cells render an
    -- up/down direction glyph + absolute value instead of a signed number;
    -- color still comes only from the badge's crit/warn/ok class below,
    -- never from the glyph or the sign.
    FUNCTION score_cells_dir(p_bucket VARCHAR2,
                              p_z      NUMBER,
                              p_pct    NUMBER) RETURN VARCHAR2 IS
        v_z      NUMBER := p_z;
        v_pct    NUMBER := p_pct;
        v_bucket VARCHAR2(40) := p_bucket;
        v_cls    VARCHAR2(10);
        v_zt     VARCHAR2(40);
        v_pt     VARCHAR2(40);
    BEGIN
        v_cls := CASE v_bucket
                     WHEN 'large'    THEN 'crit'
                     WHEN 'moderate' THEN 'warn'
                     WHEN 'typical'  THEN 'ok'
                     ELSE                 'skip'
                 END;
        v_zt := CASE WHEN v_z IS NULL THEN '&mdash;'
            ELSE (CASE WHEN v_z >= 0 THEN '&#9650; ' ELSE '&#9660; ' END)
                 || TO_CHAR(ABS(v_z), 'FM99990D00',
                            'NLS_NUMERIC_CHARACTERS=''.,''') END;
        v_pt := CASE WHEN v_pct IS NULL THEN '&mdash;'
            ELSE (CASE WHEN v_pct >= 0 THEN '&#9650; ' ELSE '&#9660; ' END)
                 || TO_CHAR(ABS(v_pct), 'FM99990D0',
                            'NLS_NUMERIC_CHARACTERS=''.,''') || '%' END;
        RETURN '<td><span class="badge ' || v_cls || '">'
            || v_bucket
            || '</span></td>'
            || '<td class="num">' || v_zt || '</td>'
            || '<td class="num">' || v_pt || '</td>';
    END score_cells_dir;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<div class="detail-block">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h">Findings (material, in the bad direction)</div>');

    -- One bulk fetch of the unified recompute; the bucket is assigned in the
    -- PL/SQL pass below.
    WITH
        @@sql/lib/windows_cte.sql
        ,
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
        -- non-idle wait time across every class (s/s), as in 07.
        wait_total AS (
            SELECT SUM(metric_value) AS tot
            FROM   wait_rows
            WHERE  week_offset = 0
        ),
        scored AS (
            SELECT p.metric_domain, p.metric_name,
                   p.cur_val,
                   p.mu       AS prior_mean,
                   p.sd       AS prior_sd,
                   p.n        AS n_prior,
                   -- z over the floored sigma, GREATEST(sd, 2% of |mu|)
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
                   END AS shr,
                   CAST(NULL AS VARCHAR2(40)) AS change_bucket
            FROM   pivoted p
            CROSS JOIN wait_total t
            WHERE  p.cur_val IS NOT NULL OR p.mu IS NOT NULL
        )
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, shr, change_bucket
        BULK COLLECT INTO v_findings
        FROM   scored
        ORDER BY ABS(NVL(z_score, 0)) DESC,
                 ABS(NVL(pct_delta, 0)) DESC,
                 metric_name;

    -- Pass 1: bucket every row through the shared policy and tally.
    FOR i IN 1 .. v_findings.COUNT LOOP
        v_findings(i).change_bucket :=
            policy_bucket(v_findings(i).metric_domain, v_findings(i).metric_name, NULL,
                          v_findings(i).cur_val, v_findings(i).prior_mean,
                          v_findings(i).prior_sd, v_findings(i).n_prior,
                          v_findings(i).shr);
        IF v_findings(i).change_bucket = 'large' THEN
            v_crit := v_crit + 1;
        ELSIF v_findings(i).change_bucket = 'moderate' THEN
            v_warn := v_warn + 1;
        ELSE
            v_suppressed := v_suppressed + 1;
            IF v_findings(i).change_bucket = 'improved' THEN
                v_improved := v_improved + 1;
            END IF;
        END IF;
    END LOOP;

    -- Pass 2: print large rows first, then moderate, each by |z| DESC (the
    -- collection's order).  Twice over the same collection, no second query.
    FOR pass IN 1 .. 2 LOOP
    FOR i IN 1 .. v_findings.COUNT LOOP
        DECLARE
            f finding_rec := v_findings(i);
        BEGIN
        IF f.change_bucket <> CASE pass WHEN 1 THEN 'large' ELSE 'moderate' END THEN
            CONTINUE;
        END IF;

        IF NOT v_open_table THEN
            DBMS_OUTPUT.PUT_LINE('<p class="muted dt-note">'
                || 'Compares the <b>current</b> window against the <b>mean of the prior '
                || 'comparison windows</b> (the same hour across the previous periods) '
                || '&mdash; not the single preceding window. '
                || '% &Delta; = (Current &minus; Prior mean) / |Prior mean| &times; 100; '
                || 'z-score divides that same gap by the baseline&rsquo;s standard deviation '
                || '(floored at 2% of the mean). A row is listed only when the move clears '
                || 'the metric&#39;s own floors in its bad direction (sql/lib/metric_policy.plsql); '
                || 'a drop in a cost-type metric is an improvement and is not listed.'
                || '</p>');
            DBMS_OUTPUT.PUT_LINE('<table class="dt"><thead><tr>'
                || '<th>Domain</th><th>Metric</th>'
                || '<th class="num">Current</th>'
                || '<th class="num" title="Average of this metric across the prior comparison windows">Prior mean</th>'
                || '<th>Change</th>'
                || '<th class="num" title="(Current &minus; Prior mean) / baseline standard deviation">z-score</th>'
                || '<th class="num" title="Percent change of the current window vs. the prior-window mean: (Current &minus; Prior mean) / |Prior mean| &times; 100">% &Delta;</th>'
                || '</tr></thead><tbody>');
            v_open_table := TRUE;
        END IF;

        DBMS_OUTPUT.PUT_LINE('<tr class="' ||
                CASE f.change_bucket WHEN 'large' THEN 'crit' ELSE 'warn' END || '">'
            || '<td>' || f.metric_domain || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(f.metric_name) || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.cur_val IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.cur_val, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.prior_mean IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.prior_mean, 'FM999G999G999G990D0000') END || '</td>'
            || score_cells_dir(f.change_bucket, f.z_score, f.pct_delta)
            || '</tr>');
        END;
    END LOOP;
    END LOOP;

    IF v_open_table THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    END IF;

    IF v_crit = 0 AND v_warn = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p>No material regression: nothing moved beyond its own floors '
            || 'in the bad direction'
            || CASE WHEN v_improved > 0
                    THEN ' (' || v_improved || ' improved)' ELSE '' END
            || '.</p>');
    ELSIF v_suppressed > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="muted">' || v_suppressed
            || ' further metric' || CASE WHEN v_suppressed = 1 THEN '' ELSE 's' END
            || ' within normal range'
            || CASE WHEN v_improved > 0
                    THEN ' or improved (' || v_improved || ')' ELSE '' END
            || ' (suppressed).</p>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .detail-block

    DBMS_OUTPUT.PUT_LINE('<!-- FLEET-COUNTS findings crit=' || v_crit
        || ' warn=' || v_warn || ' suppressed=' || v_suppressed || ' -->');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_04 END -->'); END;
/
