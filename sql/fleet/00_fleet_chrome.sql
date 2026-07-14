--
-- sql/fleet/00_fleet_chrome.sql
-- Shared page chrome for the fleet report: DOCTYPE/head/title, the
-- single-sourced report CSS (@@sql/_style.sql -- nested @@ resolves at the
-- OUTERMOST caller, i.e. awr_fleet_extract.sql's directory, same as every
-- other consumer of this file), a small fleet-only CSS block, the </head>
-- <body> open, the early-theme bootstrap, and the CDN-free sparkline
-- renderer.
--
-- Spooled independently by EVERY database in the fleet run (cheap, and
-- race-free under parallel fan-out since each alias writes its own copy);
-- the bash assembler keeps only the first successful one and discards the
-- rest.  Deliberately ends INSIDE <body> with no closing tags -- the
-- assembler appends the masthead, every DB's fragment (sorted by score),
-- and the footer + </body></html> directly after this file's content.
--
-- No ECharts anywhere in the fleet report (inline-SVG sparklines only), so
-- unlike awr_trend.sql's prologue there is no <script src="...echarts...">
-- tag, no body.no-charts fallback banner, and no AWR_DATA namespace to
-- initialize.
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

-- Fleet-only CSS: the masthead (emitted by the wrapper) plus the per-DB
-- card shell (emitted by sql/fleet/01_db_card.sql .. 05_close.sql). Every
-- color is a CSS var already declared by sql/_style.sql's :root / body.dark
-- token set above, so this block needs no dark-mode overrides of its own.
SET DEFINE OFF
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('.fleet-masthead {'
        || ' background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:10px; padding:18px 24px; margin:0 0 20px; }');
    DBMS_OUTPUT.PUT_LINE('.fleet-masthead h1 { margin:0 0 6px; font-size:22px; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.fleet-masthead .fleet-meta {'
        || ' font-size:12px; color:var(--muted); margin:0 0 10px; }');
    DBMS_OUTPUT.PUT_LINE('.fleet-masthead .fleet-badges { display:flex; gap:8px; flex-wrap:wrap; }');
    DBMS_OUTPUT.PUT_LINE('.fleet-masthead .fleet-badges .badge { font-size:12px; padding:4px 10px; }');
    -- Layout constraint applied directly to body (not a wrapper <main>):
    -- this chrome file ends INSIDE <body> with no closing tags, since the
    -- assembler appends the masthead/cards/footer/</body></html> straight
    -- after it -- introducing an unclosed wrapper element here would leave
    -- the assembled document with unbalanced markup.
    DBMS_OUTPUT.PUT_LINE('body { max-width:1100px; margin:0 auto; padding:20px; }');
    DBMS_OUTPUT.PUT_LINE('section.db-card {'
        || ' background:var(--panel); border:1px solid var(--hairline);'
        || ' border-radius:10px; padding:20px 24px; margin:0 0 20px; }');
    DBMS_OUTPUT.PUT_LINE('section.db-card.db-card-error {'
        || ' border-left:5px solid var(--crit); background:var(--crit-bg); }');
    DBMS_OUTPUT.PUT_LINE('.db-card .db-card-id {'
        || ' display:flex; flex-wrap:wrap; align-items:baseline;'
        || ' gap:6px 14px; margin:0 0 4px; }');
    DBMS_OUTPUT.PUT_LINE('.db-card .db-card-id h2 { margin:0; font-size:18px; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.db-card .db-card-score {'
        || ' font-variant-numeric:tabular-nums; color:var(--muted); font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('.db-card .db-card-meta {'
        || ' font-size:12px; color:var(--muted); margin:0 0 14px; }');
    DBMS_OUTPUT.PUT_LINE('.db-card h3 { margin:22px 0 8px; font-size:14px; color:var(--ink); }');
    DBMS_OUTPUT.PUT_LINE('.db-card .muted { color:var(--muted); font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('.db-card-error pre.log {'
        || ' max-height:220px; overflow:auto; background:var(--panel-2);'
        || ' border:1px solid var(--hairline); border-radius:6px;'
        || ' padding:10px; font-size:11.5px; white-space:pre-wrap; word-break:break-all; }');
    DBMS_OUTPUT.PUT_LINE('code.drill {'
        || ' display:block; background:var(--panel-2);'
        || ' border:1px solid var(--hairline); border-radius:6px;'
        || ' padding:8px 10px; font-size:12px; overflow-x:auto;'
        || ' white-space:pre-wrap; word-break:break-all; margin-top:10px; }');
    DBMS_OUTPUT.PUT_LINE('.db-card td.trend { width:120px; }');
    DBMS_OUTPUT.PUT_LINE('footer.fleet-footer {'
        || ' text-align:center; font-size:12px; color:var(--muted); padding:24px 0; }');
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
-- before any content paints. No toggle button in v1 (OS/localStorage only);
-- copied verbatim from sql/00_params.sql's masthead early-theme script so
-- both reports share the exact same persisted preference.
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>');
END;
/

-- CDN-free sparkline renderer -- the ONLY chart mechanism in the fleet
-- report (no ECharts). Scans every [data-spark] element on DOMContentLoaded,
-- so it renders sparklines for every DB card once the whole assembled page
-- (chrome + masthead + every fragment) has parsed.
@@sql/lib/js_sparkline.plsql

-- Deliberately ends here, inside <body>, with no closing tags: the bash
-- assembler appends the masthead, every DB's fragment (sorted by score),
-- and the footer + </body></html> directly after this file's spooled
-- content.
