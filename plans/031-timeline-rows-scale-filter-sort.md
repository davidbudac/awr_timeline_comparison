# Plan 031: Timeline rows show normal variation, and the grid can show only flagged rows or sort them by change

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/lib/src/js_wingrid.js sql/lib/js_wingrid.plsql sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/_style.sql sql/00_params.sql sql/04_waits_fg.sql tools/check.sh demo/verify_report.js sql/lib/src/js_design.js sql/lib/src/css_design.css`
> Plans 024 / 027 / 028 / 030 / 036 also touch some of these files. If any
> changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch in a
> block this plan edits (`sizeRow`, `TL.reveal`, `cellTip`, `lanes()`,
> the boot block, the `#tl` CSS lines quoted below), treat it as a STOP
> condition. New functions elsewhere in those files are expected.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW-MED (client-side drawing of the Timeline grid; numbers, ids, counts and links unchanged)
- **Depends on**: plans/030 (soft: once every wait row is in AAS, "Biggest change first" sorts the Waits lane by added AAS; before that it sorts by z, and says so)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c` (the report redesign with
  its `design` option and the visualization sections 20-28 landed).
  `js_wingrid.js` is unchanged. `js_timeline.js` changed only inside the
  Activity charts (section 6: `TL.redraw`, per-chart flags / x labels in
  `draw()`), not in any block this plan edits; its boot block moved down
  5 lines. `_style.sql`, `00_params.sql` and `awr_trend.sql` line numbers
  below are refreshed. New: the demo is three pages, `verify_report.js`
  has blocks 7 and 8 (5c / 5d still free), section 25 (Onset) shows in
  the Timeline view as its own section, not as a lane.

## Why this matters

The Timeline view draws every metric, wait, object and statement as a row
of 13 bars, one per compared window. Each row is scaled to its tallest
bar, so when the Current value is 5x or 20x normal (the rows that matter
most) the 12 prior bars shrink to flat stubs: the reader cannot see
whether "normal" was steady, noisy or already climbing. In the demo, 14
rows look like that (physical reads, scattered reads, the top segment,
the top statement ...). The grid also shows normal rows between flagged
ones in a fixed order, so the few rows that matter are spread over two
screens. This plan (1) scales Timeline rows to the prior windows and draws
a Current bar that does not fit as a broken bar (its value is already
printed above it), and (2) adds a small toolbar above the grid: "Rows: All
| Flagged only" and "Order: Report order | Biggest change first". Counts,
pills, ids, links and every number stay as they are.

Target:

```
 Rows [All] [Flagged only]    Order [Report order] [Biggest change first]   Waits: by added AAS
 ------------------------------------------------------------------------------------------
 Physical reads   | _ _ _ _ _ _ _ _ = = = = |/| 22.24 k   x5.4   (priors now 2/3 of the
 /s               | (prior bars readable)   |#|                   height; Current cut)
```

The mockup `plans/assets/ux-mockup-2026-11-17.html` (outline numbers 11,
12) shows the direction; the report's own look (`sql/_style.sql`) wins.

## Current state

How the report is built (the parts this plan touches):

- The Timeline grid is drawn client-side. Its scripts live in the readable
  sources `sql/lib/src/js_wingrid.js` (bars of any `.wg` row) and
  `sql/lib/src/js_timeline.js` (lanes, pin, tooltip, Activity charts);
  `tools/js2plsql.sh <name>` turns each into the PUT_LINE body of
  `sql/lib/<name>.plsql`. **Edit the `.js`, never the `.plsql` body**;
  lint check 24 fails on a stale body. The driver loads `js_wingrid`
  before `js_timeline` (`awr_trend.sql` lines 633 / 637).
- The demo (`python3 demo/gen_demo_report.py`, no database) writes three
  pages, one per report `design`: `docs/examples/demo_busy_db.html`
  (classic), `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html`.
  It lifts both scripts and `sql/_style.sql` verbatim: **no hand-port**
  under `demo/awrdemo/`, only a regeneration committed with the change.
- With JavaScript off the grid is hidden (`sql/_style.sql:1422`
  `body:not(.js-wg) #tl{display:none}`); nothing here changes that.

Bars are drawn by `sizeRow`, `sql/lib/src/js_wingrid.js:36-53`:

```js
function sizeRow(row){
  var cells=$$(":scope > .c",row);if(!cells.length)return;
  var vals=nums(row.getAttribute("data-v")),mu=num(row.getAttribute("data-mu")),sd=num(row.getAttribute("data-sd")),sev=row.getAttribute("data-sev")||"";
  var z=null;if(mu!=null){var d=Math.max(sd||0,0.02*Math.abs(mu));z=[Math.max(0,mu-2*d),mu+2*d,Math.max(0,mu-d),mu+d,mu];}
  var have=vals.filter(function(v){return v!=null;}),max=Math.max.apply(null,have.concat(z?[z[1]]:[]).concat([0]));if(!(max>0))max=1;
  var bh=cssNum(row,"--bh",24),bb=cssNum(row,"--bb",4),bare=!!row.closest(".wg.bare"),tl=!!row.closest("#tl");
  var y=function(v){return Math.max(0,v)/max*bh;};
  cells.forEach(function(c,k){
    $$(":scope > i",c).forEach(function(x){c.removeChild(x);});
    if(z&&(!tl||c.classList.contains("cur"))){var z2=mk("i","z2",c);z2.style.bottom=(bb+y(z[0]))+"px";z2.style.height=Math.max(1,y(z[1])-y(z[0]))+"px";
      var z1=mk("i","z1",c);z1.style.bottom=(bb+y(z[2]))+"px";z1.style.height=Math.max(1,y(z[3])-y(z[2]))+"px";
      var mn=mk("i","mn",c);mn.style.bottom=(bb+y(z[4]))+"px";}
    if(bare)mk("i","base",c);
    var v=vals[k];if(v==null)return;
    var h=Math.max(1.5,y(v)),b=mk("i","b",c);b.style.height=h+"px";
    if(c.classList.contains("cur")&&(sev==="large"||sev==="moderate")){var s=mk("i","sd s-"+sev,c);s.style.bottom=(bb+h)+"px";}
  });
}
```

`sizeRow` also draws the Summary hero strip (section 08) and every finding
card's chart; those are NOT in `#tl` (`tl` false) and must keep today's
scale exactly.

Timeline rows (`sql/lib/timeline.plsql:179-214`, `tl_bars`) carry
`class="r bars ..."`, `id="tl-<detail row id>"`, `data-v` (oldest first,
Current last), `data-mu`, `data-sd`, `data-sev` (`large`, `moderate`,
`typical`, `improved`, ... or empty for a twin row), `data-name`,
`data-unit`. Lanes are emitted by `sql/00_params.sql:1409-1417`
(`lane_h`) as `div.lane#lane-<x>[data-kind]`; `data-kind="scored"` for
`lane-metrics` ("Headline and load") and `lane-waits`. Wait-class rows
in the Waits lane come from `sql/07_summary.sql` (ids `tl-fr-w-...`,
`data-unit="AAS"`); event rows from `sql/04_waits_fg.sql:470-478` (ids
`tl-we-...`, `data-unit="s waited"` today — plan 030 changes them to AAS),
rows past the 10th event carry class `more` and fold under "+ Show N more".

`sql/lib/src/js_timeline.js` pieces this plan edits:

- `TL.reveal`, lines 63-68 (called by the page's `goTo` before it
  scrolls to a row):

```js
TL.reveal=function(el){
  var lane=el&&el.closest?el.closest('#tl .lane'):null;if(!lane)return;
  if(lane.classList.contains('closed')){lane.classList.remove('closed');var b=$('.lt2',lane);if(b)b.setAttribute('aria-expanded','true');}
  if(el.classList.contains('more'))showMore(lane);
  setTimeout(function(){if(W.render)W.render(lane);},0);
};
function showMore(lane){lane.classList.add('showmore');var b=$('.xpb',lane);if(b)b.setAttribute('aria-expanded','true');if(W.render)W.render(lane);}
```

- `lanes()`, lines 93-126: builds the "+ Show N more" row
  (`div.r.xpr`, inserted right before the first `.r.more`), the lane
  counts and the rail pills (it counts `data-sev`, not visibility — so a
  filter never changes a count).
- `cellTip`, lines 196-206, last line:

```js
  var g=$('.glf',cell);
  return head+'<b>'+fmtNum(v)+'</b> '+esc(row.getAttribute('data-unit')||'')+(g?'<br>'+esc(g.title):'');
```

- The section header `/* ---- 3. pin a window: its column tints, the gutter compares against it */`
  (line 127) and the boot block, lines 651-662 (646-657 at `ee23e49`;
  its text is unchanged):

```js
doc.addEventListener('DOMContentLoaded',function(){
  tip=doc.getElementById('tip');if(!tip){tip=mk('div','',doc.body);tip.id='tip';tip.setAttribute('role','tooltip');tip.hidden=true;}
  $$('.sw[data-wc]').forEach(function(s){s.style.setProperty('--sw',wcol(s.getAttribute('data-wc')));});
  AX=(window.AWR_DATA||{}).ashx||null;
  lanes();
  activity();
  ...
```

  Helpers available in `js_timeline.js`: `$`, `$$`, `mk`, `esc`, `num`,
  `nums`, `doc`, `W` (= `window.AWR_WG`).

Timeline CSS, `sql/_style.sql:1526-1529`:

```sql
    DBMS_OUTPUT.PUT_LINE('#tl .gin .r.more{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.showmore .r.more{display:grid}');
    DBMS_OUTPUT.PUT_LINE('#tl .lane.showmore .r.xpr{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.xpr .l{padding:8px 16px}');
```

The report already keeps one viewer preference in localStorage: the view
(`awr-view`), written only on an explicit click and read inside
`try { } catch` (`sql/00_params.sql:372`). This plan follows the same rule.

Since `ee23e49` (what the redesign and sections 20-28 changed around this
plan; none of it needs code here, but the executor must know it):

- **Report designs.** `design=quiet|dashboard` adds a stylesheet
  (`sql/lib/src/css_design.css`) and a script (`sql/lib/src/js_design.js`)
  on top of the classic report. The CSS has no `#tl` / `#timeline` rule;
  it rounds `.wg i.b` tops (`border-radius:3px 3px 0 0`), which the broken
  bar's `::after` cut is drawn over unchanged. The script never touches
  the Timeline, but it moves every `.tbl-tools > .tool-btn` (the tables'
  CSV / MD buttons) into a copy menu and renames them: never give the new
  toolbar or its buttons the classes `tbl-tools` / `tool-btn`. Leave both
  design files alone; the base CSS of step 4 applies in every design.
- **Section 25 (Onset, `section#onset.vw.in-s.in-t.in-a`)** is visible in
  the Timeline view as its own section below `#timeline`; it adds no lane
  and no `#tl` row (no `tl_open` in sections 20-28), so the filter and the
  order never see it.
- **Section 24 (Blocking)** draws a `.wg` bars strip (`#bk-bars`) outside
  `#tl`: like the hero strip and the cards it must keep the old scale (the
  `tl` false path of step 1).
- **`verify_report.js`** now has blocks 1-5, 5b, 6, 7 (the quiet /
  dashboard design) and 8 (sections 20-28). Block 5c is reserved for plan
  024; this plan adds 5d. Block 6 still starts with the line quoted in
  step 6 (about line 805).

Repo rules that apply here (each has broken the report before):

- **Never type a tilde** in `sql/lib/src/*.js` or `sql/_style.sql`, not
  even in a comment or as the CSS sibling combinator.
- **Emitted text must be pure ASCII** (lint check 25). The code below uses
  only ASCII, with `&times;` as an HTML entity inside an HTML string. Do
  NOT type `\u` escape sequences into your tool input (some agent tools
  turn them into the literal character); check with the ASCII command.
- A `src/*.js` line must stay under 2300 characters.
- `sql/_style.sql` rules are PUT_LINE string literals (no single quote is
  needed below). The file is also included by the fleet report: every new
  selector is scoped to `#timeline` / `#tl` (single-DB only).
- Plans 027 / 028 also add code to `js_wingrid.js`; they define different
  names (`W.patterns`, `W.baseline`, `avg`, ...) and do not conflict.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate client scripts | `tools/js2plsql.sh js_wingrid` and `tools/js2plsql.sh js_timeline` | `... regenerated` |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0, no output |
| JS unit tests | `node tools/js_unit_tests.js` | last line `N tests passed`, exit 0 |
| ASCII check | `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/lib/src/js_timeline.js sql/_style.sql tools/js_unit_tests.js` | `0` for each file |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote .../docs/examples/demo_busy_db*.html (... KB)` lines |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | three `up to date: ...` lines |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d) && (cd $T && npm i playwright@1.55 >/dev/null) && NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` for each (about 3 min each; never run two at once) |

There is no database available to you; the owner's checks are listed under
"Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/lib/src/js_wingrid.js`, `sql/lib/js_wingrid.plsql` (regenerated;
  header comment extended by hand)
