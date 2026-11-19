# Plan 025: Findings triage list, folded secondary cards, quieter card charts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/07_summary.sql sql/18_sqlmon.sql sql/00_params.sql sql/_style.sql sql/lib/src/js_wingrid.js sql/lib/js_wingrid.plsql sql/lib/wingrid.plsql sql/lib/src/js_design.js sql/lib/js_design.plsql sql/lib/src/css_design.css sql/lib/css_design.plsql demo/awrdemo/sections/s07_summary.py demo/awrdemo/sections/s18_sqlmon.py demo/verify_report.js`
> Plans 020, 021 and 022 are executed BEFORE this one and edit several of
> these files (020 adds `data-impact` / `data-share` to the `<article` line
> of `emit_card`; 022 rewrites the Findings heading counts). So the drift
> check WILL list changes. Compare only the excerpts quoted under "Current
> state": each must still be present (020 / 022 additions inside them are
> expected). An excerpt that is gone or restructured is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/020-*.md (rank finding cards by impact; emits `data-impact` / `data-share` on every finding card)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: 07, 18, js_wingrid and the
  twins are unchanged; `sql/00_params.sql` and `sql/_style.sql` line numbers
  moved (+12 / +7, refreshed below). New since `ee23e49`: the `design`
  option (classic / quiet / dashboard). The **dashboard** design already
  turns the findings into its own expandable table (`sql/lib/src/js_design.js`
  `findTable()`), so this plan now also hides `#triage` and unfolds the cards
  in that design (new Step 7b) and makes its browser checks design-aware
  (Step 9). The quiet / dashboard stylesheet already shows card priors on
  hover only; Step 6 brings that to classic. verify_report's `cards` line
  changed (`#findings article.fc:not(.chg)`, line 849) and block 7 (the
  design checks) was added. The demo writes three pages now.

## Why this matters

The report's Summary view shows one large "finding card" per finding.
Each card is about 600 px tall (headline, big value, a 13-window bar chart
with a number printed over every bar and a labelled release flag over
every chart, evidence rows, a related-metrics fold). On the demo report
four cards take 2.5 screens, so a reader never sees all findings at once
and cannot compare them. This plan adds a compact **triage list** (one
row per finding, all on one screen, ranked in card order), **folds** every
card except the most important one to a two-line header (one click opens
it), and makes the card charts **quieter**: prior-window values appear on
hover only, and only the release marker that sits right before the
Current window keeps its label. Nothing is removed: every number is still
in the card (when opened) and in the All sections view.

Since this plan was first written, `design=dashboard` shipped its own
answer to the same problem (an expandable findings table, see "Report
designs" below). This plan is for the default `classic` design and for
`quiet` (same layout); in `dashboard` it only steps aside (Step 7b).

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript line by line with `DBMS_OUTPUT.PUT_LINE('...')`. Client
  JavaScript written in a section is therefore **inside PL/SQL string
  literals** (a single quote is written `''`).
- `sql/07_summary.sql` emits the Findings section: in the **Summary** view
  one `article.fc` card per finding inside `div.cards.vw.in-s`; in the
  **All sections** view per-domain tables. Views are CSS classes: an
  element with `class="vw in-s"` shows only in Summary, `vw in-a` only in
  All sections (lint check 19 requires every `<section id=` to carry
  `class="vw `). With JavaScript off no body class is set and everything
  shows, stacked.
- `demo/` is a docs-only Python twin that renders
  `docs/examples/demo_busy_db.html` without a database. Every markup change
  in a `sql/NN_*.sql` file must be re-ported in its twin
  (`demo/awrdemo/sections/sNN_*.py`) and the demo regenerated in the same
  commit; `./tools/check.sh` fails when the committed demo is stale.
  Twins may lift literal-only `PUT_LINE`s from the SQL with
  `chrome.put_lines(chrome.sql_path("sql/NN_x.sql"))` (see
  `demo/awrdemo/sections/s17_narrative.py:470-475` for the pattern).
- `sql/lib/js_wingrid.plsql` is GENERATED from `sql/lib/src/js_wingrid.js`
  by `tools/js2plsql.sh js_wingrid`. Edit the `.js`, then regenerate; never
  hand-edit the `.plsql` body (lint check 24 compares them).

The card loop, `sql/07_summary.sql:940-944`:

```sql
    IF v_order.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div class="cards vw in-s">');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_card(v_order(k), k);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
```

followed (lines 946-959) by a `DECLARE ... BEGIN ... END;` block that
prints the rail sub-link `<script>`. `v_order` holds the card groups
(`'IO'`, `'DBTIME'`, `'NET'`, `'COMMIT'`, `'WAIT:<class>'`, ...) in card
order; after plan 020 the order is by impact.

The card header and the headline inside `PROCEDURE emit_card`
(`sql/07_summary.sql:337-458`), lines 420-433 at the planned commit
(plan 020 adds attributes to the first line; that is expected):

```sql
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h">'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span></div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg') || band_axis || '</div></header>');
        DBMS_OUTPUT.PUT_LINE('<h3 id="' || v_id || '-h">' || f_ent(r) || ' '
            || move_txt(r.cur_val, r.prior_mean, v_sev)
            || CASE WHEN r.metric_name = 'DB time' THEN
                   CASE v_split WHEN 'W' THEN ', all of it wait' WHEN 'w' THEN ', mostly wait'
                                WHEN 'c' THEN ', mostly CPU' WHEN 'm' THEN ', CPU and wait alike' END END
            || '</h3>');
```

`v_split` is computed at the top of `emit_card` (lines 359-362):

```sql
        IF p_g = 'DBTIME' AND v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
            v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                  v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
        END IF;
```

The card chart, line 439:

```sql
        DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
            || wg_bars(r.wv, v_s, r.prior_mean, r.prior_sd, v_sev) || wg_dates(TRUE) || '</div></div>');
```

The same chart class on the plan-change card, `sql/18_sqlmon.sql:903`:

```sql
            DBMS_OUTPUT.PUT_LINE('<div class="wg bare allv"' || wg_attr || '>' || wg_flags(TRUE)
```

What the `.wg` modifiers do (`sql/_style.sql:1267-1270`):

```sql
    DBMS_OUTPUT.PUT_LINE('body.js-wg .wg:not(.allv) .c:not(.cur) .v:not(.nil){opacity:0}');
    DBMS_OUTPUT.PUT_LINE('.wg.allv.tight .c:not(.cur) .v:not(.nil){opacity:0}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.hc,.wg .h.hc{background-image:linear-gradient(var(--hov),var(--hov))}');
    DBMS_OUTPUT.PUT_LINE('.wg .c.hc .v{opacity:1!important}');
```

`allv` = print every prior value; without it the prior values are hidden
while JS runs (`body.js-wg`), and `hov` makes a hovered column's cells
get `.hc`, which shows that column's value (`sql/lib/src/js_wingrid.js`,
"hover a column", handler on `.wg.hov [data-w]`). The Summary hero strip
already works this way: `sql/08_overview.sql:120` uses
`'<div class="panel strip" id="s-strip"><div class="wg fit hov"'`.

