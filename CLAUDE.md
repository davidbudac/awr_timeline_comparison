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

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num] [step] [step_unit] [template] [debug] [marker_file] [profile_days] [sqlmon_detail]`
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
├── 07_summary.sql       -- z-score findings + "Biggest movers" table
├── 08_overview.sql      -- hero strip: 6 headline cards
├── 09_ash_timeline.sql  -- hourly ASH stacked-area timeline by wait_class
├── 10_db_time_summary.sql      -- stacked DB time across the full span
├── 11_top_sql_ash_breakdown.sql-- per-Top-N-SQL ASH cards (stacked by wait event)
├── 12_param_changes.sql -- init params differing across windows
├── 13_utilization.sql   -- usage profile (template-INDEPENDENT)
├── 14_segment_io.sql    -- top segments by I/O (DBA_HIST_SEG_STAT; template-INDEP)
├── 15_file_io.sql       -- top files by I/O + IOStat-by-filetype (template-INDEP)
├── 16_day_profile.sql   -- Day profile: hour-of-day × N prior days (profile_days>0; template-INDEP)
├── 18_sqlmon.sql        -- SQL Monitor summaries + plan-line drift (sqlmon_detail>0; template-INDEP, always on)
├── 17_narrative.sql     -- "What changed": rule-based prose, relocated into the masthead by JS
└── lib/                 -- @@-included fragments (see conventions)
    ├── windows_cte.sql       -- run_params → … → valid_windows CTE chain
    ├── day_profile_cte.sql   -- dp_params → … → dp_scored (shared by 16 + fleet 06)
    ├── nth_csv.plsql         -- INSTR-based CSV parser (keeps empty tokens)
    ├── is_oracle_schema.plsql-- 'Y'/'N' Oracle-maintained parsing-schema test
    │                         --   (drives the "Application only" data-sys tag)
    ├── is_essential.plsql    -- curated LOAD/METRIC/WAIT name test (data-imp row tag; no CSS reads it since v1.5.0)
    ├── metric_policy.plsql   -- THE per-metric policy table (family / canonical / dir / floors)
    │                         --   + policy_bucket(), the one scoring rule (00/07/08/16/17 + score_cells)
    ├── score_cells.plsql     -- score_z / score_bucket / score_cells (04/05/18 Change column;
    │                         --   thin wrapper over policy_bucket -- include metric_policy first)
    ├── json_escape.plsql     -- escapes a string for a JSON literal on one PUT_LINE
    ├── put_clob_chunked.plsql-- emits a CLOB payload in PUT_LINE-sized chunks
    ├── fmt_num.plsql         -- T7: consistent value-cell number formatting (fmt_num/fmt_int)
    ├── dev_bucket.plsql      -- T5: data-dev="1|2|3" heat-tint bucket for prior-window cells
    ├── js_sparkline.plsql    -- inline-SVG sparkline renderer (CDN-free)
    ├── js_wait_colors.plsql  -- shared wait_class palette
    ├── js_markers.plsql      -- inits AWR_MARKERS + AWR_markLine()
    ├── marker.sql / markers_inline.sql / no_markers.sql -- marker emitters
    ├── debug_log.sql         -- per-section progress markers (no spool pollution)
    └── templates/<name>/     -- comprehensive (default) / simple / dev (+ fleet/, fleet-owned)
        ├── sysstat_load_targets.sql
        ├── sysmetric_targets.sql   -- names + is_additive flag
        └── wait_event_targets.sql  -- single '*' row = "no filter" sentinel
side/create_weekly_baselines.sql    -- optional baselines (the only writer)
run_awr_fleet.sh, awr_fleet_extract.sql, sql/fleet/ -- fleet report (see that section)
server/                             -- optional scheduler web app (see that section)
demo/                               -- docs-only synthetic demo report generator (Python; see demo/README.md)
reports/                            -- generated HTML
```

## Substitution variables

Fourteen user-facing vars, all DEFINEs (defaults in `sql/defaults.sql`):
`target_end` (`'AUTO'`=prior full hour), `win_hours`, `weeks_back`, `top_n`,
`inst_num` (`0`=aggregate across RAC, else filter to that instance), `step` +
`step_unit` (`'h'`/`'d'`/`'w'`; default `1`+`'w'` = same hour-of-week N weeks
back), `template`, `debug`, `marker_file`, `profile_days` (`0`=off; the 12th
wrapper positional), `sqlmon_detail` (`0`=off; the 13th wrapper positional;
SQL Monitor plan-line drift, `sql/18_sqlmon.sql` phase 2), `markers`,
`echarts`.

The driver resolves many derived vars **once** up front via `COLUMN … NEW_VALUE`
and every section references them as `~name` (never re-resolves): `step_hours`
(= step × 1/24/168), period labels, `run_id`, `dbid`, `dbid_list`, `db_name`,
`host_name`, `report_path`, `template_dir`, `debug_termout`, `marker_include`,
etc. Sections use `~step_hours/24` as the cadence multiplier — **never the
literal `7`**.

