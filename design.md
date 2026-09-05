# Design system — AWR Timeline Comparison report

This document describes the **workbench** visual style of the generated
HTML report (the one produced by `awr_trend.sql`). It exists so that a
future agent — human or AI — can iterate on the look without re-reading
every section file. (The previous **editorial** style lives in git
history; `design/redesign_directions.html` holds the five-direction
exploration that chose this one.)

The style is implemented as **CSS in `sql/_style.sql` plus a small
static JS block in `00_params.sql`** (the live status rail — see §5).
Section files emit **unchanged class names**; restyling happens only in
`_style.sql` plus the masthead/nav markup in `00_params.sql`. Treat that
as the contract: a visual iteration is a CSS/nav swap, not a section
rewrite.

The same constraints from `CLAUDE.md` still apply:
- single self-contained HTML file (one ECharts CDN tag, nothing else),
- read-only against `DBA_HIST_*`,
- graceful degradation when the CDN is unreachable
  (`body.no-charts` hides chart divs; tables still render every number),
- inline-SVG sparklines must keep working offline,
- all rail JS is inline and CDN-free, so the rail works offline too.

## 1. Visual identity in one sentence

An app-chrome workbench on a cool light-gray canvas: a fixed left
sidebar acts as a **live status rail** (grouped section links with
severity dots and a scrollspy highlight), content sections are white
panels, **teal** marks everything interactive/current, and red is
reserved exclusively for severity.

## 2. Design tokens

All tokens live in `sql/_style.sql` as CSS custom properties on
`:root`. To change the look, change the tokens — everything cascades.

### 2.1 Palette

| Token | Hex | Used for |
|---|---|---|
| `--paper` | `#eef1f4` | Page background, cool gray |
| `--panel` | `#ffffff` | Section panels, cards |
| `--panel-2` | `#f7f9fb` | Rail background, `thead`, `pre.sql`, hero cards |
| `--ink` / `--ink-soft` / `--muted` | `#1f2530` / `#3b4454` / `#5b6a80` | Text hierarchy |
| `--rule` / `--hairline` / `--line-soft` | `#c8d2dd` / `#dde3ea` / `#e9eef3` | Border hierarchy |
| `--accent` | `#0d9488` | Teal — links, active toggles, chart accents, current-window tint |
| `--accent-deep` / `--accent-bg` | `#0b3f39` / `#e2ecea` | Scrollspy-active link text / background |
| `--red` / `--red-deep` | `#d63b3b` / `#b42121` | Severity only (never brand/interactive) |
| `--dot-ok/warn/crit/na` | see file | Rail status dots |
| `--rail-w` | `236px` | Rail width; body clears it with padding-left |
| `--fg` / `--border` | `#3b4454` / `#dde3ea` | Read by chart-init JS for axis text / gridlines |
| `--crit-fg` / `--warn-fg` | `#b42121` / `#9a6b00` | Read by section 08's severity-tinted hero minis |

### 2.2 Severity

Five mandatory levels (`crit / warn / ok / info / skip`), each with a
`--<level>` foreground and `--<level>-bg` tint. Badges are now **soft
chips** (tinted background + colored text), not solid fills. Same
lock-step rule as before: a new severity updates `07_summary.sql`,
`08_overview.sql`, and `_style.sql` together.

### 2.3 Wait-class palette

Unchanged from the editorial design: `--wc-*` tokens kept in parity
with `js_wait_colors.plsql` so on-page swatches match ECharts series.

## 3. Typography

System Inter stack (`"Inter","Helvetica Neue",...,sans-serif`) at a
14px base. No display face: headings are just heavier/tighter Inter
(masthead h1 24px/700, section h2 18px/700 with a soft underline).
Monospace (`td.mono, code, .mono`) keeps `text-transform:none` — that
rule is load-bearing for case-sensitive sql_ids.

## 4. Page layout

- `body` is still a flex column; **visual order is set with `order:`**
  in `_style.sql`, grouped to match the rail: Triage (DB time, Overview,
  ASH timeline, Findings, Windows) → Workload (Utilization, Load,
  Metrics, FG/BG waits) → SQL (Top SQL, Top SQL ASH) → Storage & config
  (Segment I/O, File I/O, Parameters).
- The rail is `position:fixed; left:0; width:var(--rail-w)`; the body
  clears it with `padding-left:calc(var(--rail-w) + 32px)` and caps the
  content column at 1150px.