Release flags: `wg_flags(TRUE)` prints an empty
`<div class="r fr t2"><div class="flags"></div></div>` (40 px tall,
`sql/_style.sql:1236`), and `layoutFlags(wg)` in
`sql/lib/src/js_wingrid.js:60-81` writes every release marker's label
into it (two tiers). Separately `markCols(wg)` (lines 55-57) adds `.mk` to
the columns on a marker boundary, which draws a thin vertical line
through the bars and dates (`sql/_style.sql:1218` and `:1245`). Each
marker has `o` = the week_offset of the window whose LEFT edge it sits
on; `o === 0` is a marker between the last prior window and Current.
Excerpt of `layoutFlags`:

```js
function layoutFlags(wg){
  $$(".flags",wg).forEach(function(fl){
    if(!shown(fl))return;fl.innerHTML="";
    var base=fl.getBoundingClientRect().left,width=fl.clientWidth,TH=17,tiers=[[],[]],narrow=width<520;
    W.markers().forEach(function(m){
      var ref=$$('[data-w="'+m.o+'"]',wg).filter(function(e){return !e.closest(".flags");})[0];if(!ref)return;
```

`W.render(scope)` (lines 89-94) sizes bars and lays out flags under any
element; a hidden flags row is skipped (`shown(fl)`), so a chart that
becomes visible later must be re-rendered.

The chrome's `reveal(el)` (`sql/00_params.sql:1063-1076`) opens whatever
hides a link target (a library row, a tab, folded table rows, every
ancestor `<details>`). Its first lines:

```sql
    DBMS_OUTPUT.PUT_LINE('function reveal(el){');
    DBMS_OUTPUT.PUT_LINE('  if(window.AWR_TL&&AWR_TL.reveal) AWR_TL.reveal(el);');
    DBMS_OUTPUT.PUT_LINE('  var ls=closest(el,"main > section.lib"); if(ls&&curView()==="summary"&&!ls.classList.contains("lopen")) libOpen(ls,true);');
```

`closest(t,sel)` is `t.closest(sel)` (it includes `t` itself). Every
in-page `a[href^="#"]` click goes through a delegated handler that calls
`goTo(target)` -> `reveal(target)` -> `scrollIntoView`
(`sql/00_params.sql:1089-1101`). That handler and `reveal` live inside
00's `DOMContentLoaded` block; the section scripts this plan adds run
earlier, while the page parses.

Micro strips: any element with `data-spark="v1,v2,...,vCur"` (oldest
first, Current last, empty token = no value) and optional
`data-spark-title` is drawn as a 13-bar `svg.mw` at `DOMContentLoaded`
by `sql/lib/js_microstrip.plsql` (source `sql/lib/src/js_microstrip.js`,
"render()"). `wg_csv(pairs, scale)` in `sql/lib/wingrid.plsql` produces
exactly that CSV from a card's `r.wv`.

Plan 020's contract (already merged when you start): every `article.fc`
finding card carries `data-impact="<delta AAS, '.' decimal, 3 decimals,
empty when the card has no time measure>"` and `data-share="<integer
percent of the DB-time rise, empty when n/a>"`. The DB time card's share
is the total (100). Card ids: `card_id('IO')` = `f-io`,
`card_id('DBTIME')` = `f-dbtime`, `card_id('NET')` = `f-net`, ...

**Report designs (since `5594f2c`).** The report has a `design`
substitution variable: `classic` (default), `quiet`, `dashboard`. It is
presentation only. `classic` adds nothing. `quiet` and `dashboard` add a
stylesheet in `<head>` (`sql/lib/css_design.plsql`, GENERATED from
`sql/lib/src/css_design.css`) and a script before `</body>`
(`sql/lib/js_design.plsql`, GENERATED from `sql/lib/src/js_design.js`;
`window.AWR_DESIGN` holds the name). Both are generated by
`tools/js2plsql.sh` (`tools/js2plsql.sh js_design`,
`tools/js2plsql.sh css_design`; a `.css` source is wrapped in `<style>`).
The design script's `DOMContentLoaded` handler is the LAST one of the page,
so it runs after 07's inline scripts (which run while the page parses) and
after the chrome. Rule from the project: never put design rules in
`sql/_style.sql` or design markup in a section; design-specific behaviour
goes into these two source files.

What the **dashboard** design does to the Findings section
(`js_design.js`, `kpis()` and `findTable()`; its layout rules are all under
`body.d-dash`, which the script sets after building, so with JS off the
dashboard looks like quiet):

- `kpis()` (line 212) builds one KPI card per finding card:
  `$$("#findings .cards > article.fc").forEach(function(card){`.
- `findTable()` (from line 247) inserts `div.dgrid` into `#findings` right
  before `div.cards`, with tabs Moved / Normal / Improved. It MOVES every
  finding card into the body of a `details.drow.lead` row of its own table
  (lines 263-264):

  ```js
    cards.forEach(function(card){
      var fam=famOf(card),det=detailOf(card),sev=sevOf(card),lead=$("h3 a.ent",card);
  ```

  where `cards=cw?$$(":scope > article.fc",cw):[]` and `cw` is
  `#findings > .cards`. Inside a row the card's header is hidden
  (`sql/lib/src/css_design.css` line 339: `.drow .fc > .fc-h,.drow .fc .big{display:none}`),
  so a FOLDED card in a row would show only its h3, and its "Show card"
  button (in `.fc-h`) would be invisible.
- `sql/lib/src/css_design.css` line 247 hides what the table replaces:

  ```css
  body.d-dash.vs main > #overview,body.d-dash.vs #findings > .cards{display:none}
  ```

- verify_report's block 7 (dashboard only) opens the first `details.drow.lead`
  and requires `article.fc .wg` inside it to be visible.

So the dashboard is already a triage list. In the dashboard design this
plan's `#triage` list must be hidden and every card must start unfolded
(Step 7b). Classic and quiet get the full plan.

The quiet / dashboard stylesheet already hides card priors until hover
(`css_design.css` line 169,
`body.js-wg .wg.allv .c:not(.cur) .v:not(.nil){opacity:0}`) and draws the
release flags without boxes. Step 6 makes the card charts quiet in every
design; that rule then no longer matches the cards (it still matches 12's
configuration card) and stays as is.

Other new sections that link into cards (all through the chrome's
`goTo()` -> `reveal()`, so Step 5's `reveal()` line covers them): section
27's instance map (`<a href="#f-<group>">` per flagged area, and
`AWR_goTo(card, true, true)` on a click).

