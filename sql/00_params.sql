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
            || '<a href="#findings">Findings</a>'
            || '<a href="#windows">Windows</a>'
            || '<a href="#load">Load profile</a>'
            || '<a href="#metrics">System metrics</a>'
            || '<a href="#waits-fg">FG waits</a>'
            || '<a href="#waits-bg">BG waits</a>'
            || '<a href="#topsql">Top SQL</a>'
            || '</nav>');

        DBMS_OUTPUT.PUT_LINE('<header class="report">');
        DBMS_OUTPUT.PUT_LINE('  <div class="eyebrow">Oracle 19c AWR week-over-week comparison</div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="hero-grid">');
        DBMS_OUTPUT.PUT_LINE('    <div class="hero-copy">');
        DBMS_OUTPUT.PUT_LINE('      <h1>AWR Timeline Comparison &mdash; '
            || DBMS_XMLGEN.CONVERT(TRIM(r.db_name))
            || ' <span class="badge info">run #' || r.run_id || '</span></h1>');
        DBMS_OUTPUT.PUT_LINE('      <p class="lede">Comparing the current window against the '
            || r.weeks_back || ' prior '
            || RTRIM(DBMS_XMLGEN.CONVERT(TRIM(r.dow)))
            || ' window(s) at the same hour-of-day. The raw facts are still preserved in the scratch schema, but the presentation now leans harder on quick visual scanning.</p>');
        DBMS_OUTPUT.PUT_LINE('      <div class="hero-badges">'
            || '<span class="badge info">' || DBMS_XMLGEN.CONVERT(r.scope) || '</span> '
            || '<span class="badge ok">' || r.weeks_back || ' prior week(s)</span> '
            || '<span class="badge warn">Top ' || r.top_n || ' waits / SQL</span>'
            || '</div>');
        DBMS_OUTPUT.PUT_LINE('    </div>');
        DBMS_OUTPUT.PUT_LINE('    <div class="hero-stats">');
        DBMS_OUTPUT.PUT_LINE('      <div class="stat-line"><span>Window</span><strong>'
            || DBMS_XMLGEN.CONVERT(r.win_start_s) || ' &rarr; '
            || DBMS_XMLGEN.CONVERT(r.target_end_s) || '</strong></div>');
        DBMS_OUTPUT.PUT_LINE('      <div class="stat-line"><span>Scope</span><strong>'
            || DBMS_XMLGEN.CONVERT(r.inst_label) || '</strong></div>');
        DBMS_OUTPUT.PUT_LINE('      <div class="stat-line"><span>Host</span><strong>'
            || DBMS_XMLGEN.CONVERT(r.host_name) || '</strong></div>');
        DBMS_OUTPUT.PUT_LINE('      <div class="stat-line"><span>Generated</span><strong>'
            || DBMS_XMLGEN.CONVERT(r.gen_s) || '</strong></div>');
        DBMS_OUTPUT.PUT_LINE('    </div>');
        DBMS_OUTPUT.PUT_LINE('  </div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="meta">');
        DBMS_OUTPUT.PUT_LINE('    <div><b>DBID:</b> ' || r.dbid || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Host:</b> ' || DBMS_XMLGEN.CONVERT(r.host_name) || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Version:</b> ' || DBMS_XMLGEN.CONVERT(r.db_version) || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Instance scope:</b> ' || r.inst_label || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Current window:</b> '
            || r.win_start_s || ' &rarr; ' || r.target_end_s
            || ' (' || r.win_hours || 'h)</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Weeks back:</b> ' || r.weeks_back || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Top-N:</b> ' || r.top_n || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>Generated:</b> ' || r.gen_s || '</div>');
        DBMS_OUTPUT.PUT_LINE('    <div><b>By:</b> ' || DBMS_XMLGEN.CONVERT(r.caller_user) || '</div>');
        DBMS_OUTPUT.PUT_LINE('  </div>');
        DBMS_OUTPUT.PUT_LINE('</header>');
    END LOOP;
END;
/
