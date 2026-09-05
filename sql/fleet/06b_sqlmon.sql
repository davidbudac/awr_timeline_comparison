--
-- sql/fleet/06b_sqlmon.sql
-- "SQL Monitor" band in this database's detail row: cheap, always-on
-- summaries (never a DBA_HIST_REPORTS_DETAILS CLOB read -- that's the
-- single-DB report's sqlmon_detail=N phase 2, gated by FLEET_SQLMON_DETAIL
-- only for the per-DB detailed report, never this band) covering executions
-- captured in the Current window vs. the full compared span, errors in
-- Current, plan changes and DOP downgrades. Fleet-owned copy of the "new" /
-- floor logic in sql/18_sqlmon.sql (single-DB file, never edited to add a
-- fleet feature -- see CLAUDE.md's cardinal rule).
--
-- Always on: unlike sql/fleet/06_day_profile.sql (gated by profile_days),
-- this band has no opt-in var -- it's a plain aggregate scan of
-- DBA_HIST_REPORTS bounded to the compared span, same cost class as
-- 04_findings / 05_topsql.
--
-- Informational only: emits <!-- FLEET-COUNTS sqlmon cur=A span=B err=X
-- planchg=Y downgrade=Z --> for humans/tooling grepping the assembled
-- report, but the assembler's scoring regexes only ever match
-- "FLEET-COUNTS findings" and "FLEET-COUNTS topsql" (see run_awr_fleet.sh),
-- so this comment can NEVER affect the row score / sort order -- purely a
-- drill-down aid, like the Day profile band.
--
-- Read-only: one bounded scan of DBA_HIST_REPORTS (component_name=
-- 'sqlmonitor', dbid IN (dbid_list), inst_num pinned to 0 in fleet, span =
-- the same [earliest compared window start, target_end) as the single-DB
-- section). No DBA_HIST_REPORTS_DETAILS access here.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06b BEGIN -->'); END;
/

DECLARE
    v_span_start   DATE;
    v_span_end     DATE;
    v_cur_n        NUMBER := 0;
    v_span_n       NUMBER := 0;
    v_err_n        NUMBER := 0;
    v_planchg_n    NUMBER := 0;
    v_downgrade_n  NUMBER := 0;
    v_any_row      BOOLEAN := FALSE;
BEGIN
    SELECT MIN(win_start_ts), MAX(win_end_ts)
    INTO   v_span_start, v_span_end
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, win_start_ts, win_end_ts FROM windows_rollup
    );

    DBMS_OUTPUT.PUT_LINE('<div class="detail-block">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h">SQL Monitor</div>');

    WITH
    @@sql/lib/windows_cte.sql
    ,
    cur_win AS (
        SELECT win_start_ts, win_end_ts FROM windows_rollup
        WHERE  week_offset = 0 AND valid_flag = 'Y'
    ),
    base_execs AS (
        SELECT r.key1 AS sql_id,
               TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
               x.status, x.plan_hash, x.px_req, x.px_alloc
        FROM   dba_hist_reports r,
               XMLTABLE('/report_repository_summary/sql'
                   PASSING XMLTYPE(r.report_summary)
                   COLUMNS
                       status    VARCHAR2(30) PATH 'status',
                       plan_hash NUMBER       PATH 'plan_hash',
                       px_req    NUMBER       PATH 'px_servers_requested',
                       px_alloc  NUMBER       PATH 'px_servers_allocated'
               ) x
        WHERE  r.component_name = 'sqlmonitor'
          AND  r.dbid IN (~dbid_list)
          AND  r.report_summary IS NOT NULL
          AND  r.key1 IS NOT NULL
          AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
          AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
          AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
          AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end
    ),
    cur_execs AS (
        SELECT b.* FROM base_execs b, cur_win w
        WHERE  b.exec_start >= w.win_start_ts AND b.exec_start < w.win_end_ts
    ),
    plan_counts AS (
        SELECT sql_id,
               COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) AS n_plans
        FROM   base_execs
        GROUP BY sql_id
        HAVING COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) > 1
    )
    SELECT
        (SELECT COUNT(*) FROM cur_execs),
        (SELECT COUNT(*) FROM base_execs),
        (SELECT COUNT(*) FROM cur_execs WHERE status = 'DONE (ERROR)'),
        (SELECT COUNT(*) FROM plan_counts pc
          WHERE EXISTS (SELECT 1 FROM cur_execs c WHERE c.sql_id = pc.sql_id)),
        (SELECT COUNT(DISTINCT sql_id) FROM cur_execs WHERE px_alloc < px_req)
    INTO v_cur_n, v_span_n, v_err_n, v_planchg_n, v_downgrade_n
    FROM dual;

    IF v_span_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div class="detail-link muted">No SQL Monitor reports in the compared span.</div>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<div class="detail-link muted">'
            || v_cur_n || ' execution' || CASE WHEN v_cur_n = 1 THEN '' ELSE 's' END
            || ' in Current &middot; ' || v_span_n || ' in the full span &middot; '
            || v_err_n || ' error' || CASE WHEN v_err_n = 1 THEN '' ELSE 's' END
            || ' &middot; ' || v_planchg_n || ' plan change' || CASE WHEN v_planchg_n = 1 THEN '' ELSE 's' END
            || ' &middot; ' || v_downgrade_n || ' DOP downgrade' || CASE WHEN v_downgrade_n = 1 THEN '' ELSE 's' END
            || '</div>');

        -- Top 5 sql_ids by Current-window max elapsed, with flag chips.
        FOR t IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            cur_win AS (
                SELECT win_start_ts, win_end_ts FROM windows_rollup
                WHERE  week_offset = 0 AND valid_flag = 'Y'
            ),
            base_execs AS (
                SELECT r.key1 AS sql_id,
                       TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                       x.status, x.username, x.plan_hash, x.px_req, x.px_alloc,
                       NVL(x.elapsed_us, 0) AS elapsed_us
                FROM   dba_hist_reports r,
                       XMLTABLE('/report_repository_summary/sql'
                           PASSING XMLTYPE(r.report_summary)
                           COLUMNS
                               status     VARCHAR2(30)  PATH 'status',
                               username   VARCHAR2(128) PATH 'user',
                               plan_hash  NUMBER        PATH 'plan_hash',
                               px_req     NUMBER        PATH 'px_servers_requested',
                               px_alloc   NUMBER        PATH 'px_servers_allocated',
                               elapsed_us NUMBER        PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]'
                       ) x
                WHERE  r.component_name = 'sqlmonitor'
                  AND  r.dbid IN (~dbid_list)
                  AND  r.report_summary IS NOT NULL
                  AND  r.key1 IS NOT NULL
                  AND  r.period_start_time >= CAST(v_span_start AS TIMESTAMP) - INTERVAL '1' DAY
                  AND  r.period_start_time <= CAST(v_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_span_start
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_span_end
            ),
            cur_execs AS (
                SELECT b.* FROM base_execs b, cur_win w
                WHERE  b.exec_start >= w.win_start_ts AND b.exec_start < w.win_end_ts
            ),
            plan_counts AS (
                SELECT sql_id,
                       COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) AS n_plans
                FROM   base_execs
                GROUP BY sql_id
            )
            SELECT c.sql_id,
                   MAX(c.username) KEEP (DENSE_RANK LAST ORDER BY c.exec_start) AS username,
                   MAX(c.elapsed_us) / 1e6 AS max_elapsed_s,
                   COUNT(*) AS n,
                   MAX(CASE WHEN c.status = 'DONE (ERROR)' THEN 1 ELSE 0 END) AS has_error,
                   MAX(CASE WHEN c.px_alloc < c.px_req THEN 1 ELSE 0 END) AS has_downgrade,
                   MAX(NVL(pc.n_plans, 0)) AS n_plans
            FROM   cur_execs c
            LEFT JOIN plan_counts pc ON pc.sql_id = c.sql_id
            GROUP BY c.sql_id
            ORDER BY MAX(c.elapsed_us) DESC NULLS LAST
            FETCH FIRST 5 ROWS ONLY
        ) LOOP
            IF NOT v_any_row THEN
                v_any_row := TRUE;
                DBMS_OUTPUT.PUT_LINE('<table class="dt" data-notools><thead><tr>'
                    || '<th>SQL ID</th><th>User</th><th class="num">Max elapsed (s)</th>'
                    || '<th class="num">n</th><th>Flags</th></tr></thead><tbody>');
            END IF;
            DBMS_OUTPUT.PUT_LINE('<tr><td class="mono">' || t.sql_id || '</td>'
                || '<td>' || DBMS_XMLGEN.CONVERT(NVL(t.username, '?')) || '</td>'
                || '<td class="num">' || TO_CHAR(t.max_elapsed_s, 'FM99999990D000',
                                                 'NLS_NUMERIC_CHARACTERS=''.,''') || '</td>'
                || '<td class="num">' || t.n || '</td>'
                || '<td>'
                || CASE WHEN t.n_plans > 1 THEN '<span class="chip">plan change</span> ' END
                || CASE WHEN t.has_downgrade = 1 THEN '<span class="chip">DOP downgrade</span> ' END
                || CASE WHEN t.has_error = 1 THEN '<span class="chip">error</span> ' END
                || '</td></tr>');
        END LOOP;
        IF v_any_row THEN
            DBMS_OUTPUT.PUT_LINE('</tbody></table>');
        END IF;
    END IF;

    DBMS_OUTPUT.PUT_LINE('</div>');  -- .detail-block

    DBMS_OUTPUT.PUT_LINE('<!-- FLEET-COUNTS sqlmon cur=' || v_cur_n
        || ' span=' || v_span_n || ' err=' || v_err_n
        || ' planchg=' || v_planchg_n || ' downgrade=' || v_downgrade_n || ' -->');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06b END -->'); END;
/