Repo rules that apply to every edit here (each has bitten before):

- **Never type a tilde character** in any `sql/` file or in
  `sql/lib/src/*.js`, not even in a comment: every section runs under
  `SET DEFINE '~'` and a stray one prompts for input and truncates the
  output. `./lint.sh` (check 3) and `tools/js2plsql.sh` reject it.
- **Emitted text must be pure ASCII** (lint check 25): HTML entities in
  markup (`&middot;`, `&rarr;`), `\uXXXX` escapes in JS. Agent tool input
  can silently turn a typed backslash-u sequence into the character itself;
  if you need one, write that line from a small script and check with
  `grep -nP '[^\x00-\x7F]' <file>` (must print nothing). This plan's code
  needs no backslash-u escape.
- A `PUT_LINE('...')` source line must stay under 2499 characters
  (`awk 'length($0) > 2400' sql/07_summary.sql` must print nothing new).
- PL/SQL declaration order (lint check 14): in a `DECLARE` section nothing
  that looks like a variable may follow a `FUNCTION`/`PROCEDURE` or an
  `@@sql/lib/*.plsql` include. New plain variables go with the existing
  ones (before line 116's `@@sql/lib/metric_policy.plsql`).
- User-visible names go through `DBMS_XMLGEN.CONVERT` (`f_label(r)` already
  does).
- Never hand-write `class="ent"` (lint check 21); this plan adds no entity
  link.
- `sql/_style.sql` is also included by the fleet report's chrome: new rules
  must use selectors that only exist in the single-DB report (`#triage`,
  `.fc-...`, `.wg.qf`).
- The report has no global link colour: a plain `<a>` without a rule renders
  browser-blue (verify_report fails on it). The new `a.tri-go` gets a rule.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate client JS | `tools/js2plsql.sh js_wingrid` | exit 0, `sql/lib/js_wingrid.plsql` rewritten |
| Regenerate the design script / stylesheet | `tools/js2plsql.sh js_design` and `tools/js2plsql.sh css_design` | exit 0, `sql/lib/js_design.plsql` / `sql/lib/css_design.plsql` rewritten |
| Generated JS fresh | `tools/js2plsql.sh --check` | exit 0 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three lines `wrote ...docs/examples/demo_busy_db.html`, `..._quiet.html`, `..._dashboard.html` |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | exit 0 (covers all three pages) |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test, classic | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html` | last line `verify: OK` (about 3 minutes; never run two at once) |
| Browser smoke test, dashboard | the same with `docs/examples/demo_busy_db_dashboard.html` (after the classic run has finished) | last line `verify: OK`; its `design dashboard: {...}` line has `"rows":"ok"` |
| ASCII | `grep -nP '[^\x00-\x7F]' sql/07_summary.sql sql/18_sqlmon.sql sql/00_params.sql sql/_style.sql sql/lib/src/js_wingrid.js sql/lib/js_wingrid.plsql sql/lib/src/js_design.js sql/lib/src/css_design.css` | no output |

There is no database available to you. The owner's database checks are
listed under "Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/07_summary.sql` (triage list, fold attribute and header pieces, quiet chart class, inline script)
- `sql/18_sqlmon.sql` (line 903: the plan card chart class only)
- `sql/00_params.sql` (`reveal()`: one added line)
- `sql/_style.sql` (new CSS lines after the `.fc` block)
- `sql/lib/src/js_wingrid.js` and the regenerated `sql/lib/js_wingrid.plsql`
- `sql/lib/wingrid.plsql` (header comment only: the `qf` modifier)
- `sql/lib/src/js_design.js`, `sql/lib/src/css_design.css` and the
  regenerated `sql/lib/js_design.plsql`, `sql/lib/css_design.plsql`
  (Step 7b: the dashboard design only)
- `demo/awrdemo/sections/s07_summary.py`, `demo/awrdemo/sections/s18_sqlmon.py`
- `demo/verify_report.js` (new checks in block 6)
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated, never hand-edited)
- `CHANGELOG.md`, `CLAUDE.md` (documentation)

**Out of scope** (do NOT touch):
- Card order, impact computation, the verdict (`sql/00_params.sql`'s
  hero) and the Findings heading counts — plans 020 / 021 / 022.
- The dashboard's own findings table, KPI cards and tabs (`js_design.js`
  `findTable()` / `kpis()` / `drow()`) beyond the two lines of Step 7b.
- The visualization sections `sql/20_*.sql` .. `sql/28_*.sql`.
- Pattern tags: this plan only creates the EMPTY containers
  `span.tri-tags` and `span.fc-tags`; plan 027 fills them.
- `sql/12_param_changes.sql`'s configuration card (its step-row values are
  the point of that card) and `sql/08_overview.sql`'s hero strip (it keeps
  every release label: it is the one place they are all named).
- The All sections view: no change there (the triage list and the cards
  are Summary-only).
- `sql/fleet/*`, `awr_fleet_extract.sql`, `run_awr_fleet.sh`.

## Git workflow

- Branch: `advisor/025-findings-triage-list` from `main`.
- Conventional commits with scope, e.g.
  `feat(report): findings triage list, folded secondary cards, quieter card charts`.
- Do NOT push or open a PR unless the operator instructed it.

## Target UI (Summary view, inside "Findings")

```
 4 findings  (heading, as plan 022 leaves it)
 +---------------------------------------------------------------------------+
 | Finding                        Now . normal       Share of DB-time rise  13 windows |
 | * DB time  DB time up 79.7%, mostly wait   20.35 AAS     [==========] +9.03 AAS total  |||||||#
 |            [tags: plan 027]                normal 8.38-14.3 AAS                       |
 | * Physical I/O  Physical reads 5.4x normal 22.24 k/s     [=======   ] +6.31 AAS 70%    ......#
 | * Network  Network waits 5.2x normal       1.175 AAS     [=         ] +0.948 AAS 10%   ......#
 | * Commit  Commit waits up 22.5%            0.8687 AAS    [          ] +0.160 AAS 2%    |||||||#
 +---------------------------------------------------------------------------+
 [ DB time card       -- folded: kicker "Large  20.35 AAS . normal ..." + band + h3, [Show card] ]
 [ Physical I/O card  -- OPEN (the first card that is not DB time), full content              ]
 [ Network card       -- folded ]
 [ Commit card        -- folded ]
```

- One row per card, in card order; the card name links to the card; a
  click anywhere on the row opens and scrolls to the card.
- The impact column is filled by a script from the card's `data-impact`
  / `data-share` (plan 020); DB time says "total"; a card without a time
  measure says "no time measure".
