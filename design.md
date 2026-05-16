# Design system — AWR Timeline Comparison report

This document describes the **editorial** visual style of the generated
HTML report (the one produced by `awr_trend.sql`). It exists so that a
future agent — human or AI — can iterate on the look without re-reading
every section file.

The style is implemented as **pure CSS** in `sql/_style.sql`. Section
files (`sql/00_params.sql` ... `sql/10_db_time_summary.sql`) emit
**unchanged class names**; restyling happens only in `_style.sql` plus
the masthead markup in `00_params.sql`. Treat that as the contract: a
visual iteration is a CSS swap, not a section rewrite.

The same constraints from `CLAUDE.md` still apply:
- single self-contained HTML file (one ECharts CDN tag, nothing else),
- read-only against `DBA_HIST_*`,
- graceful degradation when the CDN is unreachable
  (`body.no-charts` hides chart divs; tables still render every number),
- inline-SVG sparklines must keep working offline.


## 1. Visual identity in one sentence

A magazine-style data report on warm off-white paper: bold black
headlines paired with **big red section numerals**, hairline-ruled
tables, pill-shaped param chips, and editorial cards with a coloured
left sidebar. Reading rhythm is "open spread → headline → numbers".


## 2. Design tokens

All tokens live in `sql/_style.sql` as CSS custom properties on
`:root`. To change the look, change the tokens — everything cascades.

### 2.1 Palette

| Token | Hex | Used for |
|---|---|---|
| `--paper` | `#f6f4ef` | Page background, warm off-white |
| `--panel` | `#ffffff` | Card / chart panels |
| `--panel-2` | `#fbfaf6` | `pre.sql` block, alt panel |
| `--ink` | `#111111` | Primary text, headlines, sparkline lines |
| `--ink-soft` | `#2b2b2b` | Body copy in cards / lists |
| `--muted` | `#6b6b6b` | Captions, axis labels, table column heads |
| `--rule` | `#1f1f1f` | Heavy rule under masthead and `<thead>` |
| `--hairline` | `#e2dfd7` | Light table rules, panel borders |
| `--line-soft` | `#ece9e1` | Reserved soft divider |
| `--red` | `#e2231a` | Brand red — section numerals, chip dot, hover, links inside tables |
| `--red-deep` | `#b51a13` | Reserved (hover state) |
| `--chip-bg` | `#ebe8e0` | Param chip background |
| `--track` | `#e6e2d8` | Bar-comparison track |

### 2.2 Severity

Five mandatory levels. `_style.sql` keeps them in lock-step with the
labels emitted by sections 07 (findings) and 08 (overview). If you add
a sixth, update both the CSS *and* the case-statements in those two
files (see "Severity classes" in `CLAUDE.md`).

| Token | Solid | Tint |
|---|---|---|
| `--crit` | `#c0231b` | `--crit-bg #fbeae8` |
| `--warn` | `#d28a00` | `--warn-bg #fdf2dd` |
| `--ok` | `#2f7d3a` | `--ok-bg   #e6f3e9` |
| `--info` | `#4a6f8a` | `--info-bg #e8eef4` |
| `--skip` | `#8a8a8a` | `--skip-bg #ececec` |

Mapping: `CRITICAL → crit`, `WARN → warn`, `OK → ok`, `INSUFFICIENT_HISTORY` /
`FLAT_BASELINE` → `skip`, informational → `info`.

### 2.3 Wait-class palette

Mirrors `sql/lib/js_wait_colors.plsql` (which is the source of truth
for ECharts series colours). The CSS tokens below are used **only for
in-page swatches in tables** so the table reads the same as the chart
above it.

```
--wc-cpu          #3FB344
--wc-userio       #4A90D9
--wc-sysio        #1F4E89
--wc-commit       #E89B40
--wc-concurrency  #8B0000
--wc-application  #D62728
--wc-network      #967259
--wc-cluster      #E5C228
--wc-config       #793C32
--wc-admin        #7B6FA8
--wc-sched        #88C070
--wc-queue        #E89BB7
--wc-other        #C77CB0
```

If you change a colour, change it in **both** files. There is no
single-source mechanism — one is CSS for tables, one is JS for charts.


## 3. Typography

