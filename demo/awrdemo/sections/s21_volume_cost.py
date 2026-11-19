"""Twin of sql/21_volume_cost.sql (Volume vs unit cost): each statement /
foreground wait event of the Current window placed on a log-log plane of
(executions vs its normal) x (time per execution vs its normal), the
"Reads as:" sentences, the "new in Current" strips, the AWR_DATA.volcost
payload and the two tables.

Data: per VALID window `w.window_metrics(win).sql` (DBA_HIST_SQLSTAT
*_DELTA sums, rounded to whole numbers the way AWR stores them, as s06 does)
and `.fg_waits` (DBA_HIST_SYSTEM_EVENT; the model's waits are foreground
only, so the all-session ranking that picks 04's event set and the
foreground measures read the same numbers).  Nothing is derived locally.
"""
from __future__ import annotations

import math

from awrdemo import chrome
from awrdemo import helpers as h
from awrdemo.helpers import anchor_id, anchor_uniq, ent, esc, fmt_int, fmt_num, fmt_num_title, json_escape
from awrdemo.sections import _waits as C

THR = 1.5
FLOOR = 0.02


def _ival(x: float) -> float:
    return h.ora_round(x, 0)


def _avg(vals):
    vals = [v for v in vals if v is not None]
    return math.fsum(vals) / len(vals) if vals else None


def _pp(counts, times):
    """normal per run (ms) = AVG(time) / NULLIF(AVG(count), 0) / 1e3"""
    a, c = _avg(times), _avg(counts)
    if a is None or not c:
        return None
    return a / c / 1e3


def rx(p) -> str:
    if p is None:
        return "&mdash;"
    if p < 0.005:
        return "&times;&lt;0.01"
    if p >= 9.95:
        t = h.to_char_fixed(h.ora_round(p, 0), 0, group=True)
    elif p >= 0.095:
        t = h.to_char_fixed(p, 1)
    else:
        t = h.to_char_fixed(p, 2)
    return "&times;" + t


def jn(p) -> str:
    if p is None:
        return "null"
    return h.to_char_trim(h.ora_round(p, 6), 6)


def ratio(a, b):
    if a is None or b is None or b <= 0 or a < 0:
        return None
    return a / b


def state_of(r) -> str:
    if (r["ec"] or 0) <= 0 or (r["pc"] or 0) <= 0 or (r["tc"] or 0) <= 0:
        return "Z"
    if (r["nseen"] or 0) == 0:
        return "N"
    if (r["nrun"] or 0) == 0 or (r["ep"] or 0) <= 0 or (r["pp"] or 0) <= 0 or (r["tp"] or 0) <= 0:
        return "B"
    return "P"


def cost_of(r) -> str:
    t = ratio(r["tc"], r["tp"])
    if t is not None and t >= THR:
        return "u"
    if t is not None and t <= 1 / THR:
        return "d"
    return "e"


def cat_of(r) -> str:
    x = ratio(r["ec"], r["ep"])
    y = ratio(r["pc"], r["pp"])
    if x is not None and y is not None and x >= THR and y < THR:
        return "m"
    if x is not None and y is not None and y >= THR and x < THR:
        return "s"
    return "b"


def pl(n, one, many) -> str:
    return str(n) + " " + (one if n == 1 else many)


def why_txt(r, kind) -> str:
    st = state_of(r)
    if st == "N":
        return "new in Current"
    if st != "P":
        return "no prior baseline"
    if cost_of(r) == "d":
        return "costs less"
    if cost_of(r) == "e":
        return "about the same"
    c = cat_of(r)
    if c == "m":
        return "runs more often" if kind == "sql" else "more waits"
    if c == "s":
        return "slower per run" if kind == "sql" else "longer waits"
    return "both"


def name_html(r, kind) -> str:
    if kind == "sql":
        return ent(r["nm"], anchor_id("sq-elapsed", r["nm"]), "sql") if r["in_t"] == 1 else r["nm"]
    return ent(esc(r["nm"]), anchor_id("we", r["nm"]), "event")


