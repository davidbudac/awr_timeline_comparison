# Plan 024: The Activity charts get a "Windows side by side" mode

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan is written against the code AFTER
> plan 023 (`plans/023-verdict-first-compact-activity.md`), on top of commit
> `5594f2c`. First confirm both:
> `git merge-base --is-ancestor 5594f2c HEAD && echo ok` → `ok`;
> 023 has landed: `grep -c "awr-ax" sql/lib/src/js_timeline.js` → `1` or
> more, and `grep -c 'id="ax-more"' sql/00_params.sql` → `1`. If any of
> these fails, STOP (do 023 first). Then run
> `git diff --stat 5594f2c..HEAD -- sql/00_params.sql sql/_style.sql sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/lib/css_design.plsql sql/19_reference.sql demo/verify_report.js`
> — the only changes there should be plan 023's. Line numbers below are
> those of commit `5594f2c`. After plan 023, the `js_timeline.js` lines
> 283-414 sit 5 lines lower, lines 415-492 about 20 lines lower, and the
> rest of `draw()` and everything after it about 21 lines lower. Always
> locate code by the quoted text.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED (it touches the chart core: hover, highlight, pin, brush)
- **Depends on**: plans/023-verdict-first-compact-activity.md
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19;
  first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`. Since `ee23e49` the report
  gained three designs (`design` = classic / quiet / dashboard) and sections
  20-28. Changes to this plan:
  - Line numbers were refreshed. In `js_timeline.js`, `draw()` now sets
    `c.flags` / `c.xl` from the charts that are SHOWN, and caches on
    `c.lay`. `drawWin` therefore takes `c.xl` / `c.flags` as they are, and
    the early-return condition quoted below is the new one.
  - The dashboard design adds its own segmented control to the same `.axh`
    row: "By wait class / By wait event / Both", exposed as
    `window.AWR_axMode`. So this plan's public API is renamed from
    `axMode` to `AWR_TL.axLayout`, its control class to `.axlayout`, and
    its localStorage key to `awr-axlayout`, so the two cannot be confused.
  - Side by side must also work when the dashboard shows ONE chart (labels
    and flags on it). verify_report's dashboard block 7 checks exactly that.
  - Step 4 gets a one-rule design override, and the smoke test runs on the
    three demo pages (classic, quiet, dashboard). The "is this the demo"
    file-name test matches all three.
  - verify_report block name "5c" is still free (the blocks at `5594f2c`
    are 1-5, 5b, 6, 7, 8).
- **Owner decision (default mode), DECIDED 2026-11-19: Full span.** A
  reader who never clicked the switch sees Full span (today's view) in every
  case; "Windows side by side" is opt-in. The default is one constant,
  `AXDEF='span'`, in `sql/lib/src/js_timeline.js`. The fit rule stays in the
  code (with `AXDEF='win'` side by side would be the default whenever every
  compared window gets a panel at least 24 px wide), so flipping the default
  later is a one-word change. A reader's own click is always remembered (localStorage
  `awr-axlayout`) and wins. It applies in all three designs. In the
  dashboard, the Activity header then holds two segmented controls: this
  layout switch and the dashboard's chart tabs.

## Why this matters

The report compares the same hour across weeks, but the Activity charts draw
those hours on a continuous three-month time axis, where each compared window
is a 1-to-3-px grey stripe. To compare the shape of Current against the prior
windows a reader has to zoom into each window one at a time. The data needed
for a direct comparison is already in the page: `AWR_DATA.ashx.fine` /
`ashe.fine` hold one value per minute for every compared window. This plan
adds a second layout for the same two charts: the compared windows as
adjacent panels (oldest left, Current last and highlighted) on one shared y
axis, so "Current looks different" is visible at a glance. "Full span" stays
one click away and keeps zoom.

Target (one chart; the by-event chart below it uses the same panels):

```
 Activity, whole span   13 compared windows side by side, 1-min detail
                        [Windows side by side | Full span]   key ...
          R4.0  HF        RU             R4.1                  R4.2
  30 |     |     |         |              |                     |  +------+
     |     |     |         |              |                     |  |  /\  |
  15 |  /\ | /\  |  /\ /\  | /\  /\  /\   |  /\  /\  /\  /\     |  | /  \ |
     | /  \|/  \ | /  V  \ |/  \/  \/  \  | /  \/  \/  \/  \    |  |/    \|
   0 +-----+-----+---------+--------------+---------------------+--+------+
      18 Jun 25 Jun 2 Jul ...                                 3 Sep  10 Sep
      (each panel = one compared window, minute by minute; Current boxed)
```

- Each panel's x axis is its own window, start to end. The y axis is shared
  by all panels of a chart.
- A panel is drawn minute by minute when every minute of its window is in
  the 1-minute data; otherwise (the 1-minute data is capped at 40000
  minutes, so very many or very long windows can miss it) from the coarse
  buckets that overlap the window. The range line says which.
- Release markers sit in the gap between two panels (the gap before the
  window they precede), flags on the upper chart as today.
- A click on a panel's top edge (its 4-px cap) pins that window (exactly as
  a click on a stripe does today: the Timeline grid compares against it, the
  panel turns amber); Current unpins; Enter / Space on the focused cap too.
- Hover shows the minute (or bucket) under the pointer with each series'
  AAS, and the crosshair at the same place on the other chart.
- Legend toggles, the series highlight (hover, focus, Shift+click, a click on
  a band, Esc) work as in Full span.
- No brush zoom in this mode (zooming across separate windows has no
  meaning); a drag does nothing and "Reset zoom" stays hidden. Full span
  keeps its zoom state while the reader is in side-by-side mode.
- Too many windows: panels are at least `AXMP` = 24 px wide with `AXGAP` =
  6 px between them; when not all windows fit, the most recent ones that fit
  are shown (always including Current) and the range line says "The K most
  recent of N compared windows side by side (Full span shows all)".
- Overlapping windows (`win_hours` > step): each panel shows its full
  window; a minute that two windows share appears in both panels (the
  1-minute data stores it once; each panel slices its own range).
- Skipped windows (AWR snapshot problems) still have ASH data; as in Full
  span today, their data is drawn and the panel is marked grey (its cap and
  a struck-through date label), and the cap's tooltip says "skipped".

A direction-only picture is the outline numbered 5 in
`plans/assets/ux-mockup-2026-11-17.html`.

## Current state

### Background

- The report is one HTML file printed by SQL*Plus (`DBMS_OUTPUT.PUT_LINE`
  in PL/SQL blocks; a single quote inside a PL/SQL string is `''`).
- The charts' JavaScript is `sql/lib/src/js_timeline.js` (readable source).
  `sql/lib/js_timeline.plsql` is GENERATED from it by
  `tools/js2plsql.sh js_timeline`; never edit its body by hand (its comment
  header above `BEGIN` is hand-written and kept by the generator).
- `demo/gen_demo_report.py` renders the synthetic demo without a database,
  as three pages, one per report design: `docs/examples/demo_busy_db.html`
  (classic), `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html`. It
  copies the CSS and the generated scripts literally, and copies the
  Activity skeleton of `sql/00_params.sql` literally (by text). The demo has
  13 weekly 1-hour windows (12 prior + Current), five release markers, and
  1-minute data for every window. `demo/verify_report.js` is the Playwright
  smoke test. It reads `window.AWR_DESIGN` into its file-level `DESIGN`
  variable (`classic` when absent).

### The report designs and the Activity header

`design=quiet|dashboard` adds a stylesheet and a script to the page:
`sql/lib/src/css_design.css` → generated `sql/lib/css_design.plsql`
(`tools/js2plsql.sh css_design`), and `sql/lib/src/js_design.js` →
generated `sql/lib/js_design.plsql`. Both come after `_style.sql` and after
every other script. Rule: design-only CSS goes in `css_design.css`, never
in `_style.sql`. What they do to the Activity block (`js_design.js`):

- both designs: `howToRead()` appends a `button.axhow` ("How to read") to
  `.axh` and moves the help line `p.axn2` into `.axh` as a popover;
- dashboard: `activityTabs()` inserts `div.seg.axseg` (buttons
  `data-ax="cls|ev|both"`) into `.axh` right before `.axhow`. It toggles
  `#ashx.ax-cls-only` / `#ashx.ax-ev-only` (CSS hides the other chart),
  then calls `AWR_TL.redraw()` (= `drawAll(true)`). It starts on "By wait
  class" and is exposed as `window.AWR_axMode(m)`. That is a different
  thing from this plan's `AWR_TL.axLayout`, which picks the time layout.
  In `css_design.css`: `.ashx .axseg{flex:none}`,
  `.ashx .axseg button{font-size:12px;padding:2px 10px}`, and `.seg` /
  `.seg button` restyled (padding 3px, `--chip-bg` background).
