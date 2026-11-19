--
-- 22_wait_histogram.sql
-- STUB (scaffold): Wait latency histograms.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id wait-hist) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_waithist.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_waithist.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 22_wait_histogram BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="wait-hist" class="vw in-s in-a lib" style="--os:12"><h2>Wait latency histograms'
        || '<small class="h2sub">The shape of each wait the averages hide</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_waithist.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 22_wait_histogram END -->'); END;
/
