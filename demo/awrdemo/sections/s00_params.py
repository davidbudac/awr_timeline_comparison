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
from .. import helpers as h
from ..helpers import (esc, mean_sd, z_and_pct, ts_min, ts_sec, hh24, dy, mon_dd,
                       to_char_fixed, finding_family, is_canonical, policy_bucket,
                       day_name, wg_attr, wg_ruler)

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
    """The PL/SQL v_scored collection, ORDER BY ABS(NVL(z,0)) DESC, name:
    dicts with domain / name / z / pct / n / bucket / family / canonical /
    cur / mu / sd (bucket from the per-metric policy for every row)."""
    rows = []
    allv = _window_values(w)
    wait_tot = sum(v.get(0, 0.0) for (d, _n), v in allv.items() if d == "WAIT")
    for (dom, name), vals in allv.items():
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
        share = (cur / wait_tot) if (dom == "WAIT" and wait_tot > 0 and cur is not None) else None
        # the PL/SQL pass: per-metric policy (sql/lib/metric_policy.plsql)
        bucket = policy_bucket(dom, name, None, cur, mu, sd, n, share)
        rows.append(dict(domain=dom, name=name, z=z, pct=pct, n=n, bucket=bucket,
                         family=finding_family(dom, name), canonical=is_canonical(dom, name),
                         cur=cur, mu=mu, sd=sd))
    rows.sort(key=lambda r: (-abs(r["z"] or 0.0), r["name"]))
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

def _verdict_state(w, scored):
    """The PL/SQL single pass + card order: counts and the card groups."""
    st = dict(n_moved=0, n_impr=0, n_normal=0, n_usable=0, max_n=0, dbt=None, cpu=None)
    lead, gsev, gz = {}, {}, {}
    for i, r in enumerate(scored):
        if (r["n"] or 0) > st["max_n"]:
            st["max_n"] = r["n"]
        if r["domain"] == "LOAD" and r["name"] == "DB time":
            st["dbt"] = r
        elif r["domain"] == "LOAD" and r["name"] == "DB CPU":
            st["cpu"] = r
        if r["z"] is not None:
            st["n_usable"] += 1
        if r["canonical"] != "Y":
            continue
        if r["bucket"] in ("large", "moderate"):
            st["n_moved"] += 1
            g = h.card_group(r["family"])
            if g not in lead:
                lead[g], gsev[g], gz[g] = r, 0, 0
            elif h.lead_better(g, r["bucket"], r["family"], r["z"],
                               lead[g]["bucket"], lead[g]["family"], lead[g]["z"],
                               h.metric_label(r["domain"], r["name"]),
                               h.metric_label(lead[g]["domain"], lead[g]["name"])):
                lead[g] = r
            gsev[g] = max(gsev[g], h.sev_rank(r["bucket"]))
            gz[g] = max(gz[g], abs(r["z"] or 0))
        elif r["bucket"] in ("typical", "improved", "noted", "flat baseline"):
            st["n_normal"] += 1
            if r["bucket"] == "improved":
                st["n_impr"] += 1
    st["order"] = h.card_order({g: (gsev[g], gz[g]) for g in lead})
    st["lead"] = lead
    return st


def _win_json(w) -> str:
    """window.AWR_WIN (00_params.sql v_win_json)."""
    out = []
    for k in range(w.weeks_back, -1, -1):
        s0, e0 = h._wg_start(w, k), h._wg_end(w, k)
        win = w.windows[k]
        out.append('{"o":' + str(k) + ',"d":"' + h.wg_date(w, k) + '"'
                   + ',"l":"' + ("current" if k == 0 else "-" + w.offset_labels[k - 1]) + '"'
                   + ',"s":"' + ts_min(s0) + '","e":"' + ts_min(e0) + '"'
                   + ',"t":"' + dy(s0) + " " + s0.strftime("%d") + " " + mon_dd(s0)[:3] + ", "
                   + hh24(s0) + "-" + hh24(e0) + '"'
                   + ',"v":"' + ("Y" if win.valid else "N") + '"}')
    return '{"np":' + str(w.weeks_back) + ',"w":[' + ",".join(out) + "]}"


