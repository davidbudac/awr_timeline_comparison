--
-- 07_summary.sql
-- For every scalar metric stored by sections 02-04, compute z-score of the
-- current window against the mean/stddev of the prior valid windows, flag
-- severity, and insert into awr_trend_findings.  Then render a sorted
-- "Findings" table at the top of the report body.  (Because SPOOL is append-
-- only, this block is still emitted last; the CSS already orders the
-- #findings section visually near the top when the page has a flex/grid
-- parent, but we also emit a jump link from the nav bar.)
--

SET DEFINE '~'

--
-- Build the union of metric rows across all three domains.
-- 'LOAD'   : per-sec rate from awr_trend_load_profile
-- 'METRIC' : avg value from awr_trend_sysmetric
-- 'WAIT'   : time waited per second for foreground wait CLASSES
--
INSERT INTO awr_trend_findings (
    run_id, metric_domain, metric_name,
    current_value, prior_mean, prior_sd, n_prior, z_score, pct_delta, severity
)
WITH unified AS (
    SELECT run_id, week_offset, 'LOAD'   AS metric_domain,
           stat_name       AS metric_name,
           per_sec         AS value
    FROM   awr_trend_load_profile
    WHERE  run_id = ~run_id
    AND    per_sec IS NOT NULL
    UNION ALL
    SELECT run_id, week_offset, 'METRIC',
           metric_name, avg_value
    FROM   awr_trend_sysmetric
    WHERE  run_id = ~run_id
    AND    avg_value IS NOT NULL
    UNION ALL
    SELECT w.run_id, w.week_offset, 'WAIT',
           'Wait class: ' || w.wait_class AS metric_name,
           -- per-second time-waited for this class over the window
           w.time_waited_us / NULLIF(
               (CAST(win.win_end_ts AS DATE) - CAST(win.win_start_ts AS DATE)) * 86400 * 1e6, 0)
           AS value
    FROM   awr_trend_waits w
    JOIN   awr_trend_windows win
        ON win.run_id = w.run_id AND win.week_offset = w.week_offset
    WHERE  w.run_id = ~run_id AND w.scope = 'CLASS'
),
pivoted AS (
    SELECT
        run_id, metric_domain, metric_name,
        MAX(CASE WHEN week_offset = 0 THEN value END) AS cur_val,
        AVG(CASE WHEN week_offset > 0 THEN value END) AS mu,
        STDDEV(CASE WHEN week_offset > 0 THEN value END) AS sd,
        COUNT(CASE WHEN week_offset > 0 THEN value END)  AS n
    FROM   unified
    GROUP BY run_id, metric_domain, metric_name
)
SELECT
    run_id, metric_domain, metric_name,
    cur_val,
    mu,
    sd,
    n,
    CASE
        WHEN cur_val IS NULL OR mu IS NULL THEN NULL
        WHEN sd IS NULL OR sd = 0 THEN NULL
        ELSE (cur_val - mu) / sd
    END AS z_score,
    CASE
        WHEN cur_val IS NULL OR mu IS NULL OR mu = 0 THEN NULL
        ELSE (cur_val - mu) / ABS(mu) * 100
    END AS pct_delta,
    CASE
        WHEN cur_val IS NULL THEN 'INSUFFICIENT_HISTORY'
        WHEN n < 3           THEN 'INSUFFICIENT_HISTORY'
        WHEN sd IS NULL OR sd = 0 THEN 'FLAT_BASELINE'
        WHEN ABS((cur_val - mu) / sd) > 3 THEN 'CRITICAL'
        WHEN ABS((cur_val - mu) / sd) > 2 THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM   pivoted
WHERE  cur_val IS NOT NULL OR mu IS NOT NULL;

COMMIT;

--
-- Mark the run OK.
--
UPDATE awr_trend_runs SET status = 'OK' WHERE run_id = ~run_id;
COMMIT;

--
-- Render the findings section.  This is emitted AFTER the detail sections
-- in the spool stream, but structurally it's placed inside a <section>
-- element whose id the <nav> at the top links to, so readers see it
-- prominently on scroll-to.  The findings page also prints ranked findings
-- grouped by severity for quick skimming.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_total      NUMBER;
    v_crit       NUMBER;
    v_warn       NUMBER;
    v_heat_json  CLOB;
    v_domains    VARCHAR2(200);
