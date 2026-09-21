"""
Twin of sql/18_sqlmon.sql -- SQL Monitor summaries (phase 1) + plan-line
drift (phase 2, sqlmon_detail > 0) + the execution scatter.

Walks the original's DBMS_OUTPUT.PUT_LINE calls top to bottom; every
element / class / id / data-* hook and the AWR_DATA.sqlmon payload keep
the SQL's names and shape.  The ECharts script is lifted verbatim from
the SQL source via chrome.put_lines (only the AWR_DATA line is dynamic).

Data: w.monexecs() plays DBA_HIST_REPORTS' report_summary XMLTABLE rows;
w.plan_lines(sql_id, plan_hash, exec) plays the two
DBA_HIST_REPORTS_DETAILS plan_monitor/operation XMLTABLEs of phase 2.
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


def _bucket_rank(cur_val, mu, sd, n_prior) -> int:
    """The drift candidate ORDER BY CASE (1 large / 2 moderate / 3 rest)."""
    if n_prior is not None and n_prior >= 3 and sd is not None and sd != 0 and cur_val is not None:
        z = abs((cur_val - mu) / sd)
        if z > 3:
            return 1
        if z > 2:
            return 2
    return 3


def _plan_rows(w, sql_id, cur_m, base_m, cur_total_s, base_total_s):
    """The FULL OUTER JOIN of the two plan XMLTABLEs, ORDER BY line_id.
    Join key: line_id, NVL(op,'-'), NVL(owner,'')||'.'||NVL(name,'')."""
    def norm(lines):
        out = []
        for l in lines:
            out.append({
                "line_id": l.id, "op": l.name or None, "options": l.options or None,
                "depth": l.depth, "owner": l.owner or None, "obj": l.obj or None,
                "est_rows": l.est_rows, "starts": l.starts, "act_rows": l.act_rows,
                "dur_s": l.duration_s, "max_mem": l.max_mem,
            })
        return out

    def key(r):
        return (r["line_id"], r["op"] if r["op"] is not None else "-",
                (r["owner"] or "") + "." + (r["obj"] or ""))

    cl = norm(w.plan_lines(sql_id, cur_m.plan_hash, cur_m))
    bl = norm(w.plan_lines(sql_id, base_m.plan_hash, base_m))
    bmap = {}
    for r in bl:
        bmap.setdefault(key(r), []).append(r)
    rows = []
    used = set()
    for c in cl:
        k = key(c)
        b = None
        if bmap.get(k):
            b = bmap[k].pop(0)
            used.add(id(b))
        rows.append(_join_row(c, b, cur_total_s, base_total_s))
    for b in bl:
        if id(b) not in used:
            rows.append(_join_row(None, b, cur_total_s, base_total_s))
    # ORDER BY line_id (ties: Current-side rows before baseline-only ones --
    # Oracle leaves that order unspecified).
    rows.sort(key=lambda r: (r["line_id"], 1 if r["only_side"] == "BASE" else 0))
    return rows


def _join_row(c, b, cur_total_s, base_total_s):
    src = c if c is not None else b
    op = (c["op"] if c is not None and c["op"] is not None else (b["op"] if b else None))
    opts = (c["options"] if c is not None and c["options"] is not None
            else (b["options"] if b else None))
    op_txt = (op or "") + ((" (" + opts + ")") if opts is not None else "")
    if op is None and opts is None:
        op_txt = None
    return {
        "line_id": src["line_id"],
        "op_txt": op_txt,
        "depth": src["depth"],
        "obj_owner": (c["owner"] if c is not None and c["owner"] is not None else (b["owner"] if b else None)),
        "obj_name": (c["obj"] if c is not None and c["obj"] is not None else (b["obj"] if b else None)),
        "est_rows": (c["est_rows"] if c is not None and c["est_rows"] is not None else (b["est_rows"] if b else None)),
        "base_starts": b["starts"] if b else None, "cur_starts": c["starts"] if c else None,
        "base_rows": b["act_rows"] if b else None, "cur_rows": c["act_rows"] if c else None,
        "base_dur": b["dur_s"] if b else None, "cur_dur": c["dur_s"] if c else None,
        "base_mem": b["max_mem"] if b else None, "cur_mem": c["max_mem"] if c else None,
        "base_share": (b["dur_s"] / base_total_s * 100) if (b and base_total_s > 0 and b["dur_s"] is not None) else None,
        "cur_share": (c["dur_s"] / cur_total_s * 100) if (c and cur_total_s > 0 and c["dur_s"] is not None) else None,
        "only_side": "BASE" if c is None else ("CUR" if b is None else None),
    }


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
    detail_n = w.sqlmon_detail

    put("<!-- AWR-SECTION: 18_sqlmon BEGIN -->")
    put('<section id="sqlmon"><h2>SQL Monitor</h2>')
    if detail_n > 0:
        lede = ("summaries, plus plan-line drift detail below for the top "
                + str(detail_n) + " regressed statement" + ("" if detail_n == 1 else "s") + ". ")
    else:
        lede = "summaries only &mdash; no plan-line detail (phase 2, not implemented). "
    put('<p style="font-size:12px;color:var(--muted)">'
        "Executions persisted by Oracle SQL Monitor "
        "(<code>DBA_HIST_REPORTS</code>, <code>component_name='sqlmonitor'</code>), "
        + lede +
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
                "plans": len({m.plan_hash for m in ms if m.plan_hash != 0}),
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

    # -- per-statement comparison table ---------------------------------
    if ranked:
        put("<h3>Per-statement comparison (top " + str(top_n) + ")</h3>")
        header = ('<thead><tr><th>SQL ID</th><th>User / module</th>'
                  '<th class="trend">Trend</th>'
                  '<th class="num" data-w="0">Current max elapsed (s)</th>'
                  '<th class="num">Prior mean (s)</th>'
                  '<th>Change</th><th class="num">z-score</th>'
                  '<th class="num">% &Delta;</th><th>Flags</th></tr></thead>')
        put('<table id="sqlmon-pool" data-nosort data-notools>' + header + "<tbody>")

    for rnk, sid in enumerate(ranked, start=1):
        st = stats[sid]
        p = pivot[sid] or {"cur_val": None, "mu": None, "sd": None, "n_prior": 0}
        shown_total += st["total_execs"]
        cells = [grid[(sid, k)] for k in range(weeks_back + 1)]
        spark = ",".join("" if c is None else num6(c["max_elapsed_s"]) for c in reversed(cells))

        flags = ""
        if st["distinct_plans"] > 1:
            flags += '<span class="chip" title="more than one execution plan seen in the compared span">plan change</span> '
        if st["has_downgrade"] == 1:
            flags += '<span class="chip" title="an execution got fewer parallel servers than requested">DOP downgrade</span> '
        if st["has_error"] == 1:
            flags += '<span class="chip" title="at least one execution ended DONE (ERROR)">error</span> '
        if st["is_new"] == "Y":
            flags += '<span class="chip" title="no captured execution anywhere in the span before the Current window">new</span> '

        sysflag = is_oracle_schema(st["last_username"])
        tail = ' data-tail="Y" hidden' if rnk > top_n else ""
        put('<tr id="sqlmon-' + sid + '" data-sys="' + sysflag + '"' + tail + ">"
            + '<td class="mono">' + sid
            + ' <a class="xlink" href="#sql-' + sid + '" title="This SQL in the Top SQL pool">&#8599; Top SQL</a></td>'
            + "<td>" + esc(st["last_username"] if st["last_username"] is not None else "?")
            + " / " + esc(st["last_module"] if st["last_module"] is not None else "?") + "</td>"
            + '<td class="trend" data-spark="' + spark
            + '" data-spark-title="max elapsed (s), ' + sid + '"></td>'
            + '<td class="num" data-w="0"' + fmt_num_title(p["cur_val"]) + "><b>"
            + fmt_num(p["cur_val"]) + "</b></td>"
            + '<td class="num">' + fmt_num(p["mu"]) + "</td>"
            + score_cells(p["cur_val"], p["mu"], p["sd"], p["n_prior"])
            + "<td>" + flags + "</td>"
            + "</tr>")

        put('<tr class="sqlmon-detail" data-sys="' + sysflag + '"' + tail + '><td colspan="9">')
        put("<details><summary>Per-window detail &amp; drill</summary>")
        put('<table data-notools><thead><tr><th>Window</th><th class="num">n</th>'
            '<th class="num">Max elapsed (s)</th><th class="num">Median elapsed (s)</th>'
            '<th class="num">Max IO</th><th class="num">DOP req/alloc</th>'
            '<th class="num">Plans</th><th class="num">Err</th></tr></thead><tbody>')
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
                pl = fmt_int(c["plans"])
                er = ('<span class="badge crit">' + to_char_int(c["err_cnt"]) + "</span>"
                      if c["err_cnt"] > 0 else fmt_int(c["err_cnt"]))
            put("<tr" + (' class="cur"' if k == 0 else "") + ">"
                + '<td data-w="' + str(k) + '">' + label + "</td>"
                + '<td class="num">' + n_s + "</td>"
                + '<td class="num">' + me + "</td>"
                + '<td class="num">' + med + "</td>"
                + '<td class="num">' + io + "</td>"
                + '<td class="num">' + dop + "</td>"
                + '<td class="num">' + pl + "</td>"
                + '<td class="num">' + er + "</td>"
                + "</tr>")
        put("</tbody></table>")
        put('<div class="codewrap" style="position:relative">')
        put('<button type="button" class="copy-btn" data-copy="#sqlmon-drill-' + sid + '">Copy</button>')
        put('<pre id="sqlmon-drill-' + sid + '" class="sql">' + esc(_drill_sql(drill_id(sid))) + "</pre></div>")
        put("</details></td></tr>")

    if ranked:
        put("</tbody></table>")
        if sqlid_count > top_n:
            more = sqlid_count - top_n
            put('<span class="expander" data-for="sqlmon-pool" data-n="' + str(more)
                + '" data-noun="more statements">&#9656; Show ' + str(more) + " more statements</span>")
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

    # -- phase 2: plan-line drift ---------------------------------------
    if detail_n > 0:
        put("<h3>Plan-line drift (top " + str(detail_n) + " regressed)</h3>")
        put('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
            "For each candidate below: the Current window's slowest execution "
            "(plan_hash &lt;&gt; 0) vs. the prior-window execution closest to the "
            "prior median elapsed, diffed line-by-line from "
            "<code>DBA_HIST_REPORTS_DETAILS</code> (no activity-% in the stored "
            "XML -- starts / actual rows / duration / memory only).</p>")

        cands = []
        for sid in included:
            rows = by_sql[sid]
            cur_pool = [m for m, off in rows if off == 0 and m.plan_hash != 0]
            prior_pool = [m for m, off in rows if off is not None and off > 0 and m.plan_hash != 0]
            if not cur_pool or not prior_pool:
                continue
            cb = min(cur_pool, key=lambda m: (-_nvl0(m.elapsed_us), m.report_id))
            med = median([_nvl0(m.elapsed_us) for m in prior_pool])
            pb = min(prior_pool, key=lambda m: (abs(_nvl0(m.elapsed_us) - med), -m.exec_start.timestamp()))
            p = pivot[sid] or {"cur_val": None, "mu": None, "sd": None, "n_prior": 0}
            cands.append((_bucket_rank(p["cur_val"], p["mu"], p["sd"], p["n_prior"]),
                          -_nvl0(cb.elapsed_us), sid, cb, pb))
        cands.sort(key=lambda t: (t[0], t[1]))
        cands = cands[:detail_n]

        for _, _, sid, cb, pb in cands:
            cur_total_s = _nvl0(cb.elapsed_us) / 1e6
            base_total_s = _nvl0(pb.elapsed_us) / 1e6
            plan_note = ""
            if cb.plan_hash != pb.plan_hash:
                plan_note = (" &mdash; <b>plan changed: " + str(pb.plan_hash) + " &rarr; " + str(cb.plan_hash)
                             + "</b>; lines matched by id/operation/object, unmatched lines shown one-sided")
            put('<div class="sqlmon-drift">')
            put('<h4 class="mono">' + sid + "</h4>")
            put('<p style="font-size:11px;color:var(--muted);margin:-4px 0 8px 0">'
                "Current: report " + str(cb.report_id) + ", started " + ts_sec(cb.exec_start)
                + ", elapsed " + fmt_num(cur_total_s) + " s &nbsp;|&nbsp; Baseline: report "
                + str(pb.report_id) + ", started " + ts_sec(pb.exec_start)
                + ", elapsed " + fmt_num(base_total_s) + " s" + plan_note + "</p>")

            rows = _plan_rows(w, sid, cb, pb, cur_total_s, base_total_s)

            best_idx, best_delta = None, 0
            for i, r in enumerate(rows):
                if r["cur_share"] is not None and r["base_share"] is not None \
                        and r["cur_share"] - r["base_share"] > best_delta:
                    best_delta = r["cur_share"] - r["base_share"]
                    best_idx = i
            if best_idx is not None and best_delta >= 5:
                r = rows[best_idx]
                put('<p style="font-weight:600;margin:0 0 8px">line ' + str(r["line_id"])
                    + " " + esc(r["op_txt"]) + ": " + fmt_num(r["base_share"]) + "% &rarr; "
                    + fmt_num(r["cur_share"]) + "% of execution time; actual rows "
                    + fmt_num(r["base_rows"]) + " &rarr; " + fmt_num(r["cur_rows"]) + "</p>")

            put('<table class="sqlmon-drift-tbl" data-notools><thead><tr>'
                '<th>Id</th><th>Operation</th><th>Object</th><th class="num">Est rows</th>'
                '<th class="num">Starts (base&rarr;cur)</th>'
                '<th class="num">Actual rows (base&rarr;cur)</th>'
                '<th class="num">Duration s (base&rarr;cur, % share)</th>'
                '<th class="num">Max mem</th></tr></thead><tbody>')
            for r in rows:
                cls = ""
                br, cr = _nvl0(r["base_rows"]), _nvl0(r["cur_rows"])
                if r["only_side"] is not None:
                    cls = ' class="crit"'
                elif (abs(_nvl0(r["cur_share"]) - _nvl0(r["base_share"])) >= 10
                      or (br > 0 and cr > 0 and (cr / br >= 10 or br / cr >= 10))
                      or (br == 0 and cr > 0) or (cr == 0 and br > 0)):
                    cls = ' class="warn"'
                indent = "&nbsp;&nbsp;" * min(_nvl0(r["depth"]), 100)
                only = ""
                if r["only_side"] is not None:
                    only = (' <span class="badge crit" title="line present only in the '
                            + ("Current" if r["only_side"] == "CUR" else "baseline") + ' plan">'
                            + r["only_side"] + " only</span>")
                obj = (esc((r["obj_owner"] or "") + "." + r["obj_name"])
                       if r["obj_name"] is not None else "&mdash;")
                put("<tr" + cls + ">"
                    + '<td class="num">' + str(r["line_id"]) + only + "</td>"
                    + "<td>" + indent + esc(r["op_txt"] if r["op_txt"] is not None else "?") + "</td>"
                    + "<td>" + obj + "</td>"
                    + '<td class="num">' + fmt_int(r["est_rows"]) + "</td>"
                    + '<td class="num">' + fmt_int(r["base_starts"]) + " &rarr; " + fmt_int(r["cur_starts"]) + "</td>"
                    + '<td class="num">' + fmt_int(r["base_rows"]) + " &rarr; " + fmt_int(r["cur_rows"]) + "</td>"
                    + '<td class="num">' + fmt_num(r["base_dur"]) + " &rarr; " + fmt_num(r["cur_dur"])
                    + " (" + fmt_num(r["base_share"]) + "%&rarr;" + fmt_num(r["cur_share"]) + "%)</td>"
                    + '<td class="num">' + fmt_num(r["base_mem"]) + " &rarr; " + fmt_num(r["cur_mem"]) + "</td>"
                    + "</tr>")
            put("</tbody></table>")
            put('<div class="codewrap" style="position:relative">')
            put('<button type="button" class="copy-btn" data-copy="#sqlmon-drift-drill-' + sid + '">Copy</button>')
            put('<pre id="sqlmon-drift-drill-' + sid + '" class="sql">'
                + esc(_drill_sql(pb.report_id) + "\n" + _drill_sql(cb.report_id)) + "</pre></div>")
            put("</div>")

        if not cands:
            put('<p style="font-size:12px;color:var(--muted)">'
                "no statement with a Current and a baseline monitored execution qualifies.</p>")

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
