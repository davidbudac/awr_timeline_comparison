# Plan 026: The Physical I/O card names its top statement, and the plan-change card that explains it sits right below

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/17_narrative.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/js_design.plsql sql/lib/src/css_design.css sql/lib/css_design.plsql demo/awrdemo/sections/s17_narrative.py demo/verify_report.js`
> Plan 025 (executed before this one) edits `sql/_style.sql` and
> `demo/verify_report.js`; those changes are expected. Compare only the
> excerpts quoted under "Current state": each must still be present. An
> excerpt that is gone or restructured is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none strictly; execute after plan 025 (both edit `demo/verify_report.js` block 6 and `sql/_style.sql`)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: 17, 18 and the twins are
  unchanged (every 17 excerpt and line number below still holds);
  `sql/_style.sql` moved +7 (refreshed). New: the `design` option. In
  `design=dashboard` the design script builds a KPI card and a findings
  row from every `article.fc` in `#findings .cards`, so the moved plan card
  would become a fake finding there; the dashboard already shows "What
  changed around it" in a column beside the findings, so new Step 5b sends
  the explaining card back there in that design. verify_report's `cards`
  line already excludes plan-change cards (`:not(.chg)`), so old Step 7.2
  is gone; Step 7's checks are design-aware. The demo writes three pages.
  Section 23 (plan shape) adds a link into the plan card's `.evl` by id:
  unaffected by the move.

## Why this matters