- Below 980px the rail is replaced by a **sticky top bar** (brand strip +
  a ☰ hamburger button, tracking the scrollspy's current section name)
  instead of degrading to a wrapping block; the hamburger opens a dropdown
  holding the same links/dots and the Essential/App-only/Triage toggles,
  and the body padding resets to single-column flow.
- Sections are white panels (`border:1px solid var(--hairline);
  border-radius:10px`). The old numbered `h2::before` numerals are gone
  — the rail does the wayfinding.

## 5. The live status rail (nav.toc) — the signature element

Markup is emitted by `00_params.sql`: group labels as `<b>`, section
links as `<a href="#id">`, and the Application-only `<button>` pinned to
the rail foot with `margin-top:auto`. Two inline scripts (same file,
right after the nav) make it live:

1. **Status dots.** On DOMContentLoaded, every rail link gets a
   `span.st` dot graded from the severity classes already present in
   its target section — worst wins: any `.crit` → red; else `.warn` or
   `td.chg` (changed parameter cells) → amber; else any real data row
   (`tbody tr:not(.skip) td`, `.hero-card`,
   `.ash-sql-card:not(.insufficient)`) → green; else neutral gray.
   Purely client-side, so the dots always agree with the tables and
   need no extra SQL pass. Note the sparkline severity tints
   (`svg.spark.crit/.warn`) count as signals — deliberately, a section
   whose sparklines flag a z-breach should light up.
2. **Scrollspy.** Highlights (`a.on`) the last section whose top passed
   the upper quarter of the viewport. A throttled scroll listener plus
   a 400ms `scrollY` poll fallback — NOT IntersectionObserver or rAF,
   which embedded webviews throttle to a standstill. Sections hidden by
   the app-only filter (`offsetParent === null`) are skipped, and the
   `awr:appfilter` event re-runs the spy.

The JS ↔ CSS contract: dots are `nav.toc a .st(.ok|.warn|.crit)`,
active link is `nav.toc a.on`. If you rename those, change both files.

## 6. Components (deltas vs the section-emitted markup)

- **Masthead** (`header.report`): a compact identity panel (brandline,
  24px headline, right-aligned run metadata, verdict banner, windows
  strip). Verdict banner keeps its `v-ok/v-crit/v-skip` container tints.
- **Tables**: `thead` on `--panel-2` with a 1px `--rule` underline;
  row hover uses `--panel-2`; severity rows keep tinted background +
  inset left rule.
- **Hero cards**: `--panel-2` cards, radius 8, no red stripe.
- **Charts**: `.chart-wrap` radius 8; chart-init JS reads `--fg`,
  `--border`, `--accent` (the masthead strip and current-window band
  are teal now — red bands would read as "critical").
- **App-only toggle**: rail-foot button; pressed state solid teal.
  The kept-section list is still single-sourced in three places that
  must stay in lockstep (section-hide rule, link-hide rule, and the
  set itself); group labels hide wholesale when the filter is on.
- **Tabs** (`.tabs[data-tabs]` / `.tabpanel`): a flat underline-style tab
  bar (active tab gets the teal underline + ink text, inactive tabs
  `--muted`). Used to fold Top SQL's five ranking dimensions into one
  group instead of five stacked tables.
- **Chips** (`.chip`, and the `.wchip` window-chip variant): small
  rounded-pill badges — window chips in the masthead, rank chips
  (E/C/G/R/X) in the Top SQL pool table. `.wchip.hl` (the active/
  highlighted state broadcast by `awr:window`) gets the teal fill;
  otherwise a neutral `--panel-2` pill with a hairline border.
- **Expander** (`.expander[data-for]`): a plain-text "Show N more rows"
  link-button under a long table; toggles `.open` on the table named by
  `data-for` (rows past the fold carry `data-tail="Y"` and are CSS-hidden
  until then). No icon — the label text itself flips to "Show fewer".
- **Heat-tinted prior cells** (`td[data-dev]`): a soft background tint
  (increasing opacity 1→2→3) on a prior-window value cell when it
  deviates from that row's Current value — a fast visual "this one
  didn't move much" vs "this one is way off" scan across a wide table
  without reading every number.
- **"Biggest movers" table** (`#findings-movers`): replaced the old
  `#findings-heatmap` ECharts canvas. A plain table, top 8 rows by
  `|z|`, each with a horizontal log-scaled bar (`.zbar`) sized off
  `|z|` and colored by severity — same severity tokens as the badges,
  no new color introduced. Renders identically with `body.no-charts`.
- **Narrative block** (`#narrative-slot` in the masthead / `.narr`
  content from section 17): plain paragraphs, no card chrome of its own
  — it sits directly under the verdict banner so it reads like part of
  the masthead. Links inside it (`<a href="#topsql">` etc.) use the
  ordinary link color, not a special "narrative link" style.

## 7. Print

Rail/top-bar hidden, body padding reset, panels borderless, one section
per printed page (`section { break-before:page }`, first section
exempted), charts keep `break-inside:avoid`. Long-tail rows print in
full regardless of expander state (`tr[data-tail="Y"] { display:
table-row !important }`) and `details.method` prints open with its
`<summary>` hidden, so the reader gets the full methodology text, not a
closed disclosure triangle. Controls that have no meaning on paper
(`.tbl-tools`, `.copy-btn`, `.permalink`, `.expander`, `.tag`,
`.preset-note`, `.next-finding`, `.windows-hint`, the theme button) are
hidden outright. Tabs are **not** specially handled — a `.tabpanel`
prints only if it currently has `.on` (whichever tab was last active in
the browser), same as any other client-side visibility toggle; there is
no "print all tabs" behavior.

## 8. What you can change without breaking anything

Token values, radii, spacing, the rail width (`--rail-w` cascades into
the body padding), group labels' wording, dot colors.

## 9. What requires a coordinated change

- Severity levels (07 + 08 + `_style.sql`).
- App-only kept-section set (hide rule + link rule + intent).
- Rail markup shape (`nav.toc b` / `a[href^="#"]`) ↔ the rail JS.
- `--fg` / `--border` / `--accent` / `--crit-fg` / `--warn-fg` names —
  chart-init JS in sections 00/04–15 and `js_markers.plsql` reads them
  via `getComputedStyle`.
- Section `order:` grouping ↔ the rail's link order (the scrollspy
  walks the rail top-to-bottom and assumes both agree).

## 10. Tilde gotcha (PL/SQL emission)

`_style.sql` runs under `SET DEFINE OFF` (pure static CSS), but
`00_params.sql` runs under `SET DEFINE '~'` — no literal `~` anywhere,
including inside the rail JS or CSS strings emitted there.

## 11. How to iterate

Fastest loop while dbmint is unavailable: render the static emissions
with a PUT_LINE extractor and splice them into an existing report
(style block + nav/scripts block are deterministic text), then check in
a browser. Final verification is always a real run on dbmint —
`./lint.sh` first, then the byte-level checks in `CLAUDE.md`.
