"""Twin of sql/29_who.sql (Who added the load, plan 045): the compared
windows' FOREGROUND active sessions by service, module, machine, program
and user, the values whose time rose first, a "Reads as:" sentence, the
library row text and the DB time card's "Who" evidence row.

The model has no session attributes, so this twin derives them
deterministically from the model's own numbers.  Per hour, the foreground
ASH sample count is exactly section 09's (s09: each class's samples less
the background-wait samples, rounded), so a window's total here equals
AWR_DATA.ashx.winfg's.  That count is split over a fixed list of
"clients" (one service / module / machine / program / user each, below)
by largest remainder on weights: every statement's ASH samples
(m.ash_sql) go to the client of its module and schema, and the rest (the
model's residual: PL/SQL, recursive and unlisted SQL) by fixed shares.
So every dimension sums to the same window totals, and the story is the
model's: after Release 4.2 the order lookup's plan flip doubles
OrderService (ORDERS_APP) time, which the two OrderService app servers
(app-01, app-02) share about evenly -- so machine reads "spread".  The
reporting statement runs PARALLEL 8: 8 of its 9 samples are PX slaves
("oracle@prd-ora-01 (P003)" -> norm_program -> "(Pnnn)").
"""
from __future__ import annotations

import math
import re

from awrdemo.helpers import anchor_id, anchor_uniq, band_span, band_z, delta_span, ent, esc, fmt_num, lib_ls, nbu, num6, ora_round

C_KEEP, C_SHOW = 40, 8
C_DOM, C_CARD, C_MIN = 0.5, 0.3, 0.1

DIMS = [  # (code, word, head)
    ("svc", "service", "Service"),
    ("mod", "module", "Module"),
    ("mch", "machine", "Machine"),
    ("prg", "program", "Program"),
    ("usr", "user", "User"),
]
_NOV = ["(no service)", "(no module)", "(no machine)", "(no program)", "(no user)"]

# service name -> service_hash (the SQL keys a service by its hash and
# names it through DBA_HIST_SERVICE_NAME); user -> user_id
SVC_HASH = {"ORDERS_SVC": 2917384501, "LOYALTY_SVC": 1046385297, "REPORTING_SVC": 3388019265,
            "BATCH_SVC": 744920318, "SYS$USERS": 165959219}
USER_ID = {"ORDERS_APP": 112, "LOYALTY": 131, "REPORTING": 118, "INVENTORY": 109, "SYS": 0, "DBSNMP": 75}

# the clients: (service, module, machine, program, user); None = NULL
CLIENTS = [
    ("ORDERS_SVC", "OrderService", "app-01", "JDBC Thin Client", "ORDERS_APP"),                       # 0
    ("ORDERS_SVC", "OrderService", "app-02", "JDBC Thin Client", "ORDERS_APP"),                       # 1
    ("ORDERS_SVC", "PaymentGateway", "app-03", "JDBC Thin Client", "ORDERS_APP"),                     # 2
    ("LOYALTY_SVC", "LoyaltyService", "app-03", "JDBC Thin Client", "LOYALTY"),                       # 3
    ("REPORTING_SVC", "ReportEngine", "rpt-01", "python3@rpt-01 (TNS V1-V3)", "REPORTING"),           # 4
    ("REPORTING_SVC", "ReportEngine", "prd-ora-01", "oracle@prd-ora-01 (P003)", "REPORTING"),         # 5 PX
    ("BATCH_SVC", "InventorySync", "etl-01", "JDBC Thin Client", "INVENTORY"),                        # 6
    ("SYS$USERS", "DBMS_SCHEDULER", "prd-ora-01", "oracle@prd-ora-01 (J001)", "INVENTORY"),           # 7
    ("SYS$USERS", "DBMS_SCHEDULER", "prd-ora-01", "oracle@prd-ora-01 (J002)", "LOYALTY"),             # 8
    ("SYS$USERS", "DBMS_SCHEDULER", "prd-ora-01", "oracle@prd-ora-01 (J000)", "SYS"),                 # 9
    ("BATCH_SVC", "SQL*Plus", "etl-01", "sqlplus@etl-01 (TNS V1-V3)", "REPORTING"),                   # 10
    ("SYS$USERS", "emagent_SQL_oracle_database", "oem-01", "JDBC Thin Client", "DBSNMP"),             # 11
    ("SYS$USERS", "sqlplus@prd-ora-01 (TNS V1-V3)", "prd-ora-01", "sqlplus@prd-ora-01 (TNS V1-V3)", "SYS"),  # 12
    ("ORDERS_SVC", None, "app-02", "JDBC Thin Client", "ORDERS_APP"),                                 # 13
]
PX_SQL = "9wz2ke6yq4tn1"      # PARALLEL(sf 8): 1 QC + 8 slaves


