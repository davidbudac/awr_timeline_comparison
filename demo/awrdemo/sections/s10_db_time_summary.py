"""
Twin of sql/10_db_time_summary.sql -- stacked DB time (DB CPU + non-idle
wait time per wait_class, seconds) for every snap pair from the earliest
valid compared-window begin snap through the latest end snap.

Data source: HourMetrics.time_model['DB CPU'] (microseconds) plus
fg_waits + bg_waits per wait_class (DBA_HIST_SYSTEM_EVENT covers ALL
sessions incl. background), Idle excluded, for the hour ending at each
snap.  The SQL's LAG-delta pairing drops the first snap of the span (no
prior snap inside the BETWEEN) and any snap whose prior snap carries a
different startup_time (restart), so those hours are gaps.
"""
from __future__ import annotations

from awrdemo import chrome
from awrdemo.helpers import to_char_fixed, ts_min

SQL = chrome.sql_path("sql/10_db_time_summary.sql")

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


def _paired_windows(w):
    """raw_windows JOIN begin_snap JOIN end_snap WHERE both snaps exist,
    differ, share dbid and startup_time == the valid windows."""
    return [x for x in w.windows if x.valid]


def emit(w) -> str:
    L = [t for t, _ in chrome.put_lines(SQL)]
    out = [L[0], L[1]]
    pw = _paired_windows(w)
    if not pw:
        out.append(L[2])
        out.append(L[59])
        return "\n".join(out)
    range_start = min(x.win_start_ts for x in pw)     # begin snap end_ts
    range_end = max(x.win_end_ts for x in pw)         # end snap end_ts

    out.append(L[3])   # caption
    out.append(L[4])   # chart div

    windows_json = "[" + ",".join(
        '["' + ts_min(x.win_start_ts) + '","' + ts_min(x.win_end_ts) + '","'
        + ("current" if x.week_offset == 0 else "w-" + str(x.week_offset)) + '"]'
        for x in sorted(pw, key=lambda x: -x.week_offset)) + "]"

    # ---- x-axis: snaps in [range_start, range_end] whose prior snap (in
    # the same filtered set) shares startup_time.
    snaps = [s for s in w.snaps if range_start <= s.end_ts <= range_end]
    snaps.sort(key=lambda s: s.snap_id)
    buckets = []          # [(snap, end_ts)]
    prev = None
    for s in snaps:
        if prev is not None and prev.startup_time == s.startup_time:
            buckets.append(s)
        prev = s
    times_json = "[" + ",".join('"' + ts_min(s.end_ts) + '"' for s in buckets) + "]"
    if not buckets:
        out.append(L[5])
        out.append(L[59])
        return "\n".join(out)

    # ---- per-snap delta seconds: CPU + each non-Idle wait_class
    cells: dict[tuple[int, str], float] = {}
    class_totals: dict[str, float] = {}
    for idx, s in enumerate(buckets, start=1):
        m = w.hour(s.end_ts)
        micro: dict[str, float] = {"CPU": max(m.time_model.get("DB CPU", 0.0), 0.0)}
        for src in (m.fg_waits, m.bg_waits):
            for ev, (wc, cnt, us) in src.items():
                cat = wc or "Other"
                if cat == "Idle":
                    continue
                micro[cat] = micro.get(cat, 0.0) + max(us, 0.0)
        for cat, us in micro.items():
            if us > 0:
                sec = us / 1e6
                cells[(idx, cat)] = sec
                class_totals[cat] = class_totals.get(cat, 0.0) + sec

    out.append(L[6])    # <script>
    out.append(L[7])    # (function(){
    out.append(L[8])    # AWR_DATA.dbTimeSummary = {
    out.append("times:")
    out.extend(put_clob_chunked(times_json))
    out.append(",")
    out.append("windows:" + (windows_json if windows_json else "[]") + ",")
    out.append("classes:[")
    order = sorted(class_totals.items(), key=lambda kv: (-kv[1], kv[0]))
    first = True
    nb = len(buckets)
    for wc, _tot in order:
        vals = [to_char_fixed(cells.get((b, wc), 0.0), 3) for b in range(1, nb + 1)]
        if first:
            first = False
        else:
            out.append(",")
        out.append('{"name":"' + wc.replace('"', '\\"') + '","vals":[')
        out.extend(put_clob_chunked(",".join(vals)))
        out.append("]}")
    out.append("]};")
    out.append(L[17])
    out.append(L[18])
    out.append("var d=AWR_DATA.dbTimeSummary, palette=" + PALETTE + ";")
    out.extend(L[20:L.index("</script>", 20) + 1])     # verbatim ECharts init .. </script>
    out.append("</section>")
    out.append(L[-1])
    return "\n".join(out)
