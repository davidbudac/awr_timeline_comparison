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
"""
from __future__ import annotations

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
    out.append('<section id="ash-timeline"><h2>ASH timeline (' + hourly
               + ', stacked by wait class)</h2>')
    out.append('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
               '<code>dba_hist_active_sess_history</code>, ' + ts_min(range_start)
               + ' &rarr; ' + ts_min(range_end) + ', ' + hourly
               + ' buckets. ON-CPU &rarr; <b>CPU</b>; Idle excluded. '
               'Compared windows shaded.</p>')
    out.append(L[3])   # chart div

    # ---- aggregate: (bucket, wait_class) -> samples ; class totals
    cells: dict[tuple[int, str], int] = {}
    class_totals: dict[str, int] = {}
    for m in w.hours(range_start, range_end):
        b = int(((m.ts - timedelta(hours=1)) - range_start).total_seconds() / 3600 / bh)
        for wc, smp in m.ash_class.items():
            n = int(ora_round(smp, 0))
            if n <= 0:
                continue
            cells[(b, wc)] = cells.get((b, wc), 0) + n
            class_totals[wc] = class_totals.get(wc, 0) + n

    hours_json = "[" + ",".join('"' + ts_min(range_start + timedelta(hours=b * bh)) + '"'
                                for b in range(total_buckets)) + "]"

    out.append(L[4])   # <script>
    out.append(L[5])   # (function(){
    out.append(L[6])   # AWR_DATA.ashTimeline = {
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
    out.append(L[15])
    out.append(L[16])
    out.append("var d=AWR_DATA.ashTimeline, palette=" + PALETTE + ";")
    out.extend(L[18:54])      # verbatim ECharts init .. </script>
    out.append("</section>")
    out.append(L[55])
    return "\n".join(out)
