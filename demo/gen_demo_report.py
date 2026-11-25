#!/usr/bin/env python3
"""
Generate the DEMO report: a synthetic "very busy production database" run
of awr_trend.sql over a 3-month span with a few releases / upgrades
marked on the timelines.

No Oracle needed.  The page chrome (CSS, shared JS) is lifted verbatim
from the SQL sources so it never drifts from the real report; each
section's markup is a hand-ported twin of the corresponding sql/NN_*.sql
emitter, fed from one coherent hourly model (awrdemo/model.py).

    python3 demo/gen_demo_report.py                # -> the three demo pages (one per design):
                                                   #    docs/examples/demo_busy_db.html (classic),
                                                   #    demo_busy_db_quiet.html, demo_busy_db_dashboard.html
    python3 demo/gen_demo_report.py out.html       # explicit output path (classic unless --design=)
    python3 demo/gen_demo_report.py --design=quiet out.html   # design: classic | quiet | dashboard
    python3 demo/gen_demo_report.py --cdn out.html # link ECharts from the CDN instead of inlining
    python3 demo/gen_demo_report.py --check        # compare with the existing files, write nothing, exit 1 if stale

See demo/README.md.
"""
from __future__ import annotations

import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from awrdemo import chrome                       # noqa: E402
from awrdemo.model import world                  # noqa: E402

ROOT = chrome.ROOT
DEFAULT_OUT = os.path.join(ROOT, "docs", "examples", "demo_busy_db.html")
# design -> demo page (the driver's design var: sql/lib/design_head.sql /
# design_tail.sql; classic includes the empty sql/lib/no_design.sql)
DESIGNS = ("classic", "quiet", "dashboard")
DESIGN_OUT = {d: os.path.join(ROOT, "docs", "examples",
                              "demo_busy_db.html" if d == "classic" else "demo_busy_db_" + d + ".html")
              for d in DESIGNS}

# (module name, AWR-SECTION tag) in driver order -- sql/awr_trend.sql's
# @@-include order, which is the VISUAL order since v1.5.0 (phase 4):
# Triage, Workload, SQL, Storage & config; 18 before 17 like the driver;
# 19 (guide + About, every view) right before 17, which stays last.
SECTIONS = [
    ("s00_params", "00_params"),
    ("s10_db_time_summary", "10_db_time_summary"),
    ("s08_overview", "08_overview"),
    ("s09_ash_timeline", "09_ash_timeline"),
    ("s07_summary", "07_summary"),
    ("s27_instance_map", "27_instance_map"),
    ("s20_load_response", "20_load_response"),
    ("s28_release_delta", "28_release_delta"),
    ("s01_windows", "01_windows"),
    ("s26_window_similarity", "26_window_similarity"),
    ("s16_day_profile", "16_day_profile"),
    ("s25_onset", "25_onset"),
    ("s13_utilization", "13_utilization"),
    ("s02_load_profile", "02_load_profile"),
    ("s03_sysmetric", "03_sysmetric"),
    ("s04_waits_fg", "04_waits_fg"),
    ("s22_wait_histogram", "22_wait_histogram"),
    ("s05_waits_bg", "05_waits_bg"),
    ("s24_blocking", "24_blocking"),
    ("s06_top_sql", "06_top_sql"),
    ("s21_volume_cost", "21_volume_cost"),
    ("s11_top_sql_ash_breakdown", "11_top_sql_ash_breakdown"),
    ("s18_sqlmon", "18_sqlmon"),
    ("s23_plan_flame", "23_plan_flame"),
    ("s14_segment_io", "14_segment_io"),
    ("s15_file_io", "15_file_io"),
    ("s12_param_changes", "12_param_changes"),
    ("s19_reference", "19_reference"),
    ("s17_narrative", "17_narrative"),
]


# sql/lib/viz_head.sql's @@ order: the stylesheets of sections 20-28, then
# plan 039's card qualifier, plan 043's time model table
VIZ_CSS = ("loadresp", "volcost", "waithist", "planflame", "blocking",
           "onset", "winsim", "instmap", "reldelta", "baseconf", "timemodel")


def marker(tag: str, which: str) -> str:
    return f"<!-- AWR-SECTION: {tag} {which} -->"


