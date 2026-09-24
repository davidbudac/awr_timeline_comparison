#!/usr/bin/env python3
"""Mock C generator: 'Aligned window grid'. Emits static markup + data-attributes
(the shape a PL/SQL emitter would produce) plus one inline CSS and one inline JS."""
import json, re, html, os

S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = json.load(open(os.path.join(S, 'demo_series.json')))
T = json.load(open(os.path.join(S, 'c_build', 'tables.json')))
OUT = '/Users/davidbudac/claude_projects/awr_timeline_comparison/design/report_mock_c_window_grid.html'
HERE = os.path.dirname(os.path.abspath(__file__))

WL = D['windowsWeekLabels']                      # 'Jun 18' ... 'Sep 10'
OFF = ['−%dw' % (12 - k) for k in range(12)] + ['Current']
WIN_FULL = []
for w in D['ashPerWindow']['windows']:
    import datetime as dt
    t = dt.datetime.strptime(w['start'], '%Y-%m-%d %H:%M')
    WIN_FULL.append(t.strftime('%a %-d %b, 09:00–10:00'))
N = 13
CUR = 12

esc = html.escape


def sig(v):
    s = '%.4g' % v
    if 'e' in s:
        s = '%.2f' % v
    return s


def fmt(v):
    if v is None:
        return '—'
    a = abs(v)
    if a >= 1e9:
        return sig(v / 1e9) + 'G'
    if a >= 1e6:
        return sig(v / 1e6) + 'M'
    if a >= 1e4:
        return sig(v / 1e3) + 'k'
    if a >= 1000:
        return '{:,.0f}'.format(v)
    return sig(v)


def num(s):
    s = s.replace('plan↑', '').strip()
    m = re.match(r'^([−-]?[\d,]*\.?\d+)\s*([kMG])?', s)
    if not m:
        return None
    v = float(m.group(1).replace(',', '').replace('−', '-'))
    return v * {'k': 1e3, 'M': 1e6, 'G': 1e9}.get(m.group(2), 1)


def spark(s):
    return [float(x) if x != '' else None for x in s.split(',')]


def rows_of(tid):
    return T[tid][1:]


def by_name(tid, col=0):
    out = {}
    for r in rows_of(tid):
        nm = re.sub(r'\s*(twin\s*)?↗ row$', '', r['cells'][col]).strip()
        out[nm] = r
    return out


def zinfo(cells):
    """findings table row -> (sev, z float, z display, pct, immaterial, twin)"""
    sev = cells[0].lower()
    zs = cells[6]
    imm = 'immaterial' in zs
    zs = zs.replace('immaterial', '').strip()
    zd = zs
    try:
        z = 99.0 if zs.startswith('>') else float(zs.replace('−', '-'))
    except ValueError:
        z, zd = None, None
    p = cells[7]
    try:
        pv = float(re.sub(r'[^\d.]', '', p))
    except ValueError:
        pv = None
        return sev, z, zd, None, imm
    if '▼' in p:
        pv = -pv
    return sev, z, zd, pv, imm


LOAD = by_name('load-profile')
FLOAD = by_name('findings-load', 1)
SYSM = by_name('sysmetric')
FMET = by_name('findings-metric', 1)
WFG = by_name('waits-fg-time')

GL = {'large': '●', 'moderate': '◐', 'typical': '○', 'improved': '▽', 'noted': '◇', 'flat baseline': '–'}
SEVC = {'flat baseline': 'skip'}


def delta_txt(pct):
    if pct is None:
        return ''
    up = pct >= 0
    ar = '▲' if up else '▼'
    if pct >= 100:
        r = 1 + pct / 100.0
        return '%s ×%s' % (ar, ('%.1f' % r) if r < 100 else '%.0f' % r)
    return '%s %s%.1f%%' % (ar, '+' if up else '−', abs(pct))


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def csv(vals, nd=6):
    return ','.join('' if v is None else ('%.*g' % (nd + 3, v)) for v in vals)


# --------------------------------------------------------------- row emitters
def cell_open(k, extra_cls=''):
    cls = 'c' + (' cur' if k == CUR else '') + extra_cls
    return '<div class="%s" data-w="%d" role="cell">' % (cls, k)


