--
-- 04_waits_fg.sql
-- Foreground wait-event deltas from DBA_HIST_SYSTEM_EVENT.
-- The view stores CUMULATIVE counters per snapshot, so delta per window =
-- value_at_end_snap - value_at_begin_snap.  We filter out 'Idle' waits and
-- keep the top-N per window, plus one row per wait_class for the rollup.
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_us         NUMBER;
    v_us_s       VARCHAR2(64);
    v_rank       NUMBER;
    v_rank_s     VARCHAR2(64);
    v_weeks_json VARCHAR2(4000);
    v_class_json CLOB;
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';

    @@sql/lib/nth_csv.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="waits-fg"><h2>Foreground wait events (top '
        || v_top_n || ' by time waited)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Chart: wait-class time breakdown per ~period_unit_long (stacked). Table below: '
        || 'top-' || v_top_n || ' individual events, with a sparkline over the series.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-small" id="waits-fg-stack"></div>');

    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - (~step_hours/24)*week_offset, '~period_axis_fmt') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);

    v_class_json := NULL;
    FOR c IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        pairs AS (
            SELECT w.week_offset, se.wait_class, se.snap_id, se.instance_number,
                   se.total_waits, se.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_system_event se
                ON se.dbid = w.dbid
               AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND se.instance_number = w.instance_number
               AND se.wait_class <> 'Idle'
        ),
        bounds AS (
            SELECT week_offset, instance_number, wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, instance_number, wait_class
        ),
        class_deltas AS (
            SELECT week_offset, wait_class,
                   SUM(NVL(end_us, 0) - NVL(beg_us, 0)) AS time_waited_us
            FROM   bounds
            GROUP BY week_offset, wait_class
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        classes AS (
            SELECT DISTINCT wait_class FROM class_deltas WHERE time_waited_us > 0
        ),
        grid AS (
            SELECT c.wait_class, w.week_offset, cd.time_waited_us
            FROM   classes c
            CROSS JOIN all_weeks w
            LEFT JOIN class_deltas cd
                   ON cd.wait_class = c.wait_class AND cd.week_offset = w.week_offset
        )
        SELECT wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
               LISTAGG(
                   CASE WHEN time_waited_us IS NULL THEN 'null'
                        ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''')
                   END, ','
               ) WITHIN GROUP (ORDER BY week_offset DESC) AS vals_csv
        FROM   grid
        GROUP BY wait_class
        HAVING SUM(NVL(time_waited_us, 0)) > 0
        ORDER BY MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) DESC NULLS LAST,
                 wait_class
    ) LOOP
        v_class_json := CASE WHEN v_class_json IS NULL THEN '' ELSE v_class_json || ',' END
            || '{"name":"' || REPLACE(c.wait_class, '"', '\"')
            || '","vals":[' || c.vals_csv || ']}';
    END LOOP;

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

    DBMS_OUTPUT.PUT_LINE('<h3>Top ' || v_top_n || ' events by time waited</h3>');
    v_header := '<thead><tr><th>Event</th><th>Class</th><th class="trend">Trend</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || ' (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR e IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        pairs AS (
            SELECT w.week_offset, se.event_name, se.wait_class,
                   se.snap_id, se.instance_number,
                   se.total_waits, se.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_system_event se
                ON se.dbid = w.dbid
               AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND se.instance_number = w.instance_number
               AND se.wait_class <> 'Idle'
        ),
        bounds AS (
            SELECT week_offset, instance_number, event_name, wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, instance_number, event_name, wait_class
        ),
        deltas AS (
            SELECT week_offset, event_name, wait_class,
                   SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
                   SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
            FROM   bounds
            GROUP BY week_offset, event_name, wait_class
        ),
        ranked AS (
            SELECT d.*,
                   RANK() OVER (PARTITION BY week_offset ORDER BY time_waited_us DESC) AS rnk
            FROM   deltas d
            WHERE  time_waited_us > 0
        ),
        top_n_events AS (
            SELECT week_offset, event_name, wait_class, total_waits, time_waited_us, rnk
            FROM   ranked
            WHERE  rnk <= (SELECT top_n FROM run_params)
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        events AS (
            SELECT DISTINCT event_name, wait_class FROM top_n_events
        ),
        grid AS (
            SELECT e.event_name, e.wait_class, w.week_offset,
                   t.time_waited_us, t.rnk
            FROM   events e
            CROSS JOIN all_weeks w
            LEFT JOIN top_n_events t
                   ON t.event_name = e.event_name AND t.week_offset = w.week_offset
        )
        SELECT event_name, MAX(wait_class) AS wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
               MAX(CASE WHEN week_offset = 0 THEN rnk END)            AS cur_rnk,
               LISTAGG(CASE WHEN time_waited_us IS NULL THEN ''
                            ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS spark_vals,
               LISTAGG(CASE WHEN time_waited_us IS NULL THEN ''
                            ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset ASC) AS week_us_vals,
               LISTAGG(CASE WHEN rnk IS NULL THEN '' ELSE TO_CHAR(rnk) END, ',')
                   WITHIN GROUP (ORDER BY week_offset ASC) AS week_rnk_vals
        FROM   grid
        GROUP BY event_name
        ORDER BY
            CASE WHEN MAX(CASE WHEN week_offset = 0 THEN rnk END) IS NULL THEN 1 ELSE 0 END,
            MAX(CASE WHEN week_offset = 0 THEN rnk END) NULLS LAST,
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
            v_us_s   := nth_csv(e.week_us_vals,  k + 1);
            v_rank_s := nth_csv(e.week_rnk_vals, k + 1);
            IF v_us_s IS NULL OR v_us_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;';
            ELSE
                v_us := TO_NUMBER(v_us_s, 'FM99999999990D000000',
                                  'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_us, 'FM999G999G990D00');
            END IF;
            IF v_rank_s IS NOT NULL AND v_rank_s <> '' THEN
                v_row := v_row || ' <span class="badge skip">#' || v_rank_s || '</span>';
            END IF;
            v_row := v_row || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    DBMS_OUTPUT.PUT_LINE('<h3>Wait-class rollup</h3>');
    v_header := '<thead><tr><th>Wait class</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || ' (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR c IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        pairs AS (
            SELECT w.week_offset, se.wait_class,
                   se.snap_id, se.instance_number,
                   se.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_system_event se
                ON se.dbid = w.dbid
               AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND se.instance_number = w.instance_number
               AND se.wait_class <> 'Idle'
        ),
        bounds AS (
            SELECT week_offset, instance_number, wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, instance_number, wait_class
        ),
        class_deltas AS (
            SELECT week_offset, wait_class,
                   SUM(NVL(end_us, 0) - NVL(beg_us, 0)) AS time_waited_us
            FROM   bounds
            GROUP BY week_offset, wait_class
            HAVING SUM(NVL(end_us, 0) - NVL(beg_us, 0)) > 0
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        classes AS (
            SELECT DISTINCT wait_class FROM class_deltas
        ),
        grid AS (
            SELECT c.wait_class, w.week_offset, cd.time_waited_us
            FROM   classes c
            CROSS JOIN all_weeks w
            LEFT JOIN class_deltas cd
                   ON cd.wait_class = c.wait_class AND cd.week_offset = w.week_offset
        )
        SELECT wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
               LISTAGG(CASE WHEN time_waited_us IS NULL THEN ''
                            ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals
        FROM   grid
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
            v_us_s := nth_csv(c.week_vals, k + 1);
            IF v_us_s IS NULL OR v_us_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;</td>';
            ELSE
                v_us := TO_NUMBER(v_us_s, 'FM99999999990D000000',
                                  'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_us, 'FM999G999G990D00') || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
