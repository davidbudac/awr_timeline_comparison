# CLAUDE.md

Guidance for future Claude sessions working on this repo.

## What this is

Pure-SQL Oracle 19c toolkit that compares AWR snapshots of **the same
hour across weeks** (e.g. Mon 09:00–10:00 today vs the four prior Mondays
09:00–10:00), flags drastic changes via z-score, renders a self-contained
HTML report, and persists every fact into an `AWR_TREND_*` scratch schema
for ad-hoc analysis.

Requires Oracle 19c with Diagnostic + Tuning Pack. No Python, no shell
beyond a thin `sqlplus` wrapper. Output is a single self-contained HTML file.

**Note on offline rendering**: the HTML loads Apache ECharts from
`cdn.jsdelivr.net` to render the larger visualizations (hero strip
sparklines, wait-class stacked bars, findings heatmap, top-SQL bump
chart, windows ribbon). When the CDN is unreachable, `<script onerror>`
sets `body.no-charts` which hides chart divs — tables still render
every number, and an amber "Charts hidden" banner tells the reader
why. Inline-SVG sparklines in the Load/Metrics/Waits tables are
rendered by a ~30-line pure-DOM JS block shipped in the prologue and
do **not** depend on the CDN, so they still draw when offline. For
strict air-gapped environments, remove the ECharts `<script>` tag in
`awr_trend.sql` — every other element degrades gracefully.

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
├── setup_schema.sql             -- one-time DDL (sequence + 8 tables, idempotent)
├── defaults.sql                 -- canonical DEFINEs for the 5 substitution vars
├── _style.sql                   -- embedded CSS (emitted once from the driver)
├── 00_params.sql                -- inserts AWR_TREND_RUNS row, emits <nav>+<header>
├── 01_windows.sql               -- aligned windows, snap_id pairs, instance-restart guard
├── 02_load_profile.sql          -- SYSSTAT deltas (27 curated stats)
├── 03_sysmetric.sql             -- SYSMETRIC_SUMMARY averages (23 curated metrics)
├── 04_waits_fg.sql              -- foreground waits + wait-class rollup
├── 05_waits_bg.sql              -- background waits (BG_EVENT_SUMMARY)
├── 06_top_sql.sql               -- Top-N SQL ranked 4 ways + bump chart
├── 07_summary.sql               -- z-score findings + heatmap; flips run status to 'OK'
├── 08_overview.sql              -- hero strip: 6 headline-metric cards (reads 02/03/07)
└── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline by wait_class
                                    (reads dba_hist_active_sess_history directly)
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

**Tilde gotcha**: every numbered section file issues `SET DEFINE '~'` so
it can use `~run_id` for parameter substitution. That makes `~` the
live substitution character for the rest of the file — any literal `~`
followed by a character (even in comments or strings, e.g. `~0.003`,
`~/path`) is parsed as a variable reference and triggers an `Enter
value for 0:` prompt, which silently truncates the section in
non-interactive runs. If you need a literal tilde, write it out
("around 0.003", "home dir", etc.) or wrap the affected block in `SET
DEFINE OFF` / `SET DEFINE '~'`.

### Chart render layer (sections 02, 03, 04, 05, 06, 07, 08, 09)
The chart visualizations read only from the existing scratch tables —
no new data compute or new tables. The pattern is: each numbered
section builds its rendered slice via a `WITH all_weeks AS (CONNECT BY
LEVEL …)` × entity CTE that guarantees null slots for missing weeks,
then `LISTAGG(... WITHIN GROUP (ORDER BY week_offset DESC), ',')` into
either a `data-spark="…"` attribute (read by the inline-SVG sparkline
renderer in `awr_trend.sql`) or a JSON payload on `window.AWR_DATA` for
an ECharts init block. Oldest→newest is the canonical spark order.
Numeric CSV uses `NLS_NUMERIC_CHARACTERS='.,'` so `Number(x)` parses
regardless of the session NLS. Table cells pick an adaptive decimal
format from `row_max`: at least 2 decimals, more when all values are
small enough that 2 decimals would show "0.00" for real movement.
The sparkline JS has a flatness floor: `(max-min)/|mean| < 2 %` renders
a midline instead of autoscaling imperceptible noise into a zigzag.

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
- `AWR_TREND_ASH_TIMELINE` — hourly ASH sample counts per wait_class across the full compare span. One row per `(run_id, hour_bucket, wait_class)` where `sample_count > 0`; render layer NVL-zeros the gaps.
- `AWR_TREND_FINDINGS` — z-score findings (populated last).

All child tables FK to `AWR_TREND_RUNS` with `ON DELETE CASCADE`.
Purge a run with `DELETE FROM awr_trend_runs WHERE run_id = :r;`.
No automatic retention — add `side/purge_runs.sql` if needed.

## Verification state

Last verified against Oracle 19c on dbmint (CDB1, `connect / as sysdba`)
in April 2026: all 8 sections render cleanly, 0 ORA errors, all
visualizations populate when the underlying weeks have snapshots.
Density matters — the test DB had at most 3 consecutive weeks at any
given hour-of-week, so findings are forced to `INSUFFICIENT_HISTORY`
(z-score needs ≥3 prior). Re-verify if you change any of sections
02/03/04/05/06/07/08. Particular spots worth probing on a future real run:

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
- Don't introduce additional external JS/CSS beyond the single ECharts
  CDN tag that's already in `awr_trend.sql`. The report is still one
  HTML file and works offline (charts hide, tables remain) via the
  `body.no-charts` fallback — any new dependency must degrade the
  same way. Inline-SVG sparklines and the ribbon are CDN-free and must
  stay that way.
- Don't widen the grant list in `README.md` without a concrete reason —
  everything in there is actually needed by the current SQL.
