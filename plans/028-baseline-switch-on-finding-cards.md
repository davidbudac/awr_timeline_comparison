# Plan 028: Each finding card can show its normal range three ways (as scored, robust, since the last release) — display only

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/lib/src/js_wingrid.js sql/lib/js_wingrid.plsql sql/lib/src/js_microstrip.js sql/lib/js_microstrip.plsql sql/_style.sql sql/07_summary.sql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/lib/css_design.plsql sql/26_window_similarity.sql sql/28_release_delta.sql tools/check.sh demo/verify_report.js`
> `sql/07_summary.sql` is read, not edited. Plans 020 / 025 / 027 / 031
> also touch some of these files. If any changed since this plan was
> written, compare the "Current state" excerpts against the live code
> before proceeding; on a mismatch in a block this plan edits, treat it as
> a STOP condition. Functions added to `js_wingrid.js` by plan 027 or 031
> (`avg`, `sdev`, `esc`, `winIdx`, `tagCards`, `W.patterns`,
> `W.rowScale` ...) are expected — reuse them, never add a second copy.

## Status

- **DROPPED 2026-11-19 by the owner**: sections 26 (window similarity) and
  28 (before / after a release) already cover what this switch would show.
  Do not execute this plan; it is kept for reference only.
- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (client-side, display only: no severity, order, count or verdict changes)
- **Depends on**: none (shares helpers with plan 027 if it landed first)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: mechanically valid
  (`js_wingrid.js`, `js_microstrip.js`, `07_summary.sql`, `tools/check.sh`
  unchanged; `_style.sql` lines moved +7; `awr_trend.sql` include lines
  moved +40). Its MOTIVATION now overlaps two new sections: 26 Window
  similarity (finds the odd prior windows and re-scores without them) and
  28 Before / after a release (splits the windows at a marker). The owner
  should confirm the plan is still wanted (see "Overlap with sections 26
  and 28"). Edits: the card selector excludes `.chg` (the dashboard design
  moves plan / config cards into `#findings`), one quiet / dashboard CSS
  rule set, the button titles point at sections 26 / 28, the demo is
  three files, verify_report runs on classic and dashboard, the DB-run
  pins and the section-pair count (29) are refreshed.

## Why this matters

A finding card's "normal" is the mean +/- 2 sigma of all valid prior
windows. That is the right scoring rule, but it hides two situations a DBA
needs to see: (1) one unusual prior window inflates sigma and widens
"normal", so a real change looks smaller; (2) the level stepped at an
earlier release, so "normal" mixes two regimes and the Current change
looks bigger than what the latest release added. In the demo, physical
reads are "5.4x normal" against all 12 windows, 5.8x against a robust
median, but only 4.5x against the 4 windows since Release 4.1 — the
release that matters for the question "what did Release 4.2 do?". This
plan adds a three-way switch to each finding card that recomputes the
card's normal range text, its ratio and the shaded band on its bars. It is
**display only**: the severity, the band glyph, the card order, the
counts and the verdict keep the report's scoring.

Target (under the card's big number):

```
 22.24 k/s
 normal 4,666-5,135/s (since Release 4.1, 4 windows) . x4.5 vs this range
 Normal range [mean +/- 2 sigma] [robust] [since Release 4.1]
 |  13 bars, the shaded band follows the chosen range  |
```

The mockup `plans/assets/ux-mockup-2026-11-17.html` (outline numbers 8,
9) shows the direction; the report's own look (`sql/_style.sql`) wins.

### Overlap with sections 26 and 28 (added 2026-11-19)

Two visualization sections landed after this plan was first written. Both
are library rows in Summary and full sections in All sections:

- **26 Window similarity** (`sql/26_window_similarity.sql`,
  `section#win-sim`, client `sql/lib/src/js_winsim.js`): "is the baseline
  sound?". It marks the prior windows unlike the rest ("odd one out"),
  suggests windows to drop, and RE-SCORES every canonical metric without
  them (`window.AWR_WINSIM.rescore(offsets)` → `{buckets, cards}`, its JS
  `bucket()` twins `policy_bucket()`). That answers this plan's case (1)
  — one unusual prior window widening "normal" — report-wide and with
  real severities.
- **28 Before / after a release** (`sql/28_release_delta.sql`,
  `section#release-delta`, client `sql/lib/src/js_reldelta.js`): splits
  the valid windows at a release marker (before = windows ending at or
  before it, after = windows starting at or after it, Current included)
  and lists every metric's change across the split. That answers "what did
  Release 4.1 do?"; it does NOT answer this plan's case (2), "how does
  Current compare with only the windows since Release 4.1?" (28's
  "before" side always includes every older window).

What this plan still adds: the alternative range IN PLACE, on the card a
reader is looking at, without leaving Summary. It stays display only and
does NOT reuse 26's `bucket()` or `rescore()` (that would put a second
severity on the card). The two button titles point the reader at the
sections for the report-wide view (step 4). If the owner prefers not to
have three ways to look at "normal", the cheapest cut is to drop the
"robust" mode (26 covers it) and keep "since a release"; record the
decision in `plans/README.md` before executing.

## Current state

How the report is built (the parts this plan touches):

