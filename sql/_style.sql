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
        || ' --track:#eef0f3;'
        || ' --cell-bar-bg:rgba(90,67,223,0.10);'
        -- v1.6.0: ONE accent, indigo, and it means Current (the Current
        -- column band, the Current chip, the Current bar).  Severity colour
        -- lives only on dots, the Delta text and the 2px row marker.
        || ' --accent:#5a43df;      --accent-deep:#4633c4;  --accent-bg:#ece9fc;'
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
        -- v1.6.0 (Mock D) tokens: the mock's names, aliased onto the
        -- workbench palette where one exists, so the band glyph / guide CSS
        -- below is lifted from design/report_mocks_src/hybrid/style.css as is.
        || ' --ink-4:#a3acb9;'
        || ' --zone1:#bec7d2; --zone2:#dce1e7; --tick:#aab3bf; --mean:#4f5b6c; --bar:#c5ccd6;'
        || ' --acc:#5a43df; --acc-ink:#4633c4; --acc-band:rgba(90,67,223,.07); --acc-soft:rgba(90,67,223,.11);'
        || ' --crit-dot:#d83a2f; --warn-dot:#e09b1c; --imp:#08777d;'
        || ' --mk:#3a4556; --mkline:rgba(44,54,68,.26); --flagbg:#e8ebf0;'
        || ' --hov:rgba(23,32,44,.05); --pin:rgba(178,112,0,.10); --flash:rgba(90,67,223,.22);'
        -- spacing scale: every gap between and inside sections comes from here
        || ' --s1:4px; --s2:8px; --s3:12px; --s4:16px; --s5:24px; --s6:32px; --s7:48px; --s8:64px;'
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
        || ' --track:#1f2630;'
        || ' --cell-bar-bg:rgba(167,150,255,0.16);'
        || ' --accent:#a796ff;      --accent-deep:#bdb0ff;  --accent-bg:#231f3d;'
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
        || ' --ink-4:#566070;'
        || ' --zone1:#4a5565; --zone2:#2e3744; --tick:#5c6778; --mean:#c3cbd6; --bar:#3e4757;'
        || ' --acc:#a796ff; --acc-ink:#bdb0ff; --acc-band:rgba(167,150,255,.085); --acc-soft:rgba(167,150,255,.14);'
        || ' --crit-dot:#ff6255; --warn-dot:#f0a63a; --imp:#4cc7c4;'
        || ' --mk:#c3ccd8; --mkline:rgba(202,210,221,.24); --flagbg:#222a35;'
        || ' --hov:rgba(255,255,255,.045); --pin:rgba(242,176,76,.12); --flash:rgba(167,150,255,.22);'
        || ' } }');

    -- =========================================================
    -- Reset + body.  The body is a flex column (visual order of the
    -- sections is set with order: below); the fixed sidebar is cleared
    -- with padding-left.
    -- =========================================================
    -- The Mock D alias tokens live on body, NOT :root: a var() inside a
    -- custom property resolves where it is declared, so aliases declared
    -- on :root would freeze the LIGHT values and ignore body.dark.
    DBMS_OUTPUT.PUT_LINE('body { --surface:var(--panel); --surface-2:var(--panel-2); --bg:var(--paper);'
        || ' --ink-2:var(--ink-soft); --ink-3:var(--muted);'
        || ' --line:var(--line-soft); --line-2:var(--hairline); --row-bg:var(--panel); }');
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
    DBMS_OUTPUT.PUT_LINE('main > *, body > section, body > header.report, body > footer.report {'
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
    DBMS_OUTPUT.PUT_LINE('main > *, body > section { order:3; }');
    DBMS_OUTPUT.PUT_LINE('footer.report      { order:4; }');

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
        || ' margin:12px 10px 4px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b::before { content:none; }');
    -- Section links
    DBMS_OUTPUT.PUT_LINE('nav.toc a {'
        || ' display:flex; align-items:center; gap:9px;'
        || ' padding:4px 10px; border-radius:7px;'
        || ' color:var(--ink-soft); text-decoration:none; font-weight:500;'
        || ' transition:color .12s, background .12s; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { background:var(--paper); color:var(--ink); }');
    -- The active link reads through its background and weight only: no
    -- left bar or inset shadow (on the rounded pill it drew a crescent).
    -- lint check 32 keeps every rail-link state free of one.
    DBMS_OUTPUT.PUT_LINE('nav.toc a.on {'
        || ' background:var(--panel); color:var(--ink);'
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

    -- "+ N more in All sections" line the rail JS appends (Summary view).
    DBMS_OUTPUT.PUT_LINE('nav.toc a.more-sections { display:none; color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('body.vs nav.toc a.more-sections { display:flex; }');

    -- =========================================================
    -- Views (v1.6.0): Summary / Timeline / All sections replace Normal /
    -- Full.  The early view script in 00_params.sql puts exactly one of
    -- body.vs / body.vt / body.va on the body before first paint (hash
    -- "#view=" wins, else localStorage "awr-view", else Summary).  An
    -- element opts into views with class "vw" plus one in-s / in-t / in-a
    -- class per view it belongs to (a section, or anything inside one); an
    -- element with no "vw" class shows in every view (the guide, the About
    -- fold).  With JS off no body class exists and everything shows.
    -- Rail links whose target is hidden in the current view are dimmed
    -- (.vdim, computed by the chrome JS; a click switches view).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('body.vs .vw:not(.in-s), body.vt .vw:not(.in-t), body.va .vw:not(.in-a) { display:none; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a.vdim { opacity:.45; }'
        || ' nav.toc a.vdim:hover { opacity:.85; }'
        || ' nav.toc b.vdim { opacity:.5; }');
    DBMS_OUTPUT.PUT_LINE('.view-note {'
        || ' display:none; order:3; margin:var(--s5) 0 0 0; padding:var(--s3) var(--s4); border-radius:10px;'
        || ' border:1px dashed var(--rule); background:transparent;'
        || ' color:var(--muted); font-size:12.5px; line-height:1.5; }');
    DBMS_OUTPUT.PUT_LINE('body.vs .view-note { display:block; }');
    DBMS_OUTPUT.PUT_LINE('.view-note button {'
        || ' font:inherit; font-size:12px; font-weight:600;'
        || ' padding:3px 10px; border-radius:6px;'
        || ' border:1px solid var(--rule); background:var(--panel); color:var(--ink);'
        || ' cursor:pointer; margin-left:6px; }');
    -- v1.6.0 evidence library (Summary view only).  Every section with
    -- class "lib" is one row of a single panel: chevron, title (span.lt,
    -- wrapped by the chrome JS), its one-line status (span.ls, set by the
    -- section through window.AWR_ls) and the counts; a click on the row
    -- toggles .lopen and shows the section in place.  Rows sort by the
    -- section's --os after the "Evidence library" heading (#s-lib, 07);
    -- the reference sections and the footer follow.  All sections (and JS
    -- off) show every section in full, unchanged.
    DBMS_OUTPUT.PUT_LINE('body.vs main > #s-lib { order:10; }'
        || ' body.vs main > section.lib { order:calc(10 + var(--os, 9)); }'
        || ' body.vs main > .view-note, body.vs main > #guide, body.vs main > #about { order:30; }'
        || ' body.vs footer.report { order:40; }');
    DBMS_OUTPUT.PUT_LINE('body.vs main > section.lib { margin:0; border-radius:0; border-top-width:0; padding:0 var(--s5); }'
        || ' body.vs main > section.lib.lib-first { margin-top:var(--s2); border-top-width:1px; border-radius:10px 10px 0 0; }'
        || ' body.vs main > section.lib.lib-last { border-radius:0 0 10px 10px; }'
        || ' body.vs main > section.lib.lib-first.lib-last { border-radius:10px; }');
    DBMS_OUTPUT.PUT_LINE('body.vs main > section.lib:not(.lopen) > :not(h2) { display:none !important; }');
    DBMS_OUTPUT.PUT_LINE('body.vs main > section.lib > h2 { cursor:pointer; flex-wrap:nowrap; align-items:center;'
        || ' margin:0; padding:var(--s4) 0; border-bottom:0; font-size:15px; line-height:22px; }'
        || ' body.vs main > section.lib.lopen > h2 { border-bottom:1px solid var(--line-soft); margin-bottom:var(--s3); }'
        || ' body.vs main > section.lib > h2:hover > .lt { color:var(--ink); text-decoration:underline;'
        || ' text-decoration-color:var(--hairline); text-underline-offset:3px; }'
        || ' body.vs main > section.lib > h2 .permalink { display:none; }'
        || ' body.vs main > section.lib > h2 > .h2sub { order:1; flex:1 1 auto; }'
        || ' body.vs main > section.lib > h2:has(> .ls) > .h2sub { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.vs main > section.lib > h2 > .lt { flex:0 0 200px; display:inline-flex; align-items:center; gap:10px; }'
        || ' body.vs main > section.lib > h2 > .lt::before { content:""; flex:none; width:7px; height:7px;'
        || ' border-right:1.5px solid var(--muted); border-bottom:1.5px solid var(--muted);'
        || ' transform:rotate(-45deg); transition:transform .15s; margin:0 4px 0 3px; }'
        || ' body.vs main > section.lib.lopen > h2 > .lt::before { transform:rotate(45deg); }');
    DBMS_OUTPUT.PUT_LINE('h2 > .ls { order:1; flex:1 1 auto; min-width:0; font-size:13.5px; font-weight:400;'
        || ' letter-spacing:0; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }'
        || ' h2 > .ls code { font-size:12.5px; } h2 > .ls b { font-weight:600; color:var(--ink-soft); }');
    -- A view heading (the evidence library's #s-lib, All sections' #s-all):
    -- a section holding only its h2, drawn as a plain heading, no panel.
    DBMS_OUTPUT.PUT_LINE('section.vhead { background:none; border:0; border-radius:0; padding:0; box-shadow:none; }'
        || ' section.vhead > h2 { margin:var(--s7) 0 var(--s2); padding:var(--s5) 0 0; border-bottom:0;'
        || ' border-top:1px solid var(--hairline); }'
        || ' body.va main > #s-all > h2 { margin-top:var(--s4); border-top:0; padding-top:var(--s4); }');
    -- All sections order (Mock D): the heading, then Findings, the load /
    -- metric / wait tables, SQL, storage, parameters, and the full-span
    -- charts, windows and day profile last; the reference sections and the
    -- footer follow.  Purely visual: the DOM (and JS off) keeps the driver's
    -- order.
    DBMS_OUTPUT.PUT_LINE('body.va main > #s-all { order:4; } body.va main > #findings { order:5; }'
        || ' body.va main > #load { order:6; } body.va main > #metrics { order:7; }'
        || ' body.va main > #waits-fg { order:8; } body.va main > #waits-bg { order:9; }'
        || ' body.va main > #topsql { order:10; } body.va main > #topsql-ash { order:11; }'
        || ' body.va main > #sqlmon { order:12; } body.va main > #segment-io { order:13; }'
        || ' body.va main > #file-io { order:14; } body.va main > #param-changes { order:15; }'
        || ' body.va main > #ash-timeline { order:16; } body.va main > #db-time-summary { order:17; }'
        || ' body.va main > #utilization { order:18; } body.va main > #windows { order:19; }'
        || ' body.va main > #day-profile { order:20; }'
        || ' body.va main > .view-note, body.va main > #guide, body.va main > #about { order:30; }'
        || ' body.va footer.report { order:40; }');
    -- rail sub-links: one per finding card, under Findings (07)
    DBMS_OUTPUT.PUT_LINE('nav.toc a.sub { padding-left:28px; font-size:12.5px; color:var(--muted); }');
    -- Timeline view placeholder (phase 3 of the redesign fills it).

    -- =========================================================
    -- Sections: white panels
    -- =========================================================
    -- v1.6.0: calm separation -- one panel per section, the page
    -- background between them, gaps from the spacing scale.  scroll-margin
    -- clears the sticky top bar (--navh, measured by the chrome JS);
    -- anchors INSIDE a section (rows, cards) also clear the sticky thead.
    DBMS_OUTPUT.PUT_LINE('section {'
        || ' background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:10px; padding:var(--s1) var(--s5) var(--s5);'
        || ' margin:var(--s5) 0 0; scroll-margin-top:calc(var(--navh, 0px) + var(--s4)); }');
    DBMS_OUTPUT.PUT_LINE('section tr[id], section [id].ash-sql-card, section h3[id] {'
        || ' scroll-margin-top:calc(var(--navh, 0px) + 56px); }');
    DBMS_OUTPUT.PUT_LINE('html { scroll-padding-top:calc(var(--navh, 0px) + var(--s4)); }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:24px; margin:0; }');

    -- v1.6.0: ONE section header shape -- title, a one-line plain
    -- subtitle (small.h2sub, emitted by the section) and the counts
    -- (span.meta, appended by the chrome JS) on the right.  Method notes
    -- live in the single "About this report" fold at the bottom.
    DBMS_OUTPUT.PUT_LINE('h2 {'
        || ' font-weight:600; font-size:20px; line-height:28px;'
        || ' letter-spacing:-0.015em; color:var(--ink);'
        || ' text-transform:none;'
        || ' margin:0 0 var(--s3); padding:var(--s4) 0 var(--s3); border:0;'
        || ' border-bottom:1px solid var(--line-soft);'
        || ' display:flex; flex-wrap:wrap; align-items:baseline; column-gap:var(--s4); row-gap:2px; }');
    DBMS_OUTPUT.PUT_LINE('h2 > .meta { order:2; margin-left:auto; display:flex; gap:var(--s3);'
        || ' align-items:center; font-size:12.5px; font-weight:400; color:var(--ink-soft);'
        || ' letter-spacing:0; white-space:nowrap; }'
        || ' h2 > .meta span { display:inline-flex; align-items:center; gap:6px; }'
        || ' h2 > .permalink { order:2; }');
    DBMS_OUTPUT.PUT_LINE('.dotk { display:inline-block; width:9px; height:9px; border-radius:50%; flex:none; }'
        || ' .dotk.large { background:var(--crit-dot); } .dotk.moderate { background:var(--warn-dot); }');
    -- The subtitle takes its own line under the title and ellipsizes.
    DBMS_OUTPUT.PUT_LINE('h2 .h2sub {'
        || ' order:3; flex-basis:100%; font-weight:400; font-size:13.5px; line-height:20px;'
        || ' color:var(--muted); letter-spacing:0; min-width:0; overflow:hidden;'
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
        || ' font-size:15px; letter-spacing:0; text-transform:none;'
        || ' color:var(--ink); font-weight:600; margin:var(--s6) 0 var(--s2);'
        || ' display:flex; align-items:center; gap:8px; }');

    -- Divider before each repeat chart-group block (Top SQL / segment I/O /
    -- file I/O): a rule + extra top space between one dimension's
    -- chart+detail-table and the next, without touching the section's
    -- first h3 (which follows the intro <p>, not a </details>).
    DBMS_OUTPUT.PUT_LINE('details + h3 {'
        || ' margin-top:var(--s6); padding-top:var(--s5);'
        || ' border-top:1px solid var(--line-soft); }');

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
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll thead th:first-child { background:var(--panel); z-index:5; }');
    -- band tables are wide (13 windows + the band cells): keep the name on
    -- one line and let the table scroll instead of wrapping it three times
    DBMS_OUTPUT.PUT_LINE('table:has(th.c-band) tbody td:first-child { white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('.tblwrap.scroll tbody tr:hover > td:first-child { background:var(--panel-2); }');
    DBMS_OUTPUT.PUT_LINE('table {'
        || ' width:100%; border-collapse:collapse;'
        || ' font-size:12.5px; background:transparent;'
        || ' border:0; border-radius:0;'
        || ' margin:12px 0 16px; }');
    DBMS_OUTPUT.PUT_LINE('thead th {'
        || ' background:var(--panel); color:var(--muted);'
        || ' text-align:left; padding:8px 10px;'
        || ' font-size:12px; font-weight:500; letter-spacing:0;'
        || ' text-transform:none; white-space:nowrap; vertical-align:bottom;'
        || ' border-bottom:1px solid var(--hairline); }');
    -- T2: the header row sticks just under the sticky top bar (--navh).
    DBMS_OUTPUT.PUT_LINE('section table thead th {'
        || ' position:sticky; top:var(--navh, 0px);'
        || ' z-index:4; }');
    -- T3: click-to-sort affordance.  Tables opting out carry data-nosort;
    -- per-window header cells (th[data-w]) drive the X2 window highlight
    -- instead of sorting, so they keep the default cursor.
    DBMS_OUTPUT.PUT_LINE('section table thead th { cursor:pointer;'
        || ' user-select:none; }');
    DBMS_OUTPUT.PUT_LINE('section table[data-nosort] thead th { cursor:default; }');
    DBMS_OUTPUT.PUT_LINE('section table thead th[data-w] { cursor:pointer; }');
    DBMS_OUTPUT.PUT_LINE('thead th.asc::after  { content:" \2191"; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('thead th.desc::after { content:" \2193"; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('tbody td {'
        || ' padding:8px 10px; border-bottom:1px solid var(--line-soft);'
        || ' vertical-align:middle; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:last-child td { border-bottom:0; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:var(--panel-2); --row-bg:var(--panel-2); }');
    -- indigo = Current: the Current column of every per-window table
    -- (the header cells stack the tint over an opaque panel: they are sticky)
    DBMS_OUTPUT.PUT_LINE('td[data-w="0"] { background-color:var(--acc-band); }'
        || ' th[data-w="0"], th.cur-col { background:linear-gradient(var(--acc-band),var(--acc-band)) var(--panel);'
        || ' color:var(--acc-ink); font-weight:600; }');
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
    DBMS_OUTPUT.PUT_LINE('td a { color:inherit; font-weight:600; text-decoration:underline dotted;'
        || ' text-decoration-color:var(--ink-4); text-underline-offset:3px; }');
    DBMS_OUTPUT.PUT_LINE('td a:hover { text-decoration:underline solid; text-decoration-color:var(--muted); }');

    -- Severity rows: subtle tinted background + colored left rule
    -- v1.6.0 colour diet: a finding row gets a 2px marker on its first
    -- cell, never a row fill (tr.crit / tr.warn from 07, 16 ...; rows of a
    -- band table via :has() on the band dot).
    DBMS_OUTPUT.PUT_LINE('tr.crit td:first-child, tr:has(> td.c-band .bd.s-large) > td:first-child'
        || ' { box-shadow:inset 2px 0 0 var(--crit-dot); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn td:first-child, tr:has(> td.c-band .bd.s-moderate) > td:first-child'
        || ' { box-shadow:inset 2px 0 0 var(--warn-dot); }');
    -- The fleet report includes this file too (sql/fleet/00_fleet_chrome.sql).
    -- Its fleet-owned detail tables (table.dt, never used by the single-DB
    -- sections; their cells carry the detail row's own background) keep
    -- the 3px severity-coloured bar they had before v1.6.0 instead of the
    -- 2px dot-coloured marker, which read as a stray hairline on their
    -- zero-padding first cell.  Every first cell gets a left padding so
    -- the text clears the bar and the columns stay aligned (the fleet's
    -- own "table.dt td" rule has a lower specificity).
    DBMS_OUTPUT.PUT_LINE('table.dt tr > td:first-child, table.dt tr > th:first-child { padding-left:10px; }'
        || ' table.dt tr.crit td:first-child { box-shadow:inset 3px 0 0 var(--crit); }'
        || ' table.dt tr.warn td:first-child { box-shadow:inset 3px 0 0 var(--warn); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok   { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info { background:transparent; }');
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
    DBMS_OUTPUT.PUT_LINE('.xlink { font-size:11px; font-weight:500; letter-spacing:0;'
        || ' color:var(--muted); text-decoration:none; margin-left:6px;'
        || ' white-space:nowrap; opacity:.85; }');
    DBMS_OUTPUT.PUT_LINE('.xlink:hover { text-decoration:underline; opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('.xlink[hidden] { display:none; }');
    DBMS_OUTPUT.PUT_LINE('.xlinks { display:inline-flex; gap:2px; margin-left:4px; }');
    DBMS_OUTPUT.PUT_LINE('.ash-sql-card.jump-hi, div.jump-hi {'
        || ' outline:2px solid var(--crit); outline-offset:2px; }');
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
        || ' font-size:11px; font-weight:600; letter-spacing:0;'
        || ' text-transform:none; vertical-align:middle;'
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
    -- v1.6.0: the single-DB Trend cell is a 13-bar micro strip (svg.mw,
    -- sql/lib/js_microstrip.plsql); the fleet keeps the svg.spark line.
    DBMS_OUTPUT.PUT_LINE('td.trend svg.mw { margin:0 auto; }');

    -- =========================================================
    -- Cell-bar behind the current-value column in load/sysmetric tables.
    -- v1.6.0: not drawn.  The Current column carries the accent band and
    -- the band glyph carries the comparison; the bar's 2px edge crossed
    -- the digits on the tinted cell.  02/03/13 still emit span.bg (inert).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('td.cell-bar { position:relative; }');
    DBMS_OUTPUT.PUT_LINE('td.cell-bar .bg { display:none; }');
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
    DBMS_OUTPUT.PUT_LINE('body.no-charts .chart-wrap { display:none; }');
    DBMS_OUTPUT.PUT_LINE('body.no-charts .cdn-warn { display:block !important; }');
    -- Theme-aware: var(--warn-fg) / var(--warn-border) keep the offline-charts
    -- banner legible in dark mode, where --warn-bg is near-black (F13).
    DBMS_OUTPUT.PUT_LINE('.cdn-warn {'
        || ' display:none;'
        || ' background:var(--warn-bg); color:var(--warn-fg);'
        || ' padding:8px 12px; border:1px solid var(--warn-border); border-radius:8px;'
        || ' font-size:13px; margin:6px 0; }');

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
        || ' cursor:pointer; padding:4px 0; font-weight:500; color:var(--ink-soft);'
        || ' font-size:13px; letter-spacing:0; text-transform:none; }');
    DBMS_OUTPUT.PUT_LINE('details summary:hover { color:var(--ink); }');
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
        || ' color:var(--ink-soft); font-size:13px; font-weight:500;'
        || ' letter-spacing:0; padding:8px 9px; }');
    DBMS_OUTPUT.PUT_LINE('.expander:hover { text-decoration:underline; }');

    -- X2: cross-report window highlight.  Any element carrying data-w=<N>
    -- (window offset; 0 = current) lights up when that window is selected
    -- by clicking a per-window th or a masthead .wchip.  The class is put
    -- on / taken off by the JS in 00_params.sql, which also broadcasts the
    -- awr:window CustomEvent for chart sections to draw their own markArea.
    DBMS_OUTPUT.PUT_LINE('th[data-w], .wchip[data-w] { cursor:pointer; }');
    -- A picked window is the "pinned" amber of the mock (indigo = Current).
    DBMS_OUTPUT.PUT_LINE('[data-w].hl {'
        || ' outline:2px solid var(--warn-dot); outline-offset:-2px;'
        || ' background:var(--pin); }');
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
    DBMS_OUTPUT.PUT_LINE('.wchip.hl { background:var(--pin); }');
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
        || ' color:var(--ink); border-bottom-color:var(--ink); }');
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
    DBMS_OUTPUT.PUT_LINE('.copy-btn:hover { color:var(--ink); border-color:var(--muted); }');
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
        || ' color:var(--ink); border-color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('h2 .permalink {'
        || ' font-size:13px; font-weight:700;'
        || ' color:var(--muted); text-decoration:none; cursor:pointer;'
        || ' opacity:0; transition:opacity .12s,color .12s; }');
    DBMS_OUTPUT.PUT_LINE('h2:hover .permalink, h2 .permalink:focus { opacity:1; }');
    DBMS_OUTPUT.PUT_LINE('h2 .permalink:hover { color:var(--ink); }');

    -- Small mono letter chip (dimension / flag markers in the sections).
    DBMS_OUTPUT.PUT_LINE('.chip {'
        || ' display:inline-block; border:1px solid var(--rule);'
        || ' border-radius:4px; font-size:10px; font-weight:700;'
        || ' line-height:1.5; padding:0 4px; color:var(--muted);'
        || ' text-transform:none; letter-spacing:0;'
        || ' font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('.chip.on {'
        || ' background:var(--ink); border-color:var(--ink); color:var(--panel); }');

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
        || ' color:var(--ink); border-color:var(--muted); }');
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
    -- v1.6.0 redesign ("Mock D", design/report_mock_d_hybrid.html):
    -- the top bar with the view switch, the baseline band glyph, the
    -- one Delta rule, entity links + the jump flash, the "Reading the
    -- charts" guide and the "About this report" fold.  Lifted from
    -- design/report_mocks_src/hybrid/style.css; the guide's example SVGs
    -- (sql/19_reference.sql) must stay in lockstep with these rules.
    -- =========================================================
    -- Top bar (v1.6.0): identity, the Current window, the view switch, theme
    DBMS_OUTPUT.PUT_LINE('.topbar{order:0;position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:var(--s2) var(--s4);min-height:56px;margin:0 -32px;padding:8px 32px;'
        || 'background:color-mix(in srgb,var(--paper) 90%,transparent);backdrop-filter:saturate(1.2) blur(10px);-webkit-backdrop-filter:blur(10px);border-bottom:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('.topbar .db{display:flex;align-items:baseline;gap:8px;min-width:0;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.topbar .db b{font-size:15px;font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.topbar .db span{color:var(--muted);font-size:13px;overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('.topbar .win{display:flex;align-items:center;gap:8px;font-size:14px;color:var(--ink-soft);white-space:nowrap;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.topbar .win b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.topbar .sp{flex:1}');
    DBMS_OUTPUT.PUT_LINE('.cchip{display:inline-flex;align-items:center;font-size:12px;line-height:20px;padding:0 8px;border-radius:999px;background:var(--acc-soft);color:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.seg{display:inline-flex;border:1px solid var(--rule);border-radius:8px;padding:2px;background:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.seg button{border:0;background:none;padding:4px 12px;border-radius:6px;font:inherit;font-size:13px;color:var(--ink-soft);cursor:pointer;line-height:20px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.seg button:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.seg button[aria-pressed="true"]{background:var(--ink);color:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.topbar .theme-icon-btn{flex:none;width:32px;height:32px;border:1px solid var(--rule);border-radius:8px;background:var(--panel);display:inline-grid;place-items:center;'
        || 'cursor:pointer;color:var(--ink-soft);padding:0}');
    DBMS_OUTPUT.PUT_LINE('.topbar .theme-icon-btn:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.topbar .theme-icon-btn .icon-sun{display:none}');
    DBMS_OUTPUT.PUT_LINE('body.dark .topbar .theme-icon-btn .icon-sun{display:block}');
    DBMS_OUTPUT.PUT_LINE('body.dark .topbar .theme-icon-btn .icon-moon{display:none}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 1180px){.topbar .db span{display:none}}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px){.topbar{order:1;position:static;margin:0 -20px;padding:8px 20px;flex-wrap:wrap}}');
    -- The band glyph (sql/lib/band_glyph.plsql): one span, one --x, zones and ticks drawn as gradients
    DBMS_OUTPUT.PUT_LINE('.bd{--x:.3333;position:relative;display:block;height:18px;min-width:120px}');
    DBMS_OUTPUT.PUT_LINE('.bd::before{content:"";position:absolute;left:10px;right:18px;top:5px;height:8px;border-radius:4px;background:linear-gradient(90deg,var(--track) 16.667%,var(--zone2) 16.667% 25%,'
        || 'var(--zone1) 25% 41.667%,var(--zone2) 41.667% 50%,var(--track) 50%)}');
    DBMS_OUTPUT.PUT_LINE('.bd::after{content:"";position:absolute;left:10px;right:18px;top:2px;height:14px;pointer-events:none;opacity:.9;background:linear-gradient(90deg,transparent calc(8.333% - .5px),'
        || 'var(--tick) 0 calc(8.333% + .5px),transparent 0 calc(16.667% - .5px),var(--tick) 0 calc(16.667% + .5px),transparent 0 calc(33.333% - .5px),var(--mean) 0 calc(33.333% + .5px),'
        || 'transparent 0 calc(50% - .5px),var(--tick) 0 calc(50% + .5px),transparent 0 calc(58.333% - .5px),var(--tick) 0 calc(58.333% + .5px),transparent 0)}');
    DBMS_OUTPUT.PUT_LINE('.bd>i{position:absolute;top:9px;left:calc(10px + (100% - 28px) * var(--x));width:10px;height:10px;margin:-5px 0 0 -5px;border-radius:50%;z-index:1;--dc:var(--muted);'
        || 'background:var(--row-bg);border:1.5px solid var(--dc);box-shadow:0 0 0 2px var(--row-bg)}');
    DBMS_OUTPUT.PUT_LINE('.bd.s-large>i{--dc:var(--crit-dot);background:var(--dc);border:0;width:11px;height:11px;margin:-5.5px 0 0 -5.5px}');
    DBMS_OUTPUT.PUT_LINE('.bd.s-moderate>i{--dc:var(--warn-dot);background:var(--dc);border:0}');
    DBMS_OUTPUT.PUT_LINE('.bd.s-improved>i{--dc:var(--imp);border-width:2px}');
    DBMS_OUTPUT.PUT_LINE('.bd.twn>i{opacity:.5}');
    DBMS_OUTPUT.PUT_LINE('.bd.po>i::after,.bd.pu>i::after{content:"";position:absolute;top:50%;margin-top:-4px;border:4px solid transparent}');
    DBMS_OUTPUT.PUT_LINE('.bd.po>i::after{left:calc(100% + 3px);border-left:5px solid var(--dc);border-right:0}');
    DBMS_OUTPUT.PUT_LINE('.bd.pu>i::after{right:calc(100% + 3px);border-right:5px solid var(--dc);border-left:0}');
    DBMS_OUTPUT.PUT_LINE('.bd .ov{position:absolute;top:1px;font:500 11px/16px system-ui,sans-serif;font-variant-numeric:tabular-nums;color:var(--ink-soft);background:var(--row-bg);padding:0 3px;'
        || 'border-radius:3px;white-space:nowrap;z-index:1}');
    DBMS_OUTPUT.PUT_LINE('.bd.po .ov{right:32px}');
    DBMS_OUTPUT.PUT_LINE('.bd.pu .ov{left:32px}');
    DBMS_OUTPUT.PUT_LINE('.bd.s-flat::before{background:repeating-linear-gradient(135deg,var(--zone1) 0 1.5px,transparent 1.5px 5px),var(--track)}');
    DBMS_OUTPUT.PUT_LINE('.bd.s-flat .ov{left:50%;transform:translateX(-50%);color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.bd.na::before,.bd.na::after{opacity:.35}');
    DBMS_OUTPUT.PUT_LINE('.bd.na .ov{left:50%;transform:translateX(-50%);color:var(--muted);font-weight:400}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm{min-width:88px;height:16px}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm::before{top:5px;height:6px}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm::after{top:2px;height:12px}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm>i{top:8px;width:9px;height:9px;margin:-4.5px 0 0 -4.5px}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm.s-large>i{width:10px;height:10px;margin:-5px 0 0 -5px}');
    DBMS_OUTPUT.PUT_LINE('.bd.sm .ov{font-size:10.5px;line-height:14px;top:1px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg{height:24px;min-width:200px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg::before{top:7px;height:10px;border-radius:5px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg::after{top:3px;height:18px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg>i{top:12px;width:13px;height:13px;margin:-6.5px 0 0 -6.5px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg.s-large>i,.bd.lg.s-moderate>i{width:14px;height:14px;margin:-7px 0 0 -7px}');
    DBMS_OUTPUT.PUT_LINE('.bd.lg .ov{top:4px}');
    DBMS_OUTPUT.PUT_LINE('.bd-ax{position:relative;display:block;height:14px;margin-top:2px;min-width:120px}');
    DBMS_OUTPUT.PUT_LINE('.bd-ax em{position:absolute;left:calc(10px + (100% - 28px) * var(--x));transform:translateX(-50%);font-style:normal;font-size:11px;line-height:14px;color:var(--muted);'
        || 'font-variant-numeric:tabular-nums;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.bd-ax em.end{transform:translateX(-100%)}');
    DBMS_OUTPUT.PUT_LINE('th.c-band,td.c-band{width:176px;min-width:176px;padding-left:4px;padding-right:4px}');
    DBMS_OUTPUT.PUT_LINE('td.c-rng{color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('td.c-z{color:var(--muted);font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('td.c-d{white-space:nowrap}');
    -- Delta text: the only coloured text besides links (one rule: x n at 2x or more, else %)
    DBMS_OUTPUT.PUT_LINE('.d{white-space:nowrap;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('.d.s-large{color:var(--crit);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.d.s-moderate{color:var(--warn);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.d.s-improved{color:var(--imp);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.d.s-typical,.d.s-flat,.d.s-na{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.d.s-plain{color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.imm{display:block;font-size:11px;line-height:13px;color:var(--muted);font-weight:400}');
    -- Entity links: a named thing that leads to its detail row -- inherited colour, dotted underline
    DBMS_OUTPUT.PUT_LINE('a.ent{color:inherit;font-weight:inherit;text-decoration:underline dotted;text-decoration-color:var(--ink-4);text-underline-offset:3px;text-decoration-thickness:1px}');
    DBMS_OUTPUT.PUT_LINE('a.ent:hover{text-decoration:underline solid;text-decoration-color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('a.ent code{font-size:inherit}');
    DBMS_OUTPUT.PUT_LINE('tr.flash>td{animation:awr-rowflash 2.2s ease-out}');
    DBMS_OUTPUT.PUT_LINE('.flash:not(tr){animation:awr-flash 2.2s ease-out}');
    DBMS_OUTPUT.PUT_LINE('@keyframes awr-rowflash{0%,25%{box-shadow:inset 0 0 0 999px var(--flash)}100%{box-shadow:inset 0 0 0 999px transparent}}');
    DBMS_OUTPUT.PUT_LINE('@keyframes awr-flash{0%,25%{outline:2px solid var(--acc);outline-offset:2px}100%{outline:2px solid transparent;outline-offset:2px}}');
    -- Reading the charts (static guide, every view)
    DBMS_OUTPUT.PUT_LINE('.gdg{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:0;margin:0 calc(-1 * var(--s5)) calc(-1 * var(--s5));overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('.gi{display:grid;grid-template-columns:168px minmax(0,1fr);gap:var(--s4);align-items:center;padding:var(--s4) var(--s5);border-top:1px solid var(--line-soft);margin-top:-1px;'
        || '--row-bg:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.gv{display:flex;flex-direction:column;justify-content:center;gap:4px;min-height:44px}');
    DBMS_OUTPUT.PUT_LINE('.gv .bd.sm{min-width:0;width:160px}');
    DBMS_OUTPUT.PUT_LINE('.gx2 h3{font-size:13.5px;font-weight:600;margin:0 0 2px}');
    DBMS_OUTPUT.PUT_LINE('.gx2 p{margin:0;font-size:12.5px;line-height:1.5;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.gx2 .g2{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('svg.gd{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('.gd-b{fill:var(--bar)} .gd-bc{fill:var(--acc)} .gd-cbg{fill:var(--acc-band)}');
    DBMS_OUTPUT.PUT_LINE('.gd-z2{fill:var(--zone2)} .gd-mn{stroke:var(--mean);stroke-width:1;opacity:.55}');
    DBMS_OUTPUT.PUT_LINE('.gd-ax{stroke:var(--line-2);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('.gd-dot{fill:var(--crit-dot);stroke:var(--panel);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('.gd-mk{stroke:var(--mk);stroke-width:1.5} .gd-mkf{fill:var(--mk)}');
    DBMS_OUTPUT.PUT_LINE('.gd-flg{fill:var(--flagbg)} .gd-t{font:10.5px system-ui,sans-serif;fill:var(--ink)} .gd-t.m{font-family:ui-monospace,Menlo,Consolas,monospace;fill:var(--muted)}'
        || ' .gd-t.b{fill:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.gd-t.pn{fill:var(--warn);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.gd-cell{fill:none} .gd-cl{stroke:var(--line);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('.gd-ar{stroke:var(--panel);stroke-width:.5}');
    DBMS_OUTPUT.PUT_LINE('.gd-w{fill:var(--muted);opacity:.22} .gd-wc{fill:var(--acc);opacity:.45}');
    DBMS_OUTPUT.PUT_LINE('.gd-dp{fill:var(--panel);stroke:var(--ink-2);stroke-width:1.2} .gd-dc{fill:var(--acc);stroke:var(--panel);stroke-width:1.2}');
    DBMS_OUTPUT.PUT_LINE('.gd-st{fill:none;stroke:var(--ink);stroke-width:1.5} .gd-str{stroke:var(--ink);stroke-width:1.5} .gd-nd{fill:var(--ink);stroke:var(--panel);stroke-width:2}');
    DBMS_OUTPUT.PUT_LINE('.gd-tk{stroke:var(--mean);stroke-width:1.2;opacity:.7}');
    DBMS_OUTPUT.PUT_LINE('.gd-pin{fill:var(--pin)}');
    DBMS_OUTPUT.PUT_LINE('.gd-dl,.gd-gl{display:flex;flex-direction:column;gap:2px;font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('.gd-gl b{display:inline-block;width:16px;font-style:normal}');
    DBMS_OUTPUT.PUT_LINE('svg.mw{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('.mw .z2{fill:var(--zone2)} .mw .b{fill:var(--bar)} .mw .b.cur{fill:var(--acc)}');
    -- About this report: the ONE fold holding every method note
    DBMS_OUTPUT.PUT_LINE('section.aboutsec{padding:0;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep{margin:0}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep > summary{list-style:none;cursor:pointer;display:flex;align-items:baseline;gap:var(--s4);padding:var(--s4) var(--s5);color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep > summary::-webkit-details-marker{display:none}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep > summary:hover{background:var(--panel-2)}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep > summary::before{content:"";width:7px;height:7px;border-right:1.5px solid var(--muted);border-bottom:1.5px solid var(--muted);transform:rotate(-45deg);'
        || 'transition:transform .15s;align-self:center;margin-left:3px}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep[open] > summary::before{transform:rotate(45deg)}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep .lt{font-weight:600;font-size:15px}');
    DBMS_OUTPUT.PUT_LINE('.aboutrep .ls{color:var(--muted);font-size:13.5px}');
    DBMS_OUTPUT.PUT_LINE('.ab-body{padding:0 var(--s5) var(--s5);display:flex;flex-direction:column;gap:var(--s5)}');
    DBMS_OUTPUT.PUT_LINE('.notes{display:grid;grid-template-columns:200px minmax(0,1fr);gap:var(--s2) var(--s5);margin:0;font-size:13px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.notes dt{font-weight:600;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.notes dd{margin:0;max-width:100ch}');
    DBMS_OUTPUT.PUT_LINE('.notes code,.ab-meta code{font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('.ab-meta{margin:0;font-size:12.5px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 720px){.notes{grid-template-columns:minmax(0,1fr)}.gi{grid-template-columns:minmax(0,1fr)}}');

    -- =========================================================
    -- v1.6.0 Summary view (Mock D): the verdict hero (00 / 17), the ONE
    -- window component .wg (sql/lib/wingrid.plsql + js_wingrid.plsql; the
    -- hero strip 08, the card charts 07, the config card 12 and the
    -- Timeline grid of phase 3), finding cards and the checked-and-normal
    -- grid (07).  Lifted from design/report_mocks_src/hybrid/style.css;
    -- generic class names are scoped under .wg / .fc / .hero because the
    -- fleet report includes this file too.
    -- =========================================================
    -- Summary sections sit on the page background; their cards are the panels
    DBMS_OUTPUT.PUT_LINE('body.vs section.sumsec{background:none;border:0;border-radius:0;padding:0;box-shadow:none}');
    DBMS_OUTPUT.PUT_LINE('body.vs section.sumsec > h2{margin:var(--s7) 0 var(--s5);padding:var(--s5) 0 0;border-bottom:0;border-top:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('section.sumsec[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.panel{background:var(--panel);border:1px solid var(--hairline);border-radius:10px}');
    -- the verdict hero
    DBMS_OUTPUT.PUT_LINE('section.hero{background:none;border:0;border-radius:0;padding:var(--s7) 0 0;margin:0}');
    DBMS_OUTPUT.PUT_LINE('.hero .verdict{font-size:30px;line-height:1.3;font-weight:400;letter-spacing:-.015em;max-width:30em;margin:0;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.hero .verdict b{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.hero .verdict code{font-family:inherit;font-size:1em;font-weight:500;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('.hero .verdict.quiet{font-size:26px}');
    DBMS_OUTPUT.PUT_LINE('.hero .because{font-size:16px;line-height:1.55;color:var(--ink-soft);max-width:48em;margin:var(--s3) 0 0}');
    DBMS_OUTPUT.PUT_LINE('.hero .because code{font-size:.9em}');
    -- plain links in the hero's second line (the too-little-history
    -- sentence links Windows / Findings): never browser blue
    DBMS_OUTPUT.PUT_LINE('.hero .because a:not(.ent){color:var(--ink-soft);text-decoration:underline;text-decoration-color:var(--hairline);text-underline-offset:3px}');
    DBMS_OUTPUT.PUT_LINE('.hero .pills{display:flex;flex-wrap:wrap;gap:var(--s2);margin:var(--s5) 0 0;padding:0;list-style:none}');
    DBMS_OUTPUT.PUT_LINE('.hero .pills a,.hero .pills span.pl{display:inline-flex;align-items:center;gap:8px;padding:4px 12px;border:1px solid var(--hairline);border-radius:999px;background:var(--panel);color:var(--ink-soft);font-size:13px;text-decoration:none;line-height:20px}');
    DBMS_OUTPUT.PUT_LINE('.hero .pills a:hover{border-color:var(--muted);color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.hero .pills b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes{list-style:none;margin:var(--s4) 0 0;padding:0;display:flex;flex-direction:column;gap:4px;font-size:13.5px;color:var(--ink-soft);max-width:80em}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes li{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 10px}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes .hl{font-weight:600;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes .hw{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes a.go{color:var(--ink-soft);font-size:12.5px;text-decoration:none;border-bottom:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('.hero .hnotes a.go:hover{color:var(--ink);border-color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.hero .snapnote{margin:var(--s3) 0 0;font-size:12.5px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('section.strip-sec{background:none;border:0;border-radius:0;padding:0;margin:var(--s5) 0 0}');
    DBMS_OUTPUT.PUT_LINE('.strip{overflow:hidden}');
    -- ONE window component (.wg, sql/lib/wingrid.plsql): 13 columns, Current last and wider
    DBMS_OUTPUT.PUT_LINE('.wg{--lab:224px;--gut:172px;--cmin:48px;--np:12;--tcols:repeat(var(--np),minmax(var(--cmin),1fr)) minmax(calc(var(--cmin) * 1.5),1.6fr);position:relative;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('.wg.fit{--cmin:18px}');
    -- more than 30 windows (wg_attr data-many): fitted grids shrink the column
    -- minimum so the Summary never scrolls sideways; the Timeline scrolls
    DBMS_OUTPUT.PUT_LINE('.wg[data-many]:not(#tl){--cmin:min(10px, calc(480px / var(--np)))}');
    DBMS_OUTPUT.PUT_LINE('.wg .r{display:grid;grid-template-columns:var(--lab) var(--tcols) var(--gut);position:relative}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare{--cmin:14px}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .r{grid-template-columns:var(--tcols)}');
    DBMS_OUTPUT.PUT_LINE('.wg .c{position:relative;min-width:0;border-left:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .c{border-left:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.cur{background-color:var(--acc-band)}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.mk{box-shadow:inset 1.5px 0 0 var(--mkline)}');
    DBMS_OUTPUT.PUT_LINE('.wg .r > .l{position:sticky;left:0;z-index:4;background:var(--panel);padding:0 12px 0 16px;display:flex;flex-direction:column;justify-content:center;min-width:0;border-right:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('.wg .l .nm{font-size:13px;font-weight:500;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:flex;align-items:center;gap:8px}');
    -- .nm is a flex box, so its own text-overflow never reaches the name
    -- link inside it: the link itself must shrink and ellipsise (a long
    -- segment name was clipped mid-letter on dbmint)
    DBMS_OUTPUT.PUT_LINE('.wg .l .nm > a{min-width:0;overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('.wg .l .sub{font-size:11.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.4}');
    DBMS_OUTPUT.PUT_LINE('.wg .r > .g{border-left:1px solid var(--hairline);padding:4px 12px;display:flex;flex-direction:column;justify-content:center;gap:2px;min-width:0;white-space:nowrap;overflow:hidden;background:var(--panel);--row-bg:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.wg .g .gl1{display:flex;align-items:baseline;justify-content:space-between;gap:8px;font-size:12.5px}');
    DBMS_OUTPUT.PUT_LINE('.wg .g .gl1 .z{font-size:11px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.wg .g .d1{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.wg .g .gx{font-size:11.5px;color:var(--muted);overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('.wg .g .bd.sm{margin:0 -6px 0 -10px;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .fr{height:40px}');
    DBMS_OUTPUT.PUT_LINE('.wg .fr .flags{grid-column:2 / -2;position:relative}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .fr{height:24px}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .fr .flags{grid-column:1 / -1}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .fr.t2{height:40px}');
    DBMS_OUTPUT.PUT_LINE('.wg .pole{position:absolute;bottom:0;width:0;border-left:1.5px solid var(--mk);pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('.wg .flag{position:absolute;height:16px;padding:0 6px 0 5px;font-size:11px;line-height:16px;color:var(--ink);background:var(--flagbg);border-radius:0 3px 3px 0;white-space:nowrap;cursor:default}');
    DBMS_OUTPUT.PUT_LINE('.wg .flag::before{content:"";position:absolute;left:-1.5px;top:0;height:16px;border-left:1.5px solid var(--mk)}');
    DBMS_OUTPUT.PUT_LINE('.wg .flag.end{border-radius:3px 0 0 3px;padding:0 5px 0 6px}');
    DBMS_OUTPUT.PUT_LINE('.wg .flag.end::before{left:auto;right:-1.5px}');
    DBMS_OUTPUT.PUT_LINE('.wg .dr .h{display:flex;flex-direction:column;align-items:center;justify-content:center;line-height:1.2;padding:4px 0;border-left:1px solid var(--line-soft);min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .dr .h{border-left:0;padding:4px 0 0}');
    DBMS_OUTPUT.PUT_LINE('.wg .dr .h.cur{background-color:var(--acc-band)}');
    DBMS_OUTPUT.PUT_LINE('.wg .h.mk{box-shadow:inset 1.5px 0 0 var(--mkline)}');
    DBMS_OUTPUT.PUT_LINE('.wg .h .hd{font-size:12px;font-weight:600;color:var(--ink);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.wg .h .ho{font-size:10.5px;color:var(--muted);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.wg .h.cur .hd,.wg .h.cur .ho{color:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg .h.cur .ho{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .h .hd{font-weight:400;font-size:11px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .h.cur .hd{font-weight:600;color:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg.tight .h:not(.cur):not(.keep) .hd,.wg.tight .h:not(.cur) .ho{visibility:hidden}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .rin{display:grid;grid-template-columns:var(--lab) var(--tcols) var(--gut);grid-template-rows:40px 40px}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler{border-bottom:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .corner{grid-row:1 / 3;grid-column:1;display:flex;flex-direction:column;justify-content:center;gap:2px;background:var(--panel);padding:8px 12px 8px 16px;border-right:1px solid var(--hairline)}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .corner .ct{font-weight:600;font-size:13px;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .corner .cs{font-size:11px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .flags{grid-row:1;grid-column:2 / -2;position:relative}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .h{grid-row:2;border-left:1px solid var(--line-soft);display:flex;flex-direction:column;align-items:center;justify-content:center;line-height:1.25;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .h.cur{background-color:var(--acc-band)}');
    DBMS_OUTPUT.PUT_LINE('.wg .ruler .gh{grid-row:1 / 3;grid-column:-2 / -1;border-left:1px solid var(--hairline);padding:8px 12px;display:flex;flex-direction:column;justify-content:flex-end;gap:2px}');
    DBMS_OUTPUT.PUT_LINE('.wg .gh .gt{font-weight:600;font-size:12px;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg .gh .gs{font-size:11px;color:var(--muted);line-height:1.3}');
    DBMS_OUTPUT.PUT_LINE('.wg .v{position:absolute;left:0;right:0;top:2px;text-align:center;font-size:10.5px;line-height:14px;color:var(--muted);white-space:nowrap;pointer-events:none;z-index:3}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.cur .v{font-weight:600;color:var(--ink);font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('.wg .v.nil{top:auto;bottom:4px;color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('body.js-wg .wg:not(.allv) .c:not(.cur) .v:not(.nil){opacity:0}');
    DBMS_OUTPUT.PUT_LINE('.wg.allv.tight .c:not(.cur) .v:not(.nil){opacity:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.hc,.wg .h.hc{background-image:linear-gradient(var(--hov),var(--hov))}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.hc .v{opacity:1!important}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.bars{--rh:44px;--bh:24px;--bb:4px}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.bars .c{min-height:var(--rh)}');
    DBMS_OUTPUT.PUT_LINE('.wg i.b{position:absolute;z-index:2;bottom:var(--bb);left:50%;width:14px;margin-left:-7px;border-radius:3px 3px 0 0;background:var(--bar)}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare i.b{width:calc(100% - 8px);max-width:14px;left:50%;transform:translateX(-50%);margin-left:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.cur i.b{width:20px;margin-left:-10px;background:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .c.cur i.b{width:calc(100% - 8px);max-width:20px;margin-left:0}');
    DBMS_OUTPUT.PUT_LINE('.wg i.sd{position:absolute;z-index:3;left:50%;width:9px;height:9px;margin:0 0 -4.5px -4.5px;border-radius:50%;box-shadow:0 0 0 2px var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.wg i.sd.s-large{background:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('.wg i.sd.s-moderate{background:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('.wg i.z2,.wg i.z1{position:absolute;left:0;right:0;z-index:1;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('.wg i.z2{background:var(--zone2);opacity:.75}');
    DBMS_OUTPUT.PUT_LINE('.wg i.z1{background:var(--zone1);opacity:.55}');
    DBMS_OUTPUT.PUT_LINE('.wg i.mn{position:absolute;left:0;right:0;z-index:2;height:0;border-top:1px solid var(--mean);opacity:.55;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.cur i.z2,.wg .c.cur i.z1{opacity:.5}');
    DBMS_OUTPUT.PUT_LINE('.wg .base{position:absolute;left:0;right:0;bottom:calc(var(--bb) - 1px);border-top:1px solid var(--hairline);z-index:1}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p{--rh:40px}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p .c{min-height:var(--rh)}');
    DBMS_OUTPUT.PUT_LINE('.wg .st{position:absolute;left:0;right:0;height:0;border-top:1.5px solid var(--muted);pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('.wg .st.lo{bottom:10px}');
    DBMS_OUTPUT.PUT_LINE('.wg .st.hi{bottom:24px;border-top-color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg .st.rise::before{content:"";position:absolute;left:-1.5px;top:-1.5px;height:15.5px;border-left:1.5px solid var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.wg .nd{position:absolute;left:-4px;bottom:20px;width:8px;height:8px;border-radius:50%;background:var(--ink);box-shadow:0 0 0 2px var(--panel);z-index:3}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p .pv{position:absolute;left:6px;font:10.5px/14px ui-monospace,Menlo,Consolas,monospace;color:var(--muted);white-space:nowrap;z-index:3;pointer-events:none;max-width:calc(100% - 8px);overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p .pv.lo{bottom:12px}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p .pv.hi{bottom:26px;color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.p .c.cur .pv.hi{color:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('.kf{display:inline-block;position:relative;width:9px;height:12px;vertical-align:-1px;margin-right:2px}');
    DBMS_OUTPUT.PUT_LINE('.kf::before{content:"";position:absolute;left:0;top:0;bottom:0;border-left:1.5px solid var(--mk)}');
    DBMS_OUTPUT.PUT_LINE('.kf::after{content:"";position:absolute;left:1.5px;top:0;width:7px;height:6px;background:var(--mk);clip-path:polygon(0 0,100% 50%,0 100%)}');
    -- the hero strip: DB time per window on the window geometry
    DBMS_OUTPUT.PUT_LINE('.strip .wg .r > .l{background:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.strip .r.bars{--rh:128px;--bh:96px;--bb:6px}');
    DBMS_OUTPUT.PUT_LINE('.strip .r.bars > .l .big{font-size:22px;font-weight:600;letter-spacing:-.02em;line-height:1.1;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.strip .r.bars > .l .big .u{font-size:13px;font-weight:400;color:var(--muted);margin-left:4px;letter-spacing:0}');
    -- finding cards (one per card group of metric_policy families)
    DBMS_OUTPUT.PUT_LINE('.cards{display:grid;grid-template-columns:minmax(0,1fr);gap:var(--s5)}');
    DBMS_OUTPUT.PUT_LINE('.fc{position:relative;padding:var(--s5) var(--s6) 0;display:flex;flex-direction:column;min-width:0;scroll-margin-top:calc(var(--navh, 0px) + 16px);--row-bg:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.fc.f-large::before,.fc.f-moderate::before{content:"";position:absolute;left:-1px;top:24px;height:32px;width:2px;border-radius:1px;background:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('.fc.f-moderate::before{background:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('.fc-h{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px 24px;align-items:start}');
    DBMS_OUTPUT.PUT_LINE('.fc-k{display:flex;align-items:center;gap:8px 16px;flex-wrap:wrap;font-size:13px;color:var(--muted);padding-top:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc-k .sv{display:inline-flex;align-items:center;gap:8px;color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.fc-k .gk{font-style:normal;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.fc-band{width:280px}');
    DBMS_OUTPUT.PUT_LINE('.fc-band .bd-ax{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.fc h3{font-size:19px;line-height:1.3;font-weight:600;letter-spacing:-.01em;margin:8px 0 0;padding:0;border:0;text-transform:none;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.fc h3::before{content:none}');
    DBMS_OUTPUT.PUT_LINE('.fc h3,.calm-notes .note h3{display:block}');
    DBMS_OUTPUT.PUT_LINE('.fc.lead h3{font-size:24px}');
    DBMS_OUTPUT.PUT_LINE('.fc.slim h3{font-size:17px}');
    DBMS_OUTPUT.PUT_LINE('.fc-b{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(0,1fr);gap:var(--s4) var(--s7);margin-top:var(--s4)}');
    DBMS_OUTPUT.PUT_LINE('.fc .big{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 8px}');
    DBMS_OUTPUT.PUT_LINE('.fc .big .v{font-size:32px;font-weight:600;letter-spacing:-.02em;line-height:1.15;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.fc.lead .big .v{font-size:40px}');
    DBMS_OUTPUT.PUT_LINE('.fc.slim .big .v{font-size:24px}');
    DBMS_OUTPUT.PUT_LINE('.fc .big .u{color:var(--ink-soft);font-size:14px}');
    DBMS_OUTPUT.PUT_LINE('.fc .big .nrm{color:var(--muted);font-size:13px;flex-basis:100%}');
    DBMS_OUTPUT.PUT_LINE('.fc .wg{margin-top:8px}');
    DBMS_OUTPUT.PUT_LINE('.fc .wg .r.bars{--rh:150px;--bh:118px}');
    DBMS_OUTPUT.PUT_LINE('.fc.lead .wg .r.bars{--rh:176px;--bh:144px}');
    DBMS_OUTPUT.PUT_LINE('.fc.slim .wg .r.bars{--rh:100px;--bh:70px}');
    DBMS_OUTPUT.PUT_LINE('.fc .ev{margin:0;display:flex;flex-direction:column;align-self:start;padding-top:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr{display:grid;grid-template-columns:88px minmax(0,1fr) 136px;gap:2px var(--s4);padding:var(--s3) 0;border-top:1px solid var(--line-soft);align-items:start}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr:first-child{border-top:0;padding-top:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr dt{color:var(--muted);font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr dd{margin:0;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .id{display:block;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;color:var(--ink);overflow-wrap:anywhere;line-height:1.4}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .id.txt{font-family:inherit;font-size:14px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .de{display:block;color:var(--muted);font-size:12.5px;line-height:1.45}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .m{display:flex;flex-direction:column;align-items:flex-end;gap:2px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .m .d{font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .m .bd{width:128px;min-width:0;margin-right:-8px}');
    DBMS_OUTPUT.PUT_LINE('.fc .evr .m .ns{font-size:11px;color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel{margin-top:16px;border-top:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel > summary{list-style:none;cursor:pointer;padding:12px 0;font-size:13.5px;color:var(--ink-soft);display:flex;align-items:center;gap:8px}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel > summary::-webkit-details-marker{display:none}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel > summary::before{content:"";width:6px;height:6px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;transform:rotate(-45deg);transition:transform .15s;margin:0 4px 0 2px}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel[open] > summary::before{transform:rotate(45deg)}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel > summary:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel .tw{margin:0 0 16px}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel table{margin:0}');
    DBMS_OUTPUT.PUT_LINE('.fc-f{margin-top:auto;border-top:1px solid var(--line-soft);padding:var(--s3) 0;font-size:13px;color:var(--muted);display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 16px}');
    DBMS_OUTPUT.PUT_LINE('.fc .rel + .fc-f{margin-top:0}');
    DBMS_OUTPUT.PUT_LINE('.fc-f .evl{display:flex;flex-wrap:wrap;gap:4px 16px}');
    DBMS_OUTPUT.PUT_LINE('.fc-f .evl a{color:var(--ink-soft);text-decoration:underline;text-decoration-color:var(--hairline);text-underline-offset:3px}');
    DBMS_OUTPUT.PUT_LINE('.fc-f .evl a:hover{color:var(--ink);text-decoration-color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.fc-f .jump{color:var(--ink-soft);text-decoration:none;font-weight:500;margin-right:auto;order:2}');
    DBMS_OUTPUT.PUT_LINE('.fc-f .jump:hover{color:var(--ink);text-decoration:underline}');
    DBMS_OUTPUT.PUT_LINE('.fc .takeaway{margin:8px 0 0;font-size:14px;color:var(--ink-soft);max-width:80ch}');
    DBMS_OUTPUT.PUT_LINE('.fc .cfg-wg{margin:var(--s4) calc(-1 * var(--s6)) 0;border-top:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('.fc .cfg-wg .wg > .r{border-bottom:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('.fc .cfg-wg .wg > .r:last-child{border-bottom:0}');
    DBMS_OUTPUT.PUT_LINE('.fc .cfg-wg .l .nm{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}');
    -- the plan-change card (18): who ran it, and the plan step line under
    -- the elapsed bars (bare, so the hashes may overflow their narrow cells)
    DBMS_OUTPUT.PUT_LINE('.fc .whereln{margin:0 0 4px;font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:help}');
    DBMS_OUTPUT.PUT_LINE('.fc .wg.bare .r.p .pv{max-width:none} .fc .wg.bare .r.p .c.cur .pv{left:auto;right:2px}');
    DBMS_OUTPUT.PUT_LINE('.fc .cfg-more{margin:0;padding:var(--s2) 0 0;font-size:12.5px;color:var(--muted)}');
    -- checked and normal
    DBMS_OUTPUT.PUT_LINE('.calm{padding:var(--s2) var(--s6)}');
    DBMS_OUTPUT.PUT_LINE('.ngrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));column-gap:32px}');
    DBMS_OUTPUT.PUT_LINE('.nr{display:grid;grid-template-columns:minmax(0,1fr) 112px 88px;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--line-soft);font-size:13.5px;--row-bg:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('.nr .l{color:var(--ink-soft);min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.nr .l small{display:block;color:var(--muted);font-size:12px;white-space:normal}');
    DBMS_OUTPUT.PUT_LINE('.nr .vv{text-align:right;line-height:1.3;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.nr .vv small{display:block;font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('.nr .bd{min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes{display:grid;grid-template-columns:1fr 1fr;gap:var(--s5);margin-top:var(--s5);align-items:start}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note{padding:var(--s4) var(--s6)}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note h3{font-size:14px;margin:0 0 var(--s1);padding:0;border:0;text-transform:none;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note h3::before{content:none}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note p{margin:0 0 8px;font-size:13.5px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note .nr:last-child{border-bottom:0}');
    DBMS_OUTPUT.PUT_LINE('.calm-notes .note.improved{background:transparent;border-style:dashed}');
    DBMS_OUTPUT.PUT_LINE('.calm-more{margin:var(--s3) 0 0;font-size:12.5px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.calm-more a{color:var(--ink-soft);text-decoration:underline;text-decoration-color:var(--hairline);text-underline-offset:3px}');
    DBMS_OUTPUT.PUT_LINE('.calm-empty{margin:0;padding:var(--s4) 0;font-size:14px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.ent-x{font:inherit}');
    DBMS_OUTPUT.PUT_LINE('nav.toc a[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.dotk.typical{border:1.5px solid var(--muted)} .dotk.improved{border:2px solid var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 1180px){.fc-b{grid-template-columns:minmax(0,1fr)}.ngrid{grid-template-columns:repeat(2,minmax(0,1fr))}}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 900px){.calm-notes{grid-template-columns:1fr}.fc-h{grid-template-columns:minmax(0,1fr)}.fc-band{width:100%}}');

    -- =========================================================
    -- v1.6.0 Timeline view (Mock D): the #timeline section, the Activity
    -- charts at the top of every view (section#activity .ashx: by wait
    -- class and by wait event) and the aligned window grid
    -- (#tl: sticky ruler, lanes of .wg rows, pin / hover / flash), the
    -- stacked activity columns (.r.ash, also the DB time card) and the
    -- shared tooltip (#tip).  Client half: sql/lib/js_timeline.plsql.
    -- Lifted from design/report_mocks_src/hybrid/style.css; scoped to
    -- single-DB ids / classes (the fleet report includes this file).
    -- No sibling combinator "tilde" here: SET DEFINE makes it a
    -- substitution character (the gin negative margin hides the first
    -- visible lanes separator instead).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('section#timeline{background:none;border:0;border-radius:0;padding:0;box-shadow:none}');
    DBMS_OUTPUT.PUT_LINE('section#timeline > h2{margin:var(--s7) 0 var(--s5);padding:0;border:0}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-nojs{color:var(--muted);font-size:13px;margin:0 0 var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('body.js-wg #timeline .tl-nojs{display:none}');
    DBMS_OUTPUT.PUT_LINE('body:not(.js-wg) #tl{display:none}');
    DBMS_OUTPUT.PUT_LINE('#timeline .sw,#tip .sw,.fcleg .sw,.ashx .sw{display:inline-block;width:8px;height:8px;border-radius:2px;flex:none;background:var(--sw,#9AA3AD)}');
    DBMS_OUTPUT.PUT_LINE('#activity .ax-nojs{color:var(--muted);font-size:13px;margin:0 0 var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('body.js-wg #activity .ax-nojs{display:none}');
    DBMS_OUTPUT.PUT_LINE('#timeline .muted{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.ashx{margin:0;padding:0}');
    DBMS_OUTPUT.PUT_LINE('.ashx[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axh{display:flex;align-items:baseline;gap:var(--s2) var(--s5);flex-wrap:wrap}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axh .axs{flex:1;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axch{margin-top:var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axch + .axch{margin-top:var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axch[hidden],.ashx .axk[hidden],.ashx .axn2[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axct{display:flex;align-items:baseline;gap:2px var(--s3);flex-wrap:wrap}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axct h3{display:block;font-size:13px;font-weight:600;white-space:nowrap;margin:0;padding:0;border:0;text-transform:none;letter-spacing:0;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axct h3::before{content:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axs{font-size:13px;color:var(--ink-3);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axk{display:flex;gap:var(--s4);font-size:12px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axk span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('.ashx .kw{display:inline-block;width:8px;height:12px;border-radius:1px;background:var(--ink-3);opacity:.35}');
    DBMS_OUTPUT.PUT_LINE('.ashx .kw.cur{background:var(--acc);opacity:.7}');
    DBMS_OUTPUT.PUT_LINE('.ashx .kw.pin{background:var(--warn-dot);opacity:.6}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axr{font-size:12px;border:1px solid var(--line-2);background:var(--panel);border-radius:6px;padding:2px 10px;cursor:pointer;color:var(--ink-2);line-height:20px}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axr:hover{color:var(--ink);border-color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axr[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axlg{display:flex;flex-wrap:wrap;gap:0 2px;margin:0;flex:1;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axc{display:inline-flex;align-items:center;gap:6px;border:0;background:none;border-radius:6px;padding:1px 6px;font:inherit;font-size:12px;color:var(--ink-2);cursor:pointer;line-height:18px}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axc:hover{background:var(--hov);color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axc[aria-pressed="false"]{color:var(--ink-4);text-decoration:line-through;text-decoration-color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axc[aria-pressed="false"] .sw{background:none;box-shadow:inset 0 0 0 1.5px var(--sw)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axp{position:relative;margin-top:var(--s1);user-select:none;-webkit-user-select:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axp[hidden],.ashx .axe[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axe{margin:var(--s3) 0;font-size:13px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axsvg{display:block;width:100%;cursor:crosshair}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axbr{position:absolute;top:0;pointer-events:none;background:var(--acc-soft);border-left:1px solid var(--acc);border-right:1px solid var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axbr[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axn2{margin:var(--s1) 0 0;font-size:12px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .gl{stroke:var(--line);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('.ashx .ax{stroke:var(--line-2);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('.ashx .at{font:11px ui-sans-serif,-apple-system,"Segoe UI",Inter,Roboto,system-ui,sans-serif;fill:var(--ink-3);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('.ashx .cf{stroke:var(--mk);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('.ashx .cfl{stroke:var(--mkline);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('.ashx .cfh{fill:var(--flagbg)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .cft{font:11px ui-sans-serif,-apple-system,"Segoe UI",Inter,Roboto,system-ui,sans-serif;fill:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xa{stroke:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xe{fill:none;stroke-width:.8;stroke-linejoin:round}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw{fill:var(--ink-3);opacity:.16}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw.cur{fill:var(--acc);opacity:.28}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw.on{fill:var(--warn-dot);opacity:.35}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw.sk{fill:var(--ink-4);opacity:.1}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw.wd{opacity:.07}.ashx .xw.cur.wd{opacity:.1}.ashx .xw.on.wd{opacity:.14}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwc{fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwc.cur{fill:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwc.on{fill:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwc.sk{fill:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwh{fill:transparent;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xwh:focus-visible{outline:none;stroke:var(--acc);stroke-width:2}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xch{stroke:var(--ink);stroke-width:1;opacity:.55;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xbk{fill:var(--ink);opacity:.06;pointer-events:none}');
    DBMS_OUTPUT.PUT_LINE('#tip{position:fixed;z-index:100;pointer-events:none;background:var(--ink);color:var(--panel);font-size:12px;line-height:1.45;padding:6px 10px;border-radius:6px;max-width:320px;box-shadow:0 4px 14px rgba(0,0,0,.25);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#tip[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tip .tm{opacity:.72}');
    DBMS_OUTPUT.PUT_LINE('#tip .tr2{display:flex;align-items:center;gap:6px;justify-content:space-between}');
    DBMS_OUTPUT.PUT_LINE('#tip .tr2 span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#tip .tr2 b{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#tip .tsum{border-top:1px solid color-mix(in srgb,var(--panel) 30%,transparent);margin-top:3px;padding-top:3px}');
    DBMS_OUTPUT.PUT_LINE('#tl.gridwrap{position:relative}');
    DBMS_OUTPUT.PUT_LINE('#tl > .ruler{position:sticky;top:var(--navh,0px);z-index:30;overflow:hidden;background:var(--panel);border-radius:10px 10px 0 0;border-bottom:1px solid var(--line-2);box-shadow:0 6px 12px -10px rgba(20,26,40,.35)}');
    DBMS_OUTPUT.PUT_LINE('#tl .rin,#tl .gin{min-width:calc(var(--lab) + var(--gut) + (var(--np) + 1.6) * var(--cmin))}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .corner{position:sticky;left:0;z-index:5;justify-content:space-between}');
    DBMS_OUTPUT.PUT_LINE('#tl .jumpnav{display:flex;flex-wrap:nowrap;gap:8px;font-size:11.5px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#tl .jumpnav a{color:var(--ink-2);text-decoration:none;border-bottom:1px solid var(--line-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .jumpnav a:hover{color:var(--ink);border-color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#tl .jumpnav a[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h{cursor:pointer;border:0;border-left:1px solid var(--line-soft);padding:0;margin:0;background-color:transparent;font:inherit;color:inherit}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h.cur{background-color:var(--acc-band)}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h:hover .hd{color:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h.skw .hd,#tl .ruler .h.skw .ho{color:var(--ink-4);text-decoration:line-through;text-decoration-color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h:focus-visible{outline:2px solid var(--acc);outline-offset:-2px}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h[aria-pressed="true"] .ho{font-size:0}');
    DBMS_OUTPUT.PUT_LINE('#tl .ruler .h[aria-pressed="true"] .ho::after{content:"pinned";font-size:10.5px;color:var(--warn);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#tl .gh .unpin{font:inherit;font-size:11px;font-weight:400;border:1px solid var(--line-2);background:none;border-radius:4px;padding:0 6px;margin-left:4px;cursor:pointer;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gh .unpin:hover{color:var(--ink);border-color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gbody{overflow-x:auto;overflow-y:hidden;border-radius:0 0 10px 10px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r{border-bottom:1px solid var(--line-soft);scroll-margin-top:calc(var(--navh,0px) + 96px)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.bars{--rh:48px;--bh:22px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.bars.w{--rh:44px;--bh:19px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.bars.q.sub{--rh:40px;--bh:15px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.q .l .nm,#tl .gin .r.p .l .nm{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.q.sub .l{padding-left:32px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.q.sub .l .nm{font-family:inherit;font-weight:500;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.q.sub .l::before{content:"";position:absolute;left:18px;top:0;height:50%;width:8px;border-left:1px solid var(--line-2);border-bottom:1px solid var(--line-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.twin .l .nm{color:var(--ink-3);font-weight:400}');
    DBMS_OUTPUT.PUT_LINE('#tl .l .sq{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;color:var(--ink-4);margin-left:4px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.more{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.showmore .r.more{display:grid}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.showmore .r.xpr{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.xpr .l{padding:8px 16px}');
    DBMS_OUTPUT.PUT_LINE('#tl .xpb{border:0;background:none;padding:0;font:inherit;color:var(--ink-2);font-size:12.5px;cursor:pointer;text-decoration:underline;text-underline-offset:2px;text-decoration-color:var(--line-2);text-align:left}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane{scroll-margin-top:calc(var(--navh,0px) + 96px)}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin{margin-top:calc(-1 * var(--s3))}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin > .lane{border-top:var(--s3) solid var(--paper)}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.gh2{background:var(--panel-2);border-top:1px solid var(--line-2);border-bottom:1px solid var(--line-2);margin-top:-1px;min-height:44px}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.gh2 > .l,#tl .r.gh2 > .g{background:var(--panel-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.gh2 .c{min-height:40px}');
    DBMS_OUTPUT.PUT_LINE('#tl .lt2{display:flex;align-items:center;gap:8px;border:0;background:none;padding:0;cursor:pointer;text-align:left;width:100%;font:inherit;color:inherit}');
    DBMS_OUTPUT.PUT_LINE('#tl .car{width:0;height:0;border-left:4.5px solid transparent;border-right:4.5px solid transparent;border-top:6px solid var(--ink-3);transition:transform .12s;flex:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.closed .car{transform:rotate(-90deg)}');
    DBMS_OUTPUT.PUT_LINE('#tl .lti{font-weight:600;font-size:14.5px;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#tl .cap{position:absolute;left:calc(var(--lab) + 16px + var(--sl, 0px));top:0;bottom:0;width:calc(var(--vw, 100%) - var(--lab) - var(--gut) - 32px);display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--ink-3);pointer-events:none;white-space:nowrap;z-index:4;overflow:hidden}');
    DBMS_OUTPUT.PUT_LINE('#tl .cap > span{overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.gh2 .g .meta{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:12px;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.gh2 .g .meta span{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.closed .lrows{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.ash .l{justify-content:flex-start;padding-top:12px}');
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.ash .g{justify-content:flex-start;padding-top:12px;gap:4px}');
    DBMS_OUTPUT.PUT_LINE('#tl .g .d3{font-size:11.5px;color:var(--ink-2);display:flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#tl .leg{list-style:none;margin:8px 0 0;padding:0;display:grid;grid-template-columns:1fr 1fr;gap:4px 8px;font-size:11.5px;color:var(--ink-2);max-width:176px}');
    DBMS_OUTPUT.PUT_LINE('#tl .leg li{display:flex;align-items:center;gap:6px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.ash{--rh:184px;--bh:148px;--bb:6px}');
    DBMS_OUTPUT.PUT_LINE('.wg .r.ash .c{min-height:var(--rh)}');
    DBMS_OUTPUT.PUT_LINE('.wg .stk{position:absolute;bottom:var(--bb);left:50%;width:18px;margin-left:-9px;z-index:2}');
    DBMS_OUTPUT.PUT_LINE('.wg .stk i{position:absolute;left:0;right:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .stk i:last-child{border-radius:3px 3px 0 0}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.cur .stk{width:24px;margin-left:-12px}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .stk{width:calc(100% - 8px);max-width:14px;margin-left:0;transform:translateX(-50%)}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare .c.cur .stk{max-width:20px;margin-left:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .gline{position:absolute;left:0;right:0;border-top:1px dashed var(--line);pointer-events:none;z-index:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .dl{position:absolute;left:calc(50% + 16px);display:inline-flex;align-items:center;gap:4px;font-size:11px;font-weight:600;line-height:1;color:var(--ink);white-space:nowrap;transform:translateY(50%);z-index:3}');
    DBMS_OUTPUT.PUT_LINE('.wg .dl .sw{display:inline-block;width:8px;height:8px;border-radius:2px;background:var(--sw)}');
    DBMS_OUTPUT.PUT_LINE('.wg .axn{position:absolute;right:8px;top:0;bottom:0;width:22px}');
    DBMS_OUTPUT.PUT_LINE('.wg .axn i{position:absolute;right:0;font:10px/1 ui-sans-serif,-apple-system,"Segoe UI",Inter,Roboto,system-ui,sans-serif;color:var(--ink-3);font-style:normal;transform:translateY(50%)}');
    DBMS_OUTPUT.PUT_LINE('.wg .glf{position:absolute;top:3px;right:4px;font-style:normal;font-size:11px;line-height:1;color:var(--ink);z-index:4;cursor:help}');
    DBMS_OUTPUT.PUT_LINE('.fc .wg .r.ash{--rh:150px;--bh:118px;--bb:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc.lead .wg .r.ash{--rh:176px;--bh:144px}');
    DBMS_OUTPUT.PUT_LINE('.fc .fcleg{list-style:none;margin:8px 0 0;padding:0;display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('.fc .fcleg li{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.flash{animation:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .r::after{content:"";position:absolute;inset:0;background:var(--flash);opacity:0;pointer-events:none;z-index:6}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.flash::after{animation:tl-flash 2s ease-out}');
    DBMS_OUTPUT.PUT_LINE('@keyframes tl-flash{0%{opacity:1}100%{opacity:0}}');
    DBMS_OUTPUT.PUT_LINE('#tl .c.colflash,#tl .h.colflash{animation:awr-rowflash 1.8s ease-out}');
    DBMS_OUTPUT.PUT_LINE('#tl .c.pc,#tl .h.pc{background-image:linear-gradient(var(--pin),var(--pin))}');
    DBMS_OUTPUT.PUT_LINE('#tl .c.pc .v{opacity:1!important}');
    DBMS_OUTPUT.PUT_LINE('body[data-pw] #tl .g .d1{color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('body[data-pw] #tl .g .z{display:none}');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-reduced-motion: reduce){#tl .r.flash::after,#tl .c.colflash,#tl .h.colflash{animation:none}}');

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
        || ' .view-note, .next-finding, .windows-hint, .topbar,'
        || ' .theme-icon-btn { display:none !important; }'
        || ' tr[data-tail="Y"] { display:table-row !important; }'
        || ' .tblwrap.scroll { overflow:visible; box-shadow:none; }'
        || ' .tblwrap.scroll tr > :first-child { position:static; }'
        || ' }');

    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/

SET DEFINE '~'