- `sql/lib/src/js_timeline.js`, `sql/lib/js_timeline.plsql` (regenerated;
  header comment extended by hand)
- `sql/_style.sql` (toolbar, filter, broken bar)
- `tools/js_unit_tests.js` (create, or extend if plan 027 / 028 created it)
- `tools/check.sh` (one step, only if not already added by 027 / 028)
- `demo/verify_report.js` (one check block)
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated, never hand-edited)
- `CLAUDE.md` (one paragraph), `CHANGELOG.md` (one bullet)

**Out of scope** (do NOT touch):
- `sql/00_params.sql` (lane skeleton and the Waits lane caption — plan 030
  rewrites the caption), `sql/04_waits_fg.sql`, `sql/07_summary.sql`,
  `sql/lib/timeline.plsql`: no server change is needed.
- The scale of every bars row outside `#tl` (hero strip, finding cards):
  they keep today's rule exactly.
- Lane counts, rail pills, row ids, `data-tl` targets, the pin, the
  Activity charts and their code (`js_timeline.js` sections 5-7).
- Ranked lanes (objects, SQL), the config and activity lanes: no filter,
  no sort (they are already ranked by the Current value).
- Every fleet file and the demo twins under `demo/awrdemo/`.
- The design layer (`sql/lib/src/js_design.js`, `sql/lib/src/css_design.css`
  and their generated `.plsql`) and the sections `sql/20_*.sql` …
  `sql/28_*.sql`.

