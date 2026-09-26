#!/usr/bin/env python3
"""Mock D (hybrid): A's structure, B's glyph everywhere, C as the timeline view.

Reads the shared demo data (../demo_series.json, ../pool.json), B's parsed tables
(../mockb/tables.json) and A's prebuilt series (../mock_a/data.json), emits static
markup + one JSON blob (the shape a PL/SQL emitter would produce), and inlines
template.html + style.css + app.js into design/report_mock_d_hybrid.html.
Deterministic: no clocks, no randomness, insertion-ordered dicts only.
"""
import html
import json
import os
import re
import statistics as st
import datetime as dt
from math import floor, log10

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
OUT = '/Users/davidbudac/claude_projects/awr_timeline_comparison/design/report_mock_d_hybrid.html'

S = json.load(open(os.path.join(SRC, 'demo_series.json'), encoding='utf-8'))
T = json.load(open(os.path.join(SRC, 'mockb', 'tables.json'), encoding='utf-8'))
A = json.load(open(os.path.join(SRC, 'mock_a', 'data.json'), encoding='utf-8'))

esc = html.escape
MINUS = '−'
N, CUR = 13, 12

# ------------------------------------------------------------------ windows, markers
WSTART = [dt.datetime.strptime(w['start'], '%Y-%m-%d %H:%M') for w in S['ashPerWindow']['windows']]
WL = ['%d %s' % (t.day, t.strftime('%b')) for t in WSTART]                    # '18 Jun' ... '10 Sep'
OFF = ['−%dw' % (12 - k) for k in range(12)] + ['Current']
FULLD = [t.strftime('%a ') + '%d %s, 09:00–10:00' % (t.day, t.strftime('%b')) for t in WSTART]
SHORT = {'Release 4.0': 'R 4.0', 'Hotfix 4.0.1': 'HF 4.0.1', 'RU 19.28 patch': 'RU 19.28',
         'Release 4.1': 'R 4.1', 'Release 4.2': 'R 4.2'}
MK = []
for m in S['markers']:
    tm = dt.datetime.strptime(m['t'], '%Y-%m-%d %H:%M')
    w = next(k for k in range(1, N) if WSTART[k - 1] < tm < WSTART[k])       # boundary between window w-1 and w
    MK.append({'w': w, 'l': m['label'], 's': SHORT.get(m['label'], m['label']),
               't': tm.strftime('%a ') + '%d %s %s' % (tm.day, tm.strftime('%b'), tm.strftime('%H:%M'))})
MK_AT = {m['w']: m for m in MK}
WC = {'CPU': '#3FB344', 'User I/O': '#4A90D9', 'System I/O': '#1F4E89', 'Commit': '#E89B40',
      'Application': '#D62728', 'Concurrency': '#8B0000', 'Network': '#967259', 'Configuration': '#793C32',
      'Other': '#C77CB0', 'Scheduler': '#88C070', 'Cluster': '#E5C228', 'Administrative': '#7B6FA8',
      'Queueing': '#E89BB7'}


# ------------------------------------------------------------------ number formatting (mirrors app.js)
def jsround(x):
    return int(floor(x + 0.5)) if x >= 0 else -int(floor(-x + 0.5))


def sig(v, d):
    if v == 0:
        return '0'
    dec = max(0, d - 1 - floor(log10(abs(v))))
    if dec == 0:
        return '{:,}'.format(jsround(v))
    return '%.*f' % (dec, v)


def neg(s):
    return s.replace('-', MINUS, 1)


def fv(v, u=''):
    if v is None:
        return ('—', '')
    a = abs(v)
    if u == 'B/s':
        if a >= 1e9:
            return (sig(v / 1e9, 4), 'GB/s')
        if a >= 1e6:
            return (sig(v / 1e6, 4), 'MB/s')
        if a >= 1e3:
            return (sig(v / 1e3, 4), 'kB/s')
        return (sig(v, 4), 'B/s')
    if a >= 1e9:
        return (sig(v / 1e9, 4) + 'G', u)
    if a >= 1e6:
        return (sig(v / 1e6, 4) + 'M', u)
    if a >= 1e4:
        return (sig(v / 1e3, 4) + 'k', u)
    return (neg(sig(v, 4)), u)


def fvs(v, u=''):
    n, uu = fv(v, u)
    return n + (('' if uu.startswith('/') else ' ') + uu if uu else '')


def fnum(v):
    return fv(v, '')[0]


def fp(v):
    """prose: 3 significant digits (95.1M, 13.9k, 675)"""
    a = abs(v)
    for lim, dv, suf in ((1e9, 1e9, 'G'), (1e6, 1e6, 'M'), (1e4, 1e3, 'k')):
        if a >= lim:
            return sig(v / dv, 3) + suf
    return sig(v, 3)


def den(r):
    return max(r['sd'] or 0, 0.02 * abs(r['mu'] or 0))


def nrange(r):
    """normal range = mean +/- 2 sigma, in the metric's own unit -> (text, unit)"""
    d = den(r)
    lo, hi = max(0, r['mu'] - 2 * d), r['mu'] + 2 * d
    sc, suf, u = 1, '', r['unit']
    if u == 'B/s':
        if hi >= 1e9:
            sc, u = 1e9, 'GB/s'
        elif hi >= 1e6:
            sc, u = 1e6, 'MB/s'
        elif hi >= 1e3:
            sc, u = 1e3, 'kB/s'
    elif hi >= 1e9:
        sc, suf = 1e9, 'G'
    elif hi >= 1e6:
        sc, suf = 1e6, 'M'
    elif hi >= 1e4 or (hi >= 1e3 and lo >= 1e3):
        sc, suf = 1e3, 'k'

    def f(x):
        if x == 0:
            return '0'
        s = x / sc
        if sc > 1:
            return (('%.1f' % s) if s < 100 else '{:,}'.format(jsround(s))) + suf
        return '{:,}'.format(jsround(s)) if s >= 1000 else sig(s, 3)
    return (f(lo) + '–' + f(hi), u)


def delta(cur, mu):
    if cur is None or mu in (None, 0):
        return '—'
    q = cur / mu
    if q >= 2:
        return '▲ ×' + (('%.1f' % q) if q < 100 else str(jsround(q)))
    p = (cur - mu) / abs(mu) * 100
    return ('▲ ' if p >= 0 else '▼ ') + '%.1f%%' % abs(p)


def zt(r):
    if r.get('zcap'):
        return '>+99σ'
    if r.get('z') is None:
        return '—'
    return ('+' if r['z'] >= 0 else MINUS) + '%.1fσ' % abs(r['z'])


def rnd(v, k=6):
    if v is None or v == 0:
        return v
    d = k - int(floor(log10(abs(v)))) - 1
    return round(v, max(d, 0))


def stats(vals):
    prior = [v for v in vals[:-1] if v is not None]
    n = len(prior)
    mu = st.mean(prior) if n else None
    sd = st.stdev(prior) if n > 1 else None
    return mu, sd, n


def zscore(cur, mu, sd):
    d = max(sd or 0, 0.02 * abs(mu or 0))
    return None if not d else (cur - mu) / d


def num(s):
    s = s.replace('−', '-').replace(',', '').strip()
    m = re.match(r'^([-+]?[0-9.]+)\s*([kMG]?)', s)
    if not m:
        return None
    return float(m.group(1)) * {'': 1, 'k': 1e3, 'M': 1e6, 'G': 1e9}[m.group(2)]


def parse_z(txt):
    t = txt.replace('immaterial', '').strip()
    if t.startswith('>'):
        return 99.0, True
    try:
        return float(t.replace('−', '-')), False
    except ValueError:
        return None, False


def sparkvals(row):
    return [float(x) if x not in ('', 'null') else None for x in row['spark'].split(',')]


# ------------------------------------------------------------------ the row registry (one record per scored series)
ROWS = {}


def mkrow(key, name, unit, vals, sev='typical', z=None, zcap=False, imm=False, twin=False, **kw):
    mu, sd, n = stats(vals)
    if z is None and mu is not None and vals[-1] is not None and sev not in ('flat', 'n/a'):
        z = zscore(vals[-1], mu, sd)
    r = {'key': key, 'name': name, 'unit': unit, 'vals': vals, 'cur': vals[-1], 'mu': mu, 'sd': sd, 'n': n,
         'z': z, 'zcap': zcap, 'sev': sev, 'imm': imm, 'twin': twin}
    r.update(kw)
    ROWS[key] = r
    return r


SEVMAP = {'large': 'large', 'moderate': 'moderate', 'typical': 'typical', 'flat baseline': 'flat', 'improved': 'improved'}
SHORT_UNIT = {'cs/s': 'cs/s', 'bytes/s': 'B/s', '/s': '/s', 'Sessions': 'sessions', '% Busy/(Idle+Busy)': '%',
              '% Cpu/DB_Time': '%', '% Wait/DB_Time': '%', 'Bytes Per Second': 'B/s', 'Requests Per Second': '/s',
              'Milliseconds': 'ms', 'Reads Per Second': '/s', 'Executes Per Second': '/s', 'Calls Per Second': '/s',
              'Commits Per Second': '/s', 'Rollbacks Per Second': '/s', 'Parses Per Second': '/s',
              'Logons Per Second': '/s', 'CentiSeconds Per Call': 'cs/call', 'Writes Per Second': '/s'}
LOAD = {r['cells'][0]: (SHORT_UNIT.get(r['cells'][1], r['cells'][1]), sparkvals(r)) for r in T['load-profile']['rows']}
SYSM = {r['cells'][0]: (SHORT_UNIT.get(r['cells'][1], r['cells'][1]), sparkvals(r)) for r in T['sysmetric']['rows']}
WCLS = {c['name']: [v / 3600 for v in c['vals']] for c in S['waitsFgClassPerWindow']['classes']}

# findings (load, metric, wait class) with the report's own z text
FIND = []
for dom, tkey in (('L', 'findings-load'), ('M', 'findings-metric'), ('F', 'findings-wait')):
    for row in T[tkey]['rows']:
        c = row['cells']
        raw = re.sub(r'\s*(twin\s*)?↗ row$', '', c[1]).strip()
        if dom == 'L':
            unit, vals = LOAD[raw]
        elif dom == 'M':
            unit, vals = SYSM[raw]
        else:
            unit, vals = 'AAS', WCLS[raw.replace('Wait class: ', '')]
        sev = SEVMAP[c[0].lower()]
        z, zcap = parse_z(c[6]) if sev != 'flat' else (None, False)
        r = mkrow(dom + ':' + raw, raw, unit, vals, sev, z, zcap, 'immaterial' in c[6], row['twin'])
        if dom == 'F':
            r['cls'] = raw.replace('Wait class: ', '')
        FIND.append(r)
FB = {r['name']: r for r in FIND}

# the 4 families (A's cards) over B's rows: lead, relatives, twins
LABEL = {'physical reads': 'Physical reads', 'table scans (long tables)': 'Table scans (long tables)',
         'physical read total bytes': 'Physical read bytes', 'Physical Read Total IO Requests Per Sec': 'Read I/O requests',
         'session logical reads': 'Logical reads', 'Wait class: User I/O': 'User I/O waits', 'DB time': 'DB time',
         'Database Wait Time Ratio': 'Wait time ratio', 'SQL Service Response Time': 'SQL service response time',
         'Wait class: Network': 'Network waits', 'Wait class: Commit': 'Commit waits'}
