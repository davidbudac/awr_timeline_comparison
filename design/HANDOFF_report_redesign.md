# Handoff: single-DB report redesign mockups (2026-09-24)

**Status:** three design mockups (A, B, C) plus the recommended hybrid (D)
are built and reviewed. Nothing is implemented in `sql/`, and **the owner has
not yet approved a direction.** The next
agent's first job is to get that decision, then plan the implementation.

The owner asked for a redesign of the single-DB report (`awr_trend.sql`
output) that is "more cohesive, more modern, easier to glance over and read",
as three mockups showing the biggest changes that would actually help.

## Files

| Path | What |
|---|---|
| `design/report_mock_a_finding_cards.html` | Mock A: finding cards (answer first) |
| `design/report_mock_b_baseline_bands.html` | Mock B: one visual grammar, the baseline band |
| `design/report_mock_c_window_grid.html` | Mock C: aligned window grid |
| `design/report_mock_d_hybrid.html` | Mock D: the recommended hybrid of A + B + C (see "Mock D" below) |
| `design/report_mocks_src/` | builder sources and data for all three (see "Rebuilding") |
| `design/report_mocks_src/COMMON_BRIEF.md` | the shared design brief the mocks were built from: problems, data story, hard constraints |

Each mock is one self-contained HTML file (122–219 KB; D is 479 KB). It uses
no CDN and no external fonts. Charts are inline SVG or CSS, and it works in
light and dark mode. A, B and C were also checked at 390 px; since round 2 the
owner has said mobile no longer matters, so D is only verified at desktop
width (1440). Every mock loads with 0 console errors. A dark
"MOCK NOTE" bar at the top of each page lists what differs from today's report;
it is not part of the design.

All three use the real demo data from `docs/examples/demo_busy_db.html`
(ORCLPRD, Thu 10 Sep 2026 09:00–10:00 vs 12 prior Thursdays).

Unrelated, don't confuse them: `docs/_mock1..3.html` are untracked mocks for
the docs-site redesign from a previous session (commit f9902c7).

Prior art: `design/redesign_directions.html` (July 2026). It showed five page
shells (Ops board, Briefing, Workbench, Time spine, Diff), and **Workbench was
chosen and shipped**: the left rail plus panels. `design/UI_UX_IMPROVEMENT_PLAN.md`
is the v1.5.0 plan (Normal/Full views, structured "What changed", fewer
findings). This round is about the **content system**, not the shell again:
all three mocks keep a rail-style navigation.

## Diagnosis of today's report (v1.5.0)

1. **The same fact is shown 4–5 times, each in a different style:** the red
   verdict strip, the blue "What changed" box (17), the six hero cards (08),
   the "Biggest movers" table plus the per-domain tables (07), and the Day
   profile heatmap (16). The reader has to assemble the story.
2. **There is no single visual grammar for current vs prior.**
   - Hero cards: sparkline plus 13 bars.
   - 02/03/04/05: 13 heat-tinted columns (`dev_bucket.plsql`).
   - 07: z-score plus %Δ bars.
   - 18: sparklines.
   - 16: heatmap plus line chart.
3. **Colour overload:** pink row fills, tan deviation tints, red heatmaps,
   coloured rail dots and UPPERCASE chips. Nothing stands out, and wide tables
   turn into pink and tan patchwork.
4. **Charts:** the 3-month hourly ASH chart (09/10) takes a whole screen, and
   the Current hour is a 1-px sliver at the right edge. Rotated marker labels
   collide and legends crowd the axes.
5. **Typographic noise:** letter-spaced UPPERCASE labels, section titles full
   of jargon plus source captions, "How this is computed" in every section,
   and row labels that wrap to 3 lines.
6. **No hierarchy:** every section is the same white card, so the answer
   looks exactly like the reference appendix.

## The three directions

### A · Finding cards (answer first)

**Thesis:** a finding is one object, shown once, with its evidence attached.

**Key moves:**
- A rule-based verdict sentence plus a "likely source" sentence and quiet
  count pills.
- A 13-bar DB-time strip with release flags placed between the columns, never
  rotated. It replaces the verdict strip, the What-changed box and the hero
  cards.
- One card per metric **family**: Physical I/O, DB time, Network, Commit.
  - Twins and related metrics fold into a chip list.
  - Each card lists its evidence as key → value (file, segment, wait, SQL)
    with multipliers.
  - Card size carries hierarchy: the lead card is biggest, moderate ones are
    slim.
- "What changed around it": the plan change, plus the 4 parameter changes as
  mini-timelines aligned to the release flags.
