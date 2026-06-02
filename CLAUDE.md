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

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num] [step] [step_unit] [template] [debug] [marker_file]`
  — convenience wrapper. Sets all substitution vars via heredoc, then `@@awr_trend.sql`. `debug='Y'` (case-insensitive) emits one timestamped progress marker per section to **stdout** (the HTML is byte-identical). See "Debug logging" below.
- `sqlplus user/pw@svc @sql/defaults.sql @awr_trend.sql`
  — pure-SQL\*Plus equivalent. **The driver deliberately does not DEFINE defaults itself** so an explicit caller override is never clobbered. Always load `sql/defaults.sql` (or set DEFINEs manually) before `@awr_trend.sql`.
- `sqlplus user/pw@svc @side/create_weekly_baselines.sql`
  — optional, independent of the main report. Creates `DBA_HIST_BASELINE`
  rows named `WK_<IYYY>_<IW>`. **This is the only script that writes
  to the database.** The main driver does not read these baselines.

## File layout

```
awr_trend.sql                    -- driver: prologue, SPOOL, calls sections, epilogue
markers.example.sql              -- example timeline-marker config (optional marker_file)
sql/
├── defaults.sql                 -- canonical DEFINEs for the 10 substitution vars
├── _style.sql                   -- embedded CSS (emitted once from the driver)
├── 00_params.sql                -- <nav> + <header> card (no DML)
├── 01_windows.sql               -- aligned windows, snap_id pairs, instance-restart guard
├── 02_load_profile.sql          -- SYSSTAT deltas (curated stats, per template)
├── 03_sysmetric.sql             -- SYSMETRIC_SUMMARY averages (curated metrics, per template)
├── 04_waits_fg.sql              -- foreground waits + wait-class rollup (filtered per template)
├── 05_waits_bg.sql              -- background waits (BG_EVENT_SUMMARY; filtered per template)
├── 06_top_sql.sql               -- Top-N SQL ranked 4 ways + bump chart
├── 07_summary.sql               -- z-score findings + heatmap (recomputed inline)
├── 08_overview.sql              -- hero strip: 6 headline-metric cards (recomputed inline)
├── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline by wait_class
│                                   (reads dba_hist_active_sess_history directly)
├── 10_db_time_summary.sql       -- stacked DB time across the full compared span
├── 11_top_sql_ash_breakdown.sql -- per-Top-N-SQL ASH stacked-area cards
├── 12_param_changes.sql         -- init parameters that differ across windows
│                                   (reads dba_hist_parameter; per-window end snap)
└── lib/                         -- SQL/PL/SQL fragments shared across sections via @@
    ├── windows_cte.sql          -- run_params → … → valid_windows CTE chain
    ├── nth_csv.plsql            -- INSTR-based PL/SQL CSV parser (preserves empty tokens)
    ├── js_sparkline.plsql       -- ~30-line inline-SVG sparkline renderer (CDN-free)
    ├── js_wait_colors.plsql     -- shared OEM-13c-aligned wait_class color palette
    ├── js_markers.plsql         -- inits window.AWR_MARKERS + AWR_markLine() (timeline markers)
    ├── marker.sql               -- emit one user-defined timeline marker (~1=instant, ~2=label)
    ├── no_markers.sql           -- no-op stub used when marker_file is empty
    └── templates/               -- per-template metric + wait-event target lists
        ├── comprehensive/       -- default; full curated lists (27 SYSSTAT + 23 SYSMETRIC,
        │   │                       and a '*' sentinel for waits = no event filter)
        │   ├── sysstat_load_targets.sql
        │   ├── sysmetric_targets.sql
        │   └── wait_event_targets.sql
        └── simple/              -- triage-friendly subset (9 SYSSTAT + 8 SYSMETRIC + ~10 waits)
            ├── sysstat_load_targets.sql
            ├── sysmetric_targets.sql
            └── wait_event_targets.sql
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
`sql/lib/windows_cte.sql`; the curated stat/metric/wait lists are
per-template under `sql/lib/templates/<template>/` (see "Templates"
below); the `nth_csv` PL/SQL helper is in `sql/lib/nth_csv.plsql`;
the inline SVG sparkline JS and the wait-class color palette are in
`js_*.plsql`. A view or helper package would violate the no-DDL rule,
so include-files are the chosen mechanism. To change the windows
logic, edit one file under `sql/lib/` and every consumer picks the
change up.

