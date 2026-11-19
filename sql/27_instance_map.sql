--
-- 27_instance_map.sql
-- STUB (scaffold): Instance map.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id instance-map) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_instmap.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_instmap.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 27_instance_map BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="instance-map" class="vw in-s in-a lib" style="--os:17"><h2>Instance map'
        || '<small class="h2sub">The findings on a picture of the instance</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_instmap.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 27_instance_map END -->'); END;
/
