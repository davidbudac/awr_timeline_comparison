"""Twin of sql/24_blocking.sql (Blocking): blocked time per compared window
on the window component (unscored, plain Delta) and the Current window's
holder -> waiter trees, every blocked sample's chain followed to its final
holder inside the same ASH sample.

The model has no blocking, so this twin synthesizes it deterministically
(w.rng): every valid window's blocked samples = the model's row-lock +
TX index contention ASH samples (Application / Concurrency waits, which
by definition have a holder), spread across a few small holders; in the
Current window about 70% of them sit behind one batch session (the
hourly InventorySync MERGE holding INVENTORY rows) with a dozen OLTP
UPDATE inventory sessions behind it and one second-level waiter (an
order-status update waiting on one of them).  The Current blocked total
stays at the model's normal level, so the chain is the story, not the
amount.  The tree builder below is a line-for-line port of the SQL's
flush_sample / kids_of / draw_root.
"""
from __future__ import annotations

from .. import helpers as h
from awrdemo import chrome

C_ROOTS, C_KIDS1, C_KIDS2, C_OPEN = 5, 6, 3, 300

ROW = "enq: TX - row lock contention"
IDX = "enq: TX - index contention"


def _blocked_samples(m) -> int:
    return int(h.ora_round(m.ash_events.get(("Application", ROW), 0)
                           + m.ash_events.get(("Concurrency", IDX), 0), 0))


