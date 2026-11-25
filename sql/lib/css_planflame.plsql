--
-- sql/lib/css_planflame.plsql
--
-- The stylesheet of section 23_plan_flame (Plan shape, old vs new).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_planflame.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_planflame: styles of section 23_plan_flame (Plan shape, old vs new). */');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-intro{color:var(--ink-2);max-width:72em;margin:0 0 var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lg{display:flex;flex-wrap:wrap;gap:4px 16px;font-size:12px;color:var(--ink-3);margin:0 0 var(--s4)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lg[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lg span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lg .pf-lgh{flex-basis:100%;color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-sw{display:inline-block;width:12px;height:10px;border-radius:2px;flex:none}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-swn{background:var(--zone2);box-shadow:inset 0 0 0 1px var(--zone1)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-sws{width:3px;background:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame.pf-js .pf-nojs{display:none}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-st{border-top:1px solid var(--hairline);padding:var(--s4) 0 var(--s2);min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-h{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;margin:0 0 var(--s1);font-size:15px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-h .ent{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-tag{font-size:12px;font-weight:500;color:var(--ink-2);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-el{font-size:12px;font-weight:400;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-sqlt{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:11.5px;color:var(--ink-3);margin:0 0 var(--s3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr));gap:var(--s4) var(--s5)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-pair.one{grid-template-columns:minmax(0,1fr)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-side{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-hd{font-size:13px;color:var(--ink);margin:0 0 6px;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-hd small{display:block;font-size:11.5px;color:var(--ink-3);font-weight:400;margin-top:1px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-side[data-r="new"] .pf-hd b{color:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-plot{width:100%;min-height:24px;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-svg{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-few,#plan-flame .pf-nol{font-size:12px;color:var(--ink-3);margin:4px 0 0}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-rd{margin:var(--s3) 0 var(--s2);color:var(--ink-2);max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-g{cursor:pointer;outline:none}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-bg{fill:var(--zone2);stroke:var(--zone1);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-own{stroke:none}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-slr{fill:var(--ink-4);opacity:.55}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-cut{stroke:var(--ink-3);stroke-width:2;stroke-dasharray:3 2}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lb{font-size:11px;fill:var(--ink-2);pointer-events:none;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-lb.onc{fill:#fff;font-weight:600;paint-order:stroke;stroke:rgba(0,0,0,.28);stroke-width:2px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-g.pf-hov .pf-bg,#plan-flame .pf-g:focus .pf-bg{stroke:var(--ink);stroke-width:1.6}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-g.pf-s.pf-hov .pf-slr,#plan-flame .pf-g.pf-s:focus .pf-slr{opacity:1}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-g.pf-same .pf-bg{stroke:var(--acc);stroke-width:2}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-g:focus-visible .pf-bg{stroke:var(--acc);stroke-width:2.4}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-ax{stroke:var(--ink-3);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-axl{font-size:11px;fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-tbls{margin:var(--s2) 0 0}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-tbls summary{cursor:pointer;color:var(--ink-2);font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-tbls[open]{overflow-x:auto}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-tb{margin:var(--s3) 0;font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-tb caption{text-align:left;font-weight:600;color:var(--ink-2);padding:0 0 4px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-tb td{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-ind{display:inline-block;padding-left:calc(var(--d, 0) * 10px)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame tr.pf-z td{color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame tr.pf-mk td{font-style:italic}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip{position:fixed;z-index:100;pointer-events:none;background:var(--ink);color:var(--panel);font-size:12px;line-height:1.45;padding:6px 10px;border-radius:6px;max-width:340px;box-shadow:0 4px 14px rgba(0,0,0,.25);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip .tm{opacity:.72}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip .tr2{display:flex;align-items:center;gap:10px;justify-content:space-between}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip .tr2 span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip .tr2 b{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.planflame-tip .sw{display:inline-block;width:8px;height:8px;border-radius:2px;flex:none;background:var(--sw,#9AA3AD)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-tb td:last-child{white-space:normal;min-width:12em}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-obj{margin:var(--s4) 0 0;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-oh{font-size:13px;font-weight:600;color:var(--ink);margin:0 0 var(--s1)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-oh small{font-size:11.5px;font-weight:400;color:var(--ink-3);margin-left:6px}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-ord{margin:0 0 var(--s2);color:var(--ink-2);max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-oiv,#plan-flame .pf-oerr,#plan-flame .pf-ocap{font-size:12px;color:var(--ink-3);margin:0 0 var(--s2);max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-otw{overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob{font-size:12px;margin:0 0 var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob td{vertical-align:top}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob td:nth-child(n+4):nth-child(-n+7){white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob td.pf-on{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob .pf-ot{font-weight:600;color:var(--ink);background:var(--zone2);border-radius:3px;padding:0 3px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame table.pf-ob .pf-oa{color:var(--ink-3);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-om{display:inline-block;font-size:11px;line-height:16px;padding:0 6px;margin:0 4px 2px 0;border-radius:8px;border:1px solid var(--line);color:var(--ink-2);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-om.pf-oms{border-color:var(--ink-3);color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#plan-flame .pf-om.pf-omu{border-style:dashed;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
