# Plan 023: In the Summary view the verdict comes first and the Activity charts open compact

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> 1. `git merge-base --is-ancestor 5594f2c HEAD && echo ok` → `ok`. If not,
>    your branch predates the report designs and sections 20-28 that this
>    plan is written against: STOP (branch from a `main` that contains
>    `5594f2c`).
> 2. `git diff --stat 5594f2c..HEAD -- sql/00_params.sql sql/_style.sql sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/lib/css_design.plsql sql/19_reference.sql demo/awrdemo/sections/s00_params.py demo/verify_report.js`
>
> If any of these changed since this plan was re-checked, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19;
  first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`. Since `ee23e49` the report
  gained three designs (`design` = classic / quiet / dashboard) and sections
  20-28. Changes to this plan:
  - All line numbers were refreshed. Most of `00_params.sql` moved down 12
    lines, and `_style.sql` from line 312 on moved down 7.
  - `js_timeline.js` `draw()` now picks the chart that prints the date
    labels (`c.xl`) and the release flags (`c.flags`) itself: the last and
    the first chart that is SHOWN. So Step 5 no longer needs its own `xl`
    variable. A hidden by-event chart makes the class chart print its
    dates automatically.
  - The dashboard design already leads its Summary with the verdict and
    KPI cards (CSS `order`). It already shows one Activity chart at a time
    with its own tabs. So the compact mode is switched OFF there (Step 5b),
    and the smoke test checks that.
  - The quiet / dashboard "How to read" popover shows the help line
    `p.axn2`. This plan's compact rule would hide that line, so a one-line
    override goes into the design stylesheet (Step 4b).
  - The demo now writes three pages, one per design, and the smoke test runs
    on all three (Step 9).
- **Owner decision required before Step 1**: see "Option A / Option B"
  below. The owner asked in v1.6.0 for the Activity charts to sit at the very
  top of every view. Option A (recommended) moves the verdict above them in
  the Summary view only. Option B keeps the charts on top and only makes
  them compact. The executor does Option A unless the operator says B.
  **New context (2026-11-19)**: verdict-first already exists, but only as
  the opt-in `design=dashboard` (the owner's chosen "original mock C").
  This plan changes the default `classic` design and the `quiet` design. If
  the owner wants classic to keep the v1.6 order and leave verdict-first to
  the dashboard, that is Option B.

## Why this matters

The report's Summary view is meant to answer "what is wrong in this
window?" on the first screen. Today the first thing a reader sees is two
stacked 200-px ASH charts covering the whole span (on the demo, three months
hourly); the one-sentence verdict starts about 850 px down a 1000-px-high
window at 1440 px wide, so on a laptop the answer is below the fold. This
plan puts the verdict first in Summary and shows one compact chart (by wait
class, about 170 px including flags and axis) with a button that brings back
the second chart (by wait event). The Timeline and All sections views keep
the charts exactly as they are, at the top.

### Option A / Option B (owner decision)

- **Option A (recommended, default for this plan)**: in the HTML the
  Activity section is emitted right AFTER the verdict hero. Because the
  verdict is Summary-only (`class="vw in-s"`), the Activity charts are still
  the first section in Timeline and All sections; in Summary they come second;
  with JavaScript off the verdict comes first. Summary shows them compact.
- **Option B**: the Activity section stays first everywhere; Summary only
  shows them compact. To do Option B, skip Step 2 and Step 7 and follow the
  "Option B" notes in Steps 6 and 9.
- **Both options, `design=dashboard`**: no visible change. That design's CSS
  `order` rules already put the verdict and its KPI cards above Activity in
  Summary. Its "By wait class / By wait event / Both" tabs already show one
  chart at a time, so this plan's compact mode and its button stay off
  there. With JavaScript off the dashboard falls back to the plain DOM order,
  like classic.

Target layout, Summary view, Option A:

```
+-- top bar ----------------------------------------------------------+
| Physical reads 5.4x normal, most of it on ORDERS_APP.ORDER_LINES;   |  <- verdict hero (unchanged)
| DB time up 79.7%, mostly wait.                                      |
| Likely source: ...        [4 findings] [11 metrics moved] ...       |
+---------------------------------------------------------------------+
| Activity, whole span                                                |
| 18 Jun to 10 Sep, hourly   key   [Show by wait event] [Reset zoom]  |
| By wait class  (legend)                                             |
| [ one stacked chart, plot 96 px high, flags above, dates below ]    |
+---------------------------------------------------------------------+
| DB time per window (hero strip, unchanged) ...                      |
```

Clicking "Show by wait event" shows the second chart and the help line and
switches the first chart back to its normal 150-px plot; the button then
reads "Hide by wait event". The reader's choice is remembered in this
browser (localStorage key `awr-ax`), written only when the button is
clicked — the same convention as the view switch (`awr-view`).

A visual reference (direction only, not a pixel spec) is the outline
numbered 4 in `plans/assets/ux-mockup-2026-11-17.html`; this plan does NOT
add the "Windows side by side" mode shown there (that is plan 024).

## Current state

### How the report is built (background)

- The report is one HTML file printed by SQL*Plus. PL/SQL blocks print the
  HTML line by line with `DBMS_OUTPUT.PUT_LINE('...')`. Inside a PL/SQL
  string a single quote is written `''`.
- `sql/00_params.sql` prints the top bar, the left rail, the
  `window.AWR_WIN` window list, the Activity section skeleton, the verdict
  hero and the Timeline skeleton.
- The client JavaScript of the charts lives in the readable source
  `sql/lib/src/js_timeline.js`. The file that runs, `sql/lib/js_timeline.plsql`,
  is GENERATED from it by `tools/js2plsql.sh js_timeline` (never edit its
  body by hand; its comment header above the `BEGIN` line is hand-written
  and kept by the generator).
- The report has three views. `body` carries exactly one of the classes
  `vs` (Summary), `vt` (Timeline), `va` (All sections). An element joins
  views with `class="vw in-s in-t in-a"` (one `in-*` per view that shows it).
- `demo/` is a docs-only Python twin that renders three demo pages without
  a database, one per report design: `docs/examples/demo_busy_db.html`
  (classic), `docs/examples/demo_busy_db_quiet.html` and
  `docs/examples/demo_busy_db_dashboard.html`. Its
  `demo/awrdemo/chrome.py` copies the CSS (`sql/_style.sql`, and for the two
  designs `sql/lib/css_design.plsql`) and the generated scripts
  (`sql/lib/js_*.plsql`) literally, and
  `demo/awrdemo/sections/s00_params.py` copies the Activity skeleton's
  PUT_LINEs literally from `sql/00_params.sql` by locating them by text.
  Every change to the SQL output must be followed by regenerating the demo
  and committing it (`./tools/check.sh` fails on a stale demo; `--check`
  covers all three pages).
- `demo/verify_report.js` is the headless browser smoke test (Playwright).
  It reads `window.AWR_DESIGN` (`classic` when absent) into its `DESIGN`
  variable and adapts a few checks to the dashboard.

### The report designs (`design` = classic / quiet / dashboard)

The same report has three looks, chosen when it is generated. They differ
in presentation only. `classic` (the default) adds nothing. `quiet` and
`dashboard` add one stylesheet and one script, which `awr_trend.sql`
includes after everything else:

- `sql/lib/src/css_design.css`, the readable source of the generated
  `sql/lib/css_design.plsql`. Regenerate it with `tools/js2plsql.sh
  css_design`, which wraps a `.css` source in `<style>`. It is emitted
  after `sql/_style.sql`, so it overrides it.
- `sql/lib/src/js_design.js`, the readable source of the generated
  `sql/lib/js_design.plsql`. `sql/lib/design_tail.sql` first writes
  `<script>window.AWR_DESIGN="quiet|dashboard";</script>` and then this
  script, after the footer. So `window.AWR_DESIGN` is already set when
  any `DOMContentLoaded` handler runs, including js_timeline's. The
  design script's own `DOMContentLoaded` handler is the page's LAST one.
- Project rule: never put design rules in `_style.sql`, nor design markup
  in a section. Design-only CSS goes in `css_design.css`.

What the designs do to the Activity block:

- **Both designs, "How to read"** (`howToRead()` in `js_design.js`): the
  help line `p.axn2` moves into the header row `.axh`, behind a
  `button.axhow`. `#ashx` gets the class `howable`, and a click toggles
  `#ashx.howopen`. In `css_design.css`:

  ```css
  .ashx.howable .axn2{display:none}
  .ashx.howable.howopen .axn2{display:block;position:absolute;z-index:25;right:0;...}
  ```

