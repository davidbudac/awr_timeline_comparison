"""
Twin of sql/18_sqlmon.sql -- SQL Monitor summaries + the execution scatter,
including the per-statement "Plan hash" column (Current window's slowest
execution's plan vs. the prior windows' dominant plan).

Walks the original's DBMS_OUTPUT.PUT_LINE calls top to bottom; every
element / class / id / data-* hook and the AWR_DATA.sqlmon payload keep
the SQL's names and shape.  The ECharts script is lifted verbatim from
the SQL source via chrome.put_lines (only the AWR_DATA line is dynamic).

Data: w.monexecs() plays DBA_HIST_REPORTS' report_summary XMLTABLE rows.
"""
from __future__ import annotations

from statistics import median

from .. import chrome
from ..helpers import (esc, fmt_int, fmt_num, fmt_num_title, is_oracle_schema,
                       json_escape, mean_sd, num6, score_cells, to_char_fixed,
                       to_char_int, ts_min, ts_sec, z_and_pct)

SQL_FILE = "sql/18_sqlmon.sql"
FLOOR_US = 1_000_000
SCATTER_CAP = 3000
CHUNK = 32500                      # put_clob_chunked.plsql c_chunk


# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------

def _nvl0(x):
    return 0 if x is None else x


def _put_clob_chunked(payload: str) -> list[str]:
    """sql/lib/put_clob_chunked.plsql: one PUT_LINE per <=32500-char chunk,
    every non-final chunk backed off to end on its last comma."""
    out = []
    pos, n = 0, len(payload)
    if n == 0:
        return out
    while pos < n:
        take = min(CHUNK, n - pos)
        if pos + take < n:
            cut = payload.rfind(",", pos, pos + take)
            if cut >= pos:
                take = cut - pos + 1
        out.append(payload[pos:pos + take])
        pos += take
    return out


def _plan_list(ms) -> str | None:
    """Distinct non-zero plan_hash values among ms, most frequent first,
    capped at 5 with a trailing ellipsis -- mirrors the SQL's
    window_plan_agg CTE (feeds the per-window 'Plan hash(es)' cell)."""
    cnt: dict = {}
    for m in ms:
        if m.plan_hash != 0:
            cnt[m.plan_hash] = cnt.get(m.plan_hash, 0) + 1
    if not cnt:
        return None
    ordered = sorted(cnt.keys(), key=lambda ph: (-cnt[ph], ph))
    shown = ordered[:5]
    s = " ".join(str(ph) for ph in shown)
    if len(ordered) > 5:
        s += "&hellip;"
    return s


def _cur_plan(rows):
    """Plan hash of the Current window's slowest execution; falls back to
    the most-frequent non-zero plan_hash in the Current window when that
    execution's own plan_hash is 0; None if no non-zero plan is available."""
    cur = [m for m, off in rows if off == 0]
    if not cur:
        return None
    best = min(cur, key=lambda m: (0 if m.plan_hash != 0 else 1, -_nvl0(m.elapsed_us), m.report_id))
    if best.plan_hash != 0:
        return best.plan_hash
    cnt: dict = {}
    for m in cur:
        if m.plan_hash != 0:
            cnt[m.plan_hash] = cnt.get(m.plan_hash, 0) + 1
    return min(cnt, key=lambda ph: (-cnt[ph], ph)) if cnt else None


def _prior_plan(rows):
    """Most-frequent non-zero plan_hash across the prior VALID windows;
    tie -> the one with the most recent exec_start."""
    cnt: dict = {}
    last_ts: dict = {}
    for m, off in rows:
        if off is not None and off > 0 and m.plan_hash != 0:
            cnt[m.plan_hash] = cnt.get(m.plan_hash, 0) + 1
            last_ts[m.plan_hash] = max(last_ts.get(m.plan_hash, m.exec_start), m.exec_start)
    if not cnt:
        return None
    return max(cnt, key=lambda ph: (cnt[ph], last_ts[ph]))


def _drill_sql(rid) -> str:
    return "SELECT DBMS_AUTO_REPORT.REPORT_REPOSITORY_DETAIL(rid=>" + str(rid) + ", type=>'ACTIVE') FROM dual;"


# ---------------------------------------------------------------------
# emitter
# ---------------------------------------------------------------------

