"""
Twin of sql/16_day_profile.sql (+ sql/lib/day_profile_cte.sql) -- Day
profile: every hour of the 24 h ending at target_end scored against the
same hour-of-day on the profile_days prior days at a fixed 1-day cadence.

The CTE chain's cell (stat, day_off, hour_slot) is the per-second rate of
the snap pair whose midpoint falls in that hour; on the demo's hourly
grid that is exactly w.hour(target_end - day_off days - hour_slot h), so
cell = m.load[stat] / m.dur_sec * scale (DB time / DB CPU centiseconds
scaled by 0.01).  No restart sits inside the 8-day span and every hour
has a 3600 s pair, so the 30-min coverage guard never fires.  Scoring is
section 07's CASE (helpers.mean_sd / z_and_pct / bucket_of); the SIGNED
z heatmap, the per-stat line chart and the always-emitted table mirror
the SQL, including put_clob_chunked's comma-backed 32500-char chunking
of the JSON payload.
"""
from __future__ import annotations

from datetime import timedelta

from awrdemo import chrome
from awrdemo import helpers as H

# dp_targets: stat_name, ord, label, scale
TARGETS = [
    ("DB time", 1, "DB time (avg active sessions)", 0.01),
    ("DB CPU", 2, "DB CPU (avg CPUs busy)", 0.01),
    ("user calls", 3, "user calls/s", 1),
    ("execute count", 4, "executions/s", 1),
    ("session logical reads", 5, "logical reads/s", 1),
    ("physical reads", 6, "physical reads/s", 1),
    ("physical writes", 7, "physical writes/s", 1),
    ("redo size", 8, "redo bytes/s", 1),
    ("user commits", 9, "commits/s", 1),
]

_CHUNK = 32500


def _jn(p) -> str:
    return "null" if p is None else H.num6(p)


def _js(p) -> str:
    return '"' + str(p).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _col_fmt(vmax: float):
    """v_fmt(o): the TO_CHAR mask picked from the column max."""
    if vmax == 0 or vmax >= 1000:
        return lambda x: H.to_char_fixed(x, 0, group=True)          # FM999G999G999G990
    if vmax >= 1:
        return lambda x: H.to_char_fixed(x, 2, group=True)          # FM999G990D00
    if vmax >= 0.01:
        return lambda x: H.to_char_trim(x, 4, min_dec=1)            # FM990D0000
    return lambda x: H.to_char_trim(x, 6, min_dec=1)                # FM990D000000


def _dy_dd_mon(dt) -> str:      # 'Dy DD Mon'
    return H.dy(dt) + " " + dt.strftime("%d") + " " + H.mon_dd(dt)[:3]


def _put_clob_chunked(payload: str, put) -> None:
    """sql/lib/put_clob_chunked.plsql: PUT_LINE in <=32500-char chunks,
    each non-final chunk backed off to end on its last comma."""
    n = len(payload)
    pos = 0
    while pos < n:
        take = min(_CHUNK, n - pos)
        if pos + take < n:
            cut = payload.rfind(",", pos, pos + take)
            if cut >= 0:
                take = cut - pos + 1
        put(payload[pos:pos + take])
        pos += take


def _cells(w):
    """dp_scored rows keyed (ord, hour_slot)."""
    days = w.profile_days
    t_end = w.target_end
    cells = {}
    for stat, ord_, label, scale in TARGETS:
        for h in range(24):
            rates = []
            for d in range(days + 1):
                ts = t_end - timedelta(days=d, hours=h)
                snap = w.snap_at(ts)
                prev = w.snap_at(ts - timedelta(hours=1))
                if snap is None or prev is None or snap.startup_time != prev.startup_time:
                    rates.append(None)          # restart guard / gap -> NULL cell
                    continue
                m = w.hour(ts)
                rates.append(max(m.load.get(stat, 0.0), 0.0) / m.dur_sec * scale)
            cur = rates[0]
            mu, sd, n = H.mean_sd(rates[1:])
            z, pct = H.z_and_pct(cur, mu, sd)
            bucket = H.policy_bucket("LOAD", stat, None, cur, mu, sd, n)
            start = t_end - timedelta(hours=h + 1)
            cells[(ord_, h)] = {
                "label": label, "hour_slot": h,
                "hour_label": H.hh24(start), "hour_start": H.ts_min(start),
                "cur_val": cur, "mu": mu, "sd": sd, "n": n,
                # positional CSV, oldest day first ... current day last
                "day_vals": [rates[d] for d in range(days, -1, -1)],
                "z_score": z, "pct_delta": pct, "change_bucket": bucket,
            }
    return cells


