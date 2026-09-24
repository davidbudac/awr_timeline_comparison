#!/usr/bin/env python3
"""Build data for Mock B (baseline bands) and inline it into the HTML template.

Reads the real demo numbers (tables.json extracted from docs/examples/demo_busy_db.html,
demo_series.json) and writes design/report_mock_b_baseline_bands.html.
"""
import json, re, statistics as st, os

HERE = os.path.dirname(os.path.abspath(__file__))
SP = os.path.dirname(HERE)
OUT = '/Users/davidbudac/claude_projects/awr_timeline_comparison/design/report_mock_b_baseline_bands.html'

T = json.load(open(os.path.join(HERE, 'tables.json')))
S = json.load(open(os.path.join(SP, 'demo_series.json')))


def num(s):
    """Parse a report-formatted number ('22.24 k', '1,133', '>+99', '0.603')."""
    s = s.replace('−', '-').replace(',', '').strip()
    m = re.match(r'^([-+]?[0-9.]+)\s*([kMG]?)', s)
    if not m:
        return None
    v = float(m.group(1))
    return v * {'': 1, 'k': 1e3, 'M': 1e6, 'G': 1e9}[m.group(2)]


def stats(vals):
    prior = [v for v in vals[:-1] if v is not None]
    n = len(prior)
    mu = st.mean(prior) if n else None
    sd = st.stdev(prior) if n > 1 else None
    return mu, sd, n


def zscore(cur, mu, sd):
    den = max(sd or 0, 0.02 * abs(mu or 0))
    return None if not den else (cur - mu) / den


def r(v, k=6):
    if v is None:
        return None
    if v == 0:
        return 0
    from math import log10, floor
    d = k - int(floor(log10(abs(v)))) - 1
    return round(v, max(d, 0))


def sparkvals(row):
    return [float(x) if x not in ('', 'null') else None for x in row['spark'].split(',')]


# ------------------------------------------------------------------ findings
UNIT_LOAD = {}
for row in T['load-profile']['rows']:
    UNIT_LOAD[row['cells'][0]] = (row['cells'][1], sparkvals(row))
SYSM = {}
for row in T['sysmetric']['rows']:
    SYSM[row['cells'][0]] = (row['cells'][1], sparkvals(row))
WCLS = {c['name']: [v / 3600 for v in c['vals']] for c in S['waitsFgClassPerWindow']['classes']}

FAMILY = {  # name -> (family, lead-friendly label)
    'table scans (long tables)': ('SCANS', 'Table scans (long tables)'),
    'Wait class: Network': ('W_NET', 'Network waits'),
    'physical reads': ('READ_IO', 'Physical reads'),
    'physical read total bytes': ('READ_IO', None),
    'Physical Read Total IO Requests Per Sec': ('READ_IO', None),
    'Physical Reads Per Sec': ('READ_IO', None),
    'Physical Read Total Bytes Per Sec': ('READ_IO', None),
    'Wait class: User I/O': ('W_UIO', 'User I/O waits'),
    'session logical reads': ('LOGICAL_IO', 'Logical reads'),
    'Logical Reads Per Sec': ('LOGICAL_IO', None),
    'Database Wait Time Ratio': ('CPU_WAIT_RATIO', 'Wait time ratio'),
    'Database CPU Time Ratio': ('CPU_WAIT_RATIO', None),
    'SQL Service Response Time': ('RESPONSE', 'SQL service response time'),
    'DB time': ('DB_TIME', 'DB time'),
    'Average Active Sessions': ('DB_TIME', None),
    'Wait class: Commit': ('W_COMMIT', 'Commit waits'),
}
LEADS = {'table scans (long tables)', 'Wait class: Network', 'physical reads', 'Wait class: User I/O',
         'session logical reads', 'Database Wait Time Ratio', 'SQL Service Response Time', 'DB time',
         'Wait class: Commit'}