- Every card except ONE starts folded: the one that stays open is the first
  card in card order that is not the DB time card (the verdict and the
  DB-time breakdown already carry DB time); when DB time is the only card
  it stays open. A folded card shows its header (severity, value and normal
  range, band without its axis) and its headline; a "Show card" button
  (and a click anywhere on the folded card that is not a link) opens it;
  "Fold" folds it again. A link or rail sub-link to a folded card opens it.
- JavaScript off: no folding, no impact numbers (the list still shows
  name, headline, value, normal range).
- Card charts (finding cards and the plan-change card): prior values only
  on hover; release labels only for the marker right before the Current
  window (lines for the others stay).

A rendered sketch of the direction (not a pixel spec; the report's own
tokens win) is `plans/assets/ux-mockup-2026-11-17.html`, outline 6.

## Steps

### Step 1: Factor the card headline tail into one function

In `sql/07_summary.sql`, directly ABOVE `PROCEDURE emit_card` (line 337,
after the comment block at 334-336), add:

```sql
    -- the card headline after the metric name: "5.4x normal", "up 79.7%,
    -- mostly wait" (the DB time lead adds where the extra time went).
    -- Shared by the card's h3 and its triage row (plan 025).
    FUNCTION head_txt(r finding_rec) RETURN VARCHAR2 IS
        v_split VARCHAR2(1);
    BEGIN
        IF r.metric_name = 'DB time' AND v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
            v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                  v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
        END IF;
        RETURN move_txt(r.cur_val, r.prior_mean, r.change_bucket)
            || CASE v_split WHEN 'W' THEN ', all of it wait' WHEN 'w' THEN ', mostly wait'
                            WHEN 'c' THEN ', mostly CPU' WHEN 'm' THEN ', CPU and wait alike' END;
    END head_txt;
```

Then in `emit_card` replace the h3 statement (the `'<h3 id="' || v_id`
statement quoted above) with:

```sql
        DBMS_OUTPUT.PUT_LINE('<h3 id="' || v_id || '-h">' || f_ent(r) || ' '
            || head_txt(r) || '</h3>');
```

Leave `v_split` and its computation in `emit_card` in place: the CPU
evidence row still uses it ("; the rise is wait").

This step must not change the output. In `emit_card`, `v_sev` is
`r.change_bucket`, and only a DB time lead (`r.metric_name = 'DB time'`)
ever got the suffix, exactly as in `head_txt`.

**Verify**: `./lint.sh` → clean. Then
`python3 demo/gen_demo_report.py --check` → exit 0 (the demo twin is not
changed yet and the SQL change is output-neutral; this only proves the
demo still matches the committed file, which it must at this point).

### Step 2: Mark the cards that start folded, add the folded-header pieces

1. In the outer `DECLARE` of `sql/07_summary.sql`, next to `v_meta`
   (line 115, before the `@@sql/lib/metric_policy.plsql` include), add:

   ```sql
       v_open_g     VARCHAR2(64);   -- plan 025: the one card that starts open (Summary)
   ```

2. Right AFTER the `FOR k IN 3 .. v_order.COUNT LOOP ... END LOOP;` block
   that moves the DB time card (lines 823-830; it ends before the comment
   "Card evidence: the top 2 foreground events"), add:

   ```sql
       -- plan 025: in the Summary view every card but one starts folded; the
       -- open one is the first card that is not DB time (the verdict and its
       -- DB-time breakdown already say what DB time did), else the only card
       FOR k IN 1 .. v_order.COUNT LOOP
           IF v_order(k) <> 'DBTIME' THEN
               v_open_g := v_order(k);
               EXIT;
           END IF;
       END LOOP;
       IF v_open_g IS NULL AND v_order.COUNT > 0 THEN
           v_open_g := v_order(1);
       END IF;
   ```

3. In `emit_card`, change the `<article` statement so that (a) a card other
   than `v_open_g` carries `data-fold="Y"`, and (b) the header kicker
   `div.fc-k` gets two more children after `span.sv`: the folded one-liner
   `span.fc-sum` (Current value and normal range, hidden by CSS unless the
   card is folded) and the empty tag container `span.fc-tags` (plan 027
   fills it). Keep every attribute plan 020 added. The result must read
   (020's attributes shown as `...020...`; keep them exactly where 020 put
   them):

   ```sql
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h"'
            || ...020...
            || CASE WHEN p_g <> v_open_g THEN ' data-fold="Y"' END || '>'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span>'
            || '<span class="fc-sum">' || fv(r.cur_val * v_s, v_u) || ' &middot; normal '
            || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</span>'
            || '<span class="fc-tags"></span></div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg') || band_axis || '</div></header>');
   ```

   If 020 wrote its attributes in a different place of this statement, keep
   020's text unchanged and insert only the `data-fold` CASE before the
   `'>'` that closes the `<article` tag, and the two spans before the
   `</div>` that closes `div.fc-k`.

**Verify**: `./lint.sh` → clean.
`grep -c 'data-fold="Y"' sql/07_summary.sql` → `1`.
`grep -c 'class="fc-tags"' sql/07_summary.sql` → `1`.

### Step 3: Emit the triage list

1. Directly AFTER `END emit_card;` (line 458), add:

   ```sql
       -- One row of the Summary triage list (plan 025): severity, card name
       -- (a link to the card), the headline, Current value and normal range,
       -- an empty impact cell that the inline script after the cards fills
       -- from the card's data-impact / data-share (plan 020), the lead
       -- metric's windows as a micro strip (js_microstrip), and the empty
       -- span.tri-tags that plan 027 fills.
       PROCEDURE emit_tri_row(p_g VARCHAR2) IS
           r    finding_rec  := v_findings(v_glead(p_g));
           v_s  NUMBER       := metric_scale(r.metric_domain, r.metric_name);
           v_u  VARCHAR2(20) := metric_unit(r.metric_domain, r.metric_name);
           v_id VARCHAR2(80) := card_id(p_g);
       BEGIN
           DBMS_OUTPUT.PUT_LINE('<div class="tri-row" role="listitem" data-card="' || v_id || '">'
               || '<span class="tri-f"><i class="dotk ' || r.change_bucket || '" aria-hidden="true"></i>'
               || '<a class="tri-go" href="#' || v_id || '">' || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '</a>'
               || '<span class="tri-m">' || f_label(r) || ' ' || head_txt(r) || '</span>'
               || '<span class="tri-tags"></span></span>'
               || '<span class="tri-nv"><b>' || fv(r.cur_val * v_s, v_u) || '</b><small>normal '
               || fv_range(r.prior_mean * v_s, r.prior_sd * v_s, v_u) || '</small></span>'
               || '<span class="tri-imp"></span>'
               || '<span class="tri-spark" data-spark="' || wg_csv(r.wv, v_s)
               || '" data-spark-title="' || f_label(r) || '"></span></div>');
       END emit_tri_row;
   ```

