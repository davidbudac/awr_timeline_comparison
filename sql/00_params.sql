--
-- 00_params.sql
-- Resolves run parameters and emits the report header card.
-- Expects the driver to have set these substitution variables:
--   ~run_id         numeric, pre-allocated from awr_trend_run_seq
--   ~target_end     'YYYY-MM-DD HH24:MI' (may be the sentinel 'AUTO')
--   ~win_hours      number of hours in one window
--   ~weeks_back     number of prior aligned windows
--   ~top_n          top-N cap for SQL / waits
--   ~inst_num       0 = aggregate across RAC, otherwise instance number
--
-- Inserts the AWR_TREND_RUNS row with status='RUNNING' and emits a HTML
-- <header> block describing the run.
--

SET DEFINE '~'

--
-- Insert the RUNS row. Resolve AUTO -> prior-hour floor inside the INSERT so
-- the exact timestamp we store matches what section scripts will derive.
--
INSERT INTO awr_trend_runs (
    run_id, dbid, db_name, instance_number,
    target_end_ts, win_hours, weeks_back, top_n, scope,
    generated_at, report_path, caller_user, status
)
SELECT
    ~run_id,
    d.dbid,
    d.name,
    CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END,
    CAST(
        CASE
            WHEN UPPER('~target_end') IN ('AUTO','NOW','')
                THEN TRUNC(SYSDATE, 'HH24')
            ELSE TO_DATE('~target_end', 'YYYY-MM-DD HH24:MI')
        END AS TIMESTAMP
    ),
    ~win_hours, ~weeks_back, ~top_n,
    CASE WHEN ~inst_num = 0 THEN 'ALL' ELSE 'INSTANCE' END,
    SYSTIMESTAMP,
    '~report_path',
    USER,
    'RUNNING'
FROM v$database d;

COMMIT;

--
-- Emit the HTML header using the freshly inserted row as the source of truth.
--
BEGIN
    FOR r IN (
        SELECT
            r.run_id,
            r.dbid,
            r.db_name,
            NVL(TO_CHAR(r.instance_number), 'ALL (aggregated)') AS inst_label,
            r.target_end_ts,
            TO_CHAR(r.target_end_ts, 'YYYY-MM-DD HH24:MI') AS target_end_s,
            TO_CHAR(CAST(r.target_end_ts AS DATE) - r.win_hours/24,
                    'YYYY-MM-DD HH24:MI') AS win_start_s,
            TO_CHAR(r.target_end_ts, 'Day') AS dow,
            r.win_hours,
            r.weeks_back,
            r.top_n,
            r.scope,
            TO_CHAR(r.generated_at, 'YYYY-MM-DD HH24:MI:SS TZR') AS gen_s,
            r.caller_user,
            r.report_path,
            (SELECT version FROM v$instance) AS db_version,
            (SELECT host_name FROM v$instance) AS host_name
        FROM awr_trend_runs r
        WHERE r.run_id = ~run_id
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
            || '<b>Jump to:</b> '
            || '<a href="#overview">Overview</a>'
            || '<a href="#ash-timeline">ASH timeline</a>'
            || '<a href="#findings">Findings</a>'
            || '<a href="#windows">Windows</a>'
            || '<a href="#load">Load profile</a>'
            || '<a href="#metrics">System metrics</a>'
            || '<a href="#waits-fg">FG waits</a>'
            || '<a href="#waits-bg">BG waits</a>'
            || '<a href="#topsql">Top SQL</a>'
            || '</nav>');

        DBMS_OUTPUT.PUT_LINE('<header class="report">');
        DBMS_OUTPUT.PUT_LINE('  <h1>AWR Timeline Comparison &mdash; '
            || DBMS_XMLGEN.CONVERT(TRIM(r.db_name))
            || ' <span class="badge info">run #' || r.run_id || '</span></h1>');
        DBMS_OUTPUT.PUT_LINE('  <div class="meta">');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Host:</b> ' || DBMS_XMLGEN.CONVERT(r.host_name) || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Generated:</b> ' || r.gen_s || '</div>');
        DBMS_OUTPUT.PUT_LINE('  </div>');

        --
        -- Compared windows: enumerate the (weeks_back + 1) aligned windows
        -- by shifting target_end backwards in 7-day steps.  Derived purely
        -- from r.target_end_ts / r.win_hours / r.weeks_back so we do not
        -- depend on awr_trend_windows (which is populated by 01_windows.sql
        -- *after* this section runs).
        --
        DBMS_OUTPUT.PUT_LINE('  <div class="windows-list" style="margin-top:10px;">');
        DBMS_OUTPUT.PUT_LINE('    <b>Compared windows ('
            || RTRIM(DBMS_XMLGEN.CONVERT(TRIM(r.dow))) || ', '
            || r.win_hours || 'h each):</b>');
        DBMS_OUTPUT.PUT_LINE('    <ul style="margin:4px 0 0 0;padding-left:22px;'
            || 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;'
            || 'font-size:12px;line-height:1.6;">');
        FOR w IN (
            SELECT LEVEL - 1 AS wk,
                   TO_CHAR(CAST(r.target_end_ts AS DATE) - (LEVEL-1)*7 - r.win_hours/24,
                           'YYYY-MM-DD HH24:MI') AS w_start,
                   TO_CHAR(CAST(r.target_end_ts AS DATE) - (LEVEL-1)*7,
                           'YYYY-MM-DD HH24:MI') AS w_end
            FROM   dual
            CONNECT BY LEVEL <= r.weeks_back + 1
            ORDER  BY LEVEL - 1
        ) LOOP
            DBMS_OUTPUT.PUT_LINE('      <li>'
                || CASE WHEN w.wk = 0 THEN '<b>Current:</b>   '
                        WHEN w.wk = 1 THEN '<b>&minus;1 week:</b>  '
                        ELSE '<b>&minus;' || w.wk || ' weeks:</b> '
                   END
                || w.w_start || ' &rarr; ' || w.w_end
                || '</li>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('    </ul>');
        DBMS_OUTPUT.PUT_LINE('  </div>');
        DBMS_OUTPUT.PUT_LINE('</header>');
    END LOOP;
END;
/
