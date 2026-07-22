"""Server-rendered HTML via string.Template. No template engine dependency
(stdlib only) -- every dynamic value goes through html.escape before it
touches a template, mirroring the SQL side's DBMS_XMLGEN.CONVERT convention
(CLAUDE.md "HTML emission").

Deliberately plain for this pass (CLAUDE.md build-order step 8: "just make
the pages clean and functional... a dedicated polish pass happens later").
One inline <style> block loosely echoes the fleet report's dark palette
(sql/_style.sql's --panel/--crit/--warn/--ok tokens) without trying to be a
byte-for-byte copy.
"""

import html
import json
import time
from string import Template

from . import fleetconf, records

_STYLE = """
:root {
  --paper:#eceef1; --panel:#ffffff; --panel-2:#f4f6f8;
  --ink:#12161d; --ink-soft:#333a45; --muted:#5d6672;
  --border:#d9dfe6; --rule:#c9d1da; --line-soft:#e3e8ee;
  --accent:#1f5fa8; --accent-bg:#e6eef8;
  --crit:#b01c1c; --warn:#8a5a00; --ok:#1f7a4d;
  --crit-bg:#f7e2e2; --warn-bg:#f6ecd6; --ok-bg:#dff0e6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper:#0f1319; --panel:#161b23; --panel-2:#1d232d;
    --ink:#e7ecf2; --ink-soft:#bcc5d1; --muted:#8591a0;
    --border:#2a323d; --rule:#333c48; --line-soft:#242c36;
    --accent:#5b9bd8; --accent-bg:#1a2634;
    --crit:#e5675c; --warn:#e0a53a; --ok:#43bb82;
    --crit-bg:#2e1b1b; --warn-bg:#2c2413; --ok-bg:#13271d;
  }
}
* { box-sizing:border-box; }
body {
  margin:0; background:var(--paper); color:var(--ink);
  font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
}
.mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
.tnum { font-variant-numeric:tabular-nums; }
header.top {
  padding:14px 20px; background:var(--panel); border-bottom:1px solid var(--border);
  display:flex; align-items:center; gap:18px; flex-wrap:wrap;
}
header.top h1 { font-size:16px; margin:0; font-weight:650; letter-spacing:.01em; }
header.top nav a { color:var(--muted); text-decoration:none; margin-right:14px; font-size:13px; }
header.top nav a:hover { color:var(--accent); }
main { max-width:1100px; margin:0 auto; padding:20px; }
.card {
  background:var(--panel); border:1px solid var(--border); border-radius:8px;
  padding:16px 18px; margin-bottom:16px;
}
.card h2 {
  font-size:10.5px; margin:0 0 12px; text-transform:uppercase;
  letter-spacing:.06em; color:var(--muted); font-weight:600;
}
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:6px 9px; border-bottom:1px solid var(--line-soft); }
th {
  color:var(--muted); font-weight:600; font-size:10px; text-transform:uppercase;
  letter-spacing:.05em; background:var(--panel-2); border-bottom:1px solid var(--rule);
}
th.num, td.num { text-align:right; }
td.num { font-variant-numeric:tabular-nums; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
tr:hover td { background:var(--panel-2); }
tr:last-child td { border-bottom:none; }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; }
.badge, .pill {
  display:inline-block; font-weight:650; border:1px solid transparent;
  font-variant-numeric:tabular-nums;
}
.badge { padding:1px 8px; border-radius:10px; font-size:11px; }
.pill { padding:1px 7px; border-radius:4px; font-size:11px; }
.badge.success, .pill.ok { color:var(--ok); background:var(--ok-bg); border-color:var(--ok); }
.badge.partial, .pill.warn { color:var(--warn); background:var(--warn-bg); border-color:var(--warn); }
.badge.failed, .pill.crit { color:var(--crit); background:var(--crit-bg); border-color:var(--crit); }
.badge.running { color:var(--accent); background:var(--accent-bg); border-color:var(--accent); }
.badge.queued, .badge.skipped, .pill.dead, .pill.z {
  color:var(--muted); background:var(--panel-2); border-color:var(--border);
}
.dot { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:7px; vertical-align:middle; }
.dot.crit { background:var(--crit); } .dot.warn { background:var(--warn); }
.dot.ok { background:var(--ok); } .dot.dead { background:var(--muted); }
form.inline { display:inline; }
button, input[type=submit] {
  font:inherit; font-size:13px; background:var(--accent); color:#fff; border:none;
  border-radius:5px; padding:6px 13px; cursor:pointer;
}
button.secondary { background:var(--panel-2); color:var(--ink); border:1px solid var(--border); }
button:hover { filter:brightness(1.08); }
.muted { color:var(--muted); }
.error-banner {
  background:var(--crit-bg); border:1px solid var(--crit);
  color:var(--crit); padding:8px 12px; border-radius:6px; margin-bottom:14px; font-size:13px;
}
.security-note {
  font-size:12px; color:var(--muted); margin-top:24px;
  border-top:1px solid var(--line-soft); padding-top:12px;
}
pre.log {
  background:#0a0d12; color:#d6dde6; padding:12px 14px; border-radius:6px; overflow:auto;
  max-height:420px; font-size:12px; line-height:1.45; white-space:pre-wrap; word-break:break-all;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; border:1px solid var(--rule);
}
.kv { display:grid; grid-template-columns:130px 1fr; gap:5px 14px; font-size:13px; align-items:baseline; }
.kv .k { color:var(--muted); font-size:12px; }
code { font-size:12px; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
/* latest-report masthead strip */
.latest { display:flex; align-items:baseline; gap:14px; flex-wrap:wrap; }
.latest .rlink { font-size:16px; font-weight:650; }
.latest .rlink a { color:var(--ink); }
.latest .rlink a:hover { color:var(--accent); }
.latest .ts { color:var(--muted); font-size:12px; font-variant-numeric:tabular-nums; }
.counts { display:flex; gap:6px; margin-left:auto; }
.alias { font-weight:600; }
.notes { color:var(--muted); font-size:12px; }
.run-actions { margin-top:14px; }
"""