SHORT_UNIT = {
    'cs/s': 'cs/s', 'bytes/s': 'B/s', '/s': '/s',
    'Sessions': 'sessions', '% Busy/(Idle+Busy)': '%', '% Cpu/DB_Time': '%', '% Wait/DB_Time': '%',
    'Bytes Per Second': 'B/s', 'Requests Per Second': '/s', 'Milliseconds': 'ms', 'Reads Per Second': '/s',
    'Executes Per Second': '/s', 'Calls Per Second': '/s', 'Commits Per Second': '/s',
    'Rollbacks Per Second': '/s', 'Parses Per Second': '/s', 'Logons Per Second': '/s',
    'CentiSeconds Per Call': 'cs/call', 'Writes Per Second': '/s',
}

findings = []
for dom, key in (('load', 'findings-load'), ('metric', 'findings-metric'), ('wait', 'findings-wait')):
    for row in T[key]['rows']:
        c = row['cells']
        bucket = c[0].lower()
        raw = re.sub(r'\s*(twin\s*)?↗ row$', '', c[1]).strip()
        twin = row['twin']
        if dom == 'load':
            unit, vals = UNIT_LOAD[raw]
        elif dom == 'metric':
            unit, vals = SYSM[raw]
        else:
            unit, vals = 'AAS', WCLS[raw.replace('Wait class: ', '')]
        mu, sd, n = stats(vals)
        cur = vals[-1]
        ztxt = c[6]
        imm = 'immaterial' in ztxt
        zt = num(ztxt.replace('>', '')) if '—' not in ztxt else None
        zc = zscore(cur, mu, sd) if mu else None
        sev = {'large': 'large', 'moderate': 'moderate', 'typical': 'typical', 'flat baseline': 'flat'}[bucket]
        fam, lab = FAMILY.get(raw, (None, None))
        f = {
            'name': raw, 'dom': dom, 'unit': SHORT_UNIT.get(unit, unit), 'twin': twin, 'sev': sev, 'imm': imm,
            'z': r(zc if zc is not None else 0, 4) if sev != 'flat' else None,
            'cur': r(cur), 'mu': r(mu), 'sd': r(sd), 'n': n, 'vals': [r(v) for v in vals],
        }
        if ztxt.startswith('>'):
            f['zcap'] = '>+99'
        if fam:
            f['fam'] = fam
        if raw in LEADS:
            f['lead'] = 1
            f['label'] = lab
        if dom == 'wait':
            f['cls'] = raw.replace('Wait class: ', '')
        findings.append(f)

# ------------------------------------------------------------------ headline tiles
headline = []
PRECISE = {'DB time': UNIT_LOAD['DB time'][1], 'Redo generated': UNIT_LOAD['redo size'][1],
           'Logical reads': UNIT_LOAD['session logical reads'][1], 'Average Active Sessions': SYSM['Average Active Sessions'][1],
           'Wait Time Ratio': SYSM['Database Wait Time Ratio'][1], 'Hard parses': UNIT_LOAD['parse count (hard)'][1]}
for c in S['headlineCards']:
    c['vals'] = PRECISE[c['label']]
    c['cur'] = c['vals'][-1]
    mu, sd, n = stats(c['vals'])
    headline.append({'label': c['label'], 'unit': {'bytes/s': 'B/s'}.get(c['unit'], c['unit']), 'cur': r(c['cur']),
                     'z': c['z'], 'sev': c['sev'], 'pct': c['pct'], 'mu': r(mu), 'sd': r(sd),
                     'vals': [r(v) for v in c['vals']]})

# ------------------------------------------------------------------ foreground waits
EVCLS = {
    'db file scattered read': 'User I/O', 'direct path read': 'User I/O', 'db file sequential read': 'User I/O',
    'SQL*Net more data to client': 'Network', 'log file sync': 'Commit',
    'enq: TX - row lock contention': 'Application', 'buffer busy waits': 'Concurrency',
    'db file parallel read': 'User I/O', 'control file sequential read': 'System I/O',
    'latch: cache buffers chains': 'Concurrency', 'library cache: mutex X': 'Concurrency',
    'cursor: pin S wait on X': 'Concurrency', 'direct path read temp': 'User I/O',
    'enq: TX - index contention': 'Concurrency',
}


