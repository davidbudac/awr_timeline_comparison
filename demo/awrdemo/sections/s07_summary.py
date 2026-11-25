"""
Twin of sql/07_summary.sql -- Findings (v1.6.0).

Unified LOAD / METRIC / WAIT z-score recompute of the Current window
against the prior VALID windows; the Summary view's finding cards (one per
card group of metric_policy families), the empty "What changed around it"
slot and "Checked and normal"; the All sections view's per-domain detail
tables.  Mirrors the PL/SQL block top to bottom.
"""
from __future__ import annotations

from .. import chrome
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
                 "family", "canonical", "dir", "vals", "grp", "fg_d")

    def __init__(self, domain, name, cur, mu, sd, n, share=None, vals=None, fg_d=None):
        self.domain, self.name = domain, name
        # wait-class rows: foreground Current - prior mean, AAS (the impact)
        self.fg_d = fg_d
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
            v = h.load_total(m, stat)
            if v is not None and m.dur_sec > 0:
                put("LOAD", stat, k, v / m.dur_sec)
        for name in METRIC_TARGETS:
            if name in m.sysmetric:
                put("METRIC", name, k, m.sysmetric[name])
        per_class: dict[str, float] = {}
        # wait_rows: DBA_HIST_SYSTEM_EVENT, all sessions (time_waited_micro)
        for _ev, (wc, _n, us) in m.sys_waits.items():
            if wc == "Idle":
                continue
            per_class[wc] = per_class.get(wc, 0.0) + us
        for wc, us in per_class.items():
            if m.dur_sec > 0:
                put("WAIT", "Wait class: " + wc, k, us / m.dur_sec / 1e6)
    return rows


def _fg_wait_deltas(w) -> dict:
    """wait_fg_rows / wait_fg: per wait class, Current minus the prior mean
    of the FOREGROUND time waited per second (time_waited_micro_fg), AAS --
    the cards' impact (owner decision 2026-11-20), never scored.  The same
    SYSTEM_EVENT rows as the class rows (m.sys_waits), foreground columns
    (m.sys_waits_fg): a foreground event's time is all foreground, a
    background-only one's (model.SYSEVENT_BG, the demo's Queueing class)
    is 0, so that class scores on its all-session time and adds 0 AAS."""
    by_cls: dict[str, dict[int, float]] = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        per_class: dict[str, float] = {}
        for _ev, (wc, _n, us) in m.sys_waits_fg.items():
            if wc == "Idle":
                continue
            per_class[wc] = per_class.get(wc, 0.0) + us
        for wc, us in per_class.items():
            if m.dur_sec > 0:
                by_cls.setdefault(wc, {})[win.week_offset] = us / m.dur_sec / 1e6
    out = {}
    for wc, by_off in by_cls.items():
        cur = by_off.get(0)
        mu = h.mean_sd([v for k, v in by_off.items() if k > 0])[0]
        out["Wait class: " + wc] = (cur - mu) if (cur is not None and mu is not None) else None
    return out


def compute_findings(w) -> list[Finding]:
    """The BULK COLLECT, in heat_pos order (domain, |z| DESC, name)."""
    rows = _unified_rows(w)
    fg = _fg_wait_deltas(w)
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
        out.append(Finding(dom, name, cur, mu, sd, n, share, by_off,
                           fg.get(name) if dom == "WAIT" else None))
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
    """The card-evidence scan: top 2 events per wait class by Current time
    waited per second (DBA_HIST_SYSTEM_EVENT, all sessions), with prior
    mean / sd / n and share."""
    rows: dict[tuple[str, str], dict[int, float]] = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None or m.dur_sec <= 0:
            continue
        for ev, (wc, _n, us) in m.sys_waits.items():
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
            + ident + '</span><span class="de">' + h.nbu(de) + '</span></dd>'
            '<div class="m">' + h.delta_span(cur, mu, bucket)
            + h.band_span(h.band_z(cur, mu, sd), bucket, "sm", "N", 10) + '</div></div>')


def _f_ent(f) -> str:
    return h.ent(h.esc(h.metric_label(f.domain, f.name)), _find_id(f), "metric")


