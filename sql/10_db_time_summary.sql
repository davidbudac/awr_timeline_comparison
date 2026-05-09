--
-- 10_db_time_summary.sql
-- Stacked-area summary of database time at the very top of the report.
-- Covers every AWR snapshot pair from the earliest valid comparison-window
-- begin snap through the current window end snap (one bucket per native
-- snap interval, no aggregation). Stacked by:
--   * CPU         -- from DBA_HIST_SYS_TIME_MODEL stat_name = 'DB CPU'
--   * <wait_class>-- from DBA_HIST_SYSTEM_EVENT (Idle excluded)
--
-- Snap-to-snap deltas are computed via LAG. A pair is dropped when
-- startup_time changed across the LAG (instance restart) so a restart
-- shows up as a gap, not a negative spike.
--
-- Read-only: no scratch table, no DML.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_min_snap   NUMBER;
    v_max_snap   NUMBER;
    v_buckets    PLS_INTEGER := 0;
    v_times_json   VARCHAR2(32767);
    v_class_vals   VARCHAR2(32767);
    v_windows_json VARCHAR2(4000);
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
    v_first      BOOLEAN;

    -- key = "<bucket_idx>|<category>", value = seconds
    TYPE t_cell_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(80);
    v_cells        t_cell_tab;

    TYPE t_class_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_class_totals t_class_tab;

    -- snap_id -> bucket index (1..v_buckets)
    TYPE t_idx_tab IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
    v_snap_idx     t_idx_tab;

    v_ck VARCHAR2(80);
    v_wc VARCHAR2(64);
