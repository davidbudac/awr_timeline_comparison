"""Twin of sql/27_instance_map.sql (Instance map).

Section 07's findings (the same recompute, s07_summary.compute_findings,
bucketed by helpers.policy_bucket) drawn on a schematic of the instance:
each area takes the worst bucket of the canonical metrics mapped to it by
the family -> area table below (im_comp).  Mirrors the PL/SQL block top to
bottom.
"""
from __future__ import annotations

import re

from awrdemo import chrome
from .. import helpers as h
from . import s07_summary

C_N = 11

# ===================== THE family -> area table =====================
_COMP = {
    "NETWORK": 1, "WAIT:Network": 1, "CALLS": 1, "SESSIONS": 1,
    "DB_TIME": 2, "CPU": 2, "CPU_WAIT_RATIO": 2, "RESPONSE": 2, "EXEC": 2, "ROLLBACK": 2, "SORTS": 2,
    "WAIT:Application": 3, "WAIT:Concurrency": 3,
    "PARSE": 4, "HARD_PARSE": 4, "CURSORS": 4,
    "LOGICAL_IO": 5,
    "WRITE_IO": 6,
    "REDO": 7, "COMMIT": 7, "WAIT:Commit": 7,
    "READ_IO": 8, "SCANS": 8, "WAIT:User I/O": 8,
    "WAIT:System I/O": 9,
    "SORTS_DISK": 10,
}

_KEY = {1: "clients", 2: "sessions", 3: "locks", 4: "shpool", 5: "bufcache", 6: "dbwr",
        7: "lgwr", 8: "datafiles", 9: "redologs", 10: "temp", 11: "other"}
_TITLE = {1: "Clients and network", 2: "Sessions and CPU", 3: "Locks and concurrency",
          4: "Shared pool", 5: "Buffer cache", 6: "DB writer (DBWR)", 7: "Log writer (LGWR)",
          8: "Datafiles", 9: "Redo logs", 10: "Temp", 11: "Other waits"}
_PHRASE = {1: "network", 2: "DB time / CPU", 3: "locks", 4: "parse", 5: "logical reads",
           6: "datafile writes", 7: "commits / redo", 8: "datafile reads",
           9: "background I/O", 10: "temp", 11: "other waits"}
_WHAT = {
    1: "User calls, bytes to and from clients, Network waits, sessions and logons",
    2: "DB time, DB CPU, host CPU, SQL response time, executions, rollbacks",
    3: "Application (row lock) and Concurrency waits",
    4: "Parses, hard parses, parse failures, cursors",
    5: "Logical reads",
    6: "Physical writes, write volume, write I/O requests",
    7: "Redo generated, redo writes, user commits, Commit waits",
    8: "Physical reads, read volume, read latency, long table scans, User I/O waits",
    9: "System I/O waits (log file and control file writes by the background)",
    10: "Sorts that spilled to disk",
    11: "Cluster, Scheduler, Configuration, Administrative, Queueing and Other waits",
}
_PREF = {1: "LOAD:user calls", 2: "LOAD:DB time", 3: "WAIT:Wait class: Application",
         4: "LOAD:parse count (hard)", 5: "LOAD:session logical reads", 6: "LOAD:physical writes",
         7: "LOAD:redo size", 8: "LOAD:physical reads", 9: "WAIT:Wait class: System I/O",
         10: "LOAD:sorts (disk)", 11: None}
_X = {1: 12, 2: 214, 3: 214, 4: 452, 5: 452, 6: 668, 7: 668, 8: 870, 9: 870, 10: 870, 11: 12}
_Y = {1: 140, 2: 140, 3: 262, 4: 46, 5: 140, 6: 250, 7: 330, 8: 140, 9: 330, 10: 46, 11: 330}
_W = {1: 160, 2: 166, 3: 166, 4: 170, 5: 170, 6: 154, 7: 154, 8: 158, 9: 158, 10: 158, 11: 160}


def _comp(family: str) -> int:
    return _COMP.get(family, 11)


def _sev_word(p: int) -> str:
    return {4: "large", 3: "moderate", 2: "improved", 1: "normal"}.get(p, "not measured")


def _sev_cls(p: int) -> str:
    return {4: "s-large", 3: "s-moderate", 2: "s-improved", 1: "s-typical"}.get(p, "s-nm")


