--
-- 00_params.sql
-- Emits the report's sticky top bar (.topbar): brand on the left, a single
-- breadcrumb line summarizing what's being compared, and a right-side
-- monospace meta strip (dbid / generated). Replaces the older nav.toc +
-- header.report card. Read-only; no DML.
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
--   ~period_unit_short    'h' | 'd' | 'w'
--   ~period_unit_long     'hour' | 'day' | 'week'
--   ~period_step_label    e.g. 'w', '2d', '6h'
--   ~win_label            compact window width      (e.g. '1h', '15m')
--   ~step_label           compact cadence text      (e.g. '1w', '15m')
--
-- Run parameters (from defaults.sql or caller):
--   ~target_end, ~win_hours, ~weeks_back, ~top_n, ~inst_num,
--   ~step, ~step_unit
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_period_label  VARCHAR2(120);
    v_shape_label   VARCHAR2(80);
    v_inst_label    VARCHAR2(80);
    v_gen_short     VARCHAR2(80);
BEGIN
    -- Build the breadcrumb segments in one round-trip.  Period text mirrors
    -- the mockup: "Friday 14:00-15:00".  Shape text is "<win> x <count><unit>",
    -- e.g. "1h x 5w" or "15m x 5(15m)".  Inst label tags inst_num=0 as agg.
    SELECT
        TRIM('~dow_name') || ' '
            || TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS')
                       - ~win_hours/24,
                   'HH24:MI')
            || '&ndash;'
            || TO_CHAR(
                   TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS'),
                   'HH24:MI')                                          AS period_label,
        '~win_label' || ' &times; '
            || TO_CHAR(~weeks_back + 1)
            || CASE WHEN '~step_label' LIKE '_'      -- single-char step ('h','d','w')
                    THEN '~step_label'
                    ELSE '(~step_label)' END                            AS shape_label,
        'inst <b>' || '~inst_num' || '</b>'
            || CASE WHEN '~inst_num' = '0' THEN ' (agg)' ELSE '' END    AS inst_label,
        TO_CHAR(
            TO_TIMESTAMP_TZ('~generated_at_s', 'YYYY-MM-DD HH24:MI:SS TZR'),
            'YYYY-MM-DD HH24:MI TZR')                                   AS gen_short
    INTO v_period_label, v_shape_label, v_inst_label, v_gen_short
    FROM dual;

    DBMS_OUTPUT.PUT_LINE('<div class="topbar">');
    DBMS_OUTPUT.PUT_LINE('  <div class="brand"><span class="dot"></span>AWR&nbsp;TIMELINE</div>');
    DBMS_OUTPUT.PUT_LINE('  <div class="crumbs">'
        || '<b>' || DBMS_XMLGEN.CONVERT('~db_name') || '</b>'
        || '<span class="sep">/</span>' || v_period_label
        || '<span class="sep">/</span>' || v_shape_label
        || '<span class="sep">/</span>' || v_inst_label
        || '</div>');
    DBMS_OUTPUT.PUT_LINE('  <div class="right">');
    DBMS_OUTPUT.PUT_LINE('    <div>dbid <b>' || '~dbid' || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('    <div>host <b>' || DBMS_XMLGEN.CONVERT('~host_name') || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('    <div>generated <b>' || v_gen_short || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('    <div>run <b>' || '~run_id' || '</b></div>');
    DBMS_OUTPUT.PUT_LINE('  </div>');
    DBMS_OUTPUT.PUT_LINE('</div>');

    -- Compact section nav rendered just under the topbar so jump-links remain
    -- accessible without taking the full topbar slot.
    DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
        || '<b>Jump to:</b> '
        || '<a href="#db-time-summary">DB time</a>'
        || '<a href="#overview">Overview</a>'
        || '<a href="#findings">Findings</a>'
        || '<a href="#waits-fg">FG waits</a>'
        || '<a href="#topsql">Top SQL</a>'
        || '<a href="#ash-timeline">ASH</a>'
        || '<a href="#load">Load</a>'
        || '<a href="#metrics">Metrics</a>'
        || '<a href="#waits-bg">BG waits</a>'
        || '<a href="#windows">Windows</a>'
        || '</nav>');
END;
/
