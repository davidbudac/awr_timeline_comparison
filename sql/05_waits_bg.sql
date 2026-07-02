--
-- 05_waits_bg.sql
-- Background wait-event deltas from DBA_HIST_BG_EVENT_SUMMARY.
-- This view exposes per-snapshot cumulative wait counters for background
-- processes (DBWR, LGWR, ARCn, etc.) in 19c.  We compute end - begin, keep
-- the top-N per window, and render two tables: total time waited (s) and
-- average time per wait (ms = time_waited_us / total_waits / 1000).
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 05_waits_bg BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_cnt        NUMBER;
    v_us         NUMBER;
    v_us_s       VARCHAR2(64);
    v_ms         NUMBER;
    v_ms_s       VARCHAR2(64);
    v_rank_s     VARCHAR2(64);
    v_weeks_json VARCHAR2(4000);
    v_class_json CLOB;
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';

    TYPE t_evt_rec IS RECORD (
        event_name      VARCHAR2(64),
        wait_class      VARCHAR2(64),
        cur_us          NUMBER,
        cur_ms          NUMBER,
        cur_rnk         NUMBER,
        mu_us           NUMBER,
        sd_us           NUMBER,
        n_us            NUMBER,
        mu_ms           NUMBER,
        sd_ms           NUMBER,
        n_ms            NUMBER,
        spark_vals      VARCHAR2(4000),
        spark_ms_vals   VARCHAR2(4000),
        week_us_vals    VARCHAR2(4000),
        week_ms_vals    VARCHAR2(4000),
        week_rnk_vals   VARCHAR2(4000)
    );
    TYPE t_evt_tab IS TABLE OF t_evt_rec;
    v_evts t_evt_tab;

    @@sql/lib/nth_csv.plsql
    @@sql/lib/score_cells.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="waits-bg"><h2>Background wait events</h2>');

    SELECT COUNT(*)
    INTO   v_cnt
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        wait_targets AS (
            @@~template_dir/wait_event_targets.sql
        ),
        pairs AS (
            SELECT w.week_offset, bg.event_name, bg.wait_class,
                   bg.snap_id, bg.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_bg_event_summary bg
                ON bg.dbid = w.dbid
               AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND bg.instance_number = w.instance_number
               AND NVL(bg.wait_class, 'Other') <> 'Idle'
               AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                     OR bg.event_name IN (SELECT event_name FROM wait_targets) )
        ),
        bounds AS (
            SELECT week_offset, event_name,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, event_name
        )
        SELECT 1 FROM bounds
        WHERE NVL(end_us, 0) - NVL(beg_us, 0) > 0
    );

    IF v_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No background wait activity captured in DBA_HIST_BG_EVENT_SUMMARY for any valid window.</p>');
        DBMS_OUTPUT.PUT_LINE('</section>');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'DBA_HIST_BG_EVENT_SUMMARY, Idle excluded. '
        || 'Chart stacks wait_class time per window. '
        || 'Tables: time_waited (s) and avg latency '
        || '(ms = time_waited &divide; total_waits).</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-small" id="waits-bg-stack"></div>');

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
        wait_targets AS (
            @@~template_dir/wait_event_targets.sql
        ),
        pairs AS (
            SELECT w.week_offset, bg.event_name, NVL(bg.wait_class, 'Other') AS wait_class,
                   bg.snap_id, bg.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_bg_event_summary bg
                ON bg.dbid = w.dbid
               AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND bg.instance_number = w.instance_number
               AND NVL(bg.wait_class, 'Other') <> 'Idle'
               AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                     OR bg.event_name IN (SELECT event_name FROM wait_targets) )
        ),
        bounds AS (
            SELECT week_offset, event_name, wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, event_name, wait_class
        ),
        evt_deltas AS (
            SELECT week_offset, event_name, wait_class,
                   NVL(end_us, 0) - NVL(beg_us, 0) AS time_waited_us
            FROM   bounds
        ),
        class_deltas AS (
            SELECT week_offset, wait_class,
                   SUM(time_waited_us) AS time_waited_us
            FROM   evt_deltas
            WHERE  time_waited_us > 0
            GROUP BY week_offset, wait_class
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
               LISTAGG(CASE WHEN time_waited_us IS NULL THEN 'null'
                            ELSE TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''')
                       END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS vals_csv,
               MAX(time_waited_us) AS max_us
        FROM   grid
        GROUP BY wait_class
        HAVING SUM(NVL(time_waited_us, 0)) > 0
        ORDER BY MAX(time_waited_us) DESC NULLS LAST, wait_class
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

    -- ===============================================================
    -- Events: collect once, render two tables (s) and (ms/wait)
    -- ===============================================================
    WITH
    @@sql/lib/windows_cte.sql
    ,
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    pairs AS (
        SELECT w.week_offset, bg.event_name, NVL(bg.wait_class, 'Other') AS wait_class,
               bg.snap_id, bg.total_waits, bg.time_waited_micro,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_bg_event_summary bg
            ON bg.dbid = w.dbid
           AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND bg.instance_number = w.instance_number
           AND NVL(bg.wait_class, 'Other') <> 'Idle'
           AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                 OR bg.event_name IN (SELECT event_name FROM wait_targets) )
    ),
    bounds AS (
        SELECT week_offset, event_name, wait_class,
               SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
               SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   pairs
        GROUP BY week_offset, event_name, wait_class
    ),
    deltas AS (
        SELECT week_offset, event_name, wait_class,
               NVL(end_waits, 0) - NVL(beg_waits, 0) AS total_waits,
               NVL(end_us,    0) - NVL(beg_us,    0) AS time_waited_us
        FROM   bounds
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
               t.time_waited_us, t.total_waits, t.rnk
        FROM   events e
        CROSS JOIN all_weeks w
        LEFT JOIN top_n_events t
               ON t.event_name = e.event_name AND t.week_offset = w.week_offset
    )
    SELECT event_name,
           MAX(wait_class) AS wait_class,
           MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
           MAX(CASE WHEN week_offset = 0
                     AND NVL(total_waits, 0) > 0
                     THEN time_waited_us / total_waits / 1000 END) AS cur_ms,
           MAX(CASE WHEN week_offset = 0 THEN rnk END) AS cur_rnk,
           -- Prior-window stats for the scoring mechanism mirroring
           -- sql/07_summary.sql. Two-step: time waited (us) baseline for
           -- the (s) table, avg-per-wait (ms) baseline for the (ms) table.
           AVG(CASE WHEN week_offset > 0 THEN time_waited_us END)    AS mu_us,
           STDDEV(CASE WHEN week_offset > 0 THEN time_waited_us END) AS sd_us,
           COUNT(CASE WHEN week_offset > 0 AND time_waited_us IS NOT NULL
                      THEN 1 END)                                     AS n_us,
           AVG(CASE WHEN week_offset > 0 AND NVL(total_waits, 0) > 0
                    THEN time_waited_us / total_waits / 1000 END)    AS mu_ms,
           STDDEV(CASE WHEN week_offset > 0 AND NVL(total_waits, 0) > 0
                       THEN time_waited_us / total_waits / 1000 END) AS sd_ms,
           COUNT(CASE WHEN week_offset > 0 AND NVL(total_waits, 0) > 0
                       AND time_waited_us IS NOT NULL
                      THEN 1 END)                                     AS n_ms,
           -- ','||token + SUBSTR: LISTAGG drops NULL measures (and their
           -- delimiter), which would left-compact the CSV and misalign the
           -- positional slots; ','||NULL = ',' keeps the empty slot.
           SUBSTR(LISTAGG(',' || TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,'''))
               WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_vals,
           SUBSTR(LISTAGG(',' || CASE WHEN NVL(total_waits, 0) = 0 THEN NULL
                        ELSE TO_CHAR(time_waited_us/total_waits/1000,
                                     'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''') END)
               WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_ms_vals,
           SUBSTR(LISTAGG(',' || TO_CHAR(time_waited_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,'''))
               WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_us_vals,
           SUBSTR(LISTAGG(',' || CASE WHEN NVL(total_waits, 0) = 0 THEN NULL
                        ELSE TO_CHAR(time_waited_us/total_waits/1000,
                                     'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''') END)
               WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_ms_vals,
           SUBSTR(LISTAGG(',' || TO_CHAR(rnk))
               WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_rnk_vals
    BULK COLLECT INTO v_evts
    FROM   grid
    GROUP BY event_name
    ORDER BY
        CASE WHEN MAX(CASE WHEN week_offset = 0 THEN rnk END) IS NULL THEN 1 ELSE 0 END,
        MAX(CASE WHEN week_offset = 0 THEN rnk END) NULLS LAST,
        MAX(time_waited_us) DESC;

    -- Table A: total time waited (s)
    DBMS_OUTPUT.PUT_LINE('<h3>Events &mdash; time waited (s)</h3>');
    v_header := '<thead><tr><th>Event</th><th class="trend">Trend</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || ' (s)</th>';
    END LOOP;
    v_header := v_header || '<th>Change</th><th class="num">z-score</th>'
                         || '<th class="num">% &Delta;</th></tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR i IN 1 .. NVL(v_evts.COUNT, 0) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(v_evts(i).event_name) || '</td>'
            || '<td class="trend" data-spark="' || NVL(v_evts(i).spark_vals, '')
            || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(v_evts(i).event_name) || '"></td>'
            || '<td class="num"><b>' ||
                CASE WHEN v_evts(i).cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_evts(i).cur_us/1e6, 'FM999G999G990D00') END
            || CASE WHEN v_evts(i).cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || v_evts(i).cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_us_s   := nth_csv(v_evts(i).week_us_vals,  k + 1);
            v_rank_s := nth_csv(v_evts(i).week_rnk_vals, k + 1);
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
        v_row := v_row || score_cells(v_evts(i).cur_us,
                                       v_evts(i).mu_us,
                                       v_evts(i).sd_us,
                                       v_evts(i).n_us);
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    -- Table B: avg time per wait (ms)
    DBMS_OUTPUT.PUT_LINE('<h3>Events &mdash; avg time per wait (ms)</h3>');
    v_header := '<thead><tr><th>Event</th><th class="trend">Trend</th><th class="num">Current (ms)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || ' (ms)</th>';
    END LOOP;
    v_header := v_header || '<th>Change</th><th class="num">z-score</th>'
                         || '<th class="num">% &Delta;</th></tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR i IN 1 .. NVL(v_evts.COUNT, 0) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(v_evts(i).event_name) || '</td>'
            || '<td class="trend" data-spark="' || NVL(v_evts(i).spark_ms_vals, '')
            || '" data-spark-title="' || DBMS_XMLGEN.CONVERT(v_evts(i).event_name) || '"></td>'
            || '<td class="num"><b>' ||
                CASE WHEN v_evts(i).cur_ms IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_evts(i).cur_ms, 'FM999G999G990D00') END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_ms_s := nth_csv(v_evts(i).week_ms_vals, k + 1);
            IF v_ms_s IS NULL OR v_ms_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;</td>';
            ELSE
                v_ms := TO_NUMBER(v_ms_s, 'FM99999999990D000000',
                                  'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_ms, 'FM999G999G990D00') || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || score_cells(v_evts(i).cur_ms,
                                       v_evts(i).mu_ms,
                                       v_evts(i).sd_ms,
                                       v_evts(i).n_ms);
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 05_waits_bg END -->'); END;
/