| Role | Font stack | Size | Weight | Notes |
|---|---|---|---|---|
| Headline (`<h1>`) | `"Soehne","Inter",system-ui,sans-serif` | 48 px | 800 | Letter-spacing −0.02em. `<em>` inside is red, not italic. |
| Section heading (`<h2>`) | same | 26 px | 800 | Big red numeral injected via `::before`. See §5. |
| Subsection (`<h3>`) | system sans | 11 px | 700 | Uppercase, letter-spacing 0.10em, muted colour. |
| Body | `"Inter",system-ui,sans-serif` | 15 px | 400 | Line-height 1.55. |
| Numbers in tables | inherit | 13 px | 400 | `font-variant-numeric: tabular-nums` everywhere. |
| Code / `sql_id` | `ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace` | 12 px | 400 | |
| Chip / TOC label | system sans | 12 px | 500–700 | Letter-spacing 0.04em. |

The body uses `-webkit-font-smoothing: antialiased` to keep weights
crisp on macOS. We intentionally do not load any web fonts — Söhne is a
fallback that gracefully degrades to Inter.


## 4. Page layout

```
+---------------------------------------------+
| header.report   (editorial masthead)        |
|   .brandline                                |
|   .topgrid    h1               .meta        |
|   .params     [chip] [chip] [chip] ...      |
|   .windows-list                             |
+---------------------------------------------+
| nav.toc      (sticky, hairline-ruled)       |
+---------------------------------------------+
| section#db-time-summary                     |
|   h2  → "01 Database time …"                |
|   ...                                       |
| section#overview                            |
|   h2  → "02 Headline metrics"               |
|   .hero-grid (6 cards, 2 rows × 3)          |
| ... 8 more sections ...                     |
+---------------------------------------------+
| footer.report                               |
+---------------------------------------------+
```

- **Page width**: `max-width: 1180px`, centred. Side padding is 56 px
  desktop / 22 px mobile.
- **Vertical rhythm**: each `section` carries `margin-top: 48px`.
- **`flex-direction: column` on `body`** + `order:` on each section is
  what reorders source-emission order to visual order. The driver
  emits sections 00…10 in numeric order; CSS pulls them into the
  reading order described in §5.


## 5. Section numbering

The big red numerals **are not in the markup**. They are injected by
`#section-id h2::before { content: "NN"; }` rules in `_style.sql`.

The visual order (and therefore the numerals) is fixed:

| # | Section ID | h2 emitted by | Why this order |
|---|---|---|---|
| 01 | `db-time-summary` | `10_db_time_summary.sql` | The headline answer: how was DB time spent? |
| 02 | `overview` | `08_overview.sql` | Six headline-metric hero cards |
| 03 | `ash-timeline` | `09_ash_timeline.sql` | Visual timeline first, before tables |
| 04 | `findings` | `07_summary.sql` | Z-scored "what changed" list |
| 05 | `windows` | `01_windows.sql` | Provenance: which AWR snaps fed it |
| 06 | `load` | `02_load_profile.sql` | Per-second SYSSTAT counters |
| 07 | `metrics` | `03_sysmetric.sql` | SYSMETRIC averages |
| 08 | `waits-fg` | `04_waits_fg.sql` | Foreground waits + class roll-up |
| 09 | `waits-bg` | `05_waits_bg.sql` | Background waits |
| 10 | `topsql` | `06_top_sql.sql` | Top-N SQL ranked four ways |

> **CSS counters are not used** because counters increment in source
> order, but `order:` reflows visual order. Per-section explicit
> numerals stay correct under any flex reorder.


## 6. Components

### 6.1 Editorial masthead — `header.report`

```html
<header class="report">
  <div class="brandline">● AWR / TIMELINE COMPARISON</div>
  <div class="topgrid">
    <h1>Friday <em>15:00</em><br>Hour-over-hour trend
      <span class="badge info">run …</span>
    </h1>
    <div class="meta">
      <div><b>CDB1</b> · DBID …</div>
      <div>Host <b>dbmint</b> · 19.0.0.0.0</div>
      <div>Generated <b>…</b></div>
      <div>Run by SYSTEM · read-only, no scratch schema</div>
    </div>
  </div>
  <div class="params">
    <span class="chip dot">target_end <b>…</b></span>
    <span class="chip">win <b>15m</b></span>
    <span class="chip">back <b>4 × 15m</b></span>
    ...
  </div>
  <div class="windows-list">
    <b>Compared windows (Friday, 15m each, every 15m):</b>
    <ul>
      <li><b>Current:</b> 14:45 → 15:00</li>
      <li><b>−15m:</b> 14:30 → 14:45</li>
      ...
    </ul>
  </div>
</header>
```

