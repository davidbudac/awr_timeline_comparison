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
hiding chart divs (tables still show every number) with an amber banner. Every
v1.6.0 chart (band glyph, micro strips, window component, Timeline grid,
Activity charts by wait class / event, guide examples) is inline SVG/CSS and the client JS ships
inline, so those work offline. The
`echarts` var (below) redirects or inlines the library for air-gapped use.

## Entry points

- `run_awr_trend.sh user/pw@svc [target_end] [win_hours] [weeks_back] [top_n] [inst_num] [step] [step_unit] [template] [debug] [marker_file] [profile_days]`
  — wrapper; sets DEFINEs via heredoc then `@@awr_trend.sql`. `MARKERS=`,
  `ECHARTS=`, `ARCHIVE=` and `SQLMON=` ride as **env vars** (not positional, to keep arg order symmetric).
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
awr_trend.sql            -- driver: prologue (CSS + client libs), SPOOL, sections, epilogue
sql/
├── defaults.sql         -- canonical DEFINEs for the substitution vars
├── _style.sql           -- embedded CSS (emitted once; ALSO @@-included by the fleet chrome)
├── 00_params.sql        -- top bar, rail, view switch + chrome JS, AWR_WIN, verdict hero,
│                        --   the Activity charts' skeleton (#activity, every view; under the
│                        --   verdict in Summary), Timeline skeleton (#timeline / #tl)
├── 01_windows.sql       -- aligned windows, snap pairs, restart guard
├── 02_load_profile.sql  -- SYSSTAT deltas (per template)
├── 03_sysmetric.sql     -- SYSMETRIC_SUMMARY averages (per template)
├── 04_waits_fg.sql      -- foreground waits + wait-class rollup (per template)
├── 05_waits_bg.sql      -- background waits (BG_EVENT_SUMMARY, per template)
├── 06_top_sql.sql       -- Top-N SQL ranked 7 ways (Biggest change first) + per-dim bump chart (ranked, not scored)
│                        --   (break down by SQL_ID / schema / module / action)
├── 07_summary.sql       -- scored findings: Summary finding cards + per-domain tables,
│                        --   #s-changes slot, #s-normal, #s-lib heading
├── 08_overview.sql      -- Summary hero strip: DB time per window on the window component
├── 09_ash_timeline.sql  -- ONE ASH scan: hourly ECharts timeline + AWR_DATA.ashx / .ashe
│                        --   (Activity charts: by wait class / by wait event) + the Activity lane row
├── 10_db_time_summary.sql      -- stacked DB time across the full span (ECharts)
├── 11_top_sql_ash_breakdown.sql-- per-Top-N-SQL ASH cards (stacked by wait event)
├── 12_param_changes.sql -- init params differing across windows + config card
├── 13_utilization.sql   -- usage profile (template-INDEPENDENT, unscored)
├── 14_segment_io.sql    -- top segments by I/O (DBA_HIST_SEG_STAT; template-INDEP)
├── 15_file_io.sql       -- top files by I/O + IOStat-by-filetype (template-INDEP)
├── 16_day_profile.sql   -- Day profile: hour-of-day × N prior days (profile_days>0; template-INDEP)
├── 18_sqlmon.sql        -- SQL Monitor summaries + plan-change card (template-INDEP, always on)
├── 19_reference.sql     -- "Reading the charts" guide (#guide) + About/method notes (#about)
├── 17_narrative.sql     -- verdict pieces (likely source, pills, notes), relocated by JS; runs last
├── 20_load_response.sql -- viz: load vs response time scatter (SYSMETRIC, every interval of the span)
├── 21_volume_cost.sql   -- viz: executions vs time per execution, per statement / wait event
├── 22_wait_histogram.sql-- viz: wait latency histograms (DBA_HIST_EVENT_HISTOGRAM, optional grant)
├── 23_plan_flame.sql    -- viz: plan shape old vs new (ASH per plan line + DBA_HIST_SQL_PLAN, optional grant)
├── 24_blocking.sql      -- viz: blocked time per window + who-blocked-whom trees (ASH)
├── 25_onset.sql         -- viz: onset finder (span series vs seasonal normal + CUSUM); also Timeline
├── 26_window_similarity.sql -- viz: window similarity matrix + drop-a-window what-if
├── 27_instance_map.sql  -- viz: the findings on a schematic of the instance
├── 28_release_delta.sql -- viz: before / after a release marker (split computed in the page)
└── lib/                 -- @@-included fragments (see conventions)
    ├── windows_cte.sql       -- run_params → … → valid_windows CTE chain
    ├── day_profile_cte.sql   -- dp_params → … → dp_scored (shared by 16 + fleet 06)
    ├── nth_csv.plsql         -- INSTR-based CSV parser (keeps empty tokens)
    ├── is_oracle_schema.plsql-- 'Y'/'N' Oracle-maintained parsing-schema test (data-sys tag)
    ├── is_essential.plsql    -- curated LOAD/METRIC/WAIT name test (data-imp row tag; no CSS reads it since v1.5.0)
    ├── metric_policy.plsql   -- THE per-metric policy table (family / canonical / dir / floors)
    │                         --   + policy_bucket(), the one scoring rule (00/02/03/07/08/16/17 + score_cells)
    ├── score_cells.plsql     -- score_z / score_bucket / score_cells (04/05/18; score_cells =
    │                         --   band_cells(... score_bucket ...) -- include metric_policy first)
    ├── band_glyph.plsql      -- v1.6.0 band glyph: band_z/band_span/delta_span/range_txt/
    │                         --   band_head/band_cells + lib_ls (evidence-library row text)
    ├── anchor_id.plsql       -- v1.6.0 anchor_id(kind, name) / finding_anchor(domain, name) /
    │                         --   file_anchor(path) / param_anchor(name) / anchor_uniq (dedupe)
    ├── load_pairs_cte.sql    -- the template-driven LOAD read (00/02/07): SYSSTAT + time-model
    │                         --   DB time / DB CPU (SYSSTAT has no DB CPU row)
    ├── off_label.plsql       -- off_label(k): "-1w" / "-36h" offset label for any window count
    ├── finding_cards.plsql   -- v1.6.0 Summary vocabulary: card_group/label/id, metric_label/
    │                         --   unit/scale, fv*, time_split, move_txt, ent(), lead/card order
    ├── finding_hints.plsql   -- plan 033: hint_text / hint_sql rule tables + hint_fill / hint_block (07, 18);
    │                         --   one-line WHEN rows parsed by helpers.py
    ├── wingrid.plsql         -- v1.6.0 window component markup (wg_*): ruler, flags, bars, dates
    │                         --   + wg_buf line buffer (many windows); include off_label first
    ├── timeline.plsql        -- v1.6.0 Timeline lane rows (tl_*): tl_open/tl_close, tl_bars, tl_gut
    ├── json_escape.plsql     -- escapes a string for a JSON literal on one PUT_LINE
    ├── put_clob_chunked.plsql-- emits a CLOB payload in PUT_LINE-sized chunks
    ├── fmt_num.plsql         -- T7: consistent value-cell number formatting (fmt_num/fmt_int)
    ├── js_wingrid.plsql      -- GENERATED (src/js_wingrid.js): window.AWR_WG, markers, pin, ent unwrap
    ├── js_timeline.plsql     -- GENERATED (src/js_timeline.js): window.AWR_TL, lanes, the two
    │                         --   Activity charts (one chart factory, linked zoom / crosshair / pin)
    ├── js_microstrip.plsql   -- GENERATED (src/js_microstrip.js): data-spark → 13-bar micro strips
    ├── src/*.js              -- readable sources of the generated scripts (tools/js2plsql.sh)
    ├── src/css_design.css    -- readable source of css_design.plsql (the quiet / dashboard stylesheet)
    ├── no_design.sql         -- empty stub: design_head / design_tail for design=classic
    ├── design_head.sql       -- quiet / dashboard <head>: css_fonts.plsql + css_design.plsql
    ├── design_tail.sql       -- quiet / dashboard script: window.AWR_DESIGN + js_design.plsql
    ├── css_fonts.plsql       -- GENERATED (tools/fonts2plsql.sh, vendor/fonts/): Geist @font-face
    ├── css_design.plsql      -- GENERATED (src/css_design.css): the design stylesheet
    ├── js_design.plsql       -- GENERATED (src/js_design.js): the design's client half
    ├── js_sparkline.plsql    -- inline-SVG line sparklines -- FLEET-ONLY since v1.6.0
    ├── js_wait_colors.plsql  -- shared wait_class palette
    ├── js_markers.plsql      -- inits AWR_MARKERS + AWR_markLine()
    ├── marker.sql / markers_inline.sql / no_markers.sql -- marker emitters
    ├── no_sqlmon.sql         -- stub @@-included instead of 18 when sqlmon=N
    ├── viz_head.sql          -- <head>: the stylesheets of sections 20-28 (css_<base>.plsql)
    ├── css_<base>.plsql / js_<base>.plsql -- GENERATED (src/css_<base>.css, src/js_<base>.js): one pair
    │                         --   per visualization section (loadresp, volcost, waithist, planflame,
    │                         --   blocking, onset, winsim, instmap, reldelta)
    ├── loadresp_cte.sql / onset_cte.sql -- private CTEs of sections 20 / 25
    ├── debug_log.sql         -- per-section progress markers (no spool pollution)
    └── templates/<name>/     -- comprehensive (default) / simple / dev (+ fleet/, fleet-owned)
        ├── sysstat_load_targets.sql
        ├── sysmetric_targets.sql   -- names + is_additive flag
        └── wait_event_targets.sql  -- single '*' row = "no filter" sentinel
tools/js2plsql.sh                   -- dev-time generator for the js_* / css_design .plsql bodies (lint check 24)
tools/fonts2plsql.sh                -- dev-time generator for sql/lib/css_fonts.plsql (lint check 33)
tools/js_unit_tests.js              -- node unit tests of the client scripts' pure helpers (check.sh)
side/create_weekly_baselines.sql    -- optional baselines (the only writer)
run_awr_fleet.sh, awr_fleet_extract.sql, sql/fleet/ -- fleet report (see that section)
server/                             -- optional scheduler web app (see that section)
demo/                               -- docs-only synthetic demo report generator (Python; see demo/README.md)
design/                             -- mocks + handoffs (Mock D = the v1.6.0 spec)
reports/                            -- generated HTML
```
`dev_bucket.plsql` (the v1.4 `data-dev` heat tint) is **gone** since v1.6.0;
the band glyph replaced it.

## Substitution variables

Fifteen user-facing vars, all DEFINEs (defaults in `sql/defaults.sql`):
`target_end` (`'AUTO'`=prior full hour), `win_hours`, `weeks_back`, `top_n`,
`inst_num` (`0`=aggregate across RAC, else filter to that instance), `step` +
`step_unit` (`'h'`/`'d'`/`'w'`; default `1`+`'w'` = same hour-of-week N weeks
back), `template`, `debug`, `marker_file`, `profile_days` (`0`=off; the 12th
and last wrapper positional), `markers`, `echarts`, `sqlmon` (`'Y'`;
falsy = skip section 18 + 17's R6-R9, see SQL Monitor), `design`
(`'classic'`; `quiet` / `dashboard`, see Report designs).

The driver resolves many derived vars **once** up front via `COLUMN … NEW_VALUE`
and every section references them as `~name` (never re-resolves): `step_hours`
(= step × 1/24/168), period labels, `run_id`, `dbid`, `dbid_list`, `db_name`,
`host_name`, `report_path`, `template_dir`, `debug_termout`, `marker_include`,
etc. Sections use `~step_hours/24` as the cadence multiplier — **never the
literal `7`**.

### `target_end` snap-to-snapshot-grid
Both resolving SELECTs (`awr_trend.sql` and `awr_fleet_extract.sql` — a
deliberate lockstep copy, keep them textually parallel) resolve the requested
end via a `snp` inline view: if the last snapshot is at most 15 min before the
requested instant **and** a snapshot exists in `[request − 5 min, request + 15
min]` (the exact range `windows_cte` accepts for the end snapshot), the request
is kept **verbatim** (byte-identical for every request that already resolved
valid windows); otherwise it snaps back
to `TRUNC(last snapshot at or before request + 5 min tolerance, 'MI')`, so an
off-grid request (e.g. 16:30 against on-the-hour snaps, or a request inside a
snapshot gap) produces the last real window instead of an all-empty report. No
AWR history at all → request kept (empty report, as before). `dow_name` follows
the snapped value. A second DEFINE, `~target_end_requested`, carries the
pre-snap instant; `00_params.sql` (verdict hero `p.snapnote`) and `sql/fleet/07_close.sql`
(drill panel) emit a "Requested end … snapped to last snapshot …" note **only
when the two strings differ** — equal strings must emit nothing. The fleet
drill command uses `~target_end_resolved`, so it echoes the snapped instant and
reproduces the same window. A dense snap grid (≤15-min spacing) triggers the
snap only when the request falls 6–15 min after the last snapshot and the next
one has not been taken yet (an `AUTO` run just after the hour); the window then
ends on that last real snapshot instead of leaving the Current window empty.

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
  Handles PDBs with/without local AWR. Used for the report filename + top bar.
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
  `windows_cte.sql`. The top bar emits the primary `~dbid` and
  only appends "all DBIDs …" when the list has a comma — don't "simplify" that
  (the v1.6.0 masthead rewrite dropped it once; restored in the top bar).

### `data-sys="Y|N"` tags (informational)
Sections 06, 11 and 18 tag each top SQL / ASH card / SQL Monitor row with
`data-sys="Y|N"` from its parsing schema (06/11) or executing user (18)
via `@@sql/lib/is_oracle_schema.plsql` (a curated Oracle-maintained-schema
name test — **no DBA_USERS grant**, deliberately conservative: unknown ⇒
`'N'`). Since v1.5.0 no CSS reads the tag: the "Application only" filter
(`body.app-only`, `#app-filter-toggle`, the `awr:appfilter` event and the
bump chart's `sys` series filter) was removed at the user's request. The
attribute and the `sys` bool in 06's series JSON stay as neutral metadata.

### Views: Summary / Timeline / All sections (v1.6.0, Mock D)

The report has three views; they replaced v1.5.0's Normal / Full (and its
`awr-mode` / `!v=f` / `data-normal` / `.full-only` / `setMode` machinery,
lint check 18 bans the old hooks). Spec: `design/report_mock_d_hybrid.html`
+ `design/HANDOFF_report_redesign.md` ("Implemented in v1.6.0").

- **Body state:** exactly one of `body.vs` / `body.vt` / `body.va` plus
  `body[data-view="summary|timeline|all"]`, set before first paint by the
  early script in `00_params.sql` (right after the theme script): a
  `#view=summary|timeline|all` hash wins → else localStorage **`awr-view`**
  → else `summary`. A v1.5.0 link's `!v=f` opens `all` (read-only compat;
  the `!tab=…&w=…` hash state is still written). localStorage is written
  **only on an explicit click** of the top-bar switch (`.topbar .seg
  [data-v]`) — a shared link never overwrites the reader's choice.
- **Membership:** any element opts into views with `class="vw in-s in-t
  in-a"` (one `in-*` per view that shows it). CSS: `body.vs
  .vw:not(.in-s), body.vt .vw:not(.in-t), body.va .vw:not(.in-a)
  {display:none}`. No `vw` = every view (`#guide`, `#about`). Nested `.vw`
  are ANDed (a `vw in-a` table inside a `vw in-s in-a` section is All-only).
  Lint check 19: every `<section id=` in `sql/[0-9]*.sql` carries `class="vw `
  (guide / about exempt).
- **JS off:** no body class → every section stacked in DOM (driver) order,
  nothing hidden; `#timeline` shows only its header + `p.tl-nojs` note (the
  grid is built client-side); every number is still in the tables.
- **Assignment:** EVERY view = `section#activity` (00, `vw in-s in-t
  in-a`, emitted right after the verdict hero: first in Timeline / All
  sections, under the verdict in Summary, where it opens compact; see
  "Activity, whole span" below). Summary = verdict hero `#verdict` (00), hero strip
  `#overview` (08), finding cards (07 `div.cards.vw.in-s`), `#s-changes`
  (plan / config cards, hidden until filled), `#s-normal`, the evidence
  library heading `#s-lib` + the `section.lib` rows. Timeline = `#timeline`
  (00 skeleton + lanes) and 16 Day profile (`vw in-t in-a`). All = every
  numbered section in full (heading `#s-all`, 00), 07's per-domain tables,
  06's per-SQL pool. **"All sections" must keep showing every number** —
  view work is presentation only (verify_report's `allFull` check).
- **Chrome JS API** (00, DOMContentLoaded block):
  `setView(v, persist)` / `window.AWR_setView` — flips classes, syncs the
  switch, persists only when `persist`, clears a `#view=` hash on persist,
  re-runs `railViews()` / `viewNote()` / `libViews()`, `measure()`, resizes
  every ECharts instance + `fitTables`, and dispatches `document`
  **`awr:view`** `{detail:{view}}` (replaced `awr:mode`;
  `window.AWR_setMode(det)` is a compat shim). `inView(el, v)` / `viewOf(el)`
  walk every `.vw` ancestor. `reveal(el)` — `AWR_TL.reveal` first (folded
  Timeline lane / "+ Show N more"), opens a folded finding card
  (`window.AWR_fcOpen`, plan 025), opens a closed library row, clicks the
  tab of a hidden `.tabpanel`, opens the `[data-tail]` expander, every
  ancestor `<details>`, un-hides a filtered `tr`, `AWR_openSqlRow` for a 06
  `tr.sql-row`. `goTo(el, flash, persist)` / `window.AWR_goTo` — switch view,
  reveal, `scrollIntoView` (`center` for TR), `.flash` for 2.4 s. A delegated
  click on `a[href^="#"]`: `#view=x` → `setView`; else `goTo(target, a.ent ||
  a.xlink || TR, true)` + `history.replaceState` — **no `hashchange` fires on
  in-page clicks**, so anything that must react hooks goTo / reveal.
  `revealHash()` runs on load + `hashchange` (`#view=` → setView without
  persist; `#id[!state]` → goTo without persist).
- **Rail:** `railViews()` dims (`.vdim`) links whose target is hidden in the
  current view (a group `<b>` dims when all its links do) and adds
  `a.more-sections` "+ N more in All sections" (Summary only, before
  `#rail-ref`); `data-nodot` = no status dot / count pill. Groups: Overview
  (Activity, whole span → `#activity`, never dimmed), Summary
  (Verdict, Findings + one `a.sub` per card inserted by 07's inline script,
  What changed around it, Checked and normal, Evidence library), Timeline
  (the lane links, hidden when a lane is empty),
  Workload, SQL, Storage & config, Whole span, Reference (`#guide`,
  `#about`). The v1.4 row filter, status dots, count pills on the Findings
  link only (cards), J/K (cards in Summary) and the scrollspy are kept; a
  card sub-link's share of the DB-time rise is `data-shr` + CSS `::after`,
  never a child element (the rail text names the card in the dashboard).
  A link's state (hover, `.on`) shows through its
  background and font weight only — no `border-left` / inset
  `box-shadow` (it drew a crescent on the rounded pill; lint check 32,
  verify_report's `railMarker`).
- **Top bar** `div.topbar#topbar` (sticky, 00, before `<main>`): DB · host ·
  version · DBID, the Current window chip + "vs N prior windows, every …",
  the view switch and `#theme-toggle`. `measure()` sets `--navh` (html +
  body); sticky theads use `top:var(--navh)`; section h2s are not sticky.

### Summary view pieces (v1.6.0)

| Piece | Emitter | Notes |
|---|---|---|
| Verdict hero `section#verdict.vw.in-s.hero` | 00 | one rule-based h1 sentence (no free prose), `p#because-slot` "Likely source:" (17 fills), `ul#pills` (17 inserts before `li.pl-normal`), `ul#narrative-slot.hnotes` (17), `p.snapnote` (target_end snapped), `#att-slot` (07 fills: DB-time breakdown = DB CPU + each class's foreground wait time, the cards' impact; `.att-h` / `.att-bar` / `.att-lg`, parts coloured from `AWR_WAIT_COLORS` via `--c`; a hatched rest = the rise less the parts' NET sum (rises minus falls), drawn past 1 % of the rise, the bar's base GREATEST(rise + falls, rises); a note when the net passes the rise by more than 2 %; a share is `LEAST(100, ...)`, kept up to 100.5 %, both here and in `g_shr`) |
| Hero strip `section#overview` | 08 | DB time (AAS) per window on the window component, `#hero-dbt`; replaced the six v1.5 headline tiles |
| Triage list `#triage` | 07 | one `div.tri-row[data-card]` per card, in card order; impact cell filled by 07's inline script from the card's `data-impact` / `data-share` (plan 020); empty `span.tri-tags` (plan 027); `span.tri-spark[data-spark-dense]` (a trend at any window count, see Micro strips) |
| Finding cards `#findings div.cards` | 07 | one `article.fc` per card group (below); header band glyph, big value, window bars, ≤4 evidence rows, an optional hint `div.fc-hint[data-hint]` (plan 033, below), related-metrics fold, footer `a.jump[data-tl]` "Timeline →" |
| `section#s-changes[hidden]` | 07 (`#changes-slot`) | 18's plan cards then 12's config card move in and unhide it |
| `section#s-normal` | 07 | "Checked and normal" `.ngrid` (≤18 `.nr`), "Moved, too small to matter", "Improved"; body folded in `details.calm-fold` (summary line: the three counts; closed when there is a finding card); `reveal()` opens it for `#s-normal` (plan 032) |
| Evidence library `#s-lib` + `section.lib` | 07 heading, sections | see below |

**Folded cards (plan 025):** every card but the first one that is not DB
time (the verdict and its DB-time breakdown carry DB time; DB time alone
stays open) carries `data-fold="Y"`. 07's inline script after the cards
folds them (`.fold`, a `button.fc-tg` "Show card" / "Fold" in the
kicker; a click on a folded card that is not a link opens it) and fills
the triage list's impact cells; `window.AWR_fcOpen(card)` opens one and
the chrome's `reveal()` calls it, so every link, rail sub-link or hash
into a folded card (or anything inside it) opens it first. The kicker
carries `span.fc-sum` (Current value and normal range, shown only while
folded) and the empty `span.fc-tags` (plan 027). JS off: nothing folds,
the impact cells stay empty. `window.AWR_fcFold(card)` makes any card
foldable (`mkF`: the toggle + click-to-open, once, `c.__fc`) and folds it;
a card's `setF` also folds / unfolds the foldable card right after it
that explains it (`data-explains` = its id), which keeps its own toggle
(17's plan card under a folded I/O card, G4). Print (G4): 07's
`beforeprint` handler opens every `article.fc.fold` and a closed
`#s-normal details.calm-fold` (rendering the cards' grids synchronously:
no timer runs before the print layout), `afterprint` folds back exactly
those (and reopens a card that was open but got folded by the cascade
from the card it explains); `_style.sql`'s print block hides `.fc-tg` and, for JS off, shows the
closed fold's body through `::details-content`; the dashboard opens its
closed lead rows (`printRows()` in js_design) and prints every findings tab
(`css_design.css`, `@media print`). verify_report phase 4 `print`.

**Card hints (plan 033):** a finding card may carry, right after its
evidence list (`div.fc-b`), `div.fc-hint[data-hint="<rule>"]`: one hedged
"What this usually means." line and, when the rule has a query and the
Current window is valid, a copyable read-only "Next step" SELECT
(`.codewrap` + `.copy-btn[data-copy="#hq-<card id>"]` + `pre.sql`) filled
with the Current window's DBID and snapshot range, bounded like the
report (review follow-up R2): `#INST#` keeps to the Current window's
VALID instances when the report skipped one for it (RAC, `inst_num` 0, a
restart inside it: ` AND instance_number IN (1, 3)`; else ` = n` or
nothing, so single-instance output is unchanged), and the ASH query
(`ROW_LOCK`) is cut to the nominal window `[#T0#, #T1#)` (TIMESTAMP
literals) over snapshots begin .. end + 1, like 24. 07's `pick_hint(p_g)`
picks the rule from the rows it already scored (`f_up` = a large /
moderate row above its prior mean; `ev_up` = the same for one of the top 2
events per class in `v_evs`), and a rule fires only on what its sentence
claims (R2): `IO_SCANS` (any one of long-table scans, scattered read,
direct path read; the sentence says "or"), `IO_SINGLE`, `COMMIT_LAT`
(`commit_lat_up`: log file sync flagged up AND its time per commit, the
wait's AAS / user commits per second, at least 1.5x the prior windows'
ratio of the means), `NET_PAYLOAD`, `HARD_PARSE`, `DBTIME_CPU` (only
`time_split` `'c'`, the headline's "mostly CPU"; `'m'`, "CPU and wait
alike", gets no hint), `ROW_LOCK` (links `#blocking`, always emitted by
24). 18's plan card always carries `PLAN` (`DBMS_XPLAN.DISPLAY_AWR` of
both plan hashes; each plan's DBID and `con_id` come together from ONE
`DBA_HIST_SQL_PLAN` row over the report's DBIDs, `#DBIDS#`: the latest
id-0 TIMESTAMP, then the lowest dbid / con_dbid, section 23's rule -- a
pre-migration plan keeps its old DBID, one PDB of several its own
container; from a CDB root the 3-argument call returns no rows for a
statement captured in a PDB; needs the optional `DBA_HIST_SQL_PLAN` grant
when the reader runs it), between its evidence and its footer (23 adds
"Plan shape" to the footer's `span.evl`). verify_report reads the rules
that have a query from `hint_sql` and fails when one shows none (or the
reverse), on a `#...#` left, or on anything but read-only `SELECT ... ;`
statements. The
texts and queries are ONE table in `sql/lib/finding_hints.plsql`; every
`WHEN` line is one source line because `helpers.py` parses them
(`HINT_TEXT` / `HINT_SQL`), and no code line has a space before `#NL#`
(SQL*Plus trims trailing spaces). Hidden on a folded card
(`.fc.fold > .fc-hint`). To add a rule: one `WHEN` line in `hint_text`,
optionally one in `hint_sql`, one condition in 07's `pick_hint()` and in
the twin's `_pick_hint` (`s07_summary.py`), then regenerate the demo.

v1.5.0's `header.report` masthead, verdict banner, all-movers list, windows
strip + full-span DB-time chart, `.narr` "What changed" block, six
`.hero-card` tiles and 07's "Biggest movers" table are **gone** (CSS too);
their numbers live in 01/02/03/07/10.

**Card groups** (`finding_cards.plsql` `card_group`, twin
`helpers.card_group`; map from `metric_policy`'s `family`): IO Physical I/O
(`f-io`: READ_IO, SCANS, LOGICAL_IO, WAIT:User I/O) · DBTIME (`f-dbtime`:
DB_TIME, CPU_WAIT_RATIO, RESPONSE) · NET (`f-net`: WAIT:Network, NETWORK) ·
COMMIT (`f-commit`: WAIT:Commit, COMMIT) · PARSE (PARSE, HARD_PARSE,
CURSORS) · WRITE (WRITE_IO, REDO, WAIT:System I/O) · any other family is its
own card (`WAIT:<c>` → "<c> waits", `f-wait-<c>`). Lead (`lead_better`):
large before moderate → member of `card_primary`'s family → larger |z| →
shorter label. Order (`card_before_imp`, v1.7, plan 020): tier 1 = cards
whose time measure rose by at least 0.01 AAS (`card_tier`, owner decision
2026-11-20; `imp_on`: `ROUND(imp, 3) >= 0.01`, the token's rounding,
twin `helpers.imp_on` / `card_tier`), largest
impact first; tier 2 = DBTIME; tier 3 = the rest — a smaller rise, a
fall, no time measure — by `card_before` (large before moderate, then
max |z|); then a flagged DB time card moves to 2nd. The same floor
hides the chip and the share (owner decision 2026-11-21: no chip, no
`data-share`, no rail %, "under 0.01 AAS" in the triage list, nothing
in Copy summary or the dashboard's `.dimp`; verify_report's `impOrder`
encodes the tiers, `impChips` the chip rule). Impact
(`impact_group` + `time_added`): the card's time measure — DB time or DB
CPU (time model), Current minus prior mean ×`metric_scale` = AAS, or its
wait class's FOREGROUND wait time (owner decision 2026-11-20:
`time_waited_micro_fg` from the same `DBA_HIST_SYSTEM_EVENT` rows as the
class row, CTEs `wait_fg_rows` / `wait_fg` in BOTH 00 and 07, carried as
`fg_d` on the collected row) — so a mostly-background class (archiver,
log switch) no longer outranks the whole DB-time rise. Never scored: the
`Wait class: X` rows, their z / bucket and which cards exist stay all
sessions. 021's breakdown (its parts and "Fell:"), the triage list, the
rail shares and Copy summary all read the same impact;
`article.fc[data-impact]` (3-decimal token, '' = none) and
`[data-share]` (integer % of the DB-time rise, '' below the 0.01 AAS
floor, when DB time did not rise or the share passes 100) are a
contract for later Summary features; a chip `.fc-k .fc-imp` shows it
(only a rise of 0.01 AAS or more; a share that rounds to 0 reads "<1%"
on the chip, the rail, the triage list and Copy summary). A flagged DB CPU card is its own card
`CPU` (label "CPU"). Summary-only band glyphs (07's card header,
evidence and normal rows, 08's strip, 18's plan card) pass `p_zcap =>
10` (printed z stops at ">+10σ"; tables and Timeline gutters keep the
exact z). **00 (verdict) and 07 (cards) both
order cards — keep them in lockstep** (twin `helpers.card_order`). One
count: a finding is a card — the verdict pill (`li.pl-find`), the Summary
Findings header (`.meta.in-s`) and the rail's Findings pills (`cardCounts`
in 00's chrome) count cards; the All sections Findings header and every
section header count their own rows. Units (`metric_unit/scale`): DB time / DB CPU / CPU used → AAS
(×0.01), SQL Service Response Time → ms/call (×10), waits → AAS, bytes →
B/s auto-scaled; scoring always runs on the stored value. DB time card
evidence starts with DB CPU and the top 2 events of every flagged wait
class (one bounded `DBA_HIST_SYSTEM_EVENT` scan in 07, only when a class
is flagged); `js_timeline` turns the DB time card's bars into stacked
FOREGROUND ASH per window (`ashx.winfg`, `.r.ash` + `ul.fcleg`) when
`AWR_DATA.ashx` has data. The verdict and the card name where extra DB time
went (`time_split`) from the LOAD `DB time` / `DB CPU` rows (time model, see
the gotcha). The "Likely source" plan change (17) is 18's own test --
Current plan vs the prior modal plan -- picked by largest Current max
elapsed, not "more than one plan in the span" (review #6).

**Relocation pattern** (generalises v1.5's narrative pattern): a section
that fills a slot owned by an earlier section emits its block hidden and a
one-line inline `<script>` moves it while the page parses. Slots:
`#changes-slot` (07; 18 plan cards `f-plan-<sql_id>` first, then 12's
`#f-config`, as the driver runs 18 before 12), `#att-slot` (07, the
DB-time breakdown under the verdict), `#because-slot` / `#pills` /
`#narrative-slot` / verdict `.vx[data-vx="io"]` / I/O card evidence
`[data-ev-for]` (17, which runs last). These scripts run BEFORE any
DOMContentLoaded handler (ent unwrap, chrome), so they must not depend on
them. JS off → the block stays hidden (every fact is also in its section).
17 with nothing to say emits only its two `AWR-SECTION` markers.
17 also moves the plan-change card of the I/O card's top statement (by
Current physical reads) right after `#f-io` (`data-explains="f-io"`, a
`span.xpl` "explains Physical I/O ↑" chip in its `.fc-k`, the arrow in
`i.xu`; plan 026; when 025 folded the I/O card, 17 folds the plan card
too through `AWR_fcFold`, and it opens with the I/O card or on its own
toggle -- G4) and re-hides `#s-changes` when that empties it; anything
counting finding cards in the DOM must exclude `.chg` (plan-change /
configuration cards). R1's I/O card evidence: the top statement by
Current physical reads, any statement (row "SQL": blocks vs its mean over
the prior windows it ran in, gets per execution then and now, an
`ent()` "new plan A → B" link to `#f-plan-<id>` when its plan changed),
plus the newcomer (top-N by reads, in no prior top-N) as "New SQL" when
it is a different statement; the likely-source line and R1's note still
use the newcomer only. 17 picks A / B from SQLSTAT (prior most executed,
Current most blocks read), 18 from SQL Monitor (prior most frequent
capture, Current slowest), so they can differ: 18's card carries the
transition it shows (`data-ph0` / `data-ph1` = prior / Current plan
hash), 17's `data-explains-src` carries the one it cites (emitted only
when it cites one), and the relocation script moves the card, adds the
chip and keeps the link only when the two agree; otherwise the card stays
in `#changes-slot` and the link becomes `span.ent-x` (review follow-up
R2; verify_report `explainsPh` / `planLinkPh`).

**Plan-change card** (18, twin `s18._plan_card`): one per statement whose
Plan hash column fires (`plan_changed='Y'`) with a Current execution and
`rnk <= top_n`, at most 3; buffered in a RECORD table declared before the
includes. h3 = `ent(sql_id → sq-elapsed-<id>)` + "new plan since <date>" +
`<span data-mk-at="k" data-mk-pre=" after ">` (js_wingrid writes "after
Release 4.2 (Tue 8 Sep)"). Bars = the statement's elapsed seconds per VALID
window from ONE bounded `DBA_HIST_SQLSTAT` read (fallback: SQL Monitor max
elapsed, the unit word says so); plan step line = per window the most
frequent captured plan (field 6 of `detail_csv`), carried forward, Current
forced to the Plan hash column's plan. Evidence: per exec (ranked, plain Δ),
SQL Monitor max elapsed (scored band via `score_bucket`), CPU (plain Δ,
hollow dot, "; the rise is wait" when CPU rose ≤ 10% of the elapsed rise).
Footer `data-tl="tl-sm-<id>"`. 17's plan pill still links `#sm-<id>` (its
rule — >1 distinct plan incl. Current — is not the card's rule).

**Evidence library** (Summary only): a section with class `lib` (+ `in-s`)
renders as one collapsible row: chevron + `span.lt` title + one-line status
`span.ls` + `.meta` counts; click / Enter / Space on the h2 toggles
`.lopen` and shows the section in place (charts resized, `AWR_WG.refit`,
`fitTables`). Order `style="--os:N"` (CSS `order:calc(10 + var(--os))`):
Top SQL 1 (`lopen` in markup), SQL Monitor 2 (opens on an error / DOP
downgrade on a Current top-N statement), Foreground waits 3 (open), Day
profile 4, Segment I/O 5, File I/O 6, Load profile 7, System metrics 8,
Parameters 9, then the visualization sections 10-18 (20 Load vs response
time, 21, 22, 23, 24, 25, 26, 27, 28; see "Visualization sections").
All-only: 01, 05, 09, 10, 11, 13 ("+ 6 more in All sections"). Row text: `lib_ls(id, html)` (`band_glyph.plsql`, twin
`helpers.lib_ls`) emits `<script>if(window.AWR_ls)AWR_ls("id","html")</script>`;
`window.AWR_ls` is an early 00 script (before `<main>`); 16 inlines the same
script. A row with no `.ls` shows its `.h2sub` instead. Chrome V2
(`libSecs/libResize/libOpen/libViews`): `.lib-first/.lib-last` edges by
visual order; role / tabindex / aria-expanded only in Summary; All sections
ignores `.lopen`. `vhead` = heading-only section (`#s-lib`, `#s-all`).

### Timeline view (v1.6.0)

`section#timeline.vw.in-t` (00, after the verdict hero) holds
`div#tl.panel.gridwrap.wg.hov[data-wg]` (the window grid: sticky ruler,
`#tl-body` scrolls horizontally with a scroll-synced ruler, six empty lanes).
Sections fill the lanes; a lane without rows stays hidden (its rail link
too). Lanes (`div.lane#lane-<x>[data-kind]`, rows in `.lrows`):

| Lane | kind | Rows (emitter) | Row id |
|---|---|---|---|
| activity | ash | 09: one stacked `.r.ash` row | `tl-ash-timeline` |
| metrics | scored | 07: 11 headline metrics (`hl_rank`) + every other flagged **canonical** LOAD/METRIC row (twins stay in the tables) | `tl-fr-<l\|m>-<name>` |
| waits | scored | 07 flagged wait classes; 04 Table A's first 16 events (past 10 `.more`, "+ Show N more"), event rows in AAS per window (its seconds ÷ ITS real span, `MAX(dur_sec)` of `valid_windows`, as 07's class rows; `data-mu` / `data-sd` from the prior windows' AAS); `data-sev` and the gutter Δ / z / band stay Table A's (scored on seconds), so they match the dot and the linked row and can differ by a few % from the AAS bars when a span is off nominal | `tl-fr-w-wait-class-<c>`, `tl-we-<event>` |
| objects | ranked | 14 top 2 segments by physical reads; 15 top 1 datafile by MB read | `tl-sg-…`, `tl-fl-…` |
| sql | sql | 06 first 6 by elapsed (◆ plan flip on Current, ✚ first-seen window); 18 up to 3 SQL Monitor rows (plan change / DOP downgrade), `data-after` = the 06 row | `tl-sq-elapsed-<id>`, `tl-sm-<id>` |
| config | config | 12 every changed parameter (≤20) as step rows, cells `data-pv` | `tl-pa-<param>` |

**Row-id contract:** a Timeline row's id is `tl-` + the id of its All
sections detail row, and every row label is an `a.ent` to that detail row.
Finding / plan / config cards link `a.jump[data-tl="tl-<id>"]` —
js_wingrid intercepts the click (`AWR_goTo(el, true, true)`), else the plain
`#timeline` href is followed.

**SQL side — `sql/lib/timeline.plsql`** (twin `helpers.tl_*`; include order
lint 22: `fmt_num → band_glyph → anchor_id → finding_cards → wingrid →
timeline`): `tl_open(lane)` / `tl_close` wrap rows in `<template
class="tl-src" data-lane="lane-X">…</template><script>AWR_TL.take()</script>`
— **emit after `</table>`, never inside a `<tbody>`** (14/15/18 buffer rows in
a `TABLE OF VARCHAR2(32767)` and flush after the table; lint 23 checks each
`tl_open` has a `tl_close`). `tl_csv(csv, asc, div)` turns a section's
LISTAGG CSV into data-v (oldest first); `tl_nth / tl_val / tl_mu / tl_first`;
`tl_lab(nm, sub, title, wait_class)`; `tl_gut(cur, mu, sd, bucket, note,
twin)` (Δ + z + small band) / `tl_gutp` (ranked: plain Δ); `tl_bars(csv, mu,
sd, sev, lab, gut, id, cls, name, unit, glyph_off, glyph_html, after)` —
only the Current value is printed, JS fills priors from `data-v`.

**Client — `js_timeline.plsql`** (`window.AWR_TL`): `take()` moves template
content into its lane (`data-after` → under that row), `reveal(el)`;
DOMContentLoaded: `#tip` tooltip, wait swatches from `AWR_WAIT_COLORS`, lane
meta counts / folds / "+ Show N more", skipped windows struck
through in the ruler, prior values filled, the activity rows + DB time
card, the Activity charts, `AWR_WG.render(#tl)`. **Pin:** `AWR_WG.pin(o)` /
`pinned()` — `body[data-pw]`, `.pc` on `#tl [data-w=o]`, ruler buttons
`aria-pressed`, every gutter Δ re-based "vs <date>" (`data-orig` restores),
the stripe `.on` on both Activity charts; Esc, Current or the gutter's
"clear" unpin. A view switch KEEPS the pin (the Activity charts show it in
every view; before the charts moved to the top, leaving the Timeline
unpinned). Separate from the X2 `th[data-w]` highlight (`.hl` + `awr:window`).

**Row scale, filter and order (plan 031).** In `#tl` a bars row is scaled
to its prior windows (`AWR_WG.rowScale`): a Current value above 1.5 x the
tallest prior value / zone top is drawn as a full-height broken bar
(`i.b.brk`, tooltip "bar cut"); every other row, and every row outside
`#tl` (hero strip, cards, 24's strip), keeps the old scale. `#tl-tools`
above the grid (`js_timeline` `tools()`, never `tbl-tools` / `tool-btn`:
the design script moves those) holds "Rows: All / Flagged only"
(`#tl.flagonly` hides the non-large / non-moderate rows of the two
`data-kind="scored"` lanes, folded ones included; `.lane.nofl` shows its
`.r.nfl` note "No large or moderate row here") and "Order: Report order /
Biggest change first" (`AWR_WG.changeKey`: added AAS when every row of the
lane has `data-unit="AAS"`, else |z|; a row with no prior mean -- empty
`data-mu`, new in the Current window -- in an AAS lane ranks by Current
minus the mean of its VALID prior windows, a missing value there counting
0 for the sort only (owner decision 2026-11-20: a new event is often the
story of the hour); skipped windows stay unknown, no valid prior window or
a z lane sorts it last; wait-class rows `tl-fr-w-*` stay
above the events; the lane is unfolded while sorted, `data-ord` keeps the
report order). Defaults are today's behaviour; choices are saved on click
only (localStorage `awr-tl-rows`, `awr-tl-order`); `AWR_TL.reveal` switches
the filter off (unsaved) for a jump to a hidden row. Counts, pills and ids
never change. Unit-tested in `tools/js_unit_tests.js`, verify_report block
5d.

### Activity, whole span (`section#activity`, every view; under the verdict in Summary)

The bird's-eye ASH view (owner request, v1.6.0): `section#activity.vw.in-s
.in-t.in-a.ashtop` is emitted by 00 right after the verdict hero (plan
023): the first section in Timeline and All sections (the verdict is
Summary-only), the second in Summary and with JS off.
Skeleton (static, lifted verbatim by the demo twin): h2 "Activity, whole
span" + `.h2sub`, `p.ax-nojs` (hidden under `body.js-wg`), `div#ashx.ashx
[hidden]` › `.axh` (`#ax-range`, the stripe key `.axk`, `#ax-reset`),
`#ax-empty`, two charts `div.axch#ax-cls` / `#ax-ev` (each `.axct` = small
h3 + its own legend `.axlg`, then `.axp` › `svg.axsvg` + `.axbr` brush),
`p.axn2`. The chart ids are `ax-cls` / `ax-ev`; everything inside is
addressed by class (the old single-chart `#tl-ash` / `#ax-svg` / `#ax-lg`
/ `#ax-plot` ids are gone). **Compact in Summary** (plan 023): `SP.cmp` /
`#activity.ax-cmp` hide `#ax-ev` and `.axn2` under `body.vs`, the class
chart draws a 96-px plot (it is then the last chart shown, so `draw()`
gives it the date labels); `button#ax-more` (`.axr.axm`, unhidden only
with two charts) toggles it and stores `localStorage awr-ax` = `full` /
`compact` on a click only; off in the dashboard design
(`window.AWR_DESIGN === 'dashboard'`: its `.axseg` tabs show one chart
at a time); `css_design.css` re-shows `.axn2` inside the open "How to
read" popover; the demo twin lifts the skeleton from `<section
id="activity"` to the line ending `</div></section>`.

**Payloads** (09, the SAME `DBA_HIST_ACTIVE_SESS_HISTORY` scan as 09's
ECharts chart; it groups by bucket, class, **event**, `j_lo..j_hi` = every
compared window the sample falls in — overlapping windows each count it —
and foreground flag; no second ASH scan):
- `AWR_DATA.ashx = {t0, end, bh, wh, classes, vals, win, winfg, fine}` — by wait
  class. `bh` = `v_m × bucket_hours`, `v_m = GREATEST(1, CEIL(total_buckets
  / 10000))`: the fine grid of 09's ECharts chart (hourly, or the sub-hour
  cadence), as in v1.5.0 (owner request: "much more granular"), coarsened
  only past 10000 buckets (a year of hourly buckets, 52 weekly / 365 daily
  windows, stays hourly; payload under about 1.5 MB); the last bucket
  divided by its covered hours; 09 appends the values through `lob_add`
  (one WRITEAPPEND per 30 KB or so); classes in a fixed stacking order (CPU, User I/O, System
  I/O, Commit, Application, Concurrency, Network, Configuration, Scheduler,
  Cluster, Administrative, Queueing, unknown, Other); `vals` zeros, never
  gaps; `win` per class per window (oldest first) = samples ÷ 360 ÷
  win_hours, all sessions (Activity lane, stripe tooltips); `winfg` the
  same for `session_type = 'FOREGROUND'` only (the DB time card's bars: DB
  time is foreground time; the card keeps its DB time value as the Current
  label, review #8).
- `AWR_DATA.ashe = {t0, end, bh, wh, classes, ecls, vals, win, fine}` — the
  same shape by **wait event** (ON CPU = `CPU`, ranked like any event): the 14 events
  with the most samples over the span (ties: name ascending), biggest first
  = bottom of the stack, then `"Other events"` LAST = the class total less
  the top events per bucket / per window (integer samples, so exactly the
  rest; left out with ≤ 14 events). Names through `json_escape`. `ecls`
  (v1.6.1) = each series' wait class, parallel to `classes` (`"CPU"` for
  CPU, `null` for "Other events"; an event seen under two classes keeps the
  first by name), collected in the same scan loop (`v_ecls`): it links the
  two charts' highlight (a payload without it: no cross-chart highlight).
  Same semantics as the fleet's `FLEET_ASH_EV` (`sql/fleet/02_ash.sql`),
  which stays its own copy (no `ecls` there).
- `ashx.fine` / `ashe.fine = {bm, capped, segs, vals}` -- the **1-minute
  detail** (owner request), from the SAME scan: its GROUP BY also carries
  `mk` = the sample's minute since `t0` when the sample sits in a compared
  window within the fine reach, else NULL (so the rest of the grouping is
  unchanged). `bm` = 1 (bucket minutes); `segs` = `[[first minute, buckets],
  ...]` oldest first = the compared windows (skipped ones included),
  overlapping windows MERGED so a minute counts once (a time series,
  unlike `win`); `vals` per series (same series / order as the coarse
  payload, "Other events" = the minute's total less the top 14) = the
  INTEGER sample count of every minute of every segment in order (AAS =
  n / 6), a run of k >= 2 zero minutes written as `-k`; `capped` = 1 when
  the cap left windows out. Cap: 40000 minutes (`v_fcap`; 168 hourly =
  10140, 52 weekly 1 h = 3180) -- past it the Current plus the most
  recent windows whose union fits (`v_jmin` = first covered window step;
  one window longer than the cap keeps its last 40000 minutes, `v_mmin`).
  Emitted by `fine_head` / `fine_put` through `put_clob_chunked` (the segs
  too: 15-min windows make thousands). Cross-check: a window's minutes
  summed / 6 / 60 / win_hours = its `win` value (verify_report checks the
  Current window).
Numbers via `RTRIM(TO_CHAR(ROUND(v,3),'FM9999999990D999'),'.')`.

**Client** (`js_timeline`, section 6): ONE chart factory — `mkChart(root,
payload, colours, opt)` + `draw(c)` — two instances in `CH`, sharing `SP`
(bucket times, the zoom domain, windows, `#ax-range` / `#ax-reset`, the
decoded fine grid `SP.F`). Per chart: smooth stacked AREAS (a point per
bucket at its midpoint, straight lines; one fill `path.xa` per series,
painted top of the stack first, each from the axis to its cumulative
line, then a thin darker top edge `path.xe` per band; the data's first /
last bucket runs flat to its edge; `bRange` / `bucketAt` are O(1) on the
regular grid; zoomed out past one bucket per pixel there is one point per
pixel column at that column's busiest bucket, so spikes survive and a brush zoom shows every bucket; the tooltip reads the
exact bucket; ticks go down to 5 min, `bLab` names 15-min buckets), legend toggles restack / rescale, hover tooltip (time +
each shown series' AAS; a stripe's tooltip = that window's `win` values),
window stripes from `AWR_WIN` (`.cur` indigo / `.on` pinned amber / `.sk`
skipped grey; hit rects `.xwh[data-w][tabindex=0]`, click / Enter / Space
pin, Current unpins), release markers (flags in two tiers on the upper
chart, lines on both). Linked: a brush (≥ 5 px) on either sets the shared
domain and redraws both (the brush shows on both); Reset / double-click
(mousedown `e.detail >= 2`: a stripe click re-renders the SVG so
`dblclick` may never fire) reset both; the hover crosshair + bucket band
are drawn on both at the same x; `W.pin` redraws both. **Fine rule:** a
bucket is a ref (coarse `i >= 0`, 1-minute `-1 - j`; `rS` / `rE` / `rV`);
`fineOn(d0, d1)` = the view is `FMAX` (6 h) or narrower AND overlaps a
segment -> `refs()` merges the minutes inside the segments with the
coarse buckets that overlap no segment (a couple of buckets past each
edge so lines leave the plot), `refAt(t)` hovers the minute, `#ax-range`
says "1-min detail" (or "... in the compared windows, hourly
elsewhere"), and `spZoom`'s minimum drops from `SP.min` to `FMIN` (30
min) when the brushed range touches a segment. A wide window stripe
(> 24 px) is hit-tested on its cap only (`.xw.wd` fades its fill), so the
plot inside a zoomed window hovers / brushes minute by minute; a narrower
one on its whole height (a hit rect at least 12 px wide), so when the windows tile the
span (more than about 42 contiguous windows on a 1440-px page, e.g. 168
hourly ones) every x of the un-zoomed plot is a stripe: hover shows the
window's tooltip, a click pins it, and bucket hover, the soft highlight
and click-to-keep need a brush zoom first (by design; verify_report
zooms there). Fine data
is used only when EVERY chart decodes it (length = the segments'
minutes), else both stay coarse. One time axis: x
labels only on the lower chart (tick marks on both), ticks counted from
midnight of the Current window's day, `padL` / `padR` fixed so the plots
align. Heights ≈ 180–200 px each (`ph` 150). Colours: classes from
`AWR_WAIT_COLORS`; events `evColors()` — CPU = the wait-class CPU green,
"Other events" = `#9AA3AD`, the rest cycle `EVP` (15 Tableau-like hues, no
green). A click on a stripe in Summary / All sections pins too
(the grid follows when you open the Timeline). JS off: only the note;
payload without classes: `#ax-empty`, key / charts / hint hidden.

**Series highlight (v1.6.1, owner request):** state `HS` (sticky) / `HT`
(passing; wins while it lasts), each `{c: chart, k: series[, soft]}`;
`hlApply()` derives each chart's `c.hl = {set, strong, fade, note}` and
redraws only the charts whose state key changed (`c.hk`, also part of
draw's cache check). **Strong** (legend hover, legend keyboard focus when
`:focus-visible`, sticky) = re-based: the highlighted series stacked first
from zero, the y axis fitted to it (`mh`; the rest clipped by a second
clipPath), each pixel column keeping ITS busiest bucket; the other series
in one `g.xfd` group at opacity .12 (.07 when the fit cuts the stack) so
their overlap does not darken; the highlighted ones as `path.xa.xah` bands
(upper + lower line) with a `.xeh` edge; a `text.xhn` note ("... drawn
from zero, y axis fitted to it", "· Esc clears" when sticky). **Soft**
(the band under the pointer in the plot, `seriesAt()`) = in place, not
re-stacked (a re-base would slide the band away from the pointer and
flicker); off while one is sticky. Cross-chart via `c.peer` / `c.xmap`
(built from `ashe.ecls` in `spInit`): a class highlights its events in the
event chart (strong when the class is), an event its class in the class
chart, lightly (in place, the rest at .35). Sticky: a click on a band
(mouseup without a drag, not on a stripe; a click off the stack clears) or
Shift+click / Shift+Enter on a legend entry; the same again toggles it
off; the double-click reset undoes the first press's sticky (`SP.hsel`,
like `SP.sel` for the pin). **Esc: the first press clears the highlight
(`hlEsc`), the next one unpins the window.** A legend click still hides /
shows (a hidden series never highlights). Tooltip: `ashRows(..., hl)`
leads with the highlighted rows (`.thlb` / `.thl`, share of the total
`.tpc`; several add a "together" sum). Legend: `.axlg.hlon`, `.axc.hl`
(no font-weight change: a wider label would shift the legend under the
pointer and flicker). CSS in `_style.sql` next to the other `.ashx` rules.
Without a highlight `draw` emits exactly the pre-1.6.1 SVG.

**Windows side by side (plan 024)**: `SP.mode` `'win'` / `'span'`,
`span.seg.axlayout` in `.axh` (hidden when fewer than 2 windows or panels
would be narrower than `AXMP`), `AWR_TL.axLayout(m, persist)`, localStorage
`awr-axlayout` written on a click only, default `AXDEF` (`'span'`; `'win'`
would apply the fit rule). `drawWin` draws one panel per window
(`rect.xw.xpn` + `cur` / `on` / `sk` under the bands, caps `.xwc`, hit
`.xwh` on the caps only, labels `text.xpl` on the lower chart) from
`wSlice(i)`: the 1-minute refs when `fineCov` covers the whole window,
else `bRange`; `colPts` / `bands` / `flagSvg` / `hlOrd` are shared with
Full span (`draw`); `c.g.mode`, `c.g.pan`; `panAt` / `wRefAt` /
`cross(c,t,r,q)` map the pointer; no brush, no Reset. Too many windows:
the most recent `winFit(pw)` panels. Labels / flags follow `c.xl` /
`c.flags` (the last / first chart SHOWN), so it works with one chart
hidden (compact Summary, the dashboard's tabs). Not to be confused with
the dashboard's `window.AWR_axMode` (which chart is shown). The
`js_timeline.plsql` header lists these functions. Release flags
(`flagSvg` + `flag1`, both layouts; G3 follow-up): markers less than 1 px
apart form a group (side by side: every marker of one gap) -- as many as
fit get a flag of their own (two tiers), the last flag shown reads
"<label> +n" and its `<title>` lists the rest (one per line); a group
with no room left keeps a `cfl` line whose title names every marker (the
flags chart used to draw nothing for it). The flag band (`top` 46 vs 22)
is reserved side by side only while a marker sits in the gap before a
panel SHOWN (the most recent `winFit(pw)`); Full span keeps it for every
marker of the span, also while zoomed, so a brush never moves the charts.
`setSvg(c, s)` replaces a chart's SVG in both layouts and gives the focus
back to the same `.xwh` (`data-i`) when one had it (Enter on a stripe /
cap pins, which redraws).

**Direct labels (plan 036; fitted per band, owner decision 2026-11-20)**:
`dlab(c, groups, ord, on, Y, reb, nb)` after the bands, inside the plot
clip (both `draw` and `drawWin`; groups = one `{pts, x0, x1}` for Full
span, one per panel side by side; `nb` = `noteBox()`, the highlight
note's box, which no label covers) builds per series the band's lower /
upper edge and calls the pure `fitLabels(groups, cands, o)`
(`AWR_TL.fitLabels`, unit-tested in `tools/js_unit_tests.js`): per group
the edges are reduced to whole pixel columns (`colExt`: the lowest lower
edge / highest upper edge over each column, no data = never thick), a
sliding window as wide as the label (`slideExt`, a deque) gives each
start's clear box (`stretches`; thickness rounded down to 0.5 px), and
each series takes its thickest stretch (equal thickness: the middle of
the run, `spos`) at least `LBH` 10 px thick, clear of the labels placed
so far (text box `LTH` 12 px, 2 px apart) and kept above the axis. One
label per series per chart, inside one panel; series ranked by their
best thickness (biggest bands first), at most `LMAX` 6. A name is cut at
`LW` 160 px with ASCII `...`; when no stretch fits it, shorter cuts
(`LCUT` 120 / 90 / 64 px, at least 6 characters) are tried
(`lcuts`, cached per name; "log file switch (archiving ne..." on the
test DB's busy hour). A cut whose stem also starts another series of the
chart is dropped (`labelAlts`, pure, unit-tested; G3 review: the test
DB's 15-min report read "log file s..." with both log file switch events
in the chart, a DBA reads log file sync). Before this the label went at the single thickest
POINT and needed 13 px under the whole label, so on real (spiky) data it
almost never fit the event chart. `text.xdl` (CSS halo like `.xhn`,
normal weight so `tw()` is exact, `pointer-events:none`); with a strong
highlight only the highlighted series; per chart `mkChart(..., {labels})`
(both on, owner decision). `dlab` stacks `ord` from zero exactly like
`bands()`: keep them in lockstep. Keep `.xdl` out of `css_design.css`'s
Geist font rule (`tw()` measures the system stack). Cost: about 1-2 ms
more per chart redraw (a thin band is rejected on its thickest column).
verify_report: `bandLabels` (block 5: names, overlap, inside the plot and
inside the band they name via `elementsFromPoint` -- `LABEL_BAND`, which
also fails an ambiguous cut; the demo labels both charts) / `labelHide`, the note check in the highlight
`state()` (`xov`), `sb.labels` (block 5c: inside one panel and its band;
the demo labels both charts side by side too), `sb.flagBand` /
`sb.keys` (5c) and block 5d (two markers injected after the first one:
every marker named, no flag overlap, a "+n" flag on the demo).

### Window component (`sql/lib/wingrid.plsql` + `js_wingrid.plsql`)

The ONE per-window bar grid — hero strip (08), finding / plan / config
cards, the Timeline. Markup (`wg_*`, twin `helpers.wg_*`): `div.wg[data-wg]
style="--np:N"` (`wg_attr`; `data-many` past 30 windows shrinks fitted
grids' column minimum, `#tl` scrolls) › `wg_ruler_put(pre, corner, gh, btn,
post)` (emitted through the `wg_buf` line buffer) › `wg_flags` ›
`wg_bars(pairs, scale, mu, sd, sev, lab, gut, id, cls)` (`.r.bars[data-v
data-mu data-sd data-sev]`, `.c[data-w]` ×(N+1)) › `wg_dates`. Columns are
**oldest first**, `data-w` = week_offset (0 = Current, the report-wide window
key, so the X2 highlight lights `.wg` cells). Values in as offset-keyed pairs
`'k:v;k:v'` (`LISTAGG(week_offset||':'||wg_tok(v), ';')`); a skipped window
has no pair → `.v.nil`. Modifiers: `.fit` (18 px columns), `.bare` (no label
/ gutter), `.allv` (every value printed), `.hov`, `.qf` (quiet flags: only
the marker on the Current window's left edge is labelled, the others keep
their column line; finding and plan-change cards), `.tight` (auto, columns
< 42 px). The card charts (07 finding cards, 18 plan-change card) are
`bare hov qf` since plan 025 (priors on hover), no longer `allv`; 12's
configuration card and 08's hero strip keep theirs. Step rows (12, plan card) are hand-built `.r.p` rows (`i.st.lo|hi`,
`i.nd`, `span.pv`). `wg_date/wg_off/wg_title/wg_keep/wg_start/wg_end`.
**Window metadata:** 00 emits `window.AWR_WIN = {np, w:[{o, d, l, s, e, t,
v}]}` oldest first — read it, don't recompute. **Client** (`window.AWR_WG`):
`markers()` maps `AWR_MARKERS` to window boundaries (`{o, after, l, s, t,
at, inw}`, short labels "Release 4.2" → "R 4.2"; `inw` = the marker falls
INSIDE window o, after its start -- only the Current window can hold one;
its flag still sits on that left edge), `markerAt(o, edge)` (`edge`: only a
marker at or before window o's start), `sizeRow`,
`render(scope)` (call after building / revealing grid DOM), `fit`, `refit`
(auto on DOMContentLoaded, resize, `awr:view`, a `<details>` toggle), `pin`.
`[data-mk-at="o"]` slots get the marker on that boundary (`data-mk-pre`,
`data-mk-icon`); a slot with `data-mk-pre` (" after ": 17's likely-source
line, 18's plan card, 20's sentence, also `js_loadresp`'s re-fill) claims
the change came after the marker, so it takes only one at or before window
o's start (`markerAt(o, true)`): a marker inside the Current window leaves
it hidden (review follow-up R3); the icon slots (12) take either.
`body.js-wg` hides prior values until hover.

**Pattern tags (plan 027).** `AWR_WG.patterns(vals, valid, mu, sd,
marks)` / `patternText(tag, dates)` / `PAT` (the thresholds) are pure and
unit-tested in `tools/js_unit_tests.js`. At most two tags per row, the
Current one first. Nothing is tagged with fewer than 4 valid prior windows
or no Current value. Current outside the band (prior mean +/- 2 sigma,
sigma floored at 2 % of the mean -- the band `sizeRow` and the band glyph
draw) is a run ("high / low for N windows") when the window just before
it is outside on the same side too (a skipped window ends the run), else
"spike" / "dip" ("jump" / "drop after <marker>" when a release marker
falls at or before the Current window's start, AWR_WIN `s`; one inside
Current, `inw`, may follow the change: a plain spike / dip whose sentence
says the marker falls inside the Current window -- review follow-up R3,
the 09:55 release in a 09:00-10:00 window) -- but only when no valid prior window is
outside on that side, so "Current only" holds (a recurring spike gets no
Current tag). A step needs at least 3 valid windows before and 2 after
the split, at least 90 % of the after / before pairs on the same side, a
mean shift of at least 10 % and more than 2 x the larger side's floored
sigma ("step up at <marker>" or "... on <date>"; a skipped window makes
the splits around it equal, and the one with a marker wins, else the
later); a trend needs at least 6 valid windows, R squared >= 0.6 and a
total rise of at least 10 % of the mean, and wins over a step only when a
straight line fits at least as well (smaller or equal residual sum of
squares). A step in the same direction as a "spike" / "dip" drops it: the
windows right before Current already sit at the step's new level, so
"Current only" misleads (dbmint follow-up: a card read "spike: Current
only" + "step up on 08:00" with the two windows before Current high); a
"jump" / "drop after <marker>" stays (it names its marker; the demo's I/O
card keeps "jump after Release 4.2" + "step up at Release 4.1"), and a
step the other way keeps the spike. `tagCards()` (on
DOMContentLoaded, after `render`) fills `.fc-tags` in every `#findings
article.fc:not(.chg)` header and the card's `#triage .tri-tags` (plan 025's
containers) with `span.ptag.p-<kind>[.p-rel][title]` chips, from the
card's `.fc-main .wg .r[data-v]` row (`.r[data-v]`, not `.r.bars`:
js_timeline turns the DB time card's row into `.r.ash`), `data-mu0`-or-
`data-mu` / `data-sd`, the windows' validity and dates from `AWR_WIN` and
the markers from `AWR_WG.markers()`. Tags are a hint: they never change a
severity, the card order or a count. Section 25 (Onset) is not their data
source (fixed metrics on the continuous series; the tags compare periods).
Keyboard (G4): every chip is `tabindex="0" role="note"`, named by its
text (`aria-label`) and described by its sentence (`title`); a keyboard
focus (not a mouse click: `ptr`, set on mousedown) shows the sentence in
one shared `div#ptip` (aria-hidden, absolutely positioned under the chip,
styled next to the `.ptag` rules in `_style.sql`, hidden in print), hidden
on blur, resize and Esc -- the Esc listener never stops the event, so Esc
still clears a highlight / unpins a window. The triage and dashboard
copies are clones, so they carry it too; verify_report phase 4 `tagKb`.

### Band glyph (`sql/lib/band_glyph.plsql`, twin `helpers.py`)

Replaces the v1.4 `data-dev` heat tint and the old Change / z / %Δ columns
in every scored table. `band_z(cur, mu, sd)` (z over max(sd, 2%·|mu|), the
policy's floor) · `band_ztxt(z, cap)` (cap 99 default, 10 in Summary) ·
`band_sev(bucket)` → `s-large|s-moderate|
s-improved|s-typical` · `band_span(z, bucket, size, twin, zcap)` → `<span class="bd
s-…" style="--x:…">` on an axis −4σ…+8σ (x = (z+4)/12; past the ends the dot
pins `po|pu` and prints z, clamped past `zcap`; `flat baseline` hatched `.s-flat`; NULL z /
insufficient / n/a faded `.na`; bucket NULL = unscored hollow dot) ·
`delta_span(cur, mu, bucket, plain)` = THE Δ rule (`▲ ×n` when cur/mu ≥ 2,
else `▲/▼ p.p%`) · `range_txt(mu, sd)` (mu ± 2sd, floored at 0) ·
`band_head` / `band_cells(cur, mu, sd, n, bucket, twin, note, plain)` = the 4
matching columns Normal range | vs normal (axis) | z | Δ vs mean, with
`span.imm` notes (immaterial / improved / noted / n < 3 / σ≈0 — the σ≈0
note replaced the v1.4 `.badge.sig` pill, whose CSS is dead) ·
`lib_ls(id, html)`. `score_cells(...)` = `band_cells(..., score_bucket(...))`;
callers pass the DISPLAY unit (04/05 time tables pass seconds). Include
order (lint 17): `fmt_num → band_glyph → score_cells`, `metric_policy` still
first (lint 16). Placement: 02/03/13 (13 unscored: bucket NULL + plain Δ),
04/05 (+ class rollup), 07 detail tables, 18. Guide glyphs in
`19_reference.sql` use `.bd … sm` / `.d` — keep them in lockstep with the CSS.

### Entity links (`a.ent`) and anchor ids

- ONE emitter: `ent(html, id, kind)` in `finding_cards.plsql` (twin
  `helpers.ent`); lint check 21 flags any other literal `class="ent"`. Ids
  come ONLY from `anchor_id(kind, name)` (lower-case, non-`[a-z0-9]` runs →
  `-`, trimmed, 64 chars after `kind-`) or `finding_anchor(domain, name)` =
  `anchor_id('fr-' || lower(substr(domain,1,1)), name)`, `file_anchor(full
  path)` (parent dir + file name) and `param_anchor(name)` (one extra `-`
  per leading `_`). **An id is a pure function of (kind, FULL name)**, so a
  link computed anywhere equals its target's id without knowing the other
  rows (review #7: 17 linked `fl-<short>` while 15 had suffixed the second
  PDB's `users01.dbf`; `_x_y` / `x_y` / `__x_y` shared `pa-x-y`). Targets add
  a DOM-uniqueness guard (`anchor_uniq(id, name, memo CLOB)` in 04 / 05 /
  12, 14 / 15's own map): only two DIFFERENT names that slug alike get
  `-<n>`, and a link then reaches the first. lint check 30 bans
  `anchor_id('fl'|'pa', ...)` outside `anchor_id.plsql`.
- Row ids: 07 `fr-<l|m|w>-<name>` (detail tables); 04 `we-<event>` /
  `wa-<event>` / `wc-<class>`; 05 `be-` / `ba-`; 06 `sq-<dim>-<sql_id>` per
  ranking table (`sq-change-`, `sq-elapsed-`, `sq-cpu-`, `sq-gets-`,
  `sq-preads-`, `sq-exec-`, `sq-perexec-`; in a tab + `<details>`, reveal handles both) and pool
  `sql-<sql_id>`; 18 `sm-<sql_id>`; 14 `sg-<owner.object[.partition]>` / 15
  `fl-<parent dir>-<file name>` on the FIRST row that segment / file gets (a
  slug collision gets `-<n>`); 12 `pa-<parameter>` (`pa--<_hidden>`); 02
  `load-`, 03 `metric-`, 11
  `ash-card-<sql_id>`; cards `f-<group>` / `f-config` / `f-plan-<sql_id>`;
  Timeline `tl-<detail id>`.
- **Only link to emitted rows:** top-N-dependent targets may be missing, so
  js_wingrid unwraps (DOMContentLoaded, before the chrome) every `a.ent`
  whose target id is absent into `span.ent-x`; the chrome hides 06's
  `.xlink`s to a missing `#ash-card-` / `#sm-`. verify_report requires every
  other `href="#…"` to hit exactly one id and clicks every visible `a.ent`.
- CSS: `a.ent` inherits colour, dotted underline; `.flash` (`tr.flash>td`
  inset wash, other elements outline).

### Report designs (`design`, env `DESIGN`)

Three looks of the SAME report, chosen at creation; presentation only (every
number, section, view and id is in all three). The driver resolves
`~design_name` (`classic` / `quiet` / `dashboard`; `a` / `c` / `dash` short
forms; empty = classic; anything else = the `TO_NUMBER('x')` abort, like a
template) and two include paths: `~design_head` (@@ right after
`_style.sql`) and `~design_tail` (@@ after the footer, before `</body>`).
Classic resolves both to `sql/lib/no_design.sql` (emits nothing), so **a
classic report is byte-identical** to one from before the option -- keep
it that way: never put design rules in `_style.sql` or design markup in a
section. Wrapper: `DESIGN` env var (`norm_design`, configurator menu);
web configurator (`docs/configurator.html`, hash key `ds`); fleet:
`FLEET_DETAIL_DESIGN` (detail runs only; the fleet report itself has no
designs) and the server's env whitelist.

- **Head** (`design_head.sql`): `css_fonts.plsql` (Geist + Geist Mono,
  latin, variable; base64 `@font-face` cut into 2000-char lines that end
  in `\` -- a backslash-newline inside a CSS string is dropped; generated
  by `tools/fonts2plsql.sh` from `vendor/fonts/*.woff2`, OFL, lint 33)
  and `css_design.plsql` (generated from `sql/lib/src/css_design.css` by
  `tools/js2plsql.sh`, which wraps `.css` sources in `<style>`). The CSS
  overrides the SAME tokens as `_style.sql` on `:root` / `@media screen
  { body.dark }` (zinc oklch values; indigo = Current, red / amber =
  severity; wait colours untouched), then restyles components (rail counts
  dot + number, verdict pills as one stats line, `tr.crit|warn` first
  cell a leading dot instead of the inset bar, boxless `.wg .flag` and
  Activity `.cfh`, `.wg.allv` priors on hover, phone-width fixes). The
  skin applies with JS off; every dashboard layout rule is under
  `body.d-dash`, which the script sets only after building the layout
  (JS off: the dashboard looks like quiet, every section stacked).
- **Tail** (`design_tail.sql`): `window.AWR_DESIGN="~design_name"`, then
  `js_design.plsql` (from `sql/lib/src/js_design.js`). Its
  DOMContentLoaded handler is the page's LAST one, so it runs after the
  chrome (00), js_wingrid and js_timeline built their DOM; it only MOVES
  and restyles (ids and listeners survive; the chrome's handlers are
  delegated). Both designs: `p.axn2` behind a "How to read" button
  (`#ashx.howable`), each `.tbl-tools` pair inside a `details.tmenu`.
  Dashboard (`body.d-dash`): rail hidden (`--rail-w:0`); `button.dsearch`
  + `dialog.dpal` palette (Ctrl/Cmd+K in the capture phase, so the
  chrome's row-filter focus never sees it; items = rail links, every
  `main tr[id]` (group = its table caption), cards, ASH / SQL Monitor
  ids; Enter -> `AWR_goTo`; a "Filter every table" item drives
  `#row-filter`; Esc stops propagation so it never unpins); Activity
  `.axseg` (cls / ev / both: `#ashx.ax-cls-only|ax-ev-only`, then
  `AWR_TL.redraw()` -- js_timeline puts the flags on the first chart
  shown and the x labels on the last; plan 024's layout switch
  `.seg.axlayout` sits in the same `.axh` row; `css_design.css` gives it
  the `.axseg` look); `.dkpis` after `#verdict` (DB time
  from `#hero-dbt` + one per finding card, bars from the card's / Timeline
  row's `data-v`); in `#findings` a `.dgrid` = `.dmain` (chrome-style
  `.tabs[data-tabs="dfind"]` Moved / Normal / Improved, so `reveal()`
  switches the tab; Moved = `.dft` of `details.drow`: the lead row of
  each card holds the MOVED `article.fc` (so `#f-<group>` and every link
  into it open the row via reveal's `<details>` rule), then each
  non-twin crit / warn row of the card's related table, its bars drawn
  from `#tl-<detail id>` data-v; the findings table's band cells are
  capped at 10 sigma like the cards (`capz`, plan 020); each row
  `id="dr-<card id | detail id>"`
  (the palette lists them by display name); the Trend cell is the shared
  micro strip, else (past 91 windows, where it draws nothing) the
  design's own mini bars; nothing moved -> 07's "No finding" note goes
  into the Moved tab; Normal = `#s-normal` moved in (`findTable()`
  opens its `details.calm-fold` and `css_design.css` hides the fold's
  summary line: the tab is the fold, plan 032); Improved
  = its `.note.improved`; `findTable()` calls `window.AWR_fcOpen(card)`
  on every card it moves into a row -- the row is the fold -- and
  `css_design.css` hides 07's `#triage` list, plan 025;
  the lead row of each card shows, in a `span.dmeta` line of its `.dnm`
  cell after the `<small>` the palette reads, the card's impact chip
  `span.dimp` (G4: the row hides the card's header, where `.fc-imp`
  lives; `impChip()` builds it from `data-impact` / `data-share` like the
  triage list -- only a rise, "+x AAS · s%", DB time "above normal", the
  card chip's text + explanation as its title; verify_report block 7) and
  a copy of the card's `.fc-tags` (`.fc-tags.dtags`, plan 027)) + `aside.dside`
  (`#s-changes` moved in, plus
  the releases from `AWR_WG.markers()`; a card body inside the grid
  scrolls on its own, so a 169-column plan card never widens the page).
  Before the KPI cards and the findings table are built, `explainsBack()`
  returns a plan card that 17 moved under the card it explains
  (`article.fc[data-explains]`) to `#changes-slot` (the side column, chip
  kept, its `i.xu` arrow hidden; opened with `AWR_fcOpen` and its `.fc-tg`
  toggle removed when 17 had folded it, G4) and unhides `#s-changes` + its rail link
  if 17 had re-hidden them; `kpis()` / `findTable()` select
  `article.fc:not(.chg)` (plan 026).
  Summary order:
  `body.d-dash.vs` puts `#activity` at order 5 and `#findings` at 6, so
  the verdict + KPI cards lead (original mock C; Timeline / All keep
  Activity first); `#overview` hides (its numbers are the DB time KPI)
  (the classic / quiet Summary also leads with the verdict since plan 023,
  by DOM order; the compact Activity mode is off in the dashboard).
- **Demo**: `gen_demo_report.py` writes `demo_busy_db.html` (classic),
  `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` (`--design=`;
  `--check` covers all three). **verify_report.js** reads
  `window.AWR_DESIGN`: dashboard skips the rail checks, checks that the
  compact Activity mode and `#ax-more` stay off (block 2b; every design
  lets the verdict sit above Activity in Summary), runs the Activity
  interaction checks with both charts shown, and its section 7 checks the KPI cards, the table
  (one lead row per card, rows = the Moved count, trends), row expansion,
  the tabs + a jump into Normal, the Activity tabs (x labels + flags on
  the one chart shown), and the palette (Ctrl+K, search + Enter lands,
  Esc keeps a pin); both designs: How to read, the copy menu.
- Adding a rule: edit `sql/lib/src/css_design.css` / `js_design.js`, run
  `tools/js2plsql.sh`, regenerate the demo; ASCII only (`\uXXXX` in JS,
  `\2014` in CSS `content`), no tilde (the CSS sibling combinator too).

### Micro strips (`js_microstrip.plsql`)

Renders every `[data-spark]` cell (attribute contract unchanged, no emitter
changed) as the mock's 13-bar strip `svg.mw`: bars from zero, Current last
(1.6× wide, accent), normal zone mean ± 2σ (σ floored at 2% of |mean|) from
the CSV's own prior slots, title = last four windows + range (labels from
`AWR_WIN`). A bar under a pixel wide (past about 45 windows; past 91 the
strip has no room at all) draws nothing, except in an element carrying
`data-spark-dense` (07's triage list `.tri-spark`, G4 follow-up): the prior
windows as one gapless silhouette (`path.b`) and Current a 3-px bar, title
"...; all N windows" (`AWR_microStrip(csv, title, {dense})`; the dashboard's
Trend cell keeps its own mini bars fallback). `window.__awrRenderSparks` kept. It replaced `js_sparkline.plsql`
in the single-DB prologue (and the demo); **js_sparkline is fleet-only now**
(`00_fleet_chrome.sql`) — don't delete it.

### Reference section (`sql/19_reference.sql`)

Driver: after 12, before 17 (demo SECTIONS the same). `section#guide.guide`
"Reading the charts": `.gi` items in `.gdg` (band, Δ, micro strip "Trend",
window bars, span chart, full-span activity, activity per window, step line,
day profile, hover and pin, …; markup originally lifted from the mock by a
one-off script — edit the SQL directly). `section#about.aboutsec >
details.aboutrep` — `<dl class="notes">`, one dt/dd per topic (Scoring, Band
and Δ, Windows, DB time, Timeline, What changed around it, Evidence library,
Day profile [only when `profile_days>0`], …) + `p.ab-meta` run line. **New
method notes go here, not under a section heading** (the per-section "How
this is computed" folds are gone). Twin `s19_reference.py` lifts the literal
PUT_LINEs; only the profile note and the meta line are hand-ported. Guide
markup: SQL*Plus lines < 2499 chars (split with `||`), non-ASCII as HTML
entities; SVG colours via `style="fill:var(--x)"` (a `fill="var(--x)"`
attribute is not reliable).

### Generated client scripts (`tools/js2plsql.sh`)

`sql/lib/js_timeline.plsql`, `js_wingrid.plsql` and `js_microstrip.plsql`
are GENERATED from `sql/lib/src/<name>.js`: edit the `.js`, run
`tools/js2plsql.sh [name]` (POSIX sh + awk). It keeps the hand-written
header above the `BEGIN` line and rewrites the body (blank lines dropped,
`'` doubled; a tilde or a ≥ 2300-char line is rejected). `--check` = lint
check 24. Dev-time only — the committed `.plsql` files are what runs. All
other client JS (00's chrome, section scripts) is hand-written PUT_LINEs.
**The sources are pure ASCII**: non-ASCII in JS is a `\uXXXX` escape (lint
check 25; see the gotcha).

### Section order (v1.6.0)

`awr_trend.sql` includes the sections in **DOM** order (00, 10, 08, 09, 07,
27, 20, 28, 01, 26, 16, 25, 13, 02, 03, 04, 22, 05, 24, 06, 21, 11, 18, 23,
14, 15, 12, 19, 17; each visualization section 20-28 right after the section
it extends) = the JS-off stacking; 00 emits the verdict hero, then `#activity` (plan
023); with the default `order:3` the charts are the first section in
Timeline / All sections and follow the verdict in Summary. Views reorder visually: Summary via the library's `--os`
(`order:calc(10 + var(--os))`), All sections via `_style.sql`'s "All
sections order" block keyed by section id (Findings, Load, Metrics, FG
waits, BG waits, Top SQL, Top SQL ASH, SQL Monitor, Segment, File,
Parameters, ASH timeline, DB time, Utilization, Windows, Day profile, then
guide / about / footer); the rail groups follow the All order. Adding a
section = its `@@` in the driver, its rail link in `00_params.sql`, a
`vw in-*` class (+ `lib`/`--os` if it joins the library), a slot in the All
order CSS, and the same slot in `demo/gen_demo_report.py`'s `SECTIONS`.
Order constraints: 07 before 18 and 12 (`#changes-slot`), 18 before 12
(plan cards first), 17 last. The body is `<main id="main-start">`
(display:contents) opened by 00, closed in the driver epilogue; `body >
section` selectors must also match `main > section`.

### Chrome hooks (v1.4.0 facelift, still live)

Small single-sourced attribute / class contracts wired by `00_params.sql`'s
JS and `_style.sql`; all degrade to "show everything" with JS off:
- **`tr[data-tail="Y"]` + `.expander[data-for][data-n][data-noun]`** — long-
  tail row collapse (07 detail tables, 06 SQL pool, 18). reveal() opens it.
- **`[data-w="N"]` (0 = current) + `awr:window`** — every window-indexed
  `<th>`/`<td>`, `.wg` cell and the top-bar chip carry `data-w`; clicking a
  `th[data-w]` toggles `.hl` (amber) on every element sharing that offset and
  dispatches `awr:window` (chart sections mark the window). Not the Timeline
  pin.
- **`.tabs[data-tabs]` / `.tabpanel[data-tabs][data-t]`** — Top SQL's
  ranking dimensions (Biggest change first; the first emitted panel is
  `on`; the hash's `tab=` names any tab but the bar's first, so never
  compare against a literal default); panels holding ECharts resize on
  activation.
- **`.copy-btn[data-copy]`** — copies the selected element's text; inline
  by default, absolutely positioned only inside `pre`/`.codewrap`. `.tbl-tools`
  CSV/MD toolbars auto-inject above any table with ≥ 4 rows.
- **`data-nosort` / `data-nocount` / `data-notools`** — table opt-outs
  (sort parser handles `,` `%` `▲` `▼` `−` `×` and k/M/G — keep in sync with
  `fmt_num.plsql`; `data-nocount` keeps rows out of the section-header counts, e.g. the
  cards' related-metrics tables).
- **`.chip`** — shared pill styling (rank chips, window chips).
- **`#sum-btn` / `#sum-pop`** (plan 034) — Copy summary: built at click
  time from `#topbar`, `#verdict h1`, `#because-slot`, `#narrative-slot`,
  `#findings article.fc:not(.chg)` (`.fc-k .sv`, `h3`, `.big .v/.u/.nrm`,
  `data-impact` / `data-share`), the plan card that explains a card
  (`#findings article.fc.chg[data-explains]`, plan 026) plus
  `#changes-slot > article.fc`, and `footer.report`. Renaming any of these
  hooks breaks the summary; verify_report's `sumOk` catches it. Works in
  every design (the dashboard moves the cards; the selector does not
  depend on `.cards`); quiet / dashboard style it in `css_design.css`.
  The button ships `hidden` (JS off: no button); Escape anywhere in the
  popover (it has tabindex -1) is stopped there, so it never unpins a
  window. While open the top bar carries `.sum-open` (z-index 40; relative
  at 980 px and below, where the popover hangs under the static bar): the
  Timeline's sticky ruler and the narrow rail bar painted over it.
  `position:fixed` cannot pin it: the bar's backdrop-filter makes the bar
  the containing block of fixed descendants. verify_report: `sumEsc`,
  `sumOnTop`.
- **Number formatting (T7, `fmt_num.plsql`)** — `fmt_num` ~4 significant
  digits with k/M/G ≥ 1e4/1e6/1e9, full precision in `title`; `fmt_int`
  for counts; `fmt_dur(sec, short)` for Summary-view durations (plan card;
  `fv` / `fv_range` unit `'dur'`; `wg_bars(..., p_fmt => 'dur')`), never in
  tables or payloads. Never inside `data-spark` / `data-v` / `AWR_DATA`
  JSON (raw numbers under the NLS pin).
- Retired: `td[data-dev]` heat tint (v1.6.0, band glyph), `section
  [data-normal]` / `.full-only` / triage mode / Essential rows / Application
  only (v1.5.0–1.6.0), `.badge.sig` (now a `span.imm` note), 07's movers
  table and `#findings-movers`, and the `td.cell-bar .bg` magnitude bar in
  02/03/13's Current column (still emitted, `display:none` — its edge
  crossed the digits on the Current tint).

### Look & feel tokens (v1.6.0, `sql/_style.sql`)

Spacing `--s1..--s8` (4…64 px); Mock D tokens `--acc --acc-ink --acc-band
--acc-soft` (indigo = Current), `--zone1 --zone2 --track --tick --mean --bar
--crit-dot --warn-dot --imp --mk --mkline --flagbg --hov --pin --flash
--ink-4` on `:root` + `body.dark`. **Alias tokens (`--surface --surface-2
--bg --ink-2 --ink-3 --line --line-2 --row-bg`) are declared on `body`, NOT
`:root`** (see gotchas). Section header `<h2>Title<small
class="h2sub">…</small></h2>`; the chrome appends `span.meta` (dot + "N large
· M moderate") unless the h2 brings its own. Current column
`td[data-w="0"]` = `--acc-band`; sticky `th[data-w="0"]` uses an opaque
`linear-gradient(tint,tint) var(--panel)`. Colour diet: `tr.crit/.warn` = a
2px inset marker on the first cell (no row fill), band tables the same via
`:has(.bd.s-large|s-moderate)`. **`_style.sql` is also included by the fleet
chrome** (`sql/fleet/00_fleet_chrome.sql`): scope new rules to single-DB
classes; `table.dt tr.crit|warn td:first-child{box-shadow:inset 3px 0 0 …}`
exists only to keep the fleet findings band's pre-1.6 severity bar, and
`table.dt tr > td|th:first-child{padding-left:10px}` keeps the fleet's
first-column text off that bar (the fleet's own `table.dt td` rule has 0
left padding and a lower specificity).

### Gotchas from the v1.5.0 / v1.6.0 passes

- **CSS custom-property aliases on `:root` freeze the light theme:**
  `--row-bg:var(--panel)` on `:root` resolves there and inherits as a value,
  so `body.dark` never reaches it. Declare any new alias token on `body`.
- **`~` as the CSS general-sibling combinator is the tilde gotcha** (`.lane
  ~ .lane` → "Enter value for"). Lifted mock CSS/JS must be tilde-free (the
  generator and lint check 3 catch it).
- The global `h3` rule is `display:flex; gap:8px` — an h3 built from inline
  spans (card headlines, lane titles) needs `display:block`.
- `nav.toc a{display:flex}` beats `[hidden]` → `nav.toc a[hidden]{display:none}`.
- Sticky `th` with a translucent background lets rows show through — use
  `linear-gradient(tint,tint) var(--panel)`.
- In-page link clicks use `history.replaceState` → no `hashchange`.
- Relocation scripts run during parsing, before DOMContentLoaded (see the
  relocation pattern).
- `<template>`/`<script>` between `</tr>` and `</tbody>` is legal but easy to
  misplace — flush Timeline lane rows after the table.
- PL/SQL `LOG(10, 0)` raises — guard `v = 0` before any log-scaled token.
- lint.sh: a `finding` raised inside `… | while read` runs in a subshell, so
  its `fail=1` is lost; `finding` also appends to a temp flag file that is
  checked at the end — keep using `finding`, never set `fail` directly in a
  pipeline.
- Demo twins that slice the SQL's PUT_LINEs by **index** (`L[n]`) shift when
  a PUT_LINE moves; prefer anchor-based slicing (`_slice`, `_index`).
- `grep ORA-` over a daily / AUTO report hits captured SQL text of the
  report's own queries (`regexp_like(…'ORA-200[0-9]…')`, Top SQL text) —
  false positive; look at the log and the context before calling it an error.
- `verify_report.js` takes ~3 min per report; run instances ONE AT A TIME —
  parallel runs hang Chrome.
- **Emitted text must be pure ASCII.** SQL\*Plus converts every PUT_LINE to
  the client character set; on a non-UTF-8 client (dbmint's) each
  multi-byte character arrives as `?`. Phases 3/4 shipped literal `–` `—`
  `−` `▲` `▼` `×` `◆` `✚` `▽` `…` in js_timeline / js_wingrid, so on dbmint the
  Timeline's skipped-window cells read "???" (the demo, written by Python in
  UTF-8, never shows it). HTML entities in markup, `\uXXXX` in JS; lint
  check 25 scans `awr_trend.sql`, `sql/[0-9]*.sql`, `_style.sql`,
  `sql/lib/*.plsql` and `sql/lib/src/*.js` (comments exempt). The demo
  report is now pure ASCII too — a non-ASCII byte in it is a hint.
- The report has **no global link colour**: a plain `<a>` outside `td` or a
  styled class renders in the browser's default blue (unreadable in dark).
  Give it a rule (e.g. `.calm-more a`); verify_report fails on any visible
  default-blue / purple link.
- The multi-DBID "all DBIDs …" note, the non-default template name and the
  "run by <user>" line lived in the v1.5.0 masthead and were silently lost
  with it; the first two are in the top bar now, the user in 19's About
  meta line. When retiring markup, grep main's version for every
  DEFINE it printed (`~dbid_list`, `~template_name`, `~caller_user`, …) and
  re-home each one.
- **PL/SQL declaration order (lint check 14):** nothing that looks like a
  variable / TYPE declaration may follow a FUNCTION/PROCEDURE or any
  `@@sql/lib/*.plsql` include in the same DECLARE section (PLS-00103
  "expecting begin function pragma procedure"). Every include declares
  subprograms, so put all plain variables first, includes last -- and
  `metric_policy.plsql` FIRST among the includes/subprograms because it
  opens with `TYPE policy_rec` (lint check 16). A `policy_rec` variable
  in a consumer therefore goes in a nested `DECLARE ... BEGIN ... END`
  inside the executable part (00/07 do this), never in the outer DECLARE.
- **`SHARE` is an Oracle reserved word** (`LOCK TABLE ... IN SHARE MODE`);
  as a record field / column alias it raises PLS-00103. Use `shr` (lint
  check 15).
- **Never self-join `dba_hist_reports` with an XMLTABLE aggregate on the
  inner side:** WRP$_REPORTS stats say 1 row, so the optimizer pushes the
  join predicate into a nested loop and re-parses every report's XML per
  outer row. Compute per-sql_id rollups (mode plan etc.) as analytics
  over the one scan instead (18's scatter query, 2026-09-22).
- PL/SQL `v <> ''` is never TRUE — an empty string `IS NULL` in Oracle, so
  a guard must be `v IS NOT NULL`, not `v <> ''''` (bit `17_narrative.sql`'s
  `v_tail` guard live). Worse, `IF v IS NOT NULL AND v <> '' THEN` never
  runs its branch at all: that dead guard (present since before v1.5.0)
  hid 06's `plan↑` badges and Timeline plan diamonds, every
  prior-window `#n` rank chip in 04 / 05 / 06 / 14 / 15, and flagged every
  14 / 15 row "new" -- the demo twins (Python, where `'' != None`) never
  showed it; found on dbmint 2026-09-27. lint check 31.
- `DB CPU` lives ONLY in `DBA_HIST_SYS_TIME_MODEL` (microseconds);
  `DBA_HIST_SYSSTAT` has no `DB CPU` row at all (it does carry `DB time`,
  in centiseconds). v1.6.0 shipped reading `'DB CPU'` from SYSSTAT, so the
  verdict's / DB time card's "mostly wait / mostly CPU" never fired on a
  real DB while the demo (which invented the row) showed it (review #1).
  Every template-driven LOAD read now goes through
  `sql/lib/load_pairs_cte.sql` (00 / 02 / 07), which takes `DB time` and
  `DB CPU` from the time model / 1e4 (centiseconds, the unit the templates,
  policy floors and AAS scale assume); 08's strip and `day_profile_cte.sql`
  (16 + fleet 06) route them the same way. lint check 26. The fleet's own
  `templates/fleet/sysstat_load_targets.sql` (fleet-owned, untouched) still
  lists `'DB CPU'` for its SYSSTAT findings read -- a dead row there.
- **A skipped window is unknown, never "absent":** a NULL in a per-window
  top-N CSV means "not in the top N" OR "window skipped". `tl_first(csv,
  valid)` only calls a row "new" when an older VALID window lacked it
  (review #2; weekly cadence past AWR retention made every Top SQL row new).
- **Per-window strings must not assume 13 windows.** At weeks_back 168 the
  ruler (~240 B a window) passed 32767 and the windows-JSON `LISTAGG`s
  (~50 B) passed SQL's 4000 → ORA-06502 / ORA-01489 aborted the run under
  `WHENEVER SQLERROR EXIT`. Rules: stream long per-window markup through
  `wg_buf` (`wingrid.plsql`; the ruler is `wg_ruler_put`), build per-window
  JSON in a PL/SQL loop not `LISTAGG`, give header / row accumulators
  32767, and an unavoidable per-window `LISTAGG` of wide tokens uses `ON
  OVERFLOW TRUNCATE` with a harmless indicator (18's detail slots). Offset
  labels come from `off_label(k)` (`sql/lib/off_label.plsql`, lint 29) --
  the old 16-entry `offset_labels` DEFINE is gone (a DEFINE caps at 240
  chars). Check with the demo: `demo/awrdemo/model.py`'s WEEKS_BACK /
  STEP_HOURS / WIN_HOURS can be patched from a scratch script and no output
  line may pass 32767 bytes (tested: 168 hourly, 52 weekly, 2 h every 1 h;
  past about 100 days also move SNAP_FIRST back, or the old windows are
  skipped and every string stays short).
  **06 has no per-window `LISTAGG` any more** (v1.7 review): its
  per-statement CSVs (`week_vals` / `week_rnks` / `week_phvs`, up to 25 B
  a window) and its two window-label lists (15-19 B) passed 4000 near 200
  windows, sooner since Biggest change (a value in every window the
  statement ran). Its cursors return one row per (dim, statement or group,
  window) with the statement's values as analytics; the loop keeps each
  window's tokens in collections keyed by week_offset (`v_wv` / `v_wr` /
  `v_wp`) and renders on the last window (`CONTINUE WHEN`); the header and
  detail rows go through `wg_buf` one cell at a time; the label lists are
  built in a loop. Demo at 365 daily windows: the old CSV would have been
  6953 B, every 06 line is now under 32767 (the chart JSON keeps its
  32500 cap and "first n of m" note). **The rest of the report still stops
  near 210 windows** (pre-existing, not fixed): the ISO window-label
  `LISTAGG`s of 14 / 15 / 18 (19 B a window: 4000 at about 210), the
  hourly label `LISTAGG`s of 04 / 05 (15 B: about 266), the window grids
  `wg_bars` returns as one VARCHAR2 (08's strip, 07's cards, 18 / 24:
  about 145 B a window on dbmint, 32767 at about 226) and the per-row value `LISTAGG`s of 02 / 03 / 04 /
  05 / 07 / 13 / 14 / 15 / 18 (6-24 B a window, data-dependent: 4000 at
  about 250 windows on the busy demo, 450-650 on dbmint's 168-hourly
  run). Lifting that is its own change (06's pattern, plus streaming
  `wg_bars`).
- **Overlapping windows (win_hours > step_hours)** share samples: 09 counts
  an ASH sample toward EVERY window containing it (`j_lo..j_hi`), else each
  window held only `step` hours but was divided by `win_hours` (review #4).
- Under `set -o pipefail`, `grep ... | grep -q` in lint.sh reads as "no
  match" when the first grep dies of SIGPIPE; use one `awk` instead.
- Day / month names: every `TO_CHAR` naming a day or month passes
  `'NLS_DATE_LANGUAGE=ENGLISH'` (lint 28) and the driver pins the session
  next to the numeric pin -- a localized name is non-ASCII on a Czech /
  German client ("?", lint 25) and disagrees with the JS's English arrays.
- `DBA_HIST_PARAMETER` is per-container in a CDB: a bare join fans out one
  row per container per (dbid, snap_id, instance_number), so any consumer
  comparing values across windows must collapse by `con_id`/`con_dbid`
  (lowest wins — the instance-level value a DBA means by "the parameter").
  `17_narrative.sql`'s R3 does this; `12_param_changes.sql` was fixed the
  same way concurrently.
- **Splitting a delimiter-joined string with `REGEXP_SUBSTR(s, '[^X]*',
  1, k)` is wrong** when a field can be empty: the `*` yields a
  zero-length match at each delimiter, so every later occurrence shifts by
  one. Use a pattern that consumes the delimiter — `RTRIM(REGEXP_SUBSTR(s
  || 'X', '[^X]*X', 1, k), 'X')` — or `nth_csv` (bit 18's per-window
  sub-table live, 2026-09-22).
- A `.copy-btn` is inline by default and absolutely positioned only inside
  `pre`/`.codewrap` — placing one elsewhere without that ancestor needs an
  explicit position context or it flows inline unexpectedly.
- **`DBMS_XMLGEN.CONVERT` on a long `VARCHAR2` can raise ORA-19011**: the
  escaped result must fit an internal buffer of about `max(4000, 4/3 x
  input)` bytes, so 667 quotes fail while 8000 plain bytes pass. Fine for
  names and snippets cut to a few hundred characters (400 x 6 = 2400);
  anything longer is escaped in 500-character pieces, as 06 does for the
  full SQL text (which also stops before `PUT_LINE`'s 32767 bytes). Bit a
  168-window run on dbmint, 2026-11-13: a top statement with 216 quotes
  ended the report with exit code 67.

### Visualization sections (20-28)

Nine diagnostic views, one numbered section each, added in one pass from
`design/viz_ideas_mock.html` (the mock) under the contract in
`design/HANDOFF_viz_sections.md`. They EXPLAIN: none adds a finding, a
count, a pill or a severity of its own (27 and 26 re-use `policy_bucket()`
and must agree with 07). Common shape, keep it when touching any of them:

- **Placement.** Each is `<section id=X class="vw in-s in-a lib"
  style="--os:N">` (25 also `in-t`): a Summary evidence-library row
  (`--os` 10-18, after Parameters; `lopen` only when the view has something
  to say) and a full section in All sections, where it takes the CSS
  `order` of the section it extends and follows it in the DOM (driver
  order), so it shows right after it: 27 / 20 / 28 after Findings, 22 after
  Foreground waits, 24 after Background waits, 21 after Top SQL, 23 after
  SQL Monitor, 25 after DB time, 26 after Windows. Rail: group
  **Diagnosis** (27, 20, 28) + one link next to each extended section, all
  `data-nodot`. The section is ALWAYS emitted (h2 + `p.note` when there is
  nothing to draw): the rail links to it.
- **Files per view** (lib base `<b>` = loadresp, volcost, waithist,
  planflame, blocking, onset, winsim, instmap, reldelta):
  `sql/NN_<name>.sql`, `sql/lib/src/css_<b>.css` -> `sql/lib/css_<b>.plsql`
  (in `<head>` via `sql/lib/viz_head.sql`, after `_style.sql`, before the
  design's stylesheet; single-DB only), `sql/lib/src/js_<b>.js` ->
  `sql/lib/js_<b>.plsql` (@@-included by the section AFTER its markup and
  its `window.AWR_DATA.<b>` payload), twin
  `demo/awrdemo/sections/sNN_<name>.py` (synthetic data derived in the twin
  with `w.rng`, `model.py` untouched), private CTEs `sql/lib/<b>_cte.sql`
  (20, 25). `tools/js2plsql.sh` picks every `sql/lib/src/*.js|css` up by
  itself (lint 24); lint 34 checks `viz_head.sql`'s includes exist.
- **Contract.** Inline SVG / HTML only, never in a `.chart-wrap` (they must
  draw with the CDN blocked); a chart draws when its box has a width
  (`ResizeObserver` + `awr:view` + resize: a closed library row measures
  0); colours from CSS tokens, so the theme toggle and the quiet /
  dashboard designs restyle them with no listener; every selector starts
  with the section id or the lib base; `lib_ls(id, html)` gives the row's
  one-line answer; a "Reads as:" sentence computed in PL/SQL (28: in the
  page, markers are client-only); next to every chart a real table of its
  numbers (JS off: the note and the tables). Links only through `ent()` /
  `anchor_id()` and only to emitted rows.
- **Optional grants (lint 35).** `DBA_HIST_EVENT_HISTOGRAM` (22) and
  `DBA_HIST_SQL_PLAN` (23) are NOT in the README's required list: read them
  only through `OPEN c FOR '...' USING` inside a handler for ORA-00942 /
  ORA-01031 that renders a "needs SELECT on" note; the windows / statements
  come from static SQL first. A static `FROM` on either aborts the whole
  run for an analyst user without the grant.
- **Tooltip.** js_timeline hides the shared `#tip` on every document
  `mouseover`; a view that reuses `#tip` shows it on `mousemove`, or from a
  document `mouseover` listener registered after js_timeline's (20, 22,
  24), or uses its own tip element (23).
- **Cost on dbmint** (debug markers, 9-48 windows): each 0.2-2.6 s; the
  nine together add about 4-8 s to a run.

#### Instance map (`sql/27_instance_map.sql`, `section#instance-map`)

Section 07's findings drawn on one PL/SQL-emitted inline SVG (viewBox 1040 x
410, complete with JS off): 11 areas (clients, sessions, locks, shpool,
bufcache, dbwr, lgwr, datafiles, redologs, temp, other), arrows as
axis-aligned polylines plus triangle heads (`arrow()`, half-pixel coordinates
only so the twin prints the same numbers). Recompute = 07's unified query
copied as-is, minus the per-window LISTAGG; buckets ONLY via
`policy_bucket()`; the ONE family -> area table is `im_comp` (twin `_COMP`);
only canonical rows colour an area. Area state = worst row: large > moderate >
improved > normal (typical / noted / flat baseline) > not measured. Lead:
flagged / improved -> `lead_before` (bucket, card_primary member, |z|, shorter
label); normal -> `im_pref`'s metric, else any measured row. A flagged area is
`<a href="#f-<group>">` of its lead's card (07 emits a card for every group
with a canonical large/moderate row = the same condition); `data-sev`,
`data-cards` (every card behind it) carry the agreement contract (card sev ==
max sev of the areas listing it). Hidden `div.im-src[data-c]` per area is
cloned into the one `div.im-pop` popover by js_instmap (hover / focus; Esc in
the capture phase only while open; a click on a flagged box -> `AWR_goTo(card,
true, true)`). Payload `AWR_DATA.instmap = {areas, measured, comps:[{k, sev,
cards}]}`. Table `data-nocount` (07's rows already feed the section-header counts). < 3
valid prior windows: query skipped, all "not measured" + note. Twin
`s27_instance_map.py` reuses `s07_summary.compute_findings`. Unexercised: the
improved state, RAC, multi-DBID.

#### Load vs response time (`sql/20_load_response.sql`, lib base `loadresp`)

Scatter, x = load, y = response time, from DBA_HIST_SYSMETRIC_SUMMARY only;
fixed metric list (template-independent): User Calls / Executions / Logical
Reads Per Sec, SQL Service Response Time (cs, emitted as ms), Database Time
Per Sec. Cloud = every interval of the span via the private
`sql/lib/loadresp_cte.sql` (continues a WITH after windows_cte: lr_span,
lr_snaps with the 00/10 restart guard, lr_cur, lr_pts = SUM for rates / AVG
for the ratio across instances). Window dots = 03's window average. Six pairs
p = load index + 3 * response kind (0 service time, 1 DB time per unit, x1000
for logical reads); default = most points. Curve: one SQL, ROW_NUMBER over (x,
y), LEAST(8, FLOOR(n/6)) equal-count bins, MEDIAN / PERCENTILE_CONT, needs >=
12 non-Current intervals. Verdict per pair in PL/SQL through policy_bucket
(load policy = the x metric's; response = SQL Service Response Time's, values
/ 10); the "slower than that load explains" test runs policy_bucket on
Current's ratio to the curve vs the priors' ratios. Reads-as per pair in the
payload (JS swaps it); library row = the default pair's verdict + a
`data-mk-at="0"` release slot (js_loadresp re-fills it after a swap). Payload
`AWR_DATA.loadresp = {def, t0, n, stride, p:[{n, xl, yl, xu, yu, e, c:[[mx,
my, q1, q3]], r}] x6, w:[{o, l, t, v, m:[uc, ex, lr, srt_ms, dbt]}] oldest
first, bt (minutes since t0), bc (Current flags), b0..b4}`; numeric arrays
through put_clob_chunked (strings never, it splits at commas). Cloud thinned
to about 6000 points by stride (Current kept). Client: draws only when
.lr-plot has a width (ResizeObserver, awr:view, resize);
`#load-response.lr-js` shows the chart (JS off: note + tables). Tooltip = the
shared #tip shown on mousemove (js_timeline hides #tip on every document
mouseover, so mouseover-driven tips get erased). Gotchas: an incident in the
prior windows inflates sigma, so Current reads "normal" (dbmint run D); the
default table follows the default pair only. Unexercised: RAC, multi-DBID,
thinning, empty-data notes.

#### Before and after a release (`sql/28_release_delta.sql`)

`section#release-delta.vw.in-s.in-a.lib` (--os 18). PL/SQL re-runs 07's
recompute (load_pairs_cte, additive SYSMETRIC, per-class SYSTEM_EVENT,
template wait list), keeps metric_policy canonical rows and emits
`AWR_DATA.reldelta = {nv, m:[{d:"L|M|W", n, l (metric_label), u, s
(metric_scale), dir, mp, ma (policy min_pct / min_abs), id (finding_anchor),
v:{"<week_offset>":raw}}]}` in lines < 30000 bytes. Markers live only on the
client, so `js_reldelta` (src/js_reldelta.js) does the split from AWR_WIN s/e
strings (before: e <= t, after: s >= t, else straddles; valid windows only),
usable = >= 2 before and >= 1 after; one button per usable AWR_MARKERS entry
(newest first, default the newest), a select of every boundary (W[i].s),
outside-span / unusable markers listed in `p.rd-skip`. Stats: sample sd, floor
2% of |mean|, out = |z| > 2, material = min_pct + min_abs (WAIT: share of the
after wait total); status worse / better / changed (ANY, INFO) / small /
inside. Rows are HTML/CSS (left in %), no SVG and no width needed; axis
symmetric, clamp at +-400% ("> x5"). Library row upgraded via `AWR_ls`; the
split table `table.rd-tbl[data-nocount]` (tbody replaced per split, chrome
sort works). No usable split (no release marker and no boundary picked:
every marker-less real-DB report) hides `.rd-body` -- legend, charts and the
still-empty split table -- and shows `p.rd-why` instead; `details.rd-all`
(`table.rd-tall`, Current vs all priors) shows in every case, so no number
is hidden (verify_report's `allFull` skips a table without a data row, its
`rdSplit` wants `.rd-app` shown, then the note + that table, the demo a split). JS off:
`p.rd-nojs` + `table.rd-tall`. Never call anything a
finding or use large / moderate. Links are built as `a.className="ent"` only
when the target id exists (lint 21 scans the generated plsql for the literal).
Unexercised: RAC, multi-DBID, a before mean of 0, a marker inside Current on a
real DB.

#### Wait latency histograms (`sql/22_wait_histogram.sql`, `#wait-hist`)

Library row `--os:12` (`lopen` only when an event changed shape), All sections
after Foreground waits. Source DBA_HIST_EVENT_HISTOGRAM (NOT in the README
grant list): windows (BULK COLLECT from valid_windows) and the events (04's
Current ranking over SYSTEM_EVENT, template wait list, Idle out, LEAST(8,
top_n)) by static SQL; the histogram per valid window row by `OPEN c FOR` with
binds (events bound as a `sys.odcivarchar2list`), inside a block catching -942
/ -1031 -> "needs SELECT on" note + lib_ls. 19c carries sub-ms buckets:
wait_time_milli 2^-10 .. 2^k (k folded into -10..40, the time midpoint capped
at 2^22 ms; only Idle events reach the 1.8e16 bucket). Deltas GREATEST(0, end
- begin) per instance; a valid prior window without rows = 0 waits, a skipped
one is absent. Normal = mean share over prior windows with >= 30 waits; band =
per-bucket min / max (a folded end sums them, capped at 1). Classification in
PL/SQL on the raw count percentile buckets (header comment). Payload
`AWR_DATA.waithist = {min, ev:[{n, cl, k, nc, nn, np, lab, rg, cc, ct, mc, mt,
lc, hc, lt, ht}]}`: display-bucket arrays (counts, time ms, normal / band
shares by count and time); `lab` axis labels, `rg` ranges (micro sign as a JS
escape). Client `js_waithist` draws `.whp` per `article.whc[data-i]`
(ResizeObserver, awr:view, resize), computes the marks from the shown
distribution, tooltip on the shared #tip via a document mouseover registered
after js_timeline's (an element listener would be hidden by its tipOff).
`.whseg` buttons hidden until JS. Twin s22 synthesizes log-normal buckets from
the model's waits / avg (w.rng), db file sequential read gets a 6% ~5 ms mode
after Release 4.2. Unexercised: RAC, multi-DBID, ORA-01031, con_id fan-out.

#### Blocking (`sql/24_blocking.sql`)

`section#blocking.vw.in-s.in-a.lib` (`--os:14`, `lopen` at >= 300 s Current
blocked AND (n < 3 or mean 0 or >= 2x mean)). Part 1: `.wg` strip (`#bk-bars`,
minutes) of VALID-holder ASH samples x 10 s per valid window, UNSCORED (no
policy line fits; plain `delta_span(..., 'Y')`). Part 2: the Current window's
holder trees. ONE bounded ASH scan joined to `valid_windows` per instance
(snap range + sample time), aggregated by a 4-row generator cross join (1
window, 2 edge `w|b` for event / sql / object, 3 session for holder info, 4
one row per blocked Current sample) -- NOT GROUPING SETS: 19c's rewrite raises
ORA-00905 on the `#` columns. PL/SQL `flush_sample` resolves each sample
(inst, sample_id): waiter -> holder -> ... -> final holder (visited set =
cycle stop, `pa_cyc`); the paths form a prefix tree (`pa_*`, levels 0-2,
deeper summed into the level-2 ancestor). Payload `AWR_DATA.blocking = {cur,
roots, shown,
nodes:[{i,p,lv,r,k:r|w|m,id,who,ns,sql,ev,obj,s,bn,bs,cyc,deep}]}` (seconds),
one node per PUT_LINE. Client `js_blocking` lays out bands per root, edge
width 2 + 14 s / max(maxEdge, 300 s), tooltip in `#tip` via a document
mouseover registered after js_timeline's (which hides the tip elsewhere);
Enter / click -> `AWR_goTo(#sq-elapsed-<id>)`. Names: ALL_USERS (public; uid 0
= SYS; other containers -> "user id N (container c)"), DBA_HIST_SEG_STAT_OBJ
for current_obj#, else the number. Gotcha: beware `#` columns under GROUPING
SETS. Demo twin synthesizes a batch-holder chain from the model's row-lock +
TX index samples (Current total stays normal). Unexercised: RAC / GLOBAL /
cross-instance chains, a real deadlock cycle, a skipped Current window, the
500k-sample / 3000-edge caps.

#### Volume vs unit cost (`sql/21_volume_cost.sql`, `volcost`)

`section#volume-cost.vw.in-s.in-a.lib` (`--os:11`, `lopen` when a statement is
slower per run): did what got more expensive RUN MORE OFTEN or did EACH RUN
GET SLOWER. Statements = Current's top by elapsed from DBA_HIST_SQLSTAT (06's
join; `LEAST(60, GREATEST(2*top_n, top_n+10))`); events = 04's event set
(template wait list + `'*'` sentinel, top_n by all-session time in any valid
window) measured on the `*_FG` columns (pairs -> bounds -> deltas). Normal =
over the valid prior windows with a completed run: mean executions, mean
total, per run = total / executions (so x * y = the total ratio exactly; a
mean of per-run values breaks the diagonals). States: P placed, N new in
Current (no valid prior window saw it), Z nothing now, B no prior run (counted
in `p.vc-drop`). Fixed thresholds 1.5x / 2% share (`v_thr`, `v_floor`) drive
the PL/SQL "Reads as:" (`p.vc-rd[data-vk]`) and `lib_ls`; no scoring. Payload
`AWR_DATA.volcost = {thr, top, sql:[item], ev:[item]}`, item `{n, l (link id
or ""), r (own row id vc-sq-/vc-ev-), ec, ep, pc, pp, tc, tp, k (cost u/d/e +
category m/s/b), g (label rank)}`, placed items only, one PUT_LINE each.
Client (`js_volcost`): `section.vc-on` hides nothing with JS off; `data-mode`
sql|ev + `[data-vk]` swap the axis titles / strips / sentence; log2 domain
clamped to +-14; dots tabindex 0, Enter -> `AWR_goTo` (the 06 / 04 row, else
its own table row); labels `pointer-events:none`; reuses `#tip`. Links only to
emitted rows: `sq-elapsed-` when the statement was 06's top_n somewhere.
Unexercised: two events that slug alike (anchor_uniq `-2` on the vc-ev id; the
we- link reaches 04's first), the no-valid-prior path, RAC.

#### Plan shape (`sql/23_plan_flame.sql`, lib base `planflame`)

Lib row `--os:13` (`lopen` when a top-N statement changed plan). Picks <= 3
Current top-N statements (06's elapsed ranking) whose last non-zero SQLSTAT
plan differs from the prior valid windows' modal plan (tie: most recent); none
-> one statement (first of the top 3 with a plan and >= 5 Current ASH samples,
else the first). One ASH scan (sql_id IN 3 binds, valid_windows snap ranges,
Idle dropped) by window / phv / line / class. Old plan divided by prior
windows with samples. DBA_HIST_SQL_PLAN via OPEN ... FOR with binds (not in
the README grant list; -942 / -1031 -> note + per-line tables); copy with
latest id-0 TIMESTAMP wins. Plans > 60 lines keep sampled steps + ancestors,
the rest fold into "+ n steps" rows. Line-less samples -> root. Payload
`AWR_DATA.planflame = {spw, min, mode, st:[{id, sql, p:[{r, phv, div, n, nol,
lines, state, s:[[id, pid, op, opt, owner, obj, self, {class:n},
hidden]]}]}]}`, strings comma-free (`,`) for put_clob_chunked. Block id
`anchor_id('pf', sql_id)`, h3 `ent()` -> `sq-elapsed-`. JS: own tooltip
`.planflame-tip` (js_timeline's #tip is hidden by its own mouseover), chain
folding past 14 rows, cut at 18, slivers <= 30 % of width, roving focus, Enter
-> AWR_goTo(table row), adds `a.pf-cl` "Plan shape" to `#f-plan-<sql_id> .evl`
on DOMContentLoaded. Unexercised: RAC, multi-DBID, real ORA-01031, the 18-row
cut.

#### Onset (`sql/25_onset.sql`, `sql/lib/onset_cte.sql`, `js_onset`)

"WHEN did it start": a continuous series over the report span for 7 fixed
metrics (template-independent), one point per snapshot interval (median pair
span, widened past 3000 points), each pair's rate spread over the buckets it
overlaps; a pair > 1.9 intervals or a bucket < 50% covered is a gap. ONE SQL
scan (onset_cte: snaps -> pairs with the restart guard -> SYSSTAT / time-model
deltas with the prev_snap_id match); the normal (median / PERCENTILE_CONT per
(metric, phase, excluded period), cached) and the change-point scan are PL/SQL
-- a SQL self-join with an OR join into a UNION ALL view ran 7 min on dbmint.
Normal: hour of week (>= 21 days) -> hour of day (>= 3 days) -> flat (points
before the Current window), stepping down when < half the points can be
judged. `cusum_scan`: two-sided CUSUM of clipped z against the current level,
k 0.5, h 5; on a crossing it records a step and restarts from the new level
(median z from the onset, at least k beyond). Runs of same-side levels; the
last run is OPEN when the Current median z agrees. The sentence (+ lib_ls) is
PL/SQL; `span.onset-mk` is filled client-side with the nearest release marker
within 6 h. Payload `AWR_DATA.onset = {t1, bm, nb, tc, mode, k, h, lead,
m:[{n, u, d, st, on:[onset, base, dir], cl:[onset, end, dir], sp:[[onset,
found, dir, level*10]], x, md, s, c}]}` (bucket indices oldest first, empty
slot = no value, c = CUSUM x 10, S- negative), via put_clob_chunked. `lopen`
when a shift is open. Twin: s25_onset.py (Release 4.2 -> onset at the marker,
on top of 4.1). Unexercised: the no-open-shift / closed-lead sentence in the
final code, widened buckets, RAC, multi-DBID.

#### Window similarity (`sql/26_window_similarity.sql`, `win-sim`)

Is the baseline sound? 07's per-window recompute verbatim (one query: unified
rows + analytic AVG / STDDEV / COUNT, Current wait total, each window's wait
total), robust-scaled vectors of the canonical, material metrics, a capped
mean-absolute-difference matrix (PL/SQL, BINARY_DOUBLE), odd-one-out rule,
then groups (connected components of flagged windows alike each other, `odd =
2`). Suggestions: 1 = every single odd window, then one per group (at most 4);
each re-scored in PL/SQL (`score_set`). Payload `AWR_DATA.winsim = {cap, thr,
medd, cv, nvec, w:[{o,v,dd,odd,top}],
m:[{d,n,l,k,dir,p,a,sh,g,pb,sb:[..],vec,md,sp,lk,v:[..]}], dm:[[..]], cb,
sug:[{k,drop,chg,ca}]}`, oldest first like AWR_WIN; `dm` row i = distances to
windows 0..i-1; one PUT_LINE per metric / matrix row. **`bucket()` in
`js_winsim.js` twins `policy_bucket()`** -- keep in lockstep; on load it
compares every metric with `pb` and each suggestion with `sb[s]` / `chg` /
`ca` and `cb` with its own card count, and console.errors a mismatch
(`window.AWR_WINSIM.check`, section attribute `data-winsim-check`;
verify_report fails on it). Links in the what-if are PL/SQL `ent()` HTML
(`lk`). Matrix: SVG up to 60 windows, a canvas past that (colours resolved
through a probe element, redrawn on `awr:theme`). Own tooltip `.winsim-tip`
(js_timeline's document mouseover hides `#tip`). The per-window table is
`data-nocount` (its flagged rows are `winsim-fl`, not `warn`, so no
section-header count). Section time on dbmint: 0.8 s for 8 windows, 1.8 s for 168.
Unexercised: RAC, multi-DBID, non-comprehensive templates.

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
chronological axis; `hour_label` is the hour's START. In v1.6.0 it shows in the
Timeline and All sections views (`vw in-t in-a`) and is an evidence-library
row in Summary (row text names the day-wide shifts; never auto-opens). The section's heatmap
is **signed** z (diverging ramp), unlike 07's |z|. **Metric picker
(v1.6.1, owner request):** the old `<select id="day-profile-sel">` is gone;
`div.dpk#day-profile-pick[role=tablist]` holds one `button.dpb[role=tab]
#dpb-<i>` per stat (roving tabindex, `aria-selected`, `aria-controls=
"day-profile-line"`), each with the stat name (`.dpn`) and an indicator
line `.dps`: a dot `.dpd.crit|warn|ok` (any large / any moderate hour /
none), the counts ("6 large", "2 large · 1 mod.", "▲ day-wide, 23 h",
"not flagged" when |z| > 2 but no hour is large / moderate: immaterial,
improved or noted; "normal") and the signed z of the largest |z| (`.dpz`); the title spells it
out. Per-stat `v_lg` / `v_md` / `v_zx` come from pass 1. The script's
`pick(i, focus)` sets the tab state, redraws the line chart and bolds the
heatmap's row label (`ylab()`: an `axisLabel` formatter + `rich`,
re-applied on `awr:theme`); Left / Right / Up / Down cycle, Home / End;
the heatmap's y-axis labels are clickable (`triggerEvent`), a cell click
picks its stat too (and flashes the hour row, as before). It sits inside
the `.chart-wrap`, so `body.no-charts` hides it with the charts (the table
keeps every number). Twin `s16_day_profile.py` (the script lines are
lifted literally, the buttons hand-ported). **Byte-identity at 0:**
the section emits only its two `AWR-SECTION` markers (no `<section>`), the
rail link, the Timeline jump-nav link and the About note are `CASE … ELSE ''`, the
fleet band and the drill command's 12-slot tail are likewise guarded. The
fleet band is **informational**: no `FLEET-COUNTS`, no score/sort impact.
Table rows carry `class="crit|warn"` (rail dot grading) but no `data-imp`.

### SQL Monitor (`sql/18_sqlmon.sql`)
Template-independent, always on (like 13-16, but unlike 16 it still renders
a one-line note when empty rather than staying silent). Source:
`DBA_HIST_REPORTS` where `component_name = 'sqlmonitor'` — one row per
persisted execution, `key1` = sql_id, `key2` = sql_exec_id, `key3` =
sql_exec_start as the **string** `'MM:DD:YYYY HH24:MI:SS'` (numeric-only, so
NLS-safe, but parse it with an explicit `TO_DATE(key3,'MM:DD:YYYY
HH24:MI:SS')` mask — never trust it as a DATE). `report_summary` is a
VARCHAR2 XML parsed via `XMLTABLE('/report_repository_summary/sql' ...)`;
`dbid` is the CDB dbid, so `dbid IN (dbid_list)` applies unchanged. The
section reads only `DBA_HIST_REPORTS.report_summary` — `DBA_HIST_REPORTS_DETAILS`
(the multi-KB per-execution plan CLOB) is never touched.

**Noise floor** is at the sql_id level, not per-execution: a sql_id is
included in the comparison table only if ANY of its captured executions in
the full compared span has `elapsed_time >= 1,000,000` microseconds, OR
`status = 'DONE (ERROR)'`, OR shows more than one distinct non-zero
`plan_hash` — then every execution of that sql_id is aggregated (no per-exec
floor). This keeps a lightly-loaded instance's table from being dominated by
tiny parallel-execution noise (SQL Monitor's capture policy always persists
parallel statements) while never hiding a real regression. The **execution
scatter** chart plots every captured execution in the full span regardless
of the floor — the floor only shapes the summary table and its
Current-window-max-elapsed ranking. It is capped at 3,000 points: the
executions that start inside a compared window first, then the most
recent (plan 037; `in_win` in the one `DBA_HIST_REPORTS` scan, computed
arithmetically from the nominal window grid -- `MOD(target_end - start -
0.5 s, step) < win`, the half second making it `[start, end)` and keeping
NUMBER rounding off the edge -- never a join to `windows_rollup` or a
second read; the twin's `in_win` is the same rule), so every compared
window keeps its points (the demo: 10 of 13 windows were empty under
"most recent only"). Its marks: size `4 + 2 log2(DOP)`, at most 12 px; points in the Current window,
errors and plan changes solid with a theme-independent dark outline, the
rest faded (grey "Other" fainter and drawn underneath; the legend
chips stay opaque, `legend.itemStyle.opacity` 1); the x-axis is
pinned to `spanStart..spanEnd`, so a window without captures shows as an
empty band. `series[0]` carries the window `markArea` (the `awr:window`
listener addresses it by index); verify_report's phase 4 `scatter` check
reads the mark size and the axis range.

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
(each statement row is paired with a detail row right below it).
`tr[data-sk]` (0 large, 1 moderate, 2 rest) on top-N rows; an inline
script after the table moves each statement row with its detail row so
flagged ones come first — the loop and `rnk` stay in Current max elapsed
order. Cost: the
section plus R6-R9 scan `dba_hist_reports` (with `XMLTYPE` parsing) seven
times over the span — fine at thousands of rows, worth a single BULK COLLECT
if a busy DB ever makes it slow.

**Opt-out (`sqlmon`, env `SQLMON=N`).** The driver resolves `~sqlmon_on`
(`'N'` only for a falsy form, else `'Y'`) and `~sqlmon_include` =
`sql/18_sqlmon.sql` or the stub `sql/lib/no_sqlmon.sql` (only the two
`AWR-SECTION` markers, so the pair count holds: 29 pairs since sections
20-28, 20 before); 00 drops the rail
link, 17 wraps its R6-R9 scans in `IF '~sqlmon_on' = 'Y'` (body not
re-indented), 19's About meta line says "SQL Monitor skipped". 06's MON
xlinks are hidden by the chrome (missing target). `sqlmon=Y` output is
unchanged. dbmint AUTO weekly 1/4: 84 s on, 9 s off (2026-10-08). The
fleet's `06b_sqlmon` band is not affected (detail runs load
`sql/defaults.sql`, so they keep SQL Monitor on).

**Plan-hash column.** The per-statement table's "Plan hash" column (right
after "User / module") compares `cur` = the plan_hash of the Current
window's slowest execution (falling back to the most-frequent non-zero
plan_hash in the Current window when that execution's own plan_hash is 0)
against `prior` = the most-frequent non-zero plan_hash across the prior
*valid* windows (tie → most recent `exec_start`); a mismatch renders a
`badge warn "plan changed"` with `<s>prior</s> &rarr; <b>cur</b>`, matching
the existing "plan change" chip which now reads "plan changed" and carries
the differing-plan title when this column fires. The per-window sub-table's
"Plans" column became "Plan hash(es)": the distinct non-zero hashes seen in
that window, most frequent first, capped at 5 with a trailing ellipsis.

**Fleet band (`sql/fleet/06b_sqlmon.sql`, always on).** Fleet-owned copy of
the "new"/floor logic (never edits the single-DB file), called from
`awr_fleet_extract.sql` right after `06_day_profile` and before `07_close`,
its own `AWR-SECTION: fleet_06b` markers. Cheap summaries only — it never
reads a `DBA_HIST_REPORTS_DETAILS` CLOB. Renders a `.detail-block` "SQL Monitor" band: executions in
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
(oldest→newest), emitted as `data-spark="…"` (micro strip; the fleet's line sparkline), `data-v`
(window component / Timeline, oldest first, via `wg_tok` / `tl_csv`) or JSON on
`window.AWR_DATA` (ECharts + `ashx`). Numeric CSV forces `NLS_NUMERIC_CHARACTERS='.,'` so
`Number()` parses under any NLS. The micro strip floors σ at 2% of |mean| (the
policy's floor), the fleet sparkline has a 2% flatness floor (midline instead of
magnified noise). Sections that re-grid one column per week
(06 excepted: one cursor row per window, see the per-window gotcha)
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
(siblings: `awr:window`, `awr:view`); every chart-init registers a listener that
re-reads those vars and `setOption`-merges the color-bearing options. Sections
with ECharts (v1.6.0): 04/05/06×2/09/10/11/14/15/16/18, each with a small
merge-only listener (the v1.5 masthead chart and 07's charts are gone). The
v1.6.0 SVG/CSS components (band, micro strip, window grid, Timeline, full-span
ASH chart) read CSS variables at paint time, so they follow the theme without a
listener; their JS re-renders on `awr:view` / resize only. **Section 11 registers the listener
*inside* its per-chart `forEach`** so each chart binds its own instance (a
single outer listener would capture only the last chart). Since plan 035 that loop is `initChart(c)`, called on
demand (throttled scroll / resize / `awr:view` / click / `load` /
`beforeprint`, never IntersectionObserver); `hiNow` carries the
`awr:window` slot to charts drawn later, and `noAnim` draws the
`beforeprint` ones without the initial animation (else the print gets
its first, empty frame). New charts must add an
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
the per-sec consumers (00/02/07/08, and 04's Timeline event rows through one
`MAX(dur_sec)` per `week_offset`) sum the cross-instance delta and divide by
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
`info` is the rank-chip / informational badge class (not a bucket). The band
glyph maps buckets to `.bd.s-large|s-moderate|s-improved|s-typical` (+ `.s-flat`,
`.na`) via `band_sev`, and the Δ span to `.d.s-*`. A new bucket must update
`policy_bucket` (`metric_policy.plsql`), `band_glyph.plsql` (`band_sev`,
`band_span`, `band_cells` notes), `finding_cards.plsql` (`sev_rank`),
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
02 / 03 (their own rows), 07 (PL/SQL pass 1 -- the SQL CTEs only compute
z / pct / share now), 08 hero strip, 16 (re-buckets every `day_profile_cte` cell), 17 `big()`,
and `score_cells.plsql`'s `score_bucket` / `score_cells(cur, mu, sd, n,
share, domain, name, class, demote)` for 04/05/18. **Include order:**
`metric_policy.plsql` must precede `score_cells.plsql` (lint check 13),
and a `policy_rec` variable must be declared AFTER the include. lint check
12 verifies every template LOAD/METRIC name has a policy line.
`day_profile_cte.sql`'s own CASE still carries the plain 07-style rule
without direction but no consumer reads it any more (16 and fleet 06 both
re-bucket per cell); the fleet findings band, row, headline cards and
day-profile band (`sql/fleet/04`, `01`, `03`, `06`) call `policy_bucket()`. `improved` / `noted` are
never highlighted: class `imp` / `note` (outlined badges, no row marker),
never a card lead or member, not in the verdict count / rail pills / J-K
jumps; they are listed under 07's "Checked and normal" ("Improved"). A non-canonical twin is scored and rendered
(`tr.twin`, muted) but never counted. `demo/awrdemo/helpers.py` PARSES
`metric_policy.plsql` (regex over the `WHEN 'name' THEN RETURN pol(...)`
lines), so keep that one-line shape when editing.

### Findings are recomputed, not shared
Sections 00 (verdict), 07, 08 and 17 each recompute their own z-scores (02/03
bucket their own rows through `policy_bucket` too). The LOAD/METRIC/WAIT target
lists are single-sourced per template and `@@`-included by 02/03, 04/05, and 07.
Inside 07, the unified recompute is `BULK COLLECT`-ed once into a record
collection tagged via `ROW_NUMBER()`; the finding cards, "checked and normal",
the Timeline metric / wait rows and the detail tables all walk that one
collection — don't reintroduce a second recompute cursor just for a different
ORDER BY. The verdict (00) and the cards (07) must order cards identically
(`card_before_imp`).

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
  DB as a `window.FLEET_ASH[<alias>]={t0,bh,k,classes,vals}` JS payload
  (NLS-pinned numbers; `bh` = real bucket hours, consumed by the renderer for
  marker positioning and x-label cadence — HH:MM labels for spans ≤48h, MM-DD
  HH:MM beyond). **Compact form (file-size work, 2026-11-13):** `vals` holds
  INTEGER sample counts, a run of n ≥ 2 empty buckets is the single token
  `-n`, `k` = 360 × bucket hours; the renderer's `ashDec()` expands a payload
  once to plain AAS arrays (no `k` = old AAS form). Same for `FLEET_ASH_EV`.
  `FLEET_PROFILE` is compact too: no trailing zeros, a NULL cell is an empty
  array slot (`[,,1.5]`, reads as undefined), `sev` is one string per stat
  with a base-36 digit per hour indexing `sk` (the bucket names). dbmint, 3
  DBs, 7 daily windows + 7 profile days: 287 KB → 200 KB, payloads 124 KB →
  37 KB, decoded values / SVG / tooltips identical to the old form. The renderer draws it into `data-ash-of` divs — ribbon mode in
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
  `{t0,bh,k,classes,vals}` shape: the top 14 events by total samples (tie-break
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
  progress marker shown in the report and a stderr hint), `FLEET_DETAIL_TEMPLATE`, `FLEET_DETAIL_DESIGN` (the detail report's `design`, default classic),
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
- **Co-anomaly grid (v0.8.0, `#coanom`)** -- above the console table: DBs x
  time buckets on one absolute axis, so a cause several databases share
  (storage, network, host, batch window) lines up as a column. The assembler
  emits only the skeleton + `window.FLEET_COANOM={rows:[[alias, isErr],...]}`
  (error rows in conf order, then OK rows score-desc);
  `sql/fleet/js_fleet_coanom.plsql` (in the chrome, GENERATED from
  `sql/fleet/src/js_fleet_coanom.js` / `css_fleet_coanom.css` by `sh
  sql/fleet/src/fleet_js2plsql.sh [--check]`) derives every cell in the
  browser from `window.FLEET_ASH` -- no extract change, no FLEET-COUNTS, no
  score / sort / exit-code impact. Rules: resample to the coarsest `bh` in the
  fleet (time-weighted, < 50% covered = no data); per DB a robust z of total
  AAS vs median / MAD of the same hour of day (span >= 3 days and >= 3 buckets
  for that hour) else of the whole span, sigma = max(1.4826 MAD, 20% of
  median, 0.05 AAS); raised z >= 2, far out >= 3, extreme >= 6; rises only. A
  bucket is shared when >= 25% (and >= 2) of the DBs with data are far out;
  runs of shared buckets = episodes, the biggest (count, then summed z) is
  named in `.ca-sum`. Clicks open rows through `window.__fleetSetRowOpen`
  (exported by js_fleet_charts); a shared bar emphasises its DBs
  (`.ca-row.dim`, `tr.dbrow.ca-hit`); Esc clears. JS off / older chrome on
  `--assemble`: `p.ca-nojs` stays. Unexercised: a real heterogeneous multi-DB
  fleet.

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
(contract: `demo/PORTING.md`; `demo/awrdemo/helpers.py` twins every shared
PL/SQL lib: band glyph, anchors, card vocabulary, `wg_*`, `tl_*`, `lib_ls`).
s09's `fine` payloads are SYNTHETIC (seeded minute profiles spread each
hour's samples by largest remainder, so window sums stay exact) and its SQL
lines are sliced by anchor, not index. **When a section's markup/JS changes,
re-port its twin in the same commit and regenerate**; generation is deterministic (two runs, same md5), and identical across Python 3.12-3.14 because `helpers.mean_sd` (and the model's physical-reads total) use `math.fsum` (the built-in `sum()` of floats differs by an ulp between versions, which once reordered tied rows in CI).
`tools/check.sh` (CI) fails when either generated page is stale
(`gen_demo_report.py --check`, `gen_policy_doc.py --check`). `NODE_PATH=<any
node_modules with playwright> node demo/verify_report.js <html> [shots/]` is the
headless smoke test (bundled Chromium, else system Chrome): 0 console errors in
3 views × light/dark, every in-page href resolves to exactly one id, every
visible `a.ent` clicked through, view switch / persistence / rail dimming,
Timeline lanes + `data-tl` jumps + label links + chart hover / legend / zoom /
reset / pin / Esc, the series highlight (legend hover re-base, class ->
events, event -> class, focus, sticky, Esc order, click to keep -- at a
band point under no stripe's hit area: when the windows tile the span, as
169 hourly ones do, every x is a full-height stripe, so it zooms into the
busiest window first; the demo must not need the zoom), the Day
profile picker (click / arrows / Home / End; required for the demo), plan
cards, library rows, rail sub-links, All sections completeness (`allFull`:
each library section's first chart or table holding a data row is visible),
micro strips. The legend / highlight steps park the pointer BELOW the chart
(x 2), never above it: above the event chart is the class legend, and a
hovered legend entry re-scales the chart. ~3 min per report; **one instance at a
time** (parallel runs hang Chrome). It works on any report, dbmint's included.
The "No Python" rule applies to the toolkit, not to this docs tooling --
nothing under `sql/`, `awr_trend.sql` or the wrappers may depend on `demo/`.
`docs/gen_policy_doc.py` (same rule) renders `docs/metric_policy.html`, the
human-readable reference of every metric's direction / floors / "fires
when" from `sql/lib/metric_policy.plsql` (it imports the demo's policy
parser); **regenerate it whenever the policy file changes**, together with
the demo.

## Verification & testing

- **`./tools/check.sh` is the one command** (CI runs exactly this on every
  push to `main` and every PR): `./lint.sh`, `bash -n` on every tracked
  `*.sh`, a strict parse of every tracked `*.py` (a `SyntaxWarning` fails),
  the server unit tests (`python3 -m unittest discover -s server/tests
  -t .`) and the client JS unit tests (`node tools/js_unit_tests.js`: the
  pure helpers of `sql/lib/src/*.js` under a stub window / document;
  skipped without node). No DB needed, about 5 s.
- **`./lint.sh` first** (also runs in CI): grep-based checks that encode the
  footguns below — bad `@@` include paths, flat template-target includes,
  stray `~word` substitutions (the tilde gotcha), `dbid = ~dbid` equality,
  leading-underscore identifiers, literal-7 cadence, missing `SET DEFINE '~'`,
  incomplete template dirs, GNU-only tool flags in the bash wrappers
  (`grep -o`, `sed -E`, `find -maxdepth`/`-print0`, unguarded `date -d` —
  they break on AIX/Solaris DB hosts and GNU-coreutils dbmint never catches
  it; twice bitten 2026-07-22), the `listagg-null-token` pattern, fleet
  detail-link naming (11), a policy line per template name (12), include
  order (13 metric_policy → score_cells, 16 metric_policy first, 17
  fmt_num → band_glyph → score_cells, 20 fmt_num → wingrid / finding_cards,
  22 the timeline.plsql chain), PL/SQL declaration after a subprogram (14),
  the `share` reserved word (15), and for v1.6.0: the retired view hooks
  (18: `data-normal`, `full-only`, `"awr-mode"`, `data-dev=`, `dev_attr(`),
  a `<section id=` without `class="vw ` (19), a hand-written `class="ent"`
  (21), `tl_open` without `tl_close` (23), a stale generated client script
  (24: `tools/js2plsql.sh --check`) and any non-ASCII byte in emitted
  single-DB text (25); from the v1.6.0 review: a SYSSTAT `'DB CPU'` read or
  a template LOAD read bypassing `load_pairs_cte.sql` (26), a scoring
  section reading wait events without the template's wait list (27), a
  day / month name `TO_CHAR` without `NLS_DATE_LANGUAGE` (28), `off_label`
  missing / after `wingrid` (29), `anchor_id('fl'|'pa', ...)` outside
  `anchor_id.plsql` (30), a comparison with `''` (31: `<> ''` /
  `!= ''` is never TRUE), a `border-left` / inset shadow on a rail
  link state (32), a `viz_head.sql` include that does not exist or a stale
  fleet co-anomaly script (34), and a static read of an optional-grant view
  (35: `DBA_HIST_EVENT_HISTOGRAM` / `DBA_HIST_SQL_PLAN` outside dynamic
  SQL). No DB needed; add a check when a new
  gotcha bites. A `finding` inside a `| while read` loop must go through
  `finding` (it records to a flag file; a subshell `fail=1` is lost).
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
  rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex \
    --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'
  # NEVER --delete: it wipes the untracked fleet.conf on dbmint
  sed -E 's/run [0-9]{17}/run RUNID/g;
          s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{2}:[0-9]{2}/TIMESTAMP/g' \
    "$1" | md5
  ```
- **Coverage so far (dbmint = single-DBID, 19.27, idle):** single-DBID
  byte-identity of the window-validity / SYSMETRIC / cross-DBID / snap-to-grid
  refactors; sections 13/14/15 and every 06 dimension run clean; the
  (since removed) "Application only" and Essential toggles, the workbench rail/scrollspy,
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
  "Other events" rollup -- the single-DB Activity chart's rollup IS
  exercised on dbmint and in the demo); RAC per-instance `dur_sec`; a migrated PDB
  (multi-DBID); a genuinely slow DB against the 3600-s detail timeout; the
  "no snapshot within 15 min of edge" skip reason (restart wins the CASE on
  dbmint); a series name containing `\`; the no-AWR-history-at-all branch of
  the `target_end` snap; the fleet "Compared windows" `part` and
  snap-mismatch states (all dbmint aliases hit one instance).
- **dbmint keeps 35 days of AWR** (`DBA_HIST_WR_CONTROL`), so every pinned
  `target_end` quoted in this file expires: the September / October dates
  below return all-empty windows now. Probe first (snapshots per day and
  per `startup_time`, ASH rows per hour) and pin inside a restart-free
  stretch; on 2026-11-19 that was 2026-11-07 14:45 to 2026-11-09 16:15
  (`"2026-11-08 15:00" 1 8 10 0 1 h` = a heavy blocking hour against eight
  quiet ones).
- **Visualization sections 20-28 + fleet co-anomaly grid verified on dbmint
  (2026-11-19):** each section by its owner on its own runs (numbers
  checked against an independent read-only query: DB time, ASH per plan
  line, blocked samples and final holders, histogram bucket counts,
  SQLSTAT executions / elapsed), then the merged branch: 13 runs, all rc 0,
  29/29 `AWR-SECTION` pairs, no `ORA-` / `SP2-` / `PLS-` in the logs, max
  line < 32767 -- the incident hour with markers (29 s, 18 s of it section
  18; each new section under 1 s), `DESIGN=quiet` / `dashboard`, the
  incident in the prior windows (24 hourly), `simple` and `dev` templates,
  a plan change (`"2026-11-08 11:00" 1 8 10 0 1 h`: b84c2ncqhcw23), 48
  hourly windows with skipped ones, 2 daily windows (the too-little-history
  notes), 168 hourly windows (81 s), overlapping windows (2 h every 1 h),
  `AUTO` weekly, `profile_days=7`; a fleet run with `FLEET_DETAIL=all
  FLEET_PROFILE_DAYS=7` (3 detail reports, 58 markers each, `#coanom`
  present, no `__FLEET_`). verify_report OK (incl. its section 8: every
  view drawn, the instance map vs the cards, the what-if's JS rule vs the
  PL/SQL buckets, 390 px) on the three demo designs and on the incident
  and the thin-history report. The missing-grant branch of 22 / 23 was
  simulated (a non-existent view name in a scratch copy): note shown, rc 0.
  Never exercised: RAC, multi-DBID, a real ORA-01031, a real heterogeneous
  fleet for the co-anomaly grid (synthetic 1 / 3 / 12 / 40 DBs), the
  onset's "no open shift" sentence, 26 under a non-comprehensive template's
  what-if beyond the bucket self-check.
- **v1.6.0 verified on dbmint (2026-09-27), final code incl. the nine
  review fixes:** a `nohup`'d runner on dbmint (rsync without
  `--delete`, output `reports/v160/`). Matrix, all rc 0 with 20/20 `AWR-SECTION`
  pairs: pinned hourly `2026-09-18 12:00` 1/4/1h under comprehensive /
  simple / dev (~10 s each); plan-change `2026-09-08 23:00` 1/8/1d (plan
  card as2dr3ag24gay 811755146 -> 2628649851 "new plan since 7 Sep",
  likely source = that statement); daily 2/7/1d; `AUTO` weekly 1/4 (94 s
  to 160 s; 18 dominates); markers + `profile_days=7` with `debug=Y` and
  `debug=N` back to back (identical md5 after the byte-identity `sed` plus
  the bare run id); `ECHARTS=vendor/echarts.min.js` inlined (all http(s)
  blocked: 19 ECharts instances drawn, 0 errors) and the hourly report
  with the CDN blocked (`no-charts` + banner, grid / strips / ASH present,
  pin / Esc OK); the pure-SQL\*Plus heredoc; a fleet run with
  `FLEET_DETAIL=all FLEET_PROFILE_DAYS=7` (the day-profile DB CPU row now
  has values) plus one on a busy window (`2026-09-22 13:00` 1/7/1d: crit
  16 / warn 1, the `table.dt` 3 px red / amber bar in both themes); stress
  `weeks_back=52` weekly `AUTO` (109-184 s), 168 hourly windows (152-225 s,
  18 MB),
  an overlapping grid (win 2 h every 1 h). The CPU / wait split fired on
  two busy windows (`2026-09-22 13:00` 1/7/1d: "DB time 28.3x normal,
  mostly CPU"; `2026-09-10 12:00` 1/7/1d: "DB time 180x normal, all
  wait") and every DB CPU / DB time value matched a read-only
  `DBA_HIST_SYS_TIME_MODEL` spot query to the digit. `ORA-` hits are all
  captured SQL text (a top SQL's text / tooltip naming `ORA-200nn` or
  `ORA-01014`, section 06's own PL/SQL comment captured as a top
  statement). verify_report OK on every report (one Chrome at a time) and
  a 3 views x light / dark visual pass of the plan-change and hourly
  reports: no "???", no broken layout. That pass found and fixed: the dead
  `IS NOT NULL AND x <> ''` guards (lint 31, see the gotcha), the plan
  card's monospace evidence and unit / number line breaks, a clipped long
  segment name in the Timeline, browser-blue links in the "too little
  history" hero (an AUTO run with 3 of 4 valid windows; the demo never has
  it), and verify_report's micro-strip check past 91 windows. Still never exercised: a plan-change statement with no
  Current SQLSTAT row (SQL Monitor fallback), > 3 plan cards, RAC,
  multi-DBID top bar, the fleet `plan↑` badge (no fleet Top SQL row on
  dbmint).
- **Activity charts on top (v1.6.0 follow-up) verified on dbmint
  (2026-09-27):** `reports/ashtop2/` (the v160 runner with `ASHTOP_OUT`,
  168-hourly now `debug=Y`): pinned hourly `2026-09-18 12:00` 1/4/1h,
  plan-change `2026-09-08 23:00` 1/8/1d, the busy wait `2026-09-10 12:00`
  and CPU `2026-09-22 13:00` windows (1/7/1d), `AUTO` weekly, 168 hourly
  windows (19 MB) and fleet runs with `FLEET_DETAIL=all` (quiet and busy
  window): all rc 0, 20/20 `AWR-SECTION` pairs, `ORA-` hits only in
  captured SQL text, no `__FLEET_`; verify_report OK on every report (one
  Chrome at a time) incl. both charts' hover / mirrored crosshair /
  legend / linked zoom / reset / pin. Real "Other events" rollups on
  dbmint (14 events + Other on every run but the pinned hourly one, 12
  series there); the class and event charts stack to the same totals
  within the 3-decimal rounding. Section 09's time (debug markers):
  AUTO 0.20 s before, 0.11-0.24 s after; 168 hourly 0.35 s before,
  0.28-0.40 s after (noise; the extra event grouping costs nothing
  measurable). Fleet `table.dt` first cells 10 px padded, the 3 px bar
  intact (busy window, both themes).
- **Fine-grained Activity charts verified on dbmint (2026-09-27):**
  `reports/ashgran/`: pinned hourly 1/4/1h, 15-min cadence (`0.25 16 ... 0.25
  h`: `bh` 0.25, 10-min ticks), busy CPU `2026-09-22 13:00` 1/7/1d, `AUTO`
  weekly 1/4 (673 hourly buckets) and 52 weekly (8738 hourly buckets, 13 MB,
  section 09 about 1 s): all rc 0, 20/20 pairs, max line < 32767, `ORA-`
  only in captured SQL text; verify_report OK (its grid-hover check now
  picks a cell not under the sticky labels).
- **v1.5.0 / fleet 0.7.0 verified on dbmint (2026-09-22):** built without
  a database on 2026-09-21 (synthetic demo + Playwright + the 137-test
  server suite), then run against dbmint: pinned hourly window
  (`target_end='2026-09-18 12:00'` win=1h weeks_back=4 step=1h, all three
  templates, `profile_days=7` and the since-removed `sqlmon_detail=3`), a daily-cadence run
  (win=2h weeks_back=7 step=1d) and an `AUTO`-weekly run; a fleet run
  with `FLEET_DETAIL=all FLEET_PROFILE_DAYS=7`. All: 0 ORA-/SP2-, every
  `AWR-SECTION` BEGIN/END pair present, no `__FLEET_` placeholder;
  browser pass (Chrome) on the Normal/Full switch, rail "+ N more in
  Full", chip click inside the folded `<details>`, zero-width-chart
  resize on Full, fleet row expand / bands / detail link, 0 console
  errors. Five compile/runtime bugs surfaced and were fixed in that pass
  (all now lint-guarded, checks 14-16): `share` is an Oracle reserved
  word (record field renamed `shr`); variables declared after a
  subprogram include (00/02/03/07/17; `metric_policy.plsql` opens with a
  TYPE so it must be the first subprogram-declaring item and after every
  plain variable, and a `policy_rec` variable can only live in a nested
  block); and 18's execution-scatter query, whose
  mode-plan `LEFT JOIN` the optimizer pushed into a nested loop that
  re-parsed every report's XML per outer row (hung >10 min on the
  4-week AUTO span; now one scan + analytics, ~60 s there). dbmint is
  idle, so `improved` / `noted` / a firing "What changed" block and the
  04/05 table-wide-shift note were NOT seen live (17 emits nothing on a
  quiet DB by design); the demo remains the only place those render.
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
  degrade via `body.no-charts`. The v1.6.0 components (band, micro strips,
  window grid, Timeline, the Activity charts, guide) stay inline SVG/CSS.
- Don't bring back the v1.5.0 view hooks (`data-normal`, `.full-only`,
  `awr-mode`, `data-dev`) or a section without `class="vw in-*"`; and don't
  drop a number from All sections — views change presentation only.
- Don't hand-write an entity link or an anchor id: `ent()` + `anchor_id` /
  `finding_anchor` only, and only to rows that are emitted.
- Don't hand-edit the PUT_LINE bodies of `js_timeline` / `js_wingrid` /
  `js_microstrip` — edit `sql/lib/src/*.js` and run `tools/js2plsql.sh`.
- Don't delete `sql/lib/js_sparkline.plsql` — the fleet chrome still uses it.
- Don't widen the `README.md` grant list without a concrete reason.
- Don't reintroduce the literal `7` as the cadence multiplier — use
  `~step_hours/24`.
- Don't edit any single-DB file (`awr_trend.sql`, `run_awr_trend.sh`, numbered
  `sql/NN_*.sql`, shared `sql/lib/*`) to add a fleet feature — fleet code lives
  only in `run_awr_fleet.sh`, `awr_fleet_extract.sql`, `sql/fleet/*`, and
  `sql/lib/templates/fleet/*`.
- Don't end an inline `--` comment with `;` inside a top-level SQL statement
  (it terminates the SELECT → ORA-00936; harmless only inside PL/SQL blocks).
- Don't read `DBA_HIST_EVENT_HISTOGRAM` / `DBA_HIST_SQL_PLAN` (or any view
  the README's required grant list lacks) with static SQL: dynamic SQL in a
  handler for ORA-00942 / ORA-01031, or the whole report aborts for an
  analyst user (lint 35).
- Don't let a visualization section (20-28) add a finding, a count or a
  severity of its own, or score with anything but `policy_bucket()`; 27 and
  26 must agree with section 07.
- Don't add ECharts (or any external JS/CSS) to the fleet report — it is
  inline-SVG-sparkline-only and offline-complete by design.