def waitrows(key, unit):
    out = []
    for row in T[key]['rows']:
        c = row['cells']
        vals = sparkvals(row)
        mu, sd, n = stats(vals)
        bucket = c[-3].lower()
        ztxt = c[-2]
        zc = zscore(vals[-1], mu, sd)
        rank = re.search(r'#(\d+)', c[2])
        o = {'name': c[0], 'cls': EVCLS.get(c[0], 'Other'), 'unit': unit, 'sev': bucket, 'imm': 'immaterial' in ztxt,
             'z': r(zc, 4), 'cur': r(vals[-1]), 'mu': r(mu), 'sd': r(sd), 'n': n, 'vals': [r(v) for v in vals]}
        if rank:
            o['rank'] = int(rank.group(1))
        if ztxt.startswith('>'):
            o['zcap'] = '>+99'
        out.append(o)
    return out


waits = {'time': waitrows('waits-fg-time', 's'), 'avg': waitrows('waits-fg-avg', 'ms'), 'cls': []}
for row in T['waits-fg-class']['rows']:
    c = row['cells']
    vals = [v for v in [x['vals'] for x in S['waitsFgClassPerWindow']['classes'] if x['name'] == c[0]][0]]
    mu, sd, n = stats(vals)
    waits['cls'].append({'name': c[0], 'cls': c[0], 'unit': 's', 'sev': c[-3].lower(), 'imm': 'immaterial' in c[-2],
                         'z': r(zscore(vals[-1], mu, sd), 4), 'cur': r(vals[-1]), 'mu': r(mu), 'sd': r(sd), 'n': n,
                         'vals': [r(v) for v in vals]})

# ------------------------------------------------------------------ top SQL (elapsed)
MODS = {
    '7k2m9dx4qp1zb': ('ORDERS_APP', 'OrderService', 'order-lookup'),
    'n7t3q5xc1yj4g': ('LOYALTY', 'LoyaltyService', 'points-balance'),
    '2yq9jv7c5hm3d': ('ORDERS_APP', 'OrderService', 'checkout'),
    'u9d5p3fw2hs8x': ('ORDERS_APP', 'OrderService', 'search'),
    'f1p7r4mz8vb2c': ('ORDERS_APP', 'OrderService', 'customer-profile'),
    't3h6u1zr9nb8w': ('ORDERS_APP', 'OrderService', 'cart'),
    'b6f4h0kq3ztr8': ('ORDERS_APP', 'OrderService', 'checkout'),
    'j6b1v4nr8xt2p': ('ORDERS_APP', 'OrderService', 'order-lookup'),
    'g3c8w1a2nfy5r': ('ORDERS_APP', 'OrderService', 'checkout'),
    'c7v3m6hq1kf9e': ('ORDERS_APP', 'PaymentGateway', 'authorize'),
}
sql = []
for row in T['topsql-detail-ELAPSED']['rows']:
    c = row['cells']
    sid = c[0].split()[0]
    if sid not in MODS:
        continue
    per = c[2:15]  # Current, -1w .. -12w
    vals = [None if x.startswith('—') else num(x) for x in per][::-1]  # oldest -> current
    ranks = [(int(m.group(1)) if (m := re.search(r'#(\d+)', x)) else None) for x in per][::-1]
    mu, sd, n = stats(vals)
    cur = vals[-1]
    z = zscore(cur, mu, sd)
    pct = (cur - mu) / mu * 100
    if n < 3:
        sev = 'insufficient'
    elif abs(z) <= 2:
        sev = 'typical'
    elif abs(pct) < 15:
        sev = 'typical'
    else:
        sev = ('large' if abs(z) > 3 else 'moderate') if z > 0 else 'improved'
    sch, mod, act = MODS[sid]
    o = {'id': sid, 'schema': sch, 'module': mod, 'action': act, 'plan': c[1], 'text': c[15],
         'cur': r(cur), 'mu': r(mu), 'sd': r(sd), 'n': n, 'z': r(z, 4), 'sev': sev, 'imm': abs(z) > 2 and sev == 'typical',
         'vals': [r(v) for v in vals], 'ranks': ranks, 'unit': 's'}
    if sid == '7k2m9dx4qp1zb':
        o['planchg'] = {'from': '3197245811', 'to': '2088341150', 'since': '2026-09-08 23:00',
                        'phv': [['3197245811', '2026-05-31 23:00', '2026-09-08 23:00', '2,400', '4,975,426,129', '0.002098', '38.12'],
                                ['2088341150', '2026-09-08 23:00', '2026-09-10 10:00', '35', '75,949,092', '0.009', '700.0']]}
    if sid == 'n7t3q5xc1yj4g':
        o['new'] = {'first': '2026-08-11 22:00', 'windows': 5}
    sql.append(o)