def prologue(w, echarts_src: str, design: str = "classic") -> str:
    """awr_trend.sql lines 512-538: <!DOCTYPE> .. the marker include."""
    out = []
    out.append("<!DOCTYPE html>")
    out.append('<html lang="en"><head><meta charset="utf-8">')
    out.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    out.append("<title>AWR Timeline Comparison &mdash; run " + w.run_id + "</title>")
    out.append(chrome.style_block())
    # sql/lib/viz_head.sql: one stylesheet per visualization section (20-28)
    for base in VIZ_CSS:
        out.append(chrome.lib_script("css_" + base + ".plsql"))
    if design != "classic":
        # sql/lib/design_head.sql: the fonts, then the design stylesheet
        out.append(chrome.lib_script("css_fonts.plsql"))
        out.append(chrome.lib_script("css_design.plsql"))
    out.append("</head><body>")
    out.append('<script src="' + echarts_src
               + '" onerror="document.body.classList.add(\'no-charts\')"></script>')
    if echarts_src.startswith("http"):
        out.append('<div class="cdn-warn">Charts hidden: the ECharts CDN (cdn.jsdelivr.net) '
                   'could not be reached. Tables still show every number.</div>')
    else:
        out.append('<div class="cdn-warn">Charts hidden: the ECharts library could not be '
                   'loaded. Tables still show every number.</div>')
    out.append("<script>window.AWR_DATA = window.AWR_DATA || {};</script>")
    out.append(chrome.lib_script("js_wait_colors.plsql"))
    out.append(chrome.lib_script("js_microstrip.plsql"))
    out.append(chrome.lib_script("js_markers.plsql"))
    # sql/lib/markers_inline.sql: one push per milestone
    for t, label in w.markers:
        lbl = label.replace("\\", "\\\\").replace('"', '\\"').replace("</", "<\\/")
        out.append('<script>window.AWR_MARKERS.push({t:"' + t.strftime("%Y-%m-%d %H:%M")
                   + '",label:"' + lbl + '"});</script>')
    # v1.6.0: the window component + entity-link unwrap (after the markers)
    out.append(chrome.lib_script("js_wingrid.plsql"))
    out.append(chrome.lib_script("js_timeline.plsql"))
    return "\n".join(out) + "\n"


def epilogue(w, design: str = "classic") -> str:
    tail = ""
    if design != "classic":
        # sql/lib/design_tail.sql: the design name, then its script
        tail = ('<script>window.AWR_DESIGN="' + design + '";</script>\n'
                + chrome.lib_script("js_design.plsql") + "\n")
    return ('</main>\n<footer class="report">\n'
            "Generated by awr_trend.sql v" + w.awr_version
            + " &mdash; run " + w.run_id
            + " &mdash; read-only against the source database, no scratch schema.\n"
            "</footer>\n" + tail + "</body></html>\n")


def render(w, echarts_src: str, only: set | None = None, design: str = "classic") -> str:
    parts = [prologue(w, echarts_src, design)]
    for mod_name, tag in SECTIONS:
        if only and tag not in only:
            continue
        try:
            mod = importlib.import_module("awrdemo.sections." + mod_name)
        except ModuleNotFoundError:
            parts.append(marker(tag, "BEGIN") + "\n"
                         + f"<!-- demo: section {tag} not ported yet -->\n"
                         + marker(tag, "END") + "\n")
            continue
        body = mod.emit(w)
        if not body.endswith("\n"):
            body += "\n"
        parts.append(body)
    parts.append(epilogue(w, design))
    return "".join(parts)


def inline_echarts(html: str, src_rel: str) -> str:
    """run_awr_trend.sh's inline_echarts: splice vendor/echarts.min.js in
    place of the <script src=...> tag for a self-contained file."""
    tag = '<script src="' + src_rel + '" onerror="document.body.classList.add(\'no-charts\')"></script>'
    with open(os.path.join(ROOT, src_rel), encoding="utf-8") as fh:
        js = fh.read()
    return html.replace(tag, "<script>\n" + js + "\n</script>", 1)


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    designs = [f[len("--design="):] for f in flags if f.startswith("--design=")]
    for d in designs:
        if d not in DESIGNS:
            print(f"unknown design {d!r}; one of: {', '.join(DESIGNS)}")
            return 2
    if args:
        # an explicit path: one page, classic unless --design= says otherwise
        jobs = [(designs[0] if designs else "classic", args[0])]
    else:
        jobs = [(d, DESIGN_OUT[d]) for d in (designs or DESIGNS)]
    w = world()
    if "--cdn" in flags:
        src = "https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js"
    else:
        src = w.echarts
    only = None
    for f in flags:
        if f.startswith("--only="):
            only = set(f[len("--only="):].split(","))
    rc = 0
    for design, out_path in jobs:
        html = render(w, src, only, design)
        if "--cdn" not in flags and "--no-inline" not in flags:
            html = inline_echarts(html, src)
        if "--check" in flags:
            try:
                with open(out_path, encoding="utf-8") as fh:
                    current = fh.read()
            except OSError:
                current = None
            if current != html:
                print(f"STALE: {out_path} is not what the generator produces now. "
                      "Run: python3 demo/gen_demo_report.py  and commit the result.")
                rc = 1
            else:
                print(f"up to date: {out_path}")
            continue
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(html)
        print(f"wrote {out_path} ({len(html.encode('utf-8'))/1024:.0f} KB)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