def _nr_row(f) -> str:
    s, u = h.metric_scale(f.domain, f.name), h.metric_unit(f.domain, f.name)
    return ('<div class="nr"><div class="l" title="' + h.esc(f.name) + '">' + _f_ent(f)
            + '<small>normal ' + h.fv_range(h._mul(f.mu, s), h._mul(f.sd, s), u) + '</small></div>'
            + h.band_span(f.z, f.bucket, "sm", "Y" if f.canonical == "N" else "N", 10)
            + '<div class="vv">' + h.fv(h._mul(f.cur, s), u)
            + '<small>' + h.delta_span(f.cur, f.mu, f.bucket) + '</small></div></div>')


_SPLIT_CARD = {"W": ", all of it wait", "w": ", mostly wait", "c": ", mostly CPU", "m": ", CPU and wait alike"}


def _head_txt(r, dbt, cpu) -> str:
    """07_summary.sql head_txt (plan 025): the card headline after the
    metric name; the DB time lead adds where the extra time went.  Shared
    by the card's h3 and its triage row."""
    split = None
    if r.name == "DB time" and dbt is not None and cpu is not None:
        split = h.time_split(dbt.cur, dbt.mu, cpu.cur, cpu.mu)
    return h.move_txt(r.cur, r.mu, r.bucket) + _SPLIT_CARD.get(split, "")


def _g_shr(imp, g):
    """07_summary.sql g_shr: a card's share of the DB-time rise, integer
    percent; None when the card added less than 0.01 AAS (imp_on), DB time
    did not rise, or the share passes 100 (up to 100.5% is kept, shown as
    100)."""
    v_i, v_d = imp.get(g), imp.get("DBTIME")
    if h.imp_on(v_i) and v_d is not None and v_d > 0 and v_i <= v_d * 1.005:
        return min(100, int(h.ora_round(v_i / v_d * 100, 0)))
    return None


def _f_up(findings, dom, name) -> bool:
    """07_summary.sql f_up (plan 033): a scored row moved up AND is a
    finding (large / moderate)."""
    for f in findings:
        if f.domain == dom and f.name == name:
            return (f.bucket in ("large", "moderate") and f.cur is not None and f.mu is not None
                    and f.cur > f.mu)
    return False


def _ev_up(evs, event) -> bool:
    """07_summary.sql ev_up (plan 033): one of the card evidence events
    (the top 2 of a class) moved up and is a finding by the wait policy."""
    for e in evs:
        if e["event"] == event:
            b = h.policy_bucket("WAIT", e["event"], e["wclass"], e["cur"], e["mu"], e["sd"], e["n"], e["shr"])
            if b in ("large", "moderate") and e["cur"] > (e["mu"] if e["mu"] is not None else 0):
                return True
    return False


def _commit_lat_up(findings, evs) -> bool:
    """07_summary.sql commit_lat_up (review follow-up R2): log file sync
    flagged up AND its time per commit (wait AAS / user commits per second)
    at least 1.5x the prior windows' (mean wait / mean commit rate)."""
    if not _ev_up(evs, "log file sync"):
        return False
    for f in findings:
        if f.domain == "LOAD" and f.name == "user commits":
            for e in evs:
                if (e["event"] == "log file sync" and e["mu"] is not None
                        and f.cur is not None and f.cur > 0 and f.mu is not None and f.mu > 0
                        and e["cur"] / f.cur >= 1.5 * e["mu"] / f.mu):
                    return True
            return False
    return False


def _pick_hint(g, findings, evs, dbt, cpu):
    """07_summary.sql pick_hint (plan 033): which rule of
    sql/lib/finding_hints.plsql a card gets (None = none); a rule fires
    only on what its sentence claims (review follow-up R2)."""
    if g == "IO":
        if (_f_up(findings, "LOAD", "table scans (long tables)") or _ev_up(evs, "db file scattered read")
                or _ev_up(evs, "direct path read")):
            return "IO_SCANS"
        if _ev_up(evs, "db file sequential read"):
            return "IO_SINGLE"
    elif g == "COMMIT":
        if _commit_lat_up(findings, evs):
            return "COMMIT_LAT"
    elif g == "NET":
        if (_ev_up(evs, "SQL*Net more data to client")
                or _f_up(findings, "LOAD", "bytes sent via SQL*Net to client")):
            return "NET_PAYLOAD"
    elif g == "PARSE":
        if _f_up(findings, "LOAD", "parse count (hard)"):
            return "HARD_PARSE"
    elif g == "DBTIME":
        if dbt is not None and cpu is not None:
            if h.time_split(dbt.cur, dbt.mu, cpu.cur, cpu.mu) == "c":
                return "DBTIME_CPU"
    elif g == "WAIT:Application":
        if _ev_up(evs, "enq: TX - row lock contention"):
            return "ROW_LOCK"
    return None


