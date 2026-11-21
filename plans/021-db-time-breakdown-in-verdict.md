# Plan 021: The verdict shows where the extra DB time went, split by DB CPU and wait class

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/07_summary.sql sql/00_params.sql sql/19_reference.sql sql/_style.sql sql/lib/finding_cards.plsql sql/lib/src/js_design.js sql/lib/src/css_design.css demo/awrdemo/sections/s00_params.py demo/awrdemo/sections/s07_summary.py demo/verify_report.js`
> Plan 020 changes several of these files on purpose. Before starting,
> confirm plan 020 is DONE (its row in `plans/README.md`) and that
> `grep -c "FUNCTION impact_group\|FUNCTION imp_tok\|FUNCTION imp_txt" sql/lib/finding_cards.plsql`
> prints `3` and `grep -c "FUNCTION g_imp" sql/07_summary.sql` prints `1`.
> Any OTHER difference from the "Current state" excerpts is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW-MED (new markup in the Summary verdict; no scoring change)
- **Depends on**: plans/020-rank-finding-cards-by-impact.md (uses its `impact_group`, `g_imp`, `imp_tok`, `imp_txt`)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: the report designs (`design=quiet|dashboard`) and sections 20-28 landed. Line numbers refreshed (`00_params.sql` slot 1361-1363, `_style.sql` 1203, `19_reference.sql` 232); the demo is three pages; the verify check now also runs on the quiet / dashboard demos; a dashboard note (the bar sits in the hero, above its KPI cards; the DB-time KPI reads `#f-dbtime h3`, which this plan must not change); DB-run notes updated.

## Why this matters

The verdict at the top of the report says, for example, "Physical reads 5.4×
normal …; DB time up 79.7%, mostly wait." It never says *which* wait. The
first question a DBA asks is "where did the extra DB time go?" The numbers
are already computed by section 07 (DB CPU and every wait class, Current and
prior mean), but they are spread over a card, a table in "All sections" and a
Timeline lane.

This plan adds one horizontal bar under the verdict: the DB-time rise (e.g.
+9.03 AAS) split into DB CPU and each wait class, biggest first, with a
legend that gives each part's AAS and share and says whether that part is
behind a finding (solid) or grew but stayed inside its normal range
(hatched). In the bundled demo it reads roughly: User I/O +6.3 (70%,
finding) · CPU +1.3 (15%, inside normal) · Network +0.95 (11%, finding) ·
Commit +0.16 (2%, finding).

Target, in words and as a sketch (pills and notes below it are unchanged):

```
Physical reads 5.4x normal, most of it on ORDERS_APP.ORDER_LINES; DB time up 79.7%, mostly wait.
Likely source: 7k2m9dx4qp1zb ran with a new plan ...

Where the extra DB time went                      DB time 11.32 -> 20.35 AAS, +9.030 AAS
[######## User I/O +6.315 ########][//CPU//][Net][C][o]
 ■ User I/O +6.315 70% ● finding   ▨ CPU +1.33 15% inside normal   ■ Network +0.95 11% ● finding ...
[ 4 findings ] [ 11 metrics moved ] [ 1 plan change ] ...
```

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript line by line with `DBMS_OUTPUT.PUT_LINE('…')`.
- Section 00 (`sql/00_params.sql`) runs first and prints the verdict hero
  (`section#verdict`) with empty "slots" that later sections fill. A later
  section prints its block **hidden** plus a one-line inline `<script>` that
  moves the block into the slot while the page is still parsing — the
  "relocation pattern". Example, `sql/17_narrative.sql:1036` and
  `:1057-1068` (excerpt):
  ```sql
        DBMS_OUTPUT.PUT_LINE('<div id="narr-src" hidden>');
        ...
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,src=d.getElementById("narr-src");if(!src)return;');
        DBMS_OUTPUT.PUT_LINE('var b=d.getElementById("because-slot"),bs=src.querySelector(".because-src");');
        ...
        DBMS_OUTPUT.PUT_LINE('src.parentNode.removeChild(src);})();</script>');
  ```
  These scripts run BEFORE `DOMContentLoaded`, so they must not depend on
  anything the page's DOMContentLoaded handlers set up. With JavaScript off
  the block stays hidden (every number it shows is also in a table).
