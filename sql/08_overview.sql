--
-- 08_overview.sql
-- Renders a 6-card hero strip at the top of the report (CSS order:3 places
-- it after the header and before the Findings table). Each card shows:
--   - metric label
--   - mini ECharts line+area chart across windows (oldest -> newest)
--   - current value (+ unit)
--   - change-bucket badge (large/moderate/typical) from an inline z-score
--
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- read or persist any scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_json  VARCHAR2(4000);
    v_cards_json  CLOB;
    v_weeks_back  NUMBER := ~weeks_back;

    @@sql/lib/nth_csv.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="overview"><h2>Headline metrics</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Six key signals across the last ' || v_weeks_back
        || ' compared windows (oldest &rarr; current). Change badge buckets the '
        || 'z-score of the current window vs prior valid windows '
        || '(|z|&gt;3 = large, |z|&gt;2 = moderate, otherwise typical).</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="hero-grid">');

    -- x-axis labels: one timestamp per compared window, oldest-first.
    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - (~step_hours/24)*week_offset, '~period_axis_fmt') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);

    v_cards_json := NULL;

    --
    -- Single cursor that produces every card in one pass: shared windows CTE,
    -- both LOAD and METRIC source rows, then a cards list LEFT-JOINed onto
    -- the full week grid.  Ordered by pos 1..6 (left-to-right).
    --
    FOR c IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- is_add tags METRIC rows for cross-instance aggregation: 'Y' =
        -- additive (SUM across instances per snap), 'N' = ratio/avg.
        -- LOAD rows are SYSSTAT counter deltas which are already
        -- per-instance in the GROUP BY and SUMmed at the rows level, so
        -- the flag is irrelevant for them (set to 'Y' for tidiness).
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
                   CASE WHEN dur_sec > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / dur_sec
                   END AS val
            FROM   load_bounds
            GROUP BY week_offset, dur_sec, stat_name
        ),
        -- Per-snap cluster value: SUM across instances for additive
        -- metrics (rates/counters), AVG for ratios. See is_add tagging
        -- on cards above. On single-instance, SUM and AVG over one row
        -- are identical, so no behavior change for non-RAC.
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
        ),
        with_lag AS (
            SELECT pos, label, unit, week_offset, val,
                   LEAD(val) OVER (PARTITION BY pos ORDER BY week_offset) AS older_val
            FROM   grid
        ),
        deltas AS (
            SELECT pos, week_offset,
                   CASE WHEN week_offset < ~weeks_back
                         AND val IS NOT NULL
                         AND older_val IS NOT NULL
                         AND older_val <> 0
                        THEN (val - older_val) / ABS(older_val) * 100
                   END AS delta_pct
            FROM   with_lag
        )
        SELECT pos, label, unit,
               MAX(CASE WHEN week_offset = 0 THEN val END) AS cur,
               AVG(CASE WHEN week_offset > 0 THEN val END) AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN val END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN val END) AS n,
               LISTAGG(CASE WHEN val IS NULL THEN 'null'
                            ELSE TO_CHAR(val, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS vals_csv,
               (SELECT LISTAGG(CASE WHEN d.delta_pct IS NULL THEN ''
                                    ELSE TO_CHAR(d.delta_pct, 'FM99999999990D000000',
                                                 'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY d.week_offset DESC)
                FROM   deltas d
                WHERE  d.pos = grid.pos
                  AND  d.week_offset < ~weeks_back) AS deltas_csv
        FROM   grid
        GROUP BY pos, label, unit
        ORDER BY pos
    ) LOOP
        DECLARE
            v_z    NUMBER;
            v_pct  NUMBER;
            v_sev  VARCHAR2(40);
            v_sev_cls VARCHAR2(10);
            v_chips    VARCHAR2(32767);
            v_d_s      VARCHAR2(64);
            v_d        NUMBER;
            v_off      PLS_INTEGER;
            v_off_lbl_text  VARCHAR2(80);
            v_spark_cls     VARCHAR2(40);
        BEGIN
            v_z := CASE
                WHEN c.cur IS NULL OR c.mu IS NULL THEN NULL
                WHEN c.sd IS NULL OR c.sd = 0       THEN NULL
                ELSE (c.cur - c.mu) / c.sd
            END;
            v_pct := CASE
                WHEN c.cur IS NULL OR c.mu IS NULL OR c.mu = 0 THEN NULL
                ELSE (c.cur - c.mu) / ABS(c.mu) * 100
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

            -- spark-warn / spark-crit only when the current window is far
            -- enough from baseline to deserve attention; typical/insuf draws
            -- in the default accent color.
            v_spark_cls := CASE v_sev_cls
                WHEN 'crit' THEN 'spark crit'
                WHEN 'warn' THEN 'spark warn'
                ELSE             'spark'
            END;

            v_cards_json := CASE WHEN v_cards_json IS NULL THEN '' ELSE v_cards_json || ',' END
                || '{"pos":' || c.pos
                || ',"label":"' || c.label
                || '","unit":"' || c.unit
                || '","cur":' || CASE WHEN c.cur IS NULL THEN 'null'
                                      ELSE TO_CHAR(c.cur, 'FM99999999990D000000',
                                                   'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"sev":' || CASE WHEN v_sev IS NULL THEN 'null'
                                      ELSE '"' || v_sev || '"' END
                || ',"z":' || CASE WHEN v_z IS NULL THEN 'null'
                                    ELSE TO_CHAR(v_z, 'FMS990D00',
                                                 'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"pct":' || CASE WHEN v_pct IS NULL THEN 'null'
                                      ELSE TO_CHAR(v_pct, 'FMS990D0',
                                                   'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"vals":[' || NVL(c.vals_csv, '') || ']}';

            -- Card layout: label on top, then a flex row with the current
            -- value left and a small inline-SVG sparkline on the right.
            -- Severity is conveyed by the sparkline color (no badge), so the
            -- card stays as compact as the mockup's KPI strip.
            DBMS_OUTPUT.PUT_LINE('<div class="hero-card" data-hero-pos="' || c.pos
                || '" title="' || NVL(v_sev, 'n/a')
                || CASE WHEN v_z IS NULL THEN ''
                        ELSE ' (z=' || TO_CHAR(v_z, 'FMS990D0') || ')' END
                || '">');
            DBMS_OUTPUT.PUT_LINE('  <div class="hc-lab">' || c.label || '</div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="hc-row">');
            DBMS_OUTPUT.PUT_LINE('    <div class="hc-val">'
                || CASE WHEN c.cur IS NULL THEN '&mdash;'
                        ELSE TO_CHAR(c.cur, 'FM999G999G990D00') END
                || '<small>' || c.unit || '</small></div>');
            DBMS_OUTPUT.PUT_LINE('    <div class="hc-spark" data-spark="'
                || NVL(c.vals_csv, '')
                || '" data-spark-cls="' || v_spark_cls
                || '" data-spark-title="' || c.label || '"></div>');
            DBMS_OUTPUT.PUT_LINE('  </div>');

            v_chips := NULL;
            FOR k IN 1 .. v_weeks_back LOOP
                v_off          := v_weeks_back - k + 1;
                -- Unit-aware offset label parsed from offset_labels CSV
                -- ('1w,2w,3w' or '15m,30m,45m'). Falls back to "<n>p" if the
                -- caller exceeded 16 offsets.
                v_off_lbl_text := REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, v_off);
                IF v_off_lbl_text IS NULL THEN
                    v_off_lbl_text := v_off || 'p';
                END IF;

                v_d_s := nth_csv(c.deltas_csv, k);
                IF v_d_s IS NULL OR v_d_s = '' THEN
                    v_chips := v_chips || '<span class="hc-d nc" title="vs -'
                        || v_off_lbl_text || '"><span class="dp">-'
                        || v_off_lbl_text || '</span>&mdash;</span>';
                ELSE
                    v_d := TO_NUMBER(v_d_s, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''');
                    IF v_d > 0 THEN
                        v_chips := v_chips || '<span class="hc-d up" title="vs -'
                            || v_off_lbl_text || '"><span class="dp">-'
                            || v_off_lbl_text || '</span>'
                            || TO_CHAR(v_d, 'FMS990D0') || '%</span>';
                    ELSIF v_d < 0 THEN
                        v_chips := v_chips || '<span class="hc-d dn" title="vs -'
                            || v_off_lbl_text || '"><span class="dp">-'
                            || v_off_lbl_text || '</span>'
                            || TO_CHAR(v_d, 'FMS990D0') || '%</span>';
                    ELSE
                        v_chips := v_chips || '<span class="hc-d nc" title="vs -'
                            || v_off_lbl_text || '"><span class="dp">-'
                            || v_off_lbl_text || '</span>0%</span>';
                    END IF;
                END IF;
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('  <div class="hc-deltas">'
                || NVL(v_chips, '<span class="hc-d nc">&mdash;</span>')
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('</div>');
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .hero-grid

    -- Stash the structured card data on window.AWR_DATA so a future debug
    -- console / drill-down can walk it; the inline-SVG sparkline renderer
    -- (js_sparkline.plsql) already picks up data-spark attributes on its
    -- own DOMReady pass, so no chart init is needed here.
    DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.overview = {weeks:' || v_weeks_json
        || ',cards:[' || NVL(v_cards_json, '') || ']};</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
