"""
Twin of sql/06_top_sql.sql -- Top-N SQL per window ranked five ways (+ the
PEREXEC regression dimension), per-dim detail tables, the SQL pool table
with paired detail rows, the AWR_DATA.topSql / AWR_DATA.sqlDetails JSON
payloads, and every inline <script> of the original (lifted verbatim).

Data: per window `m = w.window_metrics(win)`, `m.sql[sql_id]` = the
DBA_HIST_SQLSTAT *_DELTA sums for that window; `w.sql_by_id` supplies the
text / parsing schema / module / action; the full-retention scan for the
per-SQL detail rows walks every snapshot of `w.snaps`.

Locally derived (the model lacks them): DBA_HIST_SQLSTAT integer counters
(execs / elapsed / cpu / gets / reads are rounded to whole numbers the way
AWR stores them), `optimizer_mode` (= ALL_ROWS), `force_matching_signature`
(stable per sql_id via w.rng), `sql_profile` (= NULL).
"""
from __future__ import annotations

from datetime import timedelta

from awrdemo import chrome
from awrdemo.helpers import (esc, fmt_int, fmt_num, fmt_num_title, is_oracle_schema,
                             json_escape, mon_dd, num6, ora_round, to_char_fixed, ts_min)

_SQL = chrome.sql_path("sql/06_top_sql.sql")

# dims CTE: code, ord, label, unit, divisor  (static in the SQL)
_DIMS = [
    ("ELAPSED", 1, "By elapsed time", "s", 1e6),
    ("CPU", 2, "By CPU time", "s", 1e6),
    ("GETS", 3, "By buffer gets", "gets", 1),
    ("PREADS", 4, "By physical reads", "reads", 1),
    ("EXEC", 5, "By executions", "exec", 1),
    ("PEREXEC", 6, "By per-exec regression", "s/exec", 1e6),
]
_RANK_DIMS = ("ELAPSED", "CPU", "GETS", "PREADS", "EXEC")
_METRIC_OF = {"ELAPSED": "ela", "CPU": "cpu", "GETS": "gets", "PREADS": "reads", "EXEC": "execs"}
_JSON_CAP = 32500      # c_json_cap


# ---------------------------------------------------------------------
# literal <script> lifting
# ---------------------------------------------------------------------

def _lines():
    return chrome.put_lines(_SQL)


def _slice(lines, first: str, last: str, start: int = 0) -> tuple[list[str], int]:
    """Literal PUT_LINE texts from the first entry equal to `first` (at or
    after index `start`) through the next entry equal to `last`."""
    i = start
    while lines[i][0] != first:
        i += 1
    j = i
    while lines[j][0] != last:
        j += 1
    for t, ok in lines[i:j + 1]:
        if not ok:
            raise ValueError("non-literal PUT_LINE inside a lifted script block: " + t[:60])
    return [t for t, _ in lines[i:j + 1]], j + 1


# ---------------------------------------------------------------------
# model access
# ---------------------------------------------------------------------

def _ival(x: float) -> float:
    return ora_round(x, 0)


def _agg(w):
    """agg CTE: {week_offset: {sql_id: dict(execs, ela, cpu, gets, reads, phv, schema)}}
    over VALID windows only."""
    out = {}
    for win in w.windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        rows = {}
        for sid, x in m.sql.items():
            rows[sid] = {
                "execs": _ival(x.execs), "ela": _ival(x.elapsed_us), "cpu": _ival(x.cpu_us),
                "gets": _ival(x.gets), "reads": _ival(x.reads),
                "phv": x.plan_hash, "schema": w.sql_by_id[sid].schema,
            }
        out[win.week_offset] = rows
    return out


def _rank(rows: dict, key: str, name_of=lambda k: k) -> dict:
    """ROW_NUMBER() OVER (ORDER BY metric DESC, name) -> {name: rank}."""
    order = sorted(rows.keys(), key=lambda k: (-rows[k][key], name_of(k)))
    return {k: i + 1 for i, k in enumerate(order)}