- `demo/` is a docs-only Python twin that renders the demo report in three
  designs: `docs/examples/demo_busy_db.html` (classic),
  `demo_busy_db_quiet.html` and `demo_busy_db_dashboard.html`;
  `demo/awrdemo/sections/s00_params.py` hand-ports 00's hero (`_hero`, line
  215) and `s07_summary.py` hand-ports 07 (`emit`, line 336). Every markup
  change must be made in both and the demo regenerated
  (`python3 demo/gen_demo_report.py` writes all three pages).
- **Report designs** (landed after this plan was first written): with
  `design=quiet|dashboard` a generated stylesheet
  (`sql/lib/src/css_design.css` → `css_design.plsql`) restyles the hero
  (fonts, `.hero .verdict` / `.because` / `.pills`, zinc tokens; the wait
  colours are untouched) and, for the dashboard, `sql/lib/src/js_design.js`
  inserts a row of KPI cards (`div.dkpis`) right AFTER `section#verdict`.
  The breakdown bar of this plan lives inside the hero, so in the dashboard
  it shows above the KPI cards; nothing in the design script reads or
  moves it. The dashboard's DB-time KPI takes its "mostly wait / mostly
  CPU" context from the DB time card's `h3` text with the regex
  `,\s*(mostly .*|all .*)$` — this plan does not touch that `h3`; keep it
  so. A classic report must stay byte-identical whatever the designs do:
  this plan's CSS goes in `sql/_style.sql` (it is a new classic
  component, not a design rule), which the designs inherit.

### The slot's neighbourhood — `sql/00_params.sql:1361-1363`

```sql
        DBMS_OUTPUT.PUT_LINE('<h1 class="verdict">' || v_verdict || '.</h1>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('<p class="because" id="because-slot" hidden></p>');
    DBMS_OUTPUT.PUT_LINE('<ul class="pills" id="pills" aria-label="Counts">'
```

Twin, `demo/awrdemo/sections/s00_params.py:246`:
`put('<p class="because" id="because-slot" hidden></p>')`.

### The data — `sql/07_summary.sql`

07 BULK-COLLECTs every scored row into `v_findings` (record `finding_rec`,
lines 52-69: `metric_domain`, `metric_name`, `cur_val`, `prior_mean`,
`family`, `grp`, …). Relevant rows:

- LOAD `'DB time'` and `'DB CPU'`: from the time model, in centiseconds per
  second; `metric_scale` = 0.01 turns them into AAS. Their indexes are kept
  in `v_dbt` / `v_cpu` (pass 1, lines 761-762).
- WAIT rows, one per wait class, named `'Wait class: <class>'`, in seconds
  waited per second (= AAS), from `DBA_HIST_SYSTEM_EVENT.time_waited_micro`
  (all sessions, background included; lines 632-643).

After plan 020, 07 also has:
- `impact_group(domain, name, family)` (in `sql/lib/finding_cards.plsql`):
  `'DBTIME'` for DB time, `'CPU'` for DB CPU, the card group of a wait-class
  row (`IO` for User I/O, `NET` for Network, `COMMIT`, `WRITE` for System
  I/O, else `WAIT:<class>`).
- `v_gimp` / `g_imp(p_g)`: per card group, (Current − prior mean) × scale in
  AAS; `g_imp('DBTIME')` is the DB-time rise.
- `imp_tok(v)` (3-decimal '.'-token) and `imp_txt(v)` (`+6.315&nbsp;AAS`).
- `v_glead(g)` exists for every flagged card group; `v_gsev(g)` is 2 (large)
  or 1 (moderate); `v_order` holds the card order; `card_id(g)` is the
  card's element id (`f-io`, …); `find_id(domain, name)` (07 line 127) is the
  id of a metric's row in the "All sections" detail table (`fr-l-db-cpu`,
  `fr-w-wait-class-user-i-o`, …); `ent(html, id, kind)` is the ONLY allowed
  way to print an in-page entity link.

The Section header starts at line 904 (`-- Section header: title, …`),
right after the evidence scan's `END IF;` (line 901); `v_meta := …` is at
line 909. The new block goes between them.

### Colours

Wait-class colours are a single-sourced palette,
`window.AWR_WAIT_COLORS` (`sql/lib/js_wait_colors.plsql`, keys `CPU`,
`Scheduler`, `User I/O`, `System I/O`, `Concurrency`, `Application`,
`Commit`, `Configuration`, `Administrative`, `Network`, `Queueing`,
`Cluster`, `Other`), printed in the page prologue before section 00. Do not
copy the hex values into PL/SQL or CSS: the relocation script sets a CSS
custom property `--c` on every element with `data-wc` from that object.

