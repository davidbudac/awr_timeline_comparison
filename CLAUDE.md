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
awr_trend.sql            -- driver: prologue (CSS + client libs), SPOOL, sections, epilogue
sql/
├── defaults.sql         -- canonical DEFINEs for the substitution vars
├── _style.sql           -- embedded CSS (emitted once; ALSO @@-included by the fleet chrome)
├── 00_params.sql        -- top bar, rail, view switch + chrome JS, AWR_WIN, the Activity
│                        --   charts' skeleton (#activity, top of every view), verdict hero,
│                        --   Timeline skeleton (#timeline / #tl)
├── 01_windows.sql       -- aligned windows, snap pairs, restart guard
├── 02_load_profile.sql  -- SYSSTAT deltas (per template)
├── 03_sysmetric.sql     -- SYSMETRIC_SUMMARY averages (per template)
├── 04_waits_fg.sql      -- foreground waits + wait-class rollup (per template)
├── 05_waits_bg.sql      -- background waits (BG_EVENT_SUMMARY, per template)
├── 06_top_sql.sql       -- Top-N SQL ranked 5 ways + per-dim bump chart (ranked, not scored)
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
    ├── src/*.js              -- readable sources of the three generated scripts (tools/js2plsql.sh)
    ├── js_sparkline.plsql    -- inline-SVG line sparklines -- FLEET-ONLY since v1.6.0
    ├── js_wait_colors.plsql  -- shared wait_class palette
    ├── js_markers.plsql      -- inits AWR_MARKERS + AWR_markLine()
    ├── marker.sql / markers_inline.sql / no_markers.sql -- marker emitters
    ├── debug_log.sql         -- per-section progress markers (no spool pollution)
    └── templates/<name>/     -- comprehensive (default) / simple / dev (+ fleet/, fleet-owned)
        ├── sysstat_load_targets.sql
        ├── sysmetric_targets.sql   -- names + is_additive flag
        └── wait_event_targets.sql  -- single '*' row = "no filter" sentinel
tools/js2plsql.sh                   -- dev-time generator for the js_* .plsql bodies (lint check 24)
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

Thirteen user-facing vars, all DEFINEs (defaults in `sql/defaults.sql`):
`target_end` (`'AUTO'`=prior full hour), `win_hours`, `weeks_back`, `top_n`,
`inst_num` (`0`=aggregate across RAC, else filter to that instance), `step` +
`step_unit` (`'h'`/`'d'`/`'w'`; default `1`+`'w'` = same hour-of-week N weeks
back), `template`, `debug`, `marker_file`, `profile_days` (`0`=off; the 12th
and last wrapper positional), `markers`, `echarts`.

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
pre-snap instant; `00_params.sql` (verdict hero `p.snapnote`) and `sql/fleet/07_close.sql`
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
  in-a`, the first section after `<main>`, above the verdict; see
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
  Timeline lane / "+ Show N more"), opens a closed library row, clicks the
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
  (the lane links, hidden when a lane is empty; pills from row `data-sev`),
  Workload, SQL, Storage & config, Whole span, Reference (`#guide`,
  `#about`). The v1.4 row filter, status dots, count pills, J/K and the
  scrollspy are kept. A link's state (hover, `.on`) shows through its
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
| Verdict hero `section#verdict.vw.in-s.hero` | 00 | one rule-based h1 sentence (no free prose), `p#because-slot` "Likely source:" (17 fills), `ul#pills` (17 inserts before `li.pl-normal`), `ul#narrative-slot.hnotes` (17), `p.snapnote` (target_end snapped) |
| Hero strip `section#overview` | 08 | DB time (AAS) per window on the window component, `#hero-dbt`; replaced the six v1.5 headline tiles |
| Finding cards `#findings div.cards` | 07 | one `article.fc` per card group (below); header band glyph, big value, window bars, ≤4 evidence rows, related-metrics fold, footer `a.jump[data-tl]` "Timeline →" |
| `section#s-changes[hidden]` | 07 (`#changes-slot`) | 18's plan cards then 12's config card move in and unhide it |
| `section#s-normal` | 07 | "Checked and normal" `.ngrid` (≤18 `.nr`), "Moved, too small to matter", "Improved" |
| Evidence library `#s-lib` + `section.lib` | 07 heading, sections | see below |

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
shorter label. Order (`card_before`): large before moderate, then max |z|;
a flagged DB time card moves to 2nd. **00 (verdict) and 07 (cards) both
order cards — keep them in lockstep** (twin `helpers.card_order`). "N
findings" = number of cards; "metrics moved" = canonical large+moderate
rows. Units (`metric_unit/scale`): DB time / DB CPU / CPU used → AAS
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
`#f-config`, as the driver runs 18 before 12), `#because-slot` / `#pills` /
`#narrative-slot` / verdict `.vx[data-vx="io"]` / I/O card evidence
`[data-ev-for]` (17, which runs last). These scripts run BEFORE any
DOMContentLoaded handler (ent unwrap, chrome), so they must not depend on
them. JS off → the block stays hidden (every fact is also in its section).
17 with nothing to say emits only its two `AWR-SECTION` markers.

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
Parameters 9. All-only: 01, 05, 09, 10, 11, 13 ("+ 6 more in All
sections"). Row text: `lib_ls(id, html)` (`band_glyph.plsql`, twin
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
| waits | scored | 07 flagged wait classes; 04 Table A's first 16 events (past 10 `.more`, "+ Show N more") | `tl-fr-w-wait-class-<c>`, `tl-we-<event>` |
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
meta counts / folds / "+ Show N more" / rail pills, skipped windows struck
through in the ruler, prior values filled, the activity rows + DB time
card, the Activity charts, `AWR_WG.render(#tl)`. **Pin:** `AWR_WG.pin(o)` /
`pinned()` — `body[data-pw]`, `.pc` on `#tl [data-w=o]`, ruler buttons
`aria-pressed`, every gutter Δ re-based "vs <date>" (`data-orig` restores),
the stripe `.on` on both Activity charts; Esc, Current or the gutter's
"clear" unpin. A view switch KEEPS the pin (the Activity charts show it in
every view; before the charts moved to the top, leaving the Timeline
unpinned). Separate from the X2 `th[data-w]` highlight (`.hl` + `awr:window`).

### Activity, whole span (`section#activity`, top of every view)

The bird's-eye ASH view (owner request, v1.6.0): `section#activity.vw.in-s
.in-t.in-a.ashtop` is emitted by 00 right after `AWR_WIN`, before the
verdict hero, so it is the first section in every view (and with JS off).
Skeleton (static, lifted verbatim by the demo twin): h2 "Activity, whole
span" + `.h2sub`, `p.ax-nojs` (hidden under `body.js-wg`), `div#ashx.ashx
[hidden]` › `.axh` (`#ax-range`, the stripe key `.axk`, `#ax-reset`),
`#ax-empty`, two charts `div.axch#ax-cls` / `#ax-ev` (each `.axct` = small
h3 + its own legend `.axlg`, then `.axp` › `svg.axsvg` + `.axbr` brush),
`p.axn2`. The chart ids are `ax-cls` / `ax-ev`; everything inside is
addressed by class (the old single-chart `#tl-ash` / `#ax-svg` / `#ax-lg`
/ `#ax-plot` ids are gone).

**Payloads** (09, the SAME `DBA_HIST_ACTIVE_SESS_HISTORY` scan as 09's
ECharts chart; it groups by bucket, class, **event**, `j_lo..j_hi` = every
compared window the sample falls in — overlapping windows each count it —
and foreground flag; no second ASH scan):
- `AWR_DATA.ashx = {t0, end, bh, wh, classes, vals, win, winfg}` — by wait
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
- `AWR_DATA.ashe = {t0, end, bh, wh, classes, vals, win}` — the same shape
  by **wait event** (ON CPU = `CPU`, ranked like any event): the 14 events
  with the most samples over the span (ties: name ascending), biggest first
  = bottom of the stack, then `"Other events"` LAST = the class total less
  the top events per bucket / per window (integer samples, so exactly the
  rest; left out with ≤ 14 events). Names through `json_escape`. Same
  semantics as the fleet's `FLEET_ASH_EV` (`sql/fleet/02_ash.sql`), which
  stays its own copy.
Numbers via `RTRIM(TO_CHAR(ROUND(v,3),'FM9999999990D999'),'.')`.

**Client** (`js_timeline`, section 6): ONE chart factory — `mkChart(root,
payload, colours, opt)` + `draw(c)` — two instances in `CH`, sharing `SP`
(bucket times, the zoom domain, windows, `#ax-range` / `#ax-reset`). Per
chart: step areas (one `path` per series, painted top of the stack
first, each from the axis to its cumulative height; `bRange` / `bucketAt`
are O(1) on the regular grid; zoomed out past one bucket per pixel the
path takes one step per pixel column at that column's busiest bucket, so
spikes survive and a brush zoom shows every bucket; the tooltip reads the
exact bucket; ticks go down to 5 min, `bLab` names 15-min buckets), legend toggles restack / rescale, hover tooltip (time +
each shown series' AAS; a stripe's tooltip = that window's `win` values),
window stripes from `AWR_WIN` (`.cur` indigo / `.on` pinned amber / `.sk`
skipped grey; hit rects `.xwh[data-w][tabindex=0]`, click / Enter / Space
pin, Current unpins), release markers (flags in two tiers on the upper
chart, lines on both). Linked: a brush (≥ 5 px) on either sets the shared
domain and redraws both (the brush shows on both); Reset / double-click
(mousedown `e.detail >= 2`: a stripe click re-renders the SVG so
`dblclick` may never fire) reset both; the hover crosshair + bucket band
are drawn on both at the same x; `W.pin` redraws both. One time axis: x
labels only on the lower chart (tick marks on both), ticks counted from
midnight of the Current window's day, `padL` / `padR` fixed so the plots
align. Heights ≈ 180–200 px each (`ph` 150). Colours: classes from
`AWR_WAIT_COLORS`; events `evColors()` — CPU = the wait-class CPU green,
"Other events" = `#9AA3AD`, the rest cycle `EVP` (15 Tableau-like hues, no
green). A click on a stripe in Summary / All sections pins too
(the grid follows when you open the Timeline). JS off: only the note;
payload without classes: `#ax-empty`, key / charts / hint hidden.

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
/ gutter), `.allv` (every value printed), `.hov`, `.tight` (auto, columns
< 42 px). Step rows (12, plan card) are hand-built `.r.p` rows (`i.st.lo|hi`,
`i.nd`, `span.pv`). `wg_date/wg_off/wg_title/wg_keep/wg_start/wg_end`.
**Window metadata:** 00 emits `window.AWR_WIN = {np, w:[{o, d, l, s, e, t,
v}]}` oldest first — read it, don't recompute. **Client** (`window.AWR_WG`):
`markers()` maps `AWR_MARKERS` to window boundaries (`{o, after, l, s, t,
at}`, short labels "Release 4.2" → "R 4.2"), `markerAt(o)`, `sizeRow`,
`render(scope)` (call after building / revealing grid DOM), `fit`, `refit`
(auto on DOMContentLoaded, resize, `awr:view`, a `<details>` toggle), `pin`.
`[data-mk-at="o"]` slots get the marker on that boundary (`data-mk-pre`,
`data-mk-icon`). `body.js-wg` hides prior values until hover.

### Band glyph (`sql/lib/band_glyph.plsql`, twin `helpers.py`)

Replaces the v1.4 `data-dev` heat tint and the old Change / z / %Δ columns
in every scored table. `band_z(cur, mu, sd)` (z over max(sd, 2%·|mu|), the
policy's floor) · `band_ztxt` · `band_sev(bucket)` → `s-large|s-moderate|
s-improved|s-typical` · `band_span(z, bucket, size, twin)` → `<span class="bd
s-…" style="--x:…">` on an axis −4σ…+8σ (x = (z+4)/12; past the ends the dot
pins `po|pu` and prints z; `flat baseline` hatched `.s-flat`; NULL z /
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
  ranking table (`sq-elapsed-`, `sq-cpu-`, `sq-gets-`, `sq-preads-`,
  `sq-exec-`; in a tab + `<details>`, reveal handles both) and pool
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

### Micro strips (`js_microstrip.plsql`)

Renders every `[data-spark]` cell (attribute contract unchanged, no emitter
changed) as the mock's 13-bar strip `svg.mw`: bars from zero, Current last
(1.6× wide, accent), normal zone mean ± 2σ (σ floored at 2% of |mean|) from
the CSV's own prior slots, title = last four windows + range (labels from
`AWR_WIN`). `window.__awrRenderSparks` kept. It replaced `js_sparkline.plsql`
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
01, 16, 13, 02, 03, 04, 05, 06, 11, 18, 14, 15, 12, 19, 17) = the JS-off
stacking; 00 emits `#activity` first (before the verdict), and with the
default `order:3` it stays first in every view. Views reorder visually: Summary via the library's `--os`
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
- **`.tabs[data-tabs]` / `.tabpanel[data-tabs][data-t]`** — Top SQL's five
  ranking dimensions; panels holding ECharts resize on activation.
- **`.copy-btn[data-copy]`** — copies the selected element's text; inline
  by default, absolutely positioned only inside `pre`/`.codewrap`. `.tbl-tools`
  CSV/MD toolbars auto-inject above any table with ≥ 4 rows.
- **`data-nosort` / `data-nocount` / `data-notools`** — table opt-outs
  (sort parser handles `,` `%` `▲` `▼` `−` `×` and k/M/G — keep in sync with
  `fmt_num.plsql`; `data-nocount` keeps rows out of the rail pills, e.g. the
  cards' related-metrics tables).
- **`.chip`** — shared pill styling (rank chips, window chips).
- **Number formatting (T7, `fmt_num.plsql`)** — `fmt_num` ~4 significant
  digits with k/M/G ≥ 1e4/1e6/1e9, full precision in `title`; `fmt_int`
  for counts. Never inside `data-spark` / `data-v` / `AWR_DATA` JSON (raw
  numbers under the NLS pin).
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
  line may pass 32767 bytes (tested: 168 hourly, 52 weekly, 2 h every 1 h).
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
is **signed** z (diverging ramp), unlike 07's |z|. **Byte-identity at 0:**
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
section plus R6-R9 scan `dba_hist_reports` (with `XMLTYPE` parsing) seven
times over the span — fine at thousands of rows, worth a single BULK COLLECT
if a busy DB ever makes it slow.

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
(`card_before`).

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
(contract: `demo/PORTING.md`; `demo/awrdemo/helpers.py` twins every shared
PL/SQL lib: band glyph, anchors, card vocabulary, `wg_*`, `tl_*`, `lib_ls`).
**When a section's markup/JS changes, re-port its twin in the same commit and
regenerate**; generation is deterministic (two runs, same md5). `NODE_PATH=<any
node_modules with playwright> node demo/verify_report.js <html> [shots/]` is the
headless smoke test (bundled Chromium, else system Chrome): 0 console errors in
3 views × light/dark, every in-page href resolves to exactly one id, every
visible `a.ent` clicked through, view switch / persistence / rail dimming,
Timeline lanes + `data-tl` jumps + label links + chart hover / legend / zoom /
reset / pin / Esc, plan cards, library rows, rail sub-links, All sections
completeness (`allFull`), micro strips. ~3 min per report; **one instance at a
time** (parallel runs hang Chrome). It works on any report, dbmint's included.
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
  `!= ''` is never TRUE), and a `border-left` / inset shadow on a rail
  link state (32). No DB needed; add a check when a new
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
- Don't add ECharts (or any external JS/CSS) to the fleet report — it is
  inline-SVG-sparkline-only and offline-complete by design.
