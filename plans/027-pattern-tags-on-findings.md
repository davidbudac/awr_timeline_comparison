# Plan 027: Finding cards say what shape the change has (spike, step, trend, after a release)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/lib/src/js_wingrid.js sql/lib/js_wingrid.plsql sql/_style.sql sql/07_summary.sql sql/lib/src/js_design.js sql/lib/js_design.plsql sql/lib/src/css_design.css sql/lib/css_design.plsql tools/check.sh demo/verify_report.js`
> `sql/07_summary.sql` is read, not edited; plans 020 / 025 / 028 / 031
> also touch some of these files. If any of them changed since this plan
> was written, compare the "Current state" excerpts against the live code
> before proceeding; on a mismatch in a block this plan edits, treat it as
> a STOP condition. Extra functions added by plan 028 or 031 to
> `js_wingrid.js` (`avg`, `sdev`, `median`, `esc`, `winIdx`,
> `W.baseline`, `W.rowScale` ...) are expected — reuse them, never add a
> second copy.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (client-side hint text only; no number, severity, order or count changes)
- **Depends on**: plans/025 (soft: it creates the `span.fc-tags` / `span.tri-tags` containers; without it this plan creates its own container in the card header)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: still valid. `js_wingrid.js`,
  `07_summary.sql` and `tools/check.sh` are unchanged; `_style.sql` lines
  moved (+7). New since the first draft: the report designs (`design` =
  classic / quiet / dashboard, `sql/lib/src/js_design.js` +
  `css_design.css`) and the visualization sections 20-28. Edits: the card
  selector excludes `.chg` (the dashboard moves plan / config cards INTO
  `#findings`), a new step 6b shows the tags on the dashboard's findings
  rows, the demo is three files, verify_report runs on classic and
  dashboard, the DB-run pins and the section-pair count (29) are refreshed.
  Section 25 (Onset) overlaps in spirit only; see "Maintenance notes".

## Why this matters

Every finding card compares the Current window with the 12 prior windows,
but the reader must study the 13 bars to tell a one-window spike from a
level that stepped up at a release weeks ago, or from a slow drift. That
difference decides the next action: a step at a release is a regression to
chase in that release, a lone spike may not recur, a trend means "normal"
itself is moving. In the demo report every card's bars show the same
story (a step at Release 4.1, then a jump after Release 4.2), and nothing
on the page says so in words. This plan adds up to two short tags per card
("jump after Release 4.2", "step up at Release 4.1") computed in the
browser from data the card already carries. Tags are hints: they never
change a severity, the card order, a count or a number.

Target (card header, and the triage row of plan 025 when it exists):

```
 ● Large   [jump after Release 4.2] [step up at Release 4.1]        band ●
 Physical reads 5.4x normal
```

The mockup `plans/assets/ux-mockup-2026-11-17.html` (outline number 8)
shows the direction; the report's own look (`sql/_style.sql`) wins.

## Current state

How the report is built (the parts this plan touches):

- The report is one HTML file printed by SQL\*Plus. Client JavaScript for
  the window component lives in the readable source
  `sql/lib/src/js_wingrid.js`; `tools/js2plsql.sh js_wingrid` turns it into
  the PUT_LINE body of `sql/lib/js_wingrid.plsql`, which the driver
  includes once. **Edit the `.js`, never the `.plsql` body**; lint check 24
  fails when the `.plsql` is stale.
- The demo report `docs/examples/demo_busy_db.html` is rendered without a
  database by `python3 demo/gen_demo_report.py`; it lifts
  `sql/lib/js_wingrid.plsql` and `sql/_style.sql` verbatim
  (`demo/awrdemo/chrome.py`), so this plan needs **no hand-port** in the
  demo twins — only a regeneration, committed with the change
  (`./tools/check.sh` fails on a stale demo).

Finding cards are emitted by `sql/07_summary.sql` `emit_card`
(lines 334-458). The markup this plan reads (lines 420-440):

```sql
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h">'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span></div>'
            ...
        DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
            || wg_bars(r.wv, v_s, r.prior_mean, r.prior_sd, v_sev) || wg_dates(TRUE) || '</div></div>');
```

Rendered in the demo (card id `f-io`):

```html
<article class="panel fc f-large lead" id="f-io" ...><header class="fc-h"><div class="fc-k"><span class="sv" title="Physical I/O"><i class="dotk large" aria-hidden="true"></i>Large</span></div>...
<div class="r bars" data-v="3837.399,3767.106,3890.696,3773.923,3866.55,3526.601,3687.419,3767.599,4850.898,5072.253,4809.715,4868.913,22240.52" data-mu="4143.256" data-sd="570.1279" data-sev="large" role="row">
```

- `data-v` = one value per compared window, **oldest first, Current last**,
  empty token = no value (a skipped window). `data-mu` / `data-sd` = the
  prior mean / sample standard deviation in the same unit (the scoring
  inputs). All cards live under `section#findings` (`<div class="cards
  vw in-s">`, line 941). Plan-change and configuration cards (sections 18
  and 12) are `article.fc.chg` in `#changes-slot`; they get no tags. In
  the classic design they are outside `#findings`, but the **dashboard
  design moves `#s-changes` (and so those cards) into `#findings`** (see
  "Report designs" below), so every selector in this plan is
  `#findings article.fc:not(.chg)` — the same selector
  `demo/verify_report.js` section 6 uses since the designs landed.
- Plan 028 (if it landed first) copies the original `data-mu` / `data-sd`
  into `data-mu0` / `data-sd0` and may overwrite `data-mu` / `data-sd` when
  the reader picks another baseline. Read `data-mu0` when present.
