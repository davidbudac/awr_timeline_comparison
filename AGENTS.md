# AGENTS.md

Guidance for future Codex sessions working on this repo.

## What this is

Pure-SQL Oracle 19c toolkit that compares AWR snapshots of **the same
hour across weeks** (e.g. Mon 09:00–10:00 today vs the four prior Mondays
09:00–10:00), flags drastic changes via z-score, and renders a
self-contained HTML report.

**Read-only invariant:** the driver and every numbered section issue
`SELECT` only. There is no scratch schema, no DDL step, and no
`INSERT`/`UPDATE`/`DELETE`/`COMMIT` anywhere on the read path.
Everything is recomputed in-flight from the `DBA_HIST_*` views on each
run. The only script that ever writes is
`side/create_weekly_baselines.sql`, which is optional and orthogonal to
the main report.

Requires Oracle 19c with Diagnostic + Tuning Pack. No Python, no shell
beyond a thin `sqlplus` wrapper. Output is a single HTML file that
works offline (charts hide, tables remain) when the ECharts CDN is
blocked.

## Entry points

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num]`
  — convenience wrapper. Sets all substitution vars via heredoc, then `@@awr_trend.sql`.
- `sqlplus user/pw@svc @sql/defaults.sql @awr_trend.sql`
  — pure-SQL\*Plus equivalent. **The driver deliberately does not DEFINE defaults itself** so an explicit caller override is never clobbered. Always load `sql/defaults.sql` (or set DEFINEs manually) before `@awr_trend.sql`.
- `sqlplus user/pw@svc @side/create_weekly_baselines.sql`
  — optional, independent of the main report. Creates `DBA_HIST_BASELINE`
  rows named `WK_<IYYY>_<IW>`. **The only script that writes.** The main
  driver does not read these baselines.

## File layout

```
awr_trend.sql                    -- driver: prologue, SPOOL, calls sections, epilogue
sql/
├── defaults.sql                 -- canonical DEFINEs for the 5 substitution vars
├── _style.sql                   -- embedded CSS (emitted once from the driver)
├── 00_params.sql                -- <nav> + <header> card (no DML)
├── 01_windows.sql               -- aligned windows, snap_id pairs, instance-restart guard
├── 02_load_profile.sql          -- SYSSTAT deltas (27 curated stats)
├── 03_sysmetric.sql             -- SYSMETRIC_SUMMARY averages (23 curated metrics)
├── 04_waits_fg.sql              -- foreground waits + wait-class rollup
├── 05_waits_bg.sql              -- background waits (BG_EVENT_SUMMARY)
├── 06_top_sql.sql               -- Top-N SQL ranked 4 ways + bump chart
├── 07_summary.sql               -- z-score findings + heatmap (recomputed inline)
├── 08_overview.sql              -- hero strip: 6 headline-metric cards (recomputed inline)
└── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline by wait_class
side/
└── create_weekly_baselines.sql  -- optional weekly AWR baselines (writes; orthogonal)
reports/                         -- generated HTML files
```

## Core conventions (non-obvious, easy to break)

### Read-only invariant
Every numbered section under `sql/` must stay **pure SELECT**: no
`INSERT`, `UPDATE`, `DELETE`, `MERGE`, `COMMIT`, `CREATE`, `DROP`,
`TRUNCATE`. The report has to be runnable by a read-only analyst user
and safe against a physical standby that exposes AWR. If you need to
persist something across sections, thread it via a SQL\*Plus
substitution variable (see `awr_trend.sql` — `run_id`, `dbid`,
`target_end_resolved`, etc. are resolved once in the driver via
`COLUMN … NEW_VALUE` and then referenced with `~name` in every
section), or shape it as a PL/SQL collection inside the section's
anonymous block.

### The `windows` CTE is duplicated per section
Every numbered section (01–09) carries its own inline copy of the
windows CTE chain (`run_params → offsets → raw_windows → snaps →
begin_snap → end_snap → windows → valid_windows`). This is deliberate:
SQL\*Plus can't share a CTE across `@@` includes, and factoring into a
view or a helper package would violate the no-DDL rule. Accept the
duplication; if you change the windows logic, grep for `raw_windows AS`
and update every site.

### The `pairs → bounds → deltas` pattern
For cumulative AWR counters (`DBA_HIST_SYSSTAT`, `DBA_HIST_SYSTEM_EVENT`,
`DBA_HIST_BG_EVENT_SUMMARY`), always use this pattern. See
`sql/02_load_profile.sql` for the canonical shape. Do **not** use
`CROSS JOIN targets` + double `LEFT JOIN` — it silently drops stats that
appear at only one snap and misbehaves in aggregate (`inst_num = 0`) mode.

**Important**: `DBA_HIST_SYSTEM_EVENT` and `DBA_HIST_BG_EVENT_SUMMARY`
do **not** expose `*_DELTA` columns. Compute `end - begin` manually.
Only `DBA_HIST_SQLSTAT` has `*_DELTA` columns (used in `06_top_sql.sql`).

### HTML emission
Every section emits markup via `DBMS_OUTPUT.PUT_LINE` inside anonymous
PL/SQL blocks. SQL\*Plus is configured with `TERMOUT OFF / PAGESIZE 0 /
HEADING OFF / LINESIZE 32767 / TRIMSPOOL ON` so only the explicit
`PUT_LINE` bytes reach the spool. **Any bare `SELECT` in a section file
will leak into the HTML.** All user-visible strings (SQL text, event
names, metric names) must be wrapped in `DBMS_XMLGEN.CONVERT(...)`.

### Substitution variables
Five user-facing vars: `target_end`, `win_hours`, `weeks_back`, `top_n`,
`inst_num`. `inst_num = 0` means aggregate across RAC instances; any
other value filters to that instance. `target_end = 'AUTO'` means
"prior full hour relative to SYSDATE" (resolved in the driver into
`target_end_resolved`). The driver also resolves `run_id` (17-digit
timestamp from `SYSTIMESTAMP`), `dbid`, `db_name`, `host_name`,
`db_version`, `caller_user`, `generated_at_s`, `dow_name`, and
`report_path` up front; every section references them as `~name`.
No section re-resolves these.

**Tilde gotcha**: every numbered section file issues `SET DEFINE '~'` so
it can use `~run_id` for parameter substitution. That makes `~` the
live substitution character — any literal `~` followed by a character
(even in comments, e.g. `~0.003`, `~/path`) is parsed as a variable
reference and triggers an `Enter value for 0:` prompt that silently
truncates the section in non-interactive runs. Write out literal
tildes or temporarily `SET DEFINE OFF`.

### Window validity
`01_windows.sql` flags a window `valid_flag = 'N'` with a `skip_reason`
when: bounds can't be resolved, begin=end (same snap), or
`startup_time` differs between the two snaps (instance restart). Every
downstream section carries its own copy of the windows CTE and filters
on `valid_flag = 'Y'`; invalid weeks are still shown in the Windows
table but excluded from the z-score baseline.

### Severity classes (must stay aligned with CSS in `_style.sql`)
`CRITICAL` → `crit`, `WARN` → `warn`, `OK` → `ok`,
`INSUFFICIENT_HISTORY` / `FLAT_BASELINE` → `skip`, informational → `info`.
If you add a new severity, update both `07_summary.sql`, `08_overview.sql`
(it computes the same labels inline), and `_style.sql`.

### Findings are recomputed, not shared
Section 07 (findings) and section 08 (overview hero) each recompute
their own z-scores from the AWR views. They do not share data. If the
metric list in section 02/03/04 changes, section 07's `load_targets` /
`metric_targets` lists must be updated in lock-step.

## Verification state

The read-only rewrite on branch `no-db-writes` is **pending re-
verification on a live instance**. All files are static-reviewed only.
Particular spots worth probing on first real run:

- HTML prologue: confirm the driver's `SELECT` resolving `run_id / dbid
  / host_name / …` and the `SPOOL ~report_path` don't leak into the
  spool (they shouldn't — every column is `NOPRINT` and `TERMOUT` is
  off, but verify the very top of the generated `.html`).
- `06_top_sql.sql` uses nested `DECLARE … BEGIN … END;` blocks inside a
  `FOR` loop. Valid PL/SQL, but verbose — performance is fine at
  `top_n = 10`.
- `09_ash_timeline.sql` aggregates every qualifying ASH row to
  (hour_bucket, wait_class) over a (weeks_back+1)*win_hours×24-hour
  span. On a very busy DB this can be the single most expensive
  section; narrow the range if wall-clock matters.
- RAC aggregate vs per-instance: pick a known-quiet window on a RAC
  cluster, run with `inst_num = 0` and `inst_num = 1`, cross-check that
  aggregate ≈ sum of per-instance for cumulative stats.

## Things NOT to do

- Don't add positional args to `awr_trend.sql` itself — keep it driven
  purely by pre-set DEFINEs so both the wrapper and the pure-SQL\*Plus
  path stay symmetric.
- Don't assume `DBA_HIST_SYSTEM_EVENT` has `*_DELTA` columns. It doesn't.
- Don't reintroduce a scratch schema to "share" data between sections.
  The read-only invariant is the whole point of this branch.
- Don't concat user strings into HTML without `DBMS_XMLGEN.CONVERT`.
- Don't introduce additional external JS/CSS beyond the single ECharts
  CDN tag that's already in `awr_trend.sql`. The report must stay one
  HTML file that degrades gracefully when offline.
- Don't widen the grant list in `README.md` without a concrete reason —
  everything in there is actually needed by the current SQL.
