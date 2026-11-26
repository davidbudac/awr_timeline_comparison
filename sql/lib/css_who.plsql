--
-- sql/lib/css_who.plsql
--
-- The stylesheet of section 29 (Who added the load, plan 045): one small
-- table per dimension in a grid, the share-of-the-rise bar.
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql, before
-- the design stylesheet).  Single-DB only: the fleet chrome includes
-- sql/_style.sql but not this file.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_who.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_who: plan 045, section 29_who (Who added the load).  One small table');
    DBMS_OUTPUT.PUT_LINE('   per dimension in a grid (one column below about 1600 px of content), a share-of-the-rise bar');
    DBMS_OUTPUT.PUT_LINE('   in the accent, the notes in the muted text colour. */');
    DBMS_OUTPUT.PUT_LINE('#who{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#who .who-tot,#who .who-rd{margin:var(--s2) 0;max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('#who .who-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,780px),1fr));gap:var(--s3) var(--s5);margin:var(--s3) 0}');
    DBMS_OUTPUT.PUT_LINE('#who .who-dim{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#who .who-dim>h3{display:block;margin:var(--s2) 0 var(--s1);font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#who .who-nv{font-weight:400;color:var(--muted);margin-left:8px;font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('#who td.who-v{min-width:9em;max-width:22em;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('#who td.who-sh{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#who .who-bar{display:inline-block;vertical-align:middle;width:56px;height:8px;border-radius:4px;background:var(--track);margin-right:6px;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#who .who-bar>i{display:block;height:100%;width:var(--w);background:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('#who .who-p{font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#who tr.who-all>td{border-top:1px solid var(--line);color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#who .who-more{margin:var(--s1) 0}');
    DBMS_OUTPUT.PUT_LINE('#who .who-more>summary{cursor:pointer;color:var(--ink-2);font-size:12.5px}');
    DBMS_OUTPUT.PUT_LINE('#who .who-meth{font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
