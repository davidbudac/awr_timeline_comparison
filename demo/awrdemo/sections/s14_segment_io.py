"""
Twin of sql/14_segment_io.sql -- Segment I/O (top-N per dimension, per
window): four dimensions (PREADS / PWRITES / RREQ / WREQ) from m.seg,
each with a per-segment detail table + a JSON series list, a chart-only
per-object-type rollup over ALL segments, and the ECharts line chart per
dimension (weeksIso two-arg AWR_markLine, awr:theme / awr:window).

DBA_HIST_SEG_STAT deltas are integer block / request counts, so the
model's float per-hour totals are rounded once at the source (the SQL's
TO_CHAR(metric_value,'FM99999999999999990') would round them anyway).
"""
from __future__ import annotations

from awrdemo import chrome
from awrdemo import helpers as H
from awrdemo.sections import _iodims as D

DIMS = [  # code, ord, label, unit  (dims CTE)
    ("PREADS", 1, "By physical reads", "blocks"),
    ("PWRITES", 2, "By physical writes", "blocks"),
    ("RREQ", 3, "By physical read requests", "requests"),
    ("WREQ", 4, "By physical write requests", "requests"),
]
_IDX = {"PREADS": 0, "PWRITES": 1, "RREQ": 2, "WREQ": 3}


def _tok(v):
    """TO_CHAR(v, 'FM99999999999999990') token (integer)."""
    return None if v is None else H.to_char_int(v)


def _parse(t):
    return float(t)


