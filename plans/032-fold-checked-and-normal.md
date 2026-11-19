# Plan 032: "Checked and normal" folds to one summary line in the Summary view

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/07_summary.sql sql/00_params.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/js_design.plsql sql/lib/src/css_design.css sql/lib/css_design.plsql demo/awrdemo/sections/s07_summary.py demo/verify_report.js`
> Plans 020-026 are executed before this one and edit some of these files
> (025 adds a line to `reveal()` in `sql/00_params.sql`, CSS after the
> `.fc` block and checks in `demo/verify_report.js` block 6). Those changes
> are expected. Compare only the excerpts quoted under "Current state":
> each must still be present. An excerpt that is gone or restructured is a
> STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/025-findings-triage-list-and-folded-cards.md (same files, same `reveal()` area; execute after it)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: 07 and its twin are
  unchanged; `sql/00_params.sql` / `sql/_style.sql` line numbers moved
  (+12 / +7, refreshed). New: the `design` option. The **dashboard**
  design moves `#s-normal` into a "Normal" tab of its findings table (and
  its "Improved" panel into an "Improved" tab), so there the fold would be
  a second click behind the tab: new Step 3b opens the fold and hides its
  summary line in that design. Step 5's checks are design-aware; the demo
  writes three pages.

## Why this matters

