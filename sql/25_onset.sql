--
-- 25_onset.sql
-- STUB (scaffold): Onset.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id onset) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_onset.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_onset.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 25_onset BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="onset" class="vw in-s in-t in-a lib" style="--os:15"><h2>Onset'
        || '<small class="h2sub">When the shift started</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_onset.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 25_onset END -->'); END;
/
