"""
Twin of sql/08_overview.sql -- the 6-card hero strip.

Per card: label, mini chart div (data-spark = positional vals CSV, oldest
-> current, 'null' token for a skipped window), current value, the
inline-SVG bar strip (.hbars) on a lowered baseline, the "vs prior mean"
delta line with the prior min-max range, and the z-bucket badge.  Then
AWR_DATA.overview = {weeks, cards} + the mini-chart init script lifted
verbatim from the SQL.
"""
from __future__ import annotations

from datetime import timedelta

from .. import chrome
from .. import helpers as h

# (pos, label, unit, src, key) -- the `cards` CTE, left-to-right
CARDS = [
    (1, "DB time", "cs/s", "LOAD", "DB time"),
    (2, "Redo generated", "B/s", "LOAD", "redo size"),
    (3, "Logical reads", "/s", "LOAD", "session logical reads"),
    (4, "Average Active Sessions", "AAS", "METRIC", "Average Active Sessions"),
    (5, "Wait Time Ratio", "%", "METRIC", "Database Wait Time Ratio"),
    (6, "Hard parses", "/s", "LOAD", "parse count (hard)"),
]

BW, GAP = 34, 6


def _ora_num(x: float) -> str:
    """Implicit NUMBER -> VARCHAR2 of a value with <= 2 decimals and >= 1
    (the bar geometry never produces a leading-dot fraction)."""
    return h.to_char_trim(x, 2)


def _card_vals(w, src: str, key: str) -> list:
    """[value or None] indexed by week_offset (0 = current)."""
    def fn(m):
        if src == "LOAD":
            if key not in m.load or m.dur_sec <= 0:
                return None
            return m.load[key] / m.dur_sec
        return m.sysmetric.get(key)
    return w.window_series(fn)


def _script(overview_line: str) -> list[str]:
    """The literal <script>...</script> stretch of sql/08_overview.sql,
    with the single dynamic PUT_LINE (AWR_DATA.overview = ...) swapped
    for the hand-built line."""
    lines = chrome.put_lines(chrome.sql_path("sql/08_overview.sql"))
    texts = [t for t, _ in lines]
    i = texts.index("<script>")
    j = texts.index("</script>", i)
    out = []
    for t, lit in lines[i:j + 1]:
        if lit:
            out.append(t)
        else:
            if not t.startswith("AWR_DATA.overview = {weeks:"):
                raise ValueError("08_overview.sql: unexpected dynamic PUT_LINE in script: " + t[:60])
            out.append(overview_line)
    return out


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 08_overview BEGIN -->"]
    out.append('<section id="overview" data-triage="Y"><h2>Headline metrics</h2>')
    out.append('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
               "Six headline metrics across the compared windows, oldest &rarr; current. "
               "Badge = z bucket: |z|&gt;3 large, |z|&gt;2 moderate, else typical "
               "(z over max(&sigma;, 2% of &mu;); a move under 10% is typical; "
               "a material drop in a cost-type metric is <b>improved</b>).</p>")
    out.append('<div class="hero-grid">')

    n_win = w.weeks_back + 1
    # x-axis labels, oldest-first (ORDER BY week_offset DESC)
    weeks_json = "[" + ",".join(
        '"' + h.mon_dd(w.target_end - timedelta(hours=w.step_hours * k)) + '"'
        for k in range(w.weeks_back, -1, -1)) + "]"

    cards_json = []
    for pos, label, unit, src, key in CARDS:
        by_off = _card_vals(w, src, key)                # index = week_offset
        cur = by_off[0]
        mu, sd, n = h.mean_sd(by_off[1:])
        vals = list(reversed(by_off))                   # oldest -> current, 1..n_win
        vals_csv = ",".join("null" if v is None else h.num6(v) for v in vals)

        z, pct = h.z_and_pct(cur, mu, sd)
        sev = None if cur is None else h.bucket_of(cur, n, sd, z, pct=pct,
                                                   dir=h.higher_is_worse(src, key), mu=mu)
        sev_cls = h.bucket_cls(sev) if sev is not None else "skip"
        sig = h.sigma_flag(mu, sd)
        z_txt = None if z is None else h.z_txt(z, 1)

        cards_json.append(
            '{"pos":' + str(pos)
            + ',"label":"' + label
            + '","unit":"' + unit
            + '","cur":' + ("null" if cur is None else h.num6(cur))
            + ',"sev":' + ("null" if sev is None else '"' + sev + '"')
            + ',"z":' + ("null" if z is None else h.to_char_fixed(z, 2, plus=True))
            + ',"pct":' + ("null" if pct is None else h.to_char_fixed(pct, 1, plus=True))
            + ',"vals":[' + vals_csv + "]}")

        if sev is None:
            sev_badge = "n/a"
        elif z is not None:
            sev_badge = sev + " z=" + z_txt
        else:
            sev_badge = sev

        out.append('<div class="hero-card" data-hero-pos="' + str(pos) + '">')
        out.append('  <div class="label">' + label + "</div>")
        out.append('  <div class="mini" id="hero-mini-' + str(pos)
                   + '" data-spark="' + vals_csv
                   + '" data-spark-title="' + label + '"></div>')
        out.append('  <div class="value"' + h.fmt_num_title(cur) + ">"
                   + h.fmt_num(cur) + " <small>" + unit + "</small></div>")

        # B6: bar strip on a lowered baseline + prior min-max range
        present = [v for v in vals if v is not None]
        priors = [v for v in vals[:-1] if v is not None]
        bars = ""
        if present:
            min_all, max_all = min(present), max(present)
            lo = max(min_all - 1.5 * (max_all - min_all), 0)
            hi = lo + 1 if max_all == lo else max_all
            for k, v in enumerate(vals, start=1):
                if v is None:
                    continue
                bh = max(1, min(38, h.ora_round((v - lo) / (hi - lo) * 38, 2)))
                bars += ('<rect x="' + str((k - 1) * (BW + GAP))
                         + '" y="' + _ora_num(40 - bh)
                         + '" width="' + str(BW)
                         + '" height="' + _ora_num(bh)
                         + '" rx="2" fill="var(--accent)" opacity="'
                         + ("1" if k == n_win else "0.3") + '"></rect>')
        if bars:
            out.append('  <svg class="hbars" viewBox="0 0 '
                       + str(max(200, n_win * (BW + GAP) - GAP)) + ' 42" aria-hidden="true">'
                       + bars + "</svg>")

        pct_txt = h.pct_txt(pct)
        if priors:
            range_txt = h.fmt_num(min(priors)) + " &ndash; " + h.fmt_num(max(priors))
        else:
            range_txt = "&mdash;"
        out.append('  <div class="hc-delta">vs prior mean <b>' + pct_txt
                   + "</b> &middot; range " + range_txt + "</div>")
        out.append('  <div class="foot">'
                   + '<span class="badge ' + sev_cls + '">' + sev_badge + "</span>"
                   + (h.SIG_BADGE if sig else "")
                   + "</div>")
        out.append("</div>")

    out.append("</div>")

    out.extend(_script("AWR_DATA.overview = {weeks:" + weeks_json
                       + ",cards:[" + ",".join(cards_json) + "]};"))

    out.append("</section>")
    out.append("<!-- AWR-SECTION: 08_overview END -->")
    return "\n".join(out)
