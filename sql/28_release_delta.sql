--
-- 28_release_delta.sql
-- STUB (scaffold): Before and after a release.  The section's owner replaces this file.
-- Contract kept by the scaffold: the two AWR-SECTION markers, ONE
-- section element (id release-delta) that is ALWAYS emitted (the rail links to it),
-- its stylesheet in sql/lib/css_reldelta.plsql (included in <head> by
-- sql/lib/viz_head.sql) and its script in sql/lib/js_reldelta.plsql
-- (included below).  Read-only: SELECT only.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 28_release_delta BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="release-delta" class="vw in-s in-a lib" style="--os:18"><h2>Before and after a release'
        || '<small class="h2sub">What moved across each marker</small></h2>');
    DBMS_OUTPUT.PUT_LINE('<p class="note">Not implemented yet.</p></section>');
END;
/

@@sql/lib/js_reldelta.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 28_release_delta END -->'); END;
/
