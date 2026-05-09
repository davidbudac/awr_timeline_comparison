--
-- 07_summary.sql
-- For every scalar metric rendered by sections 02-04, compute the z-score
-- of the current window against the mean/stddev of the prior valid windows,
-- bucket the change magnitude (large / moderate / typical) and render the
-- findings heatmap + detail table.  Buckets describe how far the current
-- value sits from its baseline of prior comparison windows; "large" is not
-- a value judgement, just a |z| > 3 outlier.
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- persist anything.
--
-- Implementation note: the same set of findings drives two views (the
-- heatmap and the detail table), each with a different ORDER BY.  We
-- BULK COLLECT the unified LOAD/METRIC/WAIT recompute exactly once into a
-- PL/SQL collection, attach both view positions via ROW_NUMBER(), and then
-- walk the collection twice -- first emitting the heatmap JSON in heatmap
-- order, then the table rows in detail-table order via an index array.
-- This keeps the (substantial) recompute single-pass while preserving the
-- two distinct sort orders the report expects.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    TYPE finding_rec IS RECORD (
        metric_domain  VARCHAR2(16),
        metric_name    VARCHAR2(120),
        cur_val        NUMBER,
        prior_mean     NUMBER,
        prior_sd       NUMBER,
        n_prior        NUMBER,
        z_score        NUMBER,
        pct_delta      NUMBER,
        change_bucket  VARCHAR2(40),
        heat_pos       NUMBER,
        table_pos      NUMBER
    );
    TYPE findings_t  IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    TYPE idx_t       IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;

    v_findings   findings_t;
    v_table_idx  idx_t;
    f            finding_rec;

    v_total      NUMBER := 0;
    v_crit       NUMBER := 0;
    v_warn       NUMBER := 0;
    v_heat_json  CLOB;
    v_row        VARCHAR2(32767);
    v_sev        VARCHAR2(40);
    v_cls        VARCHAR2(10);
    v_weeks_back NUMBER := ~weeks_back;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="findings"><h2 id="findings-heading">Findings summary</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'z-score of the current window vs prior valid windows. '
        || '|z|&gt;3 = large change, |z|&gt;2 = moderate change, otherwise typical. '
        || 'Insufficient history (n&lt;3) shows only %-delta. '
        || 'Heatmap below: |z| magnitude per (domain &times; metric); gray = no baseline.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="findings-heatmap"></div>');

    --
    -- Recompute LOAD / METRIC / WAIT values per (week_offset, metric) from
    -- the AWR views, pivot to cur vs prior AVG/STDDEV, derive the change
    -- bucket, and tag each row with both view positions via ROW_NUMBER.
    -- Bulk-collected once; both report views below iterate the collection.
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    -- LOAD domain: DBA_HIST_SYSSTAT cumulative counters, per-sec deltas.
    load_targets AS (
        @@sql/lib/sysstat_load_targets.sql
    ),
    load_pairs AS (
        SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
               ss.snap_id, ss.value,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_sysstat ss
            ON ss.dbid = w.dbid
           AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND ss.instance_number = w.instance_number
           AND ss.stat_name IN (SELECT stat_name FROM load_targets)
    ),
    load_bounds AS (
        SELECT week_offset, dur_sec, stat_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   load_pairs
        GROUP BY week_offset, dur_sec, stat_name, instance_number
    ),
    load_rows AS (
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / dur_sec
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, dur_sec, stat_name
    ),
    -- METRIC domain: DBA_HIST_SYSMETRIC_SUMMARY averages over window.
    -- Per-snap cluster value: SUM across instances for additive metrics,
    -- AVG for ratios. See sql/lib/sysmetric_targets.sql for the rationale.
    metric_targets AS (
        @@sql/lib/sysmetric_targets.sql
    ),
    metric_per_snap AS (
        SELECT w.week_offset, t.metric_name, sm.snap_id,
               t.is_additive,
               CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                             ELSE AVG(sm.average) END AS snap_value
        FROM   valid_windows w
        JOIN   metric_targets t ON 1 = 1
        JOIN   dba_hist_sysmetric_summary sm
            ON sm.dbid = w.dbid
           AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
           AND sm.instance_number = w.instance_number
           AND sm.metric_name = t.metric_name
        GROUP BY w.week_offset, t.metric_name, t.is_additive, sm.snap_id
    ),
    metric_rows AS (
        SELECT 'METRIC' AS metric_domain,
               metric_name,
               week_offset,
               AVG(snap_value) AS metric_value
        FROM   metric_per_snap
        GROUP BY week_offset, metric_name
    ),
    -- WAIT domain: DBA_HIST_SYSTEM_EVENT time-waited per wait_class, as rate.
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.event_name,
               se.snap_id,
               se.time_waited_micro,
               se.instance_number,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, event_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
    ),
    wait_rows AS (
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / dur_sec / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, dur_sec, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    ),
    pivoted AS (
        SELECT metric_domain, metric_name,
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)  AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)  AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END) AS n
        FROM   unified
        GROUP BY metric_domain, metric_name
    ),
    scored AS (
        SELECT metric_domain, metric_name,
               cur_val,
               mu       AS prior_mean,
               sd       AS prior_sd,
               n        AS n_prior,
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
                   WHEN cur_val IS NULL THEN 'insufficient history'
                   WHEN n < 3           THEN 'insufficient history'
                   WHEN sd IS NULL OR sd = 0 THEN 'flat baseline'
                   WHEN ABS((cur_val - mu) / sd) > 3 THEN 'large'
                   WHEN ABS((cur_val - mu) / sd) > 2 THEN 'moderate'
                   ELSE 'typical'
               END AS change_bucket
        FROM   pivoted
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    ),
    ranked AS (
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket,
               ROW_NUMBER() OVER (
                   ORDER BY metric_domain,
                            ABS(NVL(z_score, 0)) DESC,
                            metric_name) AS heat_pos,
               ROW_NUMBER() OVER (
                   ORDER BY CASE change_bucket
                                WHEN 'large'                THEN 1
                                WHEN 'moderate'             THEN 2
                                WHEN 'insufficient history' THEN 3
                                WHEN 'flat baseline'        THEN 4
                                ELSE 5
                            END,
                            ABS(NVL(z_score, 0)) DESC,
                            ABS(NVL(pct_delta, 0)) DESC,
                            metric_name) AS table_pos
        FROM   scored
    )
    SELECT metric_domain, metric_name,
           cur_val, prior_mean, prior_sd, n_prior,
           z_score, pct_delta, change_bucket,
           heat_pos, table_pos
    BULK COLLECT INTO v_findings
    FROM   ranked
    ORDER  BY heat_pos;

    --
    -- First pass: heatmap JSON + counters, in heatmap order
    -- (which is the bulk-collect order).  Also builds the index array
    -- that the second pass uses to walk in detail-table order.
    --
    v_heat_json := NULL;
    FOR i IN 1 .. v_findings.COUNT LOOP
        f := v_findings(i);
        v_total := v_total + 1;
        IF f.change_bucket = 'large'    THEN v_crit := v_crit + 1;
        ELSIF f.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
        END IF;

        v_heat_json := CASE WHEN v_heat_json IS NULL THEN '' ELSE v_heat_json || ',' END
            || '{"dom":"' || f.metric_domain
            || '","m":"' || REPLACE(REPLACE(f.metric_name, '\', '\\'), '"', '\"')
            || '","z":' || CASE WHEN f.z_score IS NULL THEN 'null'
                                ELSE TO_CHAR(f.z_score, 'FMS99990D00',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"sev":"' || f.change_bucket
            || '","cur":' || CASE WHEN f.cur_val IS NULL THEN 'null'
                                  ELSE TO_CHAR(f.cur_val, 'FM99999999990D000000',
                                               'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"mu":' || CASE WHEN f.prior_mean IS NULL THEN 'null'
                                ELSE TO_CHAR(f.prior_mean, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"sd":' || CASE WHEN f.prior_sd IS NULL THEN 'null'
                                ELSE TO_CHAR(f.prior_sd, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END
            || ',"n":' || NVL(TO_CHAR(f.n_prior), '0')
            || ',"pct":' || CASE WHEN f.pct_delta IS NULL THEN 'null'
                                 ELSE TO_CHAR(f.pct_delta, 'FMS99990D0',
                                              'NLS_NUMERIC_CHARACTERS=''.,''') END
            || '}';

        v_table_idx(f.table_pos) := i;
    END LOOP;

    -- Rewrite the heading now that we have the counters.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var h=document.getElementById("findings-heading");'
        || 'if(h)h.innerHTML=''Findings summary &mdash; '
        || '<span class="badge crit">' || v_crit || ' large</span> '
        || '<span class="badge warn">' || v_warn || ' moderate</span> '
        || '<span class="badge ok">'   || v_total || ' total</span>'';})();</script>');

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
        DBMS_OUTPUT.PUT_LINE('  tooltip:{formatter:function(p){var f=p.data.raw;var fmt=function(v){return v==null?"\u2014":(+v).toLocaleString(undefined,{maximumFractionDigits:3});};return "<b>"+f.m+"</b><br/>domain: "+f.dom+"<br/>change: <b>"+f.sev+"</b><br/>current: "+fmt(f.cur)+"<br/>prior \u03BC: "+fmt(f.mu)+"<br/>z-score: "+(f.z==null?"\u2014":(+f.z).toFixed(2))+"<br/>% \u0394: "+(f.pct==null?"\u2014":f.pct+"%");}},');
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
        || '<th>Change</th>'
        || '<th>Domain</th>'
        || '<th>Metric</th>'
        || '<th class="num">Current</th>'
        || '<th class="num">Prior mean</th>'
        || '<th class="num">Prior sd</th>'
        || '<th class="num">n</th>'
        || '<th class="num">z-score</th>'
        || '<th class="num">% &Delta;</th>'
        || '</tr></thead><tbody>');

    --
    -- Second pass: detail table ordered by sev / |z| / |pct| / name.
    -- v_table_idx[p] -> index in v_findings, populated above.
    --
    FOR p IN 1 .. v_table_idx.COUNT LOOP
        f := v_findings(v_table_idx(p));
        v_sev := f.change_bucket;
        v_cls := CASE v_sev WHEN 'large'    THEN 'crit'
                            WHEN 'moderate' THEN 'warn'
                            WHEN 'typical'  THEN 'ok'
                            ELSE 'skip' END;

        v_row := '<tr data-metric="'
            || REPLACE(DBMS_XMLGEN.CONVERT(f.metric_name), '"', '&quot;')
            || '" class="' || v_cls || '">'
            || '<td><span class="badge ' || v_cls || '">' || v_sev || '</span></td>'
            || '<td>' || f.metric_domain || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(f.metric_name) || '</td>'
            || '<td class="num">' ||
                CASE WHEN f.cur_val IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(f.cur_val, 'FM999G999G999G990D0000') END || '</td>'
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
            || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'This run is read-only: nothing is persisted. '
        || 'Re-run <code>awr_trend.sql</code> to refresh.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
