--
-- sql/lib/css_sqlsplit.plsql
--
-- The stylesheet of section 06's "Per execution: where the time went" block
-- in an opened Per-SQL pool row (plan 044).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql, before
-- the design stylesheet).  Single-DB only: the fleet chrome includes
-- sql/_style.sql but not this file.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_sqlsplit.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_sqlsplit: plan 044, section 06''s "Per execution: where the time went"');
    DBMS_OUTPUT.PUT_LINE('   block in an opened Per-SQL pool row (single-DB only).  The parts of elapsed');
    DBMS_OUTPUT.PUT_LINE('   indented under it, the work rows set off by a rule, the Reads-as line. */');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail div.sqx{margin:0 0 6px}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail table.sqx-tbl{margin:8px 0 6px}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail table.sqx-tbl tr.sqx-e>td{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail table.sqx-tbl tr.sqx-p>td:first-child{padding-left:22px}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail table.sqx-tbl tr.sqx-w1>td{border-top:2px solid var(--line)}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail table.sqx-tbl td:last-child{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail p.sqx-rd{margin:4px 0 8px;font-size:12.5px;max-width:110ch;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail p.sqx-rd b{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('/* .sqd-tw scrolls sideways (overflow-x:auto), so a sticky header would stick');
    DBMS_OUTPUT.PUT_LINE('   to that wrapper and sit over the first row (the Compared windows table''s');
    DBMS_OUTPUT.PUT_LINE('   Current row, this block''s Elapsed row): no sticky header in the pool row */');
    DBMS_OUTPUT.PUT_LINE('tr.sql-detail .sqd-tw thead th{position:static}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