- `window.AWR_WIN` (emitted by `sql/00_params.sql`) lists the windows
  oldest first: `{"o":12,"d":"18 Jun","l":"-12w","s":"2026-06-18 09:00",
  "e":"2026-06-18 10:00","t":"...","v":"Y"}`; `o` = week offset (0 =
  Current), `v` = `"N"` for a skipped window.
- Release markers: `sql/lib/src/js_wingrid.js:17-32` maps them onto window
  boundaries:

```js
W.markers=function(){
  if(MK)return MK;MK=[];
  var win=window.AWR_WIN,ms=window.AWR_MARKERS||[];if(!win||!win.w||win.w.length<2)return MK;
  var w=win.w,n=w.length;
  ms.forEach(function(m){
    var t=String(m.t||""),lab=String(m.label||"");if(!t||t<=w[0].s||t>w[n-1].e)return;
    var i=1;while(i<n-1&&t>w[i].s)i++;
    MK.push({o:w[i].o,after:w[i-1].o,l:lab,s:shortLbl(lab),t:dayTxt(t),at:t});
  });
  return MK;
};
```

  A marker's `o` is the column whose LEFT edge it sits on. Demo markers
  (`AWR_MARKERS.push({t:"2026-09-08 22:00",label:"Release 4.2"})` etc.)
  land on columns 2 (Release 4.0), 3 (Hotfix 4.0.1), 5 (RU 19.28 patch),
  8 (Release 4.1) and 12 (Release 4.2 = the Current window), counting
  column indices oldest first from 0.
- Helpers already in `js_wingrid.js` (lines 4-9): `$$(sel, root)`,
  `mk(tag, cls, parent)`, `num(s)`, `nums(csv)`. The boot line (137):

```js
doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);setTimeout(refit,300);});
```

- Card header CSS, `sql/_style.sql:1310-1313`:

```sql
    DBMS_OUTPUT.PUT_LINE('.fc-h{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px 24px;align-items:start}');
    DBMS_OUTPUT.PUT_LINE('.fc-k{display:flex;align-items:center;gap:8px 16px;flex-wrap:wrap;font-size:13px;color:var(--muted);padding-top:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc-k .sv{display:inline-flex;align-items:center;gap:8px;color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.fc-k .gk{font-style:normal;color:var(--ink)}');
```

- Plan 025 (if landed) adds `span.fc-tags` (empty) to each card header and
  a triage list `div#triage` with one `div.tri-row[data-card="<card id>"]`
  per card, each holding an empty `span.tri-tags`. This plan fills them.
  Check with `grep -n "fc-tags\|tri-tags" sql/07_summary.sql`.

Report designs (landed after this plan was first written; read
`CLAUDE.md` "### Report designs"):

- The `design` substitution variable picks `classic` (default,
  byte-identical to before), `quiet` or `dashboard`. Quiet / dashboard add
  a stylesheet (`sql/lib/src/css_design.css` → generated
  `sql/lib/css_design.plsql`) and a script (`sql/lib/src/js_design.js` →
  generated `sql/lib/js_design.plsql`), both generated by
  `tools/js2plsql.sh` exactly like `js_wingrid`. **Design rules never go
  in `sql/_style.sql`**, and the classic report must not change because of
  a design rule.
- `js_design.js` runs from the page's LAST `DOMContentLoaded` handler, so
  after `js_wingrid`'s boot line (and so after `tagCards()`). In the
  dashboard it builds a findings table in `#findings`: function
  `findTable()` makes one `details.drow.lead` row per finding card and
  MOVES the card into that row's body, so the card (and its tags) is
  visible only when the row is open. The row's summary is a grid
  (`.dch .dsev .dnm .dcur .dnr .dbd .ddl .dtr`); `.dnm` holds
  `<b>name</b><small>family</small>`. The relevant lines today:

```js
  cards.forEach(function(card){
    var fam=famOf(card),det=detailOf(card),sev=sevOf(card),lead=$("h3 a.ent",card);
    ...
    tbl.appendChild(drow({lead:true,key:card.id,sev:sev,name:lead?txt(lead):fam,fam:fam,cur:(txt($(".big .v",card))+(/^[\/%]/.test(unit)?"":" ")+unit).trim(),nrm:nrm,
      band:cl(det&&$("td.c-band .bd",det))||cl($(".fc-band .bd",card)),delta:cl(det&&$("td.c-d .d",det))||cl($("h3 .d",card)),data:rowData(tl||$(".wg .r.bars",card)),body:card}));
    moved++;
```

  (`$(sel, root)` is `root.querySelector(sel)`; `drow()` returns the
  `details` element it built.) `famOf(card)` falls back to the text of
  `.fc-k` when the card has no rail sub-link; the rail sub-links always
  exist today, so tags inside `.fc-k` do not leak into it.
