--
-- sql/fleet/06_close.sql
-- Closes this database's detail row: the masked single-DB drill-down command
-- (the deep dive into this same database/window), then closes the right
-- column / detail-grid / detail wrappers and the <td>/<tr> opened across
-- 01_row.sql .. 05_topsql.sql, then the sentinel comment.
--
-- The sentinel MUST be the very last line spooled to frag_path -- the
-- wrapper's assembler treats its absence (crashed section, ORA- mid-run, OOM,
-- truncated spool) as proof the fragment is incomplete and demotes this
-- database to an error row instead of trusting a partial page.
--
-- fleet_conn_disp is a password-masked display string (e.g. "user/***@svc")
-- built by the wrapper from fleet.conf -- never the raw connect string, so a
-- credential never round-trips through this HTML.
--
-- Also emits __FLEET_DETAIL_LINE__ on its own line next to the drill command,
-- unconditionally -- this section stays ignorant of whether this DB was
-- flagged for a detailed report (same wrapper-owned philosophy as timeline
-- markers).  The assembler substitutes it with '' (no detail requested), a
-- link to the generated single-DB report, or an explanatory failed/skipped
-- note, using the same per-alias detail rc + report file it already knows
-- about from the __FLEET_DETAIL_CHIP__ substitution in 01_row.sql.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06 BEGIN -->'); END;
/

BEGIN
    -- target_end_resolved carries seconds ('YYYY-MM-DD HH24:MI:SS') but
    -- run_awr_trend.sh's v_target_end validator accepts only minute
    -- precision, so trim to the first 16 chars.  The positional tail
    -- (inst_num=0 + step + step_unit) reproduces the exact same comparison
    -- windows.
    DBMS_OUTPUT.PUT_LINE('<div class="drill">'
        || '<span class="cmt"># drill into this database</span><br>'
        || './run_awr_trend.sh '''
        || DBMS_XMLGEN.CONVERT('~fleet_conn_disp') || ''' '''
        || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 1, 16)) || ''' '
        || '~win_hours' || ' ' || '~weeks_back' || ' ' || '~top_n'
        || ' 0 ' || '~step' || ' ' || DBMS_XMLGEN.CONVERT('~step_unit')
        || '</div>');
    DBMS_OUTPUT.PUT_LINE('__FLEET_DETAIL_LINE__');

    DBMS_OUTPUT.PUT_LINE('</div>');   -- .detail-col-right (opened in 03_headline.sql)
    DBMS_OUTPUT.PUT_LINE('</div>');   -- .detail-grid (opened in 01_row.sql)
    DBMS_OUTPUT.PUT_LINE('</div>');   -- .detail (opened in 01_row.sql)
    DBMS_OUTPUT.PUT_LINE('</td></tr>');  -- .detailrow
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06 END -->'); END;
/

-- Sentinel: the very last spooled line of this fragment. Do not add anything
-- after this block.
BEGIN
    DBMS_OUTPUT.PUT_LINE('<!-- AWR-DB: ' || DBMS_XMLGEN.CONVERT('~fleet_alias') || ' OK -->');
END;
/
