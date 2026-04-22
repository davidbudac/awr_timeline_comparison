--
-- 09_ash_timeline.sql
-- Hourly Active-Session timeline from DBA_HIST_ACTIVE_SESS_HISTORY, stacked
-- by wait_class (ON-CPU rows bucketed as 'CPU', Idle waits excluded).
-- Spans from (target_end - weeks_back*7 days - win_hours) up to target_end,
-- so every compared window is covered in context. Renders below the
-- Headline metrics (hero strip) via flexbox order.
--
-- ASH persists 1 in 10 in-memory samples, i.e. one row per session per 10s,
-- so an hour of one fully-busy session is 360 rows and AAS = samples / 360.
--
-- Follows the compute -> insert -> render contract used by every other
-- numbered section. Reads only; no findings/z-score interaction.
--

SET DEFINE '~'

--
-- Compute + persist: one row per (hour_bucket, wait_class) with a non-zero
-- sample_count. Missing (hour, class) pairs are treated as 0 by the render
-- layer so the stacked area stays intact.
--
INSERT INTO awr_trend_ash_timeline (run_id, hour_bucket, wait_class,
                                    sample_count, active_sessions)
WITH run AS (
    SELECT run_id, dbid, instance_number, target_end_ts, win_hours, weeks_back
    FROM   awr_trend_runs
    WHERE  run_id = ~run_id
),
rng AS (
    SELECT run_id, dbid, instance_number,
           CAST(target_end_ts AS DATE) - weeks_back*7 - win_hours/24 AS range_start_dt,
           CAST(target_end_ts AS DATE)                               AS range_end_dt
    FROM   run
),
samples AS (
    SELECT
        CAST(TRUNC(CAST(ash.sample_time AS DATE), 'HH') AS TIMESTAMP) AS hour_bucket,
        CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
             ELSE NVL(ash.wait_class, 'Other') END                    AS wait_class
    FROM   rng r
    JOIN   dba_hist_active_sess_history ash
      ON   ash.dbid = r.dbid
     AND   (r.instance_number IS NULL OR ash.instance_number = r.instance_number)
     AND   ash.sample_time >= CAST(r.range_start_dt AS TIMESTAMP)
     AND   ash.sample_time <  CAST(r.range_end_dt   AS TIMESTAMP)
     AND   (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
)
SELECT ~run_id,
       hour_bucket,
       wait_class,
       COUNT(*)         AS sample_count,
       COUNT(*) / 360   AS active_sessions
FROM   samples
GROUP  BY hour_bucket, wait_class;

COMMIT;

--
-- Render: stacked area chart.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_range_start  DATE;
    v_range_end    DATE;
    v_total_hours  NUMBER;
    -- PL/SQL VARCHAR2 goes up to 32767 bytes regardless of MAX_STRING_SIZE.
    -- Enough for about 2000 hours of CSV values; LISTAGG in SQL would cap at 4000.
    v_hours_json   VARCHAR2(32767);
    v_class_vals   VARCHAR2(32767);
    v_windows_json VARCHAR2(4000);
    v_palette      VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
    v_first        BOOLEAN;
BEGIN
    SELECT CAST(target_end_ts AS DATE) - weeks_back*7 - win_hours/24,
           CAST(target_end_ts AS DATE)
    INTO   v_range_start, v_range_end
    FROM   awr_trend_runs
    WHERE  run_id = ~run_id;

    v_total_hours := GREATEST((v_range_end - v_range_start) * 24, 1);

    DBMS_OUTPUT.PUT_LINE('<section id="ash-timeline"><h2>ASH timeline '
        || '(hourly, stacked by wait class)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Active sessions per hour from <code>dba_hist_active_sess_history</code>, '
        || 'covering the full comparison span ('
        || TO_CHAR(CAST(v_range_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || ' &rarr; '
        || TO_CHAR(CAST(v_range_end   AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || '). ON-CPU rows are bucketed as <b>CPU</b>; Idle waits are excluded. '
        || 'Compared windows are highlighted in the chart background.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-big" id="ash-timeline-stack"></div>');

    -- Shared hour grid (ISO-ish strings, oldest -> newest). Built via a
    -- PL/SQL accumulator rather than LISTAGG so we are not capped at the
    -- 4000-byte VARCHAR2 limit.  Echarts categorical axis accepts these.
    v_hours_json := '[';
    v_first := TRUE;
    FOR h IN (
        SELECT v_range_start + (LEVEL - 1)/24 AS hr_dt
        FROM   dual
        CONNECT BY LEVEL <= v_total_hours
        ORDER  BY 1
    ) LOOP
        IF v_first THEN v_first := FALSE;
        ELSE v_hours_json := v_hours_json || ','; END IF;
        v_hours_json := v_hours_json
            || '"' || TO_CHAR(h.hr_dt, 'YYYY-MM-DD HH24:MI') || '"';
    END LOOP;
    v_hours_json := v_hours_json || ']';

    -- Window-band markers: small (one per compared window), LISTAGG is safe.
    SELECT '['
           || LISTAGG(
                  '["'
                  || TO_CHAR(win_start_ts, 'YYYY-MM-DD HH24:MI') || '","'
                  || TO_CHAR(win_end_ts,   'YYYY-MM-DD HH24:MI') || '","'
                  || CASE WHEN week_offset = 0 THEN 'current'
                          ELSE 'w-' || week_offset END || '",'
                  || CASE WHEN valid_flag = 'Y' THEN '1' ELSE '0' END
                  || ']',
                  ',')
                  WITHIN GROUP (ORDER BY week_offset DESC)
           || ']'
    INTO   v_windows_json
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id;

    -- Emit JS in chunks so no single PUT_LINE exceeds 32767 bytes.
    -- JS doesn't care how the tokens are split across lines.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.ashTimeline = {');
    DBMS_OUTPUT.PUT_LINE('hours:' || v_hours_json || ',');
    DBMS_OUTPUT.PUT_LINE('windows:' || v_windows_json || ',');
    DBMS_OUTPUT.PUT_LINE('classes:[');

    -- Per-class aligned values (NVL to 0 so the stack stays contiguous).
    -- Ordered biggest-first so palette[0] goes to the dominant class.
    -- Each class emits a single JS object literal line (up to about 30KB).
    v_first := TRUE;
    FOR c IN (
        SELECT wait_class,
               SUM(active_sessions) AS total_aas
        FROM   awr_trend_ash_timeline
        WHERE  run_id = ~run_id
        GROUP  BY wait_class
        ORDER  BY SUM(active_sessions) DESC, wait_class
    ) LOOP
        v_class_vals := NULL;
        FOR v IN (
            SELECT NVL(t.active_sessions, 0) AS aas
            FROM (
                SELECT v_range_start + (LEVEL - 1)/24 AS hr_dt
                FROM   dual
                CONNECT BY LEVEL <= v_total_hours
            ) g
            LEFT JOIN awr_trend_ash_timeline t
                   ON t.run_id      = ~run_id
                  AND t.wait_class  = c.wait_class
                  AND t.hour_bucket = CAST(g.hr_dt AS TIMESTAMP)
            ORDER BY g.hr_dt
        ) LOOP
            IF v_class_vals IS NULL THEN
                v_class_vals := TO_CHAR(v.aas, 'FM99999990D0000',
                                        'NLS_NUMERIC_CHARACTERS=''.,''');
            ELSE
                v_class_vals := v_class_vals || ','
                    || TO_CHAR(v.aas, 'FM99999990D0000',
                               'NLS_NUMERIC_CHARACTERS=''.,''');
            END IF;
        END LOOP;

        IF v_first THEN v_first := FALSE;
        ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
        DBMS_OUTPUT.PUT_LINE('{"name":"' || REPLACE(c.wait_class, '"', '\"')
            || '","vals":[' || v_class_vals || ']}');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(']};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("ash-timeline-stack"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.ashTimeline, palette=' || v_palette || ';');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('var bandColor="rgba(37,99,235,0.10)", bandCurrent="rgba(37,99,235,0.22)";');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=(d.windows||[]).map(function(w){return [{xAxis:w[0],itemStyle:{color:w[2]==="current"?bandCurrent:bandColor}},{xAxis:w[1]}];});');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('    valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(2);}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{bottom:30,textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8,type:"scroll"},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:50,right:16,top:20,bottom:80,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.hours,boundaryGap:false,axisLabel:{color:mu,fontSize:10,hideOverlap:true}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",name:"Active sessions",nameTextStyle:{color:mu,fontSize:11},axisLabel:{color:mu},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  dataZoom:[{type:"inside"},{type:"slider",bottom:0,height:18,textStyle:{color:mu,fontSize:10}}],');
    DBMS_OUTPUT.PUT_LINE('  series:d.classes.map(function(c,i){');
    DBMS_OUTPUT.PUT_LINE('    var s={name:c.name,type:"line",stack:"total",smooth:false,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('      areaStyle:{opacity:0.85},emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('      lineStyle:{width:0.5,color:palette[i%palette.length]},');
    DBMS_OUTPUT.PUT_LINE('      itemStyle:{color:palette[i%palette.length]},');
    DBMS_OUTPUT.PUT_LINE('      data:c.vals};');
    DBMS_OUTPUT.PUT_LINE('    if(i===0 && markAreaData.length){');
    DBMS_OUTPUT.PUT_LINE('      s.markArea={silent:true,data:markAreaData,itemStyle:{opacity:1}};}');
    DBMS_OUTPUT.PUT_LINE('    return s;})');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
