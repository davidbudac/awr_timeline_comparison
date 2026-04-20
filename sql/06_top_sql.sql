--
-- 06_top_sql.sql
-- Top-N SQL per window from DBA_HIST_SQLSTAT using the pre-computed *_DELTA
-- columns.  Ranks the same SQLs four times: by elapsed_time_delta,
-- cpu_time_delta, buffer_gets_delta, executions_delta.  Joins DBA_HIST_SQLTEXT
-- for a short text snippet.  Each row in the HTML report is expandable to
-- show the full text.
--

SET DEFINE '~'

INSERT INTO awr_trend_top_sql (
    run_id, week_offset, dimension, rank_in_window,
    sql_id, plan_hash_value,
    executions_delta, elapsed_time_delta_us, cpu_time_delta_us,
    buffer_gets_delta, disk_reads_delta, rows_processed_delta,
    sql_text_short
)
WITH run AS (
    SELECT run_id, dbid, instance_number, top_n
    FROM   awr_trend_runs WHERE run_id = ~run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id AND valid_flag = 'Y'
),
agg AS (
    SELECT
        w.run_id, w.week_offset,
        s.sql_id,
        -- Use the most recent plan_hash_value observed inside the window.
        MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
        SUM(NVL(s.executions_delta, 0))        AS executions_delta,
        SUM(NVL(s.elapsed_time_delta, 0))      AS elapsed_time_delta_us,
        SUM(NVL(s.cpu_time_delta, 0))          AS cpu_time_delta_us,
        SUM(NVL(s.buffer_gets_delta, 0))       AS buffer_gets_delta,
        SUM(NVL(s.disk_reads_delta, 0))        AS disk_reads_delta,
        SUM(NVL(s.rows_processed_delta, 0))    AS rows_processed_delta
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_sqlstat s
        ON s.dbid = r.dbid
       AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
       AND (r.instance_number IS NULL OR s.instance_number = r.instance_number)
    GROUP BY w.run_id, w.week_offset, s.sql_id
),
ranked AS (
    SELECT a.*,
           ROW_NUMBER() OVER (
               PARTITION BY run_id, week_offset
               ORDER BY elapsed_time_delta_us DESC, sql_id
           ) AS r_ela,
           ROW_NUMBER() OVER (
               PARTITION BY run_id, week_offset
               ORDER BY cpu_time_delta_us DESC, sql_id
           ) AS r_cpu,
           ROW_NUMBER() OVER (
               PARTITION BY run_id, week_offset
               ORDER BY buffer_gets_delta DESC, sql_id
           ) AS r_gets,
           ROW_NUMBER() OVER (
               PARTITION BY run_id, week_offset
               ORDER BY executions_delta DESC, sql_id
           ) AS r_exec
    FROM   agg a
),
picked AS (
    -- Unpivot the four rankings into one row per (dimension, rank).
    SELECT run_id, week_offset, 'ELAPSED' AS dimension, r_ela AS rnk,
           sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
           cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
    FROM   ranked WHERE r_ela <= (SELECT top_n FROM run) AND elapsed_time_delta_us > 0
    UNION ALL
    SELECT run_id, week_offset, 'CPU', r_cpu,
           sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
           cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
    FROM   ranked WHERE r_cpu <= (SELECT top_n FROM run) AND cpu_time_delta_us > 0
    UNION ALL
    SELECT run_id, week_offset, 'GETS', r_gets,
           sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
           cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
    FROM   ranked WHERE r_gets <= (SELECT top_n FROM run) AND buffer_gets_delta > 0
    UNION ALL
    SELECT run_id, week_offset, 'EXEC', r_exec,
           sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
           cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
    FROM   ranked WHERE r_exec <= (SELECT top_n FROM run) AND executions_delta > 0
)
SELECT
    p.run_id, p.week_offset, p.dimension, p.rnk,
    p.sql_id, p.plan_hash_value,
    p.executions_delta, p.elapsed_time_delta_us, p.cpu_time_delta_us,
    p.buffer_gets_delta, p.disk_reads_delta, p.rows_processed_delta,
    t.sql_text_short
FROM   picked p
CROSS JOIN run r
LEFT JOIN (
    SELECT dbid, sql_id, sql_text_short
    FROM (
        SELECT dbid, sql_id,
               DBMS_LOB.SUBSTR(sql_text, 400, 1) AS sql_text_short,
               ROW_NUMBER() OVER (PARTITION BY dbid, sql_id ORDER BY ROWID) AS rn
        FROM   dba_hist_sqltext
    ) WHERE rn = 1
) t
    ON t.dbid = r.dbid
   AND t.sql_id = p.sql_id;

COMMIT;

