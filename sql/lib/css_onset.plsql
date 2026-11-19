--
-- sql/lib/css_onset.plsql
--
-- The stylesheet of section 25_onset (Onset): the metric picker, legend,
-- the SVG chart's classes (o-*) and the table.  Every selector is scoped
-- to #onset; colours are the report's tokens (no theme listener needed).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_onset.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_onset: styles of section 25_onset (Onset).  Every selector is');
    DBMS_OUTPUT.PUT_LINE('   scoped to #onset; colours are the report''s tokens, so the theme toggle');
    DBMS_OUTPUT.PUT_LINE('   and the quiet / dashboard designs restyle it with no listener. */');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-viz[hidden] { display:none; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-pick { display:grid; grid-template-columns:repeat(auto-fill,minmax(168px,1fr)); gap:6px; margin:2px 0 8px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-b { display:flex; flex-direction:column; gap:3px; min-width:0; text-align:left; border:1px solid var(--line-2); background:var(--panel); border-radius:8px; padding:6px 9px; font:inherit; font-size:12px; line-height:1.3; color:var(--ink-2); cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-b:hover { border-color:var(--ink-3); color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-b[aria-selected="true"] { border-color:var(--acc); background:var(--acc-soft); color:var(--ink); box-shadow:inset 0 0 0 1px var(--acc); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-b:focus-visible { outline:2px solid var(--acc); outline-offset:2px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-bn { font-weight:600; overflow-wrap:anywhere; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-bs { display:flex; align-items:center; gap:5px; font-size:11.5px; color:var(--ink-3); font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-d { display:inline-block; width:8px; height:8px; border-radius:50%; flex:none; margin-right:4px; vertical-align:0; background:transparent; box-shadow:inset 0 0 0 1.5px var(--ink-4); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-d.crit { background:var(--crit-dot); box-shadow:none; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-d.warn { background:var(--warn-dot); box-shadow:none; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-d.ok { box-shadow:inset 0 0 0 1.5px var(--ink-3); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-lg { display:flex; flex-wrap:wrap; gap:3px 14px; font-size:11.5px; color:var(--ink-3); margin:0 2px 4px; align-items:center; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k { display:inline-block; width:16px; height:10px; margin-right:5px; vertical-align:-1px; border-radius:2px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-ln { height:0; border-top:2px solid var(--ink); border-radius:0; vertical-align:3px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-md { height:0; border-top:1.5px dashed var(--mean); border-radius:0; vertical-align:3px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-bd { background:var(--zone2); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-lv { width:0; height:0; border-left:4px solid transparent; border-right:4px solid transparent; border-bottom:7px solid var(--crit-dot); border-radius:0; background:none; vertical-align:0; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-cw { width:8px; background:var(--acc-soft); box-shadow:inset 0 0 0 1px var(--acc); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-pw { width:8px; background:var(--track); box-shadow:inset 0 0 0 1px var(--line-2); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-mk { width:0; height:12px; border-left:1.5px dashed var(--mk); border-radius:0; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-on { width:0; height:12px; border-left:2px solid var(--crit-dot); border-radius:0; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-cu { background:color-mix(in srgb,var(--crit-dot) 40%,transparent); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-k.k-cd { background:color-mix(in srgb,var(--imp) 40%,transparent); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-zoom { display:inline-flex; border:1px solid var(--line-2); border-radius:8px; overflow:hidden; margin:2px 0 4px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-zoom button { font:inherit; font-size:11.5px; color:var(--ink-3); background:none; border:0; padding:3px 10px; cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-zoom button[aria-pressed="true"] { background:var(--acc-soft); color:var(--ink); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-zoom button:disabled { opacity:.45; cursor:default; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-zoom button:focus-visible { outline:2px solid var(--acc); outline-offset:-2px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-plot { position:relative; overflow-x:auto; overflow-y:hidden; margin:2px 0 4px; min-height:40px; border-radius:6px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-plot:focus-visible { outline:2px solid var(--acc); outline-offset:2px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-plot svg { display:block; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-cap { font-size:12px; color:var(--muted); margin:2px 2px 6px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-rd { margin:6px 2px 10px; font-size:13px; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-rd b { font-weight:650; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-tbl td small { color:var(--ink-3); font-size:11px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-tbl td.num { white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-tbl td small { white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('#onset.onset-js .onset-tbl tbody tr { cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-note { font-size:12px; color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t { font-size:11px; fill:var(--ink-3); font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t.o-d { fill:var(--ink-2); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t.o-u { fill:var(--ink-3); font-size:10.5px; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-g { stroke:var(--line); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-ax { stroke:var(--tick); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-w { fill:var(--track); opacity:.75; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-w.sk { fill:none; stroke:var(--ink-4); stroke-dasharray:2 3; stroke-width:1; opacity:.8; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-w.cur { fill:var(--acc-soft); opacity:1; stroke:var(--acc); stroke-width:1; stroke-opacity:.55; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-w2 { fill:var(--track); opacity:.5; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-w2.cur { fill:var(--acc-band); opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-band { fill:var(--zone2); opacity:.9; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-md { fill:none; stroke:var(--mean); stroke-width:1.3; stroke-dasharray:5 4; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-ln { fill:none; stroke:var(--ink); stroke-width:1.6; stroke-linejoin:round; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-pt { fill:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-ex { fill:var(--warn-dot); opacity:.07; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-ex.open { fill:var(--crit-dot); opacity:.08; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-th { stroke:var(--ink-4); stroke-width:1; stroke-dasharray:3 3; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-cu { fill:var(--crit-dot); opacity:.45; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-cd { fill:var(--imp); opacity:.45; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-mkl { stroke:var(--mk); stroke-width:1.2; stroke-dasharray:4 3; opacity:.75; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-mkd { fill:var(--mk); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-fb { fill:var(--flagbg); stroke:var(--mkline); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t.o-ft { fill:var(--mk); font-size:10.5px; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-on { stroke:var(--crit-dot); stroke-width:2; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-on.closed { stroke:var(--warn-dot); stroke-dasharray:5 3; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-on.base { stroke:var(--crit-dot); stroke-width:1.2; stroke-dasharray:2 3; opacity:.7; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-st.up { fill:var(--crit-dot); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-st.dn { fill:var(--imp); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-ob { fill:var(--panel); opacity:.92; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t.o-ot { fill:var(--crit-dot); font-weight:650; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-t.o-ot.closed { fill:var(--ink-2); }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-cl { stroke:var(--ink-3); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('#onset .o-cd2 { fill:var(--panel); stroke:var(--ink); stroke-width:1.6; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:560px) { #onset .onset-pick { grid-template-columns:repeat(2,minmax(0,1fr)); } #onset .onset-lg { gap:2px 10px; } }');
    DBMS_OUTPUT.PUT_LINE('#onset .onset-tbl td:nth-child(2), #onset .onset-tbl td:nth-child(4) { white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
