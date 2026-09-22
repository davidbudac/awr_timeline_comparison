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
        || ' margin:0;'
        || ' padding:0 32px 96px calc(var(--rail-w) + 32px);'
        || ' display:flex; flex-direction:column; gap:0; align-items:stretch; }');
    DBMS_OUTPUT.PUT_LINE('main > section, body > section, body > header.report, body > footer.report {'
        || ' width:100%; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) {'
        || ' body { padding:0 20px 64px; } }');

    -- =========================================================
    -- Body-level ordering (narrow layout only) and the main landmark.
    -- =========================================================
    -- v1.5.0 (phase 4): sections are EMITTED in visual order (see the
    -- include list in awr_trend.sql), so no per-section order: remains.
    -- The masthead / rail / main / footer ranks below only exist for the
    -- narrow layout, where the rail (order:0 there) must precede the
    -- masthead; <main> is display:contents so its sections take part in
    -- the body flex column directly.
    DBMS_OUTPUT.PUT_LINE('header.report      { order:1; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc            { order:2; }');
    DBMS_OUTPUT.PUT_LINE('main               { display:contents; }');
    DBMS_OUTPUT.PUT_LINE('main > section, body > section { order:3; }');
    DBMS_OUTPUT.PUT_LINE('footer.report      { order:4; }');

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
    -- F5: direction is carried by the glyph, not by color.  The percentage
    -- text stays --ink in BOTH directions (red/green delta coloring is gone
    -- report-wide: red is reserved for severity).  Only the small triangle
    -- glyph inside the verdict block keeps a severity color.
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.up   { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct.down { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report .verdict .mover .pct .g {'
        || ' color:var(--crit); font-weight:700; margin-right:1px; }');

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
    -- F5: neutralized (see the verdict .pct rules above).  The glyph in the
    -- all-movers list is muted -- only the verdict block gets the crit glyph.
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct.up   { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct.down { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('header.report .movers-list .m-pct .g {'
        || ' color:var(--muted); font-weight:700; margin-right:1px; }');

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

    -- Rail foot wrapper: holds the Normal / Full mode switch and the
    -- next-finding button, pinned to the bottom of the rail. (Dark mode lives as an
    -- icon button beside the rail-brand title at the top of the rail.)
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-foot {'
        || ' margin-top:auto; display:flex; flex-direction:column; gap:6px;'
        || ' position:sticky; bottom:0; background:var(--panel-2);'
        || ' padding-top:8px; }');
    -- Narrow-screen "View" popover: display:contents on desktop keeps the
    -- toggle buttons as direct flex children of .rail-foot.
    DBMS_OUTPUT.PUT_LINE('nav.toc .view-btn { display:none; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .view-panel { display:contents; }');

    -- Normal / Full mode switch: a two-button segmented control
    -- (aria-pressed marks the active half), first thing in the rail foot.
    DBMS_OUTPUT.PUT_LINE('nav.toc .mode-switch {'
        || ' display:flex; border:1px solid var(--rule); border-radius:8px;'
        || ' overflow:hidden; background:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .mode-btn {'
        || ' flex:1 1 0; font:inherit; font-size:11px; font-weight:700;'
        || ' letter-spacing:0.04em; text-transform:uppercase;'
        || ' padding:7px 6px; border:0; cursor:pointer; background:transparent;'
        || ' color:var(--muted); transition:color .12s,background .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .mode-btn + .mode-btn { border-left:1px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .mode-btn:hover { color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .mode-btn[aria-pressed="true"] {'
        || ' background:var(--accent); color:#fff; }');
    -- "+ N more sections" line the rail JS appends in the Normal view.
    DBMS_OUTPUT.PUT_LINE('nav.toc a.more-sections { display:none; color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('body.normal nav.toc a.more-sections { display:flex; }');

    -- =========================================================
    -- "What changed" narrative (section 17), relocated into the masthead
    -- slot by its own inline script.  A quiet accent-tinted note, not a
    -- banner: the verdict above it already carries the severity color.
    -- Kept in the Normal view (it IS the short report) --
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('.narr {'
        || ' border-left:3px solid var(--accent);'
        || ' background:var(--accent-bg);'
        || ' font-size:13px; line-height:1.6;'
        || ' padding:10px 14px; border-radius:0 6px 6px 0;'
        || ' margin-top:10px; color:var(--ink); }');
    -- v1.5.0: the block is a structured list, one row per finding --
    -- label | headline number | from -> to | why | section link.
    DBMS_OUTPUT.PUT_LINE('.narr .narr-head {'
        || ' font-size:10.5px; font-weight:700; letter-spacing:0.08em;'
        || ' text-transform:uppercase; color:var(--accent-deep); margin:0 0 6px; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list { list-style:none; margin:0; padding:0; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list li {'
        || ' display:grid; grid-template-columns:130px auto auto 1fr auto;'
        || ' column-gap:14px; align-items:baseline; padding:5px 0;'
        || ' border-top:1px solid color-mix(in srgb, var(--accent) 18%, transparent); }');
    DBMS_OUTPUT.PUT_LINE('.narr-list li:first-child { border-top:0; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list .n-lbl { font-weight:700; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.narr-list .n-num {'
        || ' font-weight:700; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list .n-sub {'
        || ' color:var(--ink-soft); font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list .n-why { color:var(--muted); min-width:0; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list .n-go { white-space:nowrap; font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('.narr-list li > :empty { display:none; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width:700px) { .narr-list li {'
        || ' grid-template-columns:1fr auto; }'
        || ' .narr-list .n-why { grid-column:1 / -1; } }');
    DBMS_OUTPUT.PUT_LINE('.narr b { font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('.narr code {'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;'
        || ' font-size:11.5px; }');
    DBMS_OUTPUT.PUT_LINE('.narr a { color:var(--accent-deep);'
        || ' text-decoration:none; font-weight:600;'
        || ' border-bottom:1px solid var(--border); }');
    DBMS_OUTPUT.PUT_LINE('.narr a:hover { border-bottom-color:var(--accent); }');

    -- =========================================================
    -- Normal / Full views (body.normal / body.full, set by the
    -- early mode script in 00_params.sql from localStorage "awr-mode";
    -- Normal is the default).  Same body-class hook as body.no-charts.
    -- Sections opt INTO the Normal view with
    -- data-normal="Y" (06 Top SQL, 07 Findings, 08 Headline metrics, 09
    -- ASH timeline always; 12 / 16 / 18 only when they have something
    -- worth the short report, via a one-line inline script); anything
    -- tagged .full-only (07's per-domain tables, 06's per-SQL pool)
    -- drops out of Normal even inside a kept section.  Rail links to
    -- hidden sections carry .norm-dim (computed by the rail JS from the
    -- same data-normal test) and hide too; the JS appends a "+ N more
    -- sections" line and a .mode-note at the end of <main> instead.
    -- With JS off neither body class exists and everything shows.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('body.normal main > section:not([data-normal]) { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.normal .full-only { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.normal nav.toc a.norm-dim, body.normal nav.toc b.norm-dim { display:none; }');
    -- order:3 = the same flex rank as main > section, so the note (appended
    -- last inside <main>) sits after the last visible section, not first.
    DBMS_OUTPUT.PUT_LINE('.mode-note {'
        || ' display:none; order:3; margin:18px 0 0 0; padding:12px 16px; border-radius:10px;'
        || ' border:1px dashed var(--rule); background:var(--panel-2);'
        || ' color:var(--muted); font-size:12.5px; line-height:1.5; }');
    DBMS_OUTPUT.PUT_LINE('body.normal .mode-note { display:block; }');
    DBMS_OUTPUT.PUT_LINE('.mode-note button {'
        || ' font:inherit; font-size:11px; font-weight:700; letter-spacing:0.04em;'
        || ' text-transform:uppercase; padding:4px 10px; border-radius:6px;'
        || ' border:1px solid var(--accent); background:transparent; color:var(--accent);'
        || ' cursor:pointer; margin-left:6px; }');

    -- =========================================================
    -- Sections: white panels
    -- =========================================================
    -- T2: the section's own top padding moved into the sticky h2 (6 + 14 =
    -- the old 20px of headroom) so the heading can sit flush against the
    -- viewport top when it sticks, with no transparent gap above it.
    -- scroll-margin clears the narrow-screen top bar (--navh, 0 on
    -- desktop); anchors INSIDE a section (rows, cards -- phase 3 links)
    -- also clear the sticky h2 + thead stack.
    DBMS_OUTPUT.PUT_LINE('section {'
        || ' background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:10px; padding:6px 24px 20px;'
        || ' margin:18px 0 0; scroll-margin-top:calc(var(--navh, 0px) + 18px); }');
    DBMS_OUTPUT.PUT_LINE('section tr[id], section [id].ash-sql-card, section h3[id] {'
        || ' scroll-margin-top:calc(var(--navh, 0px) + var(--h2h, 48px) + 44px); }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:24px; margin:0; }');

    -- Section <h2>: compact panel heading (the rail does the wayfinding,
    -- so the big editorial numerals are gone).
    -- T2 (sticky headers): the section heading sticks to the top of the
    -- viewport while its section scrolls past.  --navh is 0 on desktop and
    -- the height of the narrow-screen top bar below 980px (set by the rail
    -- JS in 00_params.sql); z-index 6 keeps it above .chart-wrap (a z:0
    -- stacking context) and above the sticky thead (z:4).
    DBMS_OUTPUT.PUT_LINE('h2 {'
        || ' font-weight:700; font-size:18px; line-height:1.25;'
        || ' letter-spacing:-0.01em; color:var(--ink);'
        || ' text-transform:none;'
        || ' margin:0 0 12px; padding:14px 0 10px; border:0;'
        || ' border-bottom:1px solid var(--line-soft);'
        || ' background:var(--panel);'
        || ' display:flex; align-items:baseline; gap:10px; }');
    DBMS_OUTPUT.PUT_LINE('section > h2 {'
        || ' position:sticky; top:var(--navh, 0px); z-index:6;'
        || ' white-space:nowrap; }');
    -- T8: the first sentence of the section intro, kept inline on the
    -- heading as a muted subtitle (the rest folds into details.method).
    -- flex:0 1 auto + min-width:0 lets the subtitle shrink and ellipsize
    -- instead of forcing the h2 (now nowrap) onto a second line when the
    -- title + subtitle together are wider than the panel.
    DBMS_OUTPUT.PUT_LINE('h2 .h2sub {'
        || ' font-weight:400; font-size:12px; color:var(--muted);'
        || ' letter-spacing:0; flex:0 1 auto; min-width:0; overflow:hidden;'
        || ' text-overflow:ellipsis; white-space:nowrap; }');
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
    -- v1.5.0 (phase 2): the chrome JS wraps every section table in
    -- div.tblwrap and adds .scroll when the table is wider than its
    -- panel, so wide per-window tables scroll sideways inside the panel
    -- instead of pushing the whole page wide.  A scrolling table keeps its
    -- first column pinned (sticky-left) and loses the sticky thead (a
    -- scroll container ends the viewport-relative stickiness).
    DBMS_OUTPUT.PUT_LINE('.tblwrap { max-width:100%; }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll { overflow-x:auto; overscroll-behavior-x:contain;'
        || ' -webkit-overflow-scrolling:touch; margin:12px 0 16px;'
        || ' box-shadow:inset -14px 0 12px -14px rgba(0,0,0,.18); }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll table { margin:0; }');
    -- Inside a scroll container the viewport-relative top-stickiness of
    -- thead th would stick to the WRAPPER instead (the header row floats
    -- down through the rows as the page scrolls), so it is switched off
    -- there and only the first column stays sticky-left.
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll thead th { position:static; }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll tr > :first-child {'
        || ' position:sticky; left:0; top:auto; z-index:2; background:var(--panel); }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll thead th:first-child { background:var(--panel-2); z-index:5; }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll tr.crit > td:first-child { background:var(--crit-bg); }'
        || ' .tblwrap.scroll tr.warn > td:first-child { background:var(--warn-bg); }'
        || ' .tblwrap.scroll tr.info > td:first-child { background:var(--info-bg); }');
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
    -- T2: header row sticks just under the sticky section h2.  --h2h is
    -- written per section by the rail JS (default 48px), --navh is the
    -- narrow-screen top-bar height (0 on desktop).
    DBMS_OUTPUT.PUT_LINE('section table thead th {'
        || ' position:sticky; top:calc(var(--navh, 0px) + var(--h2h, 48px));'
        || ' z-index:4; }');
    -- T3: click-to-sort affordance.  Tables opting out carry data-nosort;
    -- per-window header cells (th[data-w]) drive the X2 window highlight
    -- instead of sorting, so they keep the default cursor.
    DBMS_OUTPUT.PUT_LINE('section table thead th { cursor:pointer;'
        || ' user-select:none; }');
    DBMS_OUTPUT.PUT_LINE('section table[data-nosort] thead th { cursor:default; }');
    DBMS_OUTPUT.PUT_LINE('section table thead th[data-w] { cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('thead th.asc::after  { content:" \2191"; color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('thead th.desc::after { content:" \2193"; color:var(--accent); }');
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
    -- Top-SQL text cells: wrap freely and take the leftover column width
    -- (the numeric columns are all white-space:nowrap).
    DBMS_OUTPUT.PUT_LINE('td.sqltext {'
        || ' white-space:normal; word-break:break-word; min-width:320px; }');
    -- sql-pool SQL_ID cell: keep the id and its copy button on one line
    -- instead of the button wrapping under the id.
    DBMS_OUTPUT.PUT_LINE('td.sqlid-cell { white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('td a { color:var(--accent); text-decoration:none; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('td a:hover { text-decoration:underline; }');

    -- Severity rows: subtle tinted background + colored left rule
    DBMS_OUTPUT.PUT_LINE('tr.crit { background:var(--crit-bg); }'
        || ' tr.crit td:first-child { box-shadow:inset 3px 0 0 var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn { background:var(--warn-bg); }'
        || ' tr.warn td:first-child { box-shadow:inset 3px 0 0 var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok   { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info { background:var(--info-bg); }'
        || ' tr.info td:first-child { box-shadow:inset 3px 0 0 var(--info); }');
    DBMS_OUTPUT.PUT_LINE('tr.skip { color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('tr.imp, tr.note { background:transparent; }'
        || ' tr.imp td, tr.note td { color:var(--muted); }');
    -- v1.5.0 findings rollup: non-canonical twins are muted, family
    -- members under a movers lead row are indented, and the table-wide
    -- shift note (04/05) reads as a callout.
    DBMS_OUTPUT.PUT_LINE('tr.twin td { color:var(--muted); }'
        || ' tr.twin td:first-child { box-shadow:none; }'
        || ' tr.twin { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.member td:first-child { padding-left:26px; }');
    DBMS_OUTPUT.PUT_LINE('.movers-list li.twin { color:var(--muted); }');
    -- Phase 3 cross-links between sections (07 -> 02/03/04, 08 -> 07,
    -- 06 <-> 11 / 18).  Hidden by the chrome JS when the target id is
    -- absent; a jumped-to card gets the same transient outline as a row.
    DBMS_OUTPUT.PUT_LINE('.xlink { font-size:10px; font-weight:700; letter-spacing:0.04em;'
        || ' color:var(--accent); text-decoration:none; margin-left:6px;'
        || ' white-space:nowrap; opacity:.85; }');
    DBMS_OUTPUT.PUT_LINE('.xlink:hover { text-decoration:underline; opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('.xlink[hidden] { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.xlinks { display:inline-flex; gap:2px; margin-left:4px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-card.jump-hi, .hero-card.jump-hi, div.jump-hi {'
        || ' outline:2px solid var(--crit); outline-offset:2px; }');
    DBMS_OUTPUT.PUT_LINE('.wchip em { font-style:normal; color:var(--ink-soft); font-weight:600; }');
    -- Phase 5: the SQL Monitor pool's detail row reads as part of its
    -- statement row (no rule between them, tighter padding).
    DBMS_OUTPUT.PUT_LINE('#sqlmon-pool tbody tr:not(.sqlmon-detail) > td { border-bottom:0; padding-bottom:4px; }'
        || ' #sqlmon-pool tr.sqlmon-detail > td { padding-top:0; }'
        || ' #sqlmon-pool tr.sqlmon-detail > td > details > summary { font-size:11px; }');
    DBMS_OUTPUT.PUT_LINE('.shift-note { font-size:12px; color:var(--ink-soft);'
        || ' background:var(--warn-bg); border-left:3px solid var(--warn);'
        || ' padding:6px 10px; border-radius:6px; margin:6px 0 8px; }');

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
    -- "improved": moved in the good direction. Deliberately quiet -- an
    -- outlined green badge, no row tint, so it never reads as a finding.
    DBMS_OUTPUT.PUT_LINE('.badge.imp { background:transparent; color:var(--ok);'
        || ' box-shadow:inset 0 0 0 1px var(--ok-bg); }');
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
        || ' white-space:normal; overflow-wrap:break-word;'
        || ' max-width:320px; vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('#day-profile td:first-child, #windows-table td { white-space:nowrap; }');
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
    -- position/z-index: charts must paint UNDER the sticky h2 and thead
    -- (T2).  z-index:0 makes each chart wrapper its own stacking context
    -- at level 0, below the heading (6) and the sticky header row (4).
    DBMS_OUTPUT.PUT_LINE('.chart-wrap {'
        || ' position:relative; z-index:0;'
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
    -- F5: hero deltas read direction from the glyph, not from red/green.
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.up   { color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.hero-card .delta.down { color:var(--ink); }');
    -- B6: per-card "vs prior mean ... / range ..." caption line (section 08).
    DBMS_OUTPUT.PUT_LINE('.hero-card .hc-delta, .hc-delta {'
        || ' font-size:11.5px; color:var(--muted); line-height:1.45;'
        || ' font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.hc-delta b { color:var(--ink); font-weight:700; }');
    -- Generic full-width horizontal-bar SVG (section 08 and friends).
    DBMS_OUTPUT.PUT_LINE('svg.hbars { display:block; width:100%; height:42px; }');

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
    -- Facelift chrome.  Everything below is the CSS half of the
    -- hook contract between _style.sql / 00_params.sql (which own the
    -- page-level JS) and the numbered sections (which only emit markup
    -- carrying these classes / data-attributes).  Grouped by feature.
    -- =========================================================

    -- T1: long-tail collapse.  Sections tag the uninteresting tail of a
    -- table tr[data-tail="Y"] and emit a .expander[data-for=<table id>]
    -- right after the table; the delegated click in 00_params.sql adds
    -- .open to the table.  Hidden by default, so a report opened with JS
    -- disabled still shows every headline row (and print un-hides them).
    DBMS_OUTPUT.PUT_LINE('tr[data-tail="Y"] { display:none; }');
    DBMS_OUTPUT.PUT_LINE('table.open tr[data-tail="Y"] { display:table-row; }');
    DBMS_OUTPUT.PUT_LINE('.expander {'
        || ' display:inline-block; cursor:pointer; user-select:none;'
        || ' color:var(--accent); font-size:12px; font-weight:700;'
        || ' letter-spacing:0.01em; padding:8px 9px; }');
    DBMS_OUTPUT.PUT_LINE('.expander:hover { text-decoration:underline; }');

    -- T5: heat tint on a value cell, graded by how far it deviates
    -- (1 = mild/amber, 2 = strong, 3 = extreme).  color-mix keeps the
    -- tint derived from the severity tokens, so dark mode follows for
    -- free (the tokens are re-declared in the body.dark block above).
    DBMS_OUTPUT.PUT_LINE('td[data-dev="1"] {'
        || ' background:color-mix(in srgb, var(--warn) 12%, transparent); }');
    DBMS_OUTPUT.PUT_LINE('td[data-dev="2"] {'
        || ' background:color-mix(in srgb, var(--crit) 14%, transparent); }');
    DBMS_OUTPUT.PUT_LINE('td[data-dev="3"] {'
        || ' background:color-mix(in srgb, var(--crit) 28%, transparent); }');

    -- X2: cross-report window highlight.  Any element carrying data-w=<N>
    -- (window offset; 0 = current) lights up when that window is selected
    -- by clicking a per-window th or a masthead .wchip.  The class is put
    -- on / taken off by the JS in 00_params.sql, which also broadcasts the
    -- awr:window CustomEvent for chart sections to draw their own markArea.
    DBMS_OUTPUT.PUT_LINE('th[data-w], .wchip[data-w] { cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('[data-w].hl {'
        || ' outline:2px solid var(--accent); outline-offset:-2px;'
        || ' background:color-mix(in srgb, var(--accent) 12%, transparent); }');
    -- Masthead clickable window chips + the one-line usage hint under them.
    DBMS_OUTPUT.PUT_LINE('header.report .windows-chips {'
        || ' display:flex; flex-wrap:wrap; gap:6px; margin:6px 0 2px; }');
    DBMS_OUTPUT.PUT_LINE('.wchip {'
        || ' display:inline-flex; align-items:baseline; gap:6px;'
        || ' font-size:11px; color:var(--ink-soft); white-space:nowrap;'
        || ' background:var(--panel-2); border:1px solid var(--hairline);'
        || ' border-radius:999px; padding:3px 10px;'
        || ' transition:color .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('.wchip b {'
        || ' color:var(--ink); font-weight:700;'
        || ' font-variant-numeric:tabular-nums; }');
    DBMS_OUTPUT.PUT_LINE('.wchip:hover { border-color:var(--accent); color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.wchip.cur {'
        || ' background:var(--accent-bg); border-color:var(--accent);'
        || ' color:var(--accent-deep); }');
    DBMS_OUTPUT.PUT_LINE('.wchip.cur b { color:var(--accent-deep); }');
    -- Emitted after .wchip.cur so a selected current-window chip still
    -- reads as selected (both selectors are 0,2,0 -- source order decides).
    DBMS_OUTPUT.PUT_LINE('.wchip.hl {'
        || ' background:color-mix(in srgb, var(--accent) 22%, transparent); }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-hint {'
        || ' font-size:10.5px; color:var(--muted); margin:2px 0 4px;'
        || ' letter-spacing:0.02em; }');
    -- v1.5.0: the dated chip list is folded behind a one-line summary
    -- (<details>), so the strip reads as caption + chart by default.
    DBMS_OUTPUT.PUT_LINE('header.report .windows-more { margin:4px 0 2px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-more > summary {'
        || ' cursor:pointer; list-style:none; font-size:11.5px; color:var(--ink-soft);'
        || ' text-transform:none; letter-spacing:0; font-weight:400;'
        || ' display:flex; flex-wrap:wrap; gap:6px 12px; align-items:baseline; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-more > summary::-webkit-details-marker { display:none; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-more > summary .w-toggle {'
        || ' color:var(--accent-deep); font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('header.report .windows-more[open] > summary .w-toggle .closed,'
        || ' header.report .windows-more:not([open]) > summary .w-toggle .opened { display:none; }');

    -- B5: "sigma is approximately zero" pill -- a flat-baseline marker.
    -- Grey like .badge.skip but neither italic nor upper-cased, because it
    -- carries a literal glyph rather than a severity word.
    DBMS_OUTPUT.PUT_LINE('.badge.sig {'
        || ' background:var(--skip-bg); color:var(--skip);'
        || ' font-style:normal; text-transform:none; letter-spacing:0;'
        || ' font-weight:600; }');

    -- Badge for an informational counter that moved ("noted"): grey,
    -- outlined, never a highlight.
    DBMS_OUTPUT.PUT_LINE('.badge.note {'
        || ' background:transparent; color:var(--skip);'
        || ' box-shadow:inset 0 0 0 1px var(--skip-bg); }');

    -- C1: tab bars.  A .tabs[data-tabs=G] bar of [data-t] spans switches
    -- the sibling .tabpanel[data-tabs=G][data-t=...] panels.
    DBMS_OUTPUT.PUT_LINE('.tabs {'
        || ' display:flex; flex-wrap:wrap; gap:2px; margin:14px 0 0;'
        || ' border-bottom:1px solid var(--rule); }');
    DBMS_OUTPUT.PUT_LINE('.tabs [data-t] {'
        || ' cursor:pointer; user-select:none; padding:6px 12px;'
        || ' font-size:12px; font-weight:600; color:var(--muted);'
        || ' border-bottom:2px solid transparent; margin-bottom:-1px; }');
    DBMS_OUTPUT.PUT_LINE('.tabs [data-t]:hover { color:var(--ink); }');
    -- Phase 4: the tabs are real <button role="tab"> elements now.
    DBMS_OUTPUT.PUT_LINE('.tabs button[data-t] { font:inherit; font-size:12px; font-weight:600;'
        || ' background:none; border:0; border-bottom:2px solid transparent;'
        || ' color:var(--muted); border-radius:0; }');
    DBMS_OUTPUT.PUT_LINE('button.wchip { font:inherit; cursor:pointer; }');
    -- Phase 4: keyboard focus ring for every interactive element, the
    -- skip link, the tap-to-pin tooltip, reduced motion, dark-mode chip
    -- contrast, and always-visible copy / permalink affordances on touch.
    DBMS_OUTPUT.PUT_LINE(':focus-visible { outline:2px solid var(--accent); outline-offset:2px; }');
    DBMS_OUTPUT.PUT_LINE('th[tabindex]:focus-visible { outline-offset:-2px; }');
    DBMS_OUTPUT.PUT_LINE('a.skip { position:absolute; left:8px; top:-40px; z-index:100;'
        || ' padding:6px 10px; border-radius:6px; background:var(--accent);'
        || ' color:#fff; font-weight:700; text-decoration:none; }');
    DBMS_OUTPUT.PUT_LINE('a.skip:focus { top:8px; }');
    DBMS_OUTPUT.PUT_LINE('.sr-only { position:absolute; width:1px; height:1px; padding:0;'
        || ' margin:-1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }');
    DBMS_OUTPUT.PUT_LINE('.tip { position:absolute; z-index:60; max-width:320px;'
        || ' font-size:12px; line-height:1.4; color:var(--ink);'
        || ' background:var(--panel); border:1px solid var(--rule); border-radius:8px;'
        || ' padding:6px 10px; box-shadow:0 6px 18px rgba(0,0,0,.14); }');
    DBMS_OUTPUT.PUT_LINE('[title]:not(a):not(button):not(th):not(summary) { cursor:help; }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-reduced-motion: reduce) {'
        || ' *, *::before, *::after { transition:none !important; animation:none !important;'
        || ' scroll-behavior:auto !important; } }');
    DBMS_OUTPUT.PUT_LINE('@media screen { body.dark .chip.on {'
        || ' background:var(--accent-bg); color:var(--accent-deep); border-color:var(--accent); }'
        || ' body.dark thead th { color:var(--ink-soft); } }');
    DBMS_OUTPUT.PUT_LINE('.copy-btn:focus-visible, h2 .permalink:focus-visible {'
        || ' opacity:1; pointer-events:auto; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) {'
        || ' pre > .copy-btn, .codewrap > .copy-btn { opacity:1; pointer-events:auto; }'
        || ' h2 .permalink { opacity:1; } }');
    DBMS_OUTPUT.PUT_LINE('.tabs [data-t].on {'
        || ' color:var(--accent); border-bottom-color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('.tabpanel { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.tabpanel.on { display:block; }');

    -- C4: copy affordances.  .copy-btn sits absolutely in the top-right of
    -- a positioned pre/code block and only materializes on hover; .tbl-tools
    -- is the small right-aligned CSV / Markdown toolbar the JS injects above
    -- every section table with a thead; .permalink is the hover-only "#"
    -- anchor appended to each section heading.
    DBMS_OUTPUT.PUT_LINE('pre.sql, pre.copyable, .codewrap { position:relative; }');
    -- Inline by default (table cells, headings); absolutely positioned and
    -- hover-revealed only inside a positioned pre / .codewrap block.
    DBMS_OUTPUT.PUT_LINE('.copy-btn {'
        || ' font:inherit; font-size:10.5px; font-weight:700; letter-spacing:0.04em;'
        || ' text-transform:uppercase; padding:1px 6px; border-radius:6px;'
        || ' border:1px solid var(--hairline); background:var(--panel);'
        || ' color:var(--muted); cursor:pointer; vertical-align:middle;'
        || ' transition:opacity .12s,color .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('pre > .copy-btn, .codewrap > .copy-btn {'
        || ' position:absolute; top:6px; right:6px; padding:3px 8px;'
        || ' opacity:0; pointer-events:none; z-index:2; }');
    DBMS_OUTPUT.PUT_LINE('pre:hover > .copy-btn, .codewrap:hover > .copy-btn, .copy-btn:focus {'
        || ' opacity:1; pointer-events:auto; }');
    DBMS_OUTPUT.PUT_LINE('.copy-btn:hover { color:var(--accent); border-color:var(--accent); }');
    -- T6: inline |z| bar in the Biggest-movers table (07).
    DBMS_OUTPUT.PUT_LINE('.zbar { display:inline-block; height:8px; vertical-align:middle;'
        || ' border-radius:2px; margin-right:6px; }');
    DBMS_OUTPUT.PUT_LINE('.tbl-tools {'
        || ' display:flex; justify-content:flex-end; gap:6px;'
        || ' margin:10px 0 -8px; }');
    DBMS_OUTPUT.PUT_LINE('.tbl-tools .tool-btn {'
        || ' font:inherit; font-size:11px; font-weight:600; line-height:1.4;'
        || ' padding:2px 8px; border-radius:6px; cursor:pointer;'
        || ' border:1px solid var(--hairline); background:var(--panel);'
        || ' color:var(--muted);'
        || ' transition:color .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('.tbl-tools .tool-btn:hover {'
        || ' color:var(--accent); border-color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('h2 .permalink {'
        || ' margin-left:auto; font-size:13px; font-weight:700;'
        || ' color:var(--muted); text-decoration:none; cursor:pointer;'
        || ' opacity:0; transition:opacity .12s,color .12s; }');
    DBMS_OUTPUT.PUT_LINE('h2:hover .permalink, h2 .permalink:focus { opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('h2 .permalink:hover { color:var(--accent); }');

    -- Small mono letter chip (dimension / flag markers in the sections).
    DBMS_OUTPUT.PUT_LINE('.chip {'
        || ' display:inline-block; border:1px solid var(--rule);'
        || ' border-radius:4px; font-size:10px; font-weight:700;'
        || ' line-height:1.5; padding:0 4px; color:var(--muted);'
        || ' text-transform:none; letter-spacing:0;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('.chip.on {'
        || ' background:var(--accent); border-color:var(--accent); color:#fff; }');

    -- T8: methodology disclosure.  The rail JS folds each section intro
    -- paragraph into details.method, keeping its first sentence inline on
    -- the heading as h2 .h2sub (styled with the h2 rules above).
    DBMS_OUTPUT.PUT_LINE('details.method { margin:0 0 12px; }');
    DBMS_OUTPUT.PUT_LINE('details.method > summary {'
        || ' cursor:pointer; list-style:none; padding:2px 0;'
        || ' color:var(--accent); font-size:12px; font-weight:600;'
        || ' text-transform:none; letter-spacing:0; }');
    DBMS_OUTPUT.PUT_LINE('details.method > summary::-webkit-details-marker { display:none; }');
    DBMS_OUTPUT.PUT_LINE('details.method > summary::before { content:"\25B8 "; }');
    DBMS_OUTPUT.PUT_LINE('details.method[open] > summary::before { content:"\25BE "; }');
    DBMS_OUTPUT.PUT_LINE('details.method > p {'
        || ' font-size:12px; color:var(--muted); margin:4px 0 0; }');

    -- =========================================================
    -- Rail additions: filter box (T4), per-section finding counts and the
    -- next-finding control (C2), the narrow-screen top bar (B8).
    -- =========================================================
    -- The section links now live in a .rail-list wrapper so the narrow
    -- layout can drop them into a dropdown panel.  Every existing selector
    -- (nav.toc a / nav.toc b, the rail JS) is a
    -- descendant match, so wrapping them changes nothing on desktop.
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-list {'
        || ' display:flex; flex-direction:column; gap:2px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-filter {'
        || ' position:relative; margin:0 2px 8px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-filter input {'
        || ' width:100%; font:inherit; font-size:12px;'
        || ' padding:5px 38px 5px 9px; border-radius:7px;'
        || ' border:1px solid var(--rule); background:var(--panel);'
        || ' color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-filter input:focus {'
        || ' outline:none; border-color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-filter .kbd {'
        || ' position:absolute; right:6px; top:50%; transform:translateY(-50%);'
        || ' font-size:9.5px; color:var(--muted); pointer-events:none;'
        || ' border:1px solid var(--hairline); border-radius:4px;'
        || ' padding:0 4px; background:var(--panel-2); }');
    -- Rail link dimmed because the row filter left its section with no
    -- visible rows.
    DBMS_OUTPUT.PUT_LINE('nav.toc a.dim { opacity:.35; }');
    -- C2: crit / warn row counts appended to each rail link.
    DBMS_OUTPUT.PUT_LINE('nav.toc a .cnt {'
        || ' margin-left:auto; font-size:9.5px; font-weight:700;'
        || ' line-height:1.7; padding:0 5px; border-radius:999px;'
        || ' font-variant-numeric:tabular-nums; flex:none; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .cnt + .cnt { margin-left:3px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .cnt.c { background:var(--crit-bg); color:var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a .cnt.w { background:var(--warn-bg); color:var(--warn); }');
    -- C2: "next large finding" jump control (J / K also work anywhere).
    DBMS_OUTPUT.PUT_LINE('nav.toc .next-finding {'
        || ' display:flex; align-items:center; justify-content:space-between;'
        || ' gap:8px; font:inherit; font-size:11px; font-weight:600;'
        || ' text-align:left; padding:6px 10px; border-radius:8px;'
        || ' border:1px dashed var(--rule); background:transparent;'
        || ' color:var(--muted); cursor:pointer;'
        || ' transition:color .12s,border-color .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .next-finding:hover {'
        || ' color:var(--accent); border-color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc .next-finding .keys {'
        || ' font-size:9.5px; letter-spacing:0.08em; color:var(--muted);'
        || ' border:1px solid var(--hairline); border-radius:4px;'
        || ' padding:0 4px; flex:none; }');
    -- Transient outline on the row the J / K jump landed on.
    DBMS_OUTPUT.PUT_LINE('tr.jump-hi td {'
        || ' box-shadow:inset 0 2px 0 var(--crit), inset 0 -2px 0 var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('tr.jump-hi td:first-child {'
        || ' box-shadow:inset 0 2px 0 var(--crit), inset 0 -2px 0 var(--crit),'
        || ' inset 2px 0 0 var(--crit); }');
    DBMS_OUTPUT.PUT_LINE('tr.jump-hi td:last-child {'
        || ' box-shadow:inset 0 2px 0 var(--crit), inset 0 -2px 0 var(--crit),'
        || ' inset -2px 0 0 var(--crit); }');
    -- Narrow-screen-only rail bits, hidden on desktop.
    DBMS_OUTPUT.PUT_LINE('nav.toc .rail-cur, nav.toc .rail-menu-btn { display:none; }');

    -- B8: below 980px the rail stops being a sidebar and becomes a sticky
    -- top bar: brand + current section (fed by the scrollspy) + a hamburger
    -- that drops the section list down as a panel.  --navh (written by the
    -- rail JS) keeps the sticky h2 / thead clear of the bar.
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) {'
        -- order:0 lifts the bar above the masthead (it is order:2 on
        -- desktop, where it is a fixed sidebar and the order is moot).
        || ' nav.toc { order:0; position:sticky; top:0; left:auto; bottom:auto;'
        || '   width:auto; overflow:visible; z-index:30;'
        || '   flex-direction:row; flex-wrap:nowrap; align-items:center;'
        || '   gap:8px; border-right:0;'
        || '   border-bottom:1px solid var(--hairline);'
        || '   border-radius:0; margin:0 -20px; padding:8px 20px; }'
        || ' nav.toc .rail-brand { border-bottom:0; padding:0; margin:0;'
        || '   flex:0 0 auto; gap:6px; }'
        || ' nav.toc .rail-brand > span { font-size:10px; }'
        || ' nav.toc .rail-cur { display:block; flex:1 1 auto; min-width:0;'
        || '   font-size:12px; font-weight:600; color:var(--ink);'
        || '   overflow:hidden; text-overflow:ellipsis; white-space:nowrap;'
        || '   text-transform:none; letter-spacing:0; }'
        || ' nav.toc .rail-menu-btn { display:flex; flex:none;'
        || '   align-items:center; justify-content:center;'
        || '   width:28px; height:26px; padding:0; border-radius:7px;'
        || '   border:1px solid var(--rule); background:var(--panel);'
        || '   color:var(--ink); font:inherit; font-size:14px; cursor:pointer; }'
        -- The row filter rides inside the open hamburger panel (absolute,
        -- above the list, which reserves its height with padding-top).
        || ' nav.toc .rail-filter { display:none; }'
        || ' nav.toc.menu-open .rail-filter { display:block; position:absolute;'
        || '   top:calc(100% + 8px); left:20px; right:20px; z-index:32; margin:0; }'
        || ' nav.toc .rail-list { display:none; position:absolute;'
        || '   top:100%; left:0; right:0; z-index:31;'
        || '   background:var(--panel-2);'
        || '   border-bottom:1px solid var(--hairline);'
        || '   box-shadow:0 8px 18px rgba(0,0,0,.10);'
        || '   padding:48px 20px 12px; max-height:70vh; overflow:auto; }'
        || ' nav.toc.menu-open .rail-list { display:flex; }'
        -- The three view toggles collapse into one "View" button whose
        -- popover holds them (plus the next-finding control) stacked.
        || ' nav.toc .rail-foot { margin-top:0; flex:none; position:static;'
        || '   padding:0; flex-direction:row; gap:4px; }'
        || ' nav.toc .view-btn { display:flex; align-items:center; gap:4px;'
        || '   font:inherit; font-size:11px; font-weight:700; min-height:32px;'
        || '   padding:0 10px; border-radius:7px; border:1px solid var(--rule);'
        || '   background:var(--panel); color:var(--ink); cursor:pointer; }'
        || ' nav.toc .view-btn[aria-expanded="true"] { border-color:var(--accent); color:var(--accent); }'
        || ' nav.toc .view-panel { display:none; position:absolute; right:12px;'
        || '   top:calc(100% + 6px); z-index:33; flex-direction:column; gap:6px;'
        || '   min-width:220px; padding:10px; border-radius:10px;'
        || '   background:var(--panel); border:1px solid var(--hairline);'
        || '   box-shadow:0 8px 18px rgba(0,0,0,.14); }'
        || ' nav.toc .rail-foot.open .view-panel { display:flex; }'
        || ' nav.toc .mode-btn { min-height:34px; }'
        -- Tap targets: 32px minimum for the small controls below 980px.
        || ' .tabs [data-t], .tbl-tools .tool-btn, .copy-btn, .expander,'
        || ' details > summary, .chipbar button, nav.toc .theme-icon-btn,'
        || ' nav.toc .rail-menu-btn { min-height:32px; }'
        || ' nav.toc .theme-icon-btn, nav.toc .rail-menu-btn { width:32px; height:32px; }'
        || ' }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 700px) {'
        || ' h2 .h2sub { display:none; }'
        -- headings wrap on phones (badges + permalink no longer push the
        -- page wider than the viewport); the sticky offset (--h2h) is
        -- measured after layout, so a two-line heading still stacks right.
        || ' section > h2 { white-space:normal; flex-wrap:wrap; row-gap:4px; }'
        || ' nav.toc .rail-brand > span { display:none; } }');

    -- =========================================================
    -- Print
    -- =========================================================
    -- The dark palette lives inside @media screen, so print always renders
    -- the light tokens declared on :root -- nothing to force here.  What
    -- does need undoing: the sticky headers, every interactive affordance,
    -- and the two collapse mechanisms (long-tail rows and the methodology
    -- disclosure) whose content must be on the printed page.
    DBMS_OUTPUT.PUT_LINE('@media print {'
        || ' nav.toc { display:none; position:static; }'
        || ' body { max-width:none; padding:0 0 24px; background:#fff; }'
        || ' section { border:0; padding:12px 0; break-before:page; }'
        || ' main > section:first-of-type, body > section:first-of-type { break-before:auto; }'
        || ' header.report { border:0; padding-top:0; }'
        || ' .chart-wrap { break-inside:avoid; }'
        || ' h2 { break-after:avoid; position:static; padding-top:0;'
        || '   background:transparent; }'
        || ' section table thead th { position:static; }'
        || ' .tbl-tools, .copy-btn, .permalink, .expander, .tag,'
        || ' .mode-note, .next-finding, .windows-hint,'
        || ' .theme-icon-btn { display:none !important; }'
        || ' details.method > summary { display:none; }'
        || ' details.method > * { display:block; }'
        || ' tr[data-tail="Y"] { display:table-row !important; }'
        || ' .tblwrap.scroll { overflow:visible; box-shadow:none; }'
        || ' .tblwrap.scroll tr > :first-child { position:static; }'
        || ' }');

    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