def _hero(w, st) -> list[str]:
    o = []
    put = o.append
    order = st["order"]
    put('<section id="verdict" class="vw in-s hero" aria-label="Verdict">')
    if st["n_usable"] == 0:
        n_valid = sum(1 for x in w.windows if x.week_offset > 0 and x.valid)
        put('<h1 class="verdict quiet">Too little history to score this window.</h1>')
        put('<p class="because">Scoring needs at least 3 valid prior windows; ' + str(n_valid) + ' of '
            + str(w.weeks_back) + ' ' + ('is' if n_valid == 1 else 'are')
            + ' valid here (<a href="#windows">Windows</a>). The values are still listed in '
            '<a href="#findings">Findings</a>.</p>')
    elif not order:
        put('<h1 class="verdict quiet">Nothing moved beyond its normal range.</h1>')
        put('<p class="because">All ' + str(st["n_normal"]) + ' scored metrics sit within their normal range '
            'over the prior ' + str(st["max_n"]) + ' window' + ('' if st["max_n"] == 1 else 's')
            + ('; ' + str(st["n_impr"]) + ' improved' if st["n_impr"] > 0 else '') + '.</p>')
    else:
        v = ""
        for k, g in enumerate(order[:2]):
            r = st["lead"][g]
            v += ("; " if k else "") + h.ent(esc(h.metric_label(r["domain"], r["name"])),
                                          h.finding_anchor(r["domain"], r["name"]), "metric")
            v += " " + h.move_txt(r["cur"], r["mu"], r["bucket"])
            if g == "DBTIME" and r["name"] == "DB time" and st["dbt"] and st["cpu"]:
                sp = h.time_split(st["dbt"]["cur"], st["dbt"]["mu"], st["cpu"]["cur"], st["cpu"]["mu"])
                v += {"W": ", all wait", "w": ", mostly wait", "c": ", mostly CPU",
                      "m": ", CPU and wait alike"}.get(sp, "")
            if g == "IO":
                v += '<span class="vx" data-vx="io" hidden></span>'
        put('<h1 class="verdict">' + v + '.</h1>')
    put('<p class="because" id="because-slot" hidden></p>')
    nm, nn, ni = st["n_moved"], st["n_normal"], st["n_impr"]
    put('<ul class="pills" id="pills" aria-label="Counts">'
        + (('<li><a href="#findings"><b>' + str(len(order)) + '</b> finding' + ('' if len(order) == 1 else 's')
            + '</a></li><li><a href="#findings"><b>' + str(nm) + '</b> metric' + ('' if nm == 1 else 's')
            + ' moved</a></li>') if order else '')
        + '<li class="pl-normal"><a href="#s-normal"><b>' + str(nn) + '</b> metric' + ('' if nn == 1 else 's')
        + ' normal</a></li>'
        + ('<li><a href="#s-normal"><b>' + str(ni) + '</b> improved</a></li>' if ni > 0 else '')
        + '</ul>')
    put('<ul class="hnotes" id="narrative-slot" hidden></ul>')
    target_end_s, requested_s = ts_sec(w.target_end), ts_sec(w.target_end_requested)
    if requested_s != target_end_s:
        put('<p class="snapnote">Requested end ' + esc(requested_s[:16])
            + ' had no snapshot within 15 min &mdash; snapped to last snapshot '
            + esc(target_end_s[:16]) + '</p>')
    put('</section>')
    return o


