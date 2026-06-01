--
-- 11_top_sql_ash_breakdown.sql
-- Per-SQL ASH wait-event breakdown: for each SQL in section 06's top-N
-- pool (any of the 4 ranking dimensions + the per-exec regression),
-- render a stacked-area ECharts timeline showing how that SQL spent its
-- active time across individual wait events and CPU, bucketed by
-- bucket_hours and spanning the same target_end .. target_end-weeks_back
-- range as section 09.
--
-- Pool source: replicates section 06's windows + agg + ranked +
-- per_exec + delta_ranked + picked CTE chain inline (read-only
-- invariant: no shared state between sections). DISTINCT sql_id from
-- every ranking dim is the candidate set, then re-ranked by total ASH
-- samples and capped at v_max_charts entries so the report stays
-- bounded on busy DBs.
--
-- Per-SQL legend cap: top v_top_events individual event names (by
-- sample count) are rendered; the remainder lump into a single 'Other'
-- series. ON-CPU samples are a synthetic 'CPU' series. Idle waits are
-- excluded.
--
-- Coloring: js_wait_colors.plsql is wait_class-only and unusable for
-- individual event names. Section emits a small deterministic
-- event-name -> HSL hash function inline so the same event paints the
-- same color across every per-SQL chart on the page.
--
-- Read-only: pure SELECT against dba_hist_sqlstat, dba_hist_snapshot,
-- dba_hist_active_sess_history, and dba_hist_sqltext. No scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 11_top_sql_ash_breakdown BEGIN -->'); END;
/

DECLARE
    -- Per-SQL display caps.
    v_top_events    CONSTANT PLS_INTEGER := 7;
    v_max_charts    CONSTANT PLS_INTEGER := 30;
    v_min_samples   CONSTANT PLS_INTEGER := 5;

    v_range_start   DATE;
    v_range_end     DATE;
    v_bucket_hours  NUMBER := ~bucket_hours;
    v_total_hours   NUMBER;
    v_total_buckets NUMBER;
    v_bucket_label  VARCHAR2(32);

    -- v_hours_json and v_event_vals are CLOBs so a long span with many
    -- buckets (e.g. weeks_back=4 at 15-min cadence builds 2700+ slots)
    -- cannot overflow PL/SQL's 32767-byte VARCHAR2 hard cap. Same
    -- reasoning as section 09 (commit e65d671). v_windows_json stays
    -- VARCHAR2 since it is bounded by weeks_back+1.
    v_hours_json    CLOB;
    v_event_vals    CLOB;
    v_windows_json  VARCHAR2(4000);
    v_buf           VARCHAR2(512);

    -- Cell store: key sql_id|bucket|event -> sample count.
    -- Totals: sql_id|event and sql_id, used for legend ordering and
    -- the per-card "dominant event" / "total samples" header line.
    TYPE t_num_by_str  IS TABLE OF NUMBER       INDEX BY VARCHAR2(200);
    TYPE t_str_by_str  IS TABLE OF VARCHAR2(256) INDEX BY VARCHAR2(30);
    v_cells         t_num_by_str;
    v_evt_totals    t_num_by_str;
    v_sql_totals    t_num_by_str;
    v_sql_dom       t_str_by_str;
    v_sql_text      t_str_by_str;

    v_evt_key       VARCHAR2(200);
    v_cell_key      VARCHAR2(200);
    v_sid           VARCHAR2(30);
    v_evt           VARCHAR2(128);
    v_n             NUMBER;
    v_aas           NUMBER;
    v_dom_n         NUMBER;
    v_first_sql     BOOLEAN;
    v_first_evt     BOOLEAN;
    v_rendered      PLS_INTEGER := 0;
    v_skipped       PLS_INTEGER := 0;

    -- Ordered (sql_id, total) list for per-SQL emission in descending
    -- ASH-activity order. Small (<= v_max_charts), so a selection sort
    -- in PL/SQL is cheaper than a SQL ORDER BY round-trip.
    TYPE t_sid_rec IS RECORD (sid VARCHAR2(30), tot NUMBER);
    TYPE t_sid_tab IS TABLE OF t_sid_rec;
    v_order         t_sid_tab := t_sid_tab();
    v_swap          t_sid_rec;

    -- Per-emit event list (collected fresh per SQL from v_evt_totals).
    TYPE t_evt_rec  IS RECORD (evt VARCHAR2(128), tot NUMBER);
    TYPE t_evt_tab  IS TABLE OF t_evt_rec;
    v_events        t_evt_tab;
    v_evt_swap      t_evt_rec;
    v_prefix        VARCHAR2(40);

    @@sql/lib/put_clob_chunked.plsql
