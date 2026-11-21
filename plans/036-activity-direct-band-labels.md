# Plan 036: The Activity charts name their largest bands directly on the chart

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan is written against the code AFTER
> plans 023 and 024, on top of commit `5594f2c`. Confirm all three:
> `git merge-base --is-ancestor 5594f2c HEAD && echo ok` → `ok`;
> `grep -c "function drawWin" sql/lib/src/js_timeline.js` → `1` and
> `grep -c "function bands(" sql/lib/src/js_timeline.js` → `1`. If any
> fails, STOP. Then
> `git diff --stat 5594f2c..HEAD -- sql/lib/src/js_timeline.js sql/_style.sql sql/lib/src/css_design.css sql/lib/src/js_design.js sql/19_reference.sql demo/verify_report.js`
> should show only plans 023 / 024's changes. Locate code by the quoted
> text, not by line number.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/024-activity-windows-side-by-side.md (and 023)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19;
  first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`. Since `ee23e49` the report
  gained three designs (`design` = classic / quiet / dashboard) and sections
  20-28. Changes to this plan:
  - The steps are unchanged in substance. `draw()` now sets `c.flags` /
    `c.xl` from the charts that are SHOWN, which labels do not depend on.
  - Plan 024's API is now `AWR_TL.axLayout`, not `axMode`. The dashboard's
    own `window.AWR_axMode` switches which chart is shown.
  - The quiet / dashboard stylesheet puts Geist on the chart texts; a note
    says why `.xdl` must stay out of that rule.
  - The smoke test's "is this the demo" test now matches all three demo
    pages, and the smoke test runs on classic and dashboard (quiet
    recommended).
  - The DB-run notes were updated (29/29 pairs, fresh dbmint dates).
- **Owner decision**: labels on both charts (recommended; the wait-class
  palette has four close reds / browns — Application, Concurrency,
  Configuration, Network) or on the by-event chart only. It is one option
  per chart (`labels:` in the two `mkChart(...)` calls).

## Why this matters

The "by wait event" Activity chart stacks up to 15 series (the 14 largest
events plus "Other events") in 15 categorical colours, and the legend sits
above the chart in two or three wrapped rows. Matching a band to its legend
entry by colour alone is slow and error-prone (several hues are close, and
colour-blind readers cannot do it at all). Today the reader has to hover the
band to learn its name. This plan writes the series name directly on the
widest part of the largest bands (at most six per chart), in the theme's ink
colour with a halo, never overlapping each other or the plot edges. The
legend stays.

```
 AAS
  20 |           ___________
     |    ______/ db file    \_____        <- label inside its band,
  10 |___/   scattered read        \___       where the band is thickest
     |  CPU                     CPU    |
   0 +---------------------------------+
```

A direction-only picture: outline 17 is not in the mockup; the idea is the
standard "direct labelling" of stacked areas.

## Current state

### Background

- The charts are inline SVG strings built by `sql/lib/src/js_timeline.js`
  (section 6, "Activity, whole span"); `sql/lib/js_timeline.plsql` is
  GENERATED from it by `tools/js2plsql.sh js_timeline` (its comment header
  above `BEGIN` is hand-written and kept).
- After plan 024, drawing is split into shared helpers (find each by name):
  - `hlOrd(c)` → `{hl, on, reb, ord}`: the highlight state and the series
    drawing order (`ord`: bottom of the stack first; when a highlight is
    "strong", `reb` is true and the highlighted series come first, re-based
    from zero).
  - `colPts(c,R,X,d0,d1,reb,on)` → `{pts, mx, mh}`: `pts` = the drawn
    points, each `[x px, ref, stacked total, highlighted total]`, x
    increasing; a "ref" is a bucket (`rV(c,k,ref)` = series k's AAS there).
  - `bands(c,pts,ord,on,Y)` → the band `<path>` strings. Each series k's band
    runs, at point j, from the cumulative total of the series before it in
    `ord` (lower edge) to that total plus `rV(c,k,pts[j][1])` (upper edge);
    `Y(v)` maps AAS to the SVG y pixel (larger v = smaller y).
  - `draw(c,force)` (Full span) and `drawWin(c,o)` (side by side: one
    `pts` per panel in `pan[q].pts`, panel `q` spanning `pan[q].x0` to
    `pan[q].x0+pan[q].w`).
- In `draw`, the bands are added, then the hidden bucket band `rect.xbk`,
  then the window stripes, and the clipped group is closed by the line
  `  s+='</g><line class="ax" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+(top+ph)+'" y2="'+(top+ph)+'"/>';`.
  `drawWin` closes its clipped group the same way after the caps.