### Rules of this codebase that apply

- **Never type a tilde** in any `sql/` file (SQL\*Plus substitution
  character; `./lint.sh` checks it).
- **Emitted text is pure ASCII**: entities (`&rarr;`, `&minus;`, `&middot;`,
  `&lt;`, `&#39;`) in markup; no literal non-ASCII. Check with
  `grep -nP '[^\x00-\x7F]' sql/07_summary.sql` (no output).
- `PUT_LINE` source lines < 2499 characters; `''` for a quote inside a
  literal (the code below needs none).
- **Declaration order** (lint checks 14 / 16): new TYPEs and variables go in
  07's DECLARE before the first `@@sql/lib/…` include (with the other TYPEs,
  lines 52-114), or in a nested `DECLARE … BEGIN … END;` block in the body.
- Wrap every name in `DBMS_XMLGEN.CONVERT(…)` (wait-class names are
  Oracle-defined, but this is the house rule).
- The hero is Summary-only (`section#verdict` has `class="vw in-s hero"`);
  scope the CSS under `.hero` (the stylesheet is also included by the fleet
  report).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)` |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote …` lines (`demo_busy_db.html`, `_quiet`, `_dashboard`) |
| Demo up to date | `python3 demo/gen_demo_report.py --check` | `up to date: …` for each page |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | `verify: OK` each time (about 3 min each; one at a time) |

No database is available to you; see Maintenance notes.

## Scope

**In scope**:
- `sql/00_params.sql` — one slot line in the hero
- `sql/07_summary.sql` — two TYPEs + one variable, the breakdown block and its relocation script
- `sql/_style.sql` — `.hero .att…` rules
- `sql/19_reference.sql` — one sentence in the About "Verdict" note
- `demo/awrdemo/sections/s00_params.py`, `demo/awrdemo/sections/s07_summary.py` — twins
- `demo/verify_report.js` — a check
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` — regenerated
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope**:
- The impact rule itself and the card order (plan 020).
- The pills / counts (plan 022).
- Using ASH (`AWR_DATA.ashx.winfg`) instead of `DBA_HIST_SYSTEM_EVENT`: the
  cards and this bar must show the same numbers; an owner decision (see
  Maintenance notes).
- Any table, the Timeline, the fleet report.
- The design layer (`sql/lib/src/js_design.js`, `sql/lib/src/css_design.css`)
  and the visualization sections 20-28: no change needed; the DB time
  card's `h3` (read by the dashboard's DB-time KPI) stays as it is.

## Git workflow

- Branch: `advisor/021-db-time-breakdown` from the branch that has plan 020.
- Commit, e.g. `feat(report): show where the extra DB time went under the verdict`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: The slot in 00

In `sql/00_params.sql`, right after
`DBMS_OUTPUT.PUT_LINE('<p class="because" id="because-slot" hidden></p>');`
(line 1362) add:

```sql
    -- v1.7: "Where the extra DB time went" -- 07 moves its breakdown in here
    DBMS_OUTPUT.PUT_LINE('<div class="att" id="att-slot" hidden></div>');
```

In `demo/awrdemo/sections/s00_params.py`, right after line 246 add
`put('<div class="att" id="att-slot" hidden></div>')`.

**Verify**: `./lint.sh` → clean.
`grep -c 'id="att-slot"' sql/00_params.sql demo/awrdemo/sections/s00_params.py` → `1` each.

### Step 2: Declarations in 07

In `sql/07_summary.sql`, after the `ev_t` TYPE (line 79) and before
`v_findings findings_t;`, add:

```sql
    -- v1.7 "Where the extra DB time went" (plan 021): one part per wait
    -- class and one for DB CPU, in AAS above the prior mean
    TYPE part_rec IS RECORD (
        lab VARCHAR2(64),     -- 'CPU' or the wait class name
        d   NUMBER,           -- Current - prior mean, AAS (may be negative)
        grp VARCHAR2(64),     -- the card group this part is the time measure of
        aid VARCHAR2(200)     -- link target: the card, else the detail row
    );
    TYPE part_t IS TABLE OF part_rec INDEX BY PLS_INTEGER;
```

and next to the other variables (before the includes):

```sql
    v_parts      part_t;
