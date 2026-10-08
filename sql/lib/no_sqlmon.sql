--
-- sql/lib/no_sqlmon.sql -- no-op stub included in place of section 18.
--
-- The driver resolves sqlmon_include to this file when the caller passes
-- sqlmon = 'N' (SQLMON=N run_awr_trend.sh), so the section list can always
-- @@-include exactly one file. It emits only section 18's two AWR-SECTION
-- markers (the "every section ran" check still counts the pair) -- no
-- <section>, no DBA_HIST_REPORTS read. 00_params.sql drops the rail link,
-- 17_narrative.sql skips its SQL Monitor rules, and 06's MON cross-links
-- and 19's About note fall back as for any absent target (the chrome hides
-- an .xlink whose target id is missing).
--
SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 18_sqlmon BEGIN -->'); END;
/
BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 18_sqlmon END -->'); END;
/