def _sql_items(w, cap, top_n):
    agg = {}
    for win in w.windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        agg[win.week_offset] = {sid: (_ival(x.execs), _ival(x.elapsed_us)) for sid, x in m.sql.items()}
    ranks = {}
    for off, rows in agg.items():
        order = sorted(rows, key=lambda k: (-rows[k][1], k))
        ranks[off] = {k: i + 1 for i, k in enumerate(order)}
    cur = agg.get(0, {})
    cand = {sid: ranks[0][sid] for sid, (ex, ela) in cur.items() if ela > 0 and ranks[0][sid] <= cap}
    out = []
    for sid in sorted(cand, key=lambda k: (cand[k], k)):
        rows = [(off, agg[off][sid], ranks[off][sid]) for off in sorted(agg) if sid in agg[off]]
        pr = [(ex, ela) for off, (ex, ela), _ in rows if off > 0 and ex > 0]
        ex0, ela0 = cur[sid]
        out.append({
            "nm": sid, "wc": None,
            "in_t": 1 if any(rk <= top_n and ela > 0 for _, (ex, ela), rk in rows) else 0,
            "ec": ex0, "ep": _avg([ex for ex, _ in pr]),
            "pc": ela0 / ex0 / 1e3 if ex0 > 0 else None, "pp": _pp([ex for ex, _ in pr], [ela for _, ela in pr]),
            "tc": ela0 / 1e6, "tp": _avg([ela / 1e6 for _, ela in pr]),
            "nrun": len(pr),
            "nseen": sum(1 for off, (ex, ela), _ in rows if off > 0 and (ex > 0 or ela > 0)),
        })
    return out


def _ev_items(w, top_n):
    deltas = C.window_deltas(w, lambda m: m.fg_waits)
    ev04 = set()
    for d in deltas:
        if not d:
            continue
        pos = {ev: t[2] for ev, t in d.items() if t[2] > 0}
        for ev, rk in C._rank_desc(pos).items():
            if rk <= top_n:
                ev04.add(ev)
    out = []
    for ev in ev04:
        rows = [(k, d[ev]) for k, d in enumerate(deltas) if d is not None and ev in d]
        pr = [(wf, uf) for k, (cls, wf, uf) in rows if k > 0 and wf > 0 and uf > 0]
        cur = [(wf, uf) for k, (cls, wf, uf) in rows if k == 0]
        wf0, uf0 = cur[0] if cur else (None, None)
        out.append({
            "nm": ev, "wc": max(cls for _, (cls, _w, _u) in rows), "in_t": 1,
            "ec": wf0, "ep": _avg([a for a, _ in pr]),
            "pc": uf0 / wf0 / 1e3 if wf0 else None, "pp": _pp([a for a, _ in pr], [b for _, b in pr]),
            "tc": uf0 / 1e6 if uf0 is not None else None, "tp": _avg([b / 1e6 for _, b in pr]),
            "nrun": len(pr),
            "nseen": sum(1 for k, (cls, wf, uf) in rows if k > 0 and (wf > 0 or uf > 0)),
        })
    out.sort(key=lambda r: (r["tc"] is None, -(r["tc"] or 0), r["nm"]))
    return out


def _labels(its):
    lab = {}
    for n in range(1, 7):
        best, bv = None, None
        for i, r in enumerate(its):
            if state_of(r) == "P" and cost_of(r) != "e" and i not in lab:
                dv = abs(r["tc"] - r["tp"])
                if bv is None or dv > bv:
                    best, bv = i, dv
        if best is None:
            break
        lab[best] = n
    return lab


