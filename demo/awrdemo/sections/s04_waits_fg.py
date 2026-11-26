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
    L.append('<section id="waits-fg" class="vw in-s in-a lib lopen" style="--os:3"><h2>Foreground waits'
             '<small class="h2sub">Where foreground sessions waited: top ' + str(top_n)
             + ' events by time and by average wait, and the wait classes</small></h2>')
    L.append('<div class="chart-wrap chart-small" id="waits-fg-stack"></div>')

    # DBA_HIST_SYSTEM_EVENT, all sessions (time_waited_micro): its
    # background-only events too (model.SYSEVENT_BG), as on a real DB
    deltas = C.window_deltas(w, lambda m: m.sys_waits)
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
    seen_we = {}                                   # v_seen_we (anchor_uniq memo)
    tot = C.current_total_us(deltas)
    shift, n_flag, mean_pct, sd_pct = C.shift_pass(rows, tot)
    L.extend(C.table_time(w, rows, "waits-fg-time",
                          "Top " + str(top_n) + " events &mdash; time waited (s)",
                          tot, shift, C.shift_note(rows, shift, n_flag, mean_pct, sd_pct), memo=seen_we))
    # ---- v1.6.0 Timeline: the Waits lane's event rows (Table A's order,
    # rows past the 10th fold, at most 16)
    # Values in AAS per window = the window's seconds / ITS real span
    # (v_span: MAX(dur_sec) of valid_windows, 07's divisor); data-mu /
    # data-sd from the prior windows' AAS values (STDDEV: 0 for one value);
    # the severity and the gutter stay Table A's (seconds).
    nt = min(len(rows), 16)
    span = {}                                      # v_span: valid windows only
    for win in w.windows:
        m = w.window_metrics(win)
        if m is not None:
            span[win.week_offset] = m.dur_sec

    def aas_row(csv):
        toks, prior = [], []
        for k in range(w.weeks_back, -1, -1):
            v = h.tl_val(w, csv, k)
            a = v / span[k] if (v is not None and span.get(k, 0) > 0) else None
            toks.append(h.wg_tok(a))
            if k > 0 and a is not None:
                prior.append(a)
        mu, sd, n = h.mean_sd(prior)
        return ",".join(toks), mu, (0.0 if n == 1 else sd)

    for i, r in enumerate(rows[:16], start=1):
        share = (r["cur_us"] / tot) if (tot and r["cur_us"] is not None) else None
        b = h.policy_bucket("WAIT", r["event_name"], r["wait_class"], C._s(r["cur_us"]),
                            C._s(r["mu_us"]), C._s(r["sd_us"]), r["n_us"], share, shift)
        csv, a_mu, a_sd = aas_row(r["spark_vals"])
        L.append((h.tl_open("waits") if i == 1 else "")
                 + h.tl_bars(w, csv, a_mu, a_sd, b,
                             h.tl_lab(h.ent(h.esc(r["event_name"]), h.anchor_uniq(h.anchor_id("we", r["event_name"]), r["event_name"], seen_we), "event"),
                                      h.esc(r["wait_class"]) + ", AAS", None, r["wait_class"]),
                             h.tl_gut(C._s(r["cur_us"]), C._s(r["mu_us"]), C._s(r["sd_us"]), b),
                             "tl-" + h.anchor_uniq(h.anchor_id("we", r["event_name"]), r["event_name"], seen_we),
                             "w" + (" more" if i > 10 else ""),
                             h.esc(r["event_name"]), "AAS")
                 + (h.tl_close() if i == nt else ""))
    moved = 0
    news = []                       # plan 040: card ids of the wait classes of the moved rows
    for r in rows:
        share = (r["cur_us"] / tot) if (tot and r["cur_us"] is not None) else None
        if h.policy_bucket("WAIT", r["event_name"], r["wait_class"], C._s(r["cur_us"]),
                           C._s(r["mu_us"]), C._s(r["sd_us"]), r["n_us"], share, shift) in ("large", "moderate"):
            moved += 1
            tok = "card:" + h.card_id(h.card_group("WAIT:" + r["wait_class"]))
            if tok not in news:
                news.append(tok)
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
        share = (r["cur_us"] / tot) if (tot and r["cur_us"] is not None) else None
        row = ('<tr id="' + h.anchor_id("wc", r["wait_class"]) + '"><td>' + h.esc(r["wait_class"]) + "</td>"
               + '<td class="num" data-w="0"' + h.fmt_num_title(cur_s) + "><b>"
               + h.fmt_num(cur_s) + "</b></td>"
               + h.score_cells(cur_s, C._s(r["mu_us"]), C._s(r["sd_us"]), r["n_us"], share,
                               "WAIT", "Wait class: " + r["wait_class"], r["wait_class"]))
        for k in range(1, w.weeks_back + 1):
            us_s = C.nth_csv(r["week_vals"], k + 1)
            if us_s == "":
                row += '<td class="num" data-w="' + str(k) + '">&mdash;</td>'
            else:
                us = float(us_s)
                row += ('<td class="num" data-w="' + str(k) + '">'
                        + h.fmt_num(us) + "</td>")
        row += "</tr>"
        L.append(row)
    L.append("</tbody></table>")
    L.append(h.lib_ls("waits-fg", "no foreground wait events" if not rows else
                      (("none" if moved == 0 else "<b>" + str(moved) + "</b>") + " of " + str(len(rows))
                       + " event" + ("" if len(rows) == 1 else "s") + " moved"))
             + h.lib_news("waits-fg", " ".join(news)) + "</section>")
    L.append("<!-- AWR-SECTION: " + TAG + " END -->")
    return "\n".join(L)