def emit(w) -> str:
    L = []
    put = L.append
    top_n = w.top_n
    weeks_back = w.weeks_back

    put("<!-- AWR-SECTION: 18_sqlmon BEGIN -->")
    put('<section id="sqlmon"><h2>SQL Monitor</h2>')
    put('<p style="font-size:12px;color:var(--muted)">'
        "Executions persisted by Oracle SQL Monitor "
        "(<code>DBA_HIST_REPORTS</code>, <code>component_name='sqlmonitor'</code>), "
        "summaries only. "
        "<b>Sampling caveats:</b> only completed, expensive-enough or parallel "
        "executions are ever persisted, so a statement's absence here does not "
        "mean it ran fast, and row counts are not execution-rate counts. An "
        "execution still running at the report end has no final row yet, so the "
        "Current window can under-report its slowest statement. Rows are "
        "attributed to a window by execution <i>start</i> time, so a long "
        "execution can straddle a window boundary.</p>")

    # -- span (windows_rollup MIN/MAX) --------------------------------
    span_start = min(x.win_start_ts for x in w.windows)
    span_end = max(x.win_end_ts for x in w.windows)
    valid = [x for x in w.windows if x.valid]

    def offset_of(ts):
        for x in valid:
            if x.win_start_ts <= ts < x.win_end_ts:
                return x.week_offset
        return None

    # base_execs / with_offset
    execs = [m for m in w.monexecs() if span_start <= m.exec_start < span_end]
    raw_total = len(execs)
    if raw_total == 0:
        put('<p style="font-size:12px;color:var(--muted)">'
            "No SQL Monitor reports persisted in the compared windows ("
            + ts_min(span_start) + " &rarr; " + ts_min(span_end) + ").</p></section>")
        put("<!-- AWR-SECTION: 18_sqlmon END -->")
        return "\n".join(L) + "\n"

    wo = [(m, offset_of(m.exec_start)) for m in execs]
    by_sql: dict[str, list] = {}
    for m, off in wo:
        by_sql.setdefault(m.sql_id, []).append((m, off))

    # sqlid_span_stats / included / new_flag
    cur_start = min(x.win_start_ts for x in w.windows if x.week_offset == 0)
    stats = {}
    for sid, rows in by_sql.items():
        ms = [m for m, _ in rows]
        last = max(rows, key=lambda r: (r[0].exec_start, r[0].report_id))[0]
        stats[sid] = {
            "has_long": int(any(_nvl0(m.elapsed_us) >= FLOOR_US for m in ms)),
            "has_error": int(any(m.status == "DONE (ERROR)" for m in ms)),
            "distinct_plans": len({m.plan_hash for m in ms if m.plan_hash != 0}),
            "has_downgrade": int(any(m.px_alloc < m.px_req for m in ms)),
            "total_execs": len(ms),
            "span_max_all": max(_nvl0(m.elapsed_us) for m in ms) / 1e6,
            "last_username": last.username,
            "last_module": last.module,
            "is_new": "Y" if (any(off == 0 for _, off in rows)
                              and not any(m.exec_start < cur_start for m, _ in rows)) else "N",
        }
    included = [sid for sid, st in stats.items()
                if st["has_long"] == 1 or st["has_error"] == 1 or st["distinct_plans"] > 1]

    # per_window (valid windows only) -> grid -> pivoted
    per_window = {}
    for sid in included:
        for m, off in by_sql[sid]:
            if off is None:
                continue
            per_window.setdefault((sid, off), []).append(m)
    grid = {}
    for sid in included:
        for k in range(weeks_back + 1):
            ms = per_window.get((sid, k))
            if not ms:
                grid[(sid, k)] = None
                continue
            el = [_nvl0(m.elapsed_us) for m in ms]
            grid[(sid, k)] = {
                "n": len(ms),
                "max_elapsed_s": max(el) / 1e6,
                "median_elapsed_s": median(el) / 1e6,
                "max_io_bytes": max(_nvl0(m.read_bytes) + _nvl0(m.write_bytes) for m in ms),
                "max_px_req": max(m.px_req for m in ms),
                "max_px_alloc": max(m.px_alloc for m in ms),
                "plan_list": _plan_list(ms),
                "err_cnt": sum(1 for m in ms if m.status == "DONE (ERROR)"),
            }
    pivot = {}
    for sid in included:
        cells = [grid[(sid, k)] for k in range(weeks_back + 1)]
        if all(c is None for c in cells):
            pivot[sid] = None        # LEFT JOIN pivoted: no per-window row at all
            continue
        cur = cells[0]["max_elapsed_s"] if cells[0] else None
        priors = [c["max_elapsed_s"] for c in cells[1:] if c]
        mu, sd, n = mean_sd(priors)
        pivot[sid] = {"cur_val": cur, "mu": mu, "sd": sd, "n_prior": n}

    # cur_plan / prior_plan / plan_changed: the "Plan hash" column.
    cur_plan_of, prior_plan_of, plan_changed_of = {}, {}, {}
    for sid in included:
        cur_plan_of[sid] = _cur_plan(by_sql[sid])
        prior_plan_of[sid] = _prior_plan(by_sql[sid])
        plan_changed_of[sid] = (
            "Y" if (cur_plan_of[sid] is not None and prior_plan_of[sid] is not None
                    and cur_plan_of[sid] != prior_plan_of[sid]) else "N")

    def drill_id(sid):
        rows = by_sql[sid]
        cur = [m for m, off in rows if off == 0]
        pool = cur if cur else [m for m, _ in rows]
        return min(pool, key=lambda m: (-_nvl0(m.elapsed_us), m.report_id)).report_id

    ranked = sorted(included, key=lambda sid: (
        0 if (pivot[sid] and pivot[sid]["cur_val"] is not None) else 1,
        -(pivot[sid]["cur_val"] if pivot[sid] and pivot[sid]["cur_val"] is not None else 0),
        -stats[sid]["span_max_all"], sid))
    sqlid_count = len(ranked)
    shown_total = 0
    tail_cnt = nocur_cnt = 0

    # -- per-statement comparison table ---------------------------------
    if ranked:
        put("<h3>Per-statement comparison (top " + str(top_n) + ")</h3>")
        header = ('<thead><tr><th>SQL ID</th><th>User / module</th>'
                  '<th title="plan_hash_value of the slowest Current-window execution; '
                  'prior = the most frequent plan in the prior compared windows">Plan hash</th>'
                  '<th class="trend">Trend</th>'
                  '<th class="num" data-w="0">Current max elapsed (s)</th>'
                  '<th class="num">Prior mean (s)</th>'
                  '<th>Change</th><th class="num">z-score</th>'
                  '<th class="num">% &Delta;</th><th>Flags</th></tr></thead>')
        put('<table id="sqlmon-pool" data-nosort data-notools>' + header + "<tbody>")

    normal = False
    for rnk, sid in enumerate(ranked, start=1):
        st = stats[sid]
        p = pivot[sid] or {"cur_val": None, "mu": None, "sd": None, "n_prior": 0}
        shown_total += st["total_execs"]
        cells = [grid[(sid, k)] for k in range(weeks_back + 1)]
        spark = ",".join("" if c is None else num6(c["max_elapsed_s"]) for c in reversed(cells))

        plan_changed = plan_changed_of[sid]
        cur_plan, prior_plan = cur_plan_of[sid], prior_plan_of[sid]

        flags = ""
        if plan_changed == "Y":
            flags += '<span class="chip" title="Current plan differs from the prior windows\' dominant plan">plan changed</span> '
        elif st["distinct_plans"] > 1:
            flags += '<span class="chip" title="more than one execution plan seen in the compared span">plan change</span> '
        if st["has_downgrade"] == 1:
            flags += '<span class="chip" title="an execution got fewer parallel servers than requested">DOP downgrade</span> '
        if st["has_error"] == 1:
            flags += '<span class="chip" title="at least one execution ended DONE (ERROR)">error</span> '
        if st["is_new"] == "Y":
            flags += '<span class="chip" title="no captured execution anywhere in the span before the Current window">new</span> '

        if plan_changed == "Y":
            plancell = ('<span class="badge warn" title="plan changed vs. the prior windows\' dominant plan">plan changed</span> <s>'
                        + str(prior_plan) + "</s> &rarr; <b>" + str(cur_plan) + "</b>")
        elif cur_plan is not None:
            plancell = str(cur_plan)
            if st["distinct_plans"] > 1 and cur_plan == prior_plan:
                plancell += ' <span class="badge note" title="another plan was also seen in the span">+other</span>'
        elif prior_plan is not None:
            plancell = '<span style="color:var(--muted)">' + str(prior_plan) + "</span>"
        else:
            plancell = "&mdash;"

        if (p["cur_val"] is not None and rnk <= top_n
                and (st["has_error"] == 1 or st["distinct_plans"] > 1 or st["has_downgrade"] == 1
                     or plan_changed == "Y")
                and not normal):
            normal = True
            put('<script>document.getElementById("sqlmon").setAttribute("data-normal","Y");</script>')

        sysflag = is_oracle_schema(st["last_username"])
        tail = ' data-tail="Y" hidden' if (rnk > top_n or p["cur_val"] is None) else ""
        if tail:
            tail_cnt += 1
            if p["cur_val"] is None:
                nocur_cnt += 1
        put('<tr id="sqlmon-' + sid + '" data-sys="' + sysflag + '"' + tail + ">"
            + '<td class="mono">' + sid
            + ' <a class="xlink" href="#sql-' + sid + '" title="This SQL in the Top SQL pool">&#8599; Top SQL</a></td>'
            + "<td>" + esc(st["last_username"] if st["last_username"] is not None else "?")
            + " / " + esc(st["last_module"] if st["last_module"] is not None else "?") + "</td>"
            + '<td class="mono">' + plancell + "</td>"
            + '<td class="trend" data-spark="' + spark
            + '" data-spark-title="max elapsed (s), ' + sid + '"></td>'
            + '<td class="num" data-w="0"' + fmt_num_title(p["cur_val"]) + "><b>"
            + fmt_num(p["cur_val"]) + "</b></td>"
            + '<td class="num">' + fmt_num(p["mu"]) + "</td>"
            + score_cells(p["cur_val"], p["mu"], p["sd"], p["n_prior"])
            + "<td>" + flags + "</td>"
            + "</tr>")

        put('<tr class="sqlmon-detail" data-sys="' + sysflag + '"' + tail + '><td colspan="10">')
        put("<details><summary>Per-window detail &amp; drill</summary>")
        put('<table data-notools><thead><tr><th>Window</th><th class="num">n</th>'
            '<th class="num">Max elapsed (s)</th><th class="num">Median elapsed (s)</th>'
            '<th class="num" title="largest read + write bytes of one execution">Max I/O (bytes)</th>'
            '<th class="num" title="parallel servers requested / allocated (max per execution)">DOP req/alloc</th>'
            '<th title="distinct plan_hash_values in the window, most frequent first">Plan hash(es)</th>'
            '<th class="num" title="executions that ended DONE (ERROR)">Errors</th></tr></thead><tbody>')
        for k in range(weeks_back + 1):
            c = cells[k]
            label = "Current" if k == 0 else "&minus;" + w.offset_labels[k - 1]
            if c is None:
                n_s = me = med = io = dop = pl = er = "&mdash;"
            else:
                n_s = fmt_int(c["n"])
                me = fmt_num(c["max_elapsed_s"])
                med = fmt_num(c["median_elapsed_s"])
                io = fmt_num(c["max_io_bytes"])
                dop = fmt_int(c["max_px_req"]) + "/" + fmt_int(c["max_px_alloc"]) + (
                    ' <span class="badge warn">downgrade</span>'
                    if c["max_px_alloc"] < c["max_px_req"] else "")
                pl = c["plan_list"] if c["plan_list"] else "&mdash;"
                er = ('<span class="badge crit">' + to_char_int(c["err_cnt"]) + "</span>"
                      if c["err_cnt"] > 0 else fmt_int(c["err_cnt"]))
            put("<tr" + (' class="cur"' if k == 0 else "") + ">"
                + '<td data-w="' + str(k) + '">' + label + "</td>"
                + '<td class="num">' + n_s + "</td>"
                + '<td class="num">' + me + "</td>"
                + '<td class="num">' + med + "</td>"
                + '<td class="num">' + io + "</td>"
                + '<td class="num">' + dop + "</td>"
                + '<td class="mono">' + pl + "</td>"
                + '<td class="num">' + er + "</td>"
                + "</tr>")
        put("</tbody></table>")
        put('<div class="codewrap" style="position:relative">')
        put('<button type="button" class="copy-btn" data-copy="#sqlmon-drill-' + sid + '">Copy</button>')
        put('<pre id="sqlmon-drill-' + sid + '" class="sql">' + esc(_drill_sql(drill_id(sid))) + "</pre></div>")
        put("</details></td></tr>")

    if ranked:
        put("</tbody></table>")
        if tail_cnt > 0:
            noun = "more statements" + (" (" + str(nocur_cnt) + " without a Current-window execution)"
                                        if nocur_cnt > 0 else "")
            put('<span class="expander" data-for="sqlmon-pool" data-n="' + str(tail_cnt)
                + '" data-noun="' + noun + '">&#9656; Show ' + str(tail_cnt) + " " + noun + "</span>")
        put('<p style="font-size:11px;color:var(--muted);margin:6px 0 0">'
            + fmt_int(raw_total) + " execution" + ("" if raw_total == 1 else "s")
            + " captured in the compared span; " + fmt_int(shown_total)
            + " across " + str(sqlid_count) + " statement" + ("" if sqlid_count == 1 else "s")
            + " met the inclusion floor (elapsed &ge; 1&nbsp;s, an error, or more than one "
            "execution plan) and are shown above.</p>")
    else:
        put('<p style="font-size:12px;color:var(--muted)">'
            + fmt_int(raw_total) + " execution" + ("" if raw_total == 1 else "s")
            + " captured in the compared span, but none met the inclusion floor "
            "(elapsed &ge; 1&nbsp;s, an error, or more than one execution plan). "
            "The scatter below still plots every captured execution.</p>")

    # -- execution scatter ------------------------------------------------
    put("<h3>Execution scatter (full compared span)</h3>")
    put('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
        "Every captured execution, x = start time, y = elapsed (log scale). "
        "Diamond = error, triangle = a plan different from that sql_id's most "
        "common plan, size &prop; requested DOP. Colored series are the top "
        + str(top_n) + " statements by Current-window max elapsed; grey = everything else.</p>")
    put('<div class="chart-wrap chart-medium" id="sqlmon-scatter"></div>')

    windows_json = "[" + ",".join(
        '["' + ts_min(x.win_start_ts) + '","' + ts_min(x.win_end_ts) + '","'
        + ("current" if x.week_offset == 0 else "w-" + str(x.week_offset)) + '",'
        + ('"1"' if x.valid else '"0"') + "]"
        for x in sorted(w.windows, key=lambda x: -x.week_offset)) + "]"
    weeks_iso_json = "[" + ",".join(
        '"' + ts_min(x.win_start_ts) + '"'
        for x in sorted(w.windows, key=lambda x: x.week_offset)) + "]"

    # top-N sql_ids by Current-window max elapsed (same floor, recomputed)
    top = []
    for sid in included:
        rows = by_sql[sid]
        cur = [_nvl0(m.elapsed_us) for m, off in rows if off == 0]
        top.append((0 if cur else 1, -(max(cur) if cur else 0),
                    -max(_nvl0(m.elapsed_us) for m, _ in rows), sid))
    top.sort()
    top_ids = [t[3] for t in top[:top_n]]
    top_ids_json = "[" + ",".join('"' + json_escape(s) + '"' for s in top_ids) + "]"

    # mode plan per sql_id (most frequent non-zero plan, tie -> lowest hash)
    mode_plan = {}
    for sid, rows in by_sql.items():
        cnt = {}
        for m, _ in rows:
            if m.plan_hash != 0:
                cnt[m.plan_hash] = cnt.get(m.plan_hash, 0) + 1
        if cnt:
            mode_plan[sid] = min(cnt, key=lambda ph: (-cnt[ph], ph))

    points_total = len(execs)
    recent = sorted(execs, key=lambda m: (m.exec_start, m.report_id), reverse=True)[:SCATTER_CAP]
    recent.sort(key=lambda m: (m.exec_start, m.report_id))
    pts = []
    for m in recent:
        mp = mode_plan.get(m.sql_id)
        pm = "Y" if (mp is not None and m.plan_hash != 0 and m.plan_hash != mp) else "N"
        pts.append('{"t":"' + ts_sec(m.exec_start) + '"'
                   + ',"e":' + to_char_fixed(max(_nvl0(m.elapsed_us) / 1e6, 0.0001), 4)
                   + ',"id":"' + json_escape(m.sql_id) + '"'
                   + ',"st":"' + json_escape(m.status if m.status is not None else "?") + '"'
                   + ',"ph":' + str(m.plan_hash if m.plan_hash is not None else 0)
                   + ',"dop":' + str(m.px_req if m.px_req is not None else 0)
                   + ',"pm":"' + pm + '"}')
    points_shown = len(pts)
    capped = points_total > SCATTER_CAP

    # script: lifted verbatim from the SQL (only the AWR_DATA line is dynamic)
    lines = [t for t, _ in chrome.put_lines(chrome.sql_path(SQL_FILE))]
    i0 = lines.index("<script>(function(){")
    i1 = lines.index("})();</script>")
    put(lines[i0])
    put('AWR_DATA.sqlmon = {spanStart:"' + ts_min(span_start)
        + '",spanEnd:"' + ts_min(span_end)
        + '",topIds:' + top_ids_json
        + ",windows:" + windows_json
        + ",weeksIso:" + weeks_iso_json
        + ",capped:" + ("true" if capped else "false")
        + ",totalRaw:" + str(points_total)
        + ",shown:" + str(points_shown)
        + ",points:[")
    for chunk in _put_clob_chunked(",".join(pts)):
        put(chunk)
    for t in lines[i0 + 2:i1 + 1]:
        if not capped and (t.startswith('var el0=document.getElementById("sqlmon-scatter")')
                           or t.startswith("if(el0){var note=")):
            continue
        put(t)

    put("</section>")
    put("<!-- AWR-SECTION: 18_sqlmon END -->")
    return "\n".join(L) + "\n"