- `.axh` is `display:flex;flex-wrap:wrap` (`sql/_style.sql:1429`), so the
  extra controls wrap.

### The data the charts receive (from `sql/09_ash_timeline.sql`, header lines 18-82)

- `window.AWR_DATA.ashx = {t0, end, bh, wh, classes, vals, win, winfg, fine}`
  (by wait class) and `AWR_DATA.ashe` (same shape by wait event, plus
  `ecls`). `vals[k]` = one AAS per coarse bucket of `bh` hours; `win[k]` =
  one AAS per compared window, oldest first.
- `fine = {bm, capped, segs, vals}`: `segs` = `[[first minute since t0,
  minutes], ...]`, the compared windows as minute ranges, oldest first,
  overlapping windows merged into one segment; `vals[k]` = the integer sample
  count of every minute of every segment in order (AAS = n / 6), a run of k
  zero minutes written as `-k`; `capped` = 1 when only the most recent
  windows fit in 40000 minutes.
- `window.AWR_WIN = {np, w:[{o, d, l, s, e, t, v}]}` oldest first: `o` =
  window offset (0 = Current), `d` = short column label (e.g. `18 Jun`), `l`
  = offset label, `s` / `e` = start / end `'YYYY-MM-DD HH24:MI'`, `t` = full
  title, `v` = `'Y'` valid / `'N'` skipped (`sql/00_params.sql:1247-1269`).

### The chart code, `sql/lib/src/js_timeline.js` (line numbers at `5594f2c`, before plan 023)

- Helpers already there: `wins()` (line 34, AWR_WIN.w), `idxOf(o)` (36),
  `offTxt(w)` (37), `PT(s)` (40, parses `'YYYY-MM-DD HH24:MI'` as UTC ms),
  `fAt`, `fHM`, `fDay` (42-44), `esc` (8), `niceStep` (32), `tw(text)` (385,
  text width in px), `bRange(a,b)` (383, first/last coarse bucket in
  `[a,b)`), `bucketAt(t)` (603), `fineCov(a,b)` (354, ms of `[a,b)` covered
  by the 1-minute segments), `rS(r)` / `rE(r)` / `rV(c,k,r)` (337-339: start,
  end and value of a "ref" — a coarse bucket `r >= 0` or a 1-minute bucket
  `r = -1 - j`).
- `SP` (built in `spInit`, lines 394-397) holds `T`/`T1` (bucket starts /
  ends), `t0`, `bh`, `full`, `dom` (the zoom domain), `win` (each compared
  window as `[start ms, end ms]`, oldest first, same order as `wins()`),
  `min`, `bhTxt`, `reset`, `range`, `sel`, `F` (the decoded 1-minute grid:
  `F.S` = segments `[startMs, endMs, firstIndex]`, `F.bm` = 60000), `rk`,
  `rv`:

```js
  SP={T:T,T1:T1,t0:t0,bh:bh,full:[t0,end],dom:[t0,end],win:wins().map(function(w){return [PT(w.s),PT(w.e)];}),
      min:Math.max(4*bh,Math.min(6*H1,(end-t0)/4)),bhTxt:AX.bh===1?'hourly':bLab(AX.bh)+' averages',
      reset:doc.getElementById('ax-reset'),range:doc.getElementById('ax-range'),sel:null,F:null,rk:null,rv:null};
```