```

**Verify**: `./lint.sh` → clean (checks 14 / 16 would flag a misplaced declaration).

### Step 3: Build and print the breakdown in 07

Between the evidence scan's closing `END IF;` (line 901) and the comment
`-- Section header: title, a one-line subtitle per view, the counts.`
(line 904), insert this block exactly (it is a nested block, so its own
variables are legal here):

```sql
    --
    -- v1.7: "Where the extra DB time went" (plan 021).  The DB-time rise
    -- split into DB CPU and the wait classes -- the same numbers as the
    -- cards' impact (impact_group, sql/lib/finding_cards.plsql), largest
    -- first.  Solid = the part's card is a finding; hatched = it grew but
    -- stayed inside its normal range.  Printed hidden and moved into 00's
    -- #att-slot by the script below (JavaScript off: it stays hidden; every
    -- number is in the Wait classes table and the DB CPU row).  Only when
    -- there is at least one finding card.
    --
    DECLARE
        v_dd    NUMBER := g_imp('DBTIME');
        v_p     part_rec;
        v_pos   NUMBER := 0;      -- sum of the parts that rose
        v_base  NUMBER;           -- the bar's 100%: GREATEST(rise, sum of parts)
        v_small NUMBER := 0;      -- parts under 1% of the base, merged
        v_nsm   PLS_INTEGER := 0;
        v_rest  NUMBER;
        v_pct   NUMBER;
        v_fl    BOOLEAN;
        v_bar   VARCHAR2(32767);
        v_lg    VARCHAR2(32767);
        v_fell  VARCHAR2(4000);
        v_nfell PLS_INTEGER := 0;
        v_note  VARCHAR2(4000);
        k       PLS_INTEGER;
    BEGIN
      IF v_order.COUNT > 0 AND v_dd IS NOT NULL AND v_dbt IS NOT NULL THEN
        -- the parts, largest rise first (insertion sort, stable)
        FOR i IN 1 .. v_findings.COUNT LOOP
            f := v_findings(i);
            IF f.cur_val IS NOT NULL AND f.prior_mean IS NOT NULL
               AND (f.metric_domain = 'WAIT'
                    OR (f.metric_domain = 'LOAD' AND f.metric_name = 'DB CPU')) THEN
                v_p.lab := CASE WHEN f.metric_domain = 'LOAD' THEN 'CPU'
                                ELSE REGEXP_REPLACE(f.metric_name, '^Wait class: ', '') END;
                v_p.d   := (f.cur_val - f.prior_mean) * metric_scale(f.metric_domain, f.metric_name);
                v_p.grp := impact_group(f.metric_domain, f.metric_name, f.family);
                v_p.aid := CASE WHEN v_glead.EXISTS(v_p.grp) THEN card_id(v_p.grp)
                                ELSE find_id(f.metric_domain, f.metric_name) END;
                k := v_parts.COUNT;
                WHILE k >= 1 AND v_p.d > v_parts(k).d LOOP
                    v_parts(k + 1) := v_parts(k);
                    k := k - 1;
                END LOOP;
                v_parts(k + 1) := v_p;
                IF v_p.d > 0 THEN v_pos := v_pos + v_p.d; END IF;
            END IF;
        END LOOP;

        IF v_dd > 0 THEN
            v_base := GREATEST(v_dd, v_pos);
            FOR k2 IN 1 .. v_parts.COUNT LOOP
                v_p := v_parts(k2);
                IF v_p.d > 0 AND v_p.d >= 0.01 * v_base THEN
                    v_fl  := v_glead.EXISTS(v_p.grp);
                    v_pct := ROUND(v_p.d / v_dd * 100);
                    v_bar := v_bar || '<i class="att-s' || CASE WHEN NOT v_fl THEN ' nf' END
                        || '" data-wc="' || DBMS_XMLGEN.CONVERT(v_p.lab)
                        || '" style="flex-grow:' || imp_tok(v_p.d) || '" title="'
                        || DBMS_XMLGEN.CONVERT(v_p.lab) || ': +' || fmt_num(v_p.d) || ' AAS, '
                        || v_pct || '% of the DB-time rise'
                        || CASE WHEN NOT v_fl THEN ', inside its normal range' END || '">'
                        || CASE WHEN v_p.d >= 0.18 * v_base
                                THEN '<span>' || DBMS_XMLGEN.CONVERT(v_p.lab) || ' +' || fmt_num(v_p.d) || '</span>' END
                        || '</i>';
                    v_lg := v_lg || '<li><i class="sw' || CASE WHEN NOT v_fl THEN ' nf' END
                        || '" data-wc="' || DBMS_XMLGEN.CONVERT(v_p.lab) || '" aria-hidden="true"></i>'
                        || ent(DBMS_XMLGEN.CONVERT(v_p.lab), v_p.aid, CASE WHEN v_fl THEN 'card' ELSE 'metric' END)
                        || ' <b>+' || fmt_num(v_p.d) || '</b> <span class="sh">'
                        || CASE WHEN v_pct < 1 THEN '&lt;1' ELSE TO_CHAR(v_pct) END || '%</span>'
                        || CASE WHEN v_fl
                                THEN ' <span class="st"><i class="dotk '
                                     || CASE WHEN v_gsev(v_p.grp) = 2 THEN 'large' ELSE 'moderate' END
                                     || '" aria-hidden="true"></i>finding</span>'
                                ELSE ' <span class="st nf">inside normal</span>' END
                        || '</li>';
                ELSIF v_p.d > 0 THEN
                    v_small := v_small + v_p.d;
                    v_nsm   := v_nsm + 1;
                END IF;
            END LOOP;
            IF v_nsm > 0 THEN
                v_bar := v_bar || '<i class="att-s att-small" style="flex-grow:' || imp_tok(v_small)
                    || '" title="' || v_nsm || ' smaller part' || CASE WHEN v_nsm > 1 THEN 's' END
                    || ': +' || fmt_num(v_small) || ' AAS"></i>';
                v_lg := v_lg || '<li class="att-more">+ ' || v_nsm || ' smaller ('
                    || fmt_num(v_small) || ' AAS)</li>';
            END IF;
            v_rest := v_dd - v_pos;
            IF v_rest > 0.01 * v_dd THEN
                v_bar := v_bar || '<i class="att-s att-rest" style="flex-grow:' || imp_tok(v_rest)
                    || '" title="Not in the parts above (classes that fell, or waits outside this'
                    || ' template&#39;s event list): +' || fmt_num(v_rest) || ' AAS"></i>';
            END IF;
            -- the largest drops: the parts are sorted largest first, so walk backwards
            FOR k2 IN REVERSE 1 .. v_parts.COUNT LOOP
                EXIT WHEN v_parts(k2).d >= 0 OR v_nfell >= 3;
                IF -v_parts(k2).d >= 0.01 * v_dd THEN
                    v_fell := v_fell || CASE WHEN v_nfell > 0 THEN ', ' END
                        || DBMS_XMLGEN.CONVERT(v_parts(k2).lab) || ' &minus;' || fmt_num(-v_parts(k2).d);
                    v_nfell := v_nfell + 1;
                END IF;
            END LOOP;
            IF v_fell IS NOT NULL THEN
                v_note := v_note || 'Fell: ' || v_fell || ' AAS. ';
            END IF;
            IF v_pos > v_dd * 1.005 THEN
                v_note := v_note || 'The parts add up to ' || imp_txt(v_pos) || ', more than the DB-time'
                    || ' rise: wait-class time also counts background sessions, DB time does not.';
            END IF;
            DBMS_OUTPUT.PUT_LINE('<div id="att-src" hidden><div class="att-h"><b>Where the extra DB time went</b>'
                || '<span>DB time ' || fmt_num(v_findings(v_dbt).prior_mean * 0.01) || ' &rarr; '
                || fmt_num(v_findings(v_dbt).cur_val * 0.01) || ' AAS, <b>' || imp_txt(v_dd) || '</b></span></div>');
            DBMS_OUTPUT.PUT_LINE('<div class="att-bar" role="img" aria-label="The DB-time rise by wait class and CPU,'
                || ' largest part first">' || v_bar || '</div>');
            DBMS_OUTPUT.PUT_LINE('<ul class="att-lg">' || v_lg || '</ul>'
                || CASE WHEN v_note IS NOT NULL THEN '<p class="att-n">' || RTRIM(v_note) || '</p>' END
                || '</div>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<div id="att-src" hidden><p class="att-n"><b>DB time</b> did not rise: '
                || fmt_num(v_findings(v_dbt).cur_val * 0.01) || ' AAS, against a prior mean of '
                || fmt_num(v_findings(v_dbt).prior_mean * 0.01) || ' AAS.</p></div>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,s=d.getElementById("att-src"),'
            || 't=d.getElementById("att-slot"),c=window.AWR_WAIT_COLORS||{};if(!s)return;'
            || 's.querySelectorAll("[data-wc]").forEach(function(e){var k=e.getAttribute("data-wc");'
            || 'if(c[k])e.style.setProperty("--c",c[k]);});'
            || 'if(t){while(s.firstChild)t.appendChild(s.firstChild);t.hidden=false;}'
            || 's.parentNode.removeChild(s);})();</script>');
      END IF;
    END;
