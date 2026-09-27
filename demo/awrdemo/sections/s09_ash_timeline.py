"""
Twin of sql/09_ash_timeline.sql -- hourly ASH stacked-area timeline by
wait_class over the full compared span (range_start = target_end -
weeks_back*step_hours/24 - win_hours/24 .. target_end), ON-CPU -> 'CPU',
Idle excluded, AAS = samples / (360 * bucket_hours).

Data source: HourMetrics.ash_class (already 'CPU'-keyed, Idle excluded)
for every hour ending in (range_start, range_end]; bucket b (label =
range_start + b*bucket_hours, the bucket's START) holds the hour ending
at range_start + (b+1)h, exactly as the SQL's FLOOR((sample_time -
range_start)*24 / bucket_hours) assignment.

v1.6.0 Activity charts: AWR_DATA.ashe (by wait event) from
HourMetrics.ash_events ({(wait_class, event): samples}, ('CPU', 'CPU')
for on-CPU), rounded per (hour, event) like the classes.  The SQL's
"Other events" is the class total less the top events (integer samples,
so exactly the sum of the other events); here it is the sum of the other
events' rounded samples, which stays >= 0 although the model rounds
classes and events separately.
"""
from __future__ import annotations

import math
import re
from datetime import timedelta

from awrdemo import chrome, helpers
from awrdemo.helpers import ora_round, to_char_fixed, ts_min

SQL = chrome.sql_path("sql/09_ash_timeline.sql")

PALETTE = ('["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",'
           '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]')


def put_clob_chunked(payload: str) -> list[str]:
    """sql/lib/put_clob_chunked.plsql: <=32500-char chunks, each non-final
    chunk backed off to end on its last comma; one PUT_LINE per chunk."""
    out = []
    c_chunk = 32500
    n = len(payload)
    pos = 0
    while pos < n:
        take = min(c_chunk, n - pos)
        if pos + take < n:
            cut = payload.rfind(",", pos, pos + take)
            if cut >= pos:
                take = cut - pos + 1
        out.append(payload[pos:pos + take])
        pos += take
    return out


def bucket_label(bh: float) -> str:
    if bh == 1:
        return "1-hour"
    if bh < 1 and (bh * 60) % 1 == 0:
        return str(round(bh * 60)) + "-min"
    return helpers.to_char_trim(bh, 2) + "-hour"


def windows_json(w) -> str:
    """windows_rollup -> [["start","end","w-N"|"current","1"|"0"], ...]
    ORDER BY week_offset DESC (oldest first).  valid_flag is a STRING
    (F15: the JS compares w[3]!=="0")."""
    parts = []
    for win in sorted(w.windows, key=lambda x: -x.week_offset):
        lbl = "current" if win.week_offset == 0 else "w-" + str(win.week_offset)
        parts.append('["' + ts_min(win.win_start_ts) + '","' + ts_min(win.win_end_ts)
                     + '","' + lbl + '",' + ('"1"' if win.valid_flag == "Y" else '"0"') + "]")
    return "[" + ",".join(parts) + "]"