The Summary view ends its story with "Checked and normal": a grid of up to
18 metric tiles that did NOT move, plus two lists ("Moved, too small to
matter", "Improved"). On the demo report this takes a full screen —
as much space as the actual findings — although its message is one
sentence: "everything else was checked and is normal". This plan keeps the
section and its heading but folds its body into one summary line (counts
of normal / too-small / improved metrics) that opens in place on a click.
When the report has no finding at all, the section stays open: then it IS
the story. Nothing is removed (every row is still there when opened, and in
All sections' Findings tables).

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts: PL/SQL blocks print HTML
  with `DBMS_OUTPUT.PUT_LINE('...')`.
- `sql/07_summary.sql` prints `section#s-normal` ("Checked and normal"),
  class `vw in-s sumsec`: Summary view only. It is linked from the verdict
  pills ("N metrics normal", "N improved" → `#s-normal`, emitted by
  `sql/00_params.sql:1369-1372`) and from the rail
  (`sql/00_params.sql:483`, `<a href="#s-normal" data-nodot>Checked and normal</a>`).
- Every in-page link click goes through the chrome's `goTo(el)` which calls
  `reveal(el)` (`sql/00_params.sql:1063-1076`) to open whatever hides the
  target. `reveal` opens every ANCESTOR `<details>` of the target and the
  target itself when it is a `<details>`; it does not open a `<details>`
  INSIDE a target section — the `#about` section has a special case for
  exactly that, line 1073:

  ```sql
    DBMS_OUTPUT.PUT_LINE('  if(el.id==="about"){ var ab=el.querySelector("details"); if(ab) ab.open=true; }');
  ```

- `demo/awrdemo/sections/s07_summary.py` is the hand-ported Python twin of
  07 that renders `docs/examples/demo_busy_db.html`; every markup change
  must be ported there and the demo regenerated (`./tools/check.sh` fails
  on a stale demo).

The section, `sql/07_summary.sql:994-1066` (abridged; `f` and the
collection `v_findings` / `v_table_idx` are declared by the outer block;
`v_normal` counts canonical rows whose bucket is typical / improved /
noted / flat baseline; `v_order.COUNT` is the number of finding cards):

```sql
    DECLARE
        v_grid  PLS_INTEGER := 0;
        v_more  PLS_INTEGER := 0;
        v_small VARCHAR2(32767);
        v_ns    PLS_INTEGER := 0;
        v_imp   VARCHAR2(32767);
        v_ni    PLS_INTEGER := 0;
        v_first VARCHAR2(16);
    BEGIN
        DBMS_OUTPUT.PUT_LINE('<section id="s-normal" class="vw in-s sumsec"><h2>Checked and normal'
            || '<span class="meta"><span><i class="dotk typical"></i>' || v_normal || ' normal</span></span>'
            || '<small class="h2sub">Every other scored metric, against the same prior windows</small></h2>');
        IF v_normal = 0 THEN
            DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><p class="calm-empty">'
                || 'Nothing could be scored as normal: a metric needs at least 3 valid prior windows.'
                || '</p></div>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><div class="ngrid">');
            -- the calm grid: typical within 2 sigma (loudest first), then flat baselines
            FOR pass IN 1 .. 2 LOOP
                ... nr_row(f) for canonical typical |z| <= 2 (pass 1) and flat baseline (pass 2),
                    at most 18, the rest counted in v_more ...
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('</div>'
                || CASE WHEN v_more > 0 THEN '<p class="calm-more">and ' || v_more || ' more normal row' ... END
                || '</div>');
            FOR p IN 1 .. v_table_idx.COUNT LOOP
                ... canonical: typical |z| > 2 or noted -> v_small / v_ns;  improved -> v_imp / v_ni ...
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('<div class="calm-notes">'
                || '<div class="panel note"><h3 ...>Moved, too small to matter</h3>' ...
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="panel note improved"><h3 ...>'
                ...
                || '</div></div>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('</section>');
    END;
```

The three groups are disjoint and together are exactly `v_normal`:
grid rows (typical with |z| <= 2, plus flat baseline), "too small"
(typical with |z| > 2, plus noted), "improved". On the demo: 25 + 5 + 0 = 30.

An existing fold to imitate visually: the cards' related-metrics fold,
`sql/_style.sql:1344-1349` (`.fc .rel > summary` with a CSS chevron).

**Report designs (since `5594f2c`).** The report has a `design`
substitution variable: `classic` (default), `quiet`, `dashboard`;
presentation only. `quiet` / `dashboard` add a stylesheet
(`sql/lib/css_design.plsql`, GENERATED from `sql/lib/src/css_design.css`)
and a script (`sql/lib/js_design.plsql`, GENERATED from
`sql/lib/src/js_design.js`; regenerate with `tools/js2plsql.sh css_design`
/ `tools/js2plsql.sh js_design`). The script's `DOMContentLoaded` handler
is the page's last. Project rule: design-specific rules and behaviour go
into these two source files, never into `sql/_style.sql` or a section.
Classic and quiet share one layout, so this plan applies to them as
written. The **dashboard** design's `findTable()` moves `#s-normal` into
the "Normal" tab of its findings table, `sql/lib/src/js_design.js` lines
287-289:

```js
  var sn=$("#s-normal"),imp=sn&&$(".panel.note.improved",sn);
  if(sn){var nn=(txt($("h2 .meta",sn)).match(/\d+/)||[null])[0];var pN=tab("normal","Normal",nn,false);pN.appendChild(sn);}
  if(imp){var pI=tab("improved","Improved",$$(".nr",imp).length,false);pI.appendChild(imp);}
```

It reads the count from the heading's `span.meta` (unchanged by this
plan) and moves the "Improved" panel into its own tab
(`querySelector` finds it inside the new `<details>` too). The tab hides
the section's h2 (`sql/lib/src/css_design.css` line 297,
`.dpanel #s-normal > h2{display:none}`). A tab is already a fold: inside
it, a closed `<details>` would hide the grid behind a second click, and
its summary line would repeat the tab counts. So in the dashboard the fold
must start open and its summary line must not show (Step 3b).
verify_report block 7 (dashboard only) clicks the Normal tab and needs
`#s-normal` visible, and `AWR_goTo(#s-normal)` must switch to that tab.

Repo rules that apply here:

- **Never type a tilde** in any `sql/` file, not even in a comment (lint 3).
- **Emitted text pure ASCII** (lint 25): use `&middot;`, not the character.
- `PUT_LINE` source lines under 2499 characters.
- Plain variables of the nested block go at the top of its `DECLARE`
  (no subprogram there; lint 14 concerns the outer block but keep the habit).
- `sql/_style.sql` is also included by the fleet chrome: scope new rules
  under `#s-normal` (single-DB only).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate the design script / stylesheet | `tools/js2plsql.sh js_design` and `tools/js2plsql.sh css_design` | exit 0 |
