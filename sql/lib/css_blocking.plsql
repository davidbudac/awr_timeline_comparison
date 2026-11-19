--
-- sql/lib/css_blocking.plsql
--
-- The stylesheet of section 24_blocking (Blocking).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_blocking.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_blocking: styles of section 24_blocking (Blocking). */');
    DBMS_OUTPUT.PUT_LINE('#blocking{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-strip{margin:var(--s2) 0 var(--s3);overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-ns{display:block;font-size:11px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-lg{display:flex;flex-wrap:wrap;gap:var(--s2) var(--s4);font-size:12px;color:var(--ink-3);margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-lg span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-k{display:inline-block;width:16px;height:11px;border-radius:3px;border:1.5px solid var(--ink-3);background:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-kr{border-color:var(--ink);border-width:2px}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-kw{border-color:var(--acc);background:var(--acc-soft)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-kn{border-style:dashed;border-color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-ke{border:0;height:4px;border-radius:2px;background:var(--acc);opacity:.55}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-plot{overflow-x:auto;overflow-y:hidden;max-width:100%;padding:2px 0 var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg{display:block;font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-e{fill:none;stroke:var(--acc);stroke-opacity:.42}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-ah{fill:var(--acc);fill-opacity:.75}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-em{stroke:var(--ink-4);fill:var(--ink-4);stroke-dasharray:4 3;stroke-opacity:1}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-el{fill:var(--ink-2);font-size:11px;font-weight:600;paint-order:stroke;stroke:var(--panel);stroke-width:3px;stroke-linejoin:round}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-box{fill:var(--panel);stroke:var(--ink-3);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-r .bk-box{stroke:var(--ink);stroke-width:2}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-w .bk-box{fill:var(--acc-soft);stroke:var(--acc);stroke-width:1.4}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-m .bk-box{fill:none;stroke:var(--ink-4);stroke-dasharray:5 4}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-nsm .bk-box{stroke-dasharray:6 4}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-t{fill:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-t.b{fill:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bk-t.i{font-style:italic}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bkn{outline:none}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bkn.bk-go{cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bkn:hover .bk-box,#blocking .bk-svg .bkn:focus-visible .bk-box{stroke-width:2.6}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-svg .bkn:focus-visible .bk-box{stroke:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-rd{margin:var(--s2) 0 var(--s3);max-width:72em}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-who{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-off{color:var(--ink-3);font-size:11px}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-tbl{margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-tbl caption{text-align:left;font-weight:600;padding:4px 0}');
    DBMS_OUTPUT.PUT_LINE('#blocking tr.bk-skip td{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-fold{margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-fold>summary{cursor:pointer;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-fold>.bk-tbl{display:block;overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#blocking .bk-meth{font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('body.js-wg #blocking .bk-nojs{display:none}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
