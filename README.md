# AWR Timeline Comparison

**Project website (screenshots, live example reports, cheat sheet):**
<https://davidbudac.github.io/awr_timeline_comparison/>

Pure-SQL Oracle 19c toolkit that compares AWR snapshots across a series
of **aligned windows** — by default the same hour of the week across the
last four weeks (e.g. Mon 09:00–10:00 today vs the four prior Mondays
09:00–10:00) — flags drastic changes via z-score, and renders a readable
single-file HTML report. The cadence between windows is configurable
(weekly, daily, hourly, or any multiple) so the same toolkit can do
"last four hours, hour by hour", "every other day for the past two
weeks", "every fourth Monday for a quarter", etc. **Read-only:** the
script does not create, modify or delete any database objects — it only
issues `SELECT` against `DBA_HIST_*`.

Requirements: Oracle Database 19c with the **Diagnostic + Tuning Pack**
licensed (needed for `DBA_HIST_*` and `DBA_HIST_SQLSTAT`).

## Install

Nothing to install in the database. Connect as a user (typically DBA)
that can read the AWR views listed below, and run the driver directly.

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

**New to it, or don't want to memorize the argument order?** Run the
interactive configurator. It walks you through every option (with a short
explanation, a sensible default and input validation for each), then prints
*both* a ready-to-paste `./run_awr_trend.sh` command and the equivalent
pure-SQL\*Plus block, and offers to run the report right away:

```bash
./run_awr_trend.sh --configure     # also: -c, -i, --interactive,
                                   # or just run with no arguments
```

Easiest non-interactive — the shell wrapper (sets all substitution vars for you):

```bash
./run_awr_trend.sh user/pw@svc                                  # defaults
./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0      # explicit weekly
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h                # last 4 hours straight back
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple         # lean triage report
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple Y       # simple + progress markers on stdout
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive N my_markers.sql  # annotate timelines with milestones
MARKERS='2026-06-10 09:00|Release 2.0' ./run_awr_trend.sh user/pw@svc  # file-free inline markers
ECHARTS=vendor/echarts.min.js ./run_awr_trend.sh user/pw@svc           # self-contained / offline HTML
```

Arguments: `connect_string [target_end [win_hours [weeks_back [top_n [inst_num [step [step_unit [template [debug [marker_file]]]]]]]]]]`