```

Notes for the executor:
- `f` is 07's existing `finding_rec` variable; reusing it here is safe
  (pass 1 is finished).
- `v_p.d >= 0.18 * v_base` decides whether the segment is wide enough for an
  in-bar label; every part is in the legend anyway.
- `TO_CHAR(v_pct)` of a rounded number has no decimal separator, so it is
  NLS-safe; `imp_tok` and `fmt_num` are the only other numbers.
- `v_nsm || ' smaller part'` relies on implicit integer conversion, as the
  rest of the file does.

**Verify**: `./lint.sh` → clean. `grep -c 'id="att-src"' sql/07_summary.sql` → `2`.
`awk 'length($0) > 2400' sql/07_summary.sql | wc -l` → `0`.
`grep -nP '[^\x00-\x7F]' sql/07_summary.sql` → no output.

### Step 4: CSS

In `sql/_style.sql`, after the `.hero .snapnote{…}` line (line 1203), add:

```sql
    DBMS_OUTPUT.PUT_LINE('.hero .att{margin:var(--s5) 0 0;max-width:60em}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-h{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:4px 16px;font-size:13.5px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-h b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-bar{display:flex;gap:2px;height:24px;margin:8px 0 8px}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-s{--c:var(--muted);flex-basis:0;min-width:3px;display:flex;align-items:center;overflow:hidden;padding:0 7px;border-radius:3px;background:var(--c);color:#fff;font-size:11.5px;font-weight:600;font-style:normal;white-space:nowrap;text-shadow:0 0 2px rgba(0,0,0,.45)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-s.nf{background:repeating-linear-gradient(135deg,var(--c) 0 4px,transparent 4px 8px);box-shadow:inset 0 0 0 1px var(--c)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-s.att-small,.hero .att-s.att-rest{--c:var(--hairline);color:var(--ink-soft);text-shadow:none}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg{display:flex;flex-wrap:wrap;gap:4px 18px;margin:0;padding:0;list-style:none;font-size:12.5px;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg li{display:inline-flex;align-items:center;gap:6px}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg .sw{--c:var(--muted);display:inline-block;width:10px;height:10px;border-radius:2px;background:var(--c)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg .sw.nf{background:repeating-linear-gradient(135deg,var(--c) 0 3px,transparent 3px 6px);box-shadow:inset 0 0 0 1px var(--c)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg .st{display:inline-flex;align-items:center;gap:5px}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-lg .st.nf,.hero .att-lg .att-more{color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.hero .att-n{margin:6px 0 0;font-size:12.5px;color:var(--muted)}');
