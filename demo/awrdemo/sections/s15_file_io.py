"""
Twin of sql/15_file_io.sql -- File I/O (top-N per dimension, per window):
four dimensions (READMB / WRITEMB / RREQ / WREQ) from m.files
(DBA_HIST_FILESTATXS + TEMPSTATXS end-minus-begin, blocks scaled to MB
at 8 KB), each with a per-file detail table + a JSON series list; a
second pass over m.iostat (DBA_HIST_IOSTAT_FILETYPE, the AWR "IOStat by
Filetype") feeds the chart toggle AND one combined detail table; then
the ECharts line chart per dimension (weeksIso two-arg AWR_markLine,
awr:theme / awr:window).

Counters (phyrds / phywrts / phyblkrd / phyblkwrt, iostat MB and reqs)
are integers in the real views, so the model's floats are rounded once
at the source; the CSV token is then ROUND(v, 1) with a trailing '.'
trimmed, exactly like the SQL.
"""
from __future__ import annotations

from awrdemo import chrome
from awrdemo import helpers as H
from awrdemo.sections import _iodims as D

DIMS = [  # code, ord, label, unit  (file-level dims CTE)
    ("READMB", 1, "By data read (MB)", "MB"),
    ("WRITEMB", 2, "By data written (MB)", "MB"),
    ("RREQ", 3, "By read requests", "requests"),
    ("WREQ", 4, "By write requests", "requests"),
]
FT_DIMS = [  # the file-type pass has its own (shorter) labels
    ("READMB", 1, "Data read (MB)", "MB"),
    ("WRITEMB", 2, "Data written (MB)", "MB"),
    ("RREQ", 3, "Read requests", "reqs"),
    ("WREQ", 4, "Write requests", "reqs"),
]
_CODES = [c for c, _, _, _ in DIMS]


def _tok(v):
    """RTRIM(TO_CHAR(ROUND(v,1),'FM99999999999999990D9'), '.')"""
    return None if v is None else H.to_char_trim(H.ora_round(v, 1), 1)


def _parse(t):
    return float(t)


def _file_short(name: str) -> str:
    return name[max(name.rfind("/"), name.rfind("\\")) + 1:]


