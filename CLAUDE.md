# CLAUDE.md

Guidance for future Claude sessions working on this repo.

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
the main report (it calls `DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE`).

Requires Oracle 19c with Diagnostic + Tuning Pack. No Python, no shell
beyond a thin `sqlplus` wrapper. Output is a single self-contained HTML file.

**Note on offline rendering**: the HTML loads Apache ECharts from
`cdn.jsdelivr.net` to render the larger visualizations (hero strip
sparklines, wait-class stacked bars, findings heatmap, top-SQL bump
chart, windows ribbon, ASH timeline). When the CDN is unreachable,
`<script onerror>` sets `body.no-charts` which hides chart divs —
tables still render every number, and an amber "Charts hidden" banner
tells the reader why. Inline-SVG sparklines in the Load/Metrics/Waits
tables are rendered by a ~30-line pure-DOM JS block shipped in the
prologue and do **not** depend on the CDN, so they still draw when
offline. For strict air-gapped environments, remove the ECharts
`<script>` tag in `awr_trend.sql` — every other element degrades
gracefully.

## Entry points

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num]`
  — convenience wrapper. Sets all substitution vars via heredoc, then `@@awr_trend.sql`.
- `sqlplus user/pw@svc @sql/defaults.sql @awr_trend.sql`
  — pure-SQL\*Plus equivalent. **The driver deliberately does not DEFINE defaults itself** so an explicit caller override is never clobbered. Always load `sql/defaults.sql` (or set DEFINEs manually) before `@awr_trend.sql`.
- `sqlplus user/pw@svc @side/create_weekly_baselines.sql`
  — optional, independent of the main report. Creates `DBA_HIST_BASELINE`
  rows named `WK_<IYYY>_<IW>`. **This is the only script that writes
  to the database.** The main driver does not read these baselines.

## File layout

```
awr_trend.sql                    -- driver: prologue, SPOOL, calls sections, epilogue
sql/
├── defaults.sql                 -- canonical DEFINEs for the 7 substitution vars
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
├── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline by wait_class
│                                   (reads dba_hist_active_sess_history directly)
└── lib/                         -- SQL/PL/SQL fragments shared across sections via @@
    ├── windows_cte.sql          -- run_params → … → valid_windows CTE chain
    ├── sysstat_load_targets.sql -- 27 SYSSTAT counter names (used by 02 + 07)
    ├── sysmetric_targets.sql    -- 23 SYSMETRIC_SUMMARY metric names (used by 03 + 07)
    ├── nth_csv.plsql            -- INSTR-based PL/SQL CSV parser (preserves empty tokens)
    ├── js_sparkline.plsql       -- ~30-line inline-SVG sparkline renderer (CDN-free)
    └── js_wait_colors.plsql     -- shared OEM-13c-aligned wait_class color palette
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

### Shared CTE bodies and helpers live under `sql/lib/`
What used to be six near-identical inline copies of the same SQL/PL/SQL
fragments now lives under `sql/lib/` and is `@@`-included from each
section. The `windows` CTE chain (`run_params → offsets → raw_windows →
snaps → begin_snap → end_snap → windows → valid_windows`) is in
`sql/lib/windows_cte.sql`; the curated stat/metric lists are in
`sql/lib/sysstat_load_targets.sql` and `sql/lib/sysmetric_targets.sql`;
the `nth_csv` PL/SQL helper is in `sql/lib/nth_csv.plsql`; the inline
SVG sparkline JS and the wait-class color palette are in `js_*.plsql`.
A view or helper package would violate the no-DDL rule, so include-files
are the chosen mechanism. To change the windows logic or the curated
metric lists, edit one file under `sql/lib/` and every consumer picks
the change up.