BEGIN
    DBMS_LOB.CREATETEMPORARY(v_hours_json, TRUE);
    DBMS_LOB.CREATETEMPORARY(v_event_vals, TRUE);

    -- Same range and bucket label as section 09.
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

    DBMS_OUTPUT.PUT_LINE('<section id="topsql-ash"><h2>Top SQL ASH breakdown '
        || '(' || CASE WHEN v_bucket_hours = 1 THEN 'hourly' ELSE v_bucket_label END
        || ', per SQL, stacked by wait event)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 10px 0">'
        || 'For each SQL in the Top-N pool (union across all ranking dimensions), '
        || 'per-bucket ASH samples split by individual wait event '
        || '(top ' || v_top_events || ' per SQL by sample count; '
        || 'remainder grouped as <b>Other</b>; <b>CPU</b> = ON-CPU). '
        || '<code>dba_hist_active_sess_history</code>, '
        || TO_CHAR(CAST(v_range_start AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || ' &rarr; '
        || TO_CHAR(CAST(v_range_end   AS TIMESTAMP), 'YYYY-MM-DD HH24:MI')
        || ', '
        || CASE WHEN v_bucket_hours = 1 THEN 'hourly' ELSE v_bucket_label END
        || ' buckets. Compared windows shaded. '
        || 'SQLs with fewer than ' || v_min_samples
        || ' samples appear as placeholders.</p>');

    -- Shared bucket-label grid (one entry per chart-X-axis tick).
    -- Same logic as section 09 lines 144-155.
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

    -- Window-band markers. Same shape and source as section 09 lines 161-179.
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

    -- Single big ASH cursor:
    --   * re-derive section 06's "picked" pool inline (no shared state),
    --   * rank that pool by total ASH activity, cap to v_max_charts,
    --   * bucket ASH by (sql_id, bucket_key, event_name) over the
    --     full timeline range, with ON-CPU mapped to 'CPU',
    --   * per-SQL DENSE_RANK events by sample count and lump rank >
    --     v_top_events into 'Other'.
    --
    -- agg/ranked/per_exec/delta_ranked/picked are verbatim slices of
    -- sql/06_top_sql.sql lines 91-189. Kept in sync by hand; if 06
    -- changes its pool definition, mirror it here.
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   SUM(NVL(s.executions_delta, 0))     AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0))   AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0))       AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0))    AS buffer_gets_delta
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
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
        per_exec AS (
            SELECT week_offset, sql_id, executions_delta,
                   CASE WHEN executions_delta > 0
                        THEN elapsed_time_delta_us / executions_delta
                   END AS per_exec_us
            FROM   agg
        ),
        delta_ranked AS (
            SELECT sql_id,
                   ROW_NUMBER() OVER (ORDER BY (cur_pe - prior_pe) DESC NULLS LAST,
                                               sql_id) AS r_delta
            FROM (
                SELECT sql_id,
                       MAX(CASE WHEN week_offset = 0 THEN per_exec_us      END) AS cur_pe,
                       AVG(CASE WHEN week_offset > 0 THEN per_exec_us      END) AS prior_pe,
                       COUNT(CASE WHEN week_offset > 0 AND per_exec_us IS NOT NULL
                                  THEN 1 END)                                    AS n_prior_pe,
                       MAX(CASE WHEN week_offset = 0 THEN executions_delta END) AS cur_execs
                FROM   per_exec
                GROUP BY sql_id
            )
            WHERE cur_pe   IS NOT NULL
              AND prior_pe IS NOT NULL
              AND n_prior_pe >= 1
              AND cur_pe   > prior_pe
              AND cur_execs >= 3
        ),
        picked AS (
            SELECT sql_id FROM ranked
            WHERE r_ela <= (SELECT top_n FROM run_params) AND elapsed_time_delta_us > 0
            UNION
            SELECT sql_id FROM ranked
            WHERE r_cpu <= (SELECT top_n FROM run_params) AND cpu_time_delta_us > 0
            UNION
            SELECT sql_id FROM ranked
            WHERE r_gets <= (SELECT top_n FROM run_params) AND buffer_gets_delta > 0
            UNION
            SELECT sql_id FROM ranked
            WHERE r_exec <= (SELECT top_n FROM run_params) AND executions_delta > 0
            UNION
            SELECT sql_id FROM delta_ranked
            WHERE r_delta <= (SELECT top_n FROM run_params)
        ),
        -- Re-rank the pool by total ASH activity so the v_max_charts
        -- cap drops the least-active SQLs first.
        pool_ranked AS (
            SELECT p.sql_id,
                   COUNT(a.sample_id) AS total_s,
                   ROW_NUMBER() OVER (
                       ORDER BY COUNT(a.sample_id) DESC NULLS LAST, p.sql_id) AS rn
            FROM   picked p
            LEFT JOIN dba_hist_active_sess_history a
                  ON a.sql_id = p.sql_id
                 AND a.dbid = ~dbid
                 AND (~inst_num = 0 OR a.instance_number = ~inst_num)
                 AND a.sample_time >= CAST(v_range_start AS TIMESTAMP)
                 AND a.sample_time <  CAST(v_range_end   AS TIMESTAMP)
                 AND (a.session_state = 'ON CPU' OR NVL(a.wait_class, 'x') <> 'Idle')
            GROUP BY p.sql_id
        ),
        pool AS (
            SELECT sql_id FROM pool_ranked WHERE rn <= v_max_charts
        ),
        ash_raw AS (
            SELECT a.sql_id,
                   FLOOR(((CAST(a.sample_time AS DATE) - v_range_start) * 24)
                         / v_bucket_hours) AS bucket_key,
                   CASE WHEN a.session_state = 'ON CPU' THEN 'CPU'
                        ELSE NVL(a.event, 'unknown') END AS event_name,
                   COUNT(*) AS samples
            FROM   dba_hist_active_sess_history a
            JOIN   pool p ON p.sql_id = a.sql_id
            WHERE  a.dbid = ~dbid
              AND  (~inst_num = 0 OR a.instance_number = ~inst_num)
              AND  a.sample_time >= CAST(v_range_start AS TIMESTAMP)
              AND  a.sample_time <  CAST(v_range_end   AS TIMESTAMP)
              AND  (a.session_state = 'ON CPU' OR NVL(a.wait_class, 'x') <> 'Idle')
            GROUP BY a.sql_id,
                     FLOOR(((CAST(a.sample_time AS DATE) - v_range_start) * 24)
                           / v_bucket_hours),
                     CASE WHEN a.session_state = 'ON CPU' THEN 'CPU'
                          ELSE NVL(a.event, 'unknown') END
        ),
        event_totals AS (
            SELECT sql_id, event_name, SUM(samples) AS evt_total
            FROM   ash_raw
            GROUP  BY sql_id, event_name
        ),
        ranked_events AS (
            SELECT ar.sql_id, ar.bucket_key, ar.event_name, ar.samples,
                   DENSE_RANK() OVER (
                       PARTITION BY ar.sql_id
                       ORDER BY et.evt_total DESC,
                                ar.event_name) AS erank
            FROM   ash_raw ar
            JOIN   event_totals et
                ON et.sql_id = ar.sql_id
               AND et.event_name = ar.event_name
        ),
        lumped AS (
            SELECT sql_id, bucket_key,
                   CASE WHEN erank <= v_top_events THEN event_name ELSE 'Other' END AS event_name,
                   SUM(samples) AS samples
            FROM   ranked_events
            GROUP BY sql_id, bucket_key,
                     CASE WHEN erank <= v_top_events THEN event_name ELSE 'Other' END
        )
        SELECT sql_id, bucket_key, event_name, samples
        FROM   lumped
        ORDER  BY sql_id, bucket_key, event_name
    ) LOOP
        v_cells(r.sql_id || '|' || TO_CHAR(r.bucket_key) || '|' || r.event_name) := r.samples;

        v_evt_key := r.sql_id || '|' || r.event_name;
        IF v_evt_totals.EXISTS(v_evt_key) THEN
            v_evt_totals(v_evt_key) := v_evt_totals(v_evt_key) + r.samples;
        ELSE
            v_evt_totals(v_evt_key) := r.samples;
        END IF;

        IF v_sql_totals.EXISTS(r.sql_id) THEN
            v_sql_totals(r.sql_id) := v_sql_totals(r.sql_id) + r.samples;
        ELSE
            v_sql_totals(r.sql_id) := r.samples;
        END IF;
    END LOOP;

    -- If no SQL came back, render a tidy empty-state message and bail.
    IF v_sql_totals.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="empty-state" '
            || 'style="font-size:13px;color:var(--muted);padding:18px 0">'
            || 'No SQLs in the Top-N pool had any ASH samples in the comparison range. '
            || 'This typically means a quiet test DB or an excessively narrow window. '
            || 'Increase weeks_back / win_hours or pick a busier target_end.</p>');
        DBMS_OUTPUT.PUT_LINE('</section>');
        DBMS_LOB.FREETEMPORARY(v_hours_json);
        DBMS_LOB.FREETEMPORARY(v_event_vals);
        RETURN;
    END IF;

    -- Build ordered SID list (DESC by total samples, ASC by sql_id for tie-break).
    v_sid := v_sql_totals.FIRST;
    WHILE v_sid IS NOT NULL LOOP
        v_order.EXTEND;
        v_order(v_order.LAST).sid := v_sid;
        v_order(v_order.LAST).tot := v_sql_totals(v_sid);
        v_sid := v_sql_totals.NEXT(v_sid);
    END LOOP;
    FOR i IN 1 .. v_order.COUNT - 1 LOOP
        FOR j IN i + 1 .. v_order.COUNT LOOP
            IF v_order(j).tot > v_order(i).tot
               OR (v_order(j).tot = v_order(i).tot AND v_order(j).sid < v_order(i).sid) THEN
                v_swap := v_order(i); v_order(i) := v_order(j); v_order(j) := v_swap;
            END IF;
        END LOOP;
    END LOOP;

    -- Compute dominant event per SQL by walking v_evt_totals once.
    FOR i IN 1 .. v_order.COUNT LOOP
        v_sid    := v_order(i).sid;
        v_prefix := v_sid || '|';
        v_dom_n  := -1;
        v_evt_key := v_evt_totals.FIRST;
        WHILE v_evt_key IS NOT NULL LOOP
            IF INSTR(v_evt_key, v_prefix) = 1
               AND v_evt_totals(v_evt_key) > v_dom_n THEN
                v_dom_n          := v_evt_totals(v_evt_key);
                v_sql_dom(v_sid) := SUBSTR(v_evt_key, LENGTH(v_prefix) + 1);
            END IF;
            v_evt_key := v_evt_totals.NEXT(v_evt_key);
        END LOOP;
    END LOOP;

    -- Pull the SQL-text snippet for every SID we will render. Cheap
    -- batch lookup against dba_hist_sqltext: at most v_max_charts single-row IDs.
    FOR i IN 1 .. v_order.COUNT LOOP
        v_sid := v_order(i).sid;
        BEGIN
            SELECT SUBSTR(REPLACE(REPLACE(DBMS_LOB.SUBSTR(sql_text, 200, 1),
                                          CHR(10), ' '), CHR(13), ' '), 1, 200)
            INTO   v_sql_text(v_sid)
            FROM   dba_hist_sqltext
            WHERE  dbid = ~dbid
              AND  sql_id = v_sid
              AND  ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_sql_text(v_sid) := '(sql text not available)';
        END;
    END LOOP;

    -- Emit per-SQL HTML cards (chart divs first, JS bootstrap once at the end).
    FOR i IN 1 .. v_order.COUNT LOOP
        v_sid := v_order(i).sid;
        IF NVL(v_sql_totals(v_sid), 0) < v_min_samples THEN
            v_skipped := v_skipped + 1;
            DBMS_OUTPUT.PUT_LINE('<div class="ash-sql-card insufficient">'
                || '<div class="ash-sql-head">'
                || '<code>' || DBMS_XMLGEN.CONVERT(v_sid) || '</code>'
                || ' &middot; '
                || '<span class="ash-sql-meta">' || v_sql_totals(v_sid)
                || ' ASH samples &mdash; insufficient for a stacked timeline</span>'
                || '</div>'
                || '<pre class="ash-sql-snippet">'
                || DBMS_XMLGEN.CONVERT(v_sql_text(v_sid))
                || '</pre>'
                || '</div>');
        ELSE
            v_rendered := v_rendered + 1;
            DBMS_OUTPUT.PUT_LINE('<div class="ash-sql-card">');
            DBMS_OUTPUT.PUT_LINE('  <div class="ash-sql-head">'
                || '<code>' || DBMS_XMLGEN.CONVERT(v_sid) || '</code>'
                || ' &middot; '
                || '<span class="ash-sql-meta">'
                || v_sql_totals(v_sid) || ' ASH samples'
                || ' &middot; dominant: <b>'
                || DBMS_XMLGEN.CONVERT(NVL(v_sql_dom(v_sid), 'n/a'))
                || '</b></span>'
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('  <pre class="ash-sql-snippet">'
                || DBMS_XMLGEN.CONVERT(v_sql_text(v_sid))
                || '</pre>');
            DBMS_OUTPUT.PUT_LINE('  <div class="chart-wrap chart-ash-sql" '
                || 'id="ash-sql-' || v_sid || '"></div>');
            DBMS_OUTPUT.PUT_LINE('</div>');
        END IF;
    END LOOP;

    IF v_skipped > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="ash-sql-footnote" '
            || 'style="font-size:11px;color:var(--muted);margin:8px 0 0 0">'
            || 'Showing ' || v_rendered || ' SQL chart(s); '
            || v_skipped || ' SQL(s) had fewer than ' || v_min_samples
            || ' ASH samples and are listed as placeholders.</p>');
    END IF;

    -- Single JS block: emits AWR_DATA.topSqlAsh = {hours, windows, charts:[...]}
    -- then ECharts-init forEach. Mirrors section 09 lines 182-290 but iterates
    -- over many small charts and uses a deterministic event-name palette
    -- (js_wait_colors.plsql is wait_class-only and not reusable here).
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('AWR_DATA.topSqlAsh = {');
    DBMS_OUTPUT.PUT_LINE('hours:');
    put_clob_chunked(v_hours_json);
    DBMS_OUTPUT.PUT_LINE(',');
    DBMS_OUTPUT.PUT_LINE('windows:' || v_windows_json || ',');
    DBMS_OUTPUT.PUT_LINE('charts:[');

    v_first_sql := TRUE;
    FOR i IN 1 .. v_order.COUNT LOOP
        v_sid := v_order(i).sid;
        IF NVL(v_sql_totals(v_sid), 0) < v_min_samples THEN
            CONTINUE;
        END IF;

        -- Collect this SQL's events into a sortable list.
        v_events := t_evt_tab();
        v_prefix := v_sid || '|';
        v_evt_key := v_evt_totals.FIRST;
        WHILE v_evt_key IS NOT NULL LOOP
            IF INSTR(v_evt_key, v_prefix) = 1 THEN
                v_events.EXTEND;
                v_events(v_events.LAST).evt := SUBSTR(v_evt_key, LENGTH(v_prefix) + 1);
                v_events(v_events.LAST).tot := v_evt_totals(v_evt_key);
            END IF;
            v_evt_key := v_evt_totals.NEXT(v_evt_key);
        END LOOP;
        -- Selection sort DESC by total then ASC by evt name. <=8 entries.
        FOR a IN 1 .. v_events.COUNT - 1 LOOP
            FOR b IN a + 1 .. v_events.COUNT LOOP
                IF v_events(b).tot > v_events(a).tot
                   OR (v_events(b).tot = v_events(a).tot AND v_events(b).evt < v_events(a).evt) THEN
                    v_evt_swap := v_events(a); v_events(a) := v_events(b); v_events(b) := v_evt_swap;
                END IF;
            END LOOP;
        END LOOP;

        IF v_first_sql THEN v_first_sql := FALSE;
        ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
        DBMS_OUTPUT.PUT_LINE('{id:"ash-sql-' || v_sid
            || '",sqlId:"' || v_sid
            || '",total:' || v_sql_totals(v_sid)
            || ',events:[');

        v_first_evt := TRUE;
        FOR k IN 1 .. v_events.COUNT LOOP
            v_evt := v_events(k).evt;

            -- Rebuild v_event_vals for this (sql, event) by walking all
            -- buckets. Reused across iterations: TRIM then WRITEAPPEND.
            DBMS_LOB.TRIM(v_event_vals, 0);
            FOR bk IN 0 .. v_total_buckets - 1 LOOP
                v_cell_key := v_sid || '|' || TO_CHAR(bk) || '|' || v_evt;
                IF v_cells.EXISTS(v_cell_key) THEN
                    v_n := v_cells(v_cell_key);
                ELSE
                    v_n := 0;
                END IF;
                v_aas := v_n / (v_bucket_hours * 360);
                IF bk = 0 THEN
                    v_buf := TO_CHAR(v_aas, 'FM99999990D0000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''');
                ELSE
                    v_buf := ',' || TO_CHAR(v_aas, 'FM99999990D0000',
                                            'NLS_NUMERIC_CHARACTERS=''.,''');
                END IF;
                DBMS_LOB.WRITEAPPEND(v_event_vals, LENGTH(v_buf), v_buf);
            END LOOP;

            IF v_first_evt THEN v_first_evt := FALSE;
            ELSE DBMS_OUTPUT.PUT_LINE(','); END IF;
            DBMS_OUTPUT.PUT_LINE('{"name":"' || REPLACE(v_evt, '"', '\"')
                || '","total":' || v_events(k).tot
                || ',"vals":[');
            put_clob_chunked(v_event_vals);
            DBMS_OUTPUT.PUT_LINE(']}');
        END LOOP;

        DBMS_OUTPUT.PUT_LINE(']}');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(']};');

    -- Bootstrap: deterministic event-name palette + ECharts init per chart.
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
    DBMS_OUTPUT.PUT_LINE('var d=AWR_DATA.topSqlAsh;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var bandColor="rgba(37,99,235,0.10)", bandCurrent="rgba(37,99,235,0.22)";');
    DBMS_OUTPUT.PUT_LINE('function eventColor(name){');
    DBMS_OUTPUT.PUT_LINE('  if(name==="CPU")   return "#16a34a";');
    DBMS_OUTPUT.PUT_LINE('  if(name==="Other") return "#94a3b8";');
    DBMS_OUTPUT.PUT_LINE('  if(window.AWR_WAIT_COLORS && window.AWR_WAIT_COLORS[name]) return window.AWR_WAIT_COLORS[name];');
    DBMS_OUTPUT.PUT_LINE('  var h=0; for(var i=0;i<name.length;i++){h=(h*31 + name.charCodeAt(i))|0;}');
    DBMS_OUTPUT.PUT_LINE('  var hue=((h%360)+360)%360;');
    DBMS_OUTPUT.PUT_LINE('  return "hsl("+hue+",58%,52%)";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var markAreaData=(d.windows||[]).map(function(w){'
        || 'return [{xAxis:w[0],itemStyle:{color:w[2]==="current"?bandCurrent:bandColor}},{xAxis:w[1]}];});');
    DBMS_OUTPUT.PUT_LINE('(d.charts||[]).forEach(function(c){');
    DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById(c.id); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('  chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('    tooltip:{trigger:"axis",axisPointer:{type:"line"},');
    DBMS_OUTPUT.PUT_LINE('      valueFormatter:function(v){return v==null?"—":(+v).toFixed(2);}},');
    DBMS_OUTPUT.PUT_LINE('    legend:{top:0,left:"center",textStyle:{color:fg,fontSize:10},itemWidth:10,itemHeight:7,type:"scroll"},');
    DBMS_OUTPUT.PUT_LINE('    grid:{left:42,right:14,top:30,bottom:46,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('    xAxis:{type:"category",data:d.hours,boundaryGap:false,axisLabel:{color:mu,fontSize:9,hideOverlap:true}},');
    DBMS_OUTPUT.PUT_LINE('    yAxis:{type:"value",name:"AAS",nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,fontSize:9},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('    dataZoom:[{type:"inside"},{type:"slider",bottom:6,height:14,textStyle:{color:mu,fontSize:9}}],');
    DBMS_OUTPUT.PUT_LINE('    series:c.events.map(function(e,i){');
    DBMS_OUTPUT.PUT_LINE('      var color=eventColor(e.name);');
    DBMS_OUTPUT.PUT_LINE('      var s={name:e.name,type:"line",stack:"total",smooth:false,symbol:"none",');
    DBMS_OUTPUT.PUT_LINE('        areaStyle:{opacity:0.85},emphasis:{focus:"series"},');
    DBMS_OUTPUT.PUT_LINE('        lineStyle:{width:0.5,color:color},itemStyle:{color:color},');
    DBMS_OUTPUT.PUT_LINE('        data:e.vals};');
    DBMS_OUTPUT.PUT_LINE('      if(i===0 && markAreaData.length){');
    DBMS_OUTPUT.PUT_LINE('        s.markArea={silent:true,data:markAreaData,itemStyle:{opacity:1}};}');
    DBMS_OUTPUT.PUT_LINE('      if(i===0){var __ml=window.AWR_markLine&&window.AWR_markLine(d.hours); if(__ml) s.markLine=__ml;}');
    DBMS_OUTPUT.PUT_LINE('      return s;})');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){chart.resize();}).observe(el);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');

    DBMS_LOB.FREETEMPORARY(v_hours_json);
    DBMS_LOB.FREETEMPORARY(v_event_vals);
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            IF DBMS_LOB.ISTEMPORARY(v_hours_json) = 1 THEN
                DBMS_LOB.FREETEMPORARY(v_hours_json);
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            IF DBMS_LOB.ISTEMPORARY(v_event_vals) = 1 THEN
                DBMS_LOB.FREETEMPORARY(v_event_vals);
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RAISE;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 11_top_sql_ash_breakdown END -->'); END;
/
