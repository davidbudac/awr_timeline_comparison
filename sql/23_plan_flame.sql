--
-- 23_plan_flame.sql
-- STUB (scaffold): Plan shape, old vs new.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id plan-flame) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_planflame.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_planflame.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 23_plan_flame BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="plan-flame" class="vw in-s in-a lib" style="--os:13"><h2>Plan shape, old vs new'
        || '<small class="h2sub">Where the time goes inside a changed plan</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_planflame.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 23_plan_flame END -->'); END;
/