def _picked(w, agg):
    """picked CTE: {(dim, sql_id, week_offset): (metric_value, rnk, phv)}."""
    top_n = w.top_n
    picked = {}
    for off, rows in agg.items():
        for dim in _RANK_DIMS:
            key = _METRIC_OF[dim]
            rk = _rank(rows, key)
            for sid, r in rows.items():
                if rk[sid] <= top_n and r[key] > 0:
                    picked[(dim, sid, off)] = (r[key], rk[sid], r["phv"])
    # per_exec / delta_ranked
    per_exec = {}   # (sid, off) -> per_exec_us | None
    for off, rows in agg.items():
        for sid, r in rows.items():
            per_exec[(sid, off)] = (r["ela"] / r["execs"]) if r["execs"] > 0 else None
    cands = []
    for sid in {s for s, _ in per_exec}:
        cur_pe = per_exec.get((sid, 0))
        priors = [v for (s, o), v in per_exec.items() if s == sid and o > 0 and v is not None]
        cur_execs = agg.get(0, {}).get(sid, {}).get("execs")
        if cur_pe is None or not priors:
            continue
        prior_pe = sum(priors) / len(priors)
        if cur_pe > prior_pe and cur_execs is not None and cur_execs >= 3:
            cands.append((sid, cur_pe - prior_pe))
    cands.sort(key=lambda t: (-t[1], t[0]))
    r_delta = {sid: i + 1 for i, (sid, _) in enumerate(cands)}
    for (sid, off), pe in per_exec.items():
        rd = r_delta.get(sid)
        if rd is not None and rd <= top_n and pe is not None:
            picked[("PEREXEC", sid, off)] = (pe, rd if off == 0 else None, agg[off][sid]["phv"])
    return picked


def _per_sql(w, picked):
    """per_sql CTE rows in the cursor's ORDER BY, as dicts."""
    nweeks = w.weeks_back + 1
    keys = sorted({(d, s) for d, s, _ in picked})
    ordmap = {d[0]: d[1] for d in _DIMS}
    rows = []
    for dim, sid in keys:
        vals, rnks, phvs = [], [], []
        for off in range(nweeks):
            p = picked.get((dim, sid, off))
            vals.append(p[0] if p else None)
            rnks.append(p[1] if p else None)
            phvs.append(p[2] if p else None)
        rn = [r for r in rnks if r is not None]
        mv = [v for v in vals if v is not None]
        rows.append({
            "dim": dim, "sql_id": sid,
            "cur_val": vals[0], "cur_rnk": rnks[0], "cur_phv": phvs[0],
            "best_rank": min(rn) if rn else None,
            "best_value": max(mv) if mv else None,
            "vals": vals, "rnks": rnks, "phvs": phvs,
        })
    rows.sort(key=lambda r: (ordmap[r["dim"]],
                             1 if r["cur_rnk"] is None else 0,
                             r["cur_rnk"] if r["cur_rnk"] is not None else 0,
                             r["best_rank"] if r["best_rank"] is not None else float("inf"),
                             -(r["best_value"] or 0), r["sql_id"]))
    return rows


def _group_rows(w, agg):
    """Second cursor: per-(dim, grp_type, grp_value) chart series, in the
    cursor's ORDER BY."""
    top_n = w.top_n
    nweeks = w.weeks_back + 1
    # base -> agg by grp_type
    gagg = {}   # (off, grp_type) -> {grp_value: {metric: sum}}
    for off, rows in agg.items():
        for sid, r in rows.items():
            d = w.sql_by_id[sid]
            names = {"schema": d.schema or "(unknown)",
                     "module": d.module or "(none)",
                     "action": d.action or "(none)"}
            for gt, gv in names.items():
                slot = gagg.setdefault((off, gt), {}).setdefault(
                    gv, {"execs": 0, "ela": 0, "cpu": 0, "gets": 0, "reads": 0})
                for k in slot:
                    slot[k] += r[k]
    picked = {}
    for (off, gt), rows in gagg.items():
        for dim in _RANK_DIMS:
            key = _METRIC_OF[dim]
            rk = _rank(rows, key)
            for gv, r in rows.items():
                if rk[gv] <= top_n and r[key] > 0:
                    picked[(dim, gt, gv, off)] = (r[key], rk[gv])
    ordmap = {d[0]: d[1] for d in _DIMS}
    out = []
    for dim, gt, gv in sorted({(d, t, v) for d, t, v, _ in picked}):
        vals, rnks = [], []
        for off in range(nweeks):
            p = picked.get((dim, gt, gv, off))
            vals.append(p[0] if p else None)
            rnks.append(p[1] if p else None)
        rn = [r for r in rnks if r is not None]
        mv = [v for v in vals if v is not None]
        out.append({"dim": dim, "grp_type": gt, "grp_value": gv, "cur_rnk": rnks[0],
                    "best_rank": min(rn), "best_value": max(mv), "vals": vals})
    out.sort(key=lambda r: (ordmap[r["dim"]], r["grp_type"],
                            1 if r["cur_rnk"] is None else 0,
                            r["cur_rnk"] if r["cur_rnk"] is not None else 0,
                            r["best_rank"], -r["best_value"], r["grp_value"]))
    return out


