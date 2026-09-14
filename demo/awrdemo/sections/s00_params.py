"""
Python twin of sql/00_params.sql: the report masthead (header.report),
the verdict line (in-flight z-score recompute), the DB-time strip chart
over the full compared span, the <nav class="toc"> rail and every
client-side chrome <script>.

Walks the SQL's DBMS_OUTPUT.PUT_LINE calls top to bottom.  The literal-
only stretches (the masthead chart IIFE and the whole chrome JS after
the nav) are lifted verbatim from the SQL via awrdemo.chrome.put_lines;
only the dynamic PUT_LINEs are ported by hand.
"""
from __future__ import annotations

from datetime import timedelta

from .. import chrome
from ..helpers import (esc, mean_sd, z_and_pct, ts_min, ts_sec, hh24,
                       to_char_fixed)

SQL_PATH = chrome.sql_path("sql/00_params.sql")
H = timedelta(hours=1)

# ---------------------------------------------------------------------
# Template target lists (sql/lib/templates/comprehensive/*)
# ---------------------------------------------------------------------

LOAD_TARGETS = [
    "redo size", "redo size for lost write detection", "DB time", "DB CPU",
    "CPU used by this session", "session logical reads", "physical reads",
    "physical read total bytes", "physical writes", "physical write total bytes",
    "user calls", "user commits", "user rollbacks", "execute count",
    "parse count (total)", "parse count (hard)", "parse count (failures)",
    "sorts (memory)", "sorts (disk)", "sorts (rows)", "logons cumulative",
    "opened cursors cumulative", "redo writes", "table scans (long tables)",
    "table fetch by rowid", "bytes sent via SQL*Net to client",
    "bytes received via SQL*Net from client",
]

METRIC_TARGETS = [
    "Host CPU Utilization (%)", "Database CPU Time Ratio", "Database Wait Time Ratio",
    "Average Active Sessions", "Average Synchronous Single-Block Read Latency",
    "Physical Reads Per Sec", "Physical Writes Per Sec",
    "Physical Read Total IO Requests Per Sec", "Physical Write Total IO Requests Per Sec",
    "Physical Read Total Bytes Per Sec", "Physical Write Total Bytes Per Sec",
    "Redo Generated Per Sec", "Logons Per Sec", "Logical Reads Per Sec",
    "User Calls Per Sec", "User Commits Per Sec", "User Rollbacks Per Sec",
    "Executions Per Sec", "Hard Parse Count Per Sec", "Total Parse Count Per Sec",
    "Session Count", "Network Traffic Volume Per Sec", "SQL Service Response Time",
]


# ---------------------------------------------------------------------
# Verdict recompute (LOAD / METRIC / WAIT, same shape as 07)
# ---------------------------------------------------------------------

def _window_values(w):
    """{(domain, name): {week_offset: value}} over the VALID windows."""
    out = {}

    def put(dom, name, k, v):
        if v is None:
            return
        out.setdefault((dom, name), {})[k] = v

    for win in w.valid_windows:
        m = w.window_metrics(win)
        if m is None:
            continue
        dur = m.dur_sec
        # LOAD: cross-instance delta / span
        for st in LOAD_TARGETS:
            if st in m.load and dur > 0:
                put("LOAD", st, win.week_offset, m.load[st] / dur)
        # METRIC: AVG(snap_value) over the window's snaps
        for mt in METRIC_TARGETS:
            if mt in m.sysmetric:
                put("METRIC", mt, win.week_offset, m.sysmetric[mt])
        # WAIT: per wait_class (non-Idle), seconds waited per second
        by_cls = {}
        for ev, (wc, cnt, us) in m.fg_waits.items():
            if wc is None or wc == "Idle":
                continue
            by_cls[wc] = by_cls.get(wc, 0.0) + us
        for wc, us in by_cls.items():
            if dur > 0:
                put("WAIT", "Wait class: " + wc, win.week_offset, us / dur / 1e6)
    return out