def _card(w, out, g, pos, lead, ordered, evs, flagcls, dbt, cpu, imp, open_g,
          findings=(), cw=None):
    r = lead[g]
    # impact chip (v1.7): the card's share of the DB-time rise, left out
    # past 100% (a part is measured apart from DB time and can pass it)
    v_imp = imp.get(g)
    v_shr = _g_shr(imp, g)
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
               + '" id="' + cid + '" aria-labelledby="' + cid + '-h"'
               + ' data-impact="' + h.imp_tok(v_imp) + '" data-share="'
               + ("" if v_shr is None else str(v_shr)) + '"'
               + (' data-fold="Y"' if g != open_g else '') + '>'
               '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
               + h.esc(h.card_label(g)) + '"><i class="dotk ' + sev
               + '" aria-hidden="true"></i>' + sev.capitalize() + '</span>'
               + ('<span class="fc-imp" title="Time added: Current minus the prior'
                  ' mean of this card&#39;s time measure (DB time, DB CPU or the foreground time of its'
                  ' wait class), in average active sessions">' + h.imp_txt(v_imp)
                  + (" above normal" if g == "DBTIME"
                     else " &middot; " + ("&lt;1" if v_shr < 1 else str(v_shr)) + "% of the DB-time rise" if v_shr is not None
                     else "")
                  + '</span>' if h.imp_on(v_imp) else '')
               + '<span class="fc-sum"' + (' data-n="' + str(int(r.n)) + '"' if h.conf_mod(r.n) is not None else '') + '>'
               + h.fv(h._mul(r.cur, s), u) + ' &middot; normal '
               + h.fv_range(h._mul(r.mu, s), h._mul(r.sd, s), u) + '</span>'
               '<span class="fc-tags"></span></div>'
               '<div class="fc-band" title="z ' + h.band_ztxt(r.z) + ' against the prior normal">'
               + h.band_span(r.z, sev, "lg", "N", 10) + _AXIS + '</div></header>')
    out.append('<h3 id="' + cid + '-h">' + _f_ent(r) + ' ' + _head_txt(r, dbt, cpu) + '</h3>')
    out.append('<div class="fc-b"><div class="fc-main">'
               '<div class="big"><span class="v">' + h.fv_num(h._mul(r.cur, s), u) + '</span>'
               '<span class="u">' + h.fv_unit(h._mul(r.cur, s), u) + '</span>'
               '<span class="nrm"' + (' data-n="' + str(int(r.n)) + '"' if h.conf_mod(r.n) is not None else '')
               + ' title="prior mean ' + h.fv(h._mul(r.mu, s), u)
               + ('. ' + h.conf_title(r.n) if h.conf_mod(r.n) is not None else '') + '">normal '
               + h.fv_range(h._mul(r.mu, s), h._mul(r.sd, s), u) + '</span></div>')
    out.append('<div class="wg bare hov qf"' + h.wg_attr(w) + '>' + h.wg_flags(True)
               + h.wg_bars(w, r.vals, s, r.mu, r.sd, sev) + h.wg_dates(w, True) + '</div></div>')
    out.append('<dl class="ev">' + ev + '</dl></div>')
    # plan 033: what this usually means, and a read-only next query
    rule = _pick_hint(g, findings, evs, dbt, cpu)
    if rule is not None:
        sql = (h.hint_fill(h.HINT_SQL.get(rule), cw[0], cw[1], cw[2], w.inst_num,
                           t0=cw[3], t1=cw[4])
               if cw is not None and cw[1] is not None else None)
        out.append(h.hint_block(rule, cid, sql))
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


