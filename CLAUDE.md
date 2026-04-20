# CLAUDE.md

Guidance for future Claude sessions working on this repo.

## What this is

Pure-SQL Oracle 19c toolkit that compares AWR snapshots of **the same
hour across weeks** (e.g. Mon 09:00–10:00 today vs the four prior Mondays
09:00–10:00), flags drastic changes via z-score, renders a self-contained
HTML report, and persists every fact into an `AWR_TREND_*` scratch schema
for ad-hoc analysis.

Requires Oracle 19c with Diagnostic + Tuning Pack. No Python, no shell
beyond a thin `sqlplus` wrapper. Output is a single offline HTML file.

## Entry points

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num]`
  — convenience wrapper. Sets all substitution vars via heredoc, then `@@awr_trend.sql`.
- `sqlplus user/pw@svc @sql/defaults.sql @awr_trend.sql`
  — pure-SQL\*Plus equivalent. **The driver deliberately does not DEFINE defaults itself** so an explicit caller override is never clobbered. Always load `sql/defaults.sql` (or set DEFINEs manually) before `@awr_trend.sql`.
- `sqlplus user/pw@svc @sql/setup_schema.sql`
  — one-time DDL. Idempotent.
- `sqlplus user/pw@svc @side/create_weekly_baselines.sql`
  — optional, independent of the main report. Creates `DBA_HIST_BASELINE`
  rows named `WK_<IYYY>_<IW>`. The main driver does **not** read these.

## File layout

```
awr_trend.sql                    -- driver: prologue, SPOOL, calls sections, epilogue
sql/
├── setup_schema.sql             -- one-time DDL (sequence + 7 tables, idempotent)
├── defaults.sql                 -- canonical DEFINEs for the 5 substitution vars
├── _style.sql                   -- embedded CSS (emitted once from the driver)
├── 00_params.sql                -- inserts AWR_TREND_RUNS row, emits <nav>+<header>
├── 01_windows.sql               -- aligned windows, snap_id pairs, instance-restart guard
├── 02_load_profile.sql          -- SYSSTAT deltas (27 curated stats)
├── 03_sysmetric.sql             -- SYSMETRIC_SUMMARY averages (23 curated metrics)
├── 04_waits_fg.sql              -- foreground waits + wait-class rollup
├── 05_waits_bg.sql              -- background waits (BG_EVENT_SUMMARY)
├── 06_top_sql.sql               -- Top-N SQL ranked 4 ways
└── 07_summary.sql               -- z-score findings; also flips run status to 'OK'
side/
└── create_weekly_baselines.sql  -- optional weekly AWR baselines
reports/                         -- generated HTML (gitignored? — not yet; see below)
```

## Core conventions (non-obvious, easy to break)

### Section-script contract
Every numbered section under `sql/` does **compute → insert → render** in
that order, keyed by `&run_id`:
1. Compute per-window values via AWR view SQL.
2. `INSERT INTO awr_trend_<section> SELECT …` (commit).
3. Render HTML by `SELECT`-ing back what was just inserted.

Keeps the report and the scratch tables in lock-step — the HTML never
shows a number that isn't also persisted. Don't add a section that
renders from transient CTEs only.

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
Five vars: `target_end`, `win_hours`, `weeks_back`, `top_n`, `inst_num`.
`inst_num = 0` means aggregate across RAC instances; any other value
filters to that instance. `target_end = 'AUTO'` means "prior full hour
relative to SYSDATE" (resolved in `00_params.sql`). `&run_id` is
allocated by the driver from `AWR_TREND_RUN_SEQ` and threaded into every
section — never re-allocate it inside a section.

### Window validity
`01_windows.sql` flags a window `valid_flag = 'N'` with a `skip_reason`
when: bounds can't be resolved, begin=end (same snap), or
`startup_time` differs between the two snaps (instance restart). All
downstream sections filter on `valid_flag = 'Y'`; invalid weeks are
still shown in the Windows table but excluded from the z-score baseline.

### Severity classes (must stay aligned with CSS in `_style.sql`)
`CRITICAL` → `crit`, `WARN` → `warn`, `OK` → `ok`,
`INSUFFICIENT_HISTORY` / `FLAT_BASELINE` → `skip`, informational → `info`.
If you add a new severity, update both `07_summary.sql` and
`_style.sql`.

### Run state machine
`00_params.sql` inserts the `AWR_TREND_RUNS` row with `status='RUNNING'`.
`07_summary.sql` updates to `'OK'` at the end. If a run fails mid-way
the row stays `'RUNNING'` — a clean recovery hook exists but isn't wired
(SQL\*Plus `WHENEVER SQLERROR EXIT SQL.SQLCODE` kills the session before
we can write `'FAILED'`). Acceptable for now; noted as future work.

## Scratch schema (owned by the connected user)

- `AWR_TREND_RUN_SEQ` — allocates `run_id`.
- `AWR_TREND_RUNS` — one row per report execution.
- `AWR_TREND_WINDOWS` — aligned windows (current + N prior), PK `(run_id, week_offset)`.
- `AWR_TREND_LOAD_PROFILE` — SYSSTAT deltas.
- `AWR_TREND_SYSMETRIC` — SYSMETRIC averages.
- `AWR_TREND_WAITS` — top FG/BG events + wait-class rollup.
- `AWR_TREND_TOP_SQL` — Top-N SQL ranked 4 ways.
- `AWR_TREND_FINDINGS` — z-score findings (populated last).

All child tables FK to `AWR_TREND_RUNS` with `ON DELETE CASCADE`.
Purge a run with `DELETE FROM awr_trend_runs WHERE run_id = :r;`.
No automatic retention — add `side/purge_runs.sql` if needed.

## Verification state

**Not yet executed against a real Oracle 19c instance.** All files are
static-reviewed only. Before making substantive changes, ideally run
once on a test DB to catch any syntax/semantics issues. Particular
spots worth probing on first real run:

- HTML prologue: confirm the `SELECT awr_trend_run_seq.NEXTVAL` and the
  `report_path` SELECT don't leak into the spool (they shouldn't — both
  columns are `NOPRINT` and `TERMOUT` is off, but verify the very top
  of the generated `.html`).
- `06_top_sql.sql` uses nested `DECLARE … BEGIN … END;` blocks inside a
  `FOR` loop. Valid PL/SQL, but verbose — performance is fine at
  `top_n = 10` (4 × N × (1 + weeks_back) scalar selects per run).
- RAC aggregate vs per-instance: pick a known-quiet window on a RAC
  cluster, run with `inst_num = 0` and `inst_num = 1`, cross-check that
  aggregate ≈ sum of per-instance for cumulative stats.

## Useful investigative queries

```sql
-- Latest run's findings
SELECT severity, metric_domain, metric_name, current_value, prior_mean, z_score, pct_delta
FROM   awr_trend_findings
WHERE  run_id = (SELECT MAX(run_id) FROM awr_trend_runs)
ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 ELSE 9 END,
         ABS(NVL(z_score,0)) DESC;

-- Trend one metric across all runs for one DB
SELECT r.target_end_ts, lp.per_sec
FROM   awr_trend_runs r JOIN awr_trend_load_profile lp
       ON lp.run_id = r.run_id AND lp.week_offset = 0
WHERE  lp.stat_name = 'redo size'
ORDER BY r.target_end_ts;
```

## Things NOT to do

- Don't add positional args to `awr_trend.sql` itself — keep it driven
  purely by pre-set DEFINEs so both the wrapper and the pure-SQL\*Plus
  path stay symmetric.
- Don't assume `DBA_HIST_SYSTEM_EVENT` has `*_DELTA` columns. It doesn't.
- Don't render from in-flight CTEs — break the compute→insert→render
  contract and the HTML/scratch tables can disagree.
- Don't concat user strings into HTML without `DBMS_XMLGEN.CONVERT`.
- Don't introduce external JS/CSS — the report must be self-contained
  (emailable, works offline).
- Don't widen the grant list in `README.md` without a concrete reason —
  everything in there is actually needed by the current SQL.