- **Dashboard only, the Activity tabs** (`activityTabs()`): a
  `div.seg.axseg` ("By wait class / By wait event / Both") is inserted into
  `.axh`, before `.axhow`. It toggles `#ashx.ax-cls-only` / `#ashx.ax-ev-only`
  (CSS `.ashx.ax-cls-only #ax-ev,.ashx.ax-ev-only #ax-cls{display:none}`),
  then calls `AWR_TL.redraw()`. It starts on "By wait class" and is exposed
  as `window.AWR_axMode(m)`.
- **Dashboard only, the Summary order**: `css_design.css` has
  `body.d-dash.vs main > #activity{order:5}`,
  `body.d-dash.vs main > #findings{order:6}`, and hides `#overview`. The
  script inserts a KPI row `div.dkpis.vw.in-s` right after `#verdict`. In
  the dashboard's Summary the order is therefore verdict, KPI cards,
  Activity, findings, whatever the DOM order is.

### The Activity skeleton, `sql/00_params.sql:1272-1309`

```sql
    -- =========================================================
    -- v1.6.0 Activity, whole span: the bird's-eye view at the top of EVERY
    -- view (vw in-s in-t in-a), above the verdict.  Two stacked inline-SVG
    ...
    -- tables).  No ASH rows = the calm #ax-empty note.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<section id="activity" class="vw in-s in-t in-a ashtop" aria-labelledby="activity-h">'
        || '<h2 id="activity-h">Activity, whole span<small class="h2sub">ASH active sessions across every '
        ...
    DBMS_OUTPUT.PUT_LINE('<div class="ashx" id="ashx" role="group" aria-label="Active sessions over the whole span" hidden>'
        || '<div class="axh"><span class="axs" id="ax-range"></span>'
        || '<span class="axk" aria-hidden="true"><span><i class="kw"></i>compared window</span>'
        || '<span><i class="kw cur"></i>Current</span><span><i class="kw pin"></i>pinned</span></span>'
        || '<button type="button" class="axr" id="ax-reset" hidden>Reset zoom</button></div>'
        || '<p class="axe" id="ax-empty" hidden>No ASH samples in DBA_HIST_ACTIVE_SESS_HISTORY across the compared span.</p>');
    DBMS_OUTPUT.PUT_LINE('<div class="axch" id="ax-cls"><div class="axct"><h3>By wait class</h3>'
    ...
    DBMS_OUTPUT.PUT_LINE('<div class="axch" id="ax-ev"><div class="axct"><h3>By wait event</h3>'
    ...
    DBMS_OUTPUT.PUT_LINE('<p class="axn2">Hover for the values; drag across either chart to zoom both '
        ...
        || '</div></section>');
```

Line 1284 opens `<section id="activity"`, line 1309 ends with
`'</div></section>');`. The verdict hero follows: its comment block starts
at line 1310, `DBMS_OUTPUT.PUT_LINE('<section id="verdict" class="vw in-s hero" aria-label="Verdict">');`
is line 1319 and the hero ends at line 1386 with
`DBMS_OUTPUT.PUT_LINE('</section>');`. Line 1387 starts the comment block
of the Timeline skeleton (`-- v1.6.0 Timeline view (Mock D): the skeleton only.`).
All of this is inside one PL/SQL block (no `END;` / `/` between 1272 and 1386).

### Section order (CSS), `sql/_style.sql:150`

```sql
    DBMS_OUTPUT.PUT_LINE('main > *, body > section { order:3; }');
```

`<main>` is `display:contents`, so every section is a flex item of `body`
with `order:3`; equal orders keep DOM order. So swapping the DOM order of the
two blocks is enough — do not add `order:` rules for this plan. (The
dashboard design's own `order:5` / `order:6` rules above win over the DOM
order in its Summary, so they are not affected.)

### Activity CSS, `sql/_style.sql:1443-1457` (excerpt)

```sql
    DBMS_OUTPUT.PUT_LINE('.ashx .axr{font-size:12px;border:1px solid var(--line-2);background:var(--panel);border-radius:6px;padding:2px 10px;cursor:pointer;color:var(--ink-2);line-height:20px}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axr:hover{color:var(--ink);border-color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('.ashx .axr[hidden]{display:none}');
    ...
    DBMS_OUTPUT.PUT_LINE('.ashx .axn2{margin:var(--s1) 0 0;font-size:12px;color:var(--ink-3)}');
```