**Nested `@@` path gotcha**: SQL\*Plus resolves `@@` paths in nested
include files relative to the **outermost caller's** directory, not the
immediate parent. The driver `awr_trend.sql` runs from the project root
and `@@`-calls section files which in turn `@@`-include files under
`sql/lib/`. The path written in the section file must therefore be
`@@sql/lib/windows_cte.sql` — the full path *from the project root* —
not `@@lib/windows_cte.sql` (which fails with "No such file or
directory") nor `@@../lib/windows_cte.sql`. This was verified on Oracle
19c sqlplus; treat it as the canonical path form.

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
Seven user-facing vars: `target_end`, `win_hours`, `weeks_back`, `top_n`,
`inst_num`, `step`, `step_unit`. `inst_num = 0` means aggregate across
RAC instances; any other value filters to that instance.
`target_end = 'AUTO'` means "prior full hour relative to SYSDATE"
(resolved in the driver into `target_end_resolved`). `step` + `step_unit`
(default `1` + `'w'`) control the cadence between adjacent comparison
windows; `step_unit` is one of `'h'` (hours), `'d'` (days), `'w'`
(weeks). The original "same hour-of-week, N prior weeks" behaviour is
the default (`step=1, step_unit='w'`). Setting `step=1, step_unit='h'`
compares the last `weeks_back+1` consecutive 1-hour windows in a
straight line back from `target_end`. The driver resolves
`step_hours = step * (1|24|168)` plus `period_unit_short` /
`period_unit_long` / `period_unit_title` / `period_step_label` /
`period_axis_fmt` once up front; every section uses
`~step_hours/24` (NOT the literal `7`) as the cadence multiplier.
The driver also resolves `run_id` (17-digit timestamp from
`SYSTIMESTAMP`), `dbid`, `db_name`, `host_name`, `db_version`,
`caller_user`, `generated_at_s`, `dow_name`, and `report_path` up
front; every section references them as `~name`. No section ever
re-resolves these values.

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
Every chart is rendered from the same cursor that produces the numeric
table — not from a separately persisted slice. The pattern is: the
section's main cursor builds per-row CSVs via `LISTAGG(... WITHIN GROUP
(ORDER BY week_offset DESC), ',')` (oldest→newest is the canonical
spark order) and emits them either as a `data-spark="…"` attribute
(read by the inline-SVG sparkline renderer in `awr_trend.sql`) or as a
JSON payload on `window.AWR_DATA` for an ECharts init block. Numeric
CSV uses `NLS_NUMERIC_CHARACTERS='.,'` so `Number(x)` parses regardless
of the session NLS. Table cells pick an adaptive decimal format from
`row_max`: at least 2 decimals, more when all values are small enough
that 2 decimals would show "0.00" for real movement. The sparkline JS
has a flatness floor: `(max-min)/|mean| < 2 %` renders a midline
instead of autoscaling imperceptible noise into a zigzag.

### Per-row CSV parsing in PL/SQL (`nth_csv`)
Sections that need to render a grid with one column per week after
`LISTAGG(... ORDER BY week_offset ASC)` parse the CSV inside the loop
with a small `nth_csv(p_str, p_n)` PL/SQL function. The function lives
in `sql/lib/nth_csv.plsql` and is `@@`-included at the top of the
anonymous block (just before `BEGIN`). Slot `k+1` corresponds to
`week_offset = k`. The function is INSTR-based (not `REGEXP_SUBSTR`)
so empty tokens between commas are preserved.

### Window validity (per-instance in RAC aggregate mode)
`windows_cte.sql` resolves `begin_snap` and `end_snap` per
`(week_offset, instance_number)`, FULL OUTER JOINs them into
`instance_pairs`, and produces `windows` with one row per
`(week_offset, instance_number)`. `valid_flag = 'N'` (with a
`skip_reason`) is set per-instance when: an instance has no candidate
begin or end snap; begin=end (same snap, window shorter than the AWR
interval); or `startup_time` differs between the two snaps (the
instance restarted inside the window).

`valid_windows` is the per-instance, valid-only projection consumed by
every numbered data section (02–08); their joins use
`v.instance_number = w.instance_number` directly (no NULL fallback —
`valid_windows.instance_number` is never NULL by construction). The
final per-week aggregate happens at the section's own `GROUP BY
week_offset` and naturally sums only over instance pairs that survived
validation. On a RAC cluster where one instance restarts mid-window,
its delta is dropped and the others' kept; on single-instance, this is
a no-op.

For display, `windows_rollup` aggregates `windows` back to one row per
`week_offset`: `valid_flag = 'Y'` if at least one instance was valid;
`begin_snap_id`/`end_snap_id` show the MIN/MAX across instances; the
first non-null `skip_reason` wins. Sections 01 (windows ribbon + table)
and 09 (ASH band markers) read `windows_rollup`. Single-instance output
is byte-identical to the per-week-only design that preceded this CTE.

### SYSMETRIC cross-instance aggregation (additive vs ratio)
`DBA_HIST_SYSMETRIC_SUMMARY` reports per-(snap, instance) averages over
the snapshot interval. Cross-instance roll-up is metric-dependent:
**rates and counters** (Average Active Sessions, *_Per_Sec, Session
Count) are **additive** — the cluster value is `SUM(average)` across
instances; **ratios, percentages, latencies, response times** (CPU
Ratios, Wait Time Ratio, Sync SBR Latency, SQL Service Response Time)
are **averages** — `AVG(average)`. Doing a flat `AVG` across instances
for additive metrics silently undercounts cluster load.

`sql/lib/sysmetric_targets.sql` tags each metric with an `is_additive`
flag ('Y'/'N'). Sections 03 and 07 read the flag from the targets file;
section 08's hand-maintained `cards` CTE carries an inline `is_add`
column for the same purpose. The aggregation pattern is two-step in
every consumer: `snap_value = (SUM|AVG)(sm.average) GROUP BY week,
metric, snap_id`, then `metric_value = AVG(snap_value) GROUP BY week,
metric`. On single-instance, SUM and AVG over one row are identical, so
this is a no-op.

### Severity classes (must stay aligned with CSS in `_style.sql`)
`CRITICAL` → `crit`, `WARN` → `warn`, `OK` → `ok`,
`INSUFFICIENT_HISTORY` / `FLAT_BASELINE` → `skip`, informational → `info`.
If you add a new severity, update both `07_summary.sql`, `08_overview.sql`
(it computes the same labels inline for the hero cards), and `_style.sql`.

### Findings are recomputed, not shared
Section 07 (findings) and section 08 (overview hero) each recompute
their own z-scores from the AWR views. They do not share data. The
LOAD/METRIC target lists are now single-sourced from
`sql/lib/sysstat_load_targets.sql` and `sql/lib/sysmetric_targets.sql`
and `@@`-included by sections 02/03/07, so adding or removing a stat
updates every consumer in lock-step. Section 08's 6 hero cards
reference specific LOAD/SYSMETRIC names by hand; if you remove one of
those from a target list the hero badge will fall back to `n/a`.

Inside section 07 itself, the unified LOAD/METRIC/WAIT recompute is
`BULK COLLECT`-ed once into a PL/SQL record collection tagged with both
view positions via `ROW_NUMBER()`, and the heatmap and detail-table
loops both walk that single collection in their respective orders. Do
not reintroduce a second cursor that re-runs the whole recompute just
to get a different ORDER BY.

## Verification state

Last verified against Oracle 19c on dbmint (CDB1, `connect / as sysdba`)
in May 2026 after the `fix/codex-review-priorities` round (per-instance
window validity in `windows_cte.sql`, SYSMETRIC additive-vs-ratio
classification, baselines override regression, generated-report
gitignore). Single-instance byte-identity confirmed: the normalized
md5 of a fresh `main`-branch report and a fresh `fix` -branch report
generated minutes apart on dbmint matched (`fac510ce…`). Density
matters — the test DB had at most 3 consecutive weeks at any given
hour-of-week, so findings are forced to `INSUFFICIENT_HISTORY`
(z-score needs ≥3 prior). Re-verify if you change any of sections
02/03/04/05/06/07/08/09. Particular spots worth probing on a future
real run:

- HTML prologue: confirm that the `SELECT` resolving `run_id / dbid /
  host_name / …` and the `SPOOL ~report_path` don't leak into the
  spool (they shouldn't — every column is `NOPRINT` and `TERMOUT` is
  off, but verify the very top of the generated `.html`).
- `06_top_sql.sql` uses nested `DECLARE … BEGIN … END;` blocks inside a
  `FOR` loop. Valid PL/SQL, but verbose — performance is fine at
  `top_n = 10`.
- `09_ash_timeline.sql` pulls every qualifying ASH row aggregated to
  (hour_bucket, wait_class) over a `weeks_back*step_hours + win_hours`-
  hour span. On a very busy DB this can be the single most expensive
  section; consider narrowing the range (smaller `weeks_back`, or a
  shorter `step_hours`) if wall-clock matters.
- RAC aggregate vs per-instance: pick a known-quiet window on a RAC
  cluster, run with `inst_num = 0` and `inst_num = 1`, cross-check that
  aggregate ≈ sum of per-instance for cumulative stats.

### Byte-identity convention for behavior-preserving refactors
When refactoring code that should not change report output, sync the
project to dbmint (`rsync -az --exclude=.git --exclude=reports
--exclude=.claude ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh
-p 2201'`), generate one HTML report against the pre-change code and
one against the post-change code at roughly the same wall-clock time
(AWR data is live — the same hour-of-week run an hour later may pick
up fresh snapshots), normalize the volatile bits (`run_id`,
`generated_at`), and compare md5:

