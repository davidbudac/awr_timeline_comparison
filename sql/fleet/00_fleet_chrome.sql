--
-- sql/fleet/00_fleet_chrome.sql
-- Shared page chrome for the fleet "ops console" report (fleet v0.2.0):
-- DOCTYPE/head/title, the single-sourced report CSS (@@sql/_style.sql --
-- nested @@ resolves at the OUTERMOST caller, i.e. awr_fleet_extract.sql's
-- directory, same as every other consumer of this file), a fleet-only CSS
-- block that layers the ops-console table + detail-panel styling on top of
-- the shared tokens, the </head><body> open, the early-theme bootstrap, the
-- CDN-free per-row sparkline renderer, and the fleet chart/interaction
-- renderer (ASH ribbons + timelines, row expansion, theme toggle, marker
-- positioning).
--
-- Spooled independently by EVERY database in the fleet run (cheap, and
-- race-free under parallel fan-out since each alias writes its own copy);
-- the bash assembler keeps only the first successful one and discards the
-- rest.  Deliberately ends INSIDE <body> with no closing tags -- the
-- assembler appends the masthead, the <table class="fleet"> open, every DB's
-- two-<tr> fragment (sorted by score), the table close, and the footer +
-- </body></html> directly after this file's content.
--
-- No ECharts anywhere in the fleet report (inline-SVG only), so unlike
-- awr_trend.sql's prologue there is no <script src="...echarts...">, no
-- body.no-charts fallback banner, and no AWR_DATA namespace to initialize.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN
    DBMS_OUTPUT.PUT_LINE('<!DOCTYPE html>');
    DBMS_OUTPUT.PUT_LINE('<html lang="en"><head><meta charset="utf-8">');
    DBMS_OUTPUT.PUT_LINE('<meta name="viewport" content="width=device-width, initial-scale=1">');
    DBMS_OUTPUT.PUT_LINE('<title>AWR Fleet Report</title>');
END;
/

@@sql/_style.sql