- `tw(text)` (line 385 at `5594f2c`) measures text at
  `11px ui-sans-serif, -apple-system, "Segoe UI", Inter, Roboto, system-ui, sans-serif`
  (normal weight) with a canvas.
- `mkChart(root,P,cols,opt)` (line 437 at `5594f2c`, a few lines lower
  after plans 023 / 024) is called twice in `spInit` (lines 400 and 402 at
  `5594f2c`):

```js
  mkChart(doc.getElementById('ax-cls'),AX,AX.classes.map(wcol),{flags:true,noun:'classes',what:'wait class'});
  ...
  if(okPay(AE,n))mkChart(ev,AE,evColors(AE.classes),{noun:'events',what:'wait event'});
```

  and builds the chart object `c` as a literal starting
  `var c={root:root,P:P,cols:cols,svg:$('.axsvg',root),...` and ending
  `...lg:$('.axlg',root),hl:null,hk:'',peer:null,xmap:null};`.
- An existing halo-text style to copy, `sql/_style.sql` (the highlight note):

```sql
    DBMS_OUTPUT.PUT_LINE('.ashx .xhn{font:600 11px ui-sans-serif,-apple-system,"Segoe UI",Inter,Roboto,system-ui,sans-serif;fill:var(--ink);paint-order:stroke;stroke:var(--panel);stroke-width:3px;stroke-linejoin:round;pointer-events:none}');
```

  (`sql/_style.sql:1483` at `5594f2c`). `--ink` / `--panel` switch with the
  theme (`body.dark`), so a label in `fill:var(--ink)` with a `var(--panel)`
  halo reads on any band colour in both themes. The quiet / dashboard
  designs redefine those tokens, so the labels follow them with no extra
  rule. `sql/_style.sql` is also included by the fleet report: keep the new
  rule scoped under `.ashx`.
- The quiet / dashboard designs (`sql/lib/src/css_design.css`, generated
  into `sql/lib/css_design.plsql`, loaded after `_style.sql`) switch some
  chart texts to their own font, Geist:
  `.ashx .at,.ashx .cft,.ashx .xhn,.wg .axn i,.bd .ov{font-family:var(--font)}`
  (line 66). Do NOT add `.xdl` to that rule. `tw()` measures the system
  font stack, and the label layout (no overlap, band thick enough under the
  whole label) relies on that width. With the `font` shorthand of Step 3e
  the labels keep the system stack in every design.
- The dashboard design shows one Activity chart at a time ("By wait class /
  By wait event / Both" tabs, `window.AWR_axMode`, `sql/lib/src/js_design.js`).
  Labels are per chart, so nothing changes for them. verify_report's
  dashboard block 7 counts x labels as `text.at[text-anchor="middle"]`; the
  labels are `text.xdl` (no `at` class), so they never count as x labels.
- Series names come from the payload (`c.P.classes[k]`, wait class or wait
  event names, JSON-escaped on the server); insert them into SVG through the
  existing `esc()` (line 8).
- `demo/verify_report.js` block 5 (Timeline view) runs the Activity tests
  in Full span (plan 024 forces `AWR_TL.axLayout('span', false)` at its
  start; on the dashboard the line before shows both charts with
  `window.AWR_axMode('both')`); block "5c" (plan 024) tests side by side.
  Its per-chart loop starts `for (const id of CHS) {` (line 450 at
  `5594f2c`). The file-level `DESIGN` variable holds `window.AWR_DESIGN`
  (`classic` when absent).

### Repository rules

- No tilde in `sql/` or `sql/lib/src/*.js`. Pure ASCII output: truncated
  names end with three ASCII dots `...` (do NOT use the single ellipsis
  character, and do not add a backslash-u escape — tool input can turn a
  typed backslash-u sequence into the character itself). Check with
  `grep -nP '[^\x00-\x7F]' <file>`.
- JS source lines under 2300 characters. Fleet files out of scope.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)` |
| JS syntax | `node --check sql/lib/src/js_timeline.js` | no output |
| Regenerate | `tools/js2plsql.sh js_timeline` then `tools/js2plsql.sh --check` | exit 0 |
| Demo | `python3 demo/gen_demo_report.py` (twice, same `md5sum docs/examples/demo_busy_db*.html`), then `--check` | three `up to date` lines (classic, quiet, dashboard pages) |
| All DB-free | `./tools/check.sh` | `check.sh: all checks passed` |
| Smoke test | `NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots` (`T` = a temp dir with `npm i playwright@1.55`), then the same with `demo_busy_db_dashboard.html` (and `demo_busy_db_quiet.html`), one at a time | exit 0, about 3 min each |

## Scope

**In scope**: `sql/lib/src/js_timeline.js`, regenerated
`sql/lib/js_timeline.plsql` (+ one header comment line), `sql/_style.sql`
(one rule), `sql/19_reference.sql` (one sentence), `demo/verify_report.js`,
`docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
`demo_busy_db_dashboard.html` (regenerated), `CHANGELOG.md`, `CLAUDE.md`.

