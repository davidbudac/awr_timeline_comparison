--
-- 08_overview.sql
-- Renders a 6-card hero strip at the top of the report (CSS order:3 places
-- it after the header and before the Findings table). Each card shows:
--   - metric label
--   - mini ECharts line+area chart across windows (oldest -> newest)
--   - current value (+ unit)
--   - an inline-SVG bar strip (oldest -> current) on a lowered baseline so
--     small differences stay visible, plus a "vs prior mean" delta line
--     with the prior min-max range (B6)
--   - change-bucket badge (large/moderate/typical) from an inline z-score
--
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- read or persist any scratch table.
--
-- Display-only rules layered on top of the z/pct computed below (B5/F5,
-- same convention as sql/07_summary.sql / sql/lib/score_cells.plsql -- not
-- shared, recomputed locally):
--   - |z| > 99 is clamped to "&gt;+99" / "&lt;&minus;99" for the hero badge.
--   - A near-zero baseline sigma (sd < 1% of |mean|, or both exactly 0)
--     gets a sibling "sigma approx 0" badge next to the severity badge.
--   - The "vs prior mean" delta always carries a leading up/down triangle
--     instead of a signed number; no per-direction color class is used
--     (severity color stays on .badge only).
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 08_overview BEGIN -->'); END;
/