| Generated files fresh | `tools/js2plsql.sh --check` | exit 0 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote ...` lines: `demo_busy_db.html`, `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | exit 0 (covers the three pages) |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same for `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` each (about 3 min each; one at a time, never in parallel) |
| ASCII | `grep -nP '[^\x00-\x7F]' sql/07_summary.sql sql/00_params.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css` | no output |

No database is available to you; owner checks are in "Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/07_summary.sql` (the `#s-normal` block only)
- `sql/00_params.sql` (`reveal()`: one added line)
- `sql/_style.sql` (new CSS lines)
- `demo/awrdemo/sections/s07_summary.py`
- `demo/verify_report.js` (block 6)
- `sql/lib/src/js_design.js`, `sql/lib/src/css_design.css` and the
  regenerated `sql/lib/js_design.plsql`, `sql/lib/css_design.plsql`
  (Step 3b: the dashboard design only)
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated)
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope** (do NOT touch):
- The section heading (`h2`, its `span.meta` "N normal" and subtitle), the
  rows themselves (`nr_row`), the 18-tile cap and the 6-row note caps.
  The dashboard reads that `span.meta` for its Normal tab count.
- The dashboard's tabs and table (`findTable()`) beyond Step 3b's line.
- The verdict pills and the rail link (they keep pointing at `#s-normal`;
  `reveal()` makes them open the fold).
- The All sections view (the section is Summary-only).

## Git workflow

- Branch: `advisor/032-fold-checked-and-normal` from `main`.
- Conventional commit, e.g. `feat(report): "Checked and normal" folds to one line`.
- Do NOT push or open a PR unless the operator instructed it.

## Target UI

```
 Checked and normal   o 30 normal
 Every other scored metric, against the same prior windows
 +--------------------------------------------------------------------------+
 | >  25 metrics within the normal range . 5 moved too little to matter .     |
 |    nothing improved materially                                             |
 +--------------------------------------------------------------------------+
   (click: the existing grid and the two note panels open below the line)
```

Closed by default when the report has at least one finding card; open when
it has none (then this section is what the reader came for). A link to
`#s-normal` (pill, rail) opens it.

## Steps

### Step 1: Count first, then wrap the body in a fold

In `sql/07_summary.sql`, in the block quoted above:

1. Add three variables after `v_first VARCHAR2(16);`:

   ```sql
        v_cg    PLS_INTEGER := 0;   -- plan 032: rows in the calm grid (typical |z| <= 2, flat)
        v_cs    PLS_INTEGER := 0;   -- plan 032: moved, too small to matter (typical |z| > 2, noted)
        v_ci    PLS_INTEGER := 0;   -- plan 032: improved
   ```

2. In the `ELSE` branch, BEFORE the line
   `DBMS_OUTPUT.PUT_LINE('<div class="panel calm"><div class="ngrid">');`,
   insert:

   ```sql
            -- plan 032: count the three groups first, so the folded summary
            -- line can name them; they add up to v_normal
            FOR p IN 1 .. v_table_idx.COUNT LOOP
                f := v_findings(v_table_idx(p));
                IF f.canonical = 'Y' THEN
                    IF (f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) <= 2)
                       OR f.change_bucket = 'flat baseline' THEN
                        v_cg := v_cg + 1;
                    ELSIF (f.change_bucket = 'typical' AND ABS(NVL(f.z_score, 0)) > 2)
                          OR f.change_bucket = 'noted' THEN
                        v_cs := v_cs + 1;
                    ELSIF f.change_bucket = 'improved' THEN
                        v_ci := v_ci + 1;
                    END IF;
                END IF;
            END LOOP;
            -- plan 032: the body folds to one line in the Summary view; open
            -- when there is no finding card (then this section is the story)
            DBMS_OUTPUT.PUT_LINE('<details class="calm-fold"'
                || CASE WHEN v_order.COUNT = 0 THEN ' open' END || '>'
                || '<summary class="calm-sum"><span><b>' || v_cg || '</b> metric'
                || CASE WHEN v_cg = 1 THEN '' ELSE 's' END || ' within the normal range</span>'
                || '<span>&middot; <b>' || v_cs || '</b> moved too little to matter</span>'
                || '<span>&middot; '
                || CASE WHEN v_ci = 0 THEN 'nothing improved materially'
                        ELSE '<b>' || v_ci || '</b> improved' END
                || '</span></summary>');
   ```