def _row_sev(b) -> int:
    return {"large": 4, "moderate": 3, "improved": 2, "typical": 1, "noted": 1,
            "flat baseline": 1}.get(b, 0)


def _lab(f) -> str:
    return h.metric_label(f.domain, f.name)


def _fit(s: str, n: int) -> str:
    if len(s) > n:
        return h.esc(s[:n - 1].rstrip()) + "&hellip;"
    return h.esc(s)


def _dtxt(f) -> str:
    return re.sub(r"<[^>]*>", "", h.delta_span(f.cur, f.mu, f.bucket))


def _dtxt_aria(f) -> str:
    return (_dtxt(f).replace("&#9650; ", "up ").replace("&#9660; ", "down ")
            .replace("&times;", "x").replace("&mdash;", ""))


def _val_txt(f) -> str:
    return h.fv(None if f.cur is None else f.cur * h.metric_scale(f.domain, f.name),
                h.metric_unit(f.domain, f.name))


def _rng_txt(f) -> str:
    s = h.metric_scale(f.domain, f.name)
    return h.fv_range(None if f.mu is None else f.mu * s, None if f.sd is None else f.sd * s,
                      h.metric_unit(f.domain, f.name))


def _row_ent(f) -> str:
    return h.ent(h.esc(_lab(f)), h.finding_anchor(f.domain, f.name), "metric")


def _num(x) -> str:
    """Oracle's implicit NUMBER -> VARCHAR2 for the coordinates (halves)."""
    return str(int(x)) if x == int(x) else str(x)


def _arrow(pts: str, comp: int, csev: dict, dash: bool = False) -> str:
    p = pts.split(" ")
    x1, y1 = (int(v) for v in p[-2].split(","))
    x2, y2 = (int(v) for v in p[-1].split(","))
    sv = csev[comp]
    hs = 9 if sv == 4 else 8 if sv == 3 else 6
    hw = {9: 5, 8: 4.5}.get(hs, 3.5)
    dx = (x2 > x1) - (x2 < x1)
    dy = (y2 > y1) - (y2 < y1)
    bx, by = x2 - dx * hs, y2 - dy * hs
    pre = pts[:pts.rfind(" ") + 1] + _num(bx) + "," + _num(by)
    return ('<g class="im-a ' + _sev_cls(sv) + (" dash" if dash else "")
            + '" data-c="' + _KEY[comp] + '"><polyline points="' + pre + '"/>'
            + '<polygon points="' + _num(x2) + "," + _num(y2) + " "
            + _num(bx - dy * hw) + "," + _num(by - dx * hw) + " "
            + _num(bx + dy * hw) + "," + _num(by + dx * hw) + '"/></g>')


def _alab(x, y, txt, anchor="middle") -> str:
    return ('<text class="im-al" x="' + str(x) + '" y="' + str(y) + '" text-anchor="' + anchor
            + '">' + txt + '</text>')


def _lead_before(a, b) -> bool:
    if _row_sev(a.bucket) != _row_sev(b.bucket):
        return _row_sev(a.bucket) > _row_sev(b.bucket)
    pa = int(a.family == h.card_primary(a.grp))
    pb = int(b.family == h.card_primary(b.grp))
    if pa != pb:
        return pa > pb
    za, zb = h.ora_round(abs(a.z or 0), 6), h.ora_round(abs(b.z or 0), 6)
    if za != zb:
        return za > zb
    return len(_lab(a)) < len(_lab(b))


