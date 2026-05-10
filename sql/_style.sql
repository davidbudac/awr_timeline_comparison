--
-- _style.sql
-- Emits the <style> and tiny JS fragment shared by every section of the
-- HTML report.  Called once from awr_trend.sql after the <head> opens.
--
-- Visual style: "Dense" — power-user observability dashboard.
-- Dark-first with a prefers-color-scheme: light override, monospace
-- numerals, tight padding, KPI strip, heatmap-style findings.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');

    -- Dark-first palette (default)
    DBMS_OUTPUT.PUT_LINE(':root {'
        || ' --bg:#0c1018; --panel:#11161f; --panel-2:#161c27;'
        || ' --fg:#d8dde6; --fg-soft:#a4abba; --muted:#6b7384;'
        || ' --border:#1f2531; --border-strong:#2a3142; --line-soft:#181d27;'
        || ' --accent:#4cc9f0; --accent-2:#7df9c2;'
        || ' --crit:#ff6b6b;  --crit-fg:#ff6b6b;  --crit-bg:#2a1518;'
        || ' --warn:#ffb454;  --warn-fg:#ffb454;  --warn-bg:#2a2014;'
        || ' --ok:#7df9c2;    --ok-fg:#7df9c2;    --ok-bg:#14241e;'
        || ' --info:#82a9ff;  --info-fg:#82a9ff;  --info-bg:#161e30;'
        || ' --skip:#6b7384;'
        || ' --spark:#4cc9f0; --spark-fill:rgba(76,201,240,.15);'
        || ' --shadow:none;'
        -- OEM-13c-aligned wait_class palette (re-tuned for the dark canvas)
        || ' --wc-sysio:#4cc9f0;       --wc-other:#a78bfa;'
        || ' --wc-userio:#7df9c2;      --wc-commit:#ffb454;'
        || ' --wc-config:#ff6b6b;      --wc-concurrency:#f472b6;'
        || ' --wc-network:#82a9ff;     --wc-application:#bef264;'
        || ' --wc-cluster:#fb923c;     --wc-admin:#94a3b8;'
        || ' --wc-sched:#22d3ee;       --wc-queue:#e879f9;'
        || ' }');

    -- Light-mode override (when the user OS is in light mode)
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: light) {');
    DBMS_OUTPUT.PUT_LINE(':root {'
        || ' --bg:#f6f7f9; --panel:#ffffff; --panel-2:#f1f3f7;'
        || ' --fg:#1a1f2c; --fg-soft:#475068; --muted:#7d869b;'
        || ' --border:#d8dde6; --border-strong:#b9c1cf; --line-soft:#e8ebf0;'
        || ' --accent:#0066cc; --accent-2:#0e9f6e;'
        || ' --crit:#c0392b;  --crit-fg:#c0392b;  --crit-bg:#fbecea;'
        || ' --warn:#b07700;  --warn-fg:#b07700;  --warn-bg:#fdf3dd;'
        || ' --ok:#0e9f6e;    --ok-fg:#0e9f6e;    --ok-bg:#e6f6ee;'
        || ' --info:#2d5fd1;  --info-fg:#2d5fd1;  --info-bg:#e8eefb;'
        || ' --skip:#7d869b;'
        || ' --spark:#0066cc; --spark-fill:rgba(0,102,204,.10);'
        || ' --shadow:0 1px 2px rgba(15,23,42,.05);'
        || ' --wc-sysio:#0066cc;       --wc-other:#7c3aed;'
        || ' --wc-userio:#0e9f6e;      --wc-commit:#b07700;'
        || ' --wc-config:#c0392b;      --wc-concurrency:#db2777;'
        || ' --wc-network:#2d5fd1;     --wc-application:#65a30d;'
        || ' --wc-cluster:#ea580c;     --wc-admin:#64748b;'
        || ' --wc-sched:#0891b2;       --wc-queue:#c026d3;'
        || ' } }');

    -- Reset + body
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--bg); color:var(--fg); }');
    DBMS_OUTPUT.PUT_LINE('body {'
        || ' font-family:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",Roboto,system-ui,sans-serif;'
        || ' font-size:12.5px; line-height:1.45;'
        || ' -webkit-font-smoothing:antialiased;'
        || ' max-width:1480px; margin:0 auto; padding:0 16px 80px;'
        || ' display:flex; flex-direction:column; gap:0; }');

    -- Section ordering: topbar / sub-nav at top, then DB time, overview hero,
    -- findings, then the side-by-side FG-waits + Top-SQL row, then the deeper
    -- detail sections (load / metrics / BG waits / ASH / windows).
    DBMS_OUTPUT.PUT_LINE('.topbar { order:1; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc { order:2; }');
    DBMS_OUTPUT.PUT_LINE('#db-time-summary { order:3; }');
    DBMS_OUTPUT.PUT_LINE('#overview { order:4; }');
    DBMS_OUTPUT.PUT_LINE('#findings { order:5; }');
    DBMS_OUTPUT.PUT_LINE('.fg-topsql-row { order:6; display:grid;'
        || ' grid-template-columns:1fr 1fr; gap:14px; margin-top:18px; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:1100px) {'
        || ' .fg-topsql-row { grid-template-columns:1fr; gap:0; } }');
    DBMS_OUTPUT.PUT_LINE('.fg-topsql-row > section { margin-top:0; min-width:0; }');
    -- #waits-fg and #topsql live inside .fg-topsql-row, so they don't need
    -- their own body-level order; the wrapper carries it.
    DBMS_OUTPUT.PUT_LINE('#ash-timeline { order:7; }');
    DBMS_OUTPUT.PUT_LINE('#load { order:8; }');
    DBMS_OUTPUT.PUT_LINE('#metrics { order:9; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg { order:10; }');
    DBMS_OUTPUT.PUT_LINE('#windows { order:11; }');
    DBMS_OUTPUT.PUT_LINE('footer.report { order:13; }');

    -- Sticky top bar (brand + crumbs + right meta) per the dense mockup.
    DBMS_OUTPUT.PUT_LINE('.topbar {'
        || ' position:sticky; top:0; z-index:11;'
        || ' display:flex; align-items:center; gap:18px;'
        || ' padding:8px 16px;'
        || ' background:var(--panel); border-bottom:1px solid var(--border);'
        || ' margin:0 -16px;'
        || ' font-size:11.5px; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .brand {'
        || ' font-weight:700; letter-spacing:0.02em; font-size:12px;'
        || ' color:var(--fg); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .brand .dot {'
        || ' display:inline-block; width:6px; height:6px;'
        || ' background:var(--accent); border-radius:99px;'
        || ' margin-right:6px; vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .crumbs {'
        || ' color:var(--muted); font-size:11.5px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' min-width:0; flex:0 1 auto;'
        || ' white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .crumbs b {'
        || ' color:var(--fg-soft); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .crumbs .sep {'
        || ' color:var(--border-strong); margin:0 6px; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .right {'
        || ' margin-left:auto; display:flex; gap:14px;'
        || ' color:var(--muted); font-size:11.5px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.topbar .right b {'
        || ' color:var(--fg-soft); font-weight:600; }');

    -- Compact section nav under the topbar.
    DBMS_OUTPUT.PUT_LINE('nav.toc {'
        || ' background:transparent; border-bottom:1px solid var(--border);'
        || ' margin:0 -16px; padding:6px 16px;'
        || ' font-size:11px; display:flex; flex-wrap:wrap;'
        || ' align-items:center; gap:4px 12px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b {'
        || ' color:var(--muted); font-weight:600;'
        || ' letter-spacing:0.04em; text-transform:uppercase; font-size:10px;'
        || ' margin-right:4px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a {'
        || ' color:var(--fg-soft); text-decoration:none;'
        || ' padding:2px 7px; border-radius:3px;'
        || ' transition:background .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover {'
        || ' background:var(--panel-2); color:var(--accent); }');

    -- Sections (no card chrome - just spacing + a thin top rule via h2)
    DBMS_OUTPUT.PUT_LINE('section { background:transparent; border:0; padding:0; margin:18px 0 0; }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:20px; margin:0 0 4px; }');
    DBMS_OUTPUT.PUT_LINE('h2 {'
        || ' font-size:11.5px; letter-spacing:0.12em; text-transform:uppercase;'
        || ' font-weight:700; color:var(--fg-soft);'
        || ' margin:24px 0 8px; padding:0; border:0;'
        || ' display:flex; align-items:center; gap:10px; }');
    DBMS_OUTPUT.PUT_LINE('h2::after {'
        || ' content:""; flex:1; height:1px; background:var(--border); }');
    DBMS_OUTPUT.PUT_LINE('h3 {'
        || ' font-size:11px; letter-spacing:0.08em; text-transform:uppercase;'
        || ' color:var(--muted); font-weight:600; margin:14px 0 6px; }');

    -- Tables (compact, monospace numerics)
    DBMS_OUTPUT.PUT_LINE('table {'
        || ' width:100%; border-collapse:collapse; font-size:12px;'
        || ' background:var(--panel); border:1px solid var(--border); border-radius:4px;'
        || ' overflow:hidden; margin:6px 0 14px; }');
    DBMS_OUTPUT.PUT_LINE('thead th {'
        || ' background:var(--panel-2); color:var(--muted);'
        || ' text-align:left; padding:6px 10px;'
        || ' font-size:10.5px; font-weight:600; letter-spacing:0.06em;'
        || ' text-transform:uppercase; white-space:nowrap;'
        || ' border-bottom:1px solid var(--border); }');
    DBMS_OUTPUT.PUT_LINE('tbody td { padding:5px 10px; border-bottom:1px solid var(--line-soft);'
        || ' vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:last-child td { border-bottom:0; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num {'
        || ' text-align:right; font-variant-numeric:tabular-nums;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono {'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:11.5px; }');
    DBMS_OUTPUT.PUT_LINE('td a { color:var(--accent); text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('td a:hover { text-decoration:underline; }');

    -- Severity rows: subtle tinted background + colored left rule
    DBMS_OUTPUT.PUT_LINE('tr.crit { background:var(--crit-bg); }'
        || ' tr.crit td:first-child { box-shadow:inset 3px 0 0 var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn { background:var(--warn-bg); }'
        || ' tr.warn td:first-child { box-shadow:inset 3px 0 0 var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok   { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info { background:var(--info-bg); color:var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.skip { color:var(--muted); font-style:italic; }');

    -- Badges (used inline by sections)
    DBMS_OUTPUT.PUT_LINE('.badge {'
        || ' display:inline-block; padding:1px 7px; border-radius:3px;'
        || ' font-size:10px; font-weight:600; letter-spacing:0.04em;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' text-transform:uppercase; vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('.badge.crit {'
        || ' background:var(--crit-bg); color:var(--crit-fg); border:1px solid var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.warn {'
        || ' background:var(--warn-bg); color:var(--warn-fg); border:1px solid var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.ok {'
        || ' background:var(--ok-bg);   color:var(--ok-fg);   border:1px solid var(--ok-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.info {'
        || ' background:var(--info-bg); color:var(--info-fg); border:1px solid var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.skip {'
        || ' background:var(--panel-2); color:var(--muted);   border:1px solid var(--border); }');

    -- Soft accent bar (used by hero card foot deltas in some places)
    DBMS_OUTPUT.PUT_LINE('.bar {'
        || ' display:block; height:2px;'
        || ' background:linear-gradient(90deg,var(--accent),var(--accent-2));'
        || ' opacity:.65; border-radius:1px; margin-top:3px; }');

    --
    -- Sparkline SVGs (emitted per-row by the inline JS in awr_trend.sql)
    --
    DBMS_OUTPUT.PUT_LINE('svg.spark {'
        || ' display:inline-block; vertical-align:middle;'
        || ' width:96px; height:18px; color:var(--spark); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.warn { color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.crit { color:var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .fill { fill:var(--spark-fill); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .line {'
        || ' fill:none; stroke:currentColor; stroke-width:1.3;'
        || ' stroke-linecap:round; stroke-linejoin:round; }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .dot { fill:currentColor; }');
    DBMS_OUTPUT.PUT_LINE('th.trend, td.trend { width:110px; padding:4px 8px; text-align:center; }');

    --
    -- Cell-bar behind the current-value column in load/sysmetric tables
    --
    DBMS_OUTPUT.PUT_LINE('td.cell-bar { position:relative; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .bg {'
        || ' position:absolute; left:0; top:0; bottom:0;'
        || ' background:linear-gradient(90deg, rgba(76,201,240,.12), rgba(125,249,194,.06));'
        || ' border-right:1px solid var(--accent); pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: light) {'
        || ' td.cell-bar .bg {'
        || ' background:linear-gradient(90deg, rgba(0,102,204,.10), rgba(14,159,110,.05));'
        || ' border-right:1px solid var(--accent); } }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .v { position:relative; z-index:1; }');

    --
    -- Findings heatmap (section 07).  CSS-grid table with one row per
    -- finding and one column per (metric label, per-week value..., z).
    -- The grid-template-columns rule is set inline by the section so a
    -- single CSS block covers any weeks_back the caller chose.
    --
    DBMS_OUTPUT.PUT_LINE('.heatmap {'
        || ' display:grid; gap:2px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:11px; margin:6px 0 12px; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .h {'
        || ' color:var(--muted); padding:4px 6px;'
        || ' font-weight:600; letter-spacing:0.06em;'
        || ' text-transform:uppercase; font-size:10px; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .h.col { text-align:center; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .h.z-h { text-align:right; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .lab {'
        || ' padding:4px 6px; color:var(--fg-soft);'
        || ' white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .lab.skip { color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell {'
        || ' padding:4px 6px; text-align:center;'
        || ' color:var(--fg); background:var(--panel);'
        || ' border-radius:2px;'
        || ' font-variant-numeric:tabular-nums;'
        || ' overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell.crit { background:var(--crit-bg); color:var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell.warn { background:var(--warn-bg); color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell.ok   { background:var(--ok-bg);   color:var(--ok-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell.info { background:var(--info-bg); color:var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .cell.skip { background:var(--panel); color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .z {'
        || ' padding:4px 8px; text-align:right;'
        || ' font-weight:600; color:var(--fg-soft);'
        || ' font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .z.crit { color:var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .z.warn { color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.heatmap .z.skip { color:var(--muted); font-style:italic; font-weight:400; }');

    --
    -- ECharts chart containers
    --
    DBMS_OUTPUT.PUT_LINE('.chart-wrap {'
        || ' width:100%; background:var(--panel);'
        || ' border:1px solid var(--border); border-radius:4px;'
        || ' padding:6px; margin:4px 0 12px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-big    { height:340px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-medium { height:240px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-small  { height:160px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-ash    { height:420px; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .chart-wrap { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .cdn-warn { display:block !important; }');
    DBMS_OUTPUT.PUT_LINE('.cdn-warn {'
        || ' display:none; background:var(--warn-bg); color:var(--warn-fg);'
        || ' padding:8px 12px; border-radius:3px;'
        || ' border:1px solid var(--warn-fg); font-size:12px; margin:6px 0; }');

    --
    -- Overview KPI strip — value on top, mini-chart below, deltas at the foot
    --
    DBMS_OUTPUT.PUT_LINE('#overview .hero-grid {'
        || ' display:grid; grid-template-columns:repeat(6, minmax(0,1fr)); gap:1px;'
        || ' background:var(--border); border:1px solid var(--border);'
        || ' border-radius:4px; overflow:hidden; margin-top:6px; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 1100px) {'
        || ' #overview .hero-grid { grid-template-columns:repeat(3, minmax(0,1fr)); } }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 640px) {'
        || ' #overview .hero-grid { grid-template-columns:repeat(2, minmax(0,1fr)); } }');
    DBMS_OUTPUT.PUT_LINE('.hero-card {'
        || ' background:var(--panel); padding:10px 12px;'
        || ' display:flex; flex-direction:column; gap:2px;'
        || ' position:relative; min-width:0;'
        || ' border:0; border-radius:0; box-shadow:none; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-lab {'
        || ' font-size:10.5px; text-transform:uppercase; letter-spacing:0.08em;'
        || ' color:var(--muted); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-row {'
        || ' display:flex; justify-content:space-between; align-items:flex-end;'
        || ' gap:8px; min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-val {'
        || ' font-size:20px; font-weight:600; letter-spacing:-0.02em;'
        || ' font-variant-numeric:tabular-nums; color:var(--fg);'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' overflow:hidden; text-overflow:ellipsis; white-space:nowrap;'
        || ' min-width:0; flex:1 1 auto; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-val small {'
        || ' font-size:11px; font-weight:400; color:var(--muted);'
        || ' margin-left:3px; font-family:inherit; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-spark {'
        || ' width:78px; height:24px; flex:0 0 auto; line-height:0; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-spark svg { width:100%; height:100%; display:block; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-deltas {'
        || ' display:flex; gap:6px; flex-wrap:wrap; margin-top:3px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:10.5px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-d {'
        || ' font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-d .dp {'
        || ' color:var(--muted); margin-right:2px; font-size:9.5px; font-weight:400; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-d.up { color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-d.dn { color:var(--ok-fg); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-d.nc { color:var(--muted); }');

    --
    -- Windows timeline ribbon (kept compact to match the dense aesthetic)
    --
    DBMS_OUTPUT.PUT_LINE('.ribbon { width:100%; height:64px; margin:4px 0 12px; position:relative; }');
    DBMS_OUTPUT.PUT_LINE('.ribbon svg { width:100%; height:100%; display:block; }');

    --
    -- Disclosures + SQL listings
    --
    DBMS_OUTPUT.PUT_LINE('details { margin:4px 0; }');
    DBMS_OUTPUT.PUT_LINE('details summary {'
        || ' cursor:pointer; padding:3px 0; font-weight:600; color:var(--accent);'
        || ' font-size:11.5px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('pre.sql {'
        || ' background:var(--panel-2); padding:10px; border-radius:3px;'
        || ' border:1px solid var(--border); overflow-x:auto; white-space:pre-wrap;'
        || ' font-size:11.5px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' color:var(--fg-soft); }');

    DBMS_OUTPUT.PUT_LINE('footer.report {'
        || ' color:var(--muted); font-size:11px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' margin-top:32px; padding:10px 0; border-top:1px solid var(--border); }');

    DBMS_OUTPUT.PUT_LINE('@media print {'
        || ' nav.toc { display:none; }'
        || ' thead th { position:static; }'
        || ' body { max-width:none; }'
        || ' h2::after { display:none; } }');

    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
