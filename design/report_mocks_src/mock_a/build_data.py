#!/usr/bin/env python3
"""Build the compact JSON payload for mock A from the demo dumps."""
import json, re, statistics as st, os

SP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
dump = open(os.path.join(SP, 'demo_data_dump.txt')).read().split('\n')
ser = json.load(open(os.path.join(SP, 'demo_series.json')))
pool = {p['id']: p for p in json.load(open(os.path.join(SP, 'pool.json')))}

MULT = {'k': 1e3, 'M': 1e6, 'G': 1e9}


def num(s):
    s = s.strip()
    m = re.match(r'^(-?[\d,]*\.?\d+)\s*([kMG])?', s)
    if not m:
        return None
    v = float(m.group(1).replace(',', ''))
    return v * MULT.get(m.group(2) or '', 1)


def r(x, n=4):
    if x is None:
        return None
    if x == 0:
        return 0
    from math import log10, floor
    d = n - 1 - floor(log10(abs(x)))
    return round(x, max(d, 0))


def stats(vals):
    pri = [v for v in vals[:-1] if v is not None]
    mu = st.mean(pri)
    sd = st.stdev(pri) if len(pri) > 1 else 0
    return dict(mu=r(mu), sd=r(sd), lo=r(min(pri)), hi=r(max(pri)), n=len(pri))


def spark(line):
    m = re.search(r'\{spark:([^}]*)\}', line)
    return [r(float(x)) for x in m.group(1).split(',')] if m else None


def section(name):
    s = [i for i, l in enumerate(dump) if l.startswith('## SECTION #' + name + ' ')][0]
    e = s + 1
    while e < len(dump) and not dump[e].startswith('## SECTION'):
        e += 1
    return dump[s:e]


# ---------- top SQL per dimension (13 vals oldest->current) ----------
def topsql(dim):
    sec = section('topsql')
    s = [i for i, l in enumerate(sec) if ('#topsql-detail-' + dim + ' ') in l][0]
    rows = []
    for l in sec[s + 2:]:
        if l.startswith('###'):
            break
        c = [x.strip() for x in l.split(' | ')]
        sid = c[0][:13]
        flag = 'plan↑' in c[0]
        cells = c[2:15]  # Current, -1w .. -12w
        vals = []
        ranks = []
        for x in cells:
            if x.startswith('—'):
                vals.append(None); ranks.append(None)
            else:
                vals.append(r(num(x)))
                m = re.search(r'#(\d+)', x)
                ranks.append(int(m.group(1)) if m else None)
        vals = vals[::-1]; ranks = ranks[::-1]
        p = pool.get(sid, {})
        text = c[15] if len(c) > 15 else ''
        rows.append(dict(id=sid, plan=c[1], planChg=flag, vals=vals, rank=ranks[-1],
                         schema=p.get('schema'), module=p.get('module'), action=p.get('action'),
                         first=p.get('first'), text=text[:140]))
    return rows


TOPSQL = {d: topsql(d) for d in ['ELAPSED', 'CPU', 'GETS', 'PREADS']}

# ---------- foreground waits ----------
WCLASS = {
    'db file scattered read': 'User I/O', 'direct path read': 'User I/O', 'db file sequential read': 'User I/O',
    'SQL*Net more data to client': 'Network', 'log file sync': 'Commit',
    'enq: TX - row lock contention': 'Application', 'buffer busy waits': 'Concurrency',
    'db file parallel read': 'User I/O', 'control file sequential read': 'System I/O',
    'latch: cache buffers chains': 'Concurrency', 'library cache: mutex X': 'Concurrency',
    'cursor: pin S wait on X': 'Concurrency', 'direct path read temp': 'User I/O',
    'enq: TX - index contention': 'Concurrency'}


def table_sparks(sec, tid):
    s = [i for i, l in enumerate(sec) if ('#' + tid + ' ') in l][0]
    out = {}
    for l in sec[s + 2:]:
        if l.startswith('###') or not l.strip():
            break
        c = [x.strip() for x in l.split(' | ')]
        out[c[0]] = spark(l)
    return out


fg = section('waits-fg')
fg_time = table_sparks(fg, 'waits-fg-time')
fg_avg = table_sparks(fg, 'waits-fg-avg')
tot_cur = sum(v[-1] for v in fg_time.values())
FG = []
for ev, vals in fg_time.items():
    s = stats(vals)
    cur = vals[-1]
    z = (cur - s['mu']) / max(s['sd'], 0.02 * abs(s['mu']))
    pct = (cur - s['mu']) / s['mu'] * 100
    share = cur / tot_cur
    sev = 'typical'
    if abs(z) > 2 and abs(pct) >= 10:
        sev = 'large' if abs(z) > 3 and pct > 100 else 'moderate'
        if share < 0.05:
            sev = 'floor'
    a = fg_avg.get(ev)
    FG.append(dict(ev=ev, cls=WCLASS.get(ev, 'Other'), vals=vals, **s, z=round(z, 1), pct=round(pct, 1),
                   share=round(share, 3), sev=sev, avg=a, avgMu=r(st.mean(a[:-1])) if a else None))

