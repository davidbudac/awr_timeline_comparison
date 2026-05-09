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
            SELECT w.week_offset, w.dbid, w.instance_number,
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
            SELECT w.week_offset, w.dbid, w.instance_number,
                   w.begin_snap_id, w.end_snap_id,
                   (CAST(rw.win_end_dt AS DATE) - CAST(rw.win_start_dt AS DATE)) * 86400 AS dur_sec
            FROM   windows w
            JOIN   raw_windows rw ON rw.week_offset = w.week_offset
            WHERE  w.valid_flag = 'Y'
        ),
        cards AS (
            SELECT 1 AS pos, 'DB time'                AS label, 'cs/s' AS unit,
                   'LOAD'   AS src, 'DB time'                 AS key FROM dual UNION ALL
            SELECT 2, 'Redo generated',        'B/s',
                   'LOAD',   'redo size'                             FROM dual UNION ALL
            SELECT 3, 'Logical reads',         '/s',
                   'LOAD',   'session logical reads'                 FROM dual UNION ALL
            SELECT 4, 'Average Active Sessions','AAS',
                   'METRIC', 'Average Active Sessions'               FROM dual UNION ALL
            SELECT 5, 'Wait Time Ratio',       '%',
                   'METRIC', 'Database Wait Time Ratio'              FROM dual UNION ALL
            SELECT 6, 'Hard parses',           '/s',
                   'LOAD',   'parse count (hard)'                    FROM dual
        ),
        load_pairs AS (
            SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                   ss.snap_id, ss.value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR ss.instance_number = w.instance_number)
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
        metric_rows AS (
            SELECT 'METRIC' AS src, sm.metric_name AS key, w.week_offset,
                   AVG(sm.average) AS val
            FROM   valid_windows w
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR sm.instance_number = w.instance_number)
               AND sm.metric_name IN (SELECT key FROM cards WHERE src = 'METRIC')
            GROUP BY w.week_offset, sm.metric_name
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
               MAX(CASE WHEN week_offset = 1 THEN val END) AS prev,
               AVG(CASE WHEN week_offset > 0 THEN val END) AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN val END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN val END) AS n,
               LISTAGG(CASE WHEN val IS NULL THEN 'null'
                            ELSE TO_CHAR(val, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS vals_csv
        FROM   grid
        GROUP BY pos, label, unit
        ORDER BY pos
    ) LOOP
        DECLARE
            v_z    NUMBER;
            v_pct  NUMBER;
            v_sev  VARCHAR2(40);
            v_sev_cls VARCHAR2(10);
            v_sev_badge VARCHAR2(80);
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

            v_cards_json := CASE WHEN v_cards_json IS NULL THEN '' ELSE v_cards_json || ',' END
                || '{"pos":' || c.pos
                || ',"label":"' || c.label
                || '","unit":"' || c.unit
                || '","cur":' || CASE WHEN c.cur IS NULL THEN 'null'
                                      ELSE TO_CHAR(c.cur, 'FM99999999990D000000',
                                                   'NLS_NUMERIC_CHARACTERS=''.,''') END
                || ',"prev":' || CASE WHEN c.prev IS NULL THEN 'null'
                                       ELSE TO_CHAR(c.prev, 'FM99999999990D000000',
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

            v_sev_badge := CASE
                WHEN v_sev IS NULL THEN 'n/a'
                WHEN v_z IS NOT NULL THEN v_sev || ' z=' || TO_CHAR(v_z, 'FMS990D0')
                ELSE v_sev END;

            DBMS_OUTPUT.PUT_LINE('<div class="hero-card" data-hero-pos="' || c.pos || '">');
            DBMS_OUTPUT.PUT_LINE('  <div class="label">' || c.label || '</div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="mini" id="hero-mini-' || c.pos
                || '" data-spark="' || NVL(c.vals_csv, '')
                || '" data-spark-title="' || c.label || '"></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="value">'
                || CASE WHEN c.cur IS NULL THEN '&mdash;'
                        ELSE TO_CHAR(c.cur, 'FM999G999G990D00') END
                || ' <small>' || c.unit || '</small></div>');
            DBMS_OUTPUT.PUT_LINE('  <div class="foot">'
                || CASE
                       WHEN c.cur IS NULL OR c.prev IS NULL OR c.prev = 0 THEN
                           '<span class="delta">&mdash;</span>'
                       WHEN c.cur > c.prev THEN
                           '<span class="delta up">&uarr; '
                               || TO_CHAR((c.cur - c.prev) / ABS(c.prev) * 100, 'FMS990D0')
                               || '% vs -1w</span>'
                       WHEN c.cur < c.prev THEN
                           '<span class="delta down">&darr; '
                               || TO_CHAR((c.cur - c.prev) / ABS(c.prev) * 100, 'FMS990D0')
                               || '% vs -1w</span>'
                       ELSE
                           '<span class="delta">&mdash; vs -1w</span>'
                   END
                || '<span class="badge ' || v_sev_cls || '">'
                || v_sev_badge
                || '</span></div>');
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
