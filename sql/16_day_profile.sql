--
-- 16_day_profile.sql
-- Day profile: every hour of the 24 h ending at target_end, each scored
-- against the SAME hour-of-day on the profile_days prior days (1-day
-- cadence, independent of step / step_unit).  Answers "WHICH hour of the
-- day changed?" without running 24 separate reports.
--
-- Optional: profile_days = 0 (the default) emits nothing but the two
-- AWR-SECTION markers -- no <section>, no nav link (00_params guards the
-- link on the same var) -- so a default run is byte-identical to a build
-- without this section.
--
-- The 9 x 24 x (N+1) matrix comes from the shared CTE chain in
-- sql/lib/day_profile_cte.sql (also consumed by the fleet band).  This
-- section renders it three ways:
--   * an ECharts heatmap (hour x stat, cell = SIGNED z-score: direction
--     matters for a day profile, so the ramp is diverging, unlike section
--     07's |z| ramp),
--   * a per-stat line chart (current day vs prior-day mean, mu +/- 2 sigma
--     band, faint prior-day lines), picked via a <select>,
--   * a plain table (24 rows x 9 stats) that is ALWAYS emitted and doubles
--     as the body.no-charts fallback.  Rows carry class="crit|warn" when
--     any cell is large/moderate so the rail status dot grades.
-- Hours are labelled by hour-of-day, not a calendar axis, so no timeline
-- markers (AWR_markLine) are attached here.
-- Template-independent (fixed stat list).  Read-only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 16_day_profile BEGIN -->'); END;
/

DECLARE
    TYPE cell_rec IS RECORD (
        stat_name     VARCHAR2(64),
        ord           NUMBER,
        label         VARCHAR2(80),
        hour_slot     NUMBER,
        hour_label    VARCHAR2(5),
        hour_start    VARCHAR2(16),
        cur_val       NUMBER,
        mu            NUMBER,
        sd            NUMBER,
        n             NUMBER,
        day_vals      VARCHAR2(4000),
        z_score       NUMBER,
        pct_delta     NUMBER,
        change_bucket VARCHAR2(30)
    );
    TYPE cell_t   IS TABLE OF cell_rec INDEX BY PLS_INTEGER;
    TYPE idx_t    IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
    TYPE str_t    IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    TYPE fmt_t    IS TABLE OF VARCHAR2(40) INDEX BY PLS_INTEGER;
    TYPE num_t    IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    v_days      NUMBER := ~profile_days;
    v_cells     cell_t;
    v_idx       idx_t;
    v_nstat     PLS_INTEGER := 0;
    v_labels    str_t;        -- per ord: display label
    v_fmt       fmt_t;        -- per ord: TO_CHAR mask from the column max
    v_colmax    num_t;        -- per ord: max |value| seen (format mask input)
    v_max       NUMBER;
    v_json      CLOB;
    v_buf       VARCHAR2(32767);
    v_day_buf   str_t;        -- per day_off (1..N+1, oldest first): 24 tokens
    v_row       VARCHAR2(32767);
    v_cls       VARCHAR2(10);
    v_row_cls   VARCHAR2(10);
    v_crit      NUMBER := 0;
    v_warn      NUMBER := 0;
    v_hours_hit NUMBER := 0;
    v_hour_hit  BOOLEAN;
    v_has_cur   BOOLEAN := FALSE;   -- any current-day cell populated?
    v_key       VARCHAR2(40);
    v_tok       VARCHAR2(64);
    v_tend      DATE := TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS');
    c           cell_rec;
    c_null      cell_rec;     -- never assigned: used to blank c

    @@sql/lib/nth_csv.plsql
    @@sql/lib/put_clob_chunked.plsql

    -- JSON number token: null-safe, NLS-pinned.
    FUNCTION jn(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        RETURN TO_CHAR(p, 'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END;
    -- JSON string token (escapes backslash and double quote).
    FUNCTION js(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '"' || REPLACE(REPLACE(p, '\', '\\'), '"', '\"') || '"';
    END;
    FUNCTION bucket_cls(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p WHEN 'large' THEN 'crit' WHEN 'moderate' THEN 'warn'
                      WHEN 'typical' THEN 'ok' ELSE 'skip' END;
    END;
BEGIN
    IF v_days <= 0 THEN
        RETURN;
    END IF;

    WITH
    @@sql/lib/day_profile_cte.sql
    SELECT stat_name, ord, label, hour_slot, hour_label, hour_start,
           cur_val, mu, sd, n, day_vals, z_score, pct_delta, change_bucket
    BULK COLLECT INTO v_cells
    FROM   dp_scored
    ORDER BY ord, hour_slot DESC;

    DBMS_OUTPUT.PUT_LINE('<section id="day-profile">');

    -- The grid is dense (every stat x hour always has a row), so "no data"
    -- means no current-day cell carries a value at all.
    FOR i IN 1 .. v_cells.COUNT LOOP
        IF v_cells(i).cur_val IS NOT NULL THEN v_has_cur := TRUE; EXIT; END IF;
    END LOOP;
    IF NOT v_has_cur THEN
        DBMS_OUTPUT.PUT_LINE('<h2>Day profile &mdash; hour-of-day vs the '
            || v_days || ' prior days</h2>');
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No usable snapshot pairs in the '
            || '24 h ending ' || TO_CHAR(v_tend, 'YYYY-MM-DD HH24:MI')
            || ' &mdash; cannot build the profile.</p></section>');
        RETURN;
    END IF;

    -- Pass 1: index cells, per-column format masks, severity counters.
    FOR i IN 1 .. v_cells.COUNT LOOP
        c := v_cells(i);
        v_idx(c.ord || '|' || c.hour_slot) := i;
        IF NOT v_labels.EXISTS(c.ord) THEN
            v_labels(c.ord) := c.label;
            v_nstat := v_nstat + 1;
            v_colmax(c.ord) := 0;
        END IF;
        v_colmax(c.ord) := GREATEST(v_colmax(c.ord), NVL(ABS(c.cur_val), 0), NVL(ABS(c.mu), 0));
        IF c.change_bucket = 'large' THEN v_crit := v_crit + 1;
        ELSIF c.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
        END IF;
    END LOOP;
    FOR o IN 1 .. v_nstat LOOP
        v_max := v_colmax(o);
        v_fmt(o) := CASE
            WHEN v_max = 0 OR v_max >= 1000 THEN 'FM999G999G999G990'
            WHEN v_max >= 1                 THEN 'FM999G990D00'
            WHEN v_max >= 0.01              THEN 'FM990D0000'
            ELSE                                 'FM990D000000'
        END;
    END LOOP;
    -- Hours with at least one flagged cell.
    FOR h IN 0 .. 23 LOOP
        v_hour_hit := FALSE;
        FOR o IN 1 .. v_nstat LOOP
            v_key := o || '|' || h;
            IF v_idx.EXISTS(v_key)
               AND v_cells(v_idx(v_key)).change_bucket IN ('large', 'moderate') THEN
                v_hour_hit := TRUE;
            END IF;
        END LOOP;
        IF v_hour_hit THEN v_hours_hit := v_hours_hit + 1; END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('<h2>Day profile &mdash; hour-of-day vs the ' || v_days
        || ' prior day' || CASE WHEN v_days = 1 THEN '' ELSE 's' END || ' '
        || '<span class="badge crit">' || v_crit || ' large</span> '
        || '<span class="badge warn">' || v_warn || ' moderate</span> '
        || '<span class="badge info">' || v_hours_hit || ' of 24 hours flagged</span></h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Each hour of the 24 h ending <b>' || TO_CHAR(v_tend, 'Dy YYYY-MM-DD HH24:MI') || '</b> '
        || 'is compared with the <b>same hour-of-day</b> on the ' || v_days || ' prior day'
        || CASE WHEN v_days = 1 THEN '' ELSE 's' END
        || ' (' || TO_CHAR(v_tend - v_days - 1, 'YYYY-MM-DD') || ' &rarr; '
        || TO_CHAR(v_tend - 1, 'YYYY-MM-DD') || '), independent of the report cadence above. '
        || 'Per-second rates from DBA_HIST_SYSSTAT snapshot deltas (restart-guarded); '
        || 'an hour covered by less than 30 min of snapshots is left blank rather than shown as 0. '
        || 'Cells are scored like the Findings summary: <b>large</b> = |z| &gt; 3, '
        || '<b>moderate</b> = |z| &gt; 2, against the mean and standard deviation of the prior days '
        || '(needs at least 3 prior values). The heatmap shows <b>signed</b> z '
        || '(red = above the prior days, blue = below); pick a metric to see the hour-by-hour '
        || 'line against its prior-day band.</p>');

    -- Charts (hidden wholesale by body.no-charts; the table below is the fallback).
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-big" id="day-profile-heatmap"></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap" id="day-profile-line-wrap">'
        || '<div style="font-size:12px;color:var(--muted);margin:2px 4px 6px">Metric: '
        || '<select id="day-profile-sel">');
    FOR o IN 1 .. v_nstat LOOP
        DBMS_OUTPUT.PUT_LINE('<option value="' || (o - 1) || '">'
            || DBMS_XMLGEN.CONVERT(v_labels(o)) || '</option>');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</select> &mdash; current day (teal) vs prior-day mean (dashed) '
        || 'with the &mu;&nbsp;&plusmn;&nbsp;2&sigma; band; faint lines are the individual prior days.</div>'
        || '<div id="day-profile-line" style="height:240px"></div></div>');

    -- Table: one row per hour (chronological), one column per stat.
    v_row := '<table><thead><tr><th>Hour</th>';
    FOR o IN 1 .. v_nstat LOOP
        v_row := v_row || '<th class="num">' || DBMS_XMLGEN.CONVERT(v_labels(o)) || '</th>';
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(v_row || '</tr></thead><tbody>');
    FOR h IN REVERSE 0 .. 23 LOOP
        v_row_cls := '';
        v_row := '';
        FOR o IN 1 .. v_nstat LOOP
            v_key := o || '|' || h;
            IF NOT v_idx.EXISTS(v_key) THEN
                v_row := v_row || '<td class="num">&mdash;</td>';
                CONTINUE;
            END IF;
            c := v_cells(v_idx(v_key));
            v_cls := bucket_cls(c.change_bucket);
            IF v_cls = 'crit' THEN v_row_cls := 'crit';
            ELSIF v_cls = 'warn' AND v_row_cls <> 'crit' THEN v_row_cls := 'warn';
            END IF;
            v_row := v_row || '<td class="num" title="'
                || 'prior mean ' || CASE WHEN c.mu IS NULL THEN '-' ELSE TO_CHAR(c.mu, v_fmt(o)) END
                || ' / sd ' || CASE WHEN c.sd IS NULL THEN '-' ELSE TO_CHAR(c.sd, v_fmt(o)) END
                || ' / n ' || c.n
                || ' / z ' || CASE WHEN c.z_score IS NULL THEN '-' ELSE TO_CHAR(c.z_score, 'FMS9990D00') END
                || ' / ' || CASE WHEN c.pct_delta IS NULL THEN '-' ELSE TO_CHAR(c.pct_delta, 'FMS99990D0') || '%' END
                || ' / ' || c.change_bucket || '">'
                || CASE WHEN c.cur_val IS NULL THEN '&mdash;' ELSE TO_CHAR(c.cur_val, v_fmt(o)) END
                || CASE WHEN v_cls IN ('crit', 'warn')
                        THEN ' <span class="badge ' || v_cls || '">'
                             || TO_CHAR(c.z_score, 'FMS9990D0') || '&sigma;</span>'
                        ELSE '' END
                || '</td>';
        END LOOP;
        -- hour label from any stat's cell (all stats share the hour grid)
        v_key := '1|' || h;
        DBMS_OUTPUT.PUT_LINE('<tr data-hour="' || h || '"'
            || CASE WHEN v_row_cls IS NOT NULL THEN ' class="' || v_row_cls || '"' ELSE '' END
            || '><td>' || CASE WHEN v_idx.EXISTS(v_key)
                               THEN DBMS_XMLGEN.CONVERT(v_cells(v_idx(v_key)).hour_start)
                               ELSE TO_CHAR(h) END
            || '</td>' || v_row || '</tr>');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    -- JSON payload for the charts.
    DBMS_LOB.CREATETEMPORARY(v_json, TRUE);
    v_buf := '{ndays:' || v_days || ',hours:[';
    FOR h IN REVERSE 0 .. 23 LOOP
        v_key := '1|' || h;
        v_buf := v_buf || CASE WHEN h < 23 THEN ',' ELSE '' END
              || js(CASE WHEN v_idx.EXISTS(v_key) THEN v_cells(v_idx(v_key)).hour_label
                         ELSE TO_CHAR(h) END);
    END LOOP;
    v_buf := v_buf || '],dates:[';
    FOR d IN REVERSE 0 .. v_days LOOP
        v_buf := v_buf || CASE WHEN d < v_days THEN ',' ELSE '' END
              || js(TO_CHAR(v_tend - d, 'Dy DD Mon'));
    END LOOP;
    v_buf := v_buf || '],stats:[';
    DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);

    FOR o IN 1 .. v_nstat LOOP
        DECLARE
            v_cur  VARCHAR2(4000); v_mu VARCHAR2(4000); v_sd VARCHAR2(4000);
            v_n    VARCHAR2(4000); v_z  VARCHAR2(4000); v_pct VARCHAR2(4000);
            v_sev  VARCHAR2(4000);
        BEGIN
            FOR d IN 1 .. v_days + 1 LOOP v_day_buf(d) := ''; END LOOP;
            FOR h IN REVERSE 0 .. 23 LOOP
                v_key := o || '|' || h;
                IF v_idx.EXISTS(v_key) THEN
                    c := v_cells(v_idx(v_key));
                ELSE
                    c := c_null;
                END IF;
                v_cur := v_cur || ',' || jn(c.cur_val);
                v_mu  := v_mu  || ',' || jn(c.mu);
                v_sd  := v_sd  || ',' || jn(c.sd);
                v_n   := v_n   || ',' || NVL(c.n, 0);
                v_z   := v_z   || ',' || jn(c.z_score);
                v_pct := v_pct || ',' || jn(ROUND(c.pct_delta, 1));
                v_sev := v_sev || ',' || js(NVL(c.change_bucket, 'n/a'));
                FOR d IN 1 .. v_days + 1 LOOP
                    v_tok := nth_csv(c.day_vals, d);
                    v_day_buf(d) := v_day_buf(d) || ','
                        || CASE WHEN v_tok IS NULL THEN 'null' ELSE v_tok END;
                END LOOP;
            END LOOP;
            v_buf := CASE WHEN o > 1 THEN ',' ELSE '' END
                || '{name:' || js(v_labels(o))
                || ',cur:['  || SUBSTR(v_cur, 2) || ']'
                || ',mu:['   || SUBSTR(v_mu, 2)  || ']'
                || ',sd:['   || SUBSTR(v_sd, 2)  || ']'
                || ',n:['    || SUBSTR(v_n, 2)   || ']'
                || ',z:['    || SUBSTR(v_z, 2)   || ']'
                || ',pct:['  || SUBSTR(v_pct, 2) || ']'
                || ',sev:['  || SUBSTR(v_sev, 2) || ']'
                || ',days:[';
            DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);
            FOR d IN 1 .. v_days + 1 LOOP
                v_buf := CASE WHEN d > 1 THEN ',' ELSE '' END
                      || '[' || SUBSTR(v_day_buf(d), 2) || ']';
                DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);
            END LOOP;
            v_buf := ']}';
            DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);
        END;
    END LOOP;
    v_buf := ']}';
    DBMS_LOB.WRITEAPPEND(v_json, LENGTH(v_buf), v_buf);

    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.dayProfile=');
    put_clob_chunked(v_json);
    DBMS_OUTPUT.PUT_LINE(';');
    DBMS_LOB.FREETEMPORARY(v_json);
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.dayProfile;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("day-profile-heatmap"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var fmt=function(v){return v==null?"\u2014":(+v).toLocaleString(undefined,{maximumFractionDigits:3});};');
    DBMS_OUTPUT.PUT_LINE('var data=[];d.stats.forEach(function(s,i){s.z.forEach(function(z,j){data.push({value:[j,i,z==null?null:Math.max(-3.5,Math.min(3.5,z))],raw:{i:i,j:j}});});});');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{formatter:function(p){if(!p.data||!p.data.raw)return "";var s=d.stats[p.data.raw.i],j=p.data.raw.j;return "<b>"+s.name+"</b> @ "+d.hours[j]+"<br/>change: <b>"+s.sev[j]+"</b><br/>current: "+fmt(s.cur[j])+"<br/>prior \u03BC: "+fmt(s.mu[j])+" (\u03C3 "+fmt(s.sd[j])+", n="+s.n[j]+")<br/>z-score: "+(s.z[j]==null?"\u2014":(+s.z[j]).toFixed(2))+"<br/>% \u0394: "+(s.pct[j]==null?"\u2014":s.pct[j]+"%");}},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:10,right:10,top:10,bottom:70,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.hours,axisLabel:{color:mu,fontSize:10,interval:0},splitArea:{show:true}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"category",data:d.stats.map(function(s){return s.name;}),inverse:true,axisLabel:{color:fg,fontSize:10},splitArea:{show:true}},');
    DBMS_OUTPUT.PUT_LINE('  visualMap:{min:-3.5,max:3.5,calculable:true,orient:"horizontal",left:"center",bottom:8,itemWidth:12,itemHeight:160,textStyle:{color:mu,fontSize:10},inRange:{color:["#1d4ed8","#93c5fd","#eef1f5","#fca5a5","#8a1c1c"]},text:["z\u2265+3","z\u2264\u22123"]},');
    DBMS_OUTPUT.PUT_LINE('  series:[{name:"z",type:"heatmap",data:data,label:{show:false},emphasis:{itemStyle:{borderColor:fg,borderWidth:1.5}}}]');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    -- Line chart: current day vs prior-day mean and mu +/- 2 sigma band.
    DBMS_OUTPUT.PUT_LINE('var lel=document.getElementById("day-profile-line"),sel=document.getElementById("day-profile-sel");');
    DBMS_OUTPUT.PUT_LINE('var line=lel?echarts.init(lel):null;');
    DBMS_OUTPUT.PUT_LINE('function drawLine(i){if(!line)return;var s=d.stats[i],ser=[];');
    DBMS_OUTPUT.PUT_LINE('  for(var k=0;k<s.days.length-1;k++){ser.push({name:d.dates[k],type:"line",data:s.days[k],symbol:"none",lineStyle:{width:1,color:"rgba(148,163,184,0.55)"},emphasis:{disabled:true}});}');
    DBMS_OUTPUT.PUT_LINE('  var lo=s.mu.map(function(m,j){return m==null||s.sd[j]==null?null:m-2*s.sd[j];}),w=s.mu.map(function(m,j){return m==null||s.sd[j]==null?null:4*s.sd[j];});');
    DBMS_OUTPUT.PUT_LINE('  ser.push({name:"band-lo",type:"line",data:lo,stack:"band",symbol:"none",lineStyle:{opacity:0},areaStyle:{opacity:0},emphasis:{disabled:true},tooltip:{show:false}});');
    DBMS_OUTPUT.PUT_LINE('  ser.push({name:"\u03BC \u00B1 2\u03C3",type:"line",data:w,stack:"band",symbol:"none",lineStyle:{opacity:0},areaStyle:{color:"rgba(37,99,235,0.14)"},emphasis:{disabled:true},tooltip:{show:false}});');
    DBMS_OUTPUT.PUT_LINE('  ser.push({name:"prior-day mean",type:"line",data:s.mu,symbol:"none",lineStyle:{width:1.5,type:"dashed",color:"#2563eb"},itemStyle:{color:"#2563eb"}});');
    DBMS_OUTPUT.PUT_LINE('  ser.push({name:"current day",type:"line",data:s.cur,symbol:"circle",symbolSize:5,lineStyle:{width:2.5,color:"#0d9488"},itemStyle:{color:"#0d9488"}});');
    DBMS_OUTPUT.PUT_LINE('  var c3=getComputedStyle(document.body),fg3=c3.getPropertyValue("--fg").trim()||"#333",mu3=c3.getPropertyValue("--muted").trim()||"#888",gr3=c3.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('  line.setOption({tooltip:{trigger:"axis",valueFormatter:function(v){return fmt(v);}},legend:{top:0,data:["current day","prior-day mean","\u03BC \u00B1 2\u03C3"],textStyle:{color:fg3,fontSize:11}},grid:{left:50,right:16,top:34,bottom:28,containLabel:true},xAxis:{type:"category",data:d.hours,boundaryGap:false,axisLabel:{color:mu3,fontSize:10}},yAxis:{type:"value",name:s.name,nameTextStyle:{color:mu3,fontSize:11},axisLabel:{color:mu3},splitLine:{lineStyle:{color:gr3}}},series:ser},true);}');
    DBMS_OUTPUT.PUT_LINE('if(sel){sel.addEventListener("change",function(){drawLine(+sel.value);});drawLine(+sel.value||0);}');
    DBMS_OUTPUT.PUT_LINE('if(line){new ResizeObserver(function(){line.resize();}).observe(lel);}');
    -- Click a heatmap cell: switch the line chart to that stat and flash the hour row.
    DBMS_OUTPUT.PUT_LINE('chart.on("click",function(p){if(!p.data||!p.data.raw)return;var r=p.data.raw;if(sel){sel.value=String(r.i);drawLine(r.i);}var row=document.querySelector("#day-profile tr[data-hour=\""+(23-r.j)+"\"]");if(row){row.scrollIntoView({behavior:"smooth",block:"center"});row.style.transition="outline 1.5s";row.style.outline="2px solid "+cs.getPropertyValue("--accent");setTimeout(function(){row.style.outline="none";},1600);}});');
    -- Theme flip: re-read the CSS vars; the diverging ramp itself is theme-independent.
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("awr:theme",function(){var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({xAxis:{axisLabel:{color:mu2}},yAxis:{axisLabel:{color:fg2}},visualMap:{textStyle:{color:mu2}},series:[{emphasis:{itemStyle:{borderColor:fg2}}}]});if(sel)drawLine(+sel.value||0);});');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 16_day_profile END -->'); END;
/