## Git workflow

- Branch: `advisor/031-timeline-rows` from `main`.
- One commit, e.g. `feat(report): Timeline rows scale to the prior windows; flagged-only filter and biggest-change order`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Scale Timeline rows to the prior windows

In `sql/lib/src/js_wingrid.js`, insert right before the comment line
`/* one bars row: grey prior columns, the Current one in the accent, the`
(line 33):

```js
/* the vertical scale of one bars row (plan 031).  Outside the Timeline
   grid (tl false) the old rule: the tallest value or the top of the normal
   zone.  In the Timeline grid the prior windows set it: when the Current
   value is more than 1.5 x the tallest prior value (or the zone top), the
   scale stops at 1.5 x that top and the Current bar is drawn broken (brk),
   so the prior bars keep up to two thirds of the row height. */
W.rowScale=function(vals,zTop,tl){
  var n=vals.length,have=vals.filter(function(v){return v!=null;}),max=Math.max.apply(null,have.concat(zTop!=null?[zTop]:[]).concat([0]));
  if(!(max>0))max=1;
  if(!tl||n<2)return {max:max,brk:false};
  var pr=vals.slice(0,n-1).filter(function(v){return v!=null;}),top=Math.max.apply(null,pr.concat(zTop!=null?[zTop]:[]).concat([0])),c=vals[n-1];
  if(top>0&&c!=null&&c>1.5*top)return {max:1.5*top,brk:true};
  return {max:max,brk:false};
};
/* how much a Timeline row changed (plan 031): Current minus the prior mean
   when aas (every row of the lane is in AAS, so the numbers add up), else
   |z| with sigma floored at 2% of the mean; null when it cannot be told */
W.changeKey=function(vals,mu,sd,aas){
  var c=vals.length?vals[vals.length-1]:null;if(c==null||mu==null)return null;
  if(aas)return c-mu;
  var den=Math.max(sd||0,0.02*Math.abs(mu));return den>0?Math.abs((c-mu)/den):null;
};
```