- The quiet / dashboard stylesheet restyles the card header's severity
  pill (`sql/lib/src/css_design.css`, section "9. finding / change
  cards"):

```css
.fc-k .sv{font-weight:500;font-size:12px;height:22px;padding:0 8px;border-radius:6px;border:1px solid var(--hairline);color:var(--ink)}
```

- `python3 demo/gen_demo_report.py` now writes THREE pages:
  `docs/examples/demo_busy_db.html` (classic),
  `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html`; `--check`
  covers all three. `demo/verify_report.js` reads `window.AWR_DESIGN` and
  has blocks 1-6, 5b, 7 (designs) and 8 (visualization sections 20-28).

Repo rules that apply here (each has broken the report before):

- **Never type a tilde** in `sql/lib/src/*.js` or `sql/_style.sql`, not even
  in a comment (`SET DEFINE` makes it a substitution character;
  `tools/js2plsql.sh` and `./lint.sh` reject it). CSS sibling combinator
  included.
- **Emitted text must be pure ASCII** (lint check 25): a non-ASCII byte
  becomes `?` on a non-UTF-8 SQL\*Plus client. This plan's strings are plain
  ASCII by design (use `...`, `x`, `+/-` in prose). Do NOT type `\u` escape
  sequences into your tool input: some agent tools turn them into the
  literal character. If you need one, write that line from a script and
  check the bytes.
- A source line of `js_wingrid.js` must stay under 2300 characters
  (`js2plsql.sh` rejects longer ones).
- In `sql/_style.sql`, every rule is a PUT_LINE string literal: a single
  quote inside is written `''` (this plan needs none). `_style.sql` is also
  included by the fleet report, so new selectors must be scoped to
  single-DB classes (`.fc`, `#triage`) — they are below.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate the client script | `tools/js2plsql.sh js_wingrid` | `sql/lib/js_wingrid.plsql regenerated` |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0, no output |
| JS unit tests | `node tools/js_unit_tests.js` | last line `N tests passed`, exit 0 |
| ASCII check | `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/_style.sql tools/js_unit_tests.js` | `0` for each file |
| Regenerate the design script / stylesheet | `tools/js2plsql.sh js_design` and `tools/js2plsql.sh css_design` | `... regenerated` |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote .../docs/examples/demo_busy_db*.html (... KB)` lines (classic, quiet, dashboard) |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | three `up to date: ...` lines |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d) && (cd $T && npm i playwright@1.55 >/dev/null) && NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html` then the same with `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` for each (about 3 min each; run them one after the other, never two at once) |

There is no database available to you; the owner's checks are listed under
"Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/lib/src/js_wingrid.js` (pure function, its text, the DOM glue)
- `sql/lib/js_wingrid.plsql` (regenerated by `tools/js2plsql.sh` only; also
  extend its header comment's "Exposes window.AWR_WG" list by hand — the
  header above `BEGIN` is kept by the generator)
- `sql/_style.sql` (tag styles)
- `tools/js_unit_tests.js` (create, or extend if plan 028 / 031 created it)
- `tools/check.sh` (one new step, only if not already added by 028 / 031)
- `sql/lib/src/js_design.js`, `sql/lib/js_design.plsql` (regenerated):
  step 6b only (the dashboard's lead rows show the tags)
- `sql/lib/src/css_design.css`, `sql/lib/css_design.plsql` (regenerated):
  step 6b only (two rules)
- `demo/verify_report.js` (one new check)
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated, never hand-edited)
- `CLAUDE.md` (one paragraph), `CHANGELOG.md` (one bullet)

**Out of scope** (do NOT touch):
- `sql/07_summary.sql`, `sql/00_params.sql`, `sql/lib/finding_cards.plsql`
  — no server-side change is needed; the containers belong to plan 025.
- The visualization sections 20-28 (`sql/2[0-8]_*.sql`, their `js_*` /
  `css_*` files). In particular section 25 (Onset) is NOT a data source for
  the tags (see "Maintenance notes").
- Scoring (`sql/lib/metric_policy.plsql`, `policy_bucket`), card order,
  counts, the verdict: tags must never feed any of them.
- Timeline rows (`#tl`): tagging them is a possible follow-up, not this plan.
- `sql/lib/src/js_timeline.js`, `js_microstrip.js` and every fleet file
  (`sql/fleet/*`, `awr_fleet_extract.sql`, `run_awr_fleet.sh`).
- Demo twins under `demo/awrdemo/` — nothing to port (client-only change).

## Git workflow

- Branch: `advisor/027-pattern-tags` from `main`, which must contain
  `5594f2c` (`git merge-base --is-ancestor 5594f2c HEAD` exits 0; if not,
  STOP: the checkout predates the designs and sections 20-28).
- One commit for the code + regenerated demo, e.g.
  `feat(report): pattern tags on finding cards (spike, step, trend, after a release)`;
  docs may ride in the same commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the pure pattern function to `js_wingrid.js`

Insert right after line 32 (`W.markerAt=...`) — reuse `avg` / `sdev` if
plan 028 already added them:

```js
/* ---- pattern tags (plan 027): the shape of one row's 13 values, as a
   hint.  Pure: vals oldest first (null = no value), valid[i] false = a
   skipped window, mu / sd = the row's prior mean / sd (data-mu / data-sd),
   marks = [{i: column index whose LEFT edge carries a marker, l: label}].
   At most two tags, the Current one first:
     {k:"jump"|"spike", dir, m}  only Current is outside mean +- 2 floored
         sigma ("jump" when a marker sits on Current's left edge, m = label)
     {k:"run", dir, n}  Current and the n-1 windows right before it are all
         outside on the same side (a skipped window ends the run)
     {k:"step", dir, at, m}  the prior windows from index at on sit apart
         from the ones before (m = the marker on that edge, else null)
     {k:"trend", dir, n}  the n prior windows follow a line better than a step
   dir = 1 up, -1 down.  Thresholds in W.PAT.  Tags never change a
   severity, an order or a count. */
W.PAT={MIN_PRIOR:4,STEP_L:3,STEP_R:2,STEP_PAIR:0.9,STEP_REL:0.10,STEP_SEP:2,TREND_MIN:6,TREND_R2:0.6,TREND_REL:0.10};
function avg(a){var s=0;for(var i=0;i<a.length;i++)s+=a[i];return s/a.length;}
function sdev(a){if(a.length<2)return 0;var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return Math.sqrt(s/(a.length-1));}
function sqs(a){var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return s;}
W.patterns=function(vals,valid,mu,sd,marks){
  var P=W.PAT,n=vals.length,c=vals[n-1],out=[],pi=[],i;
  if(c==null||mu==null||n<2)return out;
  for(i=0;i<n-1;i++)if(vals[i]!=null&&valid[i]!==false)pi.push(i);
  if(pi.length<P.MIN_PRIOR)return out;
  var mkAt=function(x){for(var k=0;k<(marks||[]).length;k++)if(marks[k].i===x)return marks[k].l;return null;};
  var den=Math.max(sd||0,0.02*Math.abs(mu)),hi=mu+2*den,lo=mu-2*den,dir=c>hi?1:c<lo?-1:0;
  if(dir){
    var run=0;
    for(i=n-2;i>=0;i--){var v=vals[i];if(v==null||valid[i]===false)break;if((dir>0&&v>hi)||(dir<0&&v<lo))run++;else break;}
    if(run>=1)out.push({k:"run",dir:dir,n:run+1});
    else{var lm=mkAt(n-1);out.push({k:lm?"jump":"spike",dir:dir,m:lm});}
  }
  var best=null,s;
  for(s=1;s<n-1;s++){
    var L=[],R=[];pi.forEach(function(x){(x<s?L:R).push(vals[x]);});
    if(L.length<P.STEP_L||R.length<P.STEP_R)continue;
    var mL=avg(L),mR=avg(R);if(mL===0)continue;
    var d=mR>mL?1:-1,pairs=0;
    R.forEach(function(r){L.forEach(function(l){if(d>0?r>l:r<l)pairs++;});});
    var gap=Math.abs(mR-mL),fl=Math.max(sdev(L),sdev(R),0.02*Math.abs(mL)),sc=gap/fl;
    if(pairs/(L.length*R.length)<P.STEP_PAIR||gap/Math.abs(mL)<P.STEP_REL||gap<=P.STEP_SEP*fl)continue;
    if(!best||sc>best.sc||(sc===best.sc&&s>best.at))best={dir:d,at:s,m:mkAt(s),sc:sc,rss:sqs(L)+sqs(R)};
  }
  var tr=null;
  if(pi.length>=P.TREND_MIN){
    var ys=pi.map(function(x){return vals[x];}),mx=avg(pi),my=avg(ys),sxx=0,sxy=0,syy=0;
    pi.forEach(function(x,k){sxx+=(x-mx)*(x-mx);sxy+=(x-mx)*(ys[k]-my);syy+=(ys[k]-my)*(ys[k]-my);});
    if(sxx>0&&syy>0&&my!==0){
      var b=sxy/sxx,r2=sxy*sxy/(sxx*syy),rss=syy-sxy*sxy/sxx,rise=Math.abs(b*(pi[pi.length-1]-pi[0]));
      if(r2>=P.TREND_R2&&rise>=P.TREND_REL*Math.abs(my))tr={dir:b>0?1:-1,n:pi.length,rss:rss};
    }
  }
  if(tr&&(!best||tr.rss<=best.rss))out.push({k:"trend",dir:tr.dir,n:tr.n});
  else if(best)out.push({k:"step",dir:best.dir,at:best.at,m:best.m});
  return out;
};
```

The rules in words (they go into `CLAUDE.md` in step 6): nothing is tagged
with fewer than 4 valid prior windows or no Current value; Current outside
the band (prior mean +/- 2 x sigma, sigma floored at 2 % of the mean — the
band the page already draws) is "new" when the window just before it is
inside the band, else a run; a step needs at least 3 valid windows before
and 2 after the split, at least 90 % of the after/before pairs on the same
side, a mean shift of at least 10 % and more than 2 x the larger side's
floored sigma; a trend needs at least 6 valid windows, R squared >= 0.6, a
total rise of at least 10 % of the mean, and wins over a step only when a
straight line fits at least as well (smaller or equal residual sum of
squares).

**Verify**: `tools/js2plsql.sh js_wingrid` → `sql/lib/js_wingrid.plsql regenerated`;
`./lint.sh` → clean.

### Step 2: Add the tag text

Right after `W.patterns`:

```js
/* a tag's words: text (on the chip) and title (the hover) */
W.patternText=function(t,dates){
  var up=t.dir>0,dt=function(i){return (dates&&dates[i])||"?";},lab=function(l){l=String(l);return l.length>24?l.slice(0,23)+"...":l;};
  if(t.k==="jump")return {text:(up?"jump":"drop")+" after "+lab(t.m),title:"Only the Current window is outside the normal range of the prior windows; the marker "+t.m+" sits right before it."};
  if(t.k==="spike")return {text:(up?"spike":"dip")+": Current only",title:"Only the Current window is outside the normal range of the prior windows."};
  if(t.k==="run")return {text:(up?"high":"low")+" for "+t.n+" windows",title:"The Current window and the "+(t.n-1)+" before it are all "+(up?"above":"below")+" the normal range."};
  if(t.k==="step")return {text:"step "+(up?"up":"down")+(t.m?" at "+lab(t.m):" on "+dt(t.at)),title:"The prior windows from "+dt(t.at)+" on sit "+(up?"above":"below")+" the ones before"+(t.m?" (marker "+t.m+")":"")+": the normal range mixes two levels."};
  return {text:(up?"rising":"falling")+" across "+t.n+" windows",title:"The prior windows follow a steady "+(up?"rise":"fall")+": the normal range is a moving target."};
};
```

**Verify**: `tools/js2plsql.sh js_wingrid` → regenerated; `./lint.sh` → clean;
`grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js` → `0`.

### Step 3: Unit tests (`tools/js_unit_tests.js`)

If `tools/js_unit_tests.js` does not exist yet, create it with this
harness (plans 028 / 031 use the same one; if one of them created it,
only append the tests below before the final `console.log`):

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
function mean(a) { return a.reduce((s, v) => s + v, 0) / a.length; }
function sd(a) { const m = mean(a); return Math.sqrt(a.reduce((s, v) => s + (v - m) * (v - m), 0) / (a.length - 1)); }

/* ---- tests go here ---- */

console.log(passed + ' tests passed');
```

Then add (between the markers) the pattern tests. `tags()` builds the
row inputs the way the page does (mean / sd of the valid prior values) and
returns a compact string so each case is one line:

```js
/* ---- plan 027: W.patterns / W.patternText (js_wingrid) ---- */
{
  const W = load('js_wingrid').AWR_WG;
  const MARKS = [{ i: 2, l: 'Release 4.0' }, { i: 3, l: 'Hotfix 4.0.1' }, { i: 5, l: 'RU 19.28 patch' },
                 { i: 8, l: 'Release 4.1' }, { i: 12, l: 'Release 4.2' }];
  const ALL = new Array(13).fill(true);
  function tags(vals, valid, marks) {
    const p = vals.slice(0, -1).filter((v, i) => v != null && valid[i] !== false);
    return W.patterns(vals, valid, mean(p), sd(p), marks).map(t => t.k + (t.dir > 0 ? '+' : '-')
      + (t.at != null ? '@' + t.at : '') + (t.n != null ? '#' + t.n : '') + (t.m ? '[' + t.m + ']' : '')).join(' ');
  }
  const PR = [3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
              4850.898, 5072.253, 4809.715, 4868.913, 22240.52];
  test('demo physical reads: jump after 4.2, step at 4.1', () =>
    assert.strictEqual(tags(PR, ALL, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  test('no markers: spike + step', () => assert.strictEqual(tags(PR, ALL, []), 'spike+ step+@8'));
  const SK = PR.slice(); SK[3] = null; SK[9] = null;
  const SKV = ALL.slice(); SKV[3] = false; SKV[9] = false;
  test('skipped windows are unknown, not absent', () =>
    assert.strictEqual(tags(SK, SKV, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  test('flat: nothing', () => assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 100], ALL, []), ''));
  test('noisy flat: nothing', () => assert.strictEqual(tags([100, 90, 110, 95, 105, 100, 92, 108, 97, 103, 99, 101, 104], ALL, []), ''));
  test('linear rise: trend, not step', () =>
    assert.strictEqual(tags([100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210, 300], ALL, []), 'spike+ trend+#12'));
  test('falling trend, Current inside band', () =>
    assert.strictEqual(tags([300, 290, 280, 270, 260, 250, 240, 230, 220, 210, 200, 190, 185], ALL, []), 'trend-#12'));
  test('run of 2 + step', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 150, 160, 170], ALL, []), 'run+#2 step+@10'));
  test('drop + step down', () =>
    assert.strictEqual(tags([200, 205, 198, 202, 201, 199, 203, 200, 150, 148, 152, 149, 100], ALL, []), 'spike- step-@8'));
  test('just below the floored band: dip', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 96], ALL, []), 'spike-'));
  test('fewer than 4 valid priors: nothing', () =>
    assert.strictEqual(tags([null, null, null, null, null, null, null, null, null, 3, 4, 5, 9], ALL, []), ''));
  test('no Current value: nothing', () => assert.strictEqual(tags([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, null], ALL, []), ''));
  test('text', () => {
    const D = ['18 Jun', '25 Jun', '2 Jul', '9 Jul', '16 Jul', '23 Jul', '30 Jul', '6 Aug', '13 Aug', '20 Aug', '27 Aug', '3 Sep', '10 Sep'];
    assert.strictEqual(W.patternText({ k: 'jump', dir: 1, m: 'Release 4.2' }, D).text, 'jump after Release 4.2');
    assert.strictEqual(W.patternText({ k: 'step', dir: 1, at: 8, m: 'Release 4.1' }, D).text, 'step up at Release 4.1');
    assert.strictEqual(W.patternText({ k: 'step', dir: -1, at: 8, m: null }, D).text, 'step down on 13 Aug');
    assert.strictEqual(W.patternText({ k: 'spike', dir: -1, m: null }, D).text, 'dip: Current only');
    assert.strictEqual(W.patternText({ k: 'run', dir: 1, n: 3 }, D).text, 'high for 3 windows');
    assert.strictEqual(W.patternText({ k: 'trend', dir: -1, n: 12 }, D).text, 'falling across 12 windows');
    assert.strictEqual(W.patternText({ k: 'jump', dir: 1, m: 'A very long release name indeed' }, D).text, 'jump after A very long release nam...');
  });
}
```

These expectations were computed against a prototype of exactly the
function in step 1; if one fails, the function was mistyped (re-read
step 1) — do not change an expectation to make it pass.

**Verify**: `node tools/js_unit_tests.js` → 13 `ok - ...` lines for this
plan, last line `N tests passed`, exit 0.

### Step 4: Run the tests from `tools/check.sh`

If `tools/check.sh` has no "client JS unit tests" step yet (028 / 031 may
have added it), add this block right before the
`step "generated docs are fresh (demo report, policy page)"` line:

```sh
step "client JS unit tests (node)"
if command -v node >/dev/null 2>&1; then
    node tools/js_unit_tests.js || fail=1