`sql/_style.sql` is ALSO included by the fleet report's chrome, so every new
rule must be scoped to single-DB ids / classes (`#activity`, `.ashx`).

### The chart script, `sql/lib/src/js_timeline.js`

- Line 282: `var AX=null,AE=null,CH=[],SP=null,DRAG=null,cvs=null;` — `CH`
  is the list of the two chart objects (by wait class first, by wait event
  second), `SP` the shared state.
- `spInit()` (lines 387-436) builds `SP`, creates the charts, then:

```js
  /* the detail only when every chart has it */
  CH.forEach(function(c){c.FV=fineVals(c.P);});
  if(CH.some(function(c){return !c.FV;}))SP.F=null;
  if(CH.length)CH[CH.length-1].xl=true;
  ...
  if(CH.length===2&&AE&&AE.ecls&&AE.ecls.length===AE.classes.length){
    ...
  }
  if(SP.reset)SP.reset.addEventListener('click',spReset);
```

  (The line `if(CH.length)CH[CH.length-1].xl=true;` is line 407 and the
  `if(SP.reset)` line is line 415. `draw()` overrides `c.xl` anyway, as
  shown next.)

- `draw(c,force)` (lines 485-601) begins:

```js
function draw(c,force){
  if(!c||!SP||!shown(c.plot))return;
  /* the release flags go on the first chart shown, the x labels on the
     last one (both on one chart when a design shows a single chart) */
  var vis=CH.filter(function(x){return shown(x.plot);}),lay;c.flags=vis[0]===c;c.xl=vis[vis.length-1]===c;lay=(c.flags?1:0)+(c.xl?2:0);
  var Wd=Math.max(480,c.plot.clientWidth),d0=SP.dom[0],d1=SP.dom[1];
  if(!force&&c.w===Wd&&c.lay===lay&&c.g&&c.pw===PW&&c.g.d0===d0&&c.g.d1===d1&&c.g.hk===c.hk)return;c.w=Wd;c.pw=PW;c.lay=lay;
  var mks=W.markers?W.markers():[],P=c.P;
  var top=c.flags&&mks.length?46:22,ph=150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;
```

  (lines 485-493). `shown(el)` (line 6) is `el.getClientRects().length>0`,
  so a chart hidden by CSS is not drawn at all. The charts that ARE shown
  decide `c.flags` (the first one) and `c.xl` (the last one), so when CSS
  hides the by-event chart, the class chart prints the date labels by
  itself. The x-label line is line 568:
  `    if(c.xl)s+='<text class="at" x="'+xt.toFixed(1)+...`
  and `draw` ends (line 600) with
  `  c.g={X:X,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:d0,d1:d1,ymax:ymax,ord:ord,hk:c.hk};`
- Line 477: `TL.redraw=function(){drawAll(true);};` is the public "redraw
  both charts now", which the dashboard's tabs call.

- A view switch already redraws every chart (lines 169-172):

```js
doc.addEventListener('awr:view',function(ev){
  var v=ev.detail&&ev.detail.view;
  setTimeout(function(){drawAll(true);if(v==='timeline'){sync();startAtCurrent();}},50);
});
```

### Existing localStorage convention, `sql/00_params.sql:1052`

```sql
    DBMS_OUTPUT.PUT_LINE('  if(persist){ try{localStorage.setItem("awr-view",v);}catch(e){} ...
```

Every localStorage access is wrapped in `try{...}catch(e){}`, and a key is
written only on an explicit click.

### Text that says "top of every view"

- `sql/19_reference.sql:66` (guide item "Full-span activity"):
  `... class="gx2"><h3>Full-span activity</h3><p>Top of every view: active sessions over the whole span ...`
- `sql/19_reference.sql:246-247` (About, "ASH timeline"):
  `... hourly (or the cadence) in All sections; at the top of'`
  `|| ' every view (Activity, whole span) on the same grid ...`
- The demo twin of 19 (`demo/awrdemo/sections/s19_reference.py`) copies those
  lines automatically; no twin edit is needed for 19.

### The demo twin, `demo/awrdemo/sections/s00_params.py:452-458`

```python
    # ---- AWR_WIN + the verdict hero (hand-ported) ----------------------
    put('<script>window.AWR_WIN=' + _win_json(w) + ';</script>')
    # ---- the Activity charts' skeleton (literal in the SQL: lifted) ----
    i_act = next(i for i in range(len(L)) if L[i][0].startswith('<section id="activity"'))
    i_ver = next(i for i in range(i_act, len(L)) if L[i][0].startswith('<section id="verdict"'))
    o.extend(_literal_slice(L, i_act, i_ver - 1))
    o.extend(_hero(w, st))
```

`L` is the list of `(text, is_literal)` for every PUT_LINE of
`sql/00_params.sql`; `_hero(w, st)` is the hand-ported verdict hero.

### The smoke test, `demo/verify_report.js`

- Line 126 (block 1, the only such line) resets stored state:
  `await page.evaluate(() => { try { localStorage.removeItem('awr-view'); localStorage.removeItem('awr-theme'); } catch (e) {} });`
- Line 111 declares `let DESIGN = 'classic';`. Block 1 (lines 146-147) sets
  it from `window.AWR_DESIGN`. Every later block can read it.
