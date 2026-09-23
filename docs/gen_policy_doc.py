#!/usr/bin/env python3
"""Render docs/metric_policy.html from sql/lib/metric_policy.plsql.

The policy file is the single source of truth for how every load
statistic, system metric, wait class and wait event is scored (direction,
minimum %-delta, value floor).  This page is generated from it so the
documentation can never drift from the code:

    python3 docs/gen_policy_doc.py          # rewrites docs/metric_policy.html

Docs tooling only (like demo/): nothing under sql/ depends on it.
"""
from __future__ import annotations

import datetime as _dt
import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(ROOT, "sql", "lib", "metric_policy.plsql")
OUT = os.path.join(ROOT, "docs", "metric_policy.html")

sys.path.insert(0, os.path.join(ROOT, "demo"))
from awrdemo import helpers as h  # noqa: E402  (parses the policy file)

# --------------------------------------------------------------------------
# Units and plain-English names (documentation only -- the policy file
# carries the numbers, this table carries what the numbers mean).
# --------------------------------------------------------------------------
LOAD_UNIT = {
    "DB time": "cs/s (centiseconds of DB time per second; 100 = one average active session)",
    "DB CPU": "cs/s (100 = one CPU fully busy)",
    "CPU used by this session": "cs/s (100 = one CPU fully busy)",
    "physical read total bytes": "bytes/s",
    "physical write total bytes": "bytes/s",
    "redo size": "bytes/s",
    "redo size for lost write detection": "bytes/s",
    "bytes sent via SQL*Net to client": "bytes/s",
    "bytes received via SQL*Net from client": "bytes/s",
    "session logical reads": "blocks/s",
    "physical reads": "blocks/s",
    "physical writes": "blocks/s",
}
METRIC_UNIT = {
    "Host CPU Utilization (%)": "% of host CPU",
    "Database CPU Time Ratio": "% of DB time spent on CPU",
    "Database Wait Time Ratio": "% of DB time spent waiting",
    "Average Active Sessions": "sessions",
    "Average Synchronous Single-Block Read Latency": "ms per single-block read",
    "Session Count": "sessions",
    "SQL Service Response Time": "cs per user call (0.1 = 1 ms)",
    "Network Traffic Volume Per Sec": "bytes/s",
    "Physical Read Total Bytes Per Sec": "bytes/s",
    "Physical Write Total Bytes Per Sec": "bytes/s",
    "Redo Generated Per Sec": "bytes/s",
}
DIR_TXT = {
    "UP":   ("rise is bad", "A rise is a finding; a drop is <i>improved</i> (never highlighted)."),
    "DOWN": ("drop is bad", "A drop is a finding; a rise is <i>improved</i> (never highlighted)."),
    "ANY":  ("either way", "Both directions are findings: a drop can be an outage, a rise a storm. Nothing is called improved."),
    "INFO": ("informational", "Never a finding. A material move renders as <i>noted</i> (grey, not counted)."),
}
FAMILY_TXT = {
    "DB_TIME": "DB time", "CPU": "CPU", "CPU_WAIT_RATIO": "CPU / wait ratio",
    "LOGICAL_IO": "logical I/O", "READ_IO": "read I/O", "WRITE_IO": "write I/O",
    "REDO": "redo", "CALLS": "user calls", "EXEC": "executions", "COMMIT": "commits",
    "ROLLBACK": "rollbacks", "PARSE": "parses", "HARD_PARSE": "hard parses",
    "SORTS": "sorts", "SORTS_DISK": "disk sorts", "SESSIONS": "sessions / logons",
    "CURSORS": "cursors", "SCANS": "full table scans", "NETWORK": "network",
    "RESPONSE": "response time",
}


def unit_of(domain: str, name: str) -> str:
    if domain == "LOAD":
        return LOAD_UNIT.get(name, "/s")
    if name in METRIC_UNIT:
        return METRIC_UNIT[name]
    if "Per Sec" in name:
        return "/s"
    return ""