def _tri_row(w, g, r, dbt, cpu) -> str:
    """07_summary.sql emit_tri_row (plan 025): one row of the Summary
    triage list; the impact cell is filled by the inline script."""
    s, u = h.metric_scale(r.domain, r.name), h.metric_unit(r.domain, r.name)
    cid = h.card_id(g)
    lab = h.esc(h.metric_label(r.domain, r.name))
    return ('<div class="tri-row" role="listitem" data-card="' + cid + '">'
            '<span class="tri-f"><i class="dotk ' + r.bucket + '" aria-hidden="true"></i>'
            '<a class="tri-go" href="#' + cid + '">' + h.esc(h.card_label(g)) + '</a>'
            '<span class="tri-m">' + lab + ' ' + _head_txt(r, dbt, cpu) + '</span>'
            '<span class="tri-tags"></span></span>'
            '<span class="tri-nv"><b>' + h.fv(h._mul(r.cur, s), u) + '</b><small>normal '
            + h.fv_range(h._mul(r.mu, s), h._mul(r.sd, s), u) + '</small></span>'
            '<span class="tri-imp"></span>'
            '<span class="tri-spark" data-spark-dense data-spark="' + h.wg_csv(w, r.vals, s)
            + '" data-spark-title="' + lab + '"></span></div>')