- Lines 197-216, inside the "every view x theme" loop (block 2), require
  the Activity section to be the first visible section (except the verdict
  in the dashboard's Summary) and every SHOWN chart drawn:

```js
          act: (() => {
            const a = document.getElementById('activity');
            if (!vis(a)) return 'hidden';
            // the dashboard's Summary puts the verdict (and the KPI cards) above it
            const dashS = document.body.classList.contains('d-dash') && document.body.classList.contains('vs');
            const secs = [...document.querySelectorAll('main > section')].filter(x => x !== a && vis(x) && !(dashS && x.id === 'verdict'));
            const top = a.getBoundingClientRect().top;
            const above = secs.filter(x => x.getBoundingClientRect().top < top).map(x => x.id);
            if (above.length) return 'below ' + above.slice(0, 3).join(',');
            const has = !!(window.AWR_DATA && AWR_DATA.ashx && AWR_DATA.ashx.classes && AWR_DATA.ashx.classes.length);
            // every chart shown is drawn (the dashboard shows one at a time)
            const c1 = vis(document.querySelector('#ax-cls .axp')), c2 = vis(document.querySelector('#ax-ev .axp'));
            const n1 = document.querySelectorAll('#ax-cls .axsvg path.xa').length, n2 = document.querySelectorAll('#ax-ev .axsvg path.xa').length;
            if (has && (!(c1 || c2) || (c1 && !n1) || (c2 && !n2))) return 'not drawn (' + n1 + '/' + n2 + ')';
            if (!has && !vis(document.getElementById('ax-empty'))) return 'no data and no empty note';
            return 'ok';
          })(),
```

  `cls` (the parameter of that `page.evaluate`) is the body class of the view
  under test: `vs`, `vt` or `va`. Block 2 ends with the `view sizes` check
  (lines 240-242). Line 244 starts `// ---- 3. interactions`.
- The chart interaction tests (hover, legend, zoom, pin, highlight; block
  "5." from line 369) run in the Timeline view, where this plan changes
  nothing; they must keep passing unchanged. On the dashboard they first
  call `window.AWR_axMode('both')` (line 437).
- Block "7." (from line 883, quiet / dashboard only) checks "How to read":
  in Summary `p.axn2` is hidden, then visible after a click on
  `#ashx .axhow`, then hidden after a click elsewhere. On the dashboard it
  also checks the Summary order (verdict and KPI cards above Activity,
  Activity above the findings) and the Activity tabs: one chart, with the x
  labels and flags on it, or both.

### Repository rules that apply to every edit here

- **Never type a tilde character** in any `sql/` file or in
  `sql/lib/src/*.js`, not even in a comment: every section runs
  `SET DEFINE '~'`, so a stray one prompts for input and truncates the
  report. `./lint.sh` and `tools/js2plsql.sh` both reject it.
- **Emitted text is pure ASCII** (lint check 25): HTML entities in markup
  (`&mdash;`), and in JavaScript an escape such as backslash-u-2026, never
  the character itself. Warning: an agent's tool input can silently turn a
  typed backslash-u sequence into the character; this plan needs none, but
  if you add one, write the line from a script and check with
  `grep -nP '[^\x00-\x7F]' <file>`.
- A `PUT_LINE` source line must stay under 2499 characters; a line of
  `sql/lib/src/js_timeline.js` must stay under 2300 characters (the
  generator rejects longer ones).
- Never end a `--` comment with `;` inside a top-level SQL statement (not
  an issue inside these PL/SQL blocks, but do not add any).
- Fleet files (`sql/fleet/*`, `awr_fleet_extract.sql`, `run_awr_fleet.sh`)
  are out of scope.
- "All sections" must keep showing every number: this plan only changes
  presentation in Summary.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | last line `lint: clean (N files checked)` (114 at `5594f2c`), exit 0 |
| Regenerate the chart script | `tools/js2plsql.sh js_timeline` | exit 0, `sql/lib/js_timeline.plsql` rewritten |
| Regenerate the design stylesheet | `tools/js2plsql.sh css_design` | exit 0, `sql/lib/css_design.plsql` rewritten |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0, no output |
| Regenerate the demo | `python3 demo/gen_demo_report.py` | three `wrote .../docs/examples/demo_busy_db*.html (... KB)` lines (classic, quiet, dashboard) |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | three `up to date: ...` lines, exit 0 |
| Everything DB-free | `./tools/check.sh` | last line `check.sh: all checks passed` |
| Playwright (once) | `T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55)` | exit 0 |
| Smoke test | `NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots` (then the same with `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html`, other shot dirs) | exit 0, about 3 minutes each; never run two at once |

There is no database available to you. The database check for the owner is
listed under "Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/00_params.sql` (move the Activity block; one button in its skeleton)
- `sql/_style.sql` (two rules after line 1445)
- `sql/lib/src/js_timeline.js` and the regenerated `sql/lib/js_timeline.plsql`
  (plus a sentence in the latter's hand-written header)
- `sql/lib/src/css_design.css` and the regenerated
  `sql/lib/css_design.plsql` (one override rule, Step 4b)
- `sql/19_reference.sql` (two sentences)
- `demo/awrdemo/sections/s00_params.py` (the slice that lifts the skeleton)
- `demo/verify_report.js`
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated — never hand-edit)
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope** (do NOT touch):
- The rail (`nav.toc`, `sql/00_params.sql:473-475`): its "Overview →
  Activity, whole span" link stays where it is; reordering the rail is not
  part of this plan.
- Any `order:` CSS rule for sections: the DOM swap is enough. That includes
  the dashboard's `body.d-dash.vs main > #activity{order:5}` /
  `#findings{order:6}` in `css_design.css`: leave them.
- `sql/lib/src/js_design.js` (the dashboard's Activity tabs, "How to
  read"): nothing there needs to change.
- The Timeline and All sections views' charts (full height, both charts).
- `sql/09_ash_timeline.sql` (the chart data) — unchanged.
- The "Windows side by side" chart mode — that is plan 024; do not start it.
- Sections 20-28 (the visualization sections; none of them reads the
  Activity block).
- Fleet files.

## Git workflow

- Branch: `advisor/023-verdict-first-compact-activity` from `main`.
- Conventional commits with a scope, as in `git log` (e.g.
  `fix(report): escape long SQL text in pieces ...`). Suggested:
  `feat(report): verdict first in Summary; Activity charts open compact`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Baseline

Install Playwright into a temporary directory and run the smoke test on the
committed demo, so later failures are known to be yours.

```sh
T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55)
cp docs/examples/demo_busy_db.html /tmp/demo_before_023.html
for d in demo_busy_db demo_busy_db_quiet demo_busy_db_dashboard; do
  NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/$d.html || echo "BASELINE FAIL $d"
done
```

(one at a time, about 9 minutes in all).

**Verify**: no `BASELINE FAIL` line. `./tools/check.sh` ends with
`check.sh: all checks passed`. If the baseline already fails, STOP.

### Step 2 (Option A only): Emit the Activity section after the verdict hero

In `sql/00_params.sql`, cut the whole block from line 1272 (the
`-- =========` line that opens the comment "v1.6.0 Activity, whole span")
through line 1309 (the line ending `|| '</div></section>');`), and paste it
immediately after the verdict's closing line
`    DBMS_OUTPUT.PUT_LINE('</section>');` (line 1386 before the cut), i.e.
before the `-- =========` line that opens "v1.6.0 Timeline view (Mock D):
the skeleton only.". Keep the indentation (4 spaces).

Rewrite the first lines of the moved comment so they stay true:

```sql
    -- =========================================================
    -- v1.6.0 Activity, whole span, emitted right AFTER the verdict hero:
    -- in Summary the answer comes first and the charts follow, compact
    -- (by wait class only, a button brings back the second chart; see
    -- js_timeline section 6); the verdict is Summary-only, so in Timeline
    -- and All sections these charts are the first section.  With JS off
    -- the DOM order shows the verdict, then the ax-nojs note.  (The
    -- dashboard design orders its Summary by CSS, css_design.css, and
    -- shows one chart at a time with its own tabs: no compact mode
    -- there.)  Two stacked inline-SVG charts over one time axis -- active
    -- sessions by
```

(continue with the existing sentence "wait class (AWR_DATA.ashx) and by
wait event ..." unchanged). In the comment of the Timeline skeleton right
after it, the words "(#tl; the whole-span ASH charts moved to the top of
every view, section#activity above)" stay correct; leave them.

**Verify**:
- `grep -n '<section id="verdict"\|<section id="activity"' sql/00_params.sql`
  → the `verdict` line number is smaller than the `activity` line number.
- `awk 'NR>=1265 && NR<=1415 && /^END;|^\//' sql/00_params.sql` → no output
  (no block boundary was crossed).
- `./lint.sh` → clean.

### Step 3: Add the "Show by wait event" button to the skeleton

In the moved block, in the PUT_LINE that starts
`DBMS_OUTPUT.PUT_LINE('<div class="ashx" id="ashx" ...`, insert a new
concatenated piece immediately BEFORE the piece
`|| '<button type="button" class="axr" id="ax-reset" hidden>Reset zoom</button></div>'`:

```sql
        || '<button type="button" class="axr axm" id="ax-more" aria-controls="ax-ev" aria-expanded="false" hidden>Show by wait event</button>'
```

It reuses the existing `.axr` button style. It starts `hidden`; the script
unhides it only when there is a second chart.

**Verify**: `grep -c 'id="ax-more"' sql/00_params.sql` → `1`;
`./lint.sh` → clean.

### Step 4: CSS for the compact state

a) In `sql/_style.sql`, right after line 1445
(`    DBMS_OUTPUT.PUT_LINE('.ashx .axr[hidden]{display:none}');`), add:

```sql
    -- Summary: the Activity charts open compact (js_timeline section 6 sets
    -- #activity.ax-cmp): the by-event chart and the help line fold away
    -- until "Show by wait event" (#ax-more, shown only in Summary)
    DBMS_OUTPUT.PUT_LINE('body:not(.vs) #activity .axm{display:none}');
    DBMS_OUTPUT.PUT_LINE('body.vs #activity.ax-cmp #ax-ev,body.vs #activity.ax-cmp .axn2{display:none}');
```

b) The quiet / dashboard designs show the help line `p.axn2` as a popover
behind their "How to read" button, through
`.ashx.howable.howopen .axn2{display:block;...}` in
`sql/lib/src/css_design.css`. The selector added in a) has an id in it,
so it beats that rule. Left alone, "How to read" would open nothing in
the quiet design's compact Summary, and verify_report's block 7 would
fail. In `sql/lib/src/css_design.css`, right after the line
`.ashx.howable.howopen .axn2{display:block;...}`, add:

```css
/* plan 023: the compact Summary hides .axn2 (sql/_style.sql); the open popover shows it */
body.vs #activity.ax-cmp #ashx.howable.howopen .axn2{display:block}
```

Then run `tools/js2plsql.sh css_design`. This rule belongs in the design
stylesheet, never in `_style.sql`: a classic report has no "How to read"
button.

**Verify**: `./lint.sh` → clean;
`grep -c 'ax-cmp' sql/_style.sql` → `2` (the comment line and the rule);
`grep -c 'ax-cmp' sql/lib/css_design.plsql` → `1` or more;
`tools/js2plsql.sh --check` → exit 0.

### Step 5: Compact mode in the chart script

All edits in `sql/lib/src/js_timeline.js`.

a) Right after line 282 (`var AX=null,AE=null,CH=[],SP=null,DRAG=null,cvs=null;`)
add:

```js
/* Summary opens the charts compact (SP.cmp): the by-class chart only, a
   shorter plot with its own date labels; #ax-more shows the by-event chart.
   The reader's choice is kept in localStorage awr-ax, written on a click. */
function cmp(){return !!(SP&&SP.cmp)&&doc.body.classList.contains('vs');}
function axMore(b){b.setAttribute('aria-expanded',String(!SP.cmp));b.textContent=SP.cmp?'Show by wait event':'Hide by wait event';}
```

b) In `spInit()`, insert immediately BEFORE line 415
(`  if(SP.reset)SP.reset.addEventListener('click',spReset);`):

```js
  /* the dashboard design shows one chart at a time with its own tabs
     (js_design.js activityTabs): no compact mode there */
  var sec=doc.getElementById('activity'),mb=doc.getElementById('ax-more'),sv=null,dash=window.AWR_DESIGN==='dashboard';
  try{sv=localStorage.getItem('awr-ax');}catch(e){}
  SP.cmp=CH.length===2&&sv!=='full'&&!dash;
  if(sec)sec.classList.toggle('ax-cmp',SP.cmp);
  if(mb&&CH.length===2&&!dash){
    mb.hidden=false;axMore(mb);
    mb.addEventListener('click',function(){
      SP.cmp=!SP.cmp;if(sec)sec.classList.toggle('ax-cmp',SP.cmp);axMore(mb);
      try{localStorage.setItem('awr-ax',SP.cmp?'compact':'full');}catch(e){}
      drawAll(true);
    });
  }
```

(`SP.cmp` is only true with two charts: with one chart there is nothing to
fold, and it keeps its full height. `window.AWR_DESIGN` is set by an
inline script near the end of the page, before any `DOMContentLoaded`
handler runs. It is `undefined` in a classic report.)

c) In `draw()`, replace line 493

```js
  var top=c.flags&&mks.length?46:22,ph=150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;
```

with

```js
  var cm=cmp();
  var top=c.flags&&mks.length?46:22,ph=cm?96:150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;
```

