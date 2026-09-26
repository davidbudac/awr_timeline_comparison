"""
Twin of sql/08_overview.sql -- the Summary view's hero strip (v1.6.0):
DB time per compared window on the window component (ruler, one column
per window, Current last), the Current value in AAS with its normal range
on the left and the Delta / z / band on the right.
"""
from __future__ import annotations

from .. import helpers as h


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 08_overview BEGIN -->"]

    def fn(m):
        if "DB time" not in m.load or m.dur_sec <= 0:
            return None
        return m.load["DB time"] / m.dur_sec

    series = w.window_series(fn)                      # index = week_offset
    vals = {k: v for k, v in enumerate(series) if v is not None}
    cur = vals.get(0)
    mu, sd, n = h.mean_sd([v for k, v in vals.items() if k > 0])
    bucket = "n/a" if cur is None else h.policy_bucket("LOAD", "DB time", None, cur, mu, sd, n)
    z = h.band_z(cur, mu, sd)

    lab = ('<div class="l" role="rowheader"><span class="big">' + h.fmt_num(h._mul(cur, 0.01))
           + '<span class="u">AAS</span></span>'
           '<span class="sub">normal ' + h.range_txt(h._mul(mu, 0.01), h._mul(sd, 0.01)) + '</span></div>')
    gut = ('<div class="g" role="cell"><div class="gl1">'
           + h.delta_span(cur, mu, bucket).replace('class="d ', 'class="d d1 ')
           + ('<span class="z">z ' + h.band_ztxt(z) + '</span>' if z is not None and -4 <= z <= 8 else '')
           + '</div>' + h.band_span(z, bucket, "sm") + '</div>')

    out.append('<section id="overview" class="vw in-s strip-sec" aria-label="DB time per compared window">')
    out.append('<div class="panel strip" id="s-strip"><div class="wg fit hov"' + h.wg_attr(w)
               + ' role="table" aria-label="DB time per compared window">')
    out.append(h.wg_ruler(w, '<span class="ct">DB time per window</span>'
                             '<span class="cs">average active sessions</span>',
                          '<span class="gt">vs prior mean</span>'))
    out.append(h.wg_bars(w, vals, 0.01, mu, sd, bucket, lab, gut, "hero-dbt"))
    out.append('</div></div></section>')
    out.append("<!-- AWR-SECTION: 08_overview END -->")
    return "\n".join(out)