DECLARE
    v_weeks_json  VARCHAR2(4000);
    v_cards_json  CLOB;
    v_weeks_back  NUMBER := ~weeks_back;

    @@sql/lib/nth_csv.plsql
    @@sql/lib/fmt_num.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="overview" data-triage="Y"><h2>Headline metrics</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Six headline metrics across the compared windows, oldest &rarr; current. '
        || 'Badge = z bucket: |z|&gt;3 large, |z|&gt;2 moderate, else typical.</p>');

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
            -- Summed cross-instance delta over ONE window span (MAX(dur_sec));
            -- dur_sec out of the GROUP BY so per-instance span jitter can't
            -- split a RAC week.  Single-instance byte-identical.
            SELECT 'LOAD' AS src, stat_name AS key, week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END AS val
            FROM   load_bounds
            GROUP BY week_offset, stat_name
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
               -- ','||token + SUBSTR: LISTAGG drops NULL measures (and their
               -- delimiter), which would left-compact the CSV and misalign
               -- the positional slots; ','||NULL = ',' keeps the empty slot.
               (SELECT SUBSTR(LISTAGG(',' || TO_CHAR(d.delta_pct, 'FM99999999990D000000',
                                                     'NLS_NUMERIC_CHARACTERS=''.,'''))
                       WITHIN GROUP (ORDER BY d.week_offset DESC), 2)
                FROM   deltas d
                WHERE  d.pos = grid.pos
                  AND  d.week_offset < ~weeks_back) AS deltas_csv
        FROM   grid
        GROUP BY pos, label, unit
        ORDER BY pos
    ) LOOP
        DECLARE
            TYPE num_arr IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

            v_z         NUMBER;
            v_pct       NUMBER;
            v_sev       VARCHAR2(40);
            v_sev_cls   VARCHAR2(10);
            v_z_txt     VARCHAR2(40);
            v_sev_badge VARCHAR2(80);
            v_sig       VARCHAR2(1) := 'N';

            -- B6: bar-strip + "vs prior mean" delta line (replaces the old
            -- per-window "-Np +x%" chip row).
            v_n         PLS_INTEGER := v_weeks_back + 1;
            v_vals      num_arr;      -- 1..v_n, oldest -> current
            v_tok       VARCHAR2(64);
            v_min_all   NUMBER;
            v_max_all   NUMBER;
            v_min_prior NUMBER;
            v_max_prior NUMBER;
            v_lo        NUMBER;
            v_hi        NUMBER;
            v_h         NUMBER;
            v_bars      VARCHAR2(32767);
            v_range_txt VARCHAR2(120);
            v_pct_txt   VARCHAR2(80);
            v_bw        CONSTANT NUMBER := 34;
            v_gap       CONSTANT NUMBER := 6;
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

            -- B5: display-only clamp + baseline-barely-moved flag (no
            -- scoring/severity impact -- v_sev/v_sev_cls above are untouched).
            IF c.mu IS NOT NULL AND c.sd IS NOT NULL THEN
                IF (c.mu = 0 AND c.sd = 0)
                   OR (c.mu <> 0 AND c.sd < 0.01 * ABS(c.mu)) THEN
                    v_sig := 'Y';
                END IF;
            END IF;
            v_z_txt := CASE
                WHEN v_z IS NULL THEN NULL
                WHEN v_z > 99    THEN '&gt;+99'
                WHEN v_z < -99   THEN '&lt;&minus;99'
                ELSE TO_CHAR(v_z, 'FMS99990D0')
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
                                    ELSE TO_CHAR(v_z, 'FMS99990D00',
                                                 'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"pct":' || CASE WHEN v_pct IS NULL THEN 'null'
                                      ELSE TO_CHAR(v_pct, 'FMS99990D0',
                                                   'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"vals":[' || NVL(c.vals_csv, '') || ']}';

            v_sev_badge := CASE
                WHEN v_sev IS NULL THEN 'n/a'
                WHEN v_z IS NOT NULL THEN v_sev || ' z=' || v_z_txt
                ELSE v_sev END;

            DBMS_OUTPUT.PUT_LINE('<div class="hero-card" data-hero-pos="' || c.pos || '">');
            DBMS_OUTPUT.PUT_LINE('  <div class="label">' || c.label || '</div>');
            -- data-spark keeps its existing CSV contract untouched -- only
            -- the foot below changes.
            DBMS_OUTPUT.PUT_LINE('  <div class="mini" id="hero-mini-' || c.pos
                || '" data-spark="' || NVL(c.vals_csv, '')
                || '" data-spark-title="' || c.label || '"></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="value"' || fmt_num_title(c.cur) || '>'
                || fmt_num(c.cur)
                || ' <small>' || c.unit || '</small></div>');

            --
            -- B6: parse the same vals_csv (oldest -> current, positional,
            -- 'null' token for a missing window) that data-spark already
            -- carries, into a bar strip with a lowered baseline so small
            -- differences stay visible, plus the prior min-max range.
            --
            FOR k IN 1 .. v_n LOOP
                v_tok := nth_csv(c.vals_csv, k);
                IF v_tok IS NULL OR v_tok = '' OR LOWER(v_tok) = 'null' THEN
                    v_vals(k) := NULL;
                ELSE
                    v_vals(k) := TO_NUMBER(v_tok, 'FM99999999990D000000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                END IF;
                IF v_vals(k) IS NOT NULL THEN
                    v_min_all := LEAST(NVL(v_min_all, v_vals(k)), v_vals(k));
                    v_max_all := GREATEST(NVL(v_max_all, v_vals(k)), v_vals(k));
                    IF k < v_n THEN
                        v_min_prior := LEAST(NVL(v_min_prior, v_vals(k)), v_vals(k));
                        v_max_prior := GREATEST(NVL(v_max_prior, v_vals(k)), v_vals(k));
                    END IF;
                END IF;
            END LOOP;

            v_bars := NULL;
            IF v_min_all IS NOT NULL THEN
                v_lo := GREATEST(v_min_all - 1.5 * (v_max_all - v_min_all), 0);
                v_hi := CASE WHEN v_max_all = v_lo THEN v_lo + 1 ELSE v_max_all END;
                FOR k IN 1 .. v_n LOOP
                    IF v_vals(k) IS NOT NULL THEN
                        v_h := GREATEST(1, LEAST(38, ROUND((v_vals(k) - v_lo) / (v_hi - v_lo) * 38, 2)));
                        v_bars := v_bars
                            || '<rect x="' || ((k - 1) * (v_bw + v_gap))
                            || '" y="' || (40 - v_h)
                            || '" width="' || v_bw
                            || '" height="' || v_h
                            || '" rx="2" fill="var(--accent)" opacity="'
                            || CASE WHEN k = v_n THEN '1' ELSE '0.3' END
                            || '"></rect>';
                    END IF;
                END LOOP;
            END IF;
            IF v_bars IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('  <svg class="hbars" viewBox="0 0 '
                    || TO_CHAR(GREATEST(200, v_n * (v_bw + v_gap) - v_gap)) || ' 42" aria-hidden="true">'
                    || v_bars || '</svg>');
            END IF;

            -- F5: direction glyph, no color class.
            v_pct_txt := CASE
                WHEN v_pct IS NULL THEN '&mdash;'
                WHEN v_pct < 0     THEN '&#9660; ' || TO_CHAR(ABS(v_pct), 'FM99990D0') || '%'
                ELSE '&#9650; ' || TO_CHAR(v_pct, 'FM99990D0') || '%'
            END;
            v_range_txt := CASE
                WHEN v_min_prior IS NULL OR v_max_prior IS NULL THEN '&mdash;'
                ELSE fmt_num(v_min_prior) || ' &ndash; ' || fmt_num(v_max_prior)
            END;
            DBMS_OUTPUT.PUT_LINE('  <div class="hc-delta">vs prior mean <b>'
                || v_pct_txt || '</b> &middot; range ' || v_range_txt || '</div>');

            DBMS_OUTPUT.PUT_LINE('  <div class="foot">'
                || '<span class="badge ' || v_sev_cls || '">'
                || v_sev_badge
                || '</span>'
                || CASE WHEN v_sig = 'Y' THEN
                       ' <span class="badge sig" title="baseline barely moved: '
                       || '&sigma; below 1% of mean; read the % delta instead">'
                       || '&sigma;&approx;0</span>'
                   END
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('</div>');
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .hero-grid

    -- Emit mini-chart init (uses sparkline renderer for CDN-free fallback, upgrades
    -- to ECharts mini line+area when ECharts is available).
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.overview = {weeks:' || v_weeks_json
        || ',cards:[' || NVL(v_cards_json, '') || ']};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts){');
    DBMS_OUTPUT.PUT_LINE('  // Fallback: use the inline SVG sparkline renderer (window.__awrRenderSparks)');
    DBMS_OUTPUT.PUT_LINE('  if(window.__awrRenderSparks) window.__awrRenderSparks();');
    DBMS_OUTPUT.PUT_LINE('  return;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var ac=cs.getPropertyValue("--accent").trim()||"#2563eb";');
    DBMS_OUTPUT.PUT_LINE('var ac2=cs.getPropertyValue("--accent-2").trim()||"#14b8a6";');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.overview.cards.forEach(function(c){');
    DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("hero-mini-"+c.pos);');
    DBMS_OUTPUT.PUT_LINE('  if(!el || !c.vals || !c.vals.length) return;');
    DBMS_OUTPUT.PUT_LINE('  el.__sparked=true;  // prevent sparkline renderer from overwriting');
    DBMS_OUTPUT.PUT_LINE('  el.innerHTML="";  // clear any sparkline fallback already rendered');
    DBMS_OUTPUT.PUT_LINE('  el.removeAttribute("data-spark");');
    DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el,null,{renderer:"svg"});');
    DBMS_OUTPUT.PUT_LINE('  var color=c.sev==="large"?cs.getPropertyValue("--crit-fg").trim():(c.sev==="moderate"?cs.getPropertyValue("--warn-fg").trim():ac);');
    DBMS_OUTPUT.PUT_LINE('  chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('    animation:false,');
    DBMS_OUTPUT.PUT_LINE('    grid:{left:2,right:2,top:2,bottom:2},');
    DBMS_OUTPUT.PUT_LINE('    xAxis:{type:"category",show:false,data:AWR_DATA.overview.weeks,boundaryGap:false},');
    DBMS_OUTPUT.PUT_LINE('    yAxis:{type:"value",show:false,scale:true},');
    DBMS_OUTPUT.PUT_LINE('    tooltip:{trigger:"axis",formatter:function(p){return p[0].axisValue+"<br/><b>"+(p[0].data==null?"\u2014":(+p[0].data).toFixed(2))+"</b> "+c.unit;}},');
    DBMS_OUTPUT.PUT_LINE('    series:[{type:"line",data:c.vals,smooth:true,showSymbol:false,connectNulls:true,lineStyle:{color:color,width:1.8},areaStyle:{color:{type:"linear",x:0,y:0,x2:0,y2:1,colorStops:[{offset:0,color:color+"33"},{offset:1,color:color+"05"}]}},markPoint:{symbol:"circle",symbolSize:6,itemStyle:{color:color},data:[{coord:[c.vals.length-1,c.vals[c.vals.length-1]]}]}}]');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 08_overview END -->'); END;
/
