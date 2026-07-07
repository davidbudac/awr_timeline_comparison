--
-- _style.sql
-- Emits the <style> shared by every section of the HTML report.  Called
-- once from awr_trend.sql after the <head> opens.
--
-- Visual style: "Workbench" -- app-chrome report.
-- Cool light-gray canvas, a fixed left sidebar (the restyled nav.toc)
-- acting as a live status rail (per-section status dots + scrollspy,
-- wired by JS in 00_params.sql), content sections as white panels,
-- teal accent for interactive/current elements, red reserved for
-- severity.  Class names match those emitted by the sections verbatim,
-- so the restyle is purely a CSS swap (no data-section changes).
--
-- Design tokens, section-level layout, table conventions, severity
-- semantics are documented in design.md at the project root -- read
-- that before iterating.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');

    -- =========================================================
    -- Design tokens
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE(':root {'
        || ' --paper:#eceef1;       --panel:#ffffff;        --panel-2:#f4f6f8;'
        || ' --ink:#12161d;         --ink-soft:#333a45;     --muted:#5d6672;'
        || ' --rule:#c4ccd6;        --hairline:#d9dfe6;     --line-soft:#e8ecf1;'
        || ' --red:#c62828;         --red-deep:#a01c1c;     --chip-bg:#eef1f5;'
        || ' --track:#e2e7ee;'
        || ' --cell-bar-bg:rgba(31,95,168,0.10);'
        || ' --accent:#1f5fa8;      --accent-deep:#123a68;  --accent-bg:#e0eaf4;'
        || ' --accent-2:#3c6591;'
        || ' --rail-w:236px;'
        -- Read by the chart-init scripts (sections 04-15 and
        -- js_markers.plsql read fg/border for axis text and gridlines;
        -- 08 reads crit-fg/warn-fg for severity-tinted hero minis).
        || ' --fg:#333a45;           --border:#d9dfe6;'
        || ' --crit-fg:#a01c1c;      --warn-fg:#8a5a00;'
        || ' --crit:#b01c1c;        --warn:#8a5a00;         --ok:#1f7a4d;'
        || ' --info:#2f6fb0;        --skip:#7a828e;'
        || ' --crit-bg:#fbeceb;     --warn-bg:#faf2df;      --ok-bg:#e8f3ed;'
        || ' --warn-border:#f0d77a;'
        || ' --info-bg:#e7eef7;     --skip-bg:#eef1f4;'
        || ' --dot-ok:#1f9d63;      --dot-warn:#d99a1a;'
        || ' --dot-crit:#c62828;    --dot-na:#c1c9d3;'
        || ' --spark:#12161d;       --spark-fill:rgba(18,22,29,.07);'
        -- Wait-class palette: kept in approximate parity with
        -- js_wait_colors.plsql so on-page swatches read the same as the
        -- ECharts series.
        || ' --wc-sysio:#1F4E89;       --wc-other:#C77CB0;'
        || ' --wc-userio:#4A90D9;      --wc-commit:#E89B40;'
        || ' --wc-config:#793C32;      --wc-concurrency:#8B0000;'
        || ' --wc-network:#967259;     --wc-application:#D62728;'
        || ' --wc-cluster:#E5C228;     --wc-admin:#7B6FA8;'
        || ' --wc-sched:#88C070;       --wc-queue:#E89BB7;'
        || ' --wc-cpu:#3FB344;'
        || ' }');

    -- =========================================================
    -- Dark palette (Slate Instrument, dark). Screen-only override of the
    -- same token set via body.dark; wrapped in @media screen so print
    -- output always uses the light palette above with zero duplication.
    -- Does not redeclare --wc-* (wait-class palette, kept in parity with
    -- js_wait_colors.plsql) or --rail-w (layout, not a color).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('@media screen { body.dark {'
        || ' --paper:#0f1319;       --panel:#161b23;        --panel-2:#1d232d;'
        || ' --ink:#e7ecf2;         --ink-soft:#bcc5d1;     --muted:#8591a0;'
        || ' --rule:#333d49;        --hairline:#2a323d;     --line-soft:#232a34;'
        || ' --red:#e5675c;         --red-deep:#f0837a;     --chip-bg:#1d232d;'
        || ' --track:#2a323d;'
        || ' --cell-bar-bg:rgba(91,155,216,0.16);'
        || ' --accent:#5b9bd8;      --accent-deep:#c4dbf2;  --accent-bg:#18314a;'
        || ' --accent-2:#7ea6cf;'
        || ' --fg:#bcc5d1;           --border:#2a323d;'
        || ' --crit-fg:#e5675c;      --warn-fg:#e0a53a;'
        || ' --crit:#e5675c;        --warn:#e0a53a;         --ok:#43bb82;'
        || ' --info:#6fa8dc;        --skip:#8591a0;'
        || ' --crit-bg:#2b1a1a;     --warn-bg:#2a2413;      --ok-bg:#15271e;'
        || ' --warn-border:#6d5a22;'
        || ' --info-bg:#172431;     --skip-bg:#1d232d;'
        || ' --dot-ok:#43bb82;      --dot-warn:#e0a53a;'
        || ' --dot-crit:#e5675c;    --dot-na:#3a4350;'
        || ' --spark:#e7ecf2;       --spark-fill:rgba(231,236,242,.10);'
        || ' } }');

    -- =========================================================
    -- Reset + body.  The body is a flex column (visual order of the
    -- sections is set with order: below); the fixed sidebar is cleared
    -- with padding-left.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    -- No html-level scroll-behavior:smooth: embedded webviews can stall
    -- the smooth-scroll animation entirely (page refuses to move), and
    -- instant anchor jumps suit an operational report better anyway.
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--paper); color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('body {'
        || ' font-family:"Inter","Helvetica Neue",Helvetica,Arial,system-ui,sans-serif;'
        || ' font-size:14px; line-height:1.55;'
        || ' -webkit-font-smoothing:antialiased;'
        || ' max-width:1560px; margin:0;'
        || ' padding:0 32px 96px calc(var(--rail-w) + 32px);'
        || ' display:flex; flex-direction:column; gap:0; align-items:stretch; }');
    DBMS_OUTPUT.PUT_LINE('body > section, body > header.report, body > footer.report {'
        || ' width:100%; max-width:1150px; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) {'
        || ' body { padding:0 20px 64px; } }');

    -- =========================================================
    -- Visual section ordering.  Grouped to match the sidebar rail:
    -- Triage, Workload, SQL, Storage and config.  (The DOM order is
    -- emission order; flex order: repaints it.)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report      { order:1; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc            { order:2; }');
    -- Triage
    DBMS_OUTPUT.PUT_LINE('#db-time-summary   { order:3; }');
    DBMS_OUTPUT.PUT_LINE('#overview          { order:4; }');
    DBMS_OUTPUT.PUT_LINE('#ash-timeline      { order:5; }');
    DBMS_OUTPUT.PUT_LINE('#findings          { order:6; }');
    DBMS_OUTPUT.PUT_LINE('#windows           { order:7; }');
    -- Workload
    DBMS_OUTPUT.PUT_LINE('#utilization       { order:8; }');
    DBMS_OUTPUT.PUT_LINE('#load              { order:9; }');
    DBMS_OUTPUT.PUT_LINE('#metrics           { order:10; }');
    DBMS_OUTPUT.PUT_LINE('#waits-fg          { order:11; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg          { order:12; }');
    -- SQL
    DBMS_OUTPUT.PUT_LINE('#topsql            { order:13; }');
    DBMS_OUTPUT.PUT_LINE('#topsql-ash        { order:14; }');
    -- Storage and config
    DBMS_OUTPUT.PUT_LINE('#segment-io        { order:15; }');
    DBMS_OUTPUT.PUT_LINE('#file-io           { order:16; }');
    DBMS_OUTPUT.PUT_LINE('#param-changes     { order:17; }');
    DBMS_OUTPUT.PUT_LINE('footer.report      { order:18; }');

    -- =========================================================
    -- Masthead (header.report) -- compact identity panel at the top
    -- of the content column: brandline, small headline, run metadata,
    -- verdict banner, windows strip.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report {'
        || ' background:var(--panel); color:var(--ink);'
        || ' border:1px solid var(--hairline); border-radius:10px;'
        || ' padding:18px 24px 16px; margin:20px 0 0; }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline {'
        || ' font-weight:700; letter-spacing:0.14em; font-size:10.5px;'
        || ' text-transform:uppercase; color:var(--muted); margin:0 0 10px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline .dot { color:var(--accent); margin-right:6px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .brandline .slash { color:var(--accent); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 {'
        || ' font-weight:700; font-size:24px; line-height:1.2;'
        || ' letter-spacing:-0.01em; margin:0; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 em {'
        || ' font-style:normal; color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('header.report h1 .badge { display:none; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 880px) {'
        || ' header.report { padding:14px 16px; }'
        || ' header.report h1 { font-size:19px; } }');

    -- Masthead .topgrid: headline left, run metadata right
    DBMS_OUTPUT.PUT_LINE('header.report .topgrid {'
        || ' display:flex; justify-content:space-between; align-items:flex-end;'
        || ' gap:24px; flex-wrap:wrap; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta {'
        || ' text-align:right; font-size:12px; color:var(--muted);'
        || ' line-height:1.65; min-width:240px;'
        || ' display:block; margin-top:0; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta div {'
        || ' color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta b {'
        || ' color:var(--ink); font-weight:600; margin-right:4px; }');

    -- Header windows-strip: narrow full-width DB-time timeline.
    -- .strip-head holds a single caption line; .windows-chart is the
    -- ECharts target (very short); .windows-fallback is shown only when
    -- body.no-charts hides the chart (offline / CDN-less) and lists
    -- windows as plain text.
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip {'
        || ' margin-top:16px; font-size:13px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .strip-head {'
        || ' display:flex; align-items:baseline; gap:10px;'
        || ' flex-wrap:wrap; margin-bottom:4px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-strip .strip-head b {'
        || ' color:var(--muted); font-weight:700;'
        || ' letter-spacing:0.08em; font-size:10.5px;'
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
    -- Masthead verdict: severity-tinted banner emitted by 00_params.sql
    -- from a recomputed z-score. The container carries a v-ok / v-crit /
    -- v-skip class so the whole callout is tinted by severity.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('header.report .verdict {'
        || ' margin-top:16px; padding:12px 16px;'
        || ' border:1px solid var(--hairline); border-left:5px solid var(--muted);'
        || ' border-radius:8px;'
        || ' background:var(--panel-2);'
        || ' font-size:13.5px; color:var(--ink-soft); line-height:1.5;'
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
        || ' font-size:10.5px; letter-spacing:0.12em; text-transform:uppercase;'
        || ' color:var(--muted); font-weight:700; align-self:center; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede {'
        || ' color:var(--ink); font-weight:700;'
        || ' font-size:19px; letter-spacing:-0.01em; line-height:1.15;'
        || ' text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict a.lede:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.crit { color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.ok   { color:var(--ok); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .lede.skip { color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .sep {'
        || ' color:var(--accent); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body { color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body a {'
        || ' color:var(--accent); text-decoration:none; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .body a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover {'
        || ' display:inline-flex; align-items:baseline; gap:6px;'
        || ' white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover::before {'
        || ' content:"\2022"; color:var(--accent); font-weight:700;'
        || ' margin-right:2px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .name {'
        || ' color:var(--ink); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct {'
        || ' font-variant-numeric:tabular-nums; font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.up   { color:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.down { color:var(--ok); }');

    -- Compact "all movers" disclosure under the verdict.
    DBMS_OUTPUT.PUT_LINE('header.report .movers-all {'
        || ' margin-top:8px; font-size:12px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-all summary {'
        || ' cursor:pointer; user-select:none; padding:4px 0;'
        || ' font-size:10.5px; letter-spacing:0.06em; text-transform:uppercase;'
        || ' color:var(--muted); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-all summary:hover { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list {'
        || ' list-style:none; margin:6px 0 2px; padding:0;'
        || ' display:grid;'
        || ' grid-template-columns:repeat(auto-fill, minmax(290px, 1fr));'
        || ' gap:1px 20px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list li {'
        || ' display:flex; align-items:baseline; gap:8px;'
        || ' padding:2px 0; line-height:1.4;'
        || ' border-bottom:1px solid var(--line-soft); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-dom {'
        || ' font-size:9px; letter-spacing:0.08em; font-weight:700;'
        || ' color:var(--muted); width:46px; flex:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-name {'
        || ' color:var(--ink); flex:1 1 auto;'
        || ' overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-z {'
        || ' font-variant-numeric:tabular-nums; color:var(--muted); flex:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct {'
        || ' font-variant-numeric:tabular-nums; font-weight:700;'
        || ' flex:none; min-width:54px; text-align:right; }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct.up   { color:var(--red); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct.down { color:var(--ok); }');

    -- =========================================================
    -- Sidebar rail (nav.toc): fixed left column with grouped section
    -- links.  JS in 00_params.sql prepends a status dot (span.st) to
    -- each link from the section severity classes, and drives the
    -- scrollspy (.on).  On narrow screens it degrades to a static
    -- wrapping block above the content.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('nav.toc {'
        || ' position:fixed; left:0; top:0; bottom:0; z-index:10;'
        || ' width:var(--rail-w);'
        || ' background:var(--panel-2);'
        || ' border-right:1px solid var(--hairline);'
        || ' margin:0; padding:16px 12px 14px;'
        || ' font-size:13px; letter-spacing:0; text-transform:none;'
        || ' color:var(--muted);'
        || ' display:flex; flex-direction:column; gap:2px;'
        || ' overflow-y:auto; }');
    -- Rail brand row: report title plus the dark-mode icon button beside it.
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand {'
        || ' display:flex; align-items:center; justify-content:space-between;'
        || ' gap:8px; padding:2px 10px 12px;'
        || ' border-bottom:1px solid var(--hairline); margin-bottom:8px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand span {'
        || ' font-size:11px; font-weight:700; letter-spacing:0.1em;'
        || ' text-transform:uppercase; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand .theme-icon-btn {'
        || ' flex:none; display:flex; align-items:center; justify-content:center;'
        || ' width:24px; height:24px; padding:0; border-radius:50%;'
        || ' border:1px solid var(--rule); background:var(--panel);'
        || ' color:var(--ink-soft); cursor:pointer;'
        || ' transition:color .12s,background .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand .theme-icon-btn:hover {'
        || ' border-color:var(--accent); color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand .theme-icon-btn .icon-sun { display:none; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-brand .theme-icon-btn .icon-moon { display:block; }');
    DBMS_OUTPUT.PUT_LINE('body.dark nav.toc .rail-brand .theme-icon-btn .icon-sun { display:block; }');
    DBMS_OUTPUT.PUT_LINE('body.dark nav.toc .rail-brand .theme-icon-btn .icon-moon { display:none; }');
    -- Group labels
    DBMS_OUTPUT.PUT_LINE('nav.toc b {'
        || ' color:var(--muted); font-weight:700;'
        || ' letter-spacing:0.14em; font-size:10px;'
        || ' text-transform:uppercase;'
        || ' margin:14px 10px 5px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b::before { content:none; }');
    -- Section links
    DBMS_OUTPUT.PUT_LINE('nav.toc a {'
        || ' display:flex; align-items:center; gap:9px;'
        || ' padding:6px 10px; border-radius:7px;'
        || ' color:var(--ink-soft); text-decoration:none; font-weight:500;'
        || ' transition:color .12s, background .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { background:var(--paper); color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a.on {'
        || ' background:var(--accent-bg); color:var(--accent-deep);'
        || ' font-weight:600; }');
    -- Status dots (injected by JS; na = no signal found)
    DBMS_OUTPUT.PUT_LINE('nav.toc a .st {'
        || ' width:8px; height:8px; border-radius:50%; flex:none;'
        || ' background:var(--dot-na); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .st.ok   { background:var(--dot-ok); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .st.warn { background:var(--dot-warn); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .st.crit { background:var(--dot-crit); }');

    -- Rail foot wrapper: holds the app-filter and essential-rows buttons
    -- together, pinned to the bottom of the rail. (Dark mode lives as an
    -- icon button beside the rail-brand title at the top of the rail.)
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-foot {'
        || ' margin-top:auto; display:flex; flex-direction:column; gap:6px; }');

    -- "Essential rows" / "Application only" toggle buttons in the rail foot.
    DBMS_OUTPUT.PUT_LINE('nav.toc .app-filter, nav.toc .essential-filter {'
        || ' font:inherit; font-size:11px; font-weight:700;'
        || ' letter-spacing:0.04em; text-transform:uppercase;'
        || ' padding:7px 12px; border-radius:8px; cursor:pointer;'
        || ' border:1px solid var(--rule); background:var(--panel);'
        || ' color:var(--ink); transition:color .12s,background .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .app-filter:hover, nav.toc .essential-filter:hover {'
        || ' border-color:var(--accent); color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .app-filter.active, nav.toc .essential-filter.active {'
        || ' background:var(--accent); border-color:var(--accent); color:#fff; }');

    -- Narrow screens: the rail becomes a static wrapping block.
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) {'
        || ' nav.toc { position:static; width:auto; overflow:visible;'
        || '   flex-direction:row; flex-wrap:wrap; align-items:center;'
        || '   gap:2px 10px; border-right:0;'
        || '   border-bottom:1px solid var(--hairline);'
        || '   border-radius:0; margin:14px 0; padding:10px 0; }'
        || ' nav.toc .rail-brand { border-bottom:0; padding:0 8px 0 0; margin:0; }'
        || ' nav.toc b { margin:0 4px 0 10px; }'
        || ' nav.toc .rail-foot { margin-top:0; margin-left:auto; flex-direction:row; } }');

    -- =========================================================
    -- "Application only" view (body.app-only).
    -- Same offline-style body-class hook as body.no-charts: a single class
    -- on <body> drives every hide rule, toggled by the rail button. When on,
    -- the report shows only application SQL and its directly related data
    -- (Top SQL, Top SQL ASH, Segment I/O, File I/O, Utilization) and hides
    -- all system-wide events/metrics sections plus the masthead's system
    -- verdict and DB-time strip.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('body.app-only #db-time-summary,'
        || ' body.app-only #overview,'
        || ' body.app-only #ash-timeline,'
        || ' body.app-only #waits-fg,'
        || ' body.app-only #waits-bg,'
        || ' body.app-only #findings,'
        || ' body.app-only #windows,'
        || ' body.app-only #load,'
        || ' body.app-only #metrics,'
        || ' body.app-only #param-changes,'
        || ' body.app-only header.report .verdict,'
        || ' body.app-only header.report .movers-all,'
        || ' body.app-only header.report .windows-strip { display:none; }');
    -- Remove the rail links that point at now-hidden sections, leaving
    -- only the ones still on screen (kept in sync with the hide rule
    -- above).  Group labels hide too: the survivors read as a flat list.
    DBMS_OUTPUT.PUT_LINE('body.app-only nav.toc a'
        || ':not([href="#topsql"])'
        || ':not([href="#topsql-ash"])'
        || ':not([href="#segment-io"])'
        || ':not([href="#file-io"])'
        || ':not([href="#utilization"]) { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.app-only nav.toc b { display:none; }');
    -- Row / card / disclosure level: hide SQL parsed by an Oracle-maintained
    -- schema (tagged data-sys="Y" by sections 06 and 11) so only application
    -- SQL remains in the tables, the per-SQL detail blocks, and the ASH cards.
    DBMS_OUTPUT.PUT_LINE('body.app-only tr[data-sys="Y"],'
        || ' body.app-only details[data-sys="Y"],'
        || ' body.app-only .ash-sql-card[data-sys="Y"] { display:none; }');

    -- =========================================================
    -- "Essential rows" preset (body.essential).
    -- Same body-class hook: sections 02/03/04/05 tag their per-name data
    -- rows data-imp="Y|N" (via sql/lib/is_essential.plsql); when on, the
    -- non-curated rows hide.  Escape hatch: a row whose Change cell holds
    -- a crit/warn severity badge stays visible even when data-imp="N",
    -- so the preset can never hide a flagged anomaly (:has degrades to
    -- hiding flagged rows only on pre-:has browsers -- acceptable).
    -- Charts and the wait-class rollup are untouched by design.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('body.essential tr[data-imp="N"]'
        || ':not(:has(.badge.crit)):not(:has(.badge.warn)) { display:none; }');
    -- Count pill appended to each affected section h2 by the toggle JS
    -- (00_params.sql); only visible while the preset is on.
    DBMS_OUTPUT.PUT_LINE('.preset-note {'
        || ' display:none; margin-left:auto; align-self:center;'
        || ' font-size:11.5px; font-weight:700; letter-spacing:0.02em;'
        || ' padding:2px 10px; border-radius:999px; white-space:nowrap;'
        || ' background:var(--accent-bg); color:var(--accent-deep); }');
    DBMS_OUTPUT.PUT_LINE('body.essential .preset-note { display:inline-block; }');

    -- =========================================================
    -- Sections: white panels
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('section {'
        || ' background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:10px; padding:20px 24px;'
        || ' margin:18px 0 0; scroll-margin-top:18px; }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:24px; margin:0; }');

    -- Section <h2>: compact panel heading (the rail does the wayfinding,
    -- so the big editorial numerals are gone).
    DBMS_OUTPUT.PUT_LINE('h2 {'
        || ' font-weight:700; font-size:18px; line-height:1.25;'
        || ' letter-spacing:-0.01em; color:var(--ink);'
        || ' text-transform:none;'
        || ' margin:0 0 12px; padding:0 0 10px; border:0;'
        || ' border-bottom:1px solid var(--line-soft);'
        || ' display:flex; align-items:baseline; gap:10px; }');
    DBMS_OUTPUT.PUT_LINE('h2::before { content:none; }');
    DBMS_OUTPUT.PUT_LINE('h2::after { content:none; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 880px) {'
        || ' h2 { font-size:16px; gap:8px; } }');

    -- h3: subsection header (chart-group headers in Top SQL / segment I/O /
    -- file I/O, severity-group headers in Findings). Sized/colored to read
    -- as a real heading so it outranks the <details> summary sitting right
    -- below it in the same block, which also carries the accent color; the
    -- accent tick echoes the rail's status-dot language.
    DBMS_OUTPUT.PUT_LINE('h3 {'
        || ' font-size:13.5px; letter-spacing:0.03em; text-transform:uppercase;'
        || ' color:var(--ink); font-weight:800; margin:28px 0 10px;'
        || ' display:flex; align-items:center; gap:8px; }');
    DBMS_OUTPUT.PUT_LINE('h3::before {'
        || ' content:""; width:3px; height:12px; flex:none;'
        || ' background:var(--accent); border-radius:1px; }');

    -- Divider before each repeat chart-group block (Top SQL / segment I/O /
    -- file I/O): a rule + extra top space between one dimension's
    -- chart+detail-table and the next, without touching the section's
    -- first h3 (which follows the intro <p>, not a </details>).
    DBMS_OUTPUT.PUT_LINE('details + h3 {'
        || ' margin-top:36px; padding-top:24px;'
        || ' border-top:1px solid var(--hairline); }');

    -- =========================================================
    -- Tables
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('table {'
        || ' width:100%; border-collapse:collapse;'
        || ' font-size:12.5px; background:transparent;'
        || ' border:0; border-radius:0;'
        || ' margin:12px 0 16px; }');
    DBMS_OUTPUT.PUT_LINE('thead th {'
        || ' background:var(--panel-2); color:var(--muted);'
        || ' text-align:left; padding:9px 10px 8px;'
        || ' font-size:10.5px; font-weight:700; letter-spacing:0.09em;'
        || ' text-transform:uppercase; white-space:nowrap;'
        || ' border-bottom:1px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('tbody td {'
        || ' padding:8px 10px; border-bottom:1px solid var(--line-soft);'
        || ' vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:last-child td { border-bottom:0; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num {'
        || ' text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    -- text-transform:none is critical: sql_ids are case-sensitive base32
    -- hashes ("gnj0gxw60apzr" is not "GNJ0GXW60APZR"), and at least one
    -- parent selector (details summary) applies text-transform:uppercase
    -- which would otherwise cascade in and break copy-paste back into AWR
    -- queries.  Pinning it here protects every <code>/.mono usage
    -- regardless of which container it ends up in.
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono {'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:12px; text-transform:none; }');
    DBMS_OUTPUT.PUT_LINE('td a { color:var(--accent); text-decoration:none; font-weight:600; }');
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
    -- Badges: soft tinted chips (workbench style)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.badge {'
        || ' display:inline-block; padding:2px 8px; border-radius:6px;'
        || ' font-size:10.5px; font-weight:700; letter-spacing:0.04em;'
        || ' text-transform:uppercase; vertical-align:middle;'
        || ' border:0; }');
    DBMS_OUTPUT.PUT_LINE('.badge.crit { background:var(--crit-bg); color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('.badge.warn { background:var(--warn-bg); color:var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('.badge.ok   { background:var(--ok-bg);   color:var(--ok); }');
    DBMS_OUTPUT.PUT_LINE('.badge.info { background:var(--info-bg); color:var(--info); }');
    DBMS_OUTPUT.PUT_LINE('.badge.skip { background:var(--skip-bg); color:var(--skip); }');

    -- Soft accent bar (legacy hook used by hero card foot deltas)
    DBMS_OUTPUT.PUT_LINE('.bar {'
        || ' display:block; height:2px; background:var(--accent);'
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
    -- Top-SQL chart breakdown toggle (SQL_ID / Schema / ...)
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle {'
        || ' display:flex; align-items:center; gap:6px;'
        || ' margin:10px 0 6px; font-size:11px; color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button {'
        || ' font:inherit; font-size:11px; font-weight:600;'
        || ' padding:3px 11px; border-radius:999px; cursor:pointer;'
        || ' border:1px solid var(--hairline); background:var(--panel);'
        || ' color:var(--muted); letter-spacing:0.02em; }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button:hover { color:var(--ink); border-color:var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('.topsql-toggle button.active {'
        || ' background:var(--accent); color:#fff;'
        || ' border-color:var(--accent); }');

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
    DBMS_OUTPUT.PUT_LINE('svg.spark .dot { fill:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('th.trend, td.trend { width:110px; padding:6px 8px; text-align:center; }');

    -- =========================================================
    -- Cell-bar behind the current-value column in load/sysmetric tables
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('td.cell-bar { position:relative; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .bg {'
        || ' position:absolute; left:0; top:0; bottom:0;'
        || ' background:var(--cell-bar-bg);'
        || ' border-right:2px solid var(--accent); pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .v {'
        || ' position:relative; z-index:1; font-weight:600; }');

    -- =========================================================
    -- Parameter-changes table (#param-changes): monospace name/value
    -- cells, value cells allowed to wrap, changed cells tinted amber
    -- with a left rule (same warn tokens as the severity rows).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('#param-changes td.pname code { font-weight:600; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('#param-changes td.pval {'
        || ' white-space:normal; word-break:break-word;'
        || ' max-width:320px; vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('#param-changes td.pval code {'
        || ' font-size:11.5px; color:var(--ink-soft); }');
    DBMS_OUTPUT.PUT_LINE('#param-changes td.cur code { font-weight:700; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('#param-changes td.chg {'
        || ' background:var(--warn-bg);'
        || ' box-shadow:inset 3px 0 0 var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('#param-changes td .muted { color:var(--muted); }');

    -- =========================================================
    -- ECharts containers
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.chart-wrap {'
        || ' width:100%; background:var(--panel);'
        || ' border:1px solid var(--line-soft); border-radius:8px;'
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
        || ' border:1px solid var(--hairline); border-radius:8px;'
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
    -- Theme-aware: var(--warn-fg) / var(--warn-border) keep the offline-charts
    -- banner legible in dark mode, where --warn-bg is near-black (F13).
    DBMS_OUTPUT.PUT_LINE('.cdn-warn {'
        || ' display:none;'
        || ' background:var(--warn-bg); color:var(--warn-fg);'
        || ' padding:8px 12px; border:1px solid var(--warn-border); border-radius:8px;'
        || ' font-size:13px; margin:6px 0; }');

    -- =========================================================
    -- Overview KPI strip (#overview .hero-grid)
    -- Panel cards: value on top, mini chart, then deltas at the foot.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('#overview .hero-grid {'
        || ' display:grid; grid-template-columns:repeat(3, minmax(0,1fr)); gap:12px;'
        || ' background:transparent; border:0; border-radius:0;'
        || ' margin-top:12px; padding:0; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 900px) {'
        || ' #overview .hero-grid { grid-template-columns:repeat(2, minmax(0,1fr)); } }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 520px) {'
        || ' #overview .hero-grid { grid-template-columns:1fr; } }');
    DBMS_OUTPUT.PUT_LINE('.hero-card {'
        || ' background:var(--panel-2);'
        || ' border:1px solid var(--hairline);'
        || ' padding:13px 15px;'
        || ' display:flex; flex-direction:column; gap:6px;'
        || ' position:relative; min-width:0;'
        || ' border-radius:8px; box-shadow:none; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .label {'
        || ' font-size:10.5px; text-transform:uppercase; letter-spacing:0.10em;'
        || ' color:var(--muted); font-weight:700; }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .value {'
        || ' font-size:25px; font-weight:700; letter-spacing:-0.02em;'
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
        || ' background:var(--panel-2); border:1px solid var(--hairline);'
        || ' border-radius:8px; }');
    DBMS_OUTPUT.PUT_LINE('.ribbon svg { width:100%; height:100%; display:block; }');

    -- =========================================================
    -- Disclosures + SQL listings
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('details { margin:6px 0; }');
    DBMS_OUTPUT.PUT_LINE('details summary {'
        || ' cursor:pointer; padding:4px 0; font-weight:600; color:var(--accent);'
        || ' font-size:12px; letter-spacing:0.04em; text-transform:uppercase; }');
    DBMS_OUTPUT.PUT_LINE('pre.sql {'
        || ' background:var(--panel-2); padding:12px; border-radius:8px;'
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
        || ' margin-top:48px; padding:18px 4px 0;'
        || ' border-top:1px solid var(--hairline); }');

    -- =========================================================
    -- Print
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('@media print {'
        || ' nav.toc { display:none; position:static; }'
        || ' body { max-width:none; padding:0 0 24px; background:#fff; }'
        || ' section { border:0; padding:12px 0; }'
        || ' header.report { border:0; padding-top:0; }'
        || ' .chart-wrap { break-inside:avoid; }'
        || ' h2 { break-after:avoid; }'
        || ' }');

    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
