"""
Twin of sql/06_top_sql.sql -- Top-N SQL per window ranked five ways (+ the
PEREXEC regression and the CHANGE "Biggest change" dimensions), per-dim detail tables, the SQL pool table
with paired detail rows, the AWR_DATA.topSql / AWR_DATA.sqlDetails JSON
payloads, and every inline <script> of the original (lifted verbatim).

"Values: Total | Per execution | Top per execution" (mode values total,
perexec, pe-rank), two parts that must not be mixed up:
  * perexec = the SWAP inside the Total view of the four total metric dims
    (ELAPSED / CPU / GETS / PREADS; _SWAP_UNIT): span.tsv data-pe / data-pt,
    the "Pe" payload arrays, executions carried per window;
  * pe-rank = the separate RANKING, four more dims (ELAPSED_PE ... PREADS_PE;
    _PE_METRIC): the tsv-view[data-val="pe-rank"] of the tab.

Data: per window `m = w.window_metrics(win)`, `m.sql[sql_id]` = the
DBA_HIST_SQLSTAT *_DELTA sums for that window; `w.sql_by_id` supplies the
text / parsing schema / module / action; the full-retention scan for the
per-SQL detail rows walks every snapshot of `w.snaps`.

Per-SQL detail rows: the "Compared windows" table is built from the same
per-window agg numbers as the ranking (valid windows only; a valid window
without a row = "not captured"), the chart payload is the compact
{t0, p:[[min, plan idx, execs, s/exec]], phv:[...]} form, and a statement
with no non-zero plan hash (the demo's PL/SQL call) gets a "no plan" row.

Locally derived (the model lacks them): DBA_HIST_SQLSTAT integer counters
(execs / elapsed / cpu / gets / reads are rounded to whole numbers the way
AWR stores them), `optimizer_mode` (= ALL_ROWS), `force_matching_signature`
(stable per sql_id via w.rng), `sql_profile` (= NULL).
"""
from __future__ import annotations

import math
from datetime import timedelta

from awrdemo import chrome
from awrdemo import helpers as h
from awrdemo.model import FG_EVENTS, ilog10
from awrdemo.helpers import (anchor_id, esc, fmt_int, fmt_num, fmt_num_title, is_oracle_schema,
                             json_escape, mon_dd, num6, ora_round, to_char_fixed, ts_min)

_SQL = chrome.sql_path("sql/06_top_sql.sql")

# dims CTE: code, ord, label, unit, divisor  (static in the SQL).  The four
# *_PE codes are the per-execution rankings of the Values: Total | Per
# execution switch: each is a view of its metric's tabpanel, ord between the
# total ranking and the next metric.
_DIMS = [
    ("ELAPSED", 1, "By elapsed time", "s", 1e6),
    ("ELAPSED_PE", 1.5, "By elapsed time per execution", "s/exec", 1e6),
    ("CPU", 2, "By CPU time", "s", 1e6),
    ("CPU_PE", 2.5, "By CPU time per execution", "s/exec", 1e6),
    ("GETS", 3, "By buffer gets", "gets", 1),
    ("GETS_PE", 3.5, "By buffer gets per execution", "gets/exec", 1),
    ("PREADS", 4, "By physical reads", "reads", 1),
    ("PREADS_PE", 4.5, "By physical reads per execution", "reads/exec", 1),
    ("EXEC", 5, "By executions", "exec", 1),
    ("PEREXEC", 6, "By per-exec regression", "s/exec", 1e6),
    ("CHANGE", 0, "By change in elapsed time (Current vs the prior mean)", "s", 1e6),
]
_RANK_DIMS = ("ELAPSED", "CPU", "GETS", "PREADS", "EXEC")
_METRIC_OF = {"ELAPSED": "ela", "CPU": "cpu", "GETS": "gets", "PREADS": "reads", "EXEC": "execs"}
# the per-execution rankings: dim -> the metric divided by the window's executions
_PE_METRIC = {"ELAPSED_PE": "ela", "CPU_PE": "cpu", "GETS_PE": "gets", "PREADS_PE": "reads"}
_PE_OF = {"ELAPSED": "ELAPSED_PE", "CPU": "CPU_PE", "GETS": "GETS_PE", "PREADS": "PREADS_PE"}
_TOTAL_OF = {v: k for k, v in _PE_OF.items()}
# the four TOTAL metric dims carry the swap; their per-execution unit word
# (v_dim_unit_swap).  Never a *_PE dimension, CHANGE, EXEC or PEREXEC.
_SWAP_UNIT = {"ELAPSED": "s/exec", "CPU": "s/exec", "GETS": "gets/exec", "PREADS": "reads/exec"}
_JSON_CAP = 32500      # c_json_cap


# ---------------------------------------------------------------------
# literal <script> lifting
# ---------------------------------------------------------------------

def _lines():
    return chrome.put_lines(_SQL)


def _slice(lines, first: str, last: str, start: int = 0,
           last_prefix: bool = False) -> tuple[list[str], int]:
    """Literal PUT_LINE texts from the first entry equal to `first` (at or
    after index `start`) through the next entry equal to `last` (or, with
    `last_prefix`, the next one that starts with it)."""
    i = start
    while lines[i][0] != first:
        i += 1
    j = i
    while not (lines[j][0].startswith(last) if last_prefix else lines[j][0] == last):
        j += 1
    for t, ok in lines[i:j + 1]:
        if not ok:
            raise ValueError("non-literal PUT_LINE inside a lifted script block: " + t[:60])
    return [t for t, _ in lines[i:j + 1]], j + 1


# ---------------------------------------------------------------------
# model access
# ---------------------------------------------------------------------

def _ival(x: float) -> float:
    return ora_round(x, 0)


# plan 044: the model's per-statement wait split (event -> microseconds) by
# wait class, for the CCWAIT_DELTA / APWAIT_DELTA twins
_EV_CLASS = {e.name: e.wait_class for e in FG_EVENTS}


def _class_us(x, cls: str) -> float:
    return math.fsum(us for ev, us in x.waits.items() if _EV_CLASS.get(ev) == cls)


def _agg(w):
    """agg CTE: {week_offset: {sql_id: dict(execs, ela, cpu, gets, reads, phv, schema,
    io, cc, ap, cl, rows)}} over VALID windows only.  Plan 044's wait timers:
    I/O = the model's iowait_us, concurrency / application = its wait split
    summed by wait class, cluster = 0 (one instance)."""
    out = {}
    for win in w.windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        rows = {}
        for sid, x in m.sql.items():
            rows[sid] = {
                "execs": _ival(x.execs), "ela": _ival(x.elapsed_us), "cpu": _ival(x.cpu_us),
                "gets": _ival(x.gets), "reads": _ival(x.reads),
                "phv": x.plan_hash, "schema": w.sql_by_id[sid].schema,
                "io": _ival(x.iowait_us), "cc": _ival(_class_us(x, "Concurrency")),
                "ap": _ival(_class_us(x, "Application")), "cl": 0.0, "rows": _ival(x.rows),
            }
        out[win.week_offset] = rows
    return out


def _rank(rows: dict, key: str, name_of=lambda k: k) -> dict:
    """ROW_NUMBER() OVER (ORDER BY metric DESC, name) -> {name: rank}."""
    order = sorted(rows.keys(), key=lambda k: (-rows[k][key], name_of(k)))
    return {k: i + 1 for i, k in enumerate(order)}