FAMS = [
    ('phys', 'Physical I/O', ['physical reads', 'table scans (long tables)', 'physical read total bytes',
                              'Physical Read Total IO Requests Per Sec', 'session logical reads', 'Wait class: User I/O'],
     ['Physical Reads Per Sec', 'Physical Read Total Bytes Per Sec', 'Logical Reads Per Sec']),
    ('dbt', 'DB time', ['DB time', 'Database Wait Time Ratio', 'SQL Service Response Time'],
     ['Average Active Sessions', 'Database CPU Time Ratio']),
    ('net', 'Network wait', ['Wait class: Network'], []),
    ('commit', 'Commit wait', ['Wait class: Commit'], []),
]
for fk, _, mem, tw in FAMS:
    for nm in mem + tw:
        FB[nm]['fam'] = fk
flagged = [r for r in FIND if r['sev'] in ('large', 'moderate')]
assert sorted(r['name'] for r in flagged) == sorted(n for f in FAMS for n in f[2] + f[3]), 'family map must cover every flagged row'
NORMAL = sorted([r for r in FIND if r['sev'] not in ('large', 'moderate')],
                key=lambda r: ((r['sev'] == 'flat'), -abs(r['z'] or 0)))
N_LARGE = sum(1 for r in flagged if r['sev'] == 'large' and not r['twin'])
N_MOD = sum(1 for r in flagged if r['sev'] == 'moderate' and not r['twin'])
N_TWIN = sum(1 for r in flagged if r['twin'])
N_NORM = len(NORMAL)
assert (N_LARGE, N_MOD, N_TWIN, N_NORM) == (10, 1, 5, 43), (N_LARGE, N_MOD, N_TWIN, N_NORM)

# other load / metric rows not in findings are not needed (every load/sysmetric row is a finding row)

# ------------------------------------------------------------------ foreground waits (3 tabs)
EVCLS = {'db file scattered read': 'User I/O', 'direct path read': 'User I/O', 'db file sequential read': 'User I/O',
         'SQL*Net more data to client': 'Network', 'log file sync': 'Commit',
         'enq: TX - row lock contention': 'Application', 'buffer busy waits': 'Concurrency',
         'db file parallel read': 'User I/O', 'control file sequential read': 'System I/O',
         'latch: cache buffers chains': 'Concurrency', 'library cache: mutex X': 'Concurrency',
         'cursor: pin S wait on X': 'Concurrency', 'direct path read temp': 'User I/O',
         'enq: TX - index contention': 'Concurrency'}


def waitrows(tkey, prefix, unit):
    out = []
    for row in T[tkey]['rows']:
        c = row['cells']
        z, zcap = parse_z(c[-2])
        r = mkrow(prefix + c[0], c[0], unit, sparkvals(row), SEVMAP[c[-3].lower()], z, zcap, 'immaterial' in c[-2],
                  cls=EVCLS.get(c[0], 'Other'))
        rk = re.search(r'#(\d+)', c[2])
        if rk:
            r['rank'] = int(rk.group(1))
        out.append(r)
    return out


WT = waitrows('waits-fg-time', 'W:', 's')
WA = waitrows('waits-fg-avg', 'WA:', 'ms')
WCR = []
for row in T['waits-fg-class']['rows']:
    c = row['cells']
    vals = [x['vals'] for x in S['waitsFgClassPerWindow']['classes'] if x['name'] == c[0]][0]
    z, zcap = parse_z(c[-2])
    WCR.append(mkrow('WC:' + c[0], c[0], 's', vals, SEVMAP[c[-3].lower()], z, zcap, 'immaterial' in c[-2], cls=c[0]))
WB = {r['name']: r for r in WT}
WAB = {r['name']: r for r in WA}

# ------------------------------------------------------------------ Top SQL, 4 rankings (A's series; z is mock-only, as in B)
DIMS = [('ELAPSED', 'Elapsed time', 'Elapsed', 's'), ('CPU', 'CPU time', 'CPU', 's'),
        ('GETS', 'Buffer gets', 'Gets', ''), ('PREADS', 'Physical reads', 'Reads', '')]
SQL = {}
for dim, _, _, unit in DIMS:
    lst = []
    for s in sorted([x for x in A['topsql'][dim] if x.get('rank') is not None], key=lambda x: x['rank']):
        vals = s['vals']
        mu, sd, n = stats(vals)
        z = zscore(vals[-1], mu, sd)
        pct = (vals[-1] - mu) / mu * 100
        if n < 3:
            sev = 'insufficient'
        elif abs(z) <= 2 or abs(pct) < 15:
            sev = 'typical'
        else:
            sev = ('large' if abs(z) > 3 else 'moderate') if z > 0 else 'improved'
        r = mkrow('Q:%s:%s' % (dim, s['id']), s['id'], unit, vals, sev, z, imm=abs(z) > 2 and sev == 'typical',
                  sql=s)
        lst.append(r)
    SQL[dim] = lst
QB = {d: {r['name']: r for r in SQL[d]} for d in SQL}

# ------------------------------------------------------------------ SQL Monitor (B's parsed rows)
SMON = [
    ('7k2m9dx4qp1zb', 'ORDERS_APP', 'OrderService', '3197245811 → 2088341150', [1.749645, 1.454318, 1.188314, 1.342073, 1.805734, 1.264887, 1.327481, 1.904801, 1.251031, 1.659982, 1.881540, 1.200589, 8.016030], 23.41, 'large', ['plan changed']),
    ('9wz2ke6yq4tn1', 'REPORTING', 'ReportEngine', '2789504216', [214.438652, 213.369131, 193.832114, 198.375378, 206.668241, 247.528329, 229.722407, 237.534415, 218.012881, 199.175738, 191.741678, 192.482235, 213.282163], 0.07, 'typical', ['DOP downgrade']),
    ('v8c2l5qs3wd7m', 'INVENTORY', 'DBMS_SCHEDULER', '2098345671', [45.970295, 36.325097, 39.000533, 44.002793, 45.134307, 31.782743, 31.180542, 41.504374, 45.465041, 35.811706, 38.402869, 46.337029, 40.151381], 0.01, 'typical', []),
    ('d8s3n5tw2xk7f', 'INVENTORY', 'InventorySync', '3350188817', [40.828043, 41.362438, 52.826280, 44.216644, 39.431836, 41.072140, 51.173726, 41.614704, 45.368650, 34.131273, 39.613962, 40.956110, 40.024642], -0.52, 'typical', []),
    ('w1n9k3pf6tx4a', 'REPORTING', 'SQL*Plus', None, None, None, 'n/a', ['error']),
    ('a4g6j2ct5nq1w', 'LOYALTY', 'DBMS_SCHEDULER', None, None, None, 'n/a', ['error']),
    ('h5x1c9pa7rd3s', 'REPORTING', 'ReportEngine', None, None, None, 'n/a', ['DOP downgrade']),
    ('x6j2d8rq5vm1b', 'SYS', 'DBMS_SCHEDULER', None, None, None, 'n/a', []),
    ('e1k8s4yn7pw2j', 'ORDERS_APP', 'PaymentGateway', None, None, None, 'n/a', []),
]
SM = []
for sid, user, mod, plan, vals, z, sev, flags in SMON:
    if vals:
        r = mkrow('SM:' + sid, sid, 's', vals, sev, z, user=user, module=mod, plan=plan, flags=flags)
    else:
        r = {'key': None, 'name': sid, 'unit': 's', 'vals': None, 'cur': None, 'mu': None, 'z': None, 'sev': 'n/a',
             'user': user, 'module': mod, 'flags': flags}
    SM.append(r)
SMB = {r['name']: r for r in SM}

# ------------------------------------------------------------------ parameters, segments, files
PARAMS = []
for row in T['param-changes-table']['rows']:
    c = row['cells']
    PARAMS.append({'name': c[0], 'vals': [x.replace('≠', '').strip() for x in c[1:14]][::-1]})


def gb(v):
    try:
        n = float(v)
    except ValueError:
        return v
    return '%d GB' % (n / 1073741824) if n >= 1073741824 else v


def tvals(cells, start):
    return [num(x) if x.strip() not in ('—', '') else None for x in cells[start:start + 13]][::-1]


SEG = {r['cells'][0]: r['cells'] for r in T['segio-detail-PREADS']['rows']}
FIL = {r['cells'][0]: r['cells'] for r in T['fileio-detail-READMB']['rows']}
seg_ol = mkrow('O:ORDER_LINES', 'ORDERS_APP.ORDER_LINES', 'blocks', tvals(SEG['ORDERS_APP.ORDER_LINES'], 2), 'n/a')
seg_pk = mkrow('O:ORDER_LINES_PK', 'ORDERS_APP.ORDER_LINES_PK', 'blocks', tvals(SEG['ORDERS_APP.ORDER_LINES_PK'], 2), 'n/a')
fil_301 = mkrow('O:ts301', 'ts_orders_data.301.1131588213', 'MB', tvals(FIL['ts_orders_data.301.1131588213'], 2), 'n/a')
for r in (seg_ol, seg_pk, fil_301):
    r['z'] = None

# ------------------------------------------------------------------ ASH per window, grouped like A's card and C's lane
APW = {c['name']: c['vals'] for c in S['ashPerWindow']['classes']}
ASH_ORDER = ['CPU', 'User I/O', 'System I/O', 'Commit', 'Application', 'Concurrency', 'Network', 'Other']
ash_other = [APW['Other'][k] + APW['Configuration'][k] + APW['Scheduler'][k] for k in range(N)]
ASH_VALS = [APW[c] if c != 'Other' else ash_other for c in ASH_ORDER]
ASH_TOT = [sum(ASH_VALS[i][k] for i in range(len(ASH_ORDER))) for k in range(N)]


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


# ================================================================== emitters
ZMIN, ZMAX = -4, 8
SEVW = {'large': 'large', 'moderate': 'moderate', 'typical': 'normal', 'improved': 'improved',
        'flat': 'flat baseline', 'n/a': 'not scored', 'insufficient': 'too little history'}
CHEV = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'


def band(r, size='', na='not scored'):
    sz = (' ' + size) if size else ''
    sev = r['sev']
    if sev == 'flat':
        return '<span class="bd s-flat%s" role="img" aria-label="flat baseline, prior sigma is zero"><b class="ov">flat, σ = 0</b></span>' % sz
    if r.get('z') is None:
        return '<span class="bd na%s" role="img" aria-label="%s"><b class="ov">%s</b></span>' % (sz, esc(na), esc(na))
    cls = ['bd', 's-' + sev] + ([size] if size else [])
    x = (r['z'] - ZMIN) / (ZMAX - ZMIN)
    ov = ''
    if x > 1:
        x = 1
        cls.append('po')
        ov = '<b class="ov">%s</b>' % zt(r)
    elif x < 0:
        x = 0
        cls.append('pu')
        ov = '<b class="ov">%s</b>' % zt(r)
    if r.get('twin'):
        cls.append('twn')
    lab = '%s%s, z %s' % (SEVW.get(sev, sev), ' (immaterial)' if r.get('imm') else '', zt(r))
    return '<span class="%s" style="--x:%s" role="img" aria-label="%s"><i></i>%s</span>' % (' '.join(cls), ('%.3f' % x).lstrip('0') if x < 1 else '1', lab, ov)


