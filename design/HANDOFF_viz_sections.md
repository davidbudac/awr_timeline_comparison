# Handoff: the visualization sections (20-28) and the fleet co-anomaly grid

> **Implemented** (2026-11-19, branch `feat/new-visualizations`): all ten
> items are merged; the as-built notes live in `CLAUDE.md` ("Visualization
> sections (20-28)", and "Co-anomaly grid" under the fleet report). This
> file is kept as the contract a new view of the same kind should follow;
> the dbmint dates below have since aged out of its 35-day AWR retention.

Ten new views are added to the report, one owner each, built in parallel in
separate checkouts and merged afterwards.  This file is the shared contract;
your task message names YOUR item and its specifics.  Read `CLAUDE.md`
first (conventions and gotchas: they all apply), then this file.

Visual spec: `design/viz_ideas_mock.html` (open it; item N is
`<section class="idea" data-idea="N">`, drawn by function `cN` in its
script).  Take the FORM from the mock (encodings, legend, "reads as"
sentence, wording level); the data is real and the look comes from the
report's own tokens, not the mock's.

| # | Section file | `<section id>` | lib base | Views | `--os` | Shows after (All sections) |
|---|---|---|---|---|---|---|
| 1 | `sql/20_load_response.sql` | `load-response` | `loadresp` | `vw in-s in-a lib` | 10 | Findings |
| 2 | `sql/21_volume_cost.sql` | `volume-cost` | `volcost` | `vw in-s in-a lib` | 11 | Top SQL |
| 3 | `sql/22_wait_histogram.sql` | `wait-hist` | `waithist` | `vw in-s in-a lib` | 12 | Foreground waits |
| 4 | `sql/23_plan_flame.sql` | `plan-flame` | `planflame` | `vw in-s in-a lib` | 13 | SQL Monitor |
| 5 | `sql/24_blocking.sql` | `blocking` | `blocking` | `vw in-s in-a lib` | 14 | Background waits |
| 6 | `sql/25_onset.sql` | `onset` | `onset` | `vw in-s in-t in-a lib` | 15 | DB time |
| 7 | `sql/26_window_similarity.sql` | `win-sim` | `winsim` | `vw in-s in-a lib` | 16 | Windows |
| 8 | `sql/27_instance_map.sql` | `instance-map` | `instmap` | `vw in-s in-a lib` | 17 | Findings |
| 9 | `sql/28_release_delta.sql` | `release-delta` | `reldelta` | `vw in-s in-a lib` | 18 | Findings |
| 10 | fleet (`run_awr_fleet.sh`, `sql/fleet/*`) | n/a | n/a | fleet report | n/a | n/a |

## What the scaffold already did (do not redo, do not edit)

- `awr_trend.sql` @@-includes each section (DOM position chosen so the All
  sections order works) and `sql/lib/viz_head.sql` (the nine stylesheets, in
  `<head>` after `_style.sql`, before the design's stylesheet).
- `sql/00_params.sql` + its twin have the rail links (`data-nodot`);
  `sql/_style.sql` has the All sections `order`; `demo/gen_demo_report.py`
  has the `SECTIONS` slots and the stylesheet includes.
- Stub files exist for every section: the SQL, `sql/lib/src/js_<base>.js`,
  `sql/lib/src/css_<base>.css`, their generated `sql/lib/js_<base>.plsql` /
  `css_<base>.plsql`, and the demo twin `demo/awrdemo/sections/sNN_<name>.py`.

## Files you own (items 1-9)

Replace / edit ONLY these, plus new private files whose name starts with
your lib base (for example `sql/lib/<base>_cte.sql`):

    sql/NN_<name>.sql
    sql/lib/src/js_<base>.js      -> tools/js2plsql.sh js_<base>
    sql/lib/src/css_<base>.css    -> tools/js2plsql.sh css_<base>
    sql/lib/js_<base>.plsql, sql/lib/css_<base>.plsql   (generated; the
        header comment above BEGIN is yours to write)
    demo/awrdemo/sections/sNN_<name>.py

Everything else is off limits: the driver, `00_params.sql`, `_style.sql`,
every other section, every shared `sql/lib/*` file, `demo/awrdemo/model.py`,
`helpers.py`, `chrome.py`, `gen_demo_report.py`, `demo/verify_report.js`,
`lint.sh`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`, `docs/`.  Nine other
owners are editing in parallel and every shared edit is a merge conflict.
If you need a shared change, do NOT make it: describe it (exact file, exact
text) in your final report and work around it in your own files meanwhile.
Never write `docs/examples/*.html` (generate the demo to a scratch path).

## Section contract

- Keep the scaffold's `<section id>`, classes, `--os` and both
  `AWR-SECTION` marker lines exactly (you may add `lopen` to the class list
  when the section has something worth opening the row for).  The section
  is ALWAYS emitted, also with no data: h2 + a one-line `p.note` that says
  why (the rail links to it; verify_report requires every `href="#x"` to
  hit exactly one id).
- Header: `<h2>Title<small class="h2sub">one plain line</small></h2>`.
- Evidence-library row text: `lib_ls('<id>', '<html>')` once
  (`sql/lib/band_glyph.plsql`; twin `helpers.lib_ls`): one short status
  sentence that answers the section's question for THIS run ("load is
  normal, each call 2.3x slower"), or the empty-state reason.
- Read-only: `SELECT` only.  `dbid IN (~dbid_list)`, the `inst_num`
  convention, valid windows from `@@sql/lib/windows_cte.sql`
  (`valid_windows` / `windows_rollup`), cadence via `~step_hours` (never a
  literal 7), `pairs -> bounds -> deltas` for cumulative counters,
  `DBMS_XMLGEN.CONVERT` on every user-visible string, `json_escape` for
  JSON strings, numbers NLS-safe, pure ASCII, no tilde, no bare SELECT.
- A skipped window is unknown, never zero.  Nothing may assume 13 windows:
  `weeks_back` goes to 168 and beyond (no per-window `LISTAGG` past 4000
  bytes, no PUT_LINE past 32767 bytes; build per-window JSON in a PL/SQL
  loop; big payloads through `put_clob_chunked`).  Overlapping windows
  (`win_hours > step_hours`) share samples.
- **New grants must not break old installs.**  `README.md` lists the
  exact `DBA_HIST_*` views a dedicated analyst user is granted.  If you
  read a view that is NOT in that list (`DBA_HIST_EVENT_HISTOGRAM`,
  `DBA_HIST_SQL_PLAN`, `DBA_HIST_OSSTAT`, ...), a missing grant must not
  abort the report (`WHENEVER SQLERROR EXIT` + static SQL = the whole run
  dies with ORA-00942).  Read such a view through dynamic SQL
  (`OPEN c FOR '...' USING ...` / `EXECUTE IMMEDIATE`) inside a block that
  catches ORA-00942 / ORA-01031 and renders a one-line "needs SELECT on
  ..." note; resolve the windows with static SQL first (an `@@` include
  cannot sit inside a string literal).  Name the view in your final report.
- Cost: every scan bounded (by snap range, by sql_id list, by the compared
  windows).  Report your section's time from the `debug=Y` markers.
- Payload: `window.AWR_DATA.<base> = {...}` in one inline `<script>`
  emitted by the section BEFORE its `@@sql/lib/js_<base>.plsql` line.
- Client script (`sql/lib/src/js_<base>.js`): an IIFE, no globals beyond
  an optional `window.AWR_<BASE>`; inline SVG only (no ECharts, no external
  anything; these views must work with the CDN blocked, so never put them
  in a `.chart-wrap`, which `body.no-charts` hides).  Draw when the plot
  has a width: a closed library row measures 0, so observe the container
  (`ResizeObserver`) and also redraw on `awr:view` and window resize.
  Colours from CSS (classes / `style="fill:var(--x)"`, never a
  `fill="var(--x)"` attribute) so the theme toggle and the quiet /
  dashboard designs restyle it with no listener.  Available globals:
  `AWR_WIN` (window metadata, oldest first), `AWR_WG.markers()` /
  `AWR_MARKERS` (release markers), `AWR_WAIT_COLORS`, `AWR_goTo(el, flash,
  persist)`, the shared tooltip element `#tip` that js_timeline creates
  (read `sql/lib/src/js_timeline.js` for how it is positioned and reuse
  its look).  Pure ASCII source: write `\uXXXX` escapes from a script, or
  avoid them (HTML entities through `innerHTML`); lint check 25.
- Stylesheet (`sql/lib/src/css_<base>.css`): every selector starts with
  `#<your section id>` (or a class prefixed with your lib base); use the
  report's tokens (`--acc`, `--acc-band`, `--crit-dot`, `--warn-dot`,
  `--imp`, `--zone1`, `--zone2`, `--track`, `--tick`, `--mean`, `--bar`,
  `--ink-2`, `--ink-3`, `--ink-4`, `--line`, `--panel`, `--muted`,
  `--hairline`, `--s1..--s8`; see `sql/_style.sql`), no hard-coded theme
  colours except the wait-class palette.  No tilde (the sibling combinator
  included), ASCII only.
- JS off / every number in tables: next to the chart emit a real HTML
  table of the numbers the chart draws (a `<details>` fold is fine when it
  is long).  With JS off the reader still gets the note and the table.
  Use `fmt_num` / `fmt_int` for value cells, `ent()` + `anchor_id()` for
  every link to another row (only to rows that are emitted; never a
  hand-written `class="ent"`), `data-w="k"` on window-indexed cells.
- Charts: one axis per chart, a legend, status as colour + glyph + word,
  hover tooltips with exact values, keyboard focus for anything clickable,
  `role="img"` + `aria-label` on the SVG, one "Reads as:" sentence under
  the chart computed from the data (in PL/SQL where you can, so it is
  there with JS off and can feed `lib_ls`).  Phone width (390 px): no
  horizontal page scroll (a wide plot scrolls inside its own box).
- PL/SQL declaration order (lint 14, 16, 17, 20, 22, 29): plain variables
  first, includes last, `metric_policy.plsql` first among them.  Reserved
  word `share`.  `x <> ''` is never true.  See CLAUDE.md "Gotchas".
- Scoring, when you score: only through `policy_bucket()` /
  `score_cells()`.  Never invent a second rule.

## Demo twin

`demo/awrdemo/sections/sNN_<name>.py` mirrors your SQL emitter line by
line (`demo/PORTING.md`).  The model must stay untouched: derive what it
lacks inside your twin with `w.rng(<stable key>)`, deterministic, and
consistent with the demo story (read `demo/awrdemo/model.py`: Release 4.2
flips the order-lookup statement's plan, the I/O findings, the markers).
Lift literal script lines with `chrome.put_lines`, your generated script
with `chrome.lib_script('js_<base>.plsql')`.

## Checks you must run (and iterate on) before you finish

1. `sh tools/js2plsql.sh js_<base> css_<base>` then `./lint.sh` clean.
2. Demo: `python3 demo/gen_demo_report.py <scratch>/demo.html`, also
   `--design=quiet` and `--design=dashboard`; two runs give the same md5.
3. Browser, your section only (do NOT run `demo/verify_report.js`: it
   takes minutes and parallel runs hang Chrome; the integrator runs it
   after the merge).  Write a small Playwright script
   (`NODE_PATH=/home/db/.npm/_npx/e41f203b7505f1fb/node_modules`,
   `chromium.launch({executablePath:'/usr/bin/google-chrome', args:['--no-sandbox']})`,
   `file://` URL): 0 console errors; Summary (row closed, then opened by a
   click on its h2), All sections, Timeline when you are in it; light and
   dark (`#theme-toggle`); the three designs; 1280 px and 390 px wide.
   Screenshot your section each time and LOOK at the screenshots (Read
   the PNGs): overlaps, clipped labels, unreadable dark-mode colours and
   default-blue links are defects to fix, not to report.
4. Real database, dbmint (Oracle 19c test VM; read-only report runs only,
   never DDL / DML, never open the standby).  ssh / rsync / scp need
   `dangerouslyDisableSandbox: true` on the Bash call (the sandbox blocks
   the host and it looks like a DNS failure).  Use YOUR OWN remote
   directory, never `~/awr_timeline_comparison`:

       rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex \
         --exclude=fleet.conf --exclude=docs/examples ./ oracle@dbmint:~/awr_viz_<NN>/ -e 'ssh -p 2200'
       ssh -p 2200 oracle@dbmint 'bash -lc "cd ~/awr_viz_<NN> && SQLMON=N ./run_awr_trend.sh \"/ as sysdba\" \"2026-11-08 15:00\" 1 8 10 0 1 h comprehensive Y"'

   (`bash -lc`: the login shell sets the Oracle environment.  `SQLMON=N`
   skips the slow SQL Monitor section; drop it if you depend on 18.)
   Facts about that database (probed 2026-11-19): AWR retention 35 days,
   history from 2026-10-15, 15-minute snapshots, many restarts.  The one
   long restart-free stretch is **2026-11-07 14:45 to 2026-11-09 16:15**;
   a second one is 2026-11-12 19:55 to 2026-11-13 10:45.  Runs that have
   valid windows and real activity:
   - A: `"2026-11-08 15:00" 1 8 10 0 1 h` -- Current 14:00-15:00 is a
     heavy blocking hour (2733 ASH samples, 2382 with a blocker) against
     eight quiet prior hours.
   - B: `"2026-11-09 15:00" 1 24 10 0 1 h` -- that incident (11-08
     14:00-17:00) sits in the PRIOR windows; Current is normal.
   - C: `"2026-11-13 10:00" 1 12 10 0 1 h` -- a busy night.
   - D: `"2026-11-09 15:00" 1 48 10 0 1 h` -- older windows straddle
     restarts (skipped windows), and `"2026-11-09 15:00" 1 2 10 0 1 d`
     has too little history (the insufficient-history path).
   - Markers: prefix `MARKERS='2026-11-08 12:30|Release 4.2;;2026-11-08 09:10|Config push'`.
   - Statements with several plans there: `4uwvvrnhxxp7t`,
     `fh0kj1mqjy19s`, `g4mvmfbz407fr` (seen to 11-08), `b84c2ncqhcw23`,
     `7n961y406m3ct` (seen to 11-13).
   Every run: exit code 0, 58 `AWR-SECTION` lines (29 pairs), no `ORA-` /
   `SP2-` outside captured SQL text, no output line past 32767 bytes.
   Copy the report back (`scp -P 2200`) and repeat step 3 on it.  Check
   your numbers against an independent read-only query for at least one
   value.  A window with data is required before you call it done; "the
   section rendered its empty note" is not a test of the chart.

## Finishing

Commit your work on the branch of your checkout (do not push, no PR).
Your final message must contain:

1. Branch and commit sha; the files you changed.
2. What the section shows, its data sources, its queries' cost on dbmint.
3. Test evidence: which dbmint runs, what you compared by hand, what the
   screenshots showed; anything you could NOT exercise, stated plainly.
4. Requests for shared-file changes, if any (exact text).
5. Ready-to-paste documentation text: (a) one `<dt>/<dd>` method note for
   the About fold (`sql/19_reference.sql`, HTML, ASCII), (b) one guide
   item for "Reading the charts" (title + two sentences), (c) a CLAUDE.md
   subsection in that file's style (what it is, payload shape, hooks,
   gotchas, what is unexercised), (d) one CHANGELOG bullet, (e) any new
   grant for the README.
