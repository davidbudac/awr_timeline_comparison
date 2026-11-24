"""
Twin of sql/25_onset.sql (+ sql/lib/onset_cte.sql) -- Onset: every
snapshot interval of the report span against its seasonal normal, with a
one-sided CUSUM in each direction that dates the change.

On the demo's hourly grid every bucket is one snapshot pair (1 h, the
median interval; 2017 points < 3000, so no coarsening), its rate is
load_total / dur_sec * scale, and the RU-patch restart drops the pair
across it (a gap).  The span is 12 weeks, so the normal is the same hour
of the WEEK in the other weeks (period = ISO week, the point's own week
excluded).  MEDIAN / PERCENTILE_CONT are Oracle's (linear interpolation
at 1 + p (n - 1)).  The CUSUM, the excursions, the sentence, the table
and the payload follow the PL/SQL step by step.
"""
from __future__ import annotations

import math
from datetime import timedelta

from awrdemo import chrome
from awrdemo import helpers as H

# on_targets + the section's labels: (stat, ord, scale, name, short, unit)
TARGETS = [
    ("DB time", 1, 0.01, "DB time", "DB time", "avg active sessions"),
    ("DB CPU", 2, 0.01, "DB CPU", "DB CPU", "avg CPUs busy"),
    ("user calls", 3, 1, "User calls", "user calls", "calls/s"),
    ("execute count", 4, 1, "Executions", "executions", "executions/s"),
    ("session logical reads", 5, 1, "Logical reads", "logical reads", "blocks/s"),
    ("physical reads", 6, 1, "Physical reads", "physical reads", "blocks/s"),
    ("redo size", 7, 1, "Redo", "redo", "bytes/s"),
]
K, HH, CLIP, MAXPTS = 0.5, 5, 3, 3000
NMET = len(TARGETS)
MK = '<span class="onset-mk"></span>'
H2 = ('<h2>Trend breaks<small class="h2sub">When the shift started: every snapshot interval '
      'of the span against its seasonal normal, dated by a CUSUM change-point test</small></h2>')
_CHUNK = 32500
_DY = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _dt(d) -> str:       # 'Dy fmDD Mon fmHH24:MI'
    return f"{_DY[d.weekday()]} {d.day} {_MON[d.month - 1]} {d:%H:%M}"


def _ds(d) -> str:       # 'fmDD Mon fmHH24:MI'
    return f"{d.day} {_MON[d.month - 1]} {d:%H:%M}"


def _hm(d) -> str:
    return f"{d:%H:%M}"


def _dur(p_min: float) -> str:
    if p_min < 60:
        return str(int(H.ora_round(p_min, 0))) + " min"
    if p_min < 2880:
        v = H.to_char_fixed(p_min / 60, 1 if p_min < 600 else 0)
        if "." not in v:
            v += ".0"
        return v.rstrip("0").rstrip(".") + " h"
    return str(int(H.ora_round(p_min / 1440, 0))) + " days"


def _tok(p, d: int) -> str:
    if p is None:
        return ""
    if d <= 0:
        return H.to_char_fixed(p, 0)
    return H.to_char_trim(H.ora_round(p, d), d)


def _pct(vals, p):
    """Oracle PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY v)."""
    s = sorted(vals)
    rn = 1 + p * (len(s) - 1)
    lo, hi = math.floor(rn), math.ceil(rn)
    if lo == hi:
        return s[lo - 1]
    return (hi - rn) * s[lo - 1] + (rn - lo) * s[hi - 1]