def _timeline(w) -> list[str]:
    """00_params.sql's v1.6.0 Timeline skeleton: the ASH chart panel, the
    grid's ruler (dates as pin buttons) and six empty lanes."""
    cells = "".join('<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k) + '"></div>'
                    for k in range(w.weeks_back, -1, -1))

    def lane_h(lid, title, kind, cap=None, note=None, noun=None):
        return ('<div class="lane" id="lane-' + lid + '" data-kind="' + kind + '"'
                + ((' data-note="' + note + '"') if note else '')
                + ((' data-noun="' + noun + '"') if noun else '')
                + ' role="rowgroup" hidden><div class="r gh2" role="row">'
                '<div class="l" role="rowheader"><button class="lt2" type="button" aria-expanded="true">'
                '<i class="car" aria-hidden="true"></i><span class="lti">' + title + '</span></button></div>'
                + cells + '<div class="g" role="cell"><span class="meta"></span></div>'
                + (('<div class="cap"><span>' + cap + '</span></div>') if cap else '')
                + '</div><div class="lrows"></div></div>')

    st = w.target_end - timedelta(hours=w.win_hours)
    if w.step_hours in (24, 168):
        ct = (({168: day_name(st) + ' ', 24: 'Daily '})[w.step_hours]
              + hh24(st) + '&ndash;' + hh24(w.target_end))
    else:
        ct = 'Every ' + w.step_label + ', ' + w.win_label + ' windows'
    o = []
    o.append('<section id="timeline" class="vw in-t">'
             '<h2>Timeline<small class="h2sub">Down a column: one window. Across a row: when it started.</small></h2>'
             '<p class="tl-nojs">The Timeline is drawn by the page script; with JavaScript off it is not '
             'drawn, and every number it would show is in the sections below.</p>')
    o.append('<div class="panel ashx" id="tl-ash" role="group" aria-labelledby="tl-ash-h" hidden>'
             '<div class="axh"><div class="axt"><h3 id="tl-ash-h">Active sessions, full span</h3>'
             '<span class="axs" id="ax-range"></span></div>'
             '<span class="axk" aria-hidden="true"><span><i class="kw"></i>compared window</span>'
             '<span><i class="kw cur"></i>Current</span><span><i class="kw pin"></i>pinned</span></span>'
             '<button type="button" class="axr" id="ax-reset" hidden>Reset zoom</button></div>'
             '<div class="axlg" id="ax-lg" role="group" aria-label="Wait classes: click to show or hide"></div>'
             '<p class="axe" id="ax-empty" hidden>No ASH samples in DBA_HIST_ACTIVE_SESS_HISTORY across the compared span.</p>'
             '<div class="axp" id="ax-plot"><svg id="ax-svg" role="img" aria-label="Active sessions stacked by wait class '
             'over the whole compared span, the compared windows shaded and release markers drawn. Drag to zoom."></svg>'
             '<div class="axbr" id="ax-brush" hidden></div></div>'
             '<p class="axn2">Drag across the chart to zoom, double-click to reset. '
             'Click a shaded window to pin its column in the grid below.</p></div>')
    o.append('<div class="panel gridwrap wg hov" id="tl"' + wg_attr(w)
             + ' role="table" aria-label="Current vs ' + str(w.weeks_back) + ' prior windows, one column per window">'
             + wg_ruler(w, '<span class="ct">' + ct + '</span><span class="cs">' + str(w.weeks_back + 1)
                        + ' windows</span>'
                        '<nav class="jumpnav" aria-label="Jump to lane"><a href="#lane-metrics">Load</a>'
                        '<a href="#lane-waits">Waits</a><a href="#lane-sql">SQL</a><a href="#lane-config">Config</a>'
                        + ('<a href="#day-profile">Day</a>' if w.profile_days > 0 else '') + '</nav>',
                        '<span class="gt" id="tl-gt">vs prior mean</span><span class="gs" id="tl-gs">click a date to pin</span>',
                        'Y')
             + '<div class="gbody" id="tl-body"><div class="gin" id="tl-in">')
    o.append(lane_h('activity', 'Activity', 'ash', None, 'ASH, not scored'))
    o.append(lane_h('metrics', 'Headline and load', 'scored'))
    o.append(lane_h('waits', 'Waits', 'scored', 'wait classes in AAS, events in seconds waited', None, 'events'))
    o.append(lane_h('objects', 'Where the reads land', 'ranked', None, 'ranked, not scored'))
    o.append(lane_h('sql', 'SQL', 'sql', 'elapsed s; a dash = not in the top ' + str(w.top_n)))
    o.append(lane_h('config', 'Configuration', 'config'))
    o.append('</div></div></div></section>')
    return o