Nothing else in `draw()` has to change for the date labels. Line 489 sets
`c.xl` to "this is the last chart shown". In compact mode CSS hides
`#ax-ev`, so the class chart is the last one shown and prints its own dates
(`if(c.xl)` on line 568 stays as it is).

d) (Nothing to do here. Before 2026-11-19 this step changed the x-label
condition; `draw()` now handles that itself.)

e) In `draw()`, the early return on line 491 must notice a compact change:
append `&&c.g.cm===cmp()` inside the condition, i.e.

```js
  if(!force&&c.w===Wd&&c.lay===lay&&c.g&&c.pw===PW&&c.g.d0===d0&&c.g.d1===d1&&c.g.hk===c.hk&&c.g.cm===cmp())return;c.w=Wd;c.pw=PW;c.lay=lay;
```

and on line 600 add `cm:cm` to the object:
`  c.g={X:X,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:d0,d1:d1,ymax:ymax,ord:ord,hk:c.hk,cm:cm};`

f) Regenerate and update the generated file's hand-written header: run
`tools/js2plsql.sh js_timeline`, then in `sql/lib/js_timeline.plsql`, in the
comment header ABOVE the `BEGIN` line, after the sentence ending "(mirrored
on the other chart), legend toggles that restack and rescale, ..." block,
add one comment line pair:

```
-- In the Summary view the charts open compact (#activity.ax-cmp: the
-- by-class chart only, 96-px plot; #ax-more toggles, localStorage awr-ax;
-- off in the dashboard design, whose tabs show one chart at a time).
```

(Comment lines only; do not touch anything from `BEGIN` on.)

**Verify**:
- `tools/js2plsql.sh --check` → exit 0.
- `grep -c "awr-ax" sql/lib/js_timeline.plsql` → `2` or more.
- `grep -nP '[^\x00-\x7F]' sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql` → no output.
- `./lint.sh` → clean.

### Step 6: Update the guide and About text

In `sql/19_reference.sql`:
- Line 66: replace `<p>Top of every view: active sessions` with
  `<p>Under the verdict in Summary (compact: by wait class; Show by wait event adds the second chart), at the top of Timeline and All sections: active sessions`.
- Lines 246-247: replace `at the top of'` / `|| ' every view (Activity, whole span) on the same grid`
  with `in the Activity charts (under'` / `|| ' the verdict in Summary, at the top of the other views) on the same grid`.

**Option B**: line 66 becomes `<p>Top of every view (compact in Summary: by wait class; Show by wait event adds the second chart): active sessions`; leave 246-247.

**Verify**: `awk 'length($0) > 2400' sql/19_reference.sql | wc -l` → the
same number as `git show 5594f2c:sql/19_reference.sql | awk 'length($0) > 2400' | wc -l`
(`0` at `5594f2c`); `./lint.sh` → clean.

### Step 7 (Option A only): Re-port the demo twin's slice

In `demo/awrdemo/sections/s00_params.py`, replace lines 454-458 (from the
comment `# ---- the Activity charts' skeleton ...` through
`o.extend(_hero(w, st))`) with:

```python
    o.extend(_hero(w, st))
    # ---- the Activity charts' skeleton (literal in the SQL: lifted) ----
    # emitted right after the verdict hero (plan 023): from its <section>
    # to the PUT_LINE that closes it ("...</div></section>")
    i_act = next(i for i in range(len(L)) if L[i][0].startswith('<section id="activity"'))
    i_end = next(i for i in range(i_act, len(L)) if L[i][0].endswith('</div></section>'))
    o.extend(_literal_slice(L, i_act, i_end))
```

Keep the `put('<script>window.AWR_WIN=' ...)` line above it unchanged.

**Verify**:
`python3 -c "import ast,sys;ast.parse(open('demo/awrdemo/sections/s00_params.py').read())"` → no output;
then `python3 demo/gen_demo_report.py` → `wrote ...`.

### Step 8: Regenerate the demo and check determinism

```sh
python3 demo/gen_demo_report.py && md5sum docs/examples/demo_busy_db*.html
python3 demo/gen_demo_report.py && md5sum docs/examples/demo_busy_db*.html
python3 demo/gen_demo_report.py --check
```

(The generator writes all three pages: classic, quiet, dashboard.)

**Verify**: the two sets of md5 sums are equal; `--check` prints three
`up to date` lines. Also (Option A), for each of the three pages:
`grep -n 'id="verdict"\|id="activity"' docs/examples/demo_busy_db.html | head -2`
→ the `verdict` match comes first. `grep -c 'id="ax-more"' docs/examples/demo_busy_db.html` → `1`
(and the same for `demo_busy_db_quiet.html` / `demo_busy_db_dashboard.html`).
`grep -c 'ax-cmp' docs/examples/demo_busy_db_quiet.html` → at least 4: the
two `_style.sql` lines, the design override and the script. The classic
page has no design stylesheet, so it shows at least 3.

### Step 9: Extend the smoke test

In `demo/verify_report.js`:

a) Line 126 (block 1): also remove the new key — add
`localStorage.removeItem('awr-ax');` inside the same `try { ... }`.

b) Replace the `act` closure (lines 197-216) so that, in Summary
(`cls === 'vs'`), the verdict may sit above the Activity section in every
design. Outside the dashboard, the compact state must hold there. Other
views keep today's rule, and "every chart shown is drawn" stays as it is:

```js
          act: (() => {
            const a = document.getElementById('activity');
            if (!vis(a)) return 'hidden';
            // Summary puts the verdict above it (plan 023; the dashboard by its CSS order, with its KPI cards)
            const summary = cls === 'vs';
            const secs = [...document.querySelectorAll('main > section')].filter(x => x !== a && vis(x) && !(summary && x.id === 'verdict'));
            const top = a.getBoundingClientRect().top;
            const above = secs.filter(x => x.getBoundingClientRect().top < top).map(x => x.id);
            if (above.length) return 'below ' + above.slice(0, 3).join(',');
            const has = !!(window.AWR_DATA && AWR_DATA.ashx && AWR_DATA.ashx.classes && AWR_DATA.ashx.classes.length);
            const two = !!(window.AWR_DATA && AWR_DATA.ashe && AWR_DATA.ashe.classes && AWR_DATA.ashe.classes.length);
            // every chart shown is drawn (the dashboard shows one at a time; Summary opens compact)
            const c1 = vis(document.querySelector('#ax-cls .axp')), c2 = vis(document.querySelector('#ax-ev .axp'));
            const n1 = document.querySelectorAll('#ax-cls .axsvg path.xa').length, n2 = document.querySelectorAll('#ax-ev .axsvg path.xa').length;
            if (has && (!(c1 || c2) || (c1 && !n1) || (c2 && !n2))) return 'not drawn (' + n1 + '/' + n2 + ')';
            // compact in Summary (plan 023), except in the dashboard design (its tabs show one chart)
            if (summary && has && two && window.AWR_DESIGN !== 'dashboard') {
              if (!a.classList.contains('ax-cmp') || c2) return 'not compact in Summary';
              const h = +document.querySelector('#ax-cls .axsvg').getAttribute('height');
              if (!(h > 0 && h <= 175)) return 'compact chart ' + h + ' px high';
            }
            if (!has && !vis(document.getElementById('ax-empty'))) return 'no data and no empty note';
            return 'ok';
          })(),
```