-- Fleet-only CSS: the ops-console masthead (emitted by the wrapper), the
-- dense <table class="fleet"> (summary dbrow + hidden detailrow per DB) and
-- the expanded detail panel (ASH timeline, headline metric mini-cards,
-- findings + Top-SQL detail tables, drill-down).  Every color is a CSS var
-- already declared by sql/_style.sql's :root / body.dark token set above, so
-- this block needs no dark-mode overrides of its own -- adapted from
-- design/fleet_mock_b_ops_console.html (which reuses the same token names).
SET DEFINE OFF
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    -- Layout constraint applied directly to body: this chrome file ends
    -- INSIDE <body> with no closing tags, so an unclosed wrapper element
    -- here would leave the assembled document with unbalanced markup.
    -- Overrides sql/_style.sql's rail-padded flex body (there is no nav rail
    -- in the fleet report) -- this rule wins because it is emitted after it.
    -- The console now spans the full viewport width (no max-width cap) so
    -- the widened ASH timelines get all the room a wide window can offer;
    -- narrow viewports fall back to the .console/table.fleet horizontal
    -- scroll declared below instead of crushing columns.
    DBMS_OUTPUT.PUT_LINE('body { margin:0;'
        || ' padding:20px 22px 60px; display:block; }');
    DBMS_OUTPUT.PUT_LINE('.tnum { font-variant-numeric:tabular-nums; font-feature-settings:"tnum" 1; }');

    -- ---------- masthead ----------
    DBMS_OUTPUT.PUT_LINE('.masthead { background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:8px; padding:16px 18px; margin-bottom:16px; }');
    DBMS_OUTPUT.PUT_LINE('.mh-top { display:flex; align-items:flex-start; gap:16px; flex-wrap:wrap; }');
    DBMS_OUTPUT.PUT_LINE('.mh-title { flex:1 1 auto; min-width:260px; }');
    DBMS_OUTPUT.PUT_LINE('.mh-title h1 { font-size:17px; margin:0 0 3px; letter-spacing:.01em; font-weight:650; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.mh-title .sub { color:var(--muted); font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('.mh-title .run { color:var(--ink-soft); font-size:12px; margin-top:5px; }');
    DBMS_OUTPUT.PUT_LINE('.mh-title .run b { font-weight:600; color:var(--ink); }');
    -- Reuse the shared .theme-icon-btn (declared but unused in sql/_style.sql,
    -- scoped there to nav.toc .rail-brand); here it lives in the masthead, so
    -- give it its own unscoped box + icon-visibility rules.
    DBMS_OUTPUT.PUT_LINE('.masthead .theme-icon-btn { flex:none; display:flex; align-items:center;'
        || ' justify-content:center; width:30px; height:30px; padding:0; border-radius:6px;'
        || ' border:1px solid var(--rule); background:var(--panel-2); color:var(--ink-soft);'
        || ' cursor:pointer; transition:color .12s,background .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('.masthead .theme-icon-btn:hover { border-color:var(--accent); color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('.masthead .theme-icon-btn .icon-sun { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.masthead .theme-icon-btn .icon-moon { display:block; }');
    DBMS_OUTPUT.PUT_LINE('body.dark .masthead .theme-icon-btn .icon-sun { display:block; }');
    DBMS_OUTPUT.PUT_LINE('body.dark .masthead .theme-icon-btn .icon-moon { display:none; }');

    DBMS_OUTPUT.PUT_LINE('.badges { display:flex; gap:8px; flex-wrap:wrap; margin-top:14px; }');
    DBMS_OUTPUT.PUT_LINE('.stat-badge { border:1px solid var(--hairline); border-radius:6px;'
        || ' padding:6px 11px 5px; background:var(--panel-2); min-width:70px; text-align:center; }');
    DBMS_OUTPUT.PUT_LINE('.stat-badge .n { font-size:18px; font-weight:650; line-height:1.1; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.stat-badge .l { font-size:10.5px; color:var(--muted); text-transform:uppercase;'
        || ' letter-spacing:.05em; margin-top:1px; }');
    DBMS_OUTPUT.PUT_LINE('.stat-badge.crit .n { color:var(--crit); } .stat-badge.warn .n { color:var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('.stat-badge.ok .n { color:var(--ok); } .stat-badge.dead .n { color:var(--muted); }');

    DBMS_OUTPUT.PUT_LINE('.legends { display:flex; gap:26px; flex-wrap:wrap; margin-top:16px;'
        || ' padding-top:13px; border-top:1px solid var(--line-soft); }');
    DBMS_OUTPUT.PUT_LINE('.legend-blk { min-width:200px; }');
    DBMS_OUTPUT.PUT_LINE('.legend-blk h3 { font-size:10.5px; text-transform:uppercase; letter-spacing:.06em;'
        || ' color:var(--muted); margin:0 0 7px; font-weight:600; }');
    -- Neutralize sql/_style.sql's h3::before accent tick / uppercase weight
    -- for the masthead legend headings.
    DBMS_OUTPUT.PUT_LINE('.legend-blk h3::before { content:none; }');
    DBMS_OUTPUT.PUT_LINE('.wc-legend { display:flex; flex-wrap:wrap; gap:4px 12px; }');
    DBMS_OUTPUT.PUT_LINE('.wc-item { display:flex; align-items:center; gap:5px; font-size:11px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('.wc-swatch { width:10px; height:10px; border-radius:2px; flex:none; }');
    DBMS_OUTPUT.PUT_LINE('.mk-legend { display:flex; flex-direction:column; gap:5px; }');
    DBMS_OUTPUT.PUT_LINE('.mk-item { display:flex; align-items:center; gap:7px; font-size:11.5px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('.mk-glyph { font-weight:700; font-size:13px; line-height:1; }');
    DBMS_OUTPUT.PUT_LINE('.mk-item time { color:var(--muted); font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.mk-empty { font-size:11.5px; color:var(--muted); }');

    -- ---------- console table ----------
    DBMS_OUTPUT.PUT_LINE('.console { background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:8px; overflow:hidden; overflow-x:auto; }');
    DBMS_OUTPUT.PUT_LINE('table.fleet { width:100%; min-width:880px; border-collapse:collapse; margin:0; font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('table.fleet thead th { font-size:10px; text-transform:uppercase; letter-spacing:.06em;'
        || ' color:var(--muted); font-weight:600; text-align:left; padding:9px 10px;'
        || ' background:var(--panel-2); border-bottom:1px solid var(--rule); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('table.fleet thead th.r { text-align:right; } table.fleet thead th.c { text-align:center; }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow { border-bottom:1px solid var(--line-soft); cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow:last-child { border-bottom:none; }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow:hover { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.open { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow td { padding:8px 10px; vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('.chev { width:14px; height:14px; color:var(--muted); transition:transform .15s; display:inline-block; }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.open .chev { transform:rotate(90deg); color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('.alias-cell { display:flex; align-items:center; gap:9px; }');
    DBMS_OUTPUT.PUT_LINE('.dot { width:9px; height:9px; border-radius:50%; flex:none; box-shadow:0 0 0 3px var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.dot.crit { background:var(--crit); } .dot.warn { background:var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('.dot.ok { background:var(--ok); } .dot.dead { background:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.alias { font-weight:600; font-size:13px; letter-spacing:.01em; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.alias .role { font-weight:400; color:var(--muted); font-size:10.5px; margin-left:1px; }');
    -- optional per-DB detailed-report chip (__FLEET_DETAIL_CHIP__, filled in
    -- by the assembler): a compact pill in the alias cell, linking to the
    -- generated single-DB report when detail was requested and succeeded, or
    -- a non-link failure/skip note otherwise.  Empty string (no detail
    -- requested) renders nothing.
    DBMS_OUTPUT.PUT_LINE('.dchip { font-size:9.5px; font-weight:650; padding:1px 7px; border-radius:8px;'
        || ' margin-left:6px; text-decoration:none; letter-spacing:.02em; white-space:nowrap;'
        || ' border:1px solid var(--accent); color:var(--accent); background:var(--accent-bg); }');
    DBMS_OUTPUT.PUT_LINE('a.dchip:hover { background:var(--accent); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.dchip.dfail { border-color:var(--crit); color:var(--crit); background:var(--crit-bg); cursor:help; }');
    DBMS_OUTPUT.PUT_LINE('.score { font-weight:650; font-size:15px; text-align:right; }');
    DBMS_OUTPUT.PUT_LINE('.score.s-crit { color:var(--crit); } .score.s-warn { color:var(--warn); } .score.s-ok { color:var(--ok); }');
    DBMS_OUTPUT.PUT_LINE('.score.s-dead { color:var(--muted); font-size:12px; font-weight:500; }');
    DBMS_OUTPUT.PUT_LINE('.cw { display:flex; gap:5px; }');
    DBMS_OUTPUT.PUT_LINE('.cw .pill { font-size:11px; font-weight:600; padding:1px 6px; border-radius:4px;'
        || ' font-variant-numeric:tabular-nums; border:1px solid transparent; }');
    DBMS_OUTPUT.PUT_LINE('.pill.c { color:var(--crit); background:var(--crit-bg); border-color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('.pill.w { color:var(--warn); background:var(--warn-bg); border-color:var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('.pill.z { color:var(--muted); background:var(--panel-2); border-color:var(--hairline); }');
    DBMS_OUTPUT.PUT_LINE('.aas { text-align:right; font-weight:600; font-variant-numeric:tabular-nums; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.aas .u { font-weight:400; color:var(--muted); font-size:10px; margin-left:2px; }');
    DBMS_OUTPUT.PUT_LINE('.finding { font-size:12px; color:var(--ink-soft); display:flex; align-items:center; gap:7px; min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.finding .txt { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.zbadge { font-size:10.5px; font-weight:650; padding:1px 5px; border-radius:4px; flex:none;'
        || ' font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.zbadge.c { color:var(--crit); background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('.zbadge.w { color:var(--warn); background:var(--warn-bg); }');
    DBMS_OUTPUT.PUT_LINE('.zbadge.o { color:var(--ok); background:var(--ok-bg); }');
    DBMS_OUTPUT.PUT_LINE('.spark-cell svg, .ribbon-cell svg { display:block; }');
    DBMS_OUTPUT.PUT_LINE('.spark-cell { text-align:center; }');
    DBMS_OUTPUT.PUT_LINE('.spark-cell svg.spark { width:84px; height:24px; }');
    DBMS_OUTPUT.PUT_LINE('.ribbon-cell { width:186px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-ribbon svg, .ash-timeline svg { display:block; }');
    DBMS_OUTPUT.PUT_LINE('.ash-ribbon { width:172px; height:30px; margin:0 auto; }');
    DBMS_OUTPUT.PUT_LINE('.ash-timeline { width:100%; }');

    -- ---------- detail panel ----------
    DBMS_OUTPUT.PUT_LINE('tr.detailrow td { padding:0; background:var(--panel-2); border-bottom:1px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('tr.detailrow.hidden { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.detail { padding:16px 18px 18px; }');
    DBMS_OUTPUT.PUT_LINE('.detail-grid { display:grid; grid-template-columns:1fr; gap:16px; }');
    DBMS_OUTPUT.PUT_LINE('@media(min-width:900px){ .detail-grid { grid-template-columns:minmax(0,1.35fr) minmax(0,1fr); } }');
    DBMS_OUTPUT.PUT_LINE('.panel-h { font-size:10.5px; text-transform:uppercase; letter-spacing:.06em;'
        || ' color:var(--muted); font-weight:600; margin:0 0 8px; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block { background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:6px; padding:12px 13px; }');
    DBMS_OUTPUT.PUT_LINE('.timeline-box svg { display:block; width:100%; height:auto; }');
    DBMS_OUTPUT.PUT_LINE('.tl-caption { font-size:11px; color:var(--muted); margin-top:6px; display:flex; gap:14px; flex-wrap:wrap; }');
    DBMS_OUTPUT.PUT_LINE('.tl-caption span { display:flex; align-items:center; gap:5px; }');

    -- metric mini cards
    DBMS_OUTPUT.PUT_LINE('.metrics { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; margin-top:12px; }');
    DBMS_OUTPUT.PUT_LINE('@media(max-width:560px){ .metrics { grid-template-columns:repeat(2,1fr); } }');
    DBMS_OUTPUT.PUT_LINE('.metric { border:1px solid var(--hairline); border-radius:5px; padding:7px 9px; background:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.metric .ml { font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em;'
        || ' white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }');
    DBMS_OUTPUT.PUT_LINE('.metric .mrow { display:flex; align-items:flex-end; justify-content:space-between; gap:6px; margin-top:3px; }');
    DBMS_OUTPUT.PUT_LINE('.metric .mv { font-size:15px; font-weight:650; font-variant-numeric:tabular-nums; line-height:1; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.metric .mv .mu { font-size:9.5px; color:var(--muted); font-weight:400; margin-left:1px; }');
    DBMS_OUTPUT.PUT_LINE('.metric .mspark { margin-top:5px; }');
    DBMS_OUTPUT.PUT_LINE('.metric .mspark svg.spark { width:100%; height:20px; }');
    DBMS_OUTPUT.PUT_LINE('.metric .mz { font-size:10px; font-weight:650; padding:1px 4px; border-radius:3px;'
        || ' font-variant-numeric:tabular-nums; align-self:flex-start; }');
    DBMS_OUTPUT.PUT_LINE('.mz.c { color:var(--crit); background:var(--crit-bg); } .mz.w { color:var(--warn); background:var(--warn-bg); }');
    DBMS_OUTPUT.PUT_LINE('.mz.o { color:var(--ok); background:var(--ok-bg); } .mz.n { color:var(--muted); background:var(--panel-2); }');

    -- detail tables (override sql/_style.sql generic table rules via table.dt specificity)
    DBMS_OUTPUT.PUT_LINE('table.dt { width:100%; border-collapse:collapse; font-size:11.5px; margin:2px 0 0; background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('table.dt th { text-align:left; font-size:9.5px; text-transform:uppercase; letter-spacing:.05em;'
        || ' color:var(--muted); font-weight:600; padding:4px 8px 4px 0; border-bottom:1px solid var(--hairline); background:transparent; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('table.dt th.num, table.dt th.r { text-align:right; }');
    DBMS_OUTPUT.PUT_LINE('table.dt td { padding:5px 8px 5px 0; border-bottom:1px solid var(--line-soft); vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('table.dt td.num, table.dt td.r { text-align:right; font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('table.dt tr:last-child td { border-bottom:none; }');
    DBMS_OUTPUT.PUT_LINE('table.dt tr:hover { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('table.dt .mono { color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('table.dt td.trend, table.dt th.trend { width:88px; padding-right:0; text-align:center; }');
    -- Findings/topsql h3 sub-labels inside a detail-block: strip the accent
    -- tick + big margins so they read as compact captions, not section heads.
    DBMS_OUTPUT.PUT_LINE('.detail-block h3 { font-size:11px; text-transform:none; letter-spacing:0; font-weight:700;'
        || ' color:var(--ink); margin:14px 0 6px; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block h3:first-child { margin-top:0; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block h3::before { content:none; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block details + h3 { margin-top:14px; padding-top:0; border-top:0; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block p { font-size:11.5px; color:var(--muted); margin:6px 0; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block .muted { color:var(--muted); font-size:11.5px; }');
    DBMS_OUTPUT.PUT_LINE('.detail-block .dt-note { margin:6px 0 8px; line-height:1.45; }');

    DBMS_OUTPUT.PUT_LINE('.drill { margin-top:12px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;'
        || ' font-size:11px; background:var(--ink); color:#e7ecf2; border-radius:5px; padding:8px 10px;'
        || ' overflow-x:auto; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('body.dark .drill { background:#0a0d12; }');
    DBMS_OUTPUT.PUT_LINE('.drill .cmt { color:#7f8b9c; }');
    -- optional per-DB detailed-report line (__FLEET_DETAIL_LINE__, filled in
    -- by the assembler) next to the drill-down command: empty (no detail
    -- requested), a link to the generated single-DB report, or a muted
    -- failed/skipped explanation.
    DBMS_OUTPUT.PUT_LINE('.detail-link { margin-top:8px; font-size:11.5px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('.detail-link a { color:var(--accent); font-weight:600; text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('.detail-link a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('.detail-link.muted { color:var(--muted); }');

    -- dead / error row
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.deadrow { background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('tr.dbrow.deadrow:hover { background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('tr.detailrow.dead td { background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('.err-conn { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11.5px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('.err-code { font-weight:650; color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('.logtail { margin-top:10px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;'
        || ' font-size:11px; background:var(--panel); border:1px solid var(--crit); border-radius:5px;'
        || ' padding:9px 11px; color:var(--ink-soft); white-space:pre-wrap; line-height:1.5; overflow-x:auto; }');

    DBMS_OUTPUT.PUT_LINE('.hint { color:var(--muted); font-size:11px; margin:10px 2px 0; }');
    DBMS_OUTPUT.PUT_LINE('footer.fleet-footer { text-align:center; font-size:12px; color:var(--muted); padding:24px 0 0; }');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
SET DEFINE '~'

BEGIN
    DBMS_OUTPUT.PUT_LINE('</head><body>');
END;
/

-- Early theme script: applies the saved/preferred theme (localStorage
-- "awr-theme", falling back to prefers-color-scheme) by toggling body.dark
-- before any content paints.  Shares the exact persisted preference key with
-- the single-DB report (sql/00_params.sql).  The in-page toggle button
-- (wired in js_fleet_charts.plsql below) writes the same key.
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>');
END;
/

-- CDN-free per-row sparkline renderer (shared with the single-DB report) --
-- scans every [data-spark] element on DOMContentLoaded.  Used for the row
-- DB-time micro-spark and the headline metric mini-cards.
@@sql/lib/js_sparkline.plsql

-- Fleet chart + interaction renderer: inline-SVG ASH ribbons/timelines from
-- window.FLEET_ASH, row expand/collapse, theme toggle, and marker
-- positioning from window.FLEET_MARKERS.  No ECharts.
@@sql/fleet/js_fleet_charts.plsql

-- Deliberately ends here, inside <body>, with no closing tags: the bash
-- assembler appends the masthead, the console <table> open, every DB's
-- fragment (sorted by score), the table close, and the footer +
-- </body></html> directly after this file's spooled content.
