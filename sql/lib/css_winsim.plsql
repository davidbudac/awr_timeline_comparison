--
-- sql/lib/css_winsim.plsql
--
-- The stylesheet of section 26_window_similarity (Window similarity).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_winsim.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_winsim: styles of section 26_window_similarity (Window similarity).');
    DBMS_OUTPUT.PUT_LINE('   Every selector starts with #win-sim or a winsim- class; colours from the');
    DBMS_OUTPUT.PUT_LINE('   report''s tokens only (the theme toggle and the designs restyle it). */');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-rd{margin:var(--s2) 0 var(--s3);max-width:72em;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-rd b{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-app[hidden],#win-sim .winsim-nojs[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-app{display:flex;flex-wrap:wrap;gap:var(--s5);align-items:flex-start;margin:var(--s3) 0 var(--s4)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-p1{flex:1 1 380px;min-width:0;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-p2{flex:1 1 360px;min-width:0;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-app h3{display:block;font-size:13px;margin:0 0 var(--s1)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-cap{font-size:12px;color:var(--ink-3);margin:2px 0 var(--s2);max-width:60em}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-plot{overflow-x:auto;overflow-y:hidden;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-mxb{position:relative}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-mxb .winsim-svg{position:relative;z-index:1}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-cv{position:absolute;z-index:0}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-svg{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-c{fill:var(--track)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-c.dg{fill:var(--line)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-c.sk{fill:transparent}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-c.dr{opacity:.35}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-curb{fill:none;stroke:var(--acc);stroke-width:1.5;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-oddb{fill:none;stroke:var(--warn-dot);stroke-width:1.5;stroke-dasharray:3 2;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-ax{font-size:10px;fill:var(--ink-3);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-ax.cur{fill:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-ax.odd{fill:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-ax.dr{text-decoration:line-through;opacity:.6}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-bars{margin-top:var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-bar{fill:var(--bar)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-bar.cur{fill:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-bar.odd{fill:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-bar.dr{opacity:.3}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-base{stroke:var(--ink-4);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-thr{stroke:var(--ink-3);stroke-width:1;stroke-dasharray:4 3}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-thrl{font-size:10px;fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-oddg{font-size:9px;fill:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-skx{font-size:10px;fill:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-probe{position:absolute;width:0;height:0;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-lg{display:flex;flex-wrap:wrap;gap:4px 14px;align-items:center;font-size:11px;color:var(--ink-3);margin:0 0 var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-lg span{display:inline-flex;align-items:center;gap:5px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-gr i{display:inline-block;width:84px;height:9px;border-radius:2px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-gr em{font-style:normal}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-sw{display:inline-block;width:11px;height:11px;border-radius:2px;background:var(--track)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-sw.cur{background:transparent;box-shadow:inset 0 0 0 1.5px var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-sw.odd{background:transparent;box-shadow:inset 0 0 0 1.5px var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-sw.sk{background:transparent;box-shadow:inset 0 0 0 1px var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chips{display:flex;flex-wrap:wrap;gap:6px;max-height:220px;overflow-y:auto;padding:2px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip{display:inline-flex;flex-direction:column;align-items:flex-start;gap:0;padding:4px 9px;border-radius:7px;border:1px solid var(--hairline);background:var(--panel);color:var(--ink);font:inherit;font-size:12px;line-height:1.25;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip small{font-size:10.5px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip[aria-pressed="true"]{background:var(--panel-2,var(--panel));border-color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip[aria-pressed="false"]{background:transparent;border-style:dashed;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip[aria-pressed="false"] b{text-decoration:line-through}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip.odd{border-color:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip.sk{opacity:.5;cursor:not-allowed}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip:hover:not(:disabled){border-color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-chip:focus-visible,#win-sim .winsim-btn:focus-visible{outline:2px solid var(--acc);outline-offset:1px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-act{display:flex;flex-wrap:wrap;gap:8px;margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-btn{font:inherit;font-size:12px;padding:5px 11px;border-radius:7px;border:1px solid var(--hairline);background:var(--panel);color:var(--ink);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-btn.winsim-sug{border-color:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-btn:disabled{opacity:.45;cursor:default}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-btn[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-sum{margin:var(--s2) 0;font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-tw{overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b i{width:8px;height:8px;border-radius:50%;background:var(--ink-4);flex:none}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-large i{background:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-moderate i{background:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-improved i{background:var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-typical i{background:transparent;box-shadow:inset 0 0 0 1.5px var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-skip i{background:transparent;box-shadow:inset 0 0 0 1px var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-b.b-noted i{background:transparent;box-shadow:inset 0 0 0 1.5px var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-odd{color:var(--ink);font-weight:600;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-tbl td:first-child,#win-sim .winsim-tbl td:nth-child(2),#win-sim .winsim-mt th{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#win-sim tr.winsim-fl td:first-child{box-shadow:inset 2px 0 0 var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-ct td:first-child{min-width:9em}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-mt td,#win-sim .winsim-mt th{font-size:11px;padding:2px 6px}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-full{margin:var(--s2) 0}');
    DBMS_OUTPUT.PUT_LINE('#win-sim tr.twin td{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.winsim-tip{position:fixed;z-index:100;pointer-events:none;background:var(--ink);color:var(--panel);font-size:12px;line-height:1.45;padding:6px 10px;border-radius:6px;max-width:320px;box-shadow:0 4px 14px rgba(0,0,0,.25);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('.winsim-tip[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.winsim-tip .tm{opacity:.72}');
    DBMS_OUTPUT.PUT_LINE('.winsim-tip .tr2{display:flex;align-items:center;gap:10px;justify-content:space-between}');
    DBMS_OUTPUT.PUT_LINE('#win-sim .winsim-tbl td:nth-child(5){min-width:18em}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
