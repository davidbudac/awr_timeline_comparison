--
-- sql/lib/css_timemodel.plsql
--
-- The stylesheet of section 02's time model table (plan 043): one indent
-- step per depth in the tree, background rows set off by a rule.
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql, before
-- the design stylesheet).  Single-DB only: the fleet chrome includes
-- sql/_style.sql but not this file.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_timemodel.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_timemodel: plan 043, section 02''s time model table (single-DB only).');
    DBMS_OUTPUT.PUT_LINE('   One indent step per depth in the tree (data-lvl 1-5), background rows set');
    DBMS_OUTPUT.PUT_LINE('   off by a rule; the notes in the muted text colour. */');
    DBMS_OUTPUT.PUT_LINE('#load .tm-intro,#load .tm-drop,#load .tm-none{color:var(--muted);font-size:12.5px;max-width:110ch;margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l2>td:first-child{padding-left:26px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l3>td:first-child{padding-left:42px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l4>td:first-child{padding-left:58px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l5>td:first-child{padding-left:74px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr:not(.tm-l1)>td:first-child .tm-n::before{content:"\2514\00a0";color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l1 .tm-n{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-bg1>td{border-top:2px solid var(--line)}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model td.tm-pct{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('/* phones: the first column is sticky in the scrolling table, so it must stay');
    DBMS_OUTPUT.PUT_LINE('   narrow enough to leave the numbers room -- wrap the names, smaller steps */');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:600px){');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tbody td:first-child{white-space:normal;min-width:120px;max-width:150px;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l2>td:first-child{padding-left:16px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l3>td:first-child{padding-left:22px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l4>td:first-child{padding-left:28px}');
    DBMS_OUTPUT.PUT_LINE('#load-time-model tr.tm-l5>td:first-child{padding-left:34px}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