def _add_item(lst, item, last):
    if lst is None:
        return item
    return lst + (" and " if last else ", ") + item


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 27_instance_map BEGIN -->"]
    csev = {i: 0 for i in range(1, C_N + 1)}
    clead = {i: None for i in range(1, C_N + 1)}
    cards = {i: [] for i in range(1, C_N + 1)}

    nprior = sum(1 for win in w.windows if win.week_offset > 0 and win.valid)
    curok = sum(1 for win in w.windows if win.week_offset == 0 and win.valid)
    ok = nprior >= 3 and curok > 0
    note = None
    if not ok:
        note = ("The Current window has no valid snapshot pair" if curok == 0
                else "Only " + str(nprior) + " valid prior window" + ("" if nprior == 1 else "s")
                + " (a metric needs at least 3 to be scored)") + ", so no area could be measured."

    rows = s07_summary.compute_findings(w) if ok else []
    comp = {}
    for f in rows:
        c = _comp(f.family)
        comp[id(f)] = c
        if f.canonical == "Y":
            csev[c] = max(csev[c], _row_sev(f.bucket))
            if f.bucket in ("large", "moderate") and h.card_id(f.grp) not in cards[c]:
                cards[c].append(h.card_id(f.grp))

    for f in rows:
        k = comp[id(f)]
        if f.canonical != "Y":
            continue
        if csev[k] >= 2:
            rs = _row_sev(f.bucket)
            if rs == csev[k] or (csev[k] >= 3 and rs >= 3):
                L = clead[k]
                if L is None:
                    clead[k] = f
                elif _lead_before(f, L):
                    clead[k] = f
        elif f.domain + ":" + f.name == _PREF[k] and (_row_sev(f.bucket) >= 1 or csev[k] == 0):
            clead[k] = f
    for f in rows:
        k = comp[id(f)]
        if f.canonical == "Y" and clead[k] is None and _row_sev(f.bucket) >= 1:
            clead[k] = f

    # "Reads as" order: insertion sort (stable) on severity, |z| for flagged
    order = list(range(1, C_N + 1))
    for i in range(1, C_N):
        k = i
        while k > 0 and (csev[order[k]] > csev[order[k - 1]]
                         or (csev[order[k]] == csev[order[k - 1]] and csev[order[k]] >= 3
                             and abs(clead[order[k]].z or 0) > abs(clead[order[k - 1]].z or 0))):
            order[k], order[k - 1] = order[k - 1], order[k]
            k -= 1
    nflag = sum(1 for k in order if csev[k] >= 3)
    nimpr = sum(1 for k in order if csev[k] == 2)
    nnorm = sum(1 for k in order if csev[k] == 1)
    nnm = sum(1 for k in order if csev[k] == 0)
    flag = impr = norm = nm = None
    a = b = c = d = 0
    for k in order:
        if csev[k] >= 3:
            a += 1
            flag = _add_item(flag, "<b>" + _PHRASE[k] + "</b> (" + _sev_word(csev[k]) + ", "
                             + _dtxt(clead[k]) + ")", a == nflag)
        elif csev[k] == 2:
            b += 1
            impr = _add_item(impr, _PHRASE[k], b == nimpr)
        elif csev[k] == 1:
            c += 1
            norm = _add_item(norm, _PHRASE[k], c == nnorm)
        else:
            d += 1
            nm = _add_item(nm, _PHRASE[k], d == nnm)

    def tail():
        return (("; " + impr + " improved" if nimpr > 0 else "")
                + ("; " + norm + (" is" if nnorm == 1 else " are") + " normal" if nnorm > 0 else "")
                + ("; not measured: " + nm if nnm > 0 else "") + ".")

    if not ok:
        rd = "not measured: " + note
        ls = "not measured, too little history"
    elif nflag == 0 and nnm == 0 and nimpr == 0:
        rd = "all " + str(C_N) + " areas normal."
        ls = "all " + str(C_N) + " areas normal"
    elif nflag == 0:
        rd = "no area flagged" + tail()
        ls = "no area flagged" + (", " + str(nnm) + " not measured" if nnm > 0 else "")
    else:
        rd = "<b>" + str(nflag) + "</b> of " + str(C_N) + " areas flagged: " + flag + tail()
        ls = "<b>" + str(nflag) + "</b> of " + str(C_N) + " areas flagged: "
        a = 0
        for k in order:
            if csev[k] >= 3:
                a += 1
                ls += ((" and " if a == nflag else ", ") if a > 1 else "") + _PHRASE[k]

    out.append('<section id="instance-map" class="vw in-s in-a lib' + (" lopen" if nflag > 0 else "")
               + '" style="--os:17"><h2>Instance map'
               '<small class="h2sub">Where in the database the findings sit: each area takes the worst '
               'score of the metrics behind it</small></h2>')
    out.append(h.lib_ls("instance-map", ls))
    out.append('<div class="im-wrap">')
    out.append('<ul class="im-lg" aria-label="Legend">'
               '<li><i class="im-k s-large"></i>large</li><li><i class="im-k s-moderate"></i>moderate</li>'
               '<li><i class="im-k s-improved"></i>improved</li><li><i class="im-k s-typical"></i>normal</li>'
               '<li><i class="im-k s-nm"></i>not measured</li>'
               '<li class="im-lgn">arrows: the flows; a thicker, coloured arrow feeds a flagged area</li></ul>')
    if note is not None:
        out.append('<p class="note">' + note + '</p>')
    out.append('<div class="im-scroll"><svg class="im-svg" viewBox="0 0 1040 410" role="img" aria-label="'
               + 'Instance map: ' + re.sub(r"<[^>]*>", "", rd).replace('"', '') + '">')
    out.append('<rect class="im-ct" x="440" y="16" width="194" height="200" rx="10"/>'
               '<text class="im-cl" x="452" y="34">SGA (shared memory)</text>'
               '<rect class="im-ct" x="858" y="16" width="176" height="388" rx="10"/>'
               '<text class="im-cl" x="870" y="34">Storage</text>'
               '<text class="im-cl" x="668" y="242">Background writers</text>'
               '<text class="im-cl" x="214" y="128">Server processes</text>')
    out.append(_arrow("172,172 212,172", 1, csev) + _alab(192, 164, "calls")
               + _arrow("380,164 450,164", 5, csev) + _alab(415, 156, "reads")
               + _arrow("340,140 340,78 450,78", 4, csev) + _alab(395, 70, "parse")
               + _arrow("868,172 624,172", 8, csev) + _alab(746, 164, "physical reads")
               + _arrow("537,204 537,282 666,282", 6, csev) + _alab(600, 274, "writes")
               + _arrow("822,282 949,282 949,206", 6, csev)
               + _arrow("380,196 400,196 400,362 666,362", 7, csev) + _alab(533, 354, "redo")
               + _arrow("822,362 868,362", 7, csev)
               + _arrow("297,204 297,260", 3, csev, True))
    for i in range(1, C_N + 1):
        x, y, wd, sv, L = _X[i], _Y[i], _W[i], csev[i], clead[i]
        c1 = " ".join(cards[i])
        c1a = h.card_id(L.grp) if sv >= 3 else None
        if L is not None:
            sub = _fit(_lab(L), 24)
        elif not ok:
            sub = "too little history"
        else:
            sub = "no data in this run"
        st = ('<tspan class="im-sw">' + _sev_word(sv) + '</tspan>'
              + (" &middot; " + _dtxt(L) if sv >= 2 and L is not None else ""))
        ar = (_TITLE[i] + ": " + _sev_word(sv)
              + (", " + _lab(L) + " " + _dtxt_aria(L) if L is not None else ""))
        tag = (' class="im-n ' + _sev_cls(sv) + '" data-c="' + _KEY[i] + '" data-sev="'
               + _sev_word(sv) + '" data-cards="' + c1 + '"')
        if c1a is not None:
            line = '<a href="#' + c1a + '"' + tag + ' aria-label="' + h.esc(ar) + '. Open its finding card">'
        else:
            line = '<g tabindex="0"' + tag + ' aria-label="' + h.esc(ar) + '">'
        line += ('<rect class="im-b" x="' + str(x) + '" y="' + str(y) + '" width="' + str(wd)
                 + '" height="64" rx="8"/>'
                 + '<text class="im-t" x="' + str(x + 12) + '" y="' + str(y + 21) + '">'
                 + h.esc(_TITLE[i]) + '</text>'
                 + '<text class="im-m" x="' + str(x + 12) + '" y="' + str(y + 38) + '">' + sub + '</text>'
                 + '<circle class="im-d" cx="' + str(x + 16) + '" cy="' + str(y + 51) + '" r="4"/>'
                 + '<text class="im-s" x="' + str(x + 26) + '" y="' + str(y + 55) + '">' + st + '</text>'
                 + ('</a>' if c1a is not None else '</g>'))
        out.append(line)
    out.append('</svg></div>')

    for i in range(1, C_N + 1):
        L = clead[i]
        line = ('<div class="im-src" data-c="' + _KEY[i] + '" hidden><b class="im-pt">'
                + h.esc(_TITLE[i]) + '</b> <span class="im-st ' + _sev_cls(csev[i])
                + '"><i class="im-k ' + _sev_cls(csev[i]) + '"></i>' + _sev_word(csev[i]) + '</span>'
                + '<p class="im-pw">' + h.esc(_WHAT[i]) + '</p>')
        if csev[i] >= 3:
            line += '<ul class="im-pm">'
            n = 0
            for f in rows:
                if comp[id(f)] == i and f.canonical == "Y" and f.bucket in ("large", "moderate"):
                    n += 1
                    if n <= 8:
                        line += ('<li>' + _row_ent(f) + ' <span class="im-pv">'
                                 + h.nbu(_val_txt(f)) + ', normal ' + _rng_txt(f) + '</span> '
                                 + h.delta_span(f.cur, f.mu, f.bucket) + '</li>')
            if n > 8:
                line += '<li class="im-pmore">and ' + str(n - 8) + ' more (table below)</li>'
            line += '</ul><p class="im-pc">'
            seen = set()
            for f in rows:
                if comp[id(f)] == i and f.canonical == "Y" and f.bucket in ("large", "moderate"):
                    g = h.card_id(f.grp)
                    if g not in seen:
                        seen.add(g)
                        line += ('<a class="im-go" href="#' + g + '">' + h.esc(h.card_label(f.grp))
                                 + ' card &rarr;</a> ')
            line += '</p>'
        elif L is not None:
            line += ('<ul class="im-pm"><li>' + _row_ent(L) + ' <span class="im-pv">'
                     + h.nbu(_val_txt(L)) + ', normal ' + _rng_txt(L) + '</span> '
                     + h.delta_span(L.cur, L.mu, L.bucket) + '</li></ul>')
        else:
            line += '<p class="im-pw">' + (note or 'No metric of this area has data in this run.') + '</p>'
        out.append(line + '</div>')
    out.append('<div class="im-pop" role="dialog" aria-label="Area details" hidden></div>')
    out.append('<p class="im-rd"><b>Reads as:</b> ' + rd + '</p>')
    out.append('</div>')

    out.append('<div class="im-tscroll"><table class="im-tbl" data-nocount><caption>The areas and their metrics</caption>'
               '<thead><tr><th>Area</th><th>Status</th><th>Lead metric</th><th class="num cur-col">Current</th>'
               '<th class="num">Normal range</th><th class="num">&Delta; vs mean</th><th>Other flagged metrics</th>'
               '</tr></thead><tbody>')
    for i in range(1, C_N + 1):
        L = clead[i]
        o = None
        if csev[i] >= 3:
            for f in rows:
                if (comp[id(f)] == i and f.canonical == "Y" and f is not L
                        and f.bucket in ("large", "moderate")):
                    o = ((o + ", ") if o is not None else "") + _row_ent(f) + " " + h.delta_span(f.cur, f.mu, f.bucket)
        line = ('<tr data-c="' + _KEY[i] + '"'
                + {4: ' class="crit"', 3: ' class="warn"'}.get(csev[i], "") + '>'
                + '<td title="' + h.esc(_WHAT[i]) + '">' + h.esc(_TITLE[i]) + '</td>'
                + '<td class="im-tst"><i class="im-k ' + _sev_cls(csev[i]) + '"></i>' + _sev_word(csev[i]) + '</td>')
        if L is not None:
            line += ('<td>' + _row_ent(L) + '</td>'
                     + '<td class="num" data-w="0">' + h.nbu(_val_txt(L)) + '</td>'
                     + '<td class="num">' + _rng_txt(L) + '</td>'
                     + '<td class="num">' + h.delta_span(L.cur, L.mu, L.bucket) + '</td>')
        else:
            line += ('<td>&mdash;</td><td class="num" data-w="0">&mdash;</td>'
                     '<td class="num">&mdash;</td><td class="num">&mdash;</td>')
        out.append(line + '<td>' + (o or '&mdash;') + '</td></tr>')
    out.append('</tbody></table></div>')

    js = ('<script>window.AWR_DATA=window.AWR_DATA||{};AWR_DATA.instmap={"areas":' + str(C_N)
          + ',"measured":' + ("true" if ok else "false") + ',"comps":[')
    js += ",".join('{"k":"' + _KEY[i] + '","sev":"' + _sev_word(csev[i]) + '","cards":['
                   + ",".join('"' + g + '"' for g in cards[i]) + ']}' for i in range(1, C_N + 1))
    out.append(js + ']};</script>')
    out.append('</section>')
    out.append(chrome.lib_script('js_instmap.plsql'))
    out.append('<!-- AWR-SECTION: 27_instance_map END -->')
    return "\n".join(out)