def bx(z):
    return '%.4f' % ((z - ZMIN) / (ZMAX - ZMIN))


def axis():
    return ('<span class="bd-ax" aria-hidden="true"><em style="--x:%s">%s2</em><em style="--x:%s">0</em>'
            '<em style="--x:%s">+2</em><em style="--x:%s">+3</em><em class="end" style="--x:1">+8σ</em></span>'
            % (bx(-2), MINUS, bx(0), bx(2), bx(3)))


def dtext(r, plain=False):
    if r['sev'] == 'flat':
        return '<span class="d s-flat">—</span>'
    cls = 's-plain' if plain else ('s-typical' if r.get('twin') else 's-' + r['sev'])
    return '<span class="d %s">%s</span>' % (cls, delta(r['cur'], r['mu']))


def dotk(sev):
    return '<i class="dotk %s" aria-hidden="true"></i>' % sev


def counts(large=0, moderate=0, normal=None, extra=''):
    out = []
    if large:
        out.append('<span>%s%d large</span>' % (dotk('large'), large))
    if moderate:
        out.append('<span>%s%d moderate</span>' % (dotk('moderate'), moderate))
    if normal is not None:
        out.append('<span>%s%d normal</span>' % (dotk('typical'), normal))
    if extra:
        out.append('<span class="muted">%s</span>' % extra)
    return ''.join(out)


ABOUT = []      # (title, html): every methodology note, collected into the one "About this report" fold


def add_note(title, about):
    if about:
        ABOUT.append((re.sub('<[^>]+>', '', title), about))


def sh(hid, title, summ, meta, about, tag='h2', cls=''):
    """the one section header: title, at most a one-line subtitle, counts; the method note goes to About"""
    add_note(title, about)
    return ('<div class="sh%s"><%s id="%s-h">%s</%s>%s<div class="meta">%s</div></div>'
            % (' ' + cls if cls else '', tag, hid, title, tag, ('<p class="sum">%s</p>' % summ) if summ else '', meta))


# ------------------------------------------------------------------ .bt table component
def bt_head(name_th, cur_th='Current', pre='', post='', sort=False, compact=False):
    s1 = ' data-sort="name"' if sort else ''
    s2 = ' data-sort="z"' if sort else ''
    s3 = ' data-sort="d"' if sort else ''
    h = '<thead><tr>%s<th%s><span class="thl">%s</span></th><th class="num">%s</th><th class="num">Normal range</th>' % (pre, s1, name_th, cur_th)
    h += '<th class="c-band"%s><span class="thl">vs normal, in σ</span>%s</th><th class="num"%s><span class="thl">Δ vs mean</span></th>' % (s2, axis(), s3)
    if not compact:
        h += '<th title="13 windows, oldest to Current; shaded = normal range">Trend</th>%s<th><span class="sr">Details</span></th>' % post
    return h + '</tr></thead>'


def bt_cells(r, name_html, pre='', post='', sqlcell=False, compact=False, na='not scored'):
    c = fv(r['cur'], r['unit'])
    rg = nrange(r) if r.get('mu') is not None else ('—', '')
    imm = '<span class="imm">immaterial</span>' if r.get('imm') else ''
    h = pre + '<td class="%s">%s</td>' % ('c-sql' if sqlcell else 'c-name', name_html)
    h += '<td class="c-cur">%s<span class="u">%s</span></td>' % (c[0], esc(c[1]))
    h += '<td class="c-rng">%s<span class="u">%s</span></td>' % (rg[0], esc(rg[1]))
    h += '<td class="c-band">%s</td>' % band(r, na=na)
    h += '<td class="c-d">%s%s</td>' % (dtext(r), imm)
    if not compact:
        h += '<td class="c-tr" data-k="%s"></td>' % esc(r['key'])
        h += post
        h += '<td class="c-x"></td>'
    return h


def flagcls(r):
    return (' f-' + r['sev']) if r['sev'] in ('large', 'moderate') and not r.get('twin') else ''


def sw(cls):
    return '<i class="sw" style="--sw:%s" title="%s wait class"></i>' % (WC.get(cls, '#999'), esc(cls)) if cls else ''


def name_cell(r, lead=False):
    nm = LABEL.get(r['name'], r['name']) if lead or r['name'] in LABEL else r['name']
    t = ' title="%s"' % esc(r['name']) if nm != r['name'] else ''
    tag = '<span class="tag" title="Same counter as the family lead, seen through another view; scored but not counted">twin</span>' if r.get('twin') else ''
    return '<span class="nmw">%s<span%s>%s</span>%s</span>' % (sw(r.get('cls')), t, esc(nm), tag)


def fam_rows(fk, compact=False):
    fam = next(f for f in FAMS if f[0] == fk)
    lead, rest, twins = FB[fam[2][0]], [FB[n] for n in fam[2][1:]], [FB[n] for n in fam[3]]
    h = ''
    for r, kind in [(lead, 'lead')] + [(x, 'mem') for x in rest] + [(x, 'twin') for x in twins]:
        h += '<tr class="%s%s">%s</tr>' % (kind, '' if r.get('twin') else flagcls(r),
                                            bt_cells(r, name_cell(r, kind == 'lead'), compact=compact))
    return h


# ------------------------------------------------------------------ the 13-window component (.wg)
def csv(vals):
    return ','.join('' if v is None else ('%.6g' % v) for v in vals)


def zone_attr(r):
    if r.get('mu') is None:
        return ''
    d = den(r)
    return ' data-z="%s"' % ','.join('%.6g' % x for x in (max(0, r['mu'] - 2 * d), r['mu'] + 2 * d,
                                                           max(0, r['mu'] - d), r['mu'] + d, r['mu']))


def cell(k, inner='', extra=''):
    return '<div class="c%s%s" data-w="%d">%s</div>' % (' cur' if k == CUR else '', extra, k, inner)


def vcell(k, v, glyph='', static=True):
    if not static and k != CUR:
        return cell(k, glyph)
    inner = '<span class="v nil" aria-label="not present">–</span>' if v is None else '<span class="v">%s</span>' % fnum(v)
    return cell(k, inner + glyph)


def bars_row(r, rid=None, lab=None, gut=None, cls='', glyphs=None, name=None, unit=None, prior=True):
    vals = r['vals']
    glyphs = glyphs or {}
    a = ' data-k="%s" data-name="%s" data-unit="%s"' % (esc(r['key']), esc(name or r.get('label') or r['name']), esc(unit if unit is not None else r['unit']))
    h = '<div class="r bars%s"%s%s role="row">' % ((' ' + cls) if cls else '', (' id="%s"' % rid) if rid else '', a)
    if lab is not None:
        h += lab
    h += ''.join(vcell(k, v, glyphs.get(k, ''), prior) for k, v in enumerate(vals))
    if gut is not None:
        h += gut
    return h + '</div>'


def lab_cell(name, sub='', swatch=None, title=None, extra=''):
    t = ' title="%s"' % esc(title) if title else ''
    s = '<i class="sw" style="--sw:%s" aria-hidden="true"></i>' % swatch if swatch else ''
    return '<div class="l" role="rowheader"%s><span class="nm">%s%s</span>%s%s</div>' % (
        t, s, esc(name), ('<span class="sub">%s</span>' % sub) if sub else '', extra)


def gut_scored(r, note=None):
    pinned = r.get('zcap') or (r.get('z') is not None and not ZMIN <= r['z'] <= ZMAX)
    z = note if note is not None else ('' if pinned else '<span class="z">z %s</span>' % zt(r))   # a pinned band already prints its z
    return ('<div class="g" role="cell"><div class="gl1">%s%s</div>%s</div>'
            % (dtext(r).replace('class="d ', 'class="d d1 '), z, band(r, 'sm')))


def gut_plain(r, note):
    return ('<div class="g" role="cell" title="Ranked, not scored"><div class="gl1">%s</div><div class="gx">%s</div></div>'
            % (dtext(r, plain=True).replace('class="d ', 'class="d d1 '), note))


def flags_row(lab=None, gut=None, bare=False, tall=False):
    if bare:
        return '<div class="r fr%s" aria-hidden="true"><div class="flags"></div></div>' % (' t2' if tall else '')
    return '<div class="r fr">%s<div class="flags" aria-label="Release and patch markers"></div>%s</div>' % (lab or '<div class="l"></div>', gut or '<div class="g"></div>')


def dates_row(bare=False, lab='', gut=''):
    cells = ''
    for k in range(N):
        keep = ' keep' if k in (0, 4, 8) else ''
        if bare:
            cells += '<div class="h%s%s" data-w="%d"><span class="hd">%s</span></div>' % (' cur' if k == CUR else '', keep, k, WL[k])
        else:
            cells += ('<div class="h%s%s" data-w="%d"><span class="hd">%s</span><span class="ho">%s</span></div>'
                      % (' cur' if k == CUR else '', keep, k, WL[k], OFF[k] if k < CUR else 'current'))
    if bare:
        return '<div class="r dr" aria-hidden="true">%s</div>' % cells
    return '<div class="r dr" aria-hidden="true">%s%s%s</div>' % (lab or '<div class="l"></div>', cells, gut or '<div class="g"></div>')


def wg_bare(r, rid=None, extra_rows='', cls='', glyphs=None):
    return ('<div class="wg bare allv%s" data-wg>%s%s%s%s</div>'
            % ((' ' + cls) if cls else '', flags_row(bare=True, tall=True), bars_row(r, rid=rid, glyphs=glyphs), extra_rows, dates_row(bare=True)))


def ruler(corner=None, gh=None, rid='ruler', buttons=True):
    """the one window ruler: corner | flags over 13 dates | gutter head (Timeline and the hero strip)"""
    h = '<div class="ruler"%s><div class="rin" role="row">' % ((' id="%s"' % rid) if rid else '')
    h += corner or ('<div class="corner" role="columnheader"><span class="ct">Thursday 09:00–10:00</span><span class="cs">13 windows</span>'
                    '<nav class="jumpnav" aria-label="Jump to lane"><a href="#lane-metrics">Load</a><a href="#lane-waits">Waits</a><a href="#lane-sql">SQL</a>'
                    '<a href="#lane-config">Config</a><a href="#tl-day">Day</a></nav></div>')
    h += '<div class="flags" aria-label="Release and patch markers"></div>'
    for k in range(N):
        inner = '<span class="hd">%s</span><span class="ho">%s</span>' % (WL[k], OFF[k] if k < CUR else 'current')
        keep = ' keep' if k in (0, 4, 8) else ''
        if buttons:
            h += ('<button class="h%s%s" type="button" data-w="%d" role="columnheader" aria-pressed="false" title="%s. Click to pin as the comparison target">%s</button>'
                  % (' cur' if k == CUR else '', keep, k, FULLD[k], inner))
        else:
            h += '<div class="h%s%s" data-w="%d" role="columnheader" title="%s">%s</div>' % (' cur' if k == CUR else '', keep, k, FULLD[k], inner)
    h += gh or '<div class="gh" role="columnheader"><span class="gt" id="gut-title">vs prior mean</span><span class="gs" id="gut-sub">click a date to pin</span></div>'
    return h + '</div></div>'


