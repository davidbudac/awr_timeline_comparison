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
    return ('<td class="' + cls + '" data-w="' + str(k) + '">'
            + ('<span class="g" title="differs from the Current value">&ne;</span> ' if chg else "")
            + body + "</td>")


def _pv_txt(v: str) -> str:
    """12's pv_txt: a byte count (all digits, >= 1 MB) reads as MB / GB."""
    if v is None:
        return "(unset)"
    import re
    if re.fullmatch(r"[0-9]{7,}", v):
        n = int(v)
        if n >= 1073741824:
            return h.to_char_trim(h.ora_round(n / 1073741824, 1), 1, min_dec=1) + " GB"
        if n >= 1048576:
            return h.to_char_trim(h.ora_round(n / 1048576, 1), 1, min_dec=1) + " MB"
    return v


def _pv_at(cells, name, k):
    if (name, k) not in cells:
        return "__NONE__"
    v = cells[(name, k)]
    return "__NULL__" if v is None else v


def _pv_html(v):
    if v == "__NONE__":
        return "&ndash;"
    if v == "__NULL__":
        return "(unset)"
    return h.esc(_pv_txt(v))


def _config_card(w, L, changed, cells):
    """The Summary view's configuration card (hidden, moved into 07's slot)."""
    wb = w.weeks_back
    cur = [n for n in changed if wb >= 1 and _pv_at(cells, n, 0) != _pv_at(cells, n, 1)]
    nch = len(changed)
    L.append(h.lib_ls("param-changes", "<b>" + str(nch) + "</b>" + (" differs" if nch == 1 else " differ") + ", "
                      + ("none" if not cur else str(len(cur))) + " in Current"))
    L.append('<article class="panel fc chg" id="f-config" aria-labelledby="f-config-h" hidden>'
             '<header class="fc-h"><div class="fc-k"><span class="sv"><b class="gk">&ne;</b>'
             'Configuration</span></div></header>'
             '<h3 id="f-config-h">' + str(nch) + ' parameter' + (' differs' if nch == 1 else 's differ')
             + ' across the compared windows</h3>'
             '<p class="takeaway">'
             + ('Only ' + h.ent('<code>' + h.esc(cur[-1]) + '</code>', h.anchor_id("pa", cur[-1]), "parameter")
                + ' changed into the Current window.' if len(cur) == 1
                else str(len(cur)) + ' of them changed into the Current window.' if len(cur) > 1
                else 'None changed into the Current window: every change is older.')
             + '</p>')
    L.append('<div class="cfg-wg"><div class="wg fit"' + h.wg_attr(w)
             + ' role="table" aria-label="Parameter values per compared window">'
             + h.wg_ruler(w, '<span class="ct">Parameter</span>', '<span class="gt">Changed</span>'))
    for name in changed[:8]:
        base = _pv_at(cells, name, wb)
        prev, last, ch = None, None, ""
        for k in range(wb, -1, -1):
            v = _pv_at(cells, name, k)
            start = (k == wb) or (v != prev)
            if start and k < wb:
                last = k
            lvl = "lo" if v == base else "hi"
            ch += ('<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k) + '"><i class="st ' + lvl
                   + (" rise" if start and k < wb else "") + '" aria-hidden="true"></i>'
                   + ('<i class="nd" aria-hidden="true"></i>' if start and k < wb else "")
                   + (('<span class="pv ' + lvl + '" title="'
                       + h.esc({"__NONE__": "not recorded", "__NULL__": "(unset)"}.get(v, v))
                       + '">' + _pv_html(v) + '</span>') if start or k == 0 else "")
                   + '</div>')
            prev = v
        gut = ('<div class="g" role="cell"><div class="gl1"><span class="d1">'
               + ('varies' if last is None else 'changed in Current' if last == 0
                  else 'changed ' + h.wg_date(w, last))
               + '</span></div>'
               + ('<div class="gx"><span data-mk-at="' + str(last) + '" data-mk-icon hidden></span></div>'
                  if last is not None else '')
               + '</div>')
        L.append('<div class="r p" data-name="' + h.esc(name) + '" role="row">'
                 '<div class="l" role="rowheader"><span class="nm">'
                 + h.ent('<code>' + h.esc(name) + '</code>', h.anchor_id("pa", name), "parameter")
                 + '</span><span class="sub">' + _pv_html(base) + ' &rarr; ' + _pv_html(_pv_at(cells, name, 0))
                 + '</span></div>')
        L.append(ch)
        L.append(gut + '</div>')
    L.append('</div></div>'
             + ('<p class="cfg-more">and ' + str(nch - 8) + ' more in <a href="#param-changes">Parameters</a></p>'
                if nch > 8 else '')
             + '<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
             + h.anchor_id("pa", changed[0]) + '">Timeline &rarr;</a>'
             '<span class="evl"><a href="#param-changes">Parameters</a></span></footer></article>')
    L.append('<script>(function(){var s=document.getElementById("changes-slot"),'
             'c=document.getElementById("f-config");if(!s||!c)return;s.appendChild(c);c.hidden=false;'
             'var x=document.getElementById("s-changes");if(x)x.hidden=false;})();</script>')
    # v1.6.0 Timeline: the Configuration lane (every changed parameter, at most 20)
    nt = min(20, len(changed))
    for i, name in enumerate(changed[:20], start=1):
        base = _pv_at(cells, name, wb)
        prev, last, ch = None, None, ""
        for k in range(wb, -1, -1):
            v = _pv_at(cells, name, k)
            start = (k == wb) or (v != prev)
            if start and k < wb:
                last = k
            lvl = "lo" if v == base else "hi"
            ch += ('<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k)
                   + '" data-pv="' + _pv_html(v) + '"><i class="st ' + lvl
                   + (" rise" if start and k < wb else "") + '" aria-hidden="true"></i>'
                   + ('<i class="nd" aria-hidden="true"></i>' if start and k < wb else "")
                   + (('<span class="pv ' + lvl + '">' + _pv_html(v) + '</span>') if start or k == 0 else "")
                   + '</div>')
            prev = v
        L.append((h.tl_open("config") if i == 1 else "")
                 + '<div class="r p" id="tl-' + h.anchor_id("pa", name) + '" data-name="'
                 + h.esc(name) + '" role="row">'
                 + h.tl_lab(h.ent(h.esc(name), h.anchor_id("pa", name), "parameter"),
                            _pv_html(base) + ' &rarr; ' + _pv_html(_pv_at(cells, name, 0)))
                 + ch
                 + '<div class="g" role="cell"><div class="gl1"><span class="d1">'
                 + ('varies' if last is None else 'changed in Current' if last == 0
                    else 'changed ' + h.wg_date(w, last))
                 + '</span></div>'
                 + ('<div class="gx"><span data-mk-at="' + str(last) + '" data-mk-icon hidden></span></div>'
                    if last is not None else '')
                 + '</div></div>'
                 + (h.tl_close() if i == nt else ""))


def emit(w) -> str:
    L = ["<!-- AWR-SECTION: " + TAG + " BEGIN -->"]
    L.append('<section id="param-changes" class="vw in-s in-a lib" style="--os:9"><h2>Parameters'
             '<small class="h2sub">Initialization parameters whose value differs across the windows</small></h2>')

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
                 "changed across the compared windows.</p>" + h.lib_ls("param-changes", "none differ") + "</section>")
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
        row = '<tr id="' + h.anchor_id("pa", name) + '"><td class="pname"><code>' + h.esc(name) + "</code></td>"
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
    _config_card(w, L, changed, cells)
    L.append("<!-- AWR-SECTION: " + TAG + " END -->")
    return "\n".join(L)