- Client JavaScript for the window component lives in the readable source
  `sql/lib/src/js_wingrid.js`; `tools/js2plsql.sh js_wingrid` turns it into
  the PUT_LINE body of `sql/lib/js_wingrid.plsql`. Same for
  `sql/lib/src/js_microstrip.js` → `sql/lib/js_microstrip.plsql`. **Edit
  the `.js`, never the `.plsql` body**; lint check 24 fails on a stale body.
  The driver loads `js_microstrip` before `js_wingrid` (`awr_trend.sql`
  lines 619 and 633), so `js_wingrid` can use what `js_microstrip` exposes.
- The demo (rendered by `python3 demo/gen_demo_report.py`, no database)
  lifts both scripts, `sql/_style.sql` and the design files verbatim, so
  this plan needs **no hand-port** in `demo/awrdemo/`; only a regeneration
  committed with the change. The generator now writes THREE pages, one per
  report design: `docs/examples/demo_busy_db.html` (classic),
  `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html`; `--check`
  covers all three.
- Report designs (`CLAUDE.md` "### Report designs"): `design` = `classic`
  (default) / `quiet` / `dashboard`. Quiet / dashboard add
  `sql/lib/src/css_design.css` (→ generated `sql/lib/css_design.plsql`,
  `tools/js2plsql.sh css_design`) and `sql/lib/src/js_design.js`. Design
  rules never go in `sql/_style.sql`. In the dashboard, `js_design.js`
  (the page's last `DOMContentLoaded` handler, so after this plan's
  `cardSwitch()`) moves every finding card into the body of a closed
  `details.drow.lead` row of a findings table, and moves `#s-changes` (the
  plan / config cards, `article.fc.chg`) INTO `#findings`. The row's
  summary shows the card's value and its "Normal" text, read ONCE from
  `.big .nrm` when the table is built; a switch click inside the open card
  does not update that summary text (fine: display only, the row keeps
  the scored range). The plan / config cards also carry a
  `.fc-main .big .nrm` and a `.wg .r` row, so this plan's selector must be
  `#findings article.fc:not(.chg)` (the one `demo/verify_report.js`
  section 6 uses since the designs landed). The design's button look,
  `css_design.css` lines 79-81:

```css
.seg{border:0;border-radius:10px;padding:3px;background:var(--chip-bg);gap:2px}
.seg button{border-radius:7px;font-weight:500;color:var(--muted);padding:3px 11px}
.seg button[aria-pressed="true"]{background:var(--panel);color:var(--ink);box-shadow:0 1px 2px oklch(0 0 0 / 8%),0 0 0 1px var(--hairline)}
```

A finding card's markup, `sql/07_summary.sql:434-440` (`emit_card`):

```sql
        DBMS_OUTPUT.PUT_LINE('<div class="fc-b"><div class="fc-main">'
            || '<div class="big"><span class="v">' || fv_num(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="u">' || fv_unit(r.cur_val * v_s, v_u) || '</span>'
            || '<span class="nrm" title="prior mean ' || fv(r.prior_mean * v_s, v_u) || '">normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</span></div>');
        DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
            || wg_bars(r.wv, v_s, r.prior_mean, r.prior_sd, v_sev) || wg_dates(TRUE) || '</div></div>');
```

Rendered in the demo (card `#f-io`):

```html
<div class="fc-b"><div class="fc-main"><div class="big"><span class="v">22.24 k</span><span class="u">/s</span><span class="nrm" title="prior mean 4,143/s">normal 3,003&ndash;5,284/s</span></div>
<div class="wg bare allv" data-wg style="--np:12"><div class="r fr t2" aria-hidden="true"><div class="flags"></div></div><div class="r bars" data-v="3837.399,3767.106,3890.696,3773.923,3866.55,3526.601,3687.419,3767.599,4850.898,5072.253,4809.715,4868.913,22240.52" data-mu="4143.256" data-sd="570.1279" ...
```

- `data-v`: one value per compared window, oldest first, Current last
  (empty token = no value). `data-mu` / `data-sd`: the scored prior mean /
  sample sd, in the same display unit. `.u` holds the unit as printed;
  byte units are scaled for display (`MB/s`, `kB/s`, `GB/s`, base `B/s`).
- The server's range rule, `sql/lib/finding_cards.plsql:193-209`
  (`fv_range`): sigma floored at 2 % of |mean|; low end floored at 0;
  `B/s` scaled by the upper end; a unit starting with `/` is glued on
  (`3,003-5,284/s`), any other unit follows a space (`8.38-14.3 AAS`).
- The page's one Delta rule (`sql/lib/band_glyph.plsql` `delta_span`,
  client copy `sql/lib/src/js_timeline.js:24-30`): `x n.n` when
  Current/mean >= 2, else an up / down triangle and `p.p%`.
- How the bars draw the band, `sql/lib/src/js_wingrid.js:36-53`
  (`sizeRow`): it reads `data-mu` / `data-sd` every time it draws, floors
  sigma at 2 %, and is re-run by `W.render(scope)` on a view switch and on
  a `<details>` toggle. So changing `data-mu` / `data-sd` and calling
  `sizeRow(row)` moves the band, and later re-renders keep the choice.
- On the DB time card, `js_timeline` (which runs after `js_wingrid`)
  turns the bars row into a stacked `.r.ash` row
  (`sql/lib/src/js_timeline.js` `activity()`), keeping `data-v`. Never
  call `sizeRow` on a row that no longer has the class `bars`.
