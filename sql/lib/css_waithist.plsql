--
-- sql/lib/css_waithist.plsql
--
-- The stylesheet of section 22_wait_histogram (Wait latency histograms).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_waithist.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_waithist: styles of section 22_wait_histogram (Wait latency histograms). */');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whbar{display:flex;flex-wrap:wrap;align-items:center;gap:var(--s2) var(--s4);margin:var(--s2) 0 var(--s3);font-size:12px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden;background:var(--panel)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg button{font:inherit;font-size:12px;border:0;background:none;color:var(--ink-2);padding:3px 11px;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg button+button{border-left:1px solid var(--line)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg button[aria-pressed="true"]{background:var(--acc-soft);color:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whseg button:focus-visible{outline:2px solid var(--acc);outline-offset:-2px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whlg{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsw{display:inline-block;width:12px;height:9px;border-radius:2px;flex:none}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsw-c{background:var(--acc);opacity:.8}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsw-n{height:0;border-top:2px solid var(--mean);border-radius:0;width:14px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsw-b{background:var(--zone2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsw-p{width:0;height:12px;border-left:1.5px solid var(--acc-ink);border-radius:0;margin-right:3px;box-shadow:5px 0 0 -0.5px var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whg{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,330px),1fr));gap:var(--s3)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whc{border:1px solid var(--line);border-radius:10px;padding:var(--s3) var(--s3) var(--s2);background:var(--panel);min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whc h3{display:block;margin:0 0 2px;font-size:13.5px;line-height:1.3;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whc h3 small{font-weight:400;color:var(--ink-3);font-size:11.5px;margin-left:4px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whs{margin:0;font-size:11.5px;color:var(--ink-3);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whw{margin:4px 0 0;font-size:12px;line-height:1.4;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whk{display:inline-flex;align-items:center;gap:3px;font-weight:600;color:var(--ink);white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whk i{font-style:normal;font-size:10px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whc-few .whk,#wait-hist .whc-nop .whk,#wait-hist .whc-same .whk{color:var(--ink-3);font-weight:500}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whp{display:none;margin-top:var(--s2);min-height:196px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist.whjs .whp{display:block}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsvg{display:block;overflow:visible}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsvg text{font-size:10px;fill:var(--ink-3);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsvg .whxl{fill:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whgl{stroke:var(--line);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whax{stroke:var(--tick);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whbnd{fill:var(--zone2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whbr{fill:var(--acc);fill-opacity:.78}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whbr.whfew{fill-opacity:.35}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whnl{fill:none;stroke:var(--mean);stroke-width:1.8;stroke-linejoin:round}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whpm{stroke-width:1.2}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whpm.whmc{stroke:var(--acc-ink)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whpm.whmn{stroke:var(--ink-3);stroke-dasharray:3 2}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsvg .whml.whmc{fill:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whsvg .whml.whmn{fill:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whhit{fill:transparent;cursor:default}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whhit.on{fill:var(--hov)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whr{margin:var(--s3) 0 var(--s1);font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whn{margin:0 0 var(--s2);font-size:12px;color:var(--ink-3);max-width:80ch}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whd{margin-top:var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whd summary{cursor:pointer;font-size:12.5px;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whd .whsc{overflow-x:auto;margin-top:var(--s2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whtbl tr.whfirst td{border-top:1px solid var(--line-2)}');
    DBMS_OUTPUT.PUT_LINE('#wait-hist .whdim{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