def _segment_values(w):
    """values_by_win[off][seg_name] = {dim: int}, plus seg meta and the
    per-type totals per window (the rollup covers ALL segments)."""
    meta = {}
    for g in w.segments:
        meta[g.owner + "." + g.name] = (g.object_type, g.tablespace)
    by_win, types_by_win = {}, {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        names, types = {}, {}
        for (owner, name), (pr, pw, rr, wr, _lr) in m.seg.items():
            seg_name = owner + "." + name
            vals = {"PREADS": H.ora_round(pr), "PWRITES": H.ora_round(pw),
                    "RREQ": H.ora_round(rr), "WREQ": H.ora_round(wr)}
            names[seg_name] = vals
            ot = meta.get(seg_name, ("(unknown)", "(unknown)"))[0]
            t = types.setdefault(ot, {d: 0.0 for d in _IDX})
            for d in _IDX:
                t[d] += vals[d]
        by_win[win.week_offset] = names
        types_by_win[win.week_offset] = types
    return by_win, types_by_win, meta


def emit(w) -> str:
    out = []
    put = out.append
    top_n = w.top_n
    put("<!-- AWR-SECTION: 14_segment_io BEGIN -->")
    put('<section id="segment-io" class="vw in-s in-a lib" style="--os:5"><h2>Segment I/O'
        '<small class="h2sub">Top ' + str(top_n)
        + ' segments by I/O per window; ranked, not scored</small></h2>')
    aid_by_name, aid_used = {}, {}

    weeks_j, weeks_iso_j = D.weeks_json(w)
    by_win, types_by_win, meta = _segment_values(w)
    codes = [c for c, _, _, _ in DIMS]
    picked = D.rank_pick(by_win, codes, top_n)

    dim_label, dim_unit = {}, {}
    segs_acc, types_acc = {}, {}

    # ---- per-dimension detail tables (the big cursor) -------------------
    any_rows = False
    tl_rows = []
    ls = None
    for code, _ord, label, unit in DIMS:
        entries = D.per_entity(picked[code], w.weeks_back)
        if not entries:
            continue
        if any_rows:
            put("</tbody></table></details>")
        any_rows = True
        dim_label[code] = label
        dim_unit[code] = unit
        segs_acc[code] = {"json": None, "kept": 0, "total": 0}
        types_acc.setdefault(code, {"json": None, "kept": 0, "total": 0})

        put("<h3>" + label + "</h3>")
        put('<div class="topsql-toggle" data-segio-target="' + code + '">'
            "<span>Break down by:</span>"
            '<button type="button" data-mode="segs" class="active">Segment</button>'
            '<button type="button" data-mode="types">Object type</button>'
            "</div>")
        put('<div class="chart-wrap chart-medium" id="segio-chart-' + code + '"></div>')
        put("<details>")
        put("<summary>Detail table</summary>")
        header = D.header_row(w, "<th>Segment</th><th>Type</th>", "Current (" + unit + ")")
        put('<table id="segio-detail-' + code + '">' + header + "<tbody>")

        for e in entries:
            object_type, tablespace = meta.get(e["name"], ("(unknown)", "(unknown)"))
            tokens = [_tok(v) for v in e["vals"]]
            entry = ('{"name":"' + H.json_escape(e["name"])
                     + '","type":"' + H.json_escape(object_type)
                     + '","cur":' + (str(e["cur_rnk"]) if e["cur_rnk"] is not None else "null")
                     + ',"vals":[' + D.chart_vals(tokens) + "]}")
            D.json_accumulate(segs_acc, code, entry)

            new = D.new_in_cur(e["cur_val"], tokens, _parse)
            aid = None
            if e["name"] not in aid_by_name:
                aid = H.anchor_id("sg", e["name"])
                if aid in aid_used:
                    aid = aid + "-" + str(len(aid_by_name) + 1)
                aid_by_name[e["name"]] = aid
                aid_used[aid] = e["name"]
            row = ("<tr" + (' id="' + aid + '"' if aid else "") + ">"
                   '<td class="mono"><span title="tablespace ' + H.esc(tablespace) + '">'
                   + H.esc(e["name"]) + "</span>"
                   + (' <span class="badge info" title="in the top-N '
                      'only in the current window">new</span>' if new else "")
                   + "</td>"
                   + "<td>" + H.esc(object_type) + "</td>"
                   + D.cur_cell(e["cur_val"], e["cur_rnk"]))
            row += D.week_cells(w, tokens, e["rnks"], _parse)
            row += "</tr>"
            put(row)
            # v1.6.0 Timeline: "Where the reads land" (ranked, not scored)
            if code == "PREADS" and len(tl_rows) < 2 and e["cur_val"] is not None:
                csv = H.tl_csv(w, ",".join("" if t is None else t for t in tokens), "Y")
                if not tl_rows:
                    mu0 = H.tl_mu(w, csv)
                    ls = ("<code>" + H.esc(e["name"]) + "</code> " + H.fmt_num(e["cur_val"]) + " blocks read"
                          + (" vs " + H.fmt_num(mu0) if mu0 is not None else ", new in the top " + str(w.top_n)))
                tl_rows.append(H.tl_bars(
                    w, csv, H.tl_mu(w, csv), None, None,
                    H.tl_lab(H.ent(H.esc(e["name"]), aid_by_name[e["name"]], "segment"),
                             H.esc(object_type).lower() + ', blocks read', H.esc(e["name"])),
                    H.tl_gutp(e["cur_val"], H.tl_mu(w, csv), "#" + str(e["cur_rnk"]) + " by physical reads"),
                    "tl-" + aid_by_name[e["name"]], "o", H.esc(e["name"]), "blocks read"))

    if any_rows:
        put("</tbody></table></details>")
    else:
        put('<p style="font-size:12px;color:var(--muted)">'
            "No segment-level I/O recorded for any compared window "
            "(DBA_HIST_SEG_STAT empty for these snapshots, or no valid "
            "windows).</p>")
    for i, r in enumerate(tl_rows, start=1):
        put((H.tl_open("objects") if i == 1 else "") + r + (H.tl_close() if i == len(tl_rows) else ""))

    # ---- second pass: per-object-type rollup (chart only) ---------------
    tpicked = D.rank_pick(types_by_win, codes, top_n)
    for code, _ord, _label, _unit in DIMS:
        for e in D.per_entity(tpicked[code], w.weeks_back):
            tokens = [_tok(v) for v in e["vals"]]
            entry = ('{"name":"' + H.json_escape(e["name"])
                     + '","cur":' + (str(e["cur_rnk"]) if e["cur_rnk"] is not None else "null")
                     + ',"vals":[' + D.chart_vals(tokens) + "]}")
            D.json_accumulate(types_acc, code, entry)

    # ---- one ECharts line chart per dimension ---------------------------
    if dim_label:
        put("<script>(function(){")
        put("AWR_DATA.segIo={weeks:" + weeks_j + ",weeksIso:" + weeks_iso_j
            + ",topN:" + str(top_n) + ",dims:{")
        # v_dim_label.FIRST/NEXT: INDEX BY VARCHAR2 walks keys in string order
        first = True
        for code in sorted(dim_label):
            if not first:
                put(",")
            s, t = segs_acc[code], types_acc.get(code, {"json": None, "kept": 0, "total": 0})
            put('"' + code + '":{"label":"' + dim_label[code]
                + '","unit":"' + dim_unit[code]
                + '","segsKept":' + str(s["kept"])
                + ',"segsTotal":' + str(s["total"])
                + ',"typesKept":' + str(t["kept"])
                + ',"typesTotal":' + str(t["total"])
                + ",")
            put('"segs":[' + (s["json"] or "") + "],")
            put('"types":[' + (t["json"] or "") + "]}")
            first = False
        entries_pl = chrome.put_lines(chrome.sql_path("sql/14_segment_io.sql"))
        out.extend(D.lift_script(entries_pl, "}};", "})();</script>"))

    put(H.lib_ls("segment-io", ls or "no segment-level I/O recorded") + "</section>")
    put("<!-- AWR-SECTION: 14_segment_io END -->")
    return "\n".join(out)