- "Checked and normal": a calm grid of 18 metrics, plus an explicit
  "moved but too small" note and a "nothing improved" note.
- A uniform **evidence library**: every other section is one collapsible row
  with a one-line status. Top SQL and Foreground waits are shown expanded. The
  3-month ASH chart moves to Full view.

**Needs from SQL:**
- A new rule engine for the verdict and "likely source" sentences. It must
  join findings with Top SQL, segment, file, parameter and marker data (a
  bigger version of today's 17).
- Family links in `metric_policy.plsql` beyond twin/canonical, to group related
  metrics such as table scans → physical reads.

**Mock-only derivations:**
- Moved vs "too small" for wait events uses the mock's own z plus a 5%
  share-of-wait-time rule, not the policy's.
- The Physical-read-bytes series is omitted: its spark was truncated in the
  data dump.
- The ASH daily bars use the 09:00 six-hour bucket.
- Day profile, Segment, File, Load and Metrics rows are one-line stubs.

### B · Baseline bands (one visual grammar)

**Thesis:** keep the section structure, and replace every current-vs-prior
visual with **one glyph**. Put colour on a strict diet.

**The glyph:**
- A dot on a **fixed z scale shared by the whole page**: z −4…+8, with +2σ at
  exactly 50%.
- The prior "normal" zone is shaded: μ±1σ dark, ±2σ light, with ticks at ±2σ
  and ±3σ (the policy thresholds).
- Past +8σ the dot pins to the edge with an arrow and prints its z.
- Filled dot = finding, hollow = normal, hollow past a tick = immaterial,
  outlined teal = improved.
- It is **pure CSS**: one span with a `--x` custom property, zones drawn as
  gradients. Because the scale is shared, dots line up down a table.

**One table component** (`.bt`) serves findings, the 3 foreground-wait tabs,
Top SQL and SQL Monitor:
- Columns: name | current | normal range (μ±2σ in the metric's own unit) |
  band | Δ (×n when ≥2×, else %) | 13-window sparkline with the normal zone |
  expander.
- The expander shows 13 columns plus release flags, replacing the 13 tinted
  columns.
- Findings are grouped per family, one `<tbody>` each: the lead row is bold,
  relatives are indented, twins are muted. "Show 43 normal rows" folds the
  rest.

**Other moves:**
- The masthead "what changed" rows carry the same glyph. The DB time row
  stacks DB time (red, +6.1σ) over DB CPU (hollow, +1.4σ), so "wait, not
  CPU" reads at a glance.
- Every section header has the same shape: title · one plain sentence ·
  counts · an ⓘ that reveals the source and method.
- ASH is one smoothed full-span chart: 4 classes in colour, the rest grey, the
  13 compared hours as dots, and collision-free flag lanes.

**Near-zero σ:** the policy divides by max(σ, 2%·|μ|), so the dot stays
finite. Hatch the zone (`.bd.fl` style is already in the CSS) and keep the
`σ≈0` pill. A true flat baseline gets a fully hatched track with no dot. A
live example in the demo is "redo size for lost write detection" in Full view.

**Needs from SQL:**
- The normal range per row, computed in SQL.
- Family plus lead flag per row (07's collection already has both).
- Per-row JSON for the expanders, like `sqlDetails` today.

**Risks:**
- Flag lanes measure text in JS, or need a server-side character-width estimate.
- Mobile turns table rows into grids with CSS only, which breaks if the
  column order ever changes.

**Mock-only derivations:**
- Top SQL and segment/file rows get a z-score. Today's report doesn't score
  them; Top SQL uses only the windows where the statement ranked, so
  n7t3q5xc1yj4g has n=4.
- Wait-class mapping for events is hand-assigned.

### C · Aligned window grid (the 13 windows are the page's backbone)

**Thesis:** the whole page shares one column grid, so you read down the
Current column through every section, and across a row to see *when*
something started.

**Key moves:**
- **Grid template:** 252 px labels | 12 × 1fr | Current at 1.6fr | a 136 px
  gutter holding Δ, severity glyph and z.
- **Current column:** a continuous tinted band through every lane. Hovering a
  column prints every value in it; clicking a date pins it as the comparison
  target.
- **Release flags** sit on column boundaries and their lines run through every
  lane.
  - **Payoff:** all 4 parameter changes land exactly under a flag:
    - cursor_sharing under Hotfix 4.0.1
    - sga_target under RU 19.28
    - pga_aggregate_target under Release 4.1
    - optimizer_adaptive_plans under Release 4.2
  - The DB-time step and the first appearance of n7t3q5xc1yj4g also sit under
    Release 4.1, and the plan change ◆ sits under Release 4.2.
  - No other mock shows this correlation.
- **One cell type:** a grey mini column scaled from zero. The Current bar is
  red or amber only when the row is flagged, with the prior range drawn
  behind it. No tints.
- **Lanes:**
  - Activity: ASH as 13 stacked one-hour columns, replacing the 3-month chart.
  - Headline and load rows.
  - Waits.
  - "Where the reads land" (segments and files).
  - SQL, including a SQL Monitor sub-row, the new-SQL ✚ and the plan ◆.
  - Configuration as step lines.
- The Day profile has a different axis, so it gets its own 24-column ruler
  below the grid.
- On mobile the grid opens scrolled to Current, and the sticky ruler scrolls
  in sync with the body.

**Other window counts:**
- weeks_back=4: cap the column width (`minmax(56px,120px)`).
- weeks_back=24: ~40 px columns, a label on every 4th offset, short flag
  names. Past ~30 windows the grid scrolls, anchored at Current.
- Daily cadence: weekday labels plus a faint weekend shade.

**Needs from SQL:**
- Map each marker to the pair of windows it falls between.
- Per-parameter human units (bytes → GB).
- Emit the grid template and the per-column hover/pin CSS from the actual
  window count.

**Risks:**
- The sticky ruler needs JS scroll-sync.
- Flag tiers are measured in JS.
- ASH JSON sits in an attribute, so it needs quote escaping.
- There is one removable `:has()` rule.

**Mock-only derivations:**
- The Activity gutter multipliers (User I/O ×4.2, Network ×5.2) come from ASH,
  not from the SYSTEM_EVENT values (+320%, +417%).
- The DOP-downgrade glyph for 9wz2ke6yq4tn1 is placed in Current.

## Recommendation given to the owner (not yet accepted)

Combine them:
- **A's structure** for the Normal view.
- **B's glyph** as the one grammar in every table.
- **C** as the Full view or a "timeline" tab, because its release/config
  correlation is unique.

Rough cost order, cheapest first:
1. **B:** a CSS glyph, tables keep their structure, `dev_bucket` tints retire.
2. **A:** a narrative rule engine plus family grouping.
3. **C:** a layout rewrite that depends on the window count, plus JS sync.

A sensible phased plan once the owner picks:
- Phase 1: B's glyph plus colour diet.
- Phase 2: A's Normal-view restructure.
- Phase 3: C's grid as an opt-in view.

## Mock D · the hybrid (built on request, same day)

`design/report_mock_d_hybrid.html` (479 KB after round 2, was 396 KB) is built
by `python3 design/report_mocks_src/hybrid/build.py`, which is deterministic.
It loads with 0 console errors in all three views, in light and dark, at 1440
(390 px was checked in round 1 only; mobile is no longer a target). With JS
off, every view shows stacked.

**View model:** one DOM, three views chosen by a body class from a switch in
the top bar:
- **Summary** (default): A's structure.
- **Timeline:** C's grid.
- **All sections:** every evidence-library row opened, with B's tables.

The choice is saved to localStorage `awr-view` only on an explicit click, and
a `#view=` hash wins. Rail links dim when their target is outside the current
view; clicking one switches view. Cards have a "Show in timeline →" link that
jumps to and flashes the row in Timeline.

**How the three were unified:**
- **One 13-column component** with a wider indigo Current column and flags on
  the column boundaries. It is shared by the hero strip, card charts, config
  card, table expanders and the Timeline, and the hero header *is* the
  Timeline ruler.
- **One band glyph** in card headers, scored evidence rows, table rows, the
  Timeline gutter and the "checked and normal" rows.
- **One accent:** indigo means Current. Severity colour appears only on dots,
  Δ text and the 2 px marker.
- **One table:** "N related metrics" is a clone of the family's rows from the
  single Findings table.
- **One Δ rule:** ×n at 2× or more, else %. Unscored evidence (segment, file)
  shows a neutral ratio labelled "not scored".
- **One section header:** title · plain sentence · counts · ⓘ.

**Dropped from the originals:**
- A: the chip list, the min–max "normal" (now μ±2σ everywhere) and the
  per-day ASH mode.
- B: the six headline tiles (they repeated the cards and the strip) and the
  line sparklines (now 13-bar micro strips).
- C: the ●/◐/○ glyphs, red Current bars (now a dot) and the "week before"
  span row.

**New PL/SQL risks beyond the ones above:**
- The shared evidence library needs JS to move rows between views and to
  open or restore them.
- The related tables and prior-window values are built client-side to keep
  the file small (under 400 KB in round 1, 479 KB after round 2's full-span
  ASH payload and guide), so without JS the Timeline shows only Current values.
- Every chart instance needs its own column-hover CSS.
- The 4-family grouping and Top SQL z-scores are new policy work (mock-only).

### Mock D · round 2 (owner feedback 2026-09-26)

**Owner feedback, as relayed (paraphrased where no exact wording was passed on):**

- *Declutter pass (first round on D, commit 218637a):* the page felt busy and
  wordy. Calm it down: less prose, one spacing scale, every section header the
  same shape, method notes out of the way, and colour only where it means
  something. Result, kept in round 2: the `--s1..--s8` spacing scale, the
  uniform `.sh` header (title, one-line subtitle, counts), a single
  "About this report" fold at the bottom for every method note, and indigo
  used only for Current.
- *Round 2, four requests:*
  1. "Add a completely separate section at the bottom, not the About fold,
     that explains how to read each kind of graph": the band glyph, the
     13-column grid, the ASH stacked timeline, sparklines, markers and any other
     chart. Concise and scannable, small example visuals, one or two short
     lines each, shown in every view and linked from the rail.
  2. "Use more of the screen on wide monitors" (raise or drop the max-width,
     more cards per row, stretch tables and the grid; mobile no longer
     matters). **Withdrawn by the owner the same day (2026-09-26):** keep the
     page width and column layout exactly as in 218637a. The mock was reverted
     and the width is unchanged (`main` keeps `max-width:1232px`). Only the
     "mobile no longer matters" part stands.
  3. "Make sql_ids, segments, files, wait events, parameters and other named
     things in the findings and verdicts clickable": each goes to its row in
     the detail tables, switching view if needed, scrolling there and briefly
     highlighting it. Every link must resolve; subtle styling, not loud links.
  4. "Put the complete ASH timeline, across the whole report span, at the very
     top of the Timeline view, and make it interactive": hover tooltip with the
     time and per-wait-class AAS, a legend that toggles classes, drag-to-zoom
     with reset, the compared windows shaded with Current in indigo, a click on
     a window highlighting that column in the grid below, release markers, and
     dark mode.

**1 · "Reading the charts" guide.** A `<section id="guide">` after the
evidence library and before About, outside the view classes so it shows in
Summary, Timeline and All sections alike, with a new rail group "Reference"
(Reading the charts, About this report). Twelve items in a two-column grid,
each a small visual plus one or two short lines: band, Δ text, 13-window
chart, full-span activity, activity per window, the smoothed span chart
(All sections), sparkline (the 13-bar micro strip), release marker, step line,
glyphs (◆ ✚ ▽), day profile, hover and pin. The band and Δ examples are the
real components; the rest are tiny static SVGs drawn with the page's CSS
variables, so they follow the theme. The old two-panel legend inside About
moved here, and About now holds only method and sources.
*PL/SQL:* static markup, no data. It fits `sql/00_params.sql`'s chrome (or a
small new section emitted last, before 17) as a block of `DBMS_OUTPUT.PUT_LINE`
literals with its CSS in `sql/_style.sql`. No cursor, no DEFINEs, no tilde in
the text. It would sit in the Normal view as well as Full. Keep the example
SVGs in lockstep with the real glyph CSS when either changes.

**2 · Wider layout: withdrawn.** Nothing ships. The mock keeps round 1's
`max-width:1232px`, the 12-column card grid with every card `span 12`, the
3-column "checked and normal" grid, and fixed table column widths. No
`_style.sql` width change is implied. (The rail's line height went from 24 to
22 px so the new Reference group fits at a 1000 px viewport height. That is
vertical only.)

**3 · Entity links.** Every sql_id, segment, datafile, wait event, wait class,
parameter and metric name in the verdict, the "likely source" line, the
finding and change cards' evidence, the "checked and normal" rows, and the
Timeline row labels is an `a.ent` link: inherited colour, dotted underline,
solid on hover. The mock has 88 links to 64 distinct targets; 84 are visible by default, and 4 sit in the folded "+ Show 4 more events" Waits rows. A click switches
to the target's view, opens its `<details>`, activates its tab (Top SQL,
Foreground waits), unfolds the hidden normal rows if needed, scrolls the row
to the centre and flashes it (2 s). A plain `#id` hash on load does the same
without saving the view. The builder asserts that every `href="#…"` on the
page resolves to exactly one id and that no id is duplicated. The "N related
metrics" clones strip ids.
*Anchor ids the sections would emit (slugged lower-case, `[^a-z0-9]` → `-`):*
- `07_summary.sql`, the findings table: `fr-<domain>-<name>` per metric or
  wait-class row (e.g. `fr-l-physical-reads`, `fr-f-wait-class-commit`).
- `04_waits_fg.sql`: `we-<event>` (time waited), `wa-<event>` (average wait),
  `wc-<class>` (by wait class).
- `06_top_sql.sql`: `sq-<dim>-<sql_id>` per ranking tab (`sq-elapsed-…`
  is the link target).
- `18_sqlmon.sql`: `sm-<sql_id>`.
- `14_segment_io.sql`: `sg-<owner.segment>`; `15_file_io.sql`: `fl-<file>`.
  Both were stubs in round 1. The mock now renders their top-10 tables as real
  ranked rows (band reads "ranked, not scored", plain ratio Δ).
- `12_param_changes.sql`: `pa-<parameter>`.
- Emitters: the verdict/"likely source" (`00_params.sql`, `17_narrative.sql`),
  the finding cards (07) and the Timeline labels need a shared
  `anchor_id(kind, name)` PL/SQL function (new `sql/lib/` include) so link and
  target can never drift. Only link to rows that are actually emitted: a
  sql_id outside the Top-N has no row. Names go through
  `DBMS_XMLGEN.CONVERT` for the text; the id is the slug. Where a DB has two
  entities that collide after slugging, append the rank. The link-resolves
  check belongs in `demo/verify_report.js`, plus a grep-able lint if cheap.
- Chrome JS (00): `goTo` gains `reveal()` (tab, folded rows, `<details>`) and
  flashes `tr` targets. The Normal/Full switch replaces the mock's view
  switch: a link into Full-only content calls `setMode(full)` first, as
  `revealHash()` does today.

**4 · Interactive full-span ASH chart (top of Timeline).** A new panel above
the grid: 10 wait classes stacked as a step area over the whole span
(18 Jun to 10 Sep) in the demo's 6-hour buckets. The demo has no hourly
full-span series, so the chart shows the 6-hour buckets as steps rather than
inventing hourly values. The 13 compared hours come from the per-window data
and appear as shaded stripes (grey, Current indigo, the pinned one amber).
- *Hover:* a crosshair and bucket highlight, and a tooltip with the time
  range and per-class AAS plus the total of the shown classes. Over a stripe,
  the window's own unsmoothed hour.
- *Legend:* one button per class (`aria-pressed`). Hiding a class restacks
  and rescales the y axis.
- *Zoom:* drag to brush, down to a 12 h minimum; the x ticks adapt (weekly
  Thursdays, then days, then hours); "Reset zoom" or a double-click restores.
- *Windows:* a click (or Enter on a focused stripe) pins that column in the
  13-column grid below, the same state as clicking a ruler date, so the gutter
  compares against it and Esc clears. A click on Current unpins and flashes
  the Current column.
- *Markers:* release flags in a two-tier band, with lines through the plot.
- *Theme:* all colours are CSS variables except the fixed wait-class palette,
  so a theme toggle needs no JS.
The rail's Timeline group starts with it. The All sections "Active sessions,
whole span" chart (smoothed, with dots) is unchanged.
*PL/SQL:* this is **not** a `windows_cte` consumer. It needs the
**LAG-delta, time-range scan** that `00`/`10` (and `09`'s hourly timeline) use:
`DBA_HIST_ACTIVE_SESS_HISTORY` bucketed by `sample_time` from the start of the
earliest compared window to `target_end` (span = `weeks_back × step_hours +
win_hours`), `dbid IN (dbid_list)`, ON CPU → 'CPU', idle excluded,
AAS = samples ÷ (360 × bucket hours). Use adaptive buckets like the fleet's
`02_ash.sql` (about 168–400 buckets, 1 h floor for short spans), emitted once
as a `window.AWR_DATA` payload `{t0, bh, classes, vals}` with the NLS-pinned
number format. Window shading and the per-window tooltip reuse the
`windows_rollup` rows that 09 already reads. The CSV/JSON must not
left-compact nulls (the `listagg-null-token` rule). Cost: a single ASH scan
over the span; 09 already does one, so a combined section can share it.
(As built: the Activity charts share 09's scan AND its fine grid -- hourly,
or the sub-hour cadence, coarser only past 10000 buckets; the owner found
the adaptive 168-400 buckets too coarse.)
*ECharts vs inline SVG: the mock hand-rolls it (about 150 lines of JS).*
- Why SVG: it keeps the mock CDN-free and works offline with no
  `body.no-charts` fallback. It styles itself from the same CSS variables as
  every other chart, so there is no `awr:theme` listener to maintain. It can
  share the pin state with the grid directly.
- What it costs: zoom, tooltip, legend and axis-tick logic are ours to
  maintain and test, with no data zoom slider, no touch pinch and no
  export/save-as-image.
- ECharts would give all of that for free and matches today's 09/10/11, but it
  needs the CDN or `vendor/` inlining, its own dark-mode re-style listener and
  the no-charts fallback.
- If the owner keeps ECharts for the big charts (open question 2), this chart
  maps onto a stacked `line` series with `step:'start'`, `dataZoom` (inside +
  slider), `legend`, `markArea` for the windows and `markLine` via
  `AWR_markLine`. The click-to-pin becomes a `markArea` click handler that
  calls the chrome's pin function.

**Verification (2026-09-26):** built twice with an identical md5. Headless
Playwright (system Chrome) at 1440 × light/dark × all three views: 0 console
errors, no horizontal page overflow, guide visible in every view. All 84 visible
entity links were clicked from each view they appear in, and every target existed,
was shown, sat inside the viewport under the top bar and flashed. The ASH chart
passed hover, legend toggle and restore, brush zoom, reset button,
double-click reset, window click pinning column 8 (ruler `aria-pressed`,
highlight, gutter "vs 13 Aug"), Current click unpinning and flashing,
keyboard Enter and a live theme toggle, in both themes. Known and
pre-existing: at 1280 px the hero strip overflows the page by 18 px. That was
already true in 218637a and is out of scope with the width unchanged.

## Where it lands in the code (for planning; as built: see "Implemented in v1.6.0")

- **Masthead, verdict, chrome JS:** `sql/00_params.sql`. The "What changed"
  narrative is `sql/17_narrative.sql`, which relocates itself into
  `#narrative-slot`.
- **Hero cards:** `sql/08_overview.sql`. **Findings:** `sql/07_summary.sql`
  (BULK COLLECT collection, family/canonical from `sql/lib/metric_policy.plsql`).
- **Per-window tables:**
  - 02 load, 03 metrics, 04/05 waits, 06 Top SQL, 12 params, 13–15
    utilization/segment/file, 18 SQL Monitor.
  - Heat tint comes from `sql/lib/dev_bucket.plsql`, Change/z cells from
    `sql/lib/score_cells.plsql`, number formatting from `sql/lib/fmt_num.plsql`.
- **Charts:**
  - 09 ASH, 10 DB time and 11 per-SQL ASH are ECharts.
  - Inline sparklines: `sql/lib/js_sparkline.plsql`.
  - Markers: `sql/lib/js_markers.plsql`.
  - Wait-class palette: `sql/lib/js_wait_colors.plsql`, kept in lockstep with
    the fleet copies.
- **CSS:** `sql/_style.sql`. **Section order:** `awr_trend.sql`, the rail in
  00, and `SECTIONS` in `demo/gen_demo_report.py`.
- **Demo:** every section has a hand-ported Python twin in
  `demo/awrdemo/sections/`, and CSS/JS are lifted by `demo/awrdemo/chrome.py`.
  - Re-port the twins and regenerate `docs/examples/demo_busy_db.html`.
  - Smoke test: `node demo/verify_report.js`.

**Constraints to honour (see `CLAUDE.md`):**
- HTML is emitted through `DBMS_OUTPUT.PUT_LINE`, and every user string goes
  through `DBMS_XMLGEN.CONVERT`.
- No literal tilde-word anywhere (`SET DEFINE '~'`).
- The only external dependency is ECharts, and it must degrade via
  `body.no-charts`.
- Every ECharts chart needs an `awr:theme` listener.
- The Normal/Full contract: `data-normal`, `.full-only`.
- Positional CSV via `LISTAGG(','||token)` (lint check `listagg-null-token`).
- PL/SQL declaration order (lint checks 14–16).
- Run `./lint.sh`.
- Verify on dbmint (`ssh -p 2200 oracle@dbmint`) with a pinned window, e.g.
  `target_end='2026-09-18 12:00'`, hourly.
- **Never edit fleet files** (`sql/fleet/*`, `run_awr_fleet.sh`) for this. The
  fleet report is a separate product.

Moving any chart from ECharts to inline SVG (all three mocks do this) is a
real design decision for the owner. Inline SVG gives offline-by-default and
one visual style. Round 2's full-span ASH chart shows that zoom, tooltips and
legend toggling can be hand-rolled in inline SVG (about 150 lines of JS), but
then the report owns that code instead of ECharts. See "Mock D · round 2".

## Open questions for the owner (resolved: see "Implemented in v1.6.0")

1. Which direction, or which combination? Is the recommended hybrid acceptable?
2. Keep ECharts for the big charts, or go inline-SVG only (like the fleet
   report)? Round 2's interactive ASH chart is hand-rolled SVG; confirm that
   or map it onto ECharts (see round 2 for the mapping).
3. A: is a generated verdict sentence acceptable, or should it stay
   structured lines like today's "What changed"?
4. B: should Top SQL, segment and file rows get z-scores? That is new scoring,
   and it affects the policy, 07 and the demo.
5. C: Normal view, Full view, or a separate tab?

## Implemented in v1.6.0 (2026-09-26)

Mock D shipped as v1.6.0 on branch `feat/report-redesign-d` (phases 1–5;
CHANGELOG 1.6.0; the agents' reference is `CLAUDE.md`: "Views", "Summary
view pieces", "Timeline view", "Window component", "Band glyph", "Entity
links", "Micro strips", "Reference section").

**Open questions, as resolved by the owner:**

1. Direction: **Mock D hybrid**, as decluttered in round 1 and extended in
   round 2 (graph guide, entity links, interactive full-span ASH). The wider
   layout was withdrawn: the page keeps its ~1232 px width. Phones are not a
   target (nothing ≥ 1280 px may break).
2. Charts: every **new** component is inline SVG/CSS as mocked (band glyph,
   13-window micro strips, window grid, full-span ASH, guide examples) and
   CDN-free. The existing ECharts charts stay in All sections (04/05 waits,
   06 bump chart, 09 hourly ASH, 10 DB time, 11 per-SQL ASH, 14/15 I/O,
   16 day profile, 18 scatter) with `body.no-charts` and `awr:theme` intact.
3. Verdict: **one short rule-based sentence** plus a "Likely source" line,
   generated from the existing findings and narrative rules; no free prose.
4. Top SQL / segment / file: **ranked, not scored** — no new z-score policy.
   18's SQL Monitor elapsed keeps its existing `score_cells` scoring.
5. Views: **Summary (default) / Timeline / All sections** replace Normal /
   Full (`body.vs|vt|va`, `class="vw in-s|in-t|in-a"`, localStorage
   `awr-view` saved on an explicit click only, `#view=` hash wins, entity
   and rail links switch view like the mock's goTo / reveal, JS off = all
   stacked). All sections still shows every number the v1.5.0 Full view
   showed.

Also decided: the band glyph replaces the `dev_bucket` heat tint
(`dev_bucket.plsql` deleted); finding cards group `metric_policy` families
(mapping in `sql/lib/finding_cards.plsql`); entity ids come from one PL/SQL
`anchor_id(kind, name)`; `awr_version` 1.6.0, fleet version unchanged.

**Where each piece landed:**

| Piece | Code |
|---|---|
| Top bar, view switch, rail, chrome JS (setView / goTo / reveal), Activity charts' skeleton (`#activity`), verdict hero, Timeline skeleton, `AWR_WIN` | `sql/00_params.sql` |
| DB time hero strip | `sql/08_overview.sql` on `sql/lib/wingrid.plsql` + `js_wingrid.plsql` |
| Finding cards, Checked and normal, `#changes-slot`, Evidence library heading, Timeline metric / wait-class rows | `sql/07_summary.sql`, vocabulary `sql/lib/finding_cards.plsql` |
| Verdict "Likely source", pills, notes, I/O card evidence | `sql/17_narrative.sql` (relocated by inline scripts) |
| Plan-change card | `sql/18_sqlmon.sql` → `#changes-slot` |
| Configuration card + parameter step rows | `sql/12_param_changes.sql` |
| Band glyph, Δ rule, library row text | `sql/lib/band_glyph.plsql` (+ `score_cells.plsql` delegates to it) |
| Entity links / anchors | `ent()` in `finding_cards.plsql`, `sql/lib/anchor_id.plsql`; unwrap of missing targets in `js_wingrid` |
| Timeline grid rows | `sql/lib/timeline.plsql` (tl_*), emitted by 04 / 06 / 07 / 09 / 12 / 14 / 15 / 18; client `sql/lib/js_timeline.plsql` |
| Activity, whole span (top of every view): ASH by wait class + by wait event | payloads `AWR_DATA.ashx` / `AWR_DATA.ashe` from 09's one existing scan, drawn by one chart factory in `js_timeline` (two linked instances) |
| Micro strips | `sql/lib/js_microstrip.plsql` (replaces js_sparkline in the single-DB report; the fleet keeps js_sparkline) |
| Graph guide + About | `sql/19_reference.sql` |
| Readable JS sources | `sql/lib/src/*.js` → `tools/js2plsql.sh` (lint check 24) |
| CSS | `sql/_style.sql` (also reaches the fleet chrome; `table.dt` keeps the fleet's severity bar) |
| Demo twins | `demo/awrdemo/sections/*`, `demo/awrdemo/helpers.py`; smoke test `demo/verify_report.js` |

**Owner follow-ups after the dbmint pass (2026-09-27):**

- The full-span ASH chart moved out of the Timeline view to the very top
  of the report, above the verdict, in all three views ("Activity, whole
  span", `section#activity`), and became two stacked charts on one time
  axis: by wait class and by wait event (top 14 events, ON CPU as `CPU`,
  the rest as "Other events", the fleet's `FLEET_ASH_EV` rules). Each has
  its own legend, hover, zoom, window stripes and markers; zoom, hover
  crosshair and the pinned window are linked. The Timeline view keeps the
  window grid; the pin now survives a view switch.
- The rail's active-link crescent (an inset left shadow on the rounded
  pill) is gone in every state (lint check 32).
- Fleet `table.dt` first cells get a 10 px left padding off the severity
  bar (in `sql/_style.sql`; fleet files untouched).

**Conscious divergences from the mock** (phase 4's sweep, kept):

- Rail: keeps the row filter, the "AWR · Timeline comparison" brand, status
  dots, crit / warn count pills and J / K, and extra groups (Workload / SQL
  / Storage & config / Whole span); the mock has a DB-name brand, plain
  counts and an "All sections" group.
- All sections: sections stay full panels (the mock folds them into one
  panel of `<details>` rows); Findings stays one table per domain (the mock
  groups by family with lead / member / twin rows); 09 / 10 / 11 keep their
  ECharts charts where the mock has one smoothed span chart; no per-row
  expanders or chevrons in the tables.
- Card evidence follows phase 2's rules (Physical I/O shows segment, file,
  events; the mock also lists the Top SQL by reads; Network / Commit omit
  per-wait and commit-count rows).
- Plan card: the verdict pill links `#sm-<id>`, not the card; per-exec
  numbers use `fmt_num`; the h3 carries the release date; the bars have no
  Current severity dot (Top SQL is ranked, not scored).
- The Summary library order (`--os`) differs from the All sections order,
  as in the mock; Summary opens Top SQL, Foreground waits and (on an error
  / DOP downgrade) SQL Monitor by default.
- Day profile in the Timeline is section 16 as is (heatmap, line, table),
  not the mock's 24-column bar grid.
- "Checked and normal" lists canonical rows only (the demo shows 30
  normal where the mock shows 43).
- The hero strip stays plain DB-time bars; only the DB time card is
  stacked by wait class.
- Restored in phase 5 from v1.5.0 (not in the mock): "all DBIDs …" in the
  top bar for a multi-DBID report, the template name for a non-default
  template, and "by <user>" in the About run line.

## Rebuilding / verifying the mocks

The mocks are the source of truth; you can edit the HTML directly. The
builders in `design/report_mocks_src/` regenerate them **byte-identically**
(verified 2026-09-24). Each writes straight to its `design/report_mock_*.html`
by absolute path:

```sh
sh   design/report_mocks_src/mock_a/build.sh      # template.html + data.json
python3 design/report_mocks_src/mockb/build.py    # template.html + tables.json + ../demo_series.json
python3 design/report_mocks_src/c_build/gen.py    # style.css + app.js + body.html + tables.json + ../demo_series.json
python3 design/report_mocks_src/hybrid/build.py   # D: template.html + style.css + app.js; reads ../demo_series.json, ../pool.json, ../mockb/tables.json, ../mock_a/data.json
```

**Data inputs:**
- `demo_series.json`: chart payloads pulled from `window.AWR_DATA` of the
  demo report.
- `tables.json`: parsed tables.
- `pool.json`: Top SQL pool.
- `mock_a/data.json`: A's prebuilt data. `mock_a/build_data.py` rebuilds it
  from `demo_data_dump.txt`, which is not kept (1 MB); regenerate it with
  `extract.js`.

**Screenshots and data extraction** use Playwright with system Chrome
(`channel:'chrome'`). The repo has no `node_modules`:

```sh
T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55 >/dev/null)
NODE_PATH=$T/node_modules node design/report_mocks_src/shot.js <html> out.png 1440 1000 light 1   # args: file out w h mode(dark|full|x) fullpage(1|0)
NODE_PATH=$T/node_modules node design/report_mocks_src/seg.js  <html> prefix normal 1000          # viewport-sized segments
NODE_PATH=$T/node_modules node design/report_mocks_src/extract.js                                 # -> demo_data_dump.txt (cwd)
```

`shot.js` prints the console-error count; keep it at 0.
