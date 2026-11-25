--
-- sql/lib/css_hostmem.plsql
--
-- The stylesheet of section 30 (Host and memory, plan 046): the four
-- blocks' scrolling table boxes, the configuration and resize lines.
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql, before
-- the design stylesheet).  Single-DB only: the fleet chrome includes
-- sql/_style.sql but not this file.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_hostmem.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_hostmem: plan 046, section 30_host_memory (Host and memory).  Four');
    DBMS_OUTPUT.PUT_LINE('   blocks of section-13-style tables (the chrome wraps a wide one in its');
    DBMS_OUTPUT.PUT_LINE('   own scrolling .tblwrap), the configuration / resize lines and');
    DBMS_OUTPUT.PUT_LINE('   the notes in the muted text colour. */');
    DBMS_OUTPUT.PUT_LINE('#host-memory{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-rd{margin:var(--s2) 0;max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-blk{min-width:0;margin:var(--s3) 0 var(--s4)}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-blk>h3{display:block;margin:var(--s3) 0 var(--s1);font-size:13.5px}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-blk h4{margin:var(--s3) 0 var(--s1);font-size:12.5px;font-weight:600;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-tw{max-width:100%;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-cfg,#host-memory .hm-mq{margin:var(--s1) 0;font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-chg{margin:var(--s1) 0;font-size:13px;padding:4px 8px;border-left:3px solid var(--mk);background:var(--acc-soft)}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .hm-sq td:first-child{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#host-memory .note{font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
