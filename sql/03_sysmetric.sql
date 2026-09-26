--
-- 03_sysmetric.sql
-- Per-window averages from DBA_HIST_SYSMETRIC_SUMMARY.  This view already
-- holds per-snapshot aggregates of the V$SYSMETRIC_* time series, so we
-- just AVG(average) over the snapshots that fall inside each window.
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 03_sysmetric BEGIN -->'); END;
/

DECLARE
    v_weeks_back  NUMBER := ~weeks_back;
    v_header      VARCHAR2(4000);
    v_row         VARCHAR2(32767);
    v_val         NUMBER;
    v_val_s       VARCHAR2(64);
    v_row_max     NUMBER;
    v_pct         NUMBER;
    v_rows        PLS_INTEGER := 0;
    v_bucket      VARCHAR2(40);
    v_host        NUMBER;

    -- Subprogram includes go LAST, metric_policy first (lint 14 / 16),
    -- fmt_num before band_glyph (lint 17).
    @@sql/lib/metric_policy.plsql
    @@sql/lib/nth_csv.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="metrics" class="vw in-s in-a lib" style="--os:8"><h2>System metrics'
        || '<small class="h2sub">SYSMETRIC averages per window, Current against its normal range</small></h2>');

    v_rows := 0;
    -- v1.6.0: Current, the baseline band (same policy bucket as 07), trend,
    -- then the prior windows as plain values.
    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th class="num" data-w="0">Current</th>'
        || band_head || '<th class="trend">Trend</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num" data-w="' || k || '">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table id="sysmetric">' || v_header || '<tbody>');

    FOR m IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        targets AS (
            @@~template_dir/sysmetric_targets.sql
        ),
        -- Per-snap cluster value: SUM across instances for additive
        -- metrics (rates/counters), AVG across instances for ratios
        -- and latencies. On single-instance these are identical.
        per_snap AS (
            SELECT w.week_offset, t.metric_name, sm.snap_id,
                   t.is_additive,
                   MAX(sm.metric_unit) AS metric_unit,
                   CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                                 ELSE AVG(sm.average) END AS snap_value
            FROM   valid_windows w
            CROSS JOIN targets t
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND sm.instance_number = w.instance_number
               AND sm.metric_name = t.metric_name
            GROUP BY w.week_offset, t.metric_name, t.is_additive, sm.snap_id
        ),
        facts AS (
            SELECT week_offset, metric_name,
                   MAX(metric_unit) AS metric_unit,
                   AVG(snap_value)  AS avg_value
            FROM   per_snap
            GROUP BY week_offset, metric_name
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT t.metric_name, w.week_offset, f.avg_value, f.metric_unit
            FROM   targets t
            CROSS JOIN all_weeks w
            LEFT JOIN facts f
                   ON f.metric_name = t.metric_name
                  AND f.week_offset = w.week_offset
        )
        SELECT metric_name,
               MAX(metric_unit) AS metric_unit,
               MAX(CASE WHEN week_offset = 0 THEN avg_value END) AS cur_val,
               MAX(avg_value) AS row_max,
               AVG(CASE WHEN week_offset > 0 THEN avg_value END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN avg_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN avg_value END)  AS n_prior,
               -- ','||token + SUBSTR: LISTAGG drops NULL measures (and their
               -- delimiter), which would left-compact the CSV and misalign
               -- the positional slots; ','||NULL = ',' keeps the empty slot.
               SUBSTR(LISTAGG(',' || TO_CHAR(avg_value, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_vals,
               SUBSTR(LISTAGG(',' || TO_CHAR(avg_value, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals
        FROM   grid
        GROUP BY metric_name
        ORDER BY CASE metric_name
            WHEN 'Average Active Sessions'                       THEN 1
            WHEN 'Host CPU Utilization (%)'                      THEN 2
            WHEN 'Database CPU Time Ratio'                       THEN 3
            WHEN 'Database Wait Time Ratio'                      THEN 4
            WHEN 'Session Count'                                 THEN 5
            WHEN 'Redo Generated Per Sec'                        THEN 6
            WHEN 'Physical Read Total Bytes Per Sec'             THEN 7
            WHEN 'Physical Write Total Bytes Per Sec'            THEN 8
            WHEN 'Physical Read Total IO Requests Per Sec'       THEN 9
            WHEN 'Physical Write Total IO Requests Per Sec'      THEN 10
            WHEN 'Average Synchronous Single-Block Read Latency' THEN 11
            WHEN 'Logical Reads Per Sec'                         THEN 12
            WHEN 'Executions Per Sec'                            THEN 13
            WHEN 'User Calls Per Sec'                            THEN 14
            WHEN 'User Commits Per Sec'                          THEN 15
            WHEN 'User Rollbacks Per Sec'                        THEN 16
            WHEN 'Hard Parse Count Per Sec'                      THEN 17
            WHEN 'Total Parse Count Per Sec'                     THEN 18
            WHEN 'Logons Per Sec'                                THEN 19
            WHEN 'Network Traffic Volume Per Sec'                THEN 20
            WHEN 'SQL Service Response Time'                     THEN 21
            ELSE 99 END,
            metric_name
    ) LOOP
        v_rows := v_rows + 1;
        IF m.metric_name = 'Host CPU Utilization (%)' THEN v_host := m.cur_val; END IF;
        v_row_max := NVL(m.row_max, 0);

        IF v_row_max > 0 AND m.cur_val IS NOT NULL THEN
            v_pct := LEAST(100, ABS(m.cur_val) / v_row_max * 100);
        ELSE
            v_pct := 0;
        END IF;

        v_row := '<tr id="' || anchor_id('metric', m.metric_name)
              || '" data-imp="' || is_essential('METRIC', m.metric_name)
              || '"><td>' || DBMS_XMLGEN.CONVERT(m.metric_name) || '</td>'
              || '<td>' || DBMS_XMLGEN.CONVERT(NVL(m.metric_unit, '')) || '</td>'
              || '<td class="num cell-bar" data-w="0"' || fmt_num_title(m.cur_val) || '>'
              || '<span class="bg" style="width:' || TO_CHAR(v_pct, 'FM990D0') || '%"></span>'
              || '<span class="v"><b>' || fmt_num(m.cur_val) || '</b></span></td>';
        v_bucket := policy_bucket('METRIC', m.metric_name, NULL, m.cur_val, m.mu, m.sd, m.n_prior);
        v_row := v_row || band_cells(m.cur_val, m.mu, m.sd, m.n_prior, v_bucket)
              || '<td class="trend" data-spark="' || NVL(m.spark_vals, '')
              || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(m.metric_name) || '"></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(m.week_vals, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num" data-w="' || k || '">&mdash;</td>';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num" data-w="' || k || '">'
                      || fmt_num(v_val) || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    IF v_rows = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<tr class="skip"><td colspan="' || (v_weeks_back + 8) || '">'
            || 'No system metrics in DBA_HIST_SYSMETRIC_SUMMARY for the compared windows.'
            || ' Try a wider <code>win_hours</code>, more <code>weeks_back</code>, or a busier <code>target_end</code>.</td></tr>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    -- the evidence library's row text (Summary view)
    DBMS_OUTPUT.PUT_LINE(lib_ls('metrics', v_rows || ' metric' || CASE WHEN v_rows = 1 THEN '' ELSE 's' END
        || CASE WHEN v_host IS NOT NULL THEN '; host CPU <b>' || fmt_num(v_host) || '%</b>' END)
        || '</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 03_sysmetric END -->'); END;
/
