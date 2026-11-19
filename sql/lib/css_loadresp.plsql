--
-- sql/lib/css_loadresp.plsql
--
-- The stylesheet of section 20_load_response (Load vs response time).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_loadresp.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_loadresp: styles of section 20 (Load vs response time).  Every');
    DBMS_OUTPUT.PUT_LINE('   selector starts with #load-response; colours are the report''s tokens,');
    DBMS_OUTPUT.PUT_LINE('   so the theme toggle and the quiet / dashboard designs restyle it. */');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-chart{display:none;margin:var(--s3) 0 var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#load-response.lr-js .lr-chart{display:block}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-ctl{display:flex;flex-wrap:wrap;gap:var(--s2) var(--s4);align-items:center;margin-bottom:var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg{display:inline-flex;align-items:center;flex-wrap:nowrap;max-width:100%;border:1px solid var(--hairline);border-radius:8px;padding:2px;background:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-sl{font-size:12px;color:var(--muted);padding:0 8px 0 6px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg button{border:0;background:none;padding:3px 10px;border-radius:6px;font:inherit;font-size:13px;line-height:20px;color:var(--ink-2);cursor:pointer;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg button:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg button[aria-pressed="true"]{background:var(--ink);color:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg button:disabled{opacity:.4;cursor:default}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-seg button:focus-visible{outline:2px solid var(--acc);outline-offset:1px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-lg{display:flex;flex-wrap:wrap;gap:4px var(--s4);font-size:12px;color:var(--ink-3);margin-bottom:var(--s1)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-lg span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k{display:inline-block;width:10px;height:10px;border-radius:50%;flex:none}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k.kc{background:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k.kp{border:1.6px solid var(--ink-2);background:var(--panel);box-sizing:border-box}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k.kb{width:6px;height:6px;background:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k.kn{width:16px;height:0;border-radius:0;border-top:2px dashed var(--mean)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-k.kd{width:14px;height:9px;border-radius:2px;background:var(--zone2)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-plot{width:100%;min-height:40px;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-svg{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-svg text{font-size:11px;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-tl{fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-at{fill:var(--ink-3);font-size:11.5px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-g{stroke:var(--line);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-ax{stroke:var(--zone1);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-band{fill:var(--zone2);opacity:.85}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-norm{fill:none;stroke:var(--mean);stroke-width:1.6;stroke-dasharray:6 4}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-b{fill:var(--ink-4);opacity:.55}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-b.c{fill:var(--acc);opacity:.6}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-b.out{opacity:.8}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-w{fill:var(--panel);stroke:var(--ink-2);stroke-width:1.6;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-w:hover,#load-response .lr-w:focus-visible,#load-response .lr-w.hl{stroke:var(--ink);stroke-width:2.4;outline:none}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-cur{fill:var(--acc);stroke:var(--panel);stroke-width:2;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-cur:focus-visible{stroke:var(--ink);outline:none}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-cl{stroke:var(--acc);stroke-width:1.5;stroke-dasharray:2 3}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-ce{fill:var(--panel);stroke:var(--acc);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-cll{fill:var(--ink);font-weight:600;font-size:12.5px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-cls{fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-rd{margin:var(--s2) 0 var(--s3);max-width:76ch}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-tbl caption,#load-response .lr-tbl2 caption{caption-side:top;text-align:left;font-size:12px;color:var(--ink-3);padding-bottom:4px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-z{color:var(--ink-3);font-size:12px;margin-left:4px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-sk,#load-response .lr-dt{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#load-response tr.lr-nrm td{color:var(--ink-3);border-top:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-all{margin-top:var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-all summary{cursor:pointer;color:var(--ink-2);font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-tw{max-width:100%;overflow-x:auto}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-tbl td:nth-child(2){white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#load-response .lr-tbl td,#load-response .lr-tbl2 td{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:560px){#load-response .lr-lg{font-size:11px}#load-response .lr-seg button{padding:3px 6px;font-size:12px}#load-response .lr-sl{padding:0 4px}}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