**Out of scope**: the legend (stays as is), the colours (`EVP`,
`AWR_WAIT_COLORS`), the payload (`sql/09_ash_timeline.sql`), the Timeline
grid's stacked columns, the ECharts charts of All sections, the design
files `sql/lib/src/css_design.css` / `js_design.js` (see the font note
above), sections 20-28, fleet files.

## Git workflow

- Branch `advisor/036-activity-band-labels`; commit
  `feat(report): name the largest Activity bands on the chart`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Baseline

`T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55)`, then
`NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`
→ exit 0, then the same for `docs/examples/demo_busy_db_dashboard.html`
→ exit 0 (one at a time). If not, STOP.

### Step 2: The label pass

In `sql/lib/src/js_timeline.js`, right after `function bands(...){...}`,
add:

```js
/* direct labels (plan 036): each shown series is a candidate at the point
   where its band is thickest; a label (its name, at most LW px wide, cut
   with "...") goes there when the band stays at least LBH px thick under the
   whole label and no placed label is in the way.  The thickest bands win,
   at most LMAX a chart; with a strong highlight only the highlighted series.
   groups = [{pts, x0, x1}]: one for Full span, one per panel side by side
   (a label never crosses a panel edge).  Drawn inside the plot clip, above
   bands and stripes, pointer-events none. */
var LBH=13,LMAX=6,LW=160;
function edgeAt(pts,ys,x){
  for(var j=1;j<pts.length;j++)if(pts[j][0]>=x){var a=pts[j-1][0],b=pts[j][0],f=b>a?(x-a)/(b-a):0;return ys[j-1]+(ys[j]-ys[j-1])*f;}
  return ys[ys.length-1];
}
function dlab(c,groups,ord,on,Y,reb){
  if(!c.lab)return '';
  var cand=[],placed=[],s='';
  groups.forEach(function(G){
    var pts=G.pts,np=pts.length;if(np<2)return;
    var lo=pts.map(function(){return 0;});
    ord.forEach(function(k){
      var hi=lo.map(function(l,j){return l+(rV(c,k,pts[j][1])||0);});
      if(!reb||(on&&on[k])){
        var yl=lo.map(Y),yh=hi.map(Y),best=-1,bt=0;
        for(var j=0;j<np;j++){var t=yl[j]-yh[j];if(t>bt){bt=t;best=j;}}
        if(best>=0&&bt>=LBH)cand.push({k:k,G:G,yl:yl,yh:yh,j:best,t:bt});
      }
      lo=hi;
    });
  });
  cand.sort(function(a,b){return b.t-a.t;});
  cand.forEach(function(C){
    if(placed.length>=LMAX)return;
    var nm=c.P.classes[C.k],txt=nm,w=tw(txt)+6;
    if(w>LW){while(txt.length>4&&tw(txt+'...')+6>LW)txt=txt.slice(0,-1);txt+='...';w=tw(txt)+6;}
    var pts=C.G.pts,x=pts[C.j][0],xa=x-w/2,xb=x+w/2;
    if(xa<C.G.x0){xa=C.G.x0;xb=xa+w;}
    if(xb>C.G.x1){xb=C.G.x1;xa=xb-w;}
    if(xa<C.G.x0)return;
    var top=Math.max(edgeAt(pts,C.yh,xa),edgeAt(pts,C.yh,xb)),bot=Math.min(edgeAt(pts,C.yl,xa),edgeAt(pts,C.yl,xb));
    for(var j=0;j<pts.length;j++){var px=pts[j][0];if(px<xa||px>xb)continue;top=Math.max(top,C.yh[j]);bot=Math.min(bot,C.yl[j]);}
    if(bot-top<LBH)return;
    var yc=(top+bot)/2,box=[xa,yc-LBH/2,xb,yc+LBH/2];
    if(placed.some(function(p){return box[0]<p[2]+2&&box[2]>p[0]-2&&box[1]<p[3]+2&&box[3]>p[1]-2;}))return;
    placed.push(box);
    s+='<text class="xdl" x="'+((xa+xb)/2).toFixed(1)+'" y="'+(yc+4).toFixed(1)+'" text-anchor="middle">'+esc(txt)+'</text>';
  });
  return s;
}
```