def step_row(rid, name, vals, sub, gut, lab_html=None, bare=False, fmtv=None):
    fmtv = fmtv or (lambda v: v)
    h = '<div class="r p"%s data-name="%s" role="row">' % ((' id="%s"' % rid) if rid else '', esc(name))
    if not bare:
        h += lab_html or lab_cell(name, sub)
    for k, v in enumerate(vals):
        start = k == 0 or vals[k - 1] != v
        lvl = 'lo' if v == vals[0] else 'hi'
        rise = start and k > 0
        inner = '<i class="st %s%s" aria-hidden="true"></i>' % (lvl, ' rise' if rise else '')
        if rise:
            inner += '<i class="nd" aria-hidden="true"></i>'
        if start or k == CUR:
            inner += '<span class="pv %s" title="%s">%s</span>' % (lvl, esc(str(v)), esc(fmtv(v)))
        h += '<div class="c%s" data-w="%d" data-pv="%s">%s</div>' % (' cur' if k == CUR else '', k, esc(fmtv(v)), inner)
    if not bare:
        h += gut
    return h + '</div>'


def stack_row(rid, lab, gut, cls=''):
    data = {'cls': ASH_ORDER, 'col': [WC[c] for c in ASH_ORDER],
            'v': [[round(x, 3) for x in vs] for vs in ASH_VALS], 'max': 22, 'ticks': [10, 20]}
    d = ' data-ash="%s"' % esc(json.dumps(data, separators=(',', ':')))
    h = '<div class="r ash%s"%s data-name="Active sessions (ASH)"%s role="row">' % ((' ' + cls) if cls else '', (' id="%s"' % rid) if rid else '', d)
    h += lab or ''
    h += ''.join(cell(k, '<span class="v">%s</span>' % fnum(ASH_TOT[k])) for k in range(N))
    h += gut or ''
    return h + '</div>'


# ------------------------------------------------------------------ micro window strip data + expander facts live in D.rows
def row_json(r):
    o = {'n': r.get('label') or r['name'], 'u': r['unit'], 'v': [rnd(v, 5) for v in r['vals']],
         'mu': rnd(r['mu'], 5), 'sd': rnd(r['sd'], 5), 'z': (round(r['z'], 2) if r.get('z') is not None else None),
         'sev': r['sev'], 'nw': r['n']}
    for k_src, k_dst in (('zcap', 'zc'), ('imm', 'imm'), ('twin', 'tw')):
        if r.get(k_src):
            o[k_dst] = 1
    if r.get('q'):
        o['q'] = r['q']
    for k in ('facts', 'extra', 'left'):
        if r.get(k):
            o[k[0]] = r[k]
    return o


# ================================================================== SUMMARY view
def nr_row(r, label, unit_override=None):
    unit = unit_override or r['unit']
    rr = dict(r, unit=unit)
    c = fvs(r['cur'], unit)
    rg = nrange(rr)
    return ('<div class="nr"><div class="l" title="%s">%s<small>normal %s%s</small></div>%s'
            '<div class="vv">%s<small>%s</small></div></div>'
            % (esc(r['name']), esc(label), rg[0], (' ' + rg[1]) if rg[1] and not rg[1].startswith('/') else rg[1],
               band(r, 'sm'), c, dtext(r)))


# ---- hero strip: DB time per window on the timeline geometry
dbt_cs = FB['DB time']
dbt = mkrow('H:dbtime', 'DB time', 'AAS', [v / 100 for v in dbt_cs['vals']], 'large', dbt_cs['z'], label='DB time')
hero_lab = ('<div class="l" role="rowheader"><span class="big">%s<span class="u">AAS</span></span>'
            '<span class="sub">normal %s</span></div>' % (fnum(dbt['cur']), nrange(dbt)[0]))
HERO_CORNER = ('<div class="corner" role="columnheader"><span class="ct">DB time per window</span></div>')
hero_strip = (
    '<div class="panel strip" id="s-strip"><div class="wg fit" data-wg role="table" aria-label="DB time per compared window">'
    + ruler(HERO_CORNER, '<div class="gh" role="columnheader"><span class="gt">vs prior mean</span></div>', rid=None, buttons=False)
    + bars_row(dbt, rid='hero-dbt', lab=hero_lab, gut=gut_scored(dbt), name='DB time', unit='AAS', prior=False)
    + '</div></div>')

# ---- band legend (drawn once)
legend = (
    '<div class="legend" id="s-legend">'
    '<div class="lg-p"><h3>Reading the band</h3>'
    '<div class="lg-row"><span class="lg-b" style="--row-bg:var(--surface)">%s%s</span>'
    '<span class="lg-k">%slarge</span><span class="lg-k">%smoderate</span><span class="lg-k">%snormal</span><span class="lg-k">%simproved</span></div>'
    '<p class="lg-t">Shaded: the prior normal, mean ± 1σ dark and ± 2σ light. Ticks at ±2σ and ±3σ are the moderate and large thresholds. '
    'One scale for the whole page; past +8σ the dot pins to the edge and prints its z. A hollow dot past a tick moved, but not enough to matter.</p></div>'
    '<div class="lg-p"><h3>Reading the 13 windows</h3>'
    '<div class="lg-row"><span class="lg-k"><i class="kb"></i>prior window</span><span class="lg-k"><i class="kb cur"></i><i class="kc"></i>Current</span>'
    '<span class="lg-k"><i class="kz"></i>same normal range</span><span class="lg-k">%s%sseverity on the Current bar</span>'
    '<span class="lg-k"><i class="kf"></i>release or patch</span><span class="lg-k"><b>◆</b> plan changed</span><span class="lg-k"><b>✚</b> first seen</span><span class="lg-k"><b>▽</b> DOP downgrade</span></div>'
    '<p class="lg-t">Every chart, card and Timeline row uses the same columns: oldest on the left, Current last and wider. '
    'Flags sit on the boundary between the two windows a release fell between. In the Timeline, hover a column to print its values and click a date to pin it.</p></div></div>'
    % (band({'z': 5.2, 'sev': 'large'}), axis(), dotk('large'), dotk('moderate'), dotk('typical'), dotk('improved'),
       dotk('large'), dotk('moderate')))


# ---- finding cards
def ev_row(dt_, ident, desc, r=None, plain=None, txt=True, note=''):
    if r is not None:
        m = '<div class="m">%s%s</div>' % (dtext(r), band(r, 'sm'))
    else:
        m = '<div class="m" title="Ranked, not scored"><span class="d s-plain">%s</span></div>' % plain
    return ('<div class="evr"><dt>%s</dt><dd><span class="id%s">%s</span><span class="de">%s</span></dd>%s</div>'
            % (dt_, ' txt' if txt else '', ident, desc, m))


def card(fid, sev, fam, lead_r, title, big, chart, evidence, related='', links='', jump=None, cls='', kicker=None, band_html=None):
    kk = kicker or ('<span class="sv" title="%s">%s%s</span>' % (esc(fam), dotk(sev), sev.capitalize()))
    bh = band_html if band_html is not None else (
        '<div class="fc-band" title="z %s against the prior normal">%s%s</div>' % (zt(lead_r), band(lead_r, 'lg'), axis()))
    jl = ('<a class="jump" href="#view=timeline" data-jump="%s">Timeline →</a>' % jump) if jump else ''
    return ('<article class="panel fc%s%s" id="%s" aria-labelledby="%s-h">'
            '<header class="fc-h"><div class="fc-k">%s</div>%s</header>'
            '<h3 id="%s-h">%s</h3><div class="fc-b"><div class="fc-main">%s%s</div><dl class="ev">%s</dl></div>%s'
            '<footer class="fc-f">%s<span class="evl">%s</span></footer></article>'
            % ((' f-' + sev) if sev in ('large', 'moderate') else '', (' ' + cls) if cls else '', fid, fid, kk, bh,
               fid, title, big, chart, evidence, related, jl, links))


def related(fk, label):
    return ('<details class="rel" data-fam="%s"><summary>%s</summary><div class="tw"></div></details>'
            % (fk, label))


def bigv(r, unit_word, unit=None):
    unit = unit or r['unit']
    rg = nrange(dict(r, unit=unit))
    return ('<div class="big"><span class="v">%s</span><span class="u">%s</span><span class="nrm" title="prior mean %s">normal %s%s</span></div>'
            % (fnum(r['cur']) if unit != 'B/s' else fv(r['cur'], unit)[0], unit_word, fvs(r['mu'], unit), rg[0],
               (' ' + rg[1]) if rg[1] and not rg[1].startswith('/') else rg[1]))


pr = FB['physical reads']
pr['label'] = 'Physical reads'
seg_x = seg_ol['cur'] / seg_ol['mu']
fil_x = fil_301['cur'] / fil_301['mu']
q7p = QB['PREADS']['7k2m9dx4qp1zb']
c_phys = card(
    'f-phys', 'large', 'Physical I/O', pr,
    'Physical reads <span class="d s-large">%.1f×</span> normal' % (pr['cur'] / pr['mu']),
    bigv(pr, 'reads/s'),
    wg_bare(pr),
    ev_row('Segment', 'ORDERS_APP.ORDER_LINES', '%s blocks, normal %s' % (fp(seg_ol['cur']), fp(seg_ol['mu'])), plain='▲ ×%.1f' % seg_x, txt=False)
    + ev_row('File', 'ts_orders_data.301.1131588213', '%s MB, normal %s; 302, 303 alike' % (fp(fil_301['cur']), fp(fil_301['mu'])), plain='▲ ×%.1f' % fil_x, txt=False)
    + ev_row('Wait', 'db file scattered read', '%s s, normal %s s' % (fp(WB['db file scattered read']['cur']), fp(WB['db file scattered read']['mu'])), WB['db file scattered read'])
    + ev_row('SQL', '7k2m9dx4qp1zb', '%s reads, normal %s; new plan' % (fp(q7p['cur']), fp(q7p['mu'])), q7p, txt=False),
    related('phys', '5 related metrics, 3 twins'),
    '<a href="#lib-seg">Segment I/O</a><a href="#lib-topsql">Top SQL</a>',
    jump='row-physreads', cls='lead s12')

# DB time card: stacked activity (the same row as the Timeline's Activity lane)
uio, cpu, wtr, srt = FB['Wait class: User I/O'], FB['DB CPU'], FB['Database Wait Time Ratio'], FB['SQL Service Response Time']
dbt_card = mkrow('H:dbt-card', 'DB time', 'AAS', [v / 100 for v in dbt_cs['vals']], 'large', dbt_cs['z'])
ash_lgd = ''.join('<span%s><i class="sw" style="--sw:%s"></i>%s</span>' % (' title="Other, Configuration and Scheduler"' if c == 'Other' else '', WC[c], c)
                  for c in ['CPU', 'User I/O', 'Network', 'Commit', 'Application', 'Concurrency', 'System I/O', 'Other'])
