# Plan 022: One finding count everywhere — a finding is a card

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/00_params.sql sql/07_summary.sql sql/_style.sql sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/26_window_similarity.sql demo/awrdemo/sections/s00_params.py demo/awrdemo/sections/s07_summary.py demo/verify_report.js`
> Plans 020 and 021 change `sql/00_params.sql`, `sql/07_summary.sql`,
> `sql/_style.sql` and the two twins on purpose. Confirm plan 020 is DONE
> (`grep -c "FUNCTION g_imp" sql/07_summary.sql` → `1`;
> `grep -c 'data-share=' sql/07_summary.sql` → `1`). Any OTHER difference
> from the "Current state" excerpts is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW (presentation only; no scoring change)
- **Depends on**: plans/020-rank-finding-cards-by-impact.md (shares on the rail sub-links)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: the report designs (`design=quiet|dashboard`) and sections 20-28 landed. Line numbers refreshed (00 +12 after the rail block, `_style.sql` +7, twin chrome lines 448-451, `CLAUDE.md`); the rail sub-link share is now a `data-shr` attribute drawn by CSS `::after` (a child span would leak "70%" into the rail labels the dashboard's palette and KPI / table names read); card selectors use `article.fc:not(.chg)` so J/K and the checks work in the dashboard; the "metrics moved" grep is narrowed (section 28 says "N of M metrics moved outside their usual variation", a different statement); demo is three pages; DB-run notes updated.

## Why this matters

The Summary view answers "how much is wrong?" in four different units at
once. In the bundled demo the verdict pills say "4 findings" and "11 metrics
moved"; the Findings header says "4 findings" next to "10 large · 1
moderate"; the rail shows red / amber pills that count flagged *table rows*
per section (Findings 10/1, Load profile 5, Metrics 8, Waits 7/2, Background
waits 8, Top SQL 6, …, roughly 37 in all). A reader cannot tell which number
is "the" number, and the row counts double-count the same fact (the same
physical reads appear as a SYSSTAT row, a SYSMETRIC row and a wait class).

After this plan a **finding is a card**, everywhere it is counted as a
finding: the verdict pill ("4 findings · 3 large · 1 moderate"), the Findings
header in Summary, and the rail's Findings link (red / amber pills = large /
moderate *cards*; each card's sub-link shows its share of the DB-time rise).
Section headers keep counting their own rows (that is what a section is
about), but the rail stops showing per-section row counts — only the
existing status dot. In Summary, J / K ("next large finding") steps through
the large cards.

```
Verdict pills, before:  [4 findings] [11 metrics moved] [1 plan change] [30 metrics normal]
Verdict pills, after:   [4 findings ● 3 large ● 1 moderate] [1 plan change] [30 metrics normal]

Rail, before                         Rail, after
● Findings          (10)(1)          ● Findings          (3)(1)
    Physical I/O                         Physical I/O         70%
    DB time                              DB time
    Network                              Network              11%
● Load profile       (5)             ● Load profile
● Waits - foreground (7)(2)          ● Waits - foreground
```

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript line by line with `DBMS_OUTPUT.PUT_LINE('…')`. The page's
  client JavaScript in `sql/00_params.sql` is written inside PL/SQL string
  literals, so a single quote inside it is written `''`.
- `demo/` is a docs-only Python twin that renders the demo report in three
  designs: `docs/examples/demo_busy_db.html` (classic),
  `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` (a plain
  `python3 demo/gen_demo_report.py` writes all three).
  `demo/awrdemo/sections/s00_params.py`
  lifts 00's chrome `<script>` lines **literally** (between the `<nav>` and
  `<main>`, lines 448-451 of the twin) — edits there need no port — but
  hand-ports the verdict hero (`_hero`, line 215). `s07_summary.py`
  hand-ports 07 (`emit`, line 336). `demo/awrdemo/chrome.py` lifts
  `sql/lib/js_timeline.plsql` literally.
- `sql/lib/js_timeline.plsql` is GENERATED from `sql/lib/src/js_timeline.js`
  by `tools/js2plsql.sh js_timeline`. Edit the `.js`, never the `.plsql`.
- After plan 020, `sql/07_summary.sql` has `g_imp(p_g)` (a card's impact in
  AAS) and computes a share inline in `emit_card` (`v_shr`, integer percent of
  the DB-time rise, NULL when not meaningful).

### The report designs and sections 20-28 (landed after this plan was first written)

- `design=quiet|dashboard` adds `sql/lib/js_design.plsql` (generated from
  `sql/lib/src/js_design.js`; its DOMContentLoaded handler runs LAST, after
  00's chrome). The dashboard hides the rail (`nav.toc{display:none}`, it
  stays in the DOM), moves every finding card into a row
  (`details.drow`) of an expandable findings table in `#findings`, and
  moves `#s-changes` (the plan / config cards, class `chg`) into an aside
  inside `#findings`. So after load, `#findings .cards > article.fc`
  matches nothing in the dashboard; `#findings article.fc:not(.chg)`
  matches the finding cards in every design (that is the selector
  `demo/verify_report.js` uses since the designs, line 849). 00's chrome
  (counts, J/K) runs BEFORE the move, but J/K is pressed after it.