def norm_program(p):
    """The SQL's REGEXP_REPLACE: a slave's number folded, (P003) -> (Pnnn)."""
    if p is None:
        return None
    return re.sub(r"\(([A-Z])([0-9]{3}|[A-Z][0-9]{2})\)$", r"(\1nnn)", p)


def _fg_samples(m) -> int:
    """Section 09's foreground sample count of one hour (s09 cells_by_hour)."""
    bgs = {}
    for _ev, (bwc, _c, us) in m.bg_waits.items():
        if bwc != "Idle":
            bgs[bwc] = bgs.get(bwc, 0.0) + us / 1e6 / 10
    tot = 0
    for wc, smp in m.ash_class.items():
        n = int(ora_round(smp, 0))
        if n <= 0:
            continue
        tot += max(0, int(ora_round(smp - bgs.get(wc, 0.0), 0)))
    return tot


def _sql_units(s, p):
    """[(client index, fraction)] of a statement's samples."""
    if s.module == "OrderService":
        return [(0, p), (1, 1 - p)]
    if s.module == "PaymentGateway":
        return [(2, 1.0)]
    if s.module == "LoyaltyService":
        return [(3, 1.0)]
    if s.module == "ReportEngine":
        return [(4, 1.0 / 9), (5, 8.0 / 9)] if s.sql_id == PX_SQL else [(4, 1.0)]
    if s.module == "InventorySync":
        return [(6, 1.0)]
    if s.module == "DBMS_SCHEDULER":
        return [({"INVENTORY": 7, "LOYALTY": 8}.get(s.schema, 9), 1.0)]
    if s.module == "SQL*Plus":
        return [(10, 1.0)]
    if s.module.startswith("emagent"):
        return [(11, 1.0)]
    return [(12, 1.0)]


def _hour_clients(w, m):
    """The hour's foreground samples per client (integers, summing to 09's)."""
    n = _fg_samples(m)
    r = w.rng("s29", m.ts)
    p = 0.47 + 0.06 * r.random()
    wts = [0.0] * len(CLIENTS)
    for sid, d in sorted(m.ash_sql.items()):
        v = math.fsum(d.values())
        for u, f in _sql_units(w.sql_by_id[sid], p):
            wts[u] += v * f
    resid = max(0.0, n - math.fsum(wts))
    rw = {0: 0.40 * p, 1: 0.40 * (1 - p), 2: 0.07, 3: 0.10 * m.effects.loyalty, 4: 0.07, 6: 0.05,
          9: 0.04, 10: 0.02, 11: 0.02, 12: 0.01, 13: 0.12}
    rs = math.fsum(rw.values())
    for u, x in rw.items():
        wts[u] += resid * x / rs
    tw = math.fsum(wts)
    out = [0] * len(CLIENTS)
    if n <= 0 or tw <= 0:
        return out
    raw = [n * x / tw for x in wts]
    base = [math.floor(x) for x in raw]
    left = n - sum(base)
    for i in sorted(range(len(raw)), key=lambda i: (-(raw[i] - base[i]), i))[:left]:
        base[i] += 1
    return base


