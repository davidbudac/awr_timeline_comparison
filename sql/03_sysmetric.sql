--
-- 03_sysmetric.sql
-- Per-window averages from DBA_HIST_SYSMETRIC_SUMMARY.  This view already
-- holds per-snapshot aggregates of the V$SYSMETRIC_* time series, so we
-- just AVG(average) over the snapshots that fall inside each window.
--

SET DEFINE '~'

INSERT INTO awr_trend_sysmetric (run_id, week_offset, metric_name, metric_unit, avg_value, max_value)
WITH run AS (
    SELECT run_id, dbid, instance_number
    FROM   awr_trend_runs
    WHERE  run_id = ~run_id
),
wins AS (
    SELECT w.run_id, w.week_offset, w.begin_snap_id, w.end_snap_id
    FROM   awr_trend_windows w
    WHERE  w.run_id = ~run_id
    AND    w.valid_flag = 'Y'
),
targets AS (
    -- Curated, high-signal subset of SYSMETRIC metrics.
    SELECT metric_name FROM (
        SELECT 'Host CPU Utilization (%)'                 metric_name FROM dual UNION ALL
        SELECT 'Database CPU Time Ratio'                              FROM dual UNION ALL
        SELECT 'Database Wait Time Ratio'                             FROM dual UNION ALL
        SELECT 'Average Active Sessions'                              FROM dual UNION ALL
        SELECT 'Average Synchronous Single-Block Read Latency'        FROM dual UNION ALL
        SELECT 'Physical Reads Per Sec'                               FROM dual UNION ALL
        SELECT 'Physical Writes Per Sec'                              FROM dual UNION ALL
        SELECT 'Physical Read Total IO Requests Per Sec'              FROM dual UNION ALL
        SELECT 'Physical Write Total IO Requests Per Sec'             FROM dual UNION ALL
        SELECT 'Physical Read Total Bytes Per Sec'                    FROM dual UNION ALL
        SELECT 'Physical Write Total Bytes Per Sec'                   FROM dual UNION ALL
        SELECT 'Redo Generated Per Sec'                               FROM dual UNION ALL
        SELECT 'Logons Per Sec'                                       FROM dual UNION ALL
        SELECT 'Logical Reads Per Sec'                                FROM dual UNION ALL
        SELECT 'User Calls Per Sec'                                   FROM dual UNION ALL
        SELECT 'User Commits Per Sec'                                 FROM dual UNION ALL
        SELECT 'User Rollbacks Per Sec'                               FROM dual UNION ALL
        SELECT 'Executions Per Sec'                                   FROM dual UNION ALL
        SELECT 'Hard Parse Count Per Sec'                             FROM dual UNION ALL
        SELECT 'Total Parse Count Per Sec'                            FROM dual UNION ALL
        SELECT 'Session Count'                                        FROM dual UNION ALL
        SELECT 'Network Traffic Volume Per Sec'                       FROM dual UNION ALL
        SELECT 'SQL Service Response Time'                            FROM dual
    )
)
SELECT
    w.run_id,
    w.week_offset,
    sm.metric_name,
    MAX(sm.metric_unit) AS metric_unit,
    AVG(sm.average)     AS avg_value,
    MAX(sm.maxval)      AS max_value
FROM   wins w
CROSS JOIN targets t
JOIN   run r ON 1=1
JOIN   dba_hist_sysmetric_summary sm
    ON sm.dbid = r.dbid
   AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
   AND (r.instance_number IS NULL OR sm.instance_number = r.instance_number)
   AND sm.metric_name = t.metric_name
GROUP BY w.run_id, w.week_offset, sm.metric_name;

COMMIT;

--
-- Render pivot: metric x week.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back  NUMBER;
    v_header      VARCHAR2(4000);
    v_row         VARCHAR2(32767);
    v_val         NUMBER;
    v_fmt         VARCHAR2(40);
    v_points      VARCHAR2(4000);
    v_token       VARCHAR2(80);
    TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_vals        t_num_tab;
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = ~run_id;

    DBMS_OUTPUT.PUT_LINE('<section id="metrics"><h2>System metrics (DBA_HIST_SYSMETRIC_SUMMARY)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">Averages over the snapshots inside each window. Values are already per-second where the metric name says so.</p>');

    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th>Trend</th><th class="num">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR m IN (
        SELECT metric_name,
               MAX(metric_unit) AS metric_unit,
               MAX(CASE WHEN week_offset = 0 THEN avg_value END) AS cur_val
        FROM   awr_trend_sysmetric
        WHERE  run_id = ~run_id
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
        v_fmt := 'FM999G999G999G990D00';
        v_vals.DELETE;
        v_points := NULL;

        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(avg_value)
            INTO   v_vals(k)
            FROM   awr_trend_sysmetric
            WHERE  run_id = ~run_id
            AND    metric_name = m.metric_name
            AND    week_offset = k;

            v_token := CASE
                WHEN v_vals(k) IS NULL THEN 'null'
                ELSE TO_CHAR(v_vals(k), 'FM99999999999999999990D999999',
                    'NLS_NUMERIC_CHARACTERS=''.,''')
            END;

            IF v_points IS NULL THEN
                v_points := v_token;
            ELSE
                v_points := v_token || '|' || v_points;
            END IF;
        END LOOP;

        v_token := CASE
            WHEN m.cur_val IS NULL THEN 'null'
            ELSE TO_CHAR(m.cur_val, 'FM99999999999999999990D999999',
                'NLS_NUMERIC_CHARACTERS=''.,''')
        END;
        IF v_points IS NULL THEN
            v_points := v_token;
        ELSE
            v_points := v_points || '|' || v_token;
        END IF;

        v_row := '<tr><td>' || DBMS_XMLGEN.CONVERT(m.metric_name) || '</td>'
              || '<td>' || DBMS_XMLGEN.CONVERT(NVL(m.metric_unit, '')) || '</td>'
              || '<td class="trend-cell"><span class="sparkline" data-points="' || v_points || '"></span></td>'
              || '<td class="num"><b>' ||
                 CASE WHEN m.cur_val IS NULL THEN '&mdash;'
                      ELSE TO_CHAR(m.cur_val, v_fmt) END || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val := v_vals(k);

            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_val IS NULL THEN '&mdash;' ELSE TO_CHAR(v_val, v_fmt) END
                || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
