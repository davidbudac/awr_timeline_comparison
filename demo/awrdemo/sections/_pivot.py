"""
Shared per-window pivot-row emitter for the sysstat / sysmetric pivots
(sections 02, 03, 13): the identical PL/SQL loop body those three
sections carry -- header <thead>, the Current cell-bar, the four band
cells (sql/lib/band_glyph.plsql, v1.6.0), the spark CSV (oldest ->
current) and one plain <td data-w=k> per prior window.
"""
from __future__ import annotations

from awrdemo.helpers import (band_cells, band_head, csv_num6, esc, fmt_num,
                             fmt_num_title, mean_sd, num6, to_char_fixed)


def header(w, with_unit: bool) -> str:
    h = '<thead><tr><th>Metric</th>'
    if with_unit:
        h += '<th>Unit</th>'
    h += '<th class="num" data-w="0">Current</th>' + band_head() + '<th class="trend">Trend</th>'
    for k in range(1, w.weeks_back + 1):
        h += '<th class="num" data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + '</th>'
    return h + '</tr></thead>'


def spark_vals(vals) -> str:
    """LISTAGG ... ORDER BY week_offset DESC (oldest -> current)."""
    return csv_num6(list(reversed(vals)))


def baseline(vals):
    """AVG / STDDEV / COUNT over the prior (valid) windows."""
    return mean_sd(vals[1:])


def cur_cell(vals) -> str:
    cur = vals[0]
    present = [v for v in vals if v is not None]
    row_max = max(present) if present else 0
    if row_max > 0 and cur is not None:
        pct = min(100, abs(cur) / row_max * 100)
    else:
        pct = 0
    return ('<td class="num cell-bar" data-w="0"' + fmt_num_title(cur) + '>'
            + '<span class="bg" style="width:' + to_char_fixed(pct, 1) + '%"></span>'
            + '<span class="v"><b>' + fmt_num(cur) + '</b></span></td>')


def prior_cells(vals) -> str:
    out = ''
    for k in range(1, len(vals)):
        v = vals[k]
        if v is None:
            out += '<td class="num" data-w="' + str(k) + '">&mdash;</td>'
        else:
            # TO_NUMBER(nth_csv(week_vals, k+1)): the 6-decimal round-trip
            v = float(num6(v))
            out += '<td class="num" data-w="' + str(k) + '">' + fmt_num(v) + '</td>'
    return out


def row_cells(vals, title, bucket_fn=None, plain="N") -> str:
    """Current | band cells | trend | prior windows.  bucket_fn(cur, mu, sd, n)
    -> policy bucket (None = unscored, section 13)."""
    mu, sd, n = baseline(vals)
    bucket = bucket_fn(vals[0], mu, sd, n) if bucket_fn else None
    return (cur_cell(vals)
            + band_cells(vals[0], mu, sd, n, bucket, "N", "", plain)
            + '<td class="trend" data-spark="' + spark_vals(vals)
            + '" data-spark-title="' + esc(title) + '"></td>'
            + prior_cells(vals))
