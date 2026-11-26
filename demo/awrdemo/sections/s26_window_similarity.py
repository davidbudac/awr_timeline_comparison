"""Twin of sql/26_window_similarity.sql (Window similarity).

The per-window metric values are section 07's recompute (s07_summary's
compute_findings: the same LOAD / METRIC / WAIT rows, their Current /
prior statistics and policy_bucket); the robust distance, the odd-one-out
rule, the suggestion's re-score, the prose and the payload mirror the
PL/SQL block top to bottom (same order, same tie rules).
"""
from __future__ import annotations

import math

from awrdemo import chrome
from awrdemo import helpers as h
from awrdemo.model import ilog10
from awrdemo.sections import s07_summary

CAP = 5.0


def _med(a):
    a = sorted(a)
    n = len(a)
    if n == 0:
        return None
    if n % 2 == 1:
        return a[(n + 1) // 2 - 1]
    return (a[n // 2 - 1] + a[n // 2]) / 2


def _jn(p, dig=15) -> str:
    if p is None:
        return "null"
    if p == 0:
        return "0"
    n = dig - 1 - ilog10(p)
    s = format(h._rnd(p, n), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def _d1(p) -> str:
    return "&mdash;" if p is None else h.to_char_fixed(p, 1)


def _d2(p) -> str:
    return "&mdash;" if p is None else h.to_char_fixed(p, 2)


def _wdate(w, k) -> str:
    s = h._wg_start(w, k)
    if w.step_hours >= 24:
        return h._DY[s.weekday()] + " " + str(s.day) + " " + h._MON[s.month - 1]
    return h._DY[s.weekday()] + " " + str(s.day) + " " + h._MON[s.month - 1] + " " + s.strftime("%H:%M")


def _wname(w, k) -> str:
    if k == 0:
        return "Current (" + _wdate(w, 0) + ")"
    return "&minus;" + w.offset_labels[k - 1] + " (" + _wdate(w, k) + ")"


def _off(w, k) -> str:
    return "Current" if k == 0 else "&minus;" + w.offset_labels[k - 1]


def _flag(b) -> bool:
    return b in ("large", "moderate")


class _M:
    pass


def _top3(ms, a_set, b_set):
    """top3() of the PL/SQL: the three metrics that set the windows of
    a_set apart from those of b_set (ties keep the earlier metric)."""
    top: list[list] = []
    for mi, m in enumerate(ms):
        if m.vec != "Y":
            continue
        cs, xa = [], []
        for a in sorted(a_set):
            if a in m.x:
                xa.append(m.x[a])
                for b in sorted(b_set):
                    if b in m.x:
                        cs.append(min(abs(m.x[a] - m.x[b]), CAP))
        xb = [m.x[b] for b in sorted(b_set) if b in m.x]
        if not cs:
            continue
        cc = _med(cs)
        dv = _med(xa) - _med(xb)
        sg = (dv > 0) - (dv < 0)
        j = len(top)
        while j >= 1 and top[j - 1][1] < cc:
            j -= 1
        if j < 3 and cc > 0:
            top.insert(j, [mi, cc, sg])
            del top[3:]
    parts, js = "", []
    for ti, (mi, cc, sg) in enumerate(top, 1):
        parts += (" and " if ti > 1 and ti == len(top) else ", " if ti > 1 else "")
        parts += h.esc(h.metric_label(ms[mi].dom, ms[mi].nm)) + " (" + ("lower" if sg < 0 else "higher") + ")"
        js.append("[" + str(mi) + "," + _jn(cc, 3) + "," + str(sg) + "]")
    return (parts or None), ",".join(js)


def emit(w) -> str:
    wb = w.weeks_back
    valid = {k: "N" for k in range(wb + 1)}
    for win in w.windows:
        valid[win.week_offset] = win.valid_flag
    prs = [k for k in range(1, wb + 1) if valid[k] == "Y"]
    np_ = len(prs)

    # the metrics, ORDER BY domain, name (07's statistics and bucket)
    fs = sorted(s07_summary.compute_findings(w), key=lambda f: (f.domain, f.name))
    wtot: dict[int, float] = {}
    for f in fs:
        if f.domain == "WAIT":
            for k, v in f.vals.items():
                wtot[k] = wtot.get(k, 0.0) + v
    tot = wtot.get(0)
    ms = []
    for f in fs:
        m = _M()
        m.dom, m.nm, m.cur, m.mu, m.sd, m.n = f.domain, f.name, f.cur, f.mu, f.sd, f.n
        m.shr = (f.cur / tot) if (f.domain == "WAIT" and tot and tot > 0 and f.cur is not None) else None
        pol = h.metric_policy(f.domain, f.name)
        m.canon, m.dir, m.minp, m.mina = pol[1], pol[2], pol[3], pol[4]
        m.grp = h.card_group(h.finding_family(f.domain, f.name))
        m.pb = f.bucket
        m.vals = {k: v for k, v in f.vals.items() if 0 <= k <= wb}
        m.vec, m.md, m.sp, m.x = "N", None, None, {}
        m.sb = []
        ms.append(m)

    # the vector
    nvec = 0
    for m in ms:
        if m.canon != "Y":
            continue
        tmp, mat = [], False
        for k in range(wb + 1):
            if valid[k] == "Y" and k in m.vals:
                a = m.vals[k]
                tmp.append(a)
                if m.dom == "WAIT":
                    if wtot.get(k) and wtot[k] > 0 and a / wtot[k] >= (0.02 if m.mina is None else m.mina):
                        mat = True
                elif m.mina is None or abs(a) >= m.mina:
                    mat = True
        if len(tmp) >= 3 and mat:
            m.md = _med(tmp)
            dev = [abs(x - m.md) for x in tmp]
            m.sp = max(1.4826 * _med(dev), 0.02 * abs(m.md))
            if m.sp == 0:
                m.sp = 1.2533 * sum(dev) / len(tmp)
            if m.sp > 0:
                m.vec = "Y"
                nvec += 1
                for k in range(wb + 1):
                    if valid[k] == "Y" and k in m.vals:
                        m.x[k] = (m.vals[k] - m.md) / m.sp

    d: dict[tuple[int, int], float] = {}
    dd: dict[int, float] = {}
    odd: set[int] = set()
    tops: dict[int, str] = {}
    topj: dict[int, str] = {}
    medd = madd = thr = cv = None
    maxk = None
    oddk: dict[int, int] = {}
    nsg = 0
    sets: list = []
    gtop: list = []
    if np_ >= 3 and nvec > 0:
        for i in range(wb + 1):
            if valid[i] != "Y":
                continue
            for j in range(i + 1, wb + 1):
                if valid[j] != "Y":
                    continue
                s, c = 0.0, 0
                for m in ms:
                    if m.vec == "Y" and i in m.x and j in m.x:
                        s += min(abs(m.x[i] - m.x[j]), CAP)
                        c += 1
                if c > 0:
                    d[(i, j)] = d[(j, i)] = s / c
        for q in prs:
            t = [d[(q, r)] for r in prs if r != q and (q, r) in d]
            if t:
                dd[q] = _med(t)
        if valid[0] == "Y":
            cv = _med([d[(0, r)] for r in prs if (0, r) in d])
        t = [dd[q] for q in prs if q in dd]
        medd = _med(t)
        madd = _med([abs(x - medd) for x in t]) if t else None
        if medd is not None:
            thr = max(medd + 3 * 1.4826 * madd, 1.5 * medd)
        for k in prs:
            if k in dd:
                if maxk is None or dd[k] > dd[maxk]:
                    maxk = k
                if thr is not None and dd[k] > thr:
                    odd.add(k)
        # flagged windows alike each other form a group (connected components)
        comp = {k: k for k in sorted(odd)}
        while True:
            c = 0
            for k in sorted(comp):
                for q in sorted(comp):
                    if q != k and (k, q) in d and d[(k, q)] <= thr and comp[q] < comp[k]:
                        comp[k] = comp[q]
                        c += 1
            if c == 0:
                break
        csz: dict[int, int] = {}
        for k in sorted(comp):
            csz[comp[k]] = csz.get(comp[k], 0) + 1
        for k in sorted(comp):
            if csz[comp[k]] >= 2:
                oddk[k] = 2
            else:
                oddk[k] = 1
                nsg += 1
        if nsg > 0:
            sets.append(("odd", {k for k in comp if oddk[k] == 1}))
        for q in sorted(csz):
            if len(sets) >= 4:
                break
            if csz[q] >= 2:
                sets.append(("grp", {k for k in comp if comp[k] == q}))
        for qi, k in enumerate(prs):
            if k in odd or k == maxk:
                tops[k], topj[k] = _top3(ms, {k}, [r for r in prs if r != k])
        for kind, st in sets:
            gtop.append(_top3(ms, st, [r for r in prs if r not in st])[0])
    nodd = len(odd)

    # the suggestions' re-score and the card counts
    cb = {m.grp for m in ms if m.canon == "Y" and _flag(m.pb)}
    cbn = len(cb)
    schg, sca = [], []
    for si, (kind, st) in enumerate(sets):
        ch, cg = 0, set()
        for m in ms:
            vs = [m.vals[q] for q in prs if q not in st and q in m.vals]
            n = len(vs)
            mu = sd = None
            if n > 0:
                mu = math.fsum(vs) / n
                sq = math.fsum((x - mu) * (x - mu) for x in vs)
                sd = math.sqrt(sq / (n - 1)) if n > 1 else 0.0
            bk = h.policy_bucket(m.dom, m.nm, None, m.cur, mu, sd, n, m.shr)
            m.sb.append(bk)
            if bk != m.pb:
                ch += 1
            if m.canon == "Y" and _flag(bk):
                cg.add(m.grp)
        schg.append(ch)
        sca.append(len(cg))

    def set_names(st):
        return ", ".join("&minus;" + w.offset_labels[k - 1] for k in sorted(st, reverse=True))

    def grp_txt(st, what):
        lo, hi, n = min(st), max(st), len(st)
        cont = all(q in st for q in prs if lo <= q <= hi)
        rec = cont and lo == prs[0]
        old = cont and hi == prs[-1] and not rec
        if what == "O":
            return "older ones" if rec else "more recent ones" if old else "other priors"
        if what == "E":
            return ("the baseline straddles a change" if rec or old else "an episode inside the baseline"
                    if cont else "they differ from the rest in the same way")
        rng = ("&minus;" + w.offset_labels[hi - 1] + " to &minus;" + w.offset_labels[lo - 1] + ", "
               + _wdate(w, hi) + " to " + _wdate(w, lo)) if cont else set_names(st)
        return ("The " + str(n) + (" most recent" if rec else " oldest" if old else "") + " prior windows"
                + (" (" + rng + ")" if what == "Y" else ""))

    # reads as / row text
    if np_ < 3:
        reads = ("Only " + str(np_) + " valid prior window" + ("" if np_ == 1 else "s")
                 + ": judging whether the baseline is sound needs at least 3, so there is nothing to compare.")
        ls = (("no valid prior window" if np_ == 0 else "only " + str(np_) + " valid prior window"
               + ("" if np_ == 1 else "s")) + ": nothing to compare")
    elif nvec == 0 or medd is None:
        reads = "No metric clears its materiality floor in enough windows to compare the windows."
        ls = "no material metric to compare the windows on"
    elif nodd == 0:
        reads = ("The " + str(np_) + " prior windows are alike: none stands out. The most distant, "
                 + _wname(w, maxk) + ", is " + _d1(dd[maxk]) + " robust spreads from the others (odd past "
                 + _d1(thr) + ").")
        if cv is not None:
            reads += " The Current window, the one being judged, sits " + _d1(cv) + " from the priors."
        ls = "the " + str(np_) + " prior windows are alike (no odd one out)"
    else:
        reads, first = "", None
        if nsg > 0:
            oddl, c = "", 0
            for q in reversed(prs):
                if oddk.get(q) == 1:
                    c += 1
                    oddl += (" and " if c > 1 and c == nsg else ", " if c > 1 else "") + _wname(w, q)
                    if first is None or dd[q] > dd[first]:
                        first = q
            reads = ("Window " if nsg == 1 else "Windows ") + oddl + (" is" if nsg == 1 else " are") \
                + " unlike the other priors"
            if tops.get(first):
                reads += (", mostly in " if nsg == 1 else " (" + _wname(w, first) + " mostly in ") \
                    + tops[first] + (")" if nsg > 1 else "")
            reads += ((". Its" if nsg == 1 else ". The largest") + " distance from the other priors is "
                      + _d1(dd[first]) + " robust spreads (odd past " + _d1(thr) + ").")
        for si, (kind, st) in enumerate(sets):
            if kind == "grp":
                reads += (" " if reads else "") + grp_txt(st, "Y") + " form a group of their own, unlike the " \
                    + grp_txt(st, "O") + (", mostly in " + gtop[si] if gtop[si] else "") \
                    + ": " + grp_txt(st, "E") + "."
        for si, (kind, st) in enumerate(sets):
            reads += (" Without " if si == 0 else "; without ")
            reads += (set_names(st) if kind == "odd" else "the group" if (len(sets) - (1 if nsg > 0 else 0) == 1)
                      else "the group " + set_names(st)) + ", "
            reads += ("no metric changes bucket" if schg[si] == 0 else "1 metric changes bucket" if schg[si] == 1
                      else str(schg[si]) + " metrics change bucket")
            reads += " and the findings go from " + str(cbn) + " to " + str(sca[si])
        reads += "; the what-if below shows the details."
        if nsg > 0 and len(sets) == 1:
            ls = (_wname(w, first) + " is unlike the other priors"
                  + (" (" + str(nsg) + " odd windows)" if nsg > 1 else "")
                  + ("; dropping it changes no finding" if schg[0] == 0
                     else "; the what-if shows what changes without it"))
        elif nsg > 0:
            ls = (_wname(w, first) + " is an odd one out and " + str(len(sets[1][1]))
                  + " prior windows form a group of their own")
        else:
            ls = (str(len(sets[0][1])) + " prior windows form a group unlike the " + grp_txt(sets[0][1], "O")
                  + " (" + grp_txt(sets[0][1], "E") + ")")

    out = ['<!-- AWR-SECTION: 26_window_similarity BEGIN -->']
    out.append('<section id="win-sim" class="vw in-s in-a lib' + (' lopen' if nodd > 0 else '')
               + '" style="--os:16"><h2>Window similarity'
               '<small class="h2sub">Is the baseline itself sound, and what if a window is dropped?</small></h2>')
    out.append(h.lib_ls('win-sim', ls))
    if np_ < 3 or nvec == 0 or medd is None:
        out.append('<p class="note">' + reads + '</p></section>')
    else:
        out.append('<p class="winsim-rd"><b>Reads as:</b> ' + reads + '</p>')
        out.append('<div class="winsim-app" id="winsim-app" hidden>'
                   '<div class="winsim-p1"><h3>How alike the windows are</h3>'
                   '<p class="winsim-cap">Each cell compares two windows over ' + str(nvec) + ' metrics: '
                   'the stronger the shade, the further apart (in robust spreads). Below, each window\'s distance from the prior windows; '
                   'the dashed line is the odd-one-out threshold.</p>'
                   '<div class="winsim-lg" aria-hidden="true"></div>'
                   '<div class="winsim-plot" id="winsim-mx"></div></div>'
                   '<div class="winsim-p2"><h3>What if a window is dropped?</h3>'
                   '<p class="winsim-cap">Click a prior window to take it out of the baseline; every metric is '
                   're-scored against the windows left, with the same rule as the findings.</p>'
                   '<div class="winsim-chips" id="winsim-chips" role="group" aria-label="Prior windows in the baseline"></div>'
                   '<div class="winsim-act">'
                   '<button type="button" class="winsim-btn" id="winsim-reset" disabled>Reset</button></div>'
                   '<div class="winsim-res" id="winsim-res" aria-live="polite"></div></div></div>')
        out.append('<p class="note winsim-nojs">The matrix and the what-if are drawn by the page script; '
                   'every distance is in the table below.</p>')
        if wb + 1 > 20:
            out.append('<details class="winsim-full"><summary>Distance from the priors, per window ('
                       + str(wb + 1) + ' windows)</summary>')
        out.append('<div class="winsim-tw"><table class="winsim-tbl" id="winsim-tbl" data-nosort data-nocount><thead><tr>'
                   '<th>Window</th><th>Start</th><th class="num">Distance from the priors</th>'
                   '<th>Status</th><th>Differs most in</th></tr></thead><tbody>')
        for k in range(wb, -1, -1):
            cls = "skip" if valid[k] == "N" else ("winsim-fl" if k in odd else None)
            s = h._wg_start(w, k)
            start = (h._DY[s.weekday()] + " " + s.strftime("%d") + " " + h._MON[s.month - 1] + " "
                     + s.strftime("%Y %H:%M"))
            if valid[k] == "N":
                dist = "&mdash;"
            elif k == 0:
                dist = _d2(cv)
            else:
                dist = _d2(dd[k]) if k in dd else "&mdash;"
            if valid[k] == "N":
                st = "skipped, not scored"
            elif k == 0:
                st = "Current, the window being judged"
            elif oddk.get(k) == 2:
                st = '<span class="winsim-odd">&#9650; in a group unlike the rest</span>'
            elif k in odd:
                st = '<span class="winsim-odd">&#9650; odd one out</span>'
            else:
                st = "alike"
            dm = tops.get(k) if (valid[k] == "Y" and k > 0 and k in tops) else None
            out.append('<tr id="winsim-w' + str(k) + '"' + (' class="' + cls + '"' if cls else '') + '>'
                       + '<td data-w="' + str(k) + '">' + ("Current" if k == 0 else "&minus;" + w.offset_labels[k - 1]) + '</td>'
                       + '<td>' + start + '</td><td class="num">' + dist + '</td><td>' + st + '</td>'
                       + '<td>' + (dm or "") + '</td></tr>')
        out.append('</tbody></table></div>')
        if wb + 1 > 20:
            out.append('</details>')
        out.append('<p class="winsim-cap">Threshold: a prior window is odd when its distance is above '
                   + _d2(thr) + ' (the larger of the median ' + _d2(medd) + ' + 3 &times; 1.4826 &times; MAD '
                   + _d2(madd) + ' and 1.5 &times; the median).</p>')
        nw = wb + 1
        if nw <= 20:
            line = ('<details class="winsim-full"><summary>The full matrix as a table (' + str(nw) + ' &times; '
                    + str(nw) + ')</summary><div class="winsim-tw"><table class="winsim-mt" data-nosort data-notools>'
                    '<thead><tr><th></th>')
            for j in range(wb, -1, -1):
                line += '<th class="num" data-w="' + str(j) + '">' + ("Cur" if j == 0 else "&minus;" + w.offset_labels[j - 1]) + '</th>'
            out.append(line + '</tr></thead><tbody>')
            for i in range(wb, -1, -1):
                line = '<tr><th data-w="' + str(i) + '">' + ("Cur" if i == 0 else "&minus;" + w.offset_labels[i - 1]) + '</th>'
                for j in range(wb, -1, -1):
                    line += '<td class="num">' + ("" if i == j else _d2(d[(i, j)]) if (i, j) in d else "&mdash;") + '</td>'
                out.append(line + '</tr>')
            out.append('</tbody></table></div></details>')
        else:
            out.append('<p class="winsim-cap">The full ' + str(nw) + ' &times; ' + str(nw)
                       + ' matrix is too large for a table; hover the chart for any pair (the per-window distances above '
                       'are its summary).</p>')

        out.append('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.winsim={"cap":' + _jn(CAP, 3)
                   + ',"thr":' + _jn(thr, 6) + ',"medd":' + _jn(medd, 6) + ',"cv":' + _jn(cv, 6)
                   + ',"nvec":' + str(nvec) + ',')
        parts = []
        for k in range(wb, -1, -1):
            ddv = _jn(cv, 6) if k == 0 else (_jn(dd[k], 6) if k in dd else "null")
            parts.append('{"o":' + str(k) + ',"v":"' + valid[k] + '","dd":' + ddv
                         + ',"odd":' + str(oddk.get(k, 0)) + ',"top":[' + topj.get(k, "") + ']}')
        out.append('"w":[' + ",".join(parts) + '],')
        out.append('"m":[')
        for mi, m in enumerate(ms):
            lab = h.metric_label(m.dom, m.nm)
            vals = ",".join(_jn(m.vals[k]) if (valid[k] == "Y" and k in m.vals) else "null"
                            for k in range(wb, -1, -1))
            out.append(("," if mi > 0 else "")
                       + '{"d":"' + m.dom + '","n":"' + h.json_escape(m.nm) + '"'
                       + ',"l":"' + h.json_escape(lab) + '"'
                       + ',"k":"' + m.canon + '","dir":"' + m.dir + '"'
                       + ',"p":' + _jn(m.minp) + ',"a":' + _jn(m.mina)
                       + ',"sh":' + _jn(m.shr) + ',"g":"' + h.json_escape(m.grp) + '"'
                       + ',"pb":"' + m.pb + '","sb":[' + ",".join('"' + b + '"' for b in m.sb) + ']'
                       + ',"vec":' + ('1' if m.vec == "Y" else '0')
                       + ',"md":' + _jn(m.md) + ',"sp":' + _jn(m.sp)
                       + ',"lk":"' + h.json_escape(h.ent(h.esc(lab), h.finding_anchor(m.dom, m.nm), 'metric')) + '"'
                       + ',"v":[' + vals + ']}')
        out.append('],"dm":[')
        for i in range(wb, -1, -1):
            row = ",".join(_jn(d[(i, j)], 4) if (i, j) in d else "null" for j in range(wb, i, -1))
            out.append(("," if i < wb else "") + "[" + row + "]")
        sug = []
        for si, (kind, st) in enumerate(sets):
            sug.append('{"k":"' + kind + '","drop":[' + ",".join(str(k) for k in sorted(st, reverse=True))
                       + '],"chg":' + str(schg[si]) + ',"ca":' + str(sca[si]) + '}')
        out.append('],"cb":' + str(cbn) + ',"sug":[' + ",".join(sug) + ']};</script>')
        # plan 038: the verdict's "Baseline check" note (the suggestion that
        # changes the most metrics, the first on a tie, with at least 3
        # valid prior windows left)
        bs = None
        for si, (kind, st) in enumerate(sets):
            if schg[si] > 0 and np_ - len(st) >= 3 and (bs is None or schg[si] > schg[bs]):
                bs = si
        if bs is not None:
            kind, st = sets[bs]
            if kind == "grp":
                bt = grp_txt(st, "Y") + " form a group unlike the " + grp_txt(st, "O") + "."
            elif len(st) == 1:
                bt = "The prior window " + _wname(w, min(st)) + " is unlike the other prior windows."
            elif len(st) <= 6:
                names = [_wname(w, k) for k in sorted(st, reverse=True)]
                bw = ""
                for c, nm in enumerate(names, 1):
                    bw += (" and " if c > 1 and c == len(names) else ", " if c > 1 else "") + nm
                bt = "The prior windows " + bw + " are unlike the other prior windows."
            else:
                bt = str(len(st)) + " prior windows (" + set_names(st) + ") are unlike the other prior windows."
            bt += (" Scored without " + ("it" if len(st) == 1 else "them") + ", " + str(schg[bs])
                   + (" metric changes" if schg[bs] == 1 else " metrics change") + " bucket"
                   + (" and the findings rise from " + str(cbn) + " to " + str(sca[bs]) if sca[bs] > cbn
                      else " and the findings fall from " + str(cbn) + " to " + str(sca[bs]) if sca[bs] < cbn
                      else ", though the findings stay at " + str(cbn)) + ".")
            out.append('<div id="base-src" hidden><ul><li class="hn-base" data-sug="' + str(bs)
                       + '" data-chg="' + str(schg[bs]) + '" data-cb="' + str(cbn) + '" data-ca="' + str(sca[bs]) + '">'
                       '<span class="hw"><b class="hl">Baseline check:</b> ' + bt
                       + ' <a class="go" href="#win-sim">Window similarity&nbsp;&rarr;</a></span></li></ul></div>')
            L = chrome.put_lines(chrome.sql_path("sql/26_window_similarity.sql"))
            i = next(k for k, (t, _) in enumerate(L) if t.startswith('<script>(function(){var d=document,s=d.getElementById("base-src")'))
            assert L[i][1]
            out.append(L[i][0])
            if nodd > 0:
                out.append(h.lib_news('win-sim', 'note:hn-base'))
        out.append('</section>')
    out.append(chrome.lib_script('js_winsim.plsql'))
    out.append('<!-- AWR-SECTION: 26_window_similarity END -->')
    return "\n".join(out)