_PAGE = Template(
    """<title>$title</title>
<style>$style</style>
<header class="top">
  <h1>AWR Fleet Server</h1>
  <nav>
    <a href="/">Home</a>
    <a href="/runs">Run history</a>
  </nav>
</header>
<main>
$body
<p class="security-note">No authentication. Reports may expose SQL text,
hostnames and usernames -- keep this bound to localhost or front it with a
reverse proxy / SSH tunnel.</p>
</main>
"""
)


def _page(title, body):
    return _PAGE.substitute(title=html.escape(title), style=_STYLE, body=body)


def _fmt_ts(epoch):
    if not epoch:
        return "-"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))
    except (OSError, OverflowError, ValueError):
        return "-"


def _fmt_dur(seconds):
    if seconds is None:
        return "-"
    seconds = int(seconds)
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h:
        return "%dh%02dm%02ds" % (h, m, s)
    if m:
        return "%dm%02ds" % (m, s)
    return "%ds" % (s,)


def _badge(state):
    return '<span class="badge %s">%s</span>' % (
        html.escape(state or "unknown"),
        html.escape(state or "unknown"),
    )


def _fmt_params(params):
    """Compact human window string -- the same shape shown on the home-page
    fleet card, rendered from a run record's params dict (never a raw repr)."""
    if not params:
        return "-"
    g = params.get
    return "target_end=%s win_hours=%s weeks_back=%s top_n=%s step=%s%s" % (
        g("target_end", "-"),
        g("win_hours", "-"),
        g("weeks_back", "-"),
        g("top_n", "-"),
        g("step", "-"),
        g("step_unit", ""),
    )


def _db_severity(d):
    """Fleet-console severity for one parsed per-DB row: crit/warn/ok for a
    reachable DB (by its crit/warn counts), dead for an unreachable one."""
    if (d.get("status") or "").upper() != "OK":
        return "dead"
    try:
        crit = int(d.get("crit") or 0)
        warn = int(d.get("warn") or 0)
    except (TypeError, ValueError):
        return "ok"
    if crit > 0:
        return "crit"
    if warn > 0:
        return "warn"
    return "ok"


def _fleet_counts(databases):
    counts = {"crit": 0, "warn": 0, "ok": 0, "dead": 0}
    for d in databases or []:
        counts[_db_severity(d)] += 1
    return counts


def _count_pills(counts):
    order = (("crit", "crit"), ("warn", "warn"), ("ok", "ok"), ("dead", "down"))
    out = [
        '<span class="pill %s">%d %s</span>' % (sev, counts.get(sev, 0), label)
        for sev, label in order
        if counts.get(sev, 0)
    ]
    return " ".join(out) or '<span class="pill z">no databases</span>'


