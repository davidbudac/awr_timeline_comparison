"""
Twin of sql/12_param_changes.sql -- initialization parameters whose value
differs across the compared windows, read as of each window's END
snapshot (windows_rollup: every window, valid or not), rendered as a
parameter x window pivot.
"""
from __future__ import annotations

from awrdemo import helpers as h

TAG = "12_param_changes"


def _cell_html(has: bool, val, is_cur: bool, chg: bool, k: int) -> str:
    cls = "pval"
    if is_cur:
        cls += " cur"
    if chg:
        cls += " chg"
    if not has:
        body = '<span class="muted">&mdash;</span>'
    elif val is None:
        body = '<span class="muted">(unset)</span>'
    else:
        body = "<code>" + h.esc(val) + "</code>"
    return '<td class="' + cls + '" data-w="' + str(k) + '">' + body + "</td>"


def emit(w) -> str:
    L = ["<!-- AWR-SECTION: " + TAG + " BEGIN -->"]
    L.append('<section id="param-changes"><h2>Parameter changes</h2>')
    L.append('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
             "Initialization parameters from <code>dba_hist_parameter</code> whose "
             "value differs across the compared windows (value as of each "
             "window&rsquo;s end snapshot). Only changed parameters are listed; "
             "highlighted cells differ from the <b>Current</b> value. "
             "&mdash; = not present at that snapshot; (unset) = present but "
             "empty.</p>")

    # win: every window with an end snap (windows_rollup, validity ignored)
    wins = [win for win in w.windows if win.end_snap_id is not None]
    n_win = len(wins)
    names = set(w.params_static) | {pc.name for pc in w.param_changes}
    # pv: value per (window, parameter) at the window's end snap;
    # changed: >1 distinct value (NULL-safe) or missing at some window.
    cells = {}
    changed = []
    for name in sorted(names):          # ORDER BY parameter_name (binary)
        vals = {}
        for win in wins:
            vals[win.week_offset] = w.param_value(name, win.win_end_ts)
        distinct = {"__NULL__" if v is None else v for v in vals.values()}
        if len(distinct) > 1 or len(vals) < n_win:
            changed.append(name)
            for k, v in vals.items():
                cells[(name, k)] = v

    n_changed = len(changed)
    if n_changed == 0:
        L.append('<p style="color:var(--muted)">No system parameters '
                 "changed across the compared windows.</p></section>")
        L.append("<!-- AWR-SECTION: " + TAG + " END -->")
        return "\n".join(L)

    hdr = '<thead><tr><th>Parameter</th><th data-w="0">Current</th>'
    for k in range(1, w.weeks_back + 1):
        hdr += '<th data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + "</th>"
    hdr += "</tr></thead>"
    L.append('<table id="param-changes-table">' + hdr + "<tbody>")

    for name in changed:
        cur_has = (name, 0) in cells
        cur_val = cells.get((name, 0))
        row = '<tr><td class="pname"><code>' + h.esc(name) + "</code></td>"
        row += _cell_html(cur_has, cur_val, True, False, 0)
        for k in range(1, w.weeks_back + 1):
            has = (name, k) in cells
            val = cells.get((name, k))
            if has != cur_has:
                chg = True
            elif not has and not cur_has:
                chg = False
            else:
                chg = ("__NULL__" if val is None else val) != ("__NULL__" if cur_val is None else cur_val)
            cell = _cell_html(has, val, False, chg, k)
            if len(row) + len(cell) > 30000:
                L.append(row)
                row = ""
            row += cell
        row += "</tr>"
        L.append(row)

    L.append("</tbody></table>")
    L.append('<p style="font-size:12px;color:var(--muted)">' + str(n_changed) + " parameter"
             + ("" if n_changed == 1 else "s") + " changed across the compared windows.</p>")
    L.append("</section>")
    L.append("<!-- AWR-SECTION: " + TAG + " END -->")
    return "\n".join(L)
