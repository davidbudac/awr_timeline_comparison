# CLAUDE.md

Guidance for future agent sessions working on this repo. `AGENTS.md` (read by
Codex and other agents) is a symlink to this file — edit here only.

## What this is

Pure-SQL Oracle 19c toolkit that compares AWR snapshots of **the same hour
across periods** (e.g. Mon 09:00–10:00 today vs the four prior Mondays) and
flags drastic changes via z-score, rendering a single self-contained HTML
report. Requires Oracle 19c + Diagnostic & Tuning Pack. No Python; only a thin
`sqlplus` wrapper.

**Read-only invariant (the whole point of the design):** the driver and every
numbered `sql/` section issue `SELECT` only — no DDL/DML/COMMIT, no scratch
schema. Everything is recomputed in-flight from `DBA_HIST_*` on each run, so it
runs as a read-only analyst and on a physical standby. The *only* script that
writes is `side/create_weekly_baselines.sql` (optional, orthogonal, calls
`CREATE_BASELINE`); the main report never reads its baselines.

**Offline rendering:** the report loads Apache ECharts from a CDN for the large
charts. If the CDN is unreachable, `<script onerror>` sets `body.no-charts`,
hiding chart divs (tables still show every number) with an amber banner. Inline
SVG sparklines and the marker JS are shipped inline and work offline. The
`echarts` var (below) redirects or inlines the library for air-gapped use.

## Entry points

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num] [step] [step_unit] [template] [debug] [marker_file]`
  — wrapper; sets DEFINEs via heredoc then `@@awr_trend.sql`. `MARKERS=` and
  `ECHARTS=` ride as **env vars** (not positional, to keep arg order symmetric).
- `run_awr_trend.sh --configure` (also `-c`/`-i`, or no args at a TTY) —
  interactive bash configurator living in the *same* wrapper. Prompts for every
  var, then prints both a `./run_awr_trend.sh …` command and the equivalent
  `DEFINE … @@awr_trend.sql` block. Pure UX, issues no SQL. Shares a single
  `run_report()` with the positional path; runs under `set -euo pipefail`.
- pure-SQL\*Plus: load defaults then run the driver as **two separate start
  commands** (the driver does NOT define defaults itself, so caller overrides
  survive):
  ```
  sqlplus user/pw@svc <<'SQL'
  @sql/defaults.sql
  @awr_trend.sql
  SQL
  ```
  **Never** put both `@file`s on one command line — SQL\*Plus runs only the
  first and treats the second as a *parameter*, so the driver silently no-ops.

## File layout

```
awr_trend.sql            -- driver: prologue, SPOOL, calls sections, epilogue
sql/
├── defaults.sql         -- canonical DEFINEs for the substitution vars
├── _style.sql           -- embedded CSS (emitted once)
├── 00_params.sql        -- nav + header masthead
├── 01_windows.sql       -- aligned windows, snap pairs, restart guard
├── 02_load_profile.sql  -- SYSSTAT deltas (per template)
├── 03_sysmetric.sql     -- SYSMETRIC_SUMMARY averages (per template)
├── 04_waits_fg.sql      -- foreground waits + wait-class rollup (per template)
├── 05_waits_bg.sql      -- background waits (BG_EVENT_SUMMARY, per template)
├── 06_top_sql.sql       -- Top-N SQL ranked 5 ways + per-dim bump chart
│                        --   (break down by SQL_ID / schema / module / action)
├── 07_summary.sql       -- z-score findings + heatmap
├── 08_overview.sql      -- hero strip: 6 headline cards
├── 09_ash_timeline.sql  -- hourly ASH stacked-area timeline by wait_class
├── 10_db_time_summary.sql      -- stacked DB time across the full span
├── 11_top_sql_ash_breakdown.sql-- per-Top-N-SQL ASH cards (stacked by wait event)
├── 12_param_changes.sql -- init params differing across windows
├── 13_utilization.sql   -- usage profile (template-INDEPENDENT)
├── 14_segment_io.sql    -- top segments by I/O (DBA_HIST_SEG_STAT; template-INDEP)
├── 15_file_io.sql       -- top files by I/O + IOStat-by-filetype (template-INDEP)
└── lib/                 -- @@-included fragments (see conventions)
    ├── windows_cte.sql       -- run_params → … → valid_windows CTE chain
    ├── nth_csv.plsql         -- INSTR-based CSV parser (keeps empty tokens)
    ├── is_oracle_schema.plsql-- 'Y'/'N' Oracle-maintained parsing-schema test
    │                         --   (drives the "Application only" data-sys tag)
    ├── js_sparkline.plsql    -- inline-SVG sparkline renderer (CDN-free)
    ├── js_wait_colors.plsql  -- shared wait_class palette
    ├── js_markers.plsql      -- inits AWR_MARKERS + AWR_markLine()
    ├── marker.sql / markers_inline.sql / no_markers.sql -- marker emitters
    ├── debug_log.sql         -- per-section progress markers (no spool pollution)
    └── templates/<name>/     -- comprehensive (default) / simple / dev
        ├── sysstat_load_targets.sql
        ├── sysmetric_targets.sql   -- names + is_additive flag
        └── wait_event_targets.sql  -- single '*' row = "no filter" sentinel