def _picked(w, agg):
    """picked CTE: ({(dim, sql_id, week_offset): (metric_value, rnk, phv)},
    {sql_id: (prior mean elapsed, prior valid windows with a row)} of the
    CHANGE dimension (chg_ranked))."""
    top_n = w.top_n
    picked = {}
    for off, rows in agg.items():
        for dim in _RANK_DIMS:
            key = _METRIC_OF[dim]
            rk = _rank(rows, key)
            for sid, r in rows.items():
                if rk[sid] <= top_n and r[key] > 0:
                    picked[(dim, sid, off)] = (r[key], rk[sid], r["phv"])
        # the per-execution rankings (ranked_pe): value over completed
        # executions, only statements with an execution and a value above 0
        # are ranked (NULLS LAST + the > 0 filter: ranks 1, 2, 3 without a
        # gap), the token carries 9 decimals
        for dim, key in _PE_METRIC.items():
            pe = {sid: r[key] / r["execs"] for sid, r in rows.items()
                  if r["execs"] > 0 and r[key] > 0}
            for i, sid in enumerate(sorted(pe, key=lambda k: (-pe[k], k))[:top_n], start=1):
                picked[(dim, sid, off)] = (ora_round(pe[sid], 9), i, rows[sid]["phv"])
    # per_exec / delta_ranked
    per_exec = {}   # (sid, off) -> per_exec_us | None
    for off, rows in agg.items():
        for sid, r in rows.items():
            per_exec[(sid, off)] = (r["ela"] / r["execs"]) if r["execs"] > 0 else None
    cands = []
    for sid in {s for s, _ in per_exec}:
        cur_pe = per_exec.get((sid, 0))
        priors = [v for (s, o), v in per_exec.items() if s == sid and o > 0 and v is not None]
        cur_execs = agg.get(0, {}).get(sid, {}).get("execs")
        if cur_pe is None or not priors:
            continue
        prior_pe = sum(priors) / len(priors)
        if cur_pe > prior_pe and cur_execs is not None and cur_execs >= 3:
            cands.append((sid, cur_pe - prior_pe))
    cands.sort(key=lambda t: (-t[1], t[0]))
    r_delta = {sid: i + 1 for i, (sid, _) in enumerate(cands)}
    for (sid, off), pe in per_exec.items():
        rd = r_delta.get(sid)
        if rd is not None and rd <= top_n and pe is not None:
            picked[("PEREXEC", sid, off)] = (pe, rd if off == 0 else None, agg[off][sid]["phv"])
    # n_prior_valid / chg_ranked: Current total elapsed minus the mean over
    # the prior VALID windows (agg holds valid windows only, an empty one
    # included; a statement without a row there counts as 0)
    priors = [o for o in agg if o > 0]
    chg = []
    chg_mu = {}
    for sid, r in agg.get(0, {}).items():
        if not priors:
            break
        prior_mean = sum(agg[o][sid]["ela"] for o in priors if sid in agg[o]) / len(priors)
        if r["ela"] > prior_mean:
            chg.append((sid, r["ela"] - prior_mean))
            # (prior mean, n_prior_rows = prior valid windows with a row)
            chg_mu[sid] = (prior_mean, sum(1 for o in priors if sid in agg[o]))
    chg.sort(key=lambda t: (-t[1], t[0]))
    for i, (sid, _) in enumerate(chg, start=1):
        if i > top_n:
            break
        for off, rows in agg.items():
            if sid in rows:
                picked[("CHANGE", sid, off)] = (rows[sid]["ela"], i if off == 0 else None,
                                                rows[sid]["phv"])
    return picked, chg_mu


def _per_sql(w, picked):
    """per_sql CTE rows in the cursor's ORDER BY, as dicts."""
    nweeks = w.weeks_back + 1
    keys = sorted({(d, s) for d, s, _ in picked})
    ordmap = {d[0]: d[1] for d in _DIMS}
    rows = []
    for dim, sid in keys:
        vals, rnks, phvs = [], [], []
        for off in range(nweeks):
            p = picked.get((dim, sid, off))
            vals.append(p[0] if p else None)
            rnks.append(p[1] if p else None)
            phvs.append(p[2] if p else None)
        rn = [r for r in rnks if r is not None]
        mv = [v for v in vals if v is not None]
        rows.append({
            "dim": dim, "sql_id": sid,
            "cur_val": vals[0], "cur_rnk": rnks[0], "cur_phv": phvs[0],
            "best_rank": min(rn) if rn else None,
            "best_value": max(mv) if mv else None,
            "vals": vals, "rnks": rnks, "phvs": phvs,
        })
    rows.sort(key=lambda r: (ordmap[r["dim"]],
                             1 if r["cur_rnk"] is None else 0,
                             r["cur_rnk"] if r["cur_rnk"] is not None else 0,
                             r["best_rank"] if r["best_rank"] is not None else float("inf"),
                             -(r["best_value"] or 0), r["sql_id"]))
    return rows


def _group_rows(w, agg):
    """Second cursor: per-(dim, grp_type, grp_value) chart series, in the
    cursor's ORDER BY."""
    top_n = w.top_n
    nweeks = w.weeks_back + 1
    # base -> agg by grp_type
    gagg = {}   # (off, grp_type) -> {grp_value: {metric: sum}}
    for off, rows in agg.items():
        for sid, r in rows.items():
            d = w.sql_by_id[sid]
            names = {"schema": d.schema or "(unknown)",
                     "module": d.module or "(none)",
                     "action": d.action or "(none)"}
            for gt, gv in names.items():
                slot = gagg.setdefault((off, gt), {}).setdefault(
                    gv, {"execs": 0, "ela": 0, "cpu": 0, "gets": 0, "reads": 0})
                for k in slot:
                    slot[k] += r[k]
    picked = {}
    for (off, gt), rows in gagg.items():
        for dim in _RANK_DIMS:
            key = _METRIC_OF[dim]
            rk = _rank(rows, key)
            for gv, r in rows.items():
                if rk[gv] <= top_n and r[key] > 0:
                    # (value, rank, the group's summed executions: the swap's divisor)
                    picked[(dim, gt, gv, off)] = (r[key], rk[gv], r["execs"])
        # per execution: the group's summed value over its summed executions
        # (the four *_PE branches carry no executions: they are not swapped)
        for dim, key in _PE_METRIC.items():
            pe = {gv: r[key] / r["execs"] for gv, r in rows.items()
                  if r["execs"] > 0 and r[key] > 0}
            for i, gv in enumerate(sorted(pe, key=lambda k: (-pe[k], k))[:top_n], start=1):
                picked[(dim, gt, gv, off)] = (ora_round(pe[gv], 9), i, None)
    ordmap = {d[0]: d[1] for d in _DIMS}
    out = []
    for dim, gt, gv in sorted({(d, t, v) for d, t, v, _ in picked}):
        vals, rnks, execs = [], [], []
        for off in range(nweeks):
            p = picked.get((dim, gt, gv, off))
            vals.append(p[0] if p else None)
            rnks.append(p[1] if p else None)
            execs.append(p[2] if p else None)
        rn = [r for r in rnks if r is not None]
        mv = [v for v in vals if v is not None]
        out.append({"dim": dim, "grp_type": gt, "grp_value": gv, "cur_rnk": rnks[0],
                    "best_rank": min(rn), "best_value": max(mv), "vals": vals,
                    "execs": execs})
    out.sort(key=lambda r: (ordmap[r["dim"]], r["grp_type"],
                            1 if r["cur_rnk"] is None else 0,
                            r["cur_rnk"] if r["cur_rnk"] is not None else 0,
                            r["best_rank"], -r["best_value"], r["grp_value"]))
    return out


def _chart_vals(vals, div) -> str:
    """Oldest -> newest, 'null' for a missing slot, num6(value/div)."""
    return ",".join("null" if v is None else num6(v / div) for v in reversed(vals))


def _pe_json(v) -> str:
    """pe_json(): about 4 significant digits, trailing zeros trimmed, 'null'
    for None."""
    if v is None:
        return "null"
    a = min(abs(v), 99999999999)
    if a == 0:
        return "0"
    dec = max(0, min(9, 3 - ilog10(a)))
    return ("-" if v < 0 else "") + h.to_char_trim(ora_round(a, dec), 9).rstrip(".")


def _series(dim, vals, div) -> str:
    """The chart series values of one entry: the per-execution rankings keep
    about 4 significant digits (pe_json), every other dimension 6 decimals."""
    if dim in _PE_METRIC:
        return ",".join("null" if v is None else _pe_json(v / div) for v in reversed(vals))
    return _chart_vals(vals, div)


def _pe_val(v, x):
    """pe_val(): a value over its executions; None when none completed (never
    0, never a division by zero)."""
    if v is None or x is None or x <= 0:
        return None
    return v / x


def _chart_swap(vals, execs, div) -> str:
    """The swap's twin of _chart_vals: oldest -> newest, the slot's value over
    its executions, 'null' for a missing slot or a window without a completed
    execution."""
    return ",".join("null" if v is None else _pe_json(_pe_val(v / div, x))
                    for v, x in reversed(list(zip(vals, execs))))


def _tsv_span(txt, pe, full) -> str:
    """tsv_span(): the number of a value cell of a total table with its
    per-execution text in data-pe (and the title text in data-pt)."""
    t = '<span class="tsv" data-pe="' + fmt_num(pe) + '"'
    if pe is None:
        t += ' data-pt="no completed execution in this window"'
    elif full == "Y":
        t += fmt_num_title(pe).replace(' title="', ' data-pt="')
    return t + ">" + txt + "</span>"


def _tsv_switch(dim) -> str:
    """tsv_switch(): the Values: Total | Per execution | Top per execution
    switch of a panel (button values = the mode values)."""
    return ('<div class="topsql-toggle topsql-val" data-tsv="' + dim
            + '" role="group" aria-label="Values: total, per execution, or top per execution">'
            "<span>Values:</span>"
            '<button type="button" data-val="total" class="active" aria-pressed="true"'
            " title=\"Each window's top statements by the window total\">Total</button>"
            '<button type="button" data-val="perexec" aria-pressed="false"'
            " title=\"The same statements and order as Total, each value divided by the statement's executions\">Per execution</button>"
            '<button type="button" data-val="pe-rank" aria-pressed="false"'
            " title=\"A different statement set: each window's top statements by value per completed execution\">Top per execution</button>"
            "</div>")