Rules:
- `.brandline .dot` is the red bullet, `.slash` is the red `/`.
- `<h1> em` is the **same weight** as the headline — it is red, not
  italic. The `<em>` carries semantic emphasis and is recoloured.
- `.meta` is right-aligned text (block, not flex), so wraps cleanly
  under the headline on narrow widths.
- `.windows-list` lists every comparison window with red square
  bullets; it stays *inside* the masthead (above the rule) so the
  reader knows the provenance before scrolling.

### 6.2 TOC nav — `nav.toc`

Sticky, top of viewport. Hairline-ruled top and bottom. Format:

```
SECTIONS · 01 DB time · 02 Overview · 03 ASH timeline · …
```

Anchors point at section IDs from §5. `<b>Sections</b>` is the
left-most label (uppercase, muted). Hover state: text turns red.

### 6.3 Numbered section heading — `<h2>` per section

```
[ 04 ]  Findings summary
```

The `[ 04 ]` is a `::before` pseudo-element styled at 38 px / 800
weight in `--red`. Nothing in the section file itself carries the
numeral — that is the point.

The `h2` is `display: flex; align-items: baseline; gap: 18px` so the
numeral and the title share a baseline. The numeral has
`min-width: 56px` so all 10 section heads start at the same column.

### 6.4 Editorial card — `.hero-card`

Used by section 02 (overview hero strip) and reusable for any future
"feature card". Visual: white panel, hairline border on all sides — no
coloured left rule. Severity is communicated by the badge/delta chips
inside the card, not by the frame.

Children (already emitted by `08_overview.sql`):
- `.label` — eyebrow, uppercase
- `.value` — big tabular-num figure with optional `<small>` unit
- `.mini` — 48 px sparkline canvas
- `.foot` — row containing `.deltas` (a list of `.delta.up/.down`
  chips, each with a `.dp` decimal-pixel hint)

Grid wrapper: `#overview .hero-grid` is 3 columns at desktop (so the
6 cards lay out as 2 rows × 3), 2 at ≤900 px, 1 at ≤520 px.

### 6.5 Tables

Convention across all sections:
- No outer border, no rounded corners. Rules are hairlines
  (`--hairline`) horizontally only.
- `<thead>` rule is **1.5 px solid `--rule`** (heavy black). Column
  heads are uppercase, 11 px, letter-spaced, muted colour.
- `tbody td` numeric cells use `td.num` for right-alignment +
  `tabular-nums`.
- Hover row tint: `rgba(0,0,0,0.02)`.
- Row severity classes (`tr.crit`, `tr.warn`, …) tint the row and
  inset a 3 px coloured rule into the first cell. `tr.info` tints
  background only; `tr.skip` italicises and mutes text.

### 6.6 Badge — `.badge.<severity>`

Pill, 10.5 px, uppercase, white text on solid severity colour.
Replaces the old "outline + tint" badges from the dense design.

### 6.7 Sparkline — `svg.spark`

Inline SVG, 96 × 18 px, emitted by `sql/lib/js_sparkline.plsql`.

- `.line` uses `currentColor` (default `--ink`); sections may add
  `.warn` or `.crit` to switch hue.
- `.dot` is the rightmost data point and is always `--red` (matches
  the brand).
- `.fill` is a faint area fill at 6 % alpha.

The renderer has a flatness floor (≈ 2 % range/mean) → midline instead
of a zigzag of imperceptible noise. Don't change that; it keeps the
"nothing happened" rows visually quiet.

### 6.8 Cell-bar — `td.cell-bar`

Subtle horizontal bar behind the current-value cell in the load /
metric / wait tables. Background tint at 10 % red, **2 px right edge**
in `--red`. The numeric value sits above the bar via `.v` (z-index 1).

### 6.9 Charts

