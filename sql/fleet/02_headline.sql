--
-- sql/fleet/02_headline.sql
-- Compact hero-six strip, adapted from sql/08_overview.sql's cards CTE:
-- same shared-windows-CTE x LOAD/METRIC values single-pass cursor, same six
-- metrics (DB time / redo size / logical reads / AAS / Wait Time Ratio /
-- hard parses -- the FLEET template's target lists are seeded so all six
-- source names always resolve, never falling back to "n/a").
--
-- Render differs from 08_overview: label + data-spark sparkline (oldest
-- -> current, CDN-free -- no ECharts anywhere in the fleet report) +
-- current value + z-bucket badge.  The delta-chip row and the ECharts
-- upgrade path are dropped entirely; this is a read-at-a-glance strip, not
-- an interactive widget.
--
-- Read-only: recomputes everything in-flight from the AWR views.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<h3>Headline metrics</h3>');
    DBMS_OUTPUT.PUT_LINE('<div class="hero-grid">');

    FOR c IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- is_add tags METRIC rows for cross-instance aggregation, same
        -- semantics as sql/lib/templates/*/sysmetric_targets.sql: 'Y' =
        -- SUM across instances per snap (rates/counters), 'N' = AVG
        -- (ratios/percentages). LOAD rows are SYSSTAT deltas, already
        -- summed at the row level, so the flag is irrelevant for them.
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
            -- Summed cross-instance delta over ONE window span
            -- (MAX(dur_sec)); dur_sec out of the GROUP BY so per-instance
            -- span jitter can't split a RAC week. Single-instance
            -- byte-identical.
            SELECT 'LOAD' AS src, stat_name AS key, week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END AS val
            FROM   load_bounds
            GROUP BY week_offset, stat_name
        ),
        metric_per_snap AS (
            SELECT w.week_offset, c.key AS metric_name, sm.snap_id,
                   c.is_add,
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
               -- ','||token + SUBSTR: LISTAGG drops NULL measures (and
               -- their delimiter), which would left-compact the CSV and
               -- misalign the sparkline's positional slots; ','||NULL = ','
               -- keeps the empty slot (the JS sparkline reads an empty
               -- token as a gap).
               SUBSTR(LISTAGG(',' || TO_CHAR(val, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS vals_csv
        FROM   grid
        GROUP BY pos, label, unit
        ORDER BY pos
    ) LOOP
        DECLARE
            v_z       NUMBER;
            v_sev     VARCHAR2(40);
            v_sev_cls VARCHAR2(10);
            v_badge   VARCHAR2(80);
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
            v_sev_cls := CASE v_sev
                WHEN 'large'    THEN 'crit'
                WHEN 'moderate' THEN 'warn'
                WHEN 'typical'  THEN 'ok'
                ELSE 'skip' END;
            v_badge := CASE
                WHEN v_sev IS NULL THEN 'n/a'
                WHEN v_z IS NOT NULL THEN v_sev || ' z=' || TO_CHAR(v_z, 'FMS99990D0')
                ELSE v_sev END;

            DBMS_OUTPUT.PUT_LINE('<div class="hero-card" data-hero-pos="' || c.pos || '">');
            DBMS_OUTPUT.PUT_LINE('  <div class="label">' || c.label || '</div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="mini" data-spark="' || NVL(c.vals_csv, '')
                || '" data-spark-title="' || c.label || '"></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="value">'
                || CASE WHEN c.cur IS NULL THEN '&mdash;'
                        ELSE TO_CHAR(c.cur, 'FM999G999G990D00') END
                || ' <small>' || c.unit || '</small></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="foot"><span class="badge ' || v_sev_cls || '">'
                || v_badge || '</span></div>');
            DBMS_OUTPUT.PUT_LINE('</div>');
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .hero-grid
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 END -->'); END;
/
