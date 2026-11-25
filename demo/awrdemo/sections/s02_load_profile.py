"""Twin of sql/02_load_profile.sql: DBA_HIST_SYSSTAT per-second pivot
over the comprehensive template's sysstat_load_targets.sql, then (plan
043) the time model table and the DB time card's time model row."""
from __future__ import annotations

import math

from awrdemo.helpers import (esc, is_essential, anchor_id, lib_ls, policy_bucket, load_total,
                             band_cells, band_head, band_span, band_z, delta_span, ent, fmt_num,
                             fmt_num_title, fv, mean_sd, nbu, num6, ora_round, to_char_fixed)
from awrdemo.model import q10
from awrdemo.sections._pivot import header, row_cells, spark_vals, prior_cells

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
    out.append('<section id="load" class="vw in-s in-a lib" style="--os:7"><h2>Load profile'
               '<small class="h2sub">System statistics per second, Current against its normal range</small></h2>')
    out.append('<table id="load-profile">' + header(w, True) + '<tbody>')

    for stat in sorted(TARGETS, key=lambda s: (_ORDER.get(s, 99), s)):
        vals = w.window_series(lambda m, s=stat: ((load_total(m, s) or 0.0) / m.dur_sec)
                               if m.dur_sec > 0 else None)
        label = stat
        unit = 'bytes/s' if stat in _BYTES else ('cs/s' if stat in _CS else '/s')
        row = ('<tr id="' + anchor_id('load', stat) + '" data-imp="' + is_essential('LOAD', stat)
               + '"><td>' + esc(label) + '</td>'
               + '<td' + (' title="centiseconds per second (1/100 s of DB time per elapsed second)"'
                          if unit == 'cs/s' else '') + '>' + unit + '</td>'
               + row_cells(vals, label,
                           lambda c, mu, sd, n, s=stat: policy_bucket('LOAD', s, None, c, mu, sd, n))
               + '</tr>')
        out.append(row)

    out.append('</tbody></table>')
    ls = _time_model(w, out)
    out.append(lib_ls('load', str(len(TARGETS)) + ' counters per second' + ls) + '</section>')
    out.append('<!-- AWR-SECTION: 02_load_profile END -->')
    return "\n".join(out)


# ---------------------------------------------------------------------
# plan 043: the time model.  The SQL's tm_targets, in tree order:
# (ord, lvl, name, parent, fg, card word)
# ---------------------------------------------------------------------
TM = [
    (1, 1, 'DB time', None, 'F', 'DB time'),
    (2, 2, 'DB CPU', 'DB time', 'F', 'CPU'),
    (3, 2, 'sql execute elapsed time', 'DB time', 'F', 'SQL'),
    (4, 2, 'parse time elapsed', 'DB time', 'F', 'Parse'),
    (5, 3, 'hard parse elapsed time', 'parse time elapsed', 'F', 'Parse'),
    (6, 4, 'hard parse (sharing criteria) elapsed time', 'hard parse elapsed time', 'F', 'Parse'),
    (7, 5, 'hard parse (bind mismatch) elapsed time', 'hard parse (sharing criteria) elapsed time', 'F', 'Parse'),
    (8, 3, 'failed parse elapsed time', 'parse time elapsed', 'F', 'Parse'),
    (9, 4, 'failed parse (out of shared memory) elapsed time', 'failed parse elapsed time', 'F', 'Parse'),
    (10, 2, 'PL/SQL execution elapsed time', 'DB time', 'F', 'PL/SQL'),
    (11, 2, 'PL/SQL compilation elapsed time', 'DB time', 'F', 'PL/SQL'),
    (12, 2, 'inbound PL/SQL rpc elapsed time', 'DB time', 'F', 'PL/SQL'),
    (13, 2, 'Java execution elapsed time', 'DB time', 'F', 'Java'),
    (14, 2, 'connection management call elapsed time', 'DB time', 'F', 'Connection'),
    (15, 2, 'sequence load elapsed time', 'DB time', 'F', 'Sequence'),
    (16, 2, 'repeated bind elapsed time', 'DB time', 'F', 'Bind'),
    (17, 1, 'background elapsed time', None, 'B', 'Background'),
    (18, 2, 'background cpu time', 'background elapsed time', 'B', 'Background'),
    (19, 3, 'RMAN cpu time (backup/restore)', 'background cpu time', 'B', 'Background'),
]


