"""
Twin of sql/07_summary.sql -- Findings summary.

Unified LOAD / METRIC / WAIT z-score recompute of the Current window
against the prior VALID windows, the "Biggest movers" top-8-by-|z| table
and one detail table per domain.  Mirrors the PL/SQL block top to
bottom: the same BULK COLLECT ordering (heat_pos), the same single-pass
tallies / movers shortlist, the same emit_domain_table shape.
"""
from __future__ import annotations

import math

from .. import helpers as h

# sql/lib/templates/comprehensive/sysstat_load_targets.sql (27 stats)
LOAD_TARGETS = [
    "redo size", "redo size for lost write detection", "DB time", "DB CPU",
    "CPU used by this session", "session logical reads", "physical reads",
    "physical read total bytes", "physical writes", "physical write total bytes",
    "user calls", "user commits", "user rollbacks", "execute count",
    "parse count (total)", "parse count (hard)", "parse count (failures)",
    "sorts (memory)", "sorts (disk)", "sorts (rows)", "logons cumulative",
    "opened cursors cumulative", "redo writes", "table scans (long tables)",
    "table fetch by rowid", "bytes sent via SQL*Net to client",
    "bytes received via SQL*Net from client",
]

# sql/lib/templates/comprehensive/sysmetric_targets.sql (23 metrics)
METRIC_TARGETS = [
    "Host CPU Utilization (%)", "Database CPU Time Ratio",
    "Database Wait Time Ratio", "Average Active Sessions",
    "Average Synchronous Single-Block Read Latency", "Physical Reads Per Sec",
    "Physical Writes Per Sec", "Physical Read Total IO Requests Per Sec",
    "Physical Write Total IO Requests Per Sec", "Physical Read Total Bytes Per Sec",
    "Physical Write Total Bytes Per Sec", "Redo Generated Per Sec",
    "Logons Per Sec", "Logical Reads Per Sec", "User Calls Per Sec",
    "User Commits Per Sec", "User Rollbacks Per Sec", "Executions Per Sec",
    "Hard Parse Count Per Sec", "Total Parse Count Per Sec", "Session Count",
    "Network Traffic Volume Per Sec", "SQL Service Response Time",
]

_BUCKET_RANK = {"large": 1, "moderate": 2, "insufficient history": 3,
                "n/a": 3, "flat baseline": 4}
_TAIL = ("typical", "flat baseline", "insufficient history")


class Finding:
    __slots__ = ("domain", "name", "cur", "mu", "sd", "n", "z", "pct", "bucket")

    def __init__(self, domain, name, cur, mu, sd, n):
        self.domain, self.name = domain, name
        self.cur, self.mu, self.sd, self.n = cur, mu, sd, n
        self.z, self.pct = h.z_and_pct(cur, mu, sd)
        # the 'scored' CASE (cur missing => 'n/a', matching section 08)
        self.bucket = h.bucket_of(cur, n, sd, self.z)

    @property
    def az(self):
        return abs(self.z or 0)

    @property
    def cls(self):
        return h.bucket_cls(self.bucket)


def _unified_rows(w):
    """(domain, name) -> {week_offset: value} over the VALID windows."""
    rows: dict[tuple[str, str], dict[int, float]] = {}

    def put(dom, name, k, v):
        if v is None:
            return
        rows.setdefault((dom, name), {})[k] = v

    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        k = win.week_offset
        for stat in LOAD_TARGETS:
            if stat in m.load and m.dur_sec > 0:
                put("LOAD", stat, k, m.load[stat] / m.dur_sec)
        for name in METRIC_TARGETS:
            if name in m.sysmetric:
                put("METRIC", name, k, m.sysmetric[name])
        per_class: dict[str, float] = {}
        for _ev, (wc, _n, us) in m.fg_waits.items():
            if wc == "Idle":
                continue
            per_class[wc] = per_class.get(wc, 0.0) + us
        for wc, us in per_class.items():
            if m.dur_sec > 0:
                put("WAIT", "Wait class: " + wc, k, us / m.dur_sec / 1e6)
    return rows


def compute_findings(w) -> list[Finding]:
    """The BULK COLLECT, in heat_pos order (domain, |z| DESC, name)."""
    out = []
    for (dom, name), by_off in _unified_rows(w).items():
        cur = by_off.get(0)
        priors = [v for k, v in by_off.items() if k > 0]
        mu, sd, n = h.mean_sd(priors)
        if cur is None and mu is None:
            continue
        out.append(Finding(dom, name, cur, mu, sd, n))
    out.sort(key=lambda f: (f.domain, -f.az, f.name))
    return out


def _table_order(findings: list[Finding]) -> list[Finding]:
    return sorted(findings, key=lambda f: (_BUCKET_RANK.get(f.bucket, 5), -f.az,
                                           -abs(f.pct or 0), f.name))


def _z_cell_tail(f: Finding, sig: bool) -> str:
    return h.z_txt(f.z, 2) + (h.SIG_BADGE if sig else "")


def _pct_cell(f: Finding, sig: bool) -> str:
    return ("<b>" + h.pct_txt(f.pct) + "</b>") if sig else h.pct_txt(f.pct)


