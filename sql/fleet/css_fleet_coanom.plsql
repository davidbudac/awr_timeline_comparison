--
-- sql/fleet/css_fleet_coanom.plsql
--
-- GENERATED from sql/fleet/src/css_fleet_coanom.css by
-- sh sql/fleet/src/fleet_js2plsql.sh -- edit the .css, not this body.
--
-- Stylesheet of the fleet co-anomaly grid (#coanom); @@-included by
-- sql/fleet/00_fleet_chrome.sql right after the fleet CSS block, inside
-- <head>.  Tokens from sql/_style.sql only, so body.dark restyles it.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* Fleet co-anomaly grid (#coanom, emitted by run_awr_fleet.sh''s assembler,');
    DBMS_OUTPUT.PUT_LINE('   drawn by js_fleet_coanom).  Readable source of');
    DBMS_OUTPUT.PUT_LINE('   sql/fleet/css_fleet_coanom.plsql.  ASCII only, no tilde. */');
    DBMS_OUTPUT.PUT_LINE('.coanom { background:var(--panel); border:1px solid var(--hairline); border-radius:8px; padding:12px 16px 12px; margin:0 0 14px; min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.coanom h2 { font-size:13.5px; font-weight:650; line-height:1.35; margin:0; padding:0; border:0; color:var(--ink); display:block; letter-spacing:.01em; }');
    DBMS_OUTPUT.PUT_LINE('.coanom h2::before { content:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom h2 small { font-weight:400; color:var(--muted); font-size:11.5px; margin-left:8px; letter-spacing:0; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:560px) { .coanom h2 small { display:block; margin:2px 0 0; } }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-nojs { font-size:12px; color:var(--muted); margin:6px 0 0; }');
    DBMS_OUTPUT.PUT_LINE('.coanom.ca-js .ca-nojs { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sum { font-size:12.5px; color:var(--ink-soft); margin:6px 0 8px; line-height:1.45; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sum b { color:var(--ink); font-weight:650; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sum:empty { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-lg { display:flex; flex-wrap:wrap; align-items:center; gap:4px 14px; font-size:11px; color:var(--muted); margin:0 0 8px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-lg span { display:inline-flex; align-items:center; gap:5px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw { width:12px; height:10px; border-radius:2px; display:inline-block; border:1px solid var(--hairline); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.n { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.r { background:color-mix(in srgb, var(--crit) 30%, var(--panel)); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.f { background:color-mix(in srgb, var(--crit) 68%, var(--panel)); position:relative; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.x { background:var(--crit); position:relative; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.f::after, .coanom .ca-sw.x::after { content:""; position:absolute; left:50%; top:50%; width:3px; height:3px; margin:-1.5px 0 0 -1.5px; border-radius:50%; background:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.na { background:repeating-linear-gradient(45deg, var(--panel-2) 0 2px, var(--hairline) 2px 3px); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-sw.hl { background:var(--accent-bg); border-color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-body:empty { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-body { display:grid; grid-template-columns:minmax(0, max-content) minmax(0, 1fr) max-content; align-items:start; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-lab { display:flex; flex-direction:column; max-width:150px; min-width:56px; padding-right:6px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-cnt { display:flex; flex-direction:column; padding-left:6px; min-width:34px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-lh { position:relative; flex:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-lh span { position:absolute; right:0; font-size:10px; color:var(--muted); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-cnt .ca-lh span { right:auto; left:0; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl { all:unset; box-sizing:border-box; flex:none; text-align:right; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:var(--ink-soft); cursor:pointer; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; line-height:1; display:flex; align-items:center; justify-content:flex-end; border-radius:3px; padding:0 3px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl:hover { color:var(--accent); background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl:focus-visible { outline:2px solid var(--accent); outline-offset:-1px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl.nd { color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl i { font-style:normal; font-family:system-ui,sans-serif; font-size:9.5px; margin-left:4px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rl.dim, .coanom .ca-rc.dim { opacity:.35; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rc { flex:none; display:flex; align-items:center; font-variant-numeric:tabular-nums; color:var(--muted); line-height:1; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-rc.hit { color:var(--crit); font-weight:650; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-scroll { overflow-x:auto; overflow-y:hidden; min-width:0; padding-bottom:2px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-svg { display:block; outline:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-svg:focus-visible { outline:2px solid var(--accent); outline-offset:1px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-n { fill:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-r { fill:color-mix(in srgb, var(--crit) 30%, var(--panel)); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-f { fill:color-mix(in srgb, var(--crit) 68%, var(--panel)); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-x { fill:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-g { fill:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-hb { fill:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-hl2 { stroke:var(--hairline); stroke-width:1.5; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-row.dim { opacity:.22; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-colhl { fill:var(--accent-bg); stroke:var(--accent); stroke-opacity:.45; stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-colhl.on { stroke-opacity:1; stroke-width:1.5; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bar rect { fill:var(--muted); fill-opacity:.55; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bar.sh rect { fill:var(--accent); fill-opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bar.sh { cursor:pointer; outline:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bar.sh:focus-visible rect { stroke:var(--ink); stroke-width:1.5; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bn { font-size:9.5px; font-weight:650; fill:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-bar.sh .ca-bn { fill:var(--accent-deep); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-base { stroke:var(--hairline); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-day { stroke:var(--rule); stroke-width:1; stroke-dasharray:2 2; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-tk { stroke:var(--muted); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-ax { font-size:9.5px; fill:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-mk line { stroke:currentColor; stroke-width:1; stroke-dasharray:3 2; stroke-opacity:.85; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-mk path { fill:currentColor; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-mk text { font-size:9.5px; font-weight:650; fill:currentColor; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-cur { fill:none; stroke:var(--ink); stroke-width:2; pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-filt { display:flex; align-items:center; gap:10px; flex-wrap:wrap; font-size:12px; color:var(--ink-soft); background:var(--accent-bg); border:1px solid var(--accent); border-radius:6px; padding:5px 10px; margin:0 0 8px; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-filt[hidden] { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-clear { font:inherit; font-size:11.5px; font-weight:600; padding:2px 10px; border-radius:12px; border:1px solid var(--accent); background:var(--panel); color:var(--accent-deep); cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-meta { font-size:10.5px; color:var(--muted); margin:6px 0 0; line-height:1.4; }');
    DBMS_OUTPUT.PUT_LINE('.coanom .ca-meta:empty { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.ca-live { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.ca-tip { position:fixed; z-index:50; display:none; max-width:340px; pointer-events:none; background:var(--panel); color:var(--ink-soft); border:1px solid var(--hairline); border-radius:6px; box-shadow:0 6px 18px rgba(0,0,0,.18); padding:7px 9px; font-size:11.5px; line-height:1.45; }');
    DBMS_OUTPUT.PUT_LINE('.ca-tip b { color:var(--ink); font-weight:650; }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.ca-hit td:first-child { box-shadow:inset 3px 0 0 var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.ca-hit { background:var(--accent-bg); }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.ca-flash { animation:caflash 1.6s ease-out; }');
    DBMS_OUTPUT.PUT_LINE('@keyframes caflash { 0% { background:var(--accent-bg); } 100% { background:transparent; } }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-reduced-motion: reduce) { tr.dbrow.ca-flash { animation:none; } }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:560px) { .coanom { padding:10px 10px; } .coanom .ca-lab { max-width:92px; } }');
    DBMS_OUTPUT.PUT_LINE('.coanom:not(.ca-js) .ca-lg { display:none; }');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
