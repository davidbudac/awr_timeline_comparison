"""
Twin of sql/11_top_sql_ash_breakdown.sql -- one stacked-area ASH card per
SQL in section 06's Top-N pool, split by individual wait event (top 7 by
sample count, remainder lumped as 'Other', ON-CPU as 'CPU'), over the
same range / bucket grid as section 09.

Pool rule (06's agg/ranked/per_exec/delta_ranked/picked chain, mirrored
here as the SQL does): per VALID window, rank every sql_id by elapsed,
CPU, buffer gets and executions (ties -> sql_id asc); the pool is the
union of the top_n of each dimension (metric > 0) plus the top_n
per-exec regressions (current per-exec > mean prior per-exec, >= 3
current execs).  The pool is then re-ranked by total ASH samples in the
range and capped at 30 charts.

Data source: HourMetrics.ash_sql[sql_id] {event|'CPU': samples} per hour
(Idle events dropped via the fg_events catalog, samples rounded to
integers like ASH's COUNT(*)), HourMetrics.sql for the pool ranking,
World.sql_by_id for text / parsing schema.
"""
from __future__ import annotations

from datetime import timedelta

from awrdemo import chrome, helpers
from awrdemo.helpers import esc, is_oracle_schema, ora_round, to_char_fixed, ts_min

SQL = chrome.sql_path("sql/11_top_sql_ash_breakdown.sql")

TOP_EVENTS = 7
MAX_CHARTS = 30
MIN_SAMPLES = 5


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
    parts = []
    for win in sorted(w.windows, key=lambda x: -x.week_offset):
        lbl = "current" if win.week_offset == 0 else "w-" + str(win.week_offset)
        parts.append('["' + ts_min(win.win_start_ts) + '","' + ts_min(win.win_end_ts)
                     + '","' + lbl + '",' + ('"1"' if win.valid_flag == "Y" else '"0"') + "]")
    return "[" + ",".join(parts) + "]"


def picked_pool(w) -> set[str]:
    """06's picked CTE: union of the four per-window top_n rankings plus
    the top_n per-exec regressions."""
    top_n = w.top_n
    picked: set[str] = set()
    per_exec: dict[str, dict[int, tuple[float | None, float]]] = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        rows = [(sid, x.execs, x.elapsed_us, x.cpu_us, x.gets) for sid, x in m.sql.items()]
        for col, key in ((2, "ela"), (3, "cpu"), (4, "gets"), (1, "exec")):
            ranked = sorted(rows, key=lambda r: (-r[col], r[0]))
            for rn, r in enumerate(ranked, start=1):
                if rn <= top_n and r[col] > 0:
                    picked.add(r[0])
        for sid, execs, ela, _cpu, _gets in rows:
            pe = ela / execs if execs > 0 else None
            per_exec.setdefault(sid, {})[win.week_offset] = (pe, execs)
    deltas = []
    for sid, byw in per_exec.items():
        cur = byw.get(0)
        if cur is None or cur[0] is None:
            continue
        priors = [v[0] for k, v in byw.items() if k > 0 and v[0] is not None]
        if not priors:
            continue
        prior_pe = sum(priors) / len(priors)
        if cur[0] > prior_pe and cur[1] >= 3:
            deltas.append((cur[0] - prior_pe, sid))
    deltas.sort(key=lambda d: (-d[0], d[1]))
    for _d, sid in deltas[:top_n]:
        picked.add(sid)
    return picked