def _key(g, c):
    """The SQL's value key ('v' + value, 'n' = NULL) of client c in dimension g."""
    v = c[g]
    if v is None:
        return "n"
    if g == 0:
        return "v" + str(SVC_HASH[v])
    if g == 3:
        return "v" + norm_program(v)
    if g == 4:
        return "v" + str(USER_ID[v]) + ",0"
    return "v" + v


def _name(g, key, nk, names):
    if key == "o":
        k = nk - C_KEEP
        return "(" + str(k) + (" other)" if k == 1 else " others)")
    if key == "n":
        return _NOV[g]
    return names[key]


def _pct(p):
    if p >= 100.5:
        return "&gt;100%"
    if p < 0.5:
        return "&lt;1%"
    return str(int(ora_round(p, 0))) + "%"


def _sgn(p):
    if p is None:
        return "&mdash;"
    if p < 0:
        return "&minus;" + fmt_num(-p)
    return "+" + fmt_num(p)


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 29_who BEGIN -->"]
    spa = 360 * w.win_hours
    valid = {win.week_offset: win.valid_flag for win in w.windows}
    skip = {win.week_offset: win.skip_reason for win in w.windows}
    curok = valid.get(0) == "Y"
    np_ = sum(1 for k, v in valid.items() if k > 0 and v == "Y")

    # samples per (dimension, key, window) over the valid windows
    cells = [dict() for _ in DIMS]
    names = {}
    for win in w.windows:
        if not win.valid:
            continue
        k = win.week_offset
        for m in w.hours(win.win_start_ts, win.win_end_ts):
            per = _hour_clients(w, m)
            for ci, c in enumerate(CLIENTS):
                if per[ci] <= 0:
                    continue
                for g in range(len(DIMS)):
                    key = _key(g, c)
                    names[key] = norm_program(c[g]) if g == 3 else c[g]
                    d = cells[g].setdefault(key, {})
                    d[k] = d.get(k, 0) + per[ci]

    # the SQL's cut: rank by samples over all windows (ties by key), 40 kept
    xs = []
    nk = {}
    for g in range(len(DIMS)):
        ranked = sorted(cells[g], key=lambda key: (-sum(cells[g][key].values()), key))
        nk[g] = len(ranked)
        for rk, key in enumerate(ranked, 1):
            if rk <= C_KEEP:
                xs.append(dict(g=g, rk=rk, key=key, s=dict(cells[g][key])))
            else:
                o = next((x for x in xs if x["g"] == g and x["key"] == "o"), None)
                if o is None:
                    o = dict(g=g, rk=C_KEEP + 1, key="o", s={})
                    xs.append(o)
                for wk, n in cells[g][key].items():
                    o["s"][wk] = o["s"].get(wk, 0) + n
    memo = {}
    tcs = tps = 0
    for x in xs:
        g = x["g"]
        x["nam"] = _name(g, x["key"], nk[g], names)
        x["ph"] = "O" if x["key"] == "o" else "P" if x["key"] == "n" else "N"
        x["cs"] = x["s"].get(0, 0) if curok else 0
        x["ps"] = sum(n for wk, n in x["s"].items() if wk > 0 and valid.get(wk) == "Y")
        x["ri"] = x["cs"] * np_ - x["ps"]
        x["cur"] = x["cs"] / spa if curok else None
        x["mu"] = x["ps"] / np_ / spa if np_ > 0 else None
        x["rise"] = x["cur"] - x["mu"] if curok and np_ > 0 else None
        pv = [x["s"].get(k, 0) / spa - x["mu"] for k in range(1, w.weeks_back + 1) if valid.get(k) == "Y"]
        x["sd"] = math.sqrt(math.fsum(d * d for d in pv) / (np_ - 1)) if np_ > 1 else None
        x["id"] = anchor_uniq(anchor_id("who", DIMS[g][0] + "-" + x["nam"]), DIMS[g][0] + ":" + x["key"], memo)
        if g == 0:
            tcs += x["cs"]
            tps += x["ps"]
    tcur = tcs / spa if curok else None
    tmu = tps / np_ / spa if np_ > 0 else None
    trise = tcur - tmu if curok and np_ > 0 else None
    attr = curok and np_ >= 3 and bool(xs) and trise >= C_MIN

    def best_of(g, allowed):
        b = None
        for x in xs:
            if x["g"] == g and x["ph"] in allowed and x["rise"] > 0 and (
                    b is None or x["ri"] > b["ri"] or (x["ri"] == b["ri"] and x["rk"] < b["rk"])):
                b = x
        return b

    # the reads-as sentence and the library row text
    opn = False
    if not curok:
        rd = ("The Current window was skipped (" + esc(skip.get(0) or "no valid snapshots")
              + "), so who was active in it is unknown.")
        ls = "Current window skipped"
    elif not xs:
        rd = "No foreground ASH samples in the compared windows."
        ls = "no foreground ASH samples"
    elif np_ < 3:
        rd = (("No valid prior window" if np_ == 0 else "Only " + str(np_) + " valid prior "
               + ("window" if np_ == 1 else "windows"))
              + ": too few to say who added load. Foreground activity in the Current window: "
              + fmt_num(tcur) + "&nbsp;AAS.")
        ls = "too few prior windows (" + str(np_) + ")"
    elif trise <= 0:
        rd = ("Foreground activity did not rise: " + fmt_num(tcur) + "&nbsp;AAS in the Current window against a prior mean of "
              + fmt_num(tmu) + "&nbsp;AAS over " + str(np_) + " valid prior windows.")
        ls = "foreground activity did not rise (" + fmt_num(tcur) + "&nbsp;AAS)"
    elif trise < C_MIN:
        rd = ("Foreground activity rose by only " + _sgn(trise) + "&nbsp;AAS (" + fmt_num(tcur)
              + "&nbsp;AAS against a prior mean of " + fmt_num(tmu) + "): too little to attribute.")
        ls = "foreground activity about normal (" + _sgn(trise) + "&nbsp;AAS)"
    else:
        rd = ("Foreground activity rose by " + _sgn(trise) + "&nbsp;AAS (" + fmt_num(tcur)
              + "&nbsp;AAS in the Current window against a prior mean of " + fmt_num(tmu) + " over "
              + str(np_) + " valid prior windows).")
        ls = _sgn(trise) + "&nbsp;AAS foreground"
        dm, sp, ndom, best, bshr = "", "", 0, None, None
        for g, (_c, word, _hd) in enumerate(DIMS):
            pk = best_of(g, ("N", "P"))
            if pk is None:
                continue
            if best is None or pk["rise"] / trise > bshr:
                best, bshr = pk, pk["rise"] / trise
            if pk["rise"] >= C_DOM * trise:
                ndom += 1
                if ndom == 1:
                    dm += " " + _sgn(pk["rise"]) + " of it came from " + word + " <b>" + esc(pk["nam"]) + "</b>"
                else:
                    dm += "; " + word + " <b>" + esc(pk["nam"]) + "</b> " + _sgn(pk["rise"])
                if ndom <= 2:
                    ls += ("; " if ndom == 1 else ", ") + word + " " + esc(pk["nam"]) + " " + _sgn(pk["rise"]) \
                        + " (" + _pct(pk["rise"] / trise * 100) + ")"
            else:
                sp += ("; " if sp else "") + "the largest " + word + " is <b>" + esc(pk["nam"]) + "</b> " \
                    + _sgn(pk["rise"]) + " (" + _pct(pk["rise"] / trise * 100) + ")"
        if ndom > 0:
            rd += dm + "." + (" Spread over several values: " + sp + "." if sp else "")
            opn = True
        elif best is not None:
            rd += (" The rise is spread: no single value carries half of it; the largest is "
                   + DIMS[best["g"]][1] + " <b>" + esc(best["nam"]) + "</b> " + _sgn(best["rise"])
                   + " (" + _pct(bshr * 100) + ").")
            ls += ("; spread, largest " + DIMS[best["g"]][1] + " " + esc(best["nam"]) + " "
                   + _sgn(best["rise"]) + " (" + _pct(bshr * 100) + ")")

    out.append('<section id="who" class="vw in-s in-a lib' + (" lopen" if opn else "")
               + '" style="--os:19"><h2>Who added the load'
               '<small class="h2sub">Foreground active sessions by service, module, machine, program and user (ASH)</small></h2>')
    out.append(lib_ls("who", ls))
    if curok and xs:
        out.append('<p class="who-tot" data-cur="' + num6(tcur) + '" data-mu="' + num6(tmu)
                   + '" data-rise="' + num6(trise) + '" data-np="' + str(np_) + '">Foreground activity (ASH, '
                   'sessions on CPU or in a non-idle wait): <b>' + fmt_num(tcur) + '&nbsp;AAS</b> in the Current window, '
                   + ('prior mean ' + fmt_num(tmu) + '&nbsp;AAS over ' + str(np_) + ' valid prior '
                      + ('window' if np_ == 1 else 'windows') + ', rise ' + _sgn(trise) + '&nbsp;AAS.'
                      if np_ > 0 else 'no valid prior window.')
                   + '</p>')
    out.append('<p class="who-rd"><b>Reads as:</b> ' + rd + '</p>')

    def row_html(x):
        s = x["rise"] / trise * 100 if attr and x["rise"] > 0 else None
        csv = []
        for k in range(w.weeks_back, -1, -1):
            csv.append(num6(x["s"].get(k, 0) / spa) if valid.get(k) == "Y" else "")
        sh = None if s is None else str(int(min(100, ora_round(s, 0))))
        return ('<tr id="' + x["id"] + '" data-cur="' + num6(x["cur"]) + '" data-mu="' + num6(x["mu"])
                + '" data-rise="' + num6(x["rise"]) + '" data-shr="' + (sh or "") + '"'
                + (' data-ph="' + x["ph"] + '"' if x["ph"] != "N" else "") + '>'
                + '<td class="who-v">' + esc(x["nam"]) + '</td>'
                + '<td class="num" data-w="0"><b>' + fmt_num(x["cur"]) + '</b></td>'
                + '<td class="num">' + fmt_num(x["mu"]) + '</td>'
                + '<td class="num">' + _sgn(x["rise"]) + '</td>'
                + '<td class="num">' + delta_span(x["cur"], x["mu"], None, "Y") + '</td>'
                + '<td class="who-sh">'
                + ('<span class="who-bar"><i style="--w:' + sh + '%"></i></span><span class="who-p">' + _pct(s) + '</span>'
                   if s is not None else '<span class="who-p">&mdash;</span>') + '</td>'
                + '<td class="trend" data-spark="' + ",".join(csv) + '" data-spark-title="'
                + DIMS[x["g"]][2] + ' ' + esc(x["nam"]) + ' (AAS)"></td></tr>')

    if curok and xs:
        out.append('<div class="who-grid">')
        for g, (code, _w, head) in enumerate(DIMS):
            vals = [x for x in xs if x["g"] == g]
            byrise = any(np_ > 0 and x["ri"] > 0 for x in vals)
            if byrise:
                vals.sort(key=lambda x: (-x["ri"], -x["cs"], x["rk"]))
            else:
                vals.sort(key=lambda x: (-x["cs"], x["rk"]))
            shown = 0
            for x in vals:
                if shown < C_SHOW and (not byrise or x["ri"] > 0):
                    shown += 1
            thead = ('<thead><tr><th>' + head + '</th><th class="num" data-w="0">Current (AAS)</th>'
                     '<th class="num">Prior mean</th><th class="num" title="Current minus the mean of the valid prior windows">Rise</th>'
                     '<th class="num">&Delta; vs mean</th>'
                     '<th title="this value&#39;s rise as a share of the rise in all foreground activity">Share of the rise</th>'
                     '<th class="trend">Trend</th></tr></thead>')
            out.append('<div class="who-dim" id="who-d-' + code + '" data-dim="' + code + '">'
                       + '<h3>' + head + '<span class="who-nv">' + str(nk[g])
                       + (' value' if nk[g] == 1 else ' values')
                       + (', the ' + str(C_KEEP) + ' busiest kept' if nk[g] > C_KEEP else '') + '</span></h3>')
            out.append('<table class="who-tbl" data-nocount>' + thead + '<tbody>')
            for x in vals[:shown]:
                out.append(row_html(x))
            out.append('</tbody><tfoot><tr class="who-all" data-cur="' + num6(tcur) + '"><td>All foreground</td>'
                       + '<td class="num" data-w="0"><b>' + fmt_num(tcur) + '</b></td><td class="num">' + fmt_num(tmu)
                       + '</td><td class="num">' + _sgn(trise) + '</td><td class="num">' + delta_span(tcur, tmu, None, "Y")
                       + '</td><td></td><td></td></tr></tfoot></table>')
            if len(vals) > shown:
                out.append('<details class="who-more"><summary>+ ' + str(len(vals) - shown) + ' more</summary>'
                           + '<table class="who-tbl" data-nocount>' + thead + '<tbody>')
                for x in vals[shown:]:
                    out.append(row_html(x))
                out.append('</tbody></table></details>')
            out.append('</div>')
        out.append('</div>')

    out.append('<p class="note who-meth">One ASH sample = 10 s of a foreground session&#39;s time; AAS per window = '
               'samples &times; 10 s &divide; the window&#39;s length. Counted: FOREGROUND sessions on CPU or in a non-idle wait, in the '
               'valid compared windows (a sample in two overlapping windows counts for both), so the total compares with DB time. '
               'Per dimension the ' + str(C_KEEP) + ' values with the most samples are kept and the rest summed as &ldquo;others&rdquo;; '
               'the table lists the values whose time rose, the ' + str(C_SHOW) + ' largest rises first, the rest under &ldquo;+ n more&rdquo;. '
               'A parallel or job slave&#39;s number is folded: (P003) &rarr; (Pnnn). Rise = Current minus the mean of the valid prior '
               'windows. Evidence, not a finding: nothing here is scored or counted.'
               '</p>')
    out.append('</section>')

    # the DB time card's "Who" row: module, else service, machine, user
    if attr:
        pick = None
        for g in (1, 0, 2, 4):
            b = best_of(g, ("N",))
            if b is not None and b["rise"] >= C_CARD * trise:
                pick = b
                break
        if pick is not None:
            word = DIMS[pick["g"]][1]
            out.append('<div id="who-ev-src" hidden><div class="evr ev-who" data-who="' + pick["id"]
                       + '" data-cur="' + num6(pick["cur"]) + '" data-mu="' + num6(pick["mu"]) + '" data-rise="' + num6(pick["rise"])
                       + '" data-trise="' + num6(trise)
                       + '" title="Who added the load (foreground ASH): the ' + word
                       + ' whose active sessions rose most. Its share is of the rise in all foreground activity. Not scored.">'
                       + '<dt>Who</dt><dd><span class="id txt">' + word + ' '
                       + ent(esc(pick["nam"]), pick["id"], "who")
                       + '</span><span class="de">'
                       + nbu(_sgn(pick["rise"]) + ' AAS (' + _pct(pick["rise"] / trise * 100)
                             + ' of the rise in foreground activity)')
                       + '</span></dd><div class="m">' + delta_span(pick["cur"], pick["mu"], None, "Y")
                       + band_span(band_z(pick["cur"], pick["mu"], pick["sd"]), None, "sm", "N", 10)
                       + '<span class="ns">not scored</span></div></div></div>')
            out.append('<script>(function(){var d=document,x=d.getElementById("who-ev-src");if(!x)return;'
                       'var c=d.getElementById("f-dbtime"),dl=c?c.querySelector("dl.ev"):null;'
                       'if(dl){while(x.firstChild)dl.appendChild(x.firstChild);}x.parentNode.removeChild(x);})();</script>')

    out.append("<!-- AWR-SECTION: 29_who END -->")
    return "\n".join(out) + "\n"
