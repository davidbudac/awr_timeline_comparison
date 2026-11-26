"""Twin of sql/03_sysmetric.sql: DBA_HIST_SYSMETRIC_SUMMARY per-window
AVG pivot over the comprehensive template's sysmetric_targets.sql.
Single instance, so is_additive (SUM vs AVG across instances) is a no-op.

Plan 041: the Current window's peak (the SQL's largest MAXVAL) and a plain
delta against the prior windows' peaks.  The model carries hourly averages
only, so the peak is SYNTHETIC: average x (1 + spread x (0.3 + 1.2 u)),
u uniform from the seeded w.rng (Mersenne Twister, no libm), the spread
per kind of metric, percentages capped at 100.  A peak is never below its
average (single instance: the SQL's MAXVAL is >= AVERAGE too)."""
from __future__ import annotations

import math

from awrdemo.helpers import (band_cells, delta_span, esc, fmt_num, fmt_num_title, is_essential,
                             anchor_id, lib_ls, num6, policy_bucket)
from awrdemo.sections._pivot import baseline, cur_cell, header, prior_cells, spark_vals

# sql/lib/templates/comprehensive/sysmetric_targets.sql (23 metrics)
TARGETS = [
    'Host CPU Utilization (%)', 'Database CPU Time Ratio', 'Database Wait Time Ratio',
    'Average Active Sessions', 'Average Synchronous Single-Block Read Latency',
    'Physical Reads Per Sec', 'Physical Writes Per Sec',
    'Physical Read Total IO Requests Per Sec', 'Physical Write Total IO Requests Per Sec',
    'Physical Read Total Bytes Per Sec', 'Physical Write Total Bytes Per Sec',
    'Redo Generated Per Sec', 'Logons Per Sec', 'Logical Reads Per Sec',
    'User Calls Per Sec', 'User Commits Per Sec', 'User Rollbacks Per Sec',
    'Executions Per Sec', 'Hard Parse Count Per Sec', 'Total Parse Count Per Sec',
    'Session Count', 'Network Traffic Volume Per Sec', 'SQL Service Response Time',
]

_ORDER = {
    'Average Active Sessions': 1, 'Host CPU Utilization (%)': 2,
    'Database CPU Time Ratio': 3, 'Database Wait Time Ratio': 4, 'Session Count': 5,
    'Redo Generated Per Sec': 6, 'Physical Read Total Bytes Per Sec': 7,
    'Physical Write Total Bytes Per Sec': 8, 'Physical Read Total IO Requests Per Sec': 9,
    'Physical Write Total IO Requests Per Sec': 10,
    'Average Synchronous Single-Block Read Latency': 11, 'Logical Reads Per Sec': 12,
    'Executions Per Sec': 13, 'User Calls Per Sec': 14, 'User Commits Per Sec': 15,
    'User Rollbacks Per Sec': 16, 'Hard Parse Count Per Sec': 17,
    'Total Parse Count Per Sec': 18, 'Logons Per Sec': 19,
    'Network Traffic Volume Per Sec': 20, 'SQL Service Response Time': 21,
}

# DBA_HIST_SYSMETRIC_SUMMARY.metric_unit as Oracle 19c reports it (the
# model carries values only, so the unit column is derived here).
METRIC_UNIT = {
    'Host CPU Utilization (%)': '% Busy/(Idle+Busy)',
    'Database CPU Time Ratio': '% Cpu/DB_Time',
    'Database Wait Time Ratio': '% Wait/DB_Time',
    'Average Active Sessions': 'Sessions',
    'Average Synchronous Single-Block Read Latency': 'Milliseconds',
    'Physical Reads Per Sec': 'Reads Per Second',
    'Physical Writes Per Sec': 'Writes Per Second',
    'Physical Read Total IO Requests Per Sec': 'Requests Per Second',
    'Physical Write Total IO Requests Per Sec': 'Requests Per Second',
    'Physical Read Total Bytes Per Sec': 'Bytes Per Second',
    'Physical Write Total Bytes Per Sec': 'Bytes Per Second',
    'Redo Generated Per Sec': 'Bytes Per Second',
    'Logons Per Sec': 'Logons Per Second',
    'Logical Reads Per Sec': 'Reads Per Second',
    'User Calls Per Sec': 'Calls Per Second',
    'User Commits Per Sec': 'Commits Per Second',
    'User Rollbacks Per Sec': 'Rollbacks Per Second',
    'Executions Per Sec': 'Executes Per Second',
    'Hard Parse Count Per Sec': 'Parses Per Second',
    'Total Parse Count Per Sec': 'Parses Per Second',
    'Session Count': 'Sessions',
    'Network Traffic Volume Per Sec': 'Bytes Per Second',
    'SQL Service Response Time': 'CentiSeconds Per Call',
    # section 13's extra names
    'User Transaction Per Sec': 'Transactions Per Second',
    'Open Cursors Per Sec': 'Cursors Per Second',
    'Current Logons Count': 'Logons',
    'Current Open Cursors Count': 'Cursors',
    'DB Block Changes Per Sec': 'Blocks Per Second',
    'I/O Megabytes per Second': 'Megabtyes per Second',
}