else
    echo "node not found: skipped"
fi
```

Also add `#   6. client JS unit tests        tools/js_unit_tests.js (skipped without node)`
to the header comment's numbered list.

**Verify**: `./tools/check.sh` → contains `== client JS unit tests (node)`
and ends `check.sh: all checks passed`. (The demo freshness step may fail
until step 6 regenerates the demo; that is expected at this point — if it
is the ONLY failure, continue.)

### Step 5: Put the tags on the page

In `js_wingrid.js`, add after `W.patternText` (reuse `esc` / `winIdx` if
plan 028 or 031 already added them):

```js
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}
/* the compared windows as column indices: validity, dates, marker columns */
function winIdx(){
  var w=(window.AWR_WIN&&window.AWR_WIN.w)||[],valid=[],dates=[],ix={};
  w.forEach(function(x,i){valid.push(x.v!=="N");dates.push(x.d);ix[x.o]=i;});
  var marks=W.markers().map(function(m){return {i:ix[m.o],l:m.l};}).filter(function(m){return m.i!=null;});
  return {valid:valid,dates:dates,marks:marks};
}
/* every finding card (07) gets its tags in its header; plan 025's triage
   row for the card gets the same chips */
function tagCards(){
  var X=winIdx();if(!X.valid.length)return;
  $$("#findings article.fc:not(.chg)").forEach(function(card){
    var row=card.querySelector(".fc-main .wg .r[data-v]");if(!row)return;
    var vals=nums(row.getAttribute("data-v"));if(vals.length!==X.valid.length)return;
    var a=function(n){var v=row.getAttribute(n+"0");return num(v!=null?v:row.getAttribute(n));};
    var tags=W.patterns(vals,X.valid,a("data-mu"),a("data-sd"),X.marks);if(!tags.length)return;
    var html=tags.map(function(t){var p=W.patternText(t,X.dates);
      return '<span class="ptag p-'+t.k+(t.m?' p-rel':'')+'" title="'+esc(p.title)+'">'+esc(p.text)+'</span>';}).join("");
    var box=card.querySelector(".fc-tags");
    if(!box){var k=card.querySelector(".fc-h .fc-k");if(!k)return;box=mk("span","fc-tags",k);}
    box.innerHTML=html;
    $$('#triage .tri-row[data-card="'+card.id+'"] .tri-tags').forEach(function(t){t.innerHTML=html;});
  });
}
```