2. In the main block, change the card loop (lines 940-944) to print the
   triage list first:

   ```sql
    IF v_order.COUNT > 0 THEN
        -- plan 025: the triage list (Summary): every finding on one screen
        DBMS_OUTPUT.PUT_LINE('<div id="triage" class="panel tri vw in-s" role="list" aria-label="Findings in card order">'
            || '<div class="tri-hd" aria-hidden="true"><span>Finding</span><span>Now &middot; normal</span>'
            || '<span>Share of the DB-time rise</span><span>' || TO_CHAR(v_weeks_back + 1) || ' windows</span></div>');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_tri_row(v_order(k));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
        DBMS_OUTPUT.PUT_LINE('<div class="cards vw in-s">');
        FOR k IN 1 .. v_order.COUNT LOOP
            emit_card(v_order(k), k);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
   ```

**Verify**: `./lint.sh` → clean. `grep -c 'PROCEDURE emit_tri_row' sql/07_summary.sql` → `1`.

### Step 4: The inline script (impact cells, row clicks, folding)

Directly AFTER the rail sub-link block (the `DECLARE v_js ... END;` that
ends at line 959, still inside `IF v_order.COUNT > 0 THEN`), add the
following eight `PUT_LINE`s. They must be **literal-only** (no PL/SQL
variable concatenated in) so the demo twin can lift them verbatim. Copy
them exactly; they contain no single quote and no tilde.

```sql
        -- plan 025: fill the triage list's impact cells from each card's
        -- data-impact / data-share (plan 020), make a row click open its
        -- card, and fold every card that carries data-fold (Summary; with
        -- JavaScript off nothing is folded).  window.AWR_fcOpen(card) is
        -- what the chrome's reveal() calls for a link into a folded card.
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,tri=d.getElementById("triage");');
        DBMS_OUTPUT.PUT_LINE('function n2(v){var a=Math.abs(v);return (v<0?"-":"+")+(a>=10?a.toFixed(1):a>=1?a.toFixed(2):a.toFixed(3));}');
        DBMS_OUTPUT.PUT_LINE('if(tri)tri.querySelectorAll(".tri-row[data-card]").forEach(function(r){var id=r.getAttribute("data-card"),c=d.getElementById(id),x=r.querySelector(".tri-imp");if(!c||!x)return;var im=c.getAttribute("data-impact"),sh=c.getAttribute("data-share");if(im===null||im===""){x.innerHTML="<small>no time measure</small>";return;}var v=+im,s=(sh===null||sh==="")?null:+sh,tot=id==="f-dbtime",w=tot?100:Math.max(0,Math.min(100,s||0));x.innerHTML="<i class=\"tri-bar\"><i style=\"width:"+w+"%\"></i></i><small><b>"+n2(v)+" AAS</b> "+(tot?"total":(s===null?"":s+"%"))+"</small>";});');
        DBMS_OUTPUT.PUT_LINE('if(tri)tri.addEventListener("click",function(ev){var r=ev.target.closest(".tri-row");if(!r||ev.target.closest("a"))return;var a=r.querySelector("a.tri-go");if(a)a.click();});');
        DBMS_OUTPUT.PUT_LINE('function setF(c,on){c.classList.toggle("fold",on);var b=c.querySelector(".fc-tg");if(b){b.setAttribute("aria-expanded",on?"false":"true");b.textContent=on?"Show card":"Fold";}if(!on&&window.AWR_WG)setTimeout(function(){AWR_WG.render(c);},20);}');
        DBMS_OUTPUT.PUT_LINE('window.AWR_fcOpen=function(c){if(c&&c.classList.contains("fold"))setF(c,false);};');
        DBMS_OUTPUT.PUT_LINE('d.querySelectorAll("#findings .cards > article.fc[data-fold]").forEach(function(c){var k=c.querySelector(".fc-h .fc-k");if(!k)return;var b=d.createElement("button");b.type="button";b.className="fc-tg";k.appendChild(b);b.addEventListener("click",function(ev){ev.stopPropagation();setF(c,!c.classList.contains("fold"));});c.addEventListener("click",function(ev){if(c.classList.contains("fold")&&!ev.target.closest("a,button"))setF(c,false);});setF(c,true);});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
```

Notes: the backslash-quote sequences (`\"`) are plain characters inside a
PL/SQL literal and become escaped quotes inside the JavaScript string;
type them exactly. `window.AWR_WG` is defined by the prologue
(`js_wingrid`), before `<main>`, so it exists when this script runs.

**Verify**: `./lint.sh` → clean.
`awk 'length($0) > 2400' sql/07_summary.sql | wc -l` → `0`.
`grep -c "window.AWR_fcOpen" sql/07_summary.sql` → `1`.

### Step 5: Let `reveal()` open a folded card

In `sql/00_params.sql`, inside `function reveal(el){`, add one line right
after the `AWR_TL.reveal` line (line 1064):

```sql
    DBMS_OUTPUT.PUT_LINE('  var fc=closest(el,"article.fc.fold"); if(fc&&window.AWR_fcOpen) window.AWR_fcOpen(fc);');
```

This makes every in-page link, rail sub-link, verdict link and `#hash`
into a folded card (or into anything inside it) open the card first.

**Verify**: `./lint.sh` → clean. `grep -c 'article.fc.fold' sql/00_params.sql` → `1`.

### Step 6: Quiet card charts

1. `sql/07_summary.sql` line 439: replace `'<div class="wg bare allv"'`
   with `'<div class="wg bare hov qf"'`.
2. `sql/18_sqlmon.sql` line 903: the same replacement.
3. `sql/lib/src/js_wingrid.js`, function `layoutFlags(wg)`: add a `quiet`
   flag and skip every marker that is not on the Current window's left
   edge. The function must read:

   ```js
   function layoutFlags(wg){
     var quiet=wg.classList.contains("qf");
     $$(".flags",wg).forEach(function(fl){
       if(!shown(fl))return;fl.innerHTML="";
       var base=fl.getBoundingClientRect().left,width=fl.clientWidth,TH=17,tiers=[[],[]],narrow=width<520;
       W.markers().forEach(function(m){
         if(quiet&&m.o!==0)return;
         var ref=$$('[data-w="'+m.o+'"]',wg).filter(function(e){return !e.closest(".flags");})[0];if(!ref)return;
   ```

   (Only the two new lines change; the rest of the function stays.) Also
   extend the comment above the function: "`.qf` (quiet flags, the card
   charts): only the marker on the Current window's left edge is labelled;
   the others keep their column line (markCols)."
4. Regenerate: `tools/js2plsql.sh js_wingrid`.
5. In the header comment of `sql/lib/wingrid.plsql` (line 12), extend the
   modifier list: `<div class="wg [bare] [fit] [allv] [hov] [qf]" ...>` and
   add one comment line: `--   "qf" = quiet flags: only the marker before Current is labelled (card charts).`
   (Comment only; no tilde.)

