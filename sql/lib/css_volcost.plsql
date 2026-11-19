--
-- sql/lib/css_volcost.plsql
--
-- The stylesheet of section 21_volume_cost (Volume vs unit cost).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_volcost.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_volcost: styles of section 21_volume_cost (Volume vs unit cost).');
    DBMS_OUTPUT.PUT_LINE('   Every selector starts with #volume-cost; colours are report tokens. */');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-q{margin:0 0 var(--s3);color:var(--ink-2);max-width:72ch}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost:not(.vc-on) .vc-js{display:none}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost.vc-on[data-mode="sql"] [data-vk="ev"],#volume-cost.vc-on[data-mode="ev"] [data-vk="sql"]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-bar{display:flex;flex-wrap:wrap;align-items:center;gap:var(--s2) var(--s4);margin:0 0 var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-lg{display:flex;flex-wrap:wrap;gap:var(--s1) var(--s3);font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-lg>span{display:inline-flex;align-items:center;gap:5px}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-k{display:inline-block;width:10px;height:10px;border-radius:50%;box-sizing:border-box}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-k.vc-u{background:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-k.vc-d{background:var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-k.vc-e{background:var(--ink-3);opacity:.6}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-k.vc-o{border:1.5px dashed var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-wrap{display:flex;align-items:flex-start;gap:var(--s4)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-main{flex:1 1 auto;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-yt,#volume-cost .vc-xt{font-size:12px;color:var(--muted);line-height:1.4}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-yt b,#volume-cost .vc-xt b{color:var(--ink-2);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-xt{text-align:right;margin-top:2px}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-plot{width:100%;min-height:40px;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-svg{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-grid,#volume-cost .vc-dgs,#volume-cost .vc-lb{pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-g{stroke:var(--line);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-ax{stroke:var(--ink-4);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-tk{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dg{stroke:var(--tick);stroke-width:1;stroke-dasharray:3 4}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dg.vc-d0{stroke:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dl{fill:var(--ink-3);font-size:10.5px}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot{fill-opacity:.72;stroke:var(--panel);stroke-width:1.5;cursor:pointer;outline:none}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot.vc-u{fill:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot.vc-d{fill:var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot.vc-e{fill:var(--ink-3);fill-opacity:.45}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot.vc-o{stroke:var(--ink-2);stroke-dasharray:2 2}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot:hover{fill-opacity:.95}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-dot:focus-visible{stroke:var(--acc);stroke-width:3;stroke-dasharray:none;fill-opacity:.95}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-lb{fill:var(--ink);font-size:11px;font-weight:600;paint-order:stroke;stroke:var(--panel);stroke-width:3px;stroke-linejoin:round}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-mn{font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;font-weight:500}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-none{color:var(--muted);margin:var(--s4) 0}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new{flex:0 0 210px;font-size:12px;color:var(--ink-2);border-left:1px solid var(--line);padding:0 0 0 var(--s3);margin-top:20px}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new h4{margin:0 0 var(--s2);font-size:12px;font-weight:600;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new ul{list-style:none;margin:0 0 var(--s2);padding:0}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new li{display:flex;justify-content:space-between;gap:var(--s2);padding:2px 0;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new p{margin:0;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-nv{color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-rd{margin:var(--s3) 0 var(--s2);max-width:90ch}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-drop{margin:0 0 var(--s3);font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost table.vc-t td.mono{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:760px){');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-wrap{flex-direction:column;gap:var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('#volume-cost .vc-new{flex:none;align-self:stretch;border-left:0;border-top:1px solid var(--line);padding:var(--s2) 0 0;margin-top:0}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
