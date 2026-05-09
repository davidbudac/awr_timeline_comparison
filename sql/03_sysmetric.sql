--
-- 03_sysmetric.sql
-- Per-window averages from DBA_HIST_SYSMETRIC_SUMMARY.  This view already
-- holds per-snapshot aggregates of the V$SYSMETRIC_* time series, so we
-- just AVG(average) over the snapshots that fall inside each window.
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back  NUMBER := ~weeks_back;
    v_header      VARCHAR2(4000);
    v_row         VARCHAR2(32767);
    v_val         NUMBER;
    v_val_s       VARCHAR2(64);
    v_fmt         VARCHAR2(40);
    v_row_max     NUMBER;
    v_pct         NUMBER;

    FUNCTION nth_csv(p_str VARCHAR2, p_n POSITIVE) RETURN VARCHAR2 IS
        v_start PLS_INTEGER := 1;
        v_end   PLS_INTEGER;
        v_cnt   PLS_INTEGER := 0;
    BEGIN
        IF p_str IS NULL OR p_n IS NULL OR p_n < 1 THEN
            RETURN NULL;
        END IF;
        LOOP
            v_end := INSTR(p_str, ',', v_start);
            v_cnt := v_cnt + 1;
            IF v_cnt = p_n THEN
                IF v_end = 0 THEN
                    RETURN SUBSTR(p_str, v_start);
                ELSE
                    RETURN SUBSTR(p_str, v_start, v_end - v_start);
                END IF;
            END IF;
            EXIT WHEN v_end = 0;
            v_start := v_end + 1;
        END LOOP;
        RETURN NULL;
    END nth_csv;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="metrics"><h2>System metrics (DBA_HIST_SYSMETRIC_SUMMARY)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">Averages over the snapshots inside each window. The <b>Trend</b> column plots the per-~period_unit_long series (oldest &rarr; current). Values are already per-second where the metric name says so.</p>');

    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th class="trend">Trend</th><th class="num">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || '~period_unit_short</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR m IN (
        WITH run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours,
                   ~weeks_back AS weeks_back
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset
            FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        raw_windows AS (
            SELECT r.dbid, r.instance_number, o.week_offset,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset - r.win_hours/24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset                   AS win_end_dt
            FROM run_params r CROSS JOIN offsets o
        ),
        snaps AS (
            SELECT w.week_offset, w.win_start_dt, w.win_end_dt, w.instance_number, w.dbid,
                   s.snap_id, s.end_interval_time, s.startup_time
            FROM   raw_windows w
            JOIN   dba_hist_snapshot s
              ON   s.dbid = w.dbid
             AND   (w.instance_number IS NULL OR s.instance_number = w.instance_number)
             AND   s.end_interval_time BETWEEN
                        CAST(w.win_start_dt - 1 AS TIMESTAMP)
                    AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
        ),
        begin_snap AS (
            SELECT week_offset,
                   MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS snap_id,
                   MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
            GROUP BY week_offset
        ),
        end_snap AS (
            SELECT week_offset,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
            GROUP BY week_offset
        ),
        windows AS (
            SELECT
                w.week_offset, w.dbid, w.instance_number,
                bs.snap_id AS begin_snap_id,
                es.snap_id AS end_snap_id,
                CASE
                    WHEN bs.snap_id IS NULL OR es.snap_id IS NULL THEN 'N'
                    WHEN bs.snap_id = es.snap_id                  THEN 'N'
                    WHEN bs.startup_time <> es.startup_time       THEN 'N'
                    ELSE 'Y'
                END AS valid_flag
            FROM   raw_windows w
            LEFT JOIN begin_snap bs ON bs.week_offset = w.week_offset
            LEFT JOIN end_snap   es ON es.week_offset = w.week_offset
        ),
        valid_windows AS (
            SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
            FROM   windows WHERE valid_flag = 'Y'
        ),
        targets AS (
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
        ),
        facts AS (
            SELECT w.week_offset, sm.metric_name,
                   MAX(sm.metric_unit) AS metric_unit,
                   AVG(sm.average)     AS avg_value
            FROM   valid_windows w
            CROSS JOIN targets t
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR sm.instance_number = w.instance_number)
               AND sm.metric_name = t.metric_name
            GROUP BY w.week_offset, sm.metric_name
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
               LISTAGG(CASE WHEN avg_value IS NULL THEN ''
                            ELSE TO_CHAR(avg_value, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS spark_vals,
               LISTAGG(CASE WHEN avg_value IS NULL THEN ''
                            ELSE TO_CHAR(avg_value, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals
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
        v_row_max := NVL(m.row_max, 0);
        v_fmt := CASE
            WHEN v_row_max = 0 OR v_row_max >= 1   THEN 'FM999G999G999G990D00'
            WHEN v_row_max >= 0.01                  THEN 'FM990D0000'
            WHEN v_row_max >= 0.0001                THEN 'FM990D000000'
            ELSE                                         'FM0D00EEEE'
        END;

        IF v_row_max > 0 AND m.cur_val IS NOT NULL THEN
            v_pct := LEAST(100, ABS(m.cur_val) / v_row_max * 100);
        ELSE
            v_pct := 0;
        END IF;

        v_row := '<tr><td>' || DBMS_XMLGEN.CONVERT(m.metric_name) || '</td>'
              || '<td>' || DBMS_XMLGEN.CONVERT(NVL(m.metric_unit, '')) || '</td>'
              || '<td class="trend" data-spark="' || NVL(m.spark_vals, '')
              || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(m.metric_name) || '"></td>'
              || '<td class="num cell-bar">'
              || '<span class="bg" style="width:' || TO_CHAR(v_pct, 'FM990D0') || '%"></span>'
              || '<span class="v"><b>' ||
                 CASE WHEN m.cur_val IS NULL THEN '&mdash;'
                      ELSE TO_CHAR(m.cur_val, v_fmt) END || '</b></span></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(m.week_vals, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;</td>';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_val, v_fmt) || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