def fmt(v: float | None, unit: str = "") -> str:
    if v is None:
        return "&mdash;"
    if unit.startswith("bytes"):
        if v >= 1048576:
            return f"{v / 1048576:g} MB/s"
        if v >= 1024:
            return f"{v / 1024:g} KB/s"
        return f"{v:g} B/s"
    if v == int(v):
        return f"{int(v):,}"
    return f"{v:g}"


def read_notes() -> dict[tuple[str, str], str]:
    """Trailing '-- note' comment per policy line, keyed by (domain, name)."""
    notes: dict[tuple[str, str], str] = {}
    domain = None
    for line in open(POLICY, encoding="utf-8"):
        m = re.search(r"p_domain\s*=\s*'(\w+)'", line)
        if m and "IF" in line:
            domain = m.group(1)
        m = re.match(r"\s*WHEN\s+'([^']*)'\s+THEN\s+RETURN\s+w?pol\(.*?\);\s*--\s*(.*)$", line)
        if m and domain:
            notes[(domain, m.group(1))] = m.group(2).strip()
    return notes


# --------------------------------------------------------------------------
# Per-row prose: when it fires, when it does not, with concrete numbers.
# --------------------------------------------------------------------------
def fires_text(domain, name, fam, canon, d, min_pct, min_abs, unit) -> tuple[str, str]:
    mp = 10 if min_pct is None else min_pct
    floor_txt = ""
    if min_abs is not None:
        if domain == "WAIT":
            floor_txt = (f" and the event or class holds at least <b>{min_abs * 100:g}%</b> of the "
                         f"Current window's non-idle wait time")
        else:
            floor_txt = (f" and at least one of Current / prior mean is <b>&ge; {fmt(min_abs, unit)}"
                         f"{'' if unit.startswith('bytes') else ' ' + unit.split(' (')[0]}</b>")
    base = (f"|z| &gt; 2 (moderate) or &gt; 3 (large) against the prior windows, "
            f"the move is at least <b>{mp:g}%</b> of the prior mean{floor_txt}")
    if d == "UP":
        yes = f"<b>Rise</b> of {base}."
        no = (f"Any drop (it is <i>improved</i>); a rise below {mp:g}%; "
              + (f"both Current and prior mean below the floor; " if min_abs is not None and domain != "WAIT" else "")
              + (f"a share below {min_abs * 100:g}%; " if min_abs is not None and domain == "WAIT" else "")
              + "|z| &le; 2 (inside the usual spread); fewer than 3 prior windows.")
    elif d == "DOWN":
        yes = f"<b>Drop</b> of {base}."
        no = (f"Any rise (it is <i>improved</i>); a drop below {mp:g}%; "
              + (f"both values below the floor; " if min_abs is not None else "")
              + "|z| &le; 2; fewer than 3 prior windows.")
    elif d == "ANY":
        yes = f"<b>Rise or drop</b> of {base}."
        no = (f"A move below {mp:g}% either way; "
              + (f"both values below the floor; " if min_abs is not None else "")
              + "|z| &le; 2; fewer than 3 prior windows.")
    else:
        yes = "Never. A material move is shown as <i>noted</i> only."
        no = "Always (informational counter)."
    return yes, no


