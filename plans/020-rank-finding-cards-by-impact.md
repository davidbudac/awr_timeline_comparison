# Plan 020: Finding cards are ranked by the DB time they added, and Summary shows z capped at 10 sigma

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/lib/finding_cards.plsql sql/lib/band_glyph.plsql sql/07_summary.sql sql/00_params.sql sql/08_overview.sql sql/18_sqlmon.sql sql/19_reference.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/27_instance_map.sql sql/26_window_similarity.sql demo/awrdemo/helpers.py demo/awrdemo/sections/s00_params.py demo/awrdemo/sections/s07_summary.py demo/awrdemo/sections/s08_overview.py demo/awrdemo/sections/s18_sqlmon.py demo/verify_report.js`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts below against the live code before proceeding;
> on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (changes the order of the Summary cards and the verdict sentence on some databases; two PL/SQL blocks must stay in lockstep)
- **Depends on**: none
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: the report designs (`design=quiet|dashboard`, `sql/lib/src/js_design.js`) and the visualization sections 20-28 landed. Line numbers refreshed (`_style.sql`, `19_reference.sql`, `verify_report.js`, `CLAUDE.md`); new step 7b caps the z of the dashboard findings table (it clones All-sections bands, exact z); optional quiet-skin rule for the chip; demo writes three pages; verify on classic + dashboard; DB-run notes updated (29 section pairs, expired dbmint dates).

## Why this matters

The report is a single HTML page that compares one AWR window ("Current")
against the same window in N prior periods. Its Summary view shows one
"finding card" per group of metrics that moved. Today the cards are ordered by
how *unusual* a move is (large before moderate, then the largest |z|), not by
how much it *cost*. In the bundled demo the Network card (+57.9 sigma) looks
as urgent as the Physical I/O card, although Network added about 0.95
average active sessions (AAS) of the extra DB time and Physical I/O about 6.3.
A DBA wants the card that explains the most extra DB time first.

This plan (1) computes each card's **impact** — how many AAS its time
measure (DB time, DB CPU or a wait class) rose above its prior mean — and
orders the cards by it, (2) shows that impact as a small chip on each card
("+6.315 AAS · 70% of the DB-time rise") and as two data attributes later
plans build on (`data-impact`, `data-share`), and (3) caps the printed z of
every band glyph in the Summary view at 10 sigma (">+10σ"), because a z of 57
or "more than 99" means nothing more than "far outside normal" and pulls the
eye to the wrong number. Tables in "All sections" keep the exact z.

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript line by line with `DBMS_OUTPUT.PUT_LINE('…')`. `sql/lib/*.plsql`
  files are fragments `@@`-included inside a section's `DECLARE` block.
- `demo/` is a docs-only Python twin that renders the demo report without
  a database, in three designs: `docs/examples/demo_busy_db.html`
  (classic), `docs/examples/demo_busy_db_quiet.html` and
  `docs/examples/demo_busy_db_dashboard.html` (a plain
  `python3 demo/gen_demo_report.py` writes all three).
  `demo/awrdemo/helpers.py` hand-ports every shared PL/SQL helper; each
  `demo/awrdemo/sections/sNN_*.py` hand-ports `sql/NN_*.sql`. **Every change
  to emitted markup must be made in both, and the demo regenerated and
  committed.** `python3 demo/gen_demo_report.py --check` (part of
  `./tools/check.sh`) fails when any of the three committed pages is stale.
- Two sections order the cards **independently and identically** (the
  project rule "findings are recomputed, not shared"): `sql/00_params.sql`
  (the verdict sentence at the top names the first two cards) and
  `sql/07_summary.sql` (draws the cards). They must keep the same order. The
  Python twin of the order is `helpers.card_order`.

### The card vocabulary — `sql/lib/finding_cards.plsql`

A card is a "group" key. `card_group(family)` (lines 34-45) maps a metric's
policy family to its card:

```sql
    FUNCTION card_group(p_family VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_family IN ('READ_IO', 'SCANS', 'LOGICAL_IO', 'WAIT:User I/O') THEN 'IO'
            WHEN p_family IN ('DB_TIME', 'CPU_WAIT_RATIO', 'RESPONSE')            THEN 'DBTIME'
            WHEN p_family IN ('WAIT:Network', 'NETWORK')                          THEN 'NET'
            WHEN p_family IN ('WAIT:Commit', 'COMMIT')                            THEN 'COMMIT'
            WHEN p_family IN ('PARSE', 'HARD_PARSE', 'CURSORS')                   THEN 'PARSE'
            WHEN p_family IN ('WRITE_IO', 'REDO', 'WAIT:System I/O')              THEN 'WRITE'
            ELSE p_family END;
    END card_group;
```

A wait-class row (domain `'WAIT'`, name `'Wait class: <class>'`) always has
family `'WAIT:<class>'` (`sql/lib/metric_policy.plsql:79-83`, `wpol`), so
`card_group(family)` of a wait-class row is exactly the card that class
belongs to (`IO`, `NET`, `COMMIT`, `WRITE`, or `WAIT:<class>`). `DB CPU`'s
family is `'CPU'` (`metric_policy.plsql:95`), so a flagged DB CPU is its own
card `'CPU'` — and `card_label` (lines 58-71) currently names it "Cpu"
through its `ELSE INITCAP(...)` branch.

The order rule today, lines 297-307 (the end of the file):

```sql
    -- card order, part 1: large cards before moderate ones, then the larger
    -- |z| of ANY member (a card is as loud as its loudest metric).  Part 2,
    -- done by the caller after sorting: a flagged DB time card moves up to
    -- second place, right after the lead card -- it is the number users
    -- feel.  00 (verdict) and 07 (cards) apply the same two steps.
    FUNCTION card_before(p_sev_a PLS_INTEGER, p_z_a NUMBER,
                         p_sev_b PLS_INTEGER, p_z_b NUMBER) RETURN BOOLEAN IS
    BEGIN
        IF p_sev_a <> p_sev_b THEN RETURN p_sev_a > p_sev_b; END IF;
        RETURN NVL(p_z_a, 0) > NVL(p_z_b, 0);
    END card_before;
```

`fmt_num(v)` (from `sql/lib/fmt_num.plsql`, included before this file) is the
report's number formatter (about 4 significant digits, e.g. `6.315`, `0.16`,
`20.35`).

### Units

`metric_scale(domain, name)` (lines 148-156) is `0.01` for LOAD `DB time` /
`DB CPU` (stored in centiseconds per second; ×0.01 = AAS) and `1` for wait
classes (stored in seconds waited per second = AAS). So
`(cur_val - prior_mean) * metric_scale(domain, name)` is a delta in AAS for
all three kinds of time measure.

### Section 07 — `sql/07_summary.sql`

Variables (declared BEFORE the includes, lines 85-114; excerpt):

```sql
    TYPE gz_t        IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    ...
    -- cards: group -> lead index / severity / loudest |z|; v_order = card order
    v_glead      fam_idx_t;
    v_gsev       fam_idx_t;
    v_gz         gz_t;
    v_order      ord_t;
    v_g          VARCHAR2(64);
    v_tmp        VARCHAR2(64);
    v_wait_flag  BOOLEAN := FALSE;
    v_dbt        PLS_INTEGER;
    v_cpu        PLS_INTEGER;
    v_meta       VARCHAR2(4000);

    @@sql/lib/metric_policy.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql

    -- Entity anchors (v1.6.0): ...
    FUNCTION find_id(p_dom VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
```

The WAIT rows (lines 632-643) are per wait class, in seconds waited per
second, from `DBA_HIST_SYSTEM_EVENT.time_waited_micro` (all sessions,
background included):

```sql
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
```

Pass 1 (lines 742-807) walks the BULK-COLLECTed rows; the relevant part,
lines 755-762:

```sql
        v_findings(i).grp := card_group(v_findings(i).family);
        f := v_findings(i);
        v_total := v_total + 1;
        IF f.metric_domain = 'LOAD' AND f.metric_name = 'DB time' THEN v_dbt := i; END IF;
        IF f.metric_domain = 'LOAD' AND f.metric_name = 'DB CPU'  THEN v_cpu := i; END IF;
```

The order (lines 809-829):

```sql
    -- Card order (00_params.sql's verdict applies the same two steps):
    -- large before moderate, then the loudest |z|; then a flagged DB time
    -- card moves up to second place.
    v_g := v_glead.FIRST;
    WHILE v_g IS NOT NULL LOOP
        j := v_order.COUNT;
        WHILE j >= 1 AND card_before(v_gsev(v_g), v_gz(v_g), v_gsev(v_order(j)), v_gz(v_order(j))) LOOP
            v_order(j + 1) := v_order(j);
            j := j - 1;
        END LOOP;
        v_order(j + 1) := v_g;
        v_g := v_glead.NEXT(v_g);
    END LOOP;
    FOR k IN 3 .. v_order.COUNT LOOP
        IF v_order(k) = 'DBTIME' THEN
            FOR m IN REVERSE 3 .. k LOOP
                v_tmp := v_order(m); v_order(m) := v_order(m - 1); v_order(m - 1) := v_tmp;
            END LOOP;
            EXIT;
        END IF;
    END LOOP;
```

The card's header (inside `PROCEDURE emit_card`, lines 422-427):

```sql
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h">'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span></div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg') || band_axis || '</div></header>');
```

Band glyphs in Summary-only markup in 07: the card header above (line 427),
the evidence row `ev_row` (line 222:
`|| band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm') || '</div></div>';`)
and the "Checked and normal" row `nr_row` (line 241:
`|| band_span(r.z_score, r.change_bucket, 'sm', CASE WHEN r.canonical = 'N' THEN 'Y' ELSE 'N' END)`).
The related-metrics fold inside a card is a table (`band_cells`) and keeps the
exact z.

### Section 00 — `sql/00_params.sql`

Variables lines 81-91, then the includes (lines 94-99, the last DECLARE
items), then `BEGIN` at line 100:

```sql
    v_glead      seen_t;        -- group -> index (v_scored) of its lead row
    v_gsev       seen_t;        -- group -> 2 large / 1 moderate
    TYPE gz_t    IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_gz         gz_t;          -- group -> largest |z| of any member
    TYPE ord_t   IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
    v_order      ord_t;
    v_g          VARCHAR2(64);
    v_tmp        VARCHAR2(64);
    v_j          PLS_INTEGER;
    v_dbt        PLS_INTEGER;   -- index of the LOAD 'DB time' row
    v_cpu        PLS_INTEGER;   -- index of the LOAD 'DB CPU' row
    v_verdict    VARCHAR2(32767);
    v_win_json   VARCHAR2(32767);   -- window validity flags, |k=Y|k=N|...
    -- Subprogram includes go LAST: PL/SQL forbids a variable / TYPE
    -- declaration after a subprogram in the same DECLARE section.
    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
BEGIN
```

00 has the same WAIT rows (lines 192-201). Its single pass (lines 262-322)
sets the family in a nested block, then:

```sql
        IF v_scored(i).metric_domain = 'LOAD' AND v_scored(i).metric_name = 'DB time' THEN
            v_dbt := i;
        ELSIF v_scored(i).metric_domain = 'LOAD' AND v_scored(i).metric_name = 'DB CPU' THEN
            v_cpu := i;
        END IF;
```

and the order at lines 324-343 is the same code as 07's (variable `v_j`
instead of `j`, `card_before` at line 330). Note: 00 has no `band_glyph`
include and draws no glyphs.

### Band glyph — `sql/lib/band_glyph.plsql`

`band_ztxt` (lines 47-58) already clamps at 99:

```sql
    FUNCTION band_ztxt(p_z NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_z IS NULL THEN '&mdash;'
            WHEN p_z > 99    THEN '&gt;+99&sigma;'
            WHEN p_z < -99   THEN '&lt;&minus;99&sigma;'
            WHEN ROUND(p_z, 1) < 0 THEN '&minus;' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                       'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
            ELSE '+' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
        END;
    END band_ztxt;
```

`band_span(p_z, p_bucket, p_size DEFAULT NULL, p_twin DEFAULT 'N')` (lines
73-118) pins the dot past +8 / below -4 sigma and prints `band_ztxt(p_z)` in
`<b class="ov">` (lines 97-104) and in its `aria-label` (line 116).

Other Summary-only glyph callers:
- `sql/08_overview.sql:117` (the DB time strip under the verdict):
  `|| '</div>' || band_span(v_z, v_bucket, 'sm') || '</div>';`
- `sql/18_sqlmon.sql:762` (plan-change card evidence):
  `|| CASE WHEN p_band = 'Y' THEN band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm') END`
- `sql/18_sqlmon.sql:882` (plan-change card header):
  `|| ' against the prior normal">' || band_span(v_z, v_b, 'lg')`

Other callers (`sql/lib/timeline.plsql:163` Timeline gutters,
`band_cells` in every table) are **not** Summary-only and stay unchanged.

### The demo twin — `demo/awrdemo/helpers.py`

`band_ztxt` lines 277-286, `band_span` lines 298-317, `card_label` lines
710-719, `card_before` lines 879-882 and:

```python
def card_order(groups: dict) -> list:
    """groups: {group: (sev, maxz)} in PL/SQL associative-array key order
    (sorted keys) -> the card order (insertion sort on card_before, then a
    flagged DBTIME card moves up to second place)."""
    order = []
    for g in sorted(groups):
        j = len(order)
        while j >= 1 and card_before(groups[g][0], groups[g][1], groups[order[j - 1]][0], groups[order[j - 1]][1]):
            j -= 1
        order.insert(j, g)
    if "DBTIME" in order[2:]:
        order.remove("DBTIME")
        order.insert(1, "DBTIME")
    return order
```

Callers: `demo/awrdemo/sections/s00_params.py:195`
(`st["order"] = h.card_order({g: (gsev[g], gz[g]) for g in lead})`, rows are
dicts with keys `domain`, `name`, `cur`, `mu`, `family`, ...) and
`demo/awrdemo/sections/s07_summary.py:362` (same call; rows are `Finding`
objects with `.domain .name .cur .mu .family .grp`). The card header twin is
`s07_summary.py:303-311` (`_card`), the evidence-row twin `_ev_row` line 224,
the normal-row twin `_nr_row` line 235; 08's twin `s08_overview.py:34`;
18's twins `s18_sqlmon.py:124` and `:217`. Number helpers in `helpers.py`:
`fmt_num` (line 105), `to_char_fixed(x, dec)` (line 42; = Oracle
`TO_CHAR(x, 'FM9999999990D000')` with `dec` decimals), `ora_round` (line 26).

### Today's demo (what must stay / change)

`grep -o '<article class="panel fc [^"]*" id="f-[a-z0-9-]*"' docs/examples/demo_busy_db.html`
prints, in order: `f-io` (lead), `f-dbtime`, `f-net`, `f-commit`, then the
two "what changed" cards `f-plan-7k2m9dx4qp1zb`, `f-config`. With the new
rule the four finding cards keep this order (Physical I/O has the largest
impact, DB time stays second, then Network, then Commit) — the rule only
changes the order on databases where a quieter card added more time. Pinned
z texts in the demo today include `+31.7&sigma;`, `+57.9&sigma;`,
`&gt;+99&sigma;`; in Summary-only glyphs these become `&gt;+10&sigma;`.

### The report designs and the visualization sections (landed after this plan was first written)

- The `design` variable (`classic` default / `quiet` / `dashboard`) adds a
  stylesheet `sql/lib/css_design.plsql` and a script
  `sql/lib/js_design.plsql` to quiet / dashboard reports only. Both are
  GENERATED by `tools/js2plsql.sh` from `sql/lib/src/css_design.css` and
  `sql/lib/src/js_design.js` (edit the source, regenerate, never edit the
  `.plsql`). A classic report must stay byte-identical with or without
  them: never put design rules in `sql/_style.sql`.
- The dashboard script moves every finding card into a row of an
  expandable findings table (`.dft`, one `details.drow` per card plus one
  per flagged related row). Each row's band cell is a CLONE of a band
  glyph from the All-sections detail table, `function drow(o)` in
  `sql/lib/src/js_design.js` (line 227):
  ```js
  function drow(o){
  ...
    if(o.band)$(".dbd",s).appendChild(o.band);
  ```
  (line 234). Those table glyphs keep the exact z (this plan does not cap
  tables), so in the dashboard's Summary the table would still print
  `+57.9σ`; step 7b caps the clone. The script reads the card list in DOM
  order (`#findings .cards > article.fc`), so the KPI cards and the table
  follow the new card order with no change.
- `sql/27_instance_map.sql` (instance map) and
  `sql/26_window_similarity.sql` (window similarity) must agree with
  07's cards: same severities, same card count. This plan changes only the
  order, so both stay in agreement; 27 prints `card_label(...)` in its
  "... card →" links, so a flagged DB CPU card reads "CPU card" there too
  after step 1. `demo/verify_report.js` block 8 checks the instance map
  against the cards.
- In `demo/verify_report.js` the finding cards are now selected as
  `#findings article.fc:not(.chg)` (the plan / config cards carry class
  `chg`; in the dashboard the cards sit inside `details.drow`, so
  `#findings .cards > article.fc` matches nothing there).

### Rules of this codebase that apply to every edit here

- **Never type a tilde character** in any `sql/` file, not even in a
  comment: every section runs under `SET DEFINE '~'`, so a stray one prompts
  for input and truncates the report. `./lint.sh` checks this.
- **Emitted text must be pure ASCII**: use HTML entities (`&middot;`,
  `&sigma;`, `&gt;`, `&nbsp;`) in markup. Check with
  `grep -nP '[^\x00-\x7F]' <file>` (must print nothing for the SQL files).
- A `PUT_LINE('…')` source line must stay under 2499 characters.
- Inside a PL/SQL string literal a single quote is written `''`.
- **PL/SQL declaration order** (lint checks 14 and 16): inside a `DECLARE`,
  every variable / TYPE must come BEFORE the first `@@sql/lib/*.plsql`
  include or FUNCTION/PROCEDURE. New variables go next to the existing ones,
  new local functions go after the includes.
- `sql/lib/finding_cards.plsql` declares only functions (no TYPE); it is
  included after `fmt_num.plsql` (lint check 20). Do not add a TYPE there.
- `sql/_style.sql` is also included by the fleet report's chrome: scope new
  CSS under `.fc` (single-DB only).
- Do not change the scoring (`policy_bucket`, z, buckets) — only the order
  and the display.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| All DB-free checks | `./tools/check.sh` | last line `check.sh: all checks passed` |
| Regenerate generated scripts | `tools/js2plsql.sh` | exit 0 (rewrites `sql/lib/js_*.plsql` / `css_*.plsql` from `sql/lib/src/`) |
| Generated scripts fresh | `tools/js2plsql.sh --check` | exit 0 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote …` lines (`demo_busy_db.html`, `_quiet`, `_dashboard`) |
| Demo up to date | `python3 demo/gen_demo_report.py --check` | `up to date: …` for each page |
| Demo determinism | run the generator twice, `md5sum docs/examples/demo_busy_db*.html` after each | same three md5s |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` each time (about 3 minutes each; never run two at once) |

There is no database available to you. The database checks are listed under
"Maintenance notes" for the repository owner.

## Scope

**In scope** (the only files you should modify):
- `sql/lib/finding_cards.plsql` — `impact_group`, `card_tier`, `card_before_imp`, `imp_tok`, `imp_txt`; `card_label('CPU')`
- `sql/lib/band_glyph.plsql` — optional cap argument on `band_ztxt` / `band_span`
- `sql/07_summary.sql` — impact per group, new order, chip + data attributes, capped glyphs
- `sql/00_params.sql` — impact per group, new order (lockstep with 07)
- `sql/08_overview.sql` — capped glyph (one call)
- `sql/18_sqlmon.sql` — capped glyphs (two calls, plan-change card only)
- `sql/19_reference.sql` — the About notes "Verdict" and "Finding cards"
- `sql/_style.sql` — one rule for the impact chip
- `sql/lib/src/js_design.js` + regenerated `sql/lib/js_design.plsql` — cap the dashboard table's cloned bands (step 7b)
- `sql/lib/src/css_design.css` + regenerated `sql/lib/css_design.plsql` — the chip in the quiet / dashboard skin (step 7b)
- `demo/awrdemo/helpers.py`, `demo/awrdemo/sections/s00_params.py`, `s07_summary.py`, `s08_overview.py`, `s18_sqlmon.py` — the twins
- `demo/verify_report.js` — a check for the new order / chip / cap
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`, `demo_busy_db_dashboard.html` — regenerated, never hand-edited
- `CHANGELOG.md`, `CLAUDE.md` — documentation

**Out of scope** (do NOT touch):
- Scoring: `sql/lib/metric_policy.plsql`, `policy_bucket`, z computation.
- `sql/lib/timeline.plsql` and the Timeline gutters, every table's
  `band_cells` (All sections keeps the exact z) — owner decision whether the
  cap should spread there.
- The verdict pills, the Findings header counts and the rail (plan 022), the
  DB-time breakdown bar (plan 021), the triage list (plan 025).
- Switching the wait-class source to foreground-only time
  (`time_waited_micro_fg`): an owner decision recorded under Maintenance
  notes.
- Fleet files (`sql/fleet/*`, `awr_fleet_extract.sql`, `run_awr_fleet.sh`).
- The visualization sections `sql/20_*.sql` .. `sql/28_*.sql` and their
  twins: 20 calls `band_ztxt(...)` with one argument, which the new
  default keeps byte-identical; 26 / 27 need no change (order only).
- Any other part of `js_design.js` (KPI cards, palette, Activity tabs).

## Git workflow

- Branch: `advisor/020-impact-ranking` from `main`.
- Conventional commits with a scope, e.g.
  `feat(report): rank finding cards by the DB time they added` (the repo's
  recent history uses `fix(report): …`, `docs(changelog): …`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the impact vocabulary to `sql/lib/finding_cards.plsql`

1. In `card_label` (lines 58-71) add a line before the `WAIT:%` line so a
   flagged DB CPU card is not named "Cpu":
   ```sql
            WHEN p_group = 'CPU'    THEN 'CPU'
   ```
2. Append these functions after `card_before` (end of file):

```sql
    -- Impact (v1.7): each card has at most one TIME MEASURE, a metric in
    -- seconds per second (= average active sessions, AAS):
    --   DBTIME -> LOAD 'DB time' (the total the others are shares of)
    --   CPU    -> LOAD 'DB CPU'
    --   IO / NET / COMMIT / WRITE / WAIT:<c> -> its wait class row
    --          ('Wait class: <class>', family 'WAIT:<class>')
    -- The card's impact = (Current - prior mean) of that row x
    -- metric_scale() = AAS added above normal.  impact_group() names the
    -- card a row is the time measure of (NULL: none).  A card without a
    -- time measure (PARSE, OTHER:...) has no impact.  The wait-class times
    -- come from DBA_HIST_SYSTEM_EVENT and include background sessions.
    FUNCTION impact_group(p_domain VARCHAR2, p_name VARCHAR2, p_family VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_domain = 'LOAD' AND p_name = 'DB time' THEN RETURN 'DBTIME'; END IF;
        IF p_domain = 'LOAD' AND p_name = 'DB CPU'  THEN RETURN 'CPU'; END IF;
        IF p_domain = 'WAIT' AND p_name LIKE 'Wait class: %' THEN
            RETURN card_group(p_family);
        END IF;
        RETURN NULL;
    END impact_group;

    -- card order, v1.7 (replaces card_before as the sort key; card_before is
    -- kept as the tie-break):  tier 1 = every card whose time measure ROSE
    -- (impact > 0), largest impact first; tier 2 = the DB time card (the
    -- total those impacts are shares of); tier 3 = every other card (no
    -- time measure, or it did not rise), large before moderate, then |z|.
    -- The caller then still moves a flagged DB time card up to second
    -- place, so the verdict keeps "<biggest contributor>; DB time ...".
    -- 00 (verdict) and 07 (cards) apply the same two steps.
    FUNCTION card_tier(p_group VARCHAR2, p_imp NUMBER) RETURN PLS_INTEGER IS
    BEGIN
        IF p_group = 'DBTIME' THEN RETURN 2; END IF;
        IF p_imp > 0 THEN RETURN 1; END IF;   -- NULL > 0 is not true: tier 3
        RETURN 3;
    END card_tier;

    FUNCTION card_before_imp(p_g_a VARCHAR2, p_sev_a PLS_INTEGER, p_z_a NUMBER, p_imp_a NUMBER,
                             p_g_b VARCHAR2, p_sev_b PLS_INTEGER, p_z_b NUMBER, p_imp_b NUMBER)
                             RETURN BOOLEAN IS
        v_ta PLS_INTEGER := card_tier(p_g_a, p_imp_a);
        v_tb PLS_INTEGER := card_tier(p_g_b, p_imp_b);
    BEGIN
        IF v_ta <> v_tb THEN RETURN v_ta < v_tb; END IF;
        IF v_ta = 1 AND ROUND(p_imp_a, 6) <> ROUND(p_imp_b, 6) THEN
            RETURN p_imp_a > p_imp_b;
        END IF;
        RETURN card_before(p_sev_a, p_z_a, p_sev_b, p_z_b);
    END card_before_imp;

    -- an impact as a data-attribute token: '.' decimal, 3 decimals
    -- ("6.315", "-0.050"); '' when NULL
    FUNCTION imp_tok(p_v NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_v IS NULL THEN RETURN ''; END IF;
        RETURN TO_CHAR(ROUND(p_v, 3), 'FM9999999990D000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END imp_tok;

    -- an impact for reading: "+6.315&nbsp;AAS" (callers print it only when > 0)
    FUNCTION imp_txt(p_v NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '+' || fmt_num(p_v) || '&nbsp;AAS';
    END imp_txt;
```

3. In the file's header comment (lines 1-32), add one paragraph after the
   "Units." paragraph: "Impact (v1.7): impact_group() / card_tier() /
   card_before_imp() -- cards are ordered by the AAS their time measure added
   above its prior mean; see the comment above impact_group()." Do not end a
   comment line with `;` and do not type a tilde.

**Verify**: `./lint.sh` → `lint: clean …`.
`grep -c "FUNCTION impact_group\|FUNCTION card_tier\|FUNCTION card_before_imp\|FUNCTION imp_tok\|FUNCTION imp_txt" sql/lib/finding_cards.plsql` → `5`.
`grep -nP '[^\x00-\x7F]' sql/lib/finding_cards.plsql` → no output.

### Step 2: Optional z cap in `sql/lib/band_glyph.plsql`

1. Give `band_ztxt` a second parameter with a default that keeps today's
   output byte-identical:

```sql
    -- z as display text: one decimal, sigma suffix, clamped beyond p_cap
    -- (99 = every table; 10 = the Summary view's glyphs, v1.7).
    FUNCTION band_ztxt(p_z NUMBER, p_cap NUMBER DEFAULT 99) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_z IS NULL THEN '&mdash;'
            WHEN p_z > p_cap    THEN '&gt;+' || TO_CHAR(p_cap) || '&sigma;'
            WHEN p_z < -p_cap   THEN '&lt;&minus;' || TO_CHAR(p_cap) || '&sigma;'
            WHEN ROUND(p_z, 1) < 0 THEN '&minus;' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                       'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
            ELSE '+' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
        END;
    END band_ztxt;
```

   (`TO_CHAR(99)` is `99`, so the default branch prints exactly the old
   `&gt;+99&sigma;` / `&lt;&minus;99&sigma;`.)

2. Give `band_span` a fifth parameter `p_zcap NUMBER DEFAULT 99` (after
   `p_twin`) and pass it to all three `band_ztxt(p_z)` calls inside it
   (lines 99, 103 and 116 → `band_ztxt(p_z, p_zcap)`). Update the comment
   above `band_span` with one line: "p_zcap: the |z| past which the printed z
   reads '>+cap' (99 = tables, 10 = Summary view)".

**Verify**: `./lint.sh` → clean. `grep -c "band_ztxt(p_z, p_zcap)" sql/lib/band_glyph.plsql` → `3`.

### Step 3: Python twins in `demo/awrdemo/helpers.py`

1. `band_ztxt(z, cap=99)`: `if z > cap: return "&gt;+" + str(cap) + "&sigma;"`,
   `if z < -cap: return "&lt;&minus;" + str(cap) + "&sigma;"` (cap is an int).
2. `band_span(z, bucket, size=None, twin="N", zcap=99)` passing `zcap` to its
   three `band_ztxt(z)` calls.
3. `card_label`: add `"CPU": "CPU"` to the `fixed` dict.
4. New twins (next to `card_before`):

```python
def impact_group(domain, name, family):
    if domain == "LOAD" and name == "DB time":
        return "DBTIME"
    if domain == "LOAD" and name == "DB CPU":
        return "CPU"
    if domain == "WAIT" and name.startswith("Wait class: "):
        return card_group(family)
    return None


def card_tier(group, imp) -> int:
    if group == "DBTIME":
        return 2
    return 1 if (imp is not None and imp > 0) else 3


def card_before_imp(g_a, sev_a, z_a, imp_a, g_b, sev_b, z_b, imp_b) -> bool:
    ta, tb = card_tier(g_a, imp_a), card_tier(g_b, imp_b)
    if ta != tb:
        return ta < tb
    if ta == 1 and ora_round(imp_a, 6) != ora_round(imp_b, 6):
        return imp_a > imp_b
    return card_before(sev_a, z_a, sev_b, z_b)


def imp_tok(v) -> str:
    return "" if v is None else to_char_fixed(ora_round(v, 3), 3)


def imp_txt(v) -> str:
    return "+" + fmt_num(v) + "&nbsp;AAS"
```

5. Change `card_order` to take `{group: (sev, maxz, imp)}` and sort with
   `card_before_imp(g, sev, z, imp, other, …)`; keep the "DBTIME to second
   place" step unchanged. Update its docstring.

**Verify**:
```
PYTHONPATH=demo python3 -c "
from awrdemo.helpers import card_order as o, band_ztxt as t
assert o({'IO':(2,31.7,6.3),'DBTIME':(2,6.1,9.0),'NET':(2,57.9,0.95),'COMMIT':(1,2.3,0.16)}) == ['IO','DBTIME','NET','COMMIT']
assert o({'IO':(2,31.7,0.5),'COMMIT':(1,2.3,2.0)}) == ['COMMIT','IO']
assert o({'DBTIME':(2,6.1,9.0),'PARSE':(2,40.0,None)}) == ['DBTIME','PARSE']
assert o({'PARSE':(1,3.0,None),'NET':(1,2.5,-0.2),'WAIT:Concurrency':(1,2.2,0.3)}) == ['WAIT:Concurrency','PARSE','NET']
assert o({'IO':(2,9.0,1.0),'NET':(2,8.0,3.0),'COMMIT':(2,7.0,2.0),'DBTIME':(2,5.0,6.0)}) == ['NET','DBTIME','COMMIT','IO']
assert t(57.9, 10) == '&gt;+10&sigma;' and t(57.9) == '+57.9&sigma;' and t(150) == '&gt;+99&sigma;' and t(-12, 10) == '&lt;&minus;10&sigma;'
print('ok')"
```
→ prints `ok`. (Case 2: a moderate card that added 2 AAS ranks above a
large one that added 0.5. Case 4: a card whose time measure fell (-0.2) ranks
with the cards that have none, by severity then |z|.)

### Step 4: Section 07 — compute impact, order by it, show it

1. In the variable block (before `@@sql/lib/metric_policy.plsql`, next to
   `v_gz`), add:
   ```sql
    v_gimp       gz_t;          -- card group -> impact, AAS added above normal (v1.7)
    v_ig         VARCHAR2(64);
   ```
2. After the includes, next to `find_id`, add a local function:
   ```sql
    -- a card's impact (AAS its time measure added above its prior mean), NULL when none
    FUNCTION g_imp(p_g VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF v_gimp.EXISTS(p_g) THEN RETURN v_gimp(p_g); END IF;
        RETURN NULL;
    END g_imp;
   ```
3. In pass 1, right after `IF f.metric_domain = 'LOAD' AND f.metric_name = 'DB CPU'  THEN v_cpu := i; END IF;`
   (line 762), add (for EVERY row, flagged or not — the User I/O class row
   is the I/O card's time measure even when that row itself is not flagged):
   ```sql
        -- impact (v1.7, sql/lib/finding_cards.plsql impact_group)
        v_ig := impact_group(f.metric_domain, f.metric_name, f.family);
        IF v_ig IS NOT NULL AND f.cur_val IS NOT NULL AND f.prior_mean IS NOT NULL THEN
            v_gimp(v_ig) := (f.cur_val - f.prior_mean) * metric_scale(f.metric_domain, f.metric_name);
        END IF;
   ```
4. In the card order (line 816) replace
   `card_before(v_gsev(v_g), v_gz(v_g), v_gsev(v_order(j)), v_gz(v_order(j)))`
   with
   `card_before_imp(v_g, v_gsev(v_g), v_gz(v_g), g_imp(v_g), v_order(j), v_gsev(v_order(j)), v_gz(v_order(j)), g_imp(v_order(j)))`.
   Leave the "DB time to second place" loop untouched. Update the comment
   above it ("Card order (00_params.sql's verdict applies the same two
   steps): cards whose time measure rose, by the AAS added; then DB time;
   then the rest, large before moderate and by |z|; then a flagged DB time
   card moves up to second place.") and the header comment at lines 30-34
   to the same rule.
5. In `emit_card`: add two variables to its declaration list
   (`v_imp NUMBER := g_imp(p_g);`, `v_dd NUMBER := g_imp('DBTIME');`,
   `v_shr NUMBER;`), and at the start of its body compute the share:
   ```sql
        IF v_imp > 0 AND v_dd > 0 AND v_imp <= v_dd * 1.005 THEN
            v_shr := ROUND(v_imp / v_dd * 100);
        END IF;
   ```
   (a share above 100% means background wait time rose more than DB time;
   it is left out rather than printed as a confusing ">100% of the rise").
   Then change the `<article …>` line (422-424) to carry the attributes, and
   add the chip after the severity span:
   ```sql
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc f-' || v_sev
            || CASE WHEN p_pos = 1 THEN ' lead' WHEN v_sev = 'moderate' THEN ' slim' END
            || '" id="' || v_id || '" aria-labelledby="' || v_id || '-h"'
            || ' data-impact="' || imp_tok(v_imp) || '" data-share="' || v_shr || '">'
            || '<header class="fc-h"><div class="fc-k"><span class="sv" title="'
            || DBMS_XMLGEN.CONVERT(card_label(p_g)) || '"><i class="dotk ' || v_sev
            || '" aria-hidden="true"></i>' || INITCAP(v_sev) || '</span>'
            || CASE WHEN v_imp > 0 THEN '<span class="fc-imp" title="Time added: Current minus the prior'
                    || ' mean of this card&#39;s time measure (DB time, DB CPU or its wait class),'
                    || ' in average active sessions">' || imp_txt(v_imp)
                    || CASE WHEN p_g = 'DBTIME' THEN ' above normal'
                            WHEN v_shr IS NOT NULL THEN ' &middot; ' || v_shr || '% of the DB-time rise' END
                    || '</span>' END
            || '</div>'
            || '<div class="fc-band" title="z ' || band_ztxt(r.z_score) || ' against the prior normal">'
            || band_span(r.z_score, v_sev, 'lg', 'N', 10) || band_axis || '</div></header>');
   ```
   Notes: `v_shr` is a NUMBER; concatenating NULL gives `''`, so
   `data-share=""` when there is no share. The `title` keeps the exact z
   (hover detail); only the visible pinned text is capped.
6. Cap the other Summary-only glyphs in 07: in `ev_row` (line 222) use
   `band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm', 'N', 10)`; in
   `nr_row` (line 241) add `, 10` as the fifth argument.

**Verify**: `./lint.sh` → clean (pay attention to checks 14, 16, 20).
`grep -c "card_before_imp" sql/07_summary.sql` → `1`.
`grep -c "data-impact" sql/07_summary.sql` → `1`.
`awk 'length($0) > 2400' sql/07_summary.sql | wc -l` → `0`.
`grep -nP '[^\x00-\x7F]' sql/07_summary.sql` → no output.

### Step 5: Section 00 — same impact, same order (lockstep)

1. In the variable block (lines 81-91, BEFORE the includes) add
   `v_gimp       gz_t;          -- card group -> impact (AAS), as in 07` and
   `v_ig         VARCHAR2(64);`. `gz_t` is declared at line 81; put the new
   lines after `v_gz`.
2. After the last include (`@@sql/lib/wingrid.plsql`) and before `BEGIN`,
   add the same `g_imp` function as in step 4.2.
3. In the single pass, right after the `IF … 'DB time' … ELSIF … 'DB CPU' …
   END IF;` block (lines 289-293, ending with `v_cpu := i;` / `END IF;`), add:
   ```sql
        v_ig := impact_group(v_scored(i).metric_domain, v_scored(i).metric_name, v_scored(i).family);
        IF v_ig IS NOT NULL AND v_scored(i).cur_val IS NOT NULL AND v_scored(i).prior_mean IS NOT NULL THEN
            v_gimp(v_ig) := (v_scored(i).cur_val - v_scored(i).prior_mean)
                            * metric_scale(v_scored(i).metric_domain, v_scored(i).metric_name);
        END IF;
   ```
   (`v_scored(i).family` is already set by the nested block above it.)
4. At line 330 replace the `card_before(...)` call with
   `card_before_imp(v_g, v_gsev(v_g), v_gz(v_g), g_imp(v_g), v_order(v_j), v_gsev(v_order(v_j)), v_gz(v_order(v_j)), g_imp(v_order(v_j)))`
   and update its comment exactly as in 07.

**Verify**: `./lint.sh` → clean. `grep -c "card_before_imp" sql/00_params.sql` → `1`.
`grep -c "impact_group(" sql/00_params.sql sql/07_summary.sql` → `1` each.
There is no database: the lockstep of 00 and 07 is checked by the owner's
run (Maintenance notes) and, for the logic, by the twins in step 8.

### Step 6: Cap the remaining Summary-only glyphs (08, 18)

- `sql/08_overview.sql:117`: `band_span(v_z, v_bucket, 'sm', 'N', 10)`.
- `sql/18_sqlmon.sql:762`: `band_span(band_z(p_cur, p_mu, p_sd), p_bucket, 'sm', 'N', 10)`.
- `sql/18_sqlmon.sql:882`: `band_span(v_z, v_b, 'lg', 'N', 10)`.

Do not change `band_ztxt(v_z)` inside the `title="…"` attributes (exact z on
hover) and do not change any other line of 18.

**Verify**: `./lint.sh` → clean.
`grep -c "'N', 10)" sql/08_overview.sql sql/18_sqlmon.sql` → `1` and `2`.

### Step 7: CSS for the chip (`sql/_style.sql`)

After the `.fc-k .gk{…}` line (line 1313) add:

```sql
    DBMS_OUTPUT.PUT_LINE('.fc-k .fc-imp{display:inline-flex;align-items:center;padding:1px 10px;border-radius:999px;background:var(--chip-bg);color:var(--ink);font-size:12.5px;font-weight:600;white-space:nowrap}');
```

(`--chip-bg` is defined for light and dark at lines 31 and 87.)

**Verify**: `./lint.sh` → clean.

### Step 7b: The quiet / dashboard designs

1. **Cap the dashboard findings table's bands.** In
   `sql/lib/src/js_design.js`, add this function right before
   `function drow(o){` (line 227):

   ```js
   /* plan 020: the Summary view prints z only up to 10 sigma (band_ztxt's
      p_cap); the findings table clones its bands from the All-sections
      tables, which keep the exact z, so cap the clone's pinned text */
   function capz(bd){
     var b=bd&&$(".ov",bd);if(!b)return bd;
     var M=String.fromCharCode(8722),S=String.fromCharCode(963),t=txt(b);
     var z=parseFloat(t.replace(/^[<>]/,"").replace(M,"-"));
     if(isNaN(z)||Math.abs(z)<=10)return bd;
     var c=z>0?">+10"+S:"<"+M+"10"+S,al=bd.getAttribute("aria-label");
     if(al)bd.setAttribute("aria-label",al.split(t).join(c));
     b.textContent=c;return bd;
   }
   ```

   and in `drow` change `if(o.band)$(".dbd",s).appendChild(o.band);` to
   `if(o.band)$(".dbd",s).appendChild(capz(o.band));`.
   `String.fromCharCode(8722)` / `(963)` are the minus sign and sigma: the
   source must stay pure ASCII (lint check 25), and a typed backslash-u
   escape can be turned into the character by an agent's tool input, so
   do not use one here. `.ov` holds exactly `band_ztxt(z)` (e.g. `+57.9σ`,
   `−12.0σ`, `>+99σ`); the result matches the classic cap
   (`&gt;+10&sigma;` / `&lt;&minus;10&sigma;`).
2. **The chip in the quiet skin.** In `sql/lib/src/css_design.css`, right
   after the `.fc-k .sv > .dotk,.fc-k .sv > i{display:none}` line (line
   197), add:
   ```css
   .fc-k .fc-imp{height:22px;padding:0 8px;border-radius:6px;border:1px solid var(--hairline);background:none;font-size:12px;font-weight:500;color:var(--ink)}
   ```
   (the quiet `.sv` badge next to it uses the same box). No tilde in the
   file (the generator rejects it).
3. Run `tools/js2plsql.sh` (regenerates `sql/lib/js_design.plsql` and
   `sql/lib/css_design.plsql`).

**Verify**: `tools/js2plsql.sh --check` → exit 0. `./lint.sh` → clean
(checks 24 and 25). `grep -c 'capz(' sql/lib/src/js_design.js` → `2`.
`grep -nP '[^\x00-\x7F]' sql/lib/src/js_design.js sql/lib/src/css_design.css` → no output.

### Step 8: The twins for 00, 07, 08, 18

1. `demo/awrdemo/sections/s00_params.py`, `_verdict_state`: compute
   `imp = {}`; for every row `r`,
   `g = h.impact_group(r["domain"], r["name"], r["family"])`, and when `g`
   and `r["cur"] is not None and r["mu"] is not None`:
   `imp[g] = (r["cur"] - r["mu"]) * h.metric_scale(r["domain"], r["name"])`.
   Do this for every row before the `canonical` filter (same as the
   PL/SQL). Call `h.card_order({g: (gsev[g], gz[g], imp.get(g)) for g in lead})`.
   If the row dicts do not carry `family` for every row, compute it with
   `h.finding_family(r["domain"], r["name"])`.
2. `demo/awrdemo/sections/s07_summary.py`: in `emit`, build the same `imp`
   dict from `findings` (rows are `Finding` objects: `f.domain`, `f.name`,
   `f.family`, `f.cur`, `f.mu`) and pass `(gsev[g], gz[g], imp.get(g))` to
   `card_order`. Pass `imp` into `_card` (add a parameter) and port step 4.5
   exactly: `data-impact` via `h.imp_tok`, `data-share` (`str(int(...))` of
   `ora_round(v_imp / v_dd * 100, 0)` when `v_imp > 0 and v_dd > 0 and
   v_imp <= v_dd * 1.005`, else `""`), the `fc-imp` chip, and
   `h.band_span(r.z, sev, "lg", "N", 10)` in the header. `_ev_row` and
   `_nr_row` get the fifth argument `10` (keyword or positional — the twin's
   signature is `band_span(z, bucket, size=None, twin="N", zcap=99)`).
3. `s08_overview.py:34` and `s18_sqlmon.py:124`, `:217`: add `"N", 10`.

**Verify**: `python3 demo/gen_demo_report.py` → three `wrote …` lines; run
it again and compare `md5sum docs/examples/demo_busy_db*.html` → identical.
Then (the classic page; the dashboard page carries the same cards):
- `grep -o '<article class="panel fc [^"]*" id="f-[a-z0-9-]*"' docs/examples/demo_busy_db.html | head -4`
  → still `f-io`, `f-dbtime`, `f-net`, `f-commit` in that order.
- `grep -o 'data-impact="[^"]*" data-share="[^"]*"' docs/examples/demo_busy_db.html`
  → four lines; `f-io`'s impact is the largest of the three non-DB-time
  cards and `f-dbtime`'s share is `100`.
- `grep -c 'class="fc-imp"' docs/examples/demo_busy_db.html` → `4`.
- `grep -c '+57.9&sigma;' docs/examples/demo_busy_db.html` → smaller than
  before (the Summary-only glyphs now print `&gt;+10&sigma;`; tables still
  print the exact value). `grep -c '&gt;+10&sigma;' docs/examples/demo_busy_db.html`
  → greater than 0.

### Step 9: About notes (`sql/19_reference.sql`)

- Line 230, "Verdict": replace "(the loudest card, then DB time when it is
  flagged)" with "(the card that added the most DB time, then DB time when
  it is flagged)".
- Lines 233-236, "Finding cards": append a sentence before "Twins are
  folded": "Cards are ordered by the time they added: the rise of the card&rsquo;s
  time measure (DB time, DB CPU or its wait class) above its prior mean, in
  average active sessions, largest first; cards without a time measure
  follow, large before moderate. The printed z of a band in the Summary view
  stops at &gt;+10&sigma;; tables show the exact value."

Keep each PUT_LINE source line under 2499 characters (split with `||` as the
neighbouring lines do) and pure ASCII. The demo twin
`demo/awrdemo/sections/s19_reference.py` lifts these literal lines
automatically; regenerate the demo.

**Verify**: `./lint.sh` → clean; `python3 demo/gen_demo_report.py` then
`grep -c 'the card that added the most DB time' docs/examples/demo_busy_db.html` → `1`.

### Step 10: Browser check (`demo/verify_report.js`)

In section "6. phase 4" (the `page.evaluate` that starts at line 809; this
block runs for every design), add to the returned object:

```js
      // v1.7: cards ordered by impact; chip; Summary z capped at 10
      // (#findings article.fc:not(.chg): the dashboard moves the cards into
      // its findings table, and the plan / config cards carry .chg)
      const fc = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      const imp = fc.filter(c => c.id !== 'f-dbtime').map(c => parseFloat(c.getAttribute('data-impact')))
        .filter(v => v > 0);
      out.impOrder = imp.every((v, i) => i === 0 || imp[i - 1] >= v);
      out.impAttrs = fc.every(c => c.hasAttribute('data-impact') && c.hasAttribute('data-share'));
      out.impChips = fc.filter(c => parseFloat(c.getAttribute('data-impact')) > 0).every(c => c.querySelector('.fc-k .fc-imp'));
      // the related-metrics fold (details.rel) is a table and keeps the exact z
      out.zcap = [...document.querySelectorAll('#findings article.fc .fc-h .bd .ov, #findings article.fc dl.ev .bd .ov, '
        + '#changes-slot article.fc .fc-h .bd .ov, #changes-slot dl.ev .bd .ov, #s-normal .nr .bd .ov, #overview .bd .ov, '
        + '.dft .drow .dbd .bd .ov')]
        .map(b => b.textContent).filter(t => /\u03c3/.test(t) && !/^[<>]/.test(t))
        .filter(t => Math.abs(parseFloat(t.replace('\u2212', '-'))) > 10);
