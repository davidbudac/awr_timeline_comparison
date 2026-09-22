"""Twin of sql/17_narrative.sql: the "What changed" rule-based prose.

Every rule is recomputed from the model exactly as the SQL recomputes it
from DBA_HIST_* ("findings are recomputed, not shared"):
  R1  physical reads moved LARGE -> ratio + top file / segment / newcomer SQL
  R5  DB time moved LARGE up     -> wait-bound vs CPU-bound (time model, us)
  R2  bytes-to-client vs user calls, redo vs commits
  R3  init parameters differing inside the baseline (value at each
      window's END snapshot, prior windows whose value differs from Current)
  R4  skipped prior windows
  R6-R9 SQL Monitor (plan change / DOP downgrade / DONE (ERROR) / new)
Emitted in the order R1, R5, R2, R3, R4, R6, R7, R8, R9; nothing to
say => only the two AWR-SECTION markers.
"""
from __future__ import annotations

import math
import re

from awrdemo.helpers import esc, mean_sd, ora_round, to_char_trim, policy_bucket

_STATS = ['physical reads', 'bytes sent via SQL*Net to client', 'user calls',
          'redo size', 'user commits']
_TM = ['DB time', 'DB CPU']


# ---------------------------------------------------------------------
# Formatting helpers (the PL/SQL local functions)
# ---------------------------------------------------------------------

def fmt3(p) -> str:
    """3 significant digits, FM999G999G999G990D999999 (dot decimal)."""
    if p is None:
        return '&mdash;'
    if p == 0:
        return '0'
    v = ora_round(p, 2 - math.floor(math.log10(abs(p))))
    return to_char_trim(v, 6, group=True)


def dirg(up: bool) -> str:
    return '&#9650;' if up else '&#9660;'


def _off_lbl(w, k: int) -> str:
    return '&minus;' + w.offset_labels[k - 1]


def _tc(n) -> str:
    """TO_CHAR(integer)."""
    return str(int(n))


# ---------------------------------------------------------------------
# Scoring helpers over the stats dict (section 07's rules, recomputed)
# ---------------------------------------------------------------------

class _Stats:
    def __init__(self):
        self.d = {}     # name -> (cur, mu, sd, n)

    def has(self, p):
        r = self.d.get(p)
        return r is not None and r[0] is not None and r[1] is not None

    def pctd(self, p):
        if not self.has(p):
            return None
        cur, mu = self.d[p][0], self.d[p][1]
        if mu == 0:
            return None
        return (cur - mu) / abs(mu) * 100

    def ratio(self, p):
        if not self.has(p):
            return None
        cur, mu = self.d[p][0], self.d[p][1]
        if mu == 0:
            return None
        return cur / mu

    def big(self, p):
        # section 07's bucket through the per-metric policy
        if not self.has(p):
            return False
        cur, mu, sd, n = self.d[p]
        name = p[3:] if p.startswith("TM:") else p
        return policy_bucket("LOAD", name, None, cur, mu, sd, n) == "large"

    def went_up(self, p):
        return self.has(p) and self.d[p][0] >= self.d[p][1]

    def numtxt(self, stat):
        r = self.ratio(stat)
        return dirg(self.went_up(stat)) + ('' if r is None else ' &times;' + fmt3(r))

    def rng(self, stat, unit, scale=1.0):
        cur, mu = self.d[stat][0], self.d[stat][1]
        return fmt3(mu * scale) + ' &rarr; ' + fmt3(cur * scale) + ' ' + unit


def pcttxt(p) -> str:
    return dirg(p >= 0) + ' ' + fmt3(abs(p)) + '%'


def item(label, num, sub, why, href, link) -> str:
    """add_item(): one structured <li> row."""
    return ('<li><span class="n-lbl">' + label + '</span>'
            + ('<span class="n-num">' + num + '</span>' if num else '')
            + ('<span class="n-sub">' + sub + '</span>' if sub else '')
            + ('<span class="n-why">' + why + '</span>' if why else '')
            + ('<a class="n-go" href="' + href + '">' + link + ' &#8599;</a>' if href else '')
            + '</li>')


