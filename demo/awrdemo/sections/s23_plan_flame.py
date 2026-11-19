"""
Twin of sql/23_plan_flame.sql (Plan shape, old vs new).

Statement rule (the SQL's): the Current window's top_n by elapsed (06's
ranking); window plan = the window's last non-zero plan hash; prior plan
= the most frequent window plan over the prior VALID windows (tie: the
most recent); changed = prior plan exists and differs from Current.  At
most 3 changed statements by Current elapsed; none -> the top statement
with a Current plan, alone.

The model has no plan lines, so this twin invents them for the story's
order-lookup statement (model.ORDER_LOOKUP_SQL): the old plan (its
catalog plan hash) is nested loops through two index range scans, the
Release 4.2 plan (model.ORDER_LOOKUP_BAD_PLAN) a hash join with a full
scan of ORDER_LINES.  Each hour's ASH samples of the statement
(HourMetrics.ash_sql, rounded to integers like section 11's twin, Idle
dropped, event -> wait class from the fg_events catalog) are spread over
the plan's lines by fixed per-class weights (largest remainder, so every
hour's total is exact); 3 % of each class (integer part) has no plan
line, as real ASH does.  Any other statement keeps its samples on a
one-line plan (SELECT STATEMENT).  Deterministic: no randomness needed.
"""
from __future__ import annotations

import re

from awrdemo import chrome, helpers
from awrdemo.helpers import anchor_id, ent, esc, fmt_num, json_escape, lib_ls, ora_round
from awrdemo.model import ORDER_LOOKUP_BAD_PLAN, ORDER_LOOKUP_SQL

C_MAX_ST = 3
C_MIN_SMP = 5
C_SMALL = 60
C_SPW = 10
C_KMUL = 1000000
NOLINE = C_KMUL - 1
CLASSES = ['CPU', 'User I/O', 'System I/O', 'Commit', 'Application',
           'Concurrency', 'Network', 'Configuration', 'Scheduler',
           'Cluster', 'Administrative', 'Queueing', 'Other']

