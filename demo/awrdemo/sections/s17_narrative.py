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

from awrdemo import chrome
from awrdemo import helpers as h
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


def item(label, num, sub, why, href, link, dup=None) -> str:
    """add_item(): one calm line for the verdict hero."""
    return ('<li' + (' data-dup="' + dup + '"' if dup else '') + '><span class="hl">' + label + '</span>'
            + ('<span class="hn">' + num + '</span>' if num else '')
            + ('<span class="hs">' + sub + '</span>' if sub else '')
            + ('<span class="hw">' + why + '</span>' if why else '')
            + ('<a class="go" href="' + href + '">' + link + ' &rarr;</a>' if href else '')
            + '</li>')


def pill(href, n, txt, title=None) -> str:
    return ('<li><a href="' + href + '"' + (' title="' + title + '"' if title else '')
            + '><b>' + str(n) + '</b> ' + txt + '</a></li>')


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
    """Top segment by Current physical reads + its mean over the prior
    windows it appears in -> (name, cur, mu)."""
    per = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        for (owner, name), v in m.seg.items():
            seg_name = (owner or '(unknown)') + '.' + name
            d = per.setdefault(seg_name, {})
            d[win.week_offset] = d.get(win.week_offset, 0.0) + v[0]
    rows = []
    for n, d in per.items():
        cur = d.get(0)
        prior = {k: v for k, v in d.items() if k > 0}
        mu = sum(prior.values()) / len(prior) if prior else None
        if cur is not None and cur > 0:
            rows.append((-cur, n, cur, mu))
    if not rows:
        return None, None, None
    rows.sort()
    return rows[0][1], rows[0][2], rows[0][3]