def _collect_stats(w) -> _Stats:
    st = _Stats()
    series = {}
    for s in _STATS:
        series[s] = w.window_series(
            lambda m, s=s: (m.load.get(s, 0.0) / m.dur_sec) if m.dur_sec > 0 else None)
    for s in _TM:
        series['TM:' + s] = w.window_series(
            lambda m, s=s: (m.time_model.get(s, 0.0) / m.dur_sec) if m.dur_sec > 0 else None)
    for name, vals in series.items():
        cur = vals[0]
        mu, sd, n = mean_sd(vals[1:])
        if cur is None and n == 0:
            continue       # WHERE metric_value IS NOT NULL drops the group
        st.d[name] = (cur, mu, sd, n)
    return st


# ---------------------------------------------------------------------
# R1 detail lookups
# ---------------------------------------------------------------------

def _r1_file(w):
    """Top data/temp file by MB read in the Current window + its prior mean."""
    per_file = {}     # filename -> {offset: read_mb}
    names = {(f.is_temp, f.file_id): f.name for f in w.files}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        for key, v in m.files.items():
            fn = names.get(key)
            if fn is None:
                continue
            read_mb = v[2] * 8192 / 1048576
            per_file.setdefault(fn, {})
            per_file[fn][win.week_offset] = per_file[fn].get(win.week_offset, 0.0) + read_mb
    rows = []
    for fn, d in per_file.items():
        cur = d.get(0)
        prior = [v for k, v in d.items() if k > 0]
        mu = sum(prior) / len(prior) if prior else None
        if cur is not None and cur > 0:
            rows.append((-cur, fn, cur, mu))
    if not rows:
        return None, None, None
    rows.sort()
    _, fn, cur, mu = rows[0]
    return re.sub(r'^.*[/\\]', '', fn), cur, mu


def _r1_segment(w):
    cur = [win for win in w.valid_windows if win.week_offset == 0]
    if not cur:
        return None
    m = w.window_metrics(cur[0])
    agg = {}
    for (owner, name), v in m.seg.items():
        seg_name = (owner or '(unknown)') + '.' + name
        agg[seg_name] = agg.get(seg_name, 0.0) + v[0]
    rows = [(-r, n) for n, r in agg.items() if r > 0]
    if not rows:
        return None
    rows.sort()
    return rows[0][1]


def _r1_newcomer(w):
    top = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        ranked = sorted(((x.reads, sid) for sid, x in m.sql.items() if x.reads > 0),
                        key=lambda t: (-t[0], t[1]))
        top[win.week_offset] = ranked[:w.top_n]
    if 0 not in top:
        return None
    prior_ids = set()
    for k, lst in top.items():
        if k > 0:
            prior_ids.update(sid for _, sid in lst)
    for _, sid in top[0]:
        if sid not in prior_ids:
            return sid
    return None


# ---------------------------------------------------------------------
# R3 parameter drift
# ---------------------------------------------------------------------

def _r3(w):
    wins = [win for win in w.windows if win.end_snap_id is not None]
    n_win = len(wins)
    names = set(w.params_static) | {pc.name for pc in w.param_changes}
    pv = {}   # name -> {offset: value}
    for name in names:
        pv[name] = {win.week_offset: w.param_value(name, win.win_end_ts) for win in wins}
    changed = [n for n, d in pv.items()
               if len({v if v is not None else '__NULL__' for v in d.values()}) > 1
               or len(d) < n_win]
    diff = []
    for name in changed:
        curv = pv[name].get(0)
        offs = sorted(k for k, v in pv[name].items()
                      if k > 0 and (0 not in pv[name]
                                    or (v if v is not None else '__NULL__')
                                    != (curv if curv is not None else '__NULL__')))
        if offs:
            diff.append((name, offs))
    diff.sort(key=lambda t: (-len(t[1]), t[0]))
    return diff


# ---------------------------------------------------------------------
# SQL Monitor helpers (R6-R9)
# ---------------------------------------------------------------------

def _span(w):
    return (min(win.win_start_ts for win in w.windows),
            max(win.win_end_ts for win in w.windows))