def bar_row(rid, name, sub, unit, vals, sev=None, zd=None, pct=None, imm=False,
            cls='m', swatch=None, glyphs=None, d1=None, d2=None, title=None, rtitle=None):
    glyphs = glyphs or {}
    attrs = ' data-v="%s" data-name="%s" data-unit="%s"' % (csv(vals), esc(name), esc(unit))
    if sev:
        attrs += ' data-sev="%s"' % SEVC.get(sev, sev)
    rid_attr = ' id="%s"' % rid if rid else ''
    h = ['<div class="r %s"%s%s role="row">' % (cls, rid_attr, attrs)]
    sw = '<i class="sw" style="--sw:%s" aria-hidden="true"></i>' % swatch if swatch else ''
    tt = ' title="%s"' % esc(title) if title else ''
    h.append('<div class="l" role="rowheader"%s><span class="nm">%s%s</span>%s</div>' % (
        tt, sw, esc(name), ('<span class="sub">%s</span>' % sub) if sub else ''))
    for k, v in enumerate(vals):
        inner = '<span class="v">%s</span>' % fmt(v) if v is not None else '<span class="v nil" aria-label="not present">–</span>'
        if k in glyphs:
            inner += glyphs[k]
        h.append(cell_open(k) + inner + '</div>')
    # gutter
    if d1 is None:
        d1 = delta_txt(pct)
    if d2 is None and sev:
        d2 = '<i class="sv %s" aria-hidden="true">%s</i><span class="svw">%s</span>' % (SEVC.get(sev, sev), GL[sev], {'flat baseline': 'flat'}.get(sev, sev))
        if zd and sev != 'typical':
            d2 += '<span class="z">z %s</span>' % zd
    gt = ''
    if sev and zd:
        gt = 'z %s%s' % (zd, ', below the materiality floor' if imm else '')
    if rtitle:
        gt = rtitle
    h.append('<div class="g" role="cell"%s><span class="d1">%s</span><span class="d2">%s</span></div>' % (
        (' title="%s"' % esc(gt)) if gt else '', d1, d2 or ''))
    h.append('</div>')
    return ''.join(h)


def lane_head(lid, title, count, cap, gut='', closed=False, full_only=False):
    cls = 'r gh'
    h = ['<div class="%s" role="row">' % cls]
    h.append('<div class="l" role="rowheader"><button class="lt" aria-expanded="%s" aria-controls="%s" data-lane="%s">'
             '<i class="car" aria-hidden="true"></i><span class="lti">%s</span><span class="lc">%s</span></button></div>' % (
                 'false' if closed else 'true', lid, lid, esc(title), esc(count)))
    for k in range(N):
        h.append(cell_open(k) + '</div>')
    h.append('<div class="g" role="cell"><span class="gs">%s</span></div>' % gut)
    h.append('<div class="cap">%s</div>' % cap)
    h.append('</div>')
    return ''.join(h)


def lane(lid, title, count, cap, rows, gut='', closed=False, full_only=False):
    cls = 'lane' + (' closed' if closed else '') + (' full-only' if full_only else '')
    return '<div class="%s" id="%s" role="rowgroup">%s<div class="lrows">%s</div></div>' % (
        cls, lid, lane_head(lid, title, count, cap, gut, closed), ''.join(rows))


def note_row(text, cls='nr'):
    h = ['<div class="r %s" role="row"><div class="l" role="rowheader"></div>' % cls]
    for k in range(N):
        h.append(cell_open(k) + '</div>')
    h.append('<div class="g" role="cell"></div><div class="cap">%s</div></div>' % text)
    return ''.join(h)


# --------------------------------------------------------------- ACTIVITY lane
WC = {'CPU': '#3FB344', 'User I/O': '#4A90D9', 'System I/O': '#1F4E89', 'Commit': '#E89B40',
      'Application': '#D62728', 'Concurrency': '#8B0000', 'Network': '#967259',
      'Configuration': '#793C32', 'Other': '#C77CB0', 'Scheduler': '#88C070',
      'Cluster': '#E5C228', 'Administrative': '#7B6FA8', 'Queueing': '#E89BB7'}
ORDER = ['CPU', 'User I/O', 'System I/O', 'Commit', 'Application', 'Concurrency', 'Network', 'Other']
apw = {c['name']: c['vals'] for c in D['ashPerWindow']['classes']}
other = [apw['Other'][k] + apw['Configuration'][k] + apw['Scheduler'][k] for k in range(N)]
ash_vals = [apw[c] if c != 'Other' else other for c in ORDER]
tot = [sum(ash_vals[i][k] for i in range(len(ORDER))) for k in range(N)]
ptot = mean(tot[:12])
uio_r = apw['User I/O'][12] / mean(apw['User I/O'][:12])
net_r = apw['Network'][12] / mean(apw['Network'][:12])
cpu_p = (apw['CPU'][12] / mean(apw['CPU'][:12]) - 1) * 100