side/create_weekly_baselines.sql    -- optional baselines (the only writer)
reports/                            -- generated HTML
```

## Substitution variables

Twelve user-facing vars, all DEFINEs (defaults in `sql/defaults.sql`):
`target_end` (`'AUTO'`=prior full hour), `win_hours`, `weeks_back`, `top_n`,
`inst_num` (`0`=aggregate across RAC, else filter to that instance), `step` +
`step_unit` (`'h'`/`'d'`/`'w'`; default `1`+`'w'` = same hour-of-week N weeks
back), `template`, `debug`, `marker_file`, `markers`, `echarts`.

The driver resolves many derived vars **once** up front via `COLUMN … NEW_VALUE`
and every section references them as `~name` (never re-resolves): `step_hours`
(= step × 1/24/168), period labels, `run_id`, `dbid`, `dbid_list`, `db_name`,
`host_name`, `report_path`, `template_dir`, `debug_termout`, `marker_include`,
etc. Sections use `~step_hours/24` as the cadence multiplier — **never the
literal `7`**.

## Core conventions (non-obvious, easy to break)

### Shared bodies live under `sql/lib/`, included via `@@`
A view/package would break the no-DDL rule, so common SQL/PL/SQL is factored
into include files. **Nested `@@` paths resolve against the OUTERMOST caller**
(the driver at project root), so a section must write `@@sql/lib/windows_cte.sql`
— never `@@lib/...` or `@@../lib/...`. Curated lists are per-template, so use
`@@~template_dir/<file>.sql`, never a flat `@@sql/lib/...` path.

### Templates
`template` (default `comprehensive`) resolves to `~template_dir =
sql/lib/templates/<name>`. Three ship: `comprehensive` (full lists; wait file is
the `'*'` sentinel = byte-identical to pre-template behavior), `simple` (triage
subset), `dev` (app-developer view). `simple`/`dev` deliberately retain the 6
SYSSTAT/SYSMETRIC names section 08's hero cards hard-reference (else they show
`n/a`). Add a template = drop a 3-file dir in `templates/` + extend the
whitelist `CASE` (unknown names abort via the `TO_NUMBER('x')` ORA-01722 trick).
Wait-event filter idiom in every consumer (keeps comprehensive plan identical
while still allow-listing curated templates):
```sql
AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
      OR se.event_name IN (SELECT event_name FROM wait_targets) )