def _base_execs(w):
    s0, s1 = _span(w)
    return [m for m in w.monexecs() if s0 <= m.exec_start < s1]


def _cur_win(w):
    for win in w.windows:
        if win.week_offset == 0 and win.valid:
            return win
    return None


def _r6_r9(w):
    base = _base_execs(w)
    cw = _cur_win(w)
    cur = ([m for m in base if cw.win_start_ts <= m.exec_start < cw.win_end_ts]
           if cw else [])
    plans = {}
    for m in base:
        if m.plan_hash != 0:
            plans.setdefault(m.sql_id, set()).add(m.plan_hash)
    cur_ids = {m.sql_id for m in cur}
    plan_ids = sorted(sid for sid, p in plans.items() if len(p) > 1 and sid in cur_ids)
    plan_n = len(plan_ids)
    plan_txt = ', '.join(plan_ids[:3])
    dop_n = len({m.sql_id for m in cur if m.px_alloc < m.px_req})
    err_n = sum(1 for m in cur if m.status == 'DONE (ERROR)')
    new_n, new_txt = 0, ''
    if cw:
        n_cur, n_prior = {}, {}
        for m in base:
            if cw.win_start_ts <= m.exec_start < cw.win_end_ts:
                n_cur[m.sql_id] = n_cur.get(m.sql_id, 0) + 1
            if m.exec_start < cw.win_start_ts:
                n_prior[m.sql_id] = n_prior.get(m.sql_id, 0) + 1
        new_ids = sorted(sid for sid in n_cur if n_prior.get(sid, 0) == 0)
        new_n = len(new_ids)
        new_txt = ', '.join(new_ids[:3])
    return plan_n, plan_txt, dop_n, err_n, new_n, new_txt


# ---------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------