Then in `sizeRow` replace these two lines:

```js
  var have=vals.filter(function(v){return v!=null;}),max=Math.max.apply(null,have.concat(z?[z[1]]:[]).concat([0]));if(!(max>0))max=1;
  var bh=cssNum(row,"--bh",24),bb=cssNum(row,"--bb",4),bare=!!row.closest(".wg.bare"),tl=!!row.closest("#tl");
```

with:

```js
  var bh=cssNum(row,"--bh",24),bb=cssNum(row,"--bb",4),bare=!!row.closest(".wg.bare"),tl=!!row.closest("#tl");
  var sc=W.rowScale(vals,z?z[1]:null,tl),max=sc.max;
```

and this line:

```js
    var h=Math.max(1.5,y(v)),b=mk("i","b",c);b.style.height=h+"px";
```

with:

```js
    var brk=sc.brk&&c.classList.contains("cur"),h=brk?bh:Math.max(1.5,y(v)),b=mk("i",brk?"b brk":"b",c);b.style.height=h+"px";
```

`W.rowScale(..., false)` returns exactly the old `max`, so the hero strip
and the cards draw as before. In the Timeline, a row whose Current value is
at most 1.5 x the prior top also draws exactly as before.

In the header comment of `sql/lib/js_wingrid.plsql` (above `BEGIN`), add
under the `sizeRow(row)` entry: `rowScale(vals, zTop, tl) / changeKey(vals,
mu, sd, aas): the bar scale (Timeline rows: Current past 1.5 x the prior
top is drawn broken, class brk) and a row's change (plan 031)`.

**Verify**: `tools/js2plsql.sh js_wingrid` → regenerated; `./lint.sh` → clean.

### Step 2: Unit tests (`tools/js_unit_tests.js`)

If `tools/js_unit_tests.js` does not exist, create it with this harness
(plans 027 / 028 use the same; if it exists, only append the block below
right before the final `console.log(passed + ' tests passed');`):

```js
#!/usr/bin/env node
/* tools/js_unit_tests.js -- unit tests of the pure helpers in the
 * generated client scripts (sql/lib/src/*.js), run with plain node: each
 * script is evaluated with a stub window / document, no browser.
 * Dev / CI only (tools/check.sh runs it when node is on PATH); nothing in
 * the report path depends on it.  No dependencies beyond node itself. */
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const ROOT = path.join(__dirname, '..');
function load(name, win) {
  win = win || {};
  win.addEventListener = win.addEventListener || function () {};
  const doc = { body: null, readyState: 'complete', addEventListener: function () {},
                querySelectorAll: function () { return []; } };
  const src = fs.readFileSync(path.join(ROOT, 'sql/lib/src', name + '.js'), 'utf8');
  new Function('window', 'document', src)(win, doc);
  return win;
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('ok - ' + name); }

/* ---- tests go here ---- */

console.log(passed + ' tests passed');
```

Tests for this plan (computed against a prototype of exactly the code in
step 1; if one fails, re-check step 1, never edit an expectation):

```js
/* ---- plan 031: W.rowScale / W.changeKey (js_wingrid) ---- */
{
  const W = load('js_wingrid').AWR_WG;
  const eq = (a, b) => assert.deepStrictEqual(a, b);
  test('rowScale outside the Timeline: the old rule', () => {
    eq(W.rowScale([1, 2, 3, 10], 4, false), { max: 10, brk: false });
    eq(W.rowScale([0, 0, 0, 0], null, false), { max: 1, brk: false });
  });
  test('rowScale in the Timeline: Current past 1.5 x the prior top is cut', () => {
    eq(W.rowScale([1, 2, 3, 10], 4, true), { max: 6, brk: true });
    eq(W.rowScale([1, 2, 3, 5], 4, true), { max: 5, brk: false });
    eq(W.rowScale([1, 2, 3, null], 4, true), { max: 4, brk: false });
    eq(W.rowScale([null, null, null, 5], null, true), { max: 5, brk: false });
    eq(W.rowScale([0, 0, 0, 0], null, true), { max: 1, brk: false });
    const r = W.rowScale([3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
                          4850.898, 5072.253, 4809.715, 4868.913, 22240.52], 5283.51, true);
    assert.ok(r.brk && Math.abs(r.max - 7925.265) < 0.01, JSON.stringify(r));
  });
  test('changeKey: added AAS or |z|', () => {
    assert.strictEqual(W.changeKey([1, 1, 1, 4], 1, 0.1, true), 3);
    assert.ok(Math.abs(W.changeKey([1, 1, 1, 4], 1, 0.1, false) - 30) < 1e-9);
    assert.strictEqual(W.changeKey([10, 10, 10, 5], 10, 1, true), -5);
    assert.strictEqual(W.changeKey([10, 10, 10, 5], 10, 1, false), 5);
    assert.strictEqual(W.changeKey([1, 1, 1, null], 1, 0.1, true), null);
    assert.strictEqual(W.changeKey([0, 0, 0, 1], 0, 0, false), null);
    assert.strictEqual(W.changeKey([1, 2, 3, 4], null, null, false), null);
  });
}
```

If `tools/check.sh` has no "client JS unit tests" step yet, add before
`step "generated docs are fresh (demo report, policy page)"` (and the line
`#   6. client JS unit tests        tools/js_unit_tests.js (skipped without node)`
to its header comment):

```sh
step "client JS unit tests (node)"
if command -v node >/dev/null 2>&1; then
    node tools/js_unit_tests.js || fail=1
else
    echo "node not found: skipped"
fi
```

