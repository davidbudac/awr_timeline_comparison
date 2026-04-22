--
-- 06_top_sql.sql
-- Top-N SQL per window from DBA_HIST_SQLSTAT using the pre-computed *_DELTA
-- columns.  Ranks the same SQLs four times: by elapsed_time_delta,
-- cpu_time_delta, buffer_gets_delta, executions_delta.  Joins DBA_HIST_SQLTEXT
-- for a short text snippet.  Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_weeks_json VARCHAR2(4000);
    v_sql_json   CLOB;
    v_cur_dim    VARCHAR2(10);
    v_val        NUMBER;
    v_val_s      VARCHAR2(64);
    v_rnk_s      VARCHAR2(64);
    v_phv_s      VARCHAR2(64);

    TYPE t_sqlid_tab IS TABLE OF BOOLEAN INDEX BY VARCHAR2(30);
    v_seen_sqls t_sqlid_tab;

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
    DBMS_OUTPUT.PUT_LINE('<section id="topsql"><h2>Top SQL (top ' || v_top_n
        || ' per dimension, per window)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Bump chart below shows SQL rank movement across weeks (lower = heavier). '
        || 'Red diamonds mark plan-hash changes vs current. '
        || 'Detail tables are collapsed by default &mdash; click to expand.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="topsql-bump"></div>');

    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - 7*week_offset, 'Mon DD') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);

    -- Bump chart data (ELAPSED dimension) ---------------------------------
    v_sql_json := NULL;
    FOR s IN (
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
                   CAST(r.target_end_ts AS DATE) - 7*o.week_offset - r.win_hours/24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - 7*o.week_offset                   AS win_end_dt
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
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS elapsed_time_delta_us
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR s.instance_number = w.instance_number)
            GROUP BY w.week_offset, s.sql_id
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY elapsed_time_delta_us DESC, sql_id) AS rnk
            FROM   agg a
            WHERE  elapsed_time_delta_us > 0
        ),
        top_n_sqls AS (
            SELECT * FROM ranked WHERE rnk <= (SELECT top_n FROM run_params)
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        sqls AS (
            SELECT DISTINCT sql_id FROM top_n_sqls
        ),
        grid AS (
            SELECT q.sql_id, w.week_offset, t.rnk, t.plan_hash_value, t.elapsed_time_delta_us
            FROM   sqls q CROSS JOIN all_weeks w
            LEFT JOIN top_n_sqls t
                   ON t.sql_id = q.sql_id AND t.week_offset = w.week_offset
        ),
        cur_phv AS (
            SELECT sql_id,
                   MAX(CASE WHEN week_offset = 0 THEN plan_hash_value END) AS phv_cur
            FROM   grid
            GROUP BY sql_id
        )
        SELECT g.sql_id,
               MIN(CASE WHEN g.week_offset = 0 THEN g.rnk END) AS cur_rnk,
               MIN(g.rnk) AS best_rank,
               LISTAGG(CASE WHEN g.rnk IS NULL THEN 'null'
                            ELSE TO_CHAR(g.rnk) END, ',')
                   WITHIN GROUP (ORDER BY g.week_offset DESC) AS ranks_csv,
               LISTAGG(CASE
                           WHEN g.plan_hash_value IS NULL THEN '0'
                           WHEN cp.phv_cur IS NOT NULL AND g.plan_hash_value <> cp.phv_cur THEN '1'
                           ELSE '0' END, ',')
                   WITHIN GROUP (ORDER BY g.week_offset DESC) AS phv_flag_csv,
               LISTAGG(CASE WHEN g.elapsed_time_delta_us IS NULL THEN 'null'
                            ELSE TO_CHAR(g.elapsed_time_delta_us/1e6, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY g.week_offset DESC) AS ela_csv
        FROM   grid g
        LEFT JOIN cur_phv cp ON cp.sql_id = g.sql_id
        GROUP BY g.sql_id
        ORDER BY CASE WHEN MIN(CASE WHEN g.week_offset = 0 THEN g.rnk END) IS NULL THEN 1 ELSE 0 END,
                 MIN(CASE WHEN g.week_offset = 0 THEN g.rnk END) NULLS LAST,
                 MIN(g.rnk),
                 g.sql_id
    ) LOOP
        v_sql_json := CASE WHEN v_sql_json IS NULL THEN '' ELSE v_sql_json || ',' END
            || '{"sql_id":"' || s.sql_id
            || '","cur":' || NVL(TO_CHAR(s.cur_rnk), 'null')
            || ',"ranks":[' || s.ranks_csv
            || '],"phvChg":[' || s.phv_flag_csv
            || '],"ela":[' || s.ela_csv || ']}';
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.topSql = {weeks:' || v_weeks_json
        || ',topN:' || v_top_n || ',sqls:[' || NVL(v_sql_json, '') || ']};');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var el=document.getElementById("topsql-bump"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.topSql;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var cr=cs.getPropertyValue("--crit-fg").trim()||"#c00";');
    DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
    DBMS_OUTPUT.PUT_LINE('var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('  tooltip:{trigger:"item",formatter:function(p){var s=p.data;if(!s||!s.sql_id)return p.seriesName;return "<b>"+s.sql_id+"</b><br/>week "+p.name+"<br/>rank: "+(s.value[1]||"\u2014")+"<br/>ela: "+(s.ela==null?"\u2014":s.ela.toFixed(2)+"s")+(s.phvChg?"<br/><span style=\"color:"+cr+"\">\u25C6 plan changed</span>":"");}},');
    DBMS_OUTPUT.PUT_LINE('  legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
    DBMS_OUTPUT.PUT_LINE('  grid:{left:40,right:100,top:10,bottom:44,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('  xAxis:{type:"category",data:d.weeks,axisLabel:{color:fg,fontWeight:600},splitLine:{show:true,lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  yAxis:{type:"value",inverse:true,min:1,max:d.topN,axisLabel:{color:mu,formatter:function(v){return "#"+v;}},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('  series:d.sqls.slice(0,d.topN).map(function(s,i){');
    DBMS_OUTPUT.PUT_LINE('    var pts=s.ranks.map(function(r,j){return {value:[j,r],name:d.weeks[j],sql_id:s.sql_id,ela:s.ela[j],phvChg:!!s.phvChg[j]};});');
    DBMS_OUTPUT.PUT_LINE('    var diamonds=s.phvChg.map(function(p,j){return p?{value:[j,s.ranks[j]],itemStyle:{color:cr},symbol:"diamond",symbolSize:12}:null;}).filter(Boolean);');
    DBMS_OUTPUT.PUT_LINE('    return {name:s.sql_id,type:"line",connectNulls:false,showSymbol:true,symbolSize:8,itemStyle:{color:palette[i%palette.length]},lineStyle:{width:2},emphasis:{focus:"series",lineStyle:{width:3}},endLabel:{show:true,formatter:"{a}",color:fg,fontSize:10,distance:6},data:pts,markPoint:diamonds.length?{data:diamonds}:undefined};');
    DBMS_OUTPUT.PUT_LINE('  })');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- Per-dimension detail tables, packed into one big cursor. ------------
    v_cur_dim := NULL;
    FOR s IN (
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
                   CAST(r.target_end_ts AS DATE) - 7*o.week_offset - r.win_hours/24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - 7*o.week_offset                   AS win_end_dt
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
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
                   SUM(NVL(s.executions_delta, 0))     AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0))   AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0))       AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0))    AS buffer_gets_delta
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND (w.instance_number IS NULL OR s.instance_number = w.instance_number)
            GROUP BY w.week_offset, s.sql_id
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY elapsed_time_delta_us DESC, sql_id) AS r_ela,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY cpu_time_delta_us DESC, sql_id)     AS r_cpu,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY buffer_gets_delta DESC, sql_id)     AS r_gets,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY executions_delta DESC, sql_id)      AS r_exec
            FROM   agg a
        ),
        picked AS (
            SELECT 'ELAPSED' AS dim, week_offset, sql_id, plan_hash_value,
                   elapsed_time_delta_us AS metric_value, r_ela AS rnk
            FROM ranked WHERE r_ela <= (SELECT top_n FROM run_params) AND elapsed_time_delta_us > 0
            UNION ALL
            SELECT 'CPU', week_offset, sql_id, plan_hash_value,
                   cpu_time_delta_us, r_cpu
            FROM ranked WHERE r_cpu <= (SELECT top_n FROM run_params) AND cpu_time_delta_us > 0
            UNION ALL
            SELECT 'GETS', week_offset, sql_id, plan_hash_value,
                   buffer_gets_delta, r_gets
            FROM ranked WHERE r_gets <= (SELECT top_n FROM run_params) AND buffer_gets_delta > 0
            UNION ALL
            SELECT 'EXEC', week_offset, sql_id, plan_hash_value,
                   executions_delta, r_exec
            FROM ranked WHERE r_exec <= (SELECT top_n FROM run_params) AND executions_delta > 0
        ),
        dims AS (
            SELECT 'ELAPSED' code, 1 ord, 'By elapsed time' label, 's'    unit, 1e6 divs FROM dual UNION ALL
            SELECT 'CPU',      2,     'By CPU time',         's',         1e6      FROM dual UNION ALL
            SELECT 'GETS',     3,     'By buffer gets',      'gets',      1        FROM dual UNION ALL
            SELECT 'EXEC',     4,     'By executions',       'exec',      1        FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        sqls AS (
            SELECT DISTINCT dim, sql_id FROM picked
        ),
        grid AS (
            SELECT q.dim, q.sql_id, w.week_offset,
                   p.metric_value, p.rnk, p.plan_hash_value
            FROM   sqls q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.sql_id = q.sql_id AND p.week_offset = w.week_offset
        ),
        per_sql AS (
            SELECT dim, sql_id,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END)     AS cur_val,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)              AS cur_rnk,
                   MAX(CASE WHEN week_offset = 0 THEN plan_hash_value END)  AS cur_phv,
                   MIN(rnk) AS best_rank,
                   MAX(metric_value) AS best_value,
                   LISTAGG(CASE WHEN metric_value IS NULL THEN ''
                                ELSE TO_CHAR(metric_value, 'FM99999999999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals,
                   LISTAGG(CASE WHEN rnk IS NULL THEN '' ELSE TO_CHAR(rnk) END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_rnks,
                   LISTAGG(CASE WHEN plan_hash_value IS NULL THEN ''
                                ELSE TO_CHAR(plan_hash_value) END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_phvs
            FROM   grid
            GROUP BY dim, sql_id
        ),
        text_snips AS (
            SELECT sql_id, sql_text_short FROM (
                SELECT sql_id,
                       DBMS_LOB.SUBSTR(sql_text, 400, 1) AS sql_text_short,
                       ROW_NUMBER() OVER (PARTITION BY dbid, sql_id ORDER BY ROWID) AS rn
                FROM   dba_hist_sqltext
                WHERE  dbid = ~dbid
            ) WHERE rn = 1
        )
        SELECT d.code AS dim, d.ord AS dim_ord, d.label AS dim_label,
               d.unit AS dim_unit, d.divs AS dim_div,
               ps.sql_id, ps.cur_val, ps.cur_rnk, ps.cur_phv,
               ps.week_vals, ps.week_rnks, ps.week_phvs,
               ts.sql_text_short
        FROM   dims d
        JOIN   per_sql ps ON ps.dim = d.code
        LEFT JOIN text_snips ts ON ts.sql_id = ps.sql_id
        ORDER BY d.ord,
            CASE WHEN ps.cur_rnk IS NULL THEN 1 ELSE 0 END,
            ps.cur_rnk NULLS LAST,
            ps.best_rank,
            ps.best_value DESC,
            ps.sql_id
    ) LOOP
        IF v_cur_dim IS NULL OR v_cur_dim <> s.dim THEN
            IF v_cur_dim IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
            END IF;
            v_cur_dim := s.dim;

            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>' || s.dim_label || ' &mdash; detail table</summary>');

            v_header := '<thead><tr><th>SQL_ID</th><th class="num">PHV (cur)</th>'
                || '<th class="num">Current (' || s.dim_unit || ')</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                v_header := v_header || '<th class="num">&minus;' || k || 'w</th>';
            END LOOP;
            v_header := v_header || '<th>SQL</th></tr></thead>';
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
        END IF;

        v_seen_sqls(s.sql_id) := TRUE;

        v_row := '<tr>'
            || '<td class="mono">' || s.sql_id || '</td>'
            || '<td class="num mono">' ||
                CASE WHEN s.cur_phv IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.cur_phv) END
            || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN s.cur_val IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.cur_val/s.dim_div, 'FM999G999G999G990D00') END
            || CASE WHEN s.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || s.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(s.week_vals, k + 1);
            v_rnk_s := nth_csv(s.week_rnks, k + 1);
            v_phv_s := nth_csv(s.week_phvs, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_val/s.dim_div, 'FM999G999G999G990D00');
            END IF;
            IF v_rnk_s IS NOT NULL AND v_rnk_s <> '' THEN
                v_row := v_row || ' <span class="badge skip">#' || v_rnk_s || '</span>';
            END IF;
            IF v_phv_s IS NOT NULL AND v_phv_s <> '' AND s.cur_phv IS NOT NULL
               AND TO_NUMBER(v_phv_s) <> s.cur_phv THEN
                v_row := v_row || ' <span class="badge warn" title="Plan changed. Prior PHV '
                      || v_phv_s || '">plan&#8593;</span>';
            END IF;
            v_row := v_row || '</td>';
        END LOOP;

        v_row := v_row || '<td class="mono" style="max-width:500px;">'
            || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(s.sql_text_short, ''), 1, 180))
            || CASE WHEN LENGTH(NVL(s.sql_text_short, '')) > 180 THEN '&hellip;' END
            || '</td>';

        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    IF v_cur_dim IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
    END IF;

    -- Full SQL text dump for all SQL_IDs that appeared in any dimension --
    DBMS_OUTPUT.PUT_LINE('<details><summary>Full SQL text for all listed SQL_IDs</summary>');
    DECLARE
        v_sql_id VARCHAR2(30);
        v_text   CLOB;
        v_len    NUMBER;
        v_snip   VARCHAR2(8000);
    BEGIN
        v_sql_id := v_seen_sqls.FIRST;
        WHILE v_sql_id IS NOT NULL LOOP
            BEGIN
                SELECT sql_text
                INTO   v_text
                FROM (
                    SELECT sql_text,
                           ROW_NUMBER() OVER (PARTITION BY dbid, sql_id ORDER BY ROWID) AS rn
                    FROM   dba_hist_sqltext
                    WHERE  dbid = ~dbid AND sql_id = v_sql_id
                ) WHERE rn = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_text := NULL;
            END;

            IF v_text IS NULL THEN
                v_len  := 0;
                v_snip := '(text not in DBA_HIST_SQLTEXT)';
            ELSE
                v_len  := DBMS_LOB.GETLENGTH(v_text);
                v_snip := DBMS_LOB.SUBSTR(v_text, 8000, 1);
            END IF;

            DBMS_OUTPUT.PUT_LINE('<h3>' || v_sql_id || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || DBMS_XMLGEN.CONVERT(v_snip)
                || CASE WHEN v_len > 8000
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');

            v_sql_id := v_seen_sqls.NEXT(v_sql_id);
        END LOOP;
    END;
    DBMS_OUTPUT.PUT_LINE('</details>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