def _tsv_note(dim) -> str:
    """tsv_note(): what a tab with no per-execution form says in the other modes
    (tsv-n-other: per execution and top per execution mode, tsv-n-total: total)."""
    if dim == "CHANGE":
        return ('<p class="tsv-note tsv-n-other">Biggest change compares total elapsed time, whatever the switch says.'
                ' Its per-execution counterpart is the <button type="button" class="tsv-go" data-tsv-goto="PEREXEC">'
                "Per-exec regression</button> tab.</p>")
    if dim == "EXEC":
        return ('<p class="tsv-note tsv-n-other">Executions is a count, so it has no per-execution form:'
                " this tab reads the same in every mode.</p>")
    if dim == "PEREXEC":
        return ('<p class="tsv-note tsv-n-total">Per-exec regression always ranks the change in elapsed time per execution,'
                " whatever the switch says. Its total counterpart is the"
                ' <button type="button" class="tsv-go" data-tsv-goto="CHANGE">Biggest change</button> tab.</p>')
    return ""


def _tsv_empty_view(label) -> str:
    """tsv_empty_view(): the Top per execution view of a tab with no row in it."""
    return ('<div class="tsv-view" data-val="pe-rank"><h3>' + label
            + ' per execution</h3><p class="note">No statement completed an execution with a'
            " non-zero value in any compared window, so there is no per-execution ranking.</p></div>")


def _retention(w, sid):
    """Full-retention per-SQL scan over every snapshot: (points, meta)."""
    pts = []
    for s in w.snaps:
        x = w.hour(s.end_ts).sql.get(sid)
        if x is None:
            continue
        pts.append((s, _ival(x.execs), _ival(x.elapsed_us), _ival(x.gets), x.plan_hash))
    return pts


# ---------------------------------------------------------------------
# per-SQL detail: Compared windows table + chart payload
# ---------------------------------------------------------------------

def _cnt(n):
    """sqd_cnt: a whole execution count below 10000 prints as an integer."""
    if n is not None and n == int(n) and n < 10000:
        return fmt_int(n)
    return fmt_num(n)


def _sqd_chg(p_cur, p_mu, p_n, p_what):
    """sqd_chg(): plain change of Current against the prior mean."""
    if p_cur is None:
        return ""
    if not p_n:
        return ' <span class="d s-plain" title="no row in any prior valid window">new</span>'
    if p_mu is not None and p_mu == 0:
        if p_cur == 0:
            return ""
        return (' <span class="d s-plain" title="' + p_what
                + ' was 0 in the prior mean">from 0</span>')
    t = h.delta_span(p_cur, p_mu, None, "Y")
    return " " + t.replace('<span class="d s-plain">',
                           '<span class="d s-plain" title="' + p_what
                           + ", Current vs the prior mean of " + str(p_n)
                           + (" window" if p_n == 1 else " windows") + '">')


def _windows_table(w, sid, agg) -> list[str]:
    """The 'Compared windows' block of one opened pool row (one string per
    PUT_LINE).  Numbers come from `agg` (the main cursor's agg join: valid
    windows only; a missing key = no AWR row, or a skipped window)."""
    weeks_back = w.weeks_back
    ex, ela, phv = {}, {}, {}
    for off, rows in agg.items():
        r = rows.get(sid)
        if r is not None:
            ex[off], ela[off], phv[off] = r["execs"], r["ela"], r["phv"]
    wn = wsx = wse = 0
    for k in range(1, weeks_back + 1):
        if k in ex:
            wn += 1
            wsx += ex[k]
            wse += ela[k] or 0
    mu_x = wsx / wn if wn > 0 else None
    mu_e = wse / wn / 1e6 if wn > 0 else None
    mu_pe = wse / wsx / 1e6 if wn > 0 and wsx > 0 else None
    # plan change marks: window k (valid, with a row, non-zero plan) ran a
    # different plan than the nearest OLDER such window (all windows
    # 0..weeks_back; other windows are passed over)
    wchg, wlast = {}, None
    for k in range(weeks_back, -1, -1):
        if k in phv:
            wcur = phv[k]
            if wcur:
                if wlast is not None and wcur != wlast:
                    wchg[k] = wlast
                wlast = wcur

    out = []
    out.append('<h4 class="sqd-h">Compared windows</h4>'
               '<p class="sqd-sub">This statement in each of the report&#39;s '
               + str(weeks_back + 1) + " window" + ("" if weeks_back == 0 else "s")
               + " (totals per window).</p>"
               '<div class="sqd-tw"><table id="win-' + sid
               + '" class="sqd-win" data-nosort data-nocount data-notools><thead><tr>'
               '<th>Window</th><th class="num">Executions</th><th class="num">Elapsed (s)</th>'
               '<th class="num">s / exec</th><th class="num">Plan hash</th>'
               "</tr></thead><tbody>")
    wmax = min(weeks_back, 29)

    def state(k):
        """sqd_state: 'S' + reason (skipped), 'N' (no AWR row), 'V' (values)."""
        win = w.windows[k]
        if not win.valid:
            return "S" + (win.skip_reason or "no valid snapshot pair")[:200]
        return "V" if k in ex else "N"

    skipto = -1
    for k in range(0, wmax + 1):
        if k <= skipto:
            continue
        st = state(k)
        if k > 0 and st != "V":
            b = k
            while b < wmax:
                if state(b + 1) != st:
                    break
                b += 1
            if b > k:
                skipto = b
                lab = ("&minus;" + w.offset_labels[k - 1] + " &ndash; &minus;" + w.offset_labels[b - 1]
                       + ' <span class="sqd-dt">' + str(b - k + 1) + " windows</span>")
                if st[0] == "S":
                    out.append('<tr class="skip" title="Skipped windows: not compared and not in the mean">'
                               "<td>" + lab + "</td>"
                               '<td colspan="4" title="Skipped windows: not compared and not in the mean">skipped: '
                               + esc(st[1:]) + "</td></tr>")
                else:
                    out.append('<tr class="sqd-nocap"><td>' + lab + "</td>"
                               '<td colspan="4" class="sqd-mu" title="AWR kept no row for this statement '
                               'in these windows: it ran too little to be captured, or not at all.">'
                               "not captured</td></tr>")
                continue
        wlab = ("<b>Current</b>" if k == 0 else "&minus;" + w.offset_labels[k - 1]) \
            + ' <span class="sqd-dt">' + h.wg_title(w, k) + "</span>"
        win = w.windows[k]
        if not win.valid:
            reason = win.skip_reason or "no valid snapshot pair"
            out.append('<tr class="skip" title="Skipped window: not compared and not in the mean">'
                       '<td data-w="' + str(k) + '">' + wlab + "</td>"
                       '<td colspan="4" data-w="' + str(k)
                       + '" title="Skipped window: not compared and not in the mean">skipped: '
                       + esc(reason[:200]) + "</td></tr>")
        elif k not in ex:
            out.append('<tr class="sqd-nocap"><td data-w="' + str(k) + '">' + wlab + "</td>"
                       '<td colspan="4" class="sqd-mu" data-w="' + str(k)
                       + '" title="AWR kept no row for this statement in this window: '
                       'it ran too little to be captured, or not at all.">not captured</td></tr>')
        else:
            wx = ex[k]
            we = (ela[k] or 0) / 1e6
            wph = phv[k]
            wpe = we / wx if wx > 0 else None
            row = ("<tr" + (' class="cur"' if k == 0 else "") + ">"
                   '<td data-w="' + str(k) + '">' + wlab + "</td>"
                   '<td class="num" data-w="' + str(k) + '"' + fmt_num_title(wx) + ">"
                   + _cnt(wx)
                   + (_sqd_chg(wx, mu_x, wn, "Executions") if k == 0 else "")
                   + "</td>"
                   '<td class="num" data-w="' + str(k) + '"' + fmt_num_title(we) + ">"
                   + fmt_num(we)
                   + (_sqd_chg(we, mu_e, wn, "Elapsed") if k == 0 else "")
                   + "</td>")
            if wpe is None:
                row += ('<td class="num" data-w="' + str(k)
                        + '" title="No execution completed in this window, so s / exec is undefined, not 0.">&mdash;</td>')
            else:
                row += ('<td class="num" data-w="' + str(k) + '"' + fmt_num_title(wpe) + ">"
                        + fmt_num(wpe)
                        + (_sqd_chg(wpe, mu_pe, wn, "s / exec") if k == 0 else "")
                        + "</td>")
            if not wph:
                pl = ('<span class="sqd-mu" title="No plan hash: a PL/SQL call, or another statement '
                      'without an execution plan">&mdash;</span>')
            else:
                pl = str(wph)
                if k in wchg:
                    pl += (' <span class="badge sqd-pc" title="Plan changed in this window. '
                           'The window before it with a plan ran '
                           + str(wchg[k]) + '">plan&#8593;</span>')
            row += '<td class="num mono" data-w="' + str(k) + '">' + pl + "</td></tr>"
            out.append(row)
    foot = ('</tbody><tfoot><tr><td>Prior mean <span class="sqd-dt">('
            + ("no prior window with a row" if wn == 0
               else str(wn) + (" window" if wn == 1 else " windows") + " with a row")
            + ")</span></td>")
    if wn == 0:
        foot += ('<td class="num"><span class="sqd-mu">&mdash;</span></td>' * 3)
    else:
        foot += ('<td class="num"' + fmt_num_title(mu_x) + ">" + _cnt(mu_x) + "</td>"
                 '<td class="num"' + fmt_num_title(mu_e) + ">" + fmt_num(mu_e) + "</td>"
                 '<td class="num"' + fmt_num_title(mu_pe) + ">" + fmt_num(mu_pe) + "</td>")
    foot += '<td class="num"><span class="sqd-mu">&mdash;</span></td></tr></tfoot></table></div>'
    out.append(foot)
    out.append('<p class="sqd-sub sqd-fn">Current vs the prior mean is a plain change, not a score: '
               "Top SQL is ranked, not scored.</p>")
    if weeks_back > 29:
        out.append('<p class="sqd-sub sqd-fn">Showing Current and the 29 most recent of '
                   + str(weeks_back) + " prior windows; the mean covers every valid one.</p>")
    out.extend(_split_block(w, sid, agg, ex, wn, wsx))
    return out