def _att(out, findings, order, lead, gsev, dbt, imp) -> None:
    """v1.7 "Where the extra DB time went" (plan 021): the DB-time rise split
    into DB CPU and the wait classes' foreground time (the cards' impact),
    largest first;
    printed hidden and moved into 00's #att-slot.  Twin of 07's nested block
    before the section header."""
    dd = imp.get("DBTIME")
    if not (order and dd is not None and dbt is not None):
        return
    parts, pos, neg = [], 0.0, 0.0
    for f in findings:                      # heat_pos order, like the PL/SQL loop
        if not (f.domain == "WAIT" or (f.domain == "LOAD" and f.name == "DB CPU")):
            continue
        d = h.time_added(f.domain, f.name, f.cur, f.mu, f.fg_d)
        if d is None:
            continue
        lab = "CPU" if f.domain == "LOAD" else (
            f.name[len("Wait class: "):] if f.name.startswith("Wait class: ") else f.name)
        grp = h.impact_group(f.domain, f.name, f.family)
        aid = h.card_id(grp) if grp in lead else _find_id(f)
        parts.append({"lab": lab, "d": d, "grp": grp, "aid": aid})
        if d > 0:
            pos += d
        elif d < 0:
            neg -= d
    parts.sort(key=lambda p: -p["d"])       # stable = the insertion sort's strict >
    if dd > 0:
        # the bar = the rises plus the rest, the rise the parts (falls
        # netted) leave unexplained: dd - (pos - neg)
        base = max(dd + neg, pos)
        bar, lg, small, nsm = "", "", 0.0, 0
        for p in parts:
            d = p["d"]
            if h.imp_on(d) and d >= 0.01 * base:
                fl = p["grp"] in lead
                # the share, left out past 100% like the cards' impact chip
                pct = min(100, int(h.ora_round(d / dd * 100, 0))) if d <= dd * 1.005 else None
                lab = h.esc(p["lab"])
                bar += ('<i class="att-s' + ('' if fl else ' nf') + '" data-wc="' + lab
                        + '" style="flex-grow:' + h.imp_tok(d) + '" title="'
                        + lab + ': +' + h.fmt_num(d) + ' AAS'
                        + (', ' + str(pct) + '% of the DB-time rise' if pct is not None else '')
                        + ('' if fl else ', inside its normal range') + '">'
                        + ('<span>' + lab + ' +' + h.fmt_num(d) + '</span>' if d >= 0.18 * base else '')
                        + '</i>')
                lg += ('<li><i class="sw' + ('' if fl else ' nf') + '" data-wc="' + lab + '" aria-hidden="true"></i>'
                       + h.ent(lab, p["aid"], "card" if fl else "metric")
                       + ' <b>+' + h.fmt_num(d) + '</b>'
                       + ((' <span class="sh">' + ('&lt;1' if pct < 1 else str(pct)) + '%</span>')
                          if pct is not None else '')
                       + ((' <span class="st"><i class="dotk '
                           + ('large' if gsev[p["grp"]] == 2 else 'moderate')
                           + '" aria-hidden="true"></i>finding</span>') if fl
                          else ' <span class="st nf">inside normal</span>')
                       + '</li>')
            elif d > 0:
                small += d
                nsm += 1
        if nsm > 0:
            bar += ('<i class="att-s att-small" style="flex-grow:' + h.imp_tok(small)
                    + '" title="' + str(nsm) + ' smaller part' + ('s' if nsm > 1 else '')
                    + ': +' + h.fmt_num(small) + ' AAS"></i>')
            lg += '<li class="att-more">+ ' + str(nsm) + ' smaller (' + h.fmt_num(small) + ' AAS)</li>'
        rest = dd - (pos - neg)
        if rest > 0.01 * dd:
            bar += ('<i class="att-s att-rest" style="flex-grow:' + h.imp_tok(rest)
                    + '" title="Not in the parts above' + (', net of the falls' if neg > 0 else '')
                    + ' (DB time that no wait class records, such as'
                    + ' waiting for a CPU, or waits outside this template&#39;s event list): +'
                    + h.fmt_num(rest) + ' AAS"></i>')
        # the largest drops: the parts are sorted largest first, so walk backwards
        fell, nfell = "", 0
        for p in reversed(parts):
            if p["d"] >= 0 or nfell >= 3:
                break
            if -p["d"] >= 0.01 * dd:
                fell += (', ' if nfell > 0 else '') + h.esc(p["lab"]) + ' &minus;' + h.fmt_num(-p["d"])
                nfell += 1
        note = ""
        if fell:
            note += 'Fell: ' + fell + ' AAS. '
        # falls offset rises.  The parts are foreground time like DB time, so
        # they roughly add up to the rise; an excess past 2% of it is the gap
        # between two separately kept counters, never background time
        if pos - neg > dd * 1.02:
            note += ('The parts add up to ' + h.imp_txt(pos - neg)
                     + (' net of the falls' if neg > 0 else '') + ', more than the DB-time'
                     ' rise: DB time comes from the time model, the parts from the wait interface'
                     ' and DB CPU, which Oracle keeps separately, so they need not add up exactly.')
        out.append('<div id="att-src" hidden><div class="att-h"><b>Where the extra DB time went</b>'
                   '<span>DB time ' + h.fmt_num(dbt.mu * 0.01) + ' &rarr; '
                   + h.fmt_num(dbt.cur * 0.01) + ' AAS, <b>' + h.imp_txt(dd) + '</b></span></div>')
        out.append('<div class="att-bar" role="img" aria-label="The DB-time rise by wait class and CPU,'
                   ' largest part first">' + bar + '</div>')
        out.append('<ul class="att-lg">' + lg + '</ul>'
                   + ('<p class="att-n">' + note.rstrip(' ') + '</p>' if note else '')
                   + '</div>')
    else:
        out.append('<div id="att-src" hidden><p class="att-n"><b>DB time</b> did not rise: '
                   + h.fmt_num(dbt.cur * 0.01) + ' AAS, against a prior mean of '
                   + h.fmt_num(dbt.mu * 0.01) + ' AAS.</p></div>')
    out.append('<script>(function(){var d=document,s=d.getElementById("att-src"),'
               't=d.getElementById("att-slot"),c=window.AWR_WAIT_COLORS||{};if(!s)return;'
               's.querySelectorAll("[data-wc]").forEach(function(e){var k=e.getAttribute("data-wc");'
               'if(c[k])e.style.setProperty("--c",c[k]);});'
               'if(t){while(s.firstChild)t.appendChild(s.firstChild);t.hidden=false;}'
               's.parentNode.removeChild(s);})();</script>')