def scored_rows(w):
    """[(domain, name, z, pct, n_prior)] ORDER BY ABS(NVL(z,0)) DESC, name."""
    rows = []
    for (dom, name), vals in _window_values(w).items():
        cur = vals.get(0)
        priors = [v for k, v in vals.items() if k > 0]
        mu, sd, n = mean_sd(priors)
        if cur is None and mu is None:
            continue
        # Float artifact guard (demo-only): priors that are the SAME value
        # in the synthetic model (e.g. a constant per-read latency) leave a
        # ~1e-16 STDDEV residue in binary floats where Oracle's decimal
        # NUMBER gives exactly 0 (-> flat baseline, z NULL).  Treat a sigma
        # below 1e-9 of |mean| as the 0 it would be on the real DB.
        if sd is not None and mu is not None and sd <= 1e-9 * abs(mu):
            sd = 0.0
        z, pct = z_and_pct(cur, mu, sd)
        if n < 3:
            z = None
        rows.append((dom, name, z, pct, n))
    rows.sort(key=lambda r: (-abs(r[2] or 0.0), r[1]))
    return rows


def _pct_markup(pct):
    """v_pct_cls, v_pct_txt (F5 glyph treatment)."""
    if pct is None:
        return "up", "&mdash;"
    cls = "up" if pct >= 0 else "down"
    txt = ('<span class="g">' + ("&#9650;" if pct >= 0 else "&#9660;") + "</span> "
           + to_char_fixed(abs(pct), 0) + "%")
    return cls, txt


# ---------------------------------------------------------------------
# Masthead DB-time strip
# ---------------------------------------------------------------------

def _put_clob_chunked(s: str) -> list[str]:
    """sql/lib/put_clob_chunked.plsql: 32500-char chunks backed off to the
    last comma so a PUT_LINE newline never splits a token."""
    c = 32500
    out = []
    pos, n = 0, len(s)
    if n == 0:
        return out
    while pos < n:
        take = min(c, n - pos)
        if pos + take < n:
            cut = s[pos:pos + take].rfind(",") + 1
            if cut > 0:
                take = cut
        out.append(s[pos:pos + take])
        pos += take
    return out


def _timeline(w):
    """(times_json, vals_json, windows_json) for AWR_DATA.mastheadTimeline."""
    # windows with both snaps, distinct, same startup_time (raw_windows join)
    wins = []
    for win in w.windows:
        bs, es = w.snap_at(win.win_start_ts), w.snap_at(win.win_end_ts)
        if bs is None or es is None or bs.snap_id == es.snap_id:
            continue
        if bs.dbid != es.dbid or bs.startup_time != es.startup_time:
            continue
        wins.append((win, bs, es))
    if not wins:
        return "[]", "[]", "[]"
    range_start = min(bs.end_ts for _, bs, _ in wins)
    range_end = max(es.end_ts for _, _, es in wins)
    windows_json = "[" + ",".join(
        '["' + ts_min(win.win_start_ts) + '","' + ts_min(win.win_end_ts) + '","'
        + ("current" if win.week_offset == 0 else "w-" + str(win.week_offset)) + '"]'
        for win, _, _ in sorted(wins, key=lambda t: -t[0].week_offset)) + "]"

    # Pass 1 + 2: chronological snaps in (range_start, range_end] whose
    # startup_time matches the previous snap's; per-snap DB time =
    # DB CPU + non-Idle wait deltas (seconds).
    times, vals = [], []
    for m in w.hours(range_start, range_end):
        snap = w.snap_at(m.ts)
        prev = w.snap_at(m.ts - H)
        if snap is None or prev is None or prev.end_ts < range_start:
            continue
        if snap.startup_time != prev.startup_time:
            continue
        us = m.time_model.get("DB CPU", 0.0)
        for ev, (wc, cnt, tw) in m.fg_waits.items():
            if (wc or "x") != "Idle":
                us += tw
        times.append('"' + ts_min(m.ts) + '"')
        vals.append(to_char_fixed(us / 1e6 if us > 0 else 0.0, 3))
    return "[" + ",".join(times) + "]", "[" + ",".join(vals) + "]", windows_json