```

### `pairs → bounds → deltas` for cumulative counters
For `DBA_HIST_SYSSTAT` / `SYSTEM_EVENT` / `BG_EVENT_SUMMARY`, follow the shape in
`02_load_profile.sql`. Do NOT use `CROSS JOIN targets` + double `LEFT JOIN` (it
drops stats present at only one snap and breaks in aggregate mode). **These views
have NO `*_DELTA` columns — compute `end - begin` manually.** Only
`DBA_HIST_SQLSTAT` exposes `*_DELTA` (used in `06_top_sql.sql`).

### HTML emission
Sections emit markup via `DBMS_OUTPUT.PUT_LINE` in anonymous blocks; SQL\*Plus is
set `TERMOUT OFF / PAGESIZE 0 / HEADING OFF / LINESIZE 32767 / TRIMSPOOL ON`, so
**any bare `SELECT` leaks into the HTML.** Wrap all user-visible strings (SQL
text, event/metric names) in `DBMS_XMLGEN.CONVERT(...)`.

### Multitenant DBID resolution
- `~dbid` is **not** `v$database.dbid` (which returns the CDB root's DBID in a
  PDB). The driver's `dbo` inline view picks the DBID of `MAX(end_interval_time)`
  in `dba_hist_snapshot`, falling back to `CON_DBID` only when AWR is empty.
  Handles PDBs with/without local AWR. Used for the report filename + masthead.
- `~dbid_list` = comma set of ALL DBIDs owning visible snapshots (`dbl` view).
  Needed because a non-CDB migrated into a PDB keeps pre-migration history under
  the old DBID and new snapshots under `CON_DBID`. **Every AWR filter uses
  `dbid IN (~dbid_list)`, not `dbid = ~dbid`.** `windows_cte.sql` resolves snaps
  by time across the list and carries each snap's `s.dbid` forward, so
  window-joined sections (02–08, 11, 12) need no change; a window straddling a
  DBID change is invalidated. Time-range sections (00, 10) scan by TIMESTAMP and
  key bucket maps by `dbid||'|'||snap_id`. Point-lookups (06, 09, 11) just switch
  to `IN`.
- **Single-DBID is byte-identical** to the old `= ~dbid` behavior (verified on
  dbmint). Re-run byte-identity after touching 00/06/09/10/11/12 or
  `windows_cte.sql`. Masthead emits the primary `~dbid` exactly as before and
  only appends "all DBIDs …" when the list has a comma — don't "simplify" that.

### "Application only" filter (`body.app-only`)
A client-side toggle in the sidebar rail (`#app-filter-toggle`, emitted by
`00_params.sql`) that flips `body.app-only` — same body-class hook pattern as
`body.no-charts`, so it's purely CSS-driven and ships in every report (no DEFINE,
no wrapper change). When on it shows only application SQL and its directly
related data — **`#topsql`, `#topsql-ash`, `#segment-io`, `#file-io`,
`#utilization`** — and hides every system-wide section plus the masthead
`.verdict` and `.windows-strip`. All the hide rules live in `_style.sql`; the
**kept-sections list is single-sourced three times that must stay in lockstep**:
the section-hide rule, the `nav.toc a:not([href=…])` link-dim rule, and (by
omission) the data sections you choose to keep. Change one, change all three.

Oracle-internal SQL is filtered at the row/card level: sections 06 and 11 tag
each top SQL `data-sys="Y|N"` from its parsing schema via
`@@sql/lib/is_oracle_schema.plsql` (a curated Oracle-maintained-schema name test
— **no DBA_USERS grant**, deliberately conservative: unknown ⇒ `'N'` so a real
app schema is never hidden). CSS hides `tr/details/.ash-sql-card[data-sys="Y"]`.
Per-SQL charts need no JS (their container is hidden wholesale); the **one**
multi-SQL canvas — section 06's bump chart — listens for the `awr:appfilter`
CustomEvent the toggle dispatches and re-renders with `sys` series dropped
(its series JSON carries a `sys` bool; schema-breakdown entries are tagged too,
module/action are not). Adding the attrs/`sys` field changes the HTML, so this
is a feature, not a byte-identity-preserving refactor — verify by eye, not md5.

### `echarts` var (offline / self-contained)
Polymorphic on value: **empty** → public CDN (byte-identical to before, via
`CASE WHEN TRIM('~echarts') IS NULL`); **http(s) URL** → used verbatim as
`<script src>` (internal mirror); **local path** → emitted as src, then
`run_awr_trend.sh`'s `inline_echarts` splices the file's bytes into the report
(`grep -nF` the marker line + `cat` head/body/tail) for a fully offline single
file. Inlining is wrapper-only (SQL\*Plus can't stream ~1 MB through
`DBMS_OUTPUT`); the pure-SQL\*Plus path can't inline a local path (it prints an
`# NB:` note). A pinned `vendor/echarts.min.js` (Apache-2.0, v5.6.0) ships in
the repo so `echarts=vendor/echarts.min.js` is turnkey offline; `vendor/` also
carries the license + NOTICE (Apache-2.0 §4 compliance) and a README with the
bump procedure. Users may still point at any other copy. Value must contain no
`"`.