def _tm_window(w, m) -> dict:
    """The window's time model, microseconds.  The model carries only DB
    time, DB CPU and the two background rows; the rest is derived here,
    consistent with the tree (a child never exceeds its parent): hard parse
    time from the hard parse count (plus the extra time the model spends in
    Release 4.0's hard-parse storm), connection management from the
    logons, SQL execution = the statements' elapsed time plus most of the
    model's unattributed rest, PL/SQL a share of that rest.  Java, inbound
    RPC, out-of-shared-memory parses and RMAN are zero (the demo has none),
    so the table leaves them out.  Noise from w.rng only, through q10."""
    r = w.rng("timemodel", m.ts)

    def nz(sd):
        return max(0.5, 1.0 + q10(r.gauss(0, sd)))

    tm, ld, e = m.time_model, m.load, m.effects
    dbt = tm["DB time"]
    sql_ela = math.fsum(x.elapsed_us for x in m.sql.values())
    extra = 3e9 * m.intensity * (e.hard_parse - 1) / 14 if e.hard_parse > 1 else 0.0
    rest = max(0.0, dbt - sql_ela - extra)
    hard = ld["parse count (hard)"]
    hp = hard * 6200.0 * nz(0.06) + extra * 0.9          # about 6 ms a hard parse
    sharing = hp * 0.21 * nz(0.08)
    bindmm = sharing * 0.34 * nz(0.1)
    fp = ld["parse count (failures)"] * 4100.0 * nz(0.1)
    soft = max(0.0, ld["parse count (total)"] - hard) * 105.0 * nz(0.05)
    sqlx = min(dbt, sql_ela + rest * 0.55 * nz(0.03))
    return {
        'DB time': dbt,
        'DB CPU': tm["DB CPU"],
        'sql execute elapsed time': sqlx,
        'parse time elapsed': min(dbt, hp + fp + soft),
        'hard parse elapsed time': hp,
        'hard parse (sharing criteria) elapsed time': sharing,
        'hard parse (bind mismatch) elapsed time': bindmm,
        'failed parse elapsed time': fp,
        'failed parse (out of shared memory) elapsed time': 0.0,
        'PL/SQL execution elapsed time': rest * 0.16 * nz(0.05),
        'PL/SQL compilation elapsed time': hard * 900.0 * nz(0.1),
        'inbound PL/SQL rpc elapsed time': 0.0,
        'Java execution elapsed time': 0.0,
        'connection management call elapsed time': ld["logons cumulative"] * 21000.0 * nz(0.06),
        'sequence load elapsed time': ld["user commits"] * 18.0 * nz(0.1),
        'repeated bind elapsed time': ld["execute count"] * 3.2 * nz(0.05),
        'background elapsed time': tm["background elapsed time"],
        'background cpu time': min(tm["background cpu time"], tm["background elapsed time"]),
        'RMAN cpu time (backup/restore)': 0.0,
    }


def _tm_pct(cur, dbt_cur, fg) -> str:
    if fg == 'B':
        return '<td class="num tm-pct" title="background time is outside DB time">&mdash;</td>'
    if cur is None or dbt_cur is None or dbt_cur <= 0:
        return '<td class="num tm-pct">&mdash;</td>'
    p = cur / dbt_cur * 100
    if p == 0:
        t = '0%'
    elif p < 0.05:
        t = '&lt;0.1%'
    else:
        t = to_char_fixed(ora_round(p, 1), 1) + '%'
    return '<td class="num tm-pct">' + t + '</td>'


def tm_rows(w) -> list:
    """Every time model row (the SQL's fetch loop), tree order."""
    cache = {}

    def series(name):
        def f(m):
            if m.ts not in cache:
                cache[m.ts] = _tm_window(w, m)
            return cache[m.ts][name] / 1e6 / m.dur_sec if m.dur_sec > 0 else None
        return w.window_series(f)

    rows = []
    for ord_, lvl, nm, par, fg, wd in TM:
        vals = series(nm)
        mu, sd, n = mean_sd(vals[1:])
        present = [x for x in vals if x is not None]
        rows.append(dict(ord=ord_, lvl=lvl, nm=nm, par=par, fg=fg, wd=wd, vals=vals, cur=vals[0],
                         mu=mu, sd=sd, n=n, found=len(present),
                         amax=max(abs(x) for x in present) if present else None))
    return rows


