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

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 10_db_time_summary BEGIN -->'); END;
/

DECLARE
    -- Span is bounded by TIME, not a single contiguous snap_id range: snap_ids
    -- reset per DBID, so after a non-CDB->PDB migration one snap_id range can
    -- no longer cover both the old (pre-migration) and new (post-migration)
    -- eras.  v_range_start/v_range_end are the actual end_interval_time of the
    -- earliest begin snap and latest end snap across all valid windows, and
    -- every scan filters end_interval_time BETWEEN them with dbid IN
    -- (dbid_list).  With one DBID this selects exactly the old snap_id range.
    v_range_start  TIMESTAMP;
    v_range_end    TIMESTAMP;
    v_buckets    PLS_INTEGER := 0;
    -- v_times_json + v_class_vals are CLOBs so a dense AWR span with
    -- thousands of snap pairs (e.g. weeks_back=4 at 15-min cadence)
    -- cannot overflow PL/SQL's 32767-byte VARCHAR2 limit.  v_windows_json
    -- stays VARCHAR2 (bounded by weeks_back+1).
    v_times_json   CLOB;
    v_class_vals   CLOB;
    v_windows_json VARCHAR2(4000);
    v_buf          VARCHAR2(64);
    v_palette    VARCHAR2(400) :=
        '["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",' ||
        '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]';
    v_first      BOOLEAN;

    -- key = "<bucket_idx>|<category>", value = seconds
    TYPE t_cell_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(80);
    v_cells        t_cell_tab;

    TYPE t_class_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_class_totals t_class_tab;

    -- "<dbid>|<snap_id>" -> bucket index (1..v_buckets).  Keyed by DBID too,
    -- because snap_id is only unique within a DBID once the span crosses a
    -- migration boundary.
    TYPE t_idx_tab IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
    v_snap_idx     t_idx_tab;

    v_ck VARCHAR2(80);
    v_wc VARCHAR2(64);
    @@sql/lib/put_clob_chunked.plsql
