"""
Twin of sql/07_summary.sql -- Findings (v1.6.0).

Unified LOAD / METRIC / WAIT z-score recompute of the Current window
against the prior VALID windows; the Summary view's finding cards (one per
card group of metric_policy families), the empty "What changed around it"
slot and "Checked and normal"; the All sections view's per-domain detail
tables.  Mirrors the PL/SQL block top to bottom.
"""
from __future__ import annotations

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

_BUCKET_RANK = {"large": 1, "moderate": 2, "improved": 3, "noted": 3, "insufficient history": 4,
                "n/a": 4, "flat baseline": 5}
_TAIL = ("typical", "flat baseline", "insufficient history", "improved", "noted")
_FLAGGED = ("large", "moderate", "improved", "noted")
_MOVED = ("large", "moderate")


class Finding:
    __slots__ = ("domain", "name", "cur", "mu", "sd", "n", "z", "pct", "bucket",
                 "family", "canonical", "dir", "vals", "grp")

    def __init__(self, domain, name, cur, mu, sd, n, share=None, vals=None):
        self.domain, self.name = domain, name
        self.vals = vals or {}
        self.cur, self.mu, self.sd, self.n = cur, mu, sd, n
        self.z, self.pct = h.z_and_pct(cur, mu, sd)
        # pass 1 of the PL/SQL: per-metric policy (sql/lib/metric_policy.plsql)
        # -> family / canonical / direction and the change bucket
        pol = h.metric_policy(domain, name)
        self.bucket = h.policy_bucket(domain, name, None, cur, mu, sd, n, share)
        self.family = h.finding_family(domain, name)
        self.canonical = pol[1]
        self.dir = pol[2]
        self.grp = h.card_group(self.family)

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
    rows = _unified_rows(w)
    # wait_total: the Current window's total non-idle wait across classes
    wait_tot = sum(v.get(0, 0.0) for (d, _n), v in rows.items() if d == "WAIT")
    out = []
    for (dom, name), by_off in rows.items():
        cur = by_off.get(0)
        priors = [v for k, v in by_off.items() if k > 0]
        mu, sd, n = h.mean_sd(priors)
        if cur is None and mu is None:
            continue
        share = (cur / wait_tot) if (dom == "WAIT" and wait_tot > 0 and cur is not None) else None
        out.append(Finding(dom, name, cur, mu, sd, n, share, by_off))
    out.sort(key=lambda f: (f.domain, -f.az, f.name))
    return out


def _table_order(findings: list[Finding]) -> list[Finding]:
    return sorted(findings, key=lambda f: (_BUCKET_RANK.get(f.bucket, 5), -f.az,
                                           -abs(f.pct or 0), f.name))


_TWIN_CHIP = (' <span class="chip" title="same quantity as a counted row; '
              'not counted again">twin</span>')


def _find_id(f) -> str:
    return h.finding_anchor(f.domain, f.name)


def _src_link(f) -> str:
    if f.domain == "LOAD":
        tid, sec = h.anchor_id("load", f.name), "Load profile"
    elif f.domain == "METRIC":
        tid, sec = h.anchor_id("metric", f.name), "System metrics"
    else:
        cls = f.name[len("Wait class: "):] if f.name.startswith("Wait class: ") else f.name
        tid, sec = h.anchor_id("wc", cls), "Foreground waits"
    return (' <a class="xlink" href="#' + tid + '" title="Go to this metric\'s row in '
            + sec + '">&#8599; row</a>')