def _median(vals):
    s = sorted(vals)
    n = len(s)
    if n < 1:
        return None
    if n % 2:
        return s[(n + 1) // 2 - 1]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def _glyph(d):
    return "&#9650;" if d > 0 else "&#9660;"


def _dir(d):
    return "up" if d > 0 else "down"


def _cusum_scan(zc: dict, nb: int):
    """cusum_scan: the two-sided CUSUM against the current level, a step
    per crossing (onset, detected, dir, old, new), restarting at the new
    level.  Returns (cc, steps); cc[i] = S+ or -S- (None = no residual)."""
    sp = sm = dl = 0.0
    lp = lm = -1
    cc, steps = {}, []
    for i in range(nb):
        cc[i] = None
        if i not in zc:
            continue
        r = zc[i] - dl
        sp = max(0, sp + r - K)
        sm = max(0, sm - r - K)
        cc[i] = sp if sp >= sm else -sm
        if sp == 0:
            lp = i
        if sm == 0:
            lm = i
        if sp > HH or sm > HH:
            a = (lp if sp > HH else lm) + 1
            while a < i and a not in zc:
                a += 1
            d = 1 if sp > HH else -1
            med = _median([zc[j] for j in range(a, i + 1) if j in zc])
            new = max(med, dl + K) if d > 0 else min(med, dl - K)
            steps.append((a, i, d, dl, new))
            dl = new
            sp = sm = 0
            lp = lm = i
    return cc, steps


def _sgn(v):
    return (v > 0) - (v < 0)


def _put_clob_chunked(payload: str, put) -> None:
    n, pos = len(payload), 0
    while pos < n:
        take = min(_CHUNK, n - pos)
        if pos + take < n:
            cut = payload.rfind(",", pos, pos + take)
            if cut >= 0:
                take = cut - pos + 1
        put(payload[pos:pos + take])
        pos += take


def emit(w) -> str:
    out = []
    put = out.append
    put("<!-- AWR-SECTION: 25_onset BEGIN -->")
    t1 = w.target_end
    t0 = t1 - timedelta(hours=w.weeks_back * w.step_hours + w.win_hours)
    tc = t1 - timedelta(hours=w.win_hours)

    # on_pairs (hourly grid; the restart drops the pair across it)
    pairs = []
    for m in w.hours(t0, t1):
        s, p = w.snap_at(m.ts), w.snap_at(m.ts - timedelta(hours=1))
        if s is None or p is None or s.startup_time != p.startup_time:
            continue
        pairs.append(m)
    if not pairs:
        put('<section id="onset" class="vw in-s in-t in-a lib" style="--os:15">' + H2)
        put('<p class="note">No usable snapshot pairs between ' + H.ts_min(t0) + " and " + H.ts_min(t1)
            + " (restarts, or no AWR history), so there is no series to date a change on.</p>")
        put(H.lib_ls("onset", "no snapshot pairs in the span"))
        put(chrome.lib_script("js_onset.plsql"))
        put("</section>")
        put("<!-- AWR-SECTION: 25_onset END -->")
        return "\n".join(out)

    ival = _median([m.dur_sec for m in pairs])
    first = max(t0, min(m.ts - timedelta(seconds=m.dur_sec) for m in pairs))
    bmin = max(1, int(H.ora_round(ival / 60, 0)))
    span_min = (t1 - first).total_seconds() / 60
    mm = math.ceil(span_min / bmin / MAXPTS)
    if mm > 1:
        mx = bmin * mm
        bmin = next((c for c in (30, 60, 120, 180, 360, 720) if mx <= c), None) or 1440 * math.ceil(mx / 1440)
    nb = max(1, math.ceil(span_min / bmin - 1e-6))
    eff_d = nb * bmin / 1440
    mode = "W" if eff_d >= 21 else ("D" if eff_d >= 3 else "F")
    mode0 = mode

    def b_start(i):
        return t1 - timedelta(minutes=(nb - i) * bmin)

    def b_end(i):
        return t1 - timedelta(minutes=(nb - i - 1) * bmin)

    # on_pts: rate per (stat, b); one pair per bucket on this grid
    pts = []   # (stat, ord, b, v, tm)
    for stat, o, scale, *_ in TARGETS:
        for m in pairs:
            b = int((t1 - m.ts).total_seconds() // (bmin * 60))
            if not 0 <= b <= nb - 1:
                continue
            v = H.load_total(m, stat)
            if v is None:
                continue
            pts.append((stat, o, b, max(v, 0) / m.dur_sec * scale, t1 - timedelta(minutes=(b + 0.5) * bmin)))

    while True:
        def phase(tm):
            if mode == "W":
                return tm.weekday() * 24 + tm.hour
            if mode == "D":
                return tm.hour
            return 0

        def period(tm):
            if mode == "W":
                return (tm - timedelta(days=tm.weekday())).date()
            if mode == "D":
                return tm.date()
            return None

        ph = [(stat, o, b, v, phase(tm), period(tm), "Y" if tm < tc else "N") for stat, o, b, v, tm in pts]
        groups = {}
        for r in ph:
            groups.setdefault((r[0], r[4]), []).append(r)
        norm = {}
        for key in {(r[0], r[4], r[5]) for r in ph}:
            q = [r for r in groups[(key[0], key[1])]
                 if (mode == "F" and r[6] == "Y") or (mode != "F" and r[5] != key[2])]
            if not q:
                continue
            vals = [r[3] for r in q]
            norm[key] = (_median(vals), _pct(vals, 0.25), _pct(vals, 0.75), len(vals), len({r[5] for r in q if r[5] is not None}))
        rows = []
        for r in sorted(ph, key=lambda r: (r[1], -r[2])):
            n = norm.get((r[0], r[4], r[5]))
            med, q1, q3, cnt, np_ = n if n else (None, None, None, 0, 0)
            rows.append({"ord": r[1], "b": r[2], "v": r[3], "med": med, "q1": q1, "q3": q3, "n": cnt, "np": np_})
        judged = 0
        for r in rows:
            if r["med"] is not None and ((mode == "F" and r["n"] >= 8) or (mode != "F" and r["n"] >= 3 and r["np"] >= 2)):
                judged += 1
            else:
                r["med"] = None
        if mode == "F" or judged * 2 >= len(rows):
            break
        mode = "D" if mode == "W" else "F"

    by_ord = {}
    for r in rows:
        by_ord.setdefault(r["ord"], []).append(r)
    floors = {o: (H.metric_policy("LOAD", stat)[4] or 0) * scale for stat, o, scale, *_ in TARGETS}

    def arrays(o):
        x, md, sp, zc = {}, {}, {}, {}
        for r in by_ord.get(o, []):
            i = nb - 1 - r["b"]
            x[i] = r["v"]
            if r["med"] is not None:
                md[i] = r["med"]
                sp[i] = max((r["q3"] - r["q1"]) / 1.349 if r["q3"] is not None else 0,
                            0.02 * abs(r["med"]), floors[o])
                if sp[i] > 0:
                    zc[i] = max(-CLIP, min(CLIP, (x[i] - md[i]) / sp[i]))
        return x, md, sp, zc

    M = {}
    nopen = 0
    for stat, o, scale, name, short, unit in TARGETS:
        x, md, sp, zc = arrays(o)
        r = {"x": x, "md": md, "sp": sp, "zc": zc, "valn": len(x), "jn": len(zc), "thin": len(x) - len(zc),
             "first": min(zc) if zc else None, "odir": None, "cdir": None, "bef": None, "aft": None}
        vmx = max([abs(v) for v in x.values()] + [0])
        r["dec"] = 0 if vmx <= 0 else max(0, min(6, 3 - math.floor(math.log10(vmx))))
        M[o] = r
        if r["jn"] < 8:
            r["st"] = "thin"
            continue
        cz = [zc[i] for i in range(nb) if i in zc and b_start(i) + timedelta(minutes=bmin / 2) >= tc]
        curz = _median(cz)
        r["st"] = "none"
        cc, steps = _cusum_scan(zc, nb)
        r["cc"], r["steps"] = cc, steps
        rs, rsg, rmax, rlast = None, 0, 0, None
        for a, i, d, old, lev in steps:
            if rs is not None and (abs(lev) <= K or _sgn(lev) != rsg):
                r.update(cdir=rsg, con=rs, cend=a - 1, clev=rmax)
                rs = None
            if abs(lev) > K:
                if rs is None:
                    rs, rsg, rmax = a, _sgn(lev), 0
                rmax = max(rmax, abs(lev))
                if rsg * lev > rsg * old:
                    rlast = a
        if rs is not None:
            if curz is not None and rsg * curz > K:
                r.update(odir=rsg, oon=rlast, obase=rs, olev=steps[-1][4])
            else:
                e = rs
                for i in range(rs, nb):
                    if i in zc and rsg * zc[i] > K:
                        e = i
                r.update(cdir=rsg, con=rs, cend=e, clev=rmax)

        def med_x(a, b):
            v = [x[i] for i in range(max(a, 0), min(b, nb - 1) + 1) if i in x]
            return _median(v) if len(v) >= 2 else None
        if r["odir"] is not None:
            r["st"] = "open"
            nopen += 1
            r["aft"] = med_x(r["oon"], nb - 1)
            r["bef"] = med_x(r["oon"] - (nb - r["oon"]), r["oon"] - 1)
        elif r["cdir"] is not None:
            r["st"] = "closed"
            r["aft"] = med_x(r["con"], r["cend"])
            r["bef"] = med_x(r["con"] - (r["cend"] - r["con"] + 1), r["con"] - 1)

    names = {o: (name, short, unit) for _, o, _, name, short, unit in TARGETS}
    lead = None
    for o in range(1, NMET + 1):
        if M[o]["st"] == "open" and (lead is None or (lead != 1 and M[o]["oon"] < M[lead]["oon"])):
            lead = o
    if lead is None:
        for o in range(1, NMET + 1):
            if M[o]["st"] == "closed" and (lead is None or M[o]["cend"] > M[lead]["cend"]):
                lead = o

    nthin = sum(1 for o in M if M[o]["st"] == "thin")
    if nthin == NMET:
        sent = ("too few points to judge an onset: no metric has 8 points with a normal (the span holds "
                f"{nb} snapshot interval" + ("" if nb == 1 else "s") + ")")
        ls = "too few points to date a change"
    elif nopen > 0:
        L = M[lead]
        sh = names[lead][1]
        if L["oon"] == L["first"]:
            sent = (f"<b>{sh}</b> was already {_dir(L['odir'])} at the first point of the span ("
                    + _dt(b_start(L["oon"])) + ") and still is: the shift began before what this span can see")
        elif b_start(L["oon"]) >= tc:
            sent = f"<b>{sh}</b> shifted {_dir(L['odir'])} from {_hm(b_start(L['oon']))}{MK}, inside the Current window"
        else:
            sent = (f"<b>{sh}</b> shifted {_dir(L['odir'])} from {_dt(b_start(L['oon']))}{MK}, about "
                    + _dur((tc - b_start(L["oon"])).total_seconds() / 60)
                    + " before the Current window; sustained since")
        ls = sent.replace(MK, "")
        if L["obase"] < L["oon"]:
            sent += (f", on top of an earlier shift {_dir(L['odir'])} from "
                     + ("the start of the span, " if L["obase"] == L["first"] else "") + _dt(b_start(L["obase"])))
        if mode == "F":
            sent += " (against a flat baseline, so a daily rhythm can read as a shift)"
        if nopen > 1:
            buf = ", ".join(f"{names[o][1]} {_glyph(M[o]['odir'])}"
                            for o in range(1, NMET + 1) if M[o]["st"] == "open" and o != lead)
            sent += ". Also open (onsets in the table): " + buf
            ls += f" (+{nopen - 1} more)"
    else:
        sent = "no open shift: the Current window is not part of a sustained change"
        ls = "no open shift"
        if lead is not None:
            L = M[lead]
            sh = names[lead][1]
            a, e = b_start(L["con"]), b_end(L["cend"])
            sent += (f". The most recent excursion: {sh} {_dir(L['cdir'])} from "
                     + ("the start of the span, " if L["con"] == L["first"] else "")
                     + _dt(a) + MK + " to " + (_hm(e) if e.date() == a.date() else _dt(e)))
            ls += f"; last: {sh} {_dir(L['cdir'])} {_dt(a)}"

    if mode == "W":
        phase_txt = "Normal = the median of the same hour of the week in the other weeks of the span"
    elif mode == "D":
        phase_txt = "Normal = the median of the same hour of the day on the other days of the span" + (
            " (the same hour of the week: fewer than half the points had "
            "3 same-hour points from 2 other weeks)" if mode0 == "W" else "")
    else:
        phase_txt = ("Normal = the median of every point before the Current window (a flat baseline: "
                     + ("the span, " + _dur(eff_d * 1440) + ", is too short for a seasonal normal, which needs 3 days"
                        if mode0 == "F" else
                        "fewer than half the points had 3 same-hour points from 2 other "
                        + ("weeks" if mode0 == "W" else "days")) + ")")
    phase_txt += ("; band = normal &plusmn; 2 spreads, spread = interquartile range / 1.349, at least 2% of the "
                  "median and the metric's materiality floor. One point per " + _dur(bmin) + ".")
    phs = {"W": "Normal = same hour of the week, other weeks",
           "D": "Normal = same hour of the day, other days" + (" (too few same-hour weeks)" if mode0 == "W" else "")}.get(mode) or (
        "Normal = flat baseline before the Current window (no seasonal normal: "
        + ("span under 3 days" if mode0 == "F" else "too little same-hour history") + ")")
    phs += "; band &plusmn; 2 spreads; one point per " + _dur(bmin) + "."

    put('<section id="onset" class="vw in-s in-t in-a lib' + (" lopen" if nopen > 0 else "")
        + '" style="--os:15">' + H2)
    html = '<div class="onset-viz" hidden><div class="onset-pick" role="tablist" aria-label="Trend breaks metric">'
    for o in range(1, NMET + 1):
        r = M[o]
        if r["st"] == "open":
            st = '<i class="onset-d crit" aria-hidden="true"></i>' + _glyph(r["odir"]) + " open since " + _ds(b_start(r["oon"]))
        elif r["st"] == "closed":
            st = '<i class="onset-d warn" aria-hidden="true"></i>' + _glyph(r["cdir"]) + " closed, ended " + _ds(b_end(r["cend"]))
        elif r["st"] == "none":
            st = '<i class="onset-d ok" aria-hidden="true"></i>no shift'
        else:
            st = '<i class="onset-d" aria-hidden="true"></i>too little history'
        html += (f'<button type="button" class="onset-b" role="tab" id="onset-b{o - 1}" data-i="{o - 1}" '
                 'aria-controls="onset-plot" aria-selected="'
                 + ('true" tabindex="0"' if o == (lead or 1) else 'false" tabindex="-1"')
                 + '><span class="onset-bn">' + names[o][0] + '</span><span class="onset-bs">' + st + "</span></button>")
    put(html + "</div>")
    put('<div class="onset-lg" aria-hidden="true"><span><i class="onset-k k-ln"></i>observed</span>'
        '<span><i class="onset-k k-md"></i>normal</span><span><i class="onset-k k-bd"></i>normal range</span>'
        '<span><i class="onset-k k-lv"></i>step found by the scan</span>'
        '<span><i class="onset-k k-cw"></i>Current window</span><span><i class="onset-k k-pw"></i>compared windows</span>'
        '<span><i class="onset-k k-mk"></i>release marker</span><span><i class="onset-k k-on"></i>detected onset</span>'
        '<span><i class="onset-k k-cu"></i>CUSUM, upward</span><span><i class="onset-k k-cd"></i>CUSUM, downward</span></div>')
    put('<div class="onset-plot" id="onset-plot" role="tabpanel" tabindex="0" aria-label="The picked metric over the span"></div>')
    put('<p class="onset-cap">' + phs + " CUSUM strip in spreads against the current level: "
        "residuals clipped to &plusmn;3, slack 0.5, a step counts past 5 and restarts it. Arrow keys move the cursor.</p></div>")
    put('<p class="onset-rd"><b>Reads as:</b> <span class="onset-s">' + sent + "</span>.</p>")

    if nthin < NMET:
        put('<table class="onset-tbl" data-nocount><thead><tr><th>Metric</th><th>Status</th>'
            '<th>Started</th><th>Ended</th><th class="num">Before</th><th class="num">After</th>'
            '<th class="num">Lasted</th><th class="num">Level shift</th><th class="num">Points judged</th></tr></thead><tbody>')
        for o in range(1, NMET + 1):
            r = M[o]
            h = f'<tr data-i="{o - 1}"><td>{names[o][0]} <small>{names[o][2]}</small></td>'
            if r["st"] == "open":
                h += ('<td><i class="onset-d crit" aria-hidden="true"></i>' + _glyph(r["odir"]) + " open, " + _dir(r["odir"]) + "</td>"
                      + "<td>" + ("at or before " if r["oon"] == r["first"] else "") + _dt(b_start(r["oon"]))
                      + ("<br><small>on top of a shift from " + _dt(b_start(r["obase"])) + "</small>" if r["obase"] < r["oon"] else "")
                      + "</td><td>still open</td>"
                      + '<td class="num">' + H.fmt_num(r["bef"]) + '</td><td class="num">' + H.fmt_num(r["aft"]) + "</td>"
                      + '<td class="num">' + _dur((t1 - b_start(r["oon"])).total_seconds() / 60) + "</td>"
                      + '<td class="num">' + H.to_char_fixed(r["olev"], 1, plus=True) + " spreads</td>")
            elif r["st"] == "closed":
                h += ('<td><i class="onset-d warn" aria-hidden="true"></i>' + _glyph(r["cdir"]) + " closed, " + _dir(r["cdir"]) + "</td>"
                      + "<td>" + ("at or before " if r["con"] == r["first"] else "") + _dt(b_start(r["con"]))
                      + "</td><td>" + _dt(b_end(r["cend"])) + "</td>"
                      + '<td class="num">' + H.fmt_num(r["bef"]) + '</td><td class="num">' + H.fmt_num(r["aft"]) + "</td>"
                      + '<td class="num">' + _dur((b_end(r["cend"]) - b_start(r["con"])).total_seconds() / 60) + "</td>"
                      + '<td class="num">' + H.to_char_fixed(r["cdir"] * r["clev"], 1, plus=True) + " spreads</td>")
            else:
                h += ("<td>" + ('<i class="onset-d ok" aria-hidden="true"></i>no shift' if r["st"] == "none"
                                else '<i class="onset-d" aria-hidden="true"></i>too little history')
                      + '</td><td>&mdash;</td><td>&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td>'
                      '<td class="num">&mdash;</td><td class="num">&mdash;</td>')
            put(h + '<td class="num">' + H.fmt_int(r["jn"]) + " of " + H.fmt_int(r["valn"]) + "</td></tr>")
        put("</tbody></table>")
    tthin = sum(M[o]["thin"] for o in M)
    tval = sum(M[o]["valn"] for o in M)
    put('<p class="note onset-note">' + phase_txt + " "
        + ("Every point with a value had enough history to judge." if tthin == 0 else
           H.fmt_int(tthin) + " of " + H.fmt_int(tval) + " points (all metrics) had too little history to judge ("
           + ("fewer than 8 baseline points" if mode == "F" else
              "fewer than 3 same-hour points from 2 other " + ("weeks" if mode == "W" else "days"))
           + "); the CUSUM holds across them and across gaps.")
        + " Before / After = median level in as many points before the onset as the shift lasted, and since; "
        "Level shift = the level the change-point scan settled on, in spreads from the normal.</p>")

    # the payload
    js = (f'{{t1:"{H.ts_min(t1)}",bm:{bmin},nb:{nb},tc:"{H.ts_min(tc)}",mode:"{mode}",k:0.5,h:5,lead:'
          + ("null" if lead is None else str(lead - 1)) + ",m:[")
    for o in range(1, NMET + 1):
        r = M[o]
        js += (("," if o > 1 else "") + f'{{n:"{names[o][0]}",u:"{names[o][2]}",d:{r["dec"]},st:"{r["st"]}",on:'
               + (f"[{r['oon']},{r['obase']},{r['odir']}]" if r["st"] == "open" else "null")
               + ",cl:" + (f"[{r['con']},{r['cend']},{r['cdir']}]" if r["cdir"] is not None else "null")
               + ",sp:[" + ",".join(f"[{a},{i},{d},{int(H.ora_round(lev * 10, 0))}]" for a, i, d, _o, lev in r.get("steps", []))
               + "]")
        cc = r.get("cc", {})
        xs, mds, sps, cs = [], [], [], []
        for i in range(nb):
            xs.append(_tok(r["x"].get(i), r["dec"]))
            mds.append(_tok(r["md"].get(i), r["dec"]))
            sps.append(_tok(r["sp"].get(i), r["dec"] + 1))
            c = cc.get(i)
            cs.append("" if c is None else str(int(H.ora_round(c * 10, 0))))
        js += ",x:[" + ",".join(xs) + "],md:[" + ",".join(mds) + "],s:[" + ",".join(sps) + "],c:[" + ",".join(cs) + "]}"
    js += "]}"
    put("<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.onset=")
    _put_clob_chunked(js, put)
    put(";</script>")
    put(H.lib_ls("onset", ls))
    put(chrome.lib_script("js_onset.plsql"))
    put("</section>")
    put("<!-- AWR-SECTION: 25_onset END -->")
    return "\n".join(out)