**Verify**: `tools/js2plsql.sh --check` → exit 0.
`grep -c 'wg bare allv' sql/07_summary.sql sql/18_sqlmon.sql` → `0` for both.
`grep -c 'quiet&&m.o!==0' sql/lib/js_wingrid.plsql` → `1`.

### Step 7: CSS

In `sql/_style.sql`, directly after the line
`DBMS_OUTPUT.PUT_LINE('.fc .cfg-more{margin:0;padding:var(--s2) 0 0;font-size:12.5px;color:var(--muted)}');`
(line 1368), add:

```sql
    -- plan 025: the Summary triage list (07, #triage), folded finding cards
    -- (.fc.fold, toggled by 07's inline script) and quiet card charts (.wg.qf)
    DBMS_OUTPUT.PUT_LINE('#triage{padding:var(--s2) 0;margin:0 0 var(--s5)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-hd,#triage .tri-row{display:grid;grid-template-columns:minmax(0,1fr) 180px 176px 96px;gap:4px var(--s5);align-items:center;padding:8px var(--s6)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-hd{font-size:12px;color:var(--muted);border-bottom:1px solid var(--line-soft)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-row{border-top:1px solid var(--line-soft);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-hd + .tri-row{border-top:0}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-row:hover{background:var(--hov)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-f{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;min-width:0}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-go{font-weight:600;color:var(--ink);text-decoration:none}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-go:hover{text-decoration:underline}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-m{color:var(--ink-soft);font-size:13.5px}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-tags{display:flex;flex-wrap:wrap;gap:4px;flex-basis:100%} #triage .tri-tags:empty{display:none}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-nv{display:flex;flex-direction:column;line-height:1.35;font-size:13px;color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-nv small{color:var(--muted);font-size:12px}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-imp{display:flex;flex-direction:column;gap:3px;font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-imp b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-bar{display:block;height:6px;border-radius:3px;background:var(--track)}');
    DBMS_OUTPUT.PUT_LINE('#triage .tri-bar > i{display:block;height:100%;border-radius:3px;background:var(--mean)}');
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 900px){#triage .tri-hd{display:none}#triage .tri-row{grid-template-columns:minmax(0,1fr) 140px}#triage .tri-imp,#triage .tri-spark{display:none}}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-sum{font-weight:400;color:var(--ink-soft)} .fc:not(.fold) .fc-sum{display:none}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-tags{display:inline-flex;flex-wrap:wrap;gap:4px} .fc .fc-tags:empty{display:none}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-tg{font:inherit;font-size:12px;color:var(--ink-soft);background:var(--panel);border:1px solid var(--hairline);border-radius:6px;padding:1px 8px;cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-tg:hover{color:var(--ink);border-color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.fc.fold{padding-bottom:var(--s4);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('.fc.fold > .fc-b,.fc.fold > .rel,.fc.fold > .fc-f,.fc.fold .fc-band .bd-ax{display:none}');
    DBMS_OUTPUT.PUT_LINE('.fc.fold h3,.fc.lead.fold h3,.fc.slim.fold h3{font-size:16px;margin-top:4px}');
    DBMS_OUTPUT.PUT_LINE('.wg.bare.qf .fr.t2{height:22px}');
```

All tokens used (`--s2`, `--s4`, `--s5`, `--s6`, `--muted`, `--ink`,
`--ink-soft`, `--line-soft`, `--hov`, `--track`, `--mean`, `--panel`,
`--hairline`) already exist in `sql/_style.sql`.

**Verify**: `./lint.sh` → clean.
`grep -nP '[^\x00-\x7F]' sql/_style.sql` → no output.

### Step 7b: The dashboard design keeps its own table

The dashboard design (see "Report designs" under Current state) already
lists every finding in an expandable table and moves each card into a
row. There the triage list would be a second list of the same rows, and a
folded card inside a row would show only its h3. So, in the dashboard
design only: hide `#triage`, and open every card the table moves.

1. `sql/lib/src/css_design.css`, line 247. Replace

   ```css
   body.d-dash.vs main > #overview,body.d-dash.vs #findings > .cards{display:none}
   ```

   with

   ```css
   body.d-dash.vs main > #overview,body.d-dash.vs #findings > .cards,body.d-dash.vs #findings > #triage{display:none}
   ```

   (`#triage` is a direct child of `section#findings`, like `div.cards`.)
2. `sql/lib/src/js_design.js`, function `findTable()`, lines 263-264.
   Replace

   ```js
     cards.forEach(function(card){
       var fam=famOf(card),det=detailOf(card),sev=sevOf(card),lead=$("h3 a.ent",card);
   ```

   with

   ```js
     cards.forEach(function(card){
       /* plan 025: a card folded by 07's script opens: the row is the fold */
       if(window.AWR_fcOpen)AWR_fcOpen(card);
       var fam=famOf(card),det=detailOf(card),sev=sevOf(card),lead=$("h3 a.ent",card);
   ```

   `window.AWR_fcOpen` is defined by 07's inline script (Step 4), which runs
   while the page parses, so it exists when this `DOMContentLoaded` handler
   runs; on an older report it is undefined and the line does nothing.
3. Regenerate: `tools/js2plsql.sh css_design` and `tools/js2plsql.sh js_design`.

Classic and quiet are not affected (`body.d-dash` is set only by the
dashboard script). With JS off the dashboard looks like quiet: the list
shows and no card is folded (folding needs the script).

**Verify**: `tools/js2plsql.sh --check` → exit 0.
`grep -c 'findings > #triage' sql/lib/css_design.plsql` → `1`.
`grep -c 'AWR_fcOpen' sql/lib/js_design.plsql` → `1` or more.
`grep -nP '[^\x00-\x7F]' sql/lib/src/js_design.js sql/lib/src/css_design.css` → no output.

### Step 8: Re-port the demo twins