c_dbt = card(
    'f-dbt', 'large', 'DB time', dbt_card,
    'DB time up <span class="d s-large">%.0f%%</span>, all of it wait' % ((dbt_cs['cur'] / dbt_cs['mu'] - 1) * 100),
    bigv(dbt_card, 'AAS'),
    '<div class="lgd" aria-hidden="true">%s</div><div class="wg bare" data-wg>%s%s%s</div>'
    % (ash_lgd, flags_row(bare=True, tall=True),
       stack_row(None, '', ''), dates_row(bare=True)),
    ev_row('User I/O', '%s AAS' % fp(uio['cur']), 'normal %s' % fp(uio['mu']), uio)
    + ev_row('CPU', '%s AAS' % fp(cpu['cur'] / 100), 'normal %s' % fp(cpu['mu'] / 100), cpu)
    + ev_row('Wait share', '%s%%' % fp(wtr['cur']), 'normal %s%%' % fp(wtr['mu']), wtr)
    + ev_row('Response', '%s ms / call' % fp(srt['cur'] * 10), 'normal %s ms' % fp(srt['mu'] * 10), srt),
    related('dbt', '2 related metrics, 2 twins'),
    '<a href="#lib-fg">Foreground waits</a><a href="#tl-day">Day profile</a>',
    jump='row-ash', cls='s12')

net = FB['Wait class: Network']
net['label'] = 'Network waits'
wsn, wasn, byts = WB['SQL*Net more data to client'], WAB['SQL*Net more data to client'], FB['bytes sent via SQL*Net to client']
c_net = card(
    'f-net', 'large', 'Network wait', net,
    'Network wait <span class="d s-large">%.1f×</span> normal' % (net['cur'] / net['mu']),
    bigv(net, 'AAS'),
    wg_bare(net),
    ev_row('Event', 'SQL*Net more data to client', '%s s, normal %s s' % (fp(wsn['cur']), fp(wsn['mu'])), wsn)
    + ev_row('Per wait', '%s ms' % fp(wasn['cur']), 'unchanged: more waits, not slower', wasn)
    + ev_row('Sent', fvs(byts['cur'], 'B/s'), 'normal %s' % fvs(byts['mu'], 'B/s'), byts),
    '', '<a href="#lib-fg">Foreground waits</a>', jump='row-w-sqlnet', cls='s12')

com = FB['Wait class: Commit']
com['label'] = 'Commit waits'
lfs, ucom = WB['log file sync'], FB['user commits']
c_com = card(
    'f-commit', 'moderate', 'Commit wait', com,
    'Commit wait up <span class="d s-moderate">%.1f%%</span>' % ((com['cur'] / com['mu'] - 1) * 100),
    bigv(com, 'AAS'),
    wg_bare(com),
    ev_row('Event', 'log file sync', '%s s, normal %s s' % (fp(lfs['cur']), fp(lfs['mu'])), lfs)
    + ev_row('Commits', '%s/s' % fp(ucom['cur']), 'normal %s/s; 1.92 ms each' % fp(ucom['mu']), ucom),
    '', '<a href="#lib-fg">Foreground waits</a>', jump='row-w-lfs', cls='slim s12')

# ---- what changed around it: plan change + configuration
q7e, q7c, sm7 = QB['ELAPSED']['7k2m9dx4qp1zb'], QB['CPU'].get('7k2m9dx4qp1zb'), SMB['7k2m9dx4qp1zb']
q7e['label'] = '7k2m9dx4qp1zb elapsed'
plan_vals = ['3197245811'] * 12 + ['2088341150']
plan_step = step_row(None, 'Plan hash', plan_vals, '', '', bare=True)
ev_cpu = ev_row('CPU', '%s s' % fp(q7c['cur']), 'normal %s s; the rise is wait' % fp(q7c['mu']), q7c) if q7c else ''
c_plan = card(
    'f-plan', 'change', 'Top SQL', sm7,
    '<code>7k2m9dx4qp1zb</code> new plan after Release 4.2',
    '<p class="whereln" title="%s">ORDERS_APP · OrderService</p>'
    % esc(q7e['sql']['text']) + bigv(q7e, 's elapsed'),
    '<div class="wg bare allv" data-wg>%s%s%s%s</div>'
    % (flags_row(bare=True, tall=True), bars_row(q7e, rid=None), plan_step, dates_row(bare=True)),
    ev_row('Per exec', '700 gets, was 38', '9.0 ms, was 2.1 ms', plain='▲ ×18.4')
    + ev_row('SQL Monitor', 'max %s s' % fp(sm7['cur']), 'normal %s s' % fp(sm7['mu']), sm7)
    + ev_cpu,
    '', '<a href="#lib-topsql">Top SQL</a><a href="#lib-sqlmon">SQL Monitor</a>',
    jump='row-sql-7k2m', cls='s12 chg',
    kicker='<span class="sv" title="Top SQL, #1 by elapsed time"><b class="gk">◆</b>Plan change</span>',
    band_html='<div class="fc-band" title="SQL Monitor max elapsed, z %s">%s%s</div>' % (zt(sm7), band(sm7, 'lg'), axis()))

CFG = [
    ('cfg-adaptive', 'row-p-adaptive', 'optimizer_adaptive_plans', ['FALSE'] * 12 + ['TRUE'], 'FALSE → TRUE', 'changed in Current'),
    ('cfg-pga', 'row-p-pga', 'pga_aggregate_target', ['8 GB'] * 8 + ['12 GB'] * 5, '8 GB → 12 GB', 'changed 13 Aug'),
    ('cfg-sga', 'row-p-sga', 'sga_target', ['48 GB'] * 5 + ['64 GB'] * 8, '48 GB → 64 GB', 'changed 23 Jul'),
    ('cfg-cursor', 'row-p-cursor', 'cursor_sharing', ['EXACT'] * 3 + ['FORCE'] * 10, 'EXACT → FORCE', 'changed 9 Jul'),
]


def cfg_gut(vals, when):
    k = next(i for i in range(1, N) if vals[i] != vals[i - 1])
    m = MK_AT.get(k)
    return ('<div class="g" role="cell" title="%s"><div class="gl1"><span class="d1">%s</span></div><div class="gx"><i class="kf"></i> %s</div></div>'
            % (esc('Changed between the %s and %s windows; %s went in on %s, in the same interval' % (WL[k - 1], 'Current' if k == CUR else WL[k], m['l'], m['t'])) if m else '',
               when, m['l'] if m else 'no marker'))


cfg_rows = ''.join(step_row(None, nm, vals, ch, cfg_gut(vals, when)) for _, _, nm, vals, ch, when in CFG)
c_cfg = (
    '<article class="panel fc s12" id="f-config" aria-labelledby="f-config-h">'
    '<header class="fc-h"><div class="fc-k"><span class="sv" title="Parameters, not scored"><b class="gk">≠</b>Configuration</span></div></header>'
    '<h3 id="f-config-h">4 parameters differ, each under a release flag</h3>'
    '<p class="takeaway">Only <code>optimizer_adaptive_plans</code> differs in Current (Release 4.2).</p>'
    '<div class="cfg-wg"><div class="wg fit" data-wg role="table" aria-label="Parameter values per compared window">'
    + ruler('<div class="corner" role="columnheader"><span class="ct">Parameter</span></div>',
            '<div class="gh" role="columnheader"><span class="gt">Changed</span></div>', rid=None, buttons=False)
    + cfg_rows +
    '</div></div><footer class="fc-f"><a class="jump" href="#view=timeline" data-jump="row-p-adaptive">Timeline →</a>'
    '<span class="evl"><a href="#lib-params">Parameters</a></span></footer></article>')

# ---- checked and normal (B-style compact rows)
NORM_PICK = [('L:DB CPU', 'DB CPU', 'cs/s'), ('M:Host CPU Utilization (%)', 'Host CPU', '%'), ('L:execute count', 'Executions', '/s'),
             ('L:user calls', 'User calls', '/s'), ('L:user commits', 'User commits', '/s'), ('L:user rollbacks', 'User rollbacks', '/s'),
             ('L:redo size', 'Redo generated', 'B/s'), ('L:redo writes', 'Redo writes', '/s'), ('L:physical writes', 'Physical writes', '/s'),
             ('L:physical write total bytes', 'Write volume', 'B/s'), ('L:parse count (hard)', 'Hard parses', '/s'),
             ('L:parse count (total)', 'Parses (total)', '/s'), ('M:Session Count', 'Sessions', ''), ('L:logons cumulative', 'Logons', '/s'),
             ('L:table fetch by rowid', 'Rowid fetches', '/s'), ('L:sorts (disk)', 'Sorts (disk)', '/s'),
             ('L:bytes received via SQL*Net from client', 'Bytes from clients', 'B/s'), ('M:Network Traffic Volume Per Sec', 'Network volume', 'B/s')]
ngrid = ''.join(nr_row(ROWS[k], lab, u) for k, lab, u in NORM_PICK)
small_rows = ''.join(nr_row(ROWS[k], lab, u) for k, lab, u in [
    ('M:Average Synchronous Single-Block Read Latency', 'Single-block read latency', 'ms'),
    ('F:Wait class: Scheduler', 'Scheduler waits', 'AAS'), ('F:Wait class: System I/O', 'System I/O waits', 'AAS'),
    ('F:Wait class: Other', 'Other waits', 'AAS'), ('F:Wait class: Configuration', 'Configuration waits', 'AAS')])
imp_rows = nr_row(ROWS['L:parse count (hard)'], 'Hard parses', '/s')

s_normal = (
    sh('s-normal', 'Checked and normal', '',
       counts(normal=43), '<p>Every row is scored exactly like a finding: z = (current − mean) ÷ max(σ, 2% of mean) over the 12 prior windows. '
       'A hollow dot is normal; the text under the name is the normal range, mean ± 2σ, in the metric’s own unit.</p>')
    + '<div class="panel calm"><div class="ngrid">%s</div></div>' % ngrid
    + '<div class="calm-notes"><div class="panel note"><h3 title="Past a z threshold but under the materiality floor (0.5%% of DB time, or a latency under 1 ms)">Moved, too small to matter</h3>%s</div>'
      '<div class="panel note improved"><h3 title="Hard parses sit 51%% below a mean inflated by the 2 Jul spike; 2.7/s is their usual rate">Improved: none material</h3>%s</div></div>' % (small_rows, imp_rows))

# ================================================================== LIBRARY (shared by Summary and All sections)


def libsec(lid, title, summ, meta, about, body, views='in-s in-a', open_=False, os_=0, oa_=0):
    add_note(title, about)
    return ('<details class="vw %s" id="%s"%s style="--os:%d;--oa:%d"><summary><span class="chev" aria-hidden="true"></span>'
            '<span class="lt">%s</span><span class="ls">%s</span><span class="lm">%s</span></summary>'
            '<div class="lbody">%s</div></details>'
            % (views, lid, ' open' if open_ else '', os_, oa_, title, summ, meta, body))


def stub(txt):
    return '<p class="stub">%s</p>' % txt


SAME = 'Same table as Load profile; rows not reproduced in this mock.'

