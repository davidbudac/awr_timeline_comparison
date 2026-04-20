--
-- 07_summary.sql
-- For every scalar metric stored by sections 02-04, compute z-score of the
-- current window against the mean/stddev of the prior valid windows, flag
-- severity, and insert into awr_trend_findings.  Then render a sorted
-- "Findings" table at the top of the report body.  (Because SPOOL is append-
-- only, this block is still emitted last; the CSS already orders the
-- #findings section visually near the top when the page has a flex/grid
-- parent, but we also emit a jump link from the nav bar.)
--

SET DEFINE '~'

--
-- Build the union of metric rows across all three domains.
-- 'LOAD'   : per-sec rate from awr_trend_load_profile
-- 'METRIC' : avg value from awr_trend_sysmetric
-- 'WAIT'   : time waited per second for foreground wait CLASSES
--
INSERT INTO awr_trend_findings (
    run_id, metric_domain, metric_name,
    current_value, prior_mean, prior_sd, n_prior, z_score, pct_delta, severity
)
WITH unified AS (
    SELECT run_id, week_offset, 'LOAD'   AS metric_domain,
           stat_name       AS metric_name,
           per_sec         AS value
    FROM   awr_trend_load_profile
    WHERE  run_id = ~run_id
    AND    per_sec IS NOT NULL
    UNION ALL
    SELECT run_id, week_offset, 'METRIC',
           metric_name, avg_value
    FROM   awr_trend_sysmetric
    WHERE  run_id = ~run_id
    AND    avg_value IS NOT NULL
    UNION ALL
    SELECT w.run_id, w.week_offset, 'WAIT',
           'Wait class: ' || w.wait_class AS metric_name,
           -- per-second time-waited for this class over the window
           w.time_waited_us / NULLIF(
               (CAST(win.win_end_ts AS DATE) - CAST(win.win_start_ts AS DATE)) * 86400 * 1e6, 0)
           AS value
    FROM   awr_trend_waits w
    JOIN   awr_trend_windows win
        ON win.run_id = w.run_id AND win.week_offset = w.week_offset
    WHERE  w.run_id = ~run_id AND w.scope = 'CLASS'
),
pivoted AS (
    SELECT
        run_id, metric_domain, metric_name,
        MAX(CASE WHEN week_offset = 0 THEN value END) AS cur_val,
        AVG(CASE WHEN week_offset > 0 THEN value END) AS mu,
        STDDEV(CASE WHEN week_offset > 0 THEN value END) AS sd,
        COUNT(CASE WHEN week_offset > 0 THEN value END)  AS n
    FROM   unified
    GROUP BY run_id, metric_domain, metric_name
)
SELECT
    run_id, metric_domain, metric_name,
    cur_val,
    mu,
    sd,
    n,
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
        WHEN cur_val IS NULL THEN 'INSUFFICIENT_HISTORY'
        WHEN n < 3           THEN 'INSUFFICIENT_HISTORY'
        WHEN sd IS NULL OR sd = 0 THEN 'FLAT_BASELINE'
        WHEN ABS((cur_val - mu) / sd) > 3 THEN 'CRITICAL'
        WHEN ABS((cur_val - mu) / sd) > 2 THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM   pivoted
WHERE  cur_val IS NOT NULL OR mu IS NOT NULL;

COMMIT;

--
-- Mark the run OK.
--
UPDATE awr_trend_runs SET status = 'OK' WHERE run_id = ~run_id;
COMMIT;

--
-- Render the findings section.  This is emitted AFTER the detail sections
-- in the spool stream, but structurally it's placed inside a <section>
-- element whose id the <nav> at the top links to, so readers see it
-- prominently on scroll-to.  The findings page also prints ranked findings
-- grouped by severity for quick skimming.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_total NUMBER;
    v_crit  NUMBER;
    v_warn  NUMBER;
BEGIN
    SELECT COUNT(*), SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END),
                     SUM(CASE WHEN severity = 'WARN' THEN 1 ELSE 0 END)
    INTO   v_total, v_crit, v_warn
    FROM   awr_trend_findings WHERE run_id = ~run_id;

    DBMS_OUTPUT.PUT_LINE('<section id="findings"><h2>Findings summary &mdash; ' ||
        '<span class="badge crit">' || NVL(v_crit, 0) || ' critical</span> '  ||
        '<span class="badge warn">' || NVL(v_warn, 0) || ' warn</span> '      ||
        '<span class="badge ok">'   || v_total        || ' total</span></h2>');

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'z-score of the current window vs prior valid windows. '
        || '|z|&gt;3 = CRITICAL, |z|&gt;2 = WARN. '
        || 'INSUFFICIENT_HISTORY (n&lt;3) shows only %-delta.</p>');

    DBMS_OUTPUT.PUT_LINE('<table>'
        || '<thead><tr>'
        || '<th>Severity</th>'
        || '<th>Domain</th>'
        || '<th>Metric</th>'
        || '<th class="num">Current</th>'
        || '<th class="num">Prior mean</th>'
        || '<th class="num">Prior sd</th>'
        || '<th class="num">n</th>'
        || '<th class="num">z-score</th>'
        || '<th class="num">% &Delta;</th>'
        || '</tr></thead><tbody>');

    FOR f IN (
        SELECT f.*,
               CASE severity
                   WHEN 'CRITICAL'             THEN 1
                   WHEN 'WARN'                 THEN 2
                   WHEN 'INSUFFICIENT_HISTORY' THEN 3
                   WHEN 'FLAT_BASELINE'        THEN 4
                   ELSE 5
               END AS sev_order
        FROM   awr_trend_findings f
        WHERE  f.run_id = ~run_id
        ORDER BY sev_order,
                 ABS(NVL(z_score, 0)) DESC,
                 ABS(NVL(pct_delta, 0)) DESC,
                 metric_name
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(
            '<tr class="' || CASE f.severity
                    WHEN 'CRITICAL' THEN 'crit'
                    WHEN 'WARN'     THEN 'warn'
                    WHEN 'OK'       THEN 'ok'
                    ELSE 'skip' END || '">'
            || '<td><span class="badge ' || CASE f.severity
                    WHEN 'CRITICAL' THEN 'crit'
                    WHEN 'WARN'     THEN 'warn'
                    WHEN 'OK'       THEN 'ok'
                    ELSE 'skip' END || '">' || f.severity || '</span></td>'
            || '<td>' || f.metric_domain || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(f.metric_name) || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.current_value IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.current_value, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.prior_mean IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.prior_mean, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.prior_sd IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.prior_sd, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' || NVL(TO_CHAR(f.n_prior), '0') || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.z_score IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.z_score, 'FMS990D00') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.pct_delta IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.pct_delta, 'FMS990D0') || '%' END || '</td>'
            || '</tr>');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'All raw facts are persisted in the scratch schema '
        || '(AWR_TREND_RUNS / _WINDOWS / _LOAD_PROFILE / _SYSMETRIC / _WAITS / _TOP_SQL / _FINDINGS) '
        || 'keyed by run_id = ' || ~run_id || '. Query them for deeper analysis.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