- `draw(c,force)` (lines 485-601) draws one chart for the zoom domain
  `SP.dom`. Its parts, in order:
  - 486-495: size. First the charts that are SHOWN decide which chart
    carries the release flags and which the date labels (line 489:
    `var vis=CH.filter(function(x){return shown(x.plot);}),lay;c.flags=vis[0]===c;c.xl=vis[vis.length-1]===c;lay=(c.flags?1:0)+(c.xl?2:0);`),
    so with one chart hidden (the compact Summary of plan 023, or the
    dashboard design's one-chart tabs) the chart shown gets both. Then the
    early return, which after plan 023 reads
    `if(!force&&c.w===Wd&&c.lay===lay&&c.g&&c.pw===PW&&c.g.d0===d0&&c.g.d1===d1&&c.g.hk===c.hk&&c.g.cm===cmp())return;c.w=Wd;c.pw=PW;c.lay=lay;`
    (line 491). After plan 023, line 493 is replaced by
    `var cm=cmp();` and
    `var top=c.flags&&mks.length?46:22,ph=cm?96:150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;`.
    Then `var X=function(t){return padL+pw*(t-d0)/(d1-d0);};` (495).
  - 505-509: the highlight state and the series order:

```js
  var hl=c.hl,on=null,i,k,sm,sh,r;
  if(hl){on=P.classes.map(function(x,q){return !!hl.set[q]&&c.vis[q];});if(!on.some(Boolean)){hl=null;on=null;}}
  var reb=!!(hl&&hl.strong),ord=[];
  for(k=0;k<P.vals.length;k++)if(c.vis[k]&&(!reb||on[k]))ord.push(k);
  if(reb)for(k=0;k<P.vals.length;k++)if(c.vis[k]&&!on[k])ord.push(k);
```

  - 510-517: the drawn points (one per bucket, or per pixel column at its
    busiest bucket) and the maxima `mx` / `mh`:

```js
  var R=refs(d0,d1),pts=[],cb=null,mx=0.05,mh=0;
  for(i=0;i<R.length;i++){r=R[i];sm=0;sh=0;for(k=0;k<P.vals.length;k++)if(c.vis[k]){var vk=rV(c,k,r)||0;sm+=vk;if(reb&&on[k])sh+=vk;}
    var ra=rS(r),rb=rE(r);if(rb>d0&&ra<d1){if(sm>mx)mx=sm;if(sh>mh)mh=sh;}
    var xm=X((ra+rb)/2),col=Math.floor(xm),g=pts[pts.length-1];
    if(g&&col===cb){if(reb?(sh>g[3]||(sh===g[3]&&sm>g[2])):sm>g[2]){g[0]=xm;g[1]=r;g[2]=sm;g[3]=sh;}}else{pts.push([xm,r,sm,sh]);cb=col;}}
  if(pts.length){var pf=pts[0],pl=pts[pts.length-1];
    if(rS(pf[1])>=d0)pts.unshift([X(rS(pf[1])),pf[1],pf[2],pf[3]]);
    if(rE(pl[1])<=d1)pts.push([X(rE(pl[1])),pl[1],pl[2],pl[3]]);}
```

  - 518-524: y scale, clip paths, gridlines, the "AAS" label, open the
    clipped group `<g clip-path="url(#...)">`.
  - 533-546: the band paths (`fills`, `edges`, and for highlighted series
    `hf`, `he`), built from `pts`; 547-549 assemble them (faded group when a
    highlight is on).
  - 550: the hidden bucket band `rect.xbk`.
  - 551-557: the window stripes `rect.xw` + caps `rect.xwc` (classes
    `cur` / `on` / `sk` / `wd`) and the `hit` list.
  - 558: close the group, x axis line. 559-569: x ticks and (when `c.xl`)
    date labels.
  - 570-588: the release markers (`W.markers()` → `{o, after, l, s, t, at}`;
    a line on every chart shown, flags in two tiers only on the chart with
    `c.flags`, i.e. the first one shown; the loop proper is 572-588,
    starting `var tiers=[[],[]];`).
  - 589-590: the highlight note `text.xhn`, the crosshair `line.xch`.
  - 594-598: the hit rects `rect.xwh[data-i][data-w]` (`tabindex=0`,
    `role=button`) over each stripe; 599 `c.svg.innerHTML=s`; 600 `c.g={...}`.
- `seriesAt(c,x,y)` (315-324) finds the series under the pointer through
  `tAt` + `refAt`. `cross(c,t,r)` (607-612) draws the crosshair at time `t`
  and the band of ref `r`, through `c.g.X`. `hover(c,e)` (613-630): the
  `.xwh` branch (window tooltip from `P.win`), then the point tooltip
  (lines 623-629; line 628 contains a JavaScript escape sequence for an en
  dash — do not retype it, move it).
- Brush / click handling, `spInit` (lines 416-435): the document
  `mousemove` handler shows the brush on both charts; `mouseup` either zooms
  (`spZoom`), pins (`dg.w` set by a mousedown on `.xwh`) or makes the band
  under the pointer a sticky highlight. `mkChart` (lines 460-470): the
  mousedown handler (a second press of a double-click resets the zoom,
  `spReset()`), `s.addEventListener('dblclick',spReset);`, and the keydown
  handler (Enter / Space on `.xwh` pins).
- `spHead()` (478-484) writes the range line `#ax-range` and shows "Reset
  zoom" when zoomed.
- `W.pin(o)` (133-157) re-draws every chart (`drawAll(true)`), so the
  pinned panel needs no extra wiring; Esc (166) clears a highlight first,
  then the pin.
- `TL.redraw=function(){drawAll(true);};` (line 477) is what the
  dashboard's chart tabs call after showing / hiding a chart.

### The skeleton, `sql/00_params.sql` (after plan 023 it sits right after the verdict hero)

```sql
    DBMS_OUTPUT.PUT_LINE('<div class="ashx" id="ashx" role="group" aria-label="Active sessions over the whole span" hidden>'
        || '<div class="axh"><span class="axs" id="ax-range"></span>'
        || '<span class="axk" aria-hidden="true"><span><i class="kw"></i>compared window</span>'
        || '<span><i class="kw cur"></i>Current</span><span><i class="kw pin"></i>pinned</span></span>'
        || '<button type="button" class="axr axm" id="ax-more" aria-controls="ax-ev" aria-expanded="false" hidden>Show by wait event</button>'
        || '<button type="button" class="axr" id="ax-reset" hidden>Reset zoom</button></div>'
```

and the help line, which ends:

```sql
        || 'so its shape over time reads directly. Click its band, or Shift+click the legend entry, to keep it; Esc clears.</p>'
        || '</div></section>');
```

### CSS, `sql/_style.sql`

- `.seg` (lines 1048-1051) is the global segmented control (the top bar's
  view switch uses it, scoped by the chrome JS to `.topbar .seg`):
  `.seg{display:inline-flex;...}`, `.seg button{...}`,
  `.seg button[aria-pressed="true"]{background:var(--ink);color:var(--panel)}`.
  Because `.seg` sets `display`, a `[hidden]` `.seg` needs its own
  `display:none` rule.
- The Activity rules are lines 1423-1482 (`.ashx .xw{fill:var(--ink-3);opacity:.16}`,
  `.ashx .xw.cur{fill:var(--acc);opacity:.28}`, `.ashx .xw.on{...}`,
  `.ashx .xw.sk{...}`, `.ashx .xwc...`, `.ashx .at{font:11px ...;fill:var(--ink-3)}`).
  `sql/_style.sql` is also included by the fleet report: scope every new rule
  to `.ashx` / `#activity`.

### The smoke test, `demo/verify_report.js`

- Block "5." (from line 369) opens `#view=timeline` and, inside
  `if (inv.chart && inv.ash) {` (line 438), tests hover, legend, brush zoom,
  the 1-minute zoom, pin, highlight — all in Full span terms (`.xw.cur`
  stripes, a brush). Those tests must keep running in Full span. On the
  dashboard design the line just before it (437) calls
  `window.AWR_axMode('both')` so both charts show. Block 5 ends at line
  764 (`await page.close();` then `}`), and line 766 starts
  `// ---- 5b. v1.6.1 Day profile metric picker`.
- The ruler-pin check (around line 728) looks for `.ashx .axsvg .xw.on` in
  the Summary view after a pin; this plan keeps the class `xw ... on` on the
  pinned panel so that check works in either mode.
- Block "7." (from line 883, quiet / dashboard only) checks on the
  dashboard the "Activity tabs": for "By wait event", "By wait class" and
  "Both", the chart(s) shown are drawn (`path.xa`). Only the LAST chart
  shown has x labels (`text.at[text-anchor="middle"]`), and when there are
  release markers only the FIRST chart shown has flags (`text.cft`). It
  runs in whatever layout is the default, which is Full span
  (`AXDEF='span'`), so it is unchanged by this plan; block 5c forces side by
  side and checks the same contract there, so `drawWin` must keep it.
- The existing blocks are 1-5, 5b, 6, 7, 8; "5c" is free.

### Repository rules that apply

- **Never type a tilde** in `sql/` files or `sql/lib/src/*.js` (`SET DEFINE '~'`;
  lint and the generator reject it).
- **Pure ASCII output** (lint check 25): HTML entities in markup
  (`&rsquo;`), JavaScript escapes for non-ASCII characters. Tool input can
  turn a typed backslash-u sequence into the character itself; this plan
  needs no new escape — where the existing tooltip line holds one, MOVE the
  line (cut / paste), do not retype it. Check with
  `grep -nP '[^\x00-\x7F]' <file>`.
- Lines of `sql/lib/src/js_timeline.js` under 2300 characters; PUT_LINE
  source lines under 2499.
- Fleet files are out of scope. "All sections" keeps every number (this is
  presentation only).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate the chart script | `tools/js2plsql.sh js_timeline` | exit 0 |
| Regenerate the design stylesheet | `tools/js2plsql.sh css_design` | exit 0 |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0 |
| JS syntax | `node --check sql/lib/src/js_timeline.js` | no output |
| Regenerate the demo | `python3 demo/gen_demo_report.py` | three `wrote .../demo_busy_db*.html (... KB)` lines (classic, quiet, dashboard) |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | three `up to date: ...` lines |
| Everything DB-free | `./tools/check.sh` | `check.sh: all checks passed` |
| Playwright (once) | `T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55)` | exit 0 |
| Smoke test | `NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots` (classic; the same for `demo_busy_db_dashboard.html` and `demo_busy_db_quiet.html` where a step says so) | exit 0 (about 3 min each; never two at once) |

No database is available to you; the owner's database check is under
"Maintenance notes".

## Scope

**In scope**:
- `sql/lib/src/js_timeline.js`, regenerated `sql/lib/js_timeline.plsql`
  (+ its hand-written header)
- `sql/00_params.sql` (the mode switch in `.axh`, one sentence in the help line)
- `sql/_style.sql` (a few `.ashx` rules)
- `sql/lib/src/css_design.css` + regenerated `sql/lib/css_design.plsql`
  (one rule: the layout switch in the quiet / dashboard skin)
- `sql/19_reference.sql` (one sentence in the guide, one in About)
- `demo/verify_report.js`
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
  `demo_busy_db_dashboard.html` (regenerated, never hand-edited)
- `CHANGELOG.md`, `CLAUDE.md`
- Scratch files under `/tmp` (not committed)

**Out of scope**:
- `sql/09_ash_timeline.sql` and the payload shape: everything needed is
  already in `ashx` / `ashe` / `fine` / `AWR_WIN`.
- The Timeline grid (`#tl`), the window component (`js_wingrid`), the DB time
  card's stacked bars.
- Direct labels on the bands (plan 036) — do not add them here.
- Zoom inside side-by-side mode.
- `sql/lib/src/js_design.js` (the dashboard's chart tabs `.axseg` /
  `window.AWR_axMode`, "How to read"): it needs no change; `drawWin` honours
  `c.flags` / `c.xl`, which `draw()` derives from the charts shown.
- Sections 20-28.
- Fleet files.

## Git workflow

- Branch: `advisor/024-activity-side-by-side` from `main` (with 023 merged;
  `main` must contain `5594f2c`).
- Two commits: `refactor(report): split the Activity chart's draw() into
  reusable parts (no output change)` after Step 3, then
  `feat(report): Activity charts "Windows side by side" mode`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Baseline and an SVG snapshot tool

```sh
T=$(mktemp -d) && (cd "$T" && npm i playwright@1.55)
cp docs/examples/demo_busy_db.html /tmp/demo_before_024.html
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db_dashboard.html
```

(one at a time).

Create `/tmp/axsnap.js` (a scratch tool, not committed) that prints the two
charts' SVG in Full span mode, in the Timeline view, at 1440 px:

```js
const { chromium } = require('playwright'); const path = require('path'); const fs = require('fs');
(async () => {
  const [, , file, out] = process.argv;
  let b; try { b = await chromium.launch(); } catch (e) { b = await chromium.launch({ channel: 'chrome' }); }
  const p = await b.newPage({ viewport: { width: 1440, height: 1000 } });
  await p.goto('file://' + path.resolve(file) + '#view=timeline'); await p.waitForTimeout(1500);
  await p.evaluate(() => { if (window.AWR_TL && AWR_TL.axLayout) AWR_TL.axLayout('span', false); });
  await p.waitForTimeout(400);
  const s = await p.evaluate(() => ['ax-cls', 'ax-ev'].map(id => document.querySelector('#' + id + ' .axsvg').innerHTML).join('\n=====\n'));
  fs.writeFileSync(out, s); await b.close();
})();
```

**Verify**: the smoke test exits 0;
`NODE_PATH=$T/node_modules node /tmp/axsnap.js /tmp/demo_before_024.html /tmp/svg_before.txt`
writes a file larger than 10 KB (`wc -c /tmp/svg_before.txt`).

### Step 2: Refactor `draw()` into reusable parts (no output change)

In `sql/lib/src/js_timeline.js`, add four functions right BEFORE
`function draw(c,force){` and make `draw` call them. Copy the bodies from
the existing lines — do not retype logic. (Line numbers here are those of
`5594f2c`; with plan 023 landed they sit about 21 lines lower. Find each
range by its quoted first line.)

a) `hlOrd(c)` — lines 505-509 (highlight state and series order):