- The design script names things from rail-link TEXT: its "Jump to"
  palette uses each rail link's `data-label` (captured from
  `a.textContent` by 00's rail script at DOMContentLoaded,
  `sql/00_params.sql:605`), and its KPI cards / findings-table rows name a
  card with `famOf(card)` = the text of `nav.toc a.sub[href="#<card id>"]`.
  Anything appended to a rail sub-link as a child element therefore
  becomes part of a card's name in the dashboard ("Physical I/O 70%").
  This plan shows the share through a `data-shr` attribute and a CSS
  `::after` instead (step 3): generated content is not in `textContent`.
- The dashboard's findings table has tabs "Moved N / Normal / Improved";
  its Moved count is the number of table ROWS (one per card plus one per
  flagged related row of each card), i.e. the old "metrics moved" number.
  This plan leaves it: the tab counts what it lists, like a section header
  (owner decision, see Maintenance notes).
- Section 26 (window similarity) already counts findings as cards ("<b>4</b>
  findings (3 large · 1 moderate)", `cnt()` in `sql/lib/src/js_winsim.js`)
  and checks its count against 07's cards; this plan matches it.
- Section 28 (before / after a release, `sql/lib/src/js_reldelta.js`
  lines 165-167) prints "N of M metrics moved outside their usual
  variation" in its library row: a different statement (a before / after
  split, never a finding). It stays; the greps below exclude it.
- The new rail links of sections 20-28 (group "Diagnosis" and one link next
  to each extended section) are all `data-nodot`, so the old row-count
  loop already skipped them.

### Verdict pills — `sql/00_params.sql:1363-1372`

```sql
    DBMS_OUTPUT.PUT_LINE('<ul class="pills" id="pills" aria-label="Counts">'
        || CASE WHEN v_order.COUNT > 0
                THEN '<li><a href="#findings"><b>' || v_order.COUNT || '</b> finding'
                     || CASE WHEN v_order.COUNT = 1 THEN '' ELSE 's' END || '</a></li>'
                     || '<li><a href="#findings"><b>' || v_n_moved || '</b> metric'
                     || CASE WHEN v_n_moved = 1 THEN '' ELSE 's' END || ' moved</a></li>' END
        || '<li class="pl-normal"><a href="#s-normal"><b>' || v_n_normal || '</b> metric'
        || CASE WHEN v_n_normal = 1 THEN '' ELSE 's' END || ' normal</a></li>'
        || CASE WHEN v_n_impr > 0
                THEN '<li><a href="#s-normal"><b>' || v_n_impr || '</b> improved</a></li>' END
        || '</ul>');
```

`v_order` holds the card groups in card order; `v_gsev(g)` is 2 for a large
card and 1 for a moderate one (00's variables at lines 81-91; `v_gsev` is
`seen_t`, a table of PLS_INTEGER). Section 17 later inserts more pills
("1 plan change", "4 parameters differ", …) before `li.pl-normal` — keep
that class. The twin is `s00_params.py:247-255` (`_hero`).

### Findings header — `sql/07_summary.sql:903-936`

```sql
    -- Section header: title, a one-line subtitle per view, the counts.
    -- Counts are canonical rows only; folded twins get their own muted
    -- count.  The "N findings" = cards (card groups of families), the same
    -- number the verdict pills show.
    --
    v_meta := '<span class="meta">'
        || CASE WHEN v_crit > 0 THEN '<span><i class="dotk large"></i>' || v_crit || ' large</span>' END
        || CASE WHEN v_warn > 0 THEN '<span><i class="dotk moderate"></i>' || v_warn || ' moderate</span>' END
        || '<span><i class="dotk typical"></i>' || v_normal || ' normal</span>'
        ... improved / noted / folded spans ...
        || '</span>';
    ...
    DBMS_OUTPUT.PUT_LINE('<section id="findings" class="vw in-s in-a sumsec"><h2 id="findings-heading">'
        || CASE WHEN v_order.COUNT > 0
                THEN '<span class="vw in-s">' || v_order.COUNT || ' finding'
                     || CASE WHEN v_order.COUNT = 1 THEN '' ELSE 's' END || '</span>'
                     || '<span class="vw in-a">Findings</span>'
                ELSE 'Findings' END
        || v_meta
        || '<small class="h2sub"><span class="vw in-s">'
        || CASE WHEN v_order.COUNT > 0
                THEN (v_crit + v_warn) || ' metric' || CASE WHEN v_crit + v_warn = 1 THEN '' ELSE 's' END
                     || ' moved, in ' || v_order.COUNT || ' famil'
                     || CASE WHEN v_order.COUNT = 1 THEN 'y' ELSE 'ies' END
                ELSE 'Every scored metric against its prior windows' END
        || '</span><span class="vw in-a">Every scored metric against its prior windows; one table per domain</span>'
        || '</small></h2>');
```

