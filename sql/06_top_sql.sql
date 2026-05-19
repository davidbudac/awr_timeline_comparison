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
    v_cur_dim    VARCHAR2(10);
    v_val        NUMBER;
    v_val_s      VARCHAR2(64);
    v_rnk_s      VARCHAR2(64);
    v_phv_s      VARCHAR2(64);
    v_chart_vals VARCHAR2(8000);
    v_new_entry  VARCHAR2(8000);

    -- Hard cap for the per-dimension JSON accumulators below. PL/SQL
    -- VARCHAR2 maxes out at 32767 bytes; the per-dim emit at the end of
    -- this section concatenates the accumulator with a short prefix/suffix
    -- ("sqls":[ ... ], / "schemas":[ ... ]}) so we leave headroom for that.
    -- Busy DBs with many parsing schemas in top-N can otherwise overflow
    -- the slot or the emit, raising ORA-06502 at the PUT_LINE call.
    c_json_cap   CONSTANT PLS_INTEGER := 32500;

    TYPE t_sqlid_tab IS TABLE OF BOOLEAN INDEX BY VARCHAR2(30);
    v_seen_sqls t_sqlid_tab;
    v_flip_sqls t_sqlid_tab;
    v_plan_flip BOOLEAN;

    -- Per-dimension JSON payloads accumulated while we render the detail
    -- tables; emitted once at the end as AWR_DATA.topSql.dims so each
    -- dimension can drive its own line-chart of metric value across windows.
    -- Two parallel breakdowns: one series per top-N SQL_ID, one series per
    -- top-N parsing_schema_name. The browser toggles between them.
    TYPE t_dim_str  IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(10);
    TYPE t_dim_meta IS TABLE OF VARCHAR2(80)    INDEX BY VARCHAR2(10);
    TYPE t_dim_num  IS TABLE OF NUMBER          INDEX BY VARCHAR2(10);
    v_dim_sqls_json    t_dim_str;
    v_dim_schemas_json t_dim_str;
    v_dim_label        t_dim_meta;
    v_dim_unit         t_dim_meta;
    -- Per-dim "kept vs total" counters that drive the truncation footnote
    -- shown above each dim's chart. kept is bumped only when an entry was
    -- actually appended to the accumulator; total is bumped on every row
    -- the cursor returns, so kept < total <=> the c_json_cap kicked in.
    v_dim_sqls_kept     t_dim_num;
    v_dim_sqls_total    t_dim_num;
    v_dim_schemas_kept  t_dim_num;
    v_dim_schemas_total t_dim_num;
    v_dim              VARCHAR2(10);
    v_first_dim        BOOLEAN;

    @@sql/lib/nth_csv.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="topsql"><h2>Top SQL (top ' || v_top_n
        || ' per dimension, per window)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Top-' || v_top_n || ' SQLs per dimension per window from '
        || 'DBA_HIST_SQLSTAT <code>*_DELTA</code>. '
        || 'Bump chart per dimension: each line = one SQL across windows, '
        || 'oldest &rarr; current. Detail tables collapsed; click to expand.</p>');

    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - (~step_hours/24)*week_offset, '~period_axis_fmt') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);


    -- Per-dimension detail tables, packed into one big cursor. ------------
    v_cur_dim := NULL;
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
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
        --
        -- Per-execution elapsed time per (window, sql_id), in microseconds.
        -- NULL when the SQL had no executions in that window so the bump
        -- chart renders the missing point as a gap (connectNulls:false).
        --
        per_exec AS (
            SELECT week_offset, sql_id, plan_hash_value, executions_delta,
                   CASE WHEN executions_delta > 0
                        THEN elapsed_time_delta_us / executions_delta
                   END AS per_exec_us
            FROM   agg
        ),
        --
        -- Δ elapsed-per-exec ranking: single global ROW_NUMBER (NOT
        -- partitioned by window) over the regression delta. Catches
        -- "got slower per call" — invisible to total-elapsed rankings
        -- when execution count drops.
        --
        -- Filters:
        --   * cur_pe and prior_pe both non-NULL (need a baseline to compare)
        --   * cur_pe > prior_pe (only regressions; improvements drop out)
        --   * cur_execs >= 3 (cuts noise from one-off slow parses)
        --
        delta_ranked AS (
            SELECT sql_id, cur_pe, prior_pe, n_prior_pe,
                   cur_pe - prior_pe AS delta_pe,
                   ROW_NUMBER() OVER (ORDER BY (cur_pe - prior_pe) DESC NULLS LAST,
                                               sql_id) AS r_delta
            FROM (
                SELECT sql_id,
                       MAX(CASE WHEN week_offset = 0 THEN per_exec_us       END) AS cur_pe,
                       AVG(CASE WHEN week_offset > 0 THEN per_exec_us       END) AS prior_pe,
                       COUNT(CASE WHEN week_offset > 0 AND per_exec_us IS NOT NULL
                                  THEN 1 END)                                     AS n_prior_pe,
                       MAX(CASE WHEN week_offset = 0 THEN executions_delta  END) AS cur_execs
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
            UNION ALL
            -- PEREXEC: per-window rows for the top-N most regressed SQLs.
            -- rnk is set only at week_offset = 0 (the ranking is global,
            -- not per-window; surfacing the same rank in every prior cell
            -- would clutter the detail table). per_exec_us in microseconds
            -- so it can share the dim_div=1e6 conversion path.
            SELECT 'PEREXEC' AS dim, pe.week_offset, pe.sql_id, pe.plan_hash_value,
                   pe.per_exec_us AS metric_value,
                   CASE WHEN pe.week_offset = 0 THEN dr.r_delta END AS rnk
            FROM   per_exec pe
            JOIN   delta_ranked dr ON dr.sql_id = pe.sql_id
            WHERE  dr.r_delta <= (SELECT top_n FROM run_params)
              AND  pe.per_exec_us IS NOT NULL
        ),
        dims AS (
            SELECT 'ELAPSED' code, 1 ord, 'By elapsed time'         label, 's'      unit, 1e6 divs FROM dual UNION ALL
            SELECT 'CPU',      2,     'By CPU time',                       's',          1e6      FROM dual UNION ALL
            SELECT 'GETS',     3,     'By buffer gets',                    'gets',       1        FROM dual UNION ALL
            SELECT 'EXEC',     4,     'By executions',                     'exec',       1        FROM dual UNION ALL
            SELECT 'PEREXEC',  5,     'By per-exec regression',            's/exec',     1e6      FROM dual
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
            v_dim_label(s.dim)         := s.dim_label;
            v_dim_unit(s.dim)          := s.dim_unit;
            v_dim_sqls_json(s.dim)     := NULL;
            v_dim_sqls_kept(s.dim)     := 0;
            v_dim_sqls_total(s.dim)    := 0;
            v_dim_schemas_kept(s.dim)  := 0;
            v_dim_schemas_total(s.dim) := 0;

            DBMS_OUTPUT.PUT_LINE('<h3 style="margin-top:18px">' || s.dim_label || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<div class="topsql-toggle" data-topsql-target="' || s.dim || '">'
                || '<span>Break down by:</span>'
                || '<button type="button" data-mode="sqls" class="active">SQL_ID</button>'
                || '<button type="button" data-mode="schemas">Schema</button>'
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="topsql-chart-'
                || s.dim || '"></div>');

            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>' || s.dim_label || ' &mdash; detail table</summary>');

            v_header := '<thead><tr><th>SQL_ID</th><th class="num">PHV (cur)</th>'
                || '<th class="num">Current (' || s.dim_unit || ')</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                v_header := v_header || '<th class="num">&minus;'
                    || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
            END LOOP;
            v_header := v_header || '<th>SQL</th></tr></thead>';
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
        END IF;

        v_seen_sqls(s.sql_id) := TRUE;

        -- Plan-change detection for this row: scan prior-week PHVs (slots
        -- 2..N+1 of s.week_phvs; slot 1 is the current window) and flag
        -- the SQL when any non-null prior PHV differs from s.cur_phv. The
        -- per-cell plan-up badge below uses the same comparison; this loop
        -- gives us a single boolean for the SQL_ID column badge and feeds
        -- the cross-dim rollup paragraph emitted after the bump charts.
        v_plan_flip := FALSE;
        IF s.cur_phv IS NOT NULL THEN
            FOR k IN 1 .. v_weeks_back LOOP
                v_phv_s := nth_csv(s.week_phvs, k + 1);
                IF v_phv_s IS NOT NULL AND v_phv_s <> ''
                   AND TO_NUMBER(v_phv_s) <> s.cur_phv THEN
                    v_plan_flip := TRUE;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        IF v_plan_flip THEN
            v_flip_sqls(s.sql_id) := TRUE;
        END IF;

        -- Build oldest->newest values array for this SQL (chart series).
        -- week_vals is LISTAGG(... ORDER BY week_offset ASC), i.e. slot 1 =
        -- current (week_offset 0), slot N+1 = oldest. Iterate in reverse so
        -- the chart x-axis (which is oldest-first) lines up.
        v_chart_vals := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := nth_csv(s.week_vals, k);
            IF v_chart_vals IS NOT NULL AND LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_chart_vals := v_chart_vals
                    || TO_CHAR(v_val/s.dim_div, 'FM99999999990D000000',
                               'NLS_NUMERIC_CHARACTERS=''.,''');
            END IF;
        END LOOP;
        v_new_entry := '{"sql_id":"' || s.sql_id
            || '","cur":' || NVL(TO_CHAR(s.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        v_dim_sqls_total(s.dim) := v_dim_sqls_total(s.dim) + 1;
        IF v_dim_sqls_json(s.dim) IS NULL THEN
            v_dim_sqls_json(s.dim) := v_new_entry;
            v_dim_sqls_kept(s.dim) := v_dim_sqls_kept(s.dim) + 1;
        ELSIF LENGTH(v_dim_sqls_json(s.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_sqls_json(s.dim) :=
                v_dim_sqls_json(s.dim) || ',' || v_new_entry;
            v_dim_sqls_kept(s.dim) := v_dim_sqls_kept(s.dim) + 1;
        END IF;

        -- SQL_ID links to its detail block in the Per-SQL detail section
        -- below. The hashchange listener emitted at the end of this section
        -- auto-opens the target <details> on click.
        v_row := '<tr>'
            || '<td class="mono"><a href="#sql-' || s.sql_id || '">'
            || s.sql_id || '</a>'
            || CASE WHEN v_plan_flip
                    THEN ' <span class="badge warn" title="Plan changed between current and a prior compared window">plan&#8593;</span>'
                    ELSE '' END
            || '</td>'
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

    -- Second pass: per-schema breakdown for the chart toggle. Uses the same
    -- valid_windows + DBA_HIST_SQLSTAT scan, grouped by parsing_schema_name
    -- instead of sql_id. Top-N schemas per dimension are picked the same
    -- way (best rank across windows). No detail table -- chart only.
    FOR sc IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        agg AS (
            SELECT w.week_offset, NVL(s.parsing_schema_name, '(unknown)') AS schema_name,
                   SUM(NVL(s.executions_delta, 0))   AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0))     AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0))  AS buffer_gets_delta
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
            GROUP BY w.week_offset, NVL(s.parsing_schema_name, '(unknown)')
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY elapsed_time_delta_us DESC, schema_name) AS r_ela,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY cpu_time_delta_us DESC, schema_name)     AS r_cpu,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY buffer_gets_delta DESC, schema_name)     AS r_gets,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY executions_delta DESC, schema_name)      AS r_exec
            FROM   agg a
        ),
        picked AS (
            SELECT 'ELAPSED' AS dim, week_offset, schema_name,
                   elapsed_time_delta_us AS metric_value, r_ela AS rnk
            FROM ranked WHERE r_ela <= (SELECT top_n FROM run_params) AND elapsed_time_delta_us > 0
            UNION ALL
            SELECT 'CPU', week_offset, schema_name, cpu_time_delta_us, r_cpu
            FROM ranked WHERE r_cpu <= (SELECT top_n FROM run_params) AND cpu_time_delta_us > 0
            UNION ALL
            SELECT 'GETS', week_offset, schema_name, buffer_gets_delta, r_gets
            FROM ranked WHERE r_gets <= (SELECT top_n FROM run_params) AND buffer_gets_delta > 0
            UNION ALL
            SELECT 'EXEC', week_offset, schema_name, executions_delta, r_exec
            FROM ranked WHERE r_exec <= (SELECT top_n FROM run_params) AND executions_delta > 0
        ),
        dims AS (
            SELECT 'ELAPSED' code, 1 ord, 1e6 divs FROM dual UNION ALL
            SELECT 'CPU',      2,     1e6      FROM dual UNION ALL
            SELECT 'GETS',     3,     1        FROM dual UNION ALL
            SELECT 'EXEC',     4,     1        FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        schemas AS (
            SELECT DISTINCT dim, schema_name FROM picked
        ),
        grid AS (
            SELECT q.dim, q.schema_name, w.week_offset, p.metric_value, p.rnk
            FROM   schemas q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.schema_name = q.schema_name AND p.week_offset = w.week_offset
        ),
        per_schema AS (
            SELECT dim, schema_name,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END) AS cur_rnk,
                   MIN(rnk)          AS best_rank,
                   MAX(metric_value) AS best_value,
                   LISTAGG(CASE WHEN metric_value IS NULL THEN ''
                                ELSE TO_CHAR(metric_value, 'FM99999999999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals
            FROM   grid
            GROUP BY dim, schema_name
        )
        SELECT d.code AS dim, d.divs AS dim_div, ps.schema_name,
               ps.cur_rnk, ps.week_vals
        FROM   dims d
        JOIN   per_schema ps ON ps.dim = d.code
        ORDER BY d.ord,
            CASE WHEN ps.cur_rnk IS NULL THEN 1 ELSE 0 END,
            ps.cur_rnk NULLS LAST,
            ps.best_rank,
            ps.best_value DESC,
            ps.schema_name
    ) LOOP
        v_chart_vals := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := nth_csv(sc.week_vals, k);
            IF LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990D000000',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_chart_vals := v_chart_vals
                    || TO_CHAR(v_val/sc.dim_div, 'FM99999999990D000000',
                               'NLS_NUMERIC_CHARACTERS=''.,''');
            END IF;
        END LOOP;
        v_new_entry := '{"name":"' || REPLACE(sc.schema_name, '"', '\"')
            || '","cur":' || NVL(TO_CHAR(sc.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        -- Defensive init: schemas-loop dims should already be initialized
        -- by the SQL loop's per-dim block, but a dim with schemas but no
        -- top-N SQLs would skip that init. Treat as zeroed.
        IF NOT v_dim_schemas_total.EXISTS(sc.dim) THEN
            v_dim_schemas_total(sc.dim) := 0;
            v_dim_schemas_kept(sc.dim)  := 0;
        END IF;
        v_dim_schemas_total(sc.dim) := v_dim_schemas_total(sc.dim) + 1;
        IF NOT v_dim_schemas_json.EXISTS(sc.dim)
           OR v_dim_schemas_json(sc.dim) IS NULL THEN
            v_dim_schemas_json(sc.dim) := v_new_entry;
            v_dim_schemas_kept(sc.dim) := v_dim_schemas_kept(sc.dim) + 1;
        ELSIF LENGTH(v_dim_schemas_json(sc.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_schemas_json(sc.dim) :=
                v_dim_schemas_json(sc.dim) || ',' || v_new_entry;
            v_dim_schemas_kept(sc.dim) := v_dim_schemas_kept(sc.dim) + 1;
        END IF;
    END LOOP;

    -- One ECharts line chart per dimension, plotting metric value (in the
    -- dimension's display unit) per top SQL across windows.  Skipped
    -- silently when the CDN is unreachable; tables still carry every value.
    IF v_dim_label.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<script>(function(){');
        DBMS_OUTPUT.PUT_LINE('AWR_DATA.topSql={weeks:' || v_weeks_json
            || ',topN:' || v_top_n || ',dims:{');
        v_first_dim := TRUE;
        v_dim := v_dim_label.FIRST;
        WHILE v_dim IS NOT NULL LOOP
            -- Emit each dim in three PUT_LINE calls so no single concat
            -- ever holds both the sqls and the schemas accumulator at once;
            -- their VARCHAR2(32767) slots can otherwise sum past PL/SQL's
            -- 32767-byte expression limit and raise ORA-06502. The newlines
            -- the splits inject sit inside a JS object literal and are
            -- ignored by the parser.
            IF NOT v_first_dim THEN
                DBMS_OUTPUT.PUT_LINE(',');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"' || v_dim || '":{"label":"' || v_dim_label(v_dim)
                || '","unit":"' || v_dim_unit(v_dim)
                || '","sqlsKept":' || NVL(TO_CHAR(v_dim_sqls_kept(v_dim)), '0')
                || ',"sqlsTotal":' || NVL(TO_CHAR(v_dim_sqls_total(v_dim)), '0')
                || ',"schemasKept":'
                    || CASE WHEN v_dim_schemas_kept.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_schemas_kept(v_dim))
                            ELSE '0' END
                || ',"schemasTotal":'
                    || CASE WHEN v_dim_schemas_total.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_schemas_total(v_dim))
                            ELSE '0' END
                || ',');
            DBMS_OUTPUT.PUT_LINE(
                '"sqls":[' || NVL(v_dim_sqls_json(v_dim), '') || '],');
            DBMS_OUTPUT.PUT_LINE(
                '"schemas":[' ||
                    CASE WHEN v_dim_schemas_json.EXISTS(v_dim)
                         THEN NVL(v_dim_schemas_json(v_dim), '') ELSE '' END
                || ']}');
            v_first_dim := FALSE;
            v_dim := v_dim_label.NEXT(v_dim);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('}};');
        -- Truncation footnote: when c_json_cap clamped either accumulator,
        -- inject a small <p> above the matching chart-wrap so the user
        -- knows the chart doesn't reflect every top SQL / schema. Runs
        -- before the echarts guard so the note still shows in offline mode
        -- (chart-wrap is empty there, but the detail table below carries
        -- every value).
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.topSql.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("topsql-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.topSql.dims[dim]; var bits=[];');
        DBMS_OUTPUT.PUT_LINE('  if(d.sqlsKept<d.sqlsTotal){ bits.push("first "+d.sqlsKept+" of "+d.sqlsTotal+" SQL"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.schemasKept<d.schemasTotal){ bits.push("first "+d.schemasKept+" of "+d.schemasTotal+" parsing schemas"); }');
        DBMS_OUTPUT.PUT_LINE('  if(!bits.length) return;');
        DBMS_OUTPUT.PUT_LINE('  var note=document.createElement("p");');
        DBMS_OUTPUT.PUT_LINE('  note.className="trunc-note";');
        DBMS_OUTPUT.PUT_LINE('  note.style.cssText="font-size:11px;color:var(--muted);margin:-2px 0 6px;font-style:italic";');
        DBMS_OUTPUT.PUT_LINE('  note.textContent="Chart truncated to fit the 32 KB per-dimension JSON budget: showing "+bits.join(", ")+". The detail table below carries every value.";');
        DBMS_OUTPUT.PUT_LINE('  el.parentNode.insertBefore(note, el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
        DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
        DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
        DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
        DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
        DBMS_OUTPUT.PUT_LINE('var fmt=function(v){return v==null?"—":(+v).toLocaleString(undefined,{maximumFractionDigits:3});};');
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.topSql.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("topsql-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.topSql.dims[dim];');
        DBMS_OUTPUT.PUT_LINE('  var weeks=AWR_DATA.topSql.weeks;');
        DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
        DBMS_OUTPUT.PUT_LINE('  function rowName(s){ return s.name || s.sql_id || "?"; }');
        DBMS_OUTPUT.PUT_LINE('  function render(mode){');
        DBMS_OUTPUT.PUT_LINE('    var rows=(mode==="schemas"?d.schemas:d.sqls)||[];');
        DBMS_OUTPUT.PUT_LINE('    chart.setOption({');
        DBMS_OUTPUT.PUT_LINE('      tooltip:{trigger:"axis",axisPointer:{type:"line"},formatter:function(ps){var hdr="<b>"+ps[0].axisValue+"</b>";var rs=ps.filter(function(p){return p.value!=null;}).sort(function(a,b){return (b.value||0)-(a.value||0);}).map(function(p){return p.marker+" "+p.seriesName+": <b>"+fmt(p.value)+" "+d.unit+"</b>";}).join("<br/>");return hdr+"<br/>"+rs;}},');
        DBMS_OUTPUT.PUT_LINE('      legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
        DBMS_OUTPUT.PUT_LINE('      grid:{left:50,right:90,top:10,bottom:44,containLabel:true},');
        DBMS_OUTPUT.PUT_LINE('      xAxis:{type:"category",data:weeks,axisLabel:{color:fg,fontWeight:600},splitLine:{show:true,lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      yAxis:{type:"value",name:d.unit,nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (+v).toLocaleString(undefined,{maximumFractionDigits:2});}},splitLine:{lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      series:rows.map(function(s,i){return {name:rowName(s),type:"line",connectNulls:false,showSymbol:true,symbolSize:6,itemStyle:{color:palette[i%palette.length]},lineStyle:{width:2},emphasis:{focus:"series",lineStyle:{width:3}},endLabel:{show:true,formatter:"{a}",color:fg,fontSize:10,distance:6},data:s.vals};})');
        DBMS_OUTPUT.PUT_LINE('    }, true);');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  render("sqls");');
        DBMS_OUTPUT.PUT_LINE('  var toggle=document.querySelector(''[data-topsql-target="''+dim+''"]'');');
        DBMS_OUTPUT.PUT_LINE('  if(toggle){');
        DBMS_OUTPUT.PUT_LINE('    if(!d.schemas || !d.schemas.length){');
        DBMS_OUTPUT.PUT_LINE('      var sb=toggle.querySelector(''[data-mode="schemas"]'');');
        DBMS_OUTPUT.PUT_LINE('      if(sb) sb.style.display="none";');
        DBMS_OUTPUT.PUT_LINE('    }');
        DBMS_OUTPUT.PUT_LINE('    toggle.addEventListener("click",function(ev){');
        DBMS_OUTPUT.PUT_LINE('      var btn=ev.target.closest("button"); if(!btn) return;');
        DBMS_OUTPUT.PUT_LINE('      var mode=btn.getAttribute("data-mode"); if(!mode) return;');
        DBMS_OUTPUT.PUT_LINE('      Array.prototype.forEach.call(toggle.querySelectorAll("button"),function(b){ b.classList.toggle("active", b===btn); });');
        DBMS_OUTPUT.PUT_LINE('      render(mode);');
        DBMS_OUTPUT.PUT_LINE('    });');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){chart.resize();}).observe(el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
    END IF;

    -- Cross-dim plan-change rollup. v_seen_sqls is populated for every
    -- SQL_ID that appeared in any dimension's top-N detail table above;
    -- v_flip_sqls is the subset whose current PHV differs from a non-null
    -- prior PHV. One badge + one sentence: lets a reader scan the section
    -- and immediately tell whether plan changes are even in scope.
    IF v_seen_sqls.COUNT > 0 THEN
        IF v_flip_sqls.COUNT > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<p style="margin-top:18px">'
                || '<span class="badge warn">plan&#8593;</span> '
                || v_flip_sqls.COUNT || ' of ' || v_seen_sqls.COUNT
                || ' top SQL had a plan_hash_value change between current and a prior '
                || 'compared window. Look for the <span class="badge warn">plan&#8593;</span> '
                || 'badges in the SQL_ID column and the per-week cells above.</p>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<p style="margin-top:18px">'
                || '<span class="badge ok">plan stable</span> '
                || 'No plan_hash_value changes detected for any of the '
                || v_seen_sqls.COUNT || ' top SQL across the compared windows.</p>');
        END IF;
    END IF;

    -- Per-SQL detail: full text + AWR retention range + plan timeline ----
    -- For each SQL listed in any dimension above, emit a collapsible block
    -- with: a metadata header, a per-PHV summary table, a timeline chart
    -- (x=snap end time, y=avg s/exec, color=plan_hash_value), and the
    -- full SQL text. The aim is to let a reader visually correlate
    -- performance changes in the dimension tables with plan switches.
    DBMS_OUTPUT.PUT_LINE('<h3 style="margin-top:18px">Per-SQL detail</h3>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Per SQL_ID listed above: full text, AWR retention range, '
        || 'plan_hash_value summary, and avg sec/exec colored by PHV across '
        || 'every snapshot the SQL appeared in. PHV color change = plan switch.</p>');

    -- One JS namespace bucket per SQL; populated below, consumed by the
    -- single ECharts init pass at the end of the section.
    DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.sqlDetails = AWR_DATA.sqlDetails || {};</script>');

    DECLARE
        v_sql_id          VARCHAR2(30);
        v_text            CLOB;
        v_len             NUMBER;
        v_snip            VARCHAR2(8000);
        v_first_seen      VARCHAR2(30);
        v_last_seen       VARCHAR2(30);
        v_phv_count       NUMBER;
        v_total_exec      NUMBER;
        v_total_snap      NUMBER;
        v_first_pt        BOOLEAN;

        -- Per-SQL identity / context metadata, captured across the full AWR
        -- retention range. For values that can vary across snapshots
        -- (module/action/optimizer_mode), we keep the most recent non-null
        -- via KEEP (DENSE_RANK LAST ORDER BY <non_null_flag, snap_id>);
        -- if all snaps have NULL, the result is NULL and the strip shows
        -- a muted dash.
        v_parsing_schema  VARCHAR2(128);
        v_last_module     VARCHAR2(64);
        v_last_action     VARCHAR2(64);
        v_last_opt_mode   VARCHAR2(32);
        v_module_distinct NUMBER;
        v_force_sig       NUMBER;
        v_sql_profile     VARCHAR2(64);
    BEGIN
        v_sql_id := v_seen_sqls.FIRST;
        WHILE v_sql_id IS NOT NULL LOOP
            -- Aggregate metadata across full AWR retention for this SQL.
            BEGIN
                SELECT TO_CHAR(MIN(s.begin_interval_time), 'YYYY-MM-DD HH24:MI'),
                       TO_CHAR(MAX(s.end_interval_time),   'YYYY-MM-DD HH24:MI'),
                       COUNT(DISTINCT NULLIF(st.plan_hash_value, 0)),
                       SUM(NVL(st.executions_delta, 0)),
                       COUNT(*),
                       MAX(st.parsing_schema_name)
                           KEEP (DENSE_RANK LAST ORDER BY st.snap_id),
                       MAX(st.module)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.module IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       MAX(st.action)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.action IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       MAX(st.optimizer_mode)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.optimizer_mode IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       COUNT(DISTINCT st.module),
                       MAX(st.force_matching_signature),
                       MAX(st.sql_profile)
                INTO   v_first_seen, v_last_seen,
                       v_phv_count, v_total_exec, v_total_snap,
                       v_parsing_schema, v_last_module, v_last_action,
                       v_last_opt_mode, v_module_distinct,
                       v_force_sig, v_sql_profile
                FROM   dba_hist_sqlstat st
                JOIN   dba_hist_snapshot s
                  ON   s.dbid = st.dbid
                 AND   s.snap_id = st.snap_id
                 AND   s.instance_number = st.instance_number
                WHERE  st.dbid   = ~dbid
                  AND  st.sql_id = v_sql_id
                  AND  (~inst_num = 0 OR st.instance_number = ~inst_num);
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_first_seen := NULL; v_last_seen  := NULL;
                v_phv_count  := 0;    v_total_exec := 0; v_total_snap := 0;
                v_parsing_schema := NULL; v_last_module := NULL;
                v_last_action    := NULL; v_last_opt_mode := NULL;
                v_module_distinct := 0;
                v_force_sig := NULL; v_sql_profile := NULL;
            END;

            -- Full SQL text (single source of truth, same lookup as before).
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

            -- Per-SQL collapsible container. The id is the link target for
            -- SQL_ID anchors in the top-N tables above.
            DBMS_OUTPUT.PUT_LINE('<details id="sql-' || v_sql_id || '"><summary>'
                || '<span class="mono">' || v_sql_id || '</span> &mdash; '
                || NVL(v_first_seen, '?') || ' &rarr; ' || NVL(v_last_seen, '?')
                || ' &middot; <b>' || v_phv_count || '</b> distinct plan'
                || CASE WHEN v_phv_count = 1 THEN '' ELSE 's' END
                || ' &middot; ' || TO_CHAR(NVL(v_total_exec, 0), 'FM999G999G999G990')
                || ' executions across ' || NVL(v_total_snap, 0) || ' snapshots'
                || '</summary>');

            -- Per-SQL identity / context strip. Built from the metadata SELECT
            -- above; muted dash when a field is null across all snapshots.
            DBMS_OUTPUT.PUT_LINE('<dl class="sql-meta">'
                || '<dt>Parsing schema</dt><dd class="mono">'
                || CASE WHEN v_parsing_schema IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_parsing_schema) END
                || '</dd>'
                || '<dt>Module</dt><dd>'
                || CASE WHEN v_last_module IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_module)
                             || CASE WHEN v_module_distinct > 1
                                     THEN ' <span class="muted">('
                                          || v_module_distinct
                                          || ' distinct seen)</span>'
                                     ELSE '' END END
                || '</dd>'
                || '<dt>Action</dt><dd>'
                || CASE WHEN v_last_action IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_action) END
                || '</dd>'
                || '<dt>Optimizer mode</dt><dd class="mono">'
                || CASE WHEN v_last_opt_mode IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_opt_mode) END
                || '</dd>'
                || '<dt>Force-match sig</dt><dd class="mono">'
                || CASE WHEN v_force_sig IS NULL OR v_force_sig = 0
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE TO_CHAR(v_force_sig) END
                || '</dd>'
                || '<dt>SQL profile</dt><dd>'
                || CASE WHEN v_sql_profile IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_sql_profile) END
                || '</dd>'
                || '<dt>Text length</dt><dd>'
                || CASE WHEN NVL(v_len, 0) = 0
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE TO_CHAR(v_len, 'FM999G999G990') || ' chars' END
                || '</dd>'
                || '</dl>');

            -- Per-PHV summary table + timeline chart. Skip entirely when the
            -- SQL has no captured non-zero plan_hash_value: the summary
            -- cursor (filtered to plan_hash_value > 0) would render an empty
            -- table and the chart div would remain an empty box.
            IF NVL(v_phv_count, 0) > 0 THEN
                DBMS_OUTPUT.PUT_LINE('<table><thead><tr>'
                    || '<th class="num">PHV</th>'
                    || '<th>First seen</th><th>Last seen</th>'
                    || '<th class="num">Snaps</th>'
                    || '<th class="num">Executions</th>'
                    || '<th class="num">Avg s/exec</th>'
                    || '<th class="num">Avg gets/exec</th>'
                    || '</tr></thead><tbody>');
                FOR p IN (
                    SELECT st.plan_hash_value AS phv,
                           TO_CHAR(MIN(s.begin_interval_time), 'YYYY-MM-DD HH24:MI') AS first_seen,
                           TO_CHAR(MAX(s.end_interval_time),   'YYYY-MM-DD HH24:MI') AS last_seen,
                           COUNT(*)                           AS snaps,
                           SUM(NVL(st.executions_delta, 0))   AS execs,
                           SUM(NVL(st.elapsed_time_delta, 0)) AS ela_us,
                           SUM(NVL(st.buffer_gets_delta, 0))  AS gets
                    FROM   dba_hist_sqlstat st
                    JOIN   dba_hist_snapshot s
                      ON   s.dbid = st.dbid
                     AND   s.snap_id = st.snap_id
                     AND   s.instance_number = st.instance_number
                    WHERE  st.dbid   = ~dbid
                      AND  st.sql_id = v_sql_id
                      AND  (~inst_num = 0 OR st.instance_number = ~inst_num)
                      AND  st.plan_hash_value > 0
                    GROUP BY st.plan_hash_value
                    ORDER BY MIN(s.begin_interval_time)
                ) LOOP
                    DBMS_OUTPUT.PUT_LINE('<tr>'
                        || '<td class="num mono">' || p.phv || '</td>'
                        || '<td>' || p.first_seen || '</td>'
                        || '<td>' || p.last_seen  || '</td>'
                        || '<td class="num">' || p.snaps || '</td>'
                        || '<td class="num">' || TO_CHAR(p.execs, 'FM999G999G999G990') || '</td>'
                        || '<td class="num">'
                        || CASE WHEN p.execs > 0
                                THEN TO_CHAR(p.ela_us / p.execs / 1e6, 'FM9G990D000')
                                ELSE '&mdash;' END
                        || '</td>'
                        || '<td class="num">'
                        || CASE WHEN p.execs > 0
                                THEN TO_CHAR(p.gets / p.execs, 'FM999G999G990')
                                ELSE '&mdash;' END
                        || '</td>'
                        || '</tr>');
                END LOOP;
                DBMS_OUTPUT.PUT_LINE('</tbody></table>');

                -- Timeline chart container; rendered by the ECharts init pass.
                DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" '
                    || 'id="sqltl-' || v_sql_id || '"></div>');

                -- Snap-level points feeding the timeline chart. One JSON
                -- object per (snap, phv) where the SQL had a captured plan,
                -- oldest -> newest. Numeric format uses '.,' so JS Number()
                -- parses regardless of session NLS.
                DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.sqlDetails['
                    || '"' || v_sql_id || '"]={snaps:[');
                v_first_pt := TRUE;
                FOR r IN (
                    SELECT TO_CHAR(s.end_interval_time, 'YYYY-MM-DD HH24:MI') AS t,
                           st.plan_hash_value AS phv,
                           SUM(NVL(st.executions_delta, 0))   AS execs,
                           SUM(NVL(st.elapsed_time_delta, 0)) AS ela_us
                    FROM   dba_hist_sqlstat st
                    JOIN   dba_hist_snapshot s
                      ON   s.dbid = st.dbid
                     AND   s.snap_id = st.snap_id
                     AND   s.instance_number = st.instance_number
                    WHERE  st.dbid   = ~dbid
                      AND  st.sql_id = v_sql_id
                      AND  (~inst_num = 0 OR st.instance_number = ~inst_num)
                      AND  st.plan_hash_value > 0
                    GROUP BY s.end_interval_time, st.plan_hash_value
                    ORDER BY s.end_interval_time
                ) LOOP
                    DBMS_OUTPUT.PUT_LINE(
                        CASE WHEN v_first_pt THEN '' ELSE ',' END
                        || '{"t":"' || r.t || '"'
                        || ',"phv":"' || r.phv || '"'
                        || ',"exec":' || NVL(TO_CHAR(r.execs), '0')
                        || ',"ela":'
                        || CASE WHEN r.execs > 0
                                THEN TO_CHAR(r.ela_us / r.execs / 1e6,
                                             'FM9999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,''')
                                ELSE 'null' END
                        || '}');
                    v_first_pt := FALSE;
                END LOOP;
                DBMS_OUTPUT.PUT_LINE(']};</script>');
            END IF;

            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || DBMS_XMLGEN.CONVERT(v_snip)
                || CASE WHEN v_len > 8000
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');

            DBMS_OUTPUT.PUT_LINE('</details>');

            v_sql_id := v_seen_sqls.NEXT(v_sql_id);
        END LOOP;
    END;

    -- Single ECharts init pass: render a per-SQL timeline (scatter, x=snap
    -- end time, y=s/exec, one series per PHV). Skipped silently when the
    -- ECharts CDN is unreachable; the per-PHV table still carries every
    -- number. Charts inside collapsed <details> are (re)sized when the
    -- user opens them so they don't render at 0x0.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts || !AWR_DATA.sqlDetails) return;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
    DBMS_OUTPUT.PUT_LINE('function build(el,sqlId){');
    DBMS_OUTPUT.PUT_LINE('  var snaps=(AWR_DATA.sqlDetails[sqlId]||{}).snaps||[];');
    DBMS_OUTPUT.PUT_LINE('  if(!snaps.length) return null;');
    DBMS_OUTPUT.PUT_LINE('  var phvOrder=[],phvIdx={};');
    DBMS_OUTPUT.PUT_LINE('  snaps.forEach(function(p){if(!(p.phv in phvIdx)){phvIdx[p.phv]=phvOrder.length;phvOrder.push(p.phv);}});');
    DBMS_OUTPUT.PUT_LINE('  var xs=snaps.map(function(p){return p.t;});');
    DBMS_OUTPUT.PUT_LINE('  var series=phvOrder.map(function(phv,i){return {name:"PHV "+phv,type:"scatter",symbolSize:7,itemStyle:{color:palette[i%palette.length]},data:snaps.filter(function(p){return p.phv===phv;}).map(function(p){return [p.t,p.ela,p.exec,p.phv];})};});');
    DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('  chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('    tooltip:{trigger:"item",formatter:function(p){var v=p.value;return "<b>"+v[0]+"</b><br/>PHV: <b>"+v[3]+"</b><br/>s/exec: <b>"+(v[1]==null?"&mdash;":(+v[1]).toLocaleString(undefined,{maximumFractionDigits:3}))+"</b><br/>execs: <b>"+(+v[2]).toLocaleString()+"</b>";}},');
    DBMS_OUTPUT.PUT_LINE('    legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
    DBMS_OUTPUT.PUT_LINE('    grid:{left:50,right:30,top:14,bottom:48,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('    xAxis:{type:"category",data:xs,axisLabel:{color:mu,rotate:-30,fontSize:10},splitLine:{show:false}},');
    DBMS_OUTPUT.PUT_LINE('    yAxis:{type:"value",name:"s/exec",nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (+v).toLocaleString(undefined,{maximumFractionDigits:3});}},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('    series:series');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return chart;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.sqlDetails).forEach(function(sqlId){');
    DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("sqltl-"+sqlId); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var chart=null;');
    DBMS_OUTPUT.PUT_LINE('  var details=el.closest("details");');
    DBMS_OUTPUT.PUT_LINE('  function ensure(){ if(!chart){chart=build(el,sqlId);} if(chart){chart.resize();} }');
    DBMS_OUTPUT.PUT_LINE('  if(details){');
    DBMS_OUTPUT.PUT_LINE('    details.addEventListener("toggle",function(){ if(details.open) setTimeout(ensure,0); });');
    DBMS_OUTPUT.PUT_LINE('    if(details.open) ensure();');
    DBMS_OUTPUT.PUT_LINE('  } else { ensure(); }');
    DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){ if(chart) chart.resize(); }).observe(el);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- Hash navigation: SQL_IDs in the top-N tables are anchors of the form
    -- #sql-XXXXXXXXXXXXX pointing at the per-SQL <details>. Browsers do not
    -- auto-open <details> on fragment navigation, so this listener opens
    -- the matching block on initial load and on every hashchange (i.e.
    -- every click of an in-page SQL_ID link).
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('function openHash(){');
    DBMS_OUTPUT.PUT_LINE('  var h=window.location.hash;');
    DBMS_OUTPUT.PUT_LINE('  if(!h || h.length<2) return;');
    DBMS_OUTPUT.PUT_LINE('  var el; try{ el=document.querySelector(h); } catch(e){ return; }');
    DBMS_OUTPUT.PUT_LINE('  if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var det=(el.tagName==="DETAILS")?el:(el.closest&&el.closest("details"));');
    DBMS_OUTPUT.PUT_LINE('  if(det && !det.open){ det.open=true; }');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){ el.scrollIntoView({behavior:"smooth",block:"start"}); }, 50);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("hashchange", openHash);');
    DBMS_OUTPUT.PUT_LINE('if(window.location.hash) setTimeout(openHash, 0);');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
