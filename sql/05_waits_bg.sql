--
-- 05_waits_bg.sql
-- Background wait-event deltas from DBA_HIST_BG_EVENT_SUMMARY.
-- This view exposes per-snapshot cumulative wait counters for background
-- processes (DBWR, LGWR, ARCn, etc.) in 19c.  We compute end - begin, keep
-- the top-N per window, and render them as a pivot table.
-- Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_cnt        NUMBER;
    v_us         NUMBER;
    v_us_s       VARCHAR2(64);
    v_rank_s     VARCHAR2(64);
    v_weeks_json VARCHAR2(4000);
    v_class_json CLOB;
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';

    FUNCTION nth_csv(p_str VARCHAR2, p_n POSITIVE) RETURN VARCHAR2 IS
        v_start PLS_INTEGER := 1;
        v_end   PLS_INTEGER;
        v_cnt   PLS_INTEGER := 0;
    BEGIN
        IF p_str IS NULL OR p_n IS NULL OR p_n < 1 THEN
            RETURN NULL;
        END IF;
        LOOP
            v_end := INSTR(p_str, ',', v_start);
            v_cnt := v_cnt + 1;
            IF v_cnt = p_n THEN
                IF v_end = 0 THEN
                    RETURN SUBSTR(p_str, v_start);
                ELSE
                    RETURN SUBSTR(p_str, v_start, v_end - v_start);
                END IF;
            END IF;
            EXIT WHEN v_end = 0;
            v_start := v_end + 1;
        END LOOP;
        RETURN NULL;
    END nth_csv;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="waits-bg"><h2>Background wait events</h2>');

    SELECT COUNT(*)
    INTO   v_cnt
    FROM (
        WITH run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
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
                   bs.snap_id AS begin_snap_id, es.snap_id AS end_snap_id,
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
            SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
            FROM   windows WHERE valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.week_offset, bg.event_name, bg.wait_class,
                   bg.snap_id, bg.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_bg_event_summary bg
                ON bg.dbid = w.dbid
               AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR bg.instance_number = w.instance_number)
               AND NVL(bg.wait_class, 'Other') <> 'Idle'
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
        || 'Chart: wait-class time breakdown per ~period_unit_long (stacked). '
        || 'Table below: per-event with a sparkline over the series. '
        || 'From DBA_HIST_BG_EVENT_SUMMARY. Idle waits filtered out. Time in seconds.</p>');

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
        WITH run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
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
                   bs.snap_id AS begin_snap_id, es.snap_id AS end_snap_id,
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
            SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
            FROM   windows WHERE valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.week_offset, bg.event_name, NVL(bg.wait_class, 'Other') AS wait_class,
                   bg.snap_id, bg.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_bg_event_summary bg
                ON bg.dbid = w.dbid
               AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR bg.instance_number = w.instance_number)
               AND NVL(bg.wait_class, 'Other') <> 'Idle'
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

    v_header := '<thead><tr><th>Event</th><th>Class</th><th class="trend">Trend</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || '~period_unit_short (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR e IN (
        WITH run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours,
                   ~top_n      AS top_n
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
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
                   bs.snap_id AS begin_snap_id, es.snap_id AS end_snap_id,
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
            SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id
            FROM   windows WHERE valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.week_offset, bg.event_name, NVL(bg.wait_class, 'Other') AS wait_class,
                   bg.snap_id, bg.time_waited_micro,
                   w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_bg_event_summary bg
                ON bg.dbid = w.dbid
               AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR bg.instance_number = w.instance_number)
               AND NVL(bg.wait_class, 'Other') <> 'Idle'
        ),
        bounds AS (
            SELECT week_offset, event_name, wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY week_offset, event_name, wait_class
        ),
        deltas AS (
            SELECT week_offset, event_name, wait_class,
                   NVL(end_us, 0) - NVL(beg_us, 0) AS time_waited_us
            FROM   bounds
        ),
        ranked AS (
            SELECT d.*,
                   RANK() OVER (PARTITION BY week_offset ORDER BY time_waited_us DESC) AS rnk
            FROM   deltas d
            WHERE  time_waited_us > 0
        ),
        top_n_events AS (
            SELECT week_offset, event_name, wait_class, time_waited_us, rnk
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

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