(Line numbers shift by the size of plan 021's inserted block; search for
`v_meta := '<span class="meta">'`.) `v_crit` / `v_warn` count canonical
flagged ROWS. The view classes: an element with `class="vw in-s"` shows only
in Summary, `vw in-a` only in All sections (CSS:
`body.vs .vw:not(.in-s){display:none}` etc.). With JavaScript off every
view's element shows, stacked — the existing title spans already behave
that way. The twin is `s07_summary.py:366-385`.

The rail sub-links (one per card) are created by an inline script right
after the cards, `sql/07_summary.sql:944-957`:

```sql
        DECLARE
            v_js VARCHAR2(4000);
        BEGIN
            FOR k IN 1 .. v_order.COUNT LOOP
                v_js := v_js || CASE WHEN k > 1 THEN ',' END || '["' || card_id(v_order(k)) || '","'
                    || REPLACE(REPLACE(card_label(v_order(k)), '"', ''), '<', '') || '"]';
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var n=document.querySelector(''nav.toc a[href="#findings"]'');'
                || 'if(!n)return;[' || v_js || '].forEach(function(c){var a=document.createElement("a");'
                || 'a.className="sub";a.href="#"+c[0];a.setAttribute("data-nodot","");a.textContent=c[1];'
                || 'n.parentNode.insertBefore(a,n.nextSibling);n=a;});})();</script>');
        END;
```

Twin: `s07_summary.py:391-397`.

### Rail count pills — `sql/00_params.sql:929-958` (chrome script, C2 + H1)

```
/* ---- C2 + H1: per-section large / moderate row counts, on the rail links and in the section header ---- */
function isCrit(tr){ ... }
function isWarn(tr){ ... }
function secCounts(sec){ ... counts tbody rows ... return [c,w]; }
if(nav){
  nav.querySelectorAll("a[href^=\"#\"]").forEach(function(a){
    var id=a.getAttribute("href").slice(1);
    if(id==="overview"||a.hasAttribute("data-nodot")) return;
    var sec=doc.getElementById(id); if(!sec) return;
    var n=secCounts(sec);
    if(n[0]){ var p=doc.createElement("span"); p.className="cnt c"; p.textContent=n[0]; a.appendChild(p); }
    if(n[1]){ var q=doc.createElement("span"); q.className="cnt w"; q.textContent=n[1]; a.appendChild(q); }
  });
}
doc.querySelectorAll("main > section > h2").forEach(function(h2){
  ... appends span.meta "N large / M moderate" to every section h2 that has none ...
});
```

(Shown without the `DBMS_OUTPUT.PUT_LINE('…');` wrappers; the exact PL/SQL
lines are 941-949 for the `if(nav){…}` part.) The `h2` part (the section
headers' own row counts) stays unchanged.

The status dots (`span.st`, graded crit / warn / ok) come from a different
script (lines 601-614) and stay.

### Timeline lane pills — `sql/lib/src/js_timeline.js:109-110`

```js
    var rl=doc.querySelector('nav.toc a[href="#'+lane.id+'"]');
    if(rl){rl.hidden=lane.hidden;if(n[0]){var p=mk('span','cnt c',rl);p.textContent=n[0];}if(n[1]){var q=mk('span','cnt w',rl);q.textContent=n[1];}}
```

The lane's own header counts (`laneMeta`, lines 71-92) and the Timeline
`h2` total (line 114) stay.

### J / K — `sql/00_params.sql:960-981`

```
function findingRows(){
  var out=[];
  doc.querySelectorAll("section tbody tr").forEach(function(tr){
    if(tr.hidden||tr.offsetParent===null) return;
    if(tr.classList.contains("twin")||tr.classList.contains("member")) return;
    if(isCrit(tr)) out.push(tr);
  });
  return out;
}
function jump(d){
  var list=findingRows(); if(!list.length) return;
  jIdx=(jIdx+d+list.length*2)%list.length;
  var tr=list[jIdx];
  doc.querySelectorAll("tr.jump-hi").forEach(function(x){x.classList.remove("jump-hi");});
  tr.scrollIntoView({block:"center"});
  tr.classList.add("jump-hi");
  setTimeout(function(){tr.classList.remove("jump-hi");},1600);
}
```

The same chrome script (one `DOMContentLoaded` callback from line 690 to the
`</script>` at line 1243) also defines `curView()` (line 995) and
`goTo(el, flash, persist)` (line 1078) as function declarations, so they can
be called from `jump`. Finding cards are `article.fc` with class `f-large`
or `f-moderate` inside `#findings` (`.cards > article.fc` in classic /
quiet; inside `details.drow` in the dashboard); the plan-change and config
cards are `article.fc.chg` and never findings.

### CSS hooks — `sql/_style.sql`

Rail pills `nav.toc a .cnt` (lines 931-937, keep: the Findings link still
uses them); rail sub-link `nav.toc a.sub` (line 323); rail links are
`display:flex` (line 198); no rule uses `nav.toc a::after` today. Verdict
pills `.hero .pills …` (lines 1193-1196). The quiet / dashboard skin
restyles `.cnt` as a dot + number (`sql/lib/src/css_design.css` lines
92-96) and `nav.toc a.sub` (line 90); no change needed there.

### Rules of this codebase that apply

- Never type a tilde in any `sql/` file or in `sql/lib/src/*.js`
  (`tools/js2plsql.sh` rejects it; `./lint.sh` checks the SQL).
- Emitted text pure ASCII (entities in markup; in JS no literal non-ASCII).
  Check with `grep -nP '[^\x00-\x7F]' <file>`.
- In 00's chrome script lines a single quote inside the JavaScript is `''`.
- `PUT_LINE` source lines < 2499 characters.
- New 00 variables go BEFORE the `@@sql/lib/…` includes (lint 14).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)` |
| Regenerate the timeline script | `tools/js2plsql.sh js_timeline` | exit 0 |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0 |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote …` lines (`demo_busy_db.html`, `_quiet`, `_dashboard`) |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | `verify: OK` each time (about 3 min each; one at a time) |