### Templates: per-run metric + wait-event subsetting
Sections 02/03/07 (metrics) and 04/05/07 (waits) read their target
lists from `sql/lib/templates/<template>/`:
- `sysstat_load_targets.sql`  — SYSSTAT names for the Load Profile
- `sysmetric_targets.sql`     — SYSMETRIC_SUMMARY names + is_additive flag
- `wait_event_targets.sql`    — DBA_HIST_(SYSTEM_EVENT|BG_EVENT_SUMMARY)
                                event_names; a single `'*'` row is a
                                sentinel meaning "no filter".

The driver resolves `~template` (8th DEFINE, default `'comprehensive'`)
into `~template_dir = sql/lib/templates/<template>` once up front, so
every consumer writes the include as
`@@~template_dir/<file>.sql`. Unknown template names abort the run via
the `TO_NUMBER('x')` ORA-01722 trick (same pattern as `step_unit`
validation). To add a new template, drop a directory with all three
files into `sql/lib/templates/` and extend the whitelist `CASE` in the
driver. Two templates ship today:
- `comprehensive` (default) — the full curated lists used pre-templates.
  The wait-event file is the `'*'` sentinel so the firehose-then-top-N
  behavior is byte-identical to the pre-template report.
- `simple` — a triage-friendly subset (~9 SYSSTAT, ~8 SYSMETRIC, ~10
  wait events). Deliberately includes the SYSSTAT/SYSMETRIC names that
  section 08's hero strip hard-references, so the hero cards keep
  rendering instead of falling to `n/a`.

Wait-event filter idiom (in every consumer that joins
`dba_hist_system_event` or `dba_hist_bg_event_summary`):
```sql
AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
      OR se.event_name IN (SELECT event_name FROM wait_targets) )
```
This keeps the `comprehensive`-template plan byte-identical (the
`EXISTS` short-circuits the per-row IN-list) while still applying a
proper allowlist for curated templates.

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
Ten user-facing vars: `target_end`, `win_hours`, `weeks_back`, `top_n`,
`inst_num`, `step`, `step_unit`, `template`, `debug`, `marker_file`.
`inst_num = 0` means
aggregate across RAC instances; any other value filters to that
instance. `target_end = 'AUTO'` means "prior full hour relative to
SYSDATE" (resolved in the driver into `target_end_resolved`).
`step` + `step_unit` (default `1` + `'w'`) control the cadence between
adjacent comparison windows; `step_unit` is one of `'h'` (hours), `'d'`
(days), `'w'` (weeks). The original "same hour-of-week, N prior weeks"
behaviour is the default (`step=1, step_unit='w'`). Setting `step=1,
step_unit='h'` compares the last `weeks_back+1` consecutive 1-hour
windows in a straight line back from `target_end`. `template` selects
which subset of metrics + wait events to display; see "Templates"
above. `debug` is a UI-only toggle: any case-insensitive truthy form
(`Y`, `YES`, `1`, `ON`, `TRUE`, `T`) resolves into `debug_termout='ON'`
and unmutes the per-section progress markers; everything else
(including the default `N`) resolves into `'OFF'`. See "Debug logging"
below. `marker_file` is an optional path to a timeline-marker config
file; empty/unset (the default) means no markers. See "Timeline markers"
below. The driver resolves `step_hours = step * (1|24|168)` plus
`period_unit_short` / `period_unit_long` / `period_unit_title` /
`period_step_label` / `period_axis_fmt` once up front; every section
uses `~step_hours/24` (NOT the literal `7`) as the cadence multiplier.
The driver also resolves `run_id` (17-digit timestamp from
`SYSTIMESTAMP`), `dbid`, `db_name`, `host_name`, `db_version`,
`caller_user`, `generated_at_s`, `dow_name`, `report_path`,
`template_name`, `template_dir`, `debug_termout`, and `marker_include`
up front; every section references them as `~name`. No section ever
re-resolves these values.