### `target_end` snap-to-snapshot-grid
Both resolving SELECTs (`awr_trend.sql` and `awr_fleet_extract.sql` — a
deliberate lockstep copy, keep them textually parallel) resolve the requested
end via a `snp` inline view: if a snapshot exists within 15 min of the
requested instant (mirroring `windows_cte`'s edge guard), the request is kept
**verbatim** (byte-identical to pre-feature behavior); otherwise it snaps back
to `TRUNC(last snapshot at or before request + 5 min tolerance, 'MI')`, so an
off-grid request (e.g. 16:30 against on-the-hour snaps, or a request inside a
snapshot gap) produces the last real window instead of an all-empty report. No
AWR history at all → request kept (empty report, as before). `dow_name` follows
the snapped value. A second DEFINE, `~target_end_requested`, carries the
pre-snap instant; `00_params.sql` (masthead) and `sql/fleet/07_close.sql`
(drill panel) emit a "Requested end … snapped to last snapshot …" note **only
when the two strings differ** — equal strings must emit nothing. The fleet
drill command uses `~target_end_resolved`, so it echoes the snapped instant and
reproduces the same window. Dense snap grids (≤15-min spacing) can never
trigger the snap, by design.

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

### `data-sys="Y|N"` tags (informational)
Sections 06, 11 and 18 tag each top SQL / ASH card / SQL Monitor row with
`data-sys="Y|N"` from its parsing schema (06/11) or executing user (18)
via `@@sql/lib/is_oracle_schema.plsql` (a curated Oracle-maintained-schema
name test — **no DBA_USERS grant**, deliberately conservative: unknown ⇒
`'N'`). Since v1.5.0 no CSS reads the tag: the "Application only" filter
(`body.app-only`, `#app-filter-toggle`, the `awr:appfilter` event and the
bump chart's `sys` series filter) was removed at the user's request. The
attribute and the `sys` bool in 06's series JSON stay as neutral metadata.

### Normal / Full views (`body.normal` / `body.full`, v1.5.0)
The report opens in the **Normal** view; **Full** is the whole report
(the switch was called "Detailed" for one commit). An early inline script
in `00_params.sql` (right after the theme script) adds `body.normal` or
`body.full` before first paint from localStorage `awr-mode` (a hash
`!v=f` wins); with JS off neither class exists and the CSS shows
everything. Sections opt INTO Normal with `data-normal="Y"`: 06 Top SQL,
07 Findings, 08 Headline metrics, 09 ASH timeline always; 12 Parameter
changes, 16 Day profile and 18 SQL Monitor only when they have something
to say (a differing parameter / a day-wide shift / an error, plan change
or DOP downgrade on a Current-window statement), which they signal with a
one-line inline `<script>` that sets the attribute after the fact.
`.full-only` hides Full-only content inside a kept section (07's
per-domain tables + expanders, 06's per-SQL pool, 16's hour table). The
chrome JS (`00_params.sql`, "Normal / Full view") dims rail links to
hidden sections (`.norm-dim`, group `<b>` headers too when every link
under them is dimmed), appends a "+ N more in Full" rail line and a
`.mode-note` at the end of `<main>` (flex `order:3`, same rank as the
sections, so it lands last), and `setMode(det, silent)` flips the
classes, persists (only on an explicit click -- a shared link never
overwrites the reader's choice), re-measures sticky offsets and table
wrappers, and calls `resize()` on every ECharts instance (a chart built
inside `display:none` measured zero width). `revealHash()` switches to
Full by itself when a cross-link targets hidden content. The old
**Triage mode**, **Essential rows** and **Application only** toggles are
gone (v1.5.0); the `data-imp` row tags from `is_essential.plsql` are still
emitted but no CSS reads them. The demo smoke test
(`demo/verify_report.js`) switches to Full before it clicks tabs / sort
headers / expanders, since those are hidden in Normal.

**Masthead pieces (v1.5.0):** the "What changed" block (`17_narrative.sql`)
is a `<ul class="narr-list">`, one `<li>` per rule via `add_item(label,
num, sub, why, href, link)` — spans `.n-lbl` / `.n-num` / `.n-sub` /
`.n-why` and an `a.n-go` — laid out as a 5-column grid (2 columns under
700 px); no prose sentences any more. The compared-windows strip folds its
dated chips into `<details class="windows-more">` whose `<summary>` holds
the Current chip (a `.wchip[data-w="0"]` — the chip click handler calls
`preventDefault` inside a summary so highlighting does not toggle the
fold), a "vs N prior windows, every step, back to <date>" clause and a
show / hide toggle. Section 07's "Biggest movers" table (`#findings-movers`)
carries `data-nocount` so the rail count pills don't double-count its
rows against the detail tables below it.

### Section order (v1.5.0)
`awr_trend.sql` includes the sections in **visual** order (00, 10, 08, 09,
07, 01, 16, 13, 02, 03, 04, 05, 06, 11, 18, 14, 15, 12, 17); `_style.sql`
no longer re-sorts them with flex `order:` (only the masthead / rail /
footer keep a rank for the narrow layout). Adding a section = insert its
`@@` at the right visual spot in the driver, its link at the same spot in
`00_params.sql`'s rail, and the same slot in `demo/gen_demo_report.py`'s
`SECTIONS`. Sections are independent recomputes, so the order is free
except 17 (last, relocates itself). The report body is a
`<main id="main-start">` (display:contents) opened at the end of 00 and
closed in the driver epilogue; `body > section` selectors must also match
`main > section`.

### Facelift chrome hooks (v1.4.0)
A grab-bag of small, single-sourced HTML attribute/class contracts wired up
by `00_params.sql`'s inline JS and `_style.sql`'s CSS, reused across
sections. All are purely client-side (no DEFINE, no wrapper change) and
degrade to "just show everything" with JS off:
- **`tr[data-tail="Y"]` + `.expander[data-for][data-n][data-noun]`** — long-
  tail row collapse. The expander's click handler toggles `.open` on the
  table named by `data-for`; `data-n`/`data-noun` feed the "Show N more
  rows" label. Used by 07's detail tables, 06's SQL pool, 11's sub-threshold
  ASH cards.
- **`td[data-dev="1|2|3"]`** — prior-cell heat tint from
  `sql/lib/dev_bucket.plsql`'s `dev_attr(cur, prior)`; no attribute at all
  means "close enough to Current, don't tint" (see that file for the exact
  bucket thresholds).
- **`[data-w="N"]` (0 = current) + `awr:window`** — every window-indexed
  `<th>`/`<td>` and the masthead's `.wchip` chips carry `data-w`; clicking a
  chip (or a `th[data-w]`) toggles `.hl` on every element sharing that
  offset and dispatches a `document`-level `awr:window` CustomEvent (sibling
  of `awr:theme`/`awr:mode`) that chart sections turn into a markArea/
  highlight on the matching series.
- **`.badge.sig`** — the "σ≈0" pill `score_cells.plsql` appends after a
  z-value when the baseline sigma is degenerate (< 1% of |mean|), pairing
  with a bolded %-delta cell so the reader isn't misled by a blown-out z.
- **`section[data-normal]` + `.full-only`** — the Normal / Full views
  (see that section above); replaced the v1.4.0 `data-triage` / `.hidetri`
  triage mode.
- **`.tabs[data-tabs]` / `.tabpanel[data-tabs][data-t]`** — a delegated
  click on `.tabs [data-t]` shows the matching `.tabpanel` in the same
  group and hides its siblings; used by Top SQL's five ranking dimensions.
  Panels holding an ECharts instance must resize on activation (a chart
  built while its container was `display:none` measures zero width).
- **`.copy-btn[data-copy]`** — delegated click copies the text of the
  element `data-copy` selects (clipboard API with a `<textarea>`
  fallback); inline by default, absolutely positioned only inside `pre`/
  `.codewrap`. Per-table CSV/MD toolbars (`.tbl-tools`) auto-inject above
  any table with ≥4 rows and no `data-notools`.
- **`data-nosort` / `data-nocount` / `data-notools`** — table-level opt-outs:
  `data-nosort` disables the click-to-sort header wiring (numeric parser
  handles `,` `%` `▲` `▼` `−` and k/M/G suffixes — keep that letter set in
  sync with `sql/lib/fmt_num.plsql`'s suffix choice), `data-nocount` keeps a
  table's rows out of the rail count pills (07's movers table), `data-notools`
  suppresses the CSV/MD toolbar.
- **`.chip`** — generic small pill styling shared by window chips, rank
  chips (Top SQL pool E/C/G/R/X), and similar inline badges; not a
  behavioral hook, just a shared visual class.
- **Narrative section pattern** (`sql/17_narrative.sql`) — a section that
  needs data only cheap to gather after the rest of the report has run
  emits its block hidden at the end of the document
  (`<div id="narrative-src" class="narr" hidden>`) and a one-line inline
  script relocates it into a slot the masthead already reserved
  (`<div id="narrative-slot">` in `00_params.sql`), clearing `hidden` after
  the move. JS off → the block stays hidden, which is fine because every
  fact it states is also rendered in the section it links to. Nothing to
  say ⇒ the section emits only its two `AWR-SECTION` markers, no `<div>`.
- **Number formatting (T7, `sql/lib/fmt_num.plsql`)** — `fmt_num` renders
  value cells (Current / prior / mean / sd, hero headline text) at ~4
  significant digits with a k/M/G suffix ≥1e4/1e6/1e9 and the full-precision
  number in the cell's `title`; `fmt_int` is for naturally-integer counts
  (executions, snap ids, ranks). Neither touches `%`-delta/z cells (still
  `score_cells.plsql`'s job) nor `data-spark`/`window.AWR_DATA` JSON, which
  stay raw numbers under the driver's pinned NLS setting.

New gotchas from this pass:
- PL/SQL `v <> ''` is never TRUE — an empty string `IS NULL` in Oracle, so
  a guard must be `v IS NOT NULL`, not `v <> ''''` (bit `17_narrative.sql`'s
  `v_tail` guard live).
- `DB time`/`DB CPU` live in `DBA_HIST_SYS_TIME_MODEL` (microseconds), not
  `DBA_HIST_SYSSTAT` — `v$sysstat`/`dba_hist_sysstat` has no such row at all.
- `DBA_HIST_PARAMETER` is per-container in a CDB: a bare join fans out one
  row per container per (dbid, snap_id, instance_number), so any consumer
  comparing values across windows must collapse by `con_id`/`con_dbid`
  (lowest wins — the instance-level value a DBA means by "the parameter").
  `17_narrative.sql`'s R3 does this; `12_param_changes.sql` was fixed the
  same way concurrently.
- A `.copy-btn` is inline by default and absolutely positioned only inside
  `pre`/`.codewrap` — placing one elsewhere without that ancestor needs an
  explicit position context or it flows inline unexpectedly.

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

### Day profile (`profile_days`, section 16 + fleet band 06)
Opt-in via `profile_days` (single-DB, default `0`) / `FLEET_PROFILE_DAYS`
(fleet, default `0`). Every hour of the 24 h ending at `target_end` is scored
against the same hour-of-day on the N prior days at a **fixed 1-day cadence**
(deliberately independent of `step`/`step_unit` — the main comparison keeps
its own cadence). The 9 × 24 × (N+1) matrix lives in ONE shared include,
`sql/lib/day_profile_cte.sql` (`dp_params → dp_targets → dp_snaps → dp_pairs
→ dp_deltas → dp_cells → dp_grid → dp_pivot → dp_scored`), consumed by
`sql/16_day_profile.sql` (ECharts heatmap + per-stat line + always-emitted
table) and `sql/fleet/06_day_profile.sql` (`window.FLEET_PROFILE[alias]`
payload → inline-SVG heatmap in `js_fleet_charts.plsql`'s `renderProfile`).
It is the **LAG-delta time-range scan** of 00/10, NOT `windows_cte` (which
only yields `weeks_back+1` windows): consecutive `dba_hist_snapshot` pairs
per `(dbid, instance)` that survive the `startup_time` restart guard, joined
to `DBA_HIST_SYSSTAT` with the extra `pr.prev_snap_id = d.prev_snap_id`
match (a missing sysstat row can never widen a delta across a gap); each
pair lands in the cell containing its midpoint; cell = `SUM(delta)/SUM(span)`
summed across instances. **Coverage guard:** `< 1800 s` of span in an hour
⇒ NULL (2-h snap intervals, gaps), never 0. The stat list is fixed inline
(template-independent, like 13) — do NOT turn it into a `*_targets.sql`
(lint check 2). Scoring is section 07's `scored` CASE verbatim. `hour_slot 0`
is the hour ending at `target_end`; consumers `ORDER BY hour_slot DESC` for a
chronological axis; `hour_label` is the hour's START. The section's heatmap
is **signed** z (diverging ramp), unlike 07's |z|. **Byte-identity at 0:**
the section emits only its two `AWR-SECTION` markers (no `<section>`), the
nav link and the masthead `strip-meta` clause are `CASE … ELSE ''`, the
fleet band and the drill command's 12-slot tail are likewise guarded. The
fleet band is **informational**: no `FLEET-COUNTS`, no score/sort impact.
Table rows carry `class="crit|warn"` (rail dot grading) but no `data-imp`.

### SQL Monitor (`sql/18_sqlmon.sql`, phase 1 + phase 2)
Template-independent, always on (like 13-16, but unlike 16 it still renders
a one-line note when empty rather than staying silent). Source:
`DBA_HIST_REPORTS` where `component_name = 'sqlmonitor'` — one row per
persisted execution, `key1` = sql_id, `key2` = sql_exec_id, `key3` =
sql_exec_start as the **string** `'MM:DD:YYYY HH24:MI:SS'` (numeric-only, so
NLS-safe, but parse it with an explicit `TO_DATE(key3,'MM:DD:YYYY
HH24:MI:SS')` mask — never trust it as a DATE). `report_summary` is a
VARCHAR2 XML parsed via `XMLTABLE('/report_repository_summary/sql' ...)`;
`dbid` is the CDB dbid, so `dbid IN (dbid_list)` applies unchanged. Phase 1
is summaries only — `DBA_HIST_REPORTS_DETAILS` (the multi-KB per-execution
plan CLOB) is never touched, so there is no plan-line drift / diff feature
yet (see `design/SQLMON_DESIGN.md`'s "Phase 2", not implemented).

**Noise floor** is at the sql_id level, not per-execution: a sql_id is
included in the comparison table only if ANY of its captured executions in
the full compared span has `elapsed_time >= 1,000,000` microseconds, OR
`status = 'DONE (ERROR)'`, OR shows more than one distinct non-zero
`plan_hash` — then every execution of that sql_id is aggregated (no per-exec
floor). This keeps a lightly-loaded instance's table from being dominated by
tiny parallel-execution noise (SQL Monitor's capture policy always persists
parallel statements) while never hiding a real regression. The **execution
scatter** chart plots every captured execution in the full span regardless
of the floor (capped at the 3,000 most recent) — the floor only shapes the
summary table and its Current-window-max-elapsed ranking.

**Sampling caveats** (stated in the section's own caption, and see the
design doc): only completed, expensive-enough, or parallel executions are
ever persisted, so a sql_id's absence does not mean it ran fast, and row
counts (`n`) are never execution-rate counts. An execution still running at
`target_end` has no report yet, so the Current window can under-report its
slowest statement. Attribution to a compared window is by parsed
`sql_exec_start`, i.e. execution *start* time, against a *valid*
`windows_rollup` row — an execution that starts inside a skipped window (or
outside every window) still appears in the full-span scatter but not in the
per-window table numbers.

Scoring reuses section 07's `scored` CASE verbatim via
`sql/lib/score_cells.plsql`, on max elapsed time (Current vs. prior valid
windows). `data-sys="Y|N"` comes from `is_oracle_schema()` on the
executing user (not a parsing-schema lookup — SQL Monitor's XML reports the
session's `user`, not the parsing schema). `sql/17_narrative.sql` gained rules
R6-R9 (plan change / DOP downgrade / errors / new sql_ids in the Current
window), each its own bounded `dba_hist_reports` scan per the "findings are
recomputed, not shared" convention. "New" means *no capture anywhere in the
span before the Current window starts* (both the section's chip and R9) —
"absent from the prior compared windows" would fire for statements that run
all day but missed a sparse 1-h slot. A sql_id whose every capture sits in a
skipped window still gets a table row (empty window cells) so its error flag
and drill line survive. `key3` is parsed with `DEFAULT NULL ON CONVERSION
ERROR`: `DBA_HIST_REPORTS` holds other components (`perf`, ...) whose key3 is
not a date, and Oracle may evaluate the `TO_DATE` before the
`component_name` filter. The pool table is `data-nosort data-notools`
(each statement row is paired with a detail row right below it). Cost: the
section plus R6-R9 scan `dba_hist_reports` (with `XMLTYPE` parsing) six
times over the span — fine at thousands of rows, worth a single BULK COLLECT
if a busy DB ever makes it slow.

**Phase 2 (`sqlmon_detail`, default 0): plan-line drift.** Opt-in var, same
byte-identity-at-default contract as `profile_days`: at `sqlmon_detail=0` the
whole block (and R10 below) is skipped, so the report is byte-identical to
phase-1-only output. A positive N renders a `<h3>Plan-line drift</h3>` block
inside `#sqlmon`, one `<div class="sqlmon-drift">` per candidate. Candidates:
sql_ids from the same noise-floor `included` set, with `plan_hash <> 0`, a
Current-window execution AND at least one prior-*valid*-window execution;
ranked by change bucket (large > moderate > rest, via section 07's `scored`
CASE on max elapsed) then Current max elapsed DESC, `FETCH FIRST N ROWS
ONLY`. Per candidate: **current** = the Current window's slowest execution
(`plan_hash <> 0`), **baseline** = the prior-window execution whose elapsed is
closest to the prior median (tie → most recent). Exactly two
`DBA_HIST_REPORTS_DETAILS` CLOBs are read per candidate (joined on
`report_id`+`dbid`, **no `component_name` column there**) and `XMLTABLE`'d
against `/report/sql_monitor_report/plan_monitor/operation` (verified shape,
pinned in `design/SQLMON_DESIGN.md`: `@id`/`@parent_id`/`@name`/`@options`/
`@depth`, `object/owner`/`object/name`, `optimizer/cardinality` for estimated
rows, and `stats[@type="plan_monitor"]/stat[@name=...]` for `starts` /
`cardinality` (actual rows) / `duration` (s) / `max_memory` — **no
activity-%/ASH block exists in the stored XML**, so the diff is limited to
those four measures). Lines are `FULL OUTER JOIN`ed on
`(line id, operation name+options, owner.object)`; a plan-hash difference
between the two executions is called out in the block's caption and
unmatched lines render one-sided, flagged `class="crit"` (`class="warn"` when
duration share moved ≥10 points or actual rows changed ≥10x on a matched
line). A one-sentence "what moved" lede — the line with the single largest
duration-share increase, skipped below a 5-point move — is the entire point
of phase 2. Each candidate's two CLOB reads, and its XML parse, are each
wrapped in their own `BEGIN/EXCEPTION WHEN OTHERS` so a corrupt/oversized
report can never abort the run — it renders a muted one-line note instead.
Cost is hard-bounded to `sqlmon_detail` candidate pairs (2×N CLOBs). Wired
through `run_awr_trend.sh` exactly like `profile_days` (13th positional,
configurator prompt, `v_nonneg`); `run_awr_fleet.sh`'s `FLEET_SQLMON_DETAIL`
env knob rides it into the optional **per-DB detailed report only** — the
lean extract heredoc never sets it (defaults to 0 via `sql/defaults.sql`).
`sql/17_narrative.sql` gained **R10**, recomputing (not sharing) the single
top candidate and stating its lede when `sqlmon_detail>0`; at 0 it runs no
query at all.

**Fleet band (`sql/fleet/06b_sqlmon.sql`, always on).** Fleet-owned copy of
the phase-1 "new"/floor logic (never edits the single-DB file), called from
`awr_fleet_extract.sql` right after `06_day_profile` and before `07_close`,
its own `AWR-SECTION: fleet_06b` markers. Cheap summaries only — it never
reads a `DBA_HIST_REPORTS_DETAILS` CLOB, so it does not depend on
`sqlmon_detail` at all (that var only reaches the optional per-DB detailed
report). Renders a `.detail-block` "SQL Monitor" band: executions in
Current / full span, errors in Current, plan changes, DOP downgrades, and a
top-5-by-Current-max-elapsed `table.dt` with per-row `.chip` flags (a
fleet-owned CSS rule in `00_fleet_chrome.sql`, unrelated to the single-DB
`.chip` in `sql/_style.sql`). Emits `<!-- FLEET-COUNTS sqlmon cur=A span=B
err=X planchg=Y downgrade=Z -->` — **informational only**, like the Day
profile band: the assembler's scoring regexes match only `FLEET-COUNTS
findings` and `FLEET-COUNTS topsql`, so this comment can never move the row
score or sort order.

### Output archiving (`ARCHIVE` / `FLEET_ARCHIVE`)
Both wrappers can zip/tar their finished output, wrapper-owned only (the SQL
never sees these vars). Value semantics, identical on both: **empty/`0`/`N`/
`no`/`off`** → disabled (default, byte-identical to before this feature);
**`1`/`Y`/`yes`/`on`/`auto`** → auto-pick the best available tool (`zip` if
on `PATH`, else `tar` piped through `gzip` → `.tar.gz`, else plain `tar`),
noting any fallback on stderr; **`zip`**/**`tgz`**/**`tar`** → force that
format, erroring (before anything runs) if the required tool (`zip`, or
`gzip` for `tgz`) isn't on `PATH`. Applied LAST, after the report/run folder
already exists and (single-DB) after any `ECHARTS` inlining — so an archive
failure never undoes a successful run; it warns on stderr and the wrapper's
exit code becomes **4** instead of 0 (documented in both `--help`/usage
texts). A pre-existing archive of the same name is `rm -f`'d first (so zip
doesn't "update" into a stale one); the archiving tool always runs from
inside `reports/` in a subshell so the archive entry is a bare filename, per
`ARCHIVE`/`FLEET_ARCHIVE`'s different scopes:
- `run_awr_trend.sh` (`ARCHIVE`, via `archive_report`) archives the single
  finished `.html` as `reports/<report-basename>.<ext>`.
- `run_awr_fleet.sh` (`FLEET_ARCHIVE`, via `archive_fleet_run`) archives the
  **entire per-run output folder** (`reports/awr_fleet_<ts>_run<id>/`,
  i.e. `index.html` + every `detail_<alias>.html`) with that folder as the
  archive's one top-level entry — `reports/awr_fleet_<ts>_run<id>.<ext>` —
  applied after BOTH a live run and `--assemble` (the `fleet_work_<id>/`
  extract workdir is never included). Per the cardinal no-single-DB-edits
  rule, this is a fleet-owned copy of the resolve/archive helpers, not a
  shared function.
`tar -z`/`-j`/`-J` (or any GNU-only tar compression flag) is **banned** —
AIX 7.2's bundled `tar` has no compression flag at all, so `tgz` always
shells out to a separate `gzip` process instead. `lint.sh` check 10 greps
both wrappers for `tar`+`z`/`j`/`J` alongside its existing GNU-only-flag
checks.

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

### ECharts theme re-styling (`awr:theme`)
Every ECharts chart reads its axis/label/gridline colors from the CSS vars
(`--fg`/`--muted`/`--border`, via `getComputedStyle`) **once at init**, so a
dark-mode toggle would otherwise leave charts on the old palette. The theme
toggle in `00_params.sql` dispatches `document`-level `CustomEvent('awr:theme')`
(siblings: `awr:window`, `awr:mode`); every chart-init registers a listener that
re-reads those vars and `setOption`-merges the color-bearing options. The
masthead chart wraps its whole build in a `paint()` re-run (it also theme-picks
hardcoded rgba band/area fills); the other sections (04/05/06×2/07/09/10/11/
14/15) append a small merge-only listener. **Section 11 registers the listener
*inside* its per-chart `forEach`** so each chart binds its own instance (a
single outer listener would capture only the last chart). New charts must add an
`awr:theme` listener or they'll ignore a live toggle. Wait-class series colors
are theme-independent (kept in parity with `js_wait_colors.plsql`), so only
axis/legend/fill colors need re-applying. Verify headlessly by stubbing
`getComputedStyle`/`echarts` and asserting every chart re-`setOption`s a
dark-palette color on the event.

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
snap, has begin=end, restarted mid-window (`startup_time` differs), the window
straddles a DBID change, or a resolved begin/end snap sits **more than 15 min
outside the requested window edge** (`skip_reason` `'no snapshot within 15 min
of window edge'`). `valid_windows` is the per-instance valid-only projection
consumed by data sections 02–08 (their `GROUP BY week_offset` sums only
surviving pairs). `windows_rollup` aggregates back to one row per `week_offset`
for display (sections 01, 09). Single-instance: no-op, byte-identical.

**`dur_sec` is the resolved snap-to-snap span, not `win_hours`.** Snaps are
resolved with only a one-sided ±5-min tolerance over a ±1-day bracket, so the
real delta span can exceed the nominal window; `valid_windows.dur_sec` therefore
uses `(end_snap.end_ts − begin_snap.end_ts)` (threaded via `begin_end_ts` /
`end_end_ts`), and the 15-min guard above rejects grids too far off to compare.
`dur_sec` is **per-instance** (each instance's snaps jitter independently), so
the per-sec consumers (00/02/07/08) sum the cross-instance delta and divide by
`MAX(dur_sec)` with `dur_sec` **out of the second-level GROUP BY** — grouping on
it would split a RAC week into partial rows. Single-instance is byte-identical
(one constant `dur_sec` → `MAX` is a no-op and the narrower GROUP BY is
equivalent).

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
`large`→`crit`, `moderate`→`warn`, `typical`→`ok`, `improved`→`imp`,
`noted`→`note`, `insufficient history`/`flat baseline`/`n/a`→`skip`;
`info` is the rank-chip / informational badge class (not a bucket). A
new bucket must update `policy_bucket` (`metric_policy.plsql`),
`07_summary.sql`, `08_overview.sql`, `16_day_profile.sql`,
`score_cells.plsql`, `_style.sql` and `demo/awrdemo/helpers.py`.

### Scoring rule (v1.5.0) — one rule, one function, one policy table
`sql/lib/metric_policy.plsql` is BOTH the human-editable per-metric policy
and the rule. `metric_policy(domain, name, class)` returns
`policy_rec(family, canonical, dir, min_pct, min_abs)` from a one-line-
per-name CASE table: every LOAD (SYSSTAT) and METRIC (SYSMETRIC) name,
per-event overrides then per-class lines for WAIT (`wpol(class, dir,
min_pct, min_share)`), defaults for `SQL` (06/18), `SEG`/`FILE` (14/15)
and a conservative fallback for unmapped names (own family, `ANY`, 10%,
no floor). `dir`: `UP` = a rise is a finding and a drop is `improved`;
`DOWN` = the reverse (CPU-time ratio); `ANY` = both directions are
findings (throughput, session count: a drop can be an outage); `INFO` =
never a finding, a material move is `noted`. `min_abs` is a floor in the
metric's OWN unit (LOAD = per-second rate of the raw counter; DB time /
DB CPU are centiseconds per second; METRIC = the SYSMETRIC unit; WAIT =
share 0..1 of the Current total). `policy_bucket(domain, name, class,
cur, mu, sd, n, share, demote)` is the rule: z = (cur − μ) ÷
max(σ, 2% of |μ|); |z| > 3 large, > 2 moderate, but only when material
(|%Δ| ≥ min_pct AND value ≥ min_abs / share ≥ min_share), else `typical`
(callers badge it "immaterial"); then the direction: `noted` for INFO,
`improved` for a move in the good direction; `demote` turns large into
moderate (04/05's table-wide shift). Every consumer calls it: 00 verdict,
07 (PL/SQL pass 1 -- the SQL CTEs only compute z / pct / share now), 08
hero cards, 16 (re-buckets every `day_profile_cte` cell), 17 `big()`,
and `score_cells.plsql`'s `score_bucket` / `score_cells(cur, mu, sd, n,
share, domain, name, class, demote)` for 04/05/18. **Include order:**
`metric_policy.plsql` must precede `score_cells.plsql` (lint check 13),
and a `policy_rec` variable must be declared AFTER the include. lint check
12 verifies every template LOAD/METRIC name has a policy line.
`day_profile_cte.sql`'s own CASE still carries the plain 07-style rule
without direction but no consumer reads it any more (16 and fleet 06 both
re-bucket per cell); the fleet findings band, row, headline cards and
day-profile band (`sql/fleet/04`, `01`, `03`, `06`) call `policy_bucket()`. `improved` / `noted` are
never highlighted: class `imp` / `note` (outlined badges, no row tint),
never a movers lead or member, not in the verdict count / all-movers
list / rail pills / J-K jumps; the verdict and 07's heading say "N
improved" in muted text. A non-canonical twin is scored and rendered
(`tr.twin`, muted) but never counted. `demo/awrdemo/helpers.py` PARSES
`metric_policy.plsql` (regex over the `WHEN 'name' THEN RETURN pol(...)`
lines), so keep that one-line shape when editing.

### Findings are recomputed, not shared
Sections 07 and 08 each recompute their own z-scores. The LOAD/METRIC/WAIT target
lists are single-sourced per template and `@@`-included by 02/03, 04/05, and 07.
Inside 07, the unified recompute is `BULK COLLECT`-ed once into a record
collection tagged via `ROW_NUMBER()`; the "Biggest movers" table and detail
loops both walk that one collection — don't reintroduce a second recompute
cursor just for a different ORDER BY.

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

### Semicolon-in-comment gotcha (top-level SQL statements only)
A `;` inside an inline `--` comment **terminates the statement early** when it
sits inside a bare SQL statement (SELECT/INSERT/…), because SQL\*Plus scans for
`;` and does not exempt `--` comment text. It cut the fleet extract's resolving
`SELECT` short at a comment ending `…awr_trend.sql;` → the buffer sent to Oracle
ended on a trailing comma → **ORA-00936 "missing expression"**, aborting the run
(and, with `TERMOUT OFF` set before the SELECT, printing *nothing* — an empty
`.log` with a nonzero rc; `168 = 936 mod 256`). The same `;` is **harmless
inside a PL/SQL block** (anonymous blocks terminate on a `/`, not `;`), which is
why the section emitters can carry `;`-terminated comments but a top-level
resolving SELECT (in `awr_fleet_extract.sql` / `awr_trend.sql`) must not. No
lint check: grep can't tell SQL-statement context from PL/SQL-block context, so
a blanket rule would false-positive on ~15 legitimate in-block comments. Rule of
thumb: never end an inline comment with `;` inside a `SELECT … FROM …;`.

### Fleet report (`run_awr_fleet.sh` + `sql/fleet/`, `awr_fleet_extract.sql`)
A separate multi-DB triage tool, **orthogonal to the single-DB report**. The
cardinal rule: **never touch a single-DB file to add a fleet feature** —
`awr_trend.sql`, `run_awr_trend.sh`, the numbered `sql/NN_*.sql`, and shared
`sql/lib/` files stay byte-identical; all fleet code lives in `run_awr_fleet.sh`,
`awr_fleet_extract.sql`, `sql/fleet/*`, and `sql/lib/templates/fleet/*` (plus
additive-only edits to `lint.sh`/`.gitignore`). `awr_fleet_extract.sql` reuses
shared `sql/lib/` fragments via `@@` and has its OWN local template whitelist
(a deliberate copy of `awr_trend.sql`'s CASE, so that file isn't touched).

**v0.2.0 is the "ops console" redesign** (design B): one dense
`<table class="fleet">` (opened/closed by the assembler), a collapsed summary
`tr.dbrow` + a hidden `tr.detailrow` per DB, all rows collapsed by default and
toggled by a delegated click in the chrome JS. The masthead (bash-emitted)
carries stat badges, a wait-class legend, a timeline-marker legend, and an
in-page theme toggle. Sections renumbered: `00_fleet_chrome` (chrome + fleet
CSS + `js_fleet_charts.plsql` renderer), `01_row` (dbrow + opens the detail
scaffold + ASH timeline band), `02_ash` (`window.FLEET_ASH` payload),
`03_headline` (metric mini-cards in a self-contained `.metrics-band`),
`04_findings`, `05_topsql`, `06_day_profile` (optional Day profile band, see
that convention above; `FLEET_PROFILE_DAYS`), `06b_sqlmon` (always-on SQL
Monitor band, informational `FLEET-COUNTS sqlmon ...`, see that convention
above), `07_close` (drill + closes scaffold + sentinel).
The detail panel is a **single-column stack of full-width bands** (ASH
timeline → 6-across metrics strip → findings → Top SQL → drill; `.metrics`
goes 6-up ≥1100px, 3-up below, 2-up ≤560px). Keep `.detail-grid` at
`grid-template-columns:1fr`: a two-column layout leaves the columns' heights
wildly unbalanced (dead space under the short metrics column, Top-SQL text
cramped).

- **Fragment/sentinel/FLEET-COUNTS contract (v2)** — each per-DB extract spools
  two files into `reports/fleet_work_<run_id>/`: `<alias>.chrome.html` (page
  head/CSS/JS) and `<alias>.frag.html` — now **two table rows** (`tr.dbrow` +
  `tr.detailrow`), not a `<section class="db-card">`; the assembler wraps every
  frag in the `<table>` it emits. The frag's **last** line is still the sentinel
  `<!-- AWR-DB: <alias> OK -->` (a frag lacking it ⇒ **truncated spool → error
  row**). Two machine-readable comments per frag still drive scoring, **byte-
  exact**: `<!-- FLEET-COUNTS findings crit=X warn=Y suppressed=Z -->` (04) and
  `<!-- FLEET-COUNTS topsql n=N pts=P -->` (05). The wrapper classifies each
  alias (rc≠0 OR frag missing OR sentinel absent ⇒ error row with masked connect
  + last-15 log lines + any ORA-/TNS- code as the worst-finding cell), scores OK
  ones `10*crit + 3*warn + min(25,pts)`, and emits error rows first (conf order)
  then OK rows score-DESC (ties = conf order). Exit `0`=≥1 OK, `3`=all failed,
  `2`=bad config. `01_row.sql` additionally emits one `<!-- FLEET-WINDOW
  off=K|dow=Dy|begin=…|end=…|valid=Y|N|reason=… -->` comment per compared
  window (a per-window sibling of FLEET-COUNTS); the assembler parses these
  into the masthead's "Compared windows" strip — the canonical window list
  is taken from the first OK frag that has any, and per-offset validity is
  tallied across every OK frag (flagging a per-DB `target_end` snap-to-grid
  mismatch when begin/end differ). Missing lines are tolerated, not an
  error — an older workdir re-assembled with `--assemble` predates the
  feature and simply renders no strip. The `part` (valid on X/Y DBs) and
  snap-mismatch-note states need a real multi-DB fleet (all dbmint aliases hit
  one instance, so their windows never diverge).
- **Row placeholder injection** — the summary row can't know its own score/sev
  (Top-SQL pts are computed later in the same frag, section 05), so `01_row.sql`
  emits placeholders `__FLEET_SCORE__` / `__FLEET_SEV__` (crit|warn|ok) /
  `__FLEET_CRIT__` / `__FLEET_WARN__` / `__FLEET_CPILL__` / `__FLEET_WPILL__`
  (c|z, w|z) that the assembler substitutes via `sed` at assembly time, after it
  has parsed FLEET-COUNTS and computed the score — single-sourcing the row pills
  and the sort order. Placeholders carry no tilde/ampersand; the assembler greps
  the finished report for any surviving `__FLEET_` and warns (that's a bug).
  Worst-finding / AAS / DB-time sparkline are recomputed in `01_row.sql` (same
  "findings are recomputed, not shared" convention).
- **ASH section (`02_ash.sql`)** — covers the FULL report span (from the start
  of the earliest compared window to target_end: span_hours = weeks_back ×
  step_hours + win_hours) with ADAPTIVE buckets: bucket_hours =
  GREATEST(span/168, 0.25) — at most 168 buckets, 15-min floor — from
  `DBA_HIST_ACTIVE_SESS_HISTORY` (`dbid IN (~dbid_list)`, all instances, ON-CPU
  → 'CPU', Idle excluded, AAS = samples/(360 × bucket_hours)), emitted once per
  DB as a `window.FLEET_ASH[<alias>]={t0,bh,classes,vals}` JS payload
  (NLS-pinned numbers; `bh` = real bucket hours, consumed by the renderer for
  marker positioning and x-label cadence — HH:MM labels for spans ≤48h, MM-DD
  HH:MM beyond). The renderer draws it into `data-ash-of` divs — ribbon mode in
  the dbrow, timeline mode in the detailrow. The timeline renders at its
  container's real width (lazily on first row-expand, since the hidden
  detailrow measures 0; a debounced resize listener re-renders on width
  change); the page body has no max-width cap and `.console` scrolls
  horizontally below `table.fleet`'s 880px min-width. **Do NOT reuse `sql/09_ash_timeline.sql`
  (ECharts).** The renderer's wait-class palette is copied from
  `sql/lib/js_wait_colors.plsql` (and the bash masthead legend) — keep all three
  in **lockstep**.
- **Per-event ASH timeline (second detail band)** — the SAME single ASH scan
  in `02_ash.sql` additionally groups by event (ON-CPU → 'CPU') and emits a
  second payload `window.FLEET_ASH_EV[<alias>]` with the identical
  `{t0,bh,classes,vals}` shape: the top 14 events by total samples (tie-break
  name asc; CPU ranks like any series), biggest-total first = bottom of the
  stack, every remaining event rolled into a synthetic `"Other events"` series
  emitted LAST (omitted entirely when ≤14 distinct events). The class sums in
  `FLEET_ASH` are unchanged (event rows re-aggregate to the same totals).
  `01_row.sql` emits a second `.detail-block.timeline-box` band ("ASH by wait
  event") whose chart div carries `data-ash-src="ev"` plus a sibling
  `<div class="ev-legend">`; the renderer picks the payload by that attribute,
  preserves payload order (no WCO reorder), colors via `evColors()` (CPU = the
  WC green, "Other events" = fixed grey `#9AA3AD`, everything else cycles the
  15-hex `EVP` categorical palette counting only non-special series) and fills
  the legend with one chip per series in stack order (`fillEvLegend`, names
  through `esc()`). `buildStack` grew `opts.keepOrder`/`opts.colors`; with
  both absent its behavior is bit-identical to before, so class charts and
  ribbons are untouched. Unexercised: a DB with >14 distinct ASH events (the
  "Other events" rollup and full palette rotation).
- **Timeline markers (fleet-wide, wrapper-owned)** — `run_awr_fleet.sh` accepts
  env `MARKERS` (inline `WHEN|LABEL;;…`, same format as the single-DB var) and
  `MARKER_FILE` (a file of `WHEN|LABEL` lines; precedence `MARKER_FILE` >
  `MARKERS`). Bash parses/validates (`WHEN`='YYYY-MM-DD HH:MM'; strips reserved
  `< > & ' " ~ \` from LABEL), persists them to the workdir, emits
  `window.FLEET_MARKERS` + the masthead legend; the renderer positions them by
  timestamp inside each DB's 24h ASH span (markers outside the span drop from the
  chart but stay in the legend). **The extract SQL never sees markers.**
- **Chrome-per-extract rationale** — every DB spools its own chrome copy (pure
  `DBMS_OUTPUT`, so it's race-free under `FLEET_PAR>1`); the assembler keeps only
  the first successful one and discards the rest.
- **No ECharts, ever** — inline-SVG only (CDN-free), so the report is offline-
  complete by construction. Theme follows OS/localStorage **and** an in-page
  toggle (`#themeToggle`, flips `body.dark`, persists localStorage `"awr-theme"`
  — same key the early-theme bootstrap and single-DB report use). `inst_num` is
  pinned to `0`.
- **Credential masking** — `mask_conn` turns `user/pw@svc` into `user/***@svc`
  for all display; the password is never written to the workdir or report.
  `/`-prefixed (wallet/OS-auth) connects pass through untouched.
- **Unexercised:** a real multi-DB / RAC / migrated-PDB fleet (dbmint is
  single-DBID, and all three cdb aliases hit the same instance).
- **Per-run output folder (v0.4.0)** — every run's artifacts land under ONE
  folder, `reports/awr_fleet_<REPORT_TS>_run<RUN_ID>/`, holding the assembled
  console report as `index.html` plus one `detail_<alias>.html` per detail-
  flagged DB — replacing the old flat siblings
  `reports/awr_fleet_<ts>_run<id>.html` +
  `reports/awr_fleet_detail_<alias>_run<id>.html`. `REPORT_TS` (computed once
  alongside `RUN_ID`, before the fan-out) is persisted in the workdir's
  `params.env` so `--assemble` on a saved workdir reconstructs the identical
  folder name standalone; a workdir from before this feature (no `REPORT_TS`
  line) falls back to a freshly-computed timestamp — the report it
  re-assembles was necessarily flat anyway, since it predates the shared
  folder. `run_one_detail` writes straight into the folder via the `RUN_DIR`
  global (set once, before the fan-out, alongside `WORK`); the assembler
  (`do_assemble`) derives the SAME path independently — as local `run_dir`,
  exposed to `detail_state`/`detail_bits` via the `RUN_DIR_ASM` global —
  since it may run standalone via `--assemble`, long after the live run's
  `RUN_DIR` is gone. Because `index.html` and every `detail_<alias>.html` are
  siblings, the chip/drill-panel href is a **bare relative name**,
  `detail_<alias>.html` — no `reports/` prefix, no run id in the href — which
  is the whole point: the folder is relocatable (archive it, rsync it, serve
  it from anywhere) without rewriting a single link. `lint.sh` check 11
  guards against the old flat naming or a `reports/`-prefixed href
  reappearing. The extract's own `fleet_work_<RUN_ID>/` workdir is unrelated
  and unaffected — it is still deleted on a clean, all-OK run (unless
  `FLEET_KEEP_WORK=1` or a detail run needs debugging) while `RUN_DIR` (the
  report folder) is never deleted by the wrapper itself. The AWR Fleet Server
  (`server/`) was updated in lockstep — see that section below.
- **Per-DB detailed reports (v0.3.0)** — a fleet.conf line may carry an optional
  third field, `alias|connect|detail` (case-insensitive trailing token; anything
  else after the second `|` is treated as connect-string content, deliberately —
  see fleet.conf.example). A flagged DB also gets the FULL single-DB report
  (`awr_trend.sql`, template `comprehensive` by default) generated in the same
  run with the fleet's exact window/cadence params + fleet-wide markers
  (`DETAIL_MARKERS` re-joins the sanitized MK arrays — the fleet and single-DB
  inline marker formats are byte-identical), saved as `detail_<alias>.html`
  inside the run's shared output folder (see "Per-run output folder" above)
  and linked from that DB's row via a bare relative href. Env knobs:
  `FLEET_DETAIL` (all|none|''), `FLEET_DETAIL_TIMEOUT` (default 3600, 0 = no
  limit; rc=124 surfaces as a distinct "timed out" state with the last
  progress marker shown in the report and a stderr hint), `FLEET_DETAIL_TEMPLATE`,
  `FLEET_DETAIL_ECHARTS` — **offline by default** (v0.4.0): empty inlines
  `vendor/echarts.min.js` for a fully self-contained detailed report (falls
  back to the public CDN, with a warning, if that file is missing/unreadable);
  `cdn` (case-insensitive) is the escape hatch back to the pre-v0.4.0
  empty-value behavior (link the public CDN); an http(s) URL or any other
  local path is honored verbatim, same as the single-DB `echarts` var. The
  resolved effective value lives in the `DETAIL_ECHARTS_EFF` global
  (`resolve_detail_echarts_eff`, called once before the fan-out, right before
  the existing `resolve_detail_echarts_path` local-file-exists check, which
  now validates `DETAIL_ECHARTS_EFF` rather than the raw env var) and is what
  actually rides into the detail run's `echarts` DEFINE and the
  `inline_fleet_echarts` call — local path is spliced by a fleet-owned copy
  of `inline_echarts`. Mechanics that keep the cardinal no-single-DB-edits rule:
  `run_one_detail` runs sqlplus from an isolated `$WORK/detail_<alias>/` cwd
  holding **symlinks** to `awr_trend.sql` + `sql/` — the driver's cwd-relative
  self-named spool lands in the isolated `reports/`, is captured without knowing
  its name, then moved/renamed (no rename races under `FLEET_PAR`, no absolute
  paths in the heredoc = no tilde hazard). **Gotcha (bit us live): the detail
  log redirection must sit on the SUBSHELL, not the inner command** — `dlog` is
  workdir-relative and must resolve against the project root, not the isolated
  cwd after `cd "$ddir"`. The detail run only starts when the extract rc=0
  (else `.detail.rc` = the literal `skipped`); a detail failure never changes
  the exit code, but keeps the workdir. Frags emit `__FLEET_DETAIL_CHIP__`
  (01_row alias cell) and `__FLEET_DETAIL_LINE__` (07_close drill panel)
  unconditionally; the assembler substitutes '' / link / failure-note per alias
  (sed with `|` delimiter, `&`-free replacements) via the single-sourced
  `detail_state`/`detail_bits`/`detail_status_word` helpers, prints a
  `detail=ok|skipped|timeout|failed|-` column, and manifest.tsv carries the effective
  flag as a 3rd column (2-column workdirs read as N). The success chip carries
  inline `onclick="event.stopPropagation()"` so clicking it navigates instead
  of toggling the row (zero-touch on `js_fleet_charts.plsql`'s delegated
  handler).
- **Unexercised:** a real multi-DB fleet where detail runs take minutes
  (dbmint's full report is fast; the 3600-s default timeout is untested
  against a genuinely slow DB).
- **v0.7.0 scoring = the shared policy** — `04_findings.sql` (band +
  `FLEET-COUNTS findings`), `01_row.sql` (worst finding) and
  `03_headline.sql` (mini-cards) `@@`-include `sql/lib/metric_policy.plsql`
  (a read-only lib reuse, allowed by the cardinal rule) and call
  `policy_bucket()`, so the fleet applies the single-DB direction and
  materiality floors: `improved` / `noted` rows never count, never lead
  a row, and are folded into `suppressed=` (token format unchanged). 04
  BULK COLLECTs the recompute once and prints large then moderate by
  |z|; 01's worst finding is the first large / moderate row of the
  |z|-ordered cursor after bucketing (no `SELECT INTO` / NO_DATA_FOUND
  any more). The day-profile band (`06_day_profile.sql`) re-buckets every
  cell through `policy_bucket()` too (it ignores `dp_scored.change_bucket`),
  so `day_profile_cte.sql`'s own CASE is now consumed by nobody but kept as
  the CTE's documented contract.
- **v0.7.0 accessibility** — fleet-owned copies of the single-DB phase-4
  rules: `:focus-visible` ring and `prefers-reduced-motion` in
  `00_fleet_chrome.sql`; `tr.dbrow` carries `tabindex="0" role="button"
  aria-expanded` (01_row.sql) and `js_fleet_charts.plsql`'s `wireToggle`
  also toggles on Enter / Space while `setRowOpen` keeps `aria-expanded`
  in sync (still the single open/close code path).
- **v0.6.0 visual facelift** — same chrome hooks as the single-DB report
  where they translate (glyphs, `.chip` styling), plus fleet-only additions:
  a client-side toolbar (`#fleetToolbar`: filter, sort by score/name/AAS/
  errors-first, show all/crit/warn+, expand/collapse all — reuses the
  existing row-toggle path via `setRowOpen()`, so it never diverges from a
  manual row click); a `.score-bar` stacked crit/warn/sql-points segment bar
  per row via a new `__FLEET_SBAR__` placeholder (substituted at assembly
  time alongside the existing `__FLEET_SCORE__`/`__FLEET_SEV__` family, same
  "row can't know its own score yet" reason); a primary "Open full report
  ↗" chip in `.detail-topbar` plus a Copy button on the drill block
  (`#drill-<alias>`); direction glyphs in `01_row.sql`'s worst-finding cell,
  `03_headline.sql`, and `04_findings.sql` via a fleet-local
  `score_cells_dir()` (a fleet-owned copy, not a shared include — same
  cardinal rule as everything else fleet-side); the ASH band's unit label
  moved from the ribbon into its caption (B3). Sed-safety: `↗` and `·` are
  embedded as raw UTF-8, not HTML entities, so they survive the assembler's
  `sed`-based placeholder substitution unescaped.

### AWR Fleet Server (`server/`)

`server/` (added 2026-07-22) is a separate, optional pure-stdlib Python
web app that runs `run_awr_fleet.sh` on a schedule and on demand, serves
the generated reports, and keeps a run history with live log tails — see
`server/README.md` for details. It is **orchestration-only**: it shells
out to `run_awr_fleet.sh` (and, for per-DB detail regen, indirectly to
`run_awr_trend.sh` via that same wrapper) exactly as a human would from the
CLI, and the cardinal no-touch rule extends to it verbatim — nothing under
`server/` may edit `awr_trend.sql`, `run_awr_trend.sh`, `run_awr_fleet.sh`,
`awr_fleet_extract.sql`, or anything under `sql/`, `side/`, `vendor/`; all
server code and its own tests live only under `server/` (plus the additive
`.gitignore`/`README.md`/`CLAUDE.md` lines documenting it).

**Per-run output folder support (v0.4.0, in lockstep with the wrapper's
"Per-run output folder" note above)** — the server only ever *reads* what the
wrapper wrote, and every path it parses or serves accepts BOTH the per-run
folder shape (`reports/awr_fleet_<ts>_run<id>/index.html` +
`.../detail_<alias>.html`) and the old flat
`reports/awr_fleet_<ts>_run<id>.html` one — old records and history must keep
resolving:
- `server/app/records.py` — `_REPORT_RE` matches both forms in one regex.
  `detail_report_filename(alias, wrapper_run_id, report_path=None)` derives
  the detail path from the parsed console-report folder when given one and
  falls back to the flat naming otherwise (there is no other way for it to
  learn `report_ts`); its one caller, `runner.py`'s `_finalize_detail`,
  always passes `summary.get("report_path")`.
- `server/app/paths.py` — `safe_report_path` accepts at most one folder
  segment ahead of the filename, and only when it fullmatches
  `awr_fleet_<digits>_run<digits>` (`_RUN_FOLDER_RE`); the `/reports/…` route
  regex in `webapp.py` admits the same two-segment shape, and the
  containment-inside-`REPORTS_DIR` check runs on the resolved path either way.
- `server/app/views.py` — `_latest_detail_report`'s pre-server-history glob
  fallback checks both shapes and returns a path relative to `reports_dir`.
- `server/app/retention.py` — `_recorded_artifact_paths` treats the per-run
  folder as the deletable unit when a candidate resolves to a file directly
  inside one, so pruning a fleet record's `index.html` removes its detail
  reports too; a flat report file is deleted as itself. The extract's
  `fleet_work_<id>/` workdir is a different directory and is never affected.
- `server/tests/fake_bin/run_awr_fleet.sh` (the test double) emits the folder
  form so `runner.py`/`records.py` are exercised end-to-end.

### Demo report (`demo/`, docs-only)
`docs/examples/demo_busy_db.html` is synthetic: `python3 demo/gen_demo_report.py`
renders it from `demo/awrdemo/model.py` (one deterministic hourly model of a
busy 19c DB over 3 months with marked releases). `demo/awrdemo/chrome.py`
lifts the CSS/JS literally from `sql/_style.sql` and `sql/lib/js_*.plsql`;
each `demo/awrdemo/sections/sNN_*.py` is a hand-ported twin of `sql/NN_*.sql`
(contract: `demo/PORTING.md`). **When a section's markup/JS changes, re-port
its twin and regenerate**; `node demo/verify_report.js <html> [shots/]` is the
headless smoke test (0 console errors, chart count, toggles, screenshots).
The "No Python" rule applies to the toolkit, not to this docs tooling --
nothing under `sql/`, `awr_trend.sql` or the wrappers may depend on `demo/`.
`docs/gen_policy_doc.py` (same rule) renders `docs/metric_policy.html`, the
human-readable reference of every metric's direction / floors / "fires
when" from `sql/lib/metric_policy.plsql` (it imports the demo's policy
parser); **regenerate it whenever the policy file changes**, together with
the demo.

## Verification & testing

- **`./lint.sh` first** (also runs in CI): grep-based checks that encode the
  footguns below — bad `@@` include paths, flat template-target includes,
  stray `~word` substitutions (the tilde gotcha), `dbid = ~dbid` equality,
  leading-underscore identifiers, literal-7 cadence, missing `SET DEFINE '~'`,
  incomplete template dirs, GNU-only tool flags in the bash wrappers
  (`grep -o`, `sed -E`, `find -maxdepth`/`-print0`, unguarded `date -d` —
  they break on AIX/Solaris DB hosts and GNU-coreutils dbmint never catches
  it; twice bitten 2026-07-22). No DB needed; add a check when a new gotcha
  bites.
- **Test DB: dbmint** (Oracle 19c CDB1, `connect / as sysdba`). The host name
  fronts two Data Guard boxes on different SSH ports — use **`ssh -p 2200
  oracle@dbmint`** (`cdb1` PRIMARY, read-write; every report run needs an open
  DB). Port 2201 is the mounted physical standby: sqlplus exits 195 with empty
  logs on every section there, and the standby must not be opened to "fix"
  it. Single-DBID, idle, sparse history.
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
    oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'
  sed -E 's/run [0-9]{17}/run RUNID/g;
          s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{2}:[0-9]{2}/TIMESTAMP/g' \
    "$1" | md5
  ```
- **Coverage so far (dbmint = single-DBID, 19.27, idle):** single-DBID
  byte-identity of the window-validity / SYSMETRIC / cross-DBID / snap-to-grid
  refactors; sections 13/14/15 and every 06 dimension run clean; the
  the (since removed) "Application only" and Essential toggles, the workbench rail/scrollspy,
  `awr:theme` re-styling of every ECharts instance, the LISTAGG positional-CSV
  fix, the F1–F16 review batch (CHANGELOG 1.2.0), the restart-skip path
  (windows straddling a restart are skipped, verdict falls to "baseline too
  short", ASH 09 grey-shades them), `template=simple` cross-section z-score
  agreement, and the fleet report end-to-end (truncation, all-quiet, timeout,
  `FLEET_PAR`, offline, credential masking, single-DB regression).
- **Lessons those runs left behind (still apply):**
  - Sections 06/11 are non-deterministic run-to-run on idle dbmint (Top-SQL
    rank ties with no unique tiebreaker) — exclude them when byte-diffing.
  - `C##%` common users on dbmint are genuine application schemas, so the
    conservative unknown-⇒-app rule in `is_oracle_schema.plsql` is load-bearing.
  - A JSON value that JS compares as a string must be emitted as a string: a
    bare `0`/`1` `valid_flag` (F15) silently disabled all skip-shading because
    `0 !== "0"`. Headless DOM stubs miss this class of bug — chart/JS changes
    need a live-browser pass too.
- **Still unexercised (environment-limited):** a busy DB (real segment/file
  I/O volume, app-set module/action, >14 distinct ASH events for the fleet
  "Other events" rollup); RAC per-instance `dur_sec`; a migrated PDB
  (multi-DBID); a genuinely slow DB against the 3600-s detail timeout; the
  "no snapshot within 15 min of edge" skip reason (restart wins the CASE on
  dbmint); a series name containing `\`; the no-AWR-history-at-all branch of
  the `target_end` snap; the fleet "Compared windows" `part` and
  snap-mismatch states (all dbmint aliases hit one instance).
- **v1.5.0 UI/UX pass (2026-09-21) was built and verified WITHOUT a
  database:** every phase was exercised on the synthetic demo
  (`python3 demo/gen_demo_report.py` + `node demo/verify_report.js`, 0
  console errors, 45 charts, all toggles) plus Playwright checks for
  horizontal overflow at 1440/390 px, cross-link targets, hash view-state
  restore, keyboard tabs/sort and the tap-to-pin tooltip; the server
  suite (137 tests) passes. The PL/SQL edits (new includes
  `metric_policy.plsql` with its `policy_rec` / `policy_bucket`,
  `anchor_id.plsql`, the new `score_cells` signature, the 04/05
  Current-total scalar query, 07's PL/SQL pass, 16's per-cell re-bucket
  and day-wide rollup, 17's `big()`, 18's tail rule, the visual include
  order in `awr_trend.sql`, and the three inline `data-normal` scripts)
  have **not yet run against dbmint** -- first thing to do next session:
  the pinned window + `AUTO` run, all three templates, `profile_days=7`,
  `sqlmon_detail=3`, and re-read every `AWR-SECTION` pair (see
  `design/UI_UX_IMPROVEMENT_PLAN.md`, "Verification checklist").
- **Visual facelift (1.4.0 / fleet 0.6.0) verified on dbmint (2026-09-05):**
  single-DB hourly window (`target_end='2026-09-04 12:00'` win=1h
  weeks_back=4) and a separate `AUTO`-weekly-cadence run — the movers table,
  narrative block, triage toggle, tab groups, sortable Top SQL pool, row
  filter, click-to-sort, copy buttons, CSV/MD toolbars, expanders, and the
  ≤980px sticky-bar/hamburger layout all render clean, 0 ORA-; a fleet run
  with `FLEET_DETAIL=all` exercised the toolbar, `.score-bar`, and the
  "Open full report ↗" chip end to end. Byte-identity was **not** checked
  (feature release — markup/CSS/JS changed throughout by design).

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
- Don't edit any single-DB file (`awr_trend.sql`, `run_awr_trend.sh`, numbered
  `sql/NN_*.sql`, shared `sql/lib/*`) to add a fleet feature — fleet code lives
  only in `run_awr_fleet.sh`, `awr_fleet_extract.sql`, `sql/fleet/*`, and
  `sql/lib/templates/fleet/*`.
- Don't end an inline `--` comment with `;` inside a top-level SQL statement
  (it terminates the SELECT → ORA-00936; harmless only inside PL/SQL blocks).
- Don't add ECharts (or any external JS/CSS) to the fleet report — it is
  inline-SVG-sparkline-only and offline-complete by design.