No database available to you; see Maintenance notes.

## Scope

**In scope**:
- `sql/00_params.sql` — verdict pill; rail pills only on Findings; J / K on cards in Summary
- `sql/07_summary.sql` — Findings header metas and subtitle; `g_shr`; rail sub-link shares
- `sql/_style.sql` — two small rules
- `sql/lib/src/js_timeline.js` and the regenerated `sql/lib/js_timeline.plsql`
- `demo/awrdemo/sections/s00_params.py`, `demo/awrdemo/sections/s07_summary.py`
- `demo/verify_report.js`
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` (regenerated)
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope**:
- `sql/lib/src/js_design.js` / `css_design.css` (the design layer): with
  step 3's `data-shr` design it needs no change. The dashboard's "Moved N"
  tab count stays (owner decision, Maintenance notes).
- Sections 20-28 and their scripts (26 already counts cards; 28's "metrics
  moved outside their usual variation" is not a finding count).
- Section header counts (`span.meta` appended by the chrome to each section
  h2; the evidence-library row counts; the Timeline lane headers) — they
  count their own rows and stay.
- The status dots on rail links.
- Section 17's pills (plan change, parameters, …) and the "N metrics
  normal" / "N improved" pills.
- Scoring, card order, the triage list (plan 025).

## Git workflow

- Branch: `advisor/022-one-finding-count` (on top of 020/021).
- Commit, e.g. `feat(report): count findings as cards in the verdict, header and rail`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: The verdict pill (00)

1. In 00's variable block (with `v_n_moved` etc., lines 68-91, before the
   includes) add:
   ```sql
    v_ncl        PLS_INTEGER := 0;   -- large finding cards (v1.7: a finding is a card)
    v_ncm        PLS_INTEGER := 0;   -- moderate finding cards
   ```
2. Right after the card-order block (after the `FOR k IN 3 .. v_order.COUNT
   LOOP … END LOOP;` that moves DB time to second place, around line 343),
   add:
   ```sql
    FOR k IN 1 .. v_order.COUNT LOOP
        IF v_gsev(v_order(k)) = 2 THEN v_ncl := v_ncl + 1; ELSE v_ncm := v_ncm + 1; END IF;
    END LOOP;
   ```
3. Replace the first `CASE` of the pills (the two `<li>`s for findings and
   "metrics moved") with ONE pill:
   ```sql
        || CASE WHEN v_order.COUNT > 0
                THEN '<li class="pl-find"><a href="#findings"><b>' || v_order.COUNT || '</b> finding'
                     || CASE WHEN v_order.COUNT = 1 THEN '' ELSE 's' END
                     || '<span class="pl-sev">'
                     || CASE WHEN v_ncl > 0 THEN '<i class="dotk large" aria-hidden="true"></i>' || v_ncl || ' large' END
                     || CASE WHEN v_ncm > 0 THEN '<i class="dotk moderate" aria-hidden="true"></i>' || v_ncm || ' moderate' END
                     || '</span></a></li>' END
   ```
   Leave `v_n_moved` computed (it is harmless) but update its comment to
   "(no longer printed: a finding is a card, v1.7)".
4. Twin `s00_params.py` `_hero`: compute
   `ncl = sum(1 for g in order if gsev_of(g) == 2)` — `_verdict_state`
   does not return `gsev` today, so add `st["gsev"] = gsev` to it and use
   `st["gsev"][g]` — and emit the identical `<li class="pl-find">…</li>`
   in place of the two old `<li>`s.

**Verify**: `./lint.sh` → clean. `python3 demo/gen_demo_report.py` →
`wrote …`. `grep -o '<li class="pl-find">.*</li><li' docs/examples/demo_busy_db.html | head -1`
contains `<b>4</b> findings` and `3 large` and `1 moderate`.
`grep -c 'metrics moved</a>' docs/examples/demo_busy_db.html` → `0`.
(A bare `grep -c 'metrics moved'` still finds 2 lines: section 28's
script, "… metrics moved outside their usual variation", which stays.)

### Step 2: The Findings header (07)

1. Add a local function after `g_imp` (plan 020) and make `emit_card` use it
   instead of its inline share computation:
   ```sql
    -- a card's share of the DB-time rise, integer percent; NULL when the
    -- card added no time, DB time did not rise, or the share passes 100
    FUNCTION g_shr(p_g VARCHAR2) RETURN NUMBER IS
        v_i NUMBER := g_imp(p_g);
        v_d NUMBER := g_imp('DBTIME');
    BEGIN
        IF v_i > 0 AND v_d > 0 AND v_i <= v_d * 1.005 THEN
            RETURN ROUND(v_i / v_d * 100);
        END IF;
        RETURN NULL;
    END g_shr;
   ```
   In `emit_card`, replace plan 020's
   `IF v_imp > 0 AND v_dd > 0 AND v_imp <= v_dd * 1.005 THEN v_shr := ROUND(v_imp / v_dd * 100); END IF;`
   with `v_shr := g_shr(p_g);` (the output must not change — check with the
   demo md5 before/after this sub-step).
2. Count the cards by severity just before `v_meta := …`:
   ```sql
    v_ncl := 0; v_ncm := 0;
    FOR k IN 1 .. v_order.COUNT LOOP
        IF v_gsev(v_order(k)) = 2 THEN v_ncl := v_ncl + 1; ELSE v_ncm := v_ncm + 1; END IF;
    END LOOP;
   ```
   (declare `v_ncl PLS_INTEGER := 0;` and `v_ncm PLS_INTEGER := 0;` with the
   other 07 variables, before the includes).
3. Make the existing row meta All-sections-only when there are cards, and
   add a Summary meta that counts cards. Change the first line of `v_meta`
   from `'<span class="meta">'` to
   `'<span class="meta' || CASE WHEN v_order.COUNT > 0 THEN ' vw in-a' END || '">'`
   and, in the `<section id="findings" …>` PUT_LINE, print before `v_meta`:
   ```sql
        || CASE WHEN v_order.COUNT > 0
                THEN '<span class="meta vw in-s" title="finding cards by severity">'
                     || CASE WHEN v_ncl > 0 THEN '<span><i class="dotk large"></i>' || v_ncl || ' large</span>' END
                     || CASE WHEN v_ncm > 0 THEN '<span><i class="dotk moderate"></i>' || v_ncm || ' moderate</span>' END
                     || '</span>' END
   ```
4. Replace the Summary subtitle ("N metrics moved, in M families") with:
   ```sql
                THEN 'From ' || (v_crit + v_warn) || ' flagged metric'
                     || CASE WHEN v_crit + v_warn = 1 THEN '' ELSE 's' END
                     || '; ordered by the DB time each card added'
   ```
   (keep the `ELSE 'Every scored metric against its prior windows' END`).
5. Update the comment above `v_meta` to: "Counts: in Summary the finding
   CARDS by severity (the verdict pill and the rail count the same cards);
   in All sections the canonical flagged ROWS of the detail tables, folded
   twins apart."
6. Twin `s07_summary.py` (lines 366-385): the same two metas (the row meta
   gets ` vw in-a` when `order` is non-empty), the same Summary subtitle,
   and the card counts from `gsev`.

**Verify**: `./lint.sh` → clean. Regenerate the demo, then
`grep -o '<h2 id="findings-heading">.*</h2>' docs/examples/demo_busy_db.html | head -1`
contains `class="meta vw in-s"`, `3 large`, `1 moderate`,
`class="meta vw in-a"`, `10 large` and `From 11 flagged metrics; ordered by the DB time each card added`.

### Step 3: Rail sub-links show each card's share (07)

In the sub-link script block (the `DECLARE v_js …` after the cards), add a
third element per card and show it through an attribute (NOT a child
element: the rail link's text is its name for 00's narrow-screen top bar
and for the dashboard's palette, KPI cards and findings table, see
"Current state"):

```sql
            FOR k IN 1 .. v_order.COUNT LOOP
                v_js := v_js || CASE WHEN k > 1 THEN ',' END || '["' || card_id(v_order(k)) || '","'
                    || REPLACE(REPLACE(card_label(v_order(k)), '"', ''), '<', '') || '","'
                    || CASE WHEN v_order(k) <> 'DBTIME' THEN TO_CHAR(g_shr(v_order(k))) END || '"]';
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('<script>(function(){var n=document.querySelector(''nav.toc a[href="#findings"]'');'
                || 'if(!n)return;[' || v_js || '].forEach(function(c){var a=document.createElement("a");'
                || 'a.className="sub";a.href="#"+c[0];a.setAttribute("data-nodot","");a.textContent=c[1];'
                || 'if(c[2]){a.setAttribute("data-shr",c[2]+"%");a.title=c[1]+": "+c[2]+"% of the DB-time rise";}'
                || 'n.parentNode.insertBefore(a,n.nextSibling);n=a;});})();</script>');