1. `demo/awrdemo/sections/s07_summary.py`:
   - Add a module-level `def _head_txt(r, dbt, cpu)` mirroring Step 1
     (`h.move_txt(r.cur, r.mu, r.bucket)` plus `_SPLIT_CARD.get(split, "")`
     when `r.name == "DB time"` and both `dbt` and `cpu` exist, with
     `split = h.time_split(dbt.cur, dbt.mu, cpu.cur, cpu.mu)`), and use it
     in `_card` for the h3 (line ~316) so the output is unchanged.
   - In `emit`, after `order = h.card_order(...)`, compute
     `open_g = next((g for g in order if g != "DBTIME"), order[0] if order else None)`
     and pass it to `_card` (new parameter). In `_card`'s `<article` string
     add `' data-fold="Y"'` when `g != open_g`, in exactly the place Step 2
     put it relative to plan 020's attributes, and add the two header spans
     (`'<span class="fc-sum">' + h.fv(h._mul(r.cur, s), u) + ' &middot; normal ' + h.fv_range(h._mul(r.mu, s), h._mul(r.sd, s), u) + '</span><span class="fc-tags"></span>'`).
   - Replace `'<div class="wg bare allv"'` with `'<div class="wg bare hov qf"'`.
   - Before `out.append('<div class="cards vw in-s">')` append the triage
     list exactly like Step 3 (header row with `str(w.weeks_back + 1)`, one
     row per `g` in `order`, `h.wg_csv(w, r.vals, s)` for `data-spark`,
     `h.esc(h.card_label(g))` for the link text, and
     `h.esc(h.metric_label(r.domain, r.name))` for the metric label — the
     same label `_f_ent` (line 227) uses, the twin of the SQL's `f_label`;
     `r = lead[g]`, `s, u = h.metric_scale(...), h.metric_unit(...)` as in
     `_card`).
   - After the rail sub-link `<script>` append, lift the Step 4 script
     verbatim from the SQL with the anchor pattern of
     `s17_narrative.py:470-475`: start at the `put_lines` entry whose text
     starts with `'<script>(function(){var d=document,tri=d.getElementById("triage");'`,
     end at the first following entry whose text is `'})();</script>'`,
     assert every entry in the range is literal (`ok` is True).
2. `demo/awrdemo/sections/s18_sqlmon.py` line ~236: `'<div class="wg bare allv"'` → `'<div class="wg bare hov qf"'`.
3. Regenerate: `python3 demo/gen_demo_report.py` (it writes the three
   design pages); run it a second time and compare
   `md5sum docs/examples/demo_busy_db*.html` (all three must be identical
   between the two runs). The quiet and dashboard pages are the same
   sections plus the design stylesheet and script, so no twin change is
   needed for them beyond the regenerated `js_design.plsql` /
   `css_design.plsql`, which the generator reads.

**Verify**: `python3 demo/gen_demo_report.py --check` → exit 0.
`grep -c 'id="triage"' docs/examples/demo_busy_db_dashboard.html` → `1`
(the markup is there; the dashboard hides it with CSS).
`grep -o 'class="tri-row"' docs/examples/demo_busy_db.html | wc -l` → equal to
`grep -o '<article class="panel fc f-' docs/examples/demo_busy_db.html | wc -l`
(the finding cards; plan-change and configuration cards are
`class="panel fc chg"` and do not match). On the demo at the planned
commit that is 4.
`grep -o 'data-fold="Y"' docs/examples/demo_busy_db.html | wc -l` → that number minus 1 (3 on the demo).
`grep -o 'wg bare allv' docs/examples/demo_busy_db.html | wc -l` → `0`.

### Step 9: Extend the browser smoke test

In `demo/verify_report.js`, block 6 ("phase 4 (v1.6.0)"), inside the
`page.evaluate` callback, right AFTER the line
`out.subsOk = subs.length === cards.length && ...;` (line 851; the `cards` line above it now reads `const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];`, which already excludes plan-change cards) and BEFORE
`window.AWR_setView('all', false);`, add:

```js
      // plan 025: the triage list (one row per card, in card order, with a
      // micro strip and a filled impact cell), every card but one folded, a
      // row click opens its card, quiet card charts.  The dashboard design
      // has its own findings table: there #triage is hidden and no card is
      // folded (js_design opens each card it moves into a row).
      const dash = document.body.classList.contains('d-dash');
      const tri = document.getElementById('triage');
      const trows = tri ? [...tri.querySelectorAll('.tri-row[data-card]')] : [];
      out.triage = trows.length + '/' + cards.length + (dash ? ' (dashboard)' : '');
      out.triageOk = trows.length === cards.length
        && trows.every((r, i) => r.getAttribute('data-card') === cards[i].id
          && (dash || (r.querySelector('.tri-spark svg.mw') && r.querySelector('.tri-imp').textContent.trim() !== '')))
        && (dash ? !vis(tri) : !!tri && vis(tri));
      const folded = cards.filter(c => c.classList.contains('fold'));
      out.folded = folded.length;
      out.foldOk = dash ? folded.length === 0 : (cards.length < 2 || folded.length === cards.length - 1);
      if (folded.length && !dash) {
        const fr = trows.find(r => r.getAttribute('data-card') === folded[0].id);
        if (fr) fr.click();
        await wait(350);
        out.unfold = !folded[0].classList.contains('fold') && vis(folded[0].querySelector('.fc-b')) ? 'ok' : 'FAIL ' + folded[0].id;
      } else out.unfold = 'none';
      const open = cards.find(c => !c.classList.contains('fold'));
      const pv = open ? open.querySelector('.wg .c:not(.cur) .v:not(.nil)') : null;
      out.quietV = !pv || getComputedStyle(pv).opacity === '0';
      out.quietFlags = cards.every(c => c.querySelectorAll('.wg.qf .flags .flag').length <= 1);
```

and, next to the other `fail(...)` lines after the evaluate (after
`if (!p4.subsOk) ...`), add:

```js
    if (!p4.triageOk) fail('triage list: ' + p4.triage + ' rows (expected one per card, in card order, micro strip + impact cell)');
    if (!p4.foldOk) fail('folded cards: ' + p4.folded + ' start folded (expected all but one)');
    if (/^FAIL/.test(p4.unfold)) fail('a triage row click did not open its card: ' + p4.unfold);
    if (!p4.quietV) fail('card chart: a prior value is visible without hover');
    if (!p4.quietFlags) fail('card charts: more than one release label on a card');
```

Also add one line to the header comment's "phase 4" bullet: "the triage
list (one row per card), all but one card folded, a row click opens its
card, card charts show prior values on hover only and one release label".

**Verify**: run the classic browser smoke test from the Commands table →
`verify: OK`; the `phase 4` JSON line it prints shows
`"triageOk":true`, `"foldOk":true`, `"unfold":"ok"`, `"quietV":true`,
`"quietFlags":true`. Then (never two at once) the dashboard smoke test →
`verify: OK`; its `phase 4` line shows `"triageOk":true`, `"folded":0`,
`"unfold":"none"`, and its `design dashboard:` line shows `"rows":"ok"`
(block 7 opens the first findings row and needs the card's chart visible:
it fails if Step 7b did not unfold the cards).

### Step 10: Documentation

1. `CHANGELOG.md`, under `## Unreleased` → `### Report`, add a bullet:
   "**Findings at a glance.** The Summary view lists every finding in one
   triage list (value, normal range, share of the DB-time rise, 13-window
   strip) above the cards; every card but the most important one starts
   folded (a click, a link or the list opens it); card charts print prior
   values on hover only and name only the release right before the
   Current window."
