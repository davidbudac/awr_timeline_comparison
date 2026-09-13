"""Twin of sql/13_utilization.sql: template-independent usage profile
(three grouped SYSMETRIC pivots)."""
from __future__ import annotations

from awrdemo.helpers import esc
from awrdemo.sections._pivot import header, spark_vals, value_cells
from awrdemo.sections.s03_sysmetric import METRIC_UNIT, metric_series

# (grp_ord, grp_label, met_ord, metric_name, disp_label) -- inline in the SQL
TARGETS = [
    (1, 'Transactions and SQL activity', 1, 'User Transaction Per Sec', 'Transactions / s'),
    (1, 'Transactions and SQL activity', 2, 'User Commits Per Sec', 'Commits / s'),
    (1, 'Transactions and SQL activity', 3, 'User Rollbacks Per Sec', 'Rollbacks / s'),
    (1, 'Transactions and SQL activity', 4, 'Executions Per Sec', 'SQL executions / s'),
    (1, 'Transactions and SQL activity', 5, 'User Calls Per Sec', 'User calls / s'),
    (1, 'Transactions and SQL activity', 6, 'Total Parse Count Per Sec', 'Parses (total) / s'),
    (1, 'Transactions and SQL activity', 7, 'Open Cursors Per Sec', 'Cursors opened / s'),
    (2, 'Connections and sessions', 1, 'Logons Per Sec', 'Logons / s'),
    (2, 'Connections and sessions', 2, 'Session Count', 'Sessions'),
    (2, 'Connections and sessions', 3, 'Current Logons Count', 'Logged-on users'),
    (2, 'Connections and sessions', 4, 'Current Open Cursors Count', 'Open cursors'),
    (3, 'Data and network volume', 1, 'Logical Reads Per Sec', 'Logical reads / s'),
    (3, 'Data and network volume', 2, 'Physical Reads Per Sec', 'Physical reads / s'),
    (3, 'Data and network volume', 3, 'Physical Writes Per Sec', 'Physical writes / s'),
    (3, 'Data and network volume', 4, 'DB Block Changes Per Sec', 'Block changes / s'),
    (3, 'Data and network volume', 5, 'Redo Generated Per Sec', 'Redo bytes / s'),
    (3, 'Data and network volume', 6, 'I/O Megabytes per Second', 'I/O MB / s'),
    (3, 'Data and network volume', 7, 'Network Traffic Volume Per Sec', 'Network bytes / s'),
]

_TABLE_ID = {1: 'transactions', 2: 'connections', 3: 'data'}


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 13_utilization BEGIN -->']
    out.append('<section id="utilization"><h2>Database utilization '
               '&mdash; how the applications use this DB</h2>')
    out.append('<p style="font-size:12px;color:var(--muted)">'
               'Workload volume and shape only &mdash; transaction, call and logon rates, '
               'session counts, data and network volume (DBA_HIST_SYSMETRIC_SUMMARY, '
               'AVG over each window). This is a <b>usage</b> overview, not a health check: '
               'movement here usually reflects application behaviour (releases, batch '
               'schedules, user load), not database trouble. '
               '<b>Trend</b>: per-window values, oldest &rarr; current.</p>')
    hdr = header(w, True)

    last_grp = -1
    for grp_ord, grp_label, met_ord, name, disp in sorted(TARGETS, key=lambda t: (t[0], t[2])):
        if grp_ord != last_grp:
            if last_grp != -1:
                out.append('</tbody></table>')
            out.append('<h3>' + esc(grp_label) + '</h3>')
            out.append('<table id="util-' + _TABLE_ID.get(grp_ord, 'other' + str(grp_ord))
                       + '">' + hdr + '<tbody>')
            last_grp = grp_ord
        vals = metric_series(w, name)
        unit = METRIC_UNIT.get(name, '') if any(v is not None for v in vals) else ''
        out.append('<tr><td><span title="' + esc(name) + '">' + esc(disp) + '</span></td>'
                   + '<td>' + esc(unit) + '</td>'
                   + '<td class="trend" data-spark="' + spark_vals(vals)
                   + '" data-spark-title="' + esc(disp) + '"></td>'
                   + value_cells(vals) + '</tr>')

    if last_grp != -1:
        out.append('</tbody></table>')
    out.append('</section>')
    out.append('<!-- AWR-SECTION: 13_utilization END -->')
    return "\n".join(out)
