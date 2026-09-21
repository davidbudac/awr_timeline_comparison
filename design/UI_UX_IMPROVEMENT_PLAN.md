# UI/UX improvements + findings reduction — implementation plan (2026-09-21)

Status: **in progress on `claude/ui-ux-improvements-buwjzo`.** Phase 1
to 4 implemented 2026-09-21 (see the per-item notes marked DONE below
and the CHANGELOG "Unreleased" entry); phases 5-6 pending. This document is the
outcome of a
UI/UX audit of the single-DB report (v1.4.0 chrome) rendered from
`docs/examples/demo_busy_db.html` at 1440 px and 390 px in light, dark,
Triage and Essential modes, plus a markup audit of `sql/00_params.sql`
and `sql/01_*` through `sql/18_*`. Part 1 records what the audit found;
Part 2 is the plan, in the order the work should be done. Each item names
the files it touches and how to verify it. Nothing here changes what is
measured or which views are read; the read-only invariant, the
single-file/offline contract and the template mechanism are untouched.

Conventions that every item must honor (see `CLAUDE.md`):
- Sections emit HTML via `DBMS_OUTPUT.PUT_LINE`; every user string goes
  through `DBMS_XMLGEN.CONVERT`; no bare `SELECT` leaks.
- `SET DEFINE '~'` is live in every section: no literal `~x` in prose or
  comments.
- Shared logic goes into an `@@sql/lib/<file>` include, never a view or a
  package; per-template lists stay `@@~template_dir/<file>.sql`.
- Findings are recomputed, not shared: 00 (verdict), 07 (summary), 08
  (hero cards), 16 (day profile), 17 (narrative) and `score_cells.plsql`
  each score on their own and stay in sync by inspection. A change to the
  scoring rule lands in **all** of them in one commit.
- The demo generator (`demo/awrdemo/sections/sNN_*.py`) is a hand-ported
  twin of each section; when a section's markup/JS changes, re-port the
  twin and regenerate `docs/examples/demo_busy_db.html` (`demo/README.md`,
  `demo/PORTING.md`); `node demo/verify_report.js` is the headless smoke
  test.
- Fleet files (`sql/fleet/*`, `run_awr_fleet.sh`) are never edited to add
  a single-DB feature and vice versa.
- `./lint.sh` before every commit.

---

## Part 1 — What the audit found

### 1.1 Findings volume: the same fact restated

Flagged rows in the demo report (a busy DB, 12 prior weekly windows):

| Where | Flagged | Of which distinct facts |
|---|---|---|
| 07 Findings summary (LOAD/METRIC/WAIT class) | 19 large + 2 moderate | ~7 |
| 04 Foreground waits (time + avg + class tables) | 13 large + 7 moderate | ~6 |
| 05 Background waits | 11 large + 2 moderate | 1 (all 11 events: z +5.23, +62.8%) |
| 16 Day profile (9 stats x 24 h) | 42 large + 38 moderate, 24/24 hours | ~5 day-wide shifts |

Breakdown of the 21 summary findings:

| Category | Rows | Example |
|---|---|---|
| Identical quantity from SYSSTAT and SYSMETRIC | 4 pairs | `physical reads` (LOAD) and `Physical Reads Per Sec` (METRIC), both z +31.74 |
| Complementary pair (sums to 100) | 1 pair | `Database Wait Time Ratio` +17.8 / `Database CPU Time Ratio` -17.8 |
| Same story, different counter | 5 | read bytes, read requests, User I/O wait, single-block read latency, logical reads |
| Statistically large, materially nothing | 4 | `Wait class: Scheduler` 0.066 s/s vs 20 AAS (0.3 % of DB time) |
| Distinct facts | ~7 | table scans, read I/O, DB time, wait/CPU ratio, response time, Network, Commit |

Consequences: the verdict says "21 movers" when there are ~7; the top-8
"Biggest movers" table spends 4 of its 8 slots on twins; the rail pills
light six sections red for one I/O story; the day-profile heading reads
"42 large, 38 moderate" for a single whole-day shift.

