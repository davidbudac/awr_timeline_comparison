# Handoff: single-DB report redesign mockups (2026-09-24)

**Status:** three design mockups built and reviewed. Nothing implemented in
`sql/`, nothing committed, **no direction chosen by the owner yet.** The next
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
| `design/report_mocks_src/` | builder sources and data for all three (see "Rebuilding") |
| `design/report_mocks_src/COMMON_BRIEF.md` | the shared design brief the mocks were built from: problems, data story, hard constraints |

Each mock is one self-contained HTML file (122–219 KB). It uses no CDN and no
external fonts. Charts are inline SVG or CSS, and it works in light and dark
mode and at 390 px. Every mock loads with 0 console errors. A dark
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

## Where it lands in the code (for planning)

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
one visual style. It costs ECharts' zoom, tooltips and legend toggling.

## Open questions for the owner

1. Which direction, or which combination? Is the recommended hybrid acceptable?
2. Keep ECharts for the big charts, or go inline-SVG only (like the fleet
   report)?
3. A: is a generated verdict sentence acceptable, or should it stay
   structured lines like today's "What changed"?
4. B: should Top SQL, segment and file rows get z-scores? That is new scoring,
   and it affects the policy, 07 and the demo.
5. C: Normal view, Full view, or a separate tab?

## Rebuilding / verifying the mocks

The mocks are the source of truth; you can edit the HTML directly. The
builders in `design/report_mocks_src/` regenerate them **byte-identically**
(verified 2026-09-24). Each writes straight to its `design/report_mock_*.html`
by absolute path:

```sh
sh   design/report_mocks_src/mock_a/build.sh      # template.html + data.json
python3 design/report_mocks_src/mockb/build.py    # template.html + tables.json + ../demo_series.json
python3 design/report_mocks_src/c_build/gen.py    # style.css + app.js + body.html + tables.json + ../demo_series.json
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