- `window.AWR_WIN.w[i]` = `{"o":..,"d":"13 Aug",..,"v":"Y"|"N"}` oldest
  first; `v:"N"` = skipped window. `AWR_WG.markers()` (js_wingrid lines
  21-31) gives each release marker as `{o, l: label, ...}` where `o` is the
  column whose LEFT edge it sits on. In the demo the markers land on column
  indices 2, 3, 5, 8 (Release 4.1) and 12 (Release 4.2, the Current one).
- Client number format: `sql/lib/src/js_microstrip.js:6-13` defines
  `fmt(p)` — "client twin of sql/lib/fmt_num.plsql" — inside its IIFE; line
  50 exposes only `window.AWR_microStrip=strip;`.
- Helpers already in `js_wingrid.js` (lines 4-9): `$$`, `mk`, `num`,
  `nums`. Boot line 137:

```js
doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);setTimeout(refit,300);});
```

- Card CSS, `sql/_style.sql:1327`:

```sql
    DBMS_OUTPUT.PUT_LINE('.fc .big .nrm{color:var(--muted);font-size:13px;flex-basis:100%}');
```

Repo rules that apply here (each has broken the report before):

- **Never type a tilde** in `sql/lib/src/*.js` or `sql/_style.sql` (even in
  a comment): `SET DEFINE` makes it a substitution character.
- **Emitted text must be pure ASCII** (lint check 25). The code below writes
  every special character as an HTML entity inside `innerHTML` strings
  (`&plusmn;`, `&sigma;`, `&times;`, `&ndash;`, `&middot;`, `&#9650;`,
  `&#9660;`, `&#39;`) — keep it that way. Do NOT type `\u` escape sequences
  into your tool input: some agent tools turn them into the literal
  character. Check with the ASCII command below.
- A source line of a `src/*.js` file must stay under 2300 characters.
- `sql/_style.sql` rules are PUT_LINE string literals; this plan adds no
  single quote. `_style.sql` is also included by the fleet report: the new
  selectors are scoped under `.fc` (single-DB only).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate client scripts | `tools/js2plsql.sh js_wingrid` and `tools/js2plsql.sh js_microstrip` | `... regenerated` |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0, no output |
| JS unit tests | `node tools/js_unit_tests.js` | last line `N tests passed`, exit 0 |
| ASCII check | `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/lib/src/js_microstrip.js sql/_style.sql tools/js_unit_tests.js` | `0` for each file |
| Regenerate the design stylesheet | `tools/js2plsql.sh css_design` | `sql/lib/css_design.plsql regenerated` |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote .../docs/examples/demo_busy_db*.html (... KB)` lines |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | three `up to date: ...` lines |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d) && (cd $T && npm i playwright@1.55 >/dev/null) && NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` for each (about 3 min each; one after the other, never two at once) |

There is no database available to you; the owner's checks are listed under
"Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/lib/src/js_wingrid.js`, `sql/lib/js_wingrid.plsql` (regenerated;
  extend its header comment by hand)
- `sql/lib/src/js_microstrip.js`, `sql/lib/js_microstrip.plsql`
  (regenerated; one exported name, header comment)
- `sql/_style.sql` (switch styles)
- `sql/lib/src/css_design.css`, `sql/lib/css_design.plsql` (regenerated):
  the switch in the quiet / dashboard look (step 5)
- `tools/js_unit_tests.js` (create, or extend if plan 027 / 031 created it)
- `tools/check.sh` (one step, only if not already added by 027 / 031)
- `demo/verify_report.js` (one check)
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
  `demo_busy_db_dashboard.html` (regenerated, never hand-edited)
- `CLAUDE.md` (one paragraph), `CHANGELOG.md` (one bullet)

**Out of scope** (do NOT touch):
- Sections 26 / 28 and their scripts (`sql/26_window_similarity.sql`,
  `sql/28_release_delta.sql`, `js_winsim.js`, `js_reldelta.js`): the
  switch only names them in two button titles; it never calls
  `AWR_WINSIM` or reads `AWR_DATA.winsim` / `AWR_DATA.reldelta`.
- `sql/lib/src/js_design.js`: no change needed (the switch sits inside the
  card, which the dashboard moves as a whole).
- Scoring: `sql/lib/metric_policy.plsql` (`policy_bucket`),
  `sql/lib/score_cells.plsql`, `sql/07_summary.sql`, `sql/00_params.sql`
  (verdict), `docs/metric_policy.html`. A robust baseline **for scoring**
  is an open owner decision (see Maintenance notes), not this plan.
- The card headline (`h3`, "Physical reads 5.4x normal"), the band glyph in
  the card header, the evidence rows, the triage list (plan 025), the
  verdict: they keep the scored numbers.
- The hero strip (08), Timeline rows, table micro strips — no switch there.
- Every fleet file and the demo twins under `demo/awrdemo/`.

## Git workflow

- Branch: `advisor/028-baseline-switch` from `main`, which must contain
  `5594f2c` (`git merge-base --is-ancestor 5594f2c HEAD` exits 0; if not,
  STOP: the checkout predates the designs and sections 20-28).
- One commit, e.g. `feat(report): baseline switch on finding cards (robust / since a release), display only`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Expose the client number format

In `sql/lib/src/js_microstrip.js`, right after line 50
(`window.AWR_microStrip=strip;`), add:

```js
window.AWR_fmtNum=fmt;
```