def _values(w):
    files_meta = {}
    for f in w.files:
        files_meta[(f.is_temp, f.file_id)] = f
    by_win, ft_by_win = {}, {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        names = {}
        for key, (rds, wts, blk_r, blk_w, _rt, _wt) in m.files.items():
            f = files_meta.get(key)
            if f is None:
                continue
            names[f.name] = {
                "READMB": H.ora_round(blk_r) * 8192 / 1048576,
                "WRITEMB": H.ora_round(blk_w) * 8192 / 1048576,
                "RREQ": H.ora_round(rds),
                "WREQ": H.ora_round(wts),
            }
        by_win[win.week_offset] = names
        ft = {}
        for ftype, (rmb, wmb, rr, wr) in m.iostat.items():
            ft[ftype] = {"READMB": H.ora_round(rmb), "WRITEMB": H.ora_round(wmb),
                         "RREQ": H.ora_round(rr), "WREQ": H.ora_round(wr)}
        ft_by_win[win.week_offset] = ft
    return by_win, ft_by_win, {f.name: f for f in w.files}


def emit(w) -> str:
    out = []
    put = out.append
    top_n = w.top_n
    put("<!-- AWR-SECTION: 15_file_io BEGIN -->")
    put('<section id="file-io" class="vw in-s in-a lib" style="--os:6"><h2>File I/O'
        '<small class="h2sub">Top ' + str(top_n)
        + ' data and temp files by I/O per window, and I/O by file type; ranked, not scored</small></h2>')
    aid_by_name, aid_used = {}, {}

    weeks_j, weeks_iso_j = D.weeks_json(w)
    by_win, ft_by_win, meta = _values(w)
    picked = D.rank_pick(by_win, _CODES, top_n)

    dim_label, dim_unit = {}, {}
    files_acc, ftypes_acc = {}, {}

    # ---- per-dimension detail tables (top-N files) ----------------------
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
        files_acc[code] = {"json": None, "kept": 0, "total": 0}
        ftypes_acc.setdefault(code, {"json": None, "kept": 0, "total": 0})

        put("<h3>" + label + "</h3>")
        put('<div class="topsql-toggle" data-fileio-target="' + code + '">'
            "<span>Break down by:</span>"
            '<button type="button" data-mode="files" class="active">File</button>'
            '<button type="button" data-mode="ftypes">File type</button>'
            "</div>")
        put('<div class="chart-wrap chart-medium" id="fileio-chart-' + code + '"></div>')
        put("<details>")
        put("<summary>Detail table</summary>")
        header = D.header_row(w, "<th>File</th><th>Tablespace</th>", "Current (" + unit + ")")
        put('<table id="fileio-detail-' + code + '">' + header + "<tbody>")

        for e in entries:
            filename = e["name"]
            short = _file_short(filename)
            tsname = meta[filename].tablespace if filename in meta else None
            tokens = [_tok(v) for v in e["vals"]]
            entry = ('{"name":"' + H.json_escape(short)
                     + '","cur":' + (str(e["cur_rnk"]) if e["cur_rnk"] is not None else "null")
                     + ',"vals":[' + D.chart_vals(tokens) + "]}")
            D.json_accumulate(files_acc, code, entry)

            new = D.new_in_cur(e["cur_val"], tokens, _parse)
            aid = None
            if filename not in aid_by_name:
                aid = H.anchor_id("fl", short)
                if aid in aid_used:
                    aid = aid + "-" + str(len(aid_by_name) + 1)
                aid_by_name[filename] = aid
                aid_used[aid] = filename
            row = ("<tr" + (' id="' + aid + '"' if aid else "") + ">"
                   '<td class="mono"><span title="' + H.esc(filename) + '">'
                   + H.esc(short) + "</span>"
                   + (' <span class="badge info" title="in the top-N '
                      'only in the current window">new</span>' if new else "")
                   + "</td>"
                   + "<td>" + H.esc(tsname if tsname is not None else "(unknown)") + "</td>"
                   + D.cur_cell(e["cur_val"], e["cur_rnk"]))
            row += D.week_cells(w, tokens, e["rnks"], _parse)
            row += "</tr>"
            put(row)
            # v1.6.0 Timeline: "Where the reads land" (ranked, not scored)
            if code == "READMB" and len(tl_rows) < 1 and e["cur_val"] is not None:
                csv = H.tl_csv(w, ",".join("" if t is None else t for t in tokens), "Y")
                if not tl_rows:
                    mu0 = H.tl_mu(w, csv)
                    ls = ("<code>" + H.esc(short) + "</code> " + H.fmt_num(e["cur_val"]) + " MB read"
                          + (" vs " + H.fmt_num(mu0) if mu0 is not None else ", new in the top " + str(w.top_n)))
                tl_rows.append(H.tl_bars(
                    w, csv, H.tl_mu(w, csv), None, None,
                    H.tl_lab(H.ent(H.esc(short), aid_by_name[filename], "file"),
                             'datafile, MB read', H.esc(filename)),
                    H.tl_gutp(e["cur_val"], H.tl_mu(w, csv), "#" + str(e["cur_rnk"]) + " by MB read"),
                    "tl-" + aid_by_name[filename], "o", H.esc(short), "MB read"))

    if any_rows:
        put("</tbody></table></details>")
    else:
        put('<p style="font-size:12px;color:var(--muted)">'
            "No per-file I/O recorded for any compared window "
            "(DBA_HIST_FILESTATXS empty for these snapshots, or no valid "
            "windows).</p>")
    for i, r in enumerate(tl_rows, start=1):
        put((H.tl_open("objects") if i == 1 else "") + r + (H.tl_close() if i == len(tl_rows) else ""))

    # ---- second pass: per-file-type breakdown (chart + combined table) --
    ft_picked = D.rank_pick(ft_by_win, _CODES, top_n)
    ft_table = False
    for code, _ord, label, _unit in FT_DIMS:
        for e in D.per_entity(ft_picked[code], w.weeks_back):
            tokens = [_tok(v) for v in e["vals"]]
            entry = ('{"name":"' + H.json_escape(e["name"])
                     + '","cur":' + (str(e["cur_rnk"]) if e["cur_rnk"] is not None else "null")
                     + ',"vals":[' + D.chart_vals(tokens) + "]}")
            D.json_accumulate(ftypes_acc, code, entry)

            if not ft_table:
                ft_table = True
                put("<details>")
                put("<summary>I/O by file type &mdash; detail table"
                    " (all four dimensions)</summary>")
                header = D.header_row(w, "<th>Metric</th><th>File type</th>", "Current")
                put('<table id="fileio-detail-ftype">' + header + "<tbody>")

            row = ("<tr>"
                   "<td>" + label + "</td>"
                   '<td class="mono">' + H.esc(e["name"]) + "</td>"
                   + D.cur_cell(e["cur_val"], e["cur_rnk"]))
            row += D.week_cells(w, tokens, e["rnks"], _parse)
            row += "</tr>"
            put(row)

    if ft_table:
        put("</tbody></table></details>")

    # ---- one ECharts line chart per dimension ---------------------------
    if dim_label:
        put("<script>(function(){")
        put("AWR_DATA.fileIo={weeks:" + weeks_j + ",weeksIso:" + weeks_iso_j
            + ",topN:" + str(top_n) + ",dims:{")
        # v_dim_label.FIRST/NEXT: INDEX BY VARCHAR2 walks keys in string
        # order -- READMB, RREQ, WREQ, WRITEMB (not the ord order).
        first = True
        for code in sorted(dim_label):
            if not first:
                put(",")
            f, t = files_acc[code], ftypes_acc.get(code, {"json": None, "kept": 0, "total": 0})
            put('"' + code + '":{"label":"' + dim_label[code]
                + '","unit":"' + dim_unit[code]
                + '","filesKept":' + str(f["kept"])
                + ',"filesTotal":' + str(f["total"])
                + ',"ftypesKept":' + str(t["kept"])
                + ',"ftypesTotal":' + str(t["total"])
                + ",")
            put('"files":[' + (f["json"] or "") + "],")
            put('"ftypes":[' + (t["json"] or "") + "]}")
            first = False
        entries_pl = chrome.put_lines(chrome.sql_path("sql/15_file_io.sql"))
        out.extend(D.lift_script(entries_pl, "}};", "})();</script>"))

    put(H.lib_ls("file-io", ls or "no per-file I/O recorded") + "</section>")
    put("<!-- AWR-SECTION: 15_file_io END -->")
    return "\n".join(out)