3. Still in the `ELSE` branch, after the LAST `PUT_LINE` of the branch (the
   one that ends with `'</div></div>');` and closes the "Improved" panel and
   `div.calm-notes`), and before `END IF;`, add:

   ```sql
            DBMS_OUTPUT.PUT_LINE('</details>');
   ```

The `IF v_normal = 0 THEN` branch (the "Nothing could be scored" panel)
stays unfolded.

**Verify**: `./lint.sh` → clean.
`grep -c '<details class="calm-fold"' sql/07_summary.sql` → `1`;
`grep -c "PUT_LINE('</details>');" sql/07_summary.sql` → `1` more than before
(compare with `git show 5594f2c:sql/07_summary.sql | grep -c "PUT_LINE('</details>');"`).

### Step 2: A link to `#s-normal` opens the fold

In `sql/00_params.sql`, directly after the `#about` line of `reveal()`
(line 1073, quoted above), add:

```sql
    DBMS_OUTPUT.PUT_LINE('  if(el.id==="s-normal"){ var cf=el.querySelector("details.calm-fold"); if(cf) cf.open=true; }');
```

(If plan 025 already added a line to `reveal()`, keep it; this line goes
right after the `#about` line.)

**Verify**: `./lint.sh` → clean. `grep -c 'details.calm-fold' sql/00_params.sql` → `1`.

### Step 3: CSS

In `sql/_style.sql`, directly after the line
`DBMS_OUTPUT.PUT_LINE('.calm-empty{margin:0;padding:var(--s4) 0;font-size:14px;color:var(--ink-soft)}');`
(line 1387), add:

```sql
    -- plan 032: "Checked and normal" folded to one summary line (07)
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold > summary{list-style:none;cursor:pointer;display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;padding:var(--s4) var(--s6);background:var(--panel);border:1px solid var(--hairline);border-radius:10px;font-size:14px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold > summary::-webkit-details-marker{display:none}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold > summary::before{content:"";width:6px;height:6px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;transform:rotate(-45deg);transition:transform .15s;margin:0 6px 0 2px}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold[open] > summary::before{transform:rotate(45deg)}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold > summary:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold > summary b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('#s-normal .calm-fold[open] > summary{margin-bottom:var(--s4)}');
```

**Verify**: `./lint.sh` → clean; `grep -nP '[^\x00-\x7F]' sql/_style.sql` → no output.

### Step 3b: The dashboard's Normal tab shows the body open