def _time_model(w, out) -> str:
    """The second table of section 02 and the card row source; returns the
    library row's clause ('' when no row qualifies)."""
    rows = tm_rows(w)
    dbt = rows[0]
    rise = dbt['cur'] - dbt['mu'] if dbt['cur'] is not None and dbt['mu'] is not None else None

    def tm_rise(x):
        if (x['fg'] != 'F' or x['lvl'] < 2 or x['nm'].lower() in ('db cpu', 'sql execute elapsed time')
                or x['cur'] is None or x['mu'] is None):
            return None
        return x['cur'] - x['mu']

    def tm_ok(x):
        v = tm_rise(x)
        return v is not None and rise is not None and rise > 0 and v >= 0.01 and v >= 0.05 * rise

    # the largest rise (ties: the deeper row); then, wording only, the child
    # that carries at least 80% of it and meets the rule too
    pick, best = None, None
    for x in rows:
        if tm_ok(x) and (pick is None or tm_rise(x) > best
                         or (tm_rise(x) == best and x['lvl'] > pick['lvl'])):
            pick, best = x, tm_rise(x)
    while pick is not None:
        ch, chr_ = None, None
        for x in rows:
            if (x['par'] == pick['nm'] and tm_ok(x) and tm_rise(x) >= 0.8 * tm_rise(pick)
                    and (chr_ is None or tm_rise(x) > chr_)):
                ch, chr_ = x, tm_rise(x)
        if ch is None:
            break
        pick = ch

    out.append('<h3 id="load-tm-h">Time model: what the sessions were doing</h3>')
    if dbt['found'] == 0:
        out.append('<p class="note tm-none">No time model rows (<code>DBA_HIST_SYS_TIME_MODEL</code>) for the compared windows.</p>')
        return ''
    out.append('<p class="note tm-intro">Where DB time went by activity, from the time model'
               ' (<code>DBA_HIST_SYS_TIME_MODEL</code>), in average active sessions. The rows <b>overlap</b>:'
               ' an indented row is part of the row above it, and the rows under DB time neither add up to it'
               ' nor exclude each other, so never add them up. Background rows are outside DB time. Not scored.</p>')
    hdr = ('<thead><tr><th>Statistic</th><th class="num" data-w="0">Current (AAS)</th>'
           '<th class="num" title="Current, as a share of the Current window&#39;s DB time; the rows overlap, so the shares never add up to 100%">% of DB time</th>'
           + band_head() + '<th class="trend">Trend</th>')
    for k in range(1, w.weeks_back + 1):
        hdr += '<th class="num" data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + '</th>'
    hdr += '</tr></thead>'
    out.append('<table id="load-time-model" class="tm-tbl" data-nocount data-nosort>' + hdr + '<tbody>')
    zero, miss, bg1 = [], [], True
    for x in rows:
        if x['found'] == 0:
            miss.append('<code>' + esc(x['nm']) + '</code>')
            continue
        if not x['amax']:
            zero.append('<code>' + esc(x['nm']) + '</code>')
            continue
        cls = 'tm-l' + str(x['lvl'])
        if x['fg'] == 'B':
            cls += ' tm-bg' + (' tm-bg1' if bg1 else '')
            bg1 = False
        out.append('<tr id="' + anchor_id('tm', x['nm']) + '" class="' + cls + '" data-lvl="' + str(x['lvl'])
                   + '" data-fg="' + x['fg'] + '"'
                   + (' data-par="' + anchor_id('tm', x['par']) + '"' if x['par'] else '')
                   + ' data-cur="' + num6(x['cur']) + '" data-mu="' + num6(x['mu']) + '">'
                   + '<td><span class="tm-n">' + esc(x['nm']) + '</span></td>'
                   + '<td class="num" data-w="0"' + fmt_num_title(x['cur']) + '><b>' + fmt_num(x['cur']) + '</b></td>'
                   + _tm_pct(x['cur'], dbt['cur'], x['fg'])
                   + band_cells(x['cur'], x['mu'], x['sd'], x['n'], None, 'N', '', 'Y')
                   + '<td class="trend" data-spark="' + spark_vals(x['vals']) + '" data-spark-title="'
                   + esc(x['nm']) + ' (AAS)"></td>'
                   + prior_cells(x['vals']) + '</tr>')
    out.append('</tbody></table>')
    if zero or miss:
        t = ''
        if zero:
            t += 'Not shown, zero in every window: ' + ', '.join(zero) + '.'
        if zero and miss:
            t += ' '
        if miss:
            t += ('Not found in <code>DBA_HIST_SYS_TIME_MODEL</code> for the compared windows: '
                  + ', '.join(miss) + '.')
        out.append('<p class="note tm-drop">' + t + '</p>')
    if pick is None:
        return ''
    shr = ora_round(tm_rise(pick) / rise * 100, 0)
    st = ('more than the whole DB-time rise' if shr > 100 else 'under 1% of the DB-time rise' if shr < 1
          else str(int(shr)) + '% of the DB-time rise')
    out.append('<div id="tm-ev-src" hidden><div class="evr ev-tm" data-tm="' + anchor_id('tm', pick['nm'])
               + '" data-cur="' + num6(pick['cur']) + '" data-mu="' + num6(pick['mu']) + '" data-rise="' + num6(rise)
               + '" title="Time model (DBA_HIST_SYS_TIME_MODEL): the activity whose time rose most, besides DB CPU and SQL execution.'
               ' Its time is part of DB time and overlaps the other rows of the time model. Not scored.">'
               + '<dt>' + esc(pick['wd']) + '</dt><dd><span class="id txt">'
               + ent(esc(pick['nm']), anchor_id('tm', pick['nm']), 'metric') + '</span><span class="de">'
               + nbu(fv(pick['cur'], 'AAS') + ', was ' + fv(pick['mu'], 'AAS') + '; ' + st)
               + '</span></dd><div class="m">' + delta_span(pick['cur'], pick['mu'], None, 'Y')
               + band_span(band_z(pick['cur'], pick['mu'], pick['sd']), None, 'sm', 'N', 10)
               + '<span class="ns">not scored</span></div></div></div>')
    out.append('<script>(function(){var d=document,x=d.getElementById("tm-ev-src");if(!x)return;'
               'var c=d.getElementById("f-dbtime"),dl=c?c.querySelector("dl.ev"):null;'
               'if(dl){while(x.firstChild)dl.appendChild(x.firstChild);}x.parentNode.removeChild(x);})();</script>')
    return '; time model: ' + esc(pick['nm']) + ' +' + fmt_num(tm_rise(pick)) + '&nbsp;AAS'
