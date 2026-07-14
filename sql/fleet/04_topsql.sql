--
-- sql/fleet/04_topsql.sql
-- Gated SQL regressions, adapted from sql/06_top_sql.sql's agg chain
-- (window x DBA_HIST_SQLSTAT aggregation) and PEREXEC per-execution
-- regression logic. Two dimensions only (elapsed time, per-exec
-- regression), each floor-gated so the fleet report surfaces only SQL that
-- crossed a warehouse-proven "worth a look" threshold, not every top-N SQL
-- in the window:
--
--   ELAPSED  cur_elapsed > mu_elapsed AND change bucket in (large,
--            moderate) -- falling back to pct_delta >= 25% when the
--            baseline is too short/flat to bucket -- AND cur_elapsed >= 5s.
--            Ranked by (cur_elapsed - mu_elapsed) DESC, top 5.
--   PEREXEC  sql/06_top_sql.sql's regression filters (cur_pe > prior_pe,
--            cur_execs >= 3) plus floors: (cur_pe - prior_pe) >= 0.1s AND
--            cur_elapsed >= 5s. Ranked by (cur_pe - prior_pe) * cur_execs
--            DESC (total added time attributable to the regression), top 5.
--
-- Per row: sql_id (+ plan-flip badge, sql/06_top_sql.sql convention: any
-- non-null prior-window PHV differing from the current PHV), parsing
-- schema (+ data-sys via sql/lib/is_oracle_schema.plsql), current / prior
-- mean / %-delta, a per-window sparkline, and a short SQL text snippet.
--
-- Ends with a machine-readable HTML comment (<!-- FLEET-COUNTS ... -->),
-- the PL/SQL -> bash handoff the wrapper's assembler parses to score this
-- DB. pts is a per-row "estimated added DB time" measure in 30s buckets,
-- capped per row at 10 and left UNCAPPED in the total here -- the
-- assembler applies the final min(25, pts) cap documented in its scoring
-- header. Keep the "topsql n=<int> pts=<int>" token format and spacing
-- exact -- the assembler regex-matches on it.
--
-- Read-only: recomputes everything in-flight from the AWR views; no
-- scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_04 BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_n          PLS_INTEGER := 0;
    v_pts        NUMBER := 0;
    v_cur_dim    VARCHAR2(10);
    v_phv_s      VARCHAR2(64);
    v_plan_flip  BOOLEAN;
    v_is_sys     VARCHAR2(1);
    v_pts_row    NUMBER;

    @@sql/lib/nth_csv.plsql
    @@sql/lib/is_oracle_schema.plsql