# findings table: 4 family groups (the cards), then the 43 normal rows
fh = bt_head('Metric', sort=True)
for fk, fname, mem, tw in FAMS:
    lead = FB[mem[0]]
    fh += ('<tbody class="grp" data-fam="%s" data-z="%.3f" data-name="%s" data-d="%.4f"><tr class="fam"><td colspan="8"><b>%s</b>%d metric%s%s'
           '<a href="#f-%s" data-view-go="summary">card</a></td></tr>%s</tbody>'
           % (fk, abs(lead['z']), esc(fname), lead['cur'] / lead['mu'], fname, len(mem), '' if len(mem) == 1 else 's',
              (' · %d twins' % len(tw)) if tw else '', fk, fam_rows(fk)))
fh += '<tbody class="nrm" id="nrm-find">' + ''.join(
    '<tr%s>%s</tr>' % (' class="twin"' if r.get('twin') else '', bt_cells(r, name_cell(r))) for r in NORMAL) + '</tbody>'
lib_find = libsec('lib-find', 'Findings',
                  '11 moved in 4 families',
                  counts(N_LARGE, N_MOD, N_NORM),
                  '<p>Load profile (<code>DBA_HIST_SYSSTAT</code>, end − begin ÷ seconds), system metrics (<code>DBA_HIST_SYSMETRIC_SUMMARY</code>) and foreground wait classes (AAS), '
                  'each against the same hour in the 12 prior valid windows. z = (current − mean) ÷ max(σ, 2% of mean); large beyond 3σ, moderate beyond 2σ, only when material and in the bad direction.</p>'
                  '<p>Mock-only: the 4 families group relatives beyond today’s twin/canonical links (table scans and logical reads under physical reads).</p>',
                  '<div class="tw"><table class="bt rsp" id="t-find">%s</table></div><button class="more" type="button" data-for="t-find" data-n="%d" aria-expanded="false">%sShow %d normal rows</button>'
                  % (fh, N_NORM, dotk('typical'), N_NORM),
                  views='in-a', open_=True, oa_=1)

# load profile: 27 rows
lp = bt_head('Statistic', sort=False)
lp += '<tbody>' + ''.join(
    '<tr class="%s%s">%s</tr>' % ('twin' if r.get('twin') else '', '' if r.get('twin') else flagcls(r), bt_cells(r, name_cell(r)))
    for r in [ROWS['L:' + row['cells'][0]] for row in T['load-profile']['rows']]) + '</tbody>'
lib_load = libsec('lib-load', 'Load profile',
                  '27 counters per second',
                  counts(5, 0, 21, '1 flat'),
                  '<p><code>DBA_HIST_SYSSTAT</code> and <code>DBA_HIST_SYS_TIME_MODEL</code>, end − begin per window ÷ seconds. Scored like the findings.</p>',
                  '<div class="tw"><table class="bt rsp" id="t-load">%s</table></div>' % lp, os_=7, oa_=2)

lib_metrics = libsec('lib-metrics', 'System metrics',
                     '23 metrics; host CPU 71%, normal',
                     counts(3, 0, None, '5 twins'), '<p><code>DBA_HIST_SYSMETRIC_SUMMARY</code> averages; rates summed across instances, ratios averaged.</p>',
                     stub(SAME), os_=8, oa_=3)


def waits_table(rows, label):
    h = bt_head(label)
    h += '<tbody>' + ''.join('<tr class="%s">%s</tr>' % (flagcls(r).strip(), bt_cells(r, name_cell(r))) for r in rows) + '</tbody>'
    return h


fg_body = ('<div class="tabs"><span class="seg" role="tablist" aria-label="Foreground wait views">'
           '<button type="button" role="tab" aria-selected="true" aria-controls="p-wt" id="tb-wt">Time waited</button>'
           '<button type="button" role="tab" aria-selected="false" aria-controls="p-wa" id="tb-wa">Average wait</button>'
           '<button type="button" role="tab" aria-selected="false" aria-controls="p-wc" id="tb-wc">By wait class</button></span></div>'
           '<div class="tabpanel" id="p-wt" role="tabpanel" aria-labelledby="tb-wt"><div class="tw"><table class="bt rsp">%s</table></div></div>'
           '<div class="tabpanel" id="p-wa" role="tabpanel" aria-labelledby="tb-wa" hidden><div class="tw"><table class="bt rsp">%s</table></div></div>'
           '<div class="tabpanel" id="p-wc" role="tabpanel" aria-labelledby="tb-wc" hidden><div class="tw"><table class="bt rsp">%s</table></div></div>'
           % (waits_table(WT, 'Event'), waits_table(WA, 'Event'), waits_table(WCR, 'Wait class')))
lib_fg = libsec('lib-fg', 'Foreground waits',
                '4 of 14 events moved',
                counts(3, 1),
                '<p><code>DBA_HIST_SYSTEM_EVENT</code>, foreground waits, idle excluded, end − begin per window. Scored with the wait-event policy: '
                'the floor is the event’s share of Current wait time.</p>',
                fg_body, open_=True, os_=3, oa_=4)
lib_bg = libsec('lib-bg', 'Background waits', 'all 11 up 62.8%, demoted',
                counts(0, 11), '<p><code>DBA_HIST_BG_EVENT_SUMMARY</code>. A shift that moves every row by the same factor is demoted one step.</p>',
                stub(SAME), views='in-a', oa_=5)

# top SQL: 4 rankings, same component
MODS = {s['id']: s for s in json.load(open(os.path.join(SRC, 'pool.json'), encoding='utf-8'))}


def sql_rows(dim, unit):
    out = ''
    for i, r in enumerate(SQL[dim]):
        s = r['sql']
        badges = ''
        if s.get('planChg'):
            badges += '<span class="tag" title="plan 3197245811 until 8 Sep 23:00, 2088341150 since">◆ plan changed</span>'
        if s.get('first') and s['first'] > '2026-06-18':
            badges += '<span class="tag" title="First seen %s (Release 4.1); ranked in the last %d windows only">✚ new 11 Aug</span>' % (s['first'], r['n'] + 1)
        nm = ('<div class="sql"><span class="sid">%s</span><span class="mod">%s</span><span class="txt">%s</span></div>'
              % (s['id'], esc(s['module']), esc(s['text'][:64])))
        facts = '<dt>Module</dt><dd>%s, %s, %s</dd>' % (s['schema'], esc(s['module']), esc(s['action']))
        if s.get('planChg'):
            facts += '<dt>Plan</dt><dd>new plan since 8 Sep 23:00, an hour after Release 4.2</dd>'
        if r['n'] < 12:
            facts += '<dt>History</dt><dd>ranked in %d prior windows only, so n = %d</dd>' % (r['n'], r['n'])
        r['facts'] = facts
        r['q'] = s['id']
        if s['id'] == '7k2m9dx4qp1zb' and dim == 'ELAPSED':
            r['left'] = ('<table class="mini"><thead><tr><th>Plan hash</th><th>First seen</th><th>Last seen</th><th>Executions</th><th>Avg s/exec</th><th>Avg gets/exec</th></tr></thead>'
                         '<tbody><tr><td>3197245811</td><td>2026-05-31 23:00</td><td>2026-09-08 23:00</td><td>4,975,426,129</td><td>0.002098</td><td>38.12</td></tr>'
                         '<tr><td>2088341150</td><td>2026-09-08 23:00</td><td>2026-09-10 10:00</td><td>75,949,092</td><td>0.009</td><td>700.0</td></tr></tbody></table>'
                         '<p class="subnote">Per execution the new plan is 4.3× slower and does 18× the buffer gets, consistent with the jump in long-table scans.</p>')
        out += '<tr class="%s">%s</tr>' % (flagcls(r).strip(), bt_cells(r, nm, pre='<td class="num rk">%d</td>' % (i + 1),
                                                                          post='<td class="c-fl"><span class="flags-c">%s</span></td>' % badges, sqlcell=True,
                                                                          na='too little history'))
    return out


tabs = ''.join('<button type="button" role="tab" aria-selected="%s" aria-controls="p-q%s" id="tb-q%s">%s</button>'
               % ('true' if i == 0 else 'false', d, d, lab) for i, (d, lab, _, _) in enumerate(DIMS))
panels = ''.join('<div class="tabpanel" id="p-q%s" role="tabpanel" aria-labelledby="tb-q%s"%s><div class="tw"><table class="bt rsp">%s<tbody>%s</tbody></table></div></div>'
                 % (d, d, '' if i == 0 else ' hidden', bt_head('Statement', cur_th=col, pre='<th class="num">#</th>', post='<th>Flags</th>'), sql_rows(d, u))
                 for i, (d, _, col, u) in enumerate(DIMS))
lib_topsql = libsec('lib-topsql', 'Top SQL',
                    '<code>7k2m9dx4qp1zb</code> #1, ×4.2, new plan',
                    counts(1, 1) + '<span><b>◆</b> 1</span><span><b>✚</b> 1</span>',
                    '<p>Top 10 in the Current window from <code>DBA_HIST_SQLSTAT</code> <code>*_DELTA</code>. The band compares this hour with the same statement in the prior windows where it made the top 10.</p>'
                    '<p>Mock-only: today’s report ranks statements without scoring them; this z is derived for the mock.</p>',
                    '<div class="tabs"><span class="seg" role="tablist" aria-label="Rank Top SQL by">%s</span></div>%s' % (tabs, panels),
                    open_=True, os_=1, oa_=6)

# SQL Monitor
smh = bt_head('Statement', cur_th='Max elapsed', post='<th>Flags</th>')
smb = ''
for r in SM:
    nm = '<div class="sql"><span class="sid">%s</span><span class="mod">%s / %s</span></div>' % (r['name'], esc(r['user']), esc(r['module']))
    fl = '<td class="c-fl"><span class="flags-c">%s</span></td>' % ''.join('<span class="tag">%s%s</span>' % ('◆ ' if f == 'plan changed' else '▽ ' if f == 'DOP downgrade' else '', esc(f)) for f in r['flags'])
    if r['vals'] is None:
        smb += ('<tr><td class="c-sql">%s</td><td class="c-cur num muted">—</td><td class="c-rng num muted">—</td><td class="c-band">%s</td>'
                '<td class="c-d num"><span class="d s-na">—</span></td><td class="c-tr"></td>%s<td class="c-x"></td></tr>'
                % (nm, band(r, na='no capture in a compared window'), fl))
    else:
        r['facts'] = '<dt>Plan hash</dt><dd>%s</dd>' % esc(r['plan'])
        smb += '<tr class="%s">%s</tr>' % (flagcls(r).strip(), bt_cells(r, nm, post=fl, sqlcell=True))
lib_sqlmon = libsec('lib-sqlmon', 'SQL Monitor',
                    '13,205 runs; 1 plan change, 1 DOP downgrade',
                    counts(1, 0, 3, '5 outside the windows'),
                    '<p><code>DBA_HIST_REPORTS</code> where <code>component_name = \'sqlmonitor\'</code>, summaries only, scored on each statement’s maximum elapsed time per window.</p>'
                    '<p>Only completed, expensive-enough or parallel executions are persisted, so a missing statement did not necessarily run fast.</p>',
                    '<div class="tw"><table class="bt rsp" id="t-smon">%s<tbody>%s</tbody></table></div>' % (smh, smb), os_=2, oa_=7)