### 1.2 Navigation and cross-linking
- 07 rows do not link to their source rows in 02/03/04; hero cards (08) are
  not clickable; Top SQL rows (06) link only to their own pool row; 11's
  ASH cards have no `id`, so nothing can link to them; 18 rows link to
  neither 06 nor 11. Only 17 (narrative) links out; nothing links back.
- Masthead window chips all read the same clock range (`09:00 -> 10:00`)
  under weekly cadence; the dated list exists only in the hidden
  `.windows-fallback`.
- View state (Triage / Essential / App-only, active Top SQL tab, window
  highlight) is not persisted or shareable; only the theme is.
- The rail's "next large finding" button is clipped on a 1000 px-tall
  viewport (rail scrollHeight 1024); the narrative has no rail entry.

### 1.3 Layout and overflow (measured)
- No table has a scroll container. At 390 px `scrollWidth` is 1666 vs 390;
  at 1440 px the document is still 1914 px wide (`#waits-fg-time` alone
  leaks 474 px; 18 tables exceed the content column: waits fg/bg time+avg,
  all segment-io/file-io detail tables, day-profile, sqlmon-drift,
  sysmetric). Columns -10w..-12w are off-screen unless the page is
  scrolled sideways.
- 01 aligned-windows strip: 14 per-bar captions ("valid . snaps
  41417->41418", 136 px each) overprint each other; 12 of 14 overlap at
  1440 px.
- Marker labels ("Release 4.0", "RU 19.28 patch") collide with legend
  entries on every calendar-axis chart (masthead strip, 09, 10, each 11
  card); in dark mode `js_markers.plsql` draws an opaque paper-colored box
  that hides legend items; 11 cards stack marker labels, window labels and
  the legend on one row.
- After an anchor jump on the phone the sticky h2 covers the first line of
  the section (`scroll-margin-top:18px` ignores `--navh + --h2h`).
- Phone top bar: the third preset button ("Application only") is clipped;
  the row filter is `display:none` below 980 px; 166 of 451 interactive
  elements are under 32 px in one dimension (preset buttons 27 px tall at
  9.5 px font, tool buttons 21 px, permalinks 7x16, summaries 24 px).
- Smaller: masthead sparkline axis labels clipped at both ends; 14/15 line
  chart end labels clipped past the plot edge, legends paginate with the
  6th name truncated; 16 date cells wrap to three lines; 12 parameter
  values wrap mid-number; SQL Monitor "DOP downgrade" chip wraps taller
  than its row; `weeks_back > 16` renders bare `-` headers (16-slot
  `offset_labels`, noted in `awr_trend.sql`).

### 1.4 Accessibility
- DOM order != visual order: sections are emitted 01..18 and re-sorted with
  flex `order:` in `_style.sql`, so keyboard/screen-reader order is
  windows, load, metrics, waits, ... before the overview.
- Top SQL `.tabs` are plain buttons (no `role=tablist/tab/tabpanel`, no
  `aria-selected`, no arrow keys); sortable `<th>` are not focusable and
  carry no `aria-sort`; window chips are `<span>`; no `<main>` landmark,
  no `<caption>` / `th[scope]`, no skip link, no `prefers-reduced-motion`.
  Focus rings are UA-default (3 `:focus` rules in the stylesheet).
- Dark-mode `.chip` (white on `--accent` #5b9bd8) is 2.95:1 at 10 px bold,
  below AA. Light mode passes (worst 4.68:1).
- Essential data lives only in `title` attributes (no tap/keyboard path):
  `fmt_num` full-precision values (08/14/15/18), 16's mu/sigma/n/z/%delta
  tooltip, the sigma~0 badge, all four SQL Monitor flag chips, 06's
  plan-change PHV, 14's tablespace, 15's full file path, every `.copy-btn`
  and `h2 .permalink` (opacity 0 until hover).
- Colour-only encodings in charts: wait-class stacks (09/10), window
  markArea bands (10), PHV series colours (06), the signed-z heatmap (16),
  changed-cell tint (12). The tables carry text badges; the charts do not.

### 1.5 Content and wording
- Empty states: only 11 names a parameter to change ("Increase weeks_back /
  win_hours or pick a busier target_end"); 03, 04, 09, 13 have no guard at
  all (09 renders an empty chart box); 05, 10, 12, 14, 15, 16, 18 explain
  the cause but not a remedy.
- Terminology drift: `SQL_ID` (06) vs `SQL ID` (18); `Week` (01) vs
  `Window` (18); `prior mean` (07) vs `baseline` (17) vs `mu` (07/16 ledes)
  vs `prior N windows` (00); `cur` (06 `PHV (cur)`, 18 `base->cur`) vs
  `Current`. Unexplained abbreviations without `title`: `PHV`, `Plans`,
  `Snaps`, `Max IO` (no unit), `DOP req/alloc`, `Err`, `Id`, `reqs`.
- 02 lacks the `Unit` column 03 and 13 have; hero card unit `cs/s` needs
  decoding; 15's file-type table has no units at all.
- "Biggest movers" bar is log-scaled |z|: once |z| > 20 every bar is full
  length and carries no information.
- 18's pool renders two rows per statement even collapsed; no-data rows are
  a line of dashes plus one flag chip.
- 06 hides its numbers behind a collapsed "Detail table" while the bump
  chart is unreadable at phone width.
- 17: "optimizer_adaptive_plans in -1w, -2w, ... -12w" should read "in all
  12 prior windows".
- Fleet console and the scheduler server pages lack the report's dark
  toggle; the server's tables have no sort or filter.

---

## Part 2 — Implementation plan

Work is split into six phases. Phases 1-3 are the ones worth doing first;
4-6 are polish. Within a phase, items are independent unless stated.
Every phase ends with: `./lint.sh`, regenerate the demo, `node
demo/verify_report.js docs/examples/demo_busy_db.html`, and a dbmint run
with the pinned test window (`target_end='2026-09-04 12:00'`, `win_hours=1`,
`weeks_back=4`) plus an `AUTO` weekly run. Byte-identity is **not**
expected from any phase (markup changes throughout); verify by eye and by
the headless checks. Version bump: 1.5.0, one CHANGELOG entry per phase.

### Phase 1 — Fewer findings, same information (scoring presentation) — DONE 2026-09-21

Implementation notes that differ from the proposal: the wait share gate
uses the Current window's **total non-idle wait time** (07: across
classes; 04/05: one scalar query over all events), not DB time, so all
three sections agree; the movers table is `data-nosort` (lead rows and
their member rows must stay adjacent); the verdict and the 07 heading
count **families** with a flagged lead ("9 findings"), the 07 row badges
still count canonical rows ("11 large"); hero cards got the rule but no
"lead of family" foot (low value); the day-wide rollup also stops those
stats' cells from grading the hour rows.

**1.1 Canonical-quantity map (`sql/lib/finding_family.plsql`, new).**
A `@@`-included PL/SQL function trio, single-sourced for 00/07/08/17 and
`score_cells.plsql` callers:
- `finding_family(p_domain, p_name) RETURN VARCHAR2` -> family key, e.g.
  `READ_IO`, `WRITE_IO`, `LOGICAL_IO`, `REDO`, `DB_TIME`, `CPU_WAIT_RATIO`,
  `PARSE`, `EXEC`, `COMMIT`, `NETWORK`, `SESSIONS`, `LATENCY`, `RESPONSE`,
  `SCANS`, plus `WAIT:<class>` for wait-class rows and `OTHER` fallback.
- `is_canonical(p_domain, p_name) RETURN VARCHAR2` `'Y'/'N'`: exactly one
  canonical name per (family, physical quantity). SYSSTAT twins of a
  SYSMETRIC rate (`physical reads` vs `Physical Reads Per Sec`, `session
  logical reads` vs `Logical Reads Per Sec`, `DB time` vs `Average Active
  Sessions`, `redo size` vs `Redo Generated Per Sec`, `user commits` vs
  `User Commits Per Sec`, `execute count` vs `Executions Per Sec`, `parse
  count (hard)` vs `Hard Parse Count Per Sec`, `user calls` vs `User Calls
  Per Sec`, `logons cumulative` vs `Logons Per Sec`, `physical writes` vs
  `Physical Writes Per Sec`, read/write total bytes vs their `Per Sec`
  metrics): the SYSSTAT name is canonical (it is the primary source and
  present in every template); `Database CPU Time Ratio` is non-canonical
  to `Database Wait Time Ratio`.
- `higher_is_worse(p_domain, p_name) RETURN VARCHAR2` `'Y'/'N'/'-'`:
  waits, latencies, response time, hard parses, sorts (disk), rollbacks,
  parse failures -> `'Y'`; throughput (executions, user calls, commits,
  logical reads, DB time, AAS) -> `'-'` (either direction is a finding,
  a drop can be an outage); ratios -> `'-'`.
Curated constants, case-sensitive, same style as `is_essential.plsql`;
unknown name -> family `OTHER`, canonical `'Y'`, direction `'-'`, so a
template-specific name is never hidden. `lint.sh`: add a check that every
name in every template's `sysstat_load_targets.sql` /
`sysmetric_targets.sql` appears in the map (a missing name is a lint
error, not a runtime one).

**1.2 Family rollup in 07 (`sql/07_summary.sql`).**
- Add `family`, `canonical`, `dir` to `finding_rec`; populate in the one
  BULK COLLECT pass (call the functions in the PL/SQL loop, not in SQL, to
  keep the query shape).
- Tallies (`v_crit`/`v_warn` and the h2 badges) count **canonical** rows
  only; non-canonical twins inherit their canonical sibling's bucket for
  display but never add to counts.
- "Biggest movers": one lead row per family (the canonical member with the
  largest |z|), followed by a muted `tr.member` per other flagged member
  (`data-tail="Y"` so the existing expander hides them; expander label
  "Show N related metrics"). Order families by lead |z|. Replace the
  log-scaled |z| bar with a signed %-delta bar (capped at +-500 %) whose
  cell keeps the numeric |z|.
- Per-domain detail tables: unchanged rows, plus `data-family` on each
  `<tr>` (JS hook for 1.5) and a `class="twin"` on non-canonical rows
  (muted text, still sortable/filterable/exportable).
- The `<h3>Biggest movers</h3>` lede states the rule: "one row per family;
  twins from SYSSTAT/SYSMETRIC and complementary ratios are folded".

**1.3 Materiality floor (07, 04, 05, 08, 16, 17, `score_cells.plsql`).**
- Rule: a row is `large`/`moderate` only if |z| clears the threshold **and**
  |%delta| >= 10 %; otherwise it is `typical` and carries a new
  `<span class="badge sig" ...>immaterial</span>` after the z value (same
  hook as the sigma~0 badge, so no CSS change).
- Wait rows (07 wait-class rows, 04/05 per-event rows) additionally need
  share of DB time >= 2 % in the Current window: 07 already has DB time in
  `load_rows` (join it into `scored` for WAIT rows); 04/05 pass the share
  as a new optional `p_share` parameter to `score_cells` (NULL = no gate,
  so 06/14/15/18 callers are untouched).
- Both thresholds are constants at the top of each file, in lockstep,
  documented in the section ledes ("How this is computed").

**1.4 Sigma floor (07, 08, 16, `day_profile_cte.sql`, `score_cells.plsql`).**
`z = (cur - mu) / GREATEST(sd, 0.02 * ABS(mu))`. `flat baseline` stays for
`sd = 0 AND mu = 0`. The sigma~0 badge is kept (it now marks "sigma was
floored"). Ledes updated. `is_sig()` in 07 and the copy in
`score_cells.plsql` switch to the same 2 % constant.

**1.5 Two-number verdict and hero cards (`sql/00_params.sql`,
`sql/08_overview.sql`).**
- 00's recompute gets `finding_family` / `is_canonical`; `v_n_movers`
  counts canonical rows; the lede becomes "<K> findings / <N> metrics
  moved"; the top-3 movers are family leads; the "All movers" `<details>`
  groups by family.
- 08's six hero cards stay, but each card's foot names its family lead
  status ("lead of READ_IO") only when it is one; no new card.

**1.6 Uniform-shift note for per-event tables (04, 05, 04's class table).**
Before emitting a table, compute over its flagged rows the coefficient of
variation of %delta; if the table has >= 5 flagged rows and CV < 0.15,
emit one `<p class="shift-note">` above it ("11 of 11 events up 60-65 %:
table-wide shift; per-row badges demoted") and render those rows'
badges as `warn` with `data-shift="Y"`. Rail pills follow automatically
(they count badges). Pure presentation in the PL/SQL loop; no query change.

**1.7 Day profile: day-wide vs isolated (`sql/16_day_profile.sql`).**
Per stat, if >= 12 of 24 flagged hours share a sign, emit one
`day-wide shift` finding (median z, direction, hours count) in a new short
table above the heatmap and demote those cells' `class="crit|warn"` to
`class="shift"` (muted tint, still in the table). Heading badges become
"<S> day-wide shifts . <H> isolated hours". Fleet band `06_day_profile.sql`
is informational and untouched.

**1.8 Direction awareness (07, 04, 05, rail pills in 00).**
With `higher_is_worse = 'Y'` and a negative delta, bucket `large`/`moderate`
becomes `improved` (CSS class `info`, badge text "improved"); the rail's
count pills and `findingRows()` (J/K) skip `info`. New severity =>
`07_summary.sql`, `08_overview.sql`, `_style.sql` in lockstep, per the
CLAUDE.md severity rule.

Verification for Phase 1 on the demo: summary 21 -> ~7 headline findings
(all 21 still present as members/twins), FG waits ~6, BG waits 1 + note,
day profile ~5; CSV export of each table still carries every row. On
dbmint: the pinned window and `AUTO` both run 0 ORA-; `template=simple`
and `dev` agree with `comprehensive` on every canonical row.

### Phase 2 — Overflow and the phone layout — DONE 2026-09-21

Implementation notes: the wrapper is added by the chrome JS to every
section table (`div.tblwrap`) and gets `.scroll` only when the table is
wider than its panel (re-measured on resize, tab/expander clicks and the
app filter); inside a scrolling wrapper the thead loses its top-stickiness
(it would stick to the wrapper, not the viewport) and the first column is
sticky-left instead.  Measured result on the demo: document width
1914 -> 1440 px at 1440, 1666 -> 390 px at 390, zero leaking elements.
The phone bar collapses the three toggles into a "View" popover
(`#view-btn` / `.view-panel`, `display:contents` on desktop so the rail is
unchanged) and shows the row filter inside the hamburger panel; controls
get a 32 px minimum below 980 px.  Marker labels moved inside the plot
(`insideEndTop`, alternating offset for neighbouring markers) rather than
a separate band; the windows strip keeps the date caption, moves the
snap ids / skip reason into an SVG `<title>` and prints only "skipped";
06/14/15 end labels truncate at 112 px with a wider right gutter; the
masthead strip drops its clipped first/last axis labels; `section > h2`
wraps below 700 px.  Rail foot is sticky-bottom (3.5 done here).

**2.1 Table scroll containers (`_style.sql`, `00_params.sql`).**
Rather than editing every emitter, the DOMContentLoaded chrome JS wraps
each `section table` (and `pre.sql`) in `<div class="tblwrap">`
(`overflow-x:auto; max-width:100%`), first column `position:sticky;
left:0` with the panel background, and a CSS-only fallback
`section { overflow-x:auto }` for JS-off. Sticky `thead th` keeps working
inside the wrapper (verify: the sticky offset uses `--navh`/`--h2h`, not
the wrapper). Print: `tblwrap { overflow:visible }`.

**2.2 Phone top bar (`00_params.sql`, `_style.sql`).**
Below 980 px, collapse the three preset buttons into one "View" popover
(a `<details>` in the bar, same three buttons inside, `aria-pressed`
kept); show the row filter inside the hamburger panel; minimum 32 px
tap targets for buttons, summaries, tool buttons and tabs below 980 px.

**2.3 Sticky-header anchor offset.** `section { scroll-margin-top:
calc(var(--navh,0px) + var(--h2h,48px) + 8px) }`; the same for
`tr[id]`, `.ash-sql-card[id]` (Phase 3 anchors).

**2.4 Aligned-windows strip captions (`sql/01_windows.sql`).** Drop the
per-bar caption text into the bar's `title` and a single legend line;
show the caption inline only when the bar is wider than 140 px (CSS
container query is not available in the target browsers; use a JS
measure at render, or emit captions in a second row that wraps).

**2.5 Marker labels (`sql/lib/js_markers.plsql`, chart grids in 00/09/10/
11).** Draw markers as label-less `markLine`s and render their labels in a
dedicated band: `grid.top` gains 18 px on marker-bearing charts and labels
sit at `position:'insideEndTop'` with `distance` per index so they stagger;
legends move to `bottom`. Label background reads `--panel` at paint time
(theme listener already exists). 11 cards drop the per-window text labels
(the masthead chips carry them).

**2.6 Small clips.** Masthead strip `xAxis.axisLabel.showMinLabel/
showMaxLabel:false`; 14/15 end labels `labelLayout:{hideOverlap:true}`
plus `grid.right` for the longest name; 16 date cell `white-space:nowrap`;
12 value cells `overflow-wrap:anywhere` only for `>=` 24-char values.

### Phase 3 — Navigation and cross-links — DONE 2026-09-21

Implementation notes: `sql/lib/anchor_id.plsql` (+ `helpers.anchor_id`
twin) builds the ids; 02/03/04/05 rows, 07 detail rows
(`find-<domain>-<name>`), 11 cards (`ash-card-<sql_id>`) and 18 rows
(`sqlmon-<sql_id>`) carry them.  Links are `a.xlink` (07 -> source row,
07 movers -> detail row, 08 hero foot -> finding, 06 pool -> ASH card and
SQL Monitor row, 11 / 18 -> Top SQL pool row); the chrome JS hides any
xlink whose target id is absent (24 of 147 on the demo) and a generic
`revealHash()` opens a collapsed table / tab / details around a linked
row and flashes it.  View state rides in the hash after a `!`
(`#anchor!v=t,e,a&tab=CPU&w=3`), written with `history.replaceState` on
every toggle / tab / window click, restored at load, and appended to the
h2 permalink; 06's own hash opener now strips the `!` part.  Window chips
show the date (`<em>Thu 03 Sep</em>`) whenever a window starts on a
different day than the Current one and carry the ISO range in their
title.  Rail: "What changed" link (unhidden when 17 relocated a
narrative) and the sticky foot from phase 2.

**3.1 Anchor convention.** Every scored row/card gets a stable id built by
one PL/SQL helper `anchor_id(prefix, name)` (new `sql/lib/anchor_id.plsql`:
lowercase, non-alnum -> `-`, collapsed, max 64):
- 02 `tr#load-<stat>`, 03 `tr#metric-<name>`, 04 `tr#fg-<event>` /
  `tr#fgc-<class>`, 05 `tr#bg-<event>`, 07 `tr#find-<domain>-<name>`,
  11 `div#ash-sql-<sql_id>`, 18 `tr#sqlmon-<sql_id>`, 06 keeps
  `tr#sql-<sql_id>`.
**3.2 Links.** 07 rows and movers: "-> row" link to the 02/03/04 source
(family-aware: the canonical row). 08 hero cards: whole card is a link to
its 07 family lead. 06 pool row: chips to `#ash-sql-<id>` and
`#sqlmon-<id>` when those exist (JS checks `getElementById` at load and
hides dead links, so the SQL emitters need no cross-section knowledge).
11 cards and 18 rows: "<- Top SQL" back-link. 17: unchanged.
**3.3 Dated window chips (`00_params.sql`).** Chip text becomes
`<b>-1w</b> <span>Thu 09-03 09:00->10:00</span>` (date + clock; the day
name only when it differs from Current); `title` carries the full ISO
range.
**3.4 Shareable view state (`00_params.sql` chrome JS).** Encode
Triage/Essential/App-only, the active Top SQL tab and the highlighted
window as `#view=t,e,a;tab=CPU;w=3` in `location.hash` (after the section
id, separated by `;`), restore at load, keep the `#section` part working
for the permalinks.
**3.5 Rail fixes.** Rail becomes `overflow-y:auto` with the foot
`position:sticky; bottom:0`; add a "What changed" link that appears only
when `#narrative-src` was relocated.

### Phase 4 — Accessibility — DONE 2026-09-21

Implementation notes: option (a) -- `awr_trend.sql` now includes the
sections in visual order (00, 10, 08, 09, 07, 01, 16, 13, 02, 03, 04, 05,
06, 11, 18, 14, 15, 12, 17) and `_style.sql` keeps only the narrow-layout
ranks (masthead 1, rail 2 / 0 narrow, sections 3, footer 4); the demo's
`SECTIONS` list and the 09/10/11 twins (which sliced their lifted script
by fixed index -- now sliced to the closing `</script>`) follow.  The
report body is a `<main id="main-start">` (display:contents) opened at the
end of 00 and closed in the driver epilogue, with a focus-revealed skip
link.  Top SQL tabs are `<button role="tab">` in a `role="tablist"` with
roving tabindex and Left/Right/Home/End; panels carry `role="tabpanel"`;
sortable `<th>` get `scope`, `tabindex`, `role="button"`, `aria-sort` and
Enter/Space; window chips are `<button>`s; every section table gets an
`sr-only` caption from its h2 (+ h3).  A global `:focus-visible` ring,
`prefers-reduced-motion`, dark-mode `.chip.on` / `thead th` contrast, and
copy / permalink buttons visible on focus and below 980 px.  Tap-to-pin:
clicking any titled element inside a section opens a `.tip` popover
(Esc / scroll / outside click closes).  Colour-only charts: ECharts
`aria.decal` on the stacked wait-class areas (09/10/11, which also
gives each chart an aria-label), a sign glyph on |z| >= 3 heatmap cells
(16), and a `&ne;` glyph on changed parameter cells (12).  The PHV
scatter (06) keeps colour-only series -- its tooltip names the plan.

**4.1 DOM order = visual order.** Two options; pick (a): (a) reorder the
`@@` calls in `awr_trend.sql` to the visual order and drop the `order:`
rules (the narrative's "runs last" constraint is unaffected because 17 is
still last and relocates itself); (b) keep emission order and set
`tabindex` sequencing (rejected: fragile). (a) changes the
`AWR-SECTION` marker order in the spool; `lint.sh` and `demo/PORTING.md`
note it. The `body.no-charts`, app-only and triage rules key on ids, not
order, so they are unaffected.
**4.2 Tabs and sort.** `.tabs[data-tabs]` -> `role=tablist`, buttons
`role=tab aria-selected`, panels `role=tabpanel aria-labelledby`, Left/
Right/Home/End keys. Sortable `<th>` get `tabindex=0 role=button
aria-sort`; Enter/Space sorts. Window chips become `<button>`s.
**4.3 Landmarks and semantics.** `<main>` around the sections, a skip link
before the rail, `<caption class="sr-only">` from the h2 text (JS, at
load), `th[scope=col]` in the shared header emitters, one `:focus-visible`
rule using `--accent` for every interactive element, `@media
(prefers-reduced-motion: reduce)` disabling transitions and the jump
flash.
**4.4 Contrast.** Dark `.chip` foreground to `--ink` on `--accent-bg`
(measure >= 4.5:1); dark `th` to `--ink-soft`.
**4.5 Hover-only data.** A delegated click/keypress on any `[title]`
inside `section` toggles a `<span class="tip">` sibling showing the title
text (auto-hidden on outside click/Esc); copy buttons and permalinks get
`opacity:1` on `:focus-visible` and below 980 px. `fmt_num_title` stays as
is (the tip reads it).
**4.6 Colour-only charts.** ECharts `aria:{enabled:true, decal:{show:true}}`
on stacked wait-class charts (09/10/11) and the PHV scatter (06); 16 keeps
the diverging ramp but adds the sign glyph in `label.formatter` for
|z| > 3; 12's changed cells gain a leading `*` glyph in the cell.

### Phase 5 — Content and wording

**5.1 Empty states.** One shared phrasing, emitted by every section with a
guard (add guards to 03, 04, 09, 13): "<what is empty> in <view> for the
compared windows. Try a wider `win_hours`, more `weeks_back`, or a busier
`target_end`." 09 also hides its chart div when the payload is empty.
**5.2 Terminology and units.** `SQL ID` everywhere; `Window` everywhere
(01's `~period_unit_title` header keeps the unit word); `prior mean` /
`prior sd` everywhere (17 and the 07/16 ledes stop saying baseline / mu
/ sigma outside the formula line); `Current` never `cur`. `title` on
every abbreviation header (`PHV`, `Plans`, `Snaps`, `DOP req/alloc`,
`Err`, `Id`, `reqs`) and units in every numeric header (18 `Max IO
(MB)`, 15 file-type table, 16 per-stat headers); 02 gains a `Unit`
column (the SYSSTAT target list already knows the unit per name; add it
to `finding_family.plsql` as `unit_of(name)` rather than widening the
template files). Hero cards render `s/s` (DB time) and `MB/s`, not `cs/s`
/ `B/s`.
**5.3 SQL Monitor pool.** Fold the drill row into the statement row
(`<details>` inside the last cell) and group rows with no Current data
under one expander "N statements captured only in prior windows".
**5.4 Top SQL on phones.** Below 700 px open the detail table by default
and collapse the bump chart behind an expander (inverse of desktop).
**5.5 Narrative wording.** R3 collapses a full-range list to "in all N
prior windows" / "in -5w..-12w" when contiguous.

### Phase 6 — Fleet console and server (separate PRs, fleet-owned files)
- `sql/fleet/00_fleet_chrome.sql`: `.chip` contrast, tab-order/focus
  rules, `prefers-reduced-motion`, marker band as in 2.5 (fleet copy).
- `server/app/views.py`: dark toggle on the report's `awr-theme` key,
  sortable/filterable run and alias tables (inline JS, stdlib only).

---

## Verification checklist (every phase)

1. `./lint.sh` clean (add the Phase 1 family-coverage check and, in
   Phase 4, a check that `awr_trend.sql`'s `@@` order matches the nav
   order in `00_params.sql`).
2. `python3 demo/gen_demo_report.py` after re-porting the touched
   sections' twins; `node demo/verify_report.js docs/examples/
   demo_busy_db.html shots/` -> 0 console errors, chart count unchanged
   (Phase 2.5 may change it), toggles still flip.
3. Playwright checks to add to `demo/verify_report.js`:
   `document.documentElement.scrollWidth <= clientWidth` at 390 and 1440;
   no two marker labels' bounding boxes intersect a legend item; every
   `[data-w]` th and `.tabs [data-t]` is focusable; dark `.chip`
   contrast >= 4.5.
4. dbmint: pinned window + `AUTO`, `template=comprehensive|simple|dev`,
   `profile_days=7`, `sqlmon_detail=3`, `markers=` inline; 0 ORA-, every
   section's `AWR-SECTION` pair present.
5. Findings counts before/after on the demo recorded in the CHANGELOG
   entry (21 -> K summary, 20 -> K FG, 13 -> K BG, 80 -> K day profile).
