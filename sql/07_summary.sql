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

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
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

    v_heat_json := NULL;

    --
    -- One big cursor that recomputes LOAD / METRIC / WAIT values per
    -- (week_offset, metric) from the AWR views, then pivots to cur vs
    -- prior AVG/STDDEV and derives the change bucket.  The unified CTE is a union
    -- of three per-domain sub-CTEs that all sit on the same windows CTE.
    --
    FOR f IN (
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
        -- LOAD domain: DBA_HIST_SYSSTAT cumulative counters, per-sec deltas.
        load_targets AS (
            SELECT 'redo size'                              stat_name FROM dual UNION ALL
            SELECT 'redo size for lost write detection'               FROM dual UNION ALL
            SELECT 'DB time'                                          FROM dual UNION ALL
            SELECT 'DB CPU'                                           FROM dual UNION ALL
            SELECT 'CPU used by this session'                         FROM dual UNION ALL
            SELECT 'session logical reads'                            FROM dual UNION ALL
            SELECT 'physical reads'                                   FROM dual UNION ALL
            SELECT 'physical read total bytes'                        FROM dual UNION ALL
            SELECT 'physical writes'                                  FROM dual UNION ALL
            SELECT 'physical write total bytes'                       FROM dual UNION ALL
            SELECT 'user calls'                                       FROM dual UNION ALL
            SELECT 'user commits'                                     FROM dual UNION ALL
            SELECT 'user rollbacks'                                   FROM dual UNION ALL
            SELECT 'execute count'                                    FROM dual UNION ALL
            SELECT 'parse count (total)'                              FROM dual UNION ALL
            SELECT 'parse count (hard)'                               FROM dual UNION ALL
            SELECT 'parse count (failures)'                           FROM dual UNION ALL
            SELECT 'sorts (memory)'                                   FROM dual UNION ALL
            SELECT 'sorts (disk)'                                     FROM dual UNION ALL
            SELECT 'sorts (rows)'                                     FROM dual UNION ALL
            SELECT 'logons cumulative'                                FROM dual UNION ALL
            SELECT 'opened cursors cumulative'                        FROM dual UNION ALL
            SELECT 'redo writes'                                      FROM dual UNION ALL
            SELECT 'table scans (long tables)'                        FROM dual UNION ALL
            SELECT 'table fetch by rowid'                             FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'                 FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client'           FROM dual
        ),
        load_pairs AS (
            SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                   ss.snap_id, ss.value,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR ss.instance_number = w.instance_number)
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
        metric_targets AS (
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
        ),
        metric_rows AS (
            SELECT 'METRIC' AS metric_domain,
                   sm.metric_name,
                   w.week_offset,
                   AVG(sm.average) AS metric_value
            FROM   valid_windows w
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR sm.instance_number = w.instance_number)
               AND sm.metric_name IN (SELECT metric_name FROM metric_targets)
            GROUP BY w.week_offset, sm.metric_name
        ),
        -- WAIT domain: DBA_HIST_SYSTEM_EVENT time-waited per wait_class, as rate.
        -- Delta is per (event_name, instance); then summed into wait_class.
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
               AND (w.instance_number IS NULL OR se.instance_number = w.instance_number)
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
        )
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
        ORDER BY metric_domain, ABS(NVL(
                   CASE
                       WHEN cur_val IS NULL OR mu IS NULL THEN NULL
                       WHEN sd IS NULL OR sd = 0 THEN NULL
                       ELSE (cur_val - mu) / sd
                   END, 0)) DESC, metric_name
    ) LOOP
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
    -- Second pass: detail table ordered by change-bucket then |z|.
    -- Repeating the recompute CTE is the least-bad way to walk the findings
    -- twice without persisting them anywhere.
    --
    FOR f IN (
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
        load_targets AS (
            SELECT 'redo size'                              stat_name FROM dual UNION ALL
            SELECT 'redo size for lost write detection'               FROM dual UNION ALL
            SELECT 'DB time'                                          FROM dual UNION ALL
            SELECT 'DB CPU'                                           FROM dual UNION ALL
            SELECT 'CPU used by this session'                         FROM dual UNION ALL
            SELECT 'session logical reads'                            FROM dual UNION ALL
            SELECT 'physical reads'                                   FROM dual UNION ALL
            SELECT 'physical read total bytes'                        FROM dual UNION ALL
            SELECT 'physical writes'                                  FROM dual UNION ALL
            SELECT 'physical write total bytes'                       FROM dual UNION ALL
            SELECT 'user calls'                                       FROM dual UNION ALL
            SELECT 'user commits'                                     FROM dual UNION ALL
            SELECT 'user rollbacks'                                   FROM dual UNION ALL
            SELECT 'execute count'                                    FROM dual UNION ALL
            SELECT 'parse count (total)'                              FROM dual UNION ALL
            SELECT 'parse count (hard)'                               FROM dual UNION ALL
            SELECT 'parse count (failures)'                           FROM dual UNION ALL
            SELECT 'sorts (memory)'                                   FROM dual UNION ALL
            SELECT 'sorts (disk)'                                     FROM dual UNION ALL
            SELECT 'sorts (rows)'                                     FROM dual UNION ALL
            SELECT 'logons cumulative'                                FROM dual UNION ALL
            SELECT 'opened cursors cumulative'                        FROM dual UNION ALL
            SELECT 'redo writes'                                      FROM dual UNION ALL
            SELECT 'table scans (long tables)'                        FROM dual UNION ALL
            SELECT 'table fetch by rowid'                             FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'                 FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client'           FROM dual
        ),
        load_pairs AS (
            SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                   ss.snap_id, ss.value,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR ss.instance_number = w.instance_number)
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
        metric_targets AS (
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
        ),
        metric_rows AS (
            SELECT 'METRIC' AS metric_domain,
                   sm.metric_name,
                   w.week_offset,
                   AVG(sm.average) AS metric_value
            FROM   valid_windows w
            JOIN   dba_hist_sysmetric_summary sm
                ON sm.dbid = w.dbid
               AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR sm.instance_number = w.instance_number)
               AND sm.metric_name IN (SELECT metric_name FROM metric_targets)
            GROUP BY w.week_offset, sm.metric_name
        ),
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
               AND (w.instance_number IS NULL OR se.instance_number = w.instance_number)
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
        )
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket,
               CASE change_bucket
                   WHEN 'large'                THEN 1
                   WHEN 'moderate'             THEN 2
                   WHEN 'insufficient history' THEN 3
                   WHEN 'flat baseline'        THEN 4
                   ELSE 5
               END AS sev_order
        FROM   scored
        ORDER BY sev_order,
                 ABS(NVL(z_score, 0)) DESC,
                 ABS(NVL(pct_delta, 0)) DESC,
                 metric_name
    ) LOOP
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