```

(Custom properties used: `--s5`, `--ink`, `--ink-soft`, `--muted`,
`--hairline` — all defined for light and dark at the top of the file.)

**Verify**: `./lint.sh` → clean. `grep -c "\.hero \.att" sql/_style.sql` → `15`.
The demo twin lifts `_style.sql` literally; nothing to port.

### Step 5: The twin in `demo/awrdemo/sections/s07_summary.py`

In `emit` (line 336), after `evs = _events(w) if flagcls else []` (line 363)
and before `meta = (…` (line 366), port step 3 line for line:

- Parts: iterate `findings` in their existing order (it is the PL/SQL's
  `heat_pos` order). For `f.domain == "WAIT"` or
  `(f.domain, f.name) == ("LOAD", "DB CPU")` with `f.cur` and `f.mu` not
  None: `lab = "CPU"` or the class (`f.name[len("Wait class: "):]`),
  `d = (f.cur - f.mu) * h.metric_scale(f.domain, f.name)`,
  `grp = h.impact_group(f.domain, f.name, f.family)`,
  `aid = h.card_id(grp) if grp in lead else _find_id(f)`.
  Sort with `parts.sort(key=lambda p: -p["d"])` (stable = the PL/SQL
  insertion sort with a strict `>`).
- `dd`: the same value 07's `g_imp('DBTIME')` gives (plan 020 built an
  `imp` dict in `emit`; use `imp.get("DBTIME")`).
- Emit the identical strings: `h.esc` for `DBMS_XMLGEN.CONVERT`,
  `h.fmt_num`, `h.imp_tok`, `h.imp_txt`, `h.ent`,
  `int(h.ora_round(d / dd * 100, 0))` for `ROUND(...)`, the same
  thresholds (0.01, 0.18, 1.005) and the same `<script>` text (one string;
  the PL/SQL concatenation has no separators).
- Only when `order` is non-empty and `dd is not None` and the DB time row
  exists, exactly like the PL/SQL `IF`.

**Verify**: `python3 demo/gen_demo_report.py` → three `wrote …` lines;
again → same `md5sum docs/examples/demo_busy_db*.html`. Then:
- `grep -c 'id="att-src"' docs/examples/demo_busy_db.html` → `1`
- `grep -o 'class="att-s[^"]*" data-wc="[^"]*"' docs/examples/demo_busy_db.html`
  → the first line is `class="att-s" data-wc="User I/O"` and a line with
  `class="att-s nf" data-wc="CPU"` exists (CPU grew but is not a finding in
  the demo).
- `grep -nP '[^\x00-\x7F]' docs/examples/demo_busy_db.html | head -1` → no output.

If the first part is not User I/O, STOP (see STOP conditions).

### Step 6: About note

In `sql/19_reference.sql`, at the end of the "Verdict" `<dd>` (line 232,
before `</dd>');`), add the sentence:
" <b>Where the extra DB time went</b>: the DB-time rise split into DB CPU and each wait class (Current minus prior mean, average active sessions), largest first; solid = behind a finding, hatched = grew but stayed inside its normal range. Wait-class time counts background sessions too, so the parts can add up to slightly more than the rise."

Keep the source line under 2499 characters: put it on its own
`|| '…'` continuation line like the lines around it. Pure ASCII.

**Verify**: `./lint.sh` → clean; regenerate the demo;
`grep -c 'Where the extra DB time went</b>' docs/examples/demo_busy_db.html` → `1`.

### Step 7: Browser check (`demo/verify_report.js`)

In section "6. phase 4" (the `page.evaluate` that starts at line 809; it
runs for every design) add to the `page.evaluate` result:

```js
      // v1.7: the DB-time breakdown under the verdict
      const att = document.getElementById('att-slot');
      out.att = (att && !att.hidden && vis(att)) ? att.querySelectorAll('.att-s').length : 0;
      out.attSrcGone = !document.getElementById('att-src');
      const wcs = window.AWR_WAIT_COLORS || {};
      out.attColors = [...document.querySelectorAll('#att-slot [data-wc]')]
        .every(e => !wcs[e.getAttribute('data-wc')] || !!e.style.getPropertyValue('--c'));
```

and after the `console.log('phase 4', …)` line:

```js
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !p4.att) fail('DB-time breakdown: not shown under the verdict');
    if (!p4.attSrcGone) fail('DB-time breakdown: #att-src left in the page');
    if (!p4.attColors) fail('DB-time breakdown: a part has no wait-class colour');
```

(`file` is the Node-side path, line 105; `vis` is defined inside that
`page.evaluate` at line 810 — check with
`grep -n "const file\|const vis" demo/verify_report.js`.) The regex covers
the three demo pages (`demo_busy_db.html`, `_quiet`, `_dashboard`). Add a
line to the header comment's check list.

**Verify**: `node --check demo/verify_report.js` → exit 0; the browser smoke
test on the classic and the dashboard demo → `verify: OK` each. The
existing "every visible a.ent is clicked" check now also clicks the
legend's links; it must still pass. In the dashboard a legend link to a
card (`#f-io`, …) lands inside the findings table: `reveal()` opens the
`details.drow` that holds the card.

### Step 8: Documentation

- `CHANGELOG.md`, `## Unreleased` → `### Report`: "**The verdict shows where
  the extra DB time went.** A bar under the verdict splits the DB-time rise
  into DB CPU and each wait class (AAS above the prior mean, largest
  first), solid when the part is behind a finding, hatched when it grew but
  stayed normal, with the classes that fell named under it. Same numbers as
  the finding cards' impact."
- `CLAUDE.md`, "Summary view pieces" table, verdict row: add
  "`#att-slot` (07 fills: DB-time breakdown, `.att-h` / `.att-bar` /
  `.att-lg`, parts coloured from `AWR_WAIT_COLORS` via `--c`)"; in the
  "Relocation pattern" paragraph add `#att-slot` (07) to the list of slots.

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- Demo greps in step 5 (block present, User I/O first, CPU hatched).
- `demo/verify_report.js` (step 7): visible, source removed, colours set,
  entity links clickable.