In the dashboard design the "Normal" tab replaces the fold (see "Report
designs" under Current state).

1. `sql/lib/src/js_design.js`, function `findTable()`, line 288. Replace

   ```js
     if(sn){var nn=(txt($("h2 .meta",sn)).match(/\d+/)||[null])[0];var pN=tab("normal","Normal",nn,false);pN.appendChild(sn);}
   ```

   with

   ```js
     if(sn){var nn=(txt($("h2 .meta",sn)).match(/\d+/)||[null])[0];var pN=tab("normal","Normal",nn,false);pN.appendChild(sn);
       /* plan 032: the tab is the fold, so the folded body opens */
       var cf=$("details.calm-fold",sn);if(cf)cf.open=true;}
   ```

2. `sql/lib/src/css_design.css`, directly after line 297
   (`.dpanel #s-normal > h2{display:none}`), add:

   ```css
   .dpanel #s-normal .calm-fold > summary{display:none}
   ```

   (A `<details>` with a hidden summary still shows its content while
   open; with the summary hidden a reader cannot close it by accident.)
3. Regenerate: `tools/js2plsql.sh js_design` and
   `tools/js2plsql.sh css_design`.

Classic and quiet are not affected (`findTable()` runs only for
`design=dashboard`; `.dpanel` exists only there). With JS off the
dashboard is the quiet layout: the fold works as in classic.

**Verify**: `tools/js2plsql.sh --check` → exit 0.
`grep -c 'details.calm-fold' sql/lib/js_design.plsql` → `1`.
`grep -c 'calm-fold > summary{display:none}' sql/lib/css_design.plsql` → `1`.
`grep -nP '[^\x00-\x7F]' sql/lib/src/js_design.js sql/lib/src/css_design.css` → no output.

### Step 4: Re-port the demo twin

In `demo/awrdemo/sections/s07_summary.py`, in `emit`, in the `else:`
branch of `if normal == 0:` (the block that starts
`out.append('<div class="panel calm"><div class="ngrid">')`):

1. Before that `out.append`, count the three groups exactly like Step 1
   (`cg`, `cs`, `ci` over `ordered`, canonical rows only, `f.az` is
   `abs(z)` — see the `Finding.az` property) and append the `<details>`
   opening string of Step 1 (`' open'` when `nc == 0`, where `nc =
   len(order)` is already defined above).
2. After the last `out.append` of that branch (the one ending
   `'</div></div>')`), append `'</details>'`.

Regenerate twice: `python3 demo/gen_demo_report.py` writes the three
design pages; `md5sum docs/examples/demo_busy_db*.html` must be the same
after both runs. (The quiet / dashboard pages need no twin change: the
generator reads the regenerated `js_design.plsql` / `css_design.plsql`.)

**Verify**: `python3 demo/gen_demo_report.py --check` → exit 0.
`grep -o '<summary class="calm-sum">.\{0,220\}' docs/examples/demo_busy_db.html`
shows `<b>25</b> metrics within the normal range` and
`<b>5</b> moved too little to matter` and `nothing improved materially`
(the demo's counts at the planned commit; if plans 020-026 changed
scoring and the numbers differ, the three must still add up to the
heading's "N normal").

### Step 5: Extend the browser smoke test

In `demo/verify_report.js` block 6 ("phase 4"), inside the `page.evaluate`
callback, before `window.AWR_setView('all', false);`, add:

```js
      // plan 032: "Checked and normal" folds to one summary line; a jump to
      // #s-normal (pill, rail) opens it.  The dashboard design shows it in
      // its Normal tab with the fold open (js_design).
      const sn = document.getElementById('s-normal'), cf = sn ? sn.querySelector('details.calm-fold') : null;
      out.calm = !sn ? 'none' : !cf ? 'nofold' : (cf.open ? 'open' : 'closed');
      if (cf && !cf.open) {
        window.AWR_goTo(sn, false, false); await wait(250);
        out.calmReveal = cf.open && vis(sn.querySelector('.ngrid')) ? 'ok' : 'FAIL';
        cf.open = false;
      } else out.calmReveal = 'skip';
```

and next to the other `fail(...)` lines:

```js
    if (/demo_busy_db(_quiet)?\.html$/.test(file) && p4.calm !== 'closed') fail('demo: "Checked and normal" should start folded, got ' + p4.calm);
    if (/demo_busy_db_dashboard\.html$/.test(file) && p4.calm !== 'open') fail('dashboard demo: the Normal tab should show "Checked and normal" open, got ' + p4.calm);
    if (p4.calmReveal === 'FAIL') fail('a jump to #s-normal did not open its fold');
```

(`file` is the report path, `const file = path.resolve(process.argv[2] ...)`
near the top of the script; the existing demo-only checks use the same
`/demo_busy_db\.html$/` test.)

Add to the header comment's phase 4 bullet: "Checked and normal starts
folded (one line) and a jump to it opens it; in the dashboard its Normal
tab shows it open".

**Verify**: the classic browser smoke test → `verify: OK`; the `phase 4`
JSON has `"calm":"closed"` and `"calmReveal":"ok"`. Then (after it ends)
the dashboard smoke test → `verify: OK`; `phase 4` has `"calm":"open"`,
`"calmReveal":"skip"`, and its `design dashboard:` line has
`"tabs":"ok"`.

### Step 6: Documentation

1. `CHANGELOG.md`, `## Unreleased` → `### Report`: "**"Checked and
   normal" in one line.** In the Summary view the normal / too small /
   improved metrics fold into one summary line (counts) that opens in
   place; it stays open when the report has no finding."
2. `CLAUDE.md`, "Summary view pieces" table, the `section#s-normal` row:
   append "body folded in `details.calm-fold` (summary line: the three
   counts; closed when there is a finding card); `reveal()` opens it for
   `#s-normal`". In "Report designs", the dashboard bullet: in the Normal
   tab the fold is opened by `findTable()` and its summary line hidden.

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- `./lint.sh`; `tools/js2plsql.sh --check`; demo regenerated twice (same
  md5 for the three pages) and `--check`.
- Browser smoke test with the Step 5 checks on the classic page (starts
  folded; a `goTo` to `#s-normal` opens it and shows the grid) and on the
  dashboard page (Normal tab shows it open; block 7's tab check passes).
- Manually (optional): Summary view, both themes: the summary line looks
  like a panel row, the chevron turns, the "30 metrics normal" pill opens
  it, nothing below it jumps around; the same in
  `demo_busy_db_quiet.html`; in `demo_busy_db_dashboard.html` the Normal
  tab shows the grid and the "too small" panel at once.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `python3 demo/gen_demo_report.py --check` exits 0; two runs give the same md5
- [ ] `./tools/check.sh` prints `check.sh: all checks passed`
- [ ] `demo/verify_report.js` ends with `verify: OK` on `docs/examples/demo_busy_db.html` and then on `docs/examples/demo_busy_db_dashboard.html`, including the Step 5 checks
- [ ] `grep -nP '[^\x00-\x7F]' sql/07_summary.sql sql/00_params.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css` prints nothing
- [ ] `git status` shows only in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `#s-normal` block no longer has the structure quoted above (grid,
  then the two note panels, inside `ELSE` of `IF v_normal = 0`).
- The three counts on the demo do not add up to the heading's "N normal":
  the grouping in Step 1 does not match the emission loops.
- `demo/verify_report.js` block 4 (entity links) or block 3 (cross-view
  jump) fails because a link now points into the closed fold; report which
  link instead of changing those blocks.
- `sql/lib/src/js_design.js` no longer has the `if(sn){...pN.appendChild(sn);}`
  line quoted in Step 3b (the dashboard changed shape), or the dashboard
  smoke test fails in block 7's `findings tabs` check.

## Maintenance notes

- A new group in "Checked and normal" (a new bucket) must be counted in the
  Step 1 pre-count too, or the summary line will not add up to the heading.
- With JavaScript off the fold still works (native `<details>`), closed when
  there are findings — every number in it is also in All sections'
  Findings tables.
- Plan 025 folds finding cards with a class and a script; this plan uses a
  native `<details>` because the section has no chart to re-measure. Both
  are opened by `reveal()`.
- Reviewer focus: the pre-count conditions are the same as the emission
  conditions; `' open'` only when `v_order.COUNT = 0`.
- **Designs.** If the dashboard's `findTable()` stops moving `#s-normal`
  into a tab, drop Step 3b's two lines with it.
- **Needs owner DB run** (the executor has no database). On dbmint (`ssh -p
  2200 oracle@dbmint`, never 2201; rsync without `--delete`). dbmint keeps
  35 days of AWR, so the September dates used before are gone: probe
  first and pin inside a restart-free stretch (on 2026-11-19: 2026-11-07
  14:45 to 2026-11-09 16:15), e.g. the heavy hour
  `./run_awr_trend.sh <connect> "2026-11-08 15:00" 1 8 10 0 1 h`
  (positionals: target_end win_hours weeks_back top_n inst_num step
  step_unit), the same with `DESIGN=dashboard`, and one quiet window with no
  finding card: rc 0, 29/29 `AWR-SECTION` pairs (sections 20-28 added
  nine); in a report with no finding card the fold is open;
  `demo/verify_report.js` on each report (one at a time): `verify: OK`.