# ---------------------------------------------------------------------
# Verbatim JS stretches lifted from the SQL
# ---------------------------------------------------------------------

def _lines():
    return chrome.put_lines(SQL_PATH)


def _index(L, text, start=0):
    for i in range(start, len(L)):
        if L[i][0] == text:
            return i
    raise ValueError("anchor not found in 00_params.sql: " + text[:60])


def _literal_slice(L, i, j):
    bad = [k for k in range(i, j + 1) if not L[k][1]]
    if bad:
        raise ValueError(f"00_params.sql PUT_LINE #{bad[:5]} not literal-only")
    return [L[k][0] for k in range(i, j + 1)]


# ---------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------

def emit(w) -> str:
    o = []
    put = o.append
    put("<!-- AWR-SECTION: 00_params BEGIN -->")

    scored = scored_rows(w)
    n_movers = n_usable = 0
    max_n = 0
    top = []
    for r in scored:
        if (r[4] or 0) > max_n:
            max_n = r[4]
        if r[2] is not None:
            n_usable += 1
            if abs(r[2]) > 2:
                n_movers += 1
                if len(top) < 3:
                    top.append(r)

    times_json, vals_json, windows_json = _timeline(w)
    target_end_s = ts_sec(w.target_end)

    # ---- editorial masthead ------------------------------------------
    put('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>')
    put('<header class="report" data-triage="Y">')
    put('  <div class="brandline"><span class="dot">&#9679;</span> AWR <span class="slash">/</span> TIMELINE COMPARISON</div>')
    put('  <div class="topgrid">')
    put('    <h1>' + esc(w.dow_name)
        + ' <em>' + esc(target_end_s[11:16]) + '</em>'
        + '<br>'
        + w.period_unit_long.capitalize() + '-over-' + w.period_unit_long + ' trend'
        + ' <span class="badge info">run ' + w.run_id + '</span>'
        + '</h1>')
    put('    <div class="meta">')
    put('      <div><b>' + esc(w.db_name) + '</b> &middot; DBID ' + str(w.dbid)
        + (' &middot; all DBIDs ' + w.dbid_list.replace(",", ", ") if "," in w.dbid_list else '')
        + '</div>')
    put('      <div>Host <b>' + esc(w.host_name) + '</b> &middot; ' + esc(w.db_version) + '</div>')
    put('      <div>Generated <b>' + w.generated_at + '</b></div>')
    put('      <div>Run by ' + esc(w.caller_user) + ' &middot; read-only, no scratch schema</div>')
    requested_s = ts_sec(w.target_end_requested)
    if requested_s != target_end_s:
        put('      <div>Requested end ' + esc(requested_s[:16])
            + ' had no snapshot within 15 min &mdash; snapped to last snapshot '
            + esc(target_end_s[:16]) + '</div>')
    put('    </div>')
    put('  </div>')

    # ---- verdict -----------------------------------------------------
    plural = lambda n: '' if n == 1 else 's'
    if n_usable == 0:
        put('  <div class="verdict v-skip">')
        put('    <span class="label">Verdict</span>')
        put('    <span class="lede skip">Baseline too short</span> <span class="sep">/</span> '
            '<span class="body">need at least 3 prior valid windows to score; '
            'only %-delta available in <a href="#findings">findings</a>.</span>')
    elif n_movers == 0:
        put('  <div class="verdict v-ok">')
        put('    <span class="label">Verdict</span>')
        put('    <span class="lede ok">Quiet</span> <span class="sep">/</span> '
            '<span class="body">no metric moved beyond |z| &gt; 2 vs the prior '
            + str(max_n) + ' window' + plural(max_n) + '.</span>')
    else:
        put('  <div class="verdict v-crit">')
        put('    <span class="label">Verdict</span>')
        put('    <a href="#findings" class="lede crit">' + str(n_movers) + ' mover'
            + plural(n_movers) + '</a> <span class="sep">/</span> '
            '<span class="body">vs prior ' + str(max_n) + ' window' + plural(max_n) + '</span>')
        for dom, name, z, pct, n in top:
            clean = name[len("Wait class: "):] if name.startswith("Wait class: ") else name
            if len(clean) > 36:
                clean = clean[:34] + "&hellip;"
            cls, txt = _pct_markup(pct)
            # NB: the SQL CONVERTs the already-appended &hellip; -- mirrored
            put('    <span class="mover"><span class="name">' + esc(clean) + '</span>'
                ' <span class="pct ' + cls + '">' + txt + '</span></span>')
    put('  </div>')

    # ---- all movers list --------------------------------------------
    if n_movers > 0:
        put('  <details class="movers-all">')
        put('    <summary>All ' + str(n_movers) + ' mover' + plural(n_movers)
            + ' &middot; |z| &gt; 2</summary>')
        put('    <ul class="movers-list">')
        for dom, name, z, pct, n in scored:
            if z is None or abs(z) <= 2:
                continue
            clean = name[len("Wait class: "):] if name.startswith("Wait class: ") else name
            if len(clean) > 48:
                clean = esc(clean[:46]) + "&hellip;"
            else:
                clean = esc(clean)
            z_txt = to_char_fixed(z, 1, plus=True)
            cls, txt = _pct_markup(pct)
            put('      <li><span class="m-dom">' + dom + '</span>'
                '<span class="m-name">' + clean + '</span>'
                '<span class="m-z">z ' + z_txt + '</span>'
                '<span class="m-pct ' + cls + '">' + txt + '</span></li>')
        put('    </ul>')
        put('  </details>')

    put('  <div id="narrative-slot"></div>')

    # ---- compared windows strip -------------------------------------
    put('  <div class="windows-strip hidetri">')
    put('    <div class="strip-head"><b>Compared windows</b> <span class="strip-meta">'
        + esc(w.dow_name)
        + ' &middot; ' + w.win_label + ' each &middot; every ' + w.step_label
        + ' &middot; DB time (s) over full span'
        + ('' if w.template == 'comprehensive'
           else ' &middot; template: <code>' + w.template + '</code>')
        + (' &middot; day profile: ' + str(w.profile_days) + ' prior days'
           if w.profile_days > 0 else '')
        + '</span></div>')
    put('    <div class="windows-chips">')
    step = timedelta(hours=w.step_hours)
    width = timedelta(hours=w.win_hours)
    for wk in range(w.weeks_back + 1):
        w_end = w.target_end - wk * step
        w_start = w_end - width
        put('      <span class="wchip' + (' cur' if wk == 0 else '')
            + '" data-w="' + str(wk) + '" title="Highlight this window everywhere">'
            + ('<b>current</b>' if wk == 0 else '<b>&minus;' + w.offset_labels[wk - 1] + '</b>')
            + ' <span>' + hh24(w_start) + ' &rarr; ' + hh24(w_end) + '</span></span>')
    put('    </div>')
    put('    <div class="windows-hint">click a window to highlight it everywhere &middot; Esc clears</div>')
    put('    <div class="windows-chart" id="masthead-timeline"></div>')
    put('    <div class="windows-fallback">')
    for wk in range(w.weeks_back + 1):
        w_end = w.target_end - wk * step
        w_start = w_end - width
        put('      <span class="win">'
            + ('<b>current</b> ' if wk == 0 else '<b>&minus;' + w.offset_labels[wk - 1] + '</b> ')
            + ts_min(w_start) + ' &rarr; ' + ts_min(w_end) + '</span>')
    put('    </div>')
    put('  </div>')
    put('</header>')

    # ---- masthead chart script (payload by hand, IIFE verbatim) ------
    L = _lines()
    put('<script>')
    put('(function(){')
    put('AWR_DATA.mastheadTimeline={')
    put('times:')
    o.extend(_put_clob_chunked(times_json))
    put(',')
    put('vals:')
    o.extend(_put_clob_chunked(vals_json))
    put(',')
    put('windows:' + windows_json)
    i_win = _index(L, 'windows:')
    i_end = _index(L, '</script>', i_win)
    o.extend(_literal_slice(L, i_win + 1, i_end))          # '};' .. '</script>'

    # ---- nav rail (hand-ported: profile_days CASE) --------------------
    put('<nav class="toc">'
        '<div class="rail-brand"><span>AWR &middot; Timeline comparison</span>'
        '<button type="button" id="theme-toggle" class="theme-icon-btn"'
        ' aria-pressed="false"'
        ' aria-label="Toggle dark mode"'
        ' title="Switch between light and dark color theme">'
        '<svg class="icon-sun" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">'
        '<circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/>'
        '<path d="M12 2.5v3M12 18.5v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1'
        'M2.5 12h3M18.5 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"'
        ' stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
        '</svg>'
        '<svg class="icon-moon" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">'
        '<path d="M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5a8.5 8.5 0 1 0 11.2 11.2z" fill="currentColor"/>'
        '</svg>'
        '</button>'
        '</div>'
        '<span class="rail-cur"></span>'
        '<button type="button" class="rail-menu-btn" id="rail-menu-btn"'
        ' aria-expanded="false" aria-label="Show section list">&#9776;</button>'
        '<div class="rail-filter">'
        '<input type="text" id="row-filter" autocomplete="off"'
        ' placeholder="Filter rows&#8230;"'
        ' aria-label="Filter table rows across the report">'
        '<span class="kbd">&#8984;K</span>'
        '</div>'
        '<div class="rail-list">'
        '<b>Triage</b>'
        '<a href="#db-time-summary">DB time</a>'
        '<a href="#overview">Overview</a>'
        '<a href="#ash-timeline">ASH timeline</a>'
        '<a href="#findings">Findings</a>'
        '<a href="#windows">Windows</a>'
        '<b>Workload</b>'
        + ('<a href="#day-profile">Day profile</a>' if w.profile_days > 0 else '')
        + '<a href="#utilization">Utilization</a>'
        '<a href="#load">Load profile</a>'
        '<a href="#metrics">Metrics</a>'
        '<a href="#waits-fg">Waits &mdash; foreground</a>'
        '<a href="#waits-bg">Waits &mdash; background</a>'
        '<b>SQL</b>'
        '<a href="#topsql">Top SQL</a>'
        '<a href="#topsql-ash">Top SQL &mdash; ASH</a>'
        '<a href="#sqlmon">SQL Monitor</a>'
        '<b>Storage &amp; config</b>'
        '<a href="#segment-io">Segment I/O</a>'
        '<a href="#file-io">File I/O</a>'
        '<a href="#param-changes">Parameters</a>'
        '</div>'
        '<div class="rail-foot">'
        '<button type="button" id="triage-toggle" class="triage-filter"'
        ' aria-pressed="false"'
        ' title="Collapse the report to the triage-critical sections'
        ' and the verdict">'
        'Triage mode</button>'
        '<button type="button" id="essential-toggle" class="essential-filter"'
        ' aria-pressed="false"'
        ' title="Show only the curated essential rows in the load,'
        ' metric and wait tables; severity-flagged rows stay visible">'
        'Essential rows</button>'
        '<button type="button" id="app-filter-toggle" class="app-filter"'
        ' aria-pressed="false"'
        ' title="Hide system-wide sections and Oracle-internal SQL;'
        ' show only application SQL and its related data">'
        'Application only</button>'
        '<button type="button" id="next-finding" class="next-finding"'
        ' title="Jump to the next large (critical) finding">'
        '<span>&darr; next large finding</span>'
        '<span class="keys">J K</span>'
        '</button>'
        '</div>'
        '</nav>')

    # ---- every chrome <script> after the nav, verbatim -----------------
    i_nav = next(i for i in range(len(L)) if L[i][0].startswith('<nav class="toc">'))
    i_last = len(L) - 1
    assert L[i_last][0] == '<!-- AWR-SECTION: 00_params END -->'
    o.extend(_literal_slice(L, i_nav + 1, i_last - 1))

    put('<!-- AWR-SECTION: 00_params END -->')
    return "\n".join(o)
