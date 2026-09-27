# AWR Timeline Comparison

**Project website (screenshots, live example reports, cheat sheet):**
<https://davidbudac.github.io/awr_timeline_comparison/>

## Quick start

Needs Oracle Database 19c with the Diagnostic + Tuning Pack licence,
SQL\*Plus, and a user that can read the AWR views (any DBA account works;
see [Install / grants](#install--grants)). Nothing is installed in the
database: the tool only runs `SELECT`s.

```bash
# 1. Get it
git clone https://github.com/davidbudac/awr_timeline_comparison.git
cd awr_timeline_comparison

# 2. Run it (on the DB host with OS auth: ./run_awr_trend.sh '/ as sysdba')
./run_awr_trend.sh user/pw@svc

# 3. Open the HTML file it wrote to reports/
```

That compares the last full hour with the same hour on each of the 4
prior weeks. **The defaults are the recommended settings; everything
below is optional.** Not sure about options? `./run_awr_trend.sh
--configure` asks a few questions and prints the command. What the output
looks like: [demo report](https://davidbudac.github.io/awr_timeline_comparison/examples/demo_busy_db.html).

## What it does

A pure-SQL Oracle 19c toolkit that compares AWR snapshots across a series
of **aligned windows** (by default the same hour of the week over the last
four weeks), flags drastic changes via z-score, and renders one
self-contained HTML report. The cadence is configurable (weekly, daily,
hourly or any multiple), and a separate fleet wrapper runs the same
comparison across many databases on one page.

## Install / grants

Nothing to install in the database. Connect as a user (typically DBA)
that can read the AWR views listed below.

Required grants (already covered by the `DBA` role, or for a dedicated
analyst user):

```sql
GRANT SELECT ON DBA_HIST_SNAPSHOT            TO <user>;
GRANT SELECT ON DBA_HIST_SYSSTAT             TO <user>;
GRANT SELECT ON DBA_HIST_SYSTEM_EVENT        TO <user>;
GRANT SELECT ON DBA_HIST_BG_EVENT_SUMMARY    TO <user>;
GRANT SELECT ON DBA_HIST_SYSMETRIC_SUMMARY   TO <user>;
GRANT SELECT ON DBA_HIST_SQLSTAT             TO <user>;
GRANT SELECT ON DBA_HIST_SQLTEXT             TO <user>;
GRANT SELECT ON DBA_HIST_SEG_STAT            TO <user>;
GRANT SELECT ON DBA_HIST_SEG_STAT_OBJ        TO <user>;
GRANT SELECT ON DBA_HIST_FILESTATXS          TO <user>;
GRANT SELECT ON DBA_HIST_TEMPSTATXS          TO <user>;
GRANT SELECT ON DBA_HIST_IOSTAT_FILETYPE     TO <user>;
GRANT SELECT ON DBA_HIST_ACTIVE_SESS_HISTORY TO <user>;
GRANT SELECT ON DBA_HIST_PARAMETER           TO <user>;
GRANT SELECT ON V_$DATABASE                  TO <user>;
GRANT SELECT ON V_$INSTANCE                  TO <user>;
-- Only if you use side/create_weekly_baselines.sql (optional, writes baselines):
GRANT EXECUTE ON DBMS_WORKLOAD_REPOSITORY    TO <user>;
```

## Run

The [Quick start](#quick-start) command (`./run_awr_trend.sh user/pw@svc`)
covers the usual case. This section is the reference for everything else.

**Don't want to memorize the argument order?** Run the
interactive configurator. It walks you through every option (with a short
explanation, a sensible default and input validation for each), then prints
*both* a ready-to-paste `./run_awr_trend.sh` command and the equivalent
pure-SQL\*Plus block, and offers to run the report right away:

```bash
./run_awr_trend.sh --configure     # also: -c, -i, --interactive,
                                   # or just run with no arguments
```

Or pass positional arguments to the shell wrapper (it sets all substitution vars for you):

```bash
./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0      # explicit weekly
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h                # last 4 hours straight back
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple         # lean triage report
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple Y       # simple + progress markers on stdout
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive N my_markers.sql  # annotate timelines with milestones
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive Y '' 7  # + Day profile: each hour of the last 24 h vs the 7 prior days
MARKERS='2026-06-10 09:00|Release 2.0' ./run_awr_trend.sh user/pw@svc  # file-free inline markers
ECHARTS=vendor/echarts.min.js ./run_awr_trend.sh user/pw@svc           # self-contained / offline HTML
ARCHIVE=zip ./run_awr_trend.sh user/pw@svc                             # also zip the finished report
```

Arguments: `connect_string [target_end [win_hours [weeks_back [top_n [inst_num [step [step_unit [template [debug [marker_file [profile_days]]]]]]]]]]]`

Plus two environment variables: `MARKERS` for file-free inline timeline
markers (see "Timeline markers" below), and `ECHARTS` to control where the
chart library loads from / make the report self-contained (see "Offline /
self-contained report" below).

| Arg          | Default          | Meaning                                             |
|--------------|------------------|-----------------------------------------------------|
| `target_end` | `AUTO`           | Window end — `AUTO` = prior full hour, or `'YYYY-MM-DD HH24:MI'` |
| `win_hours`  | `1`              | Length of each compared window, in hours            |
| `weeks_back` | `4`              | Number of prior windows to compare against (the name is historical; it's just the count) |
| `top_n`      | `10`             | Top-N rows per ranking in Top SQL / waits           |
| `inst_num`   | `0`              | RAC: `0` = aggregate across all instances; `>0` = filter to that instance |
| `step`       | `1`              | Cadence count between adjacent windows              |
| `step_unit`  | `w`              | Cadence unit: `h` (hours), `d` (days), `w` (weeks)  |
| `template`   | `comprehensive`  | Metric + wait-event set: `comprehensive` (full curated lists), `simple` (triage-friendly subset), or `dev` (application-developer view) |
| `debug`      | `Y`              | `Y` (or `YES/1/ON/TRUE/T`, case-insensitive; the default) prints one-line, millisecond-timestamped progress markers to stdout as each section begins — useful when a slow section makes the run look hung. Pass any other value (e.g. `N`) to silence them. Markers go to stdout only; the HTML report is byte-identical to a `debug=N` run |
| `marker_file`| *(empty)*        | Optional path to a timeline-marker config file (milestones drawn as vertical dashed lines on the dated charts). Empty = no markers. See "Timeline markers" below |
| `profile_days`| `0`             | Optional **Day profile** section: `N > 0` scores **each hour of the 24 h ending at `target_end`** against the same hour-of-day on the N prior days (1-day cadence, independent of `step`/`step_unit`) — an hour-of-day × metric heatmap, a per-metric line vs its prior-day band, and a 24-row table — so you can see *which hour of the day* changed. `0` = off (report byte-identical). z-scores need `N ≥ 3`. See "Day profile" below |
| `MARKERS` *(env var)* | *(empty)* | File-free alternative to `marker_file`: inline `WHEN\|LABEL` milestones joined by `;;`. `marker_file` wins when both are set. See "Timeline markers" below |
| `ECHARTS` *(env var)* | *(empty)* | Where the ECharts chart library loads from. Empty = public CDN (`cdn.jsdelivr.net`). An `http(s)` URL = used as-is (internal mirror). A local file path = inlined into the report for a single self-contained, offline-capable HTML file. See "Offline / self-contained report" below |
| `ARCHIVE` *(env var)* | *(empty)* | Also zip/tar the finished report. Empty/`0`/`N`/`no`/`off` = disabled. `1`/`Y`/`yes`/`on`/`auto` = auto-pick zip, else tar+gzip, else plain tar. `zip`/`tgz`/`tar` force that format. See "Archive the output (zip)" below |

`step` × `step_unit` defines the gap between adjacent comparison
windows. `step=1, step_unit=w` (the default) reproduces the original
"same hour-of-week, N prior weeks" behaviour. `step=1, step_unit=h`
gives the last `weeks_back+1` consecutive 1-hour windows. `step=2,
step_unit=d` runs every-other-day.

`template` picks which set of metrics and wait events the report renders.
`comprehensive` is the full pre-template content (27 SYSSTAT load stats,
23 SYSMETRIC metrics, all wait events ranked by time). `simple` is a
triage-friendly subset (9 load stats, 8 metrics, ~10 wait events) for a
quick glance. `dev` is an application-developer's view (17 load stats,
13 metrics, 14 wait events) that focuses on what the application drives —
transaction throughput, query work, cursor/parse behaviour, sorts,
SQL*Net chattiness, response time, and app-caused contention waits — and
omits host/OS and storage-engine internals. To add your own template, drop a directory under
`sql/lib/templates/<name>/` with three files
(`sysstat_load_targets.sql`, `sysmetric_targets.sql`,
`wait_event_targets.sql`) and extend the whitelist in `awr_trend.sql`.
See [CHEATSHEET.md](CHEATSHEET.md) for ready-to-paste recipes.

### Timeline markers (milestones)

`marker_file` lets you annotate the dated charts with your own milestones
— a patch, an index rebuild, a stats gather, an incident, a release — so a
spike or dip lines up visually with a known change. It's **optional**: no
`marker_file` means no markers and no change to the report.

The config file lists one milestone per line — a datetime (`YYYY-MM-DD
HH24:MI`, 24-hour clock) and a label. Copy
[`markers.example.sql`](markers.example.sql) and edit:

```sql
-- my_markers.sql
@@sql/lib/marker '2026-04-20 14:00' 'Applied patch 19.22'
@@sql/lib/marker '2026-05-01 02:00' 'Index rebuild on SALES'
@@sql/lib/marker '2026-05-10 09:30' 'Optimizer stats gather'
```

Then pass its path as the `marker_file` argument (wrapper) or
`DEFINE marker_file = 'my_markers.sql'` (pure SQL\*Plus). Markers appear on
every dated chart: the Activity charts at the top of every view, the
Timeline's window grid ruler (drawn inline, offline too), the finding cards' window bars, the
hourly ASH timeline, the DB-time summary, and the per-SQL ASH cards.

**File-free markers** — if you'd rather not keep a file on disk, pass the
same milestones inline. Each is `WHEN|LABEL`, joined by `;;`:

```sh
MARKERS='2026-04-20 14:00|Applied patch 19.22;;2026-05-01 02:00|Index rebuild' \
    ./run_awr_trend.sh user/pw@svc
```

or on the pure-SQL\*Plus path, `DEFINE markers = '2026-04-20 14:00|Applied
patch 19.22;;…'`. The inline form renders identical markers, but a label
there must avoid a straight single quote, `|`, `;;` and `~` — use a
`marker_file` for labels that need those. `marker_file` wins when both are
set. The [configurator](docs/configurator.html) builds either form for you.

Notes:

- Keep the path exactly `@@sql/lib/marker` even if your config lives
  elsewhere — SQL\*Plus resolves nested `@@` paths from the project root.
- A marker outside a given chart's time span is silently dropped for that
  chart; markers snap to the nearest data point on the chart's axis.
- A malformed datetime is skipped (it becomes an HTML comment) rather than
  failing the run. Labels containing a single quote must double it
  (`'Bob''s change'`).
- With the ECharts CDN blocked, markers still draw on the Timeline view and
  the window bars (inline SVG) but not on the ECharts charts; the tables'
  micro strips never carry them.

Pure SQL\*Plus (no bash) — you must pre-DEFINE the variables or load the
canonical defaults first:

```sql
SQL> @sql/defaults.sql
SQL> @awr_trend.sql
-- or, to customize one-off:
SQL> DEFINE target_end = '2026-04-15 09:00'
SQL> DEFINE win_hours  = 2
SQL> DEFINE weeks_back = 6
SQL> DEFINE top_n      = 20
SQL> DEFINE inst_num   = 1
SQL> DEFINE step       = 1
SQL> DEFINE step_unit  = 'w'
SQL> DEFINE template   = 'comprehensive'
SQL> DEFINE debug      = 'N'
SQL> DEFINE marker_file = 'my_markers.sql'   -- optional; '' for none
SQL> DEFINE profile_days = 7                 -- optional Day profile; 0 = off
SQL> DEFINE markers     = ''                 -- optional file-free markers; '' for none
SQL> @awr_trend.sql
```

Output: `reports/awr_trend_<DBID>_<YYYYMMDDHH24MI>_run<run_id>.html`. Open
it in a browser. The report is self-contained (one HTML file with inline
CSS, JS and SVG for the Summary and Timeline views; by default the larger
All-sections charts load ECharts
from `cdn.jsdelivr.net` and degrade gracefully when the CDN is blocked).
For a **fully offline** report — charts and all — see "Offline /
self-contained report" below.

### Day profile (which hour of the day changed?)

The compared windows above answer "is *this* hour unusual?". Pass a
`profile_days` (12th positional, or `DEFINE profile_days = N`) and the report
grows a **Day profile** section that scores **every hour of the 24 h ending
at `target_end`** against the same hour-of-day on the N prior days — a
1-day cadence that is independent of `step`/`step_unit`, so it combines
freely with a weekly or hourly main comparison:

```sh
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive Y '' 7
```

You get a signed-z heatmap (hour × metric; red = above the prior days, blue
= below, hover for current / mean / σ / n / %Δ), a per-metric line chart
(current day against the prior-day mean with a μ ± 2σ band and the
individual prior days as faint lines), picked from a row of buttons, one per
metric, each with a severity dot, its large / moderate hour counts and its
largest z (so the unusual ones stand out); the arrow keys cycle them, and a
heatmap row label or cell switches too (a cell also jumps to that hour's
row), and a 24-row table that also serves as the
offline fallback. Nine per-second rates come from `DBA_HIST_SYSSTAT`
snapshot deltas (DB time and DB CPU as average active sessions / CPUs busy,
user calls, executions, logical and physical reads, physical writes, redo
bytes, commits) — restart-guarded, summed across RAC instances, and blank
(not 0) for any hour covered by less than 30 minutes of snapshots (2-hour
snapshot intervals, gaps). Scoring is the Findings summary's rule set:
`|z| > 3` large, `|z| > 2` moderate, at least 3 prior values required, so
`profile_days ≥ 3` is the useful minimum (7 or 14 are good defaults).
`profile_days = 0` (the default) leaves the report byte-identical. The fleet
console has the same feature as a per-DB heatmap band via
`FLEET_PROFILE_DAYS` (see below).

### Offline / self-contained report

By default only one thing in the report reaches the network: the Apache
ECharts library that draws the larger All-sections charts (wait stacked
bars, top-SQL bump chart, hourly ASH timeline, DB time over the span, I/O
trends, SQL Monitor scatter). The Summary and Timeline views — finding
cards, window bars, band glyphs, micro strips, the Activity charts
— are inline SVG/CSS and never need it. When the CDN is blocked the report
still opens and every table renders; an amber "Charts hidden" banner
explains why. To make the report render its charts with **no network at
all**, set the `ECHARTS` environment variable (wrapper) or the `echarts`
substitution variable (pure SQL\*Plus):

```bash
# 1. Self-contained single file — inline a local ECharts into the report:
ECHARTS=vendor/echarts.min.js ./run_awr_trend.sh user/pw@svc
#    The wrapper splices the file's bytes into the finished HTML, so the
#    one .html opens and charts offline with nothing else alongside it.

# 2. Internal mirror — point the <script src> at your own host (no inlining):
ECHARTS=https://artifacts.corp.example/echarts@5/echarts.min.js \
    ./run_awr_trend.sh user/pw@svc
```

| `echarts` value | What happens |
|-----------------|--------------|
| *(empty, default)* | Loads ECharts from the public CDN. Unchanged behaviour |
| an `http(s)` URL | Used verbatim as the `<script src>` — an internal mirror on an air-gapped network. Works on the pure-SQL\*Plus path too |
| a local file path | The wrapper **inlines** the file into the report → a single self-contained, offline-capable HTML file |

A copy of `echarts.min.js` (Apache-2.0, v5.6.0) **ships in this repo** under
`vendor/`, so `ECHARTS=vendor/echarts.min.js` works out of a fresh clone with
no internet — ideal for air-gapped hosts. You can also point `ECHARTS` at any
other copy you keep elsewhere. See `vendor/README.md` for provenance and how to
bump the pinned version.

Notes:
- The inlining step lives in the `run_awr_trend.sh` wrapper. On the pure
  SQL\*Plus path a local file path is emitted as a `<script src>` (not
  inlined), so for a truly single self-contained file use the wrapper, or
  set `echarts` to an `http(s)` mirror URL. The configurator's printed
  SQL\*Plus block flags this with an `# NB:` note.
- The inlined file is read as-is; pin a version you trust. This toolkit is
  tested against ECharts 5.
- This adds roughly the size of `echarts.min.js` (~1 MB) to each generated
  report.

### Archive the output (zip)

Both wrappers can package the finished output into a single archive
alongside it, via `ARCHIVE` (single-DB) / `FLEET_ARCHIVE` (fleet) — off by
default, so behaviour is unchanged unless you opt in:

```bash
ARCHIVE=zip ./run_awr_trend.sh user/pw@svc                 # reports/awr_trend_..._run<id>.zip
FLEET_ARCHIVE=auto ./run_awr_fleet.sh fleet.conf            # reports/awr_fleet_<ts>_run<id>.zip
```

| Value | Meaning |
|-------|---------|
| *(empty)*, `0`, `N`, `no`, `off` | Disabled (default) |
| `1`, `Y`, `yes`, `on`, `auto` | Auto-pick: `zip` if it's on `PATH`, else `tar`+`gzip` (`.tar.gz`), else plain `tar` (`.tar`) — a one-line note on stderr explains any fallback |
| `zip` | Force zip; errors out if `zip` isn't on `PATH` |
| `tgz` | Force `tar` piped through `gzip` (`.tar.gz`); errors out if `gzip` isn't on `PATH` |
| `tar` | Force a plain, uncompressed `tar` |

What goes in the archive differs by wrapper, since the two reports are
shaped differently:
- **Single-DB (`ARCHIVE`)** — the archive holds just the one finished
  `.html` report (after any `ECHARTS` inlining), as the archive's only,
  bare-filename entry: `reports/<report-basename>.<zip|tar.gz|tar>`.
- **Fleet (`FLEET_ARCHIVE`)** — the archive holds the **entire per-run
  output folder** (`reports/awr_fleet_<ts>_run<id>/`, i.e. `index.html`
  plus every `detail_<alias>.html`), with that folder itself as the
  archive's single top-level entry, so unzipping reproduces the folder
  intact: `reports/awr_fleet_<ts>_run<id>.<zip|tar.gz|tar>`. It's applied
  both after a live run and after `./run_awr_fleet.sh --assemble
  <workdir>`. The `fleet_work_<id>/` extract workdir is never included.

A pre-existing archive of the same name is overwritten. Archiving is applied
last — after the report is already written successfully — so a failure to
archive never destroys the report itself; it prints a `warning:` on stderr
and the wrapper exits `4` instead of `0` (documented in each script's
`--help`/usage text) so automation can tell the difference.

**AIX note:** AIX's bundled `tar` has no compression flag at all (no `-z`),
so this toolkit never shells out to it — `tgz` always pipes plain `tar`
through a separate `gzip` process instead. `zip` on AIX comes from the AIX
Toolbox for Linux Applications; when it isn't installed, `ARCHIVE=auto` /
`FLEET_ARCHIVE=auto` quietly falls back to `tgz`, then to plain `tar` if
even `gzip` is missing.

## Read the report

A sticky **top bar** names the database and the **Current** window ("vs N
prior windows, every 1w") and carries the view switch and the dark-mode
toggle. The report has three views of the same numbers:

- **Summary** (the default) — the answer first.
- **Timeline** — every compared window side by side, oldest first.
- **All sections** — every table and chart of the report, in full.

The top-bar switch remembers your choice in `localStorage`; a link can
force a view with `#view=summary|timeline|all`. Any link to a row in
another view switches to that view, opens whatever folds it and flashes
the row. With JavaScript off, every section shows, stacked.

**Activity, whole span** opens every view, above the verdict: two stacked
charts of ASH active sessions across the whole compared span on one time
axis, **by wait class** and **by wait event** (the 14 busiest events, on
CPU as `CPU`, the rest summed as *Other events*), stacked areas, hourly
(or the sub-hour cadence), the compared windows striped (Current indigo,
pinned amber, skipped grey), release markers on top. Zoom to 6 hours or
less over a compared window and both charts switch to **1-minute detail**
inside the windows (the range label says so; at most 40000 minutes of
windows, the most recent first). Hover for each series' value (the
crosshair shows on both charts), click a legend entry to hide a series,
drag across either chart to zoom both, double-click or **Reset zoom** to
go back, click a window stripe to pin it. **Hover a wait class or event**
(its legend entry, or keyboard focus) to highlight it: it is redrawn from
zero with the y axis fitted to it, the other series faded above, so its
shape over time reads directly; a class also lights its events in the event
chart (and an event its class). Hovering a band in the plot highlights it in
place; click the band, or Shift+click the legend entry, to keep the
highlight; the same again or **Esc** clears it (the next Esc unpins the
window).

### Summary

1. **Verdict** — one sentence built from the findings ("DB time up 80%,
   mostly wait: physical I/O", or "Nothing moved beyond its normal range"),
   a **Likely source** line (the plan change, new SQL, or the segment the
   reads landed on) and count pills (findings, metrics moved, plan change,
   parameters that differ, skipped windows, metrics normal).
2. **DB time per window** — one bar per compared window, the Current one
   last and in the accent colour, with its normal range, Δ vs the prior
   mean and the band glyph (below).
3. **Findings** — one **card per family** of metrics that moved (physical
   I/O, DB time, network, commit, parsing, writes and redo, any other wait
   class): the lead metric's value and normal range, its per-window bars,
   up to four evidence rows (the event, segment, file or statement behind
   it, each a link to its table row), the related metrics that moved with
   it, and a "Timeline →" link.
4. **What changed around it** — a card per **plan change** (elapsed per
   window, the plan-hash step line, per-execution / SQL Monitor / CPU
   evidence) and a **configuration** card (parameters that step between
   windows), placed under the release markers they follow.
5. **Checked and normal** — the metrics that stayed in range, the ones
   that moved too little to matter, and the ones that improved.
6. **Evidence library** — every other section as one line with its
   status ("4 of 14 events moved", "none differ"); click a line to open the
   section in place. Top SQL and Foreground waits open by default.

**The band glyph** is how every scored row reads: *Normal range* (prior
mean ± 2σ) · a dot on a −4σ … +8σ axis over the shaded ±1σ / ±2σ zones
(filled red = large, amber = moderate, green = improved, hollow = typical)
· the z-score · the change vs the prior mean (`▲ ×4.2` from twice the
mean, else a percentage). The **Trend** cells of the tables are 13-bar
micro strips: one bar per window from zero, the normal zone shaded, Current
last. The **Reading the charts** guide and **About this report** at the end
of every view explain each chart and every method note.

### Timeline

Under the Activity charts, the **window grid**: one
column per compared window with lanes for activity, the headline and
flagged metrics, waits, the segments / files the reads land on, Top SQL
(◆ plan change, ✚ first seen) and SQL Monitor, and parameter step lines.
Click a date in the ruler (or a window stripe in either Activity chart) to
**pin** that window: every Δ in the grid is re-based against it; `Esc` or
the Current column clears the pin (switching views keeps it). The Day profile (with `profile_days > 0`) follows.

### All sections

Every section, full size: Findings (one table per domain with the band
columns), Load profile, System metrics, Foreground / Background waits, Top
SQL (five rankings as tabs + bump chart + the per-SQL pool), Top SQL ASH
cards, SQL Monitor, Segment I/O, File I/O, Parameter changes, the hourly
ASH timeline, DB time over the span, Utilization, Windows (begin / end
snap ids, skipped windows and why) and the Day profile.

- **Windows** — restart, a DBID change, a missing snapshot or one more
  than 15 min off the window edge SKIPS a window; it is excluded from the
  baseline and struck through in the Timeline ruler.
- **Findings** — `|z| > 3` large, `|z| > 2` moderate, only when the move
  is material (see the policy below); fewer than 3 valid prior windows =
  "too little history".
- **Top SQL, Segment I/O, File I/O** are **ranked, not scored**: they
  show where the time and I/O went, not whether it is abnormal.
- **SQL Monitor** — persisted SQL Monitor executions per statement, with a
  Plan hash column, errors and DOP downgrades.

### The navigation rail & dark mode

The **rail** on the left follows the view: Summary lists the verdict, one
link per finding card and the library; Timeline lists its lanes; the rest
of the links dim when their section is not in the current view, with a
"+ N more in All sections" line. Each link carries a live status dot and
crit / warn counts; `J` / `K` jump between findings; the row filter
(`⌘K` / `Ctrl+K`, `Esc` to clear) narrows every table to matching rows.

The sun/moon button in the top bar toggles **dark mode**. The first load
follows your OS `prefers-color-scheme`; after that your choice is
remembered in `localStorage` and applied before first paint.

Every table supports **click-to-sort** on its column headers; any table
with 4+ rows gets a toolbar for **copying as CSV or Markdown**; hovering a
section heading reveals a `#` permalink; long detail tables collapse their
tail behind a "Show N more rows" link. Click a per-window column header to
highlight that window across every table and chart. None of this needs the
network or a re-run.

### Per-metric policy: direction and floors

Every scored name -- each load statistic, each system metric, each wait
class and event -- has its own line in `sql/lib/metric_policy.plsql`
saying which **direction** is bad news (`UP`, `DOWN`, `ANY` or `INFO`)
and how big a move must be to matter (a minimum |%-delta| and a value
floor in the metric's own unit; for waits, a minimum share of the Current
window's wait time). A move in the good direction -- fewer physical reads,
a lower read latency, fewer hard parses -- is tagged **improved** and is
never highlighted, never leads a finding card and never counted in the verdict; a
purely informational counter that moved is **noted**. The file is a plain
one-line-per-metric table meant to be edited: change a floor or a
direction there and every section (verdict, finding cards, findings
tables, DB time strip, wait tables, day profile, likely-source line)
follows. The generated reference
[docs/metric_policy.html](docs/metric_policy.html) lists every metric,
class and event with its direction, floors, when it fires and when it
does not (`python3 docs/gen_policy_doc.py` regenerates it).

## Fleet report (many databases)

`run_awr_fleet.sh` runs the same aligned-window comparison across a whole
list of databases and stitches the results into **one** self-contained,
worst-database-first HTML page — a triage sweep, not a deep dive. It is a
companion to `run_awr_trend.sh` (the single-DB, full-detail tool), not a
replacement. The report is an **ops console**: one dense table with a
collapsed summary row per database (status dot, severity score, crit/warn
pills, current AAS, worst finding, DB-time sparkline, and a 24-hour
ASH-by-wait-class ribbon) that you click to expand into a detail panel — a
tall 24h ASH timeline with labeled marker lines, headline metric cards, the
findings table, the Top-SQL table, and the exact `./run_awr_trend.sh …`
command to drill into that database. A toolbar above the table lets you
filter by name, sort by score/name/AAS/errors-first, show only crit/warn+
rows, and expand or collapse every row at once — all client-side, no
re-run.

```bash
./run_awr_fleet.sh fleet.conf                          # defaults (AUTO, 1h, 4 back)
./run_awr_fleet.sh fleet.conf '2026-04-15 09:00' 1 4 10 1 h   # explicit window, hourly
FLEET_PAR=8 FLEET_TIMEOUT=300 ./run_awr_fleet.sh fleet.conf   # 8 at a time, 5-min cap/DB
MARKERS='2026-04-15 09:30|deploy' ./run_awr_fleet.sh fleet.conf   # mark an event on every ASH chart
FLEET_ARCHIVE=auto ./run_awr_fleet.sh fleet.conf       # also zip/tar the whole run folder
./run_awr_fleet.sh --assemble reports/fleet_work_<id>  # re-stitch a kept workdir, no DB
```

Arguments (all but `fleet.conf` optional, left to right):
`fleet.conf target_end win_hours weeks_back top_n step step_unit` — the same
meanings as the single-DB wrapper. There is **no `inst_num` argument**: a
fleet pass always queries with `inst_num=0` (aggregate across RAC); drilling
into one instance is a job for the single-DB report.

**`fleet.conf` format** — one `alias|connect` per line; blank lines and
`#` comments ignored. The alias is a short label (`[A-Za-z0-9_.-]`, ≤30
chars) shown on the row; the connect string is anything `sqlplus` accepts.
Wallet / OS-auth connects (`/@tns_alias`, `/ as sysdba`) keep passwords out
of the file entirely and are recommended:

```
# alias        | connect
prod-emea      | /@PRODEMEA
prod-amer      | /@PRODAMER
reporting      | reporting_ro/@RPT
```

See [`fleet.conf.example`](fleet.conf.example). A `user/pw@svc` password is
masked to `user/***@svc` everywhere it is displayed (table rows, drill-down
lines) and is never written to the workdir or the report — but a wallet or
`/@tns` connect keeps it out of the config file in the first place.

**How a database is scored and sorted.** Each reachable database gets a
score `10×critical + 3×warning + min(25, top-SQL points)`; rows sort by
score descending (ties keep config order), so the database that most needs
attention is first. "Critical"/"warning" are the count of curated metrics
whose current window moved past 2σ / a moderate threshold of its own prior
baseline (the same z-model as the single-DB findings section, over a lean
`fleet` template of load stats, metrics and wait events). Top-SQL points
come from SQL that crossed the regression floors (≥5 s elapsed **and** 2σ
or ≥25 % above its prior mean; or ≥0.1 s/exec slower with ≥3 executions).

**Silence never reads as healthy.** A database that is unreachable, times
out, or spools a truncated fragment surfaces as a red **error row** (with
the masked connect and the last 15 log lines) sorted to the very top — it is
never quietly dropped. Exit code: `0` = report written and at least one
database was OK; `3` = report written but every database failed; `2` = a
usage / bad-config error before anything ran.

**Environment variables:**

| Var               | Default | Meaning                                                        |
|-------------------|---------|----------------------------------------------------------------|
| `FLEET_PAR`       | `4`     | Max concurrent per-DB `sqlplus` runs                           |
| `FLEET_TIMEOUT`   | `900`   | Per-DB wall-clock limit (seconds); needs `timeout`/`gtimeout` on PATH, else unbounded with a one-time warning |
| `FLEET_TEMPLATE`  | `fleet` | `sql/lib/templates/<name>` to score against                    |
| `FLEET_KEEP_WORK` | `0`     | `1` = keep the per-run `reports/fleet_work_<id>/` workdir even when every DB succeeded (it is always kept if any DB errored, so `--assemble` can re-run) |
| `MARKERS`         | (none)  | Inline fleet-wide timeline markers, one string of `WHEN\|LABEL` entries joined by `;;` (WHEN = `YYYY-MM-DD HH:MM`), drawn on every DB's 24h ASH chart within its span and in the masthead legend; malformed entries are warned and skipped |
| `MARKER_FILE`     | (none)  | A file of `WHEN\|LABEL` lines, same format; **wins over `MARKERS`** when both are set |
| `FLEET_PROFILE_DAYS` | `0`  | `N > 0` adds a **Day profile** band to every DB's detail row — each hour of the 24 h ending at `target_end` vs the same hour on the N prior days, as an inline-SVG heatmap (hour × metric, signed z) — and passes `profile_days=N` into the per-DB detailed reports. Informational only: never changes a row's score or sort order |
| `FLEET_ARCHIVE`   | (empty) | Also zip/tar the **entire per-run output folder** (`index.html` + every `detail_<alias>.html`) as a sibling archive, applied after both a live run and `--assemble`. Same value semantics as the single-DB `ARCHIVE` var. See "Archive the output (zip)" above |

**By design (not limitations).** The fleet report is deliberately lean: it
ships **inline-SVG only — no ECharts**, so it is offline-complete by
construction (the 24h ASH ribbons, timelines, sparklines and marker lines
all render from inline SVG). Every database is queried in RAC-aggregate mode
(`inst_num=0`), against a lean curated `fleet` template. For per-instance
detail or the full section set, open the single-DB report via the drill-down
command on the row.

## AWR Fleet Server (hosted scheduler + web UI)

`server/` is an optional, separate add-on: a small pure-stdlib Python web
app that runs `run_awr_fleet.sh` on a schedule and on demand, serves the
generated reports, and keeps a run history with live log tails. It is
**orchestration only** — it shells out to the exact same wrapper described
above and never reimplements or edits any generator file.

```bash
cp server/server.conf.example server/server.conf   # edit conf_path + window params
python3 server/awrserve.py -c server/server.conf
```

Then open `http://127.0.0.1:8765/`. No authentication by default — see
`server/README.md` for the full security notes, deployment examples
(systemd / Docker / nohup for AIX), and the test suite
(`python3 -m unittest discover server/tests`).

## Does it write to the database?

No. Every fact in the report is computed in-flight from the `DBA_HIST_*`
views; the driver and every numbered section only issue `SELECT` — this is
equally true of the fleet extract (`awr_fleet_extract.sql`), which spools
HTML fragments and touches no database objects. The report is the only
output — re-run `awr_trend.sql` (or `run_awr_fleet.sh`) whenever you want a
fresh view. You can run it safely against production or read-only
standbys (assuming the standby exposes AWR).

## Side script: weekly AWR baselines (optional)

This is the **only** script that writes to the database, and it is
entirely separate from the main report. It creates one
`DBA_HIST_BASELINE` entry per ISO week so you can later compare weeks
with `awrddrpt.sql` / OEM directly.

```bash
sqlplus user/pw@svc @side/baselines_defaults.sql @side/create_weekly_baselines.sql
```

Defaults (from `side/baselines_defaults.sql`): creates a baseline for the
last completed ISO week, name `WK_<IYYY>_<IW>` (e.g. `WK_2026_16`).
Idempotent.

Override (set DEFINEs before `@`-loading the script — they are NOT
clobbered by defaults, so don't `@` `baselines_defaults.sql` here):

```sql
SQL> DEFINE weeks_back  = 4
SQL> DEFINE prefix      = 'WK_'
SQL> DEFINE expire_days = 365
SQL> @side/create_weekly_baselines.sql
```

## File layout

```
.
├── awr_trend.sql                    -- driver (pure SELECT, one spooled HTML)
├── run_awr_trend.sh                 -- single-DB wrapper + interactive configurator
├── run_awr_fleet.sh                 -- fleet wrapper: run+assemble across many DBs
├── awr_fleet_extract.sql            -- lean per-DB fleet extractor (spools fragments)
├── fleet.conf.example               -- fleet config template (alias|connect per line)
├── markers.example.sql              -- example timeline-marker config (optional)
├── sql/
│   ├── defaults.sql                 -- canonical default DEFINEs
│   ├── _style.sql                   -- shared CSS (emitted once)
│   ├── 00_params.sql                -- top bar, rail, views, verdict, Timeline skeleton
│   ├── 01_windows.sql               -- snapshot window matching
│   ├── 02_load_profile.sql          -- SYSSTAT deltas (per template)
│   ├── 03_sysmetric.sql             -- SYSMETRIC averages (per template)
│   ├── 04_waits_fg.sql              -- foreground waits (per template)
│   ├── 05_waits_bg.sql              -- background waits (per template)
│   ├── 06_top_sql.sql               -- Top-N SQL
│   ├── 07_summary.sql               -- z-score findings: Summary cards + per-domain tables
│   ├── 08_overview.sql              -- Summary strip: DB time per window
│   ├── 09_ash_timeline.sql          -- hourly ASH timeline + the Activity charts' payloads (+ 1-min detail)
│   ├── 10_db_time_summary.sql       -- full-span DB time stacked area
│   ├── 11_top_sql_ash_breakdown.sql -- per-Top-N-SQL ASH cards
│   ├── 12_param_changes.sql         -- parameters that differ across windows (+ config card)
│   ├── 13_utilization.sql           -- database utilization profile (usage overview)
│   ├── 14_segment_io.sql            -- top segments by I/O per window
│   ├── 15_file_io.sql               -- per-file / file-type I/O deltas
│   ├── 16_day_profile.sql           -- Day profile: hour-of-day vs N prior days (profile_days > 0)
│   ├── 17_narrative.sql             -- verdict pieces: likely source, pills, notes (runs last)
│   ├── 18_sqlmon.sql                -- SQL Monitor summaries (+ plan-change card)
│   ├── 19_reference.sql             -- "Reading the charts" guide + About this report
│   ├── fleet/                       -- fleet-report sections (spooled by awr_fleet_extract.sql)
│   │   ├── 00_fleet_chrome.sql      -- shared page head/CSS/JS + inline-SVG renderers
│   │   ├── 01_row.sql               -- summary row + detail scaffold + ASH bands
│   │   ├── 02_ash.sql               -- ASH payloads (by wait class / by event)
│   │   ├── 03_headline.sql          -- headline metric mini-cards
│   │   ├── 04_findings.sql          -- z-score findings table (|z|>2 rows only)
│   │   ├── 05_topsql.sql            -- gated top-SQL regressions
│   │   ├── 06_day_profile.sql       -- Day profile heatmap band (FLEET_PROFILE_DAYS > 0)
│   │   ├── 06b_sqlmon.sql           -- always-on SQL Monitor summary band (informational)
│   │   ├── 07_close.sql             -- drill-down command + OK sentinel
│   │   └── defaults.sql             -- fleet-only default DEFINEs
│   └── lib/                         -- shared @@-included fragments (CTEs, JS, helpers)
│       ├── day_profile_cte.sql      -- hour-of-day x N-day matrix (shared by 16 + fleet 06)
│       ├── fmt_num.plsql            -- consistent value-cell number formatting (fmt_num/fmt_int)
│       ├── band_glyph.plsql         -- band glyph + Δ cells (Normal range | band | z | Δ)
│       ├── anchor_id.plsql          -- stable row ids for entity links
│       ├── finding_cards.plsql      -- finding-card vocabulary (families, labels, units, ent())
│       ├── wingrid.plsql            -- per-window bar grid (strip, cards, Timeline)
│       ├── timeline.plsql           -- Timeline lane rows
│       ├── js_wingrid.plsql / js_timeline.plsql / js_microstrip.plsql
│       │                            -- client scripts, generated from src/*.js by tools/js2plsql.sh
│       ├── js_markers.plsql         -- inits window.AWR_MARKERS + AWR_markLine()
│       ├── marker.sql               -- emit one timeline marker (used by marker_file)
│       ├── markers_inline.sql       -- file-free markers parser (used by the MARKERS var)
│       ├── no_markers.sql           -- no-op stub when no markers are set
│       └── templates/               -- per-template metric + wait-event lists
│           ├── comprehensive/       -- default; full curated lists
│           │   ├── sysstat_load_targets.sql
│           │   ├── sysmetric_targets.sql
│           │   └── wait_event_targets.sql   -- '*' sentinel = no filter
│           ├── simple/              -- triage-friendly subset
│           │   ├── sysstat_load_targets.sql
│           │   ├── sysmetric_targets.sql
│           │   └── wait_event_targets.sql
│           └── fleet/               -- lean set the fleet report scores against
│               ├── sysstat_load_targets.sql
│               ├── sysmetric_targets.sql
│               └── wait_event_targets.sql
├── side/
│   ├── baselines_defaults.sql      -- canonical defaults for the baselines script
│   └── create_weekly_baselines.sql -- optional, AWR baselines (writes)
└── reports/                         -- generated HTML files
```

## Caveats

- Designed for the default hourly AWR snapshot interval. Shorter intervals
  work; longer intervals may reduce to a 2-snap window per hour.
- For an hourly cadence (`step_unit=h`), each compared window must contain
  at least one full AWR snapshot interval — if `win_hours = 1` and your
  AWR snap interval is also 1 hour, a single window covers exactly one
  snap pair, so all of section 02 / 04 / 05 / 06's deltas come from that
  one pair. Cut the snap interval to 30 minutes (`DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS`)
  or set `win_hours` ≥ 2 if you want intra-window resolution.
- Instance restarts inside a window invalidate that window for the
  baseline; the window is still shown but flagged and excluded.
- Results assume RAC nodes were all up for the window (per-instance mode
  filters by `instance_number`; aggregate mode sums across instances).
- Pluggable databases: run as a user in the container you want to analyse.
  The `dbid` is resolved from `v$database` at run time.
- Because every number is recomputed on each run, comparing the HTML of
  two runs is the only way to look at historical output — there is no
  scratch schema to query. If you need persisted facts, pipe the
  generated HTML through a parser or spool the relevant
  `DBA_HIST_*` queries yourself.