- Edge cases you cannot run without a database but must reason through in
  review (write them in the PR description): DB time row missing → no
  block; DB time did not rise → the one-line note; no finding → no block;
  parts sum above the rise → the background note; a class that fell → the
  "Fell:" list.

## Done criteria

- [ ] `./tools/check.sh` exits 0
- [ ] `grep -c 'id="att-slot"' docs/examples/demo_busy_db.html` → `1` and `grep -c 'id="att-src"' docs/examples/demo_busy_db.html` → `1`
- [ ] Demo: the first `att-s` part is `User I/O`; a hatched `CPU` part exists
- [ ] `demo/verify_report.js` → `verify: OK` on `demo_busy_db.html` and on `demo_busy_db_dashboard.html` (one at a time)
- [ ] `grep -c 'id="att-slot"' docs/examples/demo_busy_db_dashboard.html` → `1` (the bar is in every design)
- [ ] `grep -nP '[^\x00-\x7F]' sql/07_summary.sql sql/00_params.sql sql/_style.sql sql/19_reference.sql` → no output
- [ ] Only in-scope files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Plan 020 is not DONE, or `impact_group` / `g_imp` / `imp_tok` / `imp_txt`
  do not exist with the meanings described above.
- The excerpts above do not match the live code (other than plan 020's
  documented changes).