```sh
sed -E '
  s/run [0-9]{17}/run RUNID/g
  s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{2}:[0-9]{2}/TIMESTAMP/g
' "$1" | md5
```

The report is otherwise deterministic given the AWR state, so a
byte-identical match is the strongest possible "no behavior change"
signal.

## Things NOT to do

- Don't add positional args to `awr_trend.sql` itself — keep it driven
  purely by pre-set DEFINEs so both the wrapper and the pure-SQL\*Plus
  path stay symmetric.
- Don't assume `DBA_HIST_SYSTEM_EVENT` has `*_DELTA` columns. It doesn't.
- Don't reintroduce a scratch schema to "share" data between sections.
  The read-only invariant is the whole point of this design. If a
  computation needs to be reused across sections, extract it as an
  `@@`-included file under `sql/lib/`. If it needs to be reused inside
  one section (e.g. driving two views from the same recompute), use
  `BULK COLLECT` into a PL/SQL collection — section 07 is the canonical
  example.
- Don't write `@@lib/...` or `@@../lib/...` from a section file. SQL\*Plus
  resolves nested `@@` paths against the **outermost caller's**
  directory, so the only correct form is `@@sql/lib/<file>` from any
  section. The "Shared CTE bodies and helpers live under `sql/lib/`"
  section above explains why.
- Don't concat user strings into HTML without `DBMS_XMLGEN.CONVERT`.
- Don't introduce additional external JS/CSS beyond the single ECharts
  CDN tag that's already in `awr_trend.sql`. The report is still one
  HTML file and works offline (charts hide, tables remain) via the
  `body.no-charts` fallback — any new dependency must degrade the
  same way. Inline-SVG sparklines and the ribbon are CDN-free and must
  stay that way.
- Don't widen the grant list in `README.md` without a concrete reason —
  everything in there is actually needed by the current SQL.
- Don't reintroduce the literal `7` as the cadence multiplier inside any
  `raw_windows` CTE. The cadence is `~step_hours/24` (resolved by the
  driver from `step` + `step_unit`); typing `7*o.week_offset` re-hardcodes
  the weekly default and breaks every non-weekly comparison.
