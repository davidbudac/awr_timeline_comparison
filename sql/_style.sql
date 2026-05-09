--
-- _style.sql
-- Emits the <style> and tiny JS fragment shared by every section of the
-- HTML report.  Called once from awr_trend.sql after the <head> opens.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#1a1a1a; --bg:#ffffff; --panel:#ffffff; --panel-2:#f6f8fb;'
        || ' --muted:#666; --border:#e0e0e0; --border-strong:#c8d0dc;'
        || ' --crit:#ffe5e5; --crit-fg:#8a1c1c; --warn:#fff4d6; --warn-fg:#7a5a00;'
        || ' --ok:#eaf6ea; --ok-fg:#245c24; --info:#eef2ff; --info-fg:#2c3a8a;'
        || ' --accent:#2563eb; --accent-2:#14b8a6;'
        || ' --spark:#2563eb; --spark-fill:rgba(37,99,235,.14);'
        || ' --shadow:0 1px 3px rgba(0,0,0,.06), 0 4px 12px rgba(0,0,0,.04);'
        || ' --wc-sysio:#2563eb; --wc-other:#a855f7; --wc-userio:#14b8a6;'
        || ' --wc-commit:#f59e0b; --wc-config:#ef4444; --wc-concurrency:#ec4899;'
        || ' --wc-network:#6366f1; --wc-application:#84cc16;'
        || ' --wc-cluster:#f97316; --wc-admin:#64748b; --wc-sched:#0ea5e9;'
        || ' --wc-queue:#d946ef; }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: dark) {');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#e6e6e6; --bg:#0f1320; --panel:#161b2b; --panel-2:#1c2336;'
        || ' --muted:#9aa3af; --border:#2a2f3a; --border-strong:#3b4658;'
        || ' --crit:#3a1717; --crit-fg:#ffb4b4; --warn:#3a3115; --warn-fg:#ffdb8a;'
        || ' --ok:#172a1c; --ok-fg:#a8e5b4; --info:#1b2140; --info-fg:#b4c0ff;'
        || ' --accent:#7aa2ff; --accent-2:#5eead4;'
        || ' --spark:#7aa2ff; --spark-fill:rgba(122,162,255,.18);'
        || ' --shadow:none; } }');
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--bg); color:var(--fg);'
        || ' font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;'
        || ' font-size:14px; line-height:1.5; }');
    DBMS_OUTPUT.PUT_LINE('body { max-width:1400px; margin:0 auto; padding:24px; display:flex; flex-direction:column; gap:16px; }');
    DBMS_OUTPUT.PUT_LINE('section { background:var(--panel); border:1px solid var(--border); border-radius:12px; padding:18px 20px; box-shadow:var(--shadow); }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:22px; margin:0 0 4px 0; }');
    DBMS_OUTPUT.PUT_LINE('h2 { font-size:18px; margin:28px 0 12px 0; border-bottom:2px solid var(--border); padding-bottom:4px; }');
    DBMS_OUTPUT.PUT_LINE('h3 { font-size:15px; margin:16px 0 8px 0; color:var(--muted); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report { background:var(--info); color:var(--info-fg);'
        || ' padding:16px 20px; border-radius:8px; margin-bottom:20px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr));'
        || ' gap:6px 24px; margin-top:8px; font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta b { color:var(--fg); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc { position:sticky; top:0; background:var(--bg); padding:8px 0;'
        || ' border-bottom:1px solid var(--border); margin-bottom:8px; z-index:5; font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc { order:1; }');
    DBMS_OUTPUT.PUT_LINE('header.report { order:2; }');
    DBMS_OUTPUT.PUT_LINE('#db-time-summary { order:3; }');
    DBMS_OUTPUT.PUT_LINE('#overview { order:4; }');
    DBMS_OUTPUT.PUT_LINE('#ash-timeline { order:5; }');
    DBMS_OUTPUT.PUT_LINE('#findings { order:6; }');
    DBMS_OUTPUT.PUT_LINE('#windows { order:7; }');
    DBMS_OUTPUT.PUT_LINE('#load { order:8; }');
    DBMS_OUTPUT.PUT_LINE('#metrics { order:9; }');
    DBMS_OUTPUT.PUT_LINE('#waits-fg { order:10; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg { order:11; }');
    DBMS_OUTPUT.PUT_LINE('#topsql { order:12; }');
    DBMS_OUTPUT.PUT_LINE('footer.report { order:13; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a { color:var(--accent); text-decoration:none; margin-right:14px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('table { width:100%; border-collapse:collapse; margin:8px 0 16px 0; font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('thead th { background:var(--bg); position:sticky; top:38px; z-index:2;'
        || ' text-align:left; padding:8px 10px; border-bottom:2px solid var(--border); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('tbody td { padding:6px 10px; border-bottom:1px solid var(--border); vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:rgba(127,127,127,0.08); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('td a { color:var(--accent); text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('td a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('tr.crit   { background:var(--crit); }  tr.crit td:first-child { border-left:4px solid var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn   { background:var(--warn); }  tr.warn td:first-child { border-left:4px solid var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok     { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info   { background:var(--info); color:var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.skip   { color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('.badge { display:inline-block; padding:1px 8px; border-radius:10px; font-size:11px; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.badge.crit { background:var(--crit-fg); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.warn { background:var(--warn-fg); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.ok   { background:var(--ok-fg);   color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.info { background:var(--accent);  color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.skip { background:var(--muted);   color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.bar { display:block; height:4px; background:linear-gradient(90deg,var(--accent),var(--accent-2)); opacity:.55; border-radius:2px; margin-top:3px; }');
    --
    -- Sparkline SVGs (emitted per-row by PL/SQL)
    --
    DBMS_OUTPUT.PUT_LINE('svg.spark { display:inline-block; vertical-align:middle; width:110px; height:24px; color:var(--spark); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.warn { color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.crit { color:var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .fill { fill:var(--spark-fill); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .line { fill:none; stroke:currentColor; stroke-width:1.5; stroke-linecap:round; stroke-linejoin:round; }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .dot  { fill:currentColor; }');
    DBMS_OUTPUT.PUT_LINE('th.trend, td.trend { width:130px; padding-left:8px; padding-right:8px; text-align:center; }');
    --
    -- Cell-bar behind the current-week value (in load/sysmetric tables)
    --
    DBMS_OUTPUT.PUT_LINE('td.cell-bar { position:relative; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .bg { position:absolute; left:0; top:0; bottom:0; '
        || 'background:linear-gradient(90deg, rgba(37,99,235,.10), rgba(20,184,166,.06)); '
        || 'border-right:2px solid var(--accent); pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .v { position:relative; z-index:1; }');
    --
    -- ECharts chart containers
    --
    DBMS_OUTPUT.PUT_LINE('.chart-wrap { width:100%; }');
    DBMS_OUTPUT.PUT_LINE('.chart-big    { height:360px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-medium { height:260px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-small  { height:180px; }');
    -- ASH timeline: plot + top legend + bottom dataZoom slider need more room
    DBMS_OUTPUT.PUT_LINE('.chart-ash    { height:440px; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .chart-wrap, body.no-charts .hero-card .mini { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .cdn-warn { display:block !important; }');
    DBMS_OUTPUT.PUT_LINE('.cdn-warn { display:none; background:var(--warn); color:var(--warn-fg); '
        || 'padding:10px 14px; border-radius:8px; font-size:13px; margin:8px 0; }');
    --
    -- Overview hero strip
    --
    DBMS_OUTPUT.PUT_LINE('#overview .hero-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:12px; margin-top:6px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card { border:1px solid var(--border); border-radius:10px; padding:12px 14px; '
        || 'background:var(--panel-2); display:flex; flex-direction:column; gap:4px; position:relative; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .label { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .value { font-size:22px; font-weight:700; letter-spacing:-0.02em; font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .value small { font-size:12px; font-weight:500; color:var(--muted); margin-left:4px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .mini { width:100%; height:38px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .foot { display:flex; justify-content:space-between; align-items:center; gap:6px; font-size:11px; color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .deltas { display:flex; gap:3px; flex-wrap:wrap; min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta { font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta .dp { color:var(--muted); margin-right:3px; font-size:10px; font-weight:400; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.up   { color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.down { color:var(--ok-fg); }');
    --
    -- Windows timeline ribbon
    --
    DBMS_OUTPUT.PUT_LINE('.ribbon { width:100%; height:72px; margin:6px 0 14px 0; position:relative; }');
    DBMS_OUTPUT.PUT_LINE('.ribbon svg { width:100%; height:100%; display:block; }');
    DBMS_OUTPUT.PUT_LINE('details { margin:4px 0; }');
    DBMS_OUTPUT.PUT_LINE('details summary { cursor:pointer; padding:4px 0; font-weight:600; color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('pre.sql { background:rgba(127,127,127,.08); padding:10px; border-radius:6px;'
        || ' overflow-x:auto; white-space:pre-wrap; font-size:12px; font-family:ui-monospace,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('footer.report { color:var(--muted); font-size:12px; margin-top:40px;'
        || ' padding-top:12px; border-top:1px solid var(--border); }');
    DBMS_OUTPUT.PUT_LINE('@media print { nav.toc { display:none; } thead th { position:static; } body { max-width:none; } }');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