def emit(w) -> str:
    sent = []
    st = _collect_stats(w)

    # R1
    if st.big('physical reads'):
        v_file, v_file_cur, v_file_mu = _r1_file(w)
        v_seg = _r1_segment(w)
        v_sqlid = _r1_newcomer(w)
        tail = ''
        if v_file is not None:
            tail = ('file <a href="#file-io">' + esc(v_file) + '</a> '
                    + ('' if v_file_mu is None else fmt3(v_file_mu) + ' &rarr; ')
                    + fmt3(v_file_cur) + ' MB')
        if v_seg is not None:
            tail += ('' if tail == '' else ' &middot; ') + 'segment <a href="#segment-io">' + esc(v_seg) + '</a>'
        if v_sqlid is not None:
            tail += (('' if tail == '' else ' &middot; ') + 'new in top-' + _tc(w.top_n)
                     + ': <a href="#sql-' + v_sqlid + '"><code>' + v_sqlid + '</code></a>')
        sent.append(item('Physical reads', st.numtxt('physical reads'), st.rng('physical reads', '/s'),
                         tail, '#file-io', 'File I/O'))

    # R5
    if st.big('TM:DB time') and st.went_up('TM:DB time') and st.has('TM:DB CPU'):
        pc = st.pctd('TM:DB CPU')
        txt = ''
        if pc is not None and abs(pc) < 20:
            txt = 'DB CPU only ' + pcttxt(pc) + ': the extra time is wait, not CPU'
        elif pc is not None:
            txt = 'DB CPU ' + pcttxt(pc) + ' with it: CPU-bound'
        sent.append(item('DB time', st.numtxt('TM:DB time'), st.rng('TM:DB time', 'AAS', 1 / 1000000),
                         txt, '#waits-fg', 'Foreground waits'))

    # R2
    pb_, pu = st.pctd('bytes sent via SQL*Net to client'), st.pctd('user calls')
    if pb_ is not None and abs(pb_) >= 10 and pu is not None and abs(pu) <= 3:
        sent.append(item('Bytes to client', pcttxt(pb_), 'user calls ' + pcttxt(pu),
                         'payload per call ' + ('grew' if pb_ >= 0 else 'shrank') + ', not call volume',
                         '#load', 'Load profile'))
    pr, pcm = st.pctd('redo size'), st.pctd('user commits')
    if pr is not None and abs(pr) >= 20 and pcm is not None and abs(pcm) <= 5:
        sent.append(item('Redo', pcttxt(pr), 'commits ' + pcttxt(pcm),
                         'redo per commit ' + ('grew' if pr >= 0 else 'shrank') + ': transaction size, not count',
                         '#load', 'Load profile'))

    # R3
    diff = _r3(w)
    if diff:
        total = len(diff)
        shown = diff[:3]
        names = ''
        for i, (name, offs) in enumerate(shown):
            contig = all(b == a + 1 for a, b in zip(offs, offs[1:]))
            if len(offs) == w.weeks_back and contig:
                acc = 'every prior window'
            elif contig and len(offs) >= 3:
                acc = _off_lbl(w, offs[0]) + ' to ' + _off_lbl(w, offs[-1])
            else:
                acc = ', '.join(_off_lbl(w, k) for k in offs)
            names += ('' if i == 0 else '; ') + '<code>' + esc(name) + '</code> in ' + acc
        sent.append(item('Configuration',
                         _tc(total) + ' parameter' + ('' if total == 1 else 's') + ' differ' + ('s' if total == 1 else ''),
                         None,
                         names + (' (+' + _tc(total - len(shown)) + ' more)' if total > len(shown) else ''),
                         '#param-changes', 'Parameters'))

    # R4
    prior = [win for win in w.windows if win.week_offset > 0]
    bad = [win for win in prior if not win.valid]
    if bad:
        cnt = {}
        for win in bad:
            cnt[win.skip_reason] = cnt.get(win.skip_reason, 0) + 1
        reason = sorted(cnt.items(), key=lambda t: (-t[1], t[0] or ''))[0][0]
        n_all = len(prior)
        sent.append(item('Baseline',
                         _tc(len(bad)) + ' of ' + _tc(n_all) + ' prior window' + ('' if n_all == 1 else 's') + ' skipped',
                         None, 'thin prior-window set' if reason is None else esc(reason),
                         '#windows', 'Windows'))

    # R6-R9
    plan_n, plan_ids, dop_n, err_n, new_n, new_ids = _r6_r9(w)
    if plan_n > 0:
        sent.append(item('Plan change', _tc(plan_n) + ' statement' + ('' if plan_n == 1 else 's'), None,
                         '<code>' + esc(plan_ids) + '</code>'
                         + (' (+' + _tc(plan_n - 3) + ' more)' if plan_n > 3 else '')
                         + ' ran with more than one plan, including now',
                         '#sqlmon', 'SQL Monitor'))
    if dop_n > 0:
        sent.append(item('DOP downgrade', _tc(dop_n) + ' statement' + ('' if dop_n == 1 else 's'), None,
                         'fewer parallel servers than requested in the Current window',
                         '#sqlmon', 'SQL Monitor'))
    if err_n > 0:
        sent.append(item('Errors', _tc(err_n) + ' execution' + ('' if err_n == 1 else 's'), None,
                         'ended <code>DONE (ERROR)</code> in the Current window',
                         '#sqlmon', 'SQL Monitor'))
    if new_n > 0:
        sent.append(item('New SQL', _tc(new_n) + ' SQL ID' + ('' if new_n == 1 else 's'), None,
                         '<code>' + esc(new_ids) + '</code>'
                         + (' (+' + _tc(new_n - 3) + ' more)' if new_n > 3 else '')
                         + ' first seen in SQL Monitor this window',
                         '#sqlmon', 'SQL Monitor'))

    out = ['<!-- AWR-SECTION: 17_narrative BEGIN -->']
    if sent:
        out.append('<div id="narrative-src" class="narr" hidden>'
                   '<div class="narr-head">What changed</div><ul class="narr-list">')
        for s in sent:
            out.append(s)
        out.append('</ul></div>')
        out.append('<script>(function(){'
                   'var s=document.getElementById("narrative-slot"),'
                   'n=document.getElementById("narrative-src");'
                   'if(s&&n){s.appendChild(n);n.hidden=false;}'
                   '})();</script>')
    out.append('<!-- AWR-SECTION: 17_narrative END -->')
    return '\n'.join(out)