2. `CLAUDE.md`, section "Summary view pieces (v1.6.0)": add a table row
   `| Triage list `#triage` | 07 | one `div.tri-row[data-card]` per card, in card order; impact cell filled by 07's inline script from the card's `data-impact` / `data-share` (plan 020); empty `span.tri-tags` (plan 027) |`
   and a paragraph after the table: cards other than the first non-DB-time
   card carry `data-fold="Y"`; 07's inline script folds them (`.fold`, a
   `button.fc-tg`), `window.AWR_fcOpen(card)` opens one and `reveal()`
   calls it, so every link into a folded card opens it; the header carries
   `span.fc-sum` (shown only folded) and the empty `span.fc-tags`
   (plan 027). In the "Window component" paragraph add `.qf` (quiet flags:
   only the marker on the Current window's left edge is labelled; finding
   and plan-change cards) and note that the card charts now use
   `bare hov qf` instead of `allv`. In "Report designs", the dashboard
   bullet: the dashboard hides `#triage` (`css_design.css`) and
   `findTable()` calls `window.AWR_fcOpen(card)` on every card it moves
   into a row (a row is the fold).

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- No unit-test framework covers the SQL; the checks are: `./lint.sh`,
  `tools/js2plsql.sh --check`, the demo regeneration (deterministic, two
  runs same md5) and the browser smoke test extended in Step 9 (triage
  rows = cards, in order, micro strip + impact text; folded count; row
  click unfolds; prior values hidden; at most one flag label per card), run
  on the classic and the dashboard demo pages (one at a time).
- Manually (optional, recommended): open `docs/examples/demo_busy_db.html`
  in a browser, Summary view, light and dark theme: the list is readable,
  no browser-blue link, a folded card opens from the list, from its "Show
  card" button, from the rail sub-link and from a click on its body; the
  open card's chart shows a value when you hover a column. Then
  `demo_busy_db_quiet.html` (the list in the quiet skin, the kicker's new
  spans next to the severity pill) and `demo_busy_db_dashboard.html` (no
  triage list; every findings row opens to a full card; the instance map
  in the evidence library, clicked on a flagged area, lands on an open
  card in all three pages).

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `python3 demo/gen_demo_report.py --check` exits 0, and two generator runs give the same md5
- [ ] `./tools/check.sh` prints `check.sh: all checks passed`
- [ ] `demo/verify_report.js` ends with `verify: OK` on `docs/examples/demo_busy_db.html` AND (run after it) on `docs/examples/demo_busy_db_dashboard.html`, with the five new checks present
- [ ] `grep -c 'wg bare allv' sql/07_summary.sql sql/18_sqlmon.sql docs/examples/demo_busy_db.html` → 0 for each
- [ ] `grep -nP '[^\x00-\x7F]'` over every modified `sql/` file, `sql/lib/src/js_wingrid.js`, `sql/lib/src/js_design.js` and `sql/lib/src/css_design.css` prints nothing
- [ ] `git status` shows only the in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `grep -c 'data-impact' sql/07_summary.sql` is `0`: plan 020 has not landed
  (this plan depends on it).
- The excerpts under "Current state" are not found (beyond plan 020 / 022
  additions inside them), e.g. `emit_card` no longer prints the
  `<article` and `<h3` statements, or `v_order` no longer exists.
- Step 1 changes the demo output (the `--check` in Step 1's Verify fails):
  the factoring was not output-neutral.
- `demo/verify_report.js` fails in a block this plan did not touch (e.g.
  entity links in block 4) and the failure is caused by the folding: report
  which link and why instead of weakening the check.
- The fold makes a card chart render empty after opening (bars of height 0)
  and `AWR_WG.render(card)` does not fix it.
- `sql/lib/src/js_design.js` no longer has the `cards.forEach(function(card){`
  loop in `findTable()`, or `css_design.css` no longer has the
  `#findings > .cards{display:none}` rule quoted in Step 7b (the dashboard
  design changed shape).
- The dashboard smoke test fails in block 7 (`dashboard: row expansion`,
  `KPI cards`, `findings table`) after Step 7b.
- A fix seems to require editing an out-of-scope file.

## Maintenance notes

- **Ordering and impact belong to plan 020.** The triage list follows
  `v_order` and reads `data-impact` / `data-share`; if 020's attribute names
  change, the inline script's two `getAttribute` calls must follow.
- **Plan 026** may move a plan-change card next to the card it explains,
  inside `#findings .cards`. Such a card has no `data-fold` and is not a
  finding. It keeps its class `chg`, so verify_report's `cards`
  (`#findings article.fc:not(.chg)`) already excludes it; any other DOM
  count of finding cards (plan 022, `js_design.js`) must exclude `.chg` too.
- **Plan 027** fills `span.tri-tags` and `span.fc-tags`; their CSS hides them
  while empty. In the dashboard design `#triage` is hidden and a card's
  header (`.fc-h`, holding `span.fc-tags`) is hidden inside its findings
  row, so tags need their own place there (027's concern).
- **Designs.** Classic is the default design and gets this plan in full;
  quiet shares classic's layout. The dashboard keeps its own findings
  table; if that table changes (`findTable()`), keep Step 7b's
  `AWR_fcOpen` call on every moved card.
- **Plan 032** folds "Checked and normal" with the same reveal idea; keep the
  two `reveal()` additions next to each other.
- The rule "open = first card that is not DB time" is a judgment call; the
  owner may prefer "open every large card". It is one PL/SQL loop (Step 2.2)
  and one Python line in the twin.
- Reviewer focus: the `<article` statement (020's and 025's attributes
  together), the literal-only script (no single quote, no tilde), the
  `reveal()` line, and that All sections is unchanged (`allFull` check).
- **Needs owner DB run** (the executor has no database). On dbmint (`ssh -p
  2200 oracle@dbmint`, never port 2201; rsync without `--delete`). dbmint
  keeps 35 days of AWR, so the September dates used earlier are gone:
  probe first and pin inside a restart-free stretch (on 2026-11-19 that was
  2026-11-07 14:45 to 2026-11-09 16:15). E.g. the heavy hour
  `./run_awr_trend.sh <connect> "2026-11-08 15:00" 1 8 10 0 1 h` (positionals: target_end win_hours weeks_back top_n inst_num step step_unit) with classic and
  again with `DESIGN=dashboard`, plus one quiet window with 0 or 1
  findings: rc 0, 29/29 `AWR-SECTION` BEGIN/END pairs (sections 20-28
  added nine), no `ORA-`/`SP2-` outside captured SQL text; then
  `demo/verify_report.js` on each report (one at a time): `verify: OK`. On
  a quiet report with 0 or 1 finding cards the triage list has 0 or 1 rows
  and nothing is folded.