**Verify**: `node tools/js_unit_tests.js` → the 3 plan-031 cases print
`ok - ...`, last line `N tests passed`, exit 0.

### Step 3: The toolbar, filter and order (`js_timeline.js`)

Insert right before the line
`/* ---- 3. pin a window: its column tints, the gutter compares against it */`:

```js
/* ---- 2b. the row toolbar (plan 031), above the grid: "Flagged only"
   hides the rows of the scored lanes that are not large / moderate
   (folded ones included); "Biggest change first" sorts the scored lanes
   (waits: by added AAS when every row is in AAS, else by z; headline and
   load: by z), wait-class rows staying above the events.  A viewer's
   choice, saved on a click only (localStorage awr-tl-rows /
   awr-tl-order), like awr-view.  Counts, pills and ids never change. */
var TLF={rows:'all',order:'report'};
function lsGet(k){try{return localStorage.getItem(k);}catch(e){return null;}}
function lsSet(k,v){try{localStorage.setItem(k,v);}catch(e){}}
function scoredLanes(){return $$('#tl .lane[data-kind="scored"]');}
function laneRows(lane){return $$('.lrows > .r.bars',lane);}
function flagged(r){var s=r.getAttribute('data-sev');return s==='large'||s==='moderate';}
function toolSync(note){
  $$('#tl-tools button[data-tlf]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-tlf')===TLF.rows));});
  $$('#tl-tools button[data-tlo]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-tlo')===TLF.order));});
  if(note!=null){var n=$('#tl-tools .tlt-n');if(n)n.innerHTML=note;}
}
function setRows(v,save){
  var tl=doc.getElementById('tl');if(!tl)return;TLF.rows=v;
  tl.classList.toggle('flagonly',v==='flagged');
  scoredLanes().forEach(function(l){l.classList.toggle('nofl',!laneRows(l).some(flagged));});
  toolSync();if(save)lsSet('awr-tl-rows',v);
  if(W.render)W.render(tl);
}
function setOrder(v,save){
  var tl=doc.getElementById('tl');if(!tl)return;TLF.order=v;
  var notes=[];
  scoredLanes().forEach(function(lane){
    var rows=laneRows(lane),box=$('.lrows',lane);if(!rows.length||!box)return;
    rows.forEach(function(r,i){if(!r.hasAttribute('data-ord'))r.setAttribute('data-ord',String(i));});
    var aas=rows.every(function(r){return r.getAttribute('data-unit')==='AAS';});
    var key=function(r){return W.changeKey(nums(r.getAttribute('data-v')),num(r.getAttribute('data-mu')),num(r.getAttribute('data-sd')),aas);};
    var grp=function(r){return /^tl-fr-w-/.test(r.id)?0:1;},ord=function(r){return +r.getAttribute('data-ord');};
    rows.sort(v==='change'?function(a,b){var g=grp(a)-grp(b);if(g)return g;var ka=key(a),kb=key(b);
      if(ka==null&&kb!=null)return 1;if(kb==null&&ka!=null)return -1;if(ka!==kb&&ka!=null)return kb-ka;return ord(a)-ord(b);}
      :function(a,b){return ord(a)-ord(b);});
    rows.forEach(function(r){box.appendChild(r);});
    var x=$('.r.xpr',lane),m=$('.lrows > .r.more',lane),nf=$('.r.nfl',lane),xb=$('.xpb',lane);
    if(v==='change'){if(m&&!lane.classList.contains('showmore')){lane.setAttribute('data-autoshow','1');showMore(lane);}
      notes.push(esc(($('.lti',lane)||{}).textContent||lane.id)+': by '+(aas?'added AAS':'size of the move (z)'));}
    else{if(lane.hasAttribute('data-autoshow')){lane.removeAttribute('data-autoshow');lane.classList.remove('showmore');if(xb)xb.setAttribute('aria-expanded','false');}
      if(x&&m)box.insertBefore(x,m);}
    if(nf)box.appendChild(nf);
  });
  toolSync(notes.join('; '));if(save)lsSet('awr-tl-order',v);
  if(W.render)W.render(tl);
}
function tools(){
  var tl=doc.getElementById('tl');if(!tl||!scoredLanes().length||doc.getElementById('tl-tools'))return;
  scoredLanes().forEach(function(lane){var box=$('.lrows',lane);if(!box)return;var nf=mk('div','r nfl',box);nf.setAttribute('role','row');nf.innerHTML='<div class="l" role="rowheader">No large or moderate row here</div>';});
  var t=mk('div','tl-tools');t.id='tl-tools';t.setAttribute('role','toolbar');t.setAttribute('aria-label','Timeline rows');
  t.innerHTML='<span class="tlt-g" role="group" aria-label="Rows"><span class="tlt-l">Rows</span><button type="button" data-tlf="all">All</button><button type="button" data-tlf="flagged">Flagged only</button></span>'
    +'<span class="tlt-g" role="group" aria-label="Order"><span class="tlt-l">Order</span><button type="button" data-tlo="report">Report order</button><button type="button" data-tlo="change">Biggest change first</button></span>'
    +'<span class="tlt-n"></span>';
  tl.parentNode.insertBefore(t,tl);
  t.addEventListener('click',function(ev){var b=ev.target&&ev.target.closest?ev.target.closest('button'):null;if(!b)return;
    if(b.hasAttribute('data-tlf'))setRows(b.getAttribute('data-tlf'),true);else if(b.hasAttribute('data-tlo'))setOrder(b.getAttribute('data-tlo'),true);});
  var r=lsGet('awr-tl-rows'),o=lsGet('awr-tl-order');
  setRows(r==='flagged'?'flagged':'all',false);setOrder(o==='change'?'change':'report',false);
}
```