def emit(w) -> str:
    L = [t for t, _ in chrome.put_lines(SQL)]
    out = []
    bh = w.bucket_hours
    range_start = w.target_end - timedelta(hours=w.weeks_back * w.step_hours + w.win_hours)
    range_end = w.target_end
    total_hours = max((range_end - range_start).total_seconds() / 3600, 1)
    total_buckets = max(int(-(-total_hours // bh)), 1)     # CEIL
    blabel = bucket_label(bh)
    hourly = "hourly" if bh == 1 else blabel

    out.append(L[0])
    out.append('<section id="ash-timeline" class="vw in-a"><h2>Active sessions'
               '<small class="h2sub">ASH by wait class, ' + hourly + ', '
               + ts_min(range_start) + ' &rarr; ' + ts_min(range_end)
               + '; compared windows shaded</small></h2>')
    out.append(L[2])   # chart div

    # ---- aggregate: (bucket, wait_class) -> samples ; class totals
    cells: dict[tuple[int, str], int] = {}
    class_totals: dict[str, int] = {}
    # (bucket, [week_offsets the samples fall in], class, samples, foreground
    # samples) for the Timeline.  A sample belongs to EVERY window whose
    # [start, start + win_hours) holds it (j_lo .. j_hi window steps after
    # range_start, as the SQL); foreground = ash_class minus the model's
    # background-wait samples (the SQL's session_type = 'FOREGROUND').
    cells_by_hour = []
    events_by_hour = []          # (bucket, [week_offsets], event, samples)
    for m in w.hours(range_start, range_end):
        t = m.ts - timedelta(hours=1)
        b = int((t - range_start).total_seconds() / 3600 / bh)
        hh = round((t - range_start).total_seconds() / 3600, 6)
        j_lo = max(0, math.floor((hh - w.win_hours) / w.step_hours) + 1)
        j_hi = min(w.weeks_back, math.floor(hh / w.step_hours))
        wks = [w.weeks_back - j for j in range(j_lo, j_hi + 1)]
        bgs = {}
        for _ev, (bwc, _cnt, us) in m.bg_waits.items():
            if bwc != "Idle":
                bgs[bwc] = bgs.get(bwc, 0.0) + us / 1e6 / 10
        for wc, smp in m.ash_class.items():
            n = int(ora_round(smp, 0))
            if n <= 0:
                continue
            nfg = max(0, int(ora_round(smp - bgs.get(wc, 0.0), 0)))
            cells[(b, wc)] = cells.get((b, wc), 0) + n
            class_totals[wc] = class_totals.get(wc, 0) + n
            cells_by_hour.append((b, wks, wc, n, nfg))
        evs = {}
        for (_wc, ev), smp in m.ash_events.items():
            evs[ev] = evs.get(ev, 0.0) + smp
        for ev, smp in evs.items():
            n = int(ora_round(smp, 0))
            if n > 0:
                events_by_hour.append((b, wks, ev, n))

    hours_json = "[" + ",".join('"' + ts_min(range_start + timedelta(hours=b * bh)) + '"'
                                for b in range(total_buckets)) + "]"

    out.append(L[3])   # <script>
    out.append(L[4])   # (function(){
    out.append(L[5])   # AWR_DATA.ashTimeline = {
    out.append("hours:")
    out.extend(put_clob_chunked(hours_json))
    out.append(",")
    out.append("windows:" + windows_json(w) + ",")
    out.append("classes:[")
    order = sorted(class_totals.items(), key=lambda kv: (-kv[1], kv[0]))
    first = True
    for wc, _tot in order:
        vals = []
        for b in range(total_buckets):
            n = cells.get((b, wc), 0)
            vals.append(to_char_fixed(n / (bh * 360), 4))
        if first:
            first = False
        else:
            out.append(",")
        out.append('{"name":"' + wc.replace('"', '\\"') + '","vals":[')
        out.extend(put_clob_chunked(",".join(vals)))
        out.append("]}")
    out.append("]};")
    out.append(L[14])
    out.append(L[15])
    out.append("var d=AWR_DATA.ashTimeline, palette=" + PALETTE + ";")
    out.extend(L[17:L.index("</script>", 17) + 1])      # verbatim ECharts init .. </script>
    out.extend(_timeline(w, range_start, total_hours, total_buckets, bh, cells_by_hour, events_by_hour))
    out.append("</section>")
    out.append(L[-1])
    return "\n".join(out)


# ---------------------------------------------------------------------
# v1.6.0 Timeline: AWR_DATA.ashx + the Activity lane row (same scan)
# ---------------------------------------------------------------------
_CLS_RANK = {"CPU": 1, "User I/O": 2, "System I/O": 3, "Commit": 4, "Application": 5,
             "Concurrency": 6, "Network": 7, "Configuration": 8, "Scheduler": 9,
             "Cluster": 10, "Administrative": 11, "Queueing": 12, "Other": 99}


def hr_tok(v) -> str:
    """RTRIM(TO_CHAR(ROUND(v, 6), 'FM9999999990D999999'), '.') -- bh / wh"""
    return helpers.to_char_trim(ora_round(v, 6), 6)


def aas_tok(v) -> str:
    """RTRIM(TO_CHAR(ROUND(v, 3), 'FM9999999990D999'), '.')"""
    return helpers.to_char_trim(ora_round(v or 0, 3), 3)


def _events(w, range_start, total_hours, cbh, m, nc, events_by_hour):
    """AWR_DATA.ashe: the top 14 events (samples desc, name asc), biggest
    first, then "Other events" (only when more are left)."""
    ec, ew, et = {}, {}, {}
    for b, wks, ev, n in events_by_hour:
        ec[(b // m, ev)] = ec.get((b // m, ev), 0) + n
        for wk in wks:
            ew[(wk, ev)] = ew.get((wk, ev), 0) + n
        et[ev] = et.get(ev, 0) + n
    top = sorted(et, key=lambda e: (-et[e], e))[:14]
    rest = [e for e in et if e not in top]
    names = top + (["Other events"] if rest else [])

    def cell(d, key0, i):
        if i < len(top):
            return d.get((key0, top[i]), 0)
        return sum(d.get((key0, e), 0) for e in rest)

    out = ['<script>AWR_DATA.ashe={"t0":"' + ts_min(range_start) + '","end":"'
           + ts_min(w.target_end) + '","bh":' + hr_tok(cbh)
           + ',"wh":' + hr_tok(w.win_hours) + ',"classes":[']
    for i, e in enumerate(names):
        out.append(("," if i else "") + '"' + helpers.json_escape(e) + '"')
    out.append('],"vals":[')
    for i in range(len(names)):
        vals = []
        for b in range(nc):
            cov = min(cbh, total_hours - b * cbh)
            vals.append(aas_tok(cell(ec, b, i) / (360 * cov) if cov > 0 else 0))
        out.append(("," if i else "") + "[")
        out.extend(put_clob_chunked(",".join(vals)))
        out.append("]")
    out.append('],"win":[')
    for i in range(len(names)):
        row = [aas_tok(cell(ew, k, i) / (360 * w.win_hours)) for k in range(w.weeks_back, -1, -1)]
        out.append(("," if i else "") + "[" + ",".join(row) + "]")
    out.append("]};</script>")
    return out


def _timeline(w, range_start, total_hours, total_buckets, bh, cells_by_hour, events_by_hour):
    out = []
    # the fine grid; coarsened only past 10000 buckets (SQL v_m)
    m = max(1, math.ceil(total_buckets / 10000))
    cbh = m * bh
    nc = math.ceil(total_buckets / m)
    ccells, wcells, wfcells, totals = {}, {}, {}, {}
    for b, wks, wc, n, nfg in cells_by_hour:
        ccells[(b // m, wc)] = ccells.get((b // m, wc), 0) + n
        for wk in wks:
            wcells[(wk, wc)] = wcells.get((wk, wc), 0) + n
            wfcells[(wk, wc)] = wfcells.get((wk, wc), 0) + nfg
        totals[wc] = totals.get(wc, 0) + n
    classes = sorted(totals, key=lambda c: (_CLS_RANK.get(c, 50), c))
    valid = {win.week_offset: win.valid_flag for win in w.windows}
    out.append('<script>AWR_DATA.ashx={"t0":"' + ts_min(range_start) + '","end":"'
               + ts_min(w.target_end) + '","bh":' + hr_tok(cbh)
               + ',"wh":' + hr_tok(w.win_hours) + ',"classes":[')
    for i, c in enumerate(classes):
        out.append(("," if i else "") + '"' + c.replace('"', '\\"') + '"')
    out.append('],"vals":[')
    for i, c in enumerate(classes):
        vals = []
        for b in range(nc):
            n = ccells.get((b, c), 0)
            cov = min(cbh, total_hours - b * cbh)
            vals.append(aas_tok(n / (360 * cov) if cov > 0 else 0))
        out.append(("," if i else "") + "[")
        out.extend(put_clob_chunked(",".join(vals)))
        out.append("]")
    out.append('],"win":[')
    wtot = {k: 0.0 for k in range(w.weeks_back + 1)}
    cc, cm = {}, {}
    for i, c in enumerate(classes):
        row, ssum, cnt = [], 0.0, 0
        for k in range(w.weeks_back, -1, -1):
            aas = wcells.get((k, c), 0) / (360 * w.win_hours)
            row.append(aas_tok(aas))
            wtot[k] += aas
            if k == 0:
                cc[i] = aas
            elif valid.get(k) == "Y":
                ssum += aas
                cnt += 1
        cm[i] = ssum / cnt if cnt else None
        out.append(("," if i else "") + "[" + ",".join(row) + "]")
    out.append('],"winfg":[')
    for i, c in enumerate(classes):
        row = [aas_tok(wfcells.get((k, c), 0) / (360 * w.win_hours)) for k in range(w.weeks_back, -1, -1)]
        out.append(("," if i else "") + "[" + ",".join(row) + "]")
    out.append("]};</script>")
    out.extend(_events(w, range_start, total_hours, cbh, m, nc, events_by_hour))
    if not totals:
        return out
    prior = [wtot[k] for k in range(w.weeks_back, 0, -1) if valid.get(k) == "Y"]
    cur = wtot[0]
    mu = sum(prior) / len(prior) if prior else None
    tot = ",".join(helpers.wg_tok(wtot[k]) for k in range(w.weeks_back, -1, -1))
    leg = "".join('<li><i class="sw" data-wc="' + helpers.esc(c) + '"></i>' + helpers.esc(c) + '</li>'
                  for c in classes)
    gut = ('<div class="g" role="cell" title="ASH active sessions, Current vs the mean of the '
           'valid prior windows; ASH is not scored"><div class="gl1">'
           + helpers.delta_span(cur, mu, None, "Y").replace('class="d ', 'class="d d1 ', 1)
           + '<span class="z">total</span></div>')
    chosen = []
    for _ in range(min(3, len(classes))):
        k = None
        for i in range(len(classes)):
            if i in chosen:
                continue
            if k is None or cc[i] > cc[k]:
                k = i
        if k is None or cc[k] <= 0:
            break
        chosen.append(k)
        gut += ('<span class="d3"><i class="sw" data-wc="' + helpers.esc(classes[k]) + '"></i>'
                + helpers.esc(classes[k]) + ' '
                + re.sub(r"<[^>]+>", "", helpers.delta_span(cc[k], cm[k], None, "Y")) + '</span>')
    gut += '</div>'
    row = ('<div class="r ash" id="tl-ash-timeline" data-v="' + tot + '"'
           ' data-name="Active sessions (ASH)" data-unit="AAS" role="row">'
           '<div class="l" role="rowheader"><span class="nm">'
           + helpers.ent('Active sessions', 'ash-timeline', 'chart') + '</span>'
           '<span class="sub">ASH, by wait class</span><ul class="leg">' + leg + '</ul>'
           '<span class="axn" aria-hidden="true"></span></div>')
    for k in range(w.weeks_back, -1, -1):
        row += ('<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k)
                + '"><span class="v">' + helpers.fmt_num(wtot[k]) + '</span></div>')
    out.append(helpers.tl_open('activity') + row + gut + '</div>' + helpers.tl_close())
    return out
