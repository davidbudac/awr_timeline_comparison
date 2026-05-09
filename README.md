# AWR Timeline Comparison

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
GRANT SELECT ON DBA_HIST_ACTIVE_SESS_HISTORY TO <user>;
GRANT SELECT ON V_$DATABASE                  TO <user>;
GRANT SELECT ON V_$INSTANCE                  TO <user>;
-- Only if you use side/create_weekly_baselines.sql (optional, writes baselines):
GRANT EXECUTE ON DBMS_WORKLOAD_REPOSITORY    TO <user>;
```

## Run

Easiest — the shell wrapper (sets all substitution vars for you):

```bash
./run_awr_trend.sh user/pw@svc                                  # defaults
./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0      # explicit weekly
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h                # last 4 hours straight back
```

Arguments: `connect_string [target_end [win_hours [weeks_back [top_n [inst_num [step [step_unit]]]]]]]`

| Arg          | Default | Meaning                                             |
|--------------|---------|-----------------------------------------------------|
| `target_end` | `AUTO`  | Window end — `AUTO` = prior full hour, or `'YYYY-MM-DD HH24:MI'` |
| `win_hours`  | `1`     | Length of each compared window, in hours            |
| `weeks_back` | `4`     | Number of prior windows to compare against (the name is historical; it's just the count) |
| `top_n`      | `10`    | Top-N rows per ranking in Top SQL / waits           |
| `inst_num`   | `0`     | RAC: `0` = aggregate across all instances; `>0` = filter to that instance |
| `step`       | `1`     | Cadence count between adjacent windows              |
| `step_unit`  | `w`     | Cadence unit: `h` (hours), `d` (days), `w` (weeks)  |

`step` × `step_unit` defines the gap between adjacent comparison
windows. `step=1, step_unit=w` (the default) reproduces the original
"same hour-of-week, N prior weeks" behaviour. `step=1, step_unit=h`
gives the last `weeks_back+1` consecutive 1-hour windows. `step=2,
step_unit=d` runs every-other-day. See [CHEATSHEET.md](CHEATSHEET.md)
for ready-to-paste recipes.

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
SQL> @awr_trend.sql
```

Output: `reports/awr_trend_<DBID>_<YYYYMMDDHH24MI>_run<run_id>.html`. Open
it in a browser. The report is self-contained (one HTML file with inline
CSS and inline SVG sparklines; the larger charts load ECharts from
`cdn.jsdelivr.net` and degrade gracefully when the CDN is blocked).

## Read the report

The header card at the top lists **which windows were compared** —
the current window plus the prior windows, stepped back by `step ×
step_unit` each time (default: 7 days), with explicit start → end
timestamps so you always know exactly what baseline is driving the
z-scores.

1. **Overview** — hero strip with the six headline load/metric numbers.
2. **ASH timeline** — hourly stacked-area chart of Active Sessions by wait
   class from `DBA_HIST_ACTIVE_SESS_HISTORY`, covering the full compare
   span; compared windows are highlighted as background bands.
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
9. **Top SQL** — ranked 4 ways (elapsed, CPU, buffer gets, executions)
   with plan-change badges and full SQL text.

## Does it write to the database?

No. Every fact in the report is computed in-flight from the `DBA_HIST_*`
views; the driver and every numbered section only issue `SELECT`. The
report is the only output — re-run `awr_trend.sql` whenever you want a
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
├── sql/
│   ├── defaults.sql                 -- canonical default DEFINEs
│   ├── _style.sql                   -- shared CSS (emitted once)
│   ├── 00_params.sql                -- params + header card
│   ├── 01_windows.sql               -- snapshot window matching
│   ├── 02_load_profile.sql          -- SYSSTAT deltas
│   ├── 03_sysmetric.sql             -- SYSMETRIC averages
│   ├── 04_waits_fg.sql              -- foreground waits
│   ├── 05_waits_bg.sql              -- background waits
│   ├── 06_top_sql.sql               -- Top-N SQL
│   ├── 07_summary.sql               -- z-score findings
│   ├── 08_overview.sql              -- hero strip (headline metrics)
│   ├── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline
│   └── 10_db_time_summary.sql       -- full-span DB time stacked area
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