Design decisions baked in (do not change without the owner): both
controls default to today's behaviour (All rows, Report order); the
viewer's choice is saved only on a click; only the two scored lanes are
filtered / sorted; in "Biggest change first" the Waits lane keeps its
wait-class rows above its event rows and unfolds "+ Show N more" (sorted
rows must not be split by the fold), and "Report order" folds it back.

Wire it in:

1. In the boot block, right after `  lanes();` add the line `  tools();`.
2. In `TL.reveal`, right after its first line (`var lane=...;if(!lane)return;`)
   add:

```js
  if(lane.getAttribute('data-kind')==='scored'&&el.classList.contains('bars')&&!flagged(el)&&lane.closest('#tl.flagonly'))setRows('all',false);
```

   (a link or "Timeline ->" jump to a row hidden by the filter switches
   the filter off for this visit, without saving it).
3. In `cellTip`, replace its last line with:

```js
  return head+'<b>'+fmtNum(v)+'</b> '+esc(row.getAttribute('data-unit')||'')+(g?'<br>'+esc(g.title):'')
    +($('i.b.brk',cell)?'<br><span class="tm">bar cut: more than 1.5&times; the tallest prior window</span>':'');
```

In the header comment of `sql/lib/js_timeline.plsql` (above `BEGIN`), add
one line for the toolbar: `#tl-tools (plan 031): Rows All / Flagged only,
Order Report / Biggest change first, saved on click as awr-tl-rows /
awr-tl-order; #tl.flagonly, .lane.nofl, .r.nfl`.

**Verify**: `tools/js2plsql.sh js_timeline` → regenerated;
`tools/js2plsql.sh --check` → exit 0; `./lint.sh` → clean;
`grep -cP '[^\x00-\x7F]' sql/lib/src/js_timeline.js sql/lib/src/js_wingrid.js` → `0` twice.

### Step 4: CSS

In `sql/_style.sql`, right after line 1529
(`#tl .r.xpr .l{padding:8px 16px}`), add:

```sql
    -- plan 031: the Timeline row toolbar (js_timeline tools), the
    -- flagged-only filter of the scored lanes and the broken Current bar
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools{display:flex;flex-wrap:wrap;align-items:center;gap:8px 20px;margin:0 0 var(--s3);font-size:12.5px;color:var(--ink-3)}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools .tlt-g{display:inline-flex;align-items:center;gap:4px}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools .tlt-l{margin-right:4px}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools button{font:inherit;font-size:12px;line-height:18px;padding:2px 10px;border:1px solid var(--line-2);border-radius:6px;background:var(--panel);color:var(--ink-2);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools button[aria-pressed="true"]{background:var(--chip-bg);color:var(--ink);font-weight:600;border-color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools button:focus-visible{outline:2px solid var(--acc);outline-offset:1px}');
    DBMS_OUTPUT.PUT_LINE('#timeline .tl-tools .tlt-n{font-size:12px;color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('#tl.flagonly .lane[data-kind="scored"] .lrows > .r.bars:not([data-sev="large"]):not([data-sev="moderate"]){display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl.flagonly .lane[data-kind="scored"] .lrows > .r.more[data-sev="large"],#tl.flagonly .lane[data-kind="scored"] .lrows > .r.more[data-sev="moderate"]{display:grid}');
    DBMS_OUTPUT.PUT_LINE('#tl.flagonly .lane[data-kind="scored"] .r.xpr{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.nfl{display:none}');
    DBMS_OUTPUT.PUT_LINE('#tl.flagonly .lane.nofl .r.nfl{display:grid}');
    DBMS_OUTPUT.PUT_LINE('#tl .r.nfl .l{padding:10px 16px;font-size:12.5px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#tl i.b.brk::after{content:"";position:absolute;left:-3px;right:-3px;top:6px;height:3px;background:var(--panel);transform:skewY(-20deg)}');
```

(The selectors above out-rank the existing `#tl .gin .r.more{display:none}`
by specificity, which is what lets a flagged folded row show.)

**Verify**: `./lint.sh` → clean; `grep -cP '[^\x00-\x7F]' sql/_style.sql` → `0`.

### Step 5: Regenerate the demo and document

Run `python3 demo/gen_demo_report.py` twice; `md5sum
docs/examples/demo_busy_db*.html` must give the same three md5s after both
runs.

`CLAUDE.md`, section "### Timeline view (v1.6.0)": add a paragraph
"**Row scale, filter and order (plan 031).**" stating: in `#tl` a bars row
is scaled to its prior windows (`AWR_WG.rowScale`): a Current value above
1.5 x the tallest prior value / zone top is drawn as a full-height broken
bar (`i.b.brk`, tooltip "bar cut"), every other row and every row outside
`#tl` keeps the old scale; `#tl-tools` above the grid holds "Rows: All /
Flagged only" (`#tl.flagonly` hides non-large / non-moderate rows of the
two `data-kind="scored"` lanes, folded ones included; `.lane.nofl` shows
the `.r.nfl` note) and "Order: Report order / Biggest change first"
(`AWR_WG.changeKey`: added AAS when every row of the lane has
`data-unit="AAS"`, else |z|; wait-class rows `tl-fr-w-*` stay above
events; the lane is unfolded while sorted); defaults are today's
behaviour; choices are saved on click only (`awr-tl-rows`,
`awr-tl-order`); `AWR_TL.reveal` switches the filter off for a jump to a
hidden row; counts / pills / ids never change. In "## Verification &
testing" mention `tools/js_unit_tests.js` if step 2 added the check.sh step.

