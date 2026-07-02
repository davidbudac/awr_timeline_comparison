--
-- 13_utilization.sql
-- Database utilization profile: how the applications USE this database --
-- transaction / call / logon rates, session counts, data and network
-- volume.  Deliberately descriptive, not diagnostic: nothing here is
-- scored or severity-tinted; the section exists so a reader can see the
-- workload shape at a glance (and how it drifts window-over-window)
-- without implying a performance problem.
--
-- Sourced from DBA_HIST_SYSMETRIC_SUMMARY, same per-window AVG(average)
-- math as section 03.  The metric list is fixed and template-independent
-- ON PURPOSE: the usage overview should look the same no matter which
-- triage template the caller picked, so the targets live inline here
-- rather than under sql/lib/templates/.  Every metric in the list is a
-- rate or a count, hence additive across RAC instances (SUM per snap,
-- then AVG across snaps -- a no-op on single-instance).
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 13_utilization BEGIN -->'); END;
/

DECLARE
    v_weeks_back  NUMBER := ~weeks_back;
    v_header      VARCHAR2(4000);
    v_row         VARCHAR2(32767);
    v_val         NUMBER;
    v_val_s       VARCHAR2(64);
    v_fmt         VARCHAR2(40);
    v_row_max     NUMBER;
    v_pct         NUMBER;
    v_last_grp    NUMBER := -1;

    @@sql/lib/nth_csv.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="utilization"><h2>Database utilization '
        || '&mdash; how the applications use this DB</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Workload volume and shape only &mdash; transaction, call and logon rates, '
        || 'session counts, data and network volume (DBA_HIST_SYSMETRIC_SUMMARY, '
        || 'AVG over each window). This is a <b>usage</b> overview, not a health check: '
        || 'movement here usually reflects application behaviour (releases, batch '
        || 'schedules, user load), not database trouble. '
        || '<b>Trend</b>: per-window values, oldest &rarr; current.</p>');

    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th class="trend">Trend</th><th class="num">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';

    FOR m IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- Fixed, template-independent target list.  grp_ord/grp_label
        -- drive the h3 sub-sections; met_ord fixes the row order inside
        -- each group; disp_label is the reader-facing name (the raw
        -- SYSMETRIC name still shows in the tooltip + Unit column).
        targets AS (
            SELECT 1 AS grp_ord, 'Transactions and SQL activity' AS grp_label, 1 AS met_ord,
                   'User Transaction Per Sec'       AS metric_name, 'Transactions / s'    AS disp_label FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 2, 'User Commits Per Sec'          , 'Commits / s'          FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 3, 'User Rollbacks Per Sec'        , 'Rollbacks / s'        FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 4, 'Executions Per Sec'            , 'SQL executions / s'   FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 5, 'User Calls Per Sec'            , 'User calls / s'       FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 6, 'Total Parse Count Per Sec'     , 'Parses (total) / s'   FROM dual UNION ALL
            SELECT 1, 'Transactions and SQL activity', 7, 'Open Cursors Per Sec'          , 'Cursors opened / s'   FROM dual UNION ALL
            SELECT 2, 'Connections and sessions'     , 1, 'Logons Per Sec'                , 'Logons / s'           FROM dual UNION ALL
            SELECT 2, 'Connections and sessions'     , 2, 'Session Count'                 , 'Sessions'             FROM dual UNION ALL
            SELECT 2, 'Connections and sessions'     , 3, 'Current Logons Count'          , 'Logged-on users'      FROM dual UNION ALL
            SELECT 2, 'Connections and sessions'     , 4, 'Current Open Cursors Count'    , 'Open cursors'         FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 1, 'Logical Reads Per Sec'         , 'Logical reads / s'    FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 2, 'Physical Reads Per Sec'        , 'Physical reads / s'   FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 3, 'Physical Writes Per Sec'       , 'Physical writes / s'  FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 4, 'DB Block Changes Per Sec'      , 'Block changes / s'    FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 5, 'Redo Generated Per Sec'        , 'Redo bytes / s'       FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 6, 'I/O Megabytes per Second'      , 'I/O MB / s'           FROM dual UNION ALL
            SELECT 3, 'Data and network volume'      , 7, 'Network Traffic Volume Per Sec', 'Network bytes / s'    FROM dual
        ),
        -- Every metric here is a rate or count: additive across RAC
        -- instances, so the per-snap cluster value is SUM(average).
        per_snap AS (
            SELECT w.week_offset, t.metric_name, sm.snap_id,
                   MAX(sm.metric_unit) AS metric_unit,
                   SUM(sm.average)     AS snap_value
            FROM   valid_windows w
            CROSS JOIN targets t
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND sm.instance_number = w.instance_number
               AND sm.metric_name = t.metric_name
            GROUP BY w.week_offset, t.metric_name, sm.snap_id
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
            SELECT t.grp_ord, t.grp_label, t.met_ord, t.metric_name, t.disp_label,
                   w.week_offset, f.avg_value, f.metric_unit
            FROM   targets t
            CROSS JOIN all_weeks w
            LEFT JOIN facts f
                   ON f.metric_name = t.metric_name
                  AND f.week_offset = w.week_offset
        )
        SELECT grp_ord, grp_label, met_ord, metric_name, disp_label,
               MAX(metric_unit) AS metric_unit,
               MAX(CASE WHEN week_offset = 0 THEN avg_value END) AS cur_val,
               MAX(avg_value) AS row_max,
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
        GROUP BY grp_ord, grp_label, met_ord, metric_name, disp_label
        ORDER BY grp_ord, met_ord
    ) LOOP
        -- New sub-section: close the previous table, open h3 + table.
        IF m.grp_ord <> v_last_grp THEN
            IF v_last_grp <> -1 THEN
                DBMS_OUTPUT.PUT_LINE('</tbody></table>');
            END IF;
            DBMS_OUTPUT.PUT_LINE('<h3>' || DBMS_XMLGEN.CONVERT(m.grp_label) || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
            v_last_grp := m.grp_ord;
        END IF;

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

        v_row := '<tr><td><span title="'
              || DBMS_XMLGEN.CONVERT(m.metric_name) || '">'
              || DBMS_XMLGEN.CONVERT(m.disp_label) || '</span></td>'
              || '<td>' || DBMS_XMLGEN.CONVERT(NVL(m.metric_unit, '')) || '</td>'
              || '<td class="trend" data-spark="' || NVL(m.spark_vals, '')
              || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(m.disp_label) || '"></td>'
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

    IF v_last_grp <> -1 THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 13_utilization END -->'); END;
/
