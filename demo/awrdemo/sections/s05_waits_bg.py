"""
Twin of sql/05_waits_bg.sql -- background wait events
(DBA_HIST_BG_EVENT_SUMMARY deltas per window): stacked wait-class chart
and the two per-event tables (s / ms per wait).  No class rollup table.
"""
from __future__ import annotations

from awrdemo.sections import _waits as C

TAG = "05_waits_bg"


def emit(w) -> str:
    L = ["<!-- AWR-SECTION: " + TAG + " BEGIN -->"]
    L.append('<section id="waits-bg"><h2>Background wait events</h2>')

    # NVL(bg.wait_class, 'Other') <> 'Idle'
    deltas = C.window_deltas(w, lambda m: m.bg_waits, other_for_null_class=True)

    # v_cnt: any event with a > 0 delta in any valid window
    if not any(d and any(t[2] > 0 for t in d.values()) for d in deltas):
        L.append('<p style="color:var(--muted)">No background wait activity captured in '
                 "DBA_HIST_BG_EVENT_SUMMARY for any valid window.</p>")
        L.append("</section>")
        L.append("<!-- AWR-SECTION: " + TAG + " END -->")
        return "\n".join(L)

    L.append('<p style="font-size:12px;color:var(--muted)">'
             "DBA_HIST_BG_EVENT_SUMMARY, Idle excluded. "
             "Chart stacks wait_class time per window. "
             "Tables: time_waited (s) and avg latency "
             "(ms = time_waited &divide; total_waits).</p>")
    L.append('<div class="chart-wrap chart-small" id="waits-bg-stack"></div>')

    # ---- chart: class_deltas sums only the events with a > 0 delta;
    # ORDER BY MAX(time_waited_us) DESC NULLS LAST, wait_class.
    class_sum = [None if d is None else {} for d in deltas]
    for k, d in enumerate(deltas):
        if d is None:
            continue
        for ev, (cls, waits, us) in d.items():
            if us > 0:
                class_sum[k][cls] = class_sum[k].get(cls, 0.0) + us
    classes = {cls for cs in class_sum if cs for cls in cs}
    grid = {cls: [None if cs is None else cs.get(cls) for cs in class_sum] for cls in classes}
    cj = C.class_json(w, grid, lambda vals: C.desc_nulls_last(
        max((v for v in vals if v is not None), default=None)))
    L.extend(C.chart_script("waitsBg", "waits-bg-stack", C.weeks_json(w), cj))

    rows = C.event_rows(w, deltas)
    tot = C.current_total_us(deltas)
    shift, n_flag, mean_pct, sd_pct = C.shift_pass(rows, tot)
    L.extend(C.table_time(w, rows, "waits-bg-time", "Events &mdash; time waited (s)",
                          tot, shift, C.shift_note(rows, shift, n_flag, mean_pct, sd_pct), "bg"))
    avg = C.table_avg(w, rows, "waits-bg-avg", "Events &mdash; avg time per wait (ms)", "bgms")
    avg[-1] = "</tbody></table></section>"
    L.extend(avg)
    L.append("<!-- AWR-SECTION: " + TAG + " END -->")
    return "\n".join(L)
