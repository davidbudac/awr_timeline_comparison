--
-- _style.sql
-- Emits the <style> and tiny JS fragment shared by every section of the
-- HTML report.  Called once from awr_trend.sql after the <head> opens.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#1a1a1a; --bg:#ffffff; --muted:#666; --border:#e0e0e0;'
        || ' --crit:#ffe5e5; --crit-fg:#8a1c1c; --warn:#fff4d6; --warn-fg:#7a5a00;'
        || ' --ok:#eaf6ea; --ok-fg:#245c24; --info:#eef2ff; --info-fg:#2c3a8a;'
        || ' --accent:#2563eb; }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: dark) {');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#e6e6e6; --bg:#111317; --muted:#9aa3af; --border:#2a2f3a;'
        || ' --crit:#3a1717; --crit-fg:#ffb4b4; --warn:#3a3115; --warn-fg:#ffdb8a;'
        || ' --ok:#172a1c; --ok-fg:#a8e5b4; --info:#1b2140; --info-fg:#b4c0ff; --accent:#7aa2ff; } }');
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--bg); color:var(--fg);'
        || ' font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;'
        || ' font-size:14px; line-height:1.5; }');
    DBMS_OUTPUT.PUT_LINE('body { max-width:1400px; margin:0 auto; padding:24px; }');
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
    DBMS_OUTPUT.PUT_LINE('nav.toc a { color:var(--accent); text-decoration:none; margin-right:14px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('table { width:100%; border-collapse:collapse; margin:8px 0 16px 0; font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('thead th { background:var(--bg); position:sticky; top:38px; z-index:2;'
        || ' text-align:left; padding:8px 10px; border-bottom:2px solid var(--border); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('tbody td { padding:6px 10px; border-bottom:1px solid var(--border); vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:rgba(127,127,127,0.08); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:12px; }');
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
    DBMS_OUTPUT.PUT_LINE('.bar { display:block; height:4px; background:var(--accent); opacity:.45; border-radius:2px; margin-top:3px; }');
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
