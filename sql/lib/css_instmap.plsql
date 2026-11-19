--
-- sql/lib/css_instmap.plsql
--
-- The stylesheet of section 27_instance_map (Instance map).
-- @@-included in <head> by sql/lib/viz_head.sql (after sql/_style.sql).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/css_instmap.css -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<style>');
    DBMS_OUTPUT.PUT_LINE('/* css_instmap: styles of section 27_instance_map (Instance map).');
    DBMS_OUTPUT.PUT_LINE('   The map is one server-drawn SVG; every colour comes from the report''s');
    DBMS_OUTPUT.PUT_LINE('   tokens so the theme toggle and the quiet / dashboard designs restyle it. */');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-wrap{position:relative}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-lg{display:flex;flex-wrap:wrap;gap:4px 16px;margin:0 0 8px;padding:0;list-style:none;font-size:12px;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-lg li{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-lg .im-lgn{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k{display:inline-block;width:9px;height:9px;border-radius:50%;flex:none;box-sizing:border-box}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k.s-large{background:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k.s-moderate{background:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k.s-improved{border:2px solid var(--imp)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k.s-typical{border:1.5px solid var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-k.s-nm{border:1.5px dashed var(--muted);opacity:.7}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-scroll{overflow-x:auto;overflow-y:hidden;-webkit-overflow-scrolling:touch}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-svg{display:block;width:100%;min-width:740px;max-width:1120px;height:auto;font-family:inherit}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-ct{fill:var(--surface-2);stroke:var(--line);stroke-dasharray:5 4}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-cl{font-size:11px;fill:var(--muted);letter-spacing:.02em}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-al{font-size:11px;fill:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-b{fill:var(--panel);stroke:var(--line-2);stroke-width:1}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-t{font-size:13px;font-weight:600;fill:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-m{font-size:12px;fill:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-s{font-size:12px;fill:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-sw{font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-d{fill:none;stroke:var(--muted);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-large .im-b{fill:color-mix(in srgb,var(--crit-dot) 10%,var(--panel));stroke:var(--crit-dot);stroke-width:1.8}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-large .im-d{fill:var(--crit-dot);stroke:none}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-moderate .im-b{fill:color-mix(in srgb,var(--warn-dot) 11%,var(--panel));stroke:var(--warn-dot);stroke-width:1.8}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-moderate .im-d{fill:var(--warn-dot);stroke:none}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-improved .im-b{stroke:var(--imp);stroke-width:1.5}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-improved .im-d{stroke:var(--imp);stroke-width:2}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-nm .im-b{fill:none;stroke-dasharray:4 3}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-nm .im-d{stroke-dasharray:2 2}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n.s-nm .im-t,#instance-map .im-n.s-nm .im-m,#instance-map .im-n.s-nm .im-s{fill:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n{cursor:default;outline:none}');
    DBMS_OUTPUT.PUT_LINE('#instance-map a.im-n{cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n:hover .im-b,#instance-map .im-n.on .im-b{stroke-width:2.4}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-n:focus-visible .im-b{stroke:var(--acc);stroke-width:2.6}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a polyline{fill:none;stroke:var(--tick);stroke-width:1.5;stroke-linejoin:round}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a polygon{fill:var(--tick)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a.dash polyline{stroke-dasharray:3 3}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a.s-large polyline{stroke:var(--crit-dot);stroke-width:3.5}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a.s-large polygon{fill:var(--crit-dot)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a.s-moderate polyline{stroke:var(--warn-dot);stroke-width:2.6}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-a.s-moderate polygon{fill:var(--warn-dot)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-rd{margin:8px 0 12px;color:var(--ink-2)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pop{position:absolute;z-index:30;max-width:360px;min-width:220px;background:var(--panel);color:var(--ink);border:1px solid var(--line-2);border-radius:8px;box-shadow:0 6px 20px rgba(0,0,0,.18);padding:10px 12px;font-size:12px;line-height:1.45}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pop[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pt{font-size:13px}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-st{display:inline-flex;align-items:center;gap:5px;margin-left:6px;font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pw{margin:4px 0;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pm{margin:6px 0 0;padding:0 0 0 2px;list-style:none}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pm li{margin:3px 0}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pv{color:var(--ink-2);font-variant-numeric:tabular-nums}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pc{margin:8px 0 0}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pop a.im-go{color:var(--acc-ink);font-weight:600;text-decoration:none;margin-right:10px}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-pop a.im-go:hover{text-decoration:underline}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-tbl .im-tst{white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-tbl .im-tst .im-k{margin-right:6px;vertical-align:-1px}');
    DBMS_OUTPUT.PUT_LINE('#instance-map .im-tscroll{overflow-x:auto;max-width:100%}');
    DBMS_OUTPUT.PUT_LINE('</style>');
END;
/
