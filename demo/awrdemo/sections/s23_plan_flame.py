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

Plan 047 (objects around a plan change): the dictionary the SQL reads at
run time (DBA_OBJECTS, DBA_TAB_STATISTICS, DBA_TAB_STATS_HISTORY,
DBA_INDEXES) is synthesized for the two tables and two indexes of the
order-lookup plans, fixed values: statistics on ORDER_LINES (and its
index) updated on Tue 8 Sep 22:35, half an hour after Release 4.2 and
inside the interval; the old plan's index VALID and VISIBLE; no DDL; the
Saturday gathers before the interval.  "Now" = the report's generation
time.
"""
from __future__ import annotations

import re
from datetime import datetime

from awrdemo import chrome, helpers
from awrdemo.helpers import anchor_id, ent, esc, fmt_int, fmt_num, json_escape, lib_ls, ora_round
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


# plan 047: the plan lines' OBJECT_TYPE (DBA_HIST_SQL_PLAN)
_PLAN_OBJ_TYPE = {"ORDERS": "TABLE", "ORDER_LINES": "TABLE",
                  "ORDERS_CUST_IX": "INDEX", "ORDER_LINES_ORD_IX": "INDEX"}
C_MAX_OBJ = 30
C_HIST_D = 31


def _d(s):
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")


# the synthesized dictionary, keyed (kind, owner, name)
_DICT_OBJ = {   # DBA_OBJECTS: created, last_ddl_time, status
    ("T", "ORDERS_APP", "ORDERS"): (_d("2024-03-11 14:02:17"), _d("2026-05-19 21:40:03"), "VALID"),
    ("T", "ORDERS_APP", "ORDER_LINES"): (_d("2024-03-11 14:02:19"), _d("2026-05-19 21:40:05"), "VALID"),
    ("I", "ORDERS_APP", "ORDERS_CUST_IX"): (_d("2024-03-11 14:05:40"), _d("2025-11-02 01:12:09"), "VALID"),
    ("I", "ORDERS_APP", "ORDER_LINES_ORD_IX"): (_d("2024-03-11 14:06:02"), _d("2025-11-02 01:14:51"), "VALID"),
}
_DICT_TS = {    # DBA_TAB_STATISTICS: last_analyzed, num_rows, stale_stats, stattype_locked
    ("ORDERS_APP", "ORDERS"): (_d("2026-08-29 06:11:42"), 38412960, "NO", None),
    ("ORDERS_APP", "ORDER_LINES"): (_d("2026-09-08 22:35:18"), 161204773, "NO", None),
}
_DICT_TH = {    # DBA_TAB_STATS_HISTORY: stats_update_time, newest first
    ("ORDERS_APP", "ORDERS"): [_d("2026-08-29 06:11:42"), _d("2026-08-15 06:09:55")],
    ("ORDERS_APP", "ORDER_LINES"): [_d("2026-09-08 22:35:18"), _d("2026-08-29 06:15:02"),
                                    _d("2026-08-15 06:13:30")],
}
_DICT_IX = {    # DBA_INDEXES: table_owner, table_name, status, visibility, partitioned, last_analyzed, num_rows
    ("ORDERS_APP", "ORDERS_CUST_IX"): ("ORDERS_APP", "ORDERS", "VALID", "VISIBLE", "NO",
                                       _d("2026-08-29 06:12:20"), 38412960),
    ("ORDERS_APP", "ORDER_LINES_ORD_IX"): ("ORDERS_APP", "ORDER_LINES", "VALID", "VISIBLE", "NO",
                                           _d("2026-09-08 22:36:04"), 161204773),
}
_DOW = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _obj_kind(op, typ, own, nam):
    if own is None or nam is None or nam[:8] == "SYS_TEMP":
        return None
    if typ is not None:
        if "FIXED" in typ or "TEMP" in typ:
            return None
        if typ[:5] == "TABLE":
            return "T"
        if typ[:5] == "INDEX":
            return "I"
        return None
    if (op or "")[:12] == "TABLE ACCESS":
        return "T"
    if "INDEX" in (op or ""):
        return "I"
    return None


def _tcls(t, lo, hi):
    if t is None or lo is None or hi is None:
        return None
    if t > hi:
        return "A"
    if t >= lo:
        return "I"
    return "B"


def _dkey(t):
    return t.strftime("%Y-%m-%d %H:%M:%S")


def _dlong(t):
    return t.strftime("%Y-%m-%d %H:%M")


def _dday(t, with_time):
    r = _DOW[t.weekday()] + " " + str(t.day) + " " + _MON[t.month - 1]
    return r + (" " + t.strftime("%H:%M") if with_time else "")


def _tcell(t, lo, hi):
    if t is None:
        return None
    c = _tcls(t, lo, hi)
    if c == "I":
        return '<span class="pf-ot" data-t="' + _dkey(t) + '" title="inside the interval">' + _dlong(t) + '</span>'
    if c == "A":
        return '<span class="pf-oa" title="after the end of the Current window">' + _dlong(t) + '</span>'
    return _dlong(t)


class _Obj:
    """one table / index of the plans and its dictionary state (the SQL's o_*)"""
    def __init__(self, kind, own, nam):
        self.kind, self.own, self.nam = kind, own, nam
        self.seen = False
        self.crt = self.ddl = self.ost = None
        self.la = self.rows = self.stale = self.lock = None
        self.tab = self.ist = self.vis = self.part = None
        self.hist = []

    def name(self):
        return esc(self.own + "." + self.nam)

    def read(self):
        o = _DICT_OBJ.get((self.kind, self.own, self.nam))
        if o:
            self.seen = True
            self.crt, self.ddl, self.ost = o
        if self.kind == "T":
            t = _DICT_TS.get((self.own, self.nam))
            if t:
                self.seen = True
                self.la, self.rows, self.stale, self.lock = t
            h = _DICT_TH.get((self.own, self.nam))
            if h:
                self.seen = True
                self.hist = list(h)
        else:
            x = _DICT_IX.get((self.own, self.nam))
            if x:
                self.seen = True
                tow, tnm, self.ist, self.vis, self.part, self.la, self.rows = x
                self.tab = tnm if tow == self.own else tow + "." + tnm

    def st_first_in(self, lo, hi):
        if self.kind == "T":
            r = None
            for t in self.hist:
                if _tcls(t, lo, hi) == "I":
                    r = t
            if r is not None:
                return r
        if _tcls(self.la, lo, hi) == "I":
            return self.la
        return None

    def st_n_in(self, lo, hi):
        if self.kind == "T":
            n = sum(1 for t in self.hist if _tcls(t, lo, hi) == "I")
            if n > 0:
                return n
        return 1 if self.st_first_in(lo, hi) is not None else 0

    def bad_state(self):
        if self.kind == "I" and self.ist == "UNUSABLE":
            return "UNUSABLE"
        if self.kind == "I" and self.vis == "INVISIBLE":
            return "INVISIBLE"
        if self.ost == "INVALID":
            return "INVALID"
        return None


def _pre_txt(o, lo, hi):
    """a table's statistics updates before the interval, at most 2, newest first"""
    if o.kind != 'T':
        return None
    pre = [_dday(t, True) for t in o.hist if _tcls(t, lo, hi) == 'B'][:2]
    return ', '.join(pre) or None


def _in_txt(f):
    return {1: "old", 2: "new"}.get(f, "both")


def _used_txt(f):
    return {1: "used by the old plan", 2: "used by the new plan"}.get(f, "used by both plans")


def _obj_row(sid, j, o, f, lo, hi):
    r = ('<tr class="pf-or" id="' + anchor_id('pfo', sid + '-' + str(j)) + '" data-k="' + o.kind
         + '" data-in="' + _in_txt(f) + '"><td class="pf-on">' + o.name() + '</td><td>'
         + ('table' if o.kind == 'T' else 'index' + (' on ' + esc(o.tab) if o.tab else ''))
         + '</td><td>' + _in_txt(f) + '</td>')
    if o.la is not None:
        r += ('<td>' + _tcell(o.la, lo, hi)
              + (' &middot; ' + fmt_int(o.rows) + (' row' if o.rows == 1 else ' rows') if o.rows is not None else '') + '</td>')
    elif o.seen:
        r += '<td>never gathered</td>'
    else:
        r += '<td>&ndash;</td>'
    if o.kind == 'T':
        hs = [t for t in o.hist if _tcls(t, lo, hi) == 'I']
        n = len(hs)
        h = ', '.join(_tcell(t, lo, hi) for t in hs[:3])
        if n == 0 and o.st_first_in(lo, hi) is not None:
            r += ('<td title="from LAST_ANALYZED: no statistics history row inside the interval">'
                  + _tcell(o.la, lo, hi) + '</td>')
        else:
            r += '<td>' + ('&ndash;' if n == 0 and not o.seen else 'none' if n == 0 else h + (' + ' + str(n - 3) + ' more' if n > 3 else '')) + '</td>'
    else:
        n = o.st_n_in(lo, hi)
        r += ('<td' + (' title="from LAST_ANALYZED: the latest gather only"' if n == 0 else '') + '>'
              + (_tcell(o.la, lo, hi) if n > 0 else 'none' if o.seen else '&ndash;') + '</td>')
    r += ('<td>' + (_tcell(o.ddl, lo, hi) or '&ndash;') + '</td>'
          + '<td>' + (_tcell(o.crt, lo, hi) or '&ndash;') + '</td>')
    if not o.seen:
        st = 'no dictionary row in this container'
    elif o.kind == 'I':
        st = ((o.ist or 'not read') + (', ' + o.vis if o.vis else '')
              + (', partitioned (partitions not checked)' if o.part == 'YES' else ''))
        if o.ost == 'INVALID':
            st += ', INVALID'
    else:
        st = ((o.ost or 'status not read') + (', statistics stale' if o.stale == 'YES' else '')
              + (', statistics locked (' + o.lock + ')' if o.lock else ''))
    r += '<td>' + esc(st) + '</td>'
    mk = ''
    if o.st_first_in(lo, hi) is not None:
        mk += '<span class="pf-om" data-m="stats">new statistics</span>'
    if _tcls(o.ddl, lo, hi) == 'I':
        mk += '<span class="pf-om" data-m="ddl" title="LAST_DDL_TIME: DDL, including grants and revokes">DDL</span>'
    if _tcls(o.crt, lo, hi) == 'I':
        mk += '<span class="pf-om" data-m="created">created</span>'
    b = o.bad_state()
    if b:
        mk += '<span class="pf-om pf-oms" data-m="state">' + b + '</span>'
    if not o.seen:
        mk += '<span class="pf-om pf-oms" data-m="norow">no dictionary row</span>'
    if _tcls(o.ddl, lo, hi) == 'A':
        mk += ('<span class="pf-om pf-omu" data-m="later" title="the latest DDL only: a later one hides any '
               'inside the interval">later DDL</span>')
    return r + '<td>' + mk + '</td></tr>'


def _compose(sid, objs, flags, lo, hi, now):
    """(reads-as sentence, card row or None, lib clause or None): the SQL's
    compose(), over the listed (first C_MAX_OBJ) objects only"""
    thes = 'the listed objects' if len(objs) > C_MAX_OBJ else 'these objects'
    objs, flags = objs[:C_MAX_OBJ], flags[:C_MAX_OBJ]
    if not any(o.seen for o in objs):
        return ('These objects are not visible from this container (the dictionary shows the container the report '
                'runs in: run it in the PDB that owns them), so nothing can be said about statistics, DDL or index state.',
                None, None)
    rd, cid, cdt, cde, lsx = '', None, None, None, None
    nitm = nsn = ndd = 0
    sn = dd = cr = ''
    unk = None
    for j, o in enumerate(objs, 1):
        f = flags[j - 1]
        rid = anchor_id('pfo', sid + '-' + str(j))
        b = o.bad_state()
        if b:
            rd += ('Index ' if o.kind == 'I' else '') + o.name() + ', ' + _used_txt(f) + ', is ' + b + ' now. '
            nitm += 1
            if cid is None:
                cid, cdt, cde = rid, ('index ' if o.kind == 'I' else '') + ent(esc(o.nam), rid, 'obj'), b + ' now'
        elif not o.seen:
            rd += (o.name() + ', ' + _used_txt(f) + ', has no dictionary row in this container now '
                   '(dropped, or not visible here). ')
            nitm += 1
            if cid is None:
                cid, cdt, cde = rid, ent(esc(o.nam), rid, 'obj'), 'no dictionary row now'
    for j, o in enumerate(objs, 1):
        rid = anchor_id('pfo', sid + '-' + str(j))
        t = o.st_first_in(lo, hi)
        if t is not None:
            nsn += 1
            if nsn <= 2:
                sn += (' and ' if nsn == 2 else '') + o.name() + ' (' + _dday(t, True) + (
                    ', ' + str(o.st_n_in(lo, hi)) + ' times from then on' if o.st_n_in(lo, hi) > 1 else '') + (
                    '; earlier in the history: ' + _pre_txt(o, lo, hi) if nsn == 1 and _pre_txt(o, lo, hi) else '') + ')'
            if cid is None or (nitm == 0 and nsn == 1):
                cid, cdt, cde = rid, 'new statistics on ' + ent(esc(o.nam), rid, 'obj'), _dday(t, True)
            if nsn == 1:
                lsx = 'new statistics on ' + esc(o.nam) + ' around the change'
        if _tcls(o.ddl, lo, hi) == 'I':
            ndd += 1
            if ndd <= 2:
                dd += (' and ' if ndd == 2 else '') + o.name() + ' (' + _dday(o.ddl, True) + ')'
            if cid is None:
                cid, cdt, cde = rid, 'DDL on ' + ent(esc(o.nam), rid, 'obj'), _dday(o.ddl, True)
            if lsx is None:
                lsx = 'DDL on ' + esc(o.nam) + ' around the change'
        if _tcls(o.crt, lo, hi) == 'I':
            cr += o.name() + ' was created on ' + _dday(o.crt, True) + ', inside the same interval. '
            if cid is None:
                cid, cdt, cde = rid, ent(esc(o.nam), rid, 'obj') + ' created', _dday(o.crt, True)
            if lsx is None:
                lsx = esc(o.nam) + ' created around the change'
        if unk is None:
            if _tcls(o.ddl, lo, hi) == 'A':
                unk = ('the last DDL on ' + o.name() + ' (' + _dday(o.ddl, True)
                       + ') is after the Current window, so an earlier one cannot be seen')
            elif o.kind == 'I' and _tcls(o.la, lo, hi) == 'A':
                unk = ('the statistics of index ' + o.name() + ' date from ' + _dday(o.la, True)
                       + ', after the Current window, so an earlier gather cannot be seen')
            elif _tcls(o.crt, lo, hi) == 'A':
                unk = (o.name() + ' was created on ' + _dday(o.crt, True) + ', after the Current window: '
                       'the object the plans used was an earlier one of that name')
    if nsn > 0:
        rd += ('New statistics on ' + sn + (' and ' + str(nsn - 2) + ' more' if nsn > 2 else '')
               + ' date from between the start of the last window on the old plan (' + _dday(lo, False)
               + ') and the end of the Current window; the plan may have followed them. ')
    if ndd > 0:
        rd += ('The last DDL on ' + dd + (' and ' + str(ndd - 2) + ' more' if ndd > 2 else '')
               + ' falls in that interval too'
               + (' (from ' + _dday(lo, False) + ' to the end of the Current window)' if nsn == 0 else '') + '. ')
    rd += cr
    if not rd:
        rd = ('Nothing in the dictionary changed around the plan change for ' + thes + ' (statistics, DDL, '
              'creation, index state, from ' + _dday(lo, False) + ' to the end of the Current window)'
              + ('; but ' + unk if unk else '')
              + ('; the statistics history keeps ' + str(C_HIST_D) + ' days by default, so it may not reach back to '
                 + _dday(lo, False) if (now - lo).total_seconds() > C_HIST_D * 86400 else '')
              + '.')
    elif unk:
        rd += 'Also, ' + unk + '.'
    rd = rd.rstrip()
    cev = None
    if cid is not None:
        more = nitm + nsn + ndd
        cev = ('<div class="evr ev-pfo" data-pfo="' + cid + '" title="From the dictionary of this container, '
               'as of the report run. Not scored."><dt>Objects</dt><dd><span class="id txt">' + cdt
               + '</span><span class="de">' + re.sub(r'([0-9]) ', r'\1&nbsp;', cde)
               + (' (+' + str(more - 1) + ' more)' if more > 1 else '')
               + '</span></dd><div class="m"><span class="ns">not scored</span></div></div>')
    return rd, cev, lsx


def _objects(sid, P_old, P_new):
    """the statement's tables and indexes, tables first then by owner.name:
    [(obj, flag)] with flag 1 old plan, 2 new plan, 3 both"""
    seen, order = {}, []
    for q, P in ((1, P_old), (2, P_new)):
        if P is None or P.state != 'Y':
            continue
        for i in range(P.maxid + 1):
            st = P.st.get(i)
            if st is None:
                continue
            k = _obj_kind(st["op"], st["typ"], st["own"], st["obj"])
            if k is None:
                continue
            key = (k, st["own"], st["obj"])
            if key not in seen:
                seen[key] = 0
                order.append(key)
            seen[key] |= q
    order.sort(key=lambda x: ('0' if x[0] == 'T' else '1') + x[1] + '.' + x[2])
    out = []
    for key in order:
        o = _Obj(*key)
        o.read()
        out.append((o, seen[key]))
    return out


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
                       "typ": _PLAN_OBJ_TYPE.get(obj),
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

    # plan 047: the objects of the plans (changed plans only)
    now = datetime.strptime(w.generated_at[:19], "%Y-%m-%d %H:%M:%S")
    cur_end = cur_win.win_end_ts
    wstart = {x.week_offset: x.win_start_ts for x in w.windows}
    objs, lo_of, ord_of, cev_of, lsx_of = {}, {}, {}, {}, {}
    if mode == 'chg':
        for i, (sid, cur, old, ela, rnk) in enumerate(sts, 1):
            lo_wo = None
            for win in w.valid_windows:
                if win.week_offset > 0:
                    x = w.window_metrics(win).sql.get(sid)
                    if x is not None and x.plan_hash > 0 and x.plan_hash == old:
                        lo_wo = win.week_offset if lo_wo is None else min(lo_wo, win.week_offset)
            lo_of[i] = wstart.get(lo_wo) if lo_wo is not None else None
            objs[i] = _objects(sid, plans.get(2 * i), plans.get(2 * i - 1))
            if objs[i] and lo_of[i] is not None:
                ord_of[i], cev_of[i], lsx_of[i] = _compose(sid, [o for o, _ in objs[i]], [f for _, f in objs[i]],
                                                           lo_of[i], cur_end, now)

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
                  + body + ('; ' + lsx_of[1] if mode == 'chg' and lsx_of.get(1) else '')
                  + (' (+' + str(len(sts) - 1) + ' more)' if len(sts) > 1 else ''))

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
        out.append('</details>')
        if mode == 'chg' and objs.get(i) and lo_of.get(i) is not None:
            lo = lo_of[i]
            out.append('<div class="pf-obj" id="' + anchor_id('pfo', sid) + '" data-t0="' + _dkey(lo)
                       + '" data-t1="' + _dkey(cur_end) + '" data-now="' + _dkey(now) + '" data-n="' + str(len(objs[i])) + '">'
                       '<h4 class="pf-oh">Objects in these plans <small>the dictionary of this container, as of this report run ('
                       + _dlong(now) + ')</small></h4>')
            if ord_of.get(i):
                out.append('<p class="pf-ord"><b>Reads as:</b> ' + ord_of[i] + '</p>')
            out.append('<p class="pf-oiv">&ldquo;Around the plan change&rdquo; = from the start of the last prior window on the old plan ('
                       + _dday(lo, True) + ') to the end of the Current window (' + _dday(cur_end, True)
                       + '). Created, last DDL, last analyzed and the statistics history are past times; every other value is the state now. '
                       'Table-level rows only: partitions are not checked.</p>')
            out.append('<div class="pf-otw"><table class="pf-ob" data-nosort="Y" data-nocount="Y">'
                       '<thead><tr><th>Object</th><th>Type</th><th title="in the old plan, the new plan or both">In plan</th>'
                       '<th title="LAST_ANALYZED and NUM_ROWS now">Statistics now</th>'
                       '<th title="DBA_TAB_STATS_HISTORY for a table (statistics gathered, set, restored or imported); LAST_ANALYZED for an index">New statistics in the interval</th>'
                       '<th title="LAST_DDL_TIME: the latest DDL, grants and revokes included">Last DDL</th><th>Created</th><th>State now</th><th>Around the change</th></tr></thead><tbody>')
            for j, (o, f) in enumerate(objs[i][:C_MAX_OBJ], 1):
                out.append(_obj_row(sid, j, o, f, lo, cur_end))
            out.append('</tbody></table></div>')
            if len(objs[i]) > C_MAX_OBJ:
                out.append('<p class="note pf-ocap">The plans touch ' + str(len(objs[i])) + ' tables and indexes; the first '
                           + str(C_MAX_OBJ) + ' are listed (tables first, then by name).</p>')
            out.append('</div>')
        out.append('</div>')
    js.append(']}')

    out.append(lib_ls('plan-flame', ls))
    out.append('</section>')
    out.append('<script>window.AWR_DATA=window.AWR_DATA||{};window.AWR_DATA.planflame=')
    out.extend(_put_clob_chunked(''.join(js)))
    out.append(';</script>')
    srcs = ''.join('<div data-for="f-plan-' + esc(sts[i - 1][0]) + '" data-ph0="' + str(sts[i - 1][2])
                   + '" data-ph1="' + str(sts[i - 1][1]) + '">' + cev_of[i] + '</div>'
                   for i in range(1, len(sts) + 1) if mode == 'chg' and cev_of.get(i))
    if srcs:
        out.append('<div id="pfo-ev-src" hidden>' + srcs + '</div>')
        out.append('<script>(function(){var d=document,x=d.getElementById("pfo-ev-src");if(!x)return;'
                   '[].slice.call(x.children).forEach(function(g){var c=d.getElementById(g.getAttribute("data-for")),'
                   'dl=c?c.querySelector("dl.ev"):null;if(dl&&c.getAttribute("data-ph0")===g.getAttribute("data-ph0")'
                   '&&c.getAttribute("data-ph1")===g.getAttribute("data-ph1")){while(g.firstChild)dl.appendChild(g.firstChild);}});'
                   'x.parentNode.removeChild(x);})();</script>')
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