Notes: the `"\""` key above is a double quote inside a double-quoted JS
string, so the `.js` file contains a backslash followed by a double quote
— that is ASCII and fine. `js2plsql.sh` doubles single quotes on its own.
The `.r[data-v]` selector (not `.r.bars`) is deliberate: on the DB time
card `js_timeline` later turns the bars row into a stacked `.r.ash` row,
and the tags must not depend on the order the two scripts run in. The
`:not(.chg)` is deliberate too: the dashboard design moves the plan /
config cards (`article.fc.chg`, which also carry a `.fc-main .wg .r` row)
into `#findings`, and they must not get tags.

Change the boot line (137) to call it after the render:

```js
doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);tagCards();setTimeout(refit,300);});
```

(If plan 028 already added `cardSwitch();`, keep it and put `tagCards();`
before it.)

Extend the header comment of `sql/lib/js_wingrid.plsql` (above `BEGIN`;
the generator keeps it) with:

```
--   patterns(vals, valid, mu, sd, marks)   pattern tags of one row (pure;
--                 plan 027), patternText(tag, dates) their words, PAT the
--                 thresholds; tagCards() fills the finding cards' .fc-tags
--                 (and #triage .tri-tags) on DOMContentLoaded
```

**Verify**: `tools/js2plsql.sh js_wingrid` → regenerated;
`tools/js2plsql.sh --check` → exit 0; `./lint.sh` → clean;
`node tools/js_unit_tests.js` → all pass.