# (id, parent_id, depth, operation, options, owner, object)
_OLD_PLAN = [
    (0, None, 0, "SELECT STATEMENT", None, None, None),
    (1, 0, 1, "SORT", "ORDER BY", None, None),
    (2, 1, 2, "NESTED LOOPS", None, None, None),
    (3, 2, 3, "TABLE ACCESS", "BY INDEX ROWID BATCHED", "ORDERS_APP", "ORDERS"),
    (4, 3, 4, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDERS_CUST_IX"),
    (5, 2, 3, "TABLE ACCESS", "BY INDEX ROWID", "ORDERS_APP", "ORDER_LINES"),
    (6, 5, 4, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDER_LINES_ORD_IX"),
]
_NEW_PLAN = [
    (0, None, 0, "SELECT STATEMENT", None, None, None),
    (1, 0, 1, "SORT", "ORDER BY", None, None),
    (2, 1, 2, "HASH JOIN", None, None, None),
    (3, 2, 3, "TABLE ACCESS", "BY INDEX ROWID BATCHED", "ORDERS_APP", "ORDERS"),
    (4, 3, 4, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDERS_CUST_IX"),
    (5, 2, 3, "TABLE ACCESS", "FULL", "ORDERS_APP", "ORDER_LINES"),
]
# class -> [(line, weight)]; a class not listed lands on line 0
_OLD_W = {"CPU": [(2, 35), (5, 20), (6, 20), (3, 15), (1, 10)],
          "User I/O": [(6, 50), (5, 30), (3, 12), (4, 8)]}
_NEW_W = {"CPU": [(2, 45), (5, 35), (1, 15), (3, 5)],
          "User I/O": [(5, 92), (3, 8)]}


def _plan_rows(sql_id, phv, old_phv):
    if sql_id == ORDER_LOOKUP_SQL and phv == ORDER_LOOKUP_BAD_PLAN:
        return _NEW_PLAN
    if sql_id == ORDER_LOOKUP_SQL:
        return _OLD_PLAN
    return [(0, None, 0, "SELECT STATEMENT", None, None, None)]


def _weights(sql_id, phv):
    if sql_id != ORDER_LOOKUP_SQL:
        return {}
    return _NEW_W if phv == ORDER_LOOKUP_BAD_PLAN else _OLD_W


def _spread(n, ws):
    """largest remainder: n integer samples over [(line, weight)]"""
    tot = sum(x for _, x in ws)
    base = [(ln, n * x // tot, (n * x) % tot) for ln, x in ws]
    left = n - sum(b for _, b, _ in base)
    order = sorted(range(len(base)), key=lambda i: (-base[i][2], i))
    out = {ln: b for ln, b, _ in base}
    for i in order[:left]:
        out[base[i][0]] += 1
    return out


def _hour_samples(w, m, sid, ev_cls):
    """{(line, class): samples} of one hour of statement sid, and its plan"""
    x = m.sql.get(sid)
    if x is None or sid not in m.ash_sql:
        return {}, None
    phv = x.plan_hash
    by_cls = {}
    for ev, smp in m.ash_sql[sid].items():
        c = "CPU" if ev == "CPU" else ev_cls.get(ev, "Other")
        if c == "Idle":
            continue
        n = int(ora_round(smp, 0))
        if n > 0:
            c = c if c in CLASSES else "Other"
            by_cls[c] = by_cls.get(c, 0) + n
    ws = _weights(sid, phv)
    out = {}
    for c, n in by_cls.items():
        nol = n * 3 // 100
        if nol:
            out[(NOLINE, c)] = out.get((NOLINE, c), 0) + nol
        for ln, v in _spread(n - nol, ws.get(c, [(0, 1)])).items():
            if v:
                out[(ln, c)] = out.get((ln, c), 0) + v
    return out, phv


def _fs(n):
    if n >= 100:
        return str(int(ora_round(n, 0)))
    return helpers.to_char_fixed(n, 1)


def _pct(n, d):
    if not d:
        return "0%"
    return str(int(ora_round(100 * n / d, 0))) + "%"


def _ratio(a, b):
    return helpers.to_char_fixed(ora_round(a / b, 1), 1)


def _js(s):
    return (json_escape(s) or "").replace(",", "\\u002c")


class _Plan:
    def __init__(self, phv, role, div):
        self.phv, self.role, self.div = phv, role, div
        self.tot = 0
        self.nol = 0
        self.state = "X"
        self.lines = 0
        self.maxid = -1
        self.marks = 0
        self.ash = {}       # line -> samples
        self.cls = {}       # (line, class) -> samples
        self.ptot = {}      # class -> samples
        self.st = {}        # id -> dict(par, dep, op, opt, own, obj, self, incl, sz, fc, ns, zero)
        self.wo_seen = set()

    def secs(self, n):
        return n * C_SPW / max(self.div or 1, 1)


def _step_txt(s):
    return " ".join(x for x in (s["op"], s["opt"], s["obj"]) if x)


def _cls_txt(P, sid, tot):
    if not tot:
        return ""
    vals = [(c, P.cls.get((sid, c), 0)) for c in CLASSES]
    used = set()
    r = []
    for _ in CLASSES:
        best, bv = None, 0
        for i, (c, v) in enumerate(vals):
            if i not in used and v > bv:
                best, bv = i, v
        if best is None:
            break
        used.add(best)
        r.append(CLASSES[best] + " " + _pct(bv, tot))
    return " &middot; ".join(r)


def _dom_cls(P, sid):
    best, bv = None, 0
    for c in CLASSES:
        v = P.cls.get((sid, c), 0)
        if v > bv:
            best, bv = c, v
    return best


def _dom_cnt(P, sid):
    c = _dom_cls(P, sid)
    return 0 if c is None else P.cls[(sid, c)]


def _hot(P):
    best, bv = None, 0
    for i in range(P.maxid + 1):
        s = P.st.get(i)
        if s is None:
            continue
        v = s["self"] - (P.nol if i == 0 else 0)
        if v > bv:
            best, bv = i, v
    return best


def _half(P):
    cur = 0
    while True:
        best, bv = None, 0
        c = P.st[cur]["fc"]
        while c is not None:
            if P.st[c]["incl"] > bv:
                best, bv = c, P.st[c]["incl"]
            c = P.st[c]["ns"]
        if best is None or bv * 2 < P.tot:
            break
        cur = best
    return cur


def _old_route(po, pn, hn):
    kn = pn.st[hn]
    if kn["obj"] is None or po.state != "Y":
        return None
    best, bv = None, -1
    for i in range(po.maxid + 1):
        s = po.st.get(i)
        if s and s["obj"] == kn["obj"] and (s["own"] or "-") == (kn["own"] or "-") and s["incl"] > bv:
            best, bv = i, s["incl"]
    if best is None:
        return "; the old plan has no step on " + esc(kn["obj"])
    kb = po.st[best]
    if kb["op"] == "TABLE ACCESS" and re.match(r"BY.*ROWID", kb["opt"] or "") and kb["fc"] is not None:
        c = kb["fc"]
        while c is not None:
            if po.st[c]["op"] == "INDEX":
                kb, best = po.st[c], c
                break
            c = po.st[c]["ns"]
    if _step_txt(kb) == _step_txt(kn):
        return ("; the old plan had the same step (line " + str(best) + ", "
                + _fs(po.secs(kb["incl"])) + " s per window)")
    how = " ".join(x for x in (kb["op"], kb["opt"]) if x) if kb["obj"] == kn["obj"] else _step_txt(kb)
    return ("; the old plan read " + esc(kn["obj"]) + " through " + esc(how)
            + " (line " + str(best) + ", " + _fs(po.secs(kb["incl"])) + " s per window)")


def _where(P, noun, short):
    h = _hot(P)
    if P.tot == 0:
        return None
    if h is None:
        return ('no plan line in the samples' if short else
                'none of ' + noun + ' samples carries a plan line, so its time cannot be placed on a step')
    c = _dom_cls(P, h)
    n = _dom_cnt(P, h)
    if P.nol * 2 >= P.tot:
        if short:
            return 'mostly no plan line in the samples'
        return (_pct(P.nol, P.tot) + ' of ' + noun + ' samples carry no plan line '
                '(drawn on the root step); the busiest step is ' + esc(_step_txt(P.st[h]))
                + ' (line ' + str(h) + ', ' + _pct(P.st[h]["self"], P.tot) + ')')
    if n * 4 >= P.tot:
        return (_pct(n, P.tot) + " of " + noun + " time is " + c + " on "
                + esc(_step_txt(P.st[h])) + " (line " + str(h) + ")")
    cb, cbv = None, 0
    for k in CLASSES:
        if P.ptot.get(k, 0) > cbv:
            cb, cbv = k, P.ptot[k]
    hh = _half(P)
    if short:
        return noun + " time is spread thin, " + _pct(cbv, P.tot) + " " + cb
    return (noun + " time is spread thin (the busiest step, " + esc(_step_txt(P.st[h]))
            + " on line " + str(h) + ", holds " + _pct(P.st[h]["self"], P.tot) + ")"
            + ("; " + _pct(P.st[hh]["incl"], P.tot) + " of it sits under "
               + esc(_step_txt(P.st[hh])) + " (line " + str(hh) + ")" if hh > 0 else "")
            + "; " + _pct(cbv, P.tot) + " of it is " + cb)


def _pick(w):
    """the statements: [(sql_id, cur_phv, old_phv, cur_ela_s, rnk)], mode"""
    wplan, cur_ela = {}, {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        for sid, x in m.sql.items():
            if win.week_offset == 0:
                cur_ela[sid] = ora_round(x.elapsed_us, 0)
            if x.plan_hash > 0:
                wplan[(win.week_offset, sid)] = x.plan_hash
    order = sorted(cur_ela, key=lambda s: (-cur_ela[s], s))
    topn = [(s, cur_ela[s], i + 1) for i, s in enumerate(order) if i + 1 <= w.top_n and cur_ela[s] > 0]
    sts, mode = [], None
    for sid, ela, rnk in topn:
        cnt, recent = {}, {}
        for (wo, s), phv in wplan.items():
            if s == sid and wo > 0:
                cnt[phv] = cnt.get(phv, 0) + 1
                recent[phv] = min(recent.get(phv, wo), wo)
        old = min(cnt, key=lambda p: (-cnt[p], recent[p])) if cnt else None
        cur = wplan.get((0, sid))
        chg = old is not None and cur is not None and old != cur
        if chg and len(sts) < C_MAX_ST:
            if mode in (None, "top"):
                sts, mode = [], "chg"
            sts.append((sid, cur, old, ela / 1e6, rnk))
        elif mode in (None, "top") and cur is not None and len(sts) < C_MAX_ST:
            mode = "top"
            sts.append((sid, cur, None, ela / 1e6, rnk))
    if mode == "top" and len(sts) > 1:
        ev_cls = {e.name: e.wait_class for e in w.fg_events}
        pick = sts[0]
        for st in sts:
            n = 0
            for m in w.hours(w.windows[0].win_start_ts, w.windows[0].win_end_ts):
                smp, phv = _hour_samples(w, m, st[0], ev_cls)
                if phv == st[1]:
                    n += sum(smp.values())
            if n >= C_MIN_SMP:
                pick = st
                break
        sts = [pick]
    return sts, mode


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 23_plan_flame BEGIN -->']
    cur_win = w.windows[0]
    n_prior = sum(1 for x in w.windows if x.week_offset > 0 and x.valid)
    sts, mode = _pick(w) if cur_win.valid else ([], None)
    ev_cls = {e.name: e.wait_class for e in w.fg_events}
    top_n = w.top_n

    plans = {}
    for i, (sid, cur, old, ela, rnk) in enumerate(sts, 1):
        plans[2 * i - 1] = _Plan(cur, "new" if mode == "chg" else "cur", 1)
        if mode == "chg":
            plans[2 * i] = _Plan(old, "old", 0)

    # ASH, per valid window (hour by hour, the hour's own plan)
    for win in w.valid_windows:
        for m in w.hours(win.win_start_ts, win.win_end_ts):
            for i, (sid, cur, old, ela, rnk) in enumerate(sts, 1):
                smp, phv = _hour_samples(w, m, sid, ev_cls)
                p = None
                if win.week_offset == 0 and phv == cur:
                    p = 2 * i - 1
                elif win.week_offset > 0 and mode == "chg" and phv == old:
                    p = 2 * i
                if p is None or not smp:
                    continue
                P = plans[p]
                if p % 2 == 0 and win.week_offset not in P.wo_seen:
                    P.wo_seen.add(win.week_offset)
                    P.div += 1
                for (ln, c), n in smp.items():
                    P.ash[ln] = P.ash.get(ln, 0) + n
                    P.cls[(ln, c)] = P.cls.get((ln, c), 0) + n
                    P.ptot[c] = P.ptot.get(c, 0) + n
                    P.tot += n

    # plans + tree
    for p, P in plans.items():
        sid = sts[(p + 1) // 2 - 1][0]
        for (i, par, dep, op, opt, own, obj) in _plan_rows(sid, P.phv, None):
            P.st[i] = {"par": par, "dep": dep, "op": op, "opt": opt, "own": own, "obj": obj,
                       "self": 0, "incl": 0, "sz": 1, "fc": None, "ns": None, "lc": None, "zero": 0}
            P.lines += 1
            P.maxid = max(P.maxid, i)
        P.state = "Y" if P.lines > 0 and 0 in P.st else "A"
        if P.state != "Y":
            continue
        for ln in sorted(P.ash):
            if ln < NOLINE and ln in P.st:
                P.st[ln]["self"] = P.ash[ln]
            else:
                P.st[0]["self"] += P.ash[ln]
                P.nol += P.ash[ln]
                for c in CLASSES:
                    if (ln, c) in P.cls:
                        P.cls[(0, c)] = P.cls.get((0, c), 0) + P.cls[(ln, c)]
        for i in range(1, P.maxid + 1):
            s = P.st.get(i)
            if s and s["par"] is not None and s["par"] in P.st:
                pp = P.st[s["par"]]
                if pp["fc"] is None:
                    pp["fc"] = i
                else:
                    P.st[pp["lc"]]["ns"] = i
                pp["lc"] = i
        for i in range(P.maxid + 1):
            if i in P.st:
                P.st[i]["incl"] = P.st[i]["self"]
        for i in range(P.maxid, 0, -1):
            s = P.st.get(i)
            if s and s["par"] is not None and s["par"] in P.st:
                P.st[s["par"]]["incl"] += s["incl"]
                P.st[s["par"]]["sz"] += s["sz"]
        if P.lines > C_SMALL:
            for i in range(1, P.maxid + 1):
                s = P.st.get(i)
                if s and s["incl"] == 0 and s["par"] in P.st and P.st[s["par"]]["incl"] > 0:
                    pp = P.st[s["par"]]
                    if pp["zero"] == 0:
                        P.marks += 1
                    pp["zero"] += s["sz"]

    out.append('<section id="plan-flame" class="vw in-s in-a lib'
               + (' lopen' if mode == 'chg' else '')
               + '" style="--os:13"><h2>Plan shape, old vs new'
               '<small class="h2sub">Where the time goes inside a changed plan, from ASH samples per plan line</small></h2>')
    if not sts:
        if not cur_win.valid:
            note = ('The Current window was skipped (' + esc(cur_win.skip_reason or 'no valid snapshots')
                    + '), so there is no Current top SQL to look at.')
        else:
            note = ('No statement in the Current window\'s top ' + str(top_n)
                    + ' by elapsed time has a captured plan hash.')
        out.append('<p class="note">' + note + '</p>')
        out.append(lib_ls('plan-flame', 'Current window skipped' if not cur_win.valid
                          else 'no top statement with a plan'))
        out.append('</section>')
        out.append(chrome.lib_script('js_planflame.plsql'))
        out.append('<!-- AWR-SECTION: 23_plan_flame END -->')
        return "\n".join(out)

    out.append('<p class="pf-intro">'
               + ('Statements in the Current window\'s top ' + str(top_n)
                  + ' by elapsed time whose plan differs from the plan they used most in the prior windows. '
                  if mode == 'chg' else
                  '<b>No plan change among the top ' + str(top_n)
                  + '</b>; this is where a top statement spends its time (the highest-ranked of the first three '
                  'with at least ' + str(C_MIN_SMP) + ' ASH samples, else the first). ')
               + 'A step\'s width is the DB time on that step and every step below it (ASH samples, about 10 s each, '
               'per window), so the widest path down is where the time goes; the colour is what the step itself was doing.</p>')
    out.append('<div class="pf-lg" aria-hidden="true"></div>')
    out.append('<p class="pf-nojs note">The drawing needs JavaScript; the plan tables below hold every number.</p>')

    js = ['{"spw":' + str(C_SPW) + ',"min":' + str(C_MIN_SMP) + ',"mode":"' + mode + '","st":[']
    ls = ''
    for i, (sid, cur, old, ela, rnk) in enumerate(sts, 1):
        bid = anchor_id('pf', sid)
        js.append((',' if i > 1 else '') + '{"id":"' + bid + '","sql":"' + _js(sid) + '","p":[')
        out.append('<div class="pf-st" id="' + bid + '" data-sql="' + esc(sid) + '" data-k="' + str(i - 1) + '">')
        out.append('<h3 class="pf-h">' + ent(esc(sid), anchor_id('sq-elapsed', sid), 'sql')
                   + (' <span class="pf-tag">plan ' + str(old) + ' &rarr; ' + str(cur) + '</span>'
                      if mode == 'chg' else ' <span class="pf-tag">plan ' + str(cur) + '</span>')
                   + ' <span class="pf-el">' + fmt_num(ela) + ' s elapsed in the Current window, #'
                   + str(rnk) + ' by elapsed</span></h3>')
        txt = re.sub(r"\s+", " ", w.sql_by_id[sid].text[:160]) if sid in w.sql_by_id else None
        if txt:
            out.append('<p class="pf-sqlt" title="first 160 characters">' + esc(txt[:160]) + '</p>')
        out.append('<div class="pf-pair' + (' one' if mode == 'top' else '') + '">')
        for q in range(1, (2 if mode == 'chg' else 1) + 1):
            p = 2 * i if (mode == 'chg' and q == 1) else 2 * i - 1
            P = plans[p]
            s = ({'old': '<b>Before:</b> plan ', 'new': '<b>Now:</b> plan '}.get(P.role, '<b>Plan</b> ')
                 + str(P.phv) + ', ' + _fs(P.secs(P.tot)) + ' s per window')
            if P.role == 'old':
                t = ('mean of the ' + ('one' if P.div == 1 else str(P.div)) + ' prior window' + ('s' if P.div > 1 else '') + ' it ran in'
                     if P.div > 0 else 'no ASH samples in the ' + str(n_prior) + ' prior windows')
            else:
                t = 'Current window'
            t += ', ' + str(P.tot) + ' ASH sample' + ('s' if P.tot != 1 else '')
            out.append('<div class="pf-side" data-r="' + P.role + '">'
                       '<div class="pf-hd">' + s + ' <small>' + t + '</small></div>')
            if P.state == 'Y' and P.tot >= C_MIN_SMP:
                out.append('<div class="pf-plot" data-q="' + str(q - 1) + '"></div>')
            else:
                out.append('<p class="pf-few">'
                           + ('No plan tree (no SELECT on DBA_HIST_SQL_PLAN).' if P.state == 'G' else
                              'Plan ' + str(P.phv) + ' is not in DBA_HIST_SQL_PLAN.' if P.state == 'A' else
                              'No ASH samples of this plan.' if P.tot == 0 else
                              'Too few ASH samples to draw (' + str(P.tot) + ').')
                           + ' The table below lists the plan.</p>')
            if P.nol > 0:
                out.append('<p class="pf-nol">' + str(P.nol) + ' sample' + ('s' if P.nol != 1 else '')
                           + (' without a plan line are' if P.nol != 1 else ' without a plan line is')
                           + ' shown on the root step.</p>')
            if P.marks > 0:
                out.append('<p class="pf-nol">Plan of ' + str(P.lines)
                           + ' lines: only the steps with samples are drawn and listed.</p>')
            out.append('</div>')
            js.append((',' if q > 1 else '') + '{"r":"' + P.role + '","phv":' + str(P.phv)
                      + ',"div":' + str(max(P.div, 1)) + ',"n":' + str(P.tot) + ',"nol":' + str(P.nol)
                      + ',"lines":' + str(P.lines) + ',"state":"' + P.state + '","s":[')
            if P.state == 'Y':
                n = 0
                for sid2 in range(P.maxid + 1):
                    st = P.st.get(sid2)
                    if st is None or (P.lines > C_SMALL and st["incl"] == 0):
                        continue
                    cl = ','.join('"' + c + '":' + str(P.cls[(sid2, c)]) for c in CLASSES
                                  if (sid2, c) in P.cls and st["self"] > 0)
                    js.append((',' if n > 0 else '') + '[' + str(sid2) + ','
                              + ('null' if st["par"] is None else str(st["par"]))
                              + ',"' + _js(st["op"]) + '","' + _js(st["opt"]) + '","' + _js(st["own"])
                              + '","' + _js(st["obj"]) + '",' + str(st["self"]) + ',{' + cl + '},'
                              + str(st["sz"] - 1 if st["incl"] == 0 else st["zero"]) + ']')
                    n += 1
            js.append(']}')
        js.append(']}')
        out.append('</div>')

        p = 2 * i - 1
        P = plans[p]
        if P.state == 'Y' and P.tot > 0:
            if mode == 'chg':
                rd = _where(P, "the new plan's", False)
                if _dom_cnt(P, _hot(P)) * 4 >= P.tot:
                    rd += _old_route(plans[2 * i], P, _hot(P)) or ''
                po = plans[2 * i]
                rd += ('. Per window: ' + _fs(P.secs(P.tot)) + ' s now, '
                       + (_fs(po.secs(po.tot)) + ' s before (' + _ratio(P.secs(P.tot), po.secs(po.tot)) + 'x).'
                          if po.tot > 0 else 'none sampled before.'))
            else:
                rd = _where(P, "this plan's", False) + '.'
            rd = rd[:1].upper() + rd[1:]
        elif P.tot == 0:
            rd = 'ASH holds no sample of plan ' + str(P.phv) + ' in the Current window.'
        else:
            rd = (str(P.tot) + ' ASH sample' + ('s' if P.tot != 1 else '') + ' of plan ' + str(P.phv)
                  + ' in the Current window; see the table by plan line.')
        out.append('<p class="pf-rd"><b>Reads as:</b> ' + rd + '</p>')
        if i == 1:
            if P.state == 'Y' and P.tot >= C_MIN_SMP:
                body = _where(P, 'new plan' if mode == 'chg' else 'its', True)
                if mode == 'chg' and plans[2].tot > 0:
                    body += ', ' + _ratio(plans[1].secs(plans[1].tot), plans[2].secs(plans[2].tot)) + 'x the old plan per window'
            elif P.state == 'G':
                body = 'needs SELECT on DBA_HIST_SQL_PLAN to draw the plan'
            elif P.state == 'A':
                body = 'plan not in DBA_HIST_SQL_PLAN'
            else:
                body = 'too few ASH samples to draw'
            ls = (esc(sid) + ': ' + ('no plan change in the top ' + str(top_n) + '; ' if mode == 'top' else '')
                  + body + (' (+' + str(len(sts) - 1) + ' more)' if len(sts) > 1 else ''))

        out.append('<details class="pf-tbls"><summary>Plan table'
                   + ('s, old and new' if mode == 'chg' else '') + '</summary>')
        for q in range(1, (2 if mode == 'chg' else 1) + 1):
            p = 2 * i if (mode == 'chg' and q == 1) else 2 * i - 1
            P = plans[p]
            out.append('<table class="pf-tb" data-nosort="Y" data-nocount="Y" data-pl="' + str(q - 1) + '">'
                       '<caption>' + {'old': 'Before', 'new': 'Now'}.get(P.role, 'Plan')
                       + ': plan ' + str(P.phv) + ', seconds of DB time per window</caption>'
                       '<thead><tr><th class="num">Line</th><th>Step</th><th>Object</th>'
                       '<th class="num" title="samples on the step itself">On the step, s</th>'
                       '<th class="num" title="the step and every step below it">With the steps below, s</th>'
                       '<th class="num">Of the plan</th><th>What the step was doing</th></tr></thead><tbody>')
            if P.state == 'Y' and P.lines > C_SMALL and P.tot == 0:
                out.append('<tr class="pf-z pf-mk"><td class="num"></td><td colspan="6">'
                           'A plan of ' + str(P.lines) + ' steps, none with samples</td></tr>')
            elif P.state == 'Y':
                for sid2 in range(P.maxid + 1):
                    st = P.st.get(sid2)
                    if st is None or (P.lines > C_SMALL and st["incl"] == 0):
                        continue
                    out.append('<tr data-ln="' + str(sid2) + '"' + (' class="pf-z"' if st["incl"] == 0 else '') + '>'
                               '<td class="num">' + str(sid2) + '</td>'
                               '<td><span class="pf-ind" style="--d:' + str(min(st["dep"], 24)) + '"'
                               + (' title="depth ' + str(st["dep"]) + '"' if st["dep"] > 24 else '') + '>'
                               + esc(" ".join(x for x in (st["op"], st["opt"]) if x)) + '</span></td>'
                               '<td' + (' title="' + esc(st["own"] + '.' + st["obj"]) + '"' if st["own"] else '')
                               + '>' + esc(st["obj"] or '') + '</td>'
                               '<td class="num">' + fmt_num(P.secs(st["self"])) + '</td>'
                               '<td class="num">' + fmt_num(P.secs(st["incl"])) + '</td>'
                               '<td class="num">' + _pct(st["incl"], P.tot) + '</td>'
                               '<td>' + _cls_txt(P, sid2, st["self"]) + '</td></tr>')
                    if st["zero"] > 0:
                        out.append('<tr class="pf-z pf-mk"><td class="num"></td><td colspan="6">'
                                   '<span class="pf-ind" style="--d:' + str(min(st["dep"] + 1, 24)) + '">+ '
                                   + str(st["zero"]) + ' step' + ('s' if st["zero"] != 1 else '')
                                   + ' without samples</span></td></tr>')
            else:
                n = 0
                for ln in sorted(P.ash):
                    out.append('<tr data-ln="' + str(ln) + '"><td class="num">'
                               + (str(ln) if ln < NOLINE else '&ndash;') + '</td>'
                               '<td>' + ('no plan line' if ln == NOLINE else 'line ' + str(ln)) + '</td><td></td>'
                               '<td class="num">' + fmt_num(P.secs(P.ash[ln])) + '</td>'
                               '<td class="num"></td>'
                               '<td class="num">' + _pct(P.ash[ln], P.tot) + '</td>'
                               '<td>' + _cls_txt(P, ln, P.ash[ln]) + '</td></tr>')
                    n += 1
                if n == 0:
                    out.append('<tr><td class="num"></td><td colspan="6">No ASH samples.</td></tr>')
            out.append('</tbody></table>')
        out.append('</details></div>')
    js.append(']}')

    out.append(lib_ls('plan-flame', ls))
    out.append('</section>')
    out.append('<script>window.AWR_DATA=window.AWR_DATA||{};window.AWR_DATA.planflame=')
    out.extend(_put_clob_chunked(''.join(js)))
    out.append(';</script>')
    out.append(chrome.lib_script('js_planflame.plsql'))
    out.append('<!-- AWR-SECTION: 23_plan_flame END -->')
    return "\n".join(out)


def _put_clob_chunked(payload: str) -> list[str]:
    """sql/lib/put_clob_chunked.plsql: <=32500-char chunks, each non-final
    chunk backed off to end on its last comma; one PUT_LINE per chunk."""
    out, n, pos = [], len(payload), 0
    while pos < n:
        take = min(32500, n - pos)
        if pos + take < n:
            cut = payload.rfind(",", pos, pos + take)
            if cut >= pos:
                take = cut - pos + 1
        out.append(payload[pos:pos + take])
        pos += take
    return out