`CHANGELOG.md`, `## Unreleased` → `### Report`:
`- **Timeline rows show what normal looked like.** A row whose Current
value is far above its prior windows no longer squashes them: the grid
scales to the prior windows and draws the Current bar cut, with its value
above it. A toolbar above the grid shows only flagged rows or sorts the
headline and wait lanes by the size of their change (added AAS for
waits); both are remembered per browser.`

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

### Step 6: Browser check (`demo/verify_report.js`)

Add a new block right before the line
`  // ---- 6. phase 4 (v1.6.0): the plan-change card, the evidence library,`:

```js
  // ---- 5d. plan 031: Timeline rows scale to the prior windows (broken
  // Current bar), the Rows / Order toolbar, a jump to a filtered row
  {
    const { page, errors } = await openPage('#view=timeline', 'light');
    const t31 = await page.evaluate(async () => {
      const wait = ms => new Promise(r => setTimeout(r, ms));
      const vis = el => !!el && el.getClientRects().length > 0;
      const out = {};
      if (!document.getElementById('tl-tools')) return { err: 'no #tl-tools' };
      out.brk = document.querySelectorAll('#tl i.b.brk').length;
      out.brkOutside = document.querySelectorAll('i.b.brk').length - out.brk;
      out.lowPrior = [...document.querySelectorAll('#tl i.b.brk')].filter(b => {
        const row = b.closest('.r'), cur = parseFloat(b.style.height);
        const pri = Math.max(0, ...[...row.querySelectorAll(':scope > .c:not(.cur) i.b')].map(x => parseFloat(x.style.height)));
        return pri < 0.3 * cur;
      }).map(b => b.closest('.r').id);
      const lanes = () => [...document.querySelectorAll('#tl .lane[data-kind="scored"]')].filter(l => !l.hidden);
      const shown = () => lanes().map(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(vis).length).join(',');
      const before = shown();
      document.querySelector('#tl-tools button[data-tlf="flagged"]').click(); await wait(80);
      out.unflaggedShown = lanes().flatMap(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(vis))
        .filter(r => !/^(large|moderate)$/.test(r.getAttribute('data-sev') || '')).map(r => r.id);
      out.flaggedHidden = lanes().flatMap(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(r => !vis(r)))
        .filter(r => /^(large|moderate)$/.test(r.getAttribute('data-sev') || '')).map(r => r.id);
      const typ = document.querySelector('#tl .lane[data-kind="scored"] .lrows > .r.bars[data-sev="typical"]');
      if (typ) { window.AWR_goTo(typ, true, false); await wait(300);
        out.reveal = vis(typ) && !document.getElementById('tl').classList.contains('flagonly') ? 'ok' : 'FAIL ' + typ.id; } else out.reveal = 'none';
      document.querySelector('#tl-tools button[data-tlf="all"]').click(); await wait(80);
      out.restored = shown() === before ? 'ok' : 'FAIL ' + before + ' -> ' + shown();
      const waits = document.getElementById('lane-waits');
      if (waits && !waits.hidden) {
        const ids = () => [...waits.querySelectorAll('.lrows > .r.bars')].map(r => r.id).join(' ');
        const orig = ids();
        document.querySelector('#tl-tools button[data-tlo="change"]').click(); await wait(80);
        const all = [...waits.querySelectorAll('.lrows > .r.bars')], aas = all.every(r => r.getAttribute('data-unit') === 'AAS');
        const nums = s => String(s || '').split(',').map(x => x === '' ? null : +x);
        const ev = all.filter(r => !/^tl-fr-w-/.test(r.id));
        const k = ev.map(r => window.AWR_WG.changeKey(nums(r.getAttribute('data-v')), +r.getAttribute('data-mu'), +r.getAttribute('data-sd'), aas));
        out.sorted = k.every((x, i) => i === 0 || x == null || k[i - 1] == null || k[i - 1] >= x) ? 'ok' : 'FAIL ' + JSON.stringify(k);
        const fe = all.findIndex(r => !/^tl-fr-w-/.test(r.id));
        out.classesFirst = fe < 0 || all.slice(fe).every(r => !/^tl-fr-w-/.test(r.id));
        document.querySelector('#tl-tools button[data-tlo="report"]').click(); await wait(80);
        out.order = ids() === orig ? 'ok' : 'FAIL order not restored';
      } else out.order = 'none';
      try { localStorage.removeItem('awr-tl-rows'); localStorage.removeItem('awr-tl-order'); } catch (e) { /* ignore */ }
      return out;
    });
    console.log('timeline rows (031)', JSON.stringify(t31));
    if (t31.err) fail('timeline rows: ' + t31.err);
    else {
      if (t31.brkOutside) fail('timeline rows: ' + t31.brkOutside + ' broken bar(s) outside the Timeline grid');
      if (t31.lowPrior.length) fail('timeline rows: priors still squashed under a broken bar: ' + t31.lowPrior.join(', '));
      if (t31.unflaggedShown.length) fail('timeline rows: Flagged only shows ' + t31.unflaggedShown.join(', '));
      if (t31.flaggedHidden.length) fail('timeline rows: Flagged only hides flagged ' + t31.flaggedHidden.join(', '));
      if (/^FAIL/.test(t31.reveal)) fail('timeline rows: jump to a filtered row ' + t31.reveal);
      if (/^FAIL/.test(t31.restored)) fail('timeline rows: All did not restore ' + t31.restored);
      if (/^FAIL/.test(t31.sorted || '') || t31.classesFirst === false) fail('timeline rows: Biggest change first ' + t31.sorted);
      if (/^FAIL/.test(t31.order)) fail('timeline rows: ' + t31.order);
      if (/demo_busy_db\.html$/.test(file) && t31.brk < 5) fail('timeline rows: the demo should draw broken Current bars (got ' + t31.brk + ')');
    }
    if (errors.length) fail('timeline rows: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }
```