```js
/* the highlight state and the series drawing order of chart c (re-based:
   the highlighted series first) */
function hlOrd(c){
  var P=c.P,hl=c.hl,on=null,k,ord=[];
  if(hl){on=P.classes.map(function(x,q){return !!hl.set[q]&&c.vis[q];});if(!on.some(Boolean)){hl=null;on=null;}}
  var reb=!!(hl&&hl.strong);
  for(k=0;k<P.vals.length;k++)if(c.vis[k]&&(!reb||on[k]))ord.push(k);
  if(reb)for(k=0;k<P.vals.length;k++)if(c.vis[k]&&!on[k])ord.push(k);
  return {hl:hl,on:on,reb:reb,ord:ord};
}
```

b) `colPts(c,R,X,d0,d1,reb,on)` — lines 510-517, with the refs list `R`, the
x mapping `X` and the range `[d0,d1]` as parameters, returning
`{pts:pts,mx:mx,mh:mh}`:

```js
/* the points drawn for refs R over [d0, d1] mapped by X (see draw) and the
   largest stacked total mx / highlighted total mh inside [d0, d1] */
function colPts(c,R,X,d0,d1,reb,on){
  var P=c.P,pts=[],cb=null,mx=0.05,mh=0,i,k,sm,sh,r;
  ...lines 511-517 verbatim...
  return {pts:pts,mx:mx,mh:mh};
}
```

c) `bands(c,pts,ord,on,Y)` — lines 533-546 verbatim (they use `pts`, `np`,
`lo`, `Y`, `c`, `on`, `ord`, `shade`), returning
`{fills:fills,edges:edges,hf:hf,he:he}` (NOT reversed — `draw` keeps its
`fills.reverse()` / `edges.reverse()`).

d) `flagSvg(c,list,top,ph,Wd,padL,padR)` — lines 572-588, where `list` is
an array of `{x:<px>, m:<marker>}` and the loop reads `x` from the item
instead of computing `X(PT(m.at))`; it returns the SVG string (start with
`var s='',tiers=[[],[]];` and keep every `s+=` as is; `return s;`). The
loop tests `c.flags` (flags on the first chart shown, a plain line on the
others); keep that test as it is.

Then in `draw`:
- replace lines 505-509 with `var h=hlOrd(c),hl=h.hl,on=h.on,reb=h.reb,ord=h.ord;`
- replace lines 510-517 with
  `var cp=colPts(c,refs(d0,d1),X,d0,d1,reb,on),pts=cp.pts,mx=cp.mx,mh=cp.mh;`
- replace lines 533-546 with
  `var B=bands(c,pts,ord,on,Y),fills=B.fills,edges=B.edges,hf=B.hf,he=B.he;`
  (lines 547-549 stay unchanged and keep using these names)
- replace lines 572-588 with
  `s+=flagSvg(c,mks.map(function(m){return {x:X(PT(m.at)),m:m};}),top,ph,Wd,padL,padR);`

Regenerate and compare:

```sh
node --check sql/lib/src/js_timeline.js
tools/js2plsql.sh js_timeline && python3 demo/gen_demo_report.py
NODE_PATH=$T/node_modules node /tmp/axsnap.js docs/examples/demo_busy_db.html /tmp/svg_after.txt
cmp /tmp/svg_before.txt /tmp/svg_after.txt && echo identical
```

**Verify**: `identical` is printed (the refactor changed no SVG byte);
`./lint.sh` clean; `tools/js2plsql.sh --check` exit 0. If not identical,
fix the refactor until it is — do not continue with a difference.

### Step 3: Commit the refactor

Run the smoke test on the classic and the dashboard demo (one at a time):
`NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html` → exit 0,
and the same for `docs/examples/demo_busy_db_dashboard.html` → exit 0.
`python3 demo/gen_demo_report.py --check` → three `up to date` lines (Step 2
regenerated them: the demo pages embed the generated script, so their bytes
changed even though the drawn SVG did not).
`./tools/check.sh` → `check.sh: all checks passed`.
Commit `sql/lib/src/js_timeline.js`, `sql/lib/js_timeline.plsql` and the
three `docs/examples/demo_busy_db*.html` pages together (message in "Git
workflow").

### Step 4: The mode switch in the skeleton

In `sql/00_params.sql`, in the `.axh` PUT_LINE quoted above, insert
immediately BEFORE the piece `|| '<span class="axk" aria-hidden="true">...`:

```sql
        || '<span class="seg axlayout" role="group" aria-label="Chart layout" hidden>'
        || '<button type="button" data-m="win" aria-pressed="false">Windows side by side</button>'
        || '<button type="button" data-m="span" aria-pressed="true">Full span</button></span>'
```

The help-line PUT_LINE currently reads:

```sql
    DBMS_OUTPUT.PUT_LINE('<p class="axn2">Hover for the values; drag across either chart to zoom both '
        || '(6 hours or less shows the compared windows minute by minute), double-click to reset. Click a shaded window to pin it: the Timeline grid compares against it. '
        || 'Hover a wait class or event to highlight it (a class also lights its events): from the legend it is drawn from zero with the y axis fitted to it, '
        || 'so its shape over time reads directly. Click its band, or Shift+click the legend entry, to keep it; Esc clears.</p>'
        || '</div></section>');
```

Insert these two new pieces right AFTER the piece that ends
`the Timeline grid compares against it. '` (so before the piece starting
`'Hover a wait class or event ...`):

```sql
        || 'Windows side by side shows each compared window as its own panel, oldest left, minute by minute where the 1-minute detail covers it; '
        || 'click a panel&rsquo;s top edge to pin it (Full span zooms). '
```

In `sql/_style.sql`, after the line
`    DBMS_OUTPUT.PUT_LINE('.ashx .xbk{fill:var(--ink);opacity:.06;pointer-events:none}');`
add:

```sql
    -- "Windows side by side" (js_timeline section 6, SP.mode win): the mode
    -- switch, the panel backgrounds (rect.xw.xpn, under the bands) and the
    -- window labels under the lower chart (text.xpl)
    DBMS_OUTPUT.PUT_LINE('.ashx .seg.axlayout{padding:1px}.ashx .seg.axlayout[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('.ashx .seg.axlayout button{font-size:12px;padding:2px 10px;line-height:18px}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xw.xpn{opacity:.05}.ashx .xw.xpn.cur{opacity:.1}.ashx .xw.xpn.on{opacity:.16}.ashx .xw.xpn.sk{opacity:.03}');
    DBMS_OUTPUT.PUT_LINE('.ashx .xpl.cur{fill:var(--acc-ink);font-weight:600}.ashx .xpl.sk{fill:var(--ink-4);text-decoration:line-through}');
```

Design skin (quiet / dashboard). `sql/lib/src/css_design.css` restyles
every `.seg` (padding 3px, `--chip-bg` background) and gives the
dashboard's chart tabs `.ashx .axseg{flex:none}`. The classic rule above,
`.ashx .seg.axlayout{padding:1px}`, is more specific, so it would win
there. In `css_design.css`, right after the line
`.ashx .axseg button{font-size:12px;padding:2px 10px}`, add:

```css
/* plan 024: the layout switch matches the dashboard's chart tabs */
.ashx .seg.axlayout{flex:none;padding:3px}
```

and run `tools/js2plsql.sh css_design`. (Design-only rules go in
`css_design.css`, never in `_style.sql`.)

**Verify**: `./lint.sh` clean; `grep -c 'class="seg axlayout"' sql/00_params.sql` → `1`;
`grep -c 'axlayout' sql/lib/css_design.plsql` → `1` or more;
`tools/js2plsql.sh --check` → exit 0;
`grep -nP '[^\x00-\x7F]' sql/00_params.sql sql/_style.sql sql/lib/src/css_design.css` → no output.

### Step 5: The side-by-side drawing

All in `sql/lib/src/js_timeline.js`.

a) Constants and helpers, right before `function draw(c,force){`:

```js
/* ---- "Windows side by side" (SP.mode 'win'): each compared window as its
   own panel on one shared y axis, oldest left, Current last.  A panel is
   drawn minute by minute when every minute of its window is in the
   1-minute detail (SP.F), else from the coarse buckets overlapping it.
   Panels are at least AXMP px wide, AXGAP px apart: when not all windows
   fit, the most recent that fit (the Current always).  No zoom here; a
   click on a panel's top edge pins its window.  AXDEF = the mode for a
   reader who never clicked the switch, when every window fits. */
var AXMP=24,AXGAP=6,AXDEF='span';
function winFit(pw){return Math.max(1,Math.floor((pw+AXGAP)/(AXMP+AXGAP)));}
function wSlice(i){
  var a=SP.win[i][0],b=SP.win[i][1],F=SP.F,out=[],q,g,j,j0,j1;
  if(F&&fineCov(a,b)>=b-a-1){
    for(q=0;q<F.S.length;q++){g=F.S[q];if(g[1]<=a||g[0]>=b)continue;
      j0=Math.max(0,Math.floor((a-g[0])/F.bm));j1=Math.min(Math.round((g[1]-g[0])/F.bm),Math.ceil((b-g[0])/F.bm))-1;
      for(j=j0;j<=j1;j++)out.push(-1-(g[2]+j));}
    return {r:out,fine:true};
  }
  var br=bRange(a,b);for(j=br[0];j<=br[1];j++)out.push(j);
  return {r:out,fine:false};
}
/* the panel under client x on chart c: {q: panel index, t: time} or null */
function panAt(c,cx){
  var g=c.g;if(!g||g.mode!=='win')return null;
  var r=c.svg.getBoundingClientRect(),x=(cx-r.left)*g.W/r.width;
  for(var q=0;q<g.pan.length;q++){var p=g.pan[q];if(x>=p.x0&&x<p.x0+p.w)return {q:q,t:p.a+(x-p.x0)/p.w*(p.b-p.a)};}
  return null;
}
/* the ref drawn at time t in panel q (1-minute or coarse, as the panel) */
function wRefAt(c,q,t){
  var p=c.g.pan[q];if(!p)return null;
  if(p.fine){var F=SP.F;for(var k=0;k<F.S.length;k++){var g=F.S[k];if(t>=g[0]&&t<g[1])return -1-(g[2]+Math.floor((t-g[0])/F.bm));}return null;}
  var j=bucketAt(t);return j<0?null:j;
}
```

b) `drawWin(c,o)`, also before `draw` — it reuses Step 2's helpers.
Target shape (write it out in full; strings must match the ones `draw`
uses where the comment says "as draw"):

```js
function drawWin(c,o){
  var P=c.P,Wd=o.Wd,top=o.top,ph=o.ph,padL=o.padL,padR=o.padR,pw=o.pw;
  var n=SP.win.length,K=Math.min(n,winFit(pw)),w=(pw-AXGAP*(K-1))/K,ws=wins(),cur=ws.length-1;
  var h=hlOrd(c),hl=h.hl,on=h.on,reb=h.reb,ord=h.ord,pan=[],mx=0.05,mh=0,nf=0,q;
  for(q=0;q<K;q++){
    var i=n-K+q,a=SP.win[i][0],b=SP.win[i][1],x0=padL+q*(w+AXGAP),sl=wSlice(i);
    var X=(function(x0,a,b){return function(t){return x0+w*Math.min(1,Math.max(0,(t-a)/(b-a)));};})(x0,a,b);
    var cp=colPts(c,sl.r,X,a,b,reb,on);
    if(cp.mx>mx)mx=cp.mx;if(cp.mh>mh)mh=cp.mh;if(sl.fine)nf++;
    pan.push({i:i,x0:x0,w:w,a:a,b:b,X:X,fine:sl.fine,pts:cp.pts});
  }
  SP.wk=K;SP.wf=nf;
  /* y scale, clip paths, gridlines, "AAS", open the clipped group: as draw (lines 518-524 at 5594f2c) */
  ...
  /* panel backgrounds under the bands; classes as the stripes' */
  var hit=[];
  pan.forEach(function(p){var wi=ws[p.i],cls=(p.i===cur?' cur':'')+(wi.o===PW?' on':'')+(wi.v==='N'?' sk':'');
    s+='<rect class="xw xpn'+cls+'" x="'+p.x0.toFixed(1)+'" y="'+top+'" width="'+p.w.toFixed(1)+'" height="'+ph+'"/>';
    hit.push([p.i,p.x0,p.w,cls]);});
  /* the bands, panel by panel (each panel's fills top of the stack first, as draw) */
  var F=[],E=[],HF=[],HE=[];
  pan.forEach(function(p){var B=bands(c,p.pts,ord,on,Y);F=F.concat(B.fills.reverse());E=E.concat(B.edges.reverse());HF=HF.concat(B.hf);HE=HE.concat(B.he);});
  if(!hl)s+=F.join('')+E.join('');
  else s+=(reb?'<g clip-path="url(#'+clip+'f)">':'')+'<g class="xfd" opacity="'+(reb&&ymax<mx?Math.min(hl.fade,0.07):hl.fade)+'">'+F.join('')+'</g>'+HF.join('')+HE.join('')+(reb?'</g>':'');
  /* the hidden bucket band: as draw (line 550 at 5594f2c); the caps */
  ...
  hit.forEach(function(r){s+='<rect class="xwc'+r[3]+'" x="'+r[1].toFixed(1)+'" y="'+(top-5)+'" width="'+r[2].toFixed(1)+'" height="4" rx="1"/>';});
  /* close the group and the x axis line: as draw (line 558 at 5594f2c) */
  ...
  /* window labels under the lower chart: every st-th panel counted from the Current one */
  if(o.xl){var lw=0;pan.forEach(function(p){lw=Math.max(lw,tw(ws[p.i].d));});var st=Math.max(1,Math.ceil((lw+8)/(w+AXGAP)));
    pan.forEach(function(p,q){if((K-1-q)%st)return;var wi=ws[p.i];
      s+='<text class="at xpl'+(p.i===cur?' cur':'')+(wi.v==='N'?' sk':'')+'" x="'+(p.x0+p.w/2).toFixed(1)+'" y="'+(top+ph+18)+'" text-anchor="middle">'+esc(wi.d)+'</text>';});}
  /* release markers: in the gap before the window they precede */
  var list=[];o.mks.forEach(function(m){var ib=idxOf(m.o);pan.forEach(function(p){if(p.i===ib)list.push({x:Math.max(padL,p.x0-AXGAP/2),m:m});});});
  s+=flagSvg(c,list,top,ph,Wd,padL,padR);
  /* highlight note and crosshair: as draw (lines 589-590 at 5594f2c) */
  ...
  /* hit areas: the caps only (a band in the plot keeps its highlight on a click) */
  hit.forEach(function(r){var wi=ws[r[0]];
    s+='<rect class="xwh" data-i="'+r[0]+'" data-w="'+wi.o+'" x="'+r[1].toFixed(1)+'" y="'+(top-6)+'" width="'+r[2].toFixed(1)+'" height="10" tabindex="0" role="button" aria-label="'
      +esc((wi.o===0?'Current window, ':offTxt(wi)+' window, ')+wi.t+(wi.o===0?'':'. Pin it'))+'"/>';});
  c.svg.innerHTML=s;
  c.g={mode:'win',pan:pan,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:SP.dom[0],d1:SP.dom[1],ymax:ymax,ord:ord,hk:c.hk,cm:o.cm};
}
```

c) In `draw`, right after the line `var X=function(t){return padL+pw*(t-d0)/(d1-d0);};`, add:

```js
  if(SP.mode==='win'){drawWin(c,{Wd:Wd,top:top,ph:ph,padL:padL,padR:padR,pw:pw,xl:c.xl,cm:cm,mks:mks});return;}
```

(`c.xl` / `c.flags` were set at the top of `draw` from the charts that are
shown: the last one shown gets the window labels, the first one shown gets
the release flags through `flagSvg`. So side by side also works when only
one chart is shown: plan 023's compact Summary, or the dashboard design's
"By wait class" / "By wait event" tabs. `cm` is plan 023's `var cm=cmp();`.)

and in the early return (the line starting `if(!force&&c.w===Wd&&c.lay===lay&&c.g...`;
after plan 023 it ends `...&&c.g.cm===cmp())return;c.w=Wd;c.pw=PW;c.lay=lay;`)
add `&&(c.g.mode||'span')===SP.mode` before `)return;`. At the end of
`draw`, `c.g={...}` gets `mode:'span'`.

d) `SP` literal in `spInit`: add `mode:'span',wk:0,wf:0` after `rv:null`.

e) `seriesAt(c,x,y)`: replace
`  var t=tAt(c,x);if(t<c.g.d0||t>c.g.d1)return -1;` and
`  var ref=refAt(t);if(ref==null)return -1;` with:

```js
  var ref;
  if(c.g.mode==='win'){var pq=panAt(c,x);if(!pq)return -1;ref=wRefAt(c,pq.q,pq.t);}
  else{var t=tAt(c,x);if(t<c.g.d0||t>c.g.d1)return -1;ref=refAt(t);}
  if(ref==null)return -1;
```

f) `cross(c,t,r)` becomes `cross(c,t,r,q)`:

```js
function cross(c,t,r,q){
  var hb=$('.xbk',c.svg),ch=$('.xch',c.svg);if(!c.g||!hb)return;
  var X=c.g.X,lo=c.g.padL,hi=c.g.W-c.g.padR;
  if(c.g.mode==='win'){var p=c.g.pan&&c.g.pan[q];if(!p){hideCross(c);return;}X=p.X;lo=p.x0;hi=p.x0+p.w;}
  var xa=Math.max(lo,X(rS(r))),xb=Math.min(hi,X(rE(r))),x=X(t);
  ...the two setAttribute lines unchanged...
}
```

(`c.g.X` stays as `draw` stores it in Full span, so Full span output is unchanged.)

g) `hover(c,e)`: move the point tooltip (the `tipOn(...)` statement that
spans lines 623-624) into a new function by cut and paste —
`function ptTip(c,r,e){var P=c.P;<the tipOn statement>}` placed right
before `function hover` — and call `ptTip(c,r,e);` where it was. Then,
right after the `if(wh){...return;}` block, insert:

```js
  if(c.g.mode==='win'){
    var pq=panAt(c,e.clientX),pr=pq?wRefAt(c,pq.q,pq.t):null;
    if(pr==null){hideAll();tipOff();if(HT&&HT.soft)hlSet(null);return;}
    if(!HS&&!DRAG){var pk=seriesAt(c,e.clientX,e.clientY);hlSet(pk<0?null:{c:c,k:pk,soft:true});}
    CH.forEach(function(o){cross(o,pq.t,pr,pq.q);});
    ptTip(c,pr,e);return;
  }
```

h) No brush in side-by-side: in the document `mousemove` handler in
`spInit`, right after `dg.moved=true;tipOff();hideAll();` add
`if(SP.mode==='win')return;`. In the `mouseup` handler change
`if(dg.moved){if(dg.b-dg.a>6)spZoom(...);return;}` to
`if(dg.moved){if(SP.mode!=='win'&&dg.b-dg.a>6)spZoom(tAt(dg.c,dg.a),tAt(dg.c,dg.b));return;}`.
In `mkChart`: in the mousedown handler change `DRAG=null;spReset();return;}`
to `DRAG=null;if(SP.mode!=='win')spReset();return;}`, and replace
`s.addEventListener('dblclick',spReset);` with
`s.addEventListener('dblclick',function(){if(SP.mode!=='win')spReset();});`.

i) `spHead()`: insert after its first line
(`if(!SP)return;var d0=...`):

```js
  if(SP.mode==='win'){
    if(SP.reset)SP.reset.hidden=true;
    var n=SP.win.length,K=SP.wk||n,f=SP.wf||0;
    if(SP.range)SP.range.textContent=(K===n?n+' compared windows side by side':'The '+K+' most recent of '+n+' compared windows side by side (Full span shows all)')
      +(f===K?', 1-min detail':f>0?', 1-min detail in the '+f+' most recent, '+SP.bhTxt+' in the rest':', '+SP.bhTxt);
    return;
  }
```

j) The switch and its API. Add to the public API (near `W.pinned=...`,
any top-level spot after `TL` is defined):

```js
/* the Activity charts' layout: 'win' (windows side by side) or 'span'
   (full span); persist = the reader clicked (localStorage awr-axlayout) */
TL.axLayout=function(m,persist){
  if(!SP||(m!=='win'&&m!=='span'))return;
  SP.mode=m;
  $$('#activity .axlayout [data-m]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-m')===m));});
  if(persist){try{localStorage.setItem('awr-axlayout',m);}catch(e){}}
  hideAll();tipOff();drawAll(true);
};
```

and in `spInit`, after plan 023's compact block (the one ending with
`mb.addEventListener('click', ...)` and its closing `}`), add:

```js
  var mg=$('#activity .axlayout'),sm=null,pw0=Math.max(480,CH[0].plot.clientWidth)-54;
  try{sm=localStorage.getItem('awr-axlayout');}catch(e){}
  if(mg&&SP.win.length>=2&&winFit(pw0)>=2){
    mg.hidden=false;
    SP.mode=(sm==='win'||sm==='span')?sm:(AXDEF==='win'&&SP.win.length<=winFit(pw0)?'win':'span');
    $$('[data-m]',mg).forEach(function(b){
      b.setAttribute('aria-pressed',String(b.getAttribute('data-m')===SP.mode));
      b.addEventListener('click',function(){TL.axLayout(b.getAttribute('data-m'),true);});
    });
  }
```

(54 = `padL` 40 + `padR` 14 of `draw`.)

k) Regenerate: `tools/js2plsql.sh js_timeline`. In the hand-written header
of `sql/lib/js_timeline.plsql` (above `BEGIN`): add to the "Exposes
window.AWR_TL" list a line `--   axLayout(m, persist)  'win' = windows side by side, 'span' = full span`
and to the description: `-- "Windows side by side" (SP.mode win): one panel per compared window,`
`-- shared y axis, 1-minute data where it covers the window; caps pin; no zoom.`

**Verify**:
- `node --check sql/lib/src/js_timeline.js` → no output.
- `tools/js2plsql.sh --check` → exit 0; `./lint.sh` → clean.
- `grep -nP '[^\x00-\x7F]' sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql` → no output.
- `python3 demo/gen_demo_report.py` twice → same `md5sum`; `--check` → up to date.
- Full span unchanged: `NODE_PATH=$T/node_modules node /tmp/axsnap.js docs/examples/demo_busy_db.html /tmp/svg_after2.txt && cmp /tmp/svg_before.txt /tmp/svg_after2.txt && echo identical`
  → `identical` (the snapshot tool forces Full span).

### Step 6: Guide and About text

`sql/19_reference.sql`:
- Line 69 (the guide item "Full-span activity", which starts on line 66; the piece ending
  `... to keep it, Esc clears.</span></p></div></div>');`): before
  `</span></p></div></div>` insert
  ` <b>Windows side by side</b>: the compared windows as adjacent panels on one y axis, a panel&rsquo;s top edge pins it.`
- In the About "ASH timeline" `<dd>` (lines 246-252), before
  `' ON CPU is <b>CPU</b> in both; ...`, add a piece:
  `|| ' <b>Windows side by side</b> draws each compared window as its own panel from the same data: the 1-minute series where it covers the whole window, else the coarse buckets.'`

**Verify**: `./lint.sh` clean; no line of `sql/19_reference.sql` grew past
2400 characters (`awk 'length($0) > 2400' sql/19_reference.sql | wc -l`
equals the count at `5594f2c`, which is `0`).

### Step 7: Smoke test

In `demo/verify_report.js`:

a) Line 126 (block 1, the only `removeItem` line; plan 023 added
`awr-ax` to it): add `localStorage.removeItem('awr-axlayout');` inside the
existing `try { ... }`.

b) Block 5: right after `if (inv.chart && inv.ash) {` (line 438 at
`5594f2c`) add
`await page.evaluate(() => { if (window.AWR_TL && AWR_TL.axLayout) AWR_TL.axLayout('span', false); }); await page.waitForTimeout(200);`
— every existing Activity test there is a Full-span test. (The line right
before the `if`, `if (DESIGN === 'dashboard') { ... window.AWR_axMode('both') ... }`,
is the dashboard's chart tabs, a different switch: leave it.)

c) A new block "5c" right after block 5's closing `}` (line 764 at
`5594f2c`: block 5 ends with `if (errors.length) fail('timeline: ' ...);`,
`await page.close();`, `}`) and BEFORE the existing comment
`// ---- 5b. v1.6.1 Day profile metric picker` (the label "5b" is taken; 6, 7
and 8 too). On the dashboard design, first show both charts (its tabs start
on one), so the panel counts below hold for both charts. The "is this the
demo" test must match all three demo pages:

```js
  // ---- 5c. the Activity charts' "Windows side by side" mode (plan 024):
  // panels = windows, hover + mirrored crosshair, no zoom, cap click pins,
  // legend toggle per panel, markers in the gaps, the switch remembered
  {
    const { page, errors } = await openPage('#view=timeline', 'light');
    const sb = {};
    const isDemo = /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file);
    if (DESIGN === 'dashboard') { await page.evaluate(() => window.AWR_axMode && window.AWR_axMode('both')); await page.waitForTimeout(250); }
    const can = await page.evaluate(() => !!(window.AWR_TL && AWR_TL.axLayout && document.querySelector('#activity .axlayout:not([hidden])')));
    if (!can) { sb.mode = 'unavailable'; if (isDemo) fail('side by side: mode switch missing on the demo'); }
    else {
      await page.evaluate(() => AWR_TL.axLayout('win', false)); await page.waitForTimeout(250);
      sb.panels = await page.evaluate(() => {
        const n = window.AWR_WIN.w.length, out = [];
        for (const id of ['ax-cls', 'ax-ev']) {
          const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) continue;
          const caps = s.querySelectorAll('.xwh').length, pans = s.querySelectorAll('.xw.xpn').length, cur = s.querySelectorAll('.xw.xpn.cur').length, xa = s.querySelectorAll('path.xa').length;
          out.push(id + ' ' + caps + '/' + pans + ' panels, cur ' + cur + ', ' + xa + ' paths' + (caps === pans && caps >= 2 && caps <= n && cur === 1 && xa > 0 ? '' : ' FAIL'));
        }
        const r = document.getElementById('ax-range').textContent;
        return out.join('; ') + '; range "' + r + '"' + (/side by side/.test(r) && document.getElementById('ax-reset').hidden ? '' : ' FAIL');
      });
      if (/FAIL/.test(sb.panels)) fail('side by side: ' + sb.panels);
      const cp = await page.evaluate(() => { const c = document.querySelector('#ax-cls .axsvg .xw.xpn.cur').getBoundingClientRect(); return { x: c.left + c.width / 2, y: c.top + c.height * 0.6 }; });
      await page.mouse.move(cp.x, cp.y); await page.waitForTimeout(150);
      sb.hover = await page.evaluate(() => {
        const t = document.getElementById('tip'); if (!t || t.hidden || !/AAS/.test(t.textContent)) return 'FAIL tooltip';
        const chs = [...document.querySelectorAll('.ashx .axsvg')].filter(s => s.getClientRects().length).map(s => s.querySelector('.xch'));
        const on = chs.filter(c => c && c.getAttribute('visibility') === 'visible');
        if (on.length !== chs.length) return 'FAIL crosshair on ' + on.length + '/' + chs.length;
        return new Set(on.map(c => c.getAttribute('x1'))).size === 1 ? 'ok' + (/1-min average/.test(t.textContent) ? ' (1-min)' : '') : 'FAIL crosshair x differs';
      });
      if (!/^ok/.test(sb.hover)) fail('side by side: hover ' + sb.hover);
      if (isDemo && !/1-min/.test(sb.hover)) fail('side by side: the demo has 1-minute data for every window');
      const r0 = await page.evaluate(() => document.getElementById('ax-range').textContent);
      const bb = await (await page.$('#ax-cls .axsvg')).boundingBox();
      await page.mouse.move(bb.x + bb.width * 0.3, bb.y + bb.height * 0.6); await page.mouse.down();
      await page.mouse.move(bb.x + bb.width * 0.7, bb.y + bb.height * 0.6, { steps: 6 }); await page.mouse.up(); await page.waitForTimeout(200);
      sb.noZoom = await page.evaluate((r0) => document.getElementById('ax-range').textContent === r0 && document.getElementById('ax-reset').hidden ? 'ok' : 'FAIL', r0);
      if (sb.noZoom !== 'ok') fail('side by side: a drag zoomed');
      const hw = await page.evaluate(() => { const h = [...document.querySelectorAll('#ax-cls .axsvg .xwh')].find(x => x.getAttribute('data-w') !== '0'); if (!h) return null; const r = h.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: h.getAttribute('data-w') }; });
      if (hw) {
        await page.mouse.click(hw.x, hw.y); await page.waitForTimeout(200);
        const a = await page.evaluate((w) => document.body.getAttribute('data-pw') === w && [...document.querySelectorAll('.ashx .axsvg')].filter(s => s.getClientRects().length).every(s => s.querySelector('.xw.xpn.on')), hw.w);
        await page.mouse.move(2, bb.y + bb.height + 40);
        await page.keyboard.press('Escape'); await page.waitForTimeout(150);
        const b = await page.evaluate(() => !document.body.hasAttribute('data-pw'));
        sb.pin = a && b ? 'ok' : 'FAIL ' + JSON.stringify([a, b]);
        if (sb.pin !== 'ok') fail('side by side: panel pin / Esc ' + sb.pin);
      }
      const nx = () => page.evaluate(() => document.querySelectorAll('#ax-cls .axsvg path.xa').length);
      const caps = await page.evaluate(() => document.querySelectorAll('#ax-cls .axsvg .xwh').length);
      const n0 = await nx(); await page.click('#ax-cls .axlg .axc[data-c="0"]'); await page.waitForTimeout(150);
      const n1 = await nx(); await page.click('#ax-cls .axlg .axc[data-c="0"]'); await page.mouse.move(2, bb.y + bb.height + 40); await page.waitForTimeout(150);
      const n2 = await nx();
      sb.legend = n1 === n0 - caps && n2 === n0 ? 'ok' : 'FAIL ' + [n0, n1, n2, caps].join('/');
      if (sb.legend !== 'ok') fail('side by side: legend toggle ' + sb.legend);
      sb.markers = await page.evaluate(() => (window.AWR_MARKERS || []).length ? document.querySelectorAll('#ax-cls .axsvg .cfl').length : -1);
      if (sb.markers === 0) fail('side by side: release markers missing');
      await page.click('#activity .axlayout [data-m="span"]'); await page.waitForTimeout(200);
      const s1 = await page.evaluate(() => { let v = null; try { v = localStorage.getItem('awr-axlayout'); } catch (e) {} return { v, r: document.getElementById('ax-range').textContent, n: document.querySelectorAll('#ax-cls .axsvg .xw.xpn').length }; });
      await page.click('#activity .axlayout [data-m="win"]'); await page.waitForTimeout(200);
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      const s2 = await page.evaluate(() => { let v = null; try { v = localStorage.getItem('awr-axlayout'); } catch (e) {} return { v, r: document.getElementById('ax-range').textContent }; });
      sb.persist = s1.v === 'span' && !/side by side/.test(s1.r) && s1.n === 0 && s2.v === 'win' && /side by side/.test(s2.r) ? 'ok' : 'FAIL ' + JSON.stringify([s1, s2]);
      if (sb.persist !== 'ok') fail('side by side: switch / persistence ' + sb.persist);
      await page.evaluate(() => { try { localStorage.removeItem('awr-axlayout'); } catch (e) {} });
    }
    console.log('side by side', JSON.stringify(sb));
    if (errors.length) fail('side by side: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }
```

d) In the file's header comment (lines 13-77), add a bullet:
"the Activity charts' Windows side by side mode (plan 024): one panel per
window, hover / crosshair, no zoom, cap click pins, legend, markers, the
switch remembered in awr-axlayout".

**Verify**: `node --check demo/verify_report.js` → no output; then, one at
a time:

```sh
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html /tmp/awr-shots
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db_dashboard.html /tmp/awr-shots-dash
NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db_quiet.html /tmp/awr-shots-quiet
```

→ each exits 0, its output contains `side by side {"panels":"ax-cls 13/13 panels, cur 1, ...` with no `FAIL`,
and all earlier lines still pass. On the dashboard demo the block 7 line
`Activity tabs` (one chart with its x labels and flags, or both) still
passes in the default Full span layout. The `/tmp/awr-shots/*.png`
screenshots show the default (Full span); to look at the panels, open the
demo, click "Windows side by side" in the Timeline view and check: 13
panels, the Current boxed, flags over the gaps. Look at
`/tmp/awr-shots-dash/summary-light.png`: the Activity header holds the
layout switch and the dashboard's chart tabs, wrapped neatly.

### Step 8: Many windows and overlapping windows (scratch demos, not committed)

Create `/tmp/gen_variant.py`:

```python
import sys
sys.path.insert(0, 'demo')
import awrdemo.model as m
v, out = sys.argv[1], sys.argv[2]
design = sys.argv[3] if len(sys.argv) > 3 else 'classic'
if v == '168h':
    m.WEEKS_BACK, m.STEP, m.STEP_UNIT, m.STEP_HOURS, m.WIN_HOURS = 168, 1, 'h', 1.0, 1
elif v == 'overlap':
    m.WEEKS_BACK, m.STEP, m.STEP_UNIT, m.STEP_HOURS, m.WIN_HOURS = 12, 1, 'h', 1.0, 2
import gen_demo_report as g
sys.exit(g.main(['--cdn', '--design=' + design, out]))
```

and `/tmp/sbs_check.js`:

```js
const { chromium } = require('playwright'); const path = require('path');
(async () => {
  let b; try { b = await chromium.launch(); } catch (e) { b = await chromium.launch({ channel: 'chrome' }); }
  const p = await b.newPage({ viewport: { width: 1440, height: 1000 } }); const errs = [];
  p.on('pageerror', e => errs.push(e.message));
  await p.goto('file://' + path.resolve(process.argv[2]) + '#view=timeline'); await p.waitForTimeout(1500);
  const r = await p.evaluate(() => {
    const def = (document.querySelector('#activity .axlayout [aria-pressed="true"]') || {}).getAttribute ? document.querySelector('#activity .axlayout [aria-pressed="true"]').getAttribute('data-m') : 'none';
    AWR_TL.axLayout('win', false);
    return new Promise(res => setTimeout(() => res({ def, n: AWR_WIN.w.length,
      caps: document.querySelectorAll('#ax-cls .axsvg .xwh').length, cur: document.querySelectorAll('#ax-cls .axsvg .xwh[data-w="0"]').length,
      paths: document.querySelectorAll('#ax-cls .axsvg path.xa').length, range: document.getElementById('ax-range').textContent }), 300));
  });
  console.log(JSON.stringify(r), 'errors', errs.length, errs.slice(0, 3).join(' | ')); await b.close();
})();
```