def ash_row():
    data = {'cls': ORDER, 'col': [WC[c] for c in ORDER],
            'v': [[round(x, 3) for x in vs] for vs in ash_vals], 'max': 22, 'ticks': [10, 20]}
    h = ['<div class="r ash" id="row-ash" data-name="Active sessions (ASH)" data-ash=\'%s\' role="row">' % json.dumps(data, separators=(',', ':'))]
    leg = ''.join('<li><i class="sw" style="--sw:%s"></i>%s</li>' % (WC[c], c if c != 'Other' else 'Other*') for c in ORDER)
    h.append('<div class="l" role="rowheader"><span class="nm">Active sessions by wait class</span>'
             '<span class="sub">ASH, average over the hour</span><ul class="leg">%s</ul><span class="fn">* Other with Configuration and Scheduler</span>'
             '<span class="axn" aria-hidden="true"></span></div>' % leg)
    for k in range(N):
        h.append(cell_open(k) + '<span class="v">%s</span></div>' % fmt(tot[k]))
    h.append('<div class="g" role="cell" title="ASH average active sessions, Current vs the mean of the 12 prior windows">'
             '<span class="d1">▲ +%.0f%% total</span>'
             '<span class="d3"><i class="sw" style="--sw:%s"></i>User I/O ×%.1f</span>'
             '<span class="d3"><i class="sw" style="--sw:%s"></i>Network ×%.1f</span>'
             '<span class="d3"><i class="sw" style="--sw:%s"></i>CPU +%.0f%%</span></div>' % (
                 (tot[12] / ptot - 1) * 100, WC['User I/O'], uio_r, WC['Network'], net_r, WC['CPU'], cpu_p))
    h.append('</div>')
    return ''.join(h)


