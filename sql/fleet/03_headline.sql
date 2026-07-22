--
-- sql/fleet/03_headline.sql
-- Compact headline-metric mini-cards for the detail panel's left column,
-- adapted from sql/08_overview.sql's cards CTE (unchanged from the old
-- 02_headline.sql): same shared-windows x LOAD/METRIC single-pass cursor,
-- same six metrics (DB time / redo size / logical reads / AAS / Wait Time
-- Ratio / hard parses -- the FLEET template's target lists are seeded so all
-- six source names always resolve, never falling back to "n/a").
--
-- Render is the ops-console .metric card: label, current value + unit, a
-- z-bucket badge, and a CDN-free per-window sparkline (data-spark, rendered
-- by js_sparkline).  This section also CLOSES the detail row's left column
-- (opened by 01_row.sql) and OPENS the right column that 04/05/06 fill.
--
-- Read-only: recomputes everything in-flight from the AWR views.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_03 BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h" style="margin-top:14px">Headline metrics vs '
        || '~weeks_back' || '-window baseline</div>');
    DBMS_OUTPUT.PUT_LINE('<div class="metrics">');

    FOR c IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        cards AS (
            SELECT 1 AS pos, 'DB time'                AS label, 'cs/s' AS unit,
                   'LOAD'   AS src, 'DB time'                 AS key, 'Y' AS is_add FROM dual UNION ALL
            SELECT 2, 'Redo generated',        'B/s',
                   'LOAD',   'redo size'                             , 'Y'           FROM dual UNION ALL
            SELECT 3, 'Logical reads',         '/s',
                   'LOAD',   'session logical reads'                 , 'Y'           FROM dual UNION ALL
            SELECT 4, 'Average Active Sessions','AAS',
                   'METRIC', 'Average Active Sessions'               , 'Y'           FROM dual UNION ALL
            SELECT 5, 'Wait Time Ratio',       '%',
                   'METRIC', 'Database Wait Time Ratio'              , 'N'           FROM dual UNION ALL
            SELECT 6, 'Hard parses',           '/s',
                   'LOAD',   'parse count (hard)'                    , 'Y'           FROM dual
        ),
        load_pairs AS (
            SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                   ss.snap_id, ss.value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND ss.instance_number = w.instance_number
               AND ss.stat_name IN (SELECT key FROM cards WHERE src = 'LOAD')
        ),
        load_bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   load_pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        load_rows AS (
            SELECT 'LOAD' AS src, stat_name AS key, week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END AS val
            FROM   load_bounds
            GROUP BY week_offset, stat_name
        ),
        metric_per_snap AS (
            SELECT w.week_offset, c.key AS metric_name, sm.snap_id, c.is_add,
                   CASE WHEN c.is_add = 'Y' THEN SUM(sm.average)
                                            ELSE AVG(sm.average) END AS snap_value
            FROM   valid_windows w
            JOIN   cards c ON c.src = 'METRIC'
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND sm.instance_number = w.instance_number
               AND sm.metric_name = c.key
            GROUP BY w.week_offset, c.key, c.is_add, sm.snap_id
        ),
        metric_rows AS (
            SELECT 'METRIC' AS src, metric_name AS key, week_offset,
                   AVG(snap_value) AS val
            FROM   metric_per_snap
            GROUP BY week_offset, metric_name
        ),
        all_rows AS (
            SELECT * FROM load_rows   UNION ALL
            SELECT * FROM metric_rows
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT c.pos, c.label, c.unit, c.src, c.key,
                   w.week_offset, r.val
            FROM   cards c
            CROSS JOIN all_weeks w
            LEFT JOIN all_rows r
                   ON r.src = c.src AND r.key = c.key AND r.week_offset = w.week_offset
        )
        SELECT pos, label, unit,
               MAX(CASE WHEN week_offset = 0 THEN val END) AS cur,
               AVG(CASE WHEN week_offset > 0 THEN val END) AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN val END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN val END) AS n,
               SUBSTR(LISTAGG(',' || TO_CHAR(val, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS vals_csv
        FROM   grid
        GROUP BY pos, label, unit
        ORDER BY pos
    ) LOOP
        DECLARE
            v_z      NUMBER;
            v_sev    VARCHAR2(40);
            v_mz_cls VARCHAR2(4);
            v_mz_txt VARCHAR2(40);
        BEGIN
            v_z := CASE
                WHEN c.cur IS NULL OR c.mu IS NULL THEN NULL
                WHEN c.sd IS NULL OR c.sd = 0       THEN NULL
                ELSE (c.cur - c.mu) / c.sd
            END;
            v_sev := CASE
                WHEN c.cur IS NULL THEN NULL
                WHEN c.n < 3 THEN 'insufficient history'
                WHEN c.sd IS NULL OR c.sd = 0 THEN 'flat baseline'
                WHEN ABS(v_z) > 3 THEN 'large'
                WHEN ABS(v_z) > 2 THEN 'moderate'
                ELSE 'typical'
            END;
            v_mz_cls := CASE v_sev
                WHEN 'large'    THEN 'c'
                WHEN 'moderate' THEN 'w'
                WHEN 'typical'  THEN 'o'
                ELSE 'n' END;
            v_mz_txt := CASE
                WHEN v_z IS NOT NULL THEN TO_CHAR(v_z, 'FMS9990D0') || '&sigma;'
                WHEN c.cur IS NULL   THEN 'n/a'
                ELSE 'n/a' END;

            DBMS_OUTPUT.PUT_LINE('<div class="metric">');
            DBMS_OUTPUT.PUT_LINE('  <div class="ml">' || c.label || '</div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="mrow"><div class="mv">'
                || CASE WHEN c.cur IS NULL THEN '&mdash;'
                        ELSE TO_CHAR(c.cur, 'FM999G999G990D00') END
                || '<span class="mu">' || c.unit || '</span></div>'
                || '<div class="mz ' || v_mz_cls || '">' || v_mz_txt || '</div></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="mspark"><span class="trend" data-spark="'
                || NVL(c.vals_csv, '') || '" data-spark-title="' || c.label || '"></span></div>');
            DBMS_OUTPUT.PUT_LINE('</div>');
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .metrics
    DBMS_OUTPUT.PUT_LINE('</div>');  -- .detail-col-left (opened in 01_row.sql)
    DBMS_OUTPUT.PUT_LINE('<div class="detail-col-right">');  -- filled by 04/05/06
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_03 END -->'); END;
/
