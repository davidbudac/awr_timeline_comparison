"""
Twin of sql/04_waits_fg.sql -- foreground wait events (DBA_HIST_SYSTEM_EVENT
deltas per window): stacked wait-class chart, top-N events by time waited
(s) and by avg latency (ms), plus the wait-class rollup table.
"""
from __future__ import annotations

from awrdemo import helpers as h
from awrdemo.sections import _waits as C

TAG = "04_waits_fg"


def emit(w) -> str:
    L = ["<!-- AWR-SECTION: " + TAG + " BEGIN -->"]
    top_n = w.top_n
    L.append('<section id="waits-fg"><h2>Foreground wait events (top '
             + str(top_n) + " by time waited)</h2>")
    L.append('<p style="font-size:12px;color:var(--muted)">'
             "DBA_HIST_SYSTEM_EVENT, foreground waits, Idle excluded. "
             "Chart stacks wait_class time per window. "
             "Tables: top-" + str(top_n) + " by time_waited (s) and by avg latency "
             "(ms = time_waited &divide; total_waits).</p>")
    L.append('<div class="chart-wrap chart-small" id="waits-fg-stack"></div>')

    deltas = C.window_deltas(w, lambda m: m.fg_waits)
    n_win = len(deltas)

    # ---- chart: class_deltas = SUM of every event delta per (week, class);
    # classes = those with a > 0 total in some window; ORDER BY cur DESC
    # NULLS LAST, wait_class.
    class_sum = [None if d is None else {} for d in deltas]
    for k, d in enumerate(deltas):
        if d is None:
            continue
        for ev, (cls, waits, us) in d.items():
            class_sum[k][cls] = class_sum[k].get(cls, 0.0) + us
    classes = sorted({cls for cs in class_sum if cs for cls, v in cs.items() if v > 0})
    grid = {cls: [None if cs is None else cs.get(cls) for cs in class_sum] for cls in classes}
    cj = C.class_json(w, grid, lambda vals: C.desc_nulls_last(vals[0]))
    L.extend(C.chart_script("waitsFg", "waits-fg-stack", C.weeks_json(w), cj))

    # ---- top-N events, two tables
    rows = C.event_rows(w, deltas)
    tot = C.current_total_us(deltas)
    shift, n_flag, mean_pct, sd_pct = C.shift_pass(rows, tot)
    L.extend(C.table_time(w, rows, "waits-fg-time",
                          "Top " + str(top_n) + " events &mdash; time waited (s)",
                          tot, shift, C.shift_note(rows, shift, n_flag, mean_pct, sd_pct)))
    L.extend(C.table_avg(w, rows, "waits-fg-avg",
                         "Top " + str(top_n) + " events &mdash; avg time per wait (ms)"))

    # ---- wait-class rollup table: class_deltas HAVING SUM(us) > 0 per
    # (week, class); grid over all weeks; ORDER BY cur DESC NULLS LAST.
    roll = [None if cs is None else {cls: v for cls, v in cs.items() if v > 0} for cs in class_sum]
    rclasses = {cls for cs in roll if cs for cls in cs}
    crows = []
    for cls in rclasses:
        vals = [None if cs is None else cs.get(cls) for cs in roll]
        mu, sd, n = h.mean_sd(vals[1:])
        crows.append({"wait_class": cls, "cur_us": vals[0], "mu_us": mu, "sd_us": sd, "n_us": n,
                      "week_vals": h.csv_num6(None if v is None else v / 1e6 for v in vals)})
    crows.sort(key=lambda r: C.desc_nulls_last(r["cur_us"]))

    L.append("<h3>Wait-class rollup &mdash; time waited (s)</h3>")
    L.append('<table id="waits-fg-class">'
             + C.header(w, "<th>Wait class</th>", "s", with_trend=False) + "<tbody>")
    for r in crows:
        cur_s = None if r["cur_us"] is None else r["cur_us"] / 1e6
        row = ('<tr id="' + h.anchor_id("fgc", r["wait_class"]) + '"><td>' + h.esc(r["wait_class"]) + "</td>"
               + '<td class="num" data-w="0"' + h.fmt_num_title(cur_s) + "><b>"
               + h.fmt_num(cur_s) + "</b></td>")
        for k in range(1, w.weeks_back + 1):
            us_s = C.nth_csv(r["week_vals"], k + 1)
            if us_s == "":
                row += '<td class="num" data-w="' + str(k) + '">&mdash;</td>'
            else:
                us = float(us_s)
                row += ('<td class="num" data-w="' + str(k) + '"' + h.dev_attr(cur_s, us) + ">"
                        + h.fmt_num(us) + "</td>")
        share = (r["cur_us"] / tot) if (tot and r["cur_us"] is not None) else None
        row += h.score_cells(r["cur_us"], r["mu_us"], r["sd_us"], r["n_us"], share,
                             "WAIT", "Wait class: " + r["wait_class"], r["wait_class"])
        row += "</tr>"
        L.append(row)
    L.append("</tbody></table></section>")
    L.append("<!-- AWR-SECTION: " + TAG + " END -->")
    return "\n".join(L)