def example_text(domain, name, d, min_pct, min_abs, unit) -> str:
    """One concrete pair of numbers: a case that does NOT fire and one that does."""
    if d == "INFO":
        return "&mdash;"
    mp = 10 if min_pct is None else min_pct
    u = "" if unit.startswith("bytes") else " " + unit.split(" (")[0]
    if domain == "WAIT":
        return (f"An event at {max(min_abs * 100 / 2, 0.2):g}% of Current wait time doubling: no (share below "
                f"{min_abs * 100:g}%). The same event at {min_abs * 100 * 3:g}% of Current wait, up "
                f"{mp + 10:g}% on a steady baseline: yes.")
    if min_abs is not None:
        lo_a = min_abs * 0.1
        lo_b = min_abs * 0.6
        hi_a = min_abs * 4
        hi_b = hi_a * (1 + (mp + 10) / 100)
        ex_no = (f"{fmt(lo_a, unit)}{u} &rarr; {fmt(lo_b, unit)}{u} (+{(lo_b / lo_a - 1) * 100:.0f}%): "
                 f"no, both below {fmt(min_abs, unit)}{u}")
        if d == "DOWN":
            ex_yes = (f"{fmt(hi_b, unit)}{u} &rarr; {fmt(hi_a, unit)}{u} "
                      f"(&minus;{(1 - hi_a / hi_b) * 100:.0f}%) on a steady baseline: yes")
        else:
            ex_yes = (f"{fmt(hi_a, unit)}{u} &rarr; {fmt(hi_b, unit)}{u} "
                      f"(+{mp + 10:.0f}%) on a steady baseline: yes")
    else:
        ex_no = f"a move of {max(mp - 5, 1):g}%: no (below {mp:g}%)"
        ex_yes = f"a move of {mp + 10:g}% on a steady baseline: yes"
    return f"{ex_no}. {ex_yes}."


# --------------------------------------------------------------------------
# HTML
# --------------------------------------------------------------------------
CSS = """
:root{--paper:#FFFFFF;--panel:#FFFFFF;--panel-2:#F7F9FB;--ink:#10213A;--ink-soft:#34465E;--muted:#5E6E82;
--rule:#CBD3DD;--hairline:#E2E7ED;--accent:#1D5BB8;--accent-deep:#15478F;--accent-bg:#EBF2FC;
--crit:#B42318;--warn:#A15C07;--ok:#1A7F4B;--skip:#5E6E82;--crit-bg:#FDECEA;--warn-bg:#FDF3E3;--ok-bg:#E8F5EE;--skip-bg:#EEF1F5;
--sans:"IBM Plex Sans",-apple-system,"Segoe UI",Roboto,sans-serif;--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;color-scheme:light;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--paper:#0E1621;--panel:#131E2C;--panel-2:#111B28;--ink:#E4EAF2;--ink-soft:#C3CEDB;
--muted:#95A3B5;--rule:#30415A;--hairline:#223044;--accent:#7DB0F5;--accent-deep:#A6C9F8;--accent-bg:#16263C;
--crit:#F28B82;--warn:#F2B25C;--ok:#6BCB94;--skip:#95A3B5;--crit-bg:#3A1C1E;--warn-bg:#3A2A14;--ok-bg:#14301F;--skip-bg:#1C2737;color-scheme:dark;}}
:root[data-theme="dark"]{--paper:#0E1621;--panel:#131E2C;--panel-2:#111B28;--ink:#E4EAF2;--ink-soft:#C3CEDB;
--muted:#95A3B5;--rule:#30415A;--hairline:#223044;--accent:#7DB0F5;--accent-deep:#A6C9F8;--accent-bg:#16263C;
--crit:#F28B82;--warn:#F2B25C;--ok:#6BCB94;--skip:#95A3B5;--crit-bg:#3A1C1E;--warn-bg:#3A2A14;--ok-bg:#14301F;--skip-bg:#1C2737;color-scheme:dark;}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:14.5px/1.6 var(--sans);-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
.top{position:sticky;top:0;z-index:5;background:var(--paper);border-bottom:1px solid var(--hairline)}
.top div{max-width:1180px;margin:0 auto;padding:0 16px;height:52px;display:flex;align-items:center;gap:18px;font-size:14px}
.top a{color:var(--ink-soft);text-decoration:none;font-weight:500}.top a:hover{color:var(--accent)}
.top a.home{color:var(--ink);font-weight:600;margin-right:auto}
main{max-width:1180px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:28px;font-weight:600;letter-spacing:-.015em;margin:0 0 4px}h2{font-size:20px;font-weight:600;margin:36px 0 10px;padding-top:12px;border-top:1px solid var(--hairline)}
h3{font-size:15px;margin:22px 0 6px}
.sub{color:var(--muted);margin:0 0 18px}
.card{background:var(--panel);border:1px solid var(--hairline);border-radius:10px;padding:14px 18px;margin:10px 0}
code,.mono{font-family:var(--mono);font-size:12.5px}
code{background:var(--panel-2);padding:1px 5px;border-radius:4px}
table{border-collapse:collapse;width:100%;background:var(--panel);border:1px solid var(--hairline);border-radius:8px;font-size:12.5px}
th,td{padding:7px 9px;vertical-align:top;border-top:1px solid var(--hairline);text-align:left}
thead th{background:var(--panel-2);font-size:12px;font-weight:600;color:var(--ink-soft);border-top:0;border-bottom:1px solid var(--rule);position:sticky;top:0}
td.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.badge{display:inline-block;font-size:10.5px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;padding:2px 7px;border-radius:999px;white-space:nowrap}
.b-up{background:var(--crit-bg);color:var(--crit)}.b-down{background:var(--warn-bg);color:var(--warn)}
.b-any{background:var(--accent-bg);color:var(--accent-deep)}.b-info{background:var(--skip-bg);color:var(--skip)}
.b-crit{background:var(--crit-bg);color:var(--crit)}.b-warn{background:var(--warn-bg);color:var(--warn)}
.b-ok{background:var(--ok-bg);color:var(--ok)}.b-imp{background:transparent;color:var(--ok);box-shadow:inset 0 0 0 1px var(--ok-bg)}
.b-note,.b-skip{background:transparent;color:var(--skip);box-shadow:inset 0 0 0 1px var(--skip-bg)}
.twin{color:var(--muted)}
.why{color:var(--muted);font-size:12px}
.tblwrap{overflow-x:auto;margin:8px 0 14px}
ol.steps li{margin:6px 0}
.toc a{margin-right:14px;color:var(--accent);font-weight:500;text-decoration:none}
.legend{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px}
.kv{display:grid;grid-template-columns:150px 1fr;gap:4px 12px;font-size:13px}
.kv b{color:var(--ink-soft)}
footer{margin-top:40px;color:var(--muted);font-size:12px}
@media (max-width:700px){.kv{grid-template-columns:1fr}}
"""