On the demo report the verdict says "Physical reads 5.4x normal, most of
it on ORDERS_APP.ORDER_LINES" and "Likely source: 7k2m9dx4qp1zb ran with a
new plan". But the Physical I/O finding card — where a reader looks for the
evidence — lists the segment, the file and two wait events and never names
the statement doing the reads; the plan-change card that explains the
whole story sits further down in a separate "What changed around it"
block, after every finding. The reader has to connect cause and effect by
hand. This plan (1) adds a "SQL" evidence row to the Physical I/O card:
the statement reading the most blocks in the Current window, with its
normal, its gets per execution then and now, and its plan change; and
(2) moves that statement's plan-change card directly under the Physical
I/O card with an "explains Physical I/O" chip. The original Mock D design
had the Top-SQL row on this card; it was dropped in v1.6.0 as a conscious
divergence (`design/HANDOFF_report_redesign.md`, "Card evidence follows
phase 2's rules ... the mock also lists the Top SQL by reads"). The owner
asked for it back (UX review, 2026-11-17).

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript with `DBMS_OUTPUT.PUT_LINE('...')`; JavaScript is therefore
  inside PL/SQL string literals (a single quote is written `''`).
- `sql/17_narrative.sql` runs LAST. It computes cross-section facts and
  prints them into a hidden `<div id="narr-src">`; one inline `<script>`
  then MOVES each piece into place while the page parses (the "relocation
  pattern"): the likely-source line into the verdict, count pills, notes,
  and evidence rows onto the Physical I/O finding card (`#f-io`, emitted by
  `sql/07_summary.sql`).
- `sql/18_sqlmon.sql` emits one plan-change card per statement whose plan
  changed into the Current window (`<article class="panel fc chg"
  id="f-plan-<sql_id>" ... hidden>`) and its own script moves it into
  07's `#changes-slot` and unhides `section#s-changes` ("What changed
  around it"). 12 then moves its configuration card (`#f-config`) into the
  same slot. Both run BEFORE 17.
- `demo/` is a docs-only Python twin that renders
  `docs/examples/demo_busy_db.html`; `demo/awrdemo/sections/s17_narrative.py`
  is 17's twin. It lifts 17's relocation `<script>` verbatim from the SQL
  (`s17_narrative.py:470-475`: from the line starting
  `<script>(function(){var d=document,src=` to the first line ending
  `})();</script>`, every line must be literal-only), so a new script line
  must contain no PL/SQL variable.

R1 in `sql/17_narrative.sql` (lines 318-544) runs only when physical reads
moved LARGE (`IF big('physical reads') THEN`). It finds the top file, the
top segment and a "newcomer" SQL — a statement in the Current window's
top-N by physical reads that is in NO prior window's top-N. The newcomer
query ends at lines 490-495:

```sql
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_sqlid  := q.sql_id;
                v_sql_rd := q.disk_reads;
            END LOOP;
        END;
```

The card's SQL evidence row exists ONLY for a newcomer, lines 538-543:

```sql
        IF v_sqlid IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>SQL</dt><dd><span class="id">'
                || ent(v_sqlid, anchor_id('sq-preads', v_sqlid), 'sql') || '</span><span class="de">'
                || nbu(fmt_num(v_sql_rd) || ' blocks read; new in the top ' || TO_CHAR(v_top_n))
                || '</span></dd><div class="m"><span class="d s-plain">&#10010; new</span></div></div>';
        END IF;
    END IF;
```

On the demo the top statement by physical reads, `7k2m9dx4qp1zb`, was
already in the top-N before (it just switched to a worse plan), so the
card shows no SQL at all. The Segment row (lines 519-529) is the pattern
for a ranked-not-scored row:

```sql
        IF v_seg IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>Segment</dt><dd><span class="id">'
                || ent(esc(v_seg), anchor_id('sg', v_seg), 'segment') || '</span><span class="de">'
                || nbu(fmt_num(v_seg_cur) || ' blocks read'
                       || CASE WHEN v_seg_mu IS NOT NULL THEN ', normal ' || fmt_num(v_seg_mu) END)
                || '</span></dd><div class="m" title="Ranked, not scored">'
                || delta_span(v_seg_cur, v_seg_mu, NULL, 'Y') || '<span class="ns">not scored</span></div></div>';
```

The R1 variable declarations, lines 94-104 (plain variables must stay
ABOVE the `@@sql/lib/...` includes that start at line 122; lint check 14):

```sql
    -- R1 detail carriers
    v_file      VARCHAR2(600);
    ...
    v_sqlid     VARCHAR2(13);
    v_sql_rd    NUMBER;
    v_big_pr    BOOLEAN := FALSE;
```

The likely-source line (lines ~996-1023) uses `v_sqlid` (the newcomer);
this plan does NOT change it.

The emit block and the relocation script, lines 1054-1066:

```sql
        IF v_ev_io IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<div data-ev-for="f-io">' || v_ev_io || '</div>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('</div>');
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,src=d.getElementById("narr-src");if(!src)return;');
        ...
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll("[data-ev-for]").forEach(function(x){var c=d.getElementById(x.getAttribute("data-ev-for")),dl=c?c.querySelector("dl.ev"):null;if(!dl)return;var f=dl.firstChild;while(x.firstChild)dl.insertBefore(x.firstChild,f);});');
        DBMS_OUTPUT.PUT_LINE('src.parentNode.removeChild(src);})();</script>');
```

How every query in 17 reads the compared windows: `WITH
@@sql/lib/windows_cte.sql` followed by either `,` and more CTEs, or
directly by a `SELECT` (as in `sql/18_sqlmon.sql:766-782`, which reads one
statement's per-window `DBA_HIST_SQLSTAT` deltas):

```sql
            FOR r IN (
                WITH
                @@sql/lib/windows_cte.sql
                SELECT w.week_offset,
                       SUM(NVL(s.elapsed_time_delta, 0)) / 1e6 AS ela_s,
                       ...
                FROM   valid_windows w
                JOIN   dba_hist_sqlstat s
                    ON s.dbid = w.dbid
                   AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                   AND s.instance_number = w.instance_number
                WHERE  s.sql_id = v_id
                GROUP BY w.week_offset
                ORDER BY w.week_offset
            ) LOOP
```

`DBA_HIST_SQLSTAT` has real `*_DELTA` columns (`disk_reads_delta`,
`buffer_gets_delta`, `executions_delta`, `plan_hash_value`); `week_offset
= 0` is the Current window, `> 0` the prior windows. Section 06 ranks
every statement by `disk_reads_delta` per window and gives each row of its
"By physical reads" table the id `sq-preads-<sql_id>`
(`sql/06_top_sql.sql:200` and `:490`), so the Current window's top
statement by reads always has that row.

The 17 code comment at lines 954-957 records a live Oracle quirk: a
`SELECT COUNT(*), (SELECT <agg> FROM ...) FROM t` raises ORA-00937; use
only independent scalar subqueries `FROM dual` (as R9 does).

**Report designs (since `5594f2c`).** The report has a `design`
substitution variable: `classic` (default), `quiet`, `dashboard`;
presentation only. `quiet` / `dashboard` add a stylesheet
(`sql/lib/css_design.plsql`, GENERATED from `sql/lib/src/css_design.css`)
and a script (`sql/lib/js_design.plsql`, GENERATED from
`sql/lib/src/js_design.js`; regenerate with `tools/js2plsql.sh css_design`
/ `tools/js2plsql.sh js_design`). The design script's `DOMContentLoaded`
handler is the page's LAST one, so it runs after 17's relocation script
(which runs while the page parses). Project rule: design-specific rules and
behaviour go into these two source files, never into `sql/_style.sql` or a
section. Classic and quiet share one layout: this plan applies to them as
written. The **dashboard** design (`js_design.js`, function `dashboard()`,
line 302) runs, in order:

```js
function dashboard(){
  var bd=doc.body;
  palette();
  activityTabs();
  kpis();
  findTable();
```

- `kpis()` (line 212) makes one KPI card per
  `$$("#findings .cards > article.fc")` (except `#f-dbtime`);
- `findTable()` (line 251) makes one findings row per
  `$$(":scope > article.fc",cw)` with `cw` = `#findings > .cards`, and
  moves `#s-changes` (when not hidden) into `aside.dside`, a column right
  beside the findings table ("What changed around it" next to the
  findings is the dashboard's own answer to cause-next-to-effect).

A plan-change card moved by this plan into `#findings .cards` would
therefore become a fake KPI card and a fake finding row in the dashboard,
and verify_report's block 7 would fail (`KPI cards N (expected M)`). In
that design the explaining card goes back to `#changes-slot` (Step 5b).

Two other new pieces touch the plan card and are unaffected by the move:
section 23 (`sql/23_plan_flame.sql`, `js_planflame`) adds an `a.pf-cl`
"Plan shape" link into `#f-plan-<sql_id> .evl` on `DOMContentLoaded`
(found by id, wherever the card is); and verify_report block 6's finding
card list is now
`const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];`
(line 849), which already excludes every plan-change card (they carry
class `chg`), moved or not. Its plan-card check (lines 814-816) is still:

```js
      const pcs = [...document.querySelectorAll('article.fc[id^="f-plan-"]')];
      ...
      out.planOk = pcs.every(c => c.closest('#changes-slot') && vis(c)
```

Repo rules that apply here:

- **Never type a tilde** in any `sql/` file, not even in a comment (every
  section runs under `SET DEFINE '~'`). Lint check 3.
- **Emitted text pure ASCII** (lint check 25): `&rarr;`, `&uarr;` entities
  in markup; do NOT write a backslash-u escape in this plan's JavaScript
  (agent tool input can turn it into the character itself); the code
  below needs none.
- `PUT_LINE` source lines under 2499 characters; never end a `--` comment
  with `;` inside a top-level SQL statement (harmless inside these PL/SQL
  cursor loops, but keep comments `;`-free anyway).
- An empty VARCHAR2 IS NULL in Oracle: guards are `IS NOT NULL`, never
  `<> ''` (lint check 31).
- Entity links only through `ent(html, id, kind)` (lint check 21); a link
  whose target id was never emitted is unwrapped to plain text by the
  client, so linking `f-plan-<id>` is safe even when no plan card exists.
- The report has no global link colour: the new plain `<a>` in the chip
  needs a CSS rule (verify_report fails on browser-blue links).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate the design script / stylesheet | `tools/js2plsql.sh js_design` and `tools/js2plsql.sh css_design` | exit 0 |
| Generated files fresh | `tools/js2plsql.sh --check` | exit 0 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote ...` lines: `demo_busy_db.html`, `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | exit 0 |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same for `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` each (about 3 min each; one at a time, never in parallel) |
| ASCII | `grep -nP '[^\x00-\x7F]' sql/17_narrative.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css` | no output |

There is no database available to you; the owner's checks are in
"Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `sql/17_narrative.sql`
- `sql/_style.sql` (two CSS lines)
- `demo/awrdemo/sections/s17_narrative.py`
- `demo/verify_report.js` (block 6)
- `sql/lib/src/js_design.js`, `sql/lib/src/css_design.css` and the
  regenerated `sql/lib/js_design.plsql`, `sql/lib/css_design.plsql`
  (Step 5b: the dashboard design only)
- `docs/examples/demo_busy_db.html`, `docs/examples/demo_busy_db_quiet.html`,
  `docs/examples/demo_busy_db_dashboard.html` (regenerated)
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope** (do NOT touch):
- The likely-source rule and the R1 note text (`v_tail`): unchanged, they
  keep using the newcomer `v_sqlid`.
- `sql/18_sqlmon.sql` and `sql/12_param_changes.sql`: the plan card and the
  config card are moved by 17's script, not changed at the source.
- `sql/07_summary.sql`: the card evidence cap (2 rows from 07 on the I/O
  card) stays.
- Linking a plan card to any card other than Physical I/O (e.g. DB time):
  deferred, see Maintenance notes.
- `sql/23_plan_flame.sql` / `js_planflame` (its "Plan shape" link into the
  plan card works wherever the card is) and every other section 20-28.
- The dashboard's KPI cards, findings table and side column beyond
  Step 5b's lines.
- `sql/fleet/*` and the fleet wrappers.

## Git workflow

- Branch: `advisor/026-cause-next-to-effect` from `main`.
- Conventional commits, e.g.
  `feat(report): I/O card names its top statement; the plan card that explains it follows`.
- Do NOT push or open a PR unless the operator instructed it.

## Target UI

```
 [ Physical I/O card ]
   Segment  ORDERS_APP.ORDER_LINES   95.07 M blocks read, normal 8.489 M     x11.2  not scored
   File     ts_orders_data.301...    345.0 k MB read, normal 74.01 k         x4.7   not scored
   SQL      7k2m9dx4qp1zb            43.43 M blocks read, normal 3.0xx M;    x14.x  not scored
                                     700.0 gets per execution, was 38.00;
                                     new plan 3197245811 -> 2088341150   (link to the plan card)
   Event    db file scattered read   ...
 [ Plan change card for 7k2m9dx4qp1zb ]   <- moved here, header chip "explains Physical I/O ^"
 [ next finding card ... ]
 What changed around it: only the configuration card is left there
```

## Steps

### Step 1: Declare the new R1 carriers

In `sql/17_narrative.sql`, directly after `v_big_pr    BOOLEAN := FALSE;`
(line 104), add:

```sql
    -- plan 026: the statement reading the most blocks in the Current window
    -- (any statement, newcomer or not), for the Physical I/O card
    v_tq_id     VARCHAR2(13);
    v_tq_cur    NUMBER;   -- blocks read, Current window
    v_tq_mu     NUMBER;   -- mean blocks read over the prior windows it ran in
    v_tq_gpe    NUMBER;   -- buffer gets per execution, Current window
    v_tq_gpe_mu NUMBER;   -- the same over the prior windows (sum of gets / sum of executions)
    v_tq_ph     NUMBER;   -- its plan in the Current window (the one reading the most blocks)
    v_tq_ph_mu  NUMBER;   -- its most executed plan over the prior windows
```

**Verify**: `./lint.sh` → clean (check 14 would flag a misplaced declaration).

### Step 2: Find the statement and its numbers

In R1, directly after the newcomer block's `END;` (line 495, the `END;`
right after `v_sql_rd := q.disk_reads; END LOOP;`), add:

```sql
        -- plan 026: the statement reading the most blocks in the CURRENT
        -- window, newcomer or not (the I/O card names it), then its prior
        -- windows, gets per execution and plans.  Point lookups by sql_id
        -- over the compared windows, same join as section 06.
        BEGIN
            FOR q IN (
                WITH
                @@sql/lib/windows_cte.sql
                SELECT s.sql_id, SUM(NVL(s.disk_reads_delta, 0)) AS disk_reads
                FROM   valid_windows w
                JOIN   dba_hist_sqlstat s
                    ON s.dbid = w.dbid
                   AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                   AND s.instance_number = w.instance_number
                WHERE  w.week_offset = 0
                GROUP BY s.sql_id
                HAVING SUM(NVL(s.disk_reads_delta, 0)) > 0
                ORDER  BY disk_reads DESC, s.sql_id
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_tq_id := q.sql_id;
            END LOOP;
        END;
        IF v_tq_id IS NOT NULL THEN
            FOR q IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                tq_win AS (
                    SELECT w.week_offset,
                           SUM(NVL(s.disk_reads_delta, 0))  AS rd,
                           SUM(NVL(s.buffer_gets_delta, 0)) AS gets,
                           SUM(NVL(s.executions_delta, 0))  AS execs
                    FROM   valid_windows w
                    JOIN   dba_hist_sqlstat s
                        ON s.dbid = w.dbid
                       AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                       AND s.instance_number = w.instance_number
                    WHERE  s.sql_id = v_tq_id
                    GROUP BY w.week_offset
                )
                SELECT MAX(CASE WHEN week_offset = 0 THEN rd END) AS cur_rd,
                       AVG(CASE WHEN week_offset > 0 THEN rd END) AS mu_rd,
                       MAX(CASE WHEN week_offset = 0 THEN gets END)
                           / NULLIF(MAX(CASE WHEN week_offset = 0 THEN execs END), 0) AS gpe,
                       SUM(CASE WHEN week_offset > 0 THEN gets END)
                           / NULLIF(SUM(CASE WHEN week_offset > 0 THEN execs END), 0) AS gpe_mu
                FROM   tq_win
            ) LOOP
                v_tq_cur    := q.cur_rd;
                v_tq_mu     := q.mu_rd;
                v_tq_gpe    := q.gpe;
                v_tq_gpe_mu := q.gpe_mu;
            END LOOP;
            -- its plans: the Current window's (most blocks read) and the
            -- prior windows' most executed one; two independent scalar
            -- subqueries FROM dual (an outer aggregate next to a scalar
            -- subquery raises ORA-00937, see R9 below)
            FOR q IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                tq_pl AS (
                    SELECT CASE WHEN w.week_offset = 0 THEN 0 ELSE 1 END AS pri,
                           s.plan_hash_value AS ph,
                           SUM(NVL(s.disk_reads_delta, 0)) AS rd,
                           SUM(NVL(s.executions_delta, 0)) AS execs
                    FROM   valid_windows w
                    JOIN   dba_hist_sqlstat s
                        ON s.dbid = w.dbid
                       AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                       AND s.instance_number = w.instance_number
                    WHERE  s.sql_id = v_tq_id
                      AND  s.plan_hash_value <> 0
                    GROUP BY CASE WHEN w.week_offset = 0 THEN 0 ELSE 1 END, s.plan_hash_value
                )
                SELECT (SELECT MAX(ph) KEEP (DENSE_RANK FIRST ORDER BY rd DESC)
                        FROM tq_pl WHERE pri = 0) AS cur_ph,
                       (SELECT MAX(ph) KEEP (DENSE_RANK FIRST ORDER BY execs DESC)
                        FROM tq_pl WHERE pri = 1) AS prior_ph
                FROM   dual
            ) LOOP
                v_tq_ph    := q.cur_ph;
                v_tq_ph_mu := q.prior_ph;
            END LOOP;
        END IF;
```

**Verify**: `./lint.sh` → clean.
`grep -c 'v_tq_id' sql/17_narrative.sql` → 6 or more.

### Step 3: The SQL evidence row

Replace the newcomer-only row (lines 538-543, quoted above, the
`IF v_sqlid IS NOT NULL THEN ... END IF;` right before R1's closing
`END IF;`) with:

```sql
        -- plan 026: the statement reading the most blocks in the Current
        -- window -- ranked, not scored: a plain ratio -- with its gets per
        -- execution and, when its plan changed, a link to the plan card
        -- (f-plan-<sql_id>, section 18; unwrapped to text when 18 drew none)
        IF v_tq_id IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>SQL</dt><dd><span class="id">'
                || ent(v_tq_id, anchor_id('sq-preads', v_tq_id), 'sql') || '</span><span class="de">'
                || nbu(fmt_num(v_tq_cur) || ' blocks read'
                       || CASE WHEN v_tq_mu IS NOT NULL THEN ', normal ' || fmt_num(v_tq_mu) END
                       || CASE WHEN v_tq_gpe IS NOT NULL AND v_tq_gpe_mu IS NOT NULL
                               THEN '; ' || fmt_num(v_tq_gpe) || ' gets per execution, was '
                                    || fmt_num(v_tq_gpe_mu) END)
                || CASE WHEN v_tq_ph IS NOT NULL AND v_tq_ph_mu IS NOT NULL AND v_tq_ph <> v_tq_ph_mu
                        THEN '; ' || ent('new plan ' || TO_CHAR(v_tq_ph_mu) || ' &rarr; ' || TO_CHAR(v_tq_ph),
                                         'f-plan-' || v_tq_id, 'sql') END
                || CASE WHEN v_tq_id = v_sqlid THEN '; new in the top ' || TO_CHAR(v_top_n) END
                || '</span></dd><div class="m" title="Ranked, not scored">'
                || CASE WHEN v_tq_mu IS NULL
                        THEN '<span class="d s-plain">&#10010; new</span>'
                        ELSE delta_span(v_tq_cur, v_tq_mu, NULL, 'Y') || '<span class="ns">not scored</span>' END
                || '</div></div>';
        END IF;
        -- a newcomer that is not the top statement keeps its own row
        IF v_sqlid IS NOT NULL AND (v_tq_id IS NULL OR v_sqlid <> v_tq_id) THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>New SQL</dt><dd><span class="id">'
                || ent(v_sqlid, anchor_id('sq-preads', v_sqlid), 'sql') || '</span><span class="de">'
                || nbu(fmt_num(v_sql_rd) || ' blocks read; new in the top ' || TO_CHAR(v_top_n))
                || '</span></dd><div class="m"><span class="d s-plain">&#10010; new</span></div></div>';
        END IF;
```

Note `'f-plan-' || v_tq_id` is the same id section 18 builds for its plan
card (`sql/18_sqlmon.sql:702`, `v_cid := 'f-plan-' || v_pc(c).sql_id`).

**Verify**: `./lint.sh` → clean. `grep -c "<dt>New SQL</dt>" sql/17_narrative.sql` → `1`.

### Step 4: Move the explaining plan card under the I/O card

1. In the emit block, directly after the `IF v_ev_io IS NOT NULL THEN ...
   END IF;` that prints `<div data-ev-for="f-io">` (lines 1054-1056), add:

   ```sql
        -- plan 026: the plan-change card of the I/O card's top statement (if
        -- section 18 drew one) moves right under the I/O card
        IF v_tq_id IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<span data-explains-src="f-plan-' || v_tq_id || '" data-for="f-io"></span>');
        END IF;
   ```

2. In the relocation script, add ONE line directly before the last line
   (`src.parentNode.removeChild(src);})();</script>`). It must be
   literal-only and contain no single quote:

   ```sql
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll("[data-explains-src]").forEach(function(x){var p=d.getElementById(x.getAttribute("data-explains-src")),c=d.getElementById(x.getAttribute("data-for"));if(!p||!c||!c.parentNode||p===c)return;c.parentNode.insertBefore(p,c.nextSibling);p.hidden=false;p.setAttribute("data-explains",c.id);var k=p.querySelector(".fc-k"),sv=c.querySelector(".fc-k .sv"),lb=(sv&&sv.getAttribute("title"))||"the card above";if(k&&!k.querySelector(".xpl")){var s=d.createElement("span");s.className="xpl";s.appendChild(d.createTextNode("explains "));var a=d.createElement("a");a.href="#"+c.id;a.textContent=lb;s.appendChild(a);s.insertAdjacentHTML("beforeend","<i class=\"xu\" aria-hidden=\"true\"> &uarr;</i>");k.appendChild(s);}var sl=d.getElementById("changes-slot"),sc=d.getElementById("s-changes");if(sl&&sc&&!sl.children.length)sc.hidden=true;});');
   ```

   What it does: if both the plan card and the I/O card exist, the plan
   card is inserted right after the I/O card (inside 07's
   `#findings div.cards`, which is Summary-only, like `#s-changes`), gets
   `data-explains="f-io"` and a header chip "explains Physical I/O ↑"
   (the label is the I/O card's `span.sv` title, i.e. `card_label('IO')`;
   the arrow sits in its own `i.xu` so the dashboard design, which shows
   the card in a side column, can hide it; the `\"` sequences are typed
   as backslash + quote, they become escaped quotes in the JS string);
   if that leaves "What changed around it" empty, the section is hidden
   again (the rail link to it stays hidden: the chrome only unhides it
   when the section is visible at `DOMContentLoaded`, which runs after
   this script). With no I/O card or no plan card nothing moves.

3. In the header comment of `sql/17_narrative.sql` (lines 13-24, the
   "Placement" list), add one line under
   `Segment / File / SQL   -> evidence rows ...`:
   `--   the I/O card's top statement's plan-change card (18) -> right under`
   `--                             the I/O card, data-explains="f-io"`
   (no tilde, no trailing `;`).

**Verify**: `./lint.sh` → clean.
`awk 'length($0) > 2400' sql/17_narrative.sql | wc -l` → `0`.
`grep -c 'data-explains-src' sql/17_narrative.sql` → `2`.

### Step 5: CSS for the chip

In `sql/_style.sql`, after the line
`DBMS_OUTPUT.PUT_LINE('.fc .cfg-more{margin:0;padding:var(--s2) 0 0;font-size:12.5px;color:var(--muted)}');`
(line 1368) — and after any lines plan 025 added right there — add:

```sql
    -- plan 026: the "explains <card>" chip on a plan-change card moved under
    -- the finding card it explains (17's relocation script)
    DBMS_OUTPUT.PUT_LINE('.fc .fc-k .xpl{font-size:12px;font-weight:500;color:var(--ink-soft);padding:1px 8px;border:1px solid var(--hairline);border-radius:10px}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-k .xpl a{color:var(--ink);text-decoration:underline;text-decoration-color:var(--hairline);text-underline-offset:3px}');
```

**Verify**: `./lint.sh` → clean.

### Step 5b: The dashboard design keeps the plan card beside the findings

In `design=dashboard` the findings are a table and "What changed around
it" is a column right beside it (see "Report designs" under Current
state): cause and effect are already side by side there, and a plan card
inside `#findings .cards` would become a fake KPI card and finding row.
So the dashboard sends an explaining card back to `#changes-slot`.

1. `sql/lib/src/js_design.js`: directly ABOVE `function dashboard(){`
   (line 302), add:

   ```js
   /* plan 026: a plan-change card that 17 moved under the card it explains
      goes back to "What changed around it", which the dashboard shows
      beside the findings table */
   function explainsBack(){
     var sl=$("#changes-slot"),sc=$("#s-changes");if(!sl)return;
     var ex=$$("#findings article.fc[data-explains]");if(!ex.length)return;
     ex.reverse().forEach(function(p){sl.insertBefore(p,sl.firstChild);});
     if(sc&&sc.hidden){sc.hidden=false;var rl=$('nav.toc a[href="#s-changes"]');if(rl)rl.hidden=false;}
   }
   ```

   and in `dashboard()` call it before `kpis();`:

   ```js
     palette();
     activityTabs();
     explainsBack();
     kpis();
     findTable();
   ```

   (Plan cards come first in the slot, then 12's configuration card, as
   in a report without this plan. The rail link is unhidden because the
   chrome decided its visibility at `DOMContentLoaded`, while the section
   was still hidden; the dashboard's "Jump to" palette lists only shown
   rail links.)
2. Same file, belt and braces against any other `.chg` card in
   `#findings .cards`:
   - in `kpis()` (line 212) replace
     `$$("#findings .cards > article.fc").forEach(function(card){` with
     `$$("#findings .cards > article.fc:not(.chg)").forEach(function(card){`;
   - in `findTable()` (line 251) replace
     `var cards=cw?$$(":scope > article.fc",cw):[];` with
     `var cards=cw?$$(":scope > article.fc:not(.chg)",cw):[];`.
3. `sql/lib/src/css_design.css`: after the `.dside .fc h3{font-size:15px}`
   line (line 355), add:

   ```css
   .dside .fc-k .xpl .xu{display:none}
   ```

   (in the side column the explained card is to the left, not above).
4. Regenerate: `tools/js2plsql.sh js_design` and
   `tools/js2plsql.sh css_design`.

Classic and quiet are not affected (`dashboard()` runs only for
`design=dashboard`; `.dside` exists only there).

**Verify**: `tools/js2plsql.sh --check` → exit 0.
`grep -c 'explainsBack' sql/lib/js_design.plsql` → `2`.
`grep -c 'article.fc:not(.chg)' sql/lib/js_design.plsql` → `2` or more.
`grep -nP '[^\x00-\x7F]' sql/lib/src/js_design.js sql/lib/src/css_design.css` → no output.

### Step 6: Re-port the demo twin

In `demo/awrdemo/sections/s17_narrative.py`:

1. Add, after `_r1_newcomer` (line ~208):

   ```python
   def _r1_top(w):
       """Plan 026: the statement reading the most blocks in the Current window
       (newcomer or not): (sql_id, cur reads, prior mean reads, gets/exec,
       prior gets/exec, Current plan, prior most-executed plan) or None.
       Mirrors 17's three point lookups (prior mean over the prior windows
       the statement ran in; plan 0 ignored)."""
       cur = next((win for win in w.valid_windows if win.week_offset == 0), None)
       if cur is None:
           return None
       m0 = w.window_metrics(cur).sql
       ranked = sorted(((x.reads, sid) for sid, x in m0.items() if x.reads > 0),
                       key=lambda t: (-t[0], t[1]))
       if not ranked:
           return None
       sid = ranked[0][1]
       x0 = m0[sid]
       prior = [w.window_metrics(win).sql.get(sid) for win in w.valid_windows if win.week_offset > 0]
       prior = [x for x in prior if x is not None]
       mu = math.fsum(x.reads for x in prior) / len(prior) if prior else None
       gpe = x0.gets / x0.execs if x0.execs > 0 else None
       pg, px = math.fsum(x.gets for x in prior), math.fsum(x.execs for x in prior)
       gpe_mu = pg / px if px > 0 else None
       by_plan = {}
       for x in prior:
           if x.plan_hash:
               by_plan[x.plan_hash] = by_plan.get(x.plan_hash, 0.0) + x.execs
       ph_mu = max(by_plan, key=lambda p: (by_plan[p], p)) if by_plan else None
       return sid, x0.reads, mu, gpe, gpe_mu, (x0.plan_hash or None), ph_mu
   ```

   Before relying on it, confirm the model's per-window SQL record has the
   fields `reads`, `gets`, `execs`, `plan_hash` (`demo/awrdemo/model.py`,
   `class SqlHour`, line ~626) and that `w.window_metrics(win).sql` is a
   dict `sql_id -> SqlHour` (it is used that way by `_r1_newcomer`).

2. In `emit`, inside `if st.big('physical reads'):`, call
   `top = _r1_top(w)` and replace the newcomer evidence row (the
   `if v_sqlid is not None: ev_io += ('<div class="evr"><dt>SQL</dt>...`
   block, lines ~367-371) with a port of Step 3: the "SQL" row from `top`
   (using `h.ent`, `h.anchor_id('sq-preads', sid)`, `h.nbu`, `h.fmt_num`,
   `h.delta_span(cur, mu, None, 'Y')`, `str(ph_mu) + ' &rarr; ' + str(ph)`
   for the plan link with id `'f-plan-' + sid`, `_tc(w.top_n)` for the top
   N), then the "New SQL" row when `v_sqlid` is set and differs from the
   top `sid`. Keep the exact strings of Step 3.
3. In the `narr-src` output, after the `data-ev-for` line, append
   `'<span data-explains-src="f-plan-' + sid + '" data-for="f-io"></span>'`
   when `top` is not None (same condition and place as Step 4.1).
4. The script line of Step 4.2 is lifted automatically (it sits inside the
   lifted range); do not hand-copy it.
5. Regenerate: `python3 demo/gen_demo_report.py` twice (it writes the
   three design pages); `md5sum docs/examples/demo_busy_db*.html` must be
   the same both times. The quiet / dashboard pages need no twin change:
   the generator reads the regenerated `js_design.plsql` /
   `css_design.plsql`.

**Verify**: `python3 demo/gen_demo_report.py --check` → exit 0.
`grep -c 'data-explains-src="f-plan-7k2m9dx4qp1zb"' docs/examples/demo_busy_db.html` → `1`.
`grep -o '<dt>SQL</dt><dd><span class="id"><a class="ent" href="#sq-preads-7k2m9dx4qp1zb"' docs/examples/demo_busy_db.html | wc -l` → `1`.

### Step 7: Extend the browser smoke test

In `demo/verify_report.js` block 6 ("phase 4"):

1. The plan-card check must accept a card moved under the card it
   explains. Replace

   ```js
      out.planOk = pcs.every(c => c.closest('#changes-slot') && vis(c)
   ```

   with

   ```js
      out.planOk = pcs.every(c => (c.closest('#changes-slot')
          || (c.getAttribute('data-explains') && c.previousElementSibling
              && c.previousElementSibling.id === c.getAttribute('data-explains'))) && vis(c)
   ```

   (the rest of that expression stays) and update its fail message
   (`if (!p4.planOk) fail(...)`, line 863) to
   `'plan-change card incomplete, or neither in #changes-slot nor right under the card it explains'`.
   In the dashboard design the card is back in `#changes-slot` (Step 5b),
   so the first alternative holds there.

2. (Nothing to do.) A plan-change card moved into `#findings .cards` is
   not a finding card; the line
   `const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];`
   (line 849) already excludes it, because every plan-change card carries
   class `chg`. Do NOT change it.

3. After the `out.subsOk = ...` line (and after plan 025's block, if
   present), add:

   ```js
      // plan 026: the I/O card names its top statement by physical reads, and a
      // plan-change card that explains it sits right under it with its chip.
      // The dashboard design keeps it in "What changed around it" instead
      // (a column beside its findings table), chip and all.
      const dashX = document.body.classList.contains('d-dash');
      const io = document.getElementById('f-io');
      out.ioSql = io ? [...io.querySelectorAll('dl.ev .evr > dt')].some(dt => dt.textContent.trim() === 'SQL') : null;
      const ex = [...document.querySelectorAll('article.fc[data-explains]')];
      out.explains = ex.length;
      out.explainsOk = ex.every(p => (dashX ? !!p.closest('#changes-slot')
          : p.previousElementSibling && p.previousElementSibling.id === p.getAttribute('data-explains'))
        && p.querySelector('.fc-k .xpl a[href="#' + p.getAttribute('data-explains') + '"]'));
      const sl = document.getElementById('changes-slot'), sc = document.getElementById('s-changes');
      out.changesOk = !sl || !sc || (sl.children.length > 0) === !sc.hidden;
   ```

   and next to the other `fail(...)` lines:

   ```js
    if (p4.ioSql === false && /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) fail('demo: the Physical I/O card has no SQL evidence row');
    if (!p4.explainsOk) fail('an explaining plan-change card is not right under its card (dashboard: not in #changes-slot) or lacks its chip');
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.explains !== 1) fail('demo: expected the plan card of 7k2m9dx4qp1zb to explain the Physical I/O card, got ' + p4.explains);
    if (!p4.changesOk) fail('"What changed around it" visible while empty, or hidden while it holds a card');
   ```

   (`file` is the report path, defined near the top of the script; the
   existing demo-only checks use the same regex test.) Add to the header
   comment's phase 4 bullet: "the Physical I/O card's SQL row; a
   plan-change card that explains a card sits right under it (dashboard:
   in What changed around it, beside the findings)".

**Verify**: run the browser smoke test on `docs/examples/demo_busy_db.html`
→ `verify: OK`; the printed `phase 4` JSON has `"ioSql":true`,
`"explains":1`, `"explainsOk":true`, `"changesOk":true`, `"planOk":true`.
Then (after it ends, never in parallel) on
`docs/examples/demo_busy_db_dashboard.html` → `verify: OK`, the same five
values in `phase 4`, and its `design dashboard:` line passes the KPI and
findings-table checks (a plan card counted as a finding would fail
`KPI cards N (expected M)`).

### Step 8: Documentation

1. `CHANGELOG.md`, `## Unreleased` → `### Report`: "**Cause next to
   effect.** The Physical I/O card names the statement reading the most
   blocks in the Current window (blocks, gets per execution then and now,
   its plan change), and that statement's plan-change card moves right
   under the card with an "explains Physical I/O" chip."
2. `CLAUDE.md`: in "Relocation pattern" add: 17 also moves the plan-change
   card of the I/O card's top statement (by Current physical reads) right
   after `#f-io` (`data-explains="f-io"`, `span.xpl` chip) and re-hides
   `#s-changes` when that empties it; anything counting finding cards in
   the DOM must exclude `.chg` (plan-change / configuration cards). In
   "Report designs", the dashboard bullet: `explainsBack()` returns an
   explaining card to `#changes-slot` (the side column) before the KPI
   cards and the findings table are built. In the 17 rules list
   (the "Plan-change card" paragraph is fine as is) note: R1's card
   evidence = the top statement by Current physical reads (any), plus the
   newcomer when it differs ("New SQL"); the likely-source line still uses
   the newcomer.

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- `./lint.sh`; `tools/js2plsql.sh --check`; demo regeneration twice (same
  md5 for the three pages); `--check`.
- Browser smoke test with the Step 7 checks (SQL row on the demo's I/O
  card; exactly one explaining plan card on the demo, right under `#f-io`,
  with its chip; "What changed around it" still shows the configuration
  card; every in-page href resolves — the new `f-plan-` entity link and
  the chip link are covered by block 1), on the classic page and then the
  dashboard page (plan card in the side column, no extra KPI / row).
- Manually (optional): Summary view, light and dark: the chip link is not
  browser-blue; clicking it scrolls to the I/O card; the SQL row's "new
  plan ..." link scrolls to the plan card; the "Plan shape" link (section
  23) is still in the moved card's evidence line. In
  `demo_busy_db_dashboard.html`: the chip has no arrow, its link opens the
  Physical I/O row.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `python3 demo/gen_demo_report.py --check` exits 0; two runs give the same md5
- [ ] `./tools/check.sh` prints `check.sh: all checks passed`
- [ ] `demo/verify_report.js` ends with `verify: OK` on `docs/examples/demo_busy_db.html` and then on `docs/examples/demo_busy_db_dashboard.html`, including the Step 7 checks
- [ ] `grep -nP '[^\x00-\x7F]' sql/17_narrative.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css` prints nothing
- [ ] The likely-source code (`v_because` assignments) is unchanged: `git diff 5594f2c -- sql/17_narrative.sql | grep -c 'v_because'` → `0`
- [ ] `git status` shows only in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The R1 excerpts (newcomer query end, SQL evidence row, emit block,
  relocation script) are not found as quoted.
- On the demo, the top statement by Current physical reads is NOT
  `7k2m9dx4qp1zb` (check the demo's "By physical reads" table, the first
  row with `#1` in the Current column): the demo model changed; report
  the actual statement before changing the demo-specific checks.
- `ORA-00937` or any compile error is reported by the owner's DB run for
  the queries of Step 2 (do not restructure them blind).
- The demo twin cannot reproduce the SQL row (e.g. `SqlHour` has no
  `gets` / `execs` / `plan_hash`).
- verify_report's block 4 (entity links) fails on the new `f-plan-` link.
- `sql/lib/src/js_design.js` no longer has `function dashboard(){` calling
  `kpis();` then `findTable();`, or the two selectors quoted in Step 5b.2
  (the dashboard changed shape).
- The dashboard smoke test fails in block 7 (`KPI cards`, `findings
  table`) after Step 5b.

## Maintenance notes

- Cost: Step 2 adds three bounded `DBA_HIST_SQLSTAT` reads, only when R1
  fires (physical reads moved LARGE): one ranking of the Current window,
  two point lookups by `sql_id` over the compared windows. Section 06
  already scans the same rows several times; no new view or grant.
- "Normal" for the statement is the mean over the prior windows it RAN in
  (same convention as R1's segment row), not over every prior window.
- Only the Physical I/O card gets a "cause" today. The DB time card could
  name the statement whose elapsed time grew most (and pull its plan card
  under it); deferred — it needs a rule for when two cards claim the same
  plan card.
- Plans 025 / 022: a moved plan card sits inside `#findings .cards` and has
  no `data-fold`; 025's fold script ignores it, and DOM counts of finding
  cards must exclude `.chg` (verify_report and, after Step 5b,
  `js_design.js` already do).
- Designs: classic and quiet put the plan card under the I/O card; the
  dashboard keeps it in its side column (`explainsBack()`). If the owner
  prefers it inside the Physical I/O row of the dashboard's table, that is
  a change to `findTable()` (append the card to the I/O row's `.dbody`
  and re-show its header there), not to this plan's SQL.
- Reviewer focus: the three queries (dbid / snap / instance join exactly as
  in 06 and 18), the literal-only script line, that the likely source is
  untouched.
- **Needs owner DB run** (the executor has no database). On dbmint (`ssh -p
  2200 oracle@dbmint`, never 2201; rsync without `--delete`). dbmint keeps
  35 days of AWR, so the September windows used before are gone: probe
  first, pin inside a restart-free stretch. On 2026-11-19 the plan-change
  window was `./run_awr_trend.sh <connect> "2026-11-08 11:00" 1 8 10 0 1 h`
  (positionals: target_end win_hours weeks_back top_n inst_num step
  step_unit; plan change of `b84c2ncqhcw23`) and a busy one
  `"2026-11-08 15:00" 1 8 10 0 1 h`; run the plan-change window also with
  `DESIGN=dashboard`: rc 0, 29/29 `AWR-SECTION` pairs (sections 20-28
  added nine), no `ORA-` outside captured SQL text; where physical reads
  moved LARGE, the I/O card has its SQL row and the numbers match a
  read-only spot query (`SELECT sql_id, SUM(disk_reads_delta) FROM
  dba_hist_sqlstat WHERE dbid = <dbid> AND snap_id BETWEEN <Current
  begin+1> AND <end> GROUP BY sql_id ORDER BY 2 DESC FETCH FIRST 3 ROWS
  ONLY`); then `demo/verify_report.js` on each report, one at a time. If
  neither window moves physical reads LARGE, R1 (and this plan's row)
  does not fire: say so instead of claiming a DB check.
