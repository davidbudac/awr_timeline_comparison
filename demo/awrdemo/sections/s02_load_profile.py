"""Twin of sql/02_load_profile.sql: DBA_HIST_SYSSTAT per-second pivot
over the comprehensive template's sysstat_load_targets.sql."""
from __future__ import annotations

from awrdemo.helpers import esc, is_essential, anchor_id
from awrdemo.sections._pivot import header, spark_vals, value_cells

# sql/lib/templates/comprehensive/sysstat_load_targets.sql (27 stats)
TARGETS = [
    'redo size', 'redo size for lost write detection', 'DB time', 'DB CPU',
    'CPU used by this session', 'session logical reads', 'physical reads',
    'physical read total bytes', 'physical writes', 'physical write total bytes',
    'user calls', 'user commits', 'user rollbacks', 'execute count',
    'parse count (total)', 'parse count (hard)', 'parse count (failures)',
    'sorts (memory)', 'sorts (disk)', 'sorts (rows)', 'logons cumulative',
    'opened cursors cumulative', 'redo writes', 'table scans (long tables)',
    'table fetch by rowid', 'bytes sent via SQL*Net to client',
    'bytes received via SQL*Net from client',
]

_ORDER = {
    'DB time': 1, 'DB CPU': 2, 'redo size': 3, 'session logical reads': 4,
    'physical reads': 5, 'physical read total bytes': 6, 'physical writes': 7,
    'physical write total bytes': 8, 'user calls': 9, 'execute count': 10,
    'user commits': 11, 'user rollbacks': 12, 'parse count (total)': 13,
    'parse count (hard)': 14, 'parse count (failures)': 15, 'logons cumulative': 16,
    'opened cursors cumulative': 17, 'redo writes': 18, 'sorts (memory)': 19,
    'sorts (disk)': 20, 'sorts (rows)': 21, 'table scans (long tables)': 22,
    'table fetch by rowid': 23,
}

_BYTES = {'redo size', 'physical read total bytes', 'physical write total bytes',
          'bytes sent via SQL*Net to client', 'bytes received via SQL*Net from client'}
_CS = {'DB time', 'DB CPU', 'CPU used by this session'}


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 02_load_profile BEGIN -->']
    out.append('<section id="load"><h2>Load profile &mdash; per-second rates</h2>')
    out.append('<p style="font-size:12px;color:var(--muted)">'
               'DBA_HIST_SYSSTAT (end &minus; begin) &divide; window seconds. '
               '<b>Trend</b>: per-window values, oldest &rarr; current. '
               '<b>Current</b> cell bar = value &divide; row max.</p>')
    out.append('<table id="load-profile">' + header(w, True) + '<tbody>')

    for stat in sorted(TARGETS, key=lambda s: (_ORDER.get(s, 99), s)):
        vals = w.window_series(lambda m, s=stat: (m.load.get(s, 0.0) / m.dur_sec)
                               if m.dur_sec > 0 else None)
        label = stat
        unit = 'bytes/s' if stat in _BYTES else ('cs/s' if stat in _CS else '/s')
        row = ('<tr id="' + anchor_id('load', stat) + '" data-imp="' + is_essential('LOAD', stat)
               + '"><td>' + esc(label) + '</td>'
               + '<td' + (' title="centiseconds per second (1/100 s of DB time per elapsed second)"'
                          if unit == 'cs/s' else '') + '>' + unit + '</td>'
               + '<td class="trend" data-spark="' + spark_vals(vals)
               + '" data-spark-title="' + esc(label) + '"></td>'
               + value_cells(vals) + '</tr>')
        out.append(row)

    out.append('</tbody></table></section>')
    out.append('<!-- AWR-SECTION: 02_load_profile END -->')
    return "\n".join(out)