def _synth_current(w, n0):
    """-> (rows [(sample_id, waiter, holder, event, sql)], nodes {key: info},
    edges {'w|b': (event, sql, obj)})."""
    r = w.rng("s24", "current")
    root = "1,412,3391"
    waiters = []
    used = {412}
    while len(waiters) < 12:
        sid = r.randint(20, 400)
        if sid in used:
            continue
        used.add(sid)
        waiters.append("1," + str(sid) + "," + str(r.randint(1000, 65000)))
    x2 = "1,233,18077"
    chain = int(round(0.7 * n0))
    x2n = 14
    wts = [0.4 + r.random() for _ in waiters]
    tot = sum(wts)
    left = chain - x2n
    cnt = [int(left * x / tot) for x in wts]
    cnt[0] += left - sum(cnt)
    rows = []
    sids = {}
    for k, wk in enumerate(waiters):
        ids = sorted(r.sample(range(1, 361), max(1, cnt[k])))
        sids[wk] = ids
        for s in ids:
            rows.append((s, wk, root, ROW, "2yq9jv7c5hm3d"))
    hold5 = waiters[4]
    for s in sorted(r.sample(sids[hold5], min(x2n, len(sids[hold5])))):
        rows.append((s, x2, hold5, ROW, "s9e4y7mk2cq6v"))
    # the normal background: three small holders
    small = [("1,57,40211", ["1,301,7123", "1,118,22007"], ROW, "s9e4y7mk2cq6v"),
             ("1,190,5530", ["1,77,61002", "1,262,3301"], ROW, "2yq9jv7c5hm3d"),
             ("1,144,9917", ["1,35,1290"], IDX, "k4m8v2bn6ws9e")]
    rest = n0 - len(rows)
    flat = [(hk, wk, ev, sq) for hk, ws, ev, sq in small for wk in ws]
    per = [rest // len(flat)] * len(flat)
    per[0] += rest - sum(per)
    for (hk, wk, ev, sq), n in zip(flat, per):
        for s in sorted(r.sample(range(1, 361), max(0, n))):
            rows.append((s, wk, hk, ev, sq))
    rows.sort(key=lambda t: ("1," + str(t[0]), t[1], t[2]))

    nodes = {root: dict(n=331, who="INVENTORY / InventorySync", ev="db file scattered read",
                        sql="d8s3n5tw2xk7f", obj=None),
             "1,57,40211": dict(n=19, who="ORDERS_APP / OrderService", ev="ON CPU",
                                sql="s9e4y7mk2cq6v", obj=None),
             "1,144,9917": dict(n=6, who="LOYALTY / LoyaltyService", ev="ON CPU",
                                sql="k4m8v2bn6ws9e", obj=None)}
    for wk in waiters + [x2] + [x for _, ws, _, _ in small for x in ws]:
        nodes.setdefault(wk, dict(n=0, who="ORDERS_APP / OrderService", ev=ROW,
                                  sql="2yq9jv7c5hm3d", obj=None))
    for s, wk, hk, ev, sq in rows:
        nodes[wk]["n"] += 1
    objs = {ROW: "INVENTORY.INVENTORY", IDX: "LOYALTY.LOYALTY_LEDGER_PK"}
    edges = {}
    for s, wk, hk, ev, sq in rows:
        ob = "ORDERS_APP.ORDERS" if wk == x2 else objs[ev]
        edges.setdefault(wk + "|" + hk, (ev, sq, ob))
    return rows, nodes, edges


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 24_blocking BEGIN -->"]
    rp = w.rng("s24", "priors")

    # windows: blocked samples, waiting sessions, holders, GLOBAL (none)
    valid, skip = {}, {}
    wblk, wnw, wnb = {}, {}, {}
    rows, nodes, edges = [], {}, {}
    for win in w.windows:
        k = win.week_offset
        valid[k] = win.valid_flag
        skip[k] = win.skip_reason
        wblk[k] = wnw[k] = wnb[k] = 0
        if not win.valid:
            continue
        m = w.window_metrics(win)
        n = _blocked_samples(m)
        if k == 0:
            rows, nodes, edges = _synth_current(w, n)
            wblk[0] = len(rows)
            wnw[0] = len({t[1] for t in rows})
            wnb[0] = len({t[2] for t in rows})
        else:
            wblk[k] = n
            wnw[k] = rp.randint(7, 15)
            wnb[k] = rp.randint(3, 6)

    pairs, cur, nprior, vals = {}, None, 0, []
    for k in sorted(valid):
        if valid[k] == "Y":
            pairs[k] = wblk[k] * 10
            if k == 0:
                cur = wblk[0] * 10
            else:
                vals.append(wblk[k] * 10)
    mu, sd, nprior = h.mean_sd(vals)
    curok = cur is not None
    cur_s = cur or 0

    # ---- the path tree (port of flush_sample) ---------------------------
    pa = []                      # dicts: key, par, lv, s, bs, bn, kids, cyc
    pid, seen, rev, rsql = {}, set(), {}, {}

    def node_id(par, key):
        kk = str(par) + ">" + key
        if kk in pid:
            return pid[kk]
        pa.append(dict(key=key, par=par, lv=0 if par == 0 else pa[par - 1]["lv"] + 1,
                       s=0, bs=0, bn=0, kids=[], cyc="N"))
        i = len(pa)
        if par > 0:
            pa[par - 1]["kids"].append(i)
        pid[kk] = i
        return i

    def flush(buf):
        m = {wk: hk for _, wk, hk, _, _ in buf}
        for _, wk, hk, ev, sq in buf:
            ch, vis, b, cyc = [wk], {wk}, hk, False
            while True:
                if b in vis:
                    cyc = True
                    break
                ch.append(b)
                vis.add(b)
                if b not in m or len(ch) >= 50:
                    break
                b = m[b]
            n = len(ch)
            d = n - 1
            ids = {0: node_id(0, ch[n - 1])}
            if cyc:
                pa[ids[0] - 1]["cyc"] = "Y"
            for lv in range(1, min(d, 2) + 1):
                ids[lv] = node_id(ids[lv - 1], ch[n - 1 - lv])
            if d <= 2:
                pa[ids[d] - 1]["s"] += 1
            for lv in range(0, min(d - 1, 2) + 1):
                p = pa[ids[lv] - 1]
                p["bs"] += 1
                x = (ids[lv], wk)
                if x not in seen:
                    seen.add(x)
                    p["bn"] += 1
            if ev:
                rev[(ids[0], ev)] = rev.get((ids[0], ev), 0) + 1
            if sq:
                rsql[(ids[0], sq)] = rsql.get((ids[0], sq), 0) + 1

    buf, key = [], None
    for t in rows:
        sk = "1," + str(t[0])
        if key is None or sk != key:
            flush(buf)
            buf, key = [], sk
        buf.append(t)
    flush(buf)
    insts = {x.split(",")[0] for t in rows for x in (t[1], t[2])}
    multi = len(insts) > 1

    def k_lab(key):
        p = key.split(",")
        return "SID " + p[1] + "," + p[2] + ("@" + p[0] if multi else "")

    def who(key):
        return nodes[key]["who"] if key in nodes and nodes[key]["n"] > 0 else None

    def dur_txt(s):
        if s is None:
            return "&mdash;"
        if s < 120:
            return h.to_char_int(s) + " s"
        if s < 600:
            return h.to_char_fixed(h.ora_round(s / 60, 1), 1) + " min"
        if s < 7200:
            return h.to_char_int(s / 60) + " min"
        return h.to_char_fixed(h.ora_round(s / 3600, 1), 1) + " h"

    # roots
    roots = []
    for i, p in enumerate(pa, 1):
        if p["lv"] == 0:
            roots.append(dict(key=p["key"], id=i, tot=p["bs"], cnt=p["bn"], cyc=p["cyc"], ev=None, sql=None))
    best = {}
    for (i, ev), n in sorted(rev.items()):
        if n > best.get(i, -1):
            best[i] = n
            next(r for r in roots if r["id"] == i)["ev"] = ev
    best = {}
    for (i, sq), n in sorted(rsql.items()):
        if n > best.get(i, -1):
            best[i] = n
            next(r for r in roots if r["id"] == i)["sql"] = sq
    order = list(range(len(roots)))
    for a in range(len(order)):
        for b in range(a + 1, len(order)):
            ra, rb = roots[order[a]], roots[order[b]]
            if rb["tot"] > ra["tot"] or (rb["tot"] == ra["tot"] and rb["key"] < ra["key"]):
                order[a], order[b] = order[b], order[a]
    rk = [roots[i] for i in order]

    def kids_of(i):
        arr = list(pa[i - 1]["kids"])
        for a in range(len(arr)):
            for b in range(a + 1, len(arr)):
                pa_, pb = pa[arr[a] - 1], pa[arr[b] - 1]
                if (pb["s"] + pb["bs"] > pa_["s"] + pa_["bs"]
                        or (pb["s"] + pb["bs"] == pa_["s"] + pa_["bs"] and pb["key"] < pa_["key"])):
                    arr[a], arr[b] = arr[b], arr[a]
        return arr

    js, er = [], []
    di = [0]

    def js_node(i, par, r, deep):
        p = pa[i - 1]
        k = p["key"]
        wh = who(k)
        hk = ev = sq = ob = None
        if p["lv"] == 0:
            if k in nodes and nodes[k]["n"] > 0:
                ev, sq, ob = nodes[k]["ev"], nodes[k]["sql"], nodes[k]["obj"]
        else:
            hk = pa[p["par"] - 1]["key"]
            if k + "|" + hk in edges:
                ev, sq, ob = edges[k + "|" + hk]
        di[0] += 1
        js.append(("," if di[0] > 1 else "")
                  + '{"i":' + str(di[0]) + ',"p":' + str(par) + ',"lv":' + str(p["lv"]) + ',"r":' + str(r)
                  + ',"k":"' + ("r" if p["lv"] == 0 else "w") + '","id":"' + k_lab(k) + '"'
                  + ',"who":"' + h.json_escape(wh) + '","ns":' + ("1" if wh is None else "0")
                  + ',"sql":"' + h.json_escape(sq) + '","ev":"' + h.json_escape(ev) + '"'
                  + ',"obj":"' + h.json_escape(ob) + '"'
                  + ',"s":' + str(p["s"] * 10)
                  + ',"bn":' + str(p["bn"]) + ',"bs":' + str(p["bs"] * 10)
                  + ',"cyc":' + ("1" if p["cyc"] == "Y" else "0")
                  + ',"deep":' + ("1" if deep else "0") + '}')
        if p["lv"] > 0:
            er.append('<tr><td>' + k_lab(k)
                      + (' <span class="bk-who">' + h.esc(wh) + '</span>' if wh is not None else '')
                      + '</td><td>' + k_lab(hk) + '</td>'
                      + '<td class="num">' + str(p["lv"]) + '</td>'
                      + '<td class="num">' + h.fmt_int(p["s"] * 10) + '</td>'
                      + '<td>' + h.esc(ev) + '</td>'
                      + '<td>' + (h.ent(sq, h.anchor_id("sq-elapsed", sq), "sql") if sq else '') + '</td>'
                      + '<td>' + h.esc(ob) + '</td>'
                      + '<td class="num">' + (h.fmt_int(p["bn"]) + ' &middot; ' + h.fmt_int(p["bs"] * 10) + ' s'
                                              if p["bn"] > 0 else '') + '</td></tr>')

    def js_more(par, lv, r, n, s):
        di[0] += 1
        js.append(',{"i":' + str(di[0]) + ',"p":' + str(par) + ',"lv":' + str(lv) + ',"r":' + str(r)
                  + ',"k":"m","n":' + str(n) + ',"s":' + str(s * 10) + '}')

    for a, ro in enumerate(rk[:C_ROOTS], 1):
        js_node(ro["id"], 0, a, False)
        vroot = di[0]
        k1 = kids_of(ro["id"])
        mn = ms = 0
        for x, c1 in enumerate(k1, 1):
            if x <= C_KIDS1:
                js_node(c1, vroot, a, False)
                d1 = di[0]
                k2 = kids_of(c1)
                for c2 in k2[:C_KIDS2]:
                    js_node(c2, d1, a, pa[c2 - 1]["bn"] > 0)
                if len(k2) > C_KIDS2:
                    xn = sum(1 + pa[c - 1]["bn"] for c in k2[C_KIDS2:])
                    xs = sum(pa[c - 1]["s"] + pa[c - 1]["bs"] for c in k2[C_KIDS2:])
                    js_more(d1, 2, a, xn, xs)
            else:
                mn += 1 + pa[c1 - 1]["bn"]
                ms += pa[c1 - 1]["s"] + pa[c1 - 1]["bs"]
        if len(k1) > C_KIDS1:
            js_more(vroot, 1, a, mn, ms)

    # reads-as + library row text
    if nprior >= 3:
        if mu == 0:
            ratio = ("none in the " + str(nprior) + " prior windows" if cur_s > 0
                     else "none in the " + str(nprior) + " prior windows either")
        elif cur_s / mu >= 2:
            q = cur_s / mu
            ratio = ((h.to_char_fixed(q, 1) if q < 100 else h.to_char_fixed(h.ora_round(q, 0), 0)) + "&times; the prior mean for this hour ("
                     + dur_txt(mu) + ")")
        else:
            ratio = (("&#9650; " if cur_s >= mu else "&#9660; ")
                     + h.to_char_fixed(abs(cur_s - mu) / mu * 100, 0)
                     + "% vs the prior mean for this hour (" + dur_txt(mu) + ")")
    else:
        ratio = "too few prior windows (" + str(nprior) + ") to call it normal or not"

    if not curok:
        rd = ("the Current window was skipped (" + h.esc(skip.get(0) or "no valid snapshots")
              + "), so its blocking is unknown"
              + ("; the " + str(nprior) + " valid prior windows averaged " + dur_txt(mu) + " of blocked time"
                 if nprior > 0 else "") + ".")
        ls = "Current window skipped"
    elif cur_s == 0 or not rk:
        rd = ("no blocking sampled in the Current window"
              + ("; the " + str(nprior) + " prior windows averaged " + dur_txt(mu) if nprior > 0 and mu > 0
                 else "; none in the " + str(nprior) + " prior windows either" if nprior > 0 else "") + ".")
        ls = "no blocking sampled in the Current window"
    else:
        t = rk[0]
        wh = who(t["key"])
        rd = ("1 session (" + k_lab(t["key"]) + (", " + h.esc(wh) if wh is not None else ", not sampled")
              + ") held " + str(t["cnt"]) + (" session" if t["cnt"] == 1 else " sessions")
              + " for " + dur_txt(t["tot"] * 10) + " in total"
              + (", mostly on " + h.esc(t["ev"]) if t["ev"] else "")
              + ("; " + str(len(rk) - 1) + " other " + ("holder" if len(rk) == 2 else "holders") + ": "
                 + dur_txt((cur_s / 10 - t["tot"]) * 10) if len(rk) > 1 else "")
              + ". All blocked time in the Current window: " + dur_txt(cur_s) + ", " + ratio + ".")
        ls = (dur_txt(cur_s) + " blocked, " + dur_txt(t["tot"] * 10) + " behind " + k_lab(t["key"])
              + (" (" + h.esc(wh) + ")" if wh is not None else "") + "; " + ratio)
    vopen = curok and cur_s >= C_OPEN and (nprior < 3 or mu == 0 or cur_s >= 2 * mu)

    # ---- markup ---------------------------------------------------------
    out.append('<section id="blocking" class="vw in-s in-a lib' + (" lopen" if vopen else "")
               + '" style="--os:14"><h2>Blocking'
               '<small class="h2sub">Who held the sessions that waited, and is this much blocking normal for this hour</small></h2>')
    out.append(h.lib_ls("blocking", ls))
    lab = ('<div class="l" role="rowheader"><span class="big">'
           + (h.fmt_num(cur_s / 60) if curok else '&ndash;')
           + '<span class="u">min</span></span>'
           '<span class="sub">prior mean ' + ('&mdash;' if mu is None else h.fmt_num(mu / 60) + ' min')
           + '</span></div>')
    gut = ('<div class="g" role="cell"><div class="gl1">'
           + h.delta_span(cur, mu, None, "Y").replace('class="d ', 'class="d d1 ')
           + '</div><span class="bk-ns">not scored</span></div>')
    out.append('<div class="panel bk-strip"><div class="wg fit hov"' + h.wg_attr(w)
               + ' role="table" aria-label="Blocked time per compared window">')
    out.append(h.wg_ruler_put(w, None, '<span class="ct">Blocked time per window</span>'
                              '<span class="cs">minutes sessions waited behind a holder</span>',
                              '<span class="gt">vs prior mean</span>'))
    out.append(h.wg_bars(w, pairs, 1 / 60, mu, sd, None, lab, gut, "bk-bars"))
    out.append('</div></div>')
    if curok and rk:
        out.append('<div class="bk-lg" aria-hidden="true">'
                   '<span><i class="bk-k bk-kr"></i>final holder (waits on no one)</span>'
                   '<span><i class="bk-k bk-kw"></i>waiting session</span>'
                   '<span><i class="bk-k bk-kn"></i>holder not sampled</span>'
                   '<span><i class="bk-k bk-ke"></i>arrow from holder to waiter, width = seconds behind it</span></div>')
        out.append('<div class="bk-plot" id="bk-plot"><p class="note bk-nojs">The graph needs JavaScript; '
                   'the tables below hold every number.</p></div>')
    out.append('<p class="bk-rd"><b>Reads as:</b> ' + rd[:1].upper() + rd[1:] + '</p>')
    out.append('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.blocking={"cur":'
               + (str(cur_s) if curok else 'null')
               + ',"roots":' + str(len(rk)) + ',"shown":' + str(min(len(rk), C_ROOTS)) + ',"nodes":[')
    out.extend(js)
    out.append(']};</script>')

    if curok and rk:
        out.append('<table class="bk-tbl" id="bk-holders"><caption>Holders in the Current window, '
                   'by blocked time behind them</caption><thead><tr><th>#</th><th>Holder</th><th>What it was doing</th>'
                   '<th class="num">Sessions held</th><th class="num">Blocked s</th><th>Top event</th>'
                   '<th>Top waiter SQL</th></tr></thead><tbody>')
        for a, ro in enumerate(rk[:50], 1):
            wh = who(ro["key"])
            nd = nodes.get(ro["key"])
            out.append('<tr><td class="num">' + str(a) + '</td><td>' + k_lab(ro["key"])
                       + (' <span class="imm" title="a chain came back to a session already in it '
                          '(a cycle, e.g. a deadlock caught by the sampler); it ends here">cycle</span>'
                          if ro["cyc"] == "Y" else '')
                       + (' <span class="bk-who">' + h.esc(wh) + '</span>' if wh is not None else '')
                       + '</td><td>'
                       + ('holder not sampled (idle in transaction?)' if wh is None
                          else h.esc(nd["ev"])
                          + (', ' + h.ent(nd["sql"], h.anchor_id("sq-elapsed", nd["sql"]), "sql") if nd["sql"] else '')
                          + ', sampled ' + h.fmt_int(nd["n"] * 10) + ' s')
                       + '</td><td class="num">' + h.fmt_int(ro["cnt"])
                       + '</td><td class="num">' + h.fmt_int(ro["tot"] * 10)
                       + '</td><td>' + h.esc(ro["ev"])
                       + '</td><td>' + (h.ent(ro["sql"], h.anchor_id("sq-elapsed", ro["sql"]), "sql")
                                        if ro["sql"] else '')
                       + '</td></tr>')
        out.append('</tbody></table>')
        if len(rk) > 50:
            out.append('<p class="note">' + str(len(rk) - 50) + ' smaller holders not listed.</p>')
        out.append('<details class="bk-fold"><summary>Every waiter the graph draws ('
                   + str(len(er)) + ')</summary><table class="bk-tbl" id="bk-edges"><thead><tr><th>Waiter</th><th>Blocked by</th>'
                   '<th class="num">Level</th><th class="num">s behind it</th><th>Event</th>'
                   '<th>SQL</th><th>Object</th><th class="num">Behind this waiter</th></tr></thead><tbody>')
        out.extend(er)
        out.append('</tbody></table></details>')

    out.append('<details class="bk-fold"><summary>Blocked time per window</summary>'
               '<table class="bk-tbl" id="bk-windows"><thead><tr><th>Window</th><th class="num">Blocked s</th>'
               '<th class="num">Blocked min</th><th class="num">Waiting sessions</th><th class="num">Holders</th>'
               '<th class="num" title="samples whose holder is on another RAC instance, not known by session">GLOBAL samples</th>'
               '</tr></thead><tbody>')
    for k in range(0, w.weeks_back + 1):
        if valid.get(k) == "Y":
            out.append('<tr><td data-w="' + str(k) + '">' + h.wg_title(w, k) + ' <span class="bk-off">'
                       + h.wg_off(w, k) + '</span></td><td class="num" data-w="' + str(k) + '">'
                       + h.fmt_int(wblk[k] * 10)
                       + '</td><td class="num">' + h.fmt_num(wblk[k] * 10 / 60)
                       + '</td><td class="num">' + h.fmt_int(wnw[k]) + '</td><td class="num">' + h.fmt_int(wnb[k])
                       + '</td><td class="num">' + h.fmt_int(0) + '</td></tr>')
        else:
            out.append('<tr class="bk-skip"><td data-w="' + str(k) + '">' + h.wg_title(w, k) + ' <span class="bk-off">'
                       + h.wg_off(w, k) + '</span></td><td colspan="5">skipped: '
                       + h.esc(skip.get(k) or "no snapshots") + '</td></tr>')
    out.append('</tbody></table></details>')
    out.append('<p class="note bk-meth">One ASH sample = 10 s of a session&#39;s time. Counted: samples '
               'whose holder is known by session (status VALID), any event (row locks, but also log file switches '
               'behind LGWR or buffer busy waits). Holders on another RAC instance that ASH cannot name (GLOBAL) are '
               'only counted in the per-window table. Not scored: no metric policy line fits.</p>')
    out.append('</section>')
    out.append(chrome.lib_script('js_blocking.plsql'))
    out.append("<!-- AWR-SECTION: 24_blocking END -->")
    return "\n".join(out)