```

(`TO_CHAR` of NULL is NULL, so a card without a share gets `""` and no
attribute.) Port it to `s07_summary.py:391-397` with the identical text.

In `sql/_style.sql`, after the `nav.toc a.sub {…}` line (line 323), add:

```sql
    DBMS_OUTPUT.PUT_LINE('nav.toc a.sub[data-shr]::after { content:attr(data-shr); margin-left:auto; padding-left:8px; font-size:11.5px; color:var(--muted); font-variant-numeric:tabular-nums; }');
```

(Rail links are `display:flex`, so `margin-left:auto` pushes the share to
the right edge. `::after` content is not part of `textContent`, so
`data-label`, the palette and the dashboard's card names stay "Physical
I/O".)

**Verify**: `./lint.sh` → clean. Regenerate the demo;
`grep -o '\["f-io","Physical I/O","[0-9]*"\]' docs/examples/demo_busy_db.html`
prints one match with a number; `grep -o '\["f-dbtime","DB time",""\]' docs/examples/demo_busy_db.html`
prints one match; `grep -c 'sub-shr' sql/07_summary.sql sql/_style.sql` → `0` each.

### Step 4: Rail pills only on Findings (00 chrome script)

Replace the `if(nav){ … }` part of the C2 + H1 block (lines 941-949) with
these PUT_LINEs (each JavaScript line is one `DBMS_OUTPUT.PUT_LINE('…');`,
as in the surrounding code; the escaped quotes `\"` stay as they are in the
current lines):