- Container: `.chart-wrap` — white panel, hairline border, 8 px pad.
- Heights: `.chart-big 340 / .chart-medium 240 / .chart-small 160 /
  .chart-ash 420`.
- All ECharts: transparent backgrounds; let `--paper` show through
  the panel pad.
- `body.no-charts` hides every `.chart-wrap` and `.hero-card .mini`.
  The amber `.cdn-warn` banner explains why. Tables remain.

### 6.10 Windows ribbon — `.ribbon`

A 64 px tall horizontal track filled with five segments (one per
window) by `01_windows.sql`. The current window is filled red; prior
valid windows are white with a hairline; a skipped window is dimmed.
The SVG is generated from PL/SQL (no JS needed).

### 6.11 Disclosures + SQL — `<details>`, `pre.sql`

Used by Top SQL (section 10) to hide full statement text behind a
"SHOW SQL" toggle. The summary chip is red, uppercase, 12 px.
`pre.sql` sits in `--panel-2` with a hairline border.


## 7. Print

The print stylesheet at the bottom of `_style.sql` strips the sticky
TOC, drops the page max-width, prevents `.chart-wrap` from breaking
across pages, and keeps `<h2>` anchored to the next section.


## 8. What you can change without breaking anything

- **All design tokens** in `:root` — palette, severity, wait-class
  colours.
- **Typography stack** (replace Söhne with another display face).
- **Section visual order** — change `order:` on each `#id` *and* the
  per-section `h2::before` numerals together.
- **Card and table chrome** — borders, paddings, severity tinting.

## 9. What requires a coordinated change

If you touch any of these, expect to edit a section file too:

- **Severity vocabulary** — adding `notice` / `attention` etc. needs
  matching CASE arms in `07_summary.sql` and `08_overview.sql`.
- **Wait-class palette** — must be edited in *both*
  `sql/_style.sql` (CSS swatches) and `sql/lib/js_wait_colors.plsql`
  (ECharts series colours). They are the same numbers in two files.
- **Hero strip card count** — 6 cards is hand-rolled in
  `08_overview.sql`. Adding/removing cards changes the
  `#overview .hero-grid` column rules in `_style.sql`.
- **Anchor IDs** (`#findings`, `#topsql`, …) — referenced in
  `_style.sql` `order:`, `h2::before`, and in the TOC `<a href>`
  links emitted by `00_params.sql`. Three places. Treat them as a
  contract.

## 10. Tilde gotcha (PL/SQL emission)

Every numbered section file issues `SET DEFINE '~'` so it can read
substitution variables like `~run_id`. This makes `~` the live
substitution character — **any literal `~` in CSS, JS, or comments
will trigger an "Enter value for …" prompt** and silently truncate
the section in non-interactive runs.

`_style.sql` flips to `SET DEFINE OFF` before the `<style>` block and
restores `SET DEFINE '~'` at the end. Do the same in any new file
that emits a literal `~` — or just don't write `~` outside the
designated places.

## 11. How to iterate

- **CSS-only tweak**: edit `sql/_style.sql`, sync to dbmint, generate
  one report, eyeball it. The "Verification state" section in
  `CLAUDE.md` describes the byte-identity convention you can use to
  prove a change is presentation-only against a SQL refactor.
- **New visual element**: add a class to `sql/_style.sql`, then emit
  the markup from the relevant section file. Keep the markup minimal
  — sections should not set inline styles (a few legacy
  `style="margin-top:10px"` calls in `00_params.sql` are now in CSS;
  prefer that pattern).
- **Whole-section restyle**: prefer to keep the current `<table>` /
  `<section>` shape and restyle. The data model is what it is; the
  presentation layer is interchangeable.

## 12. References

- `sql/_style.sql` — single source of truth for the design system.
- `sql/00_params.sql` — masthead / nav markup; the only section
  whose markup is directly tied to this design.
- `sql/lib/js_wait_colors.plsql` — chart series palette.
- `sql/lib/js_sparkline.plsql` — inline-SVG sparkline renderer.
- `CLAUDE.md` — non-obvious project conventions, especially the
  read-only invariant, the tilde gotcha, and the byte-identity
  convention.
- `reports/mockup/awr_redesign_mockup.html` — frozen visual reference
  for this design (a static HTML mockup, not generated by SQL).