Notes for the implementation:
- `Y` is the chart's AAS-to-pixel function; with a strong highlight (`reb`)
  the y axis is fitted to the highlighted series and the others are clipped,
  which is why only the highlighted ones are candidates then.
- `bands()` stacks in exactly `ord` order from zero; this pass must stack the
  same way (it does: `lo` starts at 0 and adds each `ord` series in turn), so
  a label sits inside the band it names.

**Verify**: `node --check sql/lib/src/js_timeline.js` → no output;
`grep -n "'\.\.\.'" sql/lib/src/js_timeline.js` → the truncation lines;
`grep -nP '[^\x00-\x7F]' sql/lib/src/js_timeline.js` → no output.

### Step 3: Call it from both drawing paths and switch it on per chart

a) In `mkChart`, add `lab:opt.labels!==false` to the object literal
`var c={root:root,P:P,cols:cols,...}` (after `xmap:null`).

b) In `spInit`, give both calls an explicit option so the owner can flip
either: the class chart's options become
`{flags:true,noun:'classes',what:'wait class',labels:true}` and the event
chart's `{noun:'events',what:'wait event',labels:true}`.

c) In `draw` (Full span), immediately BEFORE
`  s+='</g><line class="ax" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+(top+ph)+'" y2="'+(top+ph)+'"/>';`
insert
`  s+=dlab(c,[{pts:pts,x0:padL,x1:Wd-padR}],ord,on,Y,reb);`

d) In `drawWin` (side by side), immediately BEFORE its own
`s+='</g><line class="ax" ...'` line insert
`  s+=dlab(c,pan.map(function(p){return {pts:p.pts,x0:p.x0,x1:p.x0+p.w};}),ord,on,Y,reb);`

(Both insertions are inside the clipped group, after the stripes / caps, so
labels draw on top and never leave the plot.)

e) `sql/_style.sql`: right after the `.ashx .xhn{...}` line add

```sql
    DBMS_OUTPUT.PUT_LINE('.ashx .xdl{font:11px ui-sans-serif,-apple-system,"Segoe UI",Inter,Roboto,system-ui,sans-serif;fill:var(--ink);paint-order:stroke;stroke:var(--panel);stroke-width:3px;stroke-linejoin:round;pointer-events:none}');
```

(Normal weight on purpose: `tw()` measures normal-weight text, so the
width rule is exact.)

f) `tools/js2plsql.sh js_timeline`; in the hand-written header of
`sql/lib/js_timeline.plsql` (above `BEGIN`) add the line
`-- Direct labels (dlab): the widest bands are named on the chart, at most 6 a chart.`

**Verify**: `tools/js2plsql.sh --check` → exit 0; `./lint.sh` clean;
`python3 demo/gen_demo_report.py` twice → equal
`md5sum docs/examples/demo_busy_db*.html`;
`grep -c 'xdl' docs/examples/demo_busy_db.html` → 2 or more (the CSS rule
and the script), the same for the quiet and dashboard pages;
`grep -c 'xdl' sql/lib/css_design.plsql` → `0` (the design font rule is
untouched).

### Step 4: Guide text

`sql/19_reference.sql`, in the guide item "Full-span activity" (the piece
that, after plan 024, ends with `... a panel&rsquo;s top edge pins it.</span></p></div></div>');`):
insert ` The largest bands carry their name.` right before
`</span></p></div></div>`.

