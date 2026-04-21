--
-- 08_overview.sql
-- Renders a 6-card hero strip at the top of the report (CSS order:3 places
-- it after the header and before the Findings table). Each card shows:
--   - metric label
--   - mini ECharts line+area chart across windows (oldest -> newest)
--   - current value (+ unit)
--   - severity badge (derived from awr_trend_findings if available)
--
-- Runs AFTER 07_summary.sql so findings are available for severity/z-score.
-- Consumes data that is already persisted in awr_trend_load_profile,
-- awr_trend_sysmetric, awr_trend_waits, awr_trend_findings. No new facts.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_json  VARCHAR2(4000);
    v_cards_json  CLOB;

    --
    -- One card per headline metric. All pulled from already-persisted
    -- scratch tables keyed by run_id.  Order matters (1..6 left-to-right).
    --
    TYPE t_card IS RECORD (
        pos      NUMBER,
        label    VARCHAR2(80),
        unit     VARCHAR2(20),
        src      VARCHAR2(20),     -- 'LOAD' | 'METRIC' | 'WAIT_RATIO'
        key      VARCHAR2(200)     -- stat_name / metric_name
    );
    TYPE t_cards IS TABLE OF t_card;
    v_cards t_cards;

    v_vals_csv   VARCHAR2(4000);
    v_cur        NUMBER;
    v_prev       NUMBER;
    v_sev        VARCHAR2(40);
    v_z          NUMBER;
    v_pct        NUMBER;
    v_find_dom   VARCHAR2(20);
    v_find_name  VARCHAR2(200);
    v_weeks_back NUMBER;
    v_src        VARCHAR2(20);
    v_key        VARCHAR2(200);
    v_label      VARCHAR2(80);
    v_unit       VARCHAR2(20);
    v_pos        NUMBER;
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = ~run_id;

    v_cards := t_cards(
        t_card(1, 'DB time',              'cs/s',   'LOAD',       'DB time'),
        t_card(2, 'Redo generated',       'B/s',    'LOAD',       'redo size'),
        t_card(3, 'Logical reads',        '/s',     'LOAD',       'session logical reads'),
        t_card(4, 'Average Active Sessions','AAS',  'METRIC',     'Average Active Sessions'),
        t_card(5, 'Wait Time Ratio',      '%',      'METRIC',     'Database Wait Time Ratio'),
        t_card(6, 'Hard parses',          '/s',     'LOAD',       'parse count (hard)')
    );

    DBMS_OUTPUT.PUT_LINE('<section id="overview"><h2>Headline metrics</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Six key signals across the last ' || v_weeks_back
        || ' aligned windows (oldest &rarr; current). Severity badge is taken from the '
        || '<a href="#findings">Findings</a> table when a z-score baseline exists.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="hero-grid">');

    -- Build per-card weeks array once (shared across cards, oldest->newest).
    SELECT '['
        || LISTAGG('"' || TO_CHAR(win_end_ts, 'Mon DD') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id;

    v_cards_json := NULL;

    FOR i IN 1 .. v_cards.COUNT LOOP
        v_vals_csv := NULL;
        v_cur := NULL;
        v_prev := NULL;
        v_pos   := v_cards(i).pos;
        v_label := v_cards(i).label;
        v_unit  := v_cards(i).unit;
        v_src   := v_cards(i).src;
        v_key   := v_cards(i).key;

        IF v_src = 'LOAD' THEN
            SELECT LISTAGG(CASE WHEN per_sec IS NULL THEN 'null'
                                ELSE TO_CHAR(per_sec, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset DESC)
            INTO   v_vals_csv
            FROM (
                SELECT w.week_offset,
                       MAX(lp.per_sec) AS per_sec
                FROM   awr_trend_windows w
                LEFT JOIN awr_trend_load_profile lp
                       ON lp.run_id = w.run_id AND lp.week_offset = w.week_offset
                      AND lp.stat_name = v_key
                WHERE  w.run_id = ~run_id
                GROUP BY w.week_offset
            );
            SELECT MAX(per_sec)
            INTO   v_cur
            FROM   awr_trend_load_profile
            WHERE  run_id = ~run_id AND stat_name = v_key AND week_offset = 0;
            SELECT MAX(per_sec)
            INTO   v_prev
            FROM   awr_trend_load_profile
            WHERE  run_id = ~run_id AND stat_name = v_key AND week_offset = 1;
            v_find_dom  := 'LOAD';
            v_find_name := v_key;

        ELSE  -- METRIC
            SELECT LISTAGG(CASE WHEN avg_value IS NULL THEN 'null'
                                ELSE TO_CHAR(avg_value, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset DESC)
            INTO   v_vals_csv
            FROM (
                SELECT w.week_offset, MAX(sm.avg_value) AS avg_value
                FROM   awr_trend_windows w
                LEFT JOIN awr_trend_sysmetric sm
                       ON sm.run_id = w.run_id AND sm.week_offset = w.week_offset
                      AND sm.metric_name = v_key
                WHERE  w.run_id = ~run_id
                GROUP BY w.week_offset
            );
            SELECT MAX(avg_value)
            INTO   v_cur
            FROM   awr_trend_sysmetric
            WHERE  run_id = ~run_id AND metric_name = v_key AND week_offset = 0;
            SELECT MAX(avg_value)
            INTO   v_prev
            FROM   awr_trend_sysmetric
            WHERE  run_id = ~run_id AND metric_name = v_key AND week_offset = 1;
            v_find_dom  := 'METRIC';
            v_find_name := v_key;
        END IF;

        -- Severity from findings (may be NULL if the metric wasn't captured)
        BEGIN
            SELECT severity, z_score, pct_delta
            INTO   v_sev, v_z, v_pct
            FROM   awr_trend_findings
            WHERE  run_id = ~run_id
              AND  metric_domain = v_find_dom
              AND  metric_name   = v_find_name;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            v_sev := NULL;
            v_z   := NULL;
            v_pct := NULL;
        END;

        v_cards_json := CASE WHEN v_cards_json IS NULL THEN '' ELSE v_cards_json || ',' END
            || '{"pos":' || v_cards(i).pos
            || ',"label":"' || v_cards(i).label
            || '","unit":"' || v_cards(i).unit
            || '","cur":' || CASE WHEN v_cur IS NULL THEN 'null'
                                  ELSE TO_CHAR(v_cur, 'FM99999999990D000000',
                                               'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"prev":' || CASE WHEN v_prev IS NULL THEN 'null'
                                   ELSE TO_CHAR(v_prev, 'FM99999999990D000000',
                                                'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"sev":' || CASE WHEN v_sev IS NULL THEN 'null'
                                  ELSE '"' || v_sev || '"' END
            || ',"z":' || CASE WHEN v_z IS NULL THEN 'null'
                                ELSE TO_CHAR(v_z, 'FMS990D00',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"pct":' || CASE WHEN v_pct IS NULL THEN 'null'
                                  ELSE TO_CHAR(v_pct, 'FMS990D0',
                                               'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"vals":[' || NVL(v_vals_csv, '') || ']}';

        -- Emit the card HTML. JS init below fills in the mini chart.
        DBMS_OUTPUT.PUT_LINE('<div class="hero-card" data-hero-pos="' || v_cards(i).pos || '">');
        DBMS_OUTPUT.PUT_LINE('  <div class="label">' || v_cards(i).label || '</div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="mini" id="hero-mini-' || v_cards(i).pos
            || '" data-spark="' || NVL(v_vals_csv, '')
            || '" data-spark-title="' || v_cards(i).label || '"></div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="value">'
            || CASE WHEN v_cur IS NULL THEN '&mdash;'
                    ELSE TO_CHAR(v_cur, 'FM999G999G990D00') END
            || ' <small>' || v_cards(i).unit || '</small></div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="foot">'
            || CASE
                   WHEN v_cur IS NULL OR v_prev IS NULL OR v_prev = 0 THEN
                       '<span class="delta">&mdash;</span>'
                   WHEN v_cur > v_prev THEN
                       '<span class="delta up">&uarr; '
                           || TO_CHAR((v_cur - v_prev) / ABS(v_prev) * 100, 'FMS990D0')
                           || '% vs -1w</span>'
                   WHEN v_cur < v_prev THEN
                       '<span class="delta down">&darr; '
                           || TO_CHAR((v_cur - v_prev) / ABS(v_prev) * 100, 'FMS990D0')
                           || '% vs -1w</span>'
                   ELSE
                       '<span class="delta">&mdash; vs -1w</span>'
               END
            || '<span class="badge '
            || CASE v_sev
                   WHEN 'CRITICAL' THEN 'crit'
                   WHEN 'WARN'     THEN 'warn'
                   WHEN 'OK'       THEN 'ok'
                   ELSE 'skip' END
            || '">'
            || CASE
                   WHEN v_sev IS NULL THEN 'n/a'
                   WHEN v_z IS NOT NULL THEN v_sev || ' z=' || TO_CHAR(v_z, 'FMS990D0')
                   ELSE v_sev END
            || '</span></div>');
        DBMS_OUTPUT.PUT_LINE('</div>');
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
    DBMS_OUTPUT.PUT_LINE('  var color=c.sev==="CRITICAL"?cs.getPropertyValue("--crit-fg").trim():(c.sev==="WARN"?cs.getPropertyValue("--warn-fg").trim():ac);');
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
