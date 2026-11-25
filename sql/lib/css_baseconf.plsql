--
-- sql/lib/css_baseconf.plsql
--
-- The stylesheet of the "n = 4" qualifier on the finding cards (plan 039).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql, before
-- the design stylesheet).  Single-DB only: the fleet chrome includes
-- sql/_style.sql but not this file.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_baseconf.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_baseconf: plan 039, the "n = 4" qualifier on the finding cards (single-DB only).');
    DBMS_OUTPUT.PUT_LINE('   data-n is generated content, never text: Copy summary and the dashboard read the');
    DBMS_OUTPUT.PUT_LINE('   .nrm / .fc-sum text, and the title on .nrm gives the two rates for that n. */');
    DBMS_OUTPUT.PUT_LINE('.fc .big .nrm[data-n]::after,.fc .fc-sum[data-n]::after{content:" \00b7  n = " attr(data-n);color:var(--ink-4);font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
