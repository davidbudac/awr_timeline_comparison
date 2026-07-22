# Fleet report redesign — design record (2026-07-22)

Context: fleet report v0.1.0 rendered one big stacked `<section class="db-card">`
per database (identity strip, hero-six headline grid, findings table, Top-SQL
table, drill command). With 10+ databases it was judged **too spread out** to
triage at a glance, and it had **no ASH timeline and no timeline markers**.

Three mockup directions were built (self-contained HTML, fake 7-DB fleet with a
"v2.3 deploy 03:10" / "OS patch 22:00" marker pair, one unreachable `DEADBOX`,
all honoring the fleet rules: inline SVG only, no ECharts, offline-complete,
`sql/_style.sql` design tokens, `js_wait_colors.plsql` wait-class palette):

| dir | file | idea |
|-----|------|------|
| A | *(not kept)* | current cards densified: 2-col grid, compact metric strip, per-card ASH chart |
| B | `fleet_mock_b_ops_console.html` | **implemented (v0.2.0)** — one dense console table, one row per DB, expandable detail |
| C | `fleet_mock_c_timeline_wall.html` | **archived here for a future redesign** — time-aligned ASH timeline wall |

## Option B — "Ops console" (the implemented direction)

One `<table class="fleet">`: per DB a collapsed `tr.dbrow` (status dot + alias,
score, crit/warn pills, current AAS, worst finding + z badge, DB-time
micro-sparkline, ~172px ASH ribbon with marker ticks) and a hidden
`tr.detailrow` (colspan panel: tall labeled-marker ASH timeline, compact
headline-metric cards, findings table, Top-SQL table, drill command). Masthead
carries run metadata, summary badges, wait-class legend, marker legend. Error
DBs are red-tinted rows whose expansion holds the masked connect + log tail.
~30 DBs fit collapsed on ~1.5 screens. Known tradeoffs: collapsed state shows
only the worst finding per DB; the narrow ribbon compresses the wait-class
stack (full detail one click away); the 8-column row rhythm wants ≥1100px.

## Option C — "Time-aligned fleet timeline wall" (KEEP for future redesign)

The centerpiece is a **shared-time-axis wall**: a sticky header carries one
24-hour axis with each fleet-wide event marker drawn once as a labeled flag;
beneath it, one horizontal band per database, every band's ASH stacked timeline
on the **identical x-scale**. The marker rules therefore cut vertically through
the entire fleet, and the compared window (e.g. 09:00–10:00) is a shaded column
across all bands.

**Killer feature:** "which databases reacted to the deploy?" is answerable in
one glance — look straight down the marker line. In the mock, ERPPRD's
Concurrency+CPU spike and BILLPRD's User-I/O bump both erupt exactly at the
deploy rule, while DWHPRD's nightly System-I/O humps visibly predate it.

Layout spec (as built in the mock):
- Sticky `axis-row`: fixed left rail (~210px, shared via a `--railw` CSS var so
  axis and bands align) + axis strip with hour ticks every 3h, marker flags
  (label pill + timestamp), and the compared-window shade + label.
- One `band` per DB: left rail = alias, status dot, severity score, crit/warn
  chips, current AAS, tiny 24h-total sparkline; right = stacked-by-wait-class
  SVG columns (24 hourly buckets, `viewBox="0 0 240 100"`, 10 units/hour,
  `preserveAspectRatio="none"` so every band stretches to the same width —
  that is what makes the vertical marker rules line up).
- **Per-band y-scale** with the y-max printed in the band corner ("14 AAS" vs
  "0.5 AAS") — honest, but band heights are NOT cross-DB comparable; the score
  in the rail is the ranking signal. Band height grades by severity (~70px
  sick, ~52px warn, ~38px quiet) so attention flows to the sick DBs.
- Unreachable DB = band with error-tinted rail + hatched timeline strip
  labeled with the ORA- code.
- Per-DB detail (compact metric cards, findings, Top SQL, drill) lives in
  collapsible drawers *below* the wall, not on it.

Tradeoffs recorded when the mock was reviewed:
- Triaging *what* broke costs one extra click (drawers) vs always-visible tables.
- The z-score story (current vs N-window baseline) is invisible on the wall —
  the wall shows only the 24h ASH span; findings stay in the drawers.
- The wall needs ~820px+ of width and scrolls horizontally on narrow viewports;
  desktop-first by design.

Future-work notes if C is revisited:
- C composes well *on top of* the B console: the wall could become a masthead-
  level overview above the console table (same per-DB ASH JSON reused), or the
  console could gain an "align timelines" toggle that swaps ribbon cells for a
  shared-axis column.
- Implementation-wise everything C needs beyond B already exists after v0.2.0:
  per-DB hourly ASH-by-wait-class data and fleet-wide marker JSON are in the
  page; C is "only" a different renderer + sticky-axis CSS.
- Keep the fleet cardinal rules: no ECharts / no external assets, single-DB
  files untouched, sentinel + FLEET-COUNTS contract intact.

Both mock files are fully self-contained — open them in any browser; each has a
light/dark toggle (top right). The fake data story to preserve when re-mocking:
sorted ERPPRD 46 / BILLPRD 21 / DWHPRD 9 / CRMPRD 3 / HRPRD 0 / ORDSTB 0 +
DEADBOX (ORA-12514), markers at 22:00 and 03:10, spike onset exactly at the
deploy marker.
