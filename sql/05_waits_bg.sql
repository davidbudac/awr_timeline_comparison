--
-- 05_waits_bg.sql
-- Background wait-event deltas from DBA_HIST_BG_EVENT_SUMMARY.
-- This view exposes per-snapshot cumulative wait counters for background
-- processes (DBWR, LGWR, ARCn, etc.) in 19c.  We compute end - begin, keep
-- the top-N per window, and render them as a pivot table.
--

SET DEFINE '~'

INSERT INTO awr_trend_waits (run_id, week_offset, scope, event_name, wait_class,
                             total_waits, time_waited_us, avg_wait_ms, rank_in_window)
WITH run AS (
    SELECT run_id, dbid, instance_number, top_n
    FROM   awr_trend_runs WHERE run_id = ~run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id AND valid_flag = 'Y'
),
pairs AS (
    SELECT
        w.run_id, w.week_offset,
        bg.event_name,
        bg.wait_class,
        bg.snap_id,
        bg.total_waits,
        bg.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_bg_event_summary bg
        ON bg.dbid = r.dbid
       AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR bg.instance_number = r.instance_number)
       AND NVL(bg.wait_class, 'Other') <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, event_name, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END) AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END) AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, event_name, wait_class
),
deltas AS (
    SELECT run_id, week_offset, event_name, wait_class,
           NVL(end_waits, 0) - NVL(beg_waits, 0) AS total_waits,
           NVL(end_us,    0) - NVL(beg_us,    0) AS time_waited_us
    FROM   bounds
),
ranked AS (
    SELECT d.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   deltas d
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'BG', event_name, wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
       rnk
FROM   ranked
WHERE  rnk <= (SELECT top_n FROM run);

COMMIT;

--
-- Render.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_cnt        NUMBER;
    v_us         NUMBER;
    v_rank       NUMBER;
    v_weeks_json VARCHAR2(4000);
    v_class_json CLOB;
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = ~run_id;
    SELECT COUNT(*) INTO v_cnt FROM awr_trend_waits WHERE run_id = ~run_id AND scope = 'BG';

    DBMS_OUTPUT.PUT_LINE('<section id="waits-bg"><h2>Background wait events</h2>');

    IF v_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No background wait activity captured in DBA_HIST_BG_EVENT_SUMMARY for any valid window.</p>');
        DBMS_OUTPUT.PUT_LINE('</section>');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Chart: wait-class time breakdown per week (stacked). '
        || 'Table below: per-event with a sparkline over the series. '
        || 'From DBA_HIST_BG_EVENT_SUMMARY. Idle waits filtered out. Time in seconds.</p>');

    -- Stacked bar chart container ----------------------------------------
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-small" id="waits-bg-stack"></div>');

    SELECT '['
        || LISTAGG('"' || TO_CHAR(win_end_ts, 'Mon DD') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id;

    -- Build one JSON object per BG wait-class across all weeks (NULL = null).
    -- Aggregated from awr_trend_waits (scope='BG') because BG doesn't have a
    -- separate CLASS rollup; sum per wait_class over events in each week.
    v_class_json := NULL;
    FOR c IN (
        SELECT w.wait_class,
               LISTAGG(
                   CASE WHEN w.time_waited_us IS NULL THEN 'null'
                        ELSE TO_CHAR(w.time_waited_us/1e6, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''')
                   END, ','
               ) WITHIN GROUP (ORDER BY w.week_offset DESC) AS vals_csv
        FROM (
            SELECT win.week_offset,
                   NVL(aw.wait_class, 'Other') AS wait_class,
                   SUM(aw.time_waited_us) AS time_waited_us
            FROM   awr_trend_windows win
            LEFT JOIN awr_trend_waits aw
                   ON aw.run_id = win.run_id
                  AND aw.week_offset = win.week_offset
                  AND aw.scope = 'BG'
            WHERE  win.run_id = ~run_id
            GROUP BY win.week_offset, NVL(aw.wait_class, 'Other')
        ) w
        GROUP BY w.wait_class
        HAVING SUM(NVL(w.time_waited_us, 0)) > 0
        ORDER BY MAX(CASE WHEN 1=1 THEN w.time_waited_us END) DESC NULLS LAST,
                 w.wait_class
    ) LOOP
        v_class_json := CASE WHEN v_class_json IS NULL THEN '' ELSE v_class_json || ',' END
            || '{"name":"' || REPLACE(c.wait_class, '"', '\"')
            || '","vals":[' || c.vals_csv || ']}';
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.waitsBg = {weeks:' || v_weeks_json
        || ',classes:[' || NVL(v_class_json, '') || ']};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("waits-bg-stack"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.waitsBg, palette=' || v_palette || ';');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"shadow"},valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(2)+"s";}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:60,right:16,top:10,bottom:42,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"value",axisLabel:{color:mu,formatter:"{value}s"},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"category",data:d.weeks,axisLabel:{color:fg,fontWeight:600}},');
    DBMS_OUTPUT.PUT_LINE('  series:d.classes.map(function(c,i){return {name:c.name,type:"bar",stack:"total",barWidth:"55%",emphasis:{focus:"series"},itemStyle:{color:palette[i%palette.length]},data:c.vals.map(function(v){return v==null?0:v;})};})');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- Per-event pivot table with sparkline column -------------------------
    v_header := '<thead><tr><th>Event</th><th>Class</th><th class="trend">Trend</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR e IN (
        WITH all_weeks AS (
            SELECT week_offset FROM awr_trend_windows WHERE run_id = ~run_id
        ),
        events AS (
            SELECT DISTINCT event_name, wait_class
            FROM   awr_trend_waits
            WHERE  run_id = ~run_id AND scope = 'BG'
        ),
        grid AS (
            SELECT e.event_name, e.wait_class, w.week_offset,
                   aw.time_waited_us, aw.rank_in_window
            FROM   events e
            CROSS JOIN all_weeks w
            LEFT JOIN awr_trend_waits aw
                   ON aw.run_id = ~run_id AND aw.scope = 'BG'
                  AND aw.event_name = e.event_name AND aw.week_offset = w.week_offset
        )
        SELECT event_name, MAX(wait_class) AS wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END)   AS cur_us,
               MAX(CASE WHEN week_offset = 0 THEN rank_in_window END)   AS cur_rnk,
               LISTAGG(CASE WHEN time_waited_us IS NULL THEN ''
                            ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS spark_vals
        FROM   grid
        GROUP BY event_name
        ORDER BY
            CASE WHEN MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) IS NULL THEN 1 ELSE 0 END,
            MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) NULLS LAST,
            MAX(time_waited_us) DESC
    ) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(e.event_name) || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(e.wait_class, '')) || '</td>'
            || '<td class="trend" data-spark="' || NVL(e.spark_vals, '')
            || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(e.event_name) || '"></td>'
            || '<td class="num"><b>' ||
                CASE WHEN e.cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(e.cur_us/1e6, 'FM999G999G990D00') END
            || CASE WHEN e.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || e.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(time_waited_us), MAX(rank_in_window)
            INTO   v_us, v_rank
            FROM   awr_trend_waits
            WHERE  run_id = ~run_id AND scope = 'BG'
            AND    event_name = e.event_name AND week_offset = k;

            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_us/1e6, 'FM999G999G990D00') END
                || CASE WHEN v_rank IS NOT NULL
                    THEN ' <span class="badge skip">#' || v_rank || '</span>' ELSE '' END
                || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