- The demo's first part is not User I/O, or the parts in the demo add up to
  more than 1.5 times the DB-time rise (the wait-class data would then be
  far from foreground DB time — report the numbers instead of tuning the
  thresholds).
- `./lint.sh` flags declaration order and moving the TYPE above the
  includes does not fix it.
- verify_report block 7 (dashboard: KPI cards, findings table) starts
  failing after this plan: the bar must not change the cards, the DB time
  card's `h3`, or anything the design script reads.

## Maintenance notes

- **Same numbers as the cards**: the bar's parts are exactly plan 020's
  impacts (per wait class, plus DB CPU). If the impact definition changes
  (for example to foreground-only wait time, `time_waited_micro_fg`), change
  both together. Using ASH (`AWR_DATA.ashx.winfg`, foreground samples per
  class per window) would be closer to DB time, but would disagree with the
  cards and the Wait classes table; that is an owner decision.
- The bar is Summary-only and JavaScript-only (relocation). Every number is
  also in "All sections" (Wait classes table, DB CPU row).
- Colours come from `window.AWR_WAIT_COLORS` at relocation time; a new wait
  class without a palette entry falls back to `--muted` (grey).
- In the dashboard design the bar stays in the hero, above the KPI cards
  (`div.dkpis`, inserted after `section#verdict` by `js_design.js`); the
  DB-time KPI and the bar show the same DB-time rise from different
  angles. If the dashboard later moves the hero's pieces, keep `#att-slot`
  with the verdict.
- **Needs owner DB run** (dbmint, `ssh -p 2200 oracle@dbmint`, never 2201;
  rsync without `--delete`). dbmint keeps 35 days of AWR, so the September
  dates this plan first used return empty windows now: probe first
  (snapshots per day and per `startup_time`) and pin inside a
  restart-free stretch. On 2026-11-19 that was 2026-11-07 14:45 to
  2026-11-09 16:15, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h` (a heavy,
  wait-dominated blocking hour against eight quiet ones).
  1. A quiet pinned hourly window: rc 0, 29/29 `AWR-SECTION` pairs (20
     before sections 20-28); expect either no block (no finding) or the
     "did not rise" note.
  2. A busy wait window (the one above): the bar is shown; each part's AAS
     equals Current minus prior mean of its row in the "Wait classes"
     table (All sections) to 3 decimals; the sum of the parts is within a
     few percent of the DB-time rise, or the background note shows.
  3. If a CPU-heavy window exists in the retention ("mostly CPU"): CPU is
     the first part.
  4. The busy window again with `DESIGN=dashboard`: the bar shows in the
     hero above the KPI cards; the DB-time KPI still reads "mostly wait".
  5. `demo/verify_report.js` on each report, one at a time.