lib_seg = libsec('lib-seg', 'Segment I/O', '<code>ORDER_LINES</code> 95.1M blocks vs 8.5M',
                 '<span class="muted">ranked, not scored</span>', '<p><code>DBA_HIST_SEG_STAT</code>, top 10 segments per dimension.</p>', stub(SAME), os_=5, oa_=8)
lib_file = libsec('lib-file', 'File I/O', '<code>ts_orders_data.301</code> 345k MB vs 74k',
                  '<span class="muted">ranked, not scored</span>', '<p><code>DBA_HIST_FILESTATXS</code> and <code>DBA_HIST_IOSTAT_FILETYPE</code>.</p>', stub(SAME), os_=6, oa_=9)

# parameters: the same step line, per row
ph = ('<thead><tr><th>Parameter</th><th>Current</th><th>Before</th><th>Changed between</th><th>Nearest marker</th>'
      '<th style="min-width:360px">Per window</th></tr></thead><tbody>')
for _, _, nm, vals, ch, when in sorted(CFG, key=lambda c: -next(i for i in range(1, N) if c[3][i] != c[3][i - 1])):
    k = next(i for i in range(1, N) if vals[i] != vals[i - 1])
    m = MK_AT[k]
    ph += ('<tr><td class="mono">%s</td><td><b>%s</b></td><td class="muted">%s</td><td>%s and %s</td><td><i class="kf"></i> %s, %s</td>'
           '<td><div class="wg bare mini" data-wg>%s</div></td></tr>'
           % (nm, vals[-1], vals[0], WL[k - 1], 'Current' if k == CUR else WL[k], m['l'], m['t'].split(' ', 1)[1].rsplit(' ', 1)[0],
              step_row(None, nm, vals, '', '', bare=True)))
ph += '</tbody>'
lib_params = libsec('lib-params', 'Parameters', '4 differ, 1 in Current',
                    '<span>4 differ</span>', '<p><code>DBA_HIST_PARAMETER</code>, value at each window’s end snapshot, lowest container wins.</p>',
                    '<div class="tw"><table class="bt" id="t-par">%s</table></div>' % ph, os_=9, oa_=10)

lib_ash = libsec('lib-ash', 'Active sessions, whole span',
                 'Current %.1f AAS; prior %.1f–%.1f'
                 % (ASH_TOT[12], min(ASH_TOT[:12]), max(ASH_TOT[:12])),
                 '<span>18 Jun to 10 Sep</span>',
                 '<p><code>DBA_HIST_ACTIVE_SESS_HISTORY</code>, samples ÷ 360 per hour, 6-hour buckets smoothed with a 24-hour rolling mean. '
                 'Dots: the unsmoothed 09:00 hour of each compared window. Application, System I/O, Concurrency, Other, Configuration and Scheduler are merged into grey.</p>',
                 '<div class="lgd" id="ash-lgd"></div><div class="ashw" id="ashw"><svg id="ash-svg" role="img" aria-label="Stacked active sessions by wait class, 18 June to 10 September, with the 13 compared hours as dots"></svg></div>',
                 views='in-a', oa_=11)
lib_day = libsec('lib-day', 'Day profile', '2 day-wide shifts',
                 counts(2), '<p>Each hour of the 24 h ending at 10:00 against the same hour on the 7 prior days, fixed daily cadence.</p>',
                 '<p class="stub"><a href="#view=timeline" data-jump="tl-day">Open in the Timeline →</a></p>', os_=4, oa_=14)
lib_util = libsec('lib-util', 'Utilization', '652 tx/s, 6,208 calls/s, 2,095 sessions',
                  counts(normal=14), '<p>Template-independent usage profile from <code>DBA_HIST_SYSMETRIC_SUMMARY</code>.</p>', stub(SAME), views='in-a', oa_=12)
lib_win = libsec('lib-win', 'Compared windows', 'snapshots 41417–43434, no restarts',
                 '<span>13 valid</span>', '<p>Begin and end snapshot per window; a window is skipped on a restart, a DBID change or a snapshot more than 15 min off its edge.</p>',
                 stub('Not reproduced in this mock.'), views='in-a', oa_=13)

LIB = ''.join([lib_find, lib_topsql, lib_sqlmon, lib_fg, lib_load, lib_metrics, lib_bg, lib_seg, lib_file, lib_params, lib_ash, lib_day, lib_util, lib_win])

# ================================================================== TIMELINE view (C's grid)


def lane_head(lid, title, summ, meta, about):
    h = ('<div class="r gh2" role="row"><div class="l" role="rowheader"><button class="lt2" type="button" aria-expanded="true" aria-controls="%s" data-lane="%s">'
         '<i class="car" aria-hidden="true"></i><span class="lti">%s</span></button></div>' % (lid, lid, esc(title)))
    h += ''.join(cell(k) for k in range(N))
    h += '<div class="g" role="cell"><span class="meta">%s</span></div>' % meta
    h += ('<div class="cap"><span>%s</span></div></div>' % summ) if summ else '</div>'
    add_note('Timeline: ' + title, about)
    return h


def lane(lid, title, summ, meta, about, rows):
    return '<div class="lane" id="%s" role="rowgroup">%s<div class="lrows">%s</div></div>' % (lid, lane_head(lid, title, summ, meta, about), ''.join(rows))


# activity
ptot = mean(ASH_TOT[:12])
act_lab = ('<div class="l" role="rowheader"><span class="nm">Active sessions</span><span class="sub">ASH, by wait class</span>'
           '<ul class="leg">%s</ul><span class="axn" aria-hidden="true"></span></div>'
           % ''.join('<li%s><i class="sw" style="--sw:%s"></i>%s</li>' % (' title="Other, Configuration and Scheduler"' if c == 'Other' else '', WC[c], c) for c in ASH_ORDER))
act_gut = ('<div class="g" role="cell" title="ASH active sessions, Current vs the mean of the 12 prior windows; ASH is not scored">'
           '<div class="gl1"><span class="d d1 s-plain">%s total</span></div>'
           '<span class="d3"><i class="sw" style="--sw:%s"></i>User I/O %s</span><span class="d3"><i class="sw" style="--sw:%s"></i>Network %s</span>'
           '<span class="d3"><i class="sw" style="--sw:%s"></i>CPU %s</span></div>'
           % (delta(ASH_TOT[12], ptot), WC['User I/O'], delta(APW['User I/O'][12], mean(APW['User I/O'][:12]))[2:], WC['Network'],
              delta(APW['Network'][12], mean(APW['Network'][:12]))[2:], WC['CPU'], delta(APW['CPU'][12], mean(APW['CPU'][:12]))[2:]))
L_ACT = lane('lane-activity', 'Activity', '',
             '<span class="muted">ASH, not scored</span>', '<p><code>DBA_HIST_ACTIVE_SESS_HISTORY</code>, samples ÷ 360 in each compared hour, idle excluded.</p>',
             [stack_row('row-ash', act_lab, act_gut)])


def mrow(rid, key, label, sub, unit=None):
    r = ROWS[key]
    return bars_row(r, rid=rid, lab=lab_cell(label, sub, title=r['name']), gut=gut_scored(r), name=label, unit=unit, prior=False)


aas = [v / 100 for v in FB['DB time']['vals']]
M_ROWS = [
    mrow('row-dbtime', 'L:DB time', 'DB time', 'cs/s'),
    mrow('row-dbcpu', 'L:DB CPU', 'DB CPU', 'cs/s'),
    mrow('row-wtr', 'M:Database Wait Time Ratio', 'Wait time ratio', '%'),
    mrow('row-lreads', 'L:session logical reads', 'Logical reads', '/s'),
    mrow('row-physreads', 'L:physical reads', 'Physical reads', 'blocks/s'),
    mrow('row-prbytes', 'L:physical read total bytes', 'Physical read bytes', 'B/s'),
    mrow('row-lscans', 'L:table scans (long tables)', 'Long-table scans', '/s'),
    mrow('row-srt', 'M:SQL Service Response Time', 'SQL response time', 'cs/call'),
    mrow('row-hcpu', 'M:Host CPU Utilization (%)', 'Host CPU', '%'),
    mrow('row-redo', 'L:redo size', 'Redo generated', 'B/s'),
    mrow('row-hparse', 'L:parse count (hard)', 'Hard parses', '/s'),
]
n_ml = sum(1 for k in ['L:DB time', 'M:Database Wait Time Ratio', 'L:session logical reads', 'L:physical reads', 'L:physical read total bytes',
                       'L:table scans (long tables)', 'M:SQL Service Response Time'] if ROWS[k]['sev'] == 'large')
L_MET = lane('lane-metrics', 'Headline and load', '',
             counts(n_ml, 0, 11 - n_ml), '<p>The six headline numbers plus the load counters behind the findings. Same scoring as the findings; the gutter is the band.</p>', M_ROWS)

WID = {'db file scattered read': 'row-w-scattered', 'direct path read': 'row-w-dpr', 'SQL*Net more data to client': 'row-w-sqlnet', 'log file sync': 'row-w-lfs'}
W_ROWS = []
for i, r in enumerate(WT):
    W_ROWS.append(bars_row(r, rid=WID.get(r['name']), lab=lab_cell(r['name'], r['cls'], swatch=WC[r['cls']]),
                           gut=gut_scored(r), cls='w' + (' more' if i >= 10 else ''), prior=False))
W_ROWS.insert(10, '<div class="r xpr" role="row"><div class="l" role="rowheader"><button class="xpb" type="button" data-for="lane-waits" aria-expanded="false">+ Show 4 more events</button></div>'
              + ''.join(cell(k) for k in range(N)) + '<div class="g" role="cell"></div></div>')
L_WAIT = lane('lane-waits', 'Waits', 'seconds waited',
              counts(3, 1), '<p><code>DBA_HIST_SYSTEM_EVENT</code>, foreground only, end − begin per window.</p>', W_ROWS)

O_ROWS = [
    bars_row(seg_ol, rid='row-o-ol', lab=lab_cell('ORDERS_APP.ORDER_LINES', 'table, blocks read'), gut=gut_plain(seg_ol, '#1 by physical reads'), cls='o', prior=False),
    bars_row(seg_pk, lab=lab_cell('ORDERS_APP.ORDER_LINES_PK', 'index, blocks read'), gut=gut_plain(seg_pk, '#2 by physical reads'), cls='o', prior=False),
    bars_row(fil_301, rid='row-o-file', lab=lab_cell('ts_orders_data.301.1131588213', 'datafile, MB read'), gut=gut_plain(fil_301, '#1 by MB read'), cls='o', prior=False),
]
L_OBJ = lane('lane-objects', 'Where the reads land', '',
             '<span class="muted">not scored</span>', '<p><code>DBA_HIST_SEG_STAT</code> and <code>DBA_HIST_FILESTATXS</code>, top 10 per window.</p>', O_ROWS)