The block resets the two localStorage keys at its end: every page of the
smoke test shares one browser profile, and a left-over "Flagged only"
would hide rows from later checks. Add to the file's header comment:
`- the Timeline rows (plan 031): broken Current bars only in #tl, the
priors under one at least 30 % of its height, Flagged only / All / a jump
to a hidden row, Biggest change first (wait classes first, sorted) and
Report order restoring the ids' order;`.

**Verify**: the browser smoke test → `verify: OK` on the classic page, then
on `docs/examples/demo_busy_db_dashboard.html` (one at a time; the demo-only
"at least 5 broken bars" line applies to the classic page only, like the
file's other demo-only checks). On the current demo the log line shows
about 14 broken bars and `Waits: by size of the move (z)` in the note (the
Waits event rows are in seconds until plan 030 lands). Also open the quiet
page in the Timeline view once: the toolbar is readable in its skin (if it
is not, report it; do not edit the design files).

## Test plan

- Unit: 3 cases in `tools/js_unit_tests.js` (step 2): the old scale
  outside the Timeline, the cut inside it (incl. the demo's physical
  reads), the change key in AAS and in z.
- Browser: block 5d in `demo/verify_report.js` (step 6; block 5c belongs to plan 024). A prototype of
  steps 1, 3 and 4 run against the demo gave: 14 broken bars, priors at
  0.62-0.67 of the Current bar's height, Headline lane 12 -> 8 rows and
  Waits 13 -> 7 under "Flagged only" (no flagged row hidden), a jump to
  `tl-fr-l-db-cpu` lifting the filter, Waits sorted with
  `tl-we-db-file-scattered-read` first, and Report order restoring the
  original row order with the fold.
- Manual (optional): open the demo in the Timeline view; the prior bars
  of "Physical reads" now show the step at 13 Aug; the Current bar has a
  diagonal cut; hovering it says "bar cut"; "Flagged only" leaves 8
  headline and 7 wait rows; reload keeps the choice; "All" brings back the
  normal rows and the "+ Show N more events" fold.

## Done criteria

- [ ] `node tools/js_unit_tests.js` exits 0 and prints the 3 plan-031 cases
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `./tools/check.sh` ends `check.sh: all checks passed`
- [ ] `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/lib/src/js_timeline.js sql/_style.sql tools/js_unit_tests.js` prints `0` four times
- [ ] the browser smoke test ends `verify: OK` with a `timeline rows (031)` line and no `timeline rows:` failure, on `docs/examples/demo_busy_db.html` and on `docs/examples/demo_busy_db_dashboard.html`
- [ ] `git diff --stat` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `sizeRow`, `TL.reveal`, `cellTip`'s last line, the boot block or the
  four `#tl` CSS lines do not match the excerpts (drift beyond added
  functions).
- After plan 030 landed, the Waits lane's event rows carry a `data-unit`
  other than exactly `AAS` while showing AAS values (then the sort falls
  back to z: report the unit string rather than changing 030's output).
- A hero-strip or finding-card chart looks different after step 1 (the
  `tl` false path must be byte-for-byte the old scale).
- The smoke test's existing Timeline checks (section 5: data-tl jumps,
  ruler pin, grid tooltip) fail after this change.

## Maintenance notes

- `AWR_WG.rowScale` is the one place that decides a bar's scale; anything
  that later adds bars to `#tl` (new lanes, plan 027-style tags) inherits
  the cut. The 1.5 factor trades how tall the priors are (up to 2/3 of the
  row) against how often a Current bar is cut; change it with the unit test.
- **Open owner decisions**: (a) the defaults — "Flagged only" and
  "Biggest change first" could be the defaults (the Summary already ranks
  by impact after plan 020); this plan keeps today's behaviour so nothing
  disappears without a click; (b) whether finding-card charts should get
  the same cut (there the jump IS the message, so this plan leaves them).
- With plan 030 (wait events in AAS) the Waits lane sorts by added AAS and
  the note reads "Waits: by added AAS"; nothing else changes here.
- **Needs owner DB run** (no database for the executor): rsync to dbmint
  without `--delete`
  (`rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'`;
  never port 2201). dbmint keeps 35 days of AWR, so the old September
  dates return empty windows: probe first and pin inside a restart-free
  stretch (on 2026-11-19: 2026-11-07 14:45 to 2026-11-09 16:15). Run the
  busy hour there (wrapper arguments `"2026-11-08 15:00" 1 8 10 0 1 h`: a
  heavy blocking hour against eight quiet ones), the plan-change hour
  (`"2026-11-08 11:00" 1 8 10 0 1 h`) and one long run (168 hourly windows
  ending in that stretch; older ones may be skipped, which is fine) to see
  the toolbar with many columns. Check: rc 0, 29/29 `AWR-SECTION` BEGIN/END pairs (sections 20-28
  added nine), `ORA-` only in captured SQL text, `demo/verify_report.js` OK on
  every report (one Chrome at a time), and on the busy report that a lane
  with no flagged row shows "No large or moderate row here" under
  "Flagged only".