**Multitenant `dbid` gotcha (data-driven resolution).** `~dbid` is **not**
`v$database.dbid` — it is resolved data-drivenly by the `dbo` inline view in
the driver as *the DBID owning the freshest snapshot visible in the current
container*. This is required because in multitenant there is no single static
source that is correct everywhere:
- In a PDB, `v$database.dbid` returns the **CDB root's** DBID, not the PDB's.
- Whether the `DBA_HIST_*` rows a PDB can see are stored under the **CDB DBID**
  or under the **PDB's `CON_DBID`** depends on PDB-level AWR (autoflush):
  with local AWR on, rows live under the PDB's `CON_DBID` and the root's
  repository is invisible inside the PDB; with it off, the only visible rows
  are the root's, under the CDB DBID. So `CON_DBID`-only would return an empty
  report against a PDB that has *no* local AWR, and `v$database.dbid`-only
  misses a PDB that *has* local AWR — the original bug.
The `dbo` view picks `MAX(end_interval_time)`'s DBID from `dba_hist_snapshot`,
falling back to `CON_DBID` only when AWR is empty (so `~dbid` is never NULL).
In a non-CDB and in the CDB root this resolves to the same DBID as
`v$database.dbid`, so existing output (and the dbmint byte-identity test) is
unchanged. Every AWR query filters `dbid = ~dbid`, so this single resolution
point governs which container's data the whole report reflects. The header
`db_name` is likewise suffixed with `/ <CON_NAME>` in a PDB so the report is
unambiguous about which container it covers.

### Timeline markers
`marker_file` lets a user annotate the dated charts with milestones
(patch applied, index rebuild, incident, release). It is an **optional**
path to a config file; the driver resolves `marker_include` via the same
CASE-to-path trick as `template_dir` — empty `marker_file` (TRIM of `''`
is NULL in Oracle) → `sql/lib/no_markers.sql` (no-op stub), otherwise the
caller's path. The prologue always `@@`-includes exactly one marker file,
so there is no conditional-include problem.

Flow: `sql/lib/js_markers.plsql` (included right after `js_sparkline.plsql`)
emits one `<script>` that inits `window.AWR_MARKERS=[]` and defines
`window.AWR_markLine(catLabels)`. Then `@@~marker_include` runs; each line
of the user's config is `@@sql/lib/marker '<YYYY-MM-DD HH24:MI>' '<label>'`,
and `sql/lib/marker.sql` emits `window.AWR_MARKERS.push({t,label})`. The
four **calendar-axis** charts — sections **00** (masthead), **09** (ASH
timeline), **10** (DB-time summary), **11** (per-SQL ASH breakdown) — call
`AWR_markLine(<their category array>)` in their ECharts init block and
attach the result as `series[0].markLine`, alongside the existing
`markArea` window bands. The per-window sparklines (sections 02–08) are
NOT calendar timelines (x-axis is week offsets), so they get no markers.

Gotchas:
- `sql/lib/marker.sql` runs under the driver's `SET DEFINE '~'`, so its
  positional parameters are `~1` / `~2`, **not** `&1` / `&2`.
- The config file uses `@@sql/lib/marker` (full path from the project
  root) because SQL\*Plus resolves nested `@@` paths against the outermost
  caller — same rule as every other `@@sql/lib/` include.
- The x-axis is `type:"category"` of `'YYYY-MM-DD HH24:MI'` strings, not a
  time axis, so `AWR_markLine` snaps each marker to the nearest category
  tick (client-side) and drops markers outside a chart's span per chart.
- Markers are chart-only: offline (no ECharts) they don't draw, which is
  inherent — the init blocks `return` before touching `markLine`.