Q_ROWS = []
for sid in ['7k2m9dx4qp1zb', 'n7t3q5xc1yj4g', '2yq9jv7c5hm3d', 'u9d5p3fw2hs8x', 'f1p7r4mz8vb2c', 't3h6u1zr9nb8w']:
    r = QB['ELAPSED'][sid]
    s = r['sql']
    glyphs, note = {}, None
    if sid == '7k2m9dx4qp1zb':
        glyphs[12] = '<b class="glf" title="Plan changed: 3197245811 → 2088341150">◆</b>'
        note = '<span class="z"><b>◆</b> new plan</span>'
    if sid == 'n7t3q5xc1yj4g':
        first = next(k for k, x in enumerate(r['vals']) if x is not None)
        glyphs[first] = '<b class="glf" title="First seen in the top 10: %s (first captured 2026-08-11 22:00, Release 4.1)">✚</b>' % WL[first]
        note = '<span class="z"><b>✚</b> new %s</span>' % WL[first]
    short = s['text'] if len(s['text']) < 90 else s['text'][:88] + '…'
    Q_ROWS.append(bars_row(r, rid='row-sql-' + sid[:4], lab=lab_cell(sid, '%s <span class="sq">%s</span>' % (s['schema'], esc(short)), title=s['text']),
                           gut=gut_scored(r, note), cls='q', glyphs=glyphs, name=sid, prior=False))
    if sid == '7k2m9dx4qp1zb':
        Q_ROWS.append(bars_row(sm7, rid='row-sqlmon-7k2m', lab=lab_cell('SQL Monitor', 'max elapsed, s'),
                               gut=gut_scored(sm7), cls='q sub', name='7k2m9dx4qp1zb, SQL Monitor max elapsed', prior=False))
sm9 = SMB['9wz2ke6yq4tn1']
Q_ROWS.append(bars_row(sm9, rid='row-sqlmon-9wz2', lab=lab_cell('9wz2ke6yq4tn1', 'REPORTING <span class="sq">SQL Monitor max</span>'),
                       gut=gut_scored(sm9, '<span class="z"><b>▽</b> DOP</span>'), cls='q',
                       glyphs={12: '<b class="glf" title="DOP downgrade flagged on a Current-window execution">▽</b>'}, name='9wz2ke6yq4tn1, SQL Monitor max elapsed', prior=False))
L_SQL = lane('lane-sql', 'SQL', 'elapsed s; dash = not in top 10',
             '<span><b>◆</b> 1 plan change</span><span><b>✚</b> 1</span>',
             '<p><code>DBA_HIST_SQLSTAT</code>; SQL Monitor rows from <code>DBA_HIST_REPORTS</code>. Mock-only: the Top SQL band is derived for the mock.</p>', Q_ROWS)

C_ROWS = [step_row(rid, nm, vals, '', cfg_gut(vals, when), lab_html=lab_cell(nm, ch)) for _, rid, nm, vals, ch, when in CFG[::-1]]
L_CFG = lane('lane-config', 'Configuration', '',
             '<span class="muted">all 4 under a flag</span>', '<p><code>DBA_HIST_PARAMETER</code>, value at each window’s end snapshot.</p>', C_ROWS)


# day profile, own 24-column ruler; severity on dots, Current hour in the accent
DP = S['dayProfile']
HRS = DP['hours']


def dp_html():
    h = ['<div class="dpg" role="table" aria-label="Day profile, 24 hours ending Thu 10 Sep 10:00">']
    h.append('<div class="dpr dph" role="row"><div class="l" role="columnheader">Hour starting</div>')
    for i, hr in enumerate(HRS):
        day = '<span class="dday">Wed 9</span>' if i == 0 else ('<span class="dday">Thu 10</span>' if hr == '00:00' else '')
        h.append('<div class="dc%s%s" role="columnheader">%s<span class="hh">%s</span></div>' % (' cur' if i == len(HRS) - 1 else '', ' brk' if hr == '00:00' else '', day, hr[:2]))
    h.append('<div class="g" role="columnheader"><span class="d1">Hours flagged</span></div></div>')
    for s_ in DP['stats']:
        fl = sum(1 for x in s_['sev'] if x in ('large', 'moderate'))
        lg = sum(1 for x in s_['sev'] if x == 'large')
        if fl >= 20:
            g2 = '%sday-wide shift' % dotk('large')
        elif lg:
            g2 = '%s%d isolated hours' % (dotk('large'), lg)
        else:
            g2 = '%snone' % dotk('typical')
        base = s_['name'].split(' (')[0]
        h.append('<div class="dpr" data-name="%s" data-v="%s" data-mu="%s" data-sev="%s" role="row"><div class="l" role="rowheader">%s</div>'
                 % (esc(base), csv(s_['cur']), csv(s_['mu']), ','.join(x[0] for x in s_['sev']), esc(base[0].upper() + base[1:])))
        for i, v in enumerate(s_['cur']):
            h.append('<div class="dc%s%s"></div>' % (' cur' if i == len(HRS) - 1 else '', ' brk' if HRS[i] == '00:00' else ''))
        h.append('<div class="g" role="cell"><span class="d1">%d of 24 h</span><span class="gx">%s</span></div></div>' % (fl, g2))
    h.append('</div>')
    return ''.join(h)


TIMELINE = (
    sh('v-tl', 'Timeline', 'Down a column: one window. Across a row: when it started.',
       counts(10, 1),
       '<p>Each row is scaled within itself from zero; the Current column is the accented band. Release and patch flags sit on the boundary between the two windows they fell between, '
       'and their lines run through every lane. The right gutter is the same band and Δ as the Summary.</p>')
    + '<div class="panel gridwrap wg" id="tl" data-wg role="table" aria-label="Current vs 12 prior windows, one column per window">'
    + ruler() + '<div class="gbody" id="gbody"><div class="gin" id="gin">' + L_ACT + L_MET + L_WAIT + L_OBJ + L_SQL + L_CFG + '</div></div></div>'
    + '<section class="panel dp" id="tl-day" aria-labelledby="tl-day-h"><div class="dphead">'
    + sh('tl-day', 'Day profile', 'Last 24 h vs the same hour on 7 prior days',
         '<span>%s2 day-wide shifts</span>' % dotk('large'), '<p>Bar = this day, tick = prior-day mean, dot = flagged hour. Fixed daily cadence, independent of the weekly comparison. Fewer than 30 min of snapshot coverage in an hour leaves it empty.</p>', tag='h3', cls='flush')
    + '</div><div class="dpscroll" id="dpscroll">' + dp_html() + '</div></section>')

# ================================================================== assemble
FINDINGS = (
    sh('s-findings', '4 findings', '11 metrics moved, in 4 families',
       counts(N_LARGE, N_MOD),
       '<p>Each card is one family: the lead metric in the header band, its 13 windows, the evidence behind it and the relatives that moved with it. '
       'Evidence rows carry a band when the value is scored and a plain ratio when it is only ranked.</p>')
    + '<div class="cards">' + c_phys + c_dbt + c_net + c_com + '</div>')
CHANGES = (
    sh('s-changes', 'What changed around it', 'Plan and parameter changes under the release flags', '', '<p>Plan hashes from <code>DBA_HIST_SQLSTAT</code>; parameters from <code>DBA_HIST_PARAMETER</code>. Neither is scored.</p>')
    + '<div class="cards">' + c_plan + c_cfg + '</div>')

LIBHEAD_S = sh('s-lib', 'Evidence library', 'Every other section, one line each', '', '<p>The same rows, in the same table component, as the All sections view.</p>')
LIBHEAD_A = sh('v-all', 'All sections', 'Every table of the report', '',
               '<p>Everything the Summary and the Timeline draw is derived from these tables. Each row: Current, normal range, band, Δ, a 13-window trend and an expander.</p>')
add_note('Scoring', '<p>z = (current − mean) ÷ max(σ, 2% of mean) over the 12 prior windows. Large beyond 3σ, moderate beyond 2σ, only when material and in the bad direction. '
     'Twins (the same counter seen through another view) are scored but folded into their family and not counted. The normal range is mean ± 2σ in the metric’s own unit.</p>'
     '<p>Mock-only: the 4-family grouping and the Top SQL z-scores are derived here; segment and file rows are ranked, not scored.</p>')
ABOUT_HTML = (
    '<details class="panel aboutrep" id="about"><summary><span class="chev" aria-hidden="true"></span><span class="lt">About this report</span>'
    '<span class="ls">legend, method, sources</span></summary><div class="ab-body">' + legend
    + '<dl class="notes">' + ''.join('<dt>%s</dt><dd>%s</dd>' % (esc(t), a) for t, a in ABOUT) + '</dl>'
    '<p class="ab-meta">awr_trend.sql 1.5.0, read-only: every number is recomputed from <code>DBA_HIST_*</code> on each run. '
    'ORCLPRD · DBID 1483726519 · prd-ora-01.corp.example · Oracle 19.0.0.0 · by AWR_READER · Mock D, built from docs/examples/demo_busy_db.html</p>'
    '</div></details>')

tpl = open(os.path.join(HERE, 'template.html'), encoding='utf-8').read()
CSS = open(os.path.join(HERE, 'style.css'), encoding='utf-8').read()
CSS = re.sub(r'/\*.*?\*/', '', CSS, flags=re.S)
CSS = re.sub(r'\n\s*', '\n', CSS).strip()
JS = open(os.path.join(HERE, 'app.js'), encoding='utf-8').read()
JS = '\n'.join(ln.strip() for ln in JS.split('\n') if ln.strip() and not ln.strip().startswith('/* ') and not ln.strip().startswith('// '))

# data blob
B_ASH = S['ashSpan6h']
KEEP = ['CPU', 'User I/O', 'Network', 'Commit']
ash_series = [{'name': k, 'vals': [round(v, 2) for v in [c for c in B_ASH['classes'] if c['name'] == k][0]['vals']]} for k in KEEP]
rest = [c for c in B_ASH['classes'] if c['name'] not in KEEP]
ash_series.append({'name': 'Other classes', 'vals': [round(sum(c['vals'][i] for c in rest), 2) for i in range(len(B_ASH['t']))]})
D = {
    'w': WL, 'off': OFF, 'full': FULLD, 'mk': MK, 'hrs': HRS,
    'rows': {k: row_json(r) for k, r in ROWS.items() if r.get('vals')},
    'sqlt': {x['id']: x['text'] for d in A['topsql'] for x in A['topsql'][d]},
    'ash': {'t': B_ASH['t'], 'series': ash_series, 'win': [w['start'] for w in S['ashPerWindow']['windows']],
            'wtot': [round(sum(c['vals'][i] for c in S['ashPerWindow']['classes']), 2) for i in range(N)]},
}
data = json.dumps(D, separators=(',', ':'), ensure_ascii=False).replace('</', '<\\/')

repl = {
    '{{CSS}}': CSS, '{{JS}}': JS, '{{DATA}}': data,
    '{{STRIP}}': hero_strip, '{{ABOUT}}': ABOUT_HTML, '{{FINDINGS}}': FINDINGS, '{{CHANGES}}': CHANGES,
    '{{NORMAL}}': s_normal, '{{TIMELINE}}': TIMELINE, '{{LIB}}': LIB,
    '{{LIBHEAD_S}}': LIBHEAD_S, '{{LIBHEAD_A}}': LIBHEAD_A,
}
out = tpl
for k, v in repl.items():
    out = out.replace(k, v)
assert '{{' not in out, re.findall(r'\{\{[A-Z_]+\}\}', out)
open(OUT, 'w', encoding='utf-8').write(out)
print('wrote', OUT, len(out.encode('utf-8')), 'bytes; data', len(data))