(Option B: keep the current `dashS` line and its filter
`!(dashS && x.id === 'verdict')` instead of `summary`. Only the dashboard
puts the verdict first then.)

The compact height is 46 (flags) + 96 (plot) + 26 (date labels) = 168 px on
the demo.

c) Add a new check block right after the "every view x theme" loop and its
`view sizes` check (after line 242, before `// ---- 3. interactions` on
line 244). `DESIGN` is the file-level variable set in block 1. The
dashboard never shows `#ax-more`, so the block only checks that there:

```js
  // ---- 2b. Summary: the Activity charts open compact; "Show by wait
  // event" shows the second chart and is remembered (awr-ax) -- plan 023
  // (the dashboard design keeps its own Activity tabs: #ax-more stays hidden)
  {
    const { page, errors } = await openPage('#view=summary', 'light');
    const has2 = await page.evaluate(() => !!(window.AWR_DATA && AWR_DATA.ashe && AWR_DATA.ashe.classes && AWR_DATA.ashe.classes.length));
    if (has2 && DESIGN === 'dashboard') {
      const off = await page.evaluate(() => { const b = document.getElementById('ax-more'); return (!b || b.hidden) && !document.getElementById('activity').classList.contains('ax-cmp'); });
      console.log('activity compact (Summary): ' + (off ? 'off in the dashboard, ok' : 'FAIL on in the dashboard'));
      if (!off) fail('activity: compact mode / #ax-more must stay off in the dashboard design');
    } else if (has2) {
      const st = () => page.evaluate(() => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const b = document.getElementById('ax-more');
        let saved = null; try { saved = localStorage.getItem('awr-ax'); } catch (e) {}
        return { cmp: document.getElementById('activity').classList.contains('ax-cmp'), ev: vis(document.getElementById('ax-ev')),
                 evDrawn: document.querySelectorAll('#ax-ev .axsvg path.xa').length, btn: b && vis(b) ? b.textContent : null,
                 exp: b ? b.getAttribute('aria-expanded') : null, saved };
      });
      const s0 = await st();
      await page.click('#ax-more'); await page.waitForTimeout(250);
      const s1 = await st();
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      const s2 = await st();
      await page.click('#ax-more'); await page.waitForTimeout(250);
      const s3 = await st();
      const ok = s0.cmp && !s0.ev && s0.btn === 'Show by wait event' && s0.exp === 'false'
        && !s1.cmp && s1.ev && s1.evDrawn > 0 && s1.saved === 'full' && s1.exp === 'true'
        && !s2.cmp && s2.ev && s3.cmp && !s3.ev && s3.saved === 'compact';
      console.log('activity compact (Summary): ' + (ok ? 'ok' : 'FAIL ' + JSON.stringify([s0, s1, s2, s3])));
      if (!ok) fail('activity: Summary compact / Show by wait event ' + JSON.stringify([s0, s1, s2, s3]));
      await page.evaluate(() => { try { localStorage.removeItem('awr-ax'); } catch (e) {} });
    }
    if (errors.length) fail('activity compact: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }
```

d) In the header comment (lines 29-31), change "at the top of every
view, above the verdict, both drawn" to "the first section in Timeline /
All sections, right under the verdict in Summary (compact there: one chart;
"Show by wait event" brings back the second, remembered in awr-ax; the
dashboard design keeps its own tabs instead), both drawn elsewhere".

**Verify**: `node --check demo/verify_report.js` → no output; then, one at
a time:

```sh
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db_quiet.html /tmp/awr-shots-quiet
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db_dashboard.html /tmp/awr-shots-dash
```

