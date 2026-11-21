--
-- sql/lib/finding_hints.plsql
--
-- Rule-based "What this usually means" lines and copyable read-only "Next
-- step" queries for the Summary view's finding cards (07) and plan-change
-- cards (18).  Plan 033 (2026-11-17).
--
-- THE TABLE.  One hint per rule id.  07's pick_hint() decides which rule a
-- card gets from the scored rows on that card; 18 always uses PLAN.  Every
-- WHEN line below is ONE source line of the shape
--     WHEN <the rule id, quoted> THEN <the text, quoted>
-- because the demo twin (demo/awrdemo/helpers.py, HINT_TEXT / HINT_SQL)
-- parses them with a regular expression.
-- Wording: hedged ("usually"), names nothing the report did not measure,
-- plain ASCII (HTML entities only), no tilde.  A text may link to a
-- section that is ALWAYS emitted (ROW_LOCK -> #blocking, section 24);
-- never to a row that depends on top-N.
--
-- Query templates: read-only SELECTs over DBA_HIST views the report already
-- reads, bounded like the report.  Placeholders, filled by hint_fill():
--   #DBID#   the Current window's DBID      #B0#  its begin snapshot id
--   #B#      its first delta snapshot (begin + 1)   #E#  its end snapshot id
--   #INST#   ' AND instance_number = n' when the report is filtered to one
--            instance; ' AND instance_number IN (1, 3)' when the report
--            skipped an instance for the Current window (RAC, inst_num 0,
--            e.g. a restart inside it): only the valid ones; else nothing
--   #T0#  #T1#   the Current window's nominal start / end as TIMESTAMP
--            literals (NLS-safe): ASH is cut to [T0, T1) like section 24,
--            whose snapshot range (begin .. end + 1) stays the scan bound
--   #SQLID#  #PH1#  #PH2#   the plan card's sql_id and the two plan hashes
--   #DBIDS#  the report's DBID list (every DBID owning visible snapshots)
--   #NL#: a line break (never put a space right before it)
-- PLAN resolves each plan's DBID and con_id together from ONE row of
-- DBA_HIST_SQL_PLAN (the table DISPLAY_AWR reads): the copy with the latest
-- id-0 TIMESTAMP, then the lowest dbid / con_dbid (section 23's rule),
-- over the report's DBIDs, so a plan captured only under the pre-migration
-- DBID or in one PDB of several is still found.  con_id 0 -> NULL; from a
-- CDB root the 3-argument call finds only plans captured in the root and
-- returns no rows for a PDB's statement (dbmint 2026-11-20).
-- A rule without a query has no WHEN line in hint_sql (it returns NULL).
--
-- To add a rule: one WHEN line in hint_text, optionally one in hint_sql,
-- one condition in pick_hint() in sql/07_summary.sql and in the demo twin's
-- _pick_hint (demo/awrdemo/sections/s07_summary.py), then regenerate the
-- demo (helpers.py reads the two tables from this file).
--
-- Include inside a DECLARE block after every plain variable.  Declares only
-- functions (no TYPE).
--

    FUNCTION hint_text(p_rule VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_rule
            WHEN 'IO_SCANS' THEN 'Rising scattered or direct-path read waits, or more long-table scans, usually mean more full scans: a changed plan, an index that is no longer used, or a new statement. The statements reading the most blocks in the Current window are the place to start.'
            WHEN 'IO_SINGLE' THEN 'More single-block reads usually mean index or rowid access touching more blocks: a less selective plan, more rows per call, or a colder buffer cache. The statements reading the most blocks in the Current window are the place to start.'
            WHEN 'COMMIT_LAT' THEN 'Commit waits (log file sync) rose faster than the commit rate: each commit waited at least 1.5 times as long as in the prior windows. That usually points to slower redo writes (log file parallel write) or a busy log writer rather than to the application.'
            WHEN 'NET_PAYLOAD' THEN 'More &quot;SQL*Net more data to client&quot; or more bytes sent to clients usually means larger result sets or a smaller fetch (array) size in a client. Compare bytes sent per user call with the prior windows.'
            WHEN 'HARD_PARSE' THEN 'More hard parses usually mean statements built with literals instead of bind variables, or cursors invalidated by DDL or statistics gathering.'
            WHEN 'DBTIME_CPU' THEN 'DB time grew mostly on CPU: more work per call (plans, rows) or more calls. The statements using the most CPU in the Current window are the place to start.'
            WHEN 'ROW_LOCK' THEN 'Row lock waits (enq: TX - row lock contention) mean sessions waiting for rows that other sessions changed and have not committed yet: usually application locking or long transactions. The <a href="#blocking">Blocking</a> view shows who blocked whom in the Current window.'
            WHEN 'PLAN' THEN 'A new plan usually follows new optimizer statistics, a different bind value at hard parse, a new or changed index, or an optimizer parameter change. Comparing the two plans shows which step changed.'
        END;
    END hint_text;

    FUNCTION hint_sql(p_rule VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_rule
            WHEN 'IO_SCANS' THEN 'SELECT sql_id, SUM(disk_reads_delta) AS disk_reads, SUM(buffer_gets_delta) AS gets,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY disk_reads DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'IO_SINGLE' THEN 'SELECT sql_id, SUM(disk_reads_delta) AS disk_reads, SUM(buffer_gets_delta) AS gets,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY disk_reads DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'COMMIT_LAT' THEN 'SELECT snap_id, instance_number,#NL#       ROUND((time_waited_micro - LAG(time_waited_micro) OVER (PARTITION BY instance_number ORDER BY snap_id))#NL#             / NULLIF(total_waits - LAG(total_waits) OVER (PARTITION BY instance_number ORDER BY snap_id), 0)#NL#             / 1000, 3) AS avg_write_ms#NL#FROM   dba_hist_bg_event_summary#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B0# AND #E##INST##NL#AND    event_name = ''log file parallel write''#NL#ORDER  BY instance_number, snap_id;'
            WHEN 'NET_PAYLOAD' THEN 'SELECT sql_id, SUM(rows_processed_delta) AS rows_processed, SUM(fetches_delta) AS fetches,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY rows_processed DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'HARD_PARSE' THEN 'SELECT force_matching_signature, COUNT(DISTINCT sql_id) AS sql_ids,#NL#       SUM(executions_delta) AS execs, MIN(sql_id) AS one_sql_id#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#AND    force_matching_signature <> 0#NL#GROUP  BY force_matching_signature#NL#HAVING COUNT(DISTINCT sql_id) > 5#NL#ORDER  BY sql_ids DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'DBTIME_CPU' THEN 'SELECT sql_id, ROUND(SUM(cpu_time_delta) / 1e6, 1) AS cpu_s,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY cpu_s DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'ROW_LOCK' THEN 'SELECT blocking_inst_id, blocking_session, sql_id, COUNT(*) AS samples#NL#FROM   dba_hist_active_sess_history#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B0# AND #E# + 1#INST##NL#AND    sample_time >= #T0# AND sample_time < #T1##NL#AND    event = ''enq: TX - row lock contention''#NL#GROUP  BY blocking_inst_id, blocking_session, sql_id#NL#ORDER  BY samples DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'PLAN' THEN 'SELECT x.*#NL#FROM   (SELECT s.dbid, NULLIF(s.con_id, 0) AS con_id FROM dba_hist_sql_plan s#NL#        WHERE  s.dbid IN (#DBIDS#) AND s.sql_id = ''#SQLID#'' AND s.plan_hash_value = #PH1# AND s.id = 0#NL#        ORDER  BY s.timestamp DESC NULLS LAST, s.dbid, s.con_dbid FETCH FIRST 1 ROW ONLY) p,#NL#       TABLE(DBMS_XPLAN.DISPLAY_AWR(''#SQLID#'', #PH1#, p.dbid, ''TYPICAL'', p.con_id)) x;#NL#SELECT x.*#NL#FROM   (SELECT s.dbid, NULLIF(s.con_id, 0) AS con_id FROM dba_hist_sql_plan s#NL#        WHERE  s.dbid IN (#DBIDS#) AND s.sql_id = ''#SQLID#'' AND s.plan_hash_value = #PH2# AND s.id = 0#NL#        ORDER  BY s.timestamp DESC NULLS LAST, s.dbid, s.con_dbid FETCH FIRST 1 ROW ONLY) p,#NL#       TABLE(DBMS_XPLAN.DISPLAY_AWR(''#SQLID#'', #PH2#, p.dbid, ''TYPICAL'', p.con_id)) x;'
        END;
    END hint_sql;

    -- fill a template; p_begin = the window's begin snapshot id; p_insts =
    -- the Current window's valid instances ('1, 3') when the report skipped
    -- another one for it, else NULL; p_t0 / p_t1 = its nominal start / end
    -- as 'YYYY-MM-DD HH24:MI:SS'; p_dbids = the report's DBID list
    FUNCTION hint_fill(p_tpl   VARCHAR2,
                       p_dbid  NUMBER,
                       p_begin NUMBER,
                       p_end   NUMBER,
                       p_inst  NUMBER,
                       p_sqlid VARCHAR2 DEFAULT NULL,
                       p_ph1   NUMBER   DEFAULT NULL,
                       p_ph2   NUMBER   DEFAULT NULL,
                       p_insts VARCHAR2 DEFAULT NULL,
                       p_t0    VARCHAR2 DEFAULT NULL,
                       p_t1    VARCHAR2 DEFAULT NULL,
                       p_dbids VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        v VARCHAR2(4000) := p_tpl;
    BEGIN
        IF v IS NULL THEN RETURN NULL; END IF;
        v := REPLACE(v, '#INST#', CASE WHEN p_insts IS NOT NULL THEN ' AND instance_number IN (' || p_insts || ')'
                                       WHEN p_inst > 0 THEN ' AND instance_number = ' || TO_CHAR(p_inst) END);
        v := REPLACE(v, '#T0#', 'TIMESTAMP ''' || p_t0 || '''');
        v := REPLACE(v, '#T1#', 'TIMESTAMP ''' || p_t1 || '''');
        v := REPLACE(v, '#DBIDS#', p_dbids);
        v := REPLACE(v, '#SQLID#', p_sqlid);
        v := REPLACE(v, '#PH1#', TO_CHAR(p_ph1));
        v := REPLACE(v, '#PH2#', TO_CHAR(p_ph2));
        v := REPLACE(v, '#DBID#', TO_CHAR(p_dbid));
        v := REPLACE(v, '#B0#', TO_CHAR(p_begin));
        v := REPLACE(v, '#B#', TO_CHAR(p_begin + 1));
        v := REPLACE(v, '#E#', TO_CHAR(p_end));
        RETURN REPLACE(v, '#NL#', CHR(10));
    END hint_fill;

    -- a card's hint block: the hedged line and, when p_sql is given, a
    -- copyable read-only "Next step" (the .codewrap / .copy-btn pattern of
    -- sections 01 and 18); p_key keeps the pre id unique (the card id)
    FUNCTION hint_block(p_rule VARCHAR2, p_key VARCHAR2, p_sql VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_rule IS NULL OR hint_text(p_rule) IS NULL THEN RETURN NULL; END IF;
        RETURN '<div class="fc-hint" data-hint="' || p_rule || '"><p><b>What this usually means.</b> '
            || hint_text(p_rule) || '</p>'
            || CASE WHEN p_sql IS NOT NULL THEN
                   '<p class="fc-next">Next step (read-only):</p>'
                   || '<div class="codewrap" style="position:relative">'
                   || '<button type="button" class="copy-btn" data-copy="#hq-' || p_key || '">Copy</button>'
                   || '<pre id="hq-' || p_key || '" class="sql">' || DBMS_XMLGEN.CONVERT(p_sql) || '</pre></div>'
               END
            || '</div>';
    END hint_block;