# ---------------------------------------------------------------------
# plan 044: Per execution, where the time went (twin of the block after the
# Compared windows table; the thresholds and rules are 06's c_sqx_*)
# ---------------------------------------------------------------------

_SQX_GATE, _SQX_PART, _SQX_FLAT, _SQX_UP = 1.5, 0.6, 0.2, 1.5
# row index -> agg key (1 elapsed .. 10 physical reads; 7 = other, derived)
_SQX_KEY = {1: "ela", 2: "cpu", 3: "io", 4: "cc", 5: "ap", 6: "cl", 8: "rows", 9: "gets", 10: "reads"}
_SQX_NAMES = {1: ("Elapsed (s)", "elapsed"), 2: ("CPU (s)", "CPU"), 3: ("I/O wait (s)", "I/O wait"),
              4: ("Concurrency (s)", "concurrency wait"), 5: ("Application, locks (s)", "application wait"),
              6: ("Cluster (s)", "cluster wait"), 7: ("Other (s)", "other time")}


def _sqx_nm(k, short=False):
    if k in _SQX_NAMES:
        return _SQX_NAMES[k][1 if short else 0]
    return {8: "Rows", 9: "Buffer gets", 10: "Physical reads"}.get(k, "Buffer gets per row")


def _sqx_tok(v):
    """TO_CHAR(v, 'TM9'): every token here is an integer-valued total."""
    return "" if v is None else str(int(ora_round(v, 0)))


def _sqx_x(r):
    return "&times;" + (str(int(ora_round(r, 0))) if r >= 100 else to_char_fixed(r, 1))


def _sqx_pct(sh):
    if sh is None:
        return ""
    v = ora_round(sh * 100, 0)
    return ("&minus;" if v < 0 else "") + str(int(abs(v))) + "%"


def _sqx_flat(r):
    return r is not None and 1 - _SQX_FLAT <= r <= 1 + _SQX_FLAT


def _ge(v, t):
    """v >= t with Oracle's NULL semantics (NULL is never >= anything)."""
    return v is not None and v >= t


def _split_block(w, sid, agg, ex, wn, wsx) -> list[str]:
    """06's "Per execution: where the time went" block of one pool row."""
    weeks_back = w.weeks_back
    cur = agg.get(0, {}).get(sid)
    if not w.windows[0].valid or cur is None:
        return ['<div class="sqx" data-sid="' + sid + '" data-sqx="nocur">'
                '<p class="sqd-sub sqd-fn">Where the time went: no Current row for this statement, '
                "nothing to split.</p></div>"]
    xc = {i: (cur[k] or 0) for i, k in _SQX_KEY.items()}
    xp = {i: 0.0 for i in range(1, 11)}
    for k in range(1, weeks_back + 1):
        r = agg.get(k, {}).get(sid)
        if r is not None:
            for i, key in _SQX_KEY.items():
                xp[i] += r[key] or 0
    xc[7] = max(0.0, xc[1] - xc[2] - xc[3] - xc[4] - xc[5] - xc[6])
    xp[7] = max(0.0, xp[1] - xp[2] - xp[3] - xp[4] - xp[5] - xp[6])
    wx = ex[0]
    mode = "tot" if not wx or wx <= 0 else "new" if wn == 0 else "noprx" if wsx <= 0 else "pe"
    xcv, xmv = {}, {}
    for i in range(1, 11):
        div = 1e6 if i <= 7 else 1
        xcv[i] = (xc[i] if mode == "tot" else xc[i] / wx) / div
        if mode == "pe":
            xmv[i] = xp[i] / wsx / div
        elif mode == "tot" and wn > 0:
            xmv[i] = xp[i] / wn / div
        else:
            xmv[i] = None
    xcv[11] = xcv[9] / xcv[8] if xcv[8] > 0 else None
    xmv[11] = xmv[9] / xmv[8] if _ge(xmv[8], 0) and xmv[8] > 0 else None
    rise = xcv[1] - xmv[1] if xmv[1] is not None else None

    def share(k):
        if rise is None or rise <= 0 or xmv[k] is None:
            return None
        return (xcv[k] - xmv[k]) / rise

    def ratio(k):
        c, m = xcv[k], xmv[k]
        return c / m if (c is not None and m is not None and m != 0) else None

    big = None
    if rise is not None and rise > 0:
        for i in range(2, 8):
            if big is None or share(i) > share(big):
                big = i
    rule, rd = None, None
    if mode == "pe" and _ge(xmv[1], 0) and xmv[1] > 0:
        re_ = xcv[1] / xmv[1]
        rr, gr, dr, pr = ratio(8), ratio(9), ratio(10), ratio(11)
        rf = _sqx_flat(rr) or (xcv[8] == 0 and xmv[8] == 0)
        s2, s3 = share(2), share(3)
        if re_ >= _SQX_GATE:
            if _ge(gr, _SQX_UP) and rf and (s2 or 0) + (s3 or 0) >= _SQX_PART:
                rule = "harder"
                rd = ("each run read " + _sqx_x(gr) + " the buffer gets for about the same rows ("
                      + ("none either side" if rr is None else _sqx_x(rr))
                      + "), and " + ("I/O wait" if s3 >= s2 else "CPU")
                      + " carries " + _sqx_pct(max(s2, s3))
                      + " of the per-run rise: it works harder for the same result, which usually points at "
                        "the plan or the access path.")
            elif _ge(rr, _SQX_UP) and _sqx_flat(pr):
                rule = "data"
                rd = ("rows per run rose " + _sqx_x(rr) + " and buffer gets per run " + _sqx_x(gr)
                      + ", so the gets per row held: more data per call (more volume, or a wider predicate) "
                        "rather than a worse plan, usually.")
            elif _ge(share(5), _SQX_PART):
                rule = "ap"
                rd = ("application wait carries " + _sqx_pct(share(5))
                      + " of the per-run rise: that is row-lock waits, usually, so it points at sessions "
                        "blocking this one (the Blocking view names them) rather than at the statement itself.")
            elif _ge(share(4), _SQX_PART):
                rule = "cc"
                rd = ("concurrency wait carries " + _sqx_pct(share(4))
                      + " of the per-run rise: it points at contention (latches, mutexes, buffer busy waits) "
                        "rather than at the plan.")
            elif _ge(share(6), _SQX_PART):
                rule = "cl"
                rd = ("cluster wait carries " + _sqx_pct(share(6))
                      + " of the per-run rise: it points at global cache transfers between RAC instances.")
            elif _ge(s3, _SQX_PART) and _sqx_flat(gr) and rf and _sqx_flat(dr):
                rule = "slowio"
                rd = ("I/O wait carries " + _sqx_pct(s3)
                      + " of the per-run rise while gets, rows and physical reads per run held: each read got "
                        "slower, which usually points at storage rather than at the statement.")
            elif _ge(s3, _SQX_PART) and _sqx_flat(gr) and _ge(dr, _SQX_UP):
                rule = "cold"
                rd = ("I/O wait carries " + _sqx_pct(s3)
                      + " of the per-run rise and physical reads per run rose " + _sqx_x(dr)
                      + " on about the same gets: more of its blocks came from disk (a colder buffer cache, "
                        "usually) rather than a worse plan.")
            else:
                rule = "mixed"
                rd = ("no single reading fits: the largest part of the per-run rise is "
                      + _sqx_nm(big, True) + " (" + _sqx_pct(share(big)) + ").")
            rd = "Each run took " + _sqx_x(re_) + " as long as the prior mean; " + rd
        elif xp[1] > 0 and xc[1] >= _SQX_GATE * xp[1] / wn:
            rule = "often"
            rd = (("Each run took about as long as before (" + _sqx_x(re_) + " per run)") if _sqx_flat(re_)
                  else ("Per run " + _sqx_x(re_) + ", under the " + _sqx_x(_SQX_GATE)
                        + " line for a per-run reading"))
            rd += ("; the total rose " + _sqx_x(xc[1] / (xp[1] / wn))
                   + " because it ran " + _sqx_x(wx / (wsx / wn)) + " as often.")

    sub = {"pe": "The Current window per execution against the prior mean per execution (the prior windows "
                 "with a row above: their totals over their executions).",
           "tot": "No execution completed in the Current window (a long-running call), so these are window "
                  "TOTALS: Current against the prior mean per window.",
           "new": "The Current window per execution; no prior window has a row for this statement (new)."}.get(
        mode, "The Current window per execution; no execution completed in the prior windows with a row, "
              "so there is no prior value per execution.")
    out = ['<div class="sqx" data-sid="' + sid + '" data-sqx="' + mode
           + '" data-cx="' + _sqx_tok(wx) + '" data-px="' + _sqx_tok(wsx) + '" data-pn="' + str(wn)
           + '" data-rule="' + (rule or "") + '">'
           '<h4 class="sqd-h">Per execution: where the time went</h4>'
           '<p class="sqd-sub">' + sub + " Ranked evidence, not scored.</p>"
           '<div class="sqd-tw"><table class="sqx-tbl" data-nosort data-nocount data-notools><thead><tr>'
           '<th title="CPU and the four waits are separate timers of DBA_HIST_SQLSTAT: they can overlap or '
           "leave a remainder, and include the time of parallel execution servers. Other = elapsed beyond "
           'the five, never below 0.">'
           + ("Window total" if mode == "tot" else "Per execution") + "</th>"
           '<th class="num">Current</th><th class="num">Prior mean</th><th class="num">Change</th>'
           '<th class="num" title="The part&#39;s change over the change of elapsed: its share of the rise. '
           'The parts are separate timers, so the shares need not add up to 100%.">Share of the rise</th>'
           "</tr></thead><tbody>"]
    for i in range(1, 12):
        cls = "sqx-e" if i == 1 else "sqx-p" if i <= 7 else "sqx-w sqx-w1" if i == 8 else "sqx-w"
        row = ('<tr class="' + cls + '" data-k="' + str(i) + '"'
               + ((' data-xc="' + _sqx_tok(xc[i]) + '" data-xp="' + _sqx_tok(xp[i]) + '"') if i <= 10 else "")
               + "><td>" + _sqx_nm(i) + "</td>"
               '<td class="num">' + fmt_num(xcv[i]) + "</td>"
               '<td class="num">' + ('<span class="sqd-mu">&mdash;</span>' if xmv[i] is None else fmt_num(xmv[i]))
               + "</td>"
               '<td class="num">'
               + (_sqd_chg(xcv[i], xmv[i], wn, _sqx_nm(i)) if mode in ("pe", "tot", "new") and xcv[i] is not None
                  else "")
               + '</td><td class="num">' + (_sqx_pct(share(i)) if 2 <= i <= 7 else "")
               + "</td></tr>")
        out.append(row)
    out.append("</tbody></table></div>"
               + (('<p class="sqx-rd" data-rule="' + rule + '"><b>Reads as:</b> ' + rd + "</p>") if rd else "")
               + "</div>")
    return out


