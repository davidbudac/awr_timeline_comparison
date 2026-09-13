"""Twin of sql/03_sysmetric.sql: DBA_HIST_SYSMETRIC_SUMMARY per-window
AVG pivot over the comprehensive template's sysmetric_targets.sql.
Single instance, so is_additive (SUM vs AVG across instances) is a no-op."""
from __future__ import annotations

from awrdemo.helpers import esc, is_essential
from awrdemo.sections._pivot import header, spark_vals, value_cells

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


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 03_sysmetric BEGIN -->']
    out.append('<section id="metrics"><h2>System metrics (DBA_HIST_SYSMETRIC_SUMMARY)</h2>')
    out.append('<p style="font-size:12px;color:var(--muted)">'
               'AVG(sm.average) over each window. '
               'Additive metrics (rates, counters): SUM across instances per snap, then AVG; '
               'ratios &amp; latencies: AVG across instances per snap, then AVG. '
               '<b>Trend</b>: per-window values, oldest &rarr; current. '
               'Units per metric name (<code>*_Per_Sec</code> etc.).</p>')
    out.append('<table id="sysmetric">' + header(w, True) + '<tbody>')

    for name in sorted(TARGETS, key=lambda s: (_ORDER.get(s, 99), s)):
        vals = metric_series(w, name)
        unit = METRIC_UNIT.get(name, '') if any(v is not None for v in vals) else ''
        out.append('<tr data-imp="' + is_essential('METRIC', name) + '"><td>' + esc(name) + '</td>'
                   + '<td>' + esc(unit) + '</td>'
                   + '<td class="trend" data-spark="' + spark_vals(vals)
                   + '" data-spark-title="' + esc(name) + '"></td>'
                   + value_cells(vals) + '</tr>')

    out.append('</tbody></table></section>')
    out.append('<!-- AWR-SECTION: 03_sysmetric END -->')
    return "\n".join(out)