BEGIN
    SELECT COUNT(*), SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END),
                     SUM(CASE WHEN severity = 'WARN' THEN 1 ELSE 0 END)
    INTO   v_total, v_crit, v_warn
    FROM   awr_trend_findings WHERE run_id = ~run_id;

    DBMS_OUTPUT.PUT_LINE('<section id="findings"><h2>Findings summary &mdash; ' ||
        '<span class="badge crit">' || NVL(v_crit, 0) || ' critical</span> '  ||
        '<span class="badge warn">' || NVL(v_warn, 0) || ' warn</span> '      ||
        '<span class="badge ok">'   || v_total        || ' total</span></h2>');

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'z-score of the current window vs prior valid windows. '
        || '|z|&gt;3 = CRITICAL, |z|&gt;2 = WARN. '
        || 'INSUFFICIENT_HISTORY (n&lt;3) shows only %-delta. '
        || 'Heatmap below: |z| magnitude per (domain &times; metric); gray = no baseline.</p>');

    -- Findings heatmap container ------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="findings-heatmap"></div>');

    -- Build heatmap data: each finding as {x:metric, y:domain, z, sev}
    v_heat_json := NULL;
    FOR f IN (
        SELECT metric_domain, metric_name, z_score, severity,
               current_value, prior_mean, pct_delta
        FROM   awr_trend_findings
        WHERE  run_id = ~run_id
        ORDER BY metric_domain, ABS(NVL(z_score, 0)) DESC, metric_name
    ) LOOP
        v_heat_json := CASE WHEN v_heat_json IS NULL THEN '' ELSE v_heat_json || ',' END
            || '{"dom":"' || f.metric_domain
            || '","m":"' || REPLACE(REPLACE(f.metric_name, '\', '\\'), '"', '\"')
            || '","z":' || CASE WHEN f.z_score IS NULL THEN 'null'
                                ELSE TO_CHAR(f.z_score, 'FMS99990D00',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"sev":"' || f.severity
            || '","cur":' || CASE WHEN f.current_value IS NULL THEN 'null'
                                  ELSE TO_CHAR(f.current_value, 'FM99999999990D000000',
                                               'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"mu":' || CASE WHEN f.prior_mean IS NULL THEN 'null'
                                ELSE TO_CHAR(f.prior_mean, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"pct":' || CASE WHEN f.pct_delta IS NULL THEN 'null'
                                 ELSE TO_CHAR(f.pct_delta, 'FMS99990D0',
                                              'NLS_NUMERIC_CHARACTERS=''.,''') END
            || '}';
    END LOOP;

    IF v_heat_json IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<script>');
        DBMS_OUTPUT.PUT_LINE('(function(){');
        DBMS_OUTPUT.PUT_LINE('AWR_DATA.findings = [' || v_heat_json || '];');
        DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
        DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("findings-heatmap"); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('var raw=AWR_DATA.findings;');
        DBMS_OUTPUT.PUT_LINE('var doms=[],mets=[],domIdx={},metIdx={};');
        DBMS_OUTPUT.PUT_LINE('raw.forEach(function(f){if(!(f.dom in domIdx)){domIdx[f.dom]=doms.length;doms.push(f.dom);} if(!(f.m in metIdx)){metIdx[f.m]=mets.length;mets.push(f.m);}});');
        DBMS_OUTPUT.PUT_LINE('var data=raw.map(function(f){var zval=f.z==null?null:Math.abs(f.z);return {value:[metIdx[f.m],domIdx[f.dom],zval],raw:f};});');
        DBMS_OUTPUT.PUT_LINE('var maxAbs=3.5;');
        DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
        DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
        DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
        DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
        DBMS_OUTPUT.PUT_LINE('chart.setOption({');
        DBMS_OUTPUT.PUT_LINE('  tooltip:{formatter:function(p){var f=p.data.raw;var fmt=function(v){return v==null?"\u2014":(+v).toLocaleString(undefined,{maximumFractionDigits:3});};return "<b>"+f.m+"</b><br/>domain: "+f.dom+"<br/>severity: <b>"+f.sev+"</b><br/>current: "+fmt(f.cur)+"<br/>prior \u03BC: "+fmt(f.mu)+"<br/>z-score: "+(f.z==null?"\u2014":(+f.z).toFixed(2))+"<br/>% \u0394: "+(f.pct==null?"\u2014":f.pct+"%");}},');
        DBMS_OUTPUT.PUT_LINE('  grid:{left:10,right:10,top:30,bottom:70,containLabel:true},');
        DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:mets,axisLabel:{color:mu,rotate:55,fontSize:10,interval:0,formatter:function(v){return v.length>22?v.slice(0,22)+"\u2026":v;}},splitArea:{show:true}},');
        DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"category",data:doms,axisLabel:{color:fg,fontWeight:600},splitArea:{show:true}},');
        DBMS_OUTPUT.PUT_LINE('  visualMap:{min:0,max:maxAbs,calculable:true,orient:"horizontal",left:"center",bottom:8,itemWidth:12,itemHeight:160,textStyle:{color:mu,fontSize:10},inRange:{color:["#eaf6ea","#eef2ff","#fff4d6","#ffe5e5","#8a1c1c"]},text:["|z|\u22653","0"]},');
        DBMS_OUTPUT.PUT_LINE('  series:[{name:"|z|",type:"heatmap",data:data,label:{show:false},emphasis:{itemStyle:{borderColor:fg,borderWidth:1.5}}}]');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('chart.on("click",function(p){if(!p.data||!p.data.raw)return;var row=document.querySelector("tr[data-metric=\""+CSS.escape(p.data.raw.m)+"\"]");if(row){row.scrollIntoView({behavior:"smooth",block:"center"});row.style.transition="outline 1.5s";row.style.outline="2px solid "+cs.getPropertyValue("--accent");setTimeout(function(){row.style.outline="none";},1600);}});');
        DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
        DBMS_OUTPUT.PUT_LINE('})();');
        DBMS_OUTPUT.PUT_LINE('</script>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('<table>'
        || '<thead><tr>'
        || '<th>Severity</th>'
        || '<th>Domain</th>'
        || '<th>Metric</th>'
        || '<th class="num">Current</th>'
        || '<th class="num">Prior mean</th>'
        || '<th class="num">Prior sd</th>'
        || '<th class="num">n</th>'
        || '<th class="num">z-score</th>'
        || '<th class="num">% &Delta;</th>'
        || '</tr></thead><tbody>');

    FOR f IN (
        SELECT f.*,
               CASE severity
                   WHEN 'CRITICAL'             THEN 1
                   WHEN 'WARN'                 THEN 2
                   WHEN 'INSUFFICIENT_HISTORY' THEN 3
                   WHEN 'FLAT_BASELINE'        THEN 4
                   ELSE 5
               END AS sev_order
        FROM   awr_trend_findings f
        WHERE  f.run_id = ~run_id
        ORDER BY sev_order,
                 ABS(NVL(z_score, 0)) DESC,
                 ABS(NVL(pct_delta, 0)) DESC,
                 metric_name
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(
            '<tr data-metric="' || REPLACE(DBMS_XMLGEN.CONVERT(f.metric_name), '"', '&quot;') || '"'
            || ' class="' || CASE f.severity
                    WHEN 'CRITICAL' THEN 'crit'
                    WHEN 'WARN'     THEN 'warn'
                    WHEN 'OK'       THEN 'ok'
                    ELSE 'skip' END || '">'
            || '<td><span class="badge ' || CASE f.severity
                    WHEN 'CRITICAL' THEN 'crit'
                    WHEN 'WARN'     THEN 'warn'
                    WHEN 'OK'       THEN 'ok'
                    ELSE 'skip' END || '">' || f.severity || '</span></td>'
            || '<td>' || f.metric_domain || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(f.metric_name) || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.current_value IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.current_value, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.prior_mean IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.prior_mean, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.prior_sd IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.prior_sd, 'FM999G999G999G990D0000') END || '</td>'
            || '<td class="num">' || NVL(TO_CHAR(f.n_prior), '0') || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.z_score IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.z_score, 'FMS990D00') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.pct_delta IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.pct_delta, 'FMS990D0') || '%' END || '</td>'
            || '</tr>');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'All raw facts are persisted in the scratch schema '
        || '(AWR_TREND_RUNS / _WINDOWS / _LOAD_PROFILE / _SYSMETRIC / _WAITS / _TOP_SQL / _FINDINGS) '
        || 'keyed by run_id = ' || ~run_id || '. Query them for deeper analysis.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
