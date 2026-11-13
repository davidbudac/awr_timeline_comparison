# Plan 004: Database-sourced names can not break out of the report's inline `<script>` JSON or chart tooltips

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- sql/lib/json_escape.plsql sql/06_top_sql.sql sql/14_segment_io.sql sql/15_file_io.sql demo/awrdemo/helpers.py docs/examples/demo_busy_db.html`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The report is one self-contained HTML file a DBA opens in a browser. Some
strings in it are chosen by application users, not by the DBA: a session's
MODULE / ACTION, segment (table, index, partition) names and data file
names. Those strings are written into inline `<script>` blocks as JSON
string values. The escaping used there handles backslash, double quote and
line breaks but not `<`, so a name containing an HTML end tag ends the
script element early and the rest is parsed as markup — script supplied by
an application account then runs in the DBA's browser when the report is
opened. Separately, three chart tooltips insert the same names into HTML
without escaping. This plan makes the JSON escape neutralise `<` and makes
the three tooltips HTML-escape the series name.

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts. PL/SQL blocks print HTML and
  JavaScript line by line with `DBMS_OUTPUT.PUT_LINE('…')`. Client JavaScript
  is therefore written **inside PL/SQL string literals**.
- `sql/lib/*.plsql` files are fragments `@@`-included inside a section's
  `DECLARE` block.
- `demo/` is a docs-only Python twin that renders
  `docs/examples/demo_busy_db.html` without a database.
  `demo/awrdemo/helpers.py` hand-ports every shared PL/SQL helper; the
  section twins lift the JavaScript `PUT_LINE` lines **literally from the SQL
  files**, so a JS change in a `sql/NN_*.sql` file changes the demo output and
  the demo must be regenerated and committed in the same change.

The shared escape, `sql/lib/json_escape.plsql:27-31`:

```sql
    FUNCTION json_escape(p_str VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(p_str,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' ');
    END json_escape;
```

Used for user-controllable names at `sql/14_segment_io.sql:328-329`
(`s.seg_name`, `s.object_type`), `sql/15_file_io.sql:329`
(`s.file_short`), and for Oracle-defined names elsewhere (09, 18).

Section 06 has its own inline copy of the same chain for MODULE / ACTION /
schema names, `sql/06_top_sql.sql:743-750`:

```sql
        -- module/action are app-set free text; escape backslash, quote, and
        -- stray CR/LF so the JS string literal and one-line PUT_LINE both stay
        -- well-formed (schema names are tame, but route them through the same
        -- escape for uniformity).
        v_new_entry := '{"name":"'
            || REPLACE(REPLACE(REPLACE(REPLACE(sc.grp_value,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' ')
            || '","cur":' || NVL(TO_CHAR(sc.cur_rnk), 'null')
```

(`sc.grp_value` comes from `NVL(s.module, '(none)')` / `NVL(s.action,
'(none)')` at `sql/06_top_sql.sql:610-611`.)

An existing exemplar that already neutralises the end-tag sequence, in the
marker emitter `sql/lib/markers_inline.sql:36`:

```sql
            || REPLACE(REPLACE(REPLACE(p_label, '\', '\\'), '"', '\"'), '</', '<\/')
```

The three tooltip lines are **textually identical** (387 characters each):
`sql/06_top_sql.sql:892`, `sql/14_segment_io.sql:677`,
`sql/15_file_io.sql:722`. The relevant fragment inside each:

```
.map(function(p){return p.marker+" "+p.seriesName+": <b>"+fmt(p.value)+" "+d.unit+"</b>";})
```

ECharts renders an axis tooltip built by a `formatter` function as HTML, so
`p.seriesName` (the module / segment / file name) is inserted as markup.

The Python twin of the escape, `demo/awrdemo/helpers.py:528-532`:

```python
def json_escape(s) -> str:
    if s is None:
        return ""
    return (str(s).replace("\\", "\\\\").replace('"', '\\"')
            .replace("\r", " ").replace("\n", " "))
```

Rules of this codebase that apply to every SQL edit (each has bitten before):

- **Never type a tilde character** in any `sql/` file, not even in a
  comment: `SET DEFINE '~'` makes it the substitution character and a stray
  one prompts for input and truncates the section. `./lint.sh` checks this.
- **Emitted text must be pure ASCII** (lint check 25). Write `<`, never
  a literal non-ASCII character.
- A `PUT_LINE('…')` source line must stay under 2499 characters.
- Inside a PL/SQL string literal a single quote is written `''`. The edits
  below add no single quotes.
- Do not end a `--` comment with `;`.
- The fleet report (`sql/fleet/*`, `awr_fleet_extract.sql`,
  `run_awr_fleet.sh`) is out of scope: its copies of this chain only carry
  Oracle-defined wait class / event names.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | `wrote …/docs/examples/demo_busy_db.html (… KB)` |
| Demo determinism | run the generator twice, `md5sum docs/examples/demo_busy_db.html` after each | same md5 both times |
| Twin unit check | see step 2 | prints `ok` |

There is no database available to you. Real-database verification is listed
under "Maintenance notes" for the repository owner.

## Scope

**In scope** (the only files you should modify):
- `sql/lib/json_escape.plsql`
- `sql/06_top_sql.sql` (the inline chain at 747-749 and the tooltip line 892)
- `sql/14_segment_io.sql` (tooltip line 677)
- `sql/15_file_io.sql` (tooltip line 722)
- `demo/awrdemo/helpers.py` (`json_escape` twin)
- `docs/examples/demo_busy_db.html` (regenerated output — never hand-edit)

**Out of scope** (do NOT touch):
- `sql/fleet/*`, `awr_fleet_extract.sql`, `run_awr_fleet.sh` — fleet-owned
  copies; names there are Oracle-defined.
- `sql/16_day_profile.sql`'s local `js()` helper — fixed stat labels only.
- `sql/18_sqlmon.sql`'s tooltip — it prints `sql_id` and an Oracle status word.
- HTML escaping in table cells — already done everywhere with
  `DBMS_XMLGEN.CONVERT`.
- Any refactor that makes 06 include `json_escape.plsql` (PL/SQL declaration
  order rules make that riskier than a one-token edit).

## Git workflow

- Branch: `advisor/004-escape-db-names` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(report): escape < in inline JSON names and HTML-escape chart tooltips`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Neutralise `<` in the shared JSON escape

In `sql/lib/json_escape.plsql`, replace the function body with (the new
`REPLACE` is the **outermost**, so the backslash it introduces is not
doubled by the backslash step):

```sql
    FUNCTION json_escape(p_str VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p_str,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' '),
                   '<', '<');
    END json_escape;
```

In the file's header comment, extend the sentence that lists what is
escaped: add that a less-than sign is emitted as the JSON escape `<`
"so a name can never end the surrounding script element" (JavaScript decodes
it back to the same character, so displayed names are unchanged).

**Verify**: `./lint.sh` → clean. `grep -c "u003c" sql/lib/json_escape.plsql` → 2 or more.

### Step 2: Keep the Python twin in lockstep

In `demo/awrdemo/helpers.py`, change `json_escape` to:

```python
def json_escape(s) -> str:
    if s is None:
        return ""
    return (str(s).replace("\\", "\\\\").replace('"', '\\"')
            .replace("\r", " ").replace("\n", " ")
            .replace("<", "\\u003c"))
```

**Verify**:
`PYTHONPATH=demo python3 -c "from awrdemo.helpers import json_escape as j; assert j('a</b>c') == r'a</b>c', j('a</b>c'); assert j('plain') == 'plain'; assert j(None) == ''; print('ok')"`
→ prints `ok`.

### Step 3: Fix section 06's inline copy

In `sql/06_top_sql.sql` at the `v_new_entry := '{"name":"'` statement
(around line 747), wrap the existing four-`REPLACE` chain in one more:

```sql
        v_new_entry := '{"name":"'
            || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(sc.grp_value,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' '),
                   '<', '<')
            || '","cur":' || NVL(TO_CHAR(sc.cur_rnk), 'null')
```

Extend the comment above it with: "a less-than sign becomes the JSON escape
< so the value can not end the script element (same rule as
sql/lib/json_escape.plsql)". Do not end the comment with `;`.

**Verify**: `./lint.sh` → clean. `grep -c "u003c" sql/06_top_sql.sql` → 2 or more.

### Step 4: HTML-escape the series name in the three tooltips

In each of `sql/06_top_sql.sql` (line ~892), `sql/14_segment_io.sql`
(~677) and `sql/15_file_io.sql` (~722), inside the `tooltip:{trigger:"axis"…`
line, replace exactly this fragment:

```
p.marker+" "+p.seriesName+": <b>"
```

with:

```
p.marker+" "+String(p.seriesName).replace(/&/g,"&amp;").replace(/</g,"&lt;")+": <b>"
```

Nothing else on the line changes. The three lines must remain identical to
each other after the edit.

**Verify**:
- `grep -c 'p.seriesName+": <b>"' sql/06_top_sql.sql sql/14_segment_io.sql sql/15_file_io.sql` → `0` for all three.
- `grep -c 'String(p.seriesName).replace(/&/g,"&amp;").replace(/</g,"&lt;")' sql/06_top_sql.sql sql/14_segment_io.sql sql/15_file_io.sql` → `1` for each.
- `awk 'length($0) > 2400' sql/06_top_sql.sql sql/14_segment_io.sql sql/15_file_io.sql | wc -l` → the same number as before your edit (run it on `git stash` state or compare with `git show e755b97:<file> | awk 'length($0) > 2400' | wc -l`).
- `./lint.sh` → clean.

### Step 5: Regenerate the demo and confirm the change reached it

Run `python3 demo/gen_demo_report.py` twice.

**Verify**:
- `md5sum docs/examples/demo_busy_db.html` is identical after both runs.
- `grep -c 'String(p.seriesName).replace(/&/g,"&amp;").replace(/</g,"&lt;")' docs/examples/demo_busy_db.html` → `3` or more (the lifted tooltip line appears once per chart script).
- `grep -c 'p.seriesName+": <b>"' docs/examples/demo_busy_db.html` → `0`.
- `git diff --stat -- docs/examples/demo_busy_db.html` → the file changed (if it did NOT change, the twins no longer lift these lines → STOP).

### Step 6: Final check

**Verify**: `./lint.sh` → clean; `git status --short` lists only the six in-scope files.

## Test plan

- The repo has no SQL unit tests and no database is available; the
  verifications are lint, the Python twin assertion (step 2), and the
  regenerated demo containing the new tooltip code (step 5).
- If `tools/check.sh` exists (plan 003), run it → `check.sh: all checks passed`.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `grep -c "u003c" sql/lib/json_escape.plsql sql/06_top_sql.sql demo/awrdemo/helpers.py` → each ≥ 1
- [ ] `grep -c 'p.seriesName+": <b>"' sql/06_top_sql.sql sql/14_segment_io.sql sql/15_file_io.sql` → all `0`
- [ ] `python3 demo/gen_demo_report.py` is deterministic and its output is committed
- [ ] `git status --short` shows only in-scope files
- [ ] `plans/README.md` status row updated (note: "needs owner DB run" — see Maintenance notes)

## STOP conditions

- The three tooltip lines are no longer identical to each other or no
  longer contain the exact fragment in step 4.
- `./lint.sh` reports a finding you can not attribute to a typo of yours
  (for example a tilde or non-ASCII finding in a file you edited).
- The demo output does not change in step 5, or changes in more places than
  the tooltip lines (run `git diff --word-diff=porcelain -- docs/examples/demo_busy_db.html | grep -c '^+'`
  and report the count if it is larger than 10).
- A fix appears to require editing a fleet file.

## Maintenance notes

- **Owner verification on a real database (not possible for the executor):**
  run one report on the test database (`./run_awr_trend.sh …`) and confirm
  rc 0, 20/20 `AWR-SECTION` BEGIN/END pairs and that the Top SQL "by module"
  chart, the Segment I/O chart and the File I/O chart still draw with their
  tooltips. Names without a less-than sign must look exactly as before.
- New inline-JSON emitters must use `json_escape()`; new HTML tooltip
  formatters must escape any name that is not generated by the report.
- Deferred, deliberately: the fleet copies of the chain
  (`sql/fleet/02_ash.sql:150,233`, `sql/fleet/06_day_profile.sql:61`) and
  `sql/16_day_profile.sql:115` — Oracle-defined or fixed names only. If a
  user-controllable string is ever routed through them, apply the same
  `<` step.