Plus three environment variables: `MARKERS` for file-free inline timeline
markers (see "Timeline markers" below), `ECHARTS` to control where the
chart library loads from / make the report self-contained (see "Offline /
self-contained report" below), and `DBIDS` to pin which AWR DBID(s) the
report trends (see "Choosing the AWR DBID(s)" below).

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
| `MARKERS` *(env var)* | *(empty)* | File-free alternative to `marker_file`: inline `WHEN\|LABEL` milestones joined by `;;`. `marker_file` wins when both are set. See "Timeline markers" below |
| `ECHARTS` *(env var)* | *(empty)* | Where the ECharts chart library loads from. Empty = public CDN (`cdn.jsdelivr.net`). An `http(s)` URL = used as-is (internal mirror). A local file path = inlined into the report for a single self-contained, offline-capable HTML file. See "Offline / self-contained report" below |
| `DBIDS` *(env var)* | *(empty)* | Which AWR DBID(s) to trend. Empty = auto-resolve from the data (the container's own `CON_DBID` plus disjoint earlier pre-migration history; an *overlapping* repository — e.g. the CDB root's AWR visible inside a PDB under a different DBID — is excluded). Set to one DBID or a comma list to pin it. Equivalent pure-SQL\*Plus DEFINE: `dbids`. See "Choosing the AWR DBID(s)" below |

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
every calendar-axis chart: the masthead strip, the ASH timeline, the
DB-time summary, and the per-SQL ASH cards.

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
- Markers are chart-only: with the ECharts CDN blocked they don't draw,
  and the per-window sparkline tables (Load / Metrics / Waits) never carry
  them since those aren't calendar timelines.

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
SQL> DEFINE markers     = ''                 -- optional file-free markers; '' for none
SQL> @awr_trend.sql
```

Output: `reports/awr_trend_<DBID>_<YYYYMMDDHH24MI>_run<run_id>.html`. Open
it in a browser. The report is self-contained (one HTML file with inline
CSS and inline SVG sparklines; by default the larger charts load ECharts
from `cdn.jsdelivr.net` and degrade gracefully when the CDN is blocked).
For a **fully offline** report — charts and all — see "Offline /
self-contained report" below.

### Offline / self-contained report

By default only one thing in the report reaches the network: the Apache
ECharts library that draws the larger visualizations (hero strip, wait
stacked bars, findings heatmap, top-SQL bump chart, ASH timeline). When
the CDN is blocked the report still opens and every table renders — an
amber "Charts hidden" banner explains why, and the inline-SVG sparklines
still draw. To make the report render its charts with **no network at
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

### Choosing the AWR DBID(s)

AWR snapshots are keyed by **DBID**, and a database can have more than one
in its history — most often after a **non-CDB is plugged in as a PDB**
(pre-plug snapshots keep the old non-CDB DBID; new ones use the PDB's
`CON_DBID`) or after a `nid` / rename. The report stitches such history
together: every `DBA_HIST_*` filter uses `dbid IN (...)`, not a single DBID.

By default the DBID set is **auto-resolved from the data** — no flags needed.
The rule: anchor on the current container's `CON_DBID`, then add only DBIDs
whose history *ends before* the anchor's first snapshot (genuine disjoint
pre-migration history). A DBID whose snapshots **overlap** the anchor's in
wall-clock time is **excluded**. This matters inside a PDB: the CDB root's AWR
repository is sometimes visible there under a *different* DBID covering the
same recent period. Including it would double-count load and make every recent
comparison window resolve its begin/end snaps under different DBIDs — so the
report would invalidate them as *"DBID changed inside window"* and show
em-dashes. Excluding the overlapping repository fixes both.

Diagnose what's in your AWR (read-only):

```sql
SELECT dbid,
       TO_CHAR(MIN(begin_interval_time),'YYYY-MM-DD HH24:MI') AS first_snap,
       TO_CHAR(MAX(end_interval_time)  ,'YYYY-MM-DD HH24:MI') AS last_snap,
       COUNT(*) AS snaps
FROM   dba_hist_snapshot
GROUP BY dbid
ORDER BY MAX(end_interval_time);
```

If the heuristic ever picks the wrong set, **pin it explicitly** with `DBIDS`
(wrapper) or the `dbids` DEFINE (pure SQL\*Plus) — a single DBID or a comma
list. Only DBIDs that own snapshots are kept; spaces are ignored.

```bash
# Trend just this PDB's own AWR (its CON_DBID), ignoring an overlapping repo:
DBIDS=3730626044 ./run_awr_trend.sh user/pw@pdb

# Stitch two specific DBIDs (e.g. across a deliberate migration boundary):
DBIDS=3730626044,4012345678 ./run_awr_trend.sh user/pw@pdb
```

In an ordinary single-DBID database (and in the CDB root / a non-CDB) the
auto-resolution is a no-op — output is byte-identical to leaving `DBIDS` empty.

## Read the report

The header card at the top lists **which windows were compared** —
the current window plus the prior windows, stepped back by `step ×
step_unit` each time (default: 7 days), with explicit start → end
timestamps so you always know exactly what baseline is driving the
z-scores.

1. **Overview** — hero strip with the six headline load/metric numbers.
2. **ASH timeline** — hourly stacked-area chart of Active Sessions by wait
   class from `DBA_HIST_ACTIVE_SESS_HISTORY`, covering the full compare
   span; compared windows are highlighted as background bands. If you pass
   a `marker_file`, your milestones appear here (and on the other dated
   charts) as vertical dashed lines — see "Timeline markers" above.
3. **Findings** — each metric with `|z|>3` is CRITICAL, `|z|>2` is WARN.
   Metrics with fewer than 3 valid prior windows fall back to a
   `%`-delta only.
4. **Windows** — the compared windows used, with begin/end snap_ids.
   Windows where the instance restarted mid-window are SKIPPED and
   excluded from the baseline.
5. **Load profile** — per-second rates for the classic AWR "Load Profile"
   stats incl. redo size.
6. **System metrics** — averages from `DBA_HIST_SYSMETRIC_SUMMARY`.
7. **Foreground waits** — top-N events + wait-class rollup.
8. **Background waits** — from `DBA_HIST_BG_EVENT_SUMMARY`.
9. **Top SQL** — ranked 5 ways (elapsed, CPU, buffer gets, physical
   reads, executions) with plan-change badges and full SQL text.
10. **Segment I/O** — segments (and object types) with the most I/O
    activity per window from `DBA_HIST_SEG_STAT`: physical reads/writes
    (blocks) and read/write requests, one line per top segment across
    windows with a per-object-type rollup toggle.
11. **File I/O** — data/temp files with the most I/O per window from
    `DBA_HIST_FILESTATXS` / `DBA_HIST_TEMPSTATXS` (data read/written in
    MB plus read/write requests), with a toggle to the AWR-report-style
    "IOStat by Filetype" view from `DBA_HIST_IOSTAT_FILETYPE` covering
    all database I/O (control file, redo log, archive log, …).
12. **Parameter changes** — initialization parameters from
    `DBA_HIST_PARAMETER` whose value differs across the compared windows,
    pivoted parameter × window (value as of each window's end snapshot).

### The navigation rail & dark mode

The report opens with a fixed **navigation rail** down the left edge: a
scrollspy-tracked link per section, each with a small live status dot
graded from that section's own content (red for a critical finding, amber
for a warning, neutral otherwise) so you can see at a glance where the
trouble is before scrolling. Under 980px the rail collapses to a stacked
layout.

A sun/moon button in the rail's brand row toggles **dark mode** (the
"Slate Instrument" theme). The first load follows your OS
`prefers-color-scheme`; after that your choice is remembered in
`localStorage`, and the theme is applied before the charts initialize so
there's no flash. Two more toggles sit at the foot of the rail —
**Essential rows** and **Application only**, described next. All of this is
purely client-side CSS/JS: no re-run, no DEFINE, and it all works offline.

### "Application only" view

The rail foot carries an **Application only** toggle.
Click it to strip the report down to *application* behaviour on the database:
it hides every system-wide section (load profile, system metrics, FG/BG waits,
ASH timeline, DB time, findings, windows, parameters) plus the masthead verdict
and DB-time strip, leaving only **Top SQL**, **Top SQL ASH breakdown**,
**Segment I/O**, **File I/O**, and **Utilization**. Within those, SQL parsed by
an Oracle-maintained schema (`SYS`, `SYSTEM`, `XDB`, `DBSNMP`, …) — i.e.
recursive/background SQL from Oracle itself — is filtered out of the tables,
charts, and per-SQL detail cards, so you see only your own application's SQL.
Click again (now labelled **Show all**) to restore the full report. It's a
purely client-side toggle — no re-run needed, and it works offline.

### "Essential rows" preset

The rail also carries an **Essential rows** toggle. When on, the Load profile,
System metrics, FG/BG wait tables, and the Findings summary load/metric
detail tables collapse to a short curated list of the rows a DBA scans first
(DB time, DB CPU, AAS, single-block read latency, log file sync, …); each
affected section header shows a pill with the kept/total row count. Rows
flagged **crit**/**warn** stay visible even when not on the curated list, so
the preset never hides an anomaly, and the Findings wait-class rows — already
a compact high-level rollup — always stay visible. Charts (including the
findings heatmap) are untouched. Like the other toggles it is purely
client-side and works offline; click again to show all rows.

## Fleet report (many databases)

`run_awr_fleet.sh` runs the same aligned-window comparison across a whole
list of databases and stitches the results into **one** self-contained,
worst-database-first HTML page — a triage sweep, not a deep dive. It is a
companion to `run_awr_trend.sh` (the single-DB, full-detail tool), not a
replacement: each fleet card links the exact `./run_awr_trend.sh …` command
to drill into that database.

```bash
./run_awr_fleet.sh fleet.conf                          # defaults (AUTO, 1h, 4 back)
./run_awr_fleet.sh fleet.conf '2026-04-15 09:00' 1 4 10 1 h   # explicit window, hourly
FLEET_PAR=8 FLEET_TIMEOUT=300 ./run_awr_fleet.sh fleet.conf   # 8 at a time, 5-min cap/DB
./run_awr_fleet.sh --assemble reports/fleet_work_<id>  # re-stitch a kept workdir, no DB
```

Arguments (all but `fleet.conf` optional, left to right):
`fleet.conf target_end win_hours weeks_back top_n step step_unit` — the same
meanings as the single-DB wrapper. There is **no `inst_num` argument**: a
fleet pass always queries with `inst_num=0` (aggregate across RAC); drilling
into one instance is a job for the single-DB report.

**`fleet.conf` format** — one `alias|connect` per line; blank lines and
`#` comments ignored. The alias is a short label (`[A-Za-z0-9_.-]`, ≤30
chars) shown on the card; the connect string is anything `sqlplus` accepts.
Wallet / OS-auth connects (`/@tns_alias`, `/ as sysdba`) keep passwords out
of the file entirely and are recommended:

```
# alias        | connect
prod-emea      | /@PRODEMEA
prod-amer      | /@PRODAMER
reporting      | reporting_ro/@RPT
```

See [`fleet.conf.example`](fleet.conf.example). A `user/pw@svc` password is
masked to `user/***@svc` everywhere it is displayed (cards, drill-down
lines) and is never written to the workdir or the report — but a wallet or
`/@tns` connect keeps it out of the config file in the first place.

**How a database is scored and sorted.** Each reachable database gets a
score `10×critical + 3×warning + min(25, top-SQL points)`; cards sort by
score descending (ties keep config order), so the database that most needs
attention is first. "Critical"/"warning" are the count of curated metrics
whose current window moved past 2σ / a moderate threshold of its own prior
baseline (the same z-model as the single-DB findings section, over a lean
`fleet` template of load stats, metrics and wait events). Top-SQL points
come from SQL that crossed the regression floors (≥5 s elapsed **and** 2σ
or ≥25 % above its prior mean; or ≥0.1 s/exec slower with ≥3 executions).

**Silence never reads as healthy.** A database that is unreachable, times
out, or spools a truncated fragment surfaces as a red **error card** (with
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

**v1 limitations.** The fleet report is deliberately lean: it ships
**inline-SVG sparklines only — no ECharts**, so it is offline-complete by
construction; the theme follows the OS / a saved preference (dark-mode
bootstrap) but there is **no in-page theme-toggle button**; and every
database is queried in RAC-aggregate mode (`inst_num=0`). For per-instance
detail, dated marker lines, the full section set, or interactive charts,
open the single-DB report via the drill-down command on the card.

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
│   ├── 00_params.sql                -- params + header card
│   ├── 01_windows.sql               -- snapshot window matching
│   ├── 02_load_profile.sql          -- SYSSTAT deltas (per template)
│   ├── 03_sysmetric.sql             -- SYSMETRIC averages (per template)
│   ├── 04_waits_fg.sql              -- foreground waits (per template)
│   ├── 05_waits_bg.sql              -- background waits (per template)
│   ├── 06_top_sql.sql               -- Top-N SQL
│   ├── 07_summary.sql               -- z-score findings
│   ├── 08_overview.sql              -- hero strip (headline metrics)
│   ├── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline
│   ├── 10_db_time_summary.sql       -- full-span DB time stacked area
│   ├── 11_top_sql_ash_breakdown.sql -- per-Top-N-SQL ASH cards
│   ├── 12_param_changes.sql         -- parameters that differ across windows
│   ├── 13_utilization.sql           -- database utilization profile (usage overview)
│   ├── fleet/                       -- fleet-report sections (spooled by awr_fleet_extract.sql)
│   │   ├── 00_fleet_chrome.sql      -- shared page head/CSS/JS + sparkline renderer
│   │   ├── 01_db_card.sql           -- per-DB identity strip
│   │   ├── 02_headline.sql          -- hero-six headline sparkline cards
│   │   ├── 03_findings.sql          -- z-score findings table (|z|>2 rows only)
│   │   ├── 04_topsql.sql            -- gated top-SQL regressions
│   │   ├── 05_close.sql             -- drill-down command + OK sentinel
│   │   └── defaults.sql             -- fleet-only default DEFINEs
│   └── lib/                         -- shared @@-included fragments (CTEs, JS, helpers)
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
  The DBID(s) are resolved **from the AWR data**, not `v$database.dbid`
  (which returns the CDB root's DBID inside a PDB). History that spans a DBID
  change is stitched; a repository that overlaps the container's own in time
  (e.g. the root's AWR visible in a PDB) is excluded. Override with `DBIDS` /
  the `dbids` DEFINE — see "Choosing the AWR DBID(s)" above.
- Because every number is recomputed on each run, comparing the HTML of
  two runs is the only way to look at historical output — there is no
  scratch schema to query. If you need persisted facts, pipe the
  generated HTML through a parser or spool the relevant
  `DBA_HIST_*` queries yourself.
