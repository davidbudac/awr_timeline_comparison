--
-- _style.sql
-- Emits the <style> and tiny JS fragment shared by every section of the
-- HTML report.  Called once from awr_trend.sql after the <head> opens.
--

SET DEFINE OFF

BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#172033; --bg:#f5f7fb; --panel:#ffffff; --panel-2:#f0f4fb;'
        || ' --muted:#63708a; --border:#d5ddea; --border-strong:#b4c1d8; --shadow:0 16px 40px rgba(23,32,51,.08);'
        || ' --crit:#ffe8e2; --crit-fg:#a43a22; --warn:#fff2d8; --warn-fg:#956200;'
        || ' --ok:#e6f7ef; --ok-fg:#1d6a46; --info:#eaf2ff; --info-fg:#264a92;'
        || ' --accent:#1769aa; --accent-2:#34a0a4; --spark:#1769aa; --spark-fill:rgba(23,105,170,.14);'
        || ' --spark-grid:#dbe4f1; }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: dark) {');
    DBMS_OUTPUT.PUT_LINE(':root { --fg:#e8edf7; --bg:#0f1420; --panel:#141b29; --panel-2:#182233;'
        || ' --muted:#94a0b8; --border:#273349; --border-strong:#3b4b67; --shadow:none;'
        || ' --crit:#402019; --crit-fg:#ffbba6; --warn:#413318; --warn-fg:#ffd991;'
        || ' --ok:#143325; --ok-fg:#9ee0bf; --info:#18294c; --info-fg:#bfd4ff;'
        || ' --accent:#74b8ff; --accent-2:#69d0c5; --spark:#8dc6ff; --spark-fill:rgba(116,184,255,.16);'
        || ' --spark-grid:#2b3851; } }');
    DBMS_OUTPUT.PUT_LINE('* { box-sizing:border-box; }');
    DBMS_OUTPUT.PUT_LINE('html,body { margin:0; padding:0; background:var(--bg); color:var(--fg);'
        || ' font-family:"Avenir Next","Segoe UI","Helvetica Neue",Arial,sans-serif;'
        || ' font-size:14px; line-height:1.5; }');
    DBMS_OUTPUT.PUT_LINE('body { max-width:1500px; margin:0 auto; padding:28px 24px 48px 24px;'
        || ' display:flex; flex-direction:column; gap:18px;'
        || ' background-image:radial-gradient(circle at top left, rgba(52,160,164,.08), transparent 28%),'
        || ' radial-gradient(circle at top right, rgba(23,105,170,.08), transparent 24%); }');
    DBMS_OUTPUT.PUT_LINE('h1 { font-size:30px; line-height:1.15; margin:0 0 10px 0; letter-spacing:-0.03em; }');
    DBMS_OUTPUT.PUT_LINE('h2 { font-size:19px; margin:0 0 10px 0; padding-bottom:10px; border-bottom:1px solid var(--border); letter-spacing:-0.02em; }');
    DBMS_OUTPUT.PUT_LINE('h3 { font-size:15px; margin:18px 0 10px 0; color:var(--muted); font-weight:700; letter-spacing:.01em; }');
    DBMS_OUTPUT.PUT_LINE('p { margin:0 0 10px 0; }');
    DBMS_OUTPUT.PUT_LINE('header.report { position:relative; overflow:hidden;'
        || ' background:linear-gradient(135deg, rgba(23,105,170,.14), rgba(52,160,164,.08) 55%, transparent 100%), var(--panel);'
        || ' color:var(--fg); padding:24px 24px 20px 24px; border:1px solid var(--border);'
        || ' border-radius:22px; box-shadow:var(--shadow); }');
    DBMS_OUTPUT.PUT_LINE('header.report::after { content:""; position:absolute; inset:auto -80px -110px auto; width:280px; height:280px;'
        || ' border-radius:50%; background:radial-gradient(circle, rgba(23,105,170,.14), transparent 68%); pointer-events:none; }');
    DBMS_OUTPUT.PUT_LINE('.eyebrow { text-transform:uppercase; letter-spacing:.14em; font-size:11px; color:var(--muted); margin-bottom:10px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-grid { display:grid; grid-template-columns:minmax(0,1.4fr) minmax(280px,.9fr); gap:18px 28px; align-items:start; }');
    DBMS_OUTPUT.PUT_LINE('.hero-copy { max-width:760px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-copy .lede { font-size:15px; color:var(--muted); max-width:64ch; }');
    DBMS_OUTPUT.PUT_LINE('.hero-badges { display:flex; flex-wrap:wrap; gap:8px; margin-top:14px; }');
    DBMS_OUTPUT.PUT_LINE('.hero-stats { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }');
    DBMS_OUTPUT.PUT_LINE('.stat-line { background:rgba(255,255,255,.54); border:1px solid var(--border); border-radius:16px; padding:12px 14px; }');
    DBMS_OUTPUT.PUT_LINE('.stat-line span { display:block; font-size:11px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); margin-bottom:4px; }');
    DBMS_OUTPUT.PUT_LINE('.stat-line strong { display:block; font-size:15px; line-height:1.3; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr));'
        || ' gap:10px 18px; margin-top:18px; padding-top:16px; border-top:1px solid var(--border); font-size:13px; }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta div { color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('header.report .meta b { color:var(--fg); }');
    DBMS_OUTPUT.PUT_LINE('nav.toc { position:sticky; top:0; background:rgba(245,247,251,.88); backdrop-filter:blur(12px);'
        || ' padding:12px 16px; border:1px solid var(--border); border-radius:16px; z-index:5; font-size:13px; box-shadow:var(--shadow); }');
    DBMS_OUTPUT.PUT_LINE('@media (prefers-color-scheme: dark) { nav.toc { background:rgba(15,20,32,.82); } .stat-line { background:rgba(255,255,255,.02); } }');
    DBMS_OUTPUT.PUT_LINE('nav.toc { order:1; }');
    DBMS_OUTPUT.PUT_LINE('header.report { order:2; }');
    DBMS_OUTPUT.PUT_LINE('#findings { order:3; }');
    DBMS_OUTPUT.PUT_LINE('#windows { order:4; }');
    DBMS_OUTPUT.PUT_LINE('#load { order:5; }');
    DBMS_OUTPUT.PUT_LINE('#metrics { order:6; }');
    DBMS_OUTPUT.PUT_LINE('#waits-fg { order:7; }');
    DBMS_OUTPUT.PUT_LINE('#waits-bg { order:8; }');
    DBMS_OUTPUT.PUT_LINE('#topsql { order:9; }');
    DBMS_OUTPUT.PUT_LINE('footer.report { order:10; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc b { margin-right:12px; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a { color:var(--accent); text-decoration:none; margin-right:14px; font-weight:600; }');
    DBMS_OUTPUT.PUT_LINE('nav.toc a:hover { text-decoration:underline; }');
    DBMS_OUTPUT.PUT_LINE('section { background:var(--panel); border:1px solid var(--border); border-radius:22px;'
        || ' padding:20px 20px 18px 20px; box-shadow:var(--shadow); overflow-x:auto; }');
    DBMS_OUTPUT.PUT_LINE('table { width:100%; border-collapse:separate; border-spacing:0; margin:10px 0 6px 0; font-size:13px; min-width:860px; }');
    DBMS_OUTPUT.PUT_LINE('thead th { background:var(--panel); position:sticky; top:66px; z-index:2;'
        || ' text-align:left; padding:10px 10px; border-bottom:1px solid var(--border-strong); white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('tbody td { padding:8px 10px; border-bottom:1px solid var(--border); vertical-align:top; }');
    DBMS_OUTPUT.PUT_LINE('tbody tr:hover { background:rgba(23,105,170,0.05); }');
    DBMS_OUTPUT.PUT_LINE('td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }');
    DBMS_OUTPUT.PUT_LINE('td.mono, code, .mono { font-family:"IBM Plex Mono","SFMono-Regular",Menlo,Consolas,monospace; font-size:12px; }');
    DBMS_OUTPUT.PUT_LINE('tr.crit   { background:var(--crit); }  tr.crit td:first-child { border-left:4px solid var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.warn   { background:var(--warn); }  tr.warn td:first-child { border-left:4px solid var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.ok     { background:transparent; }');
    DBMS_OUTPUT.PUT_LINE('tr.info   { background:var(--info); color:var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('tr.skip   { color:var(--muted); font-style:italic; }');
    DBMS_OUTPUT.PUT_LINE('.badge { display:inline-block; padding:3px 9px; border-radius:999px; font-size:11px; font-weight:700; letter-spacing:.01em; }');
    DBMS_OUTPUT.PUT_LINE('.badge.crit { background:var(--crit); color:var(--crit-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.warn { background:var(--warn); color:var(--warn-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.ok   { background:var(--ok);   color:var(--ok-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.info { background:var(--info); color:var(--info-fg); }');
    DBMS_OUTPUT.PUT_LINE('.badge.skip { background:var(--panel-2); color:var(--muted); }');
    DBMS_OUTPUT.PUT_LINE('.bar { display:block; height:4px; background:linear-gradient(90deg,var(--accent),var(--accent-2)); opacity:.65; border-radius:2px; margin-top:3px; }');
    DBMS_OUTPUT.PUT_LINE('.trend-cell { min-width:148px; width:148px; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline { display:block; width:132px; height:34px; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline svg { display:block; width:100%; height:100%; overflow:visible; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline .grid { stroke:var(--spark-grid); stroke-width:1; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline .area { fill:var(--spark-fill); }');
    DBMS_OUTPUT.PUT_LINE('.sparkline .line { fill:none; stroke:var(--spark); stroke-width:2.1; stroke-linecap:round; stroke-linejoin:round; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline .dot { fill:var(--spark); stroke:var(--panel); stroke-width:1.5; }');
    DBMS_OUTPUT.PUT_LINE('.sparkline.empty::before { content:"No trend"; color:var(--muted); font-size:11px; }');
    DBMS_OUTPUT.PUT_LINE('details { margin:4px 0; }');
    DBMS_OUTPUT.PUT_LINE('details summary { cursor:pointer; padding:6px 0; font-weight:700; color:var(--accent); }');
    DBMS_OUTPUT.PUT_LINE('pre.sql { background:rgba(127,127,127,.08); padding:10px; border-radius:10px;'
        || ' overflow-x:auto; white-space:pre-wrap; font-size:12px; font-family:ui-monospace,Consolas,monospace; }');
    DBMS_OUTPUT.PUT_LINE('footer.report { color:var(--muted); font-size:12px; margin-top:8px; padding:0 6px; }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px) { body { padding:18px 14px 36px 14px; } .hero-grid { grid-template-columns:1fr; } .hero-stats { grid-template-columns:1fr 1fr; } thead th { top:58px; } }');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 680px) { .hero-stats { grid-template-columns:1fr; } nav.toc { overflow-x:auto; white-space:nowrap; } table { min-width:720px; } }');
    DBMS_OUTPUT.PUT_LINE('@media print { nav.toc { display:none; } thead th { position:static; } body { max-width:none; background:none; } section, header.report { box-shadow:none; } }');
    DBMS_OUTPUT.PUT_LINE('</style>');
    DBMS_OUTPUT.PUT_LINE(q'!<script>
document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll(".sparkline").forEach(function (el) {
    var raw = (el.getAttribute("data-points") || "").split("|");
    var pts = raw.map(function (token) {
      if (token === "" || token === "null") return null;
      var num = Number(token);
      return Number.isFinite(num) ? num : null;
    });
    var valid = pts.map(function (v, i) { return [i, v]; }).filter(function (pair) { return pair[1] !== null; });
    if (!valid.length) {
      el.classList.add("empty");
      return;
    }

    var width = 132;
    var height = 34;
    var pad = 3;
    var min = Math.min.apply(null, valid.map(function (pair) { return pair[1]; }));
    var max = Math.max.apply(null, valid.map(function (pair) { return pair[1]; }));
    if (max === min) {
      max = min + (Math.abs(min) || 1);
      min = min - (Math.abs(min) || 1);
    }
    var usableW = width - pad * 2;
    var usableH = height - pad * 2;
    var step = pts.length > 1 ? usableW / (pts.length - 1) : 0;

    function x(i) { return (pad + i * step).toFixed(2); }
    function y(v) {
      return (height - pad - ((v - min) / (max - min)) * usableH).toFixed(2);
    }

    var poly = valid.map(function (pair) { return x(pair[0]) + "," + y(pair[1]); }).join(" ");
    var first = valid[0];
    var last = valid[valid.length - 1];
    var area = poly + " " + x(last[0]) + "," + (height - pad) + " " + x(first[0]) + "," + (height - pad);

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 " + width + " " + height);
    svg.setAttribute("aria-hidden", "true");

    var grid = document.createElementNS(svg.namespaceURI, "line");
    grid.setAttribute("class", "grid");
    grid.setAttribute("x1", pad);
    grid.setAttribute("x2", width - pad);
    grid.setAttribute("y1", height - pad);
    grid.setAttribute("y2", height - pad);
    svg.appendChild(grid);

    if (valid.length > 1) {
      var areaPath = document.createElementNS(svg.namespaceURI, "polygon");
      areaPath.setAttribute("class", "area");
      areaPath.setAttribute("points", area);
      svg.appendChild(areaPath);
    }

    var line = document.createElementNS(svg.namespaceURI, "polyline");
    line.setAttribute("class", "line");
    line.setAttribute("points", poly);
    svg.appendChild(line);

    var dot = document.createElementNS(svg.namespaceURI, "circle");
    dot.setAttribute("class", "dot");
    dot.setAttribute("cx", x(last[0]));
    dot.setAttribute("cy", y(last[1]));
    dot.setAttribute("r", "3.2");
    svg.appendChild(dot);

    el.innerHTML = "";
    el.appendChild(svg);
  });
});
</script>!');
END;
/

SET DEFINE '~'
