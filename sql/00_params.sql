--
-- 00_params.sql
-- Emits the report <nav> + <header> card using substitution variables
-- already resolved by the driver.  No DML, no tables.
--
-- Expects these substitution variables from awr_trend.sql:
--   ~run_id               17-digit timestamp run identifier
--   ~dbid                 v$database.dbid (integer)
--   ~db_name              v$database.name (trimmed)
--   ~host_name            v$instance.host_name
--   ~db_version           v$instance.version
--   ~caller_user          USER
--   ~generated_at_s       'YYYY-MM-DD HH24:MI:SS TZR'
--   ~target_end_resolved  'YYYY-MM-DD HH24:MI:SS'
--   ~dow_name             trimmed day-of-week name of target_end
--   ~report_path          output filename (relative)
--
-- Run parameters (from defaults.sql or caller):
--   ~target_end, ~win_hours, ~weeks_back, ~top_n, ~inst_num
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
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
        || DBMS_XMLGEN.CONVERT('~db_name')
        || ' <span class="badge info">run ' || '~run_id' || '</span></h1>');
    DBMS_OUTPUT.PUT_LINE('  <div class="meta">');
    DBMS_OUTPUT.PUT_LINE('    <div><b>Host:</b> ' || DBMS_XMLGEN.CONVERT('~host_name') || '</div>');
    DBMS_OUTPUT.PUT_LINE('    <div><b>Generated:</b> ' || '~generated_at_s' || '</div>');
    DBMS_OUTPUT.PUT_LINE('    <div><b>Run by:</b> ' || DBMS_XMLGEN.CONVERT('~caller_user')
        || ' (read-only; no scratch schema)</div>');
    DBMS_OUTPUT.PUT_LINE('  </div>');

    --
    -- Compared windows: enumerate (weeks_back + 1) aligned windows by
    -- stepping target_end back in 7-day chunks.  Purely derived from the
    -- resolved timestamps; no dependency on any scratch table.
    --
    DBMS_OUTPUT.PUT_LINE('  <div class="windows-list" style="margin-top:10px;">');
    DBMS_OUTPUT.PUT_LINE('    <b>Compared windows ('
        || DBMS_XMLGEN.CONVERT('~dow_name') || ', '
        || '~win_hours' || 'h each):</b>');
    DBMS_OUTPUT.PUT_LINE('    <ul style="margin:4px 0 0 0;padding-left:22px;'
        || 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;'
        || 'font-size:12px;line-height:1.6;">');

    FOR w IN (
        SELECT LEVEL - 1 AS wk,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*7 - ~win_hours/24,
                   'YYYY-MM-DD HH24:MI') AS w_start,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*7,
                   'YYYY-MM-DD HH24:MI') AS w_end
        FROM   dual
        CONNECT BY LEVEL <= ~weeks_back + 1
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
END;
/