def _report_link(report_path):
    if not report_path:
        return "-"
    filename = report_path.split("/", 1)[-1] if "/" in report_path else report_path
    return '<a href="/reports/%s">%s</a>' % (html.escape(filename, quote=True), html.escape(filename))


def _run_row(rec):
    alias = rec.get("alias") or "-"
    kind = rec.get("kind") or "-"
    label = kind if kind == "fleet" else "%s (%s)" % (kind, alias)
    return (
        "<tr>"
        '<td><a href="/runs/%s">%s</a></td>'
        "<td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
        "</tr>"
    ) % (
        html.escape(rec["run_id"], quote=True),
        html.escape(rec["run_id"][:20]),
        html.escape(label),
        html.escape(rec.get("trigger") or "-"),
        _badge(rec.get("state")),
        _fmt_ts(rec.get("queued_at")),
        _fmt_dur(rec.get("duration_s")),
        _report_link(rec.get("report_path")),
    )


def _latest_detail_report(ctx, alias):
    """Server record first, then a glob fallback for pre-server history
    (files that predate this server ever running -- see plan section
    'Per-DB on-demand detail regen')."""
    best = None
    for rec in records.list_records(ctx.data_dir):
        if (
            rec.get("kind") == records.KIND_DETAIL
            and rec.get("alias") == alias
            and rec.get("state") == records.STATE_SUCCESS
            and rec.get("report_path")
        ):
            if best is None or (rec.get("started_at") or 0) > (best.get("started_at") or 0):
                best = rec
    if best:
        rp = best["report_path"]
        return rp.split("/", 1)[-1] if "/" in rp else rp
    try:
        candidates = sorted(
            ctx.reports_dir.glob("awr_fleet_detail_%s_run*.html" % alias),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        candidates = []
    return candidates[0].name if candidates else None


def _latest_fleet_report(ctx):
    best = None
    for rec in records.list_records(ctx.data_dir):
        if rec.get("kind") == records.KIND_FLEET and rec.get("state") in (
            records.STATE_SUCCESS,
            records.STATE_PARTIAL,
        ) and rec.get("report_path"):
            if best is None or (rec.get("started_at") or 0) > (best.get("started_at") or 0):
                best = rec
    return best


def render_home(ctx, error=None):
    parts = []
    if error:
        parts.append('<div class="error-banner">%s</div>' % html.escape(error))

    sched = ctx.scheduler.status() if ctx.scheduler else {"enabled": False}
    latest = _latest_fleet_report(ctx)
    latest_dbs = (latest or {}).get("databases") or []
    sev_by_alias = {d.get("alias"): _db_severity(d) for d in latest_dbs}

    parts.append('<div class="card">')
    parts.append("<h2>Fleet</h2>")
    if latest:
        parts.append('<div class="latest">')
        parts.append('<span class="rlink">%s</span>' % _report_link(latest["report_path"]))
        parts.append('<span class="ts">%s</span>' % _fmt_ts(latest.get("ended_at")))
        if latest_dbs:
            parts.append('<span class="counts">%s</span>' % _count_pills(_fleet_counts(latest_dbs)))
        parts.append("</div>")
    else:
        parts.append('<p class="muted">No successful fleet run yet.</p>')

    parts.append('<div class="kv" style="margin-top:12px">')
    if sched.get("enabled"):
        parts.append(
            '<div class="k">Next run</div><div>%s <span class="muted">(mode=%s)</span></div>'
            % (html.escape(sched.get("next_fire") or "-"), html.escape(sched.get("mode") or "-"))
        )
    else:
        parts.append('<div class="k">Scheduler</div><div class="muted">disabled</div>')
    fp = ctx.config.fleet
    parts.append(
        '<div class="k">Window</div><div class="tnum">%s</div>'
        % html.escape(
            _fmt_params(
                {
                    "target_end": fp.target_end,
                    "win_hours": fp.win_hours,
                    "weeks_back": fp.weeks_back,
                    "top_n": fp.top_n,
                    "step": fp.step,
                    "step_unit": fp.step_unit,
                }
            )
        )
    )
    parts.append("</div>")
    parts.append(
        '<div class="run-actions"><form class="inline" method="post" action="/api/fleet/run">'
        '<button type="submit">Run fleet now</button></form></div>'
    )
    parts.append("</div>")

    parts.append('<div class="card"><h2>Databases</h2>')
    try:
        entries = fleetconf.parse_fleet_conf(ctx.config.fleet.conf_path)
    except fleetconf.FleetConfError as exc:
        parts.append('<div class="error-banner">Could not read fleet.conf: %s</div>' % html.escape(str(exc)))
        entries = {}
    if entries:
        parts.append(
            "<table><tr><th>Alias</th><th>Latest</th><th>Detail</th>"
            "<th>Latest detail report</th><th></th></tr>"
        )
        _sev_word = {"crit": "crit", "warn": "warn", "ok": "ok", "dead": "down"}
        for alias, entry in entries.items():
            latest_detail = _latest_detail_report(ctx, alias)
            sev = sev_by_alias.get(alias)
            if sev:
                status_cell = '<span class="pill %s">%s</span>' % (sev, _sev_word[sev])
            else:
                status_cell = '<span class="muted">&ndash;</span>'
            parts.append(
                '<tr><td class="alias">%s</td><td>%s</td><td>%s</td><td>%s</td>'
                '<td><form class="inline" method="post" action="/api/detail/run">'
                '<input type="hidden" name="alias" value="%s">'
                '<button type="submit" class="secondary">Regen detail</button></form></td></tr>'
                % (
                    html.escape(alias),
                    status_cell,
                    "yes" if entry.detail else "no",
                    _report_link("reports/" + latest_detail) if latest_detail else "-",
                    html.escape(alias, quote=True),
                )
            )
        parts.append("</table>")
    parts.append("</div>")

    parts.append('<div class="card"><h2>Recent runs</h2>')
    recs = records.list_records(ctx.data_dir)[:10]
    if recs:
        parts.append(
            "<table><tr><th>Run</th><th>Kind</th><th>Trigger</th><th>State</th>"
            "<th>Queued</th><th>Duration</th><th>Report</th></tr>"
        )
        parts.extend(_run_row(r) for r in recs)
        parts.append("</table>")
    else:
        parts.append('<p class="muted">No runs yet.</p>')
    parts.append('<p><a href="/runs">Full run history &rarr;</a></p>')
    parts.append("</div>")

    return _page("AWR Fleet Server", "\n".join(parts))


def render_runs(ctx):
    recs = records.list_records(ctx.data_dir)
    parts = ['<div class="card"><h2>Run history (%d)</h2>' % len(recs)]
    if recs:
        parts.append(
            "<table><tr><th>Run</th><th>Kind</th><th>Trigger</th><th>State</th>"
            "<th>Queued</th><th>Duration</th><th>Report</th></tr>"
        )
        parts.extend(_run_row(r) for r in recs)
        parts.append("</table>")
    else:
        parts.append('<p class="muted">No runs yet.</p>')
    parts.append("</div>")
    return _page("Run history - AWR Fleet Server", "\n".join(parts))


def _db_rows(databases):
    if not databases:
        return '<p class="muted">No per-database rows parsed yet.</p>'
    out = [
        '<table><tr><th>Alias</th><th>Status</th><th class="num">Score</th>'
        '<th class="num">Crit</th><th class="num">Warn</th><th>Detail</th><th>Notes</th></tr>'
    ]
    for d in databases:
        sev = _db_severity(d)
        status_cell = '<span class="pill %s">%s</span>' % (sev, html.escape(d.get("status") or "-"))
        if (d.get("status") or "").upper() == "OK":
            score = html.escape(str(d.get("score")))
            crit = html.escape(str(d.get("crit")))
            warn = html.escape(str(d.get("warn")))
            notes = "suppressed=%s topsql_n=%s topsql_pts=%s" % (
                html.escape(str(d.get("suppressed"))),
                html.escape(str(d.get("topsql_n"))),
                html.escape(str(d.get("topsql_pts"))),
            )
        else:
            score = "rc=%s" % html.escape(str(d.get("rc")))
            crit = warn = "&ndash;"
            notes = html.escape(d.get("reason") or "")
        out.append(
            '<tr><td class="alias">%s</td><td>%s</td><td class="num">%s</td>'
            '<td class="num">%s</td><td class="num">%s</td><td>%s</td><td class="notes">%s</td></tr>'
            % (
                html.escape(d.get("alias") or "-"),
                status_cell,
                score,
                crit,
                warn,
                html.escape(d.get("detail") or "-"),
                notes,
            )
        )
    out.append("</table>")
    return "\n".join(out)


def render_run_detail(ctx, rec):
    run_id = rec["run_id"]
    live = rec.get("state") in (records.STATE_QUEUED, records.STATE_RUNNING)

    parts = ['<div class="card"><h2>Run %s</h2>' % html.escape(run_id)]
    parts.append('<div class="kv">')
    parts.append('<div class="k">State</div><div id="state">%s</div>' % _badge(rec.get("state")))
    parts.append("<div class=\"k\">Kind</div><div>%s%s</div>" % (
        html.escape(rec.get("kind") or "-"),
        (" (alias %s)" % html.escape(rec["alias"])) if rec.get("alias") else "",
    ))
    parts.append('<div class="k">Trigger</div><div>%s</div>' % html.escape(rec.get("trigger") or "-"))
    parts.append('<div class="k">Queued</div><div>%s</div>' % _fmt_ts(rec.get("queued_at")))
    parts.append('<div class="k">Started</div><div>%s</div>' % _fmt_ts(rec.get("started_at")))
    parts.append('<div class="k">Ended</div><div id="ended">%s</div>' % _fmt_ts(rec.get("ended_at")))
    parts.append('<div class="k">Duration</div><div id="duration">%s</div>' % _fmt_dur(rec.get("duration_s")))
    parts.append('<div class="k">Exit code</div><div class="tnum">%s</div>' % html.escape(str(rec.get("exit_code"))))
    parts.append('<div class="k">Window</div><div class="tnum">%s</div>' % html.escape(_fmt_params(rec.get("params"))))
    parts.append('<div class="k">Report</div><div id="report">%s</div>' % _report_link(rec.get("report_path")))
    if rec.get("workdir"):
        parts.append(
            '<div class="k">Workdir</div><div><code>%s</code> '
            '<span class="muted">(kept on disk)</span></div>' % html.escape(rec["workdir"])
        )
    parts.append("</div>")

    if rec.get("warnings"):
        parts.append('<div class="error-banner">%s</div>' % "<br>".join(html.escape(w) for w in rec["warnings"]))
    if rec.get("error"):
        parts.append('<pre class="log">%s</pre>' % html.escape(rec["error"]))

    parts.append("</div>")

    parts.append('<div class="card"><h2>Databases</h2><div id="databases">%s</div></div>' % _db_rows(rec.get("databases")))

    parts.append('<div class="card"><h2>Log</h2><pre class="log" id="logbox"></pre></div>')

    if live:
        parts.append(
            """
<script>
(function(){
  var runId = %s;
  var offset = 0;
  var logbox = document.getElementById('logbox');
  function tick(){
    fetch('/api/runs/' + runId + '/log?offset=' + offset)
      .then(function(r){
        var eof = r.headers.get('X-Log-EOF') === '1';
        var newOffset = r.headers.get('X-Log-Offset');
        return r.text().then(function(t){ return {t:t, eof:eof, newOffset:newOffset}; });
      })
      .then(function(res){
        if (res.t) { logbox.textContent += res.t; logbox.scrollTop = logbox.scrollHeight; }
        if (res.newOffset) { offset = parseInt(res.newOffset, 10); }
        return fetch('/api/runs/' + runId).then(function(r){ return r.json(); });
      })
      .then(function(rec){
        document.getElementById('state').outerHTML =
          '<span class="badge ' + rec.state + '" id="state">' + rec.state + '</span>';
        if (rec.state !== 'queued' && rec.state !== 'running') {
          location.reload();
        } else {
          setTimeout(tick, 3000);
        }
      })
      .catch(function(){ setTimeout(tick, 3000); });
  }
  tick();
})();
</script>
"""
            % json.dumps(run_id)
        )
    else:
        parts.append(
            """
<script>
fetch('/api/runs/%s/log').then(function(r){return r.text();}).then(function(t){
  document.getElementById('logbox').textContent = t;
});
</script>
"""
            % json.dumps(run_id)[1:-1]
        )

    return _page("Run %s - AWR Fleet Server" % run_id, "\n".join(parts))