### Step 6: Style the chips, regenerate the demo, document

In `sql/_style.sql`, right after line 1313 (`.fc-k .gk{...}`), add:

```sql
    -- plan 027: pattern tags (js_wingrid tagCards) in the card header and
    -- the triage rows (#triage, plan 025); a hint, never a severity colour
    DBMS_OUTPUT.PUT_LINE('.fc-tags{display:inline-flex;flex-wrap:wrap;gap:4px}');
    DBMS_OUTPUT.PUT_LINE('.fc .ptag,#triage .ptag{display:inline-block;font-size:11.5px;font-weight:400;line-height:18px;padding:0 8px;border:1px solid var(--line-2);border-radius:9px;color:var(--ink-2);background:var(--panel);white-space:nowrap;cursor:help}');
    DBMS_OUTPUT.PUT_LINE('.fc .ptag.p-rel,#triage .ptag.p-rel{border-color:var(--acc);color:var(--acc-ink)}');
```

Do step 6b now (it changes the design files the demo lifts), then
regenerate the demo: `python3 demo/gen_demo_report.py`, then run it a
second time and compare: `md5sum docs/examples/demo_busy_db*.html` must
print the same three sums after both runs.

`CLAUDE.md`: in the section "### Window component (`sql/lib/wingrid.plsql`
+ `js_wingrid.plsql`)" add one paragraph "**Pattern tags (plan 027).**"
stating: `AWR_WG.patterns` / `patternText` / `PAT` (pure, unit-tested in
`tools/js_unit_tests.js`), the rules from step 1 in words, that
`tagCards()` fills `.fc-tags` in every `#findings article.fc:not(.chg)`
header (and `#triage .tri-tags`) from the card's `data-v` /
`data-mu0`-or-`data-mu` / `data-sd`, that markers come from
`AWR_WG.markers()`, and that tags never change a severity, the order or a
count. In "### Report designs", in the dashboard bullet, add one sentence:
the lead row of each card shows a copy of the card's `.fc-tags` in its
`.dnm` cell (plan 027). In "## Verification & testing", add
`tools/js_unit_tests.js` to the description of `./tools/check.sh` if step 4
added the step.