def _emit_domain_table(out: list[str], ordered: list[Finding], dom: str, title: str):
    rows = [f for f in ordered if f.domain == dom]
    if not rows:
        return
    tail_cnt = sum(1 for f in rows if f.bucket in _TAIL)
    tbl_id = "findings-" + dom.lower()
    out.append('<h3 class="vw in-a">' + title + "</h3>")
    out.append('<table id="' + tbl_id + '" class="vw in-a">'
               "<thead><tr>"
               "<th>Metric</th>"
               '<th class="num cur-col">Current</th>'
               + h.band_head()
               + '<th class="num">Prior mean</th>'
               '<th class="num">Prior sd</th>'
               '<th class="num">n</th>'
               "</tr></thead><tbody>")
    for f in rows:
        cls = f.cls
        imp = None if dom == "WAIT" else h.is_essential(dom, f.name)
        out.append('<tr id="' + _find_id(f) + '" data-metric="' + h.esc(f.name).replace('"', "&quot;") + '"'
                   + ' data-family="' + f.family + '"'
                   + ((' data-imp="' + imp + '"') if imp is not None else "")
                   + (' data-tail="Y"' if f.bucket in _TAIL else "")
                   + ' class="' + cls + (" twin" if f.canonical == "N" else "") + '">'
                   + "<td>" + h.esc(f.name) + (_TWIN_CHIP if f.canonical == "N" else "") + _src_link(f) + "</td>"
                   + '<td class="num" data-w="0"' + h.fmt_num_title(f.cur) + ">" + h.fmt_num(f.cur) + "</td>"
                   + h.band_cells(f.cur, f.mu, f.sd, f.n, f.bucket, "Y" if f.canonical == "N" else "N")
                   + '<td class="num">' + h.fmt_num(f.mu) + "</td>"
                   + '<td class="num">' + h.fmt_num(f.sd) + "</td>"
                   + '<td class="num">' + (str(f.n) if f.n is not None else "0") + "</td>"
                   + "</tr>")
    out.append("</tbody></table>")
    if tail_cnt > 0:
        out.append('<span class="expander vw in-a" data-for="' + tbl_id
                   + '" data-n="' + str(tail_cnt) + '" data-noun="normal / improved / flat rows">'
                   + "&#9656; Show " + str(tail_cnt) + " normal / improved / flat rows</span>")


def _events(w):
    """The card-evidence scan: top 2 foreground events per wait class by
    Current time waited per second, with prior mean / sd / n and share."""
    rows: dict[tuple[str, str], dict[int, float]] = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None or m.dur_sec <= 0:
            continue
        for ev, (wc, _n, us) in m.fg_waits.items():
            if wc == "Idle":
                continue
            rows.setdefault((wc, ev), {})[win.week_offset] = us / m.dur_sec / 1e6
    tot = sum(v.get(0, 0.0) for v in rows.values())
    piv = []
    for (wc, ev), by in rows.items():
        cur = by.get(0)
        if cur is None or cur <= 0:
            continue
        mu, sd, n = h.mean_sd([v for k, v in by.items() if k > 0])
        piv.append(dict(wclass=wc, event=ev, cur=cur, mu=mu, sd=sd, n=n,
                        shr=(cur / tot if tot > 0 else None)))
    out = []
    for wc in sorted({p["wclass"] for p in piv}):
        cl = sorted((p for p in piv if p["wclass"] == wc), key=lambda p: (-p["cur"], p["event"]))
        out.extend(cl[:2])
    return out


_DOM_WORD = {"LOAD": "Load", "METRIC": "Metric"}
_AXIS = ('<span class="bd-ax" aria-hidden="true"><em style="--x:.167">&minus;2</em>'
         '<em style="--x:.333">0</em><em style="--x:.500">+2</em>'
         '<em style="--x:.583">+3</em><em class="end" style="--x:1">+8&sigma;</em></span>')


def _ev_row(dt, ident, txt, de, cur, mu, sd, bucket) -> str:
    return ('<div class="evr"><dt>' + dt + '</dt><dd><span class="id' + (" txt" if txt else "") + '">'
            + ident + '</span><span class="de">' + de + '</span></dd>'
            '<div class="m">' + h.delta_span(cur, mu, bucket)
            + h.band_span(h.band_z(cur, mu, sd), bucket, "sm") + '</div></div>')


def _f_ent(f) -> str:
    return h.ent(h.esc(h.metric_label(f.domain, f.name)), _find_id(f), "metric")


def _nr_row(f) -> str:
    s, u = h.metric_scale(f.domain, f.name), h.metric_unit(f.domain, f.name)
    return ('<div class="nr"><div class="l" title="' + h.esc(f.name) + '">' + _f_ent(f)
            + '<small>normal ' + h.fv_range(h._mul(f.mu, s), h._mul(f.sd, s), u) + '</small></div>'
            + h.band_span(f.z, f.bucket, "sm", "Y" if f.canonical == "N" else "N")
            + '<div class="vv">' + h.fv(h._mul(f.cur, s), u)
            + '<small>' + h.delta_span(f.cur, f.mu, f.bucket) + '</small></div></div>')


_SPLIT_CARD = {"W": ", all of it wait", "w": ", mostly wait", "c": ", mostly CPU", "m": ", CPU and wait alike"}