BEGIN
    DBMS_LOB.CREATETEMPORARY(v_times_json, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_class_vals, TRUE);
    --
    -- Resolve the snap range from the inline windows CTE: earliest valid
    -- begin_snap through latest valid end_snap. Identical CTE shape to
    -- every other section (read-only invariant: cannot be factored out).
    --
    SELECT MIN(begin_ts), MAX(end_ts)
    INTO   v_range_start, v_range_end
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT bs.end_ts AS begin_ts,
               es.end_ts AS end_ts
        FROM   raw_windows w
        JOIN   begin_snap bs ON bs.week_offset = w.week_offset
        JOIN   end_snap   es ON es.week_offset = w.week_offset
        WHERE  bs.snap_id IS NOT NULL
          AND  es.snap_id IS NOT NULL
          AND  bs.snap_id <> es.snap_id
          AND  bs.dbid = es.dbid
          AND  bs.startup_time = es.startup_time
    );

    DBMS_OUTPUT.PUT_LINE('<section id="db-time-summary"><h2>Database time '
        || '(full comparison span)</h2>');

    IF v_range_start IS NULL OR v_range_end IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No valid comparison '
            || 'windows resolved &mdash; cannot render the timeline.</p></section>');
        DBMS_LOB.FREETEMPORARY(v_times_json);
        DBMS_LOB.FREETEMPORARY(v_class_vals);
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'DB CPU + non-idle wait time per snap interval, stacked by wait_class, '
        || 'earliest compared window &rarr; current. '
        || '<b>CPU</b>: <code>dba_hist_sys_time_model</code> (stat_name=DB CPU, '
        || 'foreground sessions). '
        || 'Waits: <code>dba_hist_system_event</code> grouped by <code>wait_class</code> '
        || '(Idle excluded, <b>all sessions incl. background</b> &mdash; LGWR/DBWR '
        || 'writes etc.), so this is not a strict foreground DB-time profile. '
        || 'Snap-pairs across an instance restart &rarr; gap.</p>');

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
        WITH
        @@sql/lib/windows_cte.sql
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
            SELECT s.dbid, s.snap_id, s.instance_number, s.end_interval_time, s.startup_time,
                   LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                             ORDER BY s.snap_id) AS prev_startup
            FROM   dba_hist_snapshot s
            WHERE  s.dbid IN (~dbid_list)
              AND  s.end_interval_time BETWEEN v_range_start AND v_range_end
              AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
        )
        SELECT dbid, snap_id,
               MIN(end_interval_time) AS end_ts
        FROM   ordered
        WHERE  prev_startup IS NOT NULL
          AND  startup_time = prev_startup
        GROUP BY dbid, snap_id
        ORDER BY MIN(end_interval_time)
    ) LOOP
        v_buckets := v_buckets + 1;
        v_snap_idx(s.dbid || '|' || s.snap_id) := v_buckets;
        IF v_buckets = 1 THEN
            v_buf := '["' || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
        ELSE
            v_buf := ',"' || TO_CHAR(s.end_ts, 'YYYY-MM-DD HH24:MI') || '"';
        END IF;
        DBMS_LOB.WRITEAPPEND(v_times_json, LENGTH(v_buf), v_buf);
    END LOOP;
    IF v_buckets = 0 THEN
        DBMS_LOB.WRITEAPPEND(v_times_json, 2, '[]');
    ELSE
        DBMS_LOB.WRITEAPPEND(v_times_json, 1, ']');
    END IF;

    IF v_buckets = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">'
            || 'No snap pairs available in the resolved span.</p></section>');
        DBMS_LOB.FREETEMPORARY(v_times_json);
        DBMS_LOB.FREETEMPORARY(v_class_vals);
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
            SELECT s.dbid, s.snap_id, s.instance_number, s.startup_time,
                   LAG(s.startup_time) OVER (PARTITION BY s.dbid, s.instance_number
                                             ORDER BY s.snap_id) AS prev_startup
            FROM   dba_hist_snapshot s
            WHERE  s.dbid IN (~dbid_list)
              AND  s.end_interval_time BETWEEN v_range_start AND v_range_end
              AND  (~inst_num = 0 OR s.instance_number = ~inst_num)
        ),
        pair_keys AS (
            SELECT dbid, snap_id, instance_number
            FROM   ordered_snaps
            WHERE  prev_startup IS NOT NULL
              AND  startup_time = prev_startup
        ),
        cpu_d AS (
            -- CAST the literal to match wait_d.cat width; otherwise UNION ALL
            -- inherits VARCHAR2(3) from this arm and longer wait_class names
            -- (e.g. 'Configuration') overflow on cursor fetch (ORA-06502).
            -- Joined to dba_hist_snapshot so the span can be bounded by TIME
            -- (sys_time_model has no end_interval_time) and the LAG delta is
            -- partitioned per DBID so it never crosses a migration boundary.
            SELECT stm.dbid, stm.snap_id, stm.instance_number,
                   CAST('CPU' AS VARCHAR2(64)) AS cat,
                   GREATEST(stm.value
                       - LAG(stm.value) OVER (PARTITION BY stm.dbid, stm.instance_number
                                              ORDER BY stm.snap_id), 0) AS micro
            FROM   dba_hist_sys_time_model stm
            JOIN   dba_hist_snapshot s2
              ON   s2.dbid = stm.dbid
             AND   s2.snap_id = stm.snap_id
             AND   s2.instance_number = stm.instance_number
            WHERE  stm.dbid IN (~dbid_list)
              AND  stm.stat_name = 'DB CPU'
              AND  s2.end_interval_time BETWEEN v_range_start AND v_range_end
              AND  (~inst_num = 0 OR stm.instance_number = ~inst_num)
        ),
        wait_d AS (
            SELECT se.dbid, se.snap_id, se.instance_number,
                   NVL(se.wait_class, 'Other') AS cat,
                   GREATEST(se.time_waited_micro
                       - LAG(se.time_waited_micro) OVER (
                           PARTITION BY se.dbid, se.instance_number, se.event_id
                           ORDER BY se.snap_id), 0) AS micro
            FROM   dba_hist_system_event se
            JOIN   dba_hist_snapshot s3
              ON   s3.dbid = se.dbid
             AND   s3.snap_id = se.snap_id
             AND   s3.instance_number = se.instance_number
            WHERE  se.dbid IN (~dbid_list)
              AND  NVL(se.wait_class, 'x') <> 'Idle'
              AND  s3.end_interval_time BETWEEN v_range_start AND v_range_end
              AND  (~inst_num = 0 OR se.instance_number = ~inst_num)
        ),
        all_d AS (
            SELECT dbid, snap_id, instance_number, cat, micro FROM cpu_d
            UNION ALL
            SELECT dbid, snap_id, instance_number, cat, micro FROM wait_d
        )
        SELECT a.dbid, a.snap_id, a.cat, SUM(a.micro)/1e6 AS sec
        FROM   all_d a
        JOIN   pair_keys pk
          ON   pk.dbid = a.dbid
         AND   pk.snap_id = a.snap_id
         AND   pk.instance_number = a.instance_number
        GROUP BY a.dbid, a.snap_id, a.cat
        HAVING SUM(a.micro) > 0
    ) LOOP
        IF v_snap_idx.EXISTS(r.dbid || '|' || r.snap_id) THEN
            v_ck := TO_CHAR(v_snap_idx(r.dbid || '|' || r.snap_id)) || '|' || r.cat;
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
    -- v_times_json is a CLOB that may exceed 32767 bytes; emit chunked.
    DBMS_OUTPUT.PUT_LINE('times:');
    put_clob_chunked(v_times_json);
    DBMS_OUTPUT.PUT_LINE(',');
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
            -- Reuse the same CLOB across iterations: truncate to 0 then
            -- WRITEAPPEND. Avoids reallocating a temp LOB per class.
            DBMS_LOB.TRIM(v_class_vals, 0);
            FOR b IN 1 .. v_buckets LOOP
                v_ck := TO_CHAR(b) || '|' || v_wc;
                IF v_cells.EXISTS(v_ck) THEN
                    v_n := v_cells(v_ck);
                ELSE
                    v_n := 0;
                END IF;
                IF b = 1 THEN
                    v_buf := TO_CHAR(v_n, 'FM99999990D000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''');
                ELSE
                    v_buf := ',' || TO_CHAR(v_n, 'FM99999990D000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                END IF;
                DBMS_LOB.WRITEAPPEND(v_class_vals, LENGTH(v_buf), v_buf);
            END LOOP;

            IF v_first THEN v_first := FALSE;
            ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
            -- Emit '{"name":"...","vals":[' prefix, then the CLOB body
            -- chunked, then ']}'.  Newlines between chunks are valid JS
            -- whitespace inside the array literal.
            DBMS_OUTPUT.PUT_LINE('{"name":"' || REPLACE(v_wc, '"', '\"')
                || '","vals":[');
            put_clob_chunked(v_class_vals);
            DBMS_OUTPUT.PUT_LINE(']}');
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
    DBMS_OUTPUT.PUT_LINE('    if(i===0){var __ml=window.AWR_markLine&&window.AWR_markLine(d.times); if(__ml) s.markLine=__ml;}');
    DBMS_OUTPUT.PUT_LINE('    return s;})');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');

    DBMS_LOB.FREETEMPORARY(v_times_json);
    DBMS_LOB.FREETEMPORARY(v_class_vals);
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 10_db_time_summary END -->'); END;
/