def _plan_points(pts, phv_count):
    """Chart payload of one statement: None (no point), else (t0, point
    lines, comma list of the quoted plan hashes).  Compact form
    {t0, p:[[minutes since t0, plan index, executions, s/exec or null]],
    phv:[...]}, one point per (snapshot, plan), oldest first; plan "0" = a
    statement without a plan hash (kept only when it has no other plan)."""
    keep = [p for p in pts if p[4] > 0 or phv_count == 0]
    if not keep:
        return None
    t0 = min(p[0].end_ts.replace(second=0, microsecond=0) for p in keep)
    pidx, plist, lines = {}, [], []
    for s, ex, ela, gets, phv in sorted(keep, key=lambda p: (p[0].end_ts, p[4])):
        key = str(int(phv or 0))
        if key not in pidx:
            if len(plist) >= 1500:
                continue
            pidx[key] = len(plist)
            plist.append('"' + key + '"')
        mins = int(ora_round((s.end_ts.replace(second=0, microsecond=0) - t0).total_seconds() / 60, 0))
        val = ("null" if not ex > 0
               else h.to_char_trim(ora_round(min(ela / ex / 1e6, 99999999), 6), 6))
        lines.append(("[" if not lines else ",[")
                     + str(mins) + "," + str(pidx[key]) + "," + str(int(ex)) + "," + val + "]")
    return ts_min(t0), lines, ",".join(plist)

# ---------------------------------------------------------------------
# emitter
# ---------------------------------------------------------------------

