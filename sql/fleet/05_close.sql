--
-- sql/fleet/05_close.sql
-- Closes this database's card: a drill-down line showing the exact
-- single-DB command to run for the full 16-section report against this
-- same database/window, then </section>, then the sentinel comment.
--
-- The sentinel MUST be the very last line spooled to frag_path -- the
-- wrapper's assembler treats its absence (crashed section, ORA- mid-run,
-- OOM, truncated spool) as proof the fragment is incomplete and demotes
-- this database to an error card instead of trusting a partial page.
--
-- fleet_conn_disp is a password-masked display string (e.g. "user/***@svc")
-- built by the wrapper from fleet.conf -- never the raw connect string, so
-- a credential never round-trips through this HTML.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_05 BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<p class="muted">Drill down with the full single-DB report:</p>');
    -- target_end_resolved carries seconds ('YYYY-MM-DD HH24:MI:SS') but
    -- run_awr_trend.sh's v_target_end validator accepts only minute
    -- precision, so trim to the first 16 chars.  The positional tail
    -- (inst_num=0 + step + step_unit) is passed through so a non-default
    -- cadence reproduces the exact same comparison windows.
    DBMS_OUTPUT.PUT_LINE('<code class="drill">./run_awr_trend.sh '''
        || DBMS_XMLGEN.CONVERT('~fleet_conn_disp') || ''' '''
        || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 1, 16)) || ''' '
        || '~win_hours' || ' ' || '~weeks_back' || ' ' || '~top_n'
        || ' 0 ' || '~step' || ' ' || DBMS_XMLGEN.CONVERT('~step_unit')
        || '</code>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_05 END -->'); END;
/

-- Sentinel: the very last spooled line of this fragment. Do not add
-- anything after this block.
BEGIN
    DBMS_OUTPUT.PUT_LINE('<!-- AWR-DB: ' || DBMS_XMLGEN.CONVERT('~fleet_alias') || ' OK -->');
END;
/