# ---------- load profile / sysmetric / utilization sparks ----------
lp = table_sparks(section('load'), 'load-profile')
sm = table_sparks(section('metrics'), 'sysmetric')
ut = {}
for tid in ['util-transactions', 'util-connections', 'util-data']:
    ut.update(table_sparks(section('utilization'), tid))

NORMAL = [
    # label, source dict, key, unit, fmt
    ('DB CPU', lp, 'DB CPU', 'cs/s'),
    ('Host CPU', sm, 'Host CPU Utilization (%)', '%'),
    ('Executions', lp, 'execute count', '/s'),
    ('User calls', lp, 'user calls', '/s'),
    ('User commits', lp, 'user commits', '/s'),
    ('User rollbacks', lp, 'user rollbacks', '/s'),
    ('Redo generated', lp, 'redo size', 'B/s'),
    ('Redo writes', lp, 'redo writes', '/s'),
    ('Physical writes', lp, 'physical writes', '/s'),
    ('Write volume', lp, 'physical write total bytes', 'B/s'),
    ('Hard parses', lp, 'parse count (hard)', '/s'),
    ('Parses (total)', lp, 'parse count (total)', '/s'),
    ('Sessions', sm, 'Session Count', ''),
    ('Logons', lp, 'logons cumulative', '/s'),
    ('Rowid fetches', lp, 'table fetch by rowid', '/s'),
    ('Sorts (disk)', lp, 'sorts (disk)', '/s'),
    ('Bytes from clients', lp, 'bytes received via SQL*Net from client', 'B/s'),
    ('Network volume', sm, 'Network Traffic Volume Per Sec', 'B/s'),
]
NORM = []
for lab, src, key, unit in NORMAL:
    v = src[key]
    s = stats(v)
    NORM.append(dict(label=lab, unit=unit, vals=v, cur=v[-1], **s,
                     pct=round((v[-1] - s['mu']) / s['mu'] * 100, 1)))

# ---------- finding series ----------
ash = ser['ashPerWindow']
ashc = {c['name']: c['vals'] for c in ash['classes']}


def fs(vals, **kw):
    d = dict(vals=[r(v) for v in vals], cur=r(vals[-1]), **stats(vals))
    d['x'] = round(vals[-1] / d['mu'], 1)
    d.update(kw)
    return d


pr = lp['physical reads']
FIND = {
    'phys': fs(pr),
    'dbt': fs(sm['Average Active Sessions']),
    'net': fs(ashc['Network']),
    'commit': fs(ashc['Commit']),
    'plan': fs([6873, 6392, 6356, 6080, 6523, 6669, 6243, 6397, 6896, 7637, 7227, 6730, 27920]),
    'planMon': fs([1.750, 1.454, 1.188, 1.342, 1.806, 1.265, 1.327, 1.905, 1.251, 1.660, 1.882, 1.201, 8.016]),
    'dbTimeStrip': [r(x) for x in sm['Average Active Sessions']],
}
REL = {
    'tsl': fs(lp['table scans (long tables)']),
    'prb': fs(lp['physical read total bytes']),
    'prio': fs(sm['Physical Read Total IO Requests Per Sec']),
    'lr': fs(lp['session logical reads']),
    'uio': fs(ashc['User I/O']),
    'wtr': fs(sm['Database Wait Time Ratio']),
    'cpur': fs(sm['Database CPU Time Ratio']),
    'srt': fs(sm['SQL Service Response Time']),
    'dbcpu': fs(lp['DB CPU']),
    'lfs': fs(fg_time['log file sync']),
    'sqlnet': fs(fg_time['SQL*Net more data to client']),
    'scat': fs(fg_time['db file scattered read']),
    'dpr': fs(fg_time['direct path read']),
    'commits': fs(lp['user commits']),
}

# ASH span, rounded to 2 decimals and classes grouped
a6 = ser['ashSpan6h']
keep = ['CPU', 'User I/O', 'Commit', 'Network']
grp = {c['name']: c['vals'] for c in a6['classes']}
other = [round(sum(grp[k][i] for k in grp if k not in keep), 2) for i in range(len(a6['t']))]
ASH = dict(t0=a6['t'][0], stepH=6, classes=[{'name': k, 'vals': [round(v, 2) for v in grp[k]]} for k in keep]
           + [{'name': 'Other', 'vals': other}])

OUT = dict(weeks=ser['windowsWeekLabels'], markers=ser['markers'], find=FIND, rel=REL,
           ashWin=dict(classes=ash['classes']), fg=FG, norm=NORM, topsql=TOPSQL, ash=ASH)
json.dump(OUT, open(os.path.join(SP, 'mock_a', 'data.json'), 'w'), separators=(',', ':'))
print(len(json.dumps(OUT, separators=(',', ':'))))
for k, v in FIND.items():
    if isinstance(v, dict):
        print(k, {kk: vv for kk, vv in v.items() if kk != 'vals'})
for k, v in REL.items():
    print(k, {kk: vv for kk, vv in v.items() if kk != 'vals'})
for f in FG:
    print(f['ev'], f['sev'], f['z'], f['pct'], f['share'], f['mu'], f['avg'][-1] if f['avg'] else None, f['avgMu'])
for n in NORM:
    print(n['label'], n['cur'], n['mu'], n['pct'])
