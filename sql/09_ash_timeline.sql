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
-- v1.6.0 Timeline (Mock D): the SAME scan (one pass over
-- DBA_HIST_ACTIVE_SESS_HISTORY, grouped also by the compared window a
-- sample falls in) feeds the Timeline view's full-span interactive chart:
-- one payload window.AWR_DATA.ashx = {t0, end, bh, wh, classes, vals, win}
--   t0 / end   span start / end ('YYYY-MM-DD HH24:MI'), bh = chart bucket
--              in hours: a whole multiple of this section's bucket, at
--              least 1 h, sized for at most about 400 buckets (13 weekly
--              windows: 6 h, 4 weeks: 2 h, a week or less: 1 h);
--   classes    wait classes in a fixed stacking order (CPU first);
--   vals       per class, one AAS per chart bucket, oldest first (a zero,
--              never a gap, so nothing left-compacts);
--   win        per class, one AAS per compared window, oldest first
--              (samples inside that window / 360 / win_hours), every
--              session -- the stripe tooltip and the Activity lane;
--   winfg      the same for FOREGROUND sessions only (session_type) -- the
--              DB time card's chart: DB time is foreground time, and ASH's
--              foreground samples are its sampled estimate, so the card's
--              bars and its DB time headline measure the same thing;
--   wh         win_hours.  Numbers are dot-decimal (NLS pinned).
-- plus the Activity lane's row (sql/lib/timeline.plsql; Current vs the
-- mean of the valid prior windows, not scored).  A sample belongs to
-- EVERY window whose span [start, start + win_hours) contains it: with
-- step >= win_hours that is at most one; when win_hours > step_hours the
-- windows overlap and a sample counts toward each of them, so every
-- window holds its full win_hours of samples and the divisor is right.
--
-- Read-only: pulls ASH rows into a PL/SQL collection in-memory, computes
-- per-bucket aggregates, and renders directly.  No scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 09_ash_timeline BEGIN -->'); END;
/