def emit(w) -> str:
    o = []
    put = o.append
    put("<!-- AWR-SECTION: 00_params BEGIN -->")

    scored = scored_rows(w)
    st = _verdict_state(w, scored)

    put('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>')
    L = _lines()
    # the early view script is literal in the SQL: lift it verbatim
    put(next(t for t, ok in L if ok and t.startswith('<script>(function(){var v="summary"')))
    put('<a class="skip" href="#main-start">Skip to report</a>')
    # ---- v1.6.0 top bar (hand-ported: DEFINEs + the Current window) --
    cur_start = w.target_end - timedelta(hours=w.win_hours)
    put('<div class="topbar" id="topbar">'
        '<div class="db"><b>' + esc(w.db_name) + '</b>'
        '<span>' + esc(w.host_name) + ' &middot; ' + esc(w.db_version) + ' &middot; DBID '
        + str(w.dbid) + '</span></div>'
        '<div class="win"><span class="cchip">Current</span><b>'
        + dy(cur_start) + ' ' + cur_start.strftime("%d") + ' ' + mon_dd(cur_start)[:3] + ', '
        + hh24(cur_start) + '&ndash;' + hh24(w.target_end)
        + '</b><span>vs ' + str(w.weeks_back) + ' prior window' + ('' if w.weeks_back == 1 else 's')
        + ', every ' + w.step_label + '</span></div>'
        '<span class="sp"></span>'
        '<div class="seg" role="group" aria-label="View">'
        '<button type="button" data-v="summary" aria-pressed="true"'
        ' title="The answer: verdict, finding cards, what changed, checked and normal">Summary</button>'
        '<button type="button" data-v="timeline" aria-pressed="false"'
        ' title="The compared windows side by side">Timeline</button>'
        '<button type="button" data-v="all" aria-pressed="false"'
        ' title="Every section and every scored row">All sections</button>'
        '</div>'
        '<button type="button" id="theme-toggle" class="theme-icon-btn"'
        ' aria-pressed="false"'
        ' aria-label="Toggle dark mode"'
        ' title="Switch between light and dark color theme">'
        '<svg class="icon-sun" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">'
        '<circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/>'
        '<path d="M12 2.5v3M12 18.5v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1'
        'M2.5 12h3M18.5 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"'
        ' stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
        '</svg>'
        '<svg class="icon-moon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">'
        '<path d="M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5a8.5 8.5 0 1 0 11.2 11.2z" fill="currentColor"/>'
        '</svg>'
        '</button>'
        '</div>')

    # ---- nav rail (hand-ported: profile_days CASE) --------------------
    put('<nav class="toc">'
        '<div class="rail-brand"><span>AWR &middot; Timeline comparison</span>'
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
        '<b>Summary</b>'
        '<a href="#verdict" data-nodot>Verdict</a>'
        '<a href="#findings">Findings</a>'
        '<a href="#s-changes" data-nodot hidden>What changed around it</a>'
        '<a href="#s-normal" data-nodot>Checked and normal</a>'
        '<b>Timeline</b>'
        '<a href="#tl-ash" data-nodot>Active sessions, full span</a>'
        '<a href="#lane-activity" data-nodot>Activity</a>'
        '<a href="#lane-metrics">Headline and load</a>'
        '<a href="#lane-waits">Waits</a>'
        '<a href="#lane-objects" data-nodot>Where the reads land</a>'
        '<a href="#lane-sql">SQL</a>'
        '<a href="#lane-config" data-nodot>Configuration</a>'
        '<b>Workload</b>'
        '<a href="#db-time-summary">DB time</a>'
        '<a href="#ash-timeline">ASH timeline</a>'
        '<a href="#windows">Windows</a>'
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
        '<b id="rail-ref">Reference</b>'
        '<a href="#guide" data-nodot>Reading the charts</a>'
        '<a href="#about" data-nodot>About this report</a>'
        '</div>'
        '<div class="rail-foot">'
        '<button type="button" class="view-btn" id="view-btn"'
        ' aria-expanded="false" aria-controls="view-panel"'
        ' title="Report view options">View &#9662;</button>'
        '<div class="view-panel" id="view-panel">'
        '<button type="button" id="next-finding" class="next-finding"'
        ' title="Jump to the next large (critical) finding">'
        '<span>&darr; next large finding</span>'
        '<span class="keys">J K</span>'
        '</button>'
        '</div>'
        '</div>'
        '</nav>')

    # ---- every chrome <script> after the nav, verbatim, up to <main> ---
    i_nav = next(i for i in range(len(L)) if L[i][0].startswith('<nav class="toc">'))
    i_main = _index(L, '<main id="main-start">', i_nav)
    o.extend(_literal_slice(L, i_nav + 1, i_main))
    # ---- AWR_WIN + the verdict hero (hand-ported) ----------------------
    put('<script>window.AWR_WIN=' + _win_json(w) + ';</script>')
    o.extend(_hero(w, st))
    # ---- the Timeline skeleton (hand-ported) ---------------------------
    o.extend(_timeline(w))

    put('<!-- AWR-SECTION: 00_params END -->')
    return "\n".join(o)
