"""Twin of sql/28_release_delta.sql (Before and after a release).

Emits the per-window values of every canonical LOAD / METRIC row and the
wait-class rollups (07's recompute, reused from s07_summary._unified_rows)
as window.AWR_DATA.reldelta, the client view's skeleton, the JS-off table
(Current vs mean / sd of all prior windows) and the generated script.  The
split itself (the model's Release 4.2 marker sits between the last prior
window and Current) is computed by sql/lib/js_reldelta.plsql in the page.
"""
from __future__ import annotations

from awrdemo import chrome
from .. import helpers as h
from .s07_summary import _unified_rows

_SQL = "sql/28_release_delta.sql"


def _lit(start: str) -> str:
    """The literal PUT_LINE of the SQL that starts with `start`."""
    for t, ok in chrome.put_lines(chrome.sql_path(_SQL)):
        if ok and t.startswith(start):
            return t
    raise KeyError(start)


def _jnum(v) -> str:
    return "null" if v is None else h.wg_tok(v)


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 28_release_delta BEGIN -->']
    nvalid = sum(1 for x in w.windows if x.valid)
    nprior = sum(1 for x in w.windows if x.valid and x.week_offset > 0)
    rows = _unified_rows(w)
    keys = sorted(rows.keys())

    out.append('<section id="release-delta" class="vw in-s in-a lib" style="--os:18"><h2>Before and after a release'
               "<small class=\"h2sub\">Each metric's mean after a release against its mean and usual variation "
               'before it</small></h2>')
    if not keys or nvalid < 3:
        out.append('<p class="note">'
                   + ('No metric values: no valid compared window.' if not keys else
                      'Only %d valid compared window%s: a split needs at least two windows before it and one after it.'
                      % (nvalid, '' if nvalid == 1 else 's'))
                   + '</p>')
        out.append(h.lib_ls('release-delta', 'no valid compared window' if not keys
                            else 'too few valid windows to split (%d)' % nvalid))
        out.append('</section>')
    else:
        parts = []
        tbl = []
        nmet = 0
        for dom, name in keys:
            pol = h.metric_policy(dom, name)
            if pol[1] != 'Y':
                continue
            nmet += 1
            s = h.metric_scale(dom, name)
            u = h.metric_unit(dom, name)
            by = rows[(dom, name)]
            vals = ",".join('"%d":%s' % (k, _jnum(by[k])) for k in sorted(by))
            parts.append('{"d":"' + dom[0] + '","n":"' + h.json_escape(name) + '","l":"'
                         + h.json_escape(h.metric_label(dom, name)) + '","u":"' + h.json_escape(u)
                         + '","s":' + _jnum(s) + ',"dir":"' + pol[2] + '","mp":' + _jnum(pol[3])
                         + ',"ma":' + _jnum(pol[4]) + ',"id":"' + h.finding_anchor(dom, name)
                         + '","v":{' + vals + '}}')
            cur = by.get(0)
            mu, sd, n = h.mean_sd([v for k, v in by.items() if k > 0])

            def mul(v):
                return None if v is None else v * s
            tbl.append('<tr><td>' + h.ent(h.esc(h.metric_label(dom, name)), h.finding_anchor(dom, name), 'metric')
                       + '</td><td class="num" data-w="0"' + h.fmt_num_title(mul(cur)) + '>' + h.fv(mul(cur), u) + '</td>'
                       + '<td class="num">' + h.fv(mul(mu), u) + '</td>'
                       + '<td class="num">' + h.fv(mul(sd), u) + '</td>'
                       + '<td class="num">' + str(n) + '</td></tr>')
        out.append('<script>window.AWR_DATA=window.AWR_DATA||{};window.AWR_DATA.reldelta={"nv":'
                   + str(nvalid) + ',"m":[' + ",".join(parts) + ']};</script>')
        out.append(h.lib_ls('release-delta', '%d metrics over %d valid windows; pick a release marker or a '
                            'window boundary to split them' % (nmet, nvalid)))
        out.append('<p class="note rd-nojs">The split before / after a release is computed by the page '
                   'script, so it needs JavaScript. The table compares Current with the mean and sd of all '
                   + str(nprior) + ' valid prior windows.</p>')
        out.append(_lit('<div class="rd-app" hidden>'))
        out.append('<details class="rd-all"><summary>Current against all ' + str(nprior)
                   + ' prior windows (no split), ' + str(nmet) + ' metrics</summary><div class="tblwrap">'
                   '<table class="rd-tall" data-nocount><thead><tr><th>Metric</th><th class="num cur-col" data-w="0">Current</th>'
                   '<th class="num">Prior mean</th><th class="num">Prior sd</th><th class="num">n</th></tr></thead><tbody>')
        out.extend(tbl)
        out.append('</tbody></table></div></details></section>')
    out.append(chrome.lib_script('js_reldelta.plsql'))
    out.append('<!-- AWR-SECTION: 28_release_delta END -->')
    return "\n".join(out)