BEGIN
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
                   MAX(s.parsing_schema_name) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS parsing_schema,
                   SUM(NVL(s.executions_delta, 0))   AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS elapsed_time_delta_us
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
            GROUP BY w.week_offset, s.sql_id
        ),
        -- Re-grid onto the full week grid before any LISTAGG: a SQL absent
        -- from a window has NO agg row at all (not a NULL measure), and
        -- LISTAGGing the ungridded rows would left-compact the positional
        -- CSVs -- sparkline values and PHV slots would drift onto the wrong
        -- window (the exact phantom-series bug the single-DB section 06
        -- fixed; see sql/lib/nth_csv.plsql's emitter contract).  Gridded,
        -- the folded ','||token keeps an empty slot for missing weeks.
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        agg_grid AS (
            SELECT g.week_offset, g.sql_id,
                   a.plan_hash_value, a.parsing_schema,
                   a.executions_delta, a.elapsed_time_delta_us
            FROM   (SELECT wk.week_offset, q.sql_id
                    FROM   all_weeks wk
                    CROSS JOIN (SELECT DISTINCT sql_id FROM agg) q) g
            LEFT JOIN agg a
                   ON a.week_offset = g.week_offset
                  AND a.sql_id      = g.sql_id
        ),
        -- ---------------------------------------------------------------
        -- ELAPSED dimension: total elapsed time per SQL, current vs prior
        -- mean, same change-bucket formula as the findings recompute.
        -- ---------------------------------------------------------------
        elapsed_agg AS (
            SELECT sql_id,
                   MAX(CASE WHEN week_offset = 0 THEN elapsed_time_delta_us END) AS cur_elapsed,
                   MAX(CASE WHEN week_offset = 0 THEN plan_hash_value END)       AS cur_phv,
                   MAX(CASE WHEN week_offset = 0 THEN parsing_schema END)        AS cur_schema,
                   AVG(CASE WHEN week_offset > 0 THEN elapsed_time_delta_us END) AS mu_elapsed,
                   STDDEV(CASE WHEN week_offset > 0 THEN elapsed_time_delta_us END) AS sd_elapsed,
                   COUNT(CASE WHEN week_offset > 0 THEN elapsed_time_delta_us END)  AS n_elapsed,
                   -- ','||token + SUBSTR fold, DESC = oldest->current: feeds
                   -- the sparkline directly, already converted to seconds.
                   SUBSTR(LISTAGG(',' || TO_CHAR(elapsed_time_delta_us / 1e6,
                              'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,'''))
                       WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_csv,
                   -- Same fold, ASC = current-first: positional lookup via
                   -- nth_csv (slot k+1 <-> week_offset k), sql/06_top_sql.sql
                   -- convention, used for the plan-flip scan below.
                   SUBSTR(LISTAGG(',' || TO_CHAR(plan_hash_value))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_phvs
            FROM   agg_grid
            GROUP BY sql_id
        ),
        elapsed_scored AS (
            SELECT sql_id, cur_elapsed, cur_phv, cur_schema,
                   mu_elapsed, sd_elapsed, n_elapsed, spark_csv, week_phvs,
                   CASE WHEN cur_elapsed IS NULL OR mu_elapsed IS NULL
                             OR mu_elapsed = 0 THEN NULL
                        ELSE (cur_elapsed - mu_elapsed) / ABS(mu_elapsed) * 100 END AS pct,
                   CASE
                       WHEN cur_elapsed IS NULL THEN 'n/a'
                       WHEN n_elapsed < 3 THEN 'insufficient history'
                       WHEN sd_elapsed IS NULL OR sd_elapsed = 0 THEN 'flat baseline'
                       WHEN ABS((cur_elapsed - mu_elapsed) / sd_elapsed) > 3 THEN 'large'
                       WHEN ABS((cur_elapsed - mu_elapsed) / sd_elapsed) > 2 THEN 'moderate'
                       ELSE 'typical'
                   END AS bucket
            FROM   elapsed_agg
        ),
        elapsed_picked AS (
            SELECT sql_id, cur_phv, cur_schema,
                   cur_elapsed / 1e6                    AS cur_disp,
                   mu_elapsed  / 1e6                    AS mu_disp,
                   pct, spark_csv, week_phvs,
                   (cur_elapsed - mu_elapsed) / 1e6      AS impact_disp
            FROM   elapsed_scored
            WHERE  cur_elapsed IS NOT NULL
              AND  mu_elapsed  IS NOT NULL
              AND  cur_elapsed > mu_elapsed
              AND  cur_elapsed >= 5e6                                  -- >= 5s floor
              AND  ( bucket IN ('large', 'moderate')
                     OR (bucket IN ('insufficient history', 'flat baseline')
                         AND pct >= 25) )
        ),
        elapsed_ranked0 AS (
            -- unit is CAST to VARCHAR2 so the UNION ALL's CHAR-literal
            -- blank-padding trap can't pad the shorter 's' token out to
            -- match 's/exec' (sql/06_top_sql.sql documents the same trap
            -- for its schema/module/action grp_type discriminator).
            SELECT CAST('ELAPSED' AS VARCHAR2(10)) AS dim, 1 AS ord,
                   CAST('s' AS VARCHAR2(10)) AS unit,
                   sql_id, cur_phv, cur_schema, cur_disp, mu_disp, pct,
                   impact_disp, spark_csv, week_phvs,
                   ROW_NUMBER() OVER (ORDER BY impact_disp DESC, sql_id) AS rnk
            FROM   elapsed_picked
        ),
        elapsed_ranked AS (
            SELECT * FROM elapsed_ranked0 WHERE rnk <= 5
        ),
        -- ---------------------------------------------------------------
        -- PEREXEC dimension: per-execution elapsed time, regressed vs the
        -- prior mean. Same shape as sql/06_top_sql.sql's per_exec /
        -- delta_ranked CTEs, plus the fleet-only floors.
        -- ---------------------------------------------------------------
        per_exec AS (
            SELECT week_offset, sql_id, plan_hash_value, parsing_schema,
                   executions_delta, elapsed_time_delta_us,
                   CASE WHEN executions_delta > 0
                        THEN elapsed_time_delta_us / executions_delta
                   END AS per_exec_us
            FROM   agg_grid
        ),
        pe_agg AS (
            SELECT sql_id,
                   MAX(CASE WHEN week_offset = 0 THEN per_exec_us END)          AS cur_pe,
                   MAX(CASE WHEN week_offset = 0 THEN executions_delta END)     AS cur_execs,
                   MAX(CASE WHEN week_offset = 0 THEN elapsed_time_delta_us END) AS cur_elapsed,
                   MAX(CASE WHEN week_offset = 0 THEN plan_hash_value END)      AS cur_phv,
                   MAX(CASE WHEN week_offset = 0 THEN parsing_schema END)       AS cur_schema,
                   AVG(CASE WHEN week_offset > 0 THEN per_exec_us END)          AS prior_pe,
                   COUNT(CASE WHEN week_offset > 0 AND per_exec_us IS NOT NULL
                              THEN 1 END)                                       AS n_prior_pe,
                   SUBSTR(LISTAGG(',' || TO_CHAR(per_exec_us / 1e6,
                              'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,'''))
                       WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_csv,
                   SUBSTR(LISTAGG(',' || TO_CHAR(plan_hash_value))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_phvs
            FROM   per_exec
            GROUP BY sql_id
        ),
        pe_picked AS (
            SELECT sql_id, cur_phv, cur_schema,
                   cur_pe   / 1e6 AS cur_disp,
                   prior_pe / 1e6 AS mu_disp,
                   CASE WHEN prior_pe IS NULL OR prior_pe = 0 THEN NULL
                        ELSE (cur_pe - prior_pe) / ABS(prior_pe) * 100 END AS pct,
                   spark_csv, week_phvs,
                   -- impact_disp: estimated added DB time (seconds)
                   -- attributable to the per-exec regression, i.e. the extra
                   -- per-call cost multiplied by how often it now runs --
                   -- the same "worth a look" scale as the ELAPSED dimension.
                   (cur_pe - prior_pe) * cur_execs / 1e6 AS impact_disp
            FROM   pe_agg
            WHERE  cur_pe    IS NOT NULL
              AND  prior_pe  IS NOT NULL
              AND  n_prior_pe >= 1
              AND  cur_pe    > prior_pe
              AND  cur_execs >= 3
              AND  (cur_pe - prior_pe) >= 100000                       -- >= 0.1s/exec floor
              AND  cur_elapsed >= 5e6                                  -- >= 5s floor
        ),
        pe_ranked0 AS (
            SELECT CAST('PEREXEC' AS VARCHAR2(10)) AS dim, 2 AS ord,
                   CAST('s/exec' AS VARCHAR2(10)) AS unit,
                   sql_id, cur_phv, cur_schema, cur_disp, mu_disp, pct,
                   impact_disp, spark_csv, week_phvs,
                   ROW_NUMBER() OVER (ORDER BY impact_disp DESC, sql_id) AS rnk
            FROM   pe_picked
        ),
        pe_ranked AS (
            SELECT * FROM pe_ranked0 WHERE rnk <= 5
        ),
        combined AS (
            SELECT * FROM elapsed_ranked
            UNION ALL
            SELECT * FROM pe_ranked
        ),
        -- One parsing schema/sql text per sql_id, sql/06_top_sql.sql
        -- convention (ORDER BY NULL, not ROWID -- DBA_HIST_SQLTEXT is a
        -- join view in a PDB and ROWID raises ORA-01445).
        text_snips AS (
            SELECT sql_id, sql_text_short FROM (
                SELECT sql_id,
                       DBMS_LOB.SUBSTR(sql_text, 200, 1) AS sql_text_short,
                       ROW_NUMBER() OVER (PARTITION BY sql_id ORDER BY NULL) AS rn
                FROM   dba_hist_sqltext
                WHERE  dbid IN (~dbid_list)
            ) WHERE rn = 1
        )
        SELECT c.dim, c.ord, c.unit, c.sql_id, c.cur_phv, c.cur_schema,
               c.cur_disp, c.mu_disp, c.pct, c.impact_disp,
               c.spark_csv, c.week_phvs, c.rnk,
               ts.sql_text_short
        FROM   combined c
        LEFT JOIN text_snips ts ON ts.sql_id = c.sql_id
        ORDER BY c.ord, c.rnk
    ) LOOP
        IF v_cur_dim IS NULL OR v_cur_dim <> s.dim THEN
            IF v_cur_dim IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('</tbody></table>');
            END IF;
            v_cur_dim := s.dim;
            DBMS_OUTPUT.PUT_LINE('<h3>' ||
                CASE s.dim WHEN 'ELAPSED' THEN 'Top SQL by elapsed time'
                           ELSE 'Top SQL by per-exec regression' END
                || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<table><thead><tr>'
                || '<th>SQL_ID</th><th>Schema</th>'
                || '<th class="num">Current (' || s.unit || ')</th>'
                || '<th class="num">Prior mean (' || s.unit || ')</th>'
                || '<th class="num">% &Delta;</th><th>Trend</th><th>SQL</th>'
                || '</tr></thead><tbody>');
        END IF;

        v_n := v_n + 1;
        -- Per-row point contribution: one point per 30s of estimated added
        -- DB time (impact_disp, seconds), capped at 10/row; the running
        -- total is left uncapped here and finished off by the assembler's
        -- min(25, pts) formula.
        v_pts_row := LEAST(10, GREATEST(CEIL(NVL(s.impact_disp, 0) / 30), 0));
        v_pts := v_pts + v_pts_row;

        v_is_sys := is_oracle_schema(s.cur_schema);

        -- Plan-flip: any non-null prior-window PHV differs from the
        -- current PHV. week_phvs is folded ASC (slot 1 = current window),
        -- so scan slots 2..weeks_back+1, sql/06_top_sql.sql convention.
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

        -- sql_id emitted as plain text: the fleet report has no per-SQL
        -- detail sections, so there is no in-page anchor to link to (the
        -- deep dive is the single-DB drill-down command in 05_close.sql).
        DBMS_OUTPUT.PUT_LINE('<tr data-sys="' || v_is_sys || '">'
            || '<td class="mono">' || s.sql_id
            || CASE WHEN v_plan_flip
                    THEN ' <span class="badge warn" title="Plan changed between current and a prior compared window">plan&#8593;</span>'
                    ELSE '' END
            || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(s.cur_schema, '(unknown)')) || '</td>'
            || '<td class="num">' ||
                CASE WHEN s.cur_disp IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.cur_disp, 'FM999G999G990D000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN s.mu_disp IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.mu_disp, 'FM999G999G990D000') END || '</td>'
            || '<td class="num">' ||
                CASE WHEN s.pct IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.pct, 'FMS99990D0') || '%' END || '</td>'
            || '<td class="trend" data-spark="' || NVL(s.spark_csv, '')
                || '" data-spark-title="' || s.dim || '"></td>'
            || '<td class="mono">'
                || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(s.sql_text_short, ''), 1, 180))
                || CASE WHEN LENGTH(NVL(s.sql_text_short, '')) > 180 THEN '&hellip;' END
                || '</td>'
            || '</tr>');
    END LOOP;

    IF v_cur_dim IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<h3>Top SQL regressions</h3>');
        DBMS_OUTPUT.PUT_LINE('<p>No SQL crossed the regression floors '
            || '(elapsed &ge;5s and 2&sigma; or &ge;25% above its prior mean; '
            || 'or per-exec &ge;0.1s/exec slower with &ge;3 executions and &ge;5s elapsed).</p>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('<!-- FLEET-COUNTS topsql n=' || v_n
        || ' pts=' || TO_CHAR(v_pts, 'FM999999990') || ' -->');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_04 END -->'); END;
/