def _card(w, out, g, pos, lead, ordered, evs, flagcls, dbt, cpu):
    r = lead[g]
    s, u = h.metric_scale(r.domain, r.name), h.metric_unit(r.domain, r.name)
    cid = h.card_id(g)
    sev = r.bucket
    cap = 2 if g == "IO" else 4
    ev, nev = "", 0
    split = None
    if g == "DBTIME" and dbt is not None and cpu is not None:
        split = h.time_split(dbt.cur, dbt.mu, cpu.cur, cpu.mu)
    if g == "DBTIME" and cpu is not None and cpu is not r:
        ev += _ev_row("CPU", _f_ent(cpu), True,
                      h.fv(h._mul(cpu.cur, 0.01), "AAS") + ", normal " + h.fv(h._mul(cpu.mu, 0.01), "AAS")
                      + ("; the rise is wait" if split in ("W", "w") else ""),
                      cpu.cur, cpu.mu, cpu.sd, cpu.bucket)
        nev += 1
    for e in evs:
        if nev >= cap:
            break
        if h.card_group("WAIT:" + e["wclass"]) == g and e["wclass"] in flagcls:
            eb = h.policy_bucket("WAIT", e["event"], e["wclass"], e["cur"], e["mu"], e["sd"], e["n"], e["shr"])
            ev += _ev_row("Event", h.ent(h.esc(e["event"]), h.anchor_id("we", e["event"]), "event"), True,
                          h.fv(e["cur"], "AAS") + ", normal " + h.fv(e["mu"], "AAS"),
                          e["cur"], e["mu"], e["sd"], eb)
            nev += 1
    rel, nrel, ntw = "", 0, 0
    for m in ordered:
        if m.grp != g or m.bucket not in ("large", "moderate") or m is r:
            continue
        ms, mu_ = h.metric_scale(m.domain, m.name), h.metric_unit(m.domain, m.name)
        if m.canonical == "Y" and nev < cap:
            ev += _ev_row(_DOM_WORD.get(m.domain, "Wait"), _f_ent(m), True,
                          h.fv(h._mul(m.cur, ms), mu_) + ", normal " + h.fv(h._mul(m.mu, ms), mu_),
                          m.cur, m.mu, m.sd, m.bucket)
            nev += 1
        if m.canonical == "N":
            ntw += 1
        else:
            nrel += 1
        rel += ('<tr class="' + h.bucket_cls(m.bucket) + (" twin" if m.canonical == "N" else "") + '"><td>'
                + _f_ent(m)
                + (' <span class="chip" title="same quantity as a counted row; not counted again">twin</span>'
                   if m.canonical == "N" else "")
                + '</td><td class="num" data-w="0">' + h.fv(h._mul(m.cur, ms), mu_) + '</td>'
                + h.band_cells(h._mul(m.cur, ms), h._mul(m.mu, ms), h._mul(m.sd, ms), m.n, m.bucket,
                               "Y" if m.canonical == "N" else "N")
                + '</tr>')
    if g == "IO":
        links = '<a href="#segment-io">Segment I/O</a><a href="#topsql">Top SQL</a>'
    elif g == "DBTIME":
        links = ('<a href="#waits-fg">Foreground waits</a>'
                 + ('<a href="#day-profile">Day profile</a>' if w.profile_days > 0
                    else '<a href="#ash-timeline">ASH timeline</a>'))
    elif g == "WRITE":
        links = '<a href="#file-io">File I/O</a><a href="#load">Load profile</a>'
    elif g in ("NET", "COMMIT") or g.startswith("WAIT:"):
        links = '<a href="#waits-fg">Foreground waits</a>'
    elif r.domain == "METRIC":
        links = '<a href="#metrics">System metrics</a>'
    else:
        links = '<a href="#load">Load profile</a>'
    out.append('<article class="panel fc f-' + sev
               + (" lead" if pos == 1 else " slim" if sev == "moderate" else "")
               + '" id="' + cid + '" aria-labelledby="' + cid + '-h">'
               '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
               + h.esc(h.card_label(g)) + '"><i class="dotk ' + sev
               + '" aria-hidden="true"></i>' + sev.capitalize() + '</span></div>'
               '<div class="fc-band" title="z ' + h.band_ztxt(r.z) + ' against the prior normal">'
               + h.band_span(r.z, sev, "lg") + _AXIS + '</div></header>')
    out.append('<h3 id="' + cid + '-h">' + _f_ent(r) + ' ' + h.move_txt(r.cur, r.mu, sev)
               + (_SPLIT_CARD.get(split, "") if r.name == "DB time" else "") + '</h3>')
    out.append('<div class="fc-b"><div class="fc-main">'
               '<div class="big"><span class="v">' + h.fv_num(h._mul(r.cur, s), u) + '</span>'
               '<span class="u">' + h.fv_unit(h._mul(r.cur, s), u) + '</span>'
               '<span class="nrm" title="prior mean ' + h.fv(h._mul(r.mu, s), u) + '">normal '
               + h.fv_range(h._mul(r.mu, s), h._mul(r.sd, s), u) + '</span></div>')
    out.append('<div class="wg bare allv"' + h.wg_attr(w) + '>' + h.wg_flags(True)
               + h.wg_bars(w, r.vals, s, r.mu, r.sd, sev) + h.wg_dates(w, True) + '</div></div>')
    out.append('<dl class="ev">' + ev + '</dl></div>')
    if nrel + ntw > 0:
        out.append('<details class="rel"><summary>'
                   + (str(nrel) + ' related metric' + ('' if nrel == 1 else 's') if nrel > 0 else '')
                   + (', ' if nrel > 0 and ntw > 0 else '')
                   + (str(ntw) + ' twin' + ('' if ntw == 1 else 's') if ntw > 0 else '')
                   + '</summary><div class="tw"><table data-nocount data-notools data-nosort><thead><tr>'
                   '<th>Metric</th><th class="num cur-col">Current</th>' + h.band_head()
                   + '</tr></thead><tbody>')
        out.append(rel)
        out.append('</tbody></table></div></details>')
    out.append('<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-' + _find_id(r)
               + '">Timeline &rarr;</a><span class="evl">' + links + '</span></footer></article>')


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 07_summary BEGIN -->"]
    findings = compute_findings(w)
    canon = [f for f in findings if f.canonical == "Y"]
    crit = sum(1 for f in canon if f.bucket == "large")
    warn = sum(1 for f in canon if f.bucket == "moderate")
    impr = sum(1 for f in canon if f.bucket == "improved")
    noted = sum(1 for f in canon if f.bucket == "noted")
    folded = sum(1 for f in findings if f.canonical == "N" and f.bucket in _FLAGGED)
    normal = sum(1 for f in canon if f.bucket in ("typical", "improved", "noted", "flat baseline"))
    dbt = next((f for f in findings if f.domain == "LOAD" and f.name == "DB time"), None)
    cpu = next((f for f in findings if f.domain == "LOAD" and f.name == "DB CPU"), None)
    lead, gsev, gz, flagcls = {}, {}, {}, set()
    for f in findings:                      # heat_pos order, like the PL/SQL pass
        if f.canonical != "Y" or f.bucket not in _MOVED:
            continue
        g = f.grp
        if g not in lead:
            lead[g], gsev[g], gz[g] = f, 0, 0
        elif h.lead_better(g, f.bucket, f.family, f.z, lead[g].bucket, lead[g].family, lead[g].z,
                           h.metric_label(f.domain, f.name), h.metric_label(lead[g].domain, lead[g].name)):
            lead[g] = f
        gsev[g] = max(gsev[g], h.sev_rank(f.bucket))
        gz[g] = max(gz[g], f.az)
        if f.domain == "WAIT":
            flagcls.add(f.name[len("Wait class: "):] if f.name.startswith("Wait class: ") else f.name)
    order = h.card_order({g: (gsev[g], gz[g]) for g in lead})
    evs = _events(w) if flagcls else []
    ordered = _table_order(findings)

    meta = ('<span class="meta">'
            + ('<span><i class="dotk large"></i>' + str(crit) + ' large</span>' if crit > 0 else '')
            + ('<span><i class="dotk moderate"></i>' + str(warn) + ' moderate</span>' if warn > 0 else '')
            + '<span><i class="dotk typical"></i>' + str(normal) + ' normal</span>'
            + ('<span title="moved in the good direction; not counted">' + str(impr) + ' improved</span>'
               if impr > 0 else '')
            + ('<span title="informational counters that moved; not counted">' + str(noted) + ' noted</span>'
               if noted > 0 else '')
            + ('<span title="flagged twins of a counted row (SYSMETRIC rate of a SYSSTAT counter, '
               'CPU half of the CPU/wait ratio)">' + str(folded) + ' folded</span>' if folded > 0 else '')
            + '</span>')
    nc = len(order)
    out.append('<section id="findings" class="vw in-s in-a sumsec"><h2 id="findings-heading">'
               + (('<span class="vw in-s">' + str(nc) + ' finding' + ('' if nc == 1 else 's') + '</span>'
                   '<span class="vw in-a">Findings</span>') if nc else 'Findings')
               + meta
               + '<small class="h2sub"><span class="vw in-s">'
               + ((str(crit + warn) + ' metric' + ('' if crit + warn == 1 else 's') + ' moved, in '
                   + str(nc) + ' famil' + ('y' if nc == 1 else 'ies')) if nc
                  else 'Every scored metric against its prior windows')
               + '</span><span class="vw in-a">Every scored metric against its prior windows; one table per domain</span>'
               '</small></h2>')
    if nc:
        out.append('<div class="cards vw in-s">')
        for k, g in enumerate(order, 1):
            _card(w, out, g, k, lead, ordered, evs, flagcls, dbt, cpu)
        out.append('</div>')
    else:
        out.append('<div class="panel calm vw in-s"><p class="calm-empty">'
                   + ('Nothing could be scored: a metric needs at least 3 valid prior windows.' if normal == 0
                      else 'No finding: every scored metric sits inside its normal range, or moved too little to matter.')
                   + '</p></div>')

    _emit_domain_table(out, ordered, "LOAD", "Load profile")
    _emit_domain_table(out, ordered, "METRIC", "System metrics")
    _emit_domain_table(out, ordered, "WAIT", "Wait classes")
    out.append("</section>")

    out.append('<section id="s-changes" class="vw in-s sumsec" hidden>'
               '<h2>What changed around it<small class="h2sub">Configuration that differs across the '
               'compared windows, under the release flags</small></h2>'
               '<div class="cards" id="changes-slot"></div></section>')

    out.append('<section id="s-normal" class="vw in-s sumsec"><h2>Checked and normal'
               '<span class="meta"><span><i class="dotk typical"></i>' + str(normal) + ' normal</span></span>'
               '<small class="h2sub">Every other scored metric, against the same prior windows</small></h2>')
    if normal == 0:
        out.append('<div class="panel calm"><p class="calm-empty">'
                   'Nothing could be scored as normal: a metric needs at least 3 valid prior windows.'
                   '</p></div>')
    else:
        out.append('<div class="panel calm"><div class="ngrid">')
        grid, more, first = 0, 0, None
        for pas in (1, 2):
            for f in ordered:
                if f.canonical == "Y" and ((pas == 1 and f.bucket == "typical" and f.az <= 2)
                                           or (pas == 2 and f.bucket == "flat baseline")):
                    if first is None:
                        first = f.domain.lower()
                    if grid < 18:
                        out.append(_nr_row(f))
                        grid += 1
                    else:
                        more += 1
        out.append('</div>'
                   + ('<p class="calm-more">and ' + str(more) + ' more normal row' + ('' if more == 1 else 's')
                      + ' in the <a href="#findings-' + first + '">Findings tables</a> (All sections).</p>'
                      if more > 0 else '')
                   + '</div>')
        small, ns, imp, ni = "", 0, "", 0
        for f in ordered:
            if f.canonical != "Y":
                continue
            if (f.bucket == "typical" and f.az > 2) or f.bucket == "noted":
                if ns < 6:
                    small += _nr_row(f)
                ns += 1
            elif f.bucket == "improved":
                if ni < 6:
                    imp += _nr_row(f)
                ni += 1
        out.append('<div class="calm-notes">'
                   '<div class="panel note"><h3 title="Past a z threshold but under the metric\'s '
                   'materiality floor (sql/lib/metric_policy.plsql), or an informational counter">'
                   'Moved, too small to matter</h3>'
                   + ('<p>Nothing crossed a threshold without clearing its floor.</p>' if ns == 0 else small)
                   + ('<p class="calm-more">and ' + str(ns - 6) + ' more</p>' if ns > 6 else '')
                   + '</div>')
        out.append('<div class="panel note improved"><h3 title="A material move in the '
                   'good direction: not a finding, not counted">'
                   + ('Improved: none material' if ni == 0 else 'Improved') + '</h3>'
                   + ('<p>Nothing moved materially in the good direction.</p>' if ni == 0 else imp)
                   + ('<p class="calm-more">and ' + str(ni - 6) + ' more</p>' if ni > 6 else '')
                   + '</div></div>')
    out.append('</section>')
    out.append("<!-- AWR-SECTION: 07_summary END -->")
    return "\n".join(out)