# ------------------------------------------------------------------ SQL Monitor
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
sqlmon = []
for sid, user, mod, plan, vals, z, sev, flags in SMON:
    o = {'id': sid, 'user': user, 'module': mod, 'plan': plan, 'sev': sev, 'flags': flags, 'unit': 's'}
    if vals:
        mu, sd, n = stats(vals)
        o.update({'cur': r(vals[-1]), 'mu': r(mu), 'sd': r(sd), 'n': n, 'z': z, 'vals': [r(v) for v in vals]})
    sqlmon.append(o)

# ------------------------------------------------------------------ parameters
params = []
for row in T['param-changes-table']['rows']:
    c = row['cells']
    vals = [x.replace('≠', '').strip() for x in c[1:14]][::-1]  # oldest -> current
    params.append({'name': c[0], 'vals': vals})

# ------------------------------------------------------------------ ASH span (merged to 5 series)
A = S['ashSpan6h']
KEEP = ['CPU', 'User I/O', 'Network', 'Commit']
series = []
for k in KEEP:
    series.append({'name': k, 'vals': [round(v, 2) for v in [c for c in A['classes'] if c['name'] == k][0]['vals']]})
rest = [c for c in A['classes'] if c['name'] not in KEEP]
series.append({'name': 'Other classes', 'members': [c['name'] for c in rest],
               'vals': [round(sum(c['vals'][i] for c in rest), 2) for i in range(len(A['t']))]})
W = S['ashPerWindow']
wtot = [round(sum(c['vals'][i] for c in W['classes']), 2) for i in range(13)]
wcls = {c['name']: c['vals'] for c in W['classes']}
ash = {'t': A['t'], 'series': series, 'win': [w['start'] for w in W['windows']], 'wtot': wtot,
       'wcur': {k: wcls[k][-1] for k in ['CPU', 'User I/O', 'Network', 'Commit']}}

DATA = {
    'weeks': S['windowsWeekLabels'], 'markers': S['markers'], 'findings': findings, 'headline': headline,
    'waits': waits, 'sql': sql, 'sqlmon': sqlmon, 'params': params, 'ash': ash,
}

tpl = open(os.path.join(HERE, 'template.html'), encoding='utf-8').read()
js = json.dumps(DATA, separators=(',', ':'), ensure_ascii=False)
html = tpl.replace('/*__DATA__*/null', js)
open(OUT, 'w', encoding='utf-8').write(html)
print('wrote', OUT, len(html.encode('utf-8')), 'bytes; data', len(js))
for f in findings:
    if f['sev'] != 'typical':
        print(f['sev'], f['name'], f['z'], f['cur'], f['mu'], f.get('fam'))
for s in sql:
    print(s['id'], s['sev'], s['z'], s['cur'], s['mu'], s['n'])
