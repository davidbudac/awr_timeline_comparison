--
-- 04_waits_fg.sql
-- Foreground wait-event deltas from DBA_HIST_SYSTEM_EVENT.
-- The view stores CUMULATIVE counters per snapshot, so delta per window =
-- value_at_end_snap - value_at_begin_snap.  We filter out 'Idle' waits and
-- keep the top-N per window, plus one row per wait_class for the rollup.
--

SET DEFINE '~'

--
-- Per-event FG deltas (TOP-N per window).
--
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
        se.event_name, se.wait_class,
        se.snap_id, se.instance_number,
        se.total_waits,
        se.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_system_event se
        ON se.dbid = r.dbid
       AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
       AND se.wait_class <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, instance_number, event_name, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, instance_number, event_name, wait_class
),
deltas AS (
    -- Aggregate across instances for scope=ALL, or flat-through for scope=INSTANCE.
    SELECT run_id, week_offset, event_name, wait_class,
           SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
           SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
    FROM   bounds
    GROUP BY run_id, week_offset, event_name, wait_class
),
ranked AS (
    SELECT d.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   deltas d
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'FG', event_name, wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
       rnk
FROM   ranked
WHERE  rnk <= (SELECT top_n FROM run);

--
-- Wait-class rollup (scope='CLASS'), ALL non-Idle classes.
--
INSERT INTO awr_trend_waits (run_id, week_offset, scope, event_name, wait_class,
                             total_waits, time_waited_us, avg_wait_ms, rank_in_window)
WITH run AS (
    SELECT run_id, dbid, instance_number FROM awr_trend_runs WHERE run_id = ~run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows WHERE run_id = ~run_id AND valid_flag = 'Y'
),
pairs AS (
    SELECT
        w.run_id, w.week_offset,
        se.wait_class, se.snap_id, se.instance_number,
        se.total_waits, se.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_system_event se
        ON se.dbid = r.dbid
       AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
       AND se.wait_class <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, instance_number, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, instance_number, wait_class
),
class_deltas AS (
    SELECT run_id, week_offset, wait_class,
           SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
           SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
    FROM   bounds
    GROUP BY run_id, week_offset, wait_class
),
ranked AS (
    SELECT c.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   class_deltas c
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'CLASS',
       wait_class AS event_name,
       wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END,
       rnk
FROM   ranked;

COMMIT;

--
-- Render the FG waits table: columns = current + each prior week.  Rows =
-- distinct event names that appeared in at least one window's top-N.
-- Additionally a wait-class rollup table below.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER;
    v_top_n      NUMBER;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_us         NUMBER;
    v_rank       NUMBER;
    v_weeks_json VARCHAR2(4000);
    v_class_json CLOB;
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
BEGIN
    SELECT weeks_back, top_n INTO v_weeks_back, v_top_n
    FROM   awr_trend_runs WHERE run_id = ~run_id;

    DBMS_OUTPUT.PUT_LINE('<section id="waits-fg"><h2>Foreground wait events (top '
        || v_top_n || ' by time waited)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Chart: wait-class time breakdown per week (stacked). Table below: '
        || 'top-' || v_top_n || ' individual events, with a sparkline over the series.</p>');

    -- Wait-class stacked bar chart container -------------------------------
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-small" id="waits-fg-stack"></div>');

    -- Build weeks[] (oldest -> newest, "Mon DD")
    SELECT '['
        || LISTAGG('"' || TO_CHAR(win_end_ts, 'Mon DD') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id;

    -- Build one JSON object per wait-class: { name, vals:[oldest..newest] }.
    -- For windows where time_waited is NULL (invalid or missing) we emit null.
    -- Ordered by current-week time_waited DESC so the biggest class is on top.
    v_class_json := NULL;
    FOR c IN (
        SELECT w.wait_class,
               MAX(CASE WHEN w.week_offset = 0 THEN w.time_waited_us END) AS cur_us,
               LISTAGG(
                   CASE WHEN w.time_waited_us IS NULL THEN 'null'
                        ELSE TO_CHAR(w.time_waited_us/1e6, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''')
                   END, ','
               ) WITHIN GROUP (ORDER BY w.week_offset DESC) AS vals_csv
        FROM (
            -- Join waits to all windows so missing weeks show up as nulls.
            SELECT win.run_id, win.week_offset, aw.wait_class, aw.time_waited_us
            FROM   awr_trend_windows win
            LEFT JOIN awr_trend_waits aw
                   ON aw.run_id = win.run_id
                  AND aw.week_offset = win.week_offset
                  AND aw.scope = 'CLASS'
            WHERE  win.run_id = ~run_id
        ) w
        WHERE  w.wait_class IS NOT NULL
        GROUP BY w.wait_class
        HAVING SUM(NVL(w.time_waited_us, 0)) > 0
        ORDER BY MAX(CASE WHEN w.week_offset = 0 THEN w.time_waited_us END) DESC NULLS LAST,
                 w.wait_class
    ) LOOP
        v_class_json := CASE WHEN v_class_json IS NULL THEN '' ELSE v_class_json || ',' END
            || '{"name":"' || REPLACE(c.wait_class, '"', '\"')
            || '","vals":[' || c.vals_csv || ']}';
    END LOOP;

    -- Emit the data + chart initializer ------------------------------------
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.waitsFg = {weeks:' || v_weeks_json
        || ',classes:[' || NVL(v_class_json, '') || ']};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("waits-fg-stack"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.waitsFg, palette=' || v_palette || ';');
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

    -- Per-event pivot table ------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<h3>Top ' || v_top_n || ' events by time waited</h3>');
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
            WHERE  run_id = ~run_id AND scope = 'FG'
        ),
        grid AS (
            SELECT e.event_name, e.wait_class, w.week_offset, aw.time_waited_us, aw.rank_in_window
            FROM   events e
            CROSS JOIN all_weeks w
            LEFT JOIN awr_trend_waits aw
                   ON aw.run_id = ~run_id AND aw.scope = 'FG'
                  AND aw.event_name = e.event_name AND aw.week_offset = w.week_offset
        )
        SELECT event_name, MAX(wait_class) AS wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
               MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) AS cur_rnk,
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
            WHERE  run_id = ~run_id AND scope = 'FG'
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
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    -- Wait-class rollup ----------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<h3>Wait-class rollup</h3>');
    v_header := '<thead><tr><th>Wait class</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR c IN (
        SELECT wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us
        FROM   awr_trend_waits
        WHERE  run_id = ~run_id AND scope = 'CLASS'
        GROUP BY wait_class
        ORDER BY MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) DESC NULLS LAST
    ) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(c.wait_class) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN c.cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(c.cur_us/1e6, 'FM999G999G990D00') END
            || '</b></td>';
        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(time_waited_us)
            INTO   v_us
            FROM   awr_trend_waits
            WHERE  run_id = ~run_id AND scope = 'CLASS'
            AND    wait_class = c.wait_class AND week_offset = k;
            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_us/1e6, 'FM999G999G990D00') END || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