In the header comment of `sql/lib/js_microstrip.plsql` (above `BEGIN`),
change "Exposes window.AWR_microStrip(csv, title) -> {svg, title} and" so
the list also names `window.AWR_fmtNum(v)` (the client twin of
`fmt_num`, used by `js_wingrid`'s baseline switch).

**Verify**: `tools/js2plsql.sh js_microstrip` → `sql/lib/js_microstrip.plsql regenerated`;
`grep -c "AWR_fmtNum=fmt" sql/lib/js_microstrip.plsql` → `1`.

### Step 2: Add the pure functions to `js_wingrid.js`

If plan 027 already added `avg` and `sdev`, skip the two lines marked
`(skip if present)`. Insert after line 32 (`W.markerAt=...`) — or, if plan
027 landed, right before its `function esc(s){` line:

```js
function avg(a){var s=0;for(var i=0;i<a.length;i++)s+=a[i];return s/a.length;}  /* (skip if present) */
function sdev(a){if(a.length<2)return 0;var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return Math.sqrt(s/(a.length-1));}  /* (skip if present) */
/* ---- baseline switch (plan 028): another "normal" for one finding card,
   DISPLAY ONLY (the severity, the band glyph, the card order and every
   count keep the report's scoring).  Pure: vals oldest first (null = no
   value), valid[i] false = a skipped window; mode "mean" = mean +- 2 sigma
   (as scored), "robust" = median +- 2 x 1.4826 MAD, "since" = mean +- 2
   sigma of the prior windows from index from on.  sigma is floored at 2%
   of the centre, like the band.  null below 4 (since: 3) valid windows. */
function median(a){var b=a.slice().sort(function(x,y){return x-y;}),n=b.length;if(!n)return null;return n%2?b[(n-1)/2]:(b[n/2-1]+b[n/2])/2;}
W.baseline=function(vals,valid,mode,from){
  var n=vals.length,p=[],i;
  for(i=0;i<n-1;i++)if(vals[i]!=null&&valid[i]!==false&&(mode!=="since"||i>=from))p.push(vals[i]);
  if(p.length<(mode==="since"?3:4))return null;
  var mid,sd;
  if(mode==="robust"){mid=median(p);sd=1.4826*median(p.map(function(v){return Math.abs(v-mid);}));}
  else{mid=avg(p);sd=sdev(p);}
  var den=Math.max(sd,0.02*Math.abs(mid));
  return {mid:mid,sd:sd,lo:Math.max(0,mid-2*den),hi:mid+2*den,n:p.length};
};
/* the most recent marker with at least 3 valid prior windows from it on
   (a marker on the Current window has none) */
W.sinceMark=function(vals,valid,marks){
  var n=vals.length,best=null;
  (marks||[]).forEach(function(m){
    if(m.i==null||m.i<1||m.i>n-2)return;
    var c=0;for(var i=m.i;i<n-1;i++)if(vals[i]!=null&&valid[i]!==false)c++;
    if(c>=3&&(!best||m.i>best.i))best=m;
  });
  return best;
};
/* sql/lib/finding_cards.plsql fv_range, client side: "3,482&ndash;4,222/s" */
W.fvRange=function(lo,hi,unit){
  var F=window.AWR_fmtNum||function(v){return String(v);};
  if(unit==="B/s"){var d=hi>=1e9?1e9:hi>=1e6?1e6:hi>=1e3?1e3:1;
    return F(lo/d)+"&ndash;"+F(hi/d)+" "+(d===1e9?"GB/s":d===1e6?"MB/s":d===1e3?"kB/s":"B/s");}
  return F(lo)+"&ndash;"+F(hi)+(!unit?"":unit.charAt(0)==="/"?unit:" "+unit);
};
/* the page's one Delta rule (sql/lib/band_glyph.plsql delta_span), as HTML */
W.deltaTxt=function(cur,mu){
  if(cur==null||mu==null||mu===0)return "&mdash;";
  var q=cur/mu;if(mu>0&&q>=2)return "&times;"+(q<100?q.toFixed(1):Math.round(q));
  var p=(cur-mu)/Math.abs(mu)*100;return (p>=0?"&#9650; ":"&#9660; ")+Math.abs(p).toFixed(1)+"%";
};
```

(Remove the `/* (skip if present) */` markers when you paste; they are
instructions, not code.)

**Verify**: `tools/js2plsql.sh js_wingrid` → regenerated; `./lint.sh` → clean;
`grep -c "^function avg\|^function sdev" sql/lib/src/js_wingrid.js` → `2`
(exactly one of each).

### Step 3: Unit tests (`tools/js_unit_tests.js`)

If `tools/js_unit_tests.js` does not exist, create it with this harness
(plans 027 / 031 use the same one; if it exists, only append the block
below right before the final `console.log(passed + ' tests passed');`):

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

Tests for this plan (the demo's physical-reads series; expectations were
computed against a prototype of exactly the code in step 2 — if one fails,
re-check step 2, never edit an expectation):

```js
/* ---- plan 028: W.baseline / sinceMark / fvRange / deltaTxt (js_wingrid + js_microstrip) ---- */
{
  const W = load('js_wingrid', load('js_microstrip', {})).AWR_WG;
  const ALL = new Array(13).fill(true);
  const MARKS = [{ i: 2, l: 'Release 4.0' }, { i: 3, l: 'Hotfix 4.0.1' }, { i: 5, l: 'RU 19.28 patch' },
                 { i: 8, l: 'Release 4.1' }, { i: 12, l: 'Release 4.2' }];
  const PR = [3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
              4850.898, 5072.253, 4809.715, 4868.913, 22240.52];
  const near = (a, b) => Math.abs(a - b) < 0.01;
  test('mean: the scored range', () => {
    const r = W.baseline(PR, ALL, 'mean');
    assert.ok(near(r.mid, 4143.256) && near(r.lo, 3003.0) && near(r.hi, 5283.51) && r.n === 12, JSON.stringify(r));
  });
  test('robust: median +- 2 x 1.4826 MAD', () => {
    const r = W.baseline(PR, ALL, 'robust');
    assert.ok(near(r.mid, 3851.9745) && near(r.sd, 184.898) && r.n === 12, JSON.stringify(r));
    assert.strictEqual(W.fvRange(r.lo, r.hi, '/s'), '3,482&ndash;4,222/s');
    assert.strictEqual(W.deltaTxt(PR[12], r.mid), '&times;5.8');
  });
  test('since the last usable marker', () => {
    const m = W.sinceMark(PR, ALL, MARKS);
    assert.deepStrictEqual(m, { i: 8, l: 'Release 4.1' });
    const r = W.baseline(PR, ALL, 'since', m.i);
    assert.ok(near(r.mid, 4900.445) && r.n === 4, JSON.stringify(r));
    assert.strictEqual(W.fvRange(r.lo, r.hi, '/s'), '4,666&ndash;5,135/s');
    assert.strictEqual(W.deltaTxt(PR[12], r.mid), '&times;4.5');
  });
  test('no usable marker / too few windows', () => {
    assert.strictEqual(W.sinceMark(PR, ALL, [{ i: 10, l: 'x' }, { i: 12, l: 'y' }]), null);
    assert.strictEqual(W.baseline(PR, ALL, 'since', 10), null);
    assert.strictEqual(W.baseline([null, null, null, null, null, null, null, null, null, 3, 4, 5, 9], ALL, 'mean'), null);
  });
  test('skipped windows are left out', () => {
    const v = PR.slice(); v[9] = null; const ok = ALL.slice(); ok[9] = false;
    assert.deepStrictEqual(W.sinceMark(v, ok, MARKS), { i: 8, l: 'Release 4.1' });
    assert.strictEqual(W.baseline(v, ok, 'since', 8).n, 3);
    assert.strictEqual(W.baseline(v, ok, 'mean').n, 11);
  });
  test('range text per unit', () => {
    assert.strictEqual(W.fvRange(2.8e6, 4.5e6, 'B/s'), '2.800&ndash;4.500 MB/s');
    assert.strictEqual(W.fvRange(5.27, 9.182, 'AAS'), '5.270&ndash;9.182 AAS');
    assert.strictEqual(W.fvRange(0.4589, 0.8569, 'AAS'), '0.4589&ndash;0.8569 AAS');
  });
  test('Delta rule', () => {
    assert.strictEqual(W.deltaTxt(0.8686635, 0.7089704), '&#9650; 22.5%');
    assert.strictEqual(W.deltaTxt(90, 100), '&#9660; 10.0%');
    assert.strictEqual(W.deltaTxt(5, 0), '&mdash;');
  });
}
```

If `tools/check.sh` has no "client JS unit tests" step yet, add this block
right before `step "generated docs are fresh (demo report, policy page)"`,
and the line `#   6. client JS unit tests        tools/js_unit_tests.js (skipped without node)`
to its header comment:

```sh
step "client JS unit tests (node)"
if command -v node >/dev/null 2>&1; then
    node tools/js_unit_tests.js || fail=1
else
    echo "node not found: skipped"
fi
```

**Verify**: `node tools/js_unit_tests.js` → the 7 plan-028 cases print
`ok - ...`, last line `N tests passed`, exit 0.

### Step 4: Put the switch on the cards

In `js_wingrid.js`, after `W.deltaTxt`, add the DOM glue. If plan 027 or
031 already defined `esc` or `winIdx`, do not add them again:

```js
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}
/* the compared windows as column indices: validity, dates, marker columns */
function winIdx(){
  var w=(window.AWR_WIN&&window.AWR_WIN.w)||[],valid=[],dates=[],ix={};
  w.forEach(function(x,i){valid.push(x.v!=="N");dates.push(x.d);ix[x.o]=i;});
  var marks=W.markers().map(function(m){return {i:ix[m.o],l:m.l};}).filter(function(m){return m.i!=null;});
  return {valid:valid,dates:dates,marks:marks};
}
/* the base unit of a card's value ("MB/s" on the page -> "B/s") */
function baseUnit(card){var u=card.querySelector(".fc-main .big .u");u=u?u.textContent.trim():"";return /B\/s$/.test(u)?"B/s":u;}
/* every finding card (07) with at least 4 valid prior windows gets the
   switch under its big number; "mean" restores the server's text */
function cardSwitch(){
  var X=winIdx();if(!X.valid.length)return;
  $$("#findings article.fc:not(.chg)").forEach(function(card){
    var row=card.querySelector(".fc-main .wg .r[data-v]"),big=card.querySelector(".fc-main .big"),nrm=big?big.querySelector(".nrm"):null;
    if(!row||!nrm||card.querySelector(".bsw"))return;
    var vals=nums(row.getAttribute("data-v"));if(vals.length!==X.valid.length||!W.baseline(vals,X.valid,"mean"))return;
    var sm=W.sinceMark(vals,X.valid,X.marks),unit=baseUnit(card),cur=vals[vals.length-1];
    row.setAttribute("data-mu0",row.getAttribute("data-mu")||"");row.setAttribute("data-sd0",row.getAttribute("data-sd")||"");
    nrm.setAttribute("data-orig",nrm.innerHTML);nrm.setAttribute("data-otitle",nrm.getAttribute("title")||"");
    var box=mk("div","bsw");box.setAttribute("role","group");box.setAttribute("aria-label","Normal range shown on this card");
    box.innerHTML='<span class="bsl" title="Display only: the severity, the band and the order of the cards keep the report&#39;s scoring (mean &plusmn; 2&sigma; of every valid prior window).">Normal range</span>'
      +'<button type="button" data-b="mean" aria-pressed="true" title="Mean &plusmn; 2&sigma; of every valid prior window, as scored">mean &plusmn; 2&sigma;</button>'
      +'<button type="button" data-b="robust" aria-pressed="false" title="Median &plusmn; 2 &times; 1.4826 MAD: one unusual prior window cannot widen it. Window similarity shows which windows are odd and what dropping them changes.">robust</button>'
      +'<button type="button" data-b="since" aria-pressed="false"'+(sm?' title="Only the prior windows from '+esc(sm.l)+' on. Before / after a release compares every metric across a release.">since '+esc(sm.l):' disabled title="Needs a release marker with at least 3 valid prior windows after it">since a release')+'</button>';
    big.parentNode.insertBefore(box,big.nextSibling);
    box.addEventListener("click",function(ev){
      var b=ev.target&&ev.target.closest?ev.target.closest("button[data-b]"):null;if(!b||b.disabled)return;
      var mode=b.getAttribute("data-b");
      $$("button[data-b]",box).forEach(function(x){x.setAttribute("aria-pressed",String(x===b));});
      if(mode==="mean"){nrm.innerHTML=nrm.getAttribute("data-orig");nrm.setAttribute("title",nrm.getAttribute("data-otitle"));
        row.setAttribute("data-mu",row.getAttribute("data-mu0"));row.setAttribute("data-sd",row.getAttribute("data-sd0"));}
      else{
        var r=W.baseline(vals,X.valid,mode,sm?sm.i:0);if(!r)return;
        nrm.innerHTML="normal "+W.fvRange(r.lo,r.hi,unit)+' <span class="bsn">('+(mode==="robust"?"median &plusmn; 2 robust &sigma;":"since "+esc(sm.l)+", "+r.n+" windows")+')</span> &middot; <b class="d">'+W.deltaTxt(cur,r.mid)+"</b> vs this range";
        nrm.removeAttribute("title");
        row.setAttribute("data-mu",String(r.mid));row.setAttribute("data-sd",String(r.sd));
      }
      if(row.classList.contains("bars"))sizeRow(row);
    });
  });
}
```

Design decisions baked in (do not change without the owner): the switch is
on **every** finding card with at least 4 valid prior windows (large and
moderate alike); the choice is **not persisted** (a reload shows the
scored range); the original values are kept in `data-mu0` / `data-sd0`
(plan 027's pattern tags read those); `.fc-h` (severity, band glyph) and
the `h3` headline are never touched; plan / config cards (`.chg`) never
get a switch, in any design.

Change the boot line (137) to run it after the render (if plan 027 added
`tagCards();`, keep it before `cardSwitch();`):

```js
doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);cardSwitch();setTimeout(refit,300);});
```

Extend the header comment of `sql/lib/js_wingrid.plsql` (above `BEGIN`):

```
--   baseline(vals, valid, mode, from)   a card's normal range as scored /
--                 robust / since a marker (pure; plan 028), sinceMark,
--                 fvRange, deltaTxt; cardSwitch() adds the display-only
--                 switch (.bsw) to every finding card on DOMContentLoaded
--                 and keeps the scored values in data-mu0 / data-sd0
```

**Verify**: `tools/js2plsql.sh js_wingrid` → regenerated;
`tools/js2plsql.sh --check` → exit 0; `./lint.sh` → clean;
`node tools/js_unit_tests.js` → all pass;
`grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/lib/src/js_microstrip.js` → `0` twice.

### Step 5: Style, regenerate, document

In `sql/_style.sql`, right after line 1327 (`.fc .big .nrm{...}`), add:

```sql
    -- plan 028: the display-only baseline switch under a finding card's number
    DBMS_OUTPUT.PUT_LINE('.fc .bsw{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin-top:6px;font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.fc .bsw .bsl{margin-right:4px;cursor:help}');
    DBMS_OUTPUT.PUT_LINE('.fc .bsw button{font:inherit;font-size:12px;line-height:18px;padding:1px 8px;border:1px solid var(--line-2);border-radius:6px;background:var(--panel);color:var(--ink-2);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('.fc .bsw button[aria-pressed="true"]{background:var(--chip-bg);color:var(--ink);font-weight:600;border-color:var(--ink-4)}');
    DBMS_OUTPUT.PUT_LINE('.fc .bsw button:disabled{opacity:.45;cursor:default}');
    DBMS_OUTPUT.PUT_LINE('.fc .bsw button:focus-visible{outline:2px solid var(--acc);outline-offset:1px}');
    DBMS_OUTPUT.PUT_LINE('.fc .big .nrm .bsn{color:var(--ink-4)}');
```

(`--line-2` and `--ink-2` are alias tokens declared on `body`; that is
correct here — never declare a new alias on `:root`.)

The quiet / dashboard look: in `sql/lib/src/css_design.css`, section "9.
finding / change cards", right after the line
`.fc-k .sv > .dotk,.fc-k .sv > i{display:none}`, add (the switch then
looks like the design's view switch, `.seg`):

```css
.fc .bsw button{border-color:var(--hairline);border-radius:7px;font-weight:500;color:var(--muted)}
.fc .bsw button[aria-pressed="true"]{background:var(--panel);color:var(--ink);border-color:var(--hairline);box-shadow:0 1px 2px oklch(0 0 0 / 8%),0 0 0 1px var(--hairline)}
```

then `tools/js2plsql.sh css_design` → `sql/lib/css_design.plsql regenerated`.
Never put these two rules in `sql/_style.sql` (a classic report must not
change because of a design rule).

Regenerate the demo twice: `python3 demo/gen_demo_report.py`, then again;
`md5sum docs/examples/demo_busy_db*.html` must print the same three sums
after both runs.

`CLAUDE.md`, section "### Window component (`sql/lib/wingrid.plsql` +
`js_wingrid.plsql`)": add a paragraph "**Baseline switch (plan 028).**"
saying: display only; every `#findings article.fc:not(.chg)` with >= 4
valid prior windows; modes mean +/- 2 sigma (as scored) / robust median +/- 2 x 1.4826
MAD / since the most recent marker with >= 3 valid prior windows after it;
sigma floored at 2 %; it rewrites `.big .nrm` and the bars' `data-mu` /
`data-sd` (originals in `data-mu0` / `data-sd0`, restored by "mean"),
never `.fc-h`, the `h3`, the evidence, the order or a count; not
persisted; the dashboard's findings-row summary keeps the scored "Normal"
text; sections 26 (odd windows, re-scored) and 28 (before / after a
release) are the report-wide views of the same question;
`window.AWR_fmtNum` now comes from `js_microstrip`. In "### Micro
strips (`js_microstrip.plsql`)" note that it also exposes `AWR_fmtNum`.

`CHANGELOG.md`, `## Unreleased` → `### Report`:
`- **Finding cards can show their normal range three ways.** A small
switch under the big number: as scored (mean +/- 2 sigma of every prior
window), robust (median +/- MAD, so one odd window cannot widen it) or
since the last release marker. Display only: severity, order, counts and
the verdict are unchanged.`

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

### Step 6: Browser check (`demo/verify_report.js`)

In section 6 (`// ---- 6. phase 4 (v1.6.0)`), inside the
`page.evaluate(async () => { ... })`, add before
`window.AWR_setView('all', false);`:

```js
      // plan 028: the display-only baseline switch on the finding cards
      out.bsw = await (async () => {
        if (document.querySelector('article.fc.chg .bsw')) return 'FAIL a plan / config card has a switch';
        const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')].filter(c => c.querySelector('.bsw'));
        if (!cards.length) return 'none';
        for (const c of cards) {
          const head = c.querySelector('.fc-h').outerHTML, h3 = c.querySelector('h3').outerHTML;
          const nrm = c.querySelector('.big .nrm'), orig = nrm.innerHTML, row = c.querySelector('.fc-main .wg .r[data-v]'), mu = row.getAttribute('data-mu');
          for (const b of c.querySelectorAll('.bsw button:not([disabled])')) {
            b.click(); await wait(30);
            if (b.getAttribute('aria-pressed') !== 'true') return 'FAIL ' + c.id + ': aria-pressed';
            if (c.querySelector('.fc-h').outerHTML !== head || c.querySelector('h3').outerHTML !== h3) return 'FAIL ' + c.id + ': severity / headline changed';
          }
          c.querySelector('.bsw button[data-b="mean"]').click(); await wait(30);
          if (nrm.innerHTML !== orig || row.getAttribute('data-mu') !== mu) return 'FAIL ' + c.id + ': mean did not restore the scored range';
        }
        const io = document.getElementById('f-io'), t = {};
        if (io && io.querySelector('.bsw')) {
          for (const m of ['robust', 'since', 'mean']) { io.querySelector('.bsw button[data-b="' + m + '"]').click(); await wait(30); t[m] = io.querySelector('.big .nrm').textContent; }
        }
        return 'ok (' + cards.length + ' cards) ' + JSON.stringify(t);
      })();
```

and after the existing `if (!p4.subsOk) ...` line:

```js
    if (/^FAIL/.test(p4.bsw)) fail('baseline switch: ' + p4.bsw);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/3,482.4,222\/s.*5\.8.*4,666.5,135\/s.*Release 4\.1.*4\.5/.test(p4.bsw))
      fail('baseline switch: demo Physical I/O numbers ' + p4.bsw);
```

(The `.` in `3,482.4,222` matches the en dash without typing it. Section 6
runs for every design; in the dashboard the cards sit inside closed
findings rows, and a programmatic `click()` works on them all the same.) Add a
line to the file's header comment: `- the baseline switch (plan 028):
every enabled button leaves the card header / headline alone, "mean"
restores the scored range and band, the demo's Physical I/O card shows
3,482-4,222/s x5.8 (robust) and 4,666-5,135/s x4.5 since Release 4.1;`.

**Verify**: the browser smoke test → `verify: OK`.

## Test plan

- Unit: 7 cases in `tools/js_unit_tests.js` (step 3): the three modes on
  the demo series, the marker choice, too few windows, skipped windows,
  range text for `/s`, `B/s` and `AAS`, and the Delta rule.
- Browser: `demo/verify_report.js` (step 6) on the regenerated classic and
  dashboard demos, one after the other.
- Manual (optional): open the demo, Summary view, Physical I/O card: click
  "robust" — the text reads `normal 3,482-4,222/s (median +/- 2 robust
  sigma) . x5.8 vs this range` and the shaded band narrows; "since Release
  4.1" — `4,666-5,135/s ... x4.5`, band moves up to the post-4.1 bars;
  "mean" — back to `normal 3,003-5,284/s`. The red dot, the header band and
  "5.4x normal" never change. Dark mode keeps the buttons readable. In
  `demo_busy_db_dashboard.html` open the Physical I/O row: the switch is in
  the card and works the same; the plan-change card under "What changed
  around it" has no switch; `demo_busy_db_quiet.html`: the buttons look
  like the top bar's view switch.

## Done criteria

- [ ] `node tools/js_unit_tests.js` exits 0 and prints the 7 plan-028 cases
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `./tools/check.sh` ends `check.sh: all checks passed`
- [ ] `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/lib/src/js_microstrip.js sql/_style.sql tools/js_unit_tests.js sql/lib/src/css_design.css` prints `0` five times
- [ ] `python3 demo/gen_demo_report.py --check` prints three `up to date:` lines
- [ ] the browser smoke test ends `verify: OK` on `demo_busy_db.html` AND on `demo_busy_db_dashboard.html`
- [ ] `git diff --stat` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `sizeRow`, `W.markers`, the boot line (js_wingrid) or line 50 of
  `js_microstrip.js` do not match the excerpts.
- A unit expectation in step 3 fails after you re-checked step 2.
- The demo Physical I/O card's `.big .u` is not `/s`, or its `data-v`
  differs from the series in step 3 (the demo model changed: report it).
- Making it work seems to need a change to scoring, `sql/07_summary.sql`,
  a demo twin, a fleet file, `js_design.js` or a section 20-28 file.
- `plans/README.md` records an owner decision to drop this plan or a mode
  (see "Overlap with sections 26 and 28"): follow it, or stop if it is
  unclear which mode stays.

## Maintenance notes

- The switch reads only what the card already carries (`data-v`, the
  windows' validity, the markers) and writes only `.big .nrm` and the bars'
  `data-mu` / `data-sd`. Anything new that reads `data-mu` from a card row
  for scoring-like purposes must read `data-mu0` when present.
- **Open owner decision — robust scoring on the server.** Today scoring
  (`policy_bucket` in `sql/lib/metric_policy.plsql`, every consumer: 00
  verdict, 02, 03, 07, 08, 16, 17, `score_cells` for 04 / 05 / 18, the
  fleet's 01 / 03 / 04 / 06) uses mean / sample sd. Moving to median / MAD
  would make findings resistant to one bad prior window (a real
  regression is not hidden by an earlier incident) and would flag a step
  like Release 4.1's on its own. Costs: every consumer changes in one
  commit (lockstep rule), the Python twin `demo/awrdemo/helpers.py`, the
  generated `docs/metric_policy.html`, byte-identity baselines on dbmint
  are lost, and with 4-5 prior windows a MAD is unstable (it can be 0;
  the 2 % floor then decides alone). This plan's switch lets the owner
  see the effect on real reports before deciding. Since 2026-11-19 the
  scoring rule also has a client twin, `bucket()` in
  `sql/lib/src/js_winsim.js` (section 26), checked against PL/SQL on every
  load: a server-side change would have to move it in lockstep too.
- Deliberately left out: the switch on the hero strip (08), Timeline rows
  and the table micro strips; persisting the choice; a "pinned window"
  baseline (the Timeline's pin already compares against one window).
- **Needs owner DB run** (no database for the executor): rsync to dbmint
  without `--delete`
  (`rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'`;
  never port 2201). dbmint keeps only 35 days of AWR: probe first for a
  restart-free stretch (CLAUDE.md, "dbmint keeps 35 days of AWR"); on
  2026-11-19 that was 2026-11-07 14:45 to 2026-11-09 16:15, and this run
  fits it: `MARKERS='2026-11-08 10:30|Test release' ./run_awr_trend.sh
  <connect> "2026-11-08 15:00" 1 8 10 0 1 h` (a heavy blocking hour
  against eight quiet hourly windows; the marker leaves 4 prior windows
  after it), once more with `DESIGN=dashboard`. Check: rc 0, 29/29
  `AWR-SECTION` BEGIN/END pairs, `ORA-` only in captured SQL text,
  `demo/verify_report.js` OK on both (one at a time); on a card with a
  byte unit (`MB/s`) the robust range is scaled like the server's; the
  "since Test release" range is consistent with section 28's split at the
  same marker (its "after" side adds Current, so the numbers differ, but
  the direction agrees).