`CHANGELOG.md`, under `## Unreleased` → `### Report`, add:
`- **Finding cards name the shape of the change.** Up to two tags per card
("jump after Release 4.2", "step up at Release 4.1", "spike: Current
only", "high for 3 windows", "rising across 12 windows"), computed in the
browser from the card's 13 values and the release markers. A hint only:
severities, order and counts are unchanged.`

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`;
`grep -c "ptag p-" sql/lib/js_wingrid.plsql` → 1 or more.

### Step 6b: The quiet / dashboard designs

In the dashboard a card sits inside a closed findings row, so its tags
would be hidden until the row opens. Show a copy in the row's name cell.

1. In `sql/lib/src/js_design.js`, function `findTable()`, replace the
   lead-row statement quoted under "Current state"
   (`tbl.appendChild(drow({lead:true, ... body:card}));`) by the same
   `drow({...})` call kept in a variable, then the copy:

   ```js
    var lrow=drow({lead:true,key:card.id,sev:sev,name:lead?txt(lead):fam,fam:fam,cur:(txt($(".big .v",card))+(/^[\/%]/.test(unit)?"":" ")+unit).trim(),nrm:nrm,
      band:cl(det&&$("td.c-band .bd",det))||cl($(".fc-band .bd",card)),delta:cl(det&&$("td.c-d .d",det))||cl($("h3 .d",card)),data:rowData(tl||$(".wg .r.bars",card)),body:card});
    tbl.appendChild(lrow);
    /* plan 027: the card's pattern tags (js_wingrid tagCards ran before) on the row */
    var ptg=$(".fc-tags",card);if(ptg&&ptg.children.length){var pcl=ptg.cloneNode(true);pcl.className="fc-tags dtags";$(".dnm",lrow).appendChild(pcl);}
   ```

   The `drow({...})` arguments must stay byte-identical to the existing
   call; only the `tbl.appendChild(` wrapper becomes `var lrow=` and the
   two new lines follow. The copy is appended AFTER `<small>`, never inside
   `<b>` / `<small>` (the "Jump to" palette reads those two).

2. In `sql/lib/src/css_design.css`, section "9. finding / change cards",
   right after the `.fc-k .sv > .dotk,.fc-k .sv > i{display:none}` line,
   add (the chips match the design's severity pill):

   ```css
   .fc .ptag,#triage .ptag{border-color:var(--hairline);border-radius:6px;background:none}
   .drow .dnm .dtags{display:flex;flex-wrap:wrap;gap:4px;margin-top:3px}
   .drow .dtags .ptag{display:inline-block;font-size:11px;line-height:16px;padding:0 6px;border:1px solid var(--hairline);border-radius:6px;color:var(--ink-2);white-space:nowrap;cursor:help}
   .drow .dtags .ptag.p-rel{border-color:var(--acc);color:var(--acc-ink)}
   ```

   (The `.fc .ptag` rule of step 6 does not reach the row copy, which is
   outside `.fc`; the third line gives it the whole chip style.)

3. Regenerate: `tools/js2plsql.sh js_design` and
   `tools/js2plsql.sh css_design`.

**Verify**: both print `... regenerated`; `tools/js2plsql.sh --check` →
exit 0; `grep -c "dtags" sql/lib/js_design.plsql sql/lib/css_design.plsql`
→ 1 or more each; `grep -cP '[^\x00-\x7F]' sql/lib/src/js_design.js
sql/lib/src/css_design.css` → `0` twice; `./lint.sh` → clean.

### Step 7: Browser check (`demo/verify_report.js`)

In section 6 (`// ---- 6. phase 4 (v1.6.0)`), inside the
`page.evaluate(async () => { ... })` that fills `out`, add before
`window.AWR_setView('all', false);`:

```js
      // plan 027: pattern tags on the finding cards (and the triage rows)
      const fcs = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      out.tagCards = fcs.length;
      out.tagNoTitle = [...document.querySelectorAll('#findings .ptag')].filter(t => !t.title || !t.textContent).length;
      out.tagChg = document.querySelectorAll('article.fc.chg .ptag').length;
      out.tagIo = [...document.querySelectorAll('#f-io .fc-tags .ptag')].map(t => t.textContent).join('|');
      out.tagTri = [...document.querySelectorAll('#triage .tri-row[data-card]')].filter(r => {
        const c = document.getElementById(r.getAttribute('data-card'));
        const a = c ? [...c.querySelectorAll('.fc-tags .ptag')].map(t => t.textContent).join('|') : '';
        const b = [...r.querySelectorAll('.tri-tags .ptag')].map(t => t.textContent).join('|');
        return a !== b;
      }).map(r => r.getAttribute('data-card'));
      // dashboard design: each lead row shows its card's tags (step 6b)
      out.tagRows = [...document.querySelectorAll('details.drow.lead')].filter(r => {
        const c = r.querySelector('article.fc');
        const a = c ? [...c.querySelectorAll('.fc-tags .ptag')].map(t => t.textContent).join('|') : '';
        const b = [...r.querySelectorAll(':scope > summary .dtags .ptag')].map(t => t.textContent).join('|');
        return a !== b;
      }).map(r => r.id);
```

and after the existing `if (!p4.subsOk) ...` line:

```js
    if (p4.tagNoTitle) fail('pattern tags: ' + p4.tagNoTitle + ' chip(s) without text / title');
    if (p4.tagChg) fail('pattern tags: ' + p4.tagChg + ' chip(s) on a plan / config card');
    if (p4.tagTri.length) fail('pattern tags: triage row differs from its card: ' + p4.tagTri.join(', '));
    if (p4.tagRows.length) fail('pattern tags: dashboard row differs from its card: ' + p4.tagRows.join(', '));
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.tagIo !== 'jump after Release 4.2|step up at Release 4.1')
      fail('pattern tags: the demo Physical I/O card shows "' + p4.tagIo + '"');
```

(Section 6 runs for every design; `details.drow.lead` exists only in the
dashboard, so `tagRows` is empty elsewhere.) Also add one line to the
header comment's checks list: `- pattern tags (plan 027): every chip has
text and a title, none on a plan / config card, a triage row and a
dashboard findings row show their card's chips, the demo Physical I/O card
reads "jump after Release 4.2" + "step up at Release 4.1";`.

(In the demo all four finding cards get the same two tags: the synthetic
model steps up at Release 4.1 and jumps after Release 4.2 everywhere.)

**Verify**: the browser smoke test (Commands table) → `verify: OK`.

## Test plan

- Unit: 13 cases in `tools/js_unit_tests.js` (step 3): the demo series with
  and without markers, skipped windows, flat and noisy-flat (no tags), a
  linear rise (trend wins over step), a falling trend, a run + step, a drop
  + step down, a dip just outside the floored band, too few priors, no
  Current value, and the tag words.
- Browser: `demo/verify_report.js` (step 7) on the regenerated classic and
  dashboard demos, one after the other.
- Manual (optional, 1 minute): open `docs/examples/demo_busy_db.html`,
  Summary view; each finding card shows two chips next to "Large" /
  "Moderate"; hovering a chip shows its sentence; the card order, the
  verdict and the "4 findings" text are unchanged; dark mode (moon button)
  keeps the chips readable. Then `demo_busy_db_dashboard.html`: each
  findings-table lead row shows the chips under its name; a plan-change
  card in "What changed around it" shows none; `demo_busy_db_quiet.html`:
  the chips have the hairline border of the severity pill.

## Done criteria

- [ ] `node tools/js_unit_tests.js` exits 0 and prints the 13 plan-027 cases
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `./tools/check.sh` ends `check.sh: all checks passed`
- [ ] `grep -cP '[^\x00-\x7F]' sql/lib/src/js_wingrid.js sql/_style.sql tools/js_unit_tests.js sql/lib/src/js_design.js sql/lib/src/css_design.css` prints `0` five times
- [ ] `python3 demo/gen_demo_report.py --check` prints three `up to date:` lines
- [ ] the browser smoke test ends `verify: OK` on `demo_busy_db.html` AND on `demo_busy_db_dashboard.html`
- [ ] `git diff --stat` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `W.markers`, `sizeRow` or the boot line in `js_wingrid.js` do not match
  the excerpts (the file drifted beyond the additions named in the drift
  check).
- The lead-row `tbl.appendChild(drow({lead:true, ...}))` statement in
  `js_design.js` `findTable()` is not found as quoted, or `drow()` no
  longer returns the `details` element (step 6b).
- A unit test expectation in step 3 fails after you re-checked step 1
  character by character — the rule may behave differently from the
  prototype; report the failing case and the actual output.
- The demo Physical I/O card does not read
  `jump after Release 4.2|step up at Release 4.1` (the demo model or the
  markers changed).
- Any check needs an edit to `sql/07_summary.sql`, a demo twin under
  `demo/awrdemo/`, or a fleet file.

## Maintenance notes

- The thresholds live in `AWR_WG.PAT`; change them only together with the
  unit-test expectations and the `CLAUDE.md` paragraph. The band used for
  "outside" is the page's own (mean +/- 2 x sigma floored at 2 %, the same
  as `sizeRow` and the band glyph), so a tag never contradicts the chart.
- If plan 028's baseline switch lands later, tags keep reading the
  server's values (`data-mu0` / `data-sd0`), never the reader's choice.
- Follow-ups deliberately left out: tags on Timeline rows (needs a place in
  the 224 px label column), tags in the verdict sentence, a server-side
  (PL/SQL) twin. A twin would be needed only if the fleet report or the
  copy-summary text (plan 034) wants the words without JavaScript.
- **Section 25 (Onset, `#onset`) is related but not a substitute, and not
  a data source.** It follows 7 FIXED metrics (DB time, DB CPU, user calls,
  executions, logical reads, physical reads, redo) through every snapshot
  interval of the span and dates a sustained shift with a CUSUM (its
  sentence names the onset time and the nearest release marker within
  6 h). The
  tags work on any card's metric and on the compared WINDOWS only (one
  value per period), and name the shape (spike / run / step / trend).
  Re-using `AWR_DATA.onset` would cover at most the cards whose lead
  metric is one of those 7, on a different time grid, so this plan keeps
  its own window rule. The two can legitimately differ (onset works inside
  the span's continuous series; a tag compares periods). A later plan may
  add a "dated in Onset" link on a card whose lead metric Onset follows.
- **Needs owner DB run** (the executor has no database): rsync to dbmint
  without `--delete`
  (`rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'`;
  never port 2201, the mounted standby). dbmint keeps only 35 days of
  AWR, so probe first for a restart-free stretch (CLAUDE.md, "dbmint keeps
  35 days of AWR"); on 2026-11-19 that was 2026-11-07 14:45 to 2026-11-09
  16:15, and these runs fit it: `./run_awr_trend.sh <connect> "2026-11-08
  15:00" 1 8 10 0 1 h` (a heavy blocking hour against eight quiet ones),
  once with `MARKERS='2026-11-08 12:30|Test release'` in the environment
  and once with `DESIGN=dashboard`. Check: rc 0, 29/29 `AWR-SECTION` BEGIN/END
  pairs, `ORA-` hits only inside captured SQL text, `demo/verify_report.js`
  OK on each report (one at a time), and that the chips read sensibly (no
  tag on a card with fewer than 4 valid windows; the marker run should
  show a step or jump "at Test release" only if the bars really moved
  there).