HEAD_EXTRA = (
    '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
    '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&amp;family=IBM+Plex+Sans:wght@400;500;600&amp;display=swap">'
    "<script>try{var t=localStorage.getItem('awr-theme');if(t==='dark'||t==='light')document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>"
)
TOP_BAR = ('<header class="top"><div><a class="home" href="index.html">AWR Timeline Comparison</a>'
           '<a href="index.html#s-install">Quick start</a><a href="index.html#docs">Docs</a>'
           '<a href="cheatsheet.html">Cheat sheet</a><a href="configurator.html">Configurator</a></div></header>')


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def badge_dir(d: str) -> str:
    return f'<span class="badge b-{d.lower()}">{d}</span> <span class="why">{DIR_TXT[d][0]}</span>'


def row(domain, name, pol, notes, unit_override=None):
    fam, canon, d, min_pct, min_abs = pol
    unit = unit_override if unit_override is not None else unit_of(domain, name)
    yes, no = fires_text(domain, name, fam, canon, d, min_pct, min_abs, unit)
    ex = example_text(domain, name, d, min_pct, min_abs, unit)
    note = notes.get((domain, name), "")
    u_short = "" if unit.startswith("bytes") else " " + unit.split(" (")[0] if unit else ""
    if domain == "WAIT":
        floor_cell = "&mdash;" if min_abs is None else f"{min_abs * 100:g}% share"
    else:
        floor_cell = "&mdash;" if min_abs is None else f"{fmt(min_abs, unit)}{u_short}"
    cls = ' class="twin"' if canon == "N" else ""
    twin = ' <span class="badge b-skip" title="scored and shown muted, never counted; its family lead carries the finding">twin</span>' if canon == "N" else ""
    fam_txt = FAMILY_TXT.get(fam, fam.replace("WAIT:", "wait class "))
    return (f"<tr{cls}><td><b>{esc(name)}</b>{twin}<div class='why'>{esc(unit)}</div></td>"
            f"<td>{esc(fam_txt)}</td>"
            f"<td>{badge_dir(d)}</td>"
            f"<td class='num'>{10 if min_pct is None else min_pct:g}%</td>"
            f"<td class='num'>{floor_cell}</td>"
            f"<td>{yes}</td><td>{no}</td>"
            f"<td><div>{ex}</div>{('<div class=why>' + esc(note) + '</div>') if note else ''}</td></tr>")