def _r1_newcomer(w):
    top = {}
    for win in w.valid_windows:
        m = w.window_metrics(win)
        ranked = sorted(((x.reads, sid) for sid, x in m.sql.items() if x.reads > 0),
                        key=lambda t: (-t[0], t[1]))
        top[win.week_offset] = ranked[:w.top_n]
    if 0 not in top:
        return None, None
    prior_ids = set()
    for k, lst in top.items():
        if k > 0:
            prior_ids.update(sid for _, sid in lst)
    for rd, sid in top[0]:
        if sid not in prior_ids:
            return sid, rd
    return None, None


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
    pills, because, ev_io, vx_io = '', None, '', None
    v_seg = v_file = v_sqlid = None
    big_pr = False
    if st.big('physical reads'):
        big_pr = True
        v_file, v_file_cur, v_file_mu = _r1_file(w)
        v_seg, v_seg_cur, v_seg_mu = _r1_segment(w)
        v_sqlid, v_sql_rd = _r1_newcomer(w)
        tail = ''
        if v_file is not None:
            tail = ('file ' + h.ent(esc(v_file), h.anchor_id('fl', v_file), 'file') + ' '
                    + ('' if v_file_mu is None else fmt3(v_file_mu) + ' &rarr; ')
                    + fmt3(v_file_cur) + ' MB')
        if v_seg is not None:
            tail += (('' if tail == '' else ' &middot; ') + 'segment '
                     + h.ent(esc(v_seg), h.anchor_id('sg', v_seg), 'segment'))
        if v_sqlid is not None:
            tail += (('' if tail == '' else ' &middot; ') + 'new in top-' + _tc(w.top_n) + ': '
                     + h.ent('<code>' + v_sqlid + '</code>', h.anchor_id('sq-preads', v_sqlid), 'sql'))
        sent.append(item('Physical reads', st.numtxt('physical reads'), st.rng('physical reads', '/s'),
                         tail, '#file-io', 'File I/O', 'f-io'))
        if v_seg is not None:
            ev_io += ('<div class="evr"><dt>Segment</dt><dd><span class="id">'
                      + h.ent(esc(v_seg), h.anchor_id('sg', v_seg), 'segment') + '</span><span class="de">'
                      + h.fmt_num(v_seg_cur) + ' blocks read'
                      + (', normal ' + h.fmt_num(v_seg_mu) if v_seg_mu is not None else '')
                      + '</span></dd><div class="m" title="Ranked, not scored">'
                      + h.delta_span(v_seg_cur, v_seg_mu, None, 'Y') + '<span class="ns">not scored</span></div></div>')
            vx_io = (', most of it on '
                     + h.ent('<code>' + esc(v_seg) + '</code>', h.anchor_id('sg', v_seg), 'segment'))
        if v_file is not None:
            ev_io += ('<div class="evr"><dt>File</dt><dd><span class="id">'
                      + h.ent(esc(v_file), h.anchor_id('fl', v_file), 'file') + '</span><span class="de">'
                      + h.fmt_num(v_file_cur) + ' MB read'
                      + (', normal ' + h.fmt_num(v_file_mu) if v_file_mu is not None else '')
                      + '</span></dd><div class="m" title="Ranked, not scored">'
                      + h.delta_span(v_file_cur, v_file_mu, None, 'Y') + '<span class="ns">not scored</span></div></div>')
        if v_sqlid is not None:
            ev_io += ('<div class="evr"><dt>SQL</dt><dd><span class="id">'
                      + h.ent(v_sqlid, h.anchor_id('sq-preads', v_sqlid), 'sql') + '</span><span class="de">'
                      + h.fmt_num(v_sql_rd) + ' blocks read; new in the top ' + _tc(w.top_n)
                      + '</span></dd><div class="m"><span class="d s-plain">&#10010; new</span></div></div>')

    # R5: retired (the verdict and the DB time card carry it)

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
                         '#param-changes', 'Parameters', 'f-config'))
        pills += pill('#f-config', total, 'parameter' + (' differs' if total == 1 else 's differ'))

    # R4
    prior = [win for win in w.windows if win.week_offset > 0]
    bad = [win for win in prior if not win.valid]
    if bad:
        cnt = {}
        for win in bad:
            cnt[win.skip_reason] = cnt.get(win.skip_reason, 0) + 1
        reason = sorted(cnt.items(), key=lambda t: (-t[1], t[0] or ''))[0][0]
        n_all = len(prior)
        pills += pill('#windows', len(bad), 'of ' + _tc(n_all) + ' prior window' + ('' if n_all == 1 else 's')
                      + ' skipped', esc(reason) if reason is not None else None)

    # R6-R9
    plan_n, plan_ids, dop_n, err_n, new_n, new_ids = _r6_r9(w)
    first_plan = plan_ids.split(', ')[0] if plan_ids else None
    if plan_n > 0:
        pills = pill('#sm-' + first_plan, plan_n, 'plan change' + ('' if plan_n == 1 else 's'),
                     'ran with more than one plan, including in the Current window: ' + esc(plan_ids)
                     + (' (+' + _tc(plan_n - 3) + ' more)' if plan_n > 3 else '')) + pills
    if new_n > 0:
        pills += pill('#sqlmon', new_n, 'new SQL',
                      'first seen in SQL Monitor this window: ' + esc(new_ids)
                      + (' (+' + _tc(new_n - 3) + ' more)' if new_n > 3 else ''))
    if dop_n > 0:
        pills += pill('#sqlmon', dop_n, 'DOP downgrade' + ('' if dop_n == 1 else 's'),
                      'fewer parallel servers than requested in the Current window')
    if err_n > 0:
        pills += pill('#sqlmon', err_n, 'SQL error' + ('' if err_n == 1 else 's'),
                      'executions that ended DONE (ERROR) in the Current window')

    # the likely-source line
    if plan_n > 0:
        because = (h.ent('<code>' + esc(first_plan) + '</code>', 'sm-' + first_plan, 'sql')
                   + ' ran with a new plan in the Current window'
                   + '<span data-mk-at="0" data-mk-pre=", after " hidden></span>'
                   + (', and is new in the top ' + _tc(w.top_n) + ' by physical reads'
                      if v_sqlid == first_plan else ''))
    elif v_sqlid is not None:
        because = (h.ent('<code>' + v_sqlid + '</code>', h.anchor_id('sq-preads', v_sqlid), 'sql')
                   + ', new in the top ' + _tc(w.top_n) + ' by physical reads (' + h.fmt_num(v_sql_rd)
                   + ' blocks)'
                   + ('; most reads land on ' + h.ent('<code>' + esc(v_seg) + '</code>',
                                                     h.anchor_id('sg', v_seg), 'segment') if v_seg else ''))
    elif new_n > 0:
        because = ('<code>' + esc(new_ids.split(', ')[0]) + '</code>'
                   + ', first seen in SQL Monitor in the Current window')
    elif big_pr and v_seg is not None:
        because = ('the reads land on ' + h.ent('<code>' + esc(v_seg) + '</code>', h.anchor_id('sg', v_seg), 'segment')
                   + (' (file ' + h.ent(esc(v_file), h.anchor_id('fl', v_file), 'file') + ')' if v_file else ''))

    out = ['<!-- AWR-SECTION: 17_narrative BEGIN -->']
    if sent or pills or because or ev_io:
        out.append('<div id="narr-src" hidden>')
        if because:
            out.append('<p class="because-src"><span class="bl">Likely source:</span> ' + because + '.</p>')
        if pills:
            out.append('<ul class="pills-src">' + pills + '</ul>')
        if sent:
            out.append('<ul class="notes-src">')
            out.extend(sent)
            out.append('</ul>')
        if vx_io:
            out.append('<span data-vx-src="io">' + vx_io + '</span>')
        if ev_io:
            out.append('<div data-ev-for="f-io">' + ev_io + '</div>')
        out.append('</div>')
        # the relocation script, lifted verbatim from the SQL
        L = chrome.put_lines(chrome.sql_path("sql/17_narrative.sql"))
        i = next(k for k, (t, _) in enumerate(L) if t.startswith('<script>(function(){var d=document,src='))
        j = next(k for k in range(i, len(L)) if L[k][0].endswith('})();</script>'))
        assert all(ok for _, ok in L[i:j + 1])
        out.extend(t for t, _ in L[i:j + 1])
    out.append('<!-- AWR-SECTION: 17_narrative END -->')
    return '\n'.join(out)
