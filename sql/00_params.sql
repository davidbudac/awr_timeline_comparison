--
-- 00_params.sql
-- Emits the report <header> (editorial masthead) and <nav> TOC,
-- using substitution variables already resolved by the driver.
-- No DML, no tables.
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
--   ~step_hours           cadence between adjacent windows, in hours
--   ~period_unit_long     'hour' | 'day' | 'week'
--   ~period_step_label    e.g. 'w', '2d', '6h'
--   ~win_label            compact width of one window (e.g. '15m', '1h')
--   ~step_label           compact cadence between windows (e.g. '15m', '1w')
--   ~report_path          output filename (relative)
--
-- Run parameters (from defaults.sql or caller):
--   ~target_end, ~win_hours, ~weeks_back, ~top_n, ~inst_num,
--   ~step, ~step_unit
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
    -- =========================================================
    -- Editorial masthead (header.report)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<header class="report">');

    -- Brand line above the headline.
    DBMS_OUTPUT.PUT_LINE('  <div class="brandline">'
        || '<span class="dot">&#9679;</span> AWR '
        || '<span class="slash">/</span> TIMELINE COMPARISON'
        || '</div>');

    -- Top grid: big headline left, run metadata stacked on the right.
    DBMS_OUTPUT.PUT_LINE('  <div class="topgrid">');
    DBMS_OUTPUT.PUT_LINE('    <h1>'
        || DBMS_XMLGEN.CONVERT('~dow_name')
        || ' <em>' || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 12, 5)) || '</em>'
        || '<br>'
        || INITCAP('~period_unit_long') || '-over-' || '~period_unit_long' || ' trend'
        || ' <span class="badge info">run ' || '~run_id' || '</span>'
        || '</h1>');
    DBMS_OUTPUT.PUT_LINE('    <div class="meta">');
    DBMS_OUTPUT.PUT_LINE('      <div><b>' || DBMS_XMLGEN.CONVERT('~db_name')
        || '</b> &middot; DBID ' || '~dbid' || '</div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Host <b>' || DBMS_XMLGEN.CONVERT('~host_name')
        || '</b> &middot; ' || DBMS_XMLGEN.CONVERT('~db_version') || '</div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Generated <b>' || '~generated_at_s' || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('      <div>Run by ' || DBMS_XMLGEN.CONVERT('~caller_user')
        || ' &middot; read-only, no scratch schema</div>');
    DBMS_OUTPUT.PUT_LINE('    </div>');
    DBMS_OUTPUT.PUT_LINE('  </div>');

    -- Param chips (the seven user-facing substitution variables).
    DBMS_OUTPUT.PUT_LINE('  <div class="params">');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip dot">target_end <b>'
        || DBMS_XMLGEN.CONVERT('~target_end_resolved') || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip">win <b>'
        || DBMS_XMLGEN.CONVERT('~win_label') || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip">back <b>'
        || '~weeks_back' || ' &times; ' || DBMS_XMLGEN.CONVERT('~step_label')
        || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip">step <b>'
        || DBMS_XMLGEN.CONVERT('~step_label') || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip">top_n <b>'
        || '~top_n' || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('    <span class="chip">inst_num <b>'
        || '~inst_num'
        || CASE WHEN TO_NUMBER('~inst_num') = 0 THEN ' (cluster)'
                ELSE '' END
        || '</b></span>');
    DBMS_OUTPUT.PUT_LINE('  </div>');

    --
    -- Compared windows: enumerate (weeks_back + 1) aligned windows by
    -- stepping target_end back in ~period_step_label chunks.  Purely derived
    -- from the resolved timestamps; no dependency on any scratch table.
    --
    DBMS_OUTPUT.PUT_LINE('  <div class="windows-list">');
    DBMS_OUTPUT.PUT_LINE('    <b>Compared windows ('
        || DBMS_XMLGEN.CONVERT('~dow_name') || ', '
        || '~win_label each, every ~step_label):</b>');
    DBMS_OUTPUT.PUT_LINE('    <ul>');

    FOR w IN (
        SELECT LEVEL - 1 AS wk,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24) - ~win_hours/24,
                   'YYYY-MM-DD HH24:MI') AS w_start,
               TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - (LEVEL-1)*(~step_hours/24),
                   'YYYY-MM-DD HH24:MI') AS w_end
        FROM   dual
        CONNECT BY LEVEL <= ~weeks_back + 1
        ORDER  BY LEVEL - 1
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('      <li>'
            || CASE WHEN w.wk = 0
                    THEN '<b>Current:</b> '
                    ELSE '<b>&minus;'
                         || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, w.wk)
                         || ':</b> '
               END
            || w.w_start || ' &rarr; ' || w.w_end
            || '</li>');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('    </ul>');
    DBMS_OUTPUT.PUT_LINE('  </div>');
    DBMS_OUTPUT.PUT_LINE('</header>');

    -- =========================================================
    -- Sticky table-of-contents nav. Same anchor IDs the dense
    -- design used; numerals match the per-section h2::before
    -- counters in _style.sql.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
        || '<b>Sections</b>'
        || '<a href="#db-time-summary">01 DB time</a>'
        || '<a href="#overview">02 Overview</a>'
        || '<a href="#ash-timeline">03 ASH timeline</a>'
        || '<a href="#findings">04 Findings</a>'
        || '<a href="#windows">05 Windows</a>'
        || '<a href="#load">06 Load profile</a>'
        || '<a href="#metrics">07 Metrics</a>'
        || '<a href="#waits-fg">08 FG waits</a>'
        || '<a href="#waits-bg">09 BG waits</a>'
        || '<a href="#topsql">10 Top SQL</a>'
        || '</nav>');
END;
/