```

(Write the two `\u…` escapes from a script or check them with
`grep -n 'u03c3\|u2212' demo/verify_report.js` afterwards: an agent's tool
input can turn a typed backslash-u sequence into the character itself, and
this file must contain the escape, not the character.)

and after the `console.log('phase 4', …)` line:

```js
    if (!p4.impAttrs) fail('finding cards: data-impact / data-share missing');
    if (!p4.impOrder) fail('finding cards: not ordered by impact');
    if (!p4.impChips) fail('finding cards: impact chip missing');
    if (p4.zcap.length) fail('Summary glyphs print z past 10: ' + p4.zcap.join(', '));
```

Also add one line to the header comment's check list ("v1.7: cards ordered
by data-impact, chip present, Summary z capped at 10").

**Verify**: `node --check demo/verify_report.js` → no output, exit 0. Then
the browser smoke test (Commands table) → `verify: OK`.

### Step 11: Documentation

- `CHANGELOG.md`, under `## Unreleased` → `### Report`, add an entry:
  "**Finding cards are ranked by the DB time they added.** Each card's time
  measure (DB time, DB CPU or its wait class) above its prior mean, in AAS,
  orders the cards and shows as a chip ("+6.315 AAS · 70% of the DB-time
  rise"); cards without a time measure follow, large before moderate. DB
  time stays second. The verdict follows the same order. Band glyphs in the
  Summary view print z only up to ">+10 sigma"; tables keep the exact z."
- `CLAUDE.md`, "Card groups" paragraph (around lines 351-363): replace the
  sentence "Order (`card_before`): large before moderate, then max |z|; a
  flagged DB time card moves to 2nd." with the tier rule
  (`card_before_imp`: tier 1 impact > 0 by impact, tier 2 DBTIME, tier 3 by
  `card_before`; then DB time to 2nd) and add: "Impact (`impact_group`): the
  card's time measure — DB time, DB CPU, or its wait-class row — Current
  minus prior mean, ×`metric_scale` = AAS; `article.fc[data-impact]`
  (3-decimal token, '' = none) and `[data-share]` (integer % of the DB-time
  rise, '' when DB time did not rise or the share passes 100) are a contract
  for later Summary features. Summary-only band glyphs pass `p_zcap => 10`."
  Also update the last sentence of "Findings are recomputed, not shared"
  (around line 1643): "(`card_before`)" → "(`card_before_imp`)". In the
  "Report designs" section's dashboard bullet, add: "the findings table's
  band cells are capped at 10 sigma like the cards (`capz`, plan 020)".

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- Python twin unit checks: the one-liner in step 3 (five ordering cases and
  four z-cap cases).
- Demo output: step 8's greps (order unchanged, four chips, four attribute
  pairs, capped z text present).