def emit(w) -> str:
    out = []
    put = out.append
    put("<!-- AWR-SECTION: 16_day_profile BEGIN -->")
    days = w.profile_days
    if days <= 0:
        put("<!-- AWR-SECTION: 16_day_profile END -->")
        return "\n".join(out)

    t_end = w.target_end
    cells = _cells(w)
    nstat = len(TARGETS)
    labels = {o: lbl for _, o, lbl, _ in TARGETS}
    put('<section id="day-profile">')

    if not any(c["cur_val"] is not None for c in cells.values()):
        put("<h2>Day profile &mdash; hour-of-day vs the " + str(days) + " prior days</h2>")
        put('<p style="color:var(--muted)">No usable snapshot pairs in the '
            "24 h ending " + H.ts_min(t_end) + " &mdash; cannot build the profile.</p></section>")
        put("<!-- AWR-SECTION: 16_day_profile END -->")
        return "\n".join(out)

    # Pass 1: per-column format masks, severity counters.
    colmax = {o: 0.0 for o in labels}
    crit = warn = 0
    for (o, _h), c in cells.items():
        colmax[o] = max(colmax[o], abs(c["cur_val"] or 0), abs(c["mu"] or 0))
        if c["change_bucket"] == "large":
            crit += 1
        elif c["change_bucket"] == "moderate":
            warn += 1
    fmt = {o: _col_fmt(colmax[o]) for o in labels}
    hours_hit = 0
    for h in range(24):
        if any(cells[(o, h)]["change_bucket"] in ("large", "moderate") for o in labels):
            hours_hit += 1
    # Day-wide shifts: >= 12 flagged hours in the same direction per stat.
    up = {o: 0 for o in labels}
    down = {o: 0 for o in labels}
    for (o, _h), c in cells.items():
        if c["change_bucket"] in ("large", "moderate"):
            if c["z_score"] >= 0:
                up[o] += 1
            else:
                down[o] += 1
    shift = {o: (1 if up[o] >= 12 else (-1 if down[o] >= 12 else 0)) for o in labels}
    nshift = sum(1 for o in labels if shift[o] != 0)
    isolated = sum(up[o] + down[o] for o in labels if shift[o] == 0)

    if nshift > 0:
        put('<script>document.getElementById("day-profile").setAttribute("data-normal","Y");</script>')

    plural = "" if days == 1 else "s"
    put("<h2>Day profile &mdash; hour-of-day vs the " + str(days)
        + " prior day" + plural + " "
        + ('<span class="badge crit">' + str(nshift) + " day-wide shift"
           + ("" if nshift == 1 else "s") + "</span> " if nshift > 0 else "")
        + '<span class="badge warn">' + str(isolated) + " isolated hour"
        + ("" if isolated == 1 else "s") + "</span> "
        + '<span class="badge skip" title="' + str(crit) + " large / " + str(warn)
        + ' moderate cells">' + str(hours_hit) + " of 24 hours flagged</span></h2>")
    put('<p style="font-size:12px;color:var(--muted)">'
        "Each hour of the 24 h ending <b>" + H.dy(t_end) + " " + H.ts_min(t_end) + "</b> "
        "is compared with the <b>same hour-of-day</b> on the " + str(days) + " prior day"
        + plural
        + " (" + (t_end - timedelta(days=days + 1)).strftime("%Y-%m-%d") + " &rarr; "
        + (t_end - timedelta(days=1)).strftime("%Y-%m-%d") + "), independent of the report cadence above. "
        "Per-second rates from DBA_HIST_SYSSTAT snapshot deltas (restart-guarded); "
        "an hour covered by less than 30 min of snapshots is left blank rather than shown as 0. "
        "Cells are scored like the Findings summary: <b>large</b> = |z| &gt; 3, "
        "<b>moderate</b> = |z| &gt; 2, against the mean and standard deviation of the prior days "
        "(needs at least 3 prior values; z over max(&sigma;, 2% of &mu;), moves under 10% are typical). "
        "A stat flagged in 12 or more hours in the same direction is one <b>day-wide shift</b>; "
        "its cells stay tinted in the table but are not counted as isolated hours. "
        "The heatmap shows <b>signed</b> z "
        "(red = above the prior days, blue = below); pick a metric to see the hour-by-hour "
        "line against its prior-day band.</p>")

    if nshift > 0:
        put('<table id="day-profile-shifts" data-nocount data-notools><thead><tr>'
            "<th>Day-wide shift</th><th>Direction</th>"
            '<th class="num">Hours flagged</th><th class="num">Median z</th>'
            "</tr></thead><tbody>")
        for o in range(1, nstat + 1):
            if shift[o] == 0:
                continue
            zs = sorted(abs(cells[(o, h)]["z_score"]) for h in range(24)
                        if cells[(o, h)]["change_bucket"] in ("large", "moderate")
                        and (1 if cells[(o, h)]["z_score"] >= 0 else -1) == shift[o])
            nz = len(zs)
            if nz == 0:
                medz = None
            elif nz % 2 == 1:
                medz = zs[(nz + 1) // 2 - 1]
            else:
                medz = (zs[nz // 2 - 1] + zs[nz // 2]) / 2
            put('<tr class="crit" data-stat="' + str(o) + '">'
                "<td>" + H.esc(labels[o]) + "</td>"
                "<td>" + ('<span class="g">&#9650;</span> above the prior days' if shift[o] > 0
                          else '<span class="g">&#9660;</span> below the prior days') + "</td>"
                '<td class="num">' + str(nz) + " of 24</td>"
                '<td class="num">' + ("&mdash;" if medz is None
                                      else H.to_char_fixed(medz * shift[o], 1, plus=True))
                + "</td></tr>")
        put("</tbody></table>")

    # Charts (hidden wholesale by body.no-charts; the table below is the fallback).
    put('<div class="chart-wrap chart-big" id="day-profile-heatmap"></div>')
    put('<div class="chart-wrap" id="day-profile-line-wrap">'
        '<div style="font-size:12px;color:var(--muted);margin:2px 4px 6px">Metric: '
        '<select id="day-profile-sel">')
    for o in range(1, nstat + 1):
        put('<option value="' + str(o - 1) + '">' + H.esc(labels[o]) + "</option>")
    put("</select> &mdash; current day (teal) vs prior-day mean (dashed) "
        "with the &mu;&nbsp;&plusmn;&nbsp;2&sigma; band; faint lines are the individual prior days.</div>"
        '<div id="day-profile-line" style="height:240px"></div></div>')

    # Table: one row per hour (chronological), one column per stat.
    row = "<table class=\"full-only\"><thead><tr><th>Hour</th>"
    for o in range(1, nstat + 1):
        row += '<th class="num">' + H.esc(labels[o]) + "</th>"
    put(row + "</tr></thead><tbody>")
    for h in range(23, -1, -1):
        row_cls = ""
        row = ""
        for o in range(1, nstat + 1):
            c = cells.get((o, h))
            if c is None:
                row += '<td class="num">&mdash;</td>'
                continue
            cls = H.bucket_cls(c["change_bucket"])
            if shift[o] == 0:
                if cls == "crit":
                    row_cls = "crit"
                elif cls == "warn" and row_cls != "crit":
                    row_cls = "warn"
            f = fmt[o]
            row += ('<td class="num" title="'
                    "prior mean " + ("-" if c["mu"] is None else f(c["mu"]))
                    + " / sd " + ("-" if c["sd"] is None else f(c["sd"]))
                    + " / n " + str(c["n"])
                    + " / z " + ("-" if c["z_score"] is None else H.to_char_fixed(c["z_score"], 2, plus=True))
                    + " / " + ("-" if c["pct_delta"] is None
                               else H.to_char_fixed(c["pct_delta"], 1, plus=True) + "%")
                    + " / " + c["change_bucket"] + '">'
                    + ("&mdash;" if c["cur_val"] is None else f(c["cur_val"]))
                    + (' <span class="badge ' + cls + '">'
                       + H.to_char_fixed(c["z_score"], 1, plus=True) + "&sigma;</span>"
                       if cls in ("crit", "warn") else "")
                    + "</td>")
        c1 = cells.get((1, h))
        put('<tr data-hour="' + str(h) + '"'
            + (' class="' + row_cls + '"' if row_cls else "")
            + "><td>" + (H.esc(c1["hour_start"]) if c1 is not None else str(h))
            + "</td>" + row + "</tr>")
    put("</tbody></table>")

    # JSON payload for the charts (built like the CLOB, emitted chunked).
    buf = "{ndays:" + str(days) + ",hours:["
    for h in range(23, -1, -1):
        c1 = cells.get((1, h))
        buf += ("," if h < 23 else "") + _js(c1["hour_label"] if c1 is not None else str(h))
    buf += "],dates:["
    for d in range(days, -1, -1):
        buf += ("," if d < days else "") + _js(_dy_dd_mon(t_end - timedelta(days=d)))
    buf += "],stats:["
    for o in range(1, nstat + 1):
        cur = mu = sd = n = z = pct = sev = ""
        day_buf = [""] * (days + 1)
        for h in range(23, -1, -1):
            c = cells.get((o, h))
            if c is None:
                c = {"cur_val": None, "mu": None, "sd": None, "n": None, "z_score": None,
                     "pct_delta": None, "change_bucket": None, "day_vals": [None] * (days + 1)}
            cur += "," + _jn(c["cur_val"])
            mu += "," + _jn(c["mu"])
            sd += "," + _jn(c["sd"])
            n += "," + str(c["n"] if c["n"] is not None else 0)
            z += "," + _jn(c["z_score"])
            pct += "," + _jn(None if c["pct_delta"] is None else H.ora_round(c["pct_delta"], 1))
            sev += "," + _js(c["change_bucket"] if c["change_bucket"] is not None else "n/a")
            for d in range(days + 1):
                tok = c["day_vals"][d]
                day_buf[d] += "," + ("null" if tok is None else H.num6(tok))
        buf += (("," if o > 1 else "")
                + "{name:" + _js(labels[o])
                + ",cur:[" + cur[1:] + "]"
                + ",mu:[" + mu[1:] + "]"
                + ",sd:[" + sd[1:] + "]"
                + ",n:[" + n[1:] + "]"
                + ",z:[" + z[1:] + "]"
                + ",pct:[" + pct[1:] + "]"
                + ",sev:[" + sev[1:] + "]"
                + ",days:[")
        for d in range(days + 1):
            buf += ("," if d > 0 else "") + "[" + day_buf[d][1:] + "]"
        buf += "]}"
    buf += "]}"

    # <script> ... </script>: every PUT_LINE is literal; the CLOB is
    # spliced in right after 'AWR_DATA.dayProfile='.
    entries = chrome.put_lines(chrome.sql_path("sql/16_day_profile.sql"))
    texts = [t for t, _ in entries]
    i, j = texts.index("<script>"), texts.index("</script>")
    for t in texts[i:j + 1]:
        put(t)
        if t == "AWR_DATA.dayProfile=":
            _put_clob_chunked(buf, put)

    put("</section>")
    put("<!-- AWR-SECTION: 16_day_profile END -->")
    return "\n".join(out)