def _emit_domain_table(out: list[str], ordered: list[Finding], dom: str, title: str):
    rows = [f for f in ordered if f.domain == dom]
    if not rows:
        return
    tail_cnt = sum(1 for f in rows if f.bucket in _TAIL)
    tbl_id = "findings-" + dom.lower()
    out.append('<h3 class="hidetri">' + title + "</h3>")
    out.append('<table id="' + tbl_id + '" class="hidetri">'
               "<thead><tr>"
               "<th>Change</th>"
               "<th>Metric</th>"
               '<th class="num">Current</th>'
               '<th class="num">Prior mean</th>'
               '<th class="num">Prior sd</th>'
               '<th class="num">n</th>'
               '<th class="num">z-score</th>'
               '<th class="num">% &Delta;</th>'
               "</tr></thead><tbody>")
    for f in rows:
        cls = f.cls
        imp = None if dom == "WAIT" else h.is_essential(dom, f.name)
        sig = h.sigma_flag(f.mu, f.sd)
        out.append('<tr data-metric="' + h.esc(f.name).replace('"', "&quot;") + '"'
                   + ((' data-imp="' + imp + '"') if imp is not None else "")
                   + (' data-tail="Y"' if f.bucket in _TAIL else "")
                   + ' class="' + cls + '">'
                   + '<td><span class="badge ' + cls + '">' + f.bucket + "</span></td>"
                   + "<td>" + h.esc(f.name) + "</td>"
                   + '<td class="num"' + h.fmt_num_title(f.cur) + ">" + h.fmt_num(f.cur) + "</td>"
                   + '<td class="num">' + h.fmt_num(f.mu) + "</td>"
                   + '<td class="num">' + h.fmt_num(f.sd) + "</td>"
                   + '<td class="num">' + (str(f.n) if f.n is not None else "0") + "</td>"
                   + '<td class="num">' + _z_cell_tail(f, sig) + "</td>"
                   + '<td class="num">' + _pct_cell(f, sig) + "</td>"
                   + "</tr>")
    out.append("</tbody></table>")
    if tail_cnt > 0:
        out.append('<span class="expander hidetri" data-for="' + tbl_id
                   + '" data-n="' + str(tail_cnt) + '" data-noun="typical / flat rows">'
                   + "&#9656; Show " + str(tail_cnt) + " typical / flat rows</span>")


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 07_summary BEGIN -->"]
    out.append('<section id="findings" data-triage="Y"><h2 id="findings-heading">Findings summary</h2>')
    out.append('<p style="font-size:12px;color:var(--muted)">'
               "z = (current &minus; &mu;) &divide; &sigma; over prior valid windows. "
               "|z|&gt;3 large, |z|&gt;2 moderate, else typical. "
               "n&lt;3 &rarr; %-delta only. "
               "|z| beyond &plusmn;99 is capped for display; "
               "&sigma;&approx;0 flags a baseline that barely moved &mdash; read the %-delta there instead.</p>")

    findings = compute_findings(w)
    total = len(findings)
    crit = sum(1 for f in findings if f.bucket == "large")
    warn = sum(1 for f in findings if f.bucket == "moderate")
    typical = total - crit - warn
    # top-8 by |z| over the heat_pos-ordered collection; the PL/SQL
    # insertion sort keeps first-seen ahead on ties == a stable sort.
    top = sorted(findings, key=lambda f: -f.az)[:8]
    ordered = _table_order(findings)

    out.append('<script>(function(){var h=document.getElementById("findings-heading");'
               "if(h)h.innerHTML='Findings summary "
               '<span class="badge crit">' + str(crit) + " large</span> "
               '<span class="badge warn">' + str(warn) + " moderate</span> "
               '<span class="badge skip">' + str(typical) + " typical</span>';})();</script>")

    if top:
        out.append("<h3>Biggest movers</h3>")
        out.append('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
                   "top " + str(len(top)) + " by |z|, log-scaled bar</p>")
        out.append('<table id="findings-movers" data-nocount><thead><tr>'
                   "<th>Metric</th>"
                   "<th>Domain</th>"
                   '<th class="num">|z|</th>'
                   '<th class="num">Current</th>'
                   '<th class="num">Prior mean</th>'
                   '<th class="num">% &Delta;</th>'
                   "</tr></thead><tbody>")
        for f in top:
            cls = f.cls
            sig = h.sigma_flag(f.mu, f.sd)
            if sig:
                bar_w = 150
                dashed = ("background-image:repeating-linear-gradient("
                          "90deg,transparent 0 4px,var(--panel) 4px 6px);opacity:.55;")
            else:
                bar_w = min(150, int(h.ora_round(20 + 40 * math.log(1 + f.az), 0)))
                dashed = ""
            bar_col = {"crit": "var(--crit)", "warn": "var(--warn)",
                       "ok": "var(--ok)"}.get(cls, "var(--skip)")
            out.append('<tr class="' + cls + '">'
                       + "<td>" + h.esc(f.name) + "</td>"
                       + '<td><span class="chip">' + f.domain + "</span></td>"
                       + '<td class="num">'
                       + '<span class="zbar" style="width:' + str(bar_w) + "px;"
                       + dashed + "background-color:" + bar_col + '"></span>'
                       + _z_cell_tail(f, sig)
                       + "</td>"
                       + '<td class="num"' + h.fmt_num_title(f.cur) + ">" + h.fmt_num(f.cur) + "</td>"
                       + '<td class="num">' + h.fmt_num(f.mu) + "</td>"
                       + '<td class="num">' + _pct_cell(f, sig) + "</td>"
                       + "</tr>")
        out.append("</tbody></table>")

    _emit_domain_table(out, ordered, "LOAD", "Load profile")
    _emit_domain_table(out, ordered, "METRIC", "System metrics")
    _emit_domain_table(out, ordered, "WAIT", "Wait classes")

    out.append("</section>")
    out.append("<!-- AWR-SECTION: 07_summary END -->")
    return "\n".join(out)