- Browser: `demo/verify_report.js` with the new phase-4 assertions (step 10),
  on the classic and the dashboard demo (the dashboard run also covers the
  capped table bands of step 7b and block 7's KPI / table checks).
- Lint: checks 14/16/20 (declaration and include order) are the ones this
  plan can trip.
- Database (owner, see Maintenance notes).

## Done criteria

- [ ] `./tools/check.sh` exits 0 (`check.sh: all checks passed`)
- [ ] The step-3 Python one-liner prints `ok`
- [ ] `grep -c 'class="fc-imp"' docs/examples/demo_busy_db.html` → `4`
- [ ] Demo card order unchanged: `f-io`, `f-dbtime`, `f-net`, `f-commit`
- [ ] `demo/verify_report.js` → `verify: OK` on `demo_busy_db.html` and on `demo_busy_db_dashboard.html` (one at a time)
- [ ] `tools/js2plsql.sh --check` exits 0
- [ ] `grep -c "card_before_imp" sql/00_params.sql sql/07_summary.sql` → `1` each
- [ ] `grep -nP '[^\x00-\x7F]' sql/lib/finding_cards.plsql sql/lib/band_glyph.plsql sql/07_summary.sql sql/00_params.sql sql/19_reference.sql` → no output
- [ ] No files outside the Scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" do not match the live code (drift).
- `./lint.sh` reports a declaration-order finding (check 14 / 16) you cannot
  fix by moving the new variable above the includes.
- After step 8 the demo's first four cards are no longer `f-io, f-dbtime,
  f-net, f-commit`: the twin and the rule disagree with this plan's
  analysis — report the new order and the four `data-impact` values.
- A wait-class row turns out not to have family `'WAIT:<class>'`
  (`metric_policy.plsql` changed): `impact_group` would map it wrongly.
- The fix seems to need a change to `policy_bucket`, z, or any table.
- `sql/lib/src/js_design.js` has no `function drow(o)` with the
  `if(o.band)$(".dbd",s).appendChild(o.band);` line (the dashboard changed):
  skip step 7b.1 and report.
- verify_report block 7 (dashboard) or block 8 (instance map vs the cards)
  starts failing after this plan: the order change must not change any
  card's severity or the card count.

## Maintenance notes

- **Lockstep**: 00 and 07 each compute impact and order; any future change
  to the rule changes `card_before_imp`/`impact_group` (shared) and the two
  call sites, plus `helpers.card_order` / `impact_group`.
- **Later plans build on the contract** `article.fc[data-impact][data-share]`
  (plan 021's DB-time breakdown uses the same `impact_group` numbers; plan
  025's triage list and plan 034's copy summary read the attributes). Do not
  rename them.
- **Approximation, owner decision**: wait-class times are
  `DBA_HIST_SYSTEM_EVENT.time_waited_micro` (all sessions, background
  included), the same numbers the cards and the Wait classes table already
  show. DB time is foreground only. A rise in background waits (System I/O:
  LGWR / DBWR) therefore gets "impact" that did not add DB time; that is
  why `data-share` is left empty above 100%. Switching the impact (not the
  scoring) to `time_waited_micro_fg` would be more exact but would make the
  chip disagree with the card's own value; not done here.
- **Behaviour change on real databases**: a card whose time measure rose
  now outranks a louder card without one (e.g. a PARSE card), and when no
  card added time, DB time leads the verdict. The demo order is unchanged.
- The z cap is display-only and Summary-only. Whether the Timeline gutters
  (`sql/lib/timeline.plsql`) should cap too is open.
- **Dashboard design**: the KPI cards and the findings table follow the
  DOM order of the cards, so they pick up the new order with no change;
  the table's band cells are capped by `capz` (step 7b). If the dashboard
  ever takes its bands from somewhere else, keep the cap.
- **Needs owner DB run** (dbmint, `ssh -p 2200 oracle@dbmint` — never port
  2201, the standby; rsync without `--delete`). dbmint keeps 35 days of
  AWR, so the September dates this plan first used return empty windows
  now: probe first (snapshots per day and per `startup_time`) and pin
  inside a restart-free stretch. On 2026-11-19 that was 2026-11-07 14:45
  to 2026-11-09 16:15, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h` (a heavy,
  wait-dominated blocking hour against eight quiet ones).
  1. A quiet pinned hourly window: rc 0, 29/29 `AWR-SECTION` BEGIN/END
     pairs (20 before sections 20-28), no `ORA-` outside captured SQL text.
  2. A busy window (the one above): the verdict's first card and 07's
     first card are the same group; every card's `data-impact` equals
     (Current − prior mean) of its wait class in the "Wait classes" table
     to 3 decimals; `f-dbtime` has `data-share="100"`; the instance map
     (27) still colours the same cards.
  3. If a CPU-heavy window exists in the retention: a CPU card, if any, is
     labelled "CPU" (not "Cpu") and ranks by DB CPU's rise.
  4. The busy window again with `DESIGN=dashboard`: the findings table's
     band cells print at most `>+10σ`.
  5. `demo/verify_report.js` on each report (one at a time).