**Verify**: `./lint.sh` clean; no `sql/19_reference.sql` line longer than
2400 characters was created (`awk 'length($0) > 2400' sql/19_reference.sql | wc -l`
unchanged from before the edit).

### Step 5: Smoke test

In `demo/verify_report.js`, section 5, after the legend test of the chart
loop (the line `if (!/^ok/.test(tl['legend_' + k])) fail(...)`) and
outside the `for (const id of CHS)` loop is simpler — put it right after
that loop's closing `}`:

```js
      // direct labels (plan 036): each label names a series, sits inside the
      // plot, no two overlap, at most 6 a chart; hiding the first labelled
      // series removes its label, showing it again restores it
      tl.labels = await page.evaluate(() => {
        const out = [];
        for (const [id, key] of [['ax-cls', 'ashx'], ['ax-ev', 'ashe']]) {
          const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) continue;
          const names = ((window.AWR_DATA || {})[key] || {}).classes || [];
          const L = [...s.querySelectorAll('text.xdl')], ax = s.querySelector('line.ax').getBoundingClientRect();
          const bad = L.filter(t => { const n = t.textContent; return !names.some(x => x === n || (n.endsWith('...') && x.startsWith(n.slice(0, -3)))); }).length;
          const B = L.map(t => t.getBoundingClientRect());
          let ov = 0; for (let i = 0; i < B.length; i++) for (let j = i + 1; j < B.length; j++) if (B[i].left < B[j].right && B[j].left < B[i].right && B[i].top < B[j].bottom && B[j].top < B[i].bottom) ov++;
          const outside = B.filter(b => b.left < ax.left - 1 || b.right > ax.right + 1 || b.bottom > ax.top + 1).length;
          out.push(id + ' ' + L.length + (bad || ov || outside || L.length > 6 ? ' FAIL bad=' + bad + ' overlap=' + ov + ' outside=' + outside : ''));
        }
        return out.join('; ');
      });
      if (/FAIL/.test(tl.labels)) fail('activity: direct labels ' + tl.labels);
      if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/ax-cls [1-6]; ax-ev [1-6]$/.test(tl.labels)) fail('activity: the demo must label at least one band on each chart: ' + tl.labels);
      {
        const first = await page.evaluate(() => { const t = document.querySelector('#ax-ev .axsvg text.xdl'); if (!t) return null; const nm = t.textContent; const i = AWR_DATA.ashe.classes.indexOf(nm); return i < 0 ? null : { nm, i }; });
        if (first) {
          const has = () => page.evaluate((nm) => [...document.querySelectorAll('#ax-ev .axsvg text.xdl')].some(t => t.textContent === nm), first.nm);
          await page.click('#ax-ev .axlg .axc[data-c="' + first.i + '"]'); await page.waitForTimeout(150);
          const gone = !(await has());
          await page.click('#ax-ev .axlg .axc[data-c="' + first.i + '"]'); await page.mouse.move(2, 2); await page.waitForTimeout(200);
          const back = await has();
          tl.labelHide = gone && back ? 'ok' : 'FAIL ' + JSON.stringify([first.nm, gone, back]);
          if (tl.labelHide !== 'ok') fail('activity: hiding a labelled series ' + tl.labelHide);
        }
      }
```

(The page scrolled to the top at the start of each chart's tests; if
`page.mouse.move(2, 2)` lands on the sticky top bar that is fine — it only
needs to leave the legend so no highlight stays on. The demo-only rule
matches all three demo pages; on the dashboard both charts are shown here,
because block 5 calls `window.AWR_axMode('both')` before its chart tests.)

In block "5c" (side by side, plan 024), right after the `sb.panels`
check, add a containment check: every `#ax-cls .axsvg text.xdl` and
`#ax-ev .axsvg text.xdl` bounding box lies within the x range of one
`rect.xw.xpn` of the same SVG (allow 1 px), else
`fail('side by side: a label crosses a panel edge')`.

Add a bullet to the file's header comment: "direct labels on the Activity
bands (plan 036): name a series, inside the plot, no overlap, at most 6,
gone when the series is hidden; inside one panel side by side".

