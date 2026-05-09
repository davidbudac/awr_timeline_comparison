--
-- 09_ash_timeline.sql
-- Active-Session timeline from DBA_HIST_ACTIVE_SESS_HISTORY, stacked by
-- wait_class (ON-CPU rows bucketed as 'CPU', Idle waits excluded).
-- Spans from (target_end - weeks_back*step_hours/24 days - win_hours) up to
-- target_end, so every compared window is covered in context. Renders below
-- the Headline metrics (hero strip) via flexbox order.
--
-- Bucket width = ~bucket_hours = LEAST(step_hours, 1). For sub-hour cadences
-- (e.g. 15-min comparisons), buckets shrink to step_hours so each window is
-- still a single bar; for hourly+ cadences, buckets stay 1h.
--
-- ASH persists 1 in 10 in-memory samples, i.e. one row per session per 10s,
-- so a fully-busy session contributes 360 rows/hour. AAS for a bucket is
-- sample_count / (bucket_hours * 360).
--
-- Read-only: pulls ASH rows into a PL/SQL collection in-memory, computes
-- per-bucket aggregates, and renders directly.  No scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_range_start  DATE;
    v_range_end    DATE;
    v_bucket_hours  NUMBER := ~bucket_hours;          -- 0.25 .. 1
    v_total_buckets NUMBER;
    v_total_hours   NUMBER;
    -- Compact, human-readable label for v_bucket_hours, used in the section
    -- title and prose. "15-min", "1-hour", or "X.YY-hour" for odd fractions.
    v_bucket_label  VARCHAR2(32);
    -- PL/SQL VARCHAR2 goes up to 32767 bytes regardless of MAX_STRING_SIZE.
    -- Enough for about 2000 hours of CSV values; LISTAGG in SQL would cap at 4000.
    v_hours_json   VARCHAR2(32767);
    v_class_vals   VARCHAR2(32767);
    v_windows_json VARCHAR2(4000);
    v_palette      VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
    v_first        BOOLEAN;

    -- ASH aggregate: one entry per (bucket, wait_class) with sample_count.
    -- DATE arithmetic at bucket_hours granularity, so DATE keys are fine.
    TYPE t_cell_key  IS RECORD (
        bucket_key NUMBER,           -- buckets since v_range_start
        wait_class VARCHAR2(64)
    );
    TYPE t_cell_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    v_cells        t_cell_tab;

    TYPE t_class_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_class_totals t_class_tab;

    v_ck           VARCHAR2(200);
    v_bk           NUMBER;
    v_wc           VARCHAR2(64);
    v_n            NUMBER;
    v_aas          NUMBER;
