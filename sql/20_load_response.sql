--
-- 20_load_response.sql
-- STUB (scaffold): Load vs response time.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id load-response) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_loadresp.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_loadresp.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 20_load_response BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="load-response" class="vw in-s in-a lib" style="--os:10"><h2>Load vs response time'
        || '<small class="h2sub">More load, or something broken?</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_loadresp.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 20_load_response END -->'); END;
/
