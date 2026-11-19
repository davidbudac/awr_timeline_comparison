"""Twin of sql/22_wait_histogram.sql (Wait latency histograms).

The model has no DBA_HIST_EVENT_HISTOGRAM, so the per-bucket counts are
synthesized here, deterministically (w.rng): for every event and valid
window, the model's total_waits spread over Oracle's power-of-two buckets
by a log-normal whose mean is the model's average wait
(time_waited_us / total_waits).  The User I/O event behind the demo's I/O
finding (db file sequential read) gets a slow tail in the windows after
Release 4.2: 6% of its reads move to a ~5 ms mode while the body speeds up
so the mean still equals the model's average -- the average barely moves,
the shape does.  Everything downstream mirrors the SQL emitter."""
from __future__ import annotations

import math
from decimal import ROUND_HALF_UP, Decimal

from awrdemo import chrome
from awrdemo import helpers as h
from awrdemo.sections import _waits as C

TAG = "22_wait_histogram"
MIN_N = 30
KMIN, KMAX = -10, 40
MU_HTML = "&micro;"
MU_JS = "\\" + "u00b5"
TAIL_EVENT = "db file sequential read"


# ---- twins of the section's local PL/SQL functions ---------------------

def _round(p, dec):
    return Decimal(repr(float(p))).quantize(Decimal(1).scaleb(-dec), rounding=ROUND_HALF_UP)