def _chart_vals(vals, div) -> str:
    """Oldest -> newest, 'null' for a missing slot, num6(value/div)."""
    return ",".join("null" if v is None else num6(v / div) for v in reversed(vals))


def _retention(w, sid):
    """Full-retention per-SQL scan over every snapshot: (points, meta)."""
    pts = []
    for s in w.snaps:
        x = w.hour(s.end_ts).sql.get(sid)
        if x is None:
            continue
        pts.append((s, _ival(x.execs), _ival(x.elapsed_us), _ival(x.gets), x.plan_hash))
    return pts


# ---------------------------------------------------------------------
# emitter
# ---------------------------------------------------------------------

def emit(w) -> str:
    o = []
    put = o.append
    L = _lines()
    top_n = w.top_n
    weeks_back = w.weeks_back
    nweeks = weeks_back + 1

    put("<!-- AWR-SECTION: 06_top_sql BEGIN -->")
    put(f'<section id="topsql" data-normal="Y"><h2>Top SQL (top {top_n}'
        " per dimension, per window)</h2>")
    put('<p style="font-size:12px;color:var(--muted)">'
        f"Top-{top_n} SQLs per dimension per window from "
        "DBA_HIST_SQLSTAT <code>*_DELTA</code>. "
        "Bump chart per dimension: each line = one SQL across windows, "
        "oldest &rarr; current. Use the <b>Break down by</b> toggle to "
        "re-aggregate the same metric by <b>SQL ID</b>, parsing "
        "<b>schema</b>, <b>module</b>, or <b>action</b> instead. "
        "Detail tables collapsed; click to expand.</p>")
    put('<div class="tabs" data-tabs="topsql" role="tablist" aria-label="Top SQL ranking dimension">'
        '<button type="button" role="tab" aria-selected="true" class="on" data-t="ELAPSED" id="tab-topsql-ELAPSED">Elapsed time</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="CPU" id="tab-topsql-CPU">CPU time</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="GETS" id="tab-topsql-GETS">Buffer gets</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PREADS" id="tab-topsql-PREADS">Physical reads</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="EXEC" id="tab-topsql-EXEC">Executions</button>'
        '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PEREXEC" id="tab-topsql-PEREXEC">Per-exec regression</button>'
        "</div>")

    # weeks / weeksIso JSON (week_offset DESC = oldest first)
    step_days = w.step_hours / 24
    wdates = [w.target_end - timedelta(days=step_days * k) for k in range(weeks_back, -1, -1)]
    weeks_json = "[" + ",".join('"' + mon_dd(d) + '"' for d in wdates) + "]"
    weeks_iso_json = "[" + ",".join('"' + ts_min(d) + '"' for d in wdates) + "]"

    agg = _agg(w)
    picked = _picked(w, agg)
    rows = _per_sql(w, picked)

    dim_label, dim_unit, dim_div = {}, {}, {}
    for code, _, label, unit, div in _DIMS:
        dim_label[code], dim_unit[code], dim_div[code] = label, unit, div
    seen_sqls = {}
    flip_sqls = {}
    sys_sqls = {}
    sql_dim_seen, sql_dim_top3 = {}, {}
    sql_elapsed_cur = {}
    dim_sqls_json, dim_sqls_kept, dim_sqls_total, dim_seen = {}, {}, {}, []

    cur_dim = None
    for s in rows:
        dim = s["dim"]
        if cur_dim != dim:
            if cur_dim is not None:
                put("</tbody></table></details></div>")
            cur_dim = dim
            dim_seen.append(dim)
            dim_sqls_json[dim] = None
            dim_sqls_kept[dim] = 0
            dim_sqls_total[dim] = 0
            put('<div class="tabpanel' + (" on" if dim == "ELAPSED" else "")
                + '" data-tabs="topsql" data-t="' + dim + '" role="tabpanel"'
                + ' aria-labelledby="tab-topsql-' + dim + '">')
            put("<h3>" + dim_label[dim] + "</h3>")
            put('<div class="topsql-toggle" data-topsql-target="' + dim + '">'
                "<span>Break down by:</span>"
                '<button type="button" data-mode="sqls" class="active">SQL ID</button>'
                '<button type="button" data-mode="schemas">Schema</button>'
                '<button type="button" data-mode="modules">Module</button>'
                '<button type="button" data-mode="actions">Action</button>'
                "</div>")
            put('<div class="chart-wrap chart-medium" id="topsql-chart-' + dim + '"></div>')
            put("<details>")
            put("<summary>Detail table</summary>")
            header = ('<thead><tr><th>SQL ID</th><th class="num" title="plan_hash_value of the Current window&#39;s execution plan">Plan hash (Current)</th>'
                      '<th class="num" data-w="0">Current (' + dim_unit[dim] + ")</th>")
            for k in range(1, weeks_back + 1):
                header += ('<th class="num" data-w="' + str(k) + '">&minus;'
                           + w.offset_labels[k - 1] + "</th>")
            header += "<th>SQL</th></tr></thead>"
            put('<table id="topsql-detail-' + cur_dim + '">' + header + "<tbody>")

        sid = s["sql_id"]
        div = dim_div[dim]
        seen_sqls[sid] = True
        if dim in _RANK_DIMS:
            sql_dim_seen[sid + "|" + dim] = "Y"
            if s["cur_rnk"] is not None and s["cur_rnk"] <= 3:
                sql_dim_top3[sid + "|" + dim] = "Y"
        if dim == "ELAPSED":
            sql_elapsed_cur[sid] = s["cur_val"] if s["cur_val"] is not None else 0

        schema = w.sql_by_id[sid].schema
        is_sys = is_oracle_schema(schema)
        sys_sqls[sid] = (is_sys == "Y")

        plan_flip = False
        cur_phv = s["cur_phv"]
        if cur_phv is not None:
            for k in range(1, weeks_back + 1):
                p = s["phvs"][k]
                if p is not None and p != cur_phv:
                    plan_flip = True
                    break
        if plan_flip:
            flip_sqls[sid] = True

        new_entry = ('{"sql_id":"' + sid + '","cur":'
                     + ("null" if s["cur_rnk"] is None else str(s["cur_rnk"]))
                     + ',"sys":' + ("true" if is_sys == "Y" else "false")
                     + ',"vals":[' + _chart_vals(s["vals"], div) + "]}")
        dim_sqls_total[dim] += 1
        if dim_sqls_json[dim] is None:
            dim_sqls_json[dim] = new_entry
            dim_sqls_kept[dim] += 1
        elif len(dim_sqls_json[dim]) + len(new_entry) + 1 <= _JSON_CAP:
            dim_sqls_json[dim] += "," + new_entry
            dim_sqls_kept[dim] += 1

        cur_val = s["cur_val"]
        cur_scaled = None if cur_val is None else cur_val / div
        row = ('<tr data-sys="' + is_sys + '">'
               '<td class="mono"><a href="#sql-' + sid + '">' + sid + "</a>"
               + (' <span class="badge warn" title="Plan changed between current and a prior '
                  'compared window">plan&#8593;</span>' if plan_flip else "")
               + "</td>"
               '<td class="num mono">' + ("&mdash;" if cur_phv is None else str(cur_phv)) + "</td>"
               '<td class="num" data-w="0"' + fmt_num_title(cur_scaled) + "><b>"
               + fmt_num(cur_scaled)
               + (' <span class="badge info">#' + str(s["cur_rnk"]) + "</span>"
                  if s["cur_rnk"] is not None else "")
               + "</b></td>")
        for k in range(1, weeks_back + 1):
            v, r, p = s["vals"][k], s["rnks"][k], s["phvs"][k]
            if v is None:
                row += '<td class="num" data-w="' + str(k) + '">&mdash;'
            else:
                row += '<td class="num" data-w="' + str(k) + '">' + fmt_num(v / div)
            if r is not None:
                row += ' <span class="badge skip">#' + str(r) + "</span>"
            if p is not None and cur_phv is not None and p != cur_phv:
                row += (' <span class="badge warn" title="Plan changed. Prior PHV '
                        + str(p) + '">plan&#8593;</span>')
            row += "</td>"
        text_short = (w.sql_by_id[sid].text or "")[:401]
        row += ('<td class="mono sqltext">' + esc(text_short[:400])
                + ("&hellip;" if len(text_short) > 400 else "") + "</td>")
        row += "</tr>"
        put(row)
    if cur_dim is not None:
        put("</tbody></table></details></div>")

    # second pass: group breakdowns -----------------------------------
    grp_json, grp_kept, grp_total = {}, {}, {}
    for sc in _group_rows(w, agg):
        gv = sc["grp_value"]
        new_entry = ('{"name":"' + json_escape(gv)
                     + '","cur":' + ("null" if sc["cur_rnk"] is None else str(sc["cur_rnk"]))
                     + ',"sys":' + ("true" if sc["grp_type"] == "schema"
                                    and is_oracle_schema(gv) == "Y" else "false")
                     + ',"vals":[' + _chart_vals(sc["vals"], dim_div[sc["dim"]]) + "]}")
        gkey = sc["dim"] + "|" + sc["grp_type"]
        if gkey not in grp_total:
            grp_total[gkey] = 0
            grp_kept[gkey] = 0
        grp_total[gkey] += 1
        if grp_json.get(gkey) is None:
            grp_json[gkey] = new_entry
            grp_kept[gkey] += 1
        elif len(grp_json[gkey]) + len(new_entry) + 1 <= _JSON_CAP:
            grp_json[gkey] += "," + new_entry
            grp_kept[gkey] += 1

    # AWR_DATA.topSql + bump-chart script ------------------------------
    if dim_seen:
        put("<script>(function(){")
        put("AWR_DATA.topSql={weeks:" + weeks_json + ",weeksIso:" + weeks_iso_json
            + ",topN:" + str(top_n) + ",dims:{")
        # PL/SQL INDEX BY VARCHAR2 iterates in key order
        for i, dim in enumerate(sorted(dim_seen)):
            if i:
                put(",")

            def cnt(tab, key):
                return str(tab[key]) if key in tab else "0"
            put('"' + dim + '":{"label":"' + dim_label[dim]
                + '","unit":"' + dim_unit[dim]
                + '","sqlsKept":' + str(dim_sqls_kept[dim])
                + ',"sqlsTotal":' + str(dim_sqls_total[dim])
                + ',"schemasKept":' + cnt(grp_kept, dim + "|schema")
                + ',"schemasTotal":' + cnt(grp_total, dim + "|schema")
                + ',"modulesKept":' + cnt(grp_kept, dim + "|module")
                + ',"modulesTotal":' + cnt(grp_total, dim + "|module")
                + ',"actionsKept":' + cnt(grp_kept, dim + "|action")
                + ',"actionsTotal":' + cnt(grp_total, dim + "|action")
                + ",")
            put('"sqls":[' + (dim_sqls_json[dim] or "") + "],")
            put('"schemas":[' + (grp_json.get(dim + "|schema") or "") + "],")
            put('"modules":[' + (grp_json.get(dim + "|module") or "") + "],")
            put('"actions":[' + (grp_json.get(dim + "|action") or "") + "]}")
        block, pos = _slice(L, "}};", "})();</script>")
        o.extend(block)

    # cross-dim plan-change rollup --------------------------------------
    if seen_sqls:
        if flip_sqls:
            put('<p style="margin-top:18px">'
                '<span class="badge warn">plan&#8593;</span> '
                + str(len(flip_sqls)) + " of " + str(len(seen_sqls))
                + " top SQL had a plan_hash_value change between current and a prior "
                'compared window. Look for the <span class="badge warn">plan&#8593;</span> '
                "badges in the SQL ID column and the per-window cells above.</p>")
        else:
            put('<p style="margin-top:18px">'
                '<span class="badge ok">plan stable</span> '
                "No plan_hash_value changes detected for any of the "
                + str(len(seen_sqls)) + " top SQL across the compared windows.</p>")

    # per-SQL detail: pool table ----------------------------------------
    block, pos = _slice(L, '<h3 class="full-only">Per-SQL detail</h3>',
                        '<table id="sql-pool" class="full-only"><thead><tr><th>SQL ID</th><th>Ranked in</th>'
                        '<th>Schema</th><th class="num" title="distinct plan_hash_values seen across the span">Plans</th><th class="num">Executions</th>'
                        '<th class="num" title="AWR snapshots in which the SQL appeared">Snapshots</th><th>First seen</th><th>Text</th>'
                        "</tr></thead><tbody>")
    o.extend(block)

    order = sorted(seen_sqls.keys(),
                   key=lambda sid: (-(sql_elapsed_cur.get(sid, 0)), sid))
    for idx, sid in enumerate(order, start=1):
        d = w.sql_by_id[sid]
        pts = _retention(w, sid)
        if pts:
            first_seen = ts_min(min(p[0].begin_ts for p in pts))
            last_seen = ts_min(max(p[0].end_ts for p in pts))
            phv_count = len({p[4] for p in pts if p[4] != 0})
            total_exec = sum(p[1] for p in pts)
            total_snap = len(pts)
            parsing_schema = d.schema or None
            last_module = d.module or None
            last_action = d.action or None
            last_opt_mode = "ALL_ROWS"
            module_distinct = 1 if last_module else 0
            force_sig = w.rng("force_sig", sid).randrange(10 ** 18, 10 ** 19)
            sql_profile = None
        else:
            first_seen = last_seen = None
            phv_count = total_exec = total_snap = 0
            parsing_schema = last_module = last_action = last_opt_mode = None
            module_distinct = 0
            force_sig = sql_profile = None
        text = d.text
        if text is None:
            vlen, snip = 0, "(text not in DBA_HIST_SQLTEXT)"
        else:
            vlen, snip = len(text), text[:8000]

        put('<tr class="sql-row" id="sql-' + sid + '"'
            + ' data-sys="' + ("Y" if sys_sqls.get(sid) else "N") + '"'
            + (' data-tail="Y" hidden' if idx > 8 else "") + ">")
        put('<td class="mono sqlid-cell">'
            '<span id="sqlid-' + sid + '">' + sid + "</span> "
            '<button type="button" class="copy-btn" '
            'data-copy="#sqlid-' + sid + '">&#10687;</button>'
            '<span class="xlinks">'
            '<a class="xlink" href="#ash-card-' + sid
            + '" title="ASH breakdown of this SQL" onclick="event.stopPropagation()">ASH</a>'
            '<a class="xlink" href="#sqlmon-' + sid
            + '" title="SQL Monitor row for this SQL" onclick="event.stopPropagation()">MON</a>'
            "</span>"
            "</td>")
        chips = ""
        for letter, dim in (("E", "ELAPSED"), ("C", "CPU"), ("G", "GETS"),
                            ("R", "PREADS"), ("X", "EXEC")):
            key = sid + "|" + dim
            if key in sql_dim_seen:
                chips += ('<span class="chip' + (" on" if key in sql_dim_top3 else "")
                          + '" title="' + dim + '">' + letter + "</span>")
        put("<td>" + chips + "</td>")
        put('<td class="mono">'
            + ("&mdash;" if parsing_schema is None else esc(parsing_schema))
            + "</td>"
            '<td class="num">' + str(phv_count or 0)
            + (' <span class="badge warn">plan flip</span>' if (phv_count or 0) > 2 else "")
            + "</td>"
            '<td class="num">' + fmt_int(total_exec or 0) + "</td>"
            '<td class="num">' + fmt_int(total_snap or 0) + "</td>"
            "<td>" + (first_seen if first_seen is not None else "?") + "</td>"
            '<td class="mono sqltext">' + esc((snip or "")[:90])
            + ("&hellip;" if len(snip or "") > 90 else "") + "</td>")
        put("</tr>")

        put('<tr class="sql-detail" data-sql="' + sid + '" hidden><td colspan="8">')
        dash = '<span class="muted">&mdash;</span>'
        put('<dl class="sql-meta">'
            '<dt>Parsing schema</dt><dd class="mono">'
            + (dash if parsing_schema is None else esc(parsing_schema)) + "</dd>"
            "<dt>Module</dt><dd>"
            + (dash if last_module is None else esc(last_module)
               + (' <span class="muted">(' + str(module_distinct) + " distinct seen)</span>"
                  if module_distinct > 1 else ""))
            + "</dd>"
            "<dt>Action</dt><dd>" + (dash if last_action is None else esc(last_action)) + "</dd>"
            '<dt>Optimizer mode</dt><dd class="mono">'
            + (dash if last_opt_mode is None else esc(last_opt_mode)) + "</dd>"
            '<dt>Force-match sig</dt><dd class="mono">'
            + (dash if not force_sig else str(force_sig)) + "</dd>"
            "<dt>SQL profile</dt><dd>" + (dash if sql_profile is None else esc(sql_profile)) + "</dd>"
            "<dt>Text length</dt><dd>"
            + (dash if not vlen else to_char_fixed(vlen, 0, group=True) + " chars") + "</dd>"
            "</dl>")

        if (phv_count or 0) > 0:
            put('<table id="phv-summary-' + sid + '"><thead><tr>'
                '<th class="num" title="plan_hash_value">Plan hash</th>'
                "<th>First seen</th><th>Last seen</th>"
                '<th class="num">Snapshots</th>'
                '<th class="num">Executions</th>'
                '<th class="num">Avg s/exec</th>'
                '<th class="num">Avg gets/exec</th>'
                "</tr></thead><tbody>")
            byphv = {}
            for s, ex, ela, gets, phv in pts:
                if phv > 0:
                    b = byphv.setdefault(phv, {"first": s.begin_ts, "last": s.end_ts,
                                               "snaps": 0, "execs": 0, "ela": 0, "gets": 0})
                    b["first"] = min(b["first"], s.begin_ts)
                    b["last"] = max(b["last"], s.end_ts)
                    b["snaps"] += 1
                    b["execs"] += ex
                    b["ela"] += ela
                    b["gets"] += gets
            for phv, b in sorted(byphv.items(), key=lambda kv: kv[1]["first"]):
                put("<tr>"
                    '<td class="num mono">' + str(phv) + "</td>"
                    "<td>" + ts_min(b["first"]) + "</td>"
                    "<td>" + ts_min(b["last"]) + "</td>"
                    '<td class="num">' + fmt_int(b["snaps"]) + "</td>"
                    '<td class="num">' + fmt_int(b["execs"]) + "</td>"
                    '<td class="num">'
                    + (fmt_num(b["ela"] / b["execs"] / 1e6) if b["execs"] > 0 else "&mdash;")
                    + "</td>"
                    '<td class="num">'
                    + (fmt_num(b["gets"] / b["execs"]) if b["execs"] > 0 else "&mdash;")
                    + "</td>"
                    "</tr>")
            put("</tbody></table>")
            put('<div class="chart-wrap chart-medium" id="sqltl-' + sid + '"></div>')
            put('<script>AWR_DATA.sqlDetails["' + sid + '"]={snaps:[')
            first_pt = True
            for s, ex, ela, gets, phv in pts:
                if phv <= 0:
                    continue
                put(("" if first_pt else ",")
                    + '{"t":"' + ts_min(s.end_ts) + '"'
                    + ',"phv":"' + str(phv) + '"'
                    + ',"exec":' + str(int(ex))
                    + ',"ela":' + (to_char_fixed(ela / ex / 1e6, 6) if ex > 0 else "null")
                    + "}")
                first_pt = False
            put("]};</script>")

        put('<pre class="sql">' + esc(snip)
            + ("\n... (truncated, " + str(vlen) + " chars total)" if vlen > 8000 else "")
            + "</pre>")
        put("</td></tr>")
    put("</tbody></table>")
    if len(seen_sqls) > 8:
        n_more = len(seen_sqls) - 8
        put('<span class="expander" data-for="sql-pool" data-n="' + str(n_more)
            + '" data-noun="more statements">'
            "&#9656; Show " + str(n_more) + " more statements</span>")

    # per-SQL timeline init, sql-pool row toggle, hash navigation --------
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # timeline init
    o.extend(block)
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # row toggle
    o.extend(block)
    block, pos = _slice(L, "<script>(function(){", "})();</script>", pos)   # hash nav
    o.extend(block)

    put("</section>")
    put("<!-- AWR-SECTION: 06_top_sql END -->")
    return "\n".join(o)