```
/* v1.7: one count -- a finding is a card.  Only the rail's Findings link carries count
   pills (large / moderate cards); every other link keeps its status dot only, and each
   section header keeps its own row counts (below). */
function cardCounts(sec){
  var c=0,w=0;
  sec.querySelectorAll("article.fc:not(.chg)").forEach(function(a){
    if(a.classList.contains("f-large")) c++; else if(a.classList.contains("f-moderate")) w++;
  });
  return [c,w];
}
if(nav){
  var fa=nav.querySelector("a[href=\"#findings\"]"), fsec=doc.getElementById("findings");
  if(fa&&fsec){
    var n=cardCounts(fsec);
    if(n[0]){ var p=doc.createElement("span"); p.className="cnt c"; p.textContent=n[0]; p.title=n[0]+" large finding card"+(n[0]>1?"s":""); fa.appendChild(p); }
    if(n[1]){ var q=doc.createElement("span"); q.className="cnt w"; q.textContent=n[1]; q.title=n[1]+" moderate finding card"+(n[1]>1?"s":""); fa.appendChild(q); }
  }
}
```

Write the comment as a `/* … */` JavaScript comment on ONE PUT_LINE (no
line breaks inside a PUT_LINE string) or as a PL/SQL `--` comment above the
PUT_LINEs. Keep `isCrit`, `isWarn`, `secCounts` and the `h2` loop as they
are (the `h2` loop and J / K still use them).

**Verify**: `./lint.sh` → clean. `grep -c 'cardCounts' sql/00_params.sql` → `2`.
The twin lifts these lines; regenerate the demo and
`grep -c 'function cardCounts' docs/examples/demo_busy_db.html` → `1`.

### Step 5: No row pills on the Timeline lane links (`js_timeline`)

In `sql/lib/src/js_timeline.js` line 110 replace

```js
    if(rl){rl.hidden=lane.hidden;if(n[0]){var p=mk('span','cnt c',rl);p.textContent=n[0];}if(n[1]){var q=mk('span','cnt w',rl);q.textContent=n[1];}}
```

with

```js
    if(rl)rl.hidden=lane.hidden;
```

Then run `tools/js2plsql.sh js_timeline`.

**Verify**: `tools/js2plsql.sh --check` → exit 0.
`grep -c "cnt c" sql/lib/src/js_timeline.js sql/lib/js_timeline.plsql` → `0` each.
`./lint.sh` → clean (check 24 compares the generated file with its source).

### Step 6: J / K steps through the large cards in Summary (00 chrome script)