def _tally(its):
    t = dict(up=0, m=0, sl=0, b=0, dn=0, pl=0, nw=0, z=0, nb=0, tot=0.0, bm=None, bs=None)
    for r in its:
        st = state_of(r)
        if st == "P":
            t["pl"] += 1
            t["tot"] += r["tc"]
        elif st == "N":
            t["nw"] += 1
        elif st == "Z":
            t["z"] += 1
        else:
            t["nb"] += 1
    for i, r in enumerate(its):
        if state_of(r) != "P":
            continue
        if cost_of(r) == "d":
            t["dn"] += 1
        if cost_of(r) == "u" and r["tc"] >= FLOOR * t["tot"]:
            t["up"] += 1
            c = cat_of(r)
            if c == "m":
                t["m"] += 1
                if t["bm"] is None or r["tc"] - r["tp"] > its[t["bm"]]["tc"] - its[t["bm"]]["tp"]:
                    t["bm"] = i
            elif c == "s":
                t["sl"] += 1
                if t["bs"] is None or r["tc"] - r["tp"] > its[t["bs"]]["tc"] - its[t["bs"]]["tp"]:
                    t["bs"] = i
            else:
                t["b"] += 1
    return t


def _put_table(its, kind, memo):
    L = []
    L.append("<h3>" + ("Top SQL" if kind == "sql" else "Wait events (foreground)") + "</h3>")
    s = kind == "sql"
    L.append('<table class="vc-t" id="vc-t-' + kind + '"><thead><tr><th>'
             + ("Statement" if s else "Event") + "</th>"
             + '<th class="num" data-w="0">' + ("Executions" if s else "Waits") + "</th>"
             + '<th class="num">normal</th><th class="num">vs normal</th>'
             + '<th class="num" data-w="0">' + ("Per run (ms)" if s else "Avg wait (ms)") + "</th>"
             + '<th class="num">normal</th><th class="num">vs normal</th>'
             + '<th class="num" data-w="0">' + ("Elapsed (s)" if s else "Waited (s)") + "</th>"
             + '<th class="num">normal</th><th class="num">vs normal</th>'
             + '<th class="num">Prior windows</th><th>Reads as</th></tr></thead><tbody>')
    for r in its:
        if state_of(r) == "Z":
            continue
        rid = anchor_id("vc-sq", r["nm"]) if s else anchor_uniq(anchor_id("vc-ev", r["nm"]), r["nm"], memo)
        L.append('<tr id="' + rid + '"><td' + (' class="mono"' if s else "") + ">"
                 + name_html(r, kind) + "</td>"
                 + '<td class="num" data-w="0"' + fmt_num_title(r["ec"]) + ">" + fmt_num(r["ec"]) + "</td>"
                 + '<td class="num">' + fmt_num(r["ep"]) + "</td>"
                 + '<td class="num">' + rx(ratio(r["ec"], r["ep"])) + "</td>"
                 + '<td class="num" data-w="0"' + fmt_num_title(r["pc"]) + ">" + fmt_num(r["pc"]) + "</td>"
                 + '<td class="num">' + fmt_num(r["pp"]) + "</td>"
                 + '<td class="num">' + rx(ratio(r["pc"], r["pp"])) + "</td>"
                 + '<td class="num" data-w="0"' + fmt_num_title(r["tc"]) + ">" + fmt_num(r["tc"]) + "</td>"
                 + '<td class="num">' + fmt_num(r["tp"]) + "</td>"
                 + '<td class="num">' + rx(ratio(r["tc"], r["tp"])) + "</td>"
                 + '<td class="num">' + fmt_int(r["nrun"]) + "</td>"
                 + "<td>" + why_txt(r, kind) + "</td></tr>")
    L.append("</tbody></table>")
    return L