**Verify**: `node --check demo/verify_report.js` → no output; then, one at
a time,
`NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots`,
the same with `docs/examples/demo_busy_db_dashboard.html /tmp/awr-shots-dash`
(and `docs/examples/demo_busy_db_quiet.html /tmp/awr-shots-quiet`)
→ each exits 0; the `timeline interactions` JSON contains `"labels":"ax-cls N; ax-ev M"`
(1 ≤ N, M ≤ 6) and `"labelHide":"ok"`; on the dashboard, block 7's
`Activity tabs` line still passes. Look at `/tmp/awr-shots/timeline-light.png`
and `timeline-dark.png` (and the dashboard's): labels readable on their
bands in both themes.

### Step 6: Documentation

- `CHANGELOG.md` (`## Unreleased`, line 8 → `### Report`, line 120 at
  `5594f2c`): "**Activity charts name
  their largest bands.** Up to six series per chart are labelled on the
  widest part of their band (never overlapping, inside one panel in Windows
  side by side); the legend stays."
- `CLAUDE.md`, "Activity, whole span": "Direct labels (plan 036): `dlab(c,
  groups, ord, on, Y, reb)` after the bands, inside the plot clip;
  `text.xdl` (CSS halo like `.xhn`, normal weight so `tw()` is exact),
  thickest bands first, band at least `LBH` 13 px under the whole label,
  at most `LMAX` 6, names cut at `LW` 160 px with ASCII `...`; with a strong
  highlight only the highlighted series; per chart `mkChart(..., {labels})`;
  keep `.xdl` out of `css_design.css`'s Geist font rule (`tw()` measures
  the system stack)."

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- `demo/verify_report.js` (Step 5): label names valid, inside the plot, no
  overlap, at most 6 per chart, at least one per chart on the demo, a hidden
  series loses its label and gets it back; side by side: labels stay inside
  their panel. All existing Activity tests still pass (labels are `text.xdl`,
  not `path.xa` / `text.at`, and `pointer-events:none` keeps hit-testing
  unchanged).
- Visual check of the screenshots (summary / timeline × light / dark),
  classic and dashboard.

## Done criteria

- [ ] `./tools/check.sh` → `check.sh: all checks passed`
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `demo/verify_report.js` exits 0 with `labels` and `labelHide` ok on `demo_busy_db.html` and `demo_busy_db_dashboard.html` (one at a time; quiet recommended)
- [ ] `python3 demo/gen_demo_report.py --check` → three `up to date` lines
- [ ] `grep -nP '[^\x00-\x7F]' sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/_style.sql sql/19_reference.sql` → no output
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `drawWin` / `bands` (plan 024) are not present, or `5594f2c` is not in
  the branch.
- On the dashboard demo, block 7 (the design checks) fails after the
  change.
- An existing Activity test in section 5 or block 5c fails after the change
  (for example the hover test now hits a label: that would mean
  `pointer-events:none` is missing).
- Labels visibly sit outside their band on the demo screenshots (the
  stacking in `dlab` does not match `bands`) and the cause is not obvious
  after one attempt.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Owner decision**: labels on both charts (default here) or on the event
  chart only (`labels:false` in the class chart's `mkChart` options); the
  limits `LMAX` / `LBH` / `LW` are constants next to `dlab`.
- Any future change to the stacking order in `bands()` must be mirrored in
  `dlab()` (both stack `ord` from zero).
- The labels are recomputed on every draw (zoom, legend, highlight, pin,
  resize), so they follow zoom: zoomed into a window, bands get wider and
  more labels fit; zoomed out or with thin bands, fewer or none.
- **Needs an owner DB run**: dbmint (`ssh -p 2200 oracle@dbmint`, never
  2201; rsync without `--delete`). dbmint keeps only 35 days of AWR (the
  September dates of older plans are gone); probe for a restart-free
  stretch first (`CLAUDE.md`, "dbmint keeps 35 days of AWR"; on 2026-11-19:
  2026-11-07 14:45 to 2026-11-09 16:15), e.g.
  `./run_awr_trend.sh '/ as sysdba' "2026-11-08 15:00" 1 8 10 0 1 h`, once
  with the default design and once with `DESIGN=dashboard`: rc 0, 29/29
  `AWR-SECTION` pairs; `demo/verify_report.js` on both reports (the
  demo-only "at least one label" rule does not apply to them: dbmint is
  idle, bands may be too thin for any label, which is correct).