1. In `findingRows()` (line 962), as its first statements after
   `var out=[];`, add:
   ```
   if(curView()==="summary"){
     doc.querySelectorAll("#findings article.fc.f-large:not(.chg)").forEach(function(a){ out.push(a); });
     if(out.length) return out;
   }
   ```
   (Not `.cards > article.fc`: the dashboard design moves the cards into
   closed `details.drow` rows of its findings table; `goTo` → `reveal()`
   opens the row that holds the card.)
2. In `jump(d)`, right after `var tr=list[jIdx];`, add:
   ```
   if(tr.tagName!=="TR"){ goTo(tr,true,false); return; }
   ```

Each JS line is its own `DBMS_OUTPUT.PUT_LINE('…');`, indented like the
neighbours. No single quotes are needed.

**Verify**: `./lint.sh` → clean. Regenerate the demo;
`grep -c 'article.fc.f-large:not(.chg)' docs/examples/demo_busy_db.html` → at least `1`.

### Step 7: CSS for the verdict pill

In `sql/_style.sql`, after `.hero .pills b{…}` (line 1196), add:

```sql
    DBMS_OUTPUT.PUT_LINE('.hero .pills .pl-sev{display:inline-flex;align-items:center;gap:5px;margin-left:6px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.hero .pills .pl-sev .dotk{width:8px;height:8px;margin-left:4px}');
```

**Verify**: `./lint.sh` → clean. The quiet / dashboard skin restyles
`.hero .pills` (one stats line, `sql/lib/src/css_design.css` lines
121-126) and inherits these two rules; check the pill in the dashboard
demo by eye (no design-file change is planned).

### Step 8: Browser check (`demo/verify_report.js`)

In section "6. phase 4" (it runs for every design), inside the
`page.evaluate`, AFTER the line that defines
`const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];`
(line 849) and BEFORE `window.AWR_setView('all', false)`, add:

```js
      // v1.7 one count: the rail's Findings pills count the cards; no other rail link counts rows
      const fl = document.querySelector('nav.toc a[href="#findings"]');
      out.railFind = (fl ? [...fl.querySelectorAll('.cnt')].reduce((s, x) => s + (parseInt(x.textContent, 10) || 0), 0) : -1) + '/' + cards.length;
      out.railOther = [...document.querySelectorAll('nav.toc a .cnt')].filter(x => x.closest('a') !== fl).length;
      out.pillMoved = [...document.querySelectorAll('#pills li')].some(li => /metrics? moved/.test(li.textContent));
      const fm = document.querySelector('#findings-heading .meta.in-s');
      out.findMeta = fm ? (fm.textContent.match(/\d+/g) || []).reduce((s, x) => s + +x, 0) + '/' + cards.length : 'none';
      // J in Summary lands on a large card
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true }));
      await wait(200);
      const fl1 = document.querySelector('#findings article.fc.flash:not(.chg)');
      out.jk = fl1 ? (fl1.classList.contains('f-large') ? 'ok' : 'FAIL not large') : 'FAIL no card flashed';
      // the rail sub-link names stay clean (the share is CSS ::after only)
      out.subNames = [...document.querySelectorAll('nav.toc a.sub')].every(a => !/%/.test(a.textContent) && !/%/.test(a.getAttribute('data-label') || ''));
```

and after `console.log('phase 4', …)`:

```js
    const [rf, rc] = p4.railFind.split('/');
    if (rf !== rc) fail('rail Findings pills count ' + rf + ', cards ' + rc);
    if (p4.railOther) fail('rail: ' + p4.railOther + ' count pill(s) outside the Findings link');
    if (p4.pillMoved) fail('verdict: a "metrics moved" pill is back');
    if (p4.findMeta !== 'none' && p4.findMeta.split('/')[0] !== p4.findMeta.split('/')[1]) fail('Findings header (Summary) does not count the cards: ' + p4.findMeta);
    if (/^FAIL/.test(p4.jk)) fail('J in Summary: ' + p4.jk);
    if (!p4.subNames) fail('rail card sub-link text / data-label carries the share');
```

Add a line to the header comment's check list.