def jn(p, dec):
    if p is None:
        return "null"
    s = format(_round(p, dec), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    if s in ("-0", ""):
        s = "0"
    return s


def pc(p):
    if p is None:
        return "&mdash;"
    return format(_round(p * 100, 1), "f") + "%"


def bnd(k, mu):
    if k < 0:
        return str(int(_round(1000 * 2.0 ** k, 0))) + " " + mu + "s"
    if k < 10:
        return str(2 ** k) + " ms"
    return str(2 ** (k - 10)) + " s"


def brng(k, mu):
    a, b = bnd(k - 1, mu), bnd(k, mu)
    if k <= KMIN:
        return "under " + b
    if a[a.index(" "):] == b[b.index(" "):]:
        a = a[:a.index(" ")]
    return a + "-" + b


def fms(p):
    if p is None:
        return "&mdash;"
    if p >= 1000:
        return h.fmt_num(p / 1000) + " s"
    return h.fmt_num(p) + " ms"


def rx(p):
    if p >= 10:
        t = h.fmt_int(round(p))
    elif p >= 1:
        t = format(_round(p, 1), "f")
    else:
        t = format(_round(p, 2), "f")
    return t + "x"


def mid(k):
    return (0.5 if k <= KMIN else 0.75) * 2.0 ** min(k, 22)


# ---- synthetic DBA_HIST_EVENT_HISTOGRAM --------------------------------

def _cdf(x_ms, mu, s):
    if x_ms <= 0:
        return 0.0
    return 0.5 * (1 + math.erf((math.log(x_ms) - mu) / (s * math.sqrt(2))))


def _probs(avg_ms, s, tail):
    """Bucket probabilities (k -> p) of a log-normal (optionally + a tail
    mode) whose mean is avg_ms."""
    parts = []
    if tail:
        f, tmed, ts = 0.06, 5.0, 0.35
        tmean = tmed * math.exp(ts * ts / 2)
        body = max(avg_ms * 0.25, (avg_ms - f * tmean) / (1 - f))
        parts.append((1 - f, math.log(body) - s * s / 2, s))
        parts.append((f, math.log(tmed), ts))
    else:
        parts.append((1.0, math.log(avg_ms) - s * s / 2, s))
    out = {}
    for k in range(KMIN, KMAX + 1):
        hi = 2.0 ** k
        lo = 0.0 if k == KMIN else 2.0 ** (k - 1)
        p = 0.0
        for wt, mu, sg in parts:
            p += wt * ((1.0 if k == KMAX else _cdf(hi, mu, sg)) - _cdf(lo, mu, sg))
        out[k] = p
    return out


def _counts(n, probs):
    """Largest-remainder integer split of n waits over the buckets."""
    raw = {k: n * p for k, p in probs.items()}
    base = {k: int(math.floor(v)) for k, v in raw.items()}
    left = n - sum(base.values())
    for k in sorted(raw, key=lambda k: (-(raw[k] - base[k]), k))[:max(0, left)]:
        base[k] += 1
    return {k: v for k, v in base.items() if v > 0}


def histograms(w, deltas, events):
    """{(event, week_offset): {k: waits}} for every VALID window."""
    release = next((t for t, l in w.markers if l == "Release 4.2"), None)
    out = {}
    for ev in events:
        r0 = w.rng("waithist", ev)
        s_ev = 0.5 if ev == TAIL_EVENT else 0.6 + 0.4 * r0.random()
        for k, d in enumerate(deltas):
            if d is None or ev not in d:
                continue
            _, waits, us = d[ev]
            n = int(round(waits))
            if n <= 0 or us <= 0:
                continue
            r = w.rng("waithist", ev, k)
            s = s_ev * (1 + 0.05 * r.gauss(0, 1))
            tail = (ev == TAIL_EVENT and release is not None
                    and w.windows[k].win_end_ts > release)
            out[(ev, k)] = _counts(n, _probs(us / waits / 1000, s, tail))
    return out


# ---- the emitter ---------------------------------------------------------

def emit(w) -> str:
    out = ['<!-- AWR-SECTION: ' + TAG + ' BEGIN -->']
    cap = min(8, w.top_n)

    deltas = C.window_deltas(w, lambda m: m.fg_waits)
    offs = [k for k, d in enumerate(deltas) if d is not None]
    cur_ok = 0 in offs
    n_prior = len([k for k in offs if k > 0])

    # section 04's Current ranking: RANK by time waited, rnk <= top_n, at most 8
    evs = []
    if cur_ok:
        cur = {ev: t for ev, t in deltas[0].items() if t[2] > 0}
        rank = {ev: 1 + sum(1 for x in cur.values() if x[2] > t[2]) for ev, t in cur.items()}
        pick = sorted((ev for ev in cur if rank[ev] <= w.top_n), key=lambda ev: (-cur[ev][2], ev))[:8]
        for ev in pick:
            av = [deltas[k][ev][2] / deltas[k][ev][1] / 1000 for k in offs
                  if k > 0 and ev in deltas[k] and deltas[k][ev][1] > 0]
            evs.append({"name": ev, "cls": cur[ev][0], "waits": cur[ev][1], "us": cur[ev][2],
                        "avg_nrm": (math.fsum(av) / len(av)) if av else None})
    evs = evs[:cap]
    hist = histograms(w, deltas, [e["name"] for e in evs])

    cards, rows, jsons = [], [], []
    changed = []
    n_chg = n_same = n_vol = n_few = n_nop = 0
    for e_i, e in enumerate(evs):
        cc = {k: 0.0 for k in range(KMIN, KMAX + 1)}
        ct, nc, nt = dict(cc), dict(cc), dict(cc)
        lc, hc, lt, ht = ({k: None for k in cc} for _ in range(4))
        np_ = 0
        sum_n = 0.0
        cur_n = cur_t = 0.0
        for o in offs:
            hb = hist.get((e["name"], o), {})
            wc = {k: float(hb.get(k, 0)) for k in cc}
            wt = {k: wc[k] * mid(k) for k in cc}
            tot = math.fsum(wc.values())
            ttot = math.fsum(wt.values())
            if o == 0:
                cc, ct = wc, wt
                cur_n, cur_t = tot, ttot
            else:
                sum_n += tot
                if tot >= MIN_N:
                    np_ += 1
                    for k in cc:
                        nc[k] += wc[k] / tot
                        nt[k] += wt[k] / ttot
                        lc[k] = min(1 if lc[k] is None else lc[k], wc[k] / tot)
                        hc[k] = max(0 if hc[k] is None else hc[k], wc[k] / tot)
                        lt[k] = min(1 if lt[k] is None else lt[k], wt[k] / ttot)
                        ht[k] = max(0 if ht[k] is None else ht[k], wt[k] / ttot)
        if np_ > 0:
            for k in cc:
                nc[k] /= np_
                nt[k] /= np_
        nrm_n = sum_n / n_prior if n_prior > 0 else None
        ratio = cur_n / nrm_n if nrm_n else None

        cp50 = cp95 = np50 = np95 = None
        s_cc = s_nc = 0.0
        for k in range(KMIN, KMAX + 1):
            s_cc += cc[k]
            s_nc += nc[k]
            if cur_n > 0:
                if cp50 is None and s_cc >= 0.5 * cur_n:
                    cp50 = k
                if cp95 is None and s_cc >= 0.95 * cur_n:
                    cp95 = k
            if np_ > 0:
                if np50 is None and s_nc >= 0.5 - 1e-9:
                    np50 = k
                if np95 is None and s_nc >= 0.95 - 1e-9:
                    np95 = k

        M = MU_HTML
        if cur_n < MIN_N:
            cls, glyph, word = "few", "&middot;", "too few waits"
            head = "too few waits to compare shapes (" + h.fmt_int(cur_n) + " in the Current window)"
            n_few += 1
        elif np_ < 2:
            cls, glyph, word = "nop", "&middot;", "no prior shape"
            head = (("no prior window" if np_ == 0 else "only one prior window")
                    + " with " + str(MIN_N) + " or more waits: too little history to call a change")
            n_nop += 1
        elif cp95 - np95 >= 2 and abs(cp50 - np50) <= 1:
            cls, glyph, word = "tail", "&#9650;", "slow tail"
            head = ("a slow tail appeared: p95 moved from the " + brng(np95, M) + " bucket to the "
                    + brng(cp95, M) + " bucket, the median stayed at " + brng(cp50, M))
        elif cp50 - np50 >= 2:
            cls, glyph, word = "up", "&#9650;", "shifted slower"
            head = ("the whole distribution moved slower: median from " + brng(np50, M) + " to "
                    + brng(cp50, M) + ", p95 from " + brng(np95, M) + " to " + brng(cp95, M))
        elif np50 - cp50 >= 2:
            cls, glyph, word = "down", "&#9660;", "shifted faster"
            head = ("the whole distribution moved faster: median from " + brng(np50, M) + " to "
                    + brng(cp50, M) + ", p95 from " + brng(np95, M) + " to " + brng(cp95, M))
        elif np95 - cp95 >= 2:
            cls, glyph, word = "gone", "&#9660;", "tail gone"
            head = ("the slow tail went away: p95 moved from the " + brng(np95, M) + " bucket to the "
                    + brng(cp95, M) + " bucket")
        elif ratio is not None and (ratio >= 2 or ratio <= 0.5):
            cls, glyph, word = "vol", "&times;", "volume only"
            head = ("shape unchanged, " + rx(ratio) + " " + ("more waits" if ratio >= 2 else "the waits")
                    + " (p95 in the " + brng(cp95, M) + " bucket)")
            n_vol += 1
        else:
            cls, glyph, word = "same", "=", "shape unchanged"
            head = "shape unchanged: median " + brng(cp50, M) + ", p95 " + brng(cp95, M)
            n_same += 1
        if cls in ("tail", "up", "down", "gone"):
            n_chg += 1
            if n_chg <= 2:
                lead = {"tail": "a slow tail appeared (p95 ", "up": "every wait got slower (median ",
                        "down": "every wait got faster (median "}.get(cls, "the slow tail went away (p95 ")
                pair = (bnd(np95, M) + " &rarr; " + bnd(cp95, M)) if cls in ("tail", "gone") \
                    else (bnd(np50, M) + " &rarr; " + bnd(cp50, M))
                changed.append("<b>" + h.esc(e["name"]) + "</b>: " + lead + pair + ")")

        # display range
        lo = hi = None
        for k in range(KMIN, KMAX + 1):
            m = max(cc[k] / cur_n if cur_n > 0 else 0, ct[k] / cur_t if cur_t > 0 else 0,
                    nc[k], nt[k], hc[k] or 0, ht[k] or 0)
            if m >= 0.002 and lo is None:
                lo = k
            if m >= 0.001:
                hi = k
        lo = 0 if lo is None else lo
        hi = max(lo if hi is None else hi, lo)
        if cp50 is not None:
            lo, hi = min(lo, cp50), max(hi, cp95)
        if np50 is not None:
            lo, hi = min(lo, np50), max(hi, np95)
        if hi - lo > 19:
            lo = hi - 19
        while hi - lo < 7:
            if hi < KMAX:
                hi += 1
            else:
                lo -= 1

        aid = h.anchor_id("we", e["name"])
        labs, rngs = [], []
        jcc, jct, jnc, jnt, jlc, jhc, jlt, jht = ([] for _ in range(8))
        for b in range(lo, hi + 1):
            ks = range(KMIN if b == lo else b, (KMAX if b == hi else b) + 1)
            s = [math.fsum(d[k] or 0 for k in ks) for d in (cc, ct, nc, nt, lc, hc, lt, ht)]
            s[5], s[7] = min(s[5], 1), min(s[7], 1)   # LEAST(s_hc, 1) / LEAST(s_ht, 1)
            first = b == lo
            labs.append('"' + ("<" + bnd(b, MU_JS) if b == lo else
                               ">" + bnd(b - 1, MU_JS) if b == hi else bnd(b, MU_JS)) + '"')
            rngs.append('"' + ("under " + bnd(b, MU_JS) if b == lo else
                               "at least " + bnd(b - 1, MU_JS) if b == hi else brng(b, MU_JS)) + '"')
            jcc.append(jn(s[0], 0)); jct.append(jn(s[1], 3))
            jnc.append(jn(s[2], 5)); jnt.append(jn(s[3], 5))
            jlc.append(jn(s[4], 5)); jhc.append(jn(s[5], 5))
            jlt.append(jn(s[6], 5)); jht.append(jn(s[7], 5))
            name = h.esc(e["name"])
            rows.append('<tr' + (' class="whfirst"' if first else '') + '><td>'
                        + (h.ent(name, aid, "event") if first else '<span class="whdim">' + name + '</span>')
                        + '</td><td>'
                        + ("under " + bnd(b, M) if b == lo else
                           "at least " + bnd(b - 1, M) if b == hi else brng(b, M))
                        + '</td><td class="num" data-w="0">' + h.fmt_int(s[0])
                        + '</td><td class="num" data-w="0">' + (pc(s[0] / cur_n) if cur_n > 0 else '&mdash;')
                        + '</td><td class="num">' + (pc(s[2]) if np_ > 0 else '&mdash;')
                        + '</td><td class="num">' + (pc(s[4]) + '&ndash;' + pc(s[5]) if np_ > 0 else '&mdash;')
                        + '</td><td class="num" data-w="0">' + (pc(s[1] / cur_t) if cur_t > 0 else '&mdash;')
                        + '</td><td class="num">' + (pc(s[3]) if np_ > 0 else '&mdash;')
                        + '</td></tr>')

        avg_cur = e["us"] / e["waits"] / 1000 if e["waits"] > 0 else None
        sub = ("avg " + (fms(e["avg_nrm"]) + " &rarr; " if e["avg_nrm"] is not None else "")
               + fms(avg_cur) + " &middot; " + h.fmt_int(cur_n) + " waits"
               + (" (" + rx(ratio) + " normal)" if ratio is not None else "")
               + (" &middot; normal from " + str(np_) + " prior window" + ("s" if np_ > 1 else "")
                  if np_ > 0 else ""))
        cards.append('<article class="whc whc-' + cls + '" data-i="' + str(e_i) + '">'
                     + '<h3>' + h.ent(h.esc(e["name"]), aid, "event")
                     + ' <small>' + h.esc(e["cls"]) + '</small></h3>'
                     + '<p class="whs">' + sub + '</p>'
                     + '<p class="whw"><span class="whk"><i>' + glyph + '</i> ' + word + '</span> '
                     + head + '</p>'
                     + '<div class="whp"></div></article>')
        jsons.append('{"n":"' + h.json_escape(e["name"]) + '","cl":"' + h.json_escape(e["cls"])
                     + '","k":"' + cls + '","nc":' + jn(cur_n, 0) + ',"nn":' + jn(nrm_n, 1)
                     + ',"np":' + str(np_)
                     + ',"lab":[' + ",".join(labs) + '],"rg":[' + ",".join(rngs) + ']'
                     + ',"cc":[' + ",".join(jcc) + '],"ct":[' + ",".join(jct) + ']'
                     + ',"mc":[' + ",".join(jnc) + '],"mt":[' + ",".join(jnt) + ']'
                     + ',"lc":[' + ",".join(jlc) + '],"hc":[' + ",".join(jhc) + ']'
                     + ',"lt":[' + ",".join(jlt) + '],"ht":[' + ",".join(jht) + ']}')

    out.append('<section id="wait-hist" class="vw in-s in-a lib' + (' lopen' if n_chg > 0 else '')
               + '" style="--os:12"><h2>Wait latency histograms'
               '<small class="h2sub">The shape of each wait the averages hide</small></h2>')
    if not cur_ok:
        out.append('<p class="note">The Current window was skipped (see Windows), '
                   'so there is no Current shape to compare.</p>')
        out.append(h.lib_ls('wait-hist', 'Current window skipped'))
    elif not evs:
        out.append('<p class="note">No foreground wait time in the Current window.</p>')
        out.append(h.lib_ls('wait-hist', 'no foreground waits in the Current window'))
    else:
        ns = n_same + n_vol
        if n_chg > 0:
            reads = ("; ".join(changed)
                     + ("; " + str(n_chg - 2) + " more changed shape" if n_chg > 2 else "")
                     + ("; " + str(ns) + " other event" + ("s" if ns > 1 else "") + " unchanged in shape"
                        if ns > 0 else ""))
        elif ns > 0:
            reads = ("the top " + (str(ns) + " " if ns > 1 else "") + "wait" + ("s" if ns > 1 else "")
                     + " kept " + ("their" if ns > 1 else "its") + " shape"
                     + (" (" + str(n_vol) + " changed only in volume)" if n_vol > 0 else ""))
        elif n_nop > 0:
            reads = "too little prior history to compare shapes"
        else:
            reads = "too few waits in the Current window to compare shapes"
        if n_few > 0 and (n_chg > 0 or ns > 0):
            reads += "; " + str(n_few) + " with too few waits"
        out.append(h.lib_ls('wait-hist', reads))
        out.append('<div class="whbar"><div class="whseg" role="group" aria-label="Weight the buckets by" hidden>'
                   '<button type="button" data-m="c" aria-pressed="true">By count</button>'
                   '<button type="button" data-m="t" aria-pressed="false">By time</button></div>'
                   '<span class="whlg"><i class="whsw whsw-c"></i>Current window</span>'
                   '<span class="whlg"><i class="whsw whsw-n"></i>normal (mean of prior windows)</span>'
                   '<span class="whlg"><i class="whsw whsw-b"></i>prior min&ndash;max</span>'
                   '<span class="whlg"><i class="whsw whsw-p"></i>median and p95</span></div>')
        out.append('<div class="whg">')
        out.extend(cards)
        out.append('</div>')
        out.append('<p class="whr"><b>Reads as:</b> ' + reads + '.</p>')
        out.append('<p class="whn">Buckets are Oracle&rsquo;s power-of-two latency bins '
                   '(each twice as wide as the one before; &ldquo;8 ms&rdquo; = 4&ndash;8 ms). '
                   'By time weights each bucket by its waits &times; its midpoint, an approximation of where the time went. '
                   'Normal = the mean share over the prior valid windows with ' + str(MIN_N)
                   + ' or more waits; a valid prior window without the event counts as zero waits, a skipped one is left out.</p>')
        out.append('<details class="whd"><summary>Every bucket, every event (' + str(len(rows))
                   + ' rows)</summary><div class="whsc"><table class="whtbl" data-nosort data-nocount><thead><tr><th>Event</th><th>Wait time</th>'
                   '<th class="num" data-w="0">Current waits</th><th class="num" data-w="0">Current share</th>'
                   '<th class="num">Normal share</th><th class="num">Prior range</th>'
                   '<th class="num" data-w="0">Current time share</th><th class="num">Normal time share</th></tr></thead><tbody>')
        out.extend(rows)
        out.append('</tbody></table></div></details>')
        out.append('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.waithist={"min":'
                   + str(MIN_N) + ',"ev":[')
        for i, j in enumerate(jsons):
            out.append(j + (',' if i < len(jsons) - 1 else ''))
        out.append(']};</script>')
    out.append('</section>')
    out.append(chrome.lib_script('js_waithist.plsql'))
    out.append('<!-- AWR-SECTION: ' + TAG + ' END -->')
    return "\n".join(out)
