--
-- sql/lib/css_reldelta.plsql
--
-- The stylesheet of section 28_release_delta (Before and after a release).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_reldelta.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_reldelta: styles of section 28_release_delta (Before and after a release).');
    DBMS_OUTPUT.PUT_LINE('   Every selector starts with #release-delta; colours are the report''s tokens');
    DBMS_OUTPUT.PUT_LINE('   (status: --crit-dot worse, --imp better, --warn-dot changed, --ink-4 inside). */');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-app[hidden],#release-delta .rd-body[hidden],#release-delta .rd-more[hidden],#release-delta .rd-why[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-pick{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;margin:6px 0 4px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-pl{font-size:12px;font-weight:600;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-mks{display:inline-flex;flex-wrap:wrap;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-mb{font:inherit;font-size:12px;line-height:1.3;padding:3px 10px;border-radius:999px;border:1px solid var(--hairline);background:var(--panel);color:var(--ink);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-mb:hover{border-color:var(--acc)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-mb[aria-pressed="true"]{background:var(--acc-soft);border-color:var(--acc);color:var(--acc-ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-mb small{font-size:11px;font-weight:400;color:var(--ink-3);margin-left:6px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-none{font-size:12px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-bl{display:inline-flex;flex-wrap:wrap;align-items:center;gap:6px;font-size:12px;color:var(--ink-3);min-width:0;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-sel{font:inherit;font-size:12px;max-width:100%;min-width:0;padding:2px 4px;border:1px solid var(--hairline);border-radius:6px;background:var(--panel);color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-skip,#release-delta .rd-side,#release-delta .rd-why{font-size:12px;color:var(--ink-3);margin:4px 0;line-height:1.5}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-skip b,#release-delta .rd-side b{color:var(--ink-2);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-why{color:var(--ink-2);max-width:72ch}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-why code{font-size:11.5px;overflow-wrap:anywhere}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-body{container-type:inline-size;margin-top:6px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:11.5px;color:var(--ink-3);margin:6px 0 8px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg span{display:inline-flex;align-items:center;gap:5px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .k{display:inline-block;width:9px;height:9px;border-radius:50%;background:currentColor}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .k.s-worse{color:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .k.s-better{color:var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .k.s-changed{color:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .k.s-inside{color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .kb{display:inline-block;width:18px;height:9px;border-radius:3px;background:var(--zone2)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .kh{display:inline-block;width:9px;height:9px;border-radius:50%;border:2px solid var(--ink-3);box-sizing:border-box}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lg .kt{display:inline-block;width:2px;height:11px;background:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r{display:grid;grid-template-columns:minmax(0,13rem) minmax(0,1fr) 7.5rem;align-items:center;column-gap:10px;min-height:26px;border-top:1px solid var(--line)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r:not(.rd-ax):hover{background:var(--hov)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-ax{border-top:0;min-height:20px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lab{font-size:12.5px;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.fl .rd-lab{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-ax .rd-lab,#release-delta .rd-ax .rd-w{font-size:11px;color:var(--ink-3);font-weight:400}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-st{position:relative;display:block;height:26px;color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-ax .rd-st{height:20px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-sc{position:absolute;left:56px;right:56px;top:0;bottom:0}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-sc em{position:absolute;top:3px;transform:translateX(-50%);font-style:normal;font-size:10.5px;color:var(--ink-3);white-space:nowrap;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-g{position:absolute;top:0;bottom:0;width:1px;background:var(--line)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-g.z{background:var(--tick)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-band{position:absolute;top:6px;bottom:6px;border-radius:3px;background:var(--zone2)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-stem{position:absolute;top:50%;height:2.5px;margin-top:-1.25px;border-radius:2px;background:currentColor}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-tk{position:absolute;top:7px;bottom:7px;width:2px;margin-left:-1px;border-radius:1px;background:currentColor;opacity:.6}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-dot{position:absolute;top:50%;width:11px;height:11px;margin:-5.5px 0 0 -5.5px;border-radius:50%;background:currentColor;box-shadow:0 0 0 2px var(--panel);box-sizing:border-box}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-dot.hol{background:var(--panel);border:2.5px solid currentColor}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-dot.clip{border-radius:2px 50% 50% 2px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-dot.clip.neg{border-radius:50% 2px 2px 50%}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-val{position:absolute;top:50%;transform:translate(8px,-50%);font-size:11.5px;font-weight:600;white-space:nowrap;font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-val.neg{transform:translate(calc(-100% - 8px),-50%)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.s-inside .rd-val,#release-delta .rd-r.s-small .rd-val{font-weight:400;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.s-small .rd-st{color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.s-worse .rd-st,#release-delta .rd-r.s-worse .rd-w{color:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.s-better .rd-st,#release-delta .rd-r.s-better .rd-w{color:var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.s-changed .rd-st,#release-delta .rd-r.s-changed .rd-w{color:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-w{font-size:12px;color:var(--ink-3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r.fl .rd-w{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-more{margin-top:6px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-more > summary,#release-delta .rd-tf > summary,#release-delta .rd-all > summary{cursor:pointer;font-size:12.5px;color:var(--ink-2);padding:4px 0}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-na{font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-reads{font-size:13px;line-height:1.5;margin:10px 0 6px;color:var(--ink);max-width:90ch}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-tf,#release-delta .rd-all{margin-top:6px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .tblwrap{overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('#release-delta tr.rd-worse td:last-child{color:var(--crit-dot);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta tr.rd-better td:last-child{color:var(--imp);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#release-delta tr.rd-changed td:last-child{color:var(--warn-dot);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('@container (max-width:620px){');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-r{grid-template-columns:minmax(0,1fr) auto;padding:3px 0 0}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-lab{text-align:left;grid-column:1;grid-row:1}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-w{grid-column:2;grid-row:1}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-st{grid-column:1 / -1;grid-row:2}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-sc{left:46px;right:46px}');
    DBMS_OUTPUT.PUT_LINE('#release-delta .rd-ax .rd-lab{white-space:normal}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