- A malformed instant is skipped with an HTML comment, not a fatal error
  (the marker file is included after SPOOL starts, so aborting there would
  truncate the report). Labels with a single quote must double it.
- See `markers.example.sql` for the user-facing format.

### Debug logging
`sql/lib/debug_log.sql` is the single helper that emits per-section
progress markers without polluting the HTML spool. The driver
`@@`-includes it before every section's main include with a
`DEFINE _dbg_msg = '...'` line setting the label. Mechanism per call:
`SPOOL OFF` → silent `SELECT TO_CHAR(SYSTIMESTAMP, ...)` (captured via
`COLUMN dbg_ts NEW_VALUE dbg_ts NOPRINT` declared once in the driver)
→ `SET TERMOUT ~debug_termout` → `PROMPT [awr_trend ~dbg_ts] ~_dbg_msg`
→ `SET TERMOUT OFF` → `SPOOL ~report_path APPEND`. Cost when disabled
is one round-trip per section (≤ 12) — negligible. Verified
byte-identical HTML output between `debug=N` and `debug=Y` runs.

**Gotcha — Oracle identifiers cannot start with an underscore.** The
column alias for the timestamp slot is `dbg_ts`, **not** `_dbg_ts`.
The latter raises `ORA-00911: invalid character`, and because the
driver runs under `WHENEVER SQLERROR EXIT SQL.SQLCODE` that error
aborts the entire run right after the prologue — producing a
213-line truncated HTML stub with zero sections. (The `_dbg_msg`
substitution variable name is fine because that's a SQL\*Plus DEFINE
name, not a column identifier.) If you ever rename either slot, keep
the leading character a letter and re-run the byte-identity smoke
test on dbmint.

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

Each template's `sysmetric_targets.sql` tags every metric with an
`is_additive` flag ('Y'/'N'). Sections 03 and 07 read the flag from
the targets file; section 08's hand-maintained `cards` CTE carries an
inline `is_add` column for the same purpose. The aggregation pattern
is two-step in every consumer: `snap_value = (SUM|AVG)(sm.average)
GROUP BY week, metric, snap_id`, then `metric_value = AVG(snap_value)
GROUP BY week, metric`. On single-instance, SUM and AVG over one row
are identical, so this is a no-op.

### Severity classes (must stay aligned with CSS in `_style.sql`)
`CRITICAL` → `crit`, `WARN` → `warn`, `OK` → `ok`,
`INSUFFICIENT_HISTORY` / `FLAT_BASELINE` → `skip`, informational → `info`.
If you add a new severity, update both `07_summary.sql`, `08_overview.sql`
(it computes the same labels inline for the hero cards), and `_style.sql`.

### Findings are recomputed, not shared
Section 07 (findings) and section 08 (overview hero) each recompute
their own z-scores from the AWR views. They do not share data. The
LOAD/METRIC/WAIT target lists are now single-sourced per template
from `sql/lib/templates/<template>/{sysstat_load,sysmetric,wait_event}_targets.sql`
and `@@`-included by sections 02/03 (LOAD/METRIC), 04/05 (waits) and
07 (all three), so adding or removing a stat from a template updates
every consumer for that template in lock-step. Section 08's 6 hero
cards reference specific LOAD/SYSMETRIC names by hand; if a template's
target list omits one of those, the hero badge falls back to `n/a` —
the `simple` template deliberately keeps the 6 names included so this
doesn't trigger.

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
- Don't hardcode `@@sql/lib/sysstat_load_targets.sql`,
  `@@sql/lib/sysmetric_targets.sql`, or any flat path under `sql/lib/`
  for the curated metric / wait-event lists. Those files moved under
  `sql/lib/templates/<template>/` and every consumer must use
  `@@~template_dir/<file>.sql` so the active template's lists are
  picked up. See "Templates" in Core conventions.
- Don't change the `'*'` sentinel idiom for wait_event_targets without
  updating every consumer (sections 04/05/07) and the comprehensive
  template's file in lockstep. The sentinel is what keeps
  comprehensive-template output byte-identical to the pre-template
  report.
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
