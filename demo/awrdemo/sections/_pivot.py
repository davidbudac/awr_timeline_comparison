"""
Shared per-window pivot-row emitter for the sysstat / sysmetric pivots
(sections 02, 03, 13): the identical PL/SQL loop body those three
sections carry -- header <thead>, spark CSV (oldest -> current), the
Current cell-bar, and one dev_attr-tinted <td data-w=k> per prior window.
"""
from __future__ import annotations

from awrdemo.helpers import (csv_num6, dev_attr, fmt_num, fmt_num_title,
                             num6, to_char_fixed)


def header(w, with_unit: bool) -> str:
    h = '<thead><tr><th>Metric</th>'
    if with_unit:
        h += '<th>Unit</th>'
    h += '<th class="trend">Trend</th><th class="num" data-w="0">Current</th>'
    for k in range(1, w.weeks_back + 1):
        h += '<th class="num" data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + '</th>'
    return h + '</tr></thead>'


def spark_vals(vals) -> str:
    """LISTAGG ... ORDER BY week_offset DESC (oldest -> current)."""
    return csv_num6(list(reversed(vals)))


def value_cells(vals) -> str:
    """The Current cell-bar + the prior-window cells.  `vals` is indexed
    by week_offset (0 = current), None for a skipped window."""
    cur = vals[0]
    present = [v for v in vals if v is not None]
    row_max = max(present) if present else 0
    if row_max > 0 and cur is not None:
        pct = min(100, abs(cur) / row_max * 100)
    else:
        pct = 0
    out = ('<td class="num cell-bar" data-w="0"' + fmt_num_title(cur) + '>'
           + '<span class="bg" style="width:' + to_char_fixed(pct, 1) + '%"></span>'
           + '<span class="v"><b>' + fmt_num(cur) + '</b></span></td>')
    for k in range(1, len(vals)):
        v = vals[k]
        if v is None:
            out += '<td class="num" data-w="' + str(k) + '">&mdash;</td>'
        else:
            # TO_NUMBER(nth_csv(week_vals, k+1)): the 6-decimal round-trip
            v = float(num6(v))
            out += ('<td class="num" data-w="' + str(k) + '"' + dev_attr(cur, v) + '>'
                    + fmt_num(v) + '</td>')
    return out