def metric_series(w, name):
    return w.window_series(lambda m: m.sysmetric.get(name))


# plan 041: how far above its hourly average a metric's busiest minute goes
_PEAK_SPREAD = {
    'Average Active Sessions': 1.2,   # near 09's (ASH) busiest minutes
    'Session Count': 0.04, 'Host CPU Utilization (%)': 0.25,
    'Database CPU Time Ratio': 0.12, 'Database Wait Time Ratio': 0.30,
    'Average Synchronous Single-Block Read Latency': 0.9,
    'SQL Service Response Time': 0.8, 'Logons Per Sec': 1.2,
    'User Rollbacks Per Sec': 1.0, 'Hard Parse Count Per Sec': 1.0,
}
_PCT = ('Host CPU Utilization (%)', 'Database CPU Time Ratio', 'Database Wait Time Ratio')


def peak_series(w, name, vals):
    """the synthetic per-window peak (None where the window has no value)"""
    out = []
    for k, v in enumerate(vals):
        if v is None:
            out.append(None)
            continue
        u = w.rng("sm-peak", name, k).random()
        p = v * (1 + _PEAK_SPREAD.get(name, 0.45) * (0.3 + 1.2 * u))
        if name in _PCT:
            p = min(100.0, max(p, v))
        out.append(p)
    return out


def peak_cells(cur_peak, priors) -> str:
    """the SQL's two plan-041 cells: Peak (1 min) | vs prior peaks"""
    pp = [p for p in priors if p is not None]
    mu = math.fsum(pp) / len(pp) if pp else None
    if cur_peak is None:
        out = '<td class="num pk">&mdash;</td>'
    else:
        out = ('<td class="num pk" data-pk="' + num6(cur_peak) + '"' + fmt_num_title(cur_peak) + '>'
               + fmt_num(cur_peak) + '</td>')
    return (out + '<td class="num pkd" title="mean of ' + str(len(pp)) + ' prior window'
            + ('' if len(pp) == 1 else 's') + '&#39; peaks: ' + ('none' if mu is None else fmt_num(mu))
            + '">' + delta_span(cur_peak, mu, None, "Y") + '</td>')


_PK_TH = ('Largest one-minute value inside the Current window: the highest MAXVAL of '
          'DBA_HIST_SYSMETRIC_SUMMARY (60-second metric intervals) over the window&#39;s snapshots; '
          'with several instances the largest single-instance value. Not scored.')


def header03(w) -> str:
    """_pivot.header plus the two peak columns after the band cells"""
    h = header(w, True)
    i = h.index('<th class="trend">')
    return (h[:i] + '<th class="num pk" title="' + _PK_TH + '">Peak (1 min)</th>'
            '<th class="num pkd" title="Current peak against the mean of the valid prior windows&#39; '
            'own peaks; a plain ratio, not scored">vs prior peaks</th>' + h[i:])


def _row_cells(w, name, vals) -> str:
    """_pivot.row_cells with the plan-041 peak cells after the band cells"""
    mu, sd, n = baseline(vals)
    bucket = policy_bucket('METRIC', name, None, vals[0], mu, sd, n)
    pk = peak_series(w, name, vals)
    return (cur_cell(vals)
            + band_cells(vals[0], mu, sd, n, bucket, "N", "", "N")
            + peak_cells(pk[0], pk[1:])
            + '<td class="trend" data-spark="' + spark_vals(vals)
            + '" data-spark-title="' + esc(name) + '"></td>'
            + prior_cells(vals))


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 03_sysmetric BEGIN -->']
    out.append('<section id="metrics" class="vw in-s in-a lib" style="--os:8"><h2>System metrics'
               '<small class="h2sub">SYSMETRIC averages per window, Current against its normal range</small></h2>')
    out.append('<table id="sysmetric">' + header03(w) + '<tbody>')

    for name in sorted(TARGETS, key=lambda s: (_ORDER.get(s, 99), s)):
        vals = metric_series(w, name)
        unit = METRIC_UNIT.get(name, '') if any(v is not None for v in vals) else ''
        out.append('<tr id="' + anchor_id('metric', name) + '" data-imp="' + is_essential('METRIC', name)
                   + '"><td>' + esc(name) + '</td>'
                   + '<td>' + esc(unit) + '</td>'
                   + _row_cells(w, name, vals)
                   + '</tr>')

    out.append('</tbody></table>')
    host = metric_series(w, 'Host CPU Utilization (%)')[0] if 'Host CPU Utilization (%)' in TARGETS else None
    out.append(lib_ls('metrics', str(len(TARGETS)) + ' metric' + ('' if len(TARGETS) == 1 else 's')
                      + ('; host CPU <b>' + fmt_num(host) + '%</b>' if host is not None else ''))
               + '</section>')
    out.append('<!-- AWR-SECTION: 03_sysmetric END -->')
    return "\n".join(out)
