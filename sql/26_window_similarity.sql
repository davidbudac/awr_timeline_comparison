--
-- 26_window_similarity.sql
-- STUB (scaffold): Window similarity.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id win-sim) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_winsim.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_winsim.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 26_window_similarity BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="win-sim" class="vw in-s in-a lib" style="--os:16"><h2>Window similarity'
        || '<small class="h2sub">Is the baseline itself sound, and what if a window is dropped?</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_winsim.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 26_window_similarity END -->'); END;
/