**Verify**: `node --check demo/verify_report.js` → exit 0; the browser
smoke test on the classic and the dashboard demo → `verify: OK` each (in
the dashboard the rail is hidden but in the DOM, so the rail checks above
still count; block 7's KPI / findings-table checks must still pass).

### Step 9: Documentation

- `CHANGELOG.md`, `## Unreleased` → `### Report`: "**One finding count.** A
  finding is a card everywhere it is counted: the verdict pill (with its
  large / moderate split; the "metrics moved" pill is gone), the Findings
  header in Summary and the rail's Findings link (whose card sub-links show
  each card's share of the DB-time rise). Other rail links keep their
  status dot but no longer count table rows; section headers still count
  their own rows. In Summary, J / K step through the large cards."
- `CLAUDE.md`:
  - "Card groups" paragraph: replace `"N findings" = number of cards;
    "metrics moved" = canonical large+moderate rows.` with `One count: a
    finding is a card — the verdict pill (li.pl-find), the Summary Findings
    header (.meta.in-s) and the rail's Findings pills (cardCounts in 00's
    chrome) count cards; the All sections Findings header and every section
    header count their own rows.`
  - Rail paragraph (around lines 323-325): "status dots, count pills, J/K" →
    "status dots, count pills on the Findings link only (cards), J/K (cards
    in Summary)"; "(the lane links, hidden when a lane is empty; pills from
    row `data-sev`)" → "(the lane links, hidden when a lane is empty)".
    Add: "a card sub-link's share of the DB-time rise is `data-shr` +
    CSS `::after`, never a child element (the rail text names the card in
    the dashboard)".
  - `js_timeline` client paragraph (around line 459): drop "/ rail pills".
  - Lines around 844 and 1088 that say `data-nocount` keeps rows "out of
    the rail pills": say "out of the section-header counts" (the rail no
    longer counts rows).

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- Demo greps in steps 1-6.
- `demo/verify_report.js` (step 8): rail Findings pills = number of cards;
  no other rail pill; no "metrics moved" pill; Summary header counts cards;
  J flashes a large card. The existing "one rail sub-link per finding card"
  check (`subsOk`) must still pass with the `data-shr` attributes added;
  `subNames` proves the share never reaches the link text.
- `tools/js2plsql.sh --check` (generated script in sync).

## Done criteria

- [ ] `./tools/check.sh` exits 0
- [ ] `grep -c 'metrics moved</a>\|metrics moved, in' docs/examples/demo_busy_db.html` → `0` (section 28's "metrics moved outside their usual variation" stays)
- [ ] `grep -c 'class="pl-find"' docs/examples/demo_busy_db.html docs/examples/demo_busy_db_dashboard.html` → `1` each
- [ ] `grep -c "cnt c" sql/lib/src/js_timeline.js` → `0`
- [ ] `demo/verify_report.js` → `verify: OK` on `demo_busy_db.html` and on `demo_busy_db_dashboard.html` (one at a time)
- [ ] `grep -nP '[^\x00-\x7F]' sql/00_params.sql sql/07_summary.sql sql/lib/src/js_timeline.js` → no output
- [ ] Only in-scope files modified; `plans/README.md` status row updated

## STOP conditions

- Plan 020 is not DONE (no `g_imp` in 07, no `data-share` attribute).
- The excerpts do not match the live code beyond plans 020 / 021's changes.
- Replacing 020's inline share with `g_shr` changes the demo's md5 (the
  functions disagree — report both values).
- `tools/js2plsql.sh --check` still fails after regenerating.
- A verify_report check other than the new ones starts failing (for
  example `subsOk`, the entity-link click-through, or block 7's dashboard
  KPI / findings-table checks) and the cause is not obviously this plan.
- `sql/00_params.sql` no longer captures the rail `data-label` from
  `a.textContent` (line 605), or `js_design.js`'s `famOf` no longer reads
  the sub-link text: re-check whether the `data-shr` design is still
  needed before improvising.

## Maintenance notes

- The rail no longer surfaces per-section row counts. If the owner wants
  them back for All sections only, gate the old loop on `curView()==="all"`
  and re-run it on `awr:view` — not done here because the rail would then
  change under the reader on every view switch.
- Section 17's pills are untouched; they are different nouns (plan change,
  parameters, skipped windows), not findings.
- The J / K button's label ("next large finding") now matches its behaviour
  in Summary; in Timeline / All sections it still walks large table rows.
- **Dashboard "Moved N" tab (owner decision, default: unchanged).** The
  dashboard design's findings table counts its rows (cards + flagged
  related rows), the old "metrics moved" number, next to the Findings
  header's card count. It counts what the tab lists, like a section
  header, so this plan leaves it. If the owner wants one number there too,
  change `findTable()` in `sql/lib/src/js_design.js` to count lead rows
  only (and verify_report block 7's `rows === tabN` check with it).
- **Needs owner DB run** (dbmint, `ssh -p 2200 oracle@dbmint`, never 2201;
  rsync without `--delete`). dbmint keeps 35 days of AWR, so the September
  dates this plan first used return empty windows now: probe first and pin
  inside a restart-free stretch (on 2026-11-19: 2026-11-07 14:45 to
  2026-11-09 16:15, e.g. the busy `"2026-11-08 15:00" 1 8 10 0 1 h`). A
  quiet and a busy window — rc 0, 29/29 `AWR-SECTION` pairs (20 before
  sections 20-28); in the busy report the verdict pill's number = the
  number of cards = the sum of the rail Findings pills = the "N findings"
  of the window-similarity section (26); no other rail link has a pill;
  the busy window again with `DESIGN=dashboard`: the KPI / table names
  carry no "%"; `demo/verify_report.js` passes on each (one at a time).
