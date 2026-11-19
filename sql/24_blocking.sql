--
-- 24_blocking.sql
-- STUB (scaffold): Blocking.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id blocking) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_blocking.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_blocking.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 24_blocking BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="blocking" class="vw in-s in-a lib" style="--os:14"><h2>Blocking'
        || '<small class="h2sub">Who waited on whom in the Current window</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_blocking.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 24_blocking END -->'); END;
/
