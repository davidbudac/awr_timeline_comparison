--
-- _style.sql
-- Emits the <style> shared by every section of the HTML report.  Called
-- once from awr_trend.sql after the <head> opens.
--
-- Visual style: "Editorial" -- magazine-style report.
-- Light, warm off-white canvas; large red section numerals; bold
-- masthead; pill-shaped param chips; red-sidebar editorial cards.
-- Class names match those emitted by sections 01-10 verbatim, so the
-- restyle is purely a CSS swap (no section-file changes required).
--
-- Design tokens, section-level layout, table conventions, severity
-- semantics, and the per-section header numbering scheme are documented
-- in design.md at the project root -- read that before iterating.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');

    -- =========================================================
    -- Design tokens
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE(':root {'
        || ' --paper:#f6f4ef;       --panel:#ffffff;        --panel-2:#fbfaf6;'
        || ' --ink:#111111;         --ink-soft:#2b2b2b;     --muted:#6b6b6b;'
        || ' --rule:#1f1f1f;        --hairline:#e2dfd7;     --line-soft:#ece9e1;'
        || ' --red:#e2231a;         --red-deep:#b51a13;     --chip-bg:#ebe8e0;'
        || ' --track:#e6e2d8;'
        || ' --crit:#c0231b;        --warn:#d28a00;         --ok:#2f7d3a;'
        || ' --info:#4a6f8a;        --skip:#8a8a8a;'
        || ' --crit-bg:#fbeae8;     --warn-bg:#fdf2dd;      --ok-bg:#e6f3e9;'
        || ' --info-bg:#e8eef4;     --skip-bg:#ececec;'
        || ' --spark:#111111;       --spark-fill:rgba(17,17,17,.06);'
        -- Wait-class palette: kept in approximate parity with
        -- js_wait_colors.plsql so on-page swatches read the same as the
        -- ECharts series. Tints are slightly muted for the warm canvas.
        || ' --wc-sysio:#1F4E89;       --wc-other:#C77CB0;'
        || ' --wc-userio:#4A90D9;      --wc-commit:#E89B40;'
        || ' --wc-config:#793C32;      --wc-concurrency:#8B0000;'
        || ' --wc-network:#967259;     --wc-application:#D62728;'
        || ' --wc-cluster:#E5C228;     --wc-admin:#7B6FA8;'
        || ' --wc-sched:#88C070;       --wc-queue:#E89BB7;'
        || ' --wc-cpu:#3FB344;'
        || ' }');

    -- =========================================================
    -- Reset + body
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--paper); color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('body {'
        || ' font-family:"Inter","Helvetica Neue",Helvetica,Arial,system-ui,sans-serif;'
        || ' font-size:15px; line-height:1.55;'
        || ' -webkit-font-smoothing:antialiased;'
        || ' max-width:1180px; margin:0 auto; padding:0 56px 96px;'
        || ' display:flex; flex-direction:column; gap:0; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 880px) {'
        || ' body { padding:0 22px 64px; font-size:14px; } }');

    -- =========================================================
    -- Visual section ordering (kept identical to the dense design,
    -- so the editorial numerals 01..10 below match the rendered order).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report      { order:1; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc            { order:2; }');
    DBMS_OUTPUT.PUT_LINE('#db-time-summary   { order:3; }');
    DBMS_OUTPUT.PUT_LINE('#overview          { order:4; }');
    DBMS_OUTPUT.PUT_LINE('#ash-timeline      { order:5; }');
    DBMS_OUTPUT.PUT_LINE('#waits-fg          { order:6; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg          { order:7; }');
    DBMS_OUTPUT.PUT_LINE('#topsql            { order:8; }');
    DBMS_OUTPUT.PUT_LINE('#findings          { order:9; }');
    DBMS_OUTPUT.PUT_LINE('#windows           { order:10; }');
    DBMS_OUTPUT.PUT_LINE('#load              { order:11; }');
    DBMS_OUTPUT.PUT_LINE('#metrics           { order:12; }');
    DBMS_OUTPUT.PUT_LINE('#topsql-ash        { order:13; }');
    DBMS_OUTPUT.PUT_LINE('footer.report      { order:14; }');

    -- =========================================================
    -- Masthead (header.report)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report {'
        || ' background:transparent; color:var(--ink);'
        || ' padding:56px 0 22px; margin:0;'
        || ' border-bottom:2px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline {'
        || ' font-weight:800; letter-spacing:0.02em; font-size:13px;'
        || ' text-transform:uppercase; color:var(--ink); margin:0 0 12px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline .dot { color:var(--red); margin-right:6px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline .slash { color:var(--red); font-weight:800; }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 {'
        || ' font-family:"Soehne","Inter","Helvetica Neue",Helvetica,Arial,sans-serif;'
        || ' font-weight:800; font-size:48px; line-height:1.04;'
        || ' letter-spacing:-0.02em; margin:0; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 em {'
        || ' font-style:normal; color:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 .badge { display:none; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 880px) {'
        || ' header.report { padding:32px 0 18px; }'
        || ' header.report h1 { font-size:32px; } }');

    -- Masthead .topgrid: headline left, run metadata right
    DBMS_OUTPUT.PUT_LINE('header.report .topgrid {'
        || ' display:flex; justify-content:space-between; align-items:flex-end;'
        || ' gap:24px; flex-wrap:wrap; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta {'
        || ' text-align:right; font-size:13px; color:var(--muted);'
        || ' line-height:1.7; min-width:240px;'
        || ' display:block; margin-top:0; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta div {'
        || ' color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta b {'
        || ' color:var(--ink); font-weight:600; margin-right:4px; }');

    -- Header windows-strip: narrow full-width DB-time timeline that
    -- replaces the old <ul> windows-list. .strip-head holds a single
    -- caption line; .windows-chart is the ECharts target (very short);
    -- .windows-fallback is shown only when body.no-charts hides the
    -- chart (offline / CDN-less) and lists windows as plain text.
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip {'
        || ' margin-top:18px; font-size:13px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .strip-head {'
        || ' display:flex; align-items:baseline; gap:10px;'
        || ' flex-wrap:wrap; margin-bottom:4px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .strip-head b {'
        || ' color:var(--muted); font-weight:700;'
        || ' letter-spacing:0.08em; font-size:11px;'
        || ' text-transform:uppercase; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .strip-meta {'
        || ' color:var(--muted); font-size:11px;'
        || ' letter-spacing:0.02em; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .windows-chart {'
        || ' width:100%; height:64px; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts header.report .windows-strip .windows-chart {'
        || ' display:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .windows-fallback {'
        || ' display:none; font-size:12px; color:var(--ink-soft);'
        || ' flex-wrap:wrap; gap:4px 14px; margin-top:2px; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts header.report .windows-strip .windows-fallback {'
        || ' display:flex; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .windows-fallback .win b {'
        || ' color:var(--ink); font-weight:700; margin-right:4px; }');

    -- =========================================================
    -- Masthead verdict: prominent severity-tinted banner emitted by
    -- 00_params.sql from a recomputed z-score. The container carries a
    -- v-ok / v-crit / v-skip class so the whole callout is tinted by
    -- severity (not just the lede text), making the headline judgement
    -- impossible to miss above the windows strip.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report .verdict {'
        || ' margin-top:18px; padding:14px 18px;'
        || ' border:1px solid var(--hairline); border-left:5px solid var(--muted);'
        || ' border-radius:10px;'
        || ' background:var(--panel-2);'
        || ' font-size:14px; color:var(--ink-soft); line-height:1.5;'
        || ' display:flex; flex-wrap:wrap; align-items:center;'
        || ' column-gap:12px; row-gap:8px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict.v-crit {'
        || ' border-left-color:var(--crit);'
        || ' background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict.v-ok {'
        || ' border-left-color:var(--ok);'
        || ' background:var(--ok-bg); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict.v-skip {'
        || ' border-left-color:var(--muted);'
        || ' background:var(--skip-bg); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .label {'
        || ' font-size:11px; letter-spacing:0.12em; text-transform:uppercase;'
        || ' color:var(--muted); font-weight:700; align-self:center; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede {'
        || ' color:var(--ink); font-weight:800;'
        || ' font-size:22px; letter-spacing:-0.01em; line-height:1.15;'
        || ' text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict a.lede:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.crit { color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.ok   { color:var(--ok); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.skip { color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .sep {'
        || ' color:var(--red); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body { color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body a {'
        || ' color:var(--red); text-decoration:none; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover {'
        || ' display:inline-flex; align-items:baseline; gap:6px;'
        || ' white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover::before {'
        || ' content:"\2022"; color:var(--red); font-weight:700;'
        || ' margin-right:2px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .name {'
        || ' color:var(--ink); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct {'
        || ' font-variant-numeric:tabular-nums; font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.up   { color:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.down { color:var(--ok); }');

    -- =========================================================
    -- Table-of-contents nav
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('nav.toc {'
        || ' position:sticky; top:0; z-index:10;'
        || ' background:var(--paper);'
        || ' border-top:1px solid var(--hairline);'
        || ' border-bottom:1px solid var(--hairline);'
        || ' margin:18px 0 28px; padding:12px 0;'
        || ' font-size:12px; letter-spacing:0.04em; text-transform:uppercase;'
        || ' color:var(--muted);'
        || ' display:flex; flex-wrap:wrap; gap:14px 22px; align-items:center; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b {'
        || ' color:var(--muted); font-weight:700;'
        || ' letter-spacing:0.10em; font-size:11px;'
        || ' margin-right:4px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b::before { content:none; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a {'
        || ' color:var(--ink); text-decoration:none; font-weight:600;'
        || ' transition:color .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { color:var(--red); }');

    -- =========================================================
    -- Sections + numbered headings (editorial)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('section {'
        || ' background:transparent; border:0; padding:0;'
        || ' margin:48px 0 0; scroll-margin-top:80px; }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:48px; margin:0; }');

    -- The section <h2> rendered as a numbered editorial heading.
    -- The big red numeral is injected as a ::before pseudo-element;
    -- per-section content is set further down via #id h2::before.
    DBMS_OUTPUT.PUT_LINE('h2 {'
        || ' font-family:"Soehne","Inter","Helvetica Neue",Helvetica,Arial,sans-serif;'
        || ' font-weight:800; font-size:26px; line-height:1.15;'
        || ' letter-spacing:-0.01em; color:var(--ink);'
        || ' text-transform:none;'
        || ' margin:0 0 14px; padding:0; border:0;'
        || ' display:flex; align-items:baseline; gap:18px; }');
    DBMS_OUTPUT.PUT_LINE('h2::before {'
        || ' content:""; color:var(--red); font-weight:800; font-size:38px;'
        || ' line-height:1; letter-spacing:-0.02em; min-width:56px;'
        || ' display:inline-block; }');
    DBMS_OUTPUT.PUT_LINE('h2::after { content:none; }');

    -- Per-section numerals (visual order matches the `order:` set above).
    DBMS_OUTPUT.PUT_LINE('#db-time-summary h2::before { content:"01"; }');
    DBMS_OUTPUT.PUT_LINE('#overview        h2::before { content:"02"; }');
    DBMS_OUTPUT.PUT_LINE('#ash-timeline    h2::before { content:"03"; }');
    DBMS_OUTPUT.PUT_LINE('#waits-fg        h2::before { content:"04"; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg        h2::before { content:"05"; }');
    DBMS_OUTPUT.PUT_LINE('#topsql          h2::before { content:"06"; }');
    DBMS_OUTPUT.PUT_LINE('#findings        h2::before { content:"07"; }');
    DBMS_OUTPUT.PUT_LINE('#windows         h2::before { content:"08"; }');
    DBMS_OUTPUT.PUT_LINE('#load            h2::before { content:"09"; }');
    DBMS_OUTPUT.PUT_LINE('#metrics         h2::before { content:"10"; }');
    DBMS_OUTPUT.PUT_LINE('#topsql-ash      h2::before { content:"11"; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 880px) {'
        || ' h2 { font-size:22px; gap:12px; }'
        || ' h2::before { font-size:30px; min-width:42px; } }');

    -- h3: subsection (used inside Top SQL etc.)
    DBMS_OUTPUT.PUT_LINE('h3 {'
        || ' font-size:11px; letter-spacing:0.10em; text-transform:uppercase;'
        || ' color:var(--muted); font-weight:700; margin:22px 0 8px; }');

    -- =========================================================
    -- Tables (clean magazine-style, hairline rules)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('table {'
        || ' width:100%; border-collapse:collapse;'
        || ' font-size:13px; background:transparent;'
        || ' border:0; border-radius:0;'
        || ' margin:14px 0 18px; }');
    DBMS_OUTPUT.PUT_LINE('thead th {'
        || ' background:transparent; color:var(--muted);'
        || ' text-align:left; padding:10px 10px 8px;'
        || ' font-size:11px; font-weight:700; letter-spacing:0.10em;'
        || ' text-transform:uppercase; white-space:nowrap;'
        || ' border-bottom:1.5px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('tbody td {'
        || ' padding:9px 10px; border-bottom:1px solid var(--hairline);'
        || ' vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:last-child td { border-bottom:0; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:rgba(0,0,0,0.02); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num {'
        || ' text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    -- text-transform:none is critical: sql_ids are case-sensitive base32
    -- hashes ("gnj0gxw60apzr" != "GNJ0GXW60APZR"), and at least one parent
    -- selector (details summary) applies text-transform:uppercase which
    -- would otherwise cascade in and break copy-paste back into AWR
    -- queries.  Pinning it here protects every <code>/.mono usage
    -- regardless of which container it ends up in.
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono {'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:12px; text-transform:none; }');
    DBMS_OUTPUT.PUT_LINE('td a { color:var(--red); text-decoration:none; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('td a:hover { text-decoration:underline; }');

    -- Severity rows: subtle tinted background + colored left rule
    DBMS_OUTPUT.PUT_LINE('tr.crit { background:var(--crit-bg); }'
        || ' tr.crit td:first-child { box-shadow:inset 3px 0 0 var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn { background:var(--warn-bg); }'
        || ' tr.warn td:first-child { box-shadow:inset 3px 0 0 var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok   { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info { background:var(--info-bg); }');
    DBMS_OUTPUT.PUT_LINE('tr.skip { color:var(--muted); font-style:italic; }');

    -- =========================================================
    -- Badges
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.badge {'
        || ' display:inline-block; padding:2px 8px; border-radius:999px;'
        || ' font-size:10.5px; font-weight:700; letter-spacing:0.04em;'
        || ' text-transform:uppercase; vertical-align:middle;'
        || ' border:0; }');
    DBMS_OUTPUT.PUT_LINE('.badge.crit { background:var(--crit); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.warn { background:var(--warn); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.ok   { background:var(--ok);   color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.info { background:var(--info); color:#fff; }');
    DBMS_OUTPUT.PUT_LINE('.badge.skip { background:var(--skip); color:#fff; }');

    -- Soft accent bar (legacy hook used by hero card foot deltas)
    DBMS_OUTPUT.PUT_LINE('.bar {'
        || ' display:block; height:2px; background:var(--red);'
        || ' opacity:.55; border-radius:1px; margin-top:3px; }');

    -- =========================================================
    -- Per-SQL metadata strip (key/value grid under each <summary>)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('dl.sql-meta {'
        || ' display:grid; grid-template-columns:max-content 1fr;'
        || ' gap:2px 14px; font-size:12px; margin:8px 0 14px; }');
    DBMS_OUTPUT.PUT_LINE('dl.sql-meta dt {'
        || ' color:var(--muted); font-weight:600;'
        || ' text-transform:uppercase; letter-spacing:0.03em;'
        || ' font-size:11px; }');
    DBMS_OUTPUT.PUT_LINE('dl.sql-meta dd { margin:0; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('dl.sql-meta dd.mono {'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:11.5px; }');
    DBMS_OUTPUT.PUT_LINE('dl.sql-meta dd .muted { color:var(--muted); }');

    -- =========================================================
    -- Top-SQL chart breakdown toggle (SQL_ID / Schema)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle {'
        || ' display:flex; align-items:center; gap:6px;'
        || ' margin:4px 0 6px; font-size:11px; color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button {'
        || ' font:inherit; font-size:11px; font-weight:600;'
        || ' padding:2px 10px; border-radius:999px; cursor:pointer;'
        || ' border:1px solid var(--border); background:transparent;'
        || ' color:var(--muted); letter-spacing:0.02em; }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button:hover { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button.active {'
        || ' background:var(--ink); color:#fff;'
        || ' border-color:var(--ink); }');

    -- =========================================================
    -- Sparkline SVGs (per-row, emitted by js_sparkline.plsql)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('svg.spark {'
        || ' display:inline-block; vertical-align:middle;'
        || ' width:96px; height:18px; color:var(--spark); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.warn { color:var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark.crit { color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .fill { fill:var(--spark-fill); }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .line {'
        || ' fill:none; stroke:currentColor; stroke-width:1.4;'
        || ' stroke-linecap:round; stroke-linejoin:round; }');
    DBMS_OUTPUT.PUT_LINE('svg.spark .dot { fill:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('th.trend, td.trend { width:110px; padding:6px 8px; text-align:center; }');

    -- =========================================================
    -- Cell-bar behind the current-value column in load/sysmetric tables
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('td.cell-bar { position:relative; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .bg {'
        || ' position:absolute; left:0; top:0; bottom:0;'
        || ' background:rgba(226,35,26,0.10);'
        || ' border-right:2px solid var(--red); pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .v {'
        || ' position:relative; z-index:1; font-weight:600; }');

    -- =========================================================
    -- ECharts containers
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.chart-wrap {'
        || ' width:100%; background:var(--panel);'
        || ' border:1px solid var(--hairline); border-radius:0;'
        || ' padding:8px; margin:14px 0 6px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-big    { height:340px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-medium { height:240px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-small  { height:160px; }');
    DBMS_OUTPUT.PUT_LINE('.chart-ash    { height:420px; }');
    -- Per-SQL ASH cards (#topsql-ash): a compact card per Top-N SQL with
    -- header (sql_id, sample count, dominant event), text snippet, and a
    -- smaller stacked-area chart. Many cards stack vertically.
    DBMS_OUTPUT.PUT_LINE('.chart-ash-sql { height:220px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-card {'
        || ' border:1px solid var(--hairline); border-radius:0;'
        || ' padding:12px 14px; margin:14px 0; background:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-card.insufficient {'
        || ' opacity:0.65; background:transparent;'
        || ' padding:8px 12px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-head {'
        || ' display:flex; flex-wrap:wrap; gap:10px; align-items:baseline;'
        || ' font-size:13px; color:var(--ink); margin-bottom:6px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-head code {'
        || ' font-family:"SFMono-Regular",Menlo,Consolas,monospace;'
        || ' font-size:13px; color:var(--ink); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-meta {'
        || ' color:var(--muted); font-size:12px; font-weight:400; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-snippet {'
        || ' font-family:"SFMono-Regular",Menlo,Consolas,monospace;'
        || ' font-size:11px; color:var(--muted);'
        || ' white-space:pre-wrap; word-break:break-word;'
        || ' margin:4px 0 8px; padding:0; background:transparent;'
        || ' max-height:48px; overflow:hidden;'
        || ' text-overflow:ellipsis; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .chart-wrap, body.no-charts .hero-card .mini { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .cdn-warn { display:block !important; }');
    DBMS_OUTPUT.PUT_LINE('.cdn-warn {'
        || ' display:none;'
        || ' background:var(--warn-bg); color:#7c5b00;'
        || ' padding:8px 12px; border:1px solid #f0d77a; border-radius:0;'
        || ' font-size:13px; margin:6px 0; }');

    -- =========================================================
    -- Overview KPI strip (#overview .hero-grid)
    -- Editorial card grid: white panels with red sidebar stripes,
    -- value on top, mini chart, then deltas at the foot.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('#overview .hero-grid {'
        || ' display:grid; grid-template-columns:repeat(3, minmax(0,1fr)); gap:14px;'
        || ' background:transparent; border:0; border-radius:0;'
        || ' margin-top:14px; padding:0; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 900px) {'
        || ' #overview .hero-grid { grid-template-columns:repeat(2, minmax(0,1fr)); } }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 520px) {'
        || ' #overview .hero-grid { grid-template-columns:1fr; } }');
    DBMS_OUTPUT.PUT_LINE('.hero-card {'
        || ' background:var(--panel);'
        || ' border:1px solid var(--hairline);'
        || ' padding:14px 16px;'
        || ' display:flex; flex-direction:column; gap:6px;'
        || ' position:relative; min-width:0;'
        || ' border-radius:0; box-shadow:none; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .label {'
        || ' font-size:11px; text-transform:uppercase; letter-spacing:0.10em;'
        || ' color:var(--muted); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .value {'
        || ' font-size:26px; font-weight:800; letter-spacing:-0.02em;'
        || ' line-height:1.05; color:var(--ink);'
        || ' font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .value small {'
        || ' font-size:12px; font-weight:500; color:var(--muted);'
        || ' margin-left:4px; letter-spacing:0; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .mini { width:100%; height:48px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .foot {'
        || ' display:flex; justify-content:space-between; align-items:center;'
        || ' gap:6px; font-size:11px; color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .deltas {'
        || ' display:flex; gap:8px; flex-wrap:wrap; min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta {'
        || ' font-variant-numeric:tabular-nums; white-space:nowrap; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta .dp {'
        || ' color:var(--muted); margin-right:2px; font-size:10.5px; font-weight:500; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.up   { color:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.down { color:var(--ok); }');

    -- =========================================================
    -- Windows ribbon
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.ribbon {'
        || ' width:100%; height:64px; margin:14px 0 8px; position:relative;'
        || ' background:var(--panel); border:1px solid var(--hairline); }');
    DBMS_OUTPUT.PUT_LINE('.ribbon svg { width:100%; height:100%; display:block; }');

    -- =========================================================
    -- Disclosures + SQL listings
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('details { margin:6px 0; }');
    DBMS_OUTPUT.PUT_LINE('details summary {'
        || ' cursor:pointer; padding:4px 0; font-weight:600; color:var(--red);'
        || ' font-size:12px; letter-spacing:0.04em; text-transform:uppercase; }');
    DBMS_OUTPUT.PUT_LINE('pre.sql {'
        || ' background:var(--panel-2); padding:12px; border-radius:0;'
        || ' border:1px solid var(--hairline);'
        || ' overflow-x:auto; white-space:pre-wrap;'
        || ' font-size:12px;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' color:var(--ink-soft); }');

    -- =========================================================
    -- Footer
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('footer.report {'
        || ' color:var(--muted); font-size:12px;'
        || ' margin-top:80px; padding:22px 0 0;'
        || ' border-top:1px solid var(--hairline); }');

    -- =========================================================
    -- Print
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('@media print {'
        || ' nav.toc { display:none; position:static; }'
        || ' body { max-width:none; padding:0 0 24px; background:#fff; }'
        || ' header.report { padding-top:0; }'
        || ' .chart-wrap { break-inside:avoid; }'
        || ' h2 { break-after:avoid; }'
        || ' }');

    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