def _item_json(r, kind, lab, memo) -> str:
    if kind == "sql":
        lk = anchor_id("sq-elapsed", r["nm"]) if r["in_t"] == 1 else ""
        rid = anchor_id("vc-sq", r["nm"])
    else:
        lk = anchor_id("we", r["nm"])
        rid = anchor_uniq(anchor_id("vc-ev", r["nm"]), r["nm"], memo)
    return ('{"n":"' + json_escape(r["nm"]) + '"' + ',"l":"' + lk + '"' + ',"r":"' + rid + '"'
            + ',"ec":' + jn(r["ec"]) + ',"ep":' + jn(r["ep"])
            + ',"pc":' + jn(r["pc"]) + ',"pp":' + jn(r["pp"])
            + ',"tc":' + jn(r["tc"]) + ',"tp":' + jn(r["tp"])
            + ',"k":"' + cost_of(r) + cat_of(r) + '","g":' + str(lab or 0) + "}")


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 21_volume_cost BEGIN -->']
    top_n = w.top_n
    cap = min(60, max(2 * top_n, top_n + 10))
    cur_win = w.windows[0]
    cur_valid = cur_win.valid_flag
    nprior = sum(1 for x in w.windows[1:] if x.valid)
    memo = {}
    sqls, evs = [], []
    if cur_valid == "Y" and nprior > 0:
        sqls = _sql_items(w, cap, top_n)
        evs = _ev_items(w, top_n)
    ts, te = _tally(sqls), _tally(evs)
    lab_s, lab_e = _labels(sqls), _labels(evs)

    rd_sql = rd_ev = None
    if ts["pl"] > 0:
        if ts["up"] == 0:
            rd_sql = ("No statement costs at least " + rx(THR) + " its normal total elapsed time ("
                      + pl(ts["pl"], "statement", "statements") + " compared"
                      + (", " + str(ts["dn"]) + " cost less" if ts["dn"] > 0 else "") + ").")
        else:
            parts = None
            if ts["m"] > 0:
                b = sqls[ts["bm"]]
                parts = (pl(ts["m"], "runs", "run") + ' more often (biggest: <b class="mono">' + b["nm"]
                         + "</b>, " + rx(ratio(b["ec"], b["ep"])) + " the executions)")
            if ts["sl"] > 0:
                b = sqls[ts["bs"]]
                parts = ((parts + ", " if parts is not None else "")
                         + ("1 is" if ts["sl"] == 1 else str(ts["sl"]) + " are")
                         + ' slower per run (biggest: <b class="mono">' + b["nm"] + "</b>, "
                         + rx(ratio(b["pc"], b["pp"])) + " per run)")
            if ts["b"] > 0:
                parts = ((parts + ", " if parts is not None else "")
                         + pl(ts["b"], "runs", "run") + " more often and " + ("takes" if ts["b"] == 1 else "take") + " longer")
            rd_sql = (pl(ts["up"], "statement costs", "statements cost") + " at least " + rx(THR)
                      + (" its" if ts["up"] == 1 else " their")
                      + " normal total elapsed time: " + parts + ".")
    if te["pl"] > 0:
        if te["up"] == 0:
            rd_ev = ("No wait event costs at least " + rx(THR) + " its normal time waited ("
                     + pl(te["pl"], "event", "events") + " compared"
                     + (", " + str(te["dn"]) + " cost less" if te["dn"] > 0 else "") + ").")
        else:
            parts = None
            if te["m"] > 0:
                b = evs[te["bm"]]
                parts = (pl(te["m"], "happens", "happen") + " more often (biggest: <b>" + esc(b["nm"])
                         + "</b>, " + rx(ratio(b["ec"], b["ep"])) + " the waits)")
            if te["sl"] > 0:
                b = evs[te["bs"]]
                parts = ((parts + ", " if parts is not None else "")
                         + pl(te["sl"], "lasts", "last") + " longer per wait (biggest: <b>" + esc(b["nm"]) + "</b>, "
                         + rx(ratio(b["pc"], b["pp"])) + " per wait)")
            if te["b"] > 0:
                parts = ((parts + ", " if parts is not None else "")
                         + pl(te["b"], "happens", "happen") + " more often and " + ("lasts" if te["b"] == 1 else "last") + " longer")
            rd_ev = (pl(te["up"], "wait event costs", "wait events cost") + " at least " + rx(THR)
                     + (" its" if te["up"] == 1 else " their")
                     + " normal time waited: " + parts + ".")

    open_ = ""
    if cur_valid != "Y":
        ls = "Current window skipped: nothing to compare"
    elif nprior == 0:
        ls = "no valid prior window: nothing to compare"
    elif ts["pl"] + te["pl"] == 0:
        ls = "nothing with a prior baseline to compare"
    elif ts["up"] == 0 and te["up"] == 0:
        ls = "no statement or wait costs " + rx(THR) + " its normal"
    else:
        ls = None
        if ts["up"] > 0:
            ls = (pl(ts["up"], "statement costs", "statements cost") + " more: "
                  + (str(ts["m"]) + " run" + ("s" if ts["m"] == 1 else "") + " more often" if ts["m"] > 0 else "")
                  + (", " if ts["m"] > 0 and ts["sl"] > 0 else "")
                  + (str(ts["sl"]) + (" is " if ts["sl"] == 1 else " are ") + "slower per run ("
                     + sqls[ts["bs"]]["nm"] + " " + rx(ratio(sqls[ts["bs"]]["pc"], sqls[ts["bs"]]["pp"])) + ")"
                     if ts["sl"] > 0 else "")
                  + (", " if (ts["m"] > 0 or ts["sl"] > 0) and ts["b"] > 0 else "")
                  + (str(ts["b"]) + " both" if ts["b"] > 0 else ""))
        if te["up"] > 0:
            ls = ((ls + "; " if ls is not None else "")
                  + pl(te["up"], "wait event costs", "wait events cost") + " more")
        if ts["sl"] > 0 or ts["b"] > 0:
            open_ = " lopen"
    mode = "ev" if ts["pl"] == 0 and te["pl"] > 0 else "sql"

    out.append('<section id="volume-cost" class="vw in-s in-a lib' + open_
               + '" style="--os:11" data-mode="' + mode + '"><h2>Volume vs unit cost'
               '<small class="h2sub">Ran more often, or each run got slower?</small></h2>')
    out.append(h.lib_ls("volume-cost", ls))
    if cur_valid != "Y":
        out.append('<p class="note">The Current window was skipped ('
                   + esc(cur_win.skip_reason or "no valid snapshots") + '), so there is nothing to place.</p>')
    elif nprior == 0:
        out.append('<p class="note">No valid prior window: there is no normal to compare'
                   ' Current with. Try more <code>weeks_back</code> or another <code>target_end</code>.</p>')
    elif len(sqls) + len(evs) == 0:
        out.append('<p class="note">No statement in DBA_HIST_SQLSTAT and no foreground wait'
                   ' event in DBA_HIST_SYSTEM_EVENT for the Current window.</p>')
    else:
        out.append('<p class="vc-q">Each dot is one statement (or wait event), Current against its'
                   ' own normal: the mean of the prior valid windows it ran in. Right = runs more often,'
                   ' up = each run is slower; the diagonals join points of equal total time.</p>')
        out.append('<div class="vc-bar vc-js"><span class="seg vc-seg" role="group" aria-label="Show">'
                   '<button type="button" data-k="sql" aria-pressed="' + ("true" if mode == "sql" else "false")
                   + '">Top SQL</button><button type="button" data-k="ev" aria-pressed="'
                   + ("true" if mode == "ev" else "false") + '">Wait events</button></span>'
                   '<span class="vc-lg"><span><i class="vc-k vc-u"></i>total &ge; ' + rx(THR) + ' normal</span>'
                   '<span><i class="vc-k vc-d"></i>&le; ' + rx(1 / THR) + '</span>'
                   '<span><i class="vc-k vc-e"></i>in between</span>'
                   '<span><i class="vc-k vc-o"></i>past the axis end</span>'
                   '<span>area = time in Current</span></span></div>')
        out.append('<div class="vc-wrap vc-js"><div class="vc-main">'
                   '<div class="vc-yt" data-vk="sql">Time per run vs normal <b>&uarr; each run slower</b> (plan, I/O, locks: database side)</div>'
                   '<div class="vc-yt" data-vk="ev">Time per wait vs normal <b>&uarr; each wait longer</b> (device, contention)</div>'
                   '<div class="vc-plot" id="vc-plot"></div>'
                   '<div class="vc-xt" data-vk="sql">Executions vs normal <b>&rarr; runs more often</b> (callers, batch size: application side)</div>'
                   '<div class="vc-xt" data-vk="ev">Number of waits vs normal <b>&rarr; waits more often</b> (more work reaching it)</div>'
                   '</div>')
        new_sql = new_ev = None
        for r in sqls:
            if state_of(r) == "N" and len(new_sql or "") < 30000:
                new_sql = (new_sql or "") + ('<li><span class="mono">' + name_html(r, "sql")
                                             + '</span> <span class="vc-nv">' + fmt_num(r["tc"]) + ' s</span></li>')
        for r in evs:
            if state_of(r) == "N" and len(new_ev or "") < 30000:
                new_ev = (new_ev or "") + ('<li>' + name_html(r, "ev")
                                           + ' <span class="vc-nv">' + fmt_num(r["tc"]) + ' s</span></li>')
        out.append('<aside class="vc-new" data-vk="sql"><h4>New in Current</h4>'
                   + ('<p>none: every statement ran in an earlier valid window</p>' if new_sql is None
                      else '<ul>' + new_sql + '</ul><p>no valid prior window saw them, so they cannot be placed</p>')
                   + '</aside>')
        out.append('<aside class="vc-new" data-vk="ev"><h4>New in Current</h4>'
                   + ('<p>none: every event was waited on before</p>' if new_ev is None
                      else '<ul>' + new_ev + '</ul><p>no valid prior window saw them, so they cannot be placed</p>')
                   + '</aside></div>')
        out.append('<p class="vc-rd" data-vk="sql"><b>Reads as:</b> '
                   + (rd_sql or 'No statement in Current has a prior baseline to compare with.') + '</p>')
        out.append('<p class="vc-rd" data-vk="ev"><b>Reads as:</b> '
                   + (rd_ev or 'No foreground wait event in Current has a prior baseline to compare with.') + '</p>')
        if ts["z"] + ts["nb"] + te["z"] + te["nb"] > 0:
            txt = ((pl(ts["z"], "statement", "statements")
                    + " with no completed execution in Current (still running at the window end, or idle), "
                    if ts["z"] > 0 else "")
                   + (pl(ts["nb"], "statement", "statements")
                      + " seen before but never completed a run in a prior valid window, " if ts["nb"] > 0 else "")
                   + (pl(te["z"], "event", "events") + " with no foreground wait in Current, " if te["z"] > 0 else "")
                   + (pl(te["nb"], "event", "events") + " with no prior foreground wait time, " if te["nb"] > 0 else ""))
            out.append('<p class="vc-drop">Not placed: ' + txt.rstrip(", ") + '.</p>')
        out.append('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.volcost={thr:' + jn(THR)
                   + ',top:' + str(top_n) + ',sql:[')
        sep = ""
        for i, r in enumerate(sqls):
            if state_of(r) == "P":
                out.append(sep + _item_json(r, "sql", lab_s.get(i), memo))
                sep = ","
        out.append('],ev:[')
        sep = ""
        for i, r in enumerate(evs):
            if state_of(r) == "P":
                out.append(sep + _item_json(r, "ev", lab_e.get(i), memo))
                sep = ","
        out.append(']};</script>')
        if sqls:
            out.extend(_put_table(sqls, "sql", memo))
        if evs:
            out.extend(_put_table(evs, "ev", memo))
    out.append('</section>')
    out.append(chrome.lib_script('js_volcost.plsql'))
    out.append('<!-- AWR-SECTION: 21_volume_cost END -->')
    return "\n".join(out)
