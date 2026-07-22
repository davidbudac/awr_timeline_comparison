--
-- sql/fleet/04_findings.sql
-- "Findings" detail-block for the detail panel's right column: the unified
-- LOAD/METRIC/WAIT z-score compute is UNCHANGED from the old 03_findings.sql
-- (same CTE chain as sql/07_summary.sql: windows_cte -> load/metric/wait
-- pairs -> bounds -> deltas -> unified -> pivoted -> scored, using the FLEET
-- template's curated target lists via ~template_dir).  Emission differs only
-- in wrapping: the table is now class="dt" inside a .detail-block/.panel-h,
-- and only rows the recompute buckets 'large'/'moderate' are printed; the
-- rest are counted and summarized in one muted line.
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
    v_suppressed PLS_INTEGER := 0;
    v_open_table BOOLEAN := FALSE;

    @@sql/lib/score_cells.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<div class="detail-block">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h">Findings (z &ge; 2&sigma;)</div>');

    FOR f IN (
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
        scored AS (
            SELECT metric_domain, metric_name,
                   cur_val,
                   mu       AS prior_mean,
                   sd       AS prior_sd,
                   n        AS n_prior,
                   CASE
                       WHEN cur_val IS NULL OR mu IS NULL THEN NULL
                       WHEN sd IS NULL OR sd = 0 THEN NULL
                       ELSE (cur_val - mu) / sd
                   END AS z_score,
                   CASE
                       WHEN cur_val IS NULL OR mu IS NULL OR mu = 0 THEN NULL
                       ELSE (cur_val - mu) / ABS(mu) * 100
                   END AS pct_delta,
                   CASE
                       WHEN cur_val IS NULL THEN 'n/a'
                       WHEN n < 3           THEN 'insufficient history'
                       WHEN sd IS NULL OR sd = 0 THEN 'flat baseline'
                       WHEN ABS((cur_val - mu) / sd) > 3 THEN 'large'
                       WHEN ABS((cur_val - mu) / sd) > 2 THEN 'moderate'
                       ELSE 'typical'
                   END AS change_bucket
            FROM   pivoted
            WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
        )
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket
        FROM   scored
        ORDER BY CASE change_bucket
                     WHEN 'large'                THEN 1
                     WHEN 'moderate'             THEN 2
                     WHEN 'insufficient history' THEN 3
                     WHEN 'n/a'                  THEN 3
                     WHEN 'flat baseline'        THEN 4
                     ELSE 5
                 END,
                 ABS(NVL(z_score, 0)) DESC,
                 ABS(NVL(pct_delta, 0)) DESC,
                 metric_name
    ) LOOP
        IF f.change_bucket NOT IN ('large', 'moderate') THEN
            v_suppressed := v_suppressed + 1;
            CONTINUE;
        END IF;
        IF f.change_bucket = 'large' THEN
            v_crit := v_crit + 1;
        ELSE
            v_warn := v_warn + 1;
        END IF;

        IF NOT v_open_table THEN
            DBMS_OUTPUT.PUT_LINE('<table class="dt"><thead><tr>'
                || '<th>Domain</th><th>Metric</th>'
                || '<th class="num">Current</th><th class="num">Prior mean</th>'
                || '<th>Change</th><th class="num">z-score</th><th class="num">% &Delta;</th>'
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
            || score_cells(f.cur_val, f.prior_mean, f.prior_sd, f.n_prior)
            || '</tr>');
    END LOOP;

    IF v_open_table THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    END IF;

    IF v_crit = 0 AND v_warn = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p>No metric moved beyond 2&sigma; of its prior baseline.</p>');
    ELSIF v_suppressed > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="muted">' || v_suppressed
            || ' further metric' || CASE WHEN v_suppressed = 1 THEN '' ELSE 's' END
            || ' within normal range (suppressed).</p>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .detail-block

    DBMS_OUTPUT.PUT_LINE('<!-- FLEET-COUNTS findings crit=' || v_crit
        || ' warn=' || v_warn || ' suppressed=' || v_suppressed || ' -->');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_04 END -->'); END;
/