def table(rows, first_col="Metric (unit)"):
    return (f'<div class="tblwrap"><table><thead><tr><th>{first_col}</th><th>Family</th><th>Direction</th>'
            f'<th>Min&nbsp;%</th><th>Floor</th><th>Fires when</th><th>Does not fire when</th>'
            f'<th>Example / note</th></tr></thead><tbody>' + "\n".join(rows) + "</tbody></table></div>")


def main() -> None:
    pol = h._POLICY
    notes = read_notes()
    load = [(k[1], v) for k, v in pol.items() if k[0] == "LOAD"]
    metric = [(k[1], v) for k, v in pol.items() if k[0] == "METRIC"]
    wclass = [(k[1], v) for k, v in pol.items() if k[0] == "WAIT:class"]
    wevent = [(k[1], v) for k, v in pol.items() if k[0] == "WAIT:event"]
    wdefault = pol[("WAIT:default", None)]
    defaults = [(k[1], v) for k, v in pol.items() if k[0] == "DEFAULT"]

    # families -> members (for the twins section)
    fams: dict[str, list[str]] = {}
    for (dom, name), v in pol.items():
        if dom in ("LOAD", "METRIC"):
            fams.setdefault(v[0], []).append(f"{name}{' (twin)' if v[1] == 'N' else ''}")

    def wrow(name, v, kind):
        fam, canon, d, mp, ms = v
        cls_txt = name if kind == "class" else ""
        yes, no = fires_text("WAIT", name, fam, canon, d, mp, ms, "share")
        ex = example_text("WAIT", name, d, mp, ms, "share")
        note = notes.get(("WAIT", name), "")
        return (f"<tr><td><b>{esc(name)}</b><div class='why'>{'wait class' if kind == 'class' else 'wait event (overrides its class)'}</div></td>"
                f"<td>{'wait class ' + esc(name) if kind == 'class' else 'its wait class'}</td>"
                f"<td>{badge_dir(d)}</td><td class='num'>{mp:g}%</td><td class='num'>{ms * 100:g}% share</td>"
                f"<td>{yes}</td><td>{no}</td><td><div>{ex}</div>{('<div class=why>' + esc(note) + '</div>') if note else ''}</td></tr>")

    gen = _dt.datetime.now().strftime("%Y-%m-%d")
    parts = [f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Scoring policy</title>{HEAD_EXTRA}<style>{CSS}</style></head><body>{TOP_BAR}<main>
<h1>Scoring policy: what fires, and when</h1>
<p class="sub">Generated {gen} from <code>sql/lib/metric_policy.plsql</code> by <code>docs/gen_policy_doc.py</code>.
The policy file is the single source of truth; edit a line there and re-run the generator (and <code>python3 demo/gen_demo_report.py</code>) to keep this page and the demo in step.</p>
<p class="toc"><a href="#rule">The rule</a><a href="#legend">Directions and buckets</a><a href="#load">Load statistics</a><a href="#metric">System metrics</a><a href="#waits">Wait classes and events</a><a href="#other">SQL, segments, files</a><a href="#families">Families and twins</a><a href="#edit">How to change it</a></p>

<h2 id="rule">The rule, step by step</h2>
<div class="card">
<p>Every scored value is the <b>Current window</b> compared with the <b>prior windows</b> (the same hour on the previous days or weeks). One bucket per row, computed by <code>policy_bucket()</code>:</p>
<ol class="steps">
<li><b>Enough history?</b> Fewer than 3 prior windows &rarr; <span class="badge b-skip">insufficient history</span>. No usable spread (all priors identical and zero) &rarr; <span class="badge b-skip">flat baseline</span>. No Current value &rarr; <span class="badge b-skip">n/a</span>.</li>
<li><b>How unusual?</b> z = (Current &minus; prior mean) &divide; max(&sigma;, 2% of |prior mean|). The 2% floor stops a dead-flat baseline from turning a trivial wobble into a huge z. |z| &le; 2 &rarr; <span class="badge b-ok">typical</span>.</li>
<li><b>Is it material?</b> The metric's own <b>minimum %-delta</b> must be met (|Current &minus; mean| / |mean|), and its <b>value floor</b>: at least one of Current / prior mean must reach the floor in the metric's unit (for waits: the row's share of the Current window's non-idle wait time must reach the minimum share). Otherwise <span class="badge b-ok">typical</span>, badged <i>immaterial</i>.</li>
<li><b>Which direction?</b> Per metric: <code>UP</code> (rise is bad), <code>DOWN</code> (drop is bad), <code>ANY</code> (both), <code>INFO</code> (never a finding). A material move in the <i>good</i> direction &rarr; <span class="badge b-imp">improved</span>; an <code>INFO</code> counter that moved &rarr; <span class="badge b-note">noted</span>. Neither is highlighted, listed as a mover, or counted in the verdict.</li>
<li><b>How big?</b> |z| &gt; 3 &rarr; <span class="badge b-crit">large</span>, otherwise <span class="badge b-warn">moderate</span>. A table-wide shift in the wait tables demotes large to moderate.</li>
</ol>
<p><b>Worked example.</b> Hard parses (<code>parse count (hard)</code>: rise is bad, min 25%, floor 2/s). Prior windows 0.1, 0.1, 0.2, 0.1 /s; Current 0.6 /s. z is about 8 and the move is +500%, but both values sit below the 2/s floor &rarr; <i>typical, immaterial</i>. Prior windows 12, 11, 13, 12 /s; Current 18 /s: z about 7, +50%, above the floor, a rise &rarr; <i>large</i>. Prior 12 /s, Current 6 /s: a drop &rarr; <i>improved</i>, shown muted, not counted.</p>
</div>

<h2 id="legend">Directions and buckets</h2>
<div class="legend">"""]
    for d, (short, long) in DIR_TXT.items():
        parts.append(f'<div class="card"><span class="badge b-{d.lower()}">{d}</span> <b>{short}</b><br>{long}</div>')
    parts.append("""</div>
<div class="card"><div class="kv">
<b><span class="badge b-crit">large</span></b><span>|z| &gt; 3, material, bad direction. Counted in the verdict, listed in Biggest movers, row tinted.</span>
<b><span class="badge b-warn">moderate</span></b><span>|z| &gt; 2, material, bad direction. Counted, listed, tinted.</span>
<b><span class="badge b-ok">typical</span></b><span>Inside the usual spread, or the move was immaterial (badged).</span>
<b><span class="badge b-imp">improved</span></b><span>Material move in the good direction. Muted badge, no tint, never counted; the verdict says "N improved".</span>
<b><span class="badge b-note">noted</span></b><span>An informational counter that moved. Grey, never counted.</span>
<b><span class="badge b-skip">skip</span></b><span>n/a, insufficient history or flat baseline: not scored.</span>
</div></div>

<h2 id="load">Load statistics (DBA_HIST_SYSSTAT, per second)</h2>
<p class="sub">Per-second rates of the raw cumulative counters over each window. DB time, DB CPU and "CPU used by this session" are centiseconds per second, so 100 means one average active session or one busy CPU.</p>""")
    parts.append(table([row("LOAD", n, v, notes) for n, v in load]))
    parts.append("""<h2 id="metric">System metrics (DBA_HIST_SYSMETRIC_SUMMARY)</h2>
<p class="sub">Window averages of the metric's own unit. Most per-second metrics are <b>twins</b> of a load statistic above: they are scored and shown (muted) but never counted, so one physical change is one finding.</p>""")
    parts.append(table([row("METRIC", n, v, notes) for n, v in metric]))
    parts.append(f"""<h2 id="waits">Wait classes and events (DBA_HIST_SYSTEM_EVENT / BG_EVENT_SUMMARY)</h2>
<p class="sub">Scored on time waited per second. Every wait is <code>UP</code> (less waiting is never a problem). The <b>floor is a share</b>: the row must hold at least that fraction of the Current window's total non-idle wait time, so a wait that tripled but is 0.3% of the total never fires. A per-event line overrides its class; a class not listed uses the default (rise &ge; {wdefault[3]:g}%, share &ge; {wdefault[4] * 100:g}%).</p>
<h3>Per wait class (also the "Wait class: X" rollups in Findings)</h3>""")
    parts.append(table([wrow(n, v, "class") for n, v in wclass], "Wait class"))
    parts.append("<h3>Per-event overrides</h3><p class='sub'>Locks and configuration faults fire earlier than their class; application payload and parallel-query plumbing later.</p>")
    parts.append(table([wrow(n, v, "event") for n, v in wevent], "Wait event"))
    parts.append("""<h2 id="other">SQL, segments, files and unmapped names</h2>
<div class="card"><div class="kv">""")
    for dom, v in defaults:
        fam, canon, d, mp, ma = v
        label = {"SQL": "Top SQL / SQL Monitor (per statement: elapsed, CPU, I/O)", "SEG": "Segment I/O (section 14)",
                 "FILE": "File I/O (section 15)", None: "Any unmapped name (a stat a template adds that has no policy line)"}.get(dom, dom)
        parts.append(f"<b>{esc(label)}</b><span>{badge_dir(d)} &middot; min {mp:g}% &middot; {'no floor' if ma is None else 'floor ' + fmt(ma)}"
                     f"{' &middot; counted, own family' if dom is None else ''}</span>")
    parts.append("""</div></div>

<h2 id="families">Families and twins</h2>
<p class="sub">Names in one family describe one physical quantity or one story. "Biggest movers" shows one lead row per family (the counted member with the largest |z|) and folds the rest under it; a twin is never the lead.</p>
<div class="card"><div class="kv">""")
    for fam in sorted(fams):
        parts.append(f"<b>{esc(FAMILY_TXT.get(fam, fam))}</b><span>{esc(', '.join(fams[fam]))}</span>")
    parts.append("""</div></div>

<h2 id="edit">How to change it</h2>
<div class="card">
<ol class="steps">
<li>Edit the metric's line in <code>sql/lib/metric_policy.plsql</code>. Keep the one-line shape <code>WHEN 'name' THEN RETURN pol('FAMILY', 'Y', 'UP', 20, 50);</code> (or <code>wpol(v_class, 'UP', 15, 0.02)</code> for waits): the demo generator and this page parse those lines.</li>
<li><b>Floors are in the metric's own unit</b> (see the unit under each name). Set a floor to <code>NULL</code> to remove it. Wait floors are shares between 0 and 1.</li>
<li>To stop a metric from ever being a finding, set its direction to <code>INFO</code>. To make a drop count as a problem too, use <code>ANY</code>.</li>
<li>A new stat or metric added to a template needs a line here, or <code>./lint.sh</code> (check 12) fails and the stat falls back to the generic default.</li>
<li>Run <code>./lint.sh</code>, then <code>python3 docs/gen_policy_doc.py</code> and <code>python3 demo/gen_demo_report.py</code>.</li>
</ol>
<p>The same policy drives the single-DB report (verdict, findings, headline cards, wait tables, day profile, narrative) and the fleet report's findings band, row worst-finding and headline cards.</p>
</div>
<footer>AWR timeline comparison &middot; scoring policy reference &middot; regenerate with <code>python3 docs/gen_policy_doc.py</code></footer>
</main></body></html>
""")
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))
    print(f"wrote {OUT} ({len(load)} load, {len(metric)} metric, {len(wclass)} wait classes, {len(wevent)} event overrides)")


if __name__ == "__main__":
    main()