def emit(w) -> str:
    o = []
    put = o.append
    L = _lines()
    top_n = w.top_n
    weeks_back = w.weeks_back
    nweeks = weeks_back + 1

    put("<!-- AWR-SECTION: 06_top_sql BEGIN -->")
    put('<section id="topsql" class="vw in-s in-a lib lopen" style="--os:1"><h2>Top SQL'
        '<small class="h2sub">Top ' + str(top_n)
        + ' statements per ranking and window; ranked, not scored</small></h2>')
    # Values: Total | Per execution | Top per execution -- the shared state,
    # set before the panels are parsed (lifted from the SQL)
    block, _ = _slice(L, "<script>(function(){ /* Top SQL: Values switch (Total | Per execution | Top per execution) */",
                      "})();</script>")
    o.extend(block)
    put('<div class="tabs" data-tabs="topsql" role="tablist" aria-label="Top SQL ranking dimension">'
        '<button type="button" role="tab" aria-selected="true" class="on" data-t="CHANGE" id="tab-topsql-CHANGE"'
        ' title="Current window total elapsed minus the prior-window mean">Biggest change</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="ELAPSED" id="tab-topsql-ELAPSED">Elapsed time</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="CPU" id="tab-topsql-CPU">CPU time</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="GETS" id="tab-topsql-GETS">Buffer gets</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PREADS" id="tab-topsql-PREADS">Physical reads</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="EXEC" id="tab-topsql-EXEC">Executions</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PEREXEC" id="tab-topsql-PEREXEC">Per-exec regression</button>'
        "</div>")

    # weeks / weeksIso JSON (week_offset DESC = oldest first)
    step_days = w.step_hours / 24
    wdates = [w.target_end - timedelta(days=step_days * k) for k in range(weeks_back, -1, -1)]
    weeks_json = "[" + ",".join('"' + mon_dd(d) + '"' for d in wdates) + "]"
    weeks_iso_json = "[" + ",".join('"' + ts_min(d) + '"' for d in wdates) + "]"

    agg = _agg(w)
    picked, chg_mu = _picked(w, agg)
    rows = _per_sql(w, picked)

    dim_label, dim_unit, dim_div = {}, {}, {}
    for code, _, label, unit, div in _DIMS:
        dim_label[code], dim_unit[code], dim_div[code] = label, unit, div
    seen_sqls = {}
    flip_sqls = {}
    sys_sqls = {}
    sql_dim_seen, sql_dim_top3 = {}, {}
    sql_elapsed_cur = {}
    dim_sqls_json, dim_sqls_kept, dim_sqls_total, dim_seen = {}, {}, {}, []
    dim_sqls_swap = {}

    cur_dim = None
    tl_rows = []
    ls = None
    news = ""                       # plan 040: the statement the row text is about
    panel_on = False

    def close_dim(nxt):
        """tsv_close(): the table / details of cur_dim, its view (or, for
        Biggest change / Executions / Per-exec regression, its panel); a
        total ranking of the four metric tabs not followed by its own
        per-execution ranking gets the empty Top per execution view, and that
        view ends the panel.  Right after a total view the swap is applied to
        its table (AWR_topsqlSync(table))."""
        if cur_dim is None:
            return
        put("</tbody></table></details></div>")
        if cur_dim in _PE_OF:
            put('<script>if(window.AWR_topsqlSync)AWR_topsqlSync(document.getElementById("topsql-detail-'
                + cur_dim + '"));</script>')
            if nxt is None or nxt != cur_dim + "_PE":
                put(_tsv_empty_view(dim_label[cur_dim]) + "</div>")
        elif cur_dim in _TOTAL_OF:
            put("</div>")

    for s in rows:
        dim = s["dim"]
        if cur_dim != dim:
            close_dim(dim)
            is_rank = dim in _TOTAL_OF
            # only the four TOTAL metric dims carry the swap (never a *_PE
            # dimension, CHANGE, EXEC or PEREXEC)
            swap_dim = dim in _SWAP_UNIT
            cur_dim = dim
            dim_seen.append(dim)
            dim_sqls_json[dim] = None
            dim_sqls_kept[dim] = 0
            dim_sqls_total[dim] = 0
            if swap_dim:
                dim_sqls_swap[dim] = None
            if not is_rank:
                # the first emitted tabpanel is the open one
                put('<div class="tabpanel' + ("" if panel_on else " on")
                    + '" data-tabs="topsql" data-t="' + dim + '" role="tabpanel"'
                    + ' aria-labelledby="tab-topsql-' + dim + '">')
                panel_on = True
                # Values: Total | Per execution | Top per execution in every
                # panel, its buttons painted by the script after it
                put(_tsv_switch(dim))
                put("<script>if(window.AWR_topsqlSync)AWR_topsqlSync();</script>")
                if swap_dim:
                    put('<div class="tsv-view" data-val="total">')
                else:
                    put(_tsv_note(dim))
            else:
                put('<div class="tsv-view" data-val="pe-rank">')
            put("<h3>" + dim_label[dim] + "</h3>")
            if is_rank:
                put('<p class="tsv-rank-note">Top per execution: a different statement set from the Total view.'
                    " Each window's top " + str(top_n)
                    + " statements by value per completed execution (the window's value divided by its"
                    " executions), ranked on their own. A statement with no completed execution in a window is"
                    " not ranked in it; a dash means it is not in that window's top " + str(top_n) + ".</p>")
            elif swap_dim:
                # shown by CSS in mode perexec only (the swap)
                put('<p class="tsv-swap-note">Per execution: the same statements, still picked and ordered by the'
                    " window total (the #n badges are ranks by total). Each value is that window's total divided"
                    " by its executions; a dash is a window where the statement is not in the top " + str(top_n)
                    + " or completed no execution.</p>")
            put('<div class="topsql-toggle" data-topsql-target="' + dim + '">'
                "<span>Break down by:</span>"
                '<button type="button" data-mode="sqls" class="active">SQL ID</button>'
                '<button type="button" data-mode="schemas">Schema</button>'
                '<button type="button" data-mode="modules">Module</button>'
                '<button type="button" data-mode="actions">Action</button>'
                "</div>")
            put('<div class="chart-wrap chart-medium" id="topsql-chart-' + dim + '"></div>')
            put("<details>")
            put("<summary>Detail table</summary>")
            # one th per window through wg_buf (h.wg_lines)
            # a Top per execution table is a second view of its tab (plan
            # badges stay out of the section-header counts); a total metric
            # table carries the swap (class tsv-tbl)
            header = ['<table id="topsql-detail-' + cur_dim + '"'
                      + (' data-nocount' if is_rank else (' class="tsv-tbl"' if swap_dim else '')) + '>'
                      '<thead><tr><th>SQL ID</th><th class="num" title="plan_hash_value of the Current window&#39;s execution plan">Plan hash (Current)</th>'
                      '<th class="num" data-w="0"'
                      + (' data-pe="Current (' + _SWAP_UNIT[dim] + ')"' if swap_dim else "")
                      + '>Current (' + dim_unit[dim] + ")</th>"]
            for k in range(1, weeks_back + 1):
                header.append('<th class="num" data-w="' + str(k) + '">&minus;'
                              + w.offset_labels[k - 1] + "</th>")
            header.append("<th>SQL</th></tr></thead><tbody>")
            put(h.wg_lines(header))

        sid = s["sql_id"]
        div = dim_div[dim]
        seen_sqls[sid] = True
        if dim in _RANK_DIMS or dim in _TOTAL_OF:
            sql_dim_seen[sid + "|" + dim] = "Y"
            if s["cur_rnk"] is not None and s["cur_rnk"] <= 3:
                sql_dim_top3[sid + "|" + dim] = "Y"
        if dim == "ELAPSED":
            sql_elapsed_cur[sid] = s["cur_val"] if s["cur_val"] is not None else 0

        schema = w.sql_by_id[sid].schema
        is_sys = is_oracle_schema(schema)
        sys_sqls[sid] = (is_sys == "Y")

        plan_flip = False
        cur_phv = s["cur_phv"]
        if cur_phv is not None:
            for k in range(1, weeks_back + 1):
                p = s["phvs"][k]
                if p is not None and p != cur_phv:
                    plan_flip = True
                    break
        if plan_flip:
            flip_sqls[sid] = True

        new_entry = ('{"sql_id":"' + sid + '","cur":'
                     + ("null" if s["cur_rnk"] is None else str(s["cur_rnk"]))
                     + ',"sys":' + ("true" if is_sys == "Y" else "false")
                     + ',"vals":[' + _series(dim, s["vals"], div) + "]}")
        # executions of the statement in each window (agg join; None = AWR kept no row)
        execs = [agg.get(k, {}).get(sid, {}).get("execs") for k in range(nweeks)]
        new_swap = "[" + _chart_swap(s["vals"], execs, div) + "]" if swap_dim else None
        dim_sqls_total[dim] += 1
        # one keep decision for the entry and its per-execution twin
        if dim_sqls_json[dim] is None:
            keep = True
        else:
            keep = len(dim_sqls_json[dim]) + len(new_entry) + 1 <= _JSON_CAP
            if keep and swap_dim:
                keep = len(dim_sqls_swap[dim]) + len(new_swap) + 1 <= _JSON_CAP
        if keep:
            if dim_sqls_json[dim] is None:
                dim_sqls_json[dim] = new_entry
                if swap_dim:
                    dim_sqls_swap[dim] = new_swap
            else:
                dim_sqls_json[dim] += "," + new_entry
                if swap_dim:
                    dim_sqls_swap[dim] += "," + new_swap
            dim_sqls_kept[dim] += 1

        cur_val = s["cur_val"]
        cur_scaled = None if cur_val is None else cur_val / div
        row = ('<tr id="' + anchor_id('sq-' + dim.lower().replace("_", ""), sid) + '" data-sys="' + is_sys + '">'
               '<td class="mono"><a href="#sql-' + sid + '">' + sid + "</a>"
               + (' <span class="badge warn" title="Plan changed between current and a prior '
                  'compared window">plan&#8593;</span>' if plan_flip else "")
               + "</td>"
               '<td class="num mono">' + ("&mdash;" if cur_phv is None else str(cur_phv)) + "</td>"
               '<td class="num" data-w="0"' + fmt_num_title(cur_scaled) + "><b>"
               + (_tsv_span(fmt_num(cur_scaled), _pe_val(cur_scaled, execs[0]), "Y")
                  if swap_dim and cur_val is not None else fmt_num(cur_scaled))
               + (' <span class="badge info">#' + str(s["cur_rnk"]) + "</span>"
                  if s["cur_rnk"] is not None else "")
               + "</b>")
        if dim == "CHANGE":
            mu, n_prior = chg_mu.get(sid, (None, 0))
            if not n_prior:
                row += ' <span class="d s-plain" title="no row in any prior valid window">new</span>'
            elif not mu:
                row += ' <span class="d s-plain" title="0 s elapsed in every prior valid window">from 0</span>'
            else:
                row += " " + h.delta_span(cur_val, mu, None, "Y")
        row += "</td>"
        # the prior windows' cells, one wg_buf piece each (h.wg_lines)
        parts = [row]
        for k in range(1, weeks_back + 1):
            v, r, p = s["vals"][k], s["rnks"][k], s["phvs"][k]
            if v is None:
                cell = '<td class="num" data-w="' + str(k) + '">&mdash;'
            else:
                cell = ('<td class="num" data-w="' + str(k) + '">'
                        + (_tsv_span(fmt_num(v / div), _pe_val(v / div, execs[k]), "N")
                           if swap_dim else fmt_num(v / div)))
            if r is not None:
                cell += ' <span class="badge skip">#' + str(r) + "</span>"
            if p is not None and cur_phv is not None and p != cur_phv:
                cell += (' <span class="badge warn" title="Plan changed. Prior PHV '
                         + str(p) + '">plan&#8593;</span>')
            parts.append(cell + "</td>")
        text_short = (w.sql_by_id[sid].text or "")[:401]
        parts.append('<td class="mono sqltext">' + esc(text_short[:400])
                     + ("&hellip;" if len(text_short) > 400 else "") + "</td></tr>")
        put(h.wg_lines(parts))
        # v1.6.0 Timeline: the SQL lane (first six of the elapsed ranking)
        if dim == "ELAPSED" and len(tl_rows) < 6:
            csv = h.tl_csv(w, _chart_vals(s["vals"], div))
            mu = h.tl_mu(w, csv)
            first = h.tl_first(w, csv)
            gw = gl = None
            note = ("#" + str(s["cur_rnk"]) + " by elapsed" if s["cur_rnk"] is not None
                    else "not in the Current top " + str(top_n))
            if plan_flip:
                gw = 0
                gl = ('<b class="glf gp" title="Plan changed: the Current plan_hash_value '
                      + str(cur_phv) + ' differs from a prior window\'s">&#9670;</b>')
                note = "<b>&#9670;</b> new plan"
            elif first is not None:
                gw = first
                gl = ('<b class="glf gn" title="First seen in the top ' + str(top_n) + ': '
                      + h.wg_title(w, first) + '">&#10010;</b>')
                note = "<b>&#10010;</b> new " + ("in Current" if first == 0 else h.wg_date(w, first))
            txt = w.sql_by_id[sid].text or ""
            if not tl_rows:
                if s["cur_rnk"] is None:
                    ls = "no statement in the Current top " + str(top_n)
                else:
                    news = "sql:" + sid
                    ls = ("<code>" + sid + "</code> #" + str(s["cur_rnk"]) + " by elapsed"
                          + ((", " + h.delta_span(h.tl_val(w, csv, 0), mu, None, "Y")) if mu is not None else "")
                          + (", new plan" if plan_flip else
                             (", new " + ("in Current" if first == 0 else h.wg_date(w, first)))
                             if first is not None else ""))
            tl_rows.append(h.tl_bars(
                w, csv, mu, None, None,
                h.tl_lab(h.ent(sid, anchor_id("sq-elapsed", sid), "sql"),
                         esc(schema or "?") + ' <span class="sq">' + esc(txt[:90]) + "</span>",
                         esc(txt[:300])),
                h.tl_gutp(h.tl_val(w, csv, 0), mu, note),
                "tl-" + anchor_id("sq-elapsed", sid), "q", sid, "s elapsed", gw, gl))
    # the last dimension's table, view and panel
    close_dim(None)
    if "CHANGE" not in dim_seen:
        # no statement got slower (or no prior valid window): the script
        # that drops the empty tab, lifted from the SQL
        put(next(t for t, _ in L
                 if t.startswith('<script>(function(){var c=document.getElementById("tab-topsql-CHANGE")')))
    if panel_on:
        # a note's link to a tab or panel this report does not have is plain text
        block, _ = _slice(L, "<script>(function(){ /* Top SQL: notes link only to tabs that exist */",
                          "})();</script>")
        o.extend(block)
    for i, r in enumerate(tl_rows, start=1):
        put((h.tl_open("sql") if i == 1 else "") + r + (h.tl_close() if i == len(tl_rows) else ""))

    # second pass: group breakdowns -----------------------------------
    grp_json, grp_kept, grp_total = {}, {}, {}
    grp_swap = {}
    for sc in _group_rows(w, agg):
        gv = sc["grp_value"]
        swap_dim = sc["dim"] in _SWAP_UNIT
        new_entry = ('{"name":"' + json_escape(gv)
                     + '","cur":' + ("null" if sc["cur_rnk"] is None else str(sc["cur_rnk"]))
                     + ',"sys":' + ("true" if sc["grp_type"] == "schema"
                                    and is_oracle_schema(gv) == "Y" else "false")
                     + ',"vals":[' + _series(sc["dim"], sc["vals"], dim_div[sc["dim"]]) + "]}")
        gkey = sc["dim"] + "|" + sc["grp_type"]
        if gkey not in grp_total:
            grp_total[gkey] = 0
            grp_kept[gkey] = 0
        grp_total[gkey] += 1
        # one keep decision for the entry and its per-execution twin
        new_swap = ("[" + _chart_swap(sc["vals"], sc["execs"], dim_div[sc["dim"]]) + "]"
                    if swap_dim else None)
        if grp_json.get(gkey) is None:
            keep = True
        else:
            keep = len(grp_json[gkey]) + len(new_entry) + 1 <= _JSON_CAP
            if keep and swap_dim:
                keep = len(grp_swap[gkey]) + len(new_swap) + 1 <= _JSON_CAP
        if keep:
            if grp_json.get(gkey) is None:
                grp_json[gkey] = new_entry
                if swap_dim:
                    grp_swap[gkey] = new_swap
            else:
                grp_json[gkey] += "," + new_entry
                if swap_dim:
                    grp_swap[gkey] += "," + new_swap
            grp_kept[gkey] += 1

    # AWR_DATA.topSql + bump-chart script ------------------------------
    if dim_seen:
        put("<script>(function(){")
        put(h.wg_lines(["AWR_DATA.topSql={weeks:", weeks_json, ",weeksIso:", weeks_iso_json,
                        ",topN:" + str(top_n) + ",dims:{"]))
        # PL/SQL INDEX BY VARCHAR2 iterates in key order
        for i, dim in enumerate(sorted(dim_seen)):
            if i:
                put(",")

            def cnt(tab, key):
                return str(tab[key]) if key in tab else "0"
            put('"' + dim + '":{"label":"' + dim_label[dim]
                + '","unit":"' + dim_unit[dim]
                + '","sqlsKept":' + str(dim_sqls_kept[dim])
                + ',"sqlsTotal":' + str(dim_sqls_total[dim])
                + ',"schemasKept":' + cnt(grp_kept, dim + "|schema")
                + ',"schemasTotal":' + cnt(grp_total, dim + "|schema")
                + ',"modulesKept":' + cnt(grp_kept, dim + "|module")
                + ',"modulesTotal":' + cnt(grp_total, dim + "|module")
                + ',"actionsKept":' + cnt(grp_kept, dim + "|action")
                + ',"actionsTotal":' + cnt(grp_total, dim + "|action")
                + (',"unitPe":"' + _SWAP_UNIT[dim] + '"' if dim in _SWAP_UNIT else "")
                + ",")
            sw = dim in _SWAP_UNIT
            put('"sqls":[' + (dim_sqls_json[dim] or "") + "],")
            if sw:
                put('"sqlsPe":[' + (dim_sqls_swap.get(dim) or "") + "],")
            put('"schemas":[' + (grp_json.get(dim + "|schema") or "") + "],")
            if sw:
                put('"schemasPe":[' + (grp_swap.get(dim + "|schema") or "") + "],")
            put('"modules":[' + (grp_json.get(dim + "|module") or "") + "],")
            if sw:
                put('"modulesPe":[' + (grp_swap.get(dim + "|module") or "") + "],")
            put('"actions":[' + (grp_json.get(dim + "|action") or "") + ("]," if sw else "]}"))
            if sw:
                put('"actionsPe":[' + (grp_swap.get(dim + "|action") or "") + "]}")
        block, pos = _slice(L, "}};", "})();</script>")
        o.extend(block)

    # cross-dim plan-change rollup --------------------------------------
    if seen_sqls:
        if flip_sqls:
            put('<p style="margin-top:18px">'
                '<span class="badge warn">plan&#8593;</span> '
                + str(len(flip_sqls)) + " of " + str(len(seen_sqls))
                + " top SQL had a plan_hash_value change between current and a prior "
                'compared window. Look for the <span class="badge warn">plan&#8593;</span> '
                "badges in the SQL ID column and the per-window cells above.</p>")
        else:
            put('<p style="margin-top:18px">'
                '<span class="badge ok">plan stable</span> '
                "No plan_hash_value changes detected for any of the "
                + str(len(seen_sqls)) + " top SQL across the compared windows.</p>")

    # per-SQL detail: pool table ----------------------------------------
    block, pos = _slice(L, '<h3 class="vw in-a">Per-SQL detail</h3>',
                        '<table id="sql-pool" class="vw in-a">', last_prefix=True)
    o.extend(block)

    order = sorted(seen_sqls.keys(),
                   key=lambda sid: (-(sql_elapsed_cur.get(sid, 0)), sid))
    for idx, sid in enumerate(order, start=1):
        d = w.sql_by_id[sid]
        pts = _retention(w, sid)
        if pts:
            first_seen = ts_min(min(p[0].begin_ts for p in pts))
            last_seen = ts_min(max(p[0].end_ts for p in pts))
            phv_count = len({p[4] for p in pts if p[4] != 0})
            total_exec = sum(p[1] for p in pts)
            total_snap = len(pts)
            parsing_schema = d.schema or None
            last_module = d.module or None
            last_action = d.action or None
            last_opt_mode = "ALL_ROWS"
            module_distinct = 1 if last_module else 0
            force_sig = w.rng("force_sig", sid).randrange(10 ** 18, 10 ** 19)
            sql_profile = None
        else:
            first_seen = last_seen = None
            phv_count = total_exec = total_snap = 0
            parsing_schema = last_module = last_action = last_opt_mode = None
            module_distinct = 0
            force_sig = sql_profile = None
        text = d.text
        if text is None:
            vlen, snip = 0, "(text not in DBA_HIST_SQLTEXT)"
        else:
            vlen, snip = len(text), text[:8000]

        put('<tr class="sql-row" id="sql-' + sid + '"'
            + ' data-sys="' + ("Y" if sys_sqls.get(sid) else "N") + '"'
            + (' data-tail="Y" hidden' if idx > 8 else "") + ">")
        put('<td class="mono sqlid-cell">'
            '<span id="sqlid-' + sid + '">' + sid + "</span> "
            '<button type="button" class="copy-btn" '
            'data-copy="#sqlid-' + sid + '">&#10687;</button>'
            '<span class="xlinks">'
            '<a class="xlink" href="#ash-card-' + sid
            + '" title="ASH breakdown of this SQL" onclick="event.stopPropagation()">ASH</a>'
            '<a class="xlink" href="#sm-' + sid
            + '" title="SQL Monitor row for this SQL" onclick="event.stopPropagation()">MON</a>'
            "</span>"
            "</td>")
        chips = ""
        for letter, dim in (("E", "ELAPSED"), ("C", "CPU"), ("G", "GETS"),
                            ("R", "PREADS"), ("X", "EXEC")):
            key = sid + "|" + dim
            if key in sql_dim_seen:
                chips += ('<span class="chip' + (" on" if key in sql_dim_top3 else "")
                          + '" title="' + dim + '">' + letter + "</span>")
        # P: the one chip of the four per-execution rankings (names them in the
        # tooltip, solid when in a Current top 3 of any of them)
        pe_names, pe_on = [], False
        for metric, dim in (("elapsed", "ELAPSED_PE"), ("CPU", "CPU_PE"),
                            ("gets", "GETS_PE"), ("reads", "PREADS_PE")):
            key = sid + "|" + dim
            if key in sql_dim_seen:
                pe_names.append(metric)
                if key in sql_dim_top3:
                    pe_on = True
        if pe_names:
            chips += ('<span class="chip' + (" on" if pe_on else "")
                      + '" title="in a per-execution ranking: ' + ", ".join(pe_names) + '">P</span>')
        put("<td>" + chips + "</td>")
        put('<td class="mono">'
            + ("&mdash;" if parsing_schema is None else esc(parsing_schema))
            + "</td>"
            '<td class="num">' + str(phv_count or 0)
            + (' <span class="badge warn">plan flip</span>' if (phv_count or 0) > 2 else "")
            + "</td>"
            '<td class="num">' + fmt_int(total_exec or 0) + "</td>"
            '<td class="num">' + fmt_int(total_snap or 0) + "</td>"
            "<td>" + (first_seen if first_seen is not None else "?") + "</td>"
            '<td class="mono sqltext">' + esc((snip or "")[:90])
            + ("&hellip;" if len(snip or "") > 90 else "") + "</td>")
        put("</tr>")

        put('<tr class="sql-detail" data-sql="' + sid + '" hidden><td colspan="8">')
        dash = '<span class="muted">&mdash;</span>'
        put('<dl class="sql-meta">'
            '<dt>Parsing schema</dt><dd class="mono">'
            + (dash if parsing_schema is None else esc(parsing_schema)) + "</dd>"
            "<dt>Module</dt><dd>"
            + (dash if last_module is None else esc(last_module)
               + (' <span class="muted">(' + str(module_distinct) + " distinct seen)</span>"
                  if module_distinct > 1 else ""))
            + "</dd>"
            "<dt>Action</dt><dd>" + (dash if last_action is None else esc(last_action)) + "</dd>"
            '<dt>Optimizer mode</dt><dd class="mono">'
            + (dash if last_opt_mode is None else esc(last_opt_mode)) + "</dd>"
            '<dt>Force-match sig</dt><dd class="mono">'
            + (dash if not force_sig else str(force_sig)) + "</dd>"
            "<dt>SQL profile</dt><dd>" + (dash if sql_profile is None else esc(sql_profile)) + "</dd>"
            "<dt>Text length</dt><dd>"
            + (dash if not vlen else to_char_fixed(vlen, 0, group=True) + " chars") + "</dd>"
            "</dl>")

        # Compared windows: the statement in every compared window, from the
        # agg numbers (no further read)
        o.extend(_windows_table(w, sid, agg))

        # Per-plan summary + chart over the whole AWR retention; any statement
        # with a SQLSTAT row.  One with no non-zero plan shows its plan-0 rows
        # as a single "no plan" plan.
        if (total_snap or 0) > 0:
            put('<h4 class="sqd-h">Whole AWR retention, by plan</h4>'
                '<p class="sqd-sub">Every snapshot AWR still holds for this statement; '
                "the compared windows are marked in the chart.</p>")
            put('<table id="phv-summary-' + sid + '"><thead><tr>'
                '<th class="num" title="plan_hash_value">Plan hash</th>'
                "<th>First seen</th><th>Last seen</th>"
                '<th class="num">Snapshots</th>'
                '<th class="num">Executions</th>'
                '<th class="num">Avg s/exec</th>'
                '<th class="num">Avg gets/exec</th>'
                "</tr></thead><tbody>")
            byphv = {}
            for s, ex, ela, gets, phv in pts:
                if phv > 0 or phv_count == 0:
                    b = byphv.setdefault(phv, {"first": s.begin_ts, "last": s.end_ts,
                                               "snaps": 0, "execs": 0, "ela": 0, "gets": 0})
                    b["first"] = min(b["first"], s.begin_ts)
                    b["last"] = max(b["last"], s.end_ts)
                    b["snaps"] += 1
                    b["execs"] += ex
                    b["ela"] += ela
                    b["gets"] += gets
            for phv, b in sorted(byphv.items(), key=lambda kv: kv[1]["first"]):
                put("<tr>"
                    '<td class="num mono">'
                    + (str(phv) if phv else
                       '<span class="sqd-mu" title="No plan hash: a PL/SQL call, or another statement '
                       'without an execution plan">no plan</span>')
                    + "</td>"
                    "<td>" + ts_min(b["first"]) + "</td>"
                    "<td>" + ts_min(b["last"]) + "</td>"
                    '<td class="num">' + fmt_int(b["snaps"]) + "</td>"
                    '<td class="num">' + fmt_int(b["execs"]) + "</td>"
                    '<td class="num">'
                    + (fmt_num(b["ela"] / b["execs"] / 1e6) if b["execs"] > 0 else "&mdash;")
                    + "</td>"
                    '<td class="num">'
                    + (fmt_num(b["gets"] / b["execs"]) if b["execs"] > 0 else "&mdash;")
                    + "</td>"
                    "</tr>")
            put("</tbody></table>")
            put('<div class="chart-wrap chart-medium" id="sqltl-' + sid + '"></div>')
            pp = _plan_points(pts, phv_count)
            if pp is not None:
                t0s, plines, plist = pp
                put('<script>AWR_DATA.sqlDetails["' + sid + '"]={t0:"' + t0s + '",p:[')
                for ln in plines:
                    put(ln)
                put("],phv:[" + plist + "]};</script>")

        put('<pre class="sql">' + esc(snip)
            + ("\n... (truncated, " + str(vlen) + " chars total)" if vlen > 8000 else "")
            + "</pre>")
        put("</td></tr>")
    put("</tbody></table>")
    if len(seen_sqls) > 8:
        n_more = len(seen_sqls) - 8
        put('<span class="expander" data-for="sql-pool" data-n="' + str(n_more)
            + '" data-noun="more statements">'
            "&#9656; Show " + str(n_more) + " more statements</span>")

    # per-SQL timeline init, sql-pool row toggle, hash navigation --------
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # timeline init
    o.extend(block)
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # row toggle
    o.extend(block)
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # hash nav
    o.extend(block)

    put(h.lib_ls("topsql", ls or "no SQL captured in the compared windows")
        + h.lib_news("topsql", news) + "</section>")
    put("<!-- AWR-SECTION: 06_top_sql END -->")
    return "\n".join(o)