BEGIN
    SELECT CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - ~weeks_back*(~step_hours/24) - ~win_hours/24,
           CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
    INTO   v_range_start, v_range_end
    FROM   dual;

    v_total_hours   := GREATEST((v_range_end - v_range_start) * 24, 1);
    v_total_buckets := GREATEST(ROUND(v_total_hours / v_bucket_hours), 1);
    v_bucket_label  :=
        CASE WHEN v_bucket_hours = 1 THEN '1-hour'
             WHEN v_bucket_hours < 1 AND MOD(v_bucket_hours*60, 1) = 0
                  THEN TO_CHAR(ROUND(v_bucket_hours*60)) || '-min'
             ELSE TO_CHAR(v_bucket_hours,
                          'FM999990.99',
                          'NLS_NUMERIC_CHARACTERS=''.,''') || '-hour'
        END;

    DBMS_OUTPUT.PUT_LINE('<section id="ash-timeline"><h2>ASH timeline '
        || '(' || CASE WHEN v_bucket_hours = 1 THEN 'hourly' ELSE v_bucket_label END
        || ', stacked by wait class)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Active sessions per '
        || CASE WHEN v_bucket_hours = 1 THEN 'hour'
                ELSE v_bucket_label || ' bucket' END
        || ' from <code>dba_hist_active_sess_history</code>, '
        || 'covering the full comparison span ('
        || TO_CHAR(CAST(v_range_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || ' &rarr; '
        || TO_CHAR(CAST(v_range_end   AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || '). ON-CPU rows are bucketed as <b>CPU</b>; Idle waits are excluded. '
        || 'Compared windows are highlighted in the chart background.</p>');

    -- Taller container than .chart-big: the stacked area needs room for the
    -- plot, a top-anchored scrolling legend (so it does not collide with the
    -- bottom dataZoom slider), and the slider itself at the bottom.
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-ash" id="ash-timeline-stack"></div>');

    --
    -- Pull aggregated ASH into a PL/SQL collection.  The view is large;
    -- we GROUP BY the two keys we need so the round trip is small.
    --
    FOR r IN (
        -- bucket_key = floor((sample - range_start) hours / bucket_hours).
        -- Direct floor on a fractional bucket avoids the TRUNC('HH') trap
        -- that collapsed every sub-hour cadence into one bar.
        SELECT FLOOR(((CAST(ash.sample_time AS DATE) - v_range_start) * 24)
                     / v_bucket_hours) AS bucket_key,
               CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                    ELSE NVL(ash.wait_class, 'Other') END AS wait_class,
               COUNT(*) AS sample_count
        FROM   dba_hist_active_sess_history ash
        WHERE  ash.dbid = ~dbid
          AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
          AND  ash.sample_time >= CAST(v_range_start AS TIMESTAMP)
          AND  ash.sample_time <  CAST(v_range_end   AS TIMESTAMP)
          AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
        GROUP BY FLOOR(((CAST(ash.sample_time AS DATE) - v_range_start) * 24)
                       / v_bucket_hours),
                 CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                      ELSE NVL(ash.wait_class, 'Other') END
    ) LOOP
        v_ck := TO_CHAR(r.bucket_key) || '|' || r.wait_class;
        v_cells(v_ck) := r.sample_count;
        IF v_class_totals.EXISTS(r.wait_class) THEN
            v_class_totals(r.wait_class) := v_class_totals(r.wait_class) + r.sample_count;
        ELSE
            v_class_totals(r.wait_class) := r.sample_count;
        END IF;
    END LOOP;

    -- Shared bucket grid (ISO-ish strings, oldest -> newest). Each label is
    -- the bucket's start instant; with sub-hour bucket_hours, HH24:MI shows
    -- the minute boundary too.
    v_hours_json := '[';
    FOR b IN 0 .. v_total_buckets - 1 LOOP
        IF b > 0 THEN v_hours_json := v_hours_json || ','; END IF;
        v_hours_json := v_hours_json
            || '"' || TO_CHAR(v_range_start + (b * v_bucket_hours) / 24,
                              'YYYY-MM-DD HH24:MI') || '"';
    END LOOP;
    v_hours_json := v_hours_json || ']';

    -- Window-band markers: small (one per compared window), LISTAGG is safe.
    -- Read from the shared windows_rollup CTE (per-week_offset roll-up
    -- of per-instance windows) so the band gets a single Y/N flag per
    -- offset regardless of RAC instance count.
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
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts, win_end_ts, valid_flag
        FROM   windows_rollup
    );

    -- Emit JS in chunks so no single PUT_LINE exceeds 32767 bytes.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.ashTimeline = {');
    DBMS_OUTPUT.PUT_LINE('hours:' || v_hours_json || ',');
    DBMS_OUTPUT.PUT_LINE('windows:' || v_windows_json || ',');
    DBMS_OUTPUT.PUT_LINE('classes:[');

    -- Emit per-class aligned values (NVL to 0 so the stack stays contiguous).
    -- Ordered biggest-first so palette[0] goes to the dominant class.
    -- Walk v_class_totals sorted by magnitude by copying keys into a sorted list.
    DECLARE
        TYPE t_kv IS RECORD (k VARCHAR2(64), v NUMBER);
        TYPE t_klist IS TABLE OF t_kv;
        v_list t_klist := t_klist();
        v_tmp  t_kv;
        v_ci   VARCHAR2(64);
    BEGIN
        v_ci := v_class_totals.FIRST;
        WHILE v_ci IS NOT NULL LOOP
            v_list.EXTEND;
            v_list(v_list.LAST).k := v_ci;
            v_list(v_list.LAST).v := v_class_totals(v_ci);
            v_ci := v_class_totals.NEXT(v_ci);
        END LOOP;

        -- Simple selection sort: list is at most a few dozen classes.
        FOR i IN 1 .. v_list.COUNT - 1 LOOP
            FOR j IN i + 1 .. v_list.COUNT LOOP
                IF v_list(j).v > v_list(i).v
                   OR (v_list(j).v = v_list(i).v AND v_list(j).k < v_list(i).k) THEN
                    v_tmp := v_list(i); v_list(i) := v_list(j); v_list(j) := v_tmp;
                END IF;
            END LOOP;
        END LOOP;

        v_first := TRUE;
        FOR i IN 1 .. v_list.COUNT LOOP
            v_wc := v_list(i).k;
            v_class_vals := NULL;
            FOR b IN 0 .. v_total_buckets - 1 LOOP
                v_ck := TO_CHAR(b) || '|' || v_wc;
                IF v_cells.EXISTS(v_ck) THEN
                    v_n := v_cells(v_ck);
                ELSE
                    v_n := 0;
                END IF;
                -- 360 ASH samples == one busy session-hour;
                -- divide by the bucket width (in hours) to get AAS.
                v_aas := v_n / (v_bucket_hours * 360);
                IF v_class_vals IS NULL THEN
                    v_class_vals := TO_CHAR(v_aas, 'FM99999990D0000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                ELSE
                    v_class_vals := v_class_vals || ','
                        || TO_CHAR(v_aas, 'FM99999990D0000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                END IF;
            END LOOP;

            IF v_first THEN v_first := FALSE;
            ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
            DBMS_OUTPUT.PUT_LINE('{"name":"' || REPLACE(v_wc, '"', '\"')
                || '","vals":[' || v_class_vals || ']}');
        END LOOP;
    END;

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
    DBMS_OUTPUT.PUT_LINE('  legend:{top:0,left:"center",textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8,type:"scroll"},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:50,right:16,top:40,bottom:60,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.hours,boundaryGap:false,axisLabel:{color:mu,fontSize:10,hideOverlap:true}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",name:"Active sessions",nameTextStyle:{color:mu,fontSize:11},axisLabel:{color:mu},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  dataZoom:[{type:"inside"},{type:"slider",bottom:8,height:18,textStyle:{color:mu,fontSize:10}}],');
    DBMS_OUTPUT.PUT_LINE('  series:d.classes.map(function(c,i){');
    DBMS_OUTPUT.PUT_LINE('    var color=(window.AWR_WAIT_COLORS||{})[c.name]||palette[i%palette.length];');
    DBMS_OUTPUT.PUT_LINE('    var s={name:c.name,type:"line",stack:"total",smooth:false,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('      areaStyle:{opacity:0.85},emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('      lineStyle:{width:0.5,color:color},');
    DBMS_OUTPUT.PUT_LINE('      itemStyle:{color:color},');
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