### Timeline markers
`marker_file` (on-disk config) or `markers` (file-free inline list, single var).
Priority: `marker_file` > `markers` > `no_markers.sql` stub — the driver
resolves `~marker_include` to exactly one file (CASE-to-path), so the prologue
always includes one. Inline format: `WHEN|LABEL` joined by `;;`. The inline value
must be **single-quote/`|`/`;;`/`~`/`&`-free** (3 quoting layers); the
configurator swaps apostrophes to `’` and strips reserved tokens — keep
`markers_inline.sql` and the configurator's `markersInline()` in lockstep.
`js_markers.plsql` defines `AWR_markLine(catLabels, isoLabels)`; markers attach
to calendar-axis charts (00/09/10/11, one-arg call, ISO category labels) and
per-window trend charts (06/14/15, two-arg call with a parallel `weeksIso` array
because their visible labels are year-less). Sparklines (02/03/08/13) and
value-axis charts (04/05/07) are not dated, so get no markers. Markers are
chart-only (don't draw offline). `marker.sql` runs under `SET DEFINE '~'` so its
params are `~1`/`~2`, not `&1`/`&2`. See `markers.example.sql`.

### Chart render layer
Every chart renders from the **same cursor** as its numeric table — never a
separate slice. Per-row CSVs via `LISTAGG(... ORDER BY week_offset DESC)`
(oldest→newest), emitted as `data-spark="…"` (SVG renderer) or JSON on
`window.AWR_DATA` (ECharts). Numeric CSV forces `NLS_NUMERIC_CHARACTERS='.,'` so
`Number()` parses under any NLS. Sparkline JS has a 2% flatness floor (renders a
midline instead of magnifying noise). Sections that re-grid one column per week
parse the CSV with `nth_csv` (INSTR-based, preserves empty tokens; `@@`-included
just before `BEGIN`). These CSVs are **positional** (slot k = kth week in the
ORDER BY) and LISTAGG drops NULL measures *and their delimiter*, so a nullable
token must fold the delimiter into the measure —
`SUBSTR(LISTAGG(','||token) WITHIN GROUP (...), 2)` — because a bare
`LISTAGG(CASE…THEN ''…, ',')` left-compacts the CSV and renders values under
the wrong week / drifts chart points to the wrong window (lint check
`listagg-null-token`; emitter contract documented in `sql/lib/nth_csv.plsql`).
A non-null sentinel token like `THEN 'null'` is fine.

### `ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'` is load-bearing
The driver pins it right after the `WHENEVER` directives. `step_hours` round-trips
as a trailing-dot string like `'1.'` and is re-parsed with a bare
`TO_NUMBER('~step_hours')`, which honors session NLS. On a `,`-decimal locale
(Czech/German) that raises ORA-01722 and — under `WHENEVER SQLERROR EXIT` —
aborts the whole run. Don't remove it, and don't add a bare `TO_NUMBER('~var')`
over a `.`-rendered value without it. Writes nothing to the DB.

### Window validity (per-instance in RAC)
`windows_cte.sql` pairs begin/end snaps per `(week_offset, instance_number)` and
marks `valid_flag='N'` (with `skip_reason`) when an instance lacks a begin/end
snap, has begin=end, restarted mid-window (`startup_time` differs), or the window
straddles a DBID change. `valid_windows` is the per-instance valid-only
projection consumed by data sections 02–08 (their `GROUP BY week_offset` sums
only surviving pairs). `windows_rollup` aggregates back to one row per
`week_offset` for display (sections 01, 09). Single-instance: no-op,
byte-identical.

### SYSMETRIC additive-vs-ratio aggregation
`DBA_HIST_SYSMETRIC_SUMMARY` is per-(snap, instance). Cross-instance roll-up is
metric-dependent: **rates/counters** (AAS, *_Per_Sec, Session Count) are
`SUM(average)`; **ratios/percentages/latencies** are `AVG(average)`. Flat AVG on
additive metrics undercounts cluster load. Each `sysmetric_targets.sql` tags
metrics `is_additive`; sections 03/07 read it, section 08's `cards` CTE carries
an inline `is_add`. Pattern: `snap_value = (SUM|AVG) GROUP BY week,metric,snap`
then `metric_value = AVG(snap_value) GROUP BY week,metric`. Single-instance:
no-op.

### Severity classes (keep aligned with `_style.sql`)
`CRITICAL`→`crit`, `WARN`→`warn`, `OK`→`ok`,
`INSUFFICIENT_HISTORY`/`FLAT_BASELINE`→`skip`, informational→`info`. A new
severity must update `07_summary.sql`, `08_overview.sql`, and `_style.sql`.

### Findings are recomputed, not shared
Sections 07 and 08 each recompute their own z-scores. The LOAD/METRIC/WAIT target
lists are single-sourced per template and `@@`-included by 02/03, 04/05, and 07.
Inside 07, the unified recompute is `BULK COLLECT`-ed once into a record
collection tagged via `ROW_NUMBER()`; the heatmap and detail loops both walk that
one collection — don't reintroduce a second recompute cursor just for a different
ORDER BY.

### Debug logging
`sql/lib/debug_log.sql` emits one timestamped progress marker per section to
**stdout** without touching the spool (`SPOOL OFF` → silent timestamp SELECT →
`PROMPT` under `~debug_termout` → re-`SPOOL APPEND`). `debug=Y` (any truthy form)
unmutes; HTML is byte-identical to `debug=N`. **Gotcha:** the timestamp column
alias is `dbg_ts`, NOT `_dbg_ts` — a leading underscore raises ORA-00911 and
aborts the run (Oracle identifiers can't start with `_`; the `_dbg_msg` DEFINE
name is fine).

### Tilde gotcha
Every section issues `SET DEFINE '~'`, making `~` the live substitution char.
Any literal `~x` (even in comments/strings, e.g. `~0.003`, `~/path`, or a stray
`~dbid_list` in a comment) triggers an `Enter value for …:` prompt that silently
truncates the section (or aborts a heredoc run with SP2-0310). Write tildes out
in prose; keep `~name` out of comments (use the bare name).

## Verification & testing

- **`./lint.sh` first** (also runs in CI): grep-based checks that encode the
  footguns below — bad `@@` include paths, flat template-target includes,
  stray `~word` substitutions (the tilde gotcha), `dbid = ~dbid` equality,
  leading-underscore identifiers, literal-7 cadence, missing `SET DEFINE '~'`,
  incomplete template dirs. No DB needed; add a check when a new gotcha bites.
- **Test DB: dbmint** (Oracle 19c CDB1, `ssh -p 2201 oracle@dbmint`, `connect /
  as sysdba`). Single-DBID, idle, sparse history.
- **dbmint default-window trap:** with `AUTO` + weekly cadence the test DB
  usually has no valid windows, so *every* data section shows em-dashes. Pin
  `target_end` into a restart-free 15-min-snap stretch (e.g.
  `target_end='2026-06-06 12:00'`, `step_unit='h'`, `win_hours=1`) before
  concluding a section is broken. It's also too idle to clear the 5-sample ASH
  chart threshold and too sparse for z-scores (forces `INSUFFICIENT_HISTORY`).
- **Byte-identity test** (the strongest "no behavior change" signal for refactors
  that shouldn't alter output): rsync to dbmint, generate a pre- and post-change
  report at ~the same wall-clock, normalize volatile bits and compare md5:
  ```sh
  rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex ./ \
    oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2201'
  sed -E 's/run [0-9]{17}/run RUNID/g;
          s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{2}:[0-9]{2}/TIMESTAMP/g' \
    "$1" | md5
  ```
- **Verified on dbmint (2026):** single-DBID byte-identity of the
  window-validity / SYSMETRIC / cross-DBID refactors; section 13 utilization;
  section 06 schema/module/action group breakdowns (clean run, all four
  toggle views populated). **Pending against a real DB:** sections 14
  (segment I/O), 15 (file I/O), and the 06 "By physical reads" dim were written
  while dbmint was unreachable; the 06 module/action breakdowns showed only the
  `(none)` placeholder on idle dbmint (no app sets module/action) — exercise
  against a workload that sets them. The multi-DBID migration path needs a real
  migrated PDB.
- **"Application only" filter verified on dbmint (2026-06-25, hourly window
  `target_end='2026-06-25 13:45'` win=1h weeks_back=2):** clean run, all 16
  sections; toggle button + all three CSS hide rules emitted; `data-sys` tags
  on rows / per-SQL `<details>` / ASH cards; chart-series `sys` flags present.
  Classification correct on real data — `SYS`-parsed SQL → `data-sys="Y"`,
  while the box's own common-user app schemas `C##AWRWH` / `C##AWRRDR` →
  `data-sys="N"` (kept). Confirms the conservative rule: NOT treating `C##%`
  as system is load-bearing — those were genuine application schemas.
  **Live-browser click-through done (2026-07-01, Chrome preview on the v1.0.0
  hourly report):** click flips `body.app-only`; exactly the 5 kept sections
  (+ their TOC links) stay visible, verdict/windows-strip hide, 142/142
  `data-sys="Y"` rows and 87/87 cards hide, and the `awr:appfilter` event
  re-renders all six section-06 dimension charts (series 29/24/28/30/21/10 →
  0 with every series `sys:true` on the idle box; restored on toggle-off).
  Sections 14/15 and the "By physical reads" dim also ran clean in that
  report — still unexercised against a *busy* DB (real segment/file I/O
  volume, app-set module/action); multi-DBID still needs a migrated PDB.
- **Workbench restyle verified end-to-end on dbmint (2026-07-02, hourly
  window `target_end='2026-06-30 14:00'`):** clean run, no ORA-; fixed rail
  with status dots graded from real section content (crit on
  findings/overview/waits via sparkline tints, warn on parameters via
  `td.chg`, neutral on skip-only Top SQL ASH), scrollspy tracks and re-runs
  on `awr:appfilter` (skips hidden sections), app-only keeps exactly the 5
  sections, masthead chart series emit teal (`#0d9488`), <980px fallback OK.
- **LISTAGG positional-CSV fix verified on dbmint (2026-07-02, hourly window
  `target_end='2026-06-30 14:00'` win=1h weeks_back=4):** unit probe on 19.27
  confirmed LISTAGG drops NULL measures (`11,33,44` vs the folded-delimiter
  `,11,,33,44`); pre-fix vs post-fix reports at the same wall-clock: post has
  126/126 sparklines with exactly weeks_back+1 slots (pre: 23 compacted),
  section 06 phantom series — a value plotted at the wrong window for a SQL
  with no current-window rank — went 82 → 0 across all dims, and every one of
  the 454 differing lines was a CSV/series/table-cell realignment (no
  collateral output change; gap-free rows byte-identical).

## Things NOT to do

- Don't add positional args to `awr_trend.sql` — keep it DEFINE-driven so the
  wrapper and pure-SQL\*Plus paths stay symmetric.
- Don't assume `DBA_HIST_SYSTEM_EVENT`/`BG_EVENT_SUMMARY` have `*_DELTA` columns.
- Don't reintroduce a scratch schema to share data — extract a `@@`-included file
  (`sql/lib/`), or `BULK COLLECT` into a collection within one section (section 07
  is the canonical example).
- Don't write `@@lib/...` / `@@../lib/...` (use `@@sql/lib/<file>`), and don't
  hardcode flat `@@sql/lib/*_targets.sql` (use `@@~template_dir/<file>.sql`).
- Don't change the `'*'` wait-target sentinel without updating 04/05/07 and the
  comprehensive template in lockstep.
- Don't concat user strings into HTML without `DBMS_XMLGEN.CONVERT`.
- Don't add external JS/CSS beyond the single ECharts tag — every dependency must
  degrade via `body.no-charts`. Inline sparklines/ribbon stay CDN-free.
- Don't widen the `README.md` grant list without a concrete reason.
- Don't reintroduce the literal `7` as the cadence multiplier — use
  `~step_hours/24`.