BEGIN
    --
    -- Resolve the snap range from the inline windows CTE: earliest valid
    -- begin_snap through latest valid end_snap. Identical CTE shape to
    -- every other section (read-only invariant: cannot be factored out).
    --
    SELECT MIN(begin_snap_id), MAX(end_snap_id)
    INTO   v_min_snap, v_max_snap
    FROM (
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
        )
        SELECT bs.snap_id AS begin_snap_id,
               es.snap_id AS end_snap_id
        FROM   raw_windows w
        JOIN   begin_snap bs ON bs.week_offset = w.week_offset
        JOIN   end_snap   es ON es.week_offset = w.week_offset
        WHERE  bs.snap_id IS NOT NULL
          AND  es.snap_id IS NOT NULL
          AND  bs.snap_id <> es.snap_id
          AND  bs.startup_time = es.startup_time
    );

    DBMS_OUTPUT.PUT_LINE('<section id="db-time-summary"><h2>Database time '
        || '(full comparison span)</h2>');

    IF v_min_snap IS NULL OR v_max_snap IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No valid comparison '
            || 'windows resolved &mdash; cannot render the timeline.</p></section>');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'DB time per AWR snapshot interval, stacked by wait class, covering '
        || 'every snap from the earliest compared window through the current one. '
        || '<b>CPU</b> comes from <code>dba_hist_sys_time_model</code> '
        || '(stat_name=DB CPU); the rest are summed from '
        || '<code>dba_hist_system_event</code> by <code>wait_class</code> '
        || '(Idle excluded). Snap-pairs that span an instance restart are '
        || 'dropped (rendered as gaps).</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-big" id="db-time-summary-chart"></div>');

    --
    -- Compared windows for the markArea bands (one per valid window). The
    -- xAxis values are the same YYYY-MM-DD HH24:MI format the chart uses
    -- for its category labels, so ECharts matches them by string.
    --
    SELECT '['
           || LISTAGG(
                  '["'
                  || TO_CHAR(win_start_ts, 'YYYY-MM-DD HH24:MI') || '","'
                  || TO_CHAR(win_end_ts,   'YYYY-MM-DD HH24:MI') || '","'
                  || CASE WHEN week_offset = 0 THEN 'current'
                          ELSE 'w-' || week_offset END || '"]',
                  ',')
                  WITHIN GROUP (ORDER BY week_offset DESC)
           || ']'
    INTO   v_windows_json
    FROM (
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
        )
        SELECT w.week_offset,
               CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
               CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts
        FROM   raw_windows w
        JOIN   begin_snap bs ON bs.week_offset = w.week_offset
        JOIN   end_snap   es ON es.week_offset = w.week_offset
        WHERE  bs.snap_id IS NOT NULL
          AND  es.snap_id IS NOT NULL
          AND  bs.snap_id <> es.snap_id
          AND  bs.startup_time = es.startup_time
    );

    --
    -- Build the x-axis: distinct snap_id (with a same-startup prior snap)
    -- in chronological order. snap_id is identical across instances at the
    -- same point in time, so DISTINCT collapses RAC duplicates correctly.
    --
    FOR s IN (
        WITH ordered AS (
            SELECT s.snap_id, s.instance_number, s.end_interval_time, s.startup_time,
                   LAG(s.startup_time) OVER (PARTITION BY s.instance_number
                                             ORDER BY s.snap_id) AS prev_startup
            FROM   dba_hist_snapshot s
            WHERE  s.dbid = ~dbid
              AND  s.snap_id BETWEEN v_min_snap AND v_max_snap
              AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
        )
        SELECT snap_id,
               MIN(end_interval_time) AS end_ts
        FROM   ordered
        WHERE  prev_startup IS NOT NULL
          AND  startup_time = prev_startup
        GROUP BY snap_id
        ORDER BY MIN(end_interval_time)
    ) LOOP
        v_buckets := v_buckets + 1;
        v_snap_idx(TO_CHAR(s.snap_id)) := v_buckets;

        IF v_times_json IS NULL THEN
            v_times_json := '["' || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
        ELSE
            v_times_json := v_times_json || ',"'
                || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
        END IF;
    END LOOP;
    v_times_json := NVL(v_times_json, '[') || ']';

    IF v_buckets = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">'
            || 'No snap pairs available in the resolved span.</p></section>');
        RETURN;
    END IF;

    --
    -- Pull per-snap delta seconds for CPU + each non-Idle wait_class. The
    -- LAG inside each branch can cross a restart boundary; we filter those
    -- out by joining to pair_keys (snap_id+instance pairs whose prior snap
    -- shares the same startup_time).
    --
    FOR r IN (
        WITH ordered_snaps AS (
            SELECT s.snap_id, s.instance_number, s.startup_time,
                   LAG(s.startup_time) OVER (PARTITION BY s.instance_number
                                             ORDER BY s.snap_id) AS prev_startup
            FROM   dba_hist_snapshot s
            WHERE  s.dbid = ~dbid
              AND  s.snap_id BETWEEN v_min_snap AND v_max_snap
              AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
        ),
        pair_keys AS (
            SELECT snap_id, instance_number
            FROM   ordered_snaps
            WHERE  prev_startup IS NOT NULL
              AND  startup_time = prev_startup
        ),
        cpu_d AS (
            SELECT stm.snap_id, stm.instance_number, 'CPU' AS cat,
                   GREATEST(stm.value
                       - LAG(stm.value) OVER (PARTITION BY stm.instance_number
                                              ORDER BY stm.snap_id), 0) AS micro
            FROM   dba_hist_sys_time_model stm
            WHERE  stm.dbid = ~dbid
              AND  stm.stat_name = 'DB CPU'
              AND  stm.snap_id BETWEEN v_min_snap AND v_max_snap
              AND  (~inst_num = 0 OR stm.instance_number = ~inst_num)
        ),
        wait_d AS (
            SELECT se.snap_id, se.instance_number,
                   NVL(se.wait_class, 'Other') AS cat,
                   GREATEST(se.time_waited_micro
                       - LAG(se.time_waited_micro) OVER (
                           PARTITION BY se.instance_number, se.event_id
                           ORDER BY se.snap_id), 0) AS micro
            FROM   dba_hist_system_event se
            WHERE  se.dbid = ~dbid
              AND  NVL(se.wait_class, 'x') <> 'Idle'
              AND  se.snap_id BETWEEN v_min_snap AND v_max_snap
              AND  (~inst_num = 0 OR se.instance_number = ~inst_num)
        ),
        all_d AS (
            SELECT snap_id, instance_number, cat, micro FROM cpu_d
            UNION ALL
            SELECT snap_id, instance_number, cat, micro FROM wait_d
        )
        SELECT a.snap_id, a.cat, SUM(a.micro)/1e6 AS sec
        FROM   all_d a
        JOIN   pair_keys pk
          ON   pk.snap_id = a.snap_id
         AND   pk.instance_number = a.instance_number
        GROUP BY a.snap_id, a.cat
        HAVING SUM(a.micro) > 0
    ) LOOP
        IF v_snap_idx.EXISTS(TO_CHAR(r.snap_id)) THEN
            v_ck := TO_CHAR(v_snap_idx(TO_CHAR(r.snap_id))) || '|' || r.cat;
            v_cells(v_ck) := r.sec;
            IF v_class_totals.EXISTS(r.cat) THEN
                v_class_totals(r.cat) := v_class_totals(r.cat) + r.sec;
            ELSE
                v_class_totals(r.cat) := r.sec;
            END IF;
        END IF;
    END LOOP;

    --
    -- Emit the JS payload + ECharts init. Same chunked PUT_LINE pattern as
    -- 09_ash_timeline so we never exceed 32767 bytes per line.
    --
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.dbTimeSummary = {');
    DBMS_OUTPUT.PUT_LINE('times:' || v_times_json || ',');
    DBMS_OUTPUT.PUT_LINE('windows:' || NVL(v_windows_json, '[]') || ',');
    DBMS_OUTPUT.PUT_LINE('classes:[');

    -- Walk v_class_totals biggest-first so the dominant series gets palette[0].
    DECLARE
        TYPE t_kv    IS RECORD (k VARCHAR2(64), v NUMBER);
        TYPE t_klist IS TABLE OF t_kv;
        v_list t_klist := t_klist();
        v_tmp  t_kv;
        v_ci   VARCHAR2(64);
        v_n    NUMBER;
    BEGIN
        v_ci := v_class_totals.FIRST;
        WHILE v_ci IS NOT NULL LOOP
            v_list.EXTEND;
            v_list(v_list.LAST).k := v_ci;
            v_list(v_list.LAST).v := v_class_totals(v_ci);
            v_ci := v_class_totals.NEXT(v_ci);
        END LOOP;

        -- Selection sort: at most a dozen wait classes.
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
            FOR b IN 1 .. v_buckets LOOP
                v_ck := TO_CHAR(b) || '|' || v_wc;
                IF v_cells.EXISTS(v_ck) THEN
                    v_n := v_cells(v_ck);
                ELSE
                    v_n := 0;
                END IF;
                IF v_class_vals IS NULL THEN
                    v_class_vals := TO_CHAR(v_n, 'FM99999990D000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                ELSE
                    v_class_vals := v_class_vals || ','
                        || TO_CHAR(v_n, 'FM99999990D000',
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
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("db-time-summary-chart"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.dbTimeSummary, palette=' || v_palette || ';');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('var bandColor="rgba(37,99,235,0.10)", bandCurrent="rgba(37,99,235,0.22)";');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=(d.windows||[]).map(function(w){return [');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[0],itemStyle:{color:w[2]==="current"?bandCurrent:bandColor},');
    DBMS_OUTPUT.PUT_LINE('   label:{show:true,position:"insideTop",color:mu,fontSize:10,formatter:w[2]}},');
    DBMS_OUTPUT.PUT_LINE('  {xAxis:w[1]}];});');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('    valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(1)+" s";}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{top:0,left:"center",textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8,type:"scroll"},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:50,right:16,top:40,bottom:60,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.times,boundaryGap:false,axisLabel:{color:mu,fontSize:10,hideOverlap:true}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",name:"DB time (s)",nameTextStyle:{color:mu,fontSize:11},axisLabel:{color:mu},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  dataZoom:[{type:"inside"},{type:"slider",bottom:8,height:18,textStyle:{color:mu,fontSize:10}}],');
    DBMS_OUTPUT.PUT_LINE('  series:d.classes.map(function(c,i){');
    DBMS_OUTPUT.PUT_LINE('    var color=(window.AWR_WAIT_COLORS||{})[c.name]||palette[i%palette.length];');
    DBMS_OUTPUT.PUT_LINE('    var s={name:c.name,type:"line",stack:"total",smooth:false,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('      areaStyle:{opacity:0.85},emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('      lineStyle:{width:0.5,color:color},');
    DBMS_OUTPUT.PUT_LINE('      itemStyle:{color:color},');
    DBMS_OUTPUT.PUT_LINE('      data:c.vals};');
    DBMS_OUTPUT.PUT_LINE('    if(i===0 && markAreaData.length){');
    DBMS_OUTPUT.PUT_LINE('      s.markArea={silent:true,data:markAreaData,itemStyle:{opacity:1},z:0};}');
    DBMS_OUTPUT.PUT_LINE('    return s;})');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