def _findings_json(w, out, order, lead, imp, ncl, ncm) -> None:
    """Plan 040: the machine-readable result (07's DECLARE ... json_num block):
    ONE application/json script, schema 1, one line per finding card."""
    nvp = sum(1 for x in w.windows if x.week_offset > 0 and x.valid)
    jn, je = h.json_num, h.json_escape
    out.append('<script type="application/json" id="awr-findings">{"schema":1,"report":{'
               '"version":"' + je(w.awr_version) + '"'
               ',"run_id":"' + je(w.run_id) + '"'
               ',"db_name":"' + je(w.db_name) + '"'
               ',"dbid":' + jn(w.dbid, 0)
               + ',"host":"' + je(w.host_name) + '"'
               ',"target_end":"' + w.target_end.strftime("%Y-%m-%d %H:%M:%S") + '"'
               ',"win_hours":' + jn(w.win_hours)
               + ',"step_hours":' + jn(w.step_hours)
               + ',"weeks_back":' + jn(w.weeks_back, 0)
               + ',"valid_prior_windows":' + str(nvp)
               + ',"template":"' + je(w.template) + '"'
               ',"inst_num":' + jn(w.inst_num, 0)
               + '},"counts":{"cards":' + str(len(order)) + ',"large":' + str(ncl)
               + ',"moderate":' + str(ncm) + '},"cards":[')
    for k, g in enumerate(order, 1):
        r = lead[g]
        s = h.metric_scale(r.domain, r.name)
        out.append('{"id":"' + je(h.card_id(g)) + '"'
                   ',"group":"' + je(g) + '"'
                   ',"label":"' + je(h.card_label(g)) + '"'
                   ',"severity":"' + je(r.bucket) + '"'
                   ',"domain":"' + je(r.domain) + '"'
                   ',"metric":"' + je(r.name) + '"'
                   ',"unit":"' + je(h.metric_unit(r.domain, r.name)) + '"'
                   ',"current":' + jn(h._mul(r.cur, s))
                   + ',"mean":' + jn(h._mul(r.mu, s))
                   + ',"sd":' + jn(h._mul(r.sd, s))
                   + ',"n":' + jn(r.n, 0)
                   + ',"z":' + jn(r.z, 3)
                   + ',"impact_aas":' + jn(imp.get(g), 3)
                   + ',"share_pct":' + jn(_g_shr(imp, g), 0)
                   + '}' + ("," if k < len(order) else ""))
    out.append(']}</script>')


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
    lead, gsev, gz, flagcls, imp = {}, {}, {}, set(), {}
    for f in findings:                      # heat_pos order, like the PL/SQL pass
        # impact (v1.7, helpers.impact_group / time_added): every row,
        # flagged or not; a wait class counts its foreground time only
        ig = h.impact_group(f.domain, f.name, f.family)
        if ig and h.time_added(f.domain, f.name, f.cur, f.mu, f.fg_d) is not None:
            imp[ig] = h.time_added(f.domain, f.name, f.cur, f.mu, f.fg_d)
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
    order = h.card_order({g: (gsev[g], gz[g], imp.get(g)) for g in lead})
    # plan 025: every card but one starts folded in Summary; the open one is
    # the first card that is not DB time, else the only card
    open_g = next((g for g in order if g != "DBTIME"), order[0] if order else None)
    evs = _events(w) if flagcls else []
    ordered = _table_order(findings)
    _att(out, findings, order, lead, gsev, dbt, imp)

    # Counts: in Summary the finding CARDS by severity (the verdict pill and
    # the rail count the same cards); in All sections the canonical flagged
    # ROWS of the detail tables, folded twins apart.
    nc = len(order)
    ncl = sum(1 for g in order if gsev[g] == 2)
    ncm = nc - ncl
    meta = ('<span class="meta' + (' vw in-a' if nc else '') + '">'
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
    out.append('<section id="findings" class="vw in-s in-a sumsec"><h2 id="findings-heading">'
               + (('<span class="vw in-s">' + str(nc) + ' finding' + ('' if nc == 1 else 's') + '</span>'
                   '<span class="vw in-a">Findings</span>') if nc else 'Findings')
               + (('<span class="meta vw in-s" title="finding cards by severity">'
                   + ('<span><i class="dotk large"></i>' + str(ncl) + ' large</span>' if ncl > 0 else '')
                   + ('<span><i class="dotk moderate"></i>' + str(ncm) + ' moderate</span>' if ncm > 0 else '')
                   + '</span>') if nc else '')
               + meta
               + '<small class="h2sub"><span class="vw in-s">'
               + (('From ' + str(crit + warn) + ' flagged metric' + ('' if crit + warn == 1 else 's')
                   + '; ordered by the DB time each card added') if nc
                  else 'Every scored metric against its prior windows')
               + '</span><span class="vw in-a">Every scored metric against its prior windows; one table per domain</span>'
               '</small></h2>')
    if nc:
        # plan 025: the triage list (Summary): every finding on one screen
        out.append('<div id="triage" class="panel tri vw in-s" role="list" aria-label="Findings in card order">'
                   '<div class="tri-hd" aria-hidden="true"><span>Finding</span><span>Now &middot; normal</span>'
                   '<span>Share of the DB-time rise</span><span>' + str(w.weeks_back + 1) + ' windows</span></div>')
        for g in order:
            out.append(_tri_row(w, g, lead[g], dbt, cpu))
        out.append('</div>')
        # plan 033: the Current window's DBID, snapshot range and nominal
        # start / end, for the cards' read-only "Next step" queries (None
        # when it is not valid; the model is single-instance, so 07's
        # valid-instance list never applies)
        cwin = next((x for x in w.valid_windows if x.week_offset == 0), None)
        cw = ((cwin.dbid, cwin.begin_snap_id, cwin.end_snap_id,
               cwin.win_start_ts.strftime("%Y-%m-%d %H:%M:%S"), cwin.win_end_ts.strftime("%Y-%m-%d %H:%M:%S"))
              if cwin is not None else None)
        out.append('<div class="cards vw in-s">')
        for k, g in enumerate(order, 1):
            _card(w, out, g, k, lead, ordered, evs, flagcls, dbt, cpu, imp, open_g, findings, cw)
        out.append('</div>')
        # v1.7: each card's share of the DB-time rise rides on data-shr (CSS ::after)
        js = ",".join('["' + h.card_id(g) + '","' + h.card_label(g).replace('"', '').replace('<', '') + '","'
                      + ("" if g == "DBTIME" or _g_shr(imp, g) is None else str(_g_shr(imp, g))) + '"]'
                      for g in order)
        out.append('<script>(function(){var n=document.querySelector(\'nav.toc a[href="#findings"]\');'
                   'if(!n)return;[' + js + '].forEach(function(c){var a=document.createElement("a");'
                   'a.className="sub";a.href="#"+c[0];a.setAttribute("data-nodot","");a.textContent=c[1];'
                   'if(c[2]){var p=(c[2]==="0"?"<1":c[2])+"%";a.setAttribute("data-shr",p);a.title=c[1]+": "+p+" of the DB-time rise";}'
                   'n.parentNode.insertBefore(a,n.nextSibling);n=a;});})();</script>')
        # plan 025: the impact cells, row clicks and folding, lifted verbatim
        L = chrome.put_lines(chrome.sql_path("sql/07_summary.sql"))
        i = next(k for k, (t, _) in enumerate(L)
                 if t.startswith('<script>(function(){var d=document,tri=d.getElementById("triage");'))
        j = next(k for k in range(i, len(L)) if L[k][0] == '})();</script>')
        assert all(ok for _, ok in L[i:j + 1])
        out.extend(t for t, _ in L[i:j + 1])
    else:
        out.append('<div class="panel calm vw in-s"><p class="calm-empty">'
                   + ('Nothing could be scored: a metric needs at least 3 valid prior windows.' if normal == 0
                      else 'No finding: every scored metric sits inside its normal range, or moved too little to matter.')
                   + '</p></div>')

    _findings_json(w, out, order, lead, imp, ncl, ncm)

    _emit_domain_table(out, ordered, "LOAD", "Load profile")
    _emit_domain_table(out, ordered, "METRIC", "System metrics")
    _emit_domain_table(out, ordered, "WAIT", "Wait classes")
    out.append("</section>")

    out.append('<section id="s-changes" class="vw in-s sumsec" hidden>'
               '<h2>What changed around it<small class="h2sub">Plan and configuration changes '
               'under the release flags</small></h2>'
               '<div class="cards" id="changes-slot"></div></section>')

    out.append('<section id="s-normal" class="vw in-s sumsec"><h2>Checked and normal'
               '<span class="meta"><span><i class="dotk typical"></i>' + str(normal) + ' normal</span></span>'
               '<small class="h2sub">Every other scored metric, against the same prior windows</small></h2>')
    if normal == 0:
        out.append('<div class="panel calm"><p class="calm-empty">'
                   'Nothing could be scored as normal: a metric needs at least 3 valid prior windows.'
                   '</p></div>')
    else:
        # plan 032: count the three groups first, so the folded summary line
        # can name them; they add up to `normal`
        cg = cs = ci = 0
        for f in ordered:
            if f.canonical != "Y":
                continue
            if (f.bucket == "typical" and f.az <= 2) or f.bucket == "flat baseline":
                cg += 1
            elif (f.bucket == "typical" and f.az > 2) or f.bucket == "noted":
                cs += 1
            elif f.bucket == "improved":
                ci += 1
        # plan 032: the body folds to one line in the Summary view; open when
        # there is no finding card (then this section is the story)
        out.append('<details class="calm-fold"' + (' open' if nc == 0 else '') + '>'
                   '<summary class="calm-sum"><span><b>' + str(cg) + '</b> metric'
                   + ('' if cg == 1 else 's') + ' within the normal range</span>'
                   '<span>&middot; <b>' + str(cs) + '</b> moved too little to matter</span>'
                   '<span>&middot; '
                   + ('nothing improved materially' if ci == 0 else '<b>' + str(ci) + '</b> improved')
                   + '</span></summary>')
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
        out.append('</details>')
    out.append('</section>')
    out.append('<section id="s-lib" class="vw in-s vhead"><h2>Evidence library'
               '<small class="h2sub">Every other section, one line each; open a row to read it here</small></h2></section>')
    out.extend(_timeline(w, _table_order(findings)))
    out.append("<!-- AWR-SECTION: 07_summary END -->")
    return "\n".join(out)


# ---- v1.6.0 Timeline: 07's emit_timeline (headline + flagged rows) -------
_HL = ["LOAD:DB time", "LOAD:DB CPU", "METRIC:Database Wait Time Ratio",
       "LOAD:session logical reads", "LOAD:physical reads", "LOAD:physical read total bytes",
       "LOAD:table scans (long tables)", "METRIC:SQL Service Response Time",
       "METRIC:Host CPU Utilization (%)", "LOAD:redo size", "LOAD:parse count (hard)"]


def _hl_rank(f):
    k = f.domain + ":" + f.name
    return _HL.index(k) + 1 if k in _HL else None


def _tl_row(w, f, cls):
    s = h.metric_scale(f.domain, f.name)
    u = h.metric_unit(f.domain, f.name)
    tw = "Y" if f.canonical == "N" else "N"
    return h.tl_bars(w, h.wg_csv(w, f.vals, s), h._mul(f.mu, s), h._mul(f.sd, s),
                     f.bucket if tw == "N" else None,
                     h.tl_lab(_f_ent(f),
                              ("wait class, " + u if f.domain == "WAIT" else u) + (", twin" if tw == "Y" else ""),
                              h.esc(f.name),
                              f.name[len("Wait class: "):] if f.domain == "WAIT" else None),
                     h.tl_gut(h._mul(f.cur, s), h._mul(f.mu, s), h._mul(f.sd, s), f.bucket, None, tw),
                     "tl-" + _find_id(f),
                     ((cls or "") + (" twin" if tw == "Y" else "")).strip() or None,
                     h.esc(h.metric_label(f.domain, f.name)), u)


def _timeline(w, ordered):
    out, n = [], 0
    for hr in range(1, 12):
        for f in ordered:
            if _hl_rank(f) == hr:
                out.append((h.tl_open("metrics") if n == 0 else "") + _tl_row(w, f, None))
                n += 1
    for f in ordered:
        if (f.domain in ("LOAD", "METRIC") and _hl_rank(f) is None and f.bucket in _MOVED
                and f.canonical == "Y"):
            out.append((h.tl_open("metrics") if n == 0 else "") + _tl_row(w, f, None))
            n += 1
    if n:
        out.append(h.tl_close())
    n = 0
    for f in ordered:
        if f.domain == "WAIT" and f.bucket in _MOVED:
            out.append((h.tl_open("waits") if n == 0 else "") + _tl_row(w, f, "w"))
            n += 1
    if n:
        out.append(h.tl_close())
    return out