→ each exits 0. Classic and quiet print `activity compact (Summary): ok`;
the dashboard prints `activity compact (Summary): off in the dashboard, ok`.
Every view line shows `activity ok`. In quiet and dashboard, the block 7
lines ("How to read", the dashboard's Summary order and Activity tabs)
still pass. Open `/tmp/awr-shots/summary-light.png` and
`/tmp/awr-shots/summary-dark.png`: the verdict sentence is at the top
(Option A), followed by one short chart. In
`/tmp/awr-shots-dash/summary-light.png` the dashboard looks as before:
verdict, KPI cards, Activity with its tabs.

### Step 10: Documentation

- `CHANGELOG.md`, under `## Unreleased` (line 8) → `### Report` (line 120),
  add a bullet: "**Summary view: the verdict first, the Activity charts
  compact.** The one-sentence verdict now opens the Summary view; the
  Activity charts follow it as one 170-px chart by wait class, and *Show by
  wait event* brings back the second chart (remembered in this browser).
  Timeline and All sections are unchanged: the charts are still their first
  section. The dashboard design is unchanged (it already led with the
  verdict and shows one chart at a time)."
  (Option B: "The Activity charts open compact in the Summary view ...".)
- `CLAUDE.md`:
  - line 289-290 ("Assignment"): replace "the first section after `<main>`,
    above the verdict" with "emitted right after the verdict hero: first in
    Timeline / All sections, under the verdict in Summary, where it opens
    compact".
  - lines 472-474 ("Activity, whole span"): replace "is emitted by 00 right
    after `AWR_WIN`, before the verdict hero, so it is the first section in
    every view (and with JS off)" with "is emitted by 00 right after the
    verdict hero (plan 023): the first section in Timeline and All sections
    (the verdict is Summary-only), the second in Summary and with JS off".
    Add to that paragraph: "**Compact in Summary**: `SP.cmp` /
    `#activity.ax-cmp` hide `#ax-ev` and `.axn2` under `body.vs`, the class
    chart draws a 96-px plot (it is then the last chart shown, so `draw()`
    gives it the date labels); `button#ax-more` (`.axr.axm`, unhidden only
    with two charts) toggles it and stores `localStorage awr-ax` = `full` /
    `compact` on a click only; off in the dashboard design
    (`window.AWR_DESIGN === 'dashboard'`: its `.axseg` tabs show one chart
    at a time); `css_design.css` re-shows `.axn2` inside the open "How to
    read" popover; the demo twin lifts the skeleton from `<section
    id="activity"` to the line ending `</div></section>`."
  - lines 811-812 ("Section order"): replace "00 emits `#activity` first
    (before the verdict), and with the default `order:3` it stays first in
    every view" with "00 emits the verdict hero, then `#activity` (plan
    023); with the default `order:3` the charts are the first section in
    Timeline / All sections and follow the verdict in Summary".
  - the "Report designs" paragraph, after "Summary order: `body.d-dash.vs`
    puts `#activity` at order 5 ..." (line 749-752): add "(the classic /
    quiet Summary also leads with the verdict since plan 023, by DOM order;
    the compact Activity mode is off in the dashboard)".
  (Option B: only add the "Compact in Summary" paragraph and the dashboard
  sentence.)

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- `demo/verify_report.js` (extended in Step 9): the per-view contract (verdict
  above Activity only in Summary; compact chart at most 175 px high, the
  by-event chart hidden; not in the dashboard), and the new block "2b"
  (button text and `aria-expanded`, the second chart shown and drawn,
  `awr-ax` written as `full` then `compact`, the choice surviving a reload;
  on the dashboard: compact and `#ax-more` off). Model new checks on the
  existing ruler-pin check (`demo/verify_report.js` around line 719:
  `page.evaluate` returning `'ok'` or `'FAIL ...'`, then `fail(...)`).
- The unchanged Timeline-view interaction tests (hover, legend, brush zoom,
  1-minute detail, pin, highlight) prove the compact mode does not leak
  outside Summary.
- Block 7 on the quiet and dashboard demos: "How to read" still opens in
  Summary (the design override of Step 4b); the dashboard's Summary order
  and Activity tabs are unchanged.
- Visual: the `summary-light.png` / `summary-dark.png` screenshots of the
  three demo pages.

## Done criteria

- [ ] `./tools/check.sh` → `check.sh: all checks passed`
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `python3 demo/gen_demo_report.py --check` → three `up to date` lines
- [ ] `demo/verify_report.js` exits 0 on `demo_busy_db.html`, `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html` (one at a time) and prints `activity compact (Summary): ok` (classic, quiet) / `... off in the dashboard, ok` (dashboard)
- [ ] Option A: in each of the three demo pages the first `id="verdict"` precedes the first `id="activity"`
- [ ] `grep -nP '[^\x00-\x7F]' sql/00_params.sql sql/_style.sql sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/lib/src/css_design.css sql/lib/css_design.plsql sql/19_reference.sql` → no output
- [ ] `git status` shows only the in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check's ancestor test fails (`5594f2c` is not in your branch).
- The excerpts above do not match the live code (line numbers off by more
  than a few lines, or different text).
- `_literal_slice` in the demo twin raises "not literal-only" (it means a
  PUT_LINE in the Activity block contains a DEFINE substitution; the twin's
  approach would have to change).
- Any existing Timeline-view Activity check of `demo/verify_report.js`
  (hover, legend, zoom, 1-minute detail, pin, highlight) fails after your
  change — compact mode must not apply outside Summary.
- Block 7 (quiet / dashboard) fails after your change, and Step 4b does
  not explain it.
- Making it work seems to need a change to the rail, to section `order:`
  CSS (classic or the dashboard's), to `sql/lib/src/js_design.js`, to
  `sql/09_ash_timeline.sql` or to any fleet file.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Owner decision recorded here**: the v1.6.0 request was "Activity charts
  at the very top of every view". Option A keeps that for Timeline and All
  sections but puts the verdict first in Summary. If the owner prefers
  Option B, it is Steps 2 and 7 not done, and the Option B notes followed.
  Since 2026-11-19 the dashboard design (opt-in) already leads with the
  verdict. So the question for the owner is whether the default classic
  look (and quiet) should too.
- The compact mode and the dashboard's Activity tabs are two answers to the
  same "two tall charts" problem. Never both on one page: the guard is
  `window.AWR_DESIGN === 'dashboard'` in `spInit()`. If the dashboard's
  tabs are ever removed, drop that guard.
- Plan 024 (the "Windows side by side" chart mode) adds a mode switch to the
  same `.axh` header row and touches `draw()`; it is written against the
  code after this plan.
- If the Summary view later gets a "triage list" directly under the verdict
  (plan 025), the order becomes verdict, Activity, hero strip, findings; the
  owner may want the Activity charts after the hero strip instead. That needs
  a JS relocation (a `vw in-s` section emitted later than 08's `#overview`),
  not a CSS `order`, because all these sections share `order:3`.
- A reviewer should check: nothing in Timeline / All sections changed
  (compare `/tmp/awr-shots/timeline-light.png` with a run of the smoke test
  on `/tmp/demo_before_023.html`), the button is keyboard reachable, and the
  `localStorage` access is wrapped in `try`.
- **Needs an owner DB run** (the executor has no database). On dbmint
  (`ssh -p 2200 oracle@dbmint`, never port 2201; copy the tree with
  `rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'`
  — never `--delete`):
  - dbmint keeps only 35 days of AWR, so the September dates used in older
    plans return empty windows. Probe for a restart-free stretch first (see
    `CLAUDE.md`, "dbmint keeps 35 days of AWR"); on 2026-11-19 that was
    2026-11-07 14:45 to 2026-11-09 16:15, e.g.
    `./run_awr_trend.sh '/ as sysdba' "2026-11-08 15:00" 1 8 10 0 1 h` (a heavy blocking
    hour against eight quiet ones), once with the default design and once
    with `DESIGN=dashboard` (and `DESIGN=quiet` if time allows): rc 0, 29/29
    `AWR-SECTION` BEGIN/END pairs (`grep -c 'AWR-SECTION: .* BEGIN'` and
    `END`), the verdict above the Activity charts in Summary, compact chart,
    "Show by wait event" works (not shown in the dashboard); `ORA-` hits
    inside captured SQL text are false positives;
  - `demo/verify_report.js` on each report (one at a time).