--
-- Render four collapsible subsections, one per dimension.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER;
    v_top_n      NUMBER;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_val        NUMBER;
    v_rank       NUMBER;
    v_phv        NUMBER;
    v_phv_cur    NUMBER;
    v_metric     VARCHAR2(40);
    v_divisor    NUMBER;

    TYPE t_dim IS RECORD (
        code   VARCHAR2(10),
        label  VARCHAR2(40),
        unit   VARCHAR2(20),
        col    VARCHAR2(30),
        div    NUMBER
    );
    TYPE t_dim_tab IS TABLE OF t_dim;
    v_dims t_dim_tab;
BEGIN
    SELECT weeks_back, top_n INTO v_weeks_back, v_top_n
    FROM   awr_trend_runs WHERE run_id = ~run_id;

    v_dims := t_dim_tab(
        t_dim('ELAPSED','By elapsed time','s',   'ELAPSED_TIME_DELTA_US', 1e6),
        t_dim('CPU',    'By CPU time',    's',   'CPU_TIME_DELTA_US',     1e6),
        t_dim('GETS',   'By buffer gets', 'gets','BUFFER_GETS_DELTA',     1),
        t_dim('EXEC',   'By executions',  'exec','EXECUTIONS_DELTA',      1)
    );

    DBMS_OUTPUT.PUT_LINE('<section id="topsql"><h2>Top SQL (top ' || v_top_n
        || ' per dimension, per window)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Click a row to reveal full SQL text. The plan-hash column highlights plan changes '
        || 'across weeks (same SQL_ID, different PHV).</p>');

    FOR i IN 1 .. v_dims.COUNT LOOP
        v_metric  := v_dims(i).label;
        v_divisor := v_dims(i).div;

        DBMS_OUTPUT.PUT_LINE('<details' || CASE WHEN i = 1 THEN ' open' END || '>');
        DBMS_OUTPUT.PUT_LINE('<summary>' || v_metric || '</summary>');

        v_header := '<thead><tr><th>SQL_ID</th><th class="num">PHV (cur)</th>'
            || '<th class="num">Current (' || v_dims(i).unit || ')</th>';
        FOR k IN 1 .. v_weeks_back LOOP
            v_header := v_header || '<th class="num">&minus;' || k || 'w</th>';
        END LOOP;
        v_header := v_header || '<th>SQL</th></tr></thead>';
        DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

        FOR s IN (
            SELECT sql_id
            FROM (
                SELECT sql_id,
                       MIN(CASE WHEN week_offset = 0 THEN rank_in_window END) AS cur_rank,
                       MIN(rank_in_window) AS best_rank,
                       MAX(CASE v_dims(i).code
                               WHEN 'ELAPSED' THEN elapsed_time_delta_us
                               WHEN 'CPU'     THEN cpu_time_delta_us
                               WHEN 'GETS'    THEN buffer_gets_delta
                               WHEN 'EXEC'    THEN executions_delta
                           END) AS best_value
                FROM   awr_trend_top_sql
                WHERE  run_id = ~run_id
                AND    dimension = v_dims(i).code
                GROUP BY sql_id
            )
            -- All SQLs that appeared in the top-N of this dimension in any window.
            ORDER BY
                CASE WHEN cur_rank IS NULL THEN 1 ELSE 0 END,
                cur_rank NULLS LAST,
                best_rank,
                best_value DESC,
                sql_id
        ) LOOP
            -- Pull current week values + PHV for this SQL in this dimension.
            v_phv_cur := NULL;
            SELECT MAX(plan_hash_value)
            INTO   v_phv_cur
            FROM   awr_trend_top_sql
            WHERE  run_id = ~run_id AND dimension = v_dims(i).code
            AND    sql_id = s.sql_id AND week_offset = 0;

            v_row := '<tr>'
                || '<td class="mono">' || s.sql_id || '</td>'
                || '<td class="num mono">' ||
                    CASE WHEN v_phv_cur IS NULL THEN '&mdash;'
                         ELSE TO_CHAR(v_phv_cur) END
                || '</td>';

            -- Current value + rank
            DECLARE v_cur NUMBER; v_cur_rnk NUMBER;
            BEGIN
                SELECT
                    MAX(CASE v_dims(i).code
                        WHEN 'ELAPSED' THEN elapsed_time_delta_us
                        WHEN 'CPU'     THEN cpu_time_delta_us
                        WHEN 'GETS'    THEN buffer_gets_delta
                        WHEN 'EXEC'    THEN executions_delta END),
                    MAX(rank_in_window)
                INTO v_cur, v_cur_rnk
                FROM awr_trend_top_sql
                WHERE run_id = ~run_id AND dimension = v_dims(i).code
                  AND sql_id = s.sql_id AND week_offset = 0;

                v_row := v_row || '<td class="num"><b>' ||
                    CASE WHEN v_cur IS NULL THEN '&mdash;'
                         ELSE TO_CHAR(v_cur/v_divisor, 'FM999G999G999G990D00') END
                    || CASE WHEN v_cur_rnk IS NOT NULL
                            THEN ' <span class="badge info">#' || v_cur_rnk || '</span>' ELSE '' END
                    || '</b></td>';
            END;

            -- Prior weeks
            FOR k IN 1 .. v_weeks_back LOOP
                DECLARE v_v NUMBER; v_r NUMBER; v_p NUMBER;
                BEGIN
                    SELECT
                        MAX(CASE v_dims(i).code
                            WHEN 'ELAPSED' THEN elapsed_time_delta_us
                            WHEN 'CPU'     THEN cpu_time_delta_us
                            WHEN 'GETS'    THEN buffer_gets_delta
                            WHEN 'EXEC'    THEN executions_delta END),
                        MAX(rank_in_window),
                        MAX(plan_hash_value)
                    INTO v_v, v_r, v_p
                    FROM awr_trend_top_sql
                    WHERE run_id = ~run_id AND dimension = v_dims(i).code
                      AND sql_id = s.sql_id AND week_offset = k;

                    v_row := v_row || '<td class="num">' ||
                        CASE WHEN v_v IS NULL THEN '&mdash;'
                             ELSE TO_CHAR(v_v/v_divisor, 'FM999G999G999G990D00') END
                        || CASE WHEN v_r IS NOT NULL
                                THEN ' <span class="badge skip">#' || v_r || '</span>' ELSE '' END
                        || CASE
                                WHEN v_p IS NOT NULL AND v_phv_cur IS NOT NULL AND v_p <> v_phv_cur
                                    THEN ' <span class="badge warn" title="Plan changed. Prior PHV ' || v_p || '">plan&#8593;</span>'
                                ELSE '' END
                        || '</td>';
                END;
            END LOOP;

            -- SQL text cell (short snippet, details for full text available below the table)
            DECLARE v_snip VARCHAR2(4000);
            BEGIN
                SELECT MAX(sql_text_short)
                INTO   v_snip
                FROM   awr_trend_top_sql
                WHERE  run_id = ~run_id AND dimension = v_dims(i).code
                AND    sql_id = s.sql_id;
                v_row := v_row || '<td class="mono" style="max-width:500px;">'
                    || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(v_snip, ''), 1, 180))
                    || CASE WHEN LENGTH(NVL(v_snip, '')) > 180 THEN '&hellip;' END
                    || '</td>';
            END;

            v_row := v_row || '</tr>';
            DBMS_OUTPUT.PUT_LINE(v_row);
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        DBMS_OUTPUT.PUT_LINE('</details>');
    END LOOP;

    -- Full SQL text dump ---------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<details><summary>Full SQL text for all listed SQL_IDs</summary>');
    FOR t IN (
        WITH r AS (SELECT dbid FROM awr_trend_runs WHERE run_id = ~run_id),
        tx AS (
            SELECT dbid, sql_id, sql_text
            FROM (
                SELECT dbid, sql_id, sql_text,
                       ROW_NUMBER() OVER (PARTITION BY dbid, sql_id ORDER BY ROWID) AS rn
                FROM   dba_hist_sqltext
            ) WHERE rn = 1
        )
        SELECT ts.sql_id, ht.sql_text
        FROM   (SELECT DISTINCT sql_id FROM awr_trend_top_sql WHERE run_id = ~run_id) ts
        CROSS JOIN r
        LEFT JOIN tx ht
            ON ht.dbid = r.dbid
           AND ht.sql_id = ts.sql_id
        ORDER BY ts.sql_id
    ) LOOP
        DECLARE
            v_full_len  NUMBER;
            v_snip      VARCHAR2(8000);
        BEGIN
            IF t.sql_text IS NULL THEN
                v_full_len := 0;
                v_snip     := '(text not in DBA_HIST_SQLTEXT)';
            ELSE
                v_full_len := DBMS_LOB.GETLENGTH(t.sql_text);
                v_snip     := DBMS_LOB.SUBSTR(t.sql_text, 8000, 1);
            END IF;
            DBMS_OUTPUT.PUT_LINE('<h3>' || t.sql_id || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || DBMS_XMLGEN.CONVERT(v_snip)
                || CASE WHEN v_full_len > 8000
                        THEN CHR(10) || '... (truncated, ' || v_full_len || ' chars total)'
                        ELSE '' END
                || '</pre>');
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</details>');

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
