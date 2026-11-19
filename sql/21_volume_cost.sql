--
-- 21_volume_cost.sql
-- STUB (scaffold): Volume vs unit cost.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id volume-cost) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_volcost.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_volcost.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 21_volume_cost BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="volume-cost" class="vw in-s in-a lib" style="--os:11"><h2>Volume vs unit cost'
        || '<small class="h2sub">Ran more often, or each run got slower?</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_volcost.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 21_volume_cost END -->'); END;
/