def emit(w) -> str:
    L = [t for t, _ in chrome.put_lines(SQL)]
    out = []
    bh = w.bucket_hours
    range_start = w.target_end - timedelta(hours=w.weeks_back * w.step_hours + w.win_hours)
    range_end = w.target_end
    total_hours = max((range_end - range_start).total_seconds() / 3600, 1)
    total_buckets = max(int(-(-total_hours // bh)), 1)
    hourly = "hourly" if bh == 1 else bucket_label(bh)

    out.append(L[0])
    out.append('<section id="topsql-ash"><h2>Top SQL ASH breakdown (' + hourly
               + ', per SQL, stacked by wait event)</h2>')
    out.append('<p style="font-size:12px;color:var(--muted);margin:0 0 10px 0">'
               'For each SQL in the Top-N pool (union across all ranking dimensions), '
               'per-bucket ASH samples split by individual wait event '
               '(top ' + str(TOP_EVENTS) + ' per SQL by sample count; '
               'remainder grouped as <b>Other</b>; <b>CPU</b> = ON-CPU). '
               '<code>dba_hist_active_sess_history</code>, ' + ts_min(range_start)
               + ' &rarr; ' + ts_min(range_end) + ', ' + hourly
               + ' buckets. Compared windows shaded. '
               'SQLs with fewer than ' + str(MIN_SAMPLES)
               + ' samples appear as placeholders.</p>')

    hours_json = "[" + ",".join('"' + ts_min(range_start + timedelta(hours=b * bh)) + '"'
                                for b in range(total_buckets)) + "]"
    wjson = windows_json(w)

    # ---- raw ASH per (sql_id, bucket, event) over the range, Idle dropped
    idle = {ev.name for ev in w.fg_events if ev.wait_class == "Idle"}
    raw: dict[str, dict[tuple[int, str], int]] = {}
    for m in w.hours(range_start, range_end):
        b = int(((m.ts - timedelta(hours=1)) - range_start).total_seconds() / 3600 / bh)
        for sid, evs in m.ash_sql.items():
            for ev, smp in evs.items():
                if ev in idle:
                    continue
                n = int(ora_round(smp, 0))
                if n <= 0:
                    continue
                d = raw.setdefault(sid, {})
                d[(b, ev)] = d.get((b, ev), 0) + n

    # ---- pool: picked, re-ranked by total ASH samples, capped
    picked = picked_pool(w)
    pool_ranked = sorted(((sum(raw.get(sid, {}).values()), sid) for sid in picked),
                         key=lambda t: (-t[0], t[1]))
    pool = [sid for _tot, sid in pool_ranked[:MAX_CHARTS]]

    # ---- lump events beyond the top 7 per SQL into 'Other'
    cells: dict[tuple[str, int, str], int] = {}
    evt_totals: dict[str, dict[str, int]] = {}
    sql_totals: dict[str, int] = {}
    for sid in pool:
        d = raw.get(sid, {})
        if not d:
            continue
        et: dict[str, int] = {}
        for (b, ev), n in d.items():
            et[ev] = et.get(ev, 0) + n
        ranking = sorted(et.items(), key=lambda kv: (-kv[1], kv[0]))
        keep = {ev for ev, _ in ranking[:TOP_EVENTS]}
        for (b, ev), n in d.items():
            name = ev if ev in keep else "Other"
            cells[(sid, b, name)] = cells.get((sid, b, name), 0) + n
            evt_totals.setdefault(sid, {})[name] = evt_totals.setdefault(sid, {}).get(name, 0) + n
            sql_totals[sid] = sql_totals.get(sid, 0) + n

    if not sql_totals:
        out.append(L[3])
        out.append("</section>")
        out.append(L[75])
        return "\n".join(out)

    order = sorted(sql_totals.items(), key=lambda kv: (-kv[1], kv[0]))
    dom = {sid: sorted(evt_totals[sid].items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
           for sid, _ in order}

    def sql_text(sid: str) -> str:
        s = w.sql_by_id.get(sid)
        if s is None:
            return "(sql text not available)"
        return s.text[:200].replace("\n", " ").replace("\r", " ")[:200]

    def sql_sys(sid: str) -> str:
        s = w.sql_by_id.get(sid)
        return is_oracle_schema(s.schema if s else None)

    # ---- cards
    rendered = 0
    skipped = 0
    below = []
    for sid, tot in order:
        if tot < MIN_SAMPLES:
            skipped += 1
            below.append(esc(sid) + " (" + str(tot) + ")")
            continue
        rendered += 1
        out.append('<div class="ash-sql-card" data-sys="' + sql_sys(sid) + '">')
        out.append('  <div class="ash-sql-head"><code>' + esc(sid) + '</code> &middot; '
                   '<span class="ash-sql-meta">' + str(tot) + ' ASH samples &middot; dominant: <b>'
                   + esc(dom.get(sid, "n/a")) + '</b></span></div>')
        out.append('  <pre class="ash-sql-snippet">' + esc(sql_text(sid)) + '</pre>')
        out.append('  <div class="chart-wrap chart-ash-sql" id="ash-sql-' + sid + '"></div>')
        out.append("</div>")
    if skipped > 0:
        out.append('<details class="method"><summary>' + str(skipped) + ' SQLs below the '
                   + str(MIN_SAMPLES) + '-sample ASH threshold, listed without a chart</summary>'
                   '<p class="mono">' + " &middot; ".join(below) + '</p></details>')
        out.append('<p class="ash-sql-footnote" style="font-size:11px;color:var(--muted);margin:8px 0 0 0">'
                   'Showing ' + str(rendered) + ' SQL chart(s); ' + str(skipped)
                   + ' SQL(s) had fewer than ' + str(MIN_SAMPLES)
                   + ' ASH samples and are listed as placeholders.</p>')

    # ---- JS payload + per-chart init
    out.append(L[12])   # <script>
    out.append(L[13])   # (function(){
    out.append(L[14])   # AWR_DATA.topSqlAsh = {
    out.append("hours:")
    out.extend(put_clob_chunked(hours_json))
    out.append(",")
    out.append("windows:" + wjson + ",")
    out.append("charts:[")
    first_sql = True
    for sid, tot in order:
        if tot < MIN_SAMPLES:
            continue
        events = sorted(evt_totals[sid].items(), key=lambda kv: (-kv[1], kv[0]))
        if first_sql:
            first_sql = False
        else:
            out.append(",")
        out.append('{id:"ash-sql-' + sid + '",sqlId:"' + sid + '",total:' + str(tot) + ',events:[')
        first_evt = True
        for ev, etot in events:
            vals = [to_char_fixed(cells.get((sid, b, ev), 0) / (bh * 360), 4)
                    for b in range(total_buckets)]
            if first_evt:
                first_evt = False
            else:
                out.append(",")
            out.append('{"name":"' + ev.replace('"', '\\"') + '","total":' + str(etot) + ',"vals":[')
            out.extend(put_clob_chunked(",".join(vals)))
            out.append("]}")
        out.append("]}")
    out.append("]};")
    out.extend(L[26:74])     # verbatim bootstrap .. </script>
    out.append("</section>")
    out.append(L[75])
    return "\n".join(out)