def span_row():
    """Full view: the whole week before each window (6-h ASH averages), aligned to the same columns."""
    sp = D['ashSpan6h']
    cls = {c['name']: c['vals'] for c in sp['classes']}
    n = len(sp['t'])
    totals = [sum(cls[c][i] for c in cls) for i in range(n)]
    uio = cls['User I/O']
    mx = max(totals)
    # markers: true position inside the week column
    import datetime as dt
    t0 = dt.datetime.strptime(sp['t'][0], '%Y-%m-%d %H:%M')
    mk_by_col = {}
    for m in D['markers']:
        tm = dt.datetime.strptime(m['t'], '%Y-%m-%d %H:%M')
        idx = (tm - t0).total_seconds() / (6 * 3600)
        k = int((idx - 1) // 28) + 1
        f = (idx - (28 * (k - 1) + 1)) / 27.0
        mk_by_col.setdefault(k, []).append('%.3f|%s' % (max(0, min(1, f)), m['label']))
    h = ['<div class="r span" id="row-span" data-name="The week before each window" data-max="%.2f" role="row">' % mx]
    h.append('<div class="l" role="rowheader"><span class="nm">The week before each window</span>'
             '<span class="sub">ASH, 6-h averages, window at right edge</span></div>')
    for k in range(N):
        if k == 0:
            h.append(cell_open(k) + '<span class="v nil sp0">span starts</span></div>')
            continue
        a = totals[28 * (k - 1) + 1: 28 * k + 1]
        b = uio[28 * (k - 1) + 1: 28 * k + 1]
        mk = ';'.join(mk_by_col.get(k, []))
        h.append(cell_open(k) + '<span class="v">%s</span>' % fmt(max(a)) +
                 '<svg class="sa" data-a="%s" data-b="%s"%s aria-hidden="true"></svg></div>' % (
                     ','.join('%.2f' % x for x in a), ','.join('%.2f' % x for x in b),
                     (' data-mk="%s"' % esc(mk)) if mk else ''))
    h.append('<div class="g" role="cell"><span class="d1">peak %s</span><span class="d2 mut">3 months, Full only</span></div></div>' % fmt(max(totals[-28:])))
    return ''.join(h)


# --------------------------------------------------------------- METRICS lane
def load_row(rid, stat, label, sub, unit, src='load'):
    if src == 'load':
        r = LOAD[stat]; f = FLOAD[stat]
    else:
        r = SYSM[stat]; f = FMET[stat]
    vals = spark(r['spark'])
    sev, z, zd, pct, imm = zinfo(f['cells'])
    return bar_row(rid, label, sub, unit, vals, sev, zd, pct, imm)


aas = D['headlineCards'][3]['vals']
metrics_rows = [
    load_row('row-dbtime', 'DB time', 'DB time', 'cs/s, AAS %.1f → %.1f' % (mean(aas[:12]), aas[12]), 'cs/s'),
    load_row('row-dbcpu', 'DB CPU', 'DB CPU', 'cs/s, CPU part of DB time', 'cs/s'),
    load_row('row-wtr', 'Database Wait Time Ratio', 'Wait time ratio', '% of DB time spent waiting', '%', 'm'),
    load_row('row-lreads', 'session logical reads', 'Logical reads', 'per second, session logical reads', '/s'),
    load_row('row-physreads', 'physical reads', 'Physical reads', 'per second, blocks', '/s'),
    load_row('row-prbytes', 'physical read total bytes', 'Physical read bytes', 'bytes per second', 'bytes/s'),
    load_row('row-lscans', 'table scans (long tables)', 'Long-table scans', 'per second, table scans (long tables)', '/s'),
    load_row('row-srt', 'SQL Service Response Time', 'SQL response time', 'centiseconds per call', 'cs/call', 'm'),
    load_row('row-hcpu', 'Host CPU Utilization (%)', 'Host CPU', '% busy', '%', 'm'),
    load_row('row-redo', 'redo size', 'Redo generated', 'bytes per second', 'bytes/s'),
    load_row('row-hparse', 'parse count (hard)', 'Hard parses', 'per second', '/s'),
]

# --------------------------------------------------------------- WAITS lane
EVCLS = {'db file scattered read': 'User I/O', 'direct path read': 'User I/O', 'db file sequential read': 'User I/O',
         'SQL*Net more data to client': 'Network', 'log file sync': 'Commit',
         'enq: TX - row lock contention': 'Application', 'buffer busy waits': 'Concurrency',
         'db file parallel read': 'User I/O', 'control file sequential read': 'System I/O',
         'latch: cache buffers chains': 'Concurrency', 'library cache: mutex X': 'Concurrency',
         'cursor: pin S wait on X': 'Concurrency', 'direct path read temp': 'User I/O',
         'enq: TX - index contention': 'Concurrency'}
WID = {'db file scattered read': 'row-w-scattered', 'direct path read': 'row-w-dpr',
       'SQL*Net more data to client': 'row-w-sqlnet', 'log file sync': 'row-w-lfs'}
wait_rows = []
for i, r in enumerate(rows_of('waits-fg-time')):
    c = r['cells']
    ev = c[0]
    vals = spark(r['spark'])
    sev = c[15].lower()
    zs = c[16]
    imm = 'immaterial' in zs
    zd = zs.replace('immaterial', '').strip()
    p = c[17]
    pv = float(re.sub(r'[^\d.]', '', p)) * (-1 if '▼' in p else 1)
    row = bar_row(WID.get(ev), ev, '%s, seconds waited' % EVCLS[ev], 's', vals, sev, zd, pv, imm,
                  cls='m w' + (' more' if i >= 10 else ''), swatch=WC[EVCLS[ev]])
    wait_rows.append(row)
wait_rows.insert(10, '<div class="r xp" role="row"><div class="l" role="rowheader"><button class="xpb" data-for="lane-waits" aria-expanded="false">Show 4 more events</button></div>' + ''.join(cell_open(k) + '</div>' for k in range(N)) + '<div class="g" role="cell"></div></div>')

# --------------------------------------------------------------- OBJECTS lane
obj_rows = []
seg = {r['cells'][0]: r['cells'] for r in rows_of('segio-detail-PREADS')}
fil = {r['cells'][0]: r['cells'] for r in rows_of('fileio-detail-READMB')}


def tvals(cells, start):
    cur_to_old = [num(x) if x.strip() not in ('—', '') else None for x in cells[start:start + 13]]
    return cur_to_old[::-1]


for nm, sub, rid in [('ORDERS_APP.ORDER_LINES', 'table, physical reads (blocks)', 'row-o-ol'),
                     ('ORDERS_APP.ORDER_LINES_PK', 'index, physical reads (blocks)', None)]:
    v = tvals(seg[nm], 2)
    pm = mean(v[:12])
    rk = re.search(r'#(\d+)', seg[nm][2]).group(1)
    obj_rows.append(bar_row(rid, nm, sub, 'blocks', v, d1=delta_txt((v[12] / pm - 1) * 100),
                            d2='<span class="mut">#%s by physical reads</span>' % rk, cls='m o'))
fn = 'ts_orders_data.301.1131588213'
v = tvals(fil[fn], 2)
obj_rows.append(bar_row('row-o-file', fn, 'TS_ORDERS_DATA datafile, MB read', 'MB', v,
                        d1=delta_txt((v[12] / mean(v[:12]) - 1) * 100),
                        d2='<span class="mut">#1 by MB read</span>', cls='m o'))

# --------------------------------------------------------------- SQL lane
TOP = {r['cells'][0].replace('plan↑', '').strip(): r['cells'] for r in rows_of('topsql-detail-ELAPSED')}
SCHEMA = {'7k2m9dx4qp1zb': 'ORDERS_APP', 'n7t3q5xc1yj4g': 'LOYALTY', '2yq9jv7c5hm3d': 'ORDERS_APP',
          'u9d5p3fw2hs8x': 'ORDERS_APP', 'f1p7r4mz8vb2c': 'ORDERS_APP', 't3h6u1zr9nb8w': 'ORDERS_APP'}
SQLMON_7K = [1.749645, 1.454318, 1.188314, 1.342073, 1.805734, 1.264887, 1.327481, 1.904801, 1.251031, 1.659982, 1.881540, 1.200589, 8.016030]
SQLMON_9W = [214.438652, 213.369131, 193.832114, 198.375378, 206.668241, 247.528329, 229.722407, 237.534415, 218.012881, 199.175738, 191.741678, 192.482235, 213.282163]
sql_rows = []
for sid in ['7k2m9dx4qp1zb', 'n7t3q5xc1yj4g', '2yq9jv7c5hm3d', 'u9d5p3fw2hs8x', 'f1p7r4mz8vb2c', 't3h6u1zr9nb8w']:
    c = TOP[sid]
    v = tvals(c, 2)
    txt = c[15]
    rk = re.search(r'#(\d+)', c[2]).group(1)
    pm = mean(v[:12])
    glyphs = {}
    d2 = '<span class="mut">#%s by elapsed</span>' % rk
    d1 = delta_txt((v[12] / pm - 1) * 100)
    rt = None
    if sid == '7k2m9dx4qp1zb':
        glyphs[12] = '<b class="gl pc" title="Plan changed: 3197245811 → 2088341150">◆</b>'
        d2 = '<i class="gk" aria-hidden="true">◆</i><span>plan changed</span>'
        rt = 'Plan hash 3197245811 in every prior window, 2088341150 in Current'
    if sid == 'n7t3q5xc1yj4g':
        first = next(k for k, x in enumerate(v) if x is not None)
        glyphs[first] = '<b class="gl nw" title="First seen in the Top-N: %s">✚</b>' % WL[first]
        d2 = '<i class="gk" aria-hidden="true">✚</i><span>new, %s</span>' % WL[first]
        d1 = delta_txt((v[12] / pm - 1) * 100)
        rt = 'Not in the top 10 before the %s window; first captured 2026-08-11 22:00 (Release 4.1)' % WL[first]
    short = txt if len(txt) < 90 else txt[:88] + '…'
    sql_rows.append(bar_row('row-sql-' + sid[:4], sid, '%s <span class="sq">%s</span>' % (SCHEMA[sid], esc(short)),
                            's', v, glyphs=glyphs, d1=d1, d2=d2, cls='m q', title=txt, rtitle=rt))
    if sid == '7k2m9dx4qp1zb':
        sql_rows.append(bar_row('row-sqlmon-7k2m', 'SQL Monitor, max elapsed', 'slowest captured run, s',
                                's', SQLMON_7K, 'large', '+23.41', 433.5, cls='m q sub'))
sql_rows.append(bar_row('row-sqlmon-9wz2', '9wz2ke6yq4tn1', 'REPORTING <span class="sq">SQL Monitor, slowest run</span>',
                        's', SQLMON_9W, 'typical', '+0.07', 0.6, cls='m q',
                        glyphs={12: '<b class="gl dg" title="DOP downgrade flagged on a Current-window execution">▽</b>'},
                        d2='<i class="gk" aria-hidden="true">▽</i><span>DOP downgrade</span>',
                        rtitle='Max elapsed typical (z +0.07); a Current-window execution got fewer PX servers than requested'))

# --------------------------------------------------------------- CONFIG lane
PARAMS = [
    ('row-p-cursor', 'cursor_sharing', ['EXACT'] * 3 + ['FORCE'] * 10, 'changed Jul 09', 'Hotfix 4.0.1',
     'Changed between the Jul 02 and Jul 09 windows; Hotfix 4.0.1 went in on Fri 3 Jul 09:00, in the same interval'),
    ('row-p-sga', 'sga_target', ['48 GB'] * 5 + ['64 GB'] * 8, 'changed Jul 23', 'RU 19.28 patch',
     'Changed between the Jul 16 and Jul 23 windows; the RU 19.28 patch went in on Tue 21 Jul 01:00, in the same interval'),
    ('row-p-pga', 'pga_aggregate_target', ['8 GB'] * 8 + ['12 GB'] * 5, 'changed Aug 13', 'Release 4.1',
     'Changed between the Aug 06 and Aug 13 windows; Release 4.1 went in on Tue 11 Aug 22:00, in the same interval'),
    ('row-p-adaptive', 'optimizer_adaptive_plans', ['FALSE'] * 12 + ['TRUE'], 'changed in Current', 'Release 4.2',
     'Changed between the Sep 03 window and Current; Release 4.2 went in on Tue 8 Sep 22:00, in the same interval'),
]
RAW = {'48 GB': '51539607552', '64 GB': '68719476736', '8 GB': '8589934592', '12 GB': '12884901888'}
cfg_rows = []
for rid, pname, vals, d1, mk, tt in PARAMS:
    h = ['<div class="r m p" id="%s" data-name="%s" role="row">' % (rid, pname)]
    h.append('<div class="l" role="rowheader" title="%s"><span class="nm mono">%s</span><span class="sub">value at each window’s end snapshot</span></div>' % (pname, pname))
    for k, v in enumerate(vals):
        start = k == 0 or vals[k - 1] != v
        lvl = 'lo' if v == vals[0] else 'hi'
        rise = start and k > 0
        inner = '<i class="st %s%s" aria-hidden="true"></i>' % (lvl, ' rise' if rise else '')
        if rise:
            inner += '<i class="nd %s" aria-hidden="true"></i>' % lvl
        inner += '<span class="v pv%s" data-raw="%s">%s</span>' % (' on' if start else (' cv' if k == CUR else ''), RAW.get(v, v), v)
        h.append(cell_open(k) + inner + '</div>')
    h.append('<div class="g" role="cell" title="%s"><span class="d1 cfg">%s</span><span class="d2"><i class="gk fl" aria-hidden="true"></i><span>%s</span></span></div></div>' % (esc(tt), d1, mk))
    cfg_rows.append(''.join(h))

# --------------------------------------------------------------- FULL: load profile (27)
load_full = []
for nm, r in LOAD.items():
    if nm not in FLOAD:
        continue
    vals = spark(r['spark'])
    sev, z, zd, pct, imm = zinfo(FLOAD[nm]['cells'])
    twin = 'twin' in FLOAD[nm]['cells'][1]
    unit = r['cells'][1]
    load_full.append(bar_row(None, nm, unit + (', twin' if twin else ''), unit, vals, sev, zd, pct, imm, cls='m d', title=nm))

# --------------------------------------------------------------- FULL: windows lane
win = {r['cells'][0]: r['cells'] for r in rows_of('windows-table')}
snap_cells = []
for k in range(N):
    key = OFF[k] if k < 12 else 'Current'
    c = win[key]
    snap_cells.append((c[3], c[4], c[5]))


def text_row(name, sub, texts, titles, cls='m t', gut=''):
    h = ['<div class="r %s" data-name="%s" role="row"><div class="l" role="rowheader"><span class="nm">%s</span><span class="sub">%s</span></div>' % (cls, esc(name), esc(name), sub)]
    for k in range(N):
        h.append(cell_open(k) + '<span class="v tx" title="%s">%s</span></div>' % (esc(titles[k]), texts[k]))
    h.append('<div class="g" role="cell">%s</div></div>' % gut)
    return ''.join(h)


win_rows = [
    text_row('Begin snapshot', 'end snapshot is begin + 1', [s[0] for s in snap_cells],
             ['snap %s → %s' % (s[0], s[1]) for s in snap_cells]),
    text_row('Status', 'no restart, no DBID change, edges within 15 min', ['✓' for s in snap_cells],
             ['valid' for s in snap_cells], gut='<span class="d1">13 of 13 valid</span>'),
]

STUBS = [
    ('System metrics', '23 rows', 'SYSMETRIC averages, same cell grammar as the Metrics lane'),
    ('Background waits', '11 events', 'db file parallel write, log file parallel write, … all moderate, +62.8%'),
    ('Top SQL, other rankings', '4', 'by CPU, buffer gets, physical reads and executions; one row per sql_id'),
    ('Segment and file I/O', '6', 'writes, logical reads and temp; top 10 per window'),
    ('Database utilization', '14 rows', 'transactions, calls, logons, sessions, network volume'),
    ('SQL Monitor, others', '7', 'errors and DOP downgrades without a Current-window execution'),
]
stub_lanes = []
for i, (t, cnt, cap) in enumerate(STUBS):
    stub_lanes.append(lane('lane-stub%d' % i, t, cnt, cap,
                           [note_row('Rows omitted in this mock. They use the same cell grammar: one mini column per window, the value printed in Current, the verdict in the right gutter.')],
                           closed=True, full_only=True))

# --------------------------------------------------------------- DAY PROFILE
dp = D['dayProfile']
HRS = dp['hours']


def dp_html():
    cols = len(HRS)
    h = ['<div class="dpg" role="table" aria-label="Day profile, 24 hours ending Thu 10 Sep 10:00">']
    # ruler
    h.append('<div class="dr dh" role="row"><div class="l" role="columnheader"><span class="nm">Hour starting</span>'
             '<span class="sub">Wed 9 Sep 10:00 → Thu 10 Sep 10:00</span></div>')
    for i, hr in enumerate(HRS):
        day = ''
        if i == 0:
            day = '<span class="dday">Wed 9</span>'
        if hr == '00:00':
            day = '<span class="dday">Thu 10</span>'
        cur = ' cur' if i == cols - 1 else ''
        brk = ' brk' if hr == '00:00' else ''
        h.append('<div class="dc%s%s" data-h="%d" role="columnheader">%s<span class="hh">%s</span></div>' % (cur, brk, i, day, hr[:2]))
    h.append('<div class="g" role="columnheader"><span class="d1">hours flagged</span><span class="d2 mut">vs 7 prior days</span></div></div>')
    for s in dp['stats']:
        flagged = sum(1 for x in s['sev'] if x in ('large', 'moderate'))
        large = sum(1 for x in s['sev'] if x == 'large')
        nm = s['name']
        if flagged >= 20:
            g2 = '<i class="sv large" aria-hidden="true">●</i><span class="svw">day-wide shift</span>'
        elif large:
            g2 = '<i class="sv large" aria-hidden="true">●</i><span class="svw">%d isolated h</span>' % large
        else:
            g2 = '<i class="sv typical" aria-hidden="true">○</i><span class="svw">none</span>'
        h.append('<div class="dr" data-name="%s" data-v="%s" data-mu="%s" data-sev="%s" data-z="%s" role="row">' % (
            esc(nm), csv(s['cur']), csv(s['mu']), ','.join(x[0] for x in s['sev']), ','.join('%.1f' % z for z in s['z'])))
        base = nm.split(' (')[0]
        h.append('<div class="l" role="rowheader"><span class="nm">%s</span></div>' % esc(base[0].upper() + base[1:]))
        for i, v in enumerate(s['cur']):
            cur = ' cur' if i == cols - 1 else ''
            brk = ' brk' if HRS[i] == '00:00' else ''
            h.append('<div class="dc%s%s" data-h="%d" role="cell"><span class="v">%s</span></div>' % (cur, brk, i, fmt(v)))
        h.append('<div class="g" role="cell"><span class="d1">%d of 24 h</span><span class="d2">%s</span></div></div>' % (flagged, g2))
    h.append('</div>')
    return ''.join(h)


# --------------------------------------------------------------- RULER
def ruler():
    h = ['<div class="ruler" id="ruler"><div class="rin" role="row">']
    h.append('<div class="corner" role="columnheader"><span class="ct"><span class="wide">Thursday </span>09:00–10:00</span>'
             '<span class="cs">13 windows, one week apart</span>'
             '<nav class="jump" aria-label="Jump to lane"><a href="#lane-metrics">Metrics</a>'
             '<a href="#lane-waits">Waits</a><a href="#lane-sql">SQL</a><a href="#lane-config">Config</a><a href="#dayprofile">Day</a></nav></div>')
    h.append('<div class="flags" id="flags" aria-label="Release and patch markers"></div>')
    for k in range(N):
        cls = 'h' + (' cur' if k == CUR else '')
        lab = WL[k]
        h.append('<button class="%s" data-w="%d" role="columnheader" aria-pressed="false" title="%s. Click to pin as the comparison target">'
                 '<span class="hd">%s</span><span class="ho">%s</span></button>' % (cls, k, WIN_FULL[k], lab, OFF[k] if k < 12 else 'current'))
    h.append('<div class="gh0" role="columnheader"><span class="gt" id="gut-title">vs prior mean</span>'
             '<span class="gs" id="gut-sub">12 windows; click a date to pin</span></div>')
    h.append('</div></div>')
    return ''.join(h)


MK = []
bound = {'Release 4.0': 2, 'Hotfix 4.0.1': 3, 'RU 19.28 patch': 5, 'Release 4.1': 8, 'Release 4.2': 12}
short = {'Release 4.0': 'R 4.0', 'Hotfix 4.0.1': 'HF 4.0.1', 'RU 19.28 patch': 'RU 19.28', 'Release 4.1': 'R 4.1', 'Release 4.2': 'R 4.2'}
import datetime as dt
for m in D['markers']:
    tm = dt.datetime.strptime(m['t'], '%Y-%m-%d %H:%M')
    MK.append({'w': bound[m['label']], 'l': m['label'], 's': short[m['label']], 't': tm.strftime('%a %-d %b %H:%M')})

# --------------------------------------------------------------- assemble
CSS = open(os.path.join(HERE, 'style.css')).read()
JS = open(os.path.join(HERE, 'app.js')).read()
hover_css = []
for k in range(N):
    hover_css.append('body[data-hw="%d"] .c[data-w="%d"],body[data-hw="%d"] .h[data-w="%d"]{background-image:linear-gradient(var(--hov),var(--hov))}' % (k, k, k, k))
    hover_css.append('body[data-hw="%d"] .c[data-w="%d"] .v,body[data-pw="%d"] .c[data-w="%d"] .v{opacity:1}' % (k, k, k, k))
    hover_css.append('body[data-pw="%d"] .c[data-w="%d"],body[data-pw="%d"] .h[data-w="%d"]{background-image:linear-gradient(var(--pin),var(--pin))}' % (k, k, k, k))
CSS += '\n' + '\n'.join(hover_css)

body = open(os.path.join(HERE, 'body.html')).read()
repl = {
    '{{RULER}}': ruler(),
    '{{LANE_ACTIVITY}}': lane('lane-activity', 'Activity', '1 row',
                              'One stacked column per compared hour. In Full, the row below adds the whole week before each window.',
                              [ash_row(), span_row()], gut='<span class="gs"><i class="sv large">●</i> 2 <i class="sv moderate">◐</i> 1 wait classes</span>'),
    '{{LANE_METRICS}}': lane('lane-metrics', 'Headline metrics', '11 rows',
                             'Mini column per window, scaled within the row from zero. Value printed in Current; hover a column for the rest.',
                             metrics_rows, gut='<span class="gs"><i class="sv large">●</i> 7 large</span>'),
    '{{LANE_WAITS}}': lane('lane-waits', 'Foreground waits', '14 events',
                           'Seconds waited in each window, idle events excluded. Swatch = wait class.',
                           wait_rows, gut='<span class="gs"><i class="sv large">●</i> 3 <i class="sv moderate">◐</i> 1</span>'),
    '{{LANE_OBJECTS}}': lane('lane-objects', 'Where the reads land', '3 rows',
                             'Top segment and datafile by physical reads. Ranked, not scored.', obj_rows),
    '{{LANE_SQL}}': lane('lane-sql', 'SQL', '8 rows',
                         'Elapsed seconds per window from the Top-N. A dash means outside the top 10 in that window, not zero.',
                         sql_rows, gut='<span class="gs"><i class="gk">◆</i> 1 plan change</span>'),
    '{{LANE_CONFIG}}': lane('lane-config', 'Configuration', '4 parameters',
                            'Only parameters whose value differs across the windows. A step marks the window where the new value first appears.',
                            cfg_rows, gut='<span class="gs">all 4 under a flag</span>'),
    '{{LANE_LOAD}}': lane('lane-load', 'Load profile', '27 counters',
                          'All SYSSTAT counters, per second. The reference table, in the same grid.',
                          load_full, full_only=True),
    '{{LANE_WINDOWS}}': lane('lane-windows', 'Windows and snapshots', '2 rows', 'Snapshot pairs behind each column.', win_rows, full_only=True),
    '{{STUBS}}': ''.join(stub_lanes),
    '{{DAYPROFILE}}': dp_html(),
    '{{MK}}': json.dumps(MK, ensure_ascii=False),
}
for k, v in repl.items():
    body = body.replace(k, v)
out = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n' \
      '<title>ORCLPRD window grid</title>\n<meta name="description" content="Mock C: AWR timeline comparison report on one aligned 13-window grid">\n' \
      '<style>\n' + CSS + '\n</style>\n</head>\n' + body.replace('</body>', '<script>\n' + JS + '\n</script>\n</body>') + '\n</html>\n'
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, 'w').write(out)
print('wrote', OUT, len(out.encode()), 'bytes')