Run:

```sh
python3 /tmp/gen_variant.py 168h /tmp/demo_168h.html
python3 /tmp/gen_variant.py overlap /tmp/demo_overlap.html
python3 /tmp/gen_variant.py 168h /tmp/demo_168h_dash.html dashboard
NODE_PATH=$T/node_modules node /tmp/sbs_check.js /tmp/demo_168h.html
NODE_PATH=$T/node_modules node /tmp/sbs_check.js /tmp/demo_overlap.html
NODE_PATH=$T/node_modules node /tmp/sbs_check.js /tmp/demo_168h_dash.html
git status --short   # the repository must be unchanged by this step
```

**Verify**:
- 168h: `def` is `"span"` (169 windows do not fit), `n` 169, `caps` between
  2 and 168, `cur` 1, `paths` > 0, `range` contains `most recent of 169`,
  `errors 0`.
- overlap: `def` is `"span"` (the default, `AXDEF='span'`), `n` 13, `caps` 13, `cur` 1, `paths` > 0,
  `range` contains `13 compared windows side by side`, `errors 0`.
- 168h, dashboard design: the same as 168h (the dashboard shows the class
  chart only, which is the one `sbs_check.js` reads), `errors 0`.
- `git status --short` shows no change made by this step.
If `gen_variant.py` itself raises inside the demo model (not in your code),
report it and skip this step (the model patching is documented in
`CLAUDE.md` as tested for 168 hourly and "2 h every 1 h", but it is not part
of CI).

### Step 9: Documentation

- `CHANGELOG.md`, `## Unreleased` (line 8) → `### Report` (line 120 at
  `5594f2c`): "**Activity charts:
  Windows side by side.** A switch above the charts shows the compared
  windows as adjacent panels on one y axis (minute by minute where the
  1-minute data covers the window), the Current one last and highlighted,
  release markers between the panels; hover, legend, highlight and pin work
  as before, zoom stays in Full span. Full span stays the default; the
  reader's choice is remembered. Works
  in all three designs, next to the dashboard's chart tabs."
- `CLAUDE.md`, section "Activity, whole span": add a paragraph
  "**Windows side by side (plan 024)**: `SP.mode` `'win'` / `'span'`,
  `span.seg.axlayout` in `.axh` (hidden when fewer than 2 windows or panels
  would be narrower than `AXMP`), `AWR_TL.axLayout(m, persist)`, localStorage
  `awr-axlayout` written on a click only, default `AXDEF` (`'span'`; `'win'`
  would apply the fit rule). `drawWin` draws one panel per window (`rect.xw.xpn` + `cur` / `on` /
  `sk` under the bands, caps `.xwc`, hit `.xwh` on the caps only, labels
  `text.xpl` on the lower chart) from `wSlice(i)`: the 1-minute refs when
  `fineCov` covers the whole window, else `bRange`; `colPts` / `bands` /
  `flagSvg` / `hlOrd` are shared with Full span (`draw`); `c.g.mode`,
  `c.g.pan`; `panAt` / `wRefAt` / `cross(c,t,r,q)` map the pointer; no brush,
  no Reset. Too many windows: the most recent `winFit(pw)` panels. Labels /
  flags follow `c.xl` / `c.flags` (the last / first chart SHOWN), so it
  works with one chart hidden (compact Summary, the dashboard's tabs).
  Not to be confused with the dashboard's `window.AWR_axMode` (which
  chart is shown)."
  Also mention the new functions in the `js_timeline.plsql` header line
  you added in Step 5k.
- `CLAUDE.md`, section "Report designs", in the dashboard bullet after
  "Activity `.axseg` (cls / ev / both ...": add "(plan 024's layout switch
  `.seg.axlayout` sits in the same `.axh` row; `css_design.css` gives it
  the `.axseg` look)".

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- Step 2's byte comparison proves the refactor changed no Full span output;
  Step 5's second comparison proves the new mode leaves Full span intact.
- `demo/verify_report.js` block "5c" (Step 7) covers panels, the 1-minute
  hover, the mirrored crosshair, no zoom, the cap pin and Esc, the legend
  toggle per panel, the release markers, and the persisted switch. Existing
  section-5 tests run forced into Full span and must all still pass.
- Step 8 covers 169 windows (cropping, default Full span) and
  overlapping windows on throwaway demo variants, plus 169 windows in the
  dashboard design.
- The dashboard demo's block 7 ("Activity tabs") proves side by side keeps
  the one-chart contract: labels on the last chart shown, flags on the first.
- Visual: `/tmp/awr-shots/*-light.png` / `*-dark.png` show the default (Full
  span, unchanged); the side-by-side panels are checked by hand after a click
  on the switch, plus the dashboard screenshots.

## Done criteria

- [ ] `./tools/check.sh` → `check.sh: all checks passed`
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `cmp /tmp/svg_before.txt /tmp/svg_after2.txt` → identical (Full span unchanged)
- [ ] `demo/verify_report.js` exits 0 on `demo_busy_db.html`, `demo_busy_db_dashboard.html` and `demo_busy_db_quiet.html` (one at a time) and prints a `side by side` line with no `FAIL`
- [ ] `python3 demo/gen_demo_report.py --check` → three `up to date` lines
- [ ] Step 8 outputs match the expectations (or the step is reported as skipped with the reason)
- [ ] `grep -nP '[^\x00-\x7F]' sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/00_params.sql sql/_style.sql sql/lib/src/css_design.css sql/lib/css_design.plsql sql/19_reference.sql` → no output
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Plan 023 has not landed, or `5594f2c` is not in the branch (see the drift
  check).
- On the dashboard demo, block 7's "Activity tabs" check fails in side by
  side (labels or flags on the wrong chart). Report it; do not touch
  `js_design.js` or verify_report's block 7.
- Step 2 cannot be made byte-identical after two attempts (the refactor
  would then change Full span; report the first differing SVG fragment).
- An existing section-5 Activity test fails after Step 5 (Full span must
  not change).
- The pin, highlight or Esc logic seems to need changes outside
  `js_timeline.js` (for example in `sql/00_params.sql`'s chrome JS).
- You find yourself changing `sql/09_ash_timeline.sql` or the payload.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Owner decisions** (decided 2026-11-19): (1) the default mode is Full span
  (`AXDEF='span'`; `'win'` would make side by side the default when every
  window fits); (2) skipped windows are drawn with data and marked grey
  (consistent with Full span, where ASH data under a skipped stripe is drawn
  too), not empty;
  (3) no zoom in side-by-side mode. A possible follow-up: a double-click on a
  panel switches to Full span zoomed to that window. (4) In the dashboard
  design the Activity header holds two segmented controls, this layout
  switch and the dashboard's "By wait class / By wait event / Both" tabs.
  Merging them into one control would be a design change in `js_design.js`
  and is not part of this plan.
- Plan 036 (direct labels on the bands) builds on `bands()` / `drawWin()`
  from this plan.
- Reviewers: check that `cross()` / `seriesAt()` / `hover()` behave
  identically in Full span (the byte comparison covers drawing, not
  interaction — the unchanged section-5 tests cover interaction), that the
  side-by-side hit rects are only the caps (so a click on a band still keeps
  its highlight), and that `localStorage` access is wrapped in `try`.
- Long windows (for example `win_hours=24`, daily): a panel then holds 1440
  minutes; `colPts` keeps one point per pixel column at its busiest minute,
  as Full span does.
- **Needs an owner DB run** (the executor has no database): on dbmint
  (`ssh -p 2200 oracle@dbmint`, never 2201; rsync without `--delete`, as in
  `CLAUDE.md`). dbmint keeps only 35 days of AWR, so the September dates
  of older plans are gone. Probe for a restart-free stretch first
  (`CLAUDE.md`, "dbmint keeps 35 days of AWR"); on 2026-11-19 that was
  2026-11-07 14:45 to 2026-11-09 16:15. Run, e.g.,
  `./run_awr_trend.sh '/ as sysdba' "2026-11-08 15:00" 1 8 10 0 1 h` (once
  more with `DESIGN=dashboard`), an `AUTO` weekly 1/4, and 168 hourly
  windows: rc 0, 29/29 `AWR-SECTION` pairs, `ORA-` hits only in captured
  SQL text; `demo/verify_report.js` on each report (one at a time); look at
  the side-by-side panels on the real data (dbmint is idle: expect thin
  panels; the 168-hourly run must default to Full span and crop to the most
  recent windows when switched).