DECLARE
    v_range_start  DATE;
    v_range_end    DATE;
    v_bucket_hours  NUMBER := ~bucket_hours;          -- 0.25 .. 1
    v_total_buckets NUMBER;
    v_total_hours   NUMBER;
    -- Compact, human-readable label for v_bucket_hours, used in the section
    -- title and prose. "15-min", "1-hour", or "X.YY-hour" for odd fractions.
    v_bucket_label  VARCHAR2(32);
    -- v_hours_json + v_class_vals are CLOBs so a long span with many
    -- buckets (e.g. weeks_back=4 at 15-min cadence -> 2700+ buckets)
    -- can't overflow PL/SQL's 32767-byte VARCHAR2 limit and abort the
    -- chart with ORA-06502.  v_windows_json stays VARCHAR2 (one entry
    -- per compared window, bounded by weeks_back+1).
    v_hours_json   CLOB;
    v_class_vals   CLOB;
    v_windows_json VARCHAR2(32767);
    v_buf          VARCHAR2(64);
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
    v_total_n      NUMBER := 0;
    v_aas          NUMBER;
    -- v1.6.0 Timeline: chart buckets (v_m fine buckets each) and windows
    v_m            PLS_INTEGER;
    v_bh           NUMBER;
    v_nc           PLS_INTEGER;
    v_ccells       t_cell_tab;          -- (chart bucket | class) -> samples
    v_wcells       t_cell_tab;          -- (week_offset | class)  -> samples
    v_wfcells      t_cell_tab;          -- the same, foreground sessions only
    v_valid        VARCHAR2(4000);      -- '|k=Y|k=N|...' per window
    v_cls_order    VARCHAR2(4000);      -- '|CPU|User I/O|...' stacking order
    @@sql/lib/put_clob_chunked.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql

    -- an AAS as a compact dot-decimal JS number (3 decimals, no trailing zeros)
    FUNCTION aas_tok(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RTRIM(TO_CHAR(ROUND(NVL(p, 0), 3), 'FM9999999990D999',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END aas_tok;

    -- the Timeline's fixed stacking order: CPU at the bottom, then the
    -- usual suspects, anything unknown before Other
    FUNCTION cls_rank(p VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE p WHEN 'CPU' THEN 1 WHEN 'User I/O' THEN 2 WHEN 'System I/O' THEN 3
                      WHEN 'Commit' THEN 4 WHEN 'Application' THEN 5 WHEN 'Concurrency' THEN 6
                      WHEN 'Network' THEN 7 WHEN 'Configuration' THEN 8 WHEN 'Scheduler' THEN 9
                      WHEN 'Cluster' THEN 10 WHEN 'Administrative' THEN 11 WHEN 'Queueing' THEN 12
                      WHEN 'Other' THEN 99 ELSE 50 END;
    END cls_rank;
BEGIN
    DBMS_LOB.CREATETEMPORARY(v_hours_json, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_class_vals, TRUE);
    SELECT CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - ~weeks_back*(~step_hours/24) - ~win_hours/24,
           CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
    INTO   v_range_start, v_range_end
    FROM   dual;

    v_total_hours   := GREATEST((v_range_end - v_range_start) * 24, 1);
    -- CEIL, not ROUND: bucket assignment uses FLOOR(elapsed/bucket), so a
    -- fractional final bucket has index = FLOOR(total/bucket) which equals
    -- ROUND(total/bucket) only when the tail is >= half a bucket -- otherwise
    -- ROUND drops it and the last partial bucket vanishes.  CEIL always keeps
    -- it; integer cadences give ROUND=CEIL, so aligned runs are unchanged (F4).
    v_total_buckets := GREATEST(CEIL(v_total_hours / v_bucket_hours), 1);
    -- the Timeline chart's bucket: v_m of these buckets, at least 1 h
    v_m  := GREATEST(1, CEIL(GREATEST(1, v_total_hours / 400) / v_bucket_hours));
    v_bh := v_m * v_bucket_hours;
    v_nc := CEIL(v_total_buckets / v_m);
    v_bucket_label  :=
        CASE WHEN v_bucket_hours = 1 THEN '1-hour'
             WHEN v_bucket_hours < 1 AND MOD(v_bucket_hours*60, 1) = 0
                  THEN TO_CHAR(ROUND(v_bucket_hours*60)) || '-min'
             ELSE TO_CHAR(v_bucket_hours,
                          'FM999990.99',
                          'NLS_NUMERIC_CHARACTERS=''.,''') || '-hour'
        END;

    DBMS_OUTPUT.PUT_LINE('<section id="ash-timeline" class="vw in-a"><h2>Active sessions'
        || '<small class="h2sub">ASH by wait class, '
        || CASE WHEN v_bucket_hours = 1 THEN 'hourly' ELSE v_bucket_label END
        || ', '
        || TO_CHAR(CAST(v_range_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || ' &rarr; '
        || TO_CHAR(CAST(v_range_end   AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || '; compared windows shaded</small></h2>');

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
        -- j_lo .. j_hi (v1.6.0) = the compared windows the sample falls in,
        -- as window STEPS after range_start: the window of offset o starts
        -- j = weeks_back - o steps after range_start and holds a sample h
        -- hours after range_start when j * step <= h < j * step + win, i.e.
        -- (h - win) / step < j <= h / step.  An empty range (j_lo > j_hi)
        -- = between windows; overlapping windows (win > step) give a range
        -- of more than one.  fg = 1 for a FOREGROUND session's sample.
        SELECT bucket_key, wait_class, j_lo, j_hi, fg, COUNT(*) AS sample_count
        FROM (
            SELECT FLOOR(h / v_bucket_hours) AS bucket_key,
                   CASE WHEN session_state = 'ON CPU' THEN 'CPU'
                        ELSE NVL(wait_class, 'Other') END AS wait_class,
                   GREATEST(0, FLOOR((ROUND(h, 6) - ~win_hours) / ~step_hours) + 1) AS j_lo,
                   LEAST(~weeks_back, FLOOR(ROUND(h, 6) / ~step_hours))           AS j_hi,
                   CASE WHEN session_type = 'FOREGROUND' THEN 1 ELSE 0 END      AS fg
            FROM (
                SELECT (CAST(ash.sample_time AS DATE) - v_range_start) * 24 AS h,
                       ash.session_state, ash.wait_class, ash.session_type
                FROM   dba_hist_active_sess_history ash
                WHERE  ash.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
                  AND  ash.sample_time >= CAST(v_range_start AS TIMESTAMP)
                  AND  ash.sample_time <  CAST(v_range_end   AS TIMESTAMP)
                  AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
            )
        )
        GROUP BY bucket_key, wait_class, j_lo, j_hi, fg
    ) LOOP
        v_ck := TO_CHAR(r.bucket_key) || '|' || r.wait_class;
        IF v_cells.EXISTS(v_ck) THEN
            v_cells(v_ck) := v_cells(v_ck) + r.sample_count;
        ELSE
            v_cells(v_ck) := r.sample_count;
        END IF;
        v_ck := TO_CHAR(FLOOR(r.bucket_key / v_m)) || '|' || r.wait_class;
        IF v_ccells.EXISTS(v_ck) THEN
            v_ccells(v_ck) := v_ccells(v_ck) + r.sample_count;
        ELSE
            v_ccells(v_ck) := r.sample_count;
        END IF;
        FOR j IN r.j_lo .. r.j_hi LOOP
            v_ck := TO_CHAR(~weeks_back - j) || '|' || r.wait_class;
            IF v_wcells.EXISTS(v_ck) THEN
                v_wcells(v_ck) := v_wcells(v_ck) + r.sample_count;
            ELSE
                v_wcells(v_ck) := r.sample_count;
            END IF;
            IF r.fg = 1 THEN
                IF v_wfcells.EXISTS(v_ck) THEN
                    v_wfcells(v_ck) := v_wfcells(v_ck) + r.sample_count;
                ELSE
                    v_wfcells(v_ck) := r.sample_count;
                END IF;
            END IF;
        END LOOP;
        IF v_class_totals.EXISTS(r.wait_class) THEN
            v_class_totals(r.wait_class) := v_class_totals(r.wait_class) + r.sample_count;
        ELSE
            v_class_totals(r.wait_class) := r.sample_count;
        END IF;
    END LOOP;

    -- Shared bucket grid (ISO-ish strings, oldest -> newest). Each label is
    -- the bucket's start instant; with sub-hour bucket_hours, HH24:MI shows
    -- the minute boundary too.  Built into a CLOB via WRITEAPPEND so a
    -- long compared span can hold thousands of buckets without overflow.
    DBMS_LOB.WRITEAPPEND(v_hours_json, 1, '[');
    FOR b IN 0 .. v_total_buckets - 1 LOOP
        IF b = 0 THEN
            v_buf := '"' || TO_CHAR(v_range_start + (b * v_bucket_hours) / 24,
                                    'YYYY-MM-DD HH24:MI') || '"';
        ELSE
            v_buf := ',"' || TO_CHAR(v_range_start + (b * v_bucket_hours) / 24,
                                     'YYYY-MM-DD HH24:MI') || '"';
        END IF;
        DBMS_LOB.WRITEAPPEND(v_hours_json, LENGTH(v_buf), v_buf);
    END LOOP;
    DBMS_LOB.WRITEAPPEND(v_hours_json, 1, ']');

    -- Window-band markers, one per compared window, read from the shared
    -- windows_rollup CTE (per-week_offset roll-up of per-instance windows)
    -- so the band gets a single Y/N flag per offset regardless of RAC
    -- instance count.  Built in PL/SQL, not with LISTAGG: at about 50
    -- bytes a window, SQL's 4000-byte LISTAGG limit (ORA-01489) would
    -- abort the run past about 78 windows.
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts, win_end_ts, valid_flag
        FROM   windows_rollup
        ORDER BY week_offset DESC
    ) LOOP
        v_windows_json := v_windows_json || CASE WHEN v_windows_json IS NOT NULL THEN ',' END
            || '["' || TO_CHAR(r.win_start_ts, 'YYYY-MM-DD HH24:MI') || '","'
            || TO_CHAR(r.win_end_ts, 'YYYY-MM-DD HH24:MI') || '","'
            || CASE WHEN r.week_offset = 0 THEN 'current' ELSE 'w-' || r.week_offset END || '",'
            || CASE WHEN r.valid_flag = 'Y' THEN '"1"' ELSE '"0"' END || ']';
        v_valid := NVL(v_valid, '|') || r.week_offset || '=' || r.valid_flag || '|';
    END LOOP;
    v_windows_json := '[' || v_windows_json || ']';

    -- Emit JS in chunks so no single PUT_LINE exceeds 32767 bytes.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.ashTimeline = {');
    -- v_hours_json is a CLOB that may exceed 32767 bytes; emit chunked.
    DBMS_OUTPUT.PUT_LINE('hours:');
    put_clob_chunked(v_hours_json);
    DBMS_OUTPUT.PUT_LINE(',');
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
            -- Reuse the same CLOB across iterations: truncate to 0 then
            -- WRITEAPPEND. Avoids reallocating a temp LOB per class.
            DBMS_LOB.TRIM(v_class_vals, 0);
            FOR b IN 0 .. v_total_buckets - 1 LOOP
                v_ck := TO_CHAR(b) || '|' || v_wc;
                IF v_cells.EXISTS(v_ck) THEN
                    v_n := v_cells(v_ck);
                ELSE
                    v_n := 0;
                END IF;
                v_total_n := v_total_n + v_n;
                -- 360 ASH samples == one busy session-hour;
                -- divide by the bucket width (in hours) to get AAS.
                v_aas := v_n / (v_bucket_hours * 360);
                IF b = 0 THEN
                    v_buf := TO_CHAR(v_aas, 'FM99999990D0000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''');
                ELSE
                    v_buf := ',' || TO_CHAR(v_aas, 'FM99999990D0000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                END IF;
                DBMS_LOB.WRITEAPPEND(v_class_vals, LENGTH(v_buf), v_buf);
            END LOOP;

            IF v_first THEN v_first := FALSE;
            ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
            -- Emit '{"name":"...","vals":[' prefix, then the CLOB body
            -- chunked, then ']}'. Newlines between chunks are valid JS
            -- whitespace inside the array literal.
            DBMS_OUTPUT.PUT_LINE('{"name":"' || REPLACE(v_wc, '"', '\"')
                || '","vals":[');
            put_clob_chunked(v_class_vals);
            DBMS_OUTPUT.PUT_LINE(']}');
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
    DBMS_OUTPUT.PUT_LINE('var bandColor="rgba(37,99,235,0.10)", bandCurrent="rgba(37,99,235,0.22)", bandSkip="rgba(148,163,175,0.12)";');
    -- F15: honor w[3] (valid_flag) -- shade skipped windows in muted grey with
    -- a "skipped" label instead of a real blue band; and clamp the right edge
    -- to the last bucket label when the window end has no exact category anchor
    -- (the current window ends at last-label + bucket, which is off-grid), so
    -- the final band isn't dropped or short.
    DBMS_OUTPUT.PUT_LINE('var lastCat=(d.hours&&d.hours.length)?d.hours[d.hours.length-1]:null;');
    DBMS_OUTPUT.PUT_LINE('function buildMarkAreas(hiSlot){return (d.windows||[]).map(function(w){var valid=w[3]!=="0";var slotLabel=w[2]==="current"?"current":w[2];var hi=(hiSlot!=null)&&((hiSlot===0&&w[2]==="current")||("w-"+hiSlot===w[2]));var a={xAxis:w[0],name:w[2],itemStyle:{color:valid?(w[2]==="current"?bandCurrent:bandColor):bandSkip,opacity:hi?1:(hiSlot!=null?0.35:1),borderColor:hi?fg:null,borderWidth:hi?1.5:0}};if(!valid){a.label={show:true,position:"insideTop",color:mu,fontSize:9,formatter:"skipped",distance:1};}var end=w[1];if(lastCat!==null&&d.hours.indexOf(end)<0)end=lastCat;return [a,{xAxis:end}];});}');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=buildMarkAreas(null);');
    -- C3: hide the slider dataZoom (keep the inside/wheel one) when there
    -- are few enough buckets to read directly, and reclaim the vertical
    -- space the slider would have used.
    DBMS_OUTPUT.PUT_LINE('var showSlider=(d.hours||[]).length>24;');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  aria:{enabled:true,decal:{show:true}},');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('    valueFormatter:function(v){return v==null?"\u2014":(+v).toFixed(2);}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{top:0,left:"center",textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8,type:"scroll"},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:50,right:16,top:40,bottom:showSlider?60:24,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.hours,boundaryGap:false,axisLabel:{color:mu,fontSize:10,hideOverlap:true}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",name:"Active sessions",nameTextStyle:{color:mu,fontSize:11},axisLabel:{color:mu},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  dataZoom:[{type:"inside"},{type:"slider",show:showSlider,bottom:8,height:18,textStyle:{color:mu,fontSize:10}}],');
    DBMS_OUTPUT.PUT_LINE('  series:d.classes.map(function(c,i){');
    DBMS_OUTPUT.PUT_LINE('    var color=(window.AWR_WAIT_COLORS||{})[c.name]||palette[i%palette.length];');
    DBMS_OUTPUT.PUT_LINE('    var s={name:c.name,type:"line",stack:"total",smooth:false,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('      areaStyle:{opacity:0.85},emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('      lineStyle:{width:0.5,color:color},');
    DBMS_OUTPUT.PUT_LINE('      itemStyle:{color:color},');
    DBMS_OUTPUT.PUT_LINE('      data:c.vals};');
    DBMS_OUTPUT.PUT_LINE('    if(i===0 && markAreaData.length){');
    DBMS_OUTPUT.PUT_LINE('      s.markArea={silent:true,data:markAreaData,itemStyle:{opacity:1}};}');
    DBMS_OUTPUT.PUT_LINE('    if(i===0){var __ml=window.AWR_markLine&&window.AWR_markLine(d.hours); if(__ml) s.markLine=__ml;}');
    DBMS_OUTPUT.PUT_LINE('    return s;})');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    -- Re-apply axis/legend/dataZoom colors from the CSS vars on theme flip (F14).
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:theme",function(){var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888",gr2=c2.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({legend:{textStyle:{color:fg2}},xAxis:{axisLabel:{color:mu2}},yAxis:{nameTextStyle:{color:mu2},axisLabel:{color:mu2},splitLine:{lineStyle:{color:gr2}}},dataZoom:[{},{textStyle:{color:mu2}}]});});');
    -- X2: highlight the compared-window markArea band for slot w (0=current,
    -- 1=first prior, ...); null clears back to the default appearance.
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:window",function(e){var w=e.detail?e.detail.w:null;chart.setOption({series:[{markArea:{data:buildMarkAreas(w)}}]});});');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- Empty state: no ASH sample in the whole span -> say so and hide the
    -- (empty) chart box.  Emitted after the script so the demo twin's
    -- script slice is unaffected.
    IF v_total_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No ASH samples in '
            || 'DBA_HIST_ACTIVE_SESS_HISTORY for the compared span (an idle database, or '
            || 'ASH not flushed to AWR). Try a wider <code>win_hours</code>, more <code>weeks_back</code>, or a busier <code>target_end</code>.</p>');
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var e=document.getElementById("ash-timeline-stack");if(e)e.style.display="none";})();</script>');
    END IF;

    --
    -- v1.6.0 Timeline: the full-span chart's payload (AWR_DATA.ashx, see
    -- the header) and the Activity lane's row, both from the scan above.
    --
    DECLARE
        v_ci    VARCHAR2(64);
        v_i     PLS_INTEGER;
        v_k     PLS_INTEGER;
        v_nm    VARCHAR2(64);
        v_tmp   VARCHAR2(64);
        v_cov   NUMBER;
        v_n2    NUMBER;
        v_row   VARCHAR2(32767);
        v_tot   VARCHAR2(4000);
        v_leg   VARCHAR2(4000);
        v_gut   VARCHAR2(4000);
        v_cur   NUMBER;
        v_mu    NUMBER;
        v_sum   NUMBER;
        v_cnt   PLS_INTEGER;
        TYPE t_names IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
        TYPE t_nums  IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        v_cls   t_names;
        v_wtot  t_nums;          -- per window offset: total AAS
        v_cc    t_nums;          -- per class index: Current AAS
        v_cm    t_nums;          -- per class index: prior mean AAS
    BEGIN
        -- the classes in stacking order (insertion sort, a dozen at most)
        v_ci := v_class_totals.FIRST;
        WHILE v_ci IS NOT NULL LOOP
            v_i := v_cls.COUNT + 1;
            WHILE v_i > 1 AND (cls_rank(v_cls(v_i - 1)) > cls_rank(v_ci)
                    OR (cls_rank(v_cls(v_i - 1)) = cls_rank(v_ci) AND v_cls(v_i - 1) > v_ci)) LOOP
                v_cls(v_i) := v_cls(v_i - 1);
                v_i := v_i - 1;
            END LOOP;
            v_cls(v_i) := v_ci;
            v_ci := v_class_totals.NEXT(v_ci);
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.ashx={"t0":"'
            || TO_CHAR(v_range_start, 'YYYY-MM-DD HH24:MI') || '","end":"'
            || TO_CHAR(v_range_end, 'YYYY-MM-DD HH24:MI') || '","bh":' || wg_tok(v_bh)
            || ',"wh":' || wg_tok(~win_hours) || ',"classes":[');
        FOR c IN 1 .. v_cls.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE(CASE WHEN c > 1 THEN ',' END || '"' || REPLACE(v_cls(c), '"', '\"') || '"');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],"vals":[');
        FOR c IN 1 .. v_cls.COUNT LOOP
            DBMS_LOB.TRIM(v_class_vals, 0);
            FOR b IN 0 .. v_nc - 1 LOOP
                v_ck := TO_CHAR(b) || '|' || v_cls(c);
                v_n2 := CASE WHEN v_ccells.EXISTS(v_ck) THEN v_ccells(v_ck) ELSE 0 END;
                -- the last chart bucket may cover less than bh
                v_cov := LEAST(v_bh, v_total_hours - b * v_bh);
                v_buf := CASE WHEN b > 0 THEN ',' END
                    || aas_tok(CASE WHEN v_cov > 0 THEN v_n2 / (360 * v_cov) ELSE 0 END);
                DBMS_LOB.WRITEAPPEND(v_class_vals, LENGTH(v_buf), v_buf);
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(CASE WHEN c > 1 THEN ',' END || '[');
            put_clob_chunked(v_class_vals);
            DBMS_OUTPUT.PUT_LINE(']');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('],"win":[');
        FOR c IN 1 .. v_cls.COUNT LOOP
            v_row := NULL;
            v_sum := 0;
            v_cnt := 0;
            FOR k IN REVERSE 0 .. ~weeks_back LOOP
                v_ck := TO_CHAR(k) || '|' || v_cls(c);
                v_aas := CASE WHEN v_wcells.EXISTS(v_ck) THEN v_wcells(v_ck) ELSE 0 END / (360 * ~win_hours);
                v_row := v_row || CASE WHEN k < ~weeks_back THEN ',' END || aas_tok(v_aas);
                v_wtot(k) := CASE WHEN v_wtot.EXISTS(k) THEN v_wtot(k) ELSE 0 END + v_aas;
                IF k = 0 THEN
                    v_cc(c) := v_aas;
                ELSIF INSTR(v_valid, '|' || k || '=Y|') > 0 THEN
                    v_sum := v_sum + v_aas;
                    v_cnt := v_cnt + 1;
                END IF;
            END LOOP;
            v_cm(c) := CASE WHEN v_cnt > 0 THEN v_sum / v_cnt END;
            DBMS_OUTPUT.PUT_LINE(CASE WHEN c > 1 THEN ',' END || '[' || v_row || ']');
        END LOOP;
        -- foreground sessions only (the DB time card's chart)
        DBMS_OUTPUT.PUT_LINE('],"winfg":[');
        FOR c IN 1 .. v_cls.COUNT LOOP
            v_row := NULL;
            FOR k IN REVERSE 0 .. ~weeks_back LOOP
                v_ck := TO_CHAR(k) || '|' || v_cls(c);
                v_row := v_row || CASE WHEN k < ~weeks_back THEN ',' END
                    || aas_tok(CASE WHEN v_wfcells.EXISTS(v_ck) THEN v_wfcells(v_ck) ELSE 0 END
                               / (360 * ~win_hours));
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(CASE WHEN c > 1 THEN ',' END || '[' || v_row || ']');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(']};</script>');

        -- The Activity lane: one row of stacked columns (drawn client-side
        -- from ashx.win), the Current total printed, the gutter = total and
        -- the three largest classes vs the mean of the valid prior windows.
        IF v_total_n > 0 THEN
            v_sum := 0;
            v_cnt := 0;
            FOR k IN REVERSE 0 .. ~weeks_back LOOP
                v_tot := v_tot || CASE WHEN k < ~weeks_back THEN ',' END || wg_tok(v_wtot(k));
                IF k > 0 AND INSTR(v_valid, '|' || k || '=Y|') > 0 THEN
                    v_sum := v_sum + v_wtot(k);
                    v_cnt := v_cnt + 1;
                END IF;
            END LOOP;
            v_cur := v_wtot(0);
            v_mu  := CASE WHEN v_cnt > 0 THEN v_sum / v_cnt END;
            FOR c IN 1 .. v_cls.COUNT LOOP
                v_leg := v_leg || '<li><i class="sw" data-wc="' || DBMS_XMLGEN.CONVERT(v_cls(c))
                    || '"></i>' || DBMS_XMLGEN.CONVERT(v_cls(c)) || '</li>';
            END LOOP;
            v_gut := '<div class="g" role="cell" title="ASH active sessions, Current vs the mean of the '
                || 'valid prior windows; ASH is not scored"><div class="gl1">'
                || REPLACE(delta_span(v_cur, v_mu, NULL, 'Y'), 'class="d ', 'class="d d1 ')
                || '<span class="z">total</span></div>';
            -- the three classes with the most Current activity
            FOR n IN 1 .. LEAST(3, v_cls.COUNT) LOOP
                v_k := NULL;
                FOR c IN 1 .. v_cls.COUNT LOOP
                    IF (v_k IS NULL OR v_cc(c) > v_cc(v_k))
                       AND INSTR(v_gut, 'data-wc="' || DBMS_XMLGEN.CONVERT(v_cls(c)) || '"') = 0 THEN
                        v_k := c;
                    END IF;
                END LOOP;
                EXIT WHEN v_k IS NULL OR v_cc(v_k) <= 0;
                v_gut := v_gut || '<span class="d3"><i class="sw" data-wc="' || DBMS_XMLGEN.CONVERT(v_cls(v_k))
                    || '"></i>' || DBMS_XMLGEN.CONVERT(v_cls(v_k)) || ' '
                    || REGEXP_REPLACE(delta_span(v_cc(v_k), v_cm(v_k), NULL, 'Y'), '<[^>]+>', '') || '</span>';
            END LOOP;
            v_gut := v_gut || '</div>';
            v_row := '<div class="r ash" id="tl-ash-timeline" data-v="' || v_tot || '"'
                || ' data-name="Active sessions (ASH)" data-unit="AAS" role="row">'
                || '<div class="l" role="rowheader"><span class="nm">'
                || ent('Active sessions', 'ash-timeline', 'chart') || '</span>'
                || '<span class="sub">ASH, by wait class</span><ul class="leg">' || v_leg || '</ul>'
                || '<span class="axn" aria-hidden="true"></span></div>';
            FOR k IN REVERSE 0 .. ~weeks_back LOOP
                v_row := v_row || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END || '" data-w="' || k
                    || '"><span class="v">' || fmt_num(v_wtot(k)) || '</span></div>';
            END LOOP;
            DBMS_OUTPUT.PUT_LINE(tl_open('activity') || v_row || v_gut || '</div>' || tl_close);
        END IF;
    END;
    DBMS_OUTPUT.PUT_LINE('</section>');

    DBMS_LOB.FREETEMPORARY(v_hours_json);
    DBMS_LOB.FREETEMPORARY(v_class_vals);
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 09_ash_timeline END -->'); END;
/
