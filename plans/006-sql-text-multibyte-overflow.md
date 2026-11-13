# Plan 006: Multibyte SQL text can no longer abort the report (sections 06 and 11)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- sql/06_top_sql.sql sql/11_top_sql_ash_breakdown.sql`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The report runs under `WHENEVER SQLERROR EXIT`: one PL/SQL error anywhere
aborts the whole run and no report is produced. Two places copy SQL text
from a CLOB into a PL/SQL `VARCHAR2` whose size is counted in **bytes**
while the copy length is counted in **characters**:

- Section 06 copies up to 8000 characters into `VARCHAR2(8000)`.
- Section 11 copies up to 200 characters into a `VARCHAR2(256)` element.

On a Unicode database (AL32UTF8, the default), accented or CJK characters
take 2–4 bytes each. A top-N statement whose text has more than 85 CJK
characters in its first 200 (section 11), or is long and contains multibyte
characters (section 06), raises `ORA-06502: character string buffer too
small` and the entire report fails. Comments or string literals in the
national language are enough. ASCII-only SQL text is unaffected, which is
why the test database never showed it.

## Current state

### Section 06 — `sql/06_top_sql.sql`

Declarations (`:980-984`):

```sql
    DECLARE
        v_sql_id          VARCHAR2(30);
        v_text            CLOB;
        v_len             NUMBER;
        v_snip            VARCHAR2(8000);
```

The copy (`:1102-1108`):

```sql
            IF v_text IS NULL THEN
                v_len  := 0;
                v_snip := '(text not in DBA_HIST_SQLTEXT)';
            ELSE
                v_len  := DBMS_LOB.GETLENGTH(v_text);
                v_snip := DBMS_LOB.SUBSTR(v_text, 8000, 1);
            END IF;
```

`DBMS_LOB.SUBSTR(clob, 8000, 1)` returns 8000 **characters**, up to 32000
bytes; the assignment into a 8000-byte variable is what raises.

The two consumers of `v_snip` (`:1171-1172` and `:1325-1330`):

```sql
                || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(v_snip, ''), 1, 90))
                || CASE WHEN LENGTH(NVL(v_snip, '')) > 90 THEN '&hellip;' ELSE '' END
...
            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || DBMS_XMLGEN.CONVERT(v_snip)
                || CASE WHEN v_len > 8000
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');
```

`DBMS_OUTPUT.PUT_LINE` accepts at most 32767 bytes per line, so simply
widening `v_snip` to 32767 would move the failure to the `PUT_LINE`. The fix
therefore keeps the 8000-**byte** budget and cuts by bytes.

### Section 11 — `sql/11_top_sql_ash_breakdown.sql`

The collection type (`:63-64`) and its use (`:69`):

```sql
    TYPE t_num_by_str  IS TABLE OF NUMBER       INDEX BY VARCHAR2(200);
    TYPE t_str_by_str  IS TABLE OF VARCHAR2(256) INDEX BY VARCHAR2(30);
...
    v_sql_text      t_str_by_str;
```

The copy (`:394-404`); only `NO_DATA_FOUND` is handled, so the size error
propagates and aborts the run:

```sql
        BEGIN
            SELECT SUBSTR(REPLACE(REPLACE(DBMS_LOB.SUBSTR(sql_text, 200, 1),
                                          CHR(10), ' '), CHR(13), ' '), 1, 200)
            INTO   v_sql_text(v_sid)
            FROM   dba_hist_sqltext
            WHERE  dbid IN (~dbid_list)
              AND  sql_id = v_sid
              AND  ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_sql_text(v_sid) := '(sql text not available)';
        END;
```

The value is printed at `:448` through `DBMS_XMLGEN.CONVERT(v_sql_text(v_sid))`.

### Rules of this codebase that apply to every SQL edit

- **Never type a tilde character** in any `sql/` file, not even in a
  comment (`SET DEFINE '~'` makes it the substitution character). The
  existing `~dbid_list` tokens in the excerpts are substitution variables —
  leave them exactly as they are and do not add new ones.
- Emitted text must be pure ASCII; do not end a `--` comment with `;`;
  PL/SQL plain variable declarations must come before any `@@sql/lib/*.plsql`
  include in the same `DECLARE` (you add no declarations here).
- For ASCII SQL text the output must stay **byte-identical** to today.
- `SUBSTRB(str, 1, n)` is Oracle's byte-counted substring; it never returns
  a partial multibyte character (a split character is replaced by blanks).

The Python demo twins (`demo/awrdemo/sections/s06_top_sql.py:513`
`text[:8000]`, and s11) work on Python `str` and have no byte limit; their
output does not change, so no demo regeneration is needed. Confirm in step 4.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Demo unchanged | `python3 demo/gen_demo_report.py && git status --short docs/examples/demo_busy_db.html` | no output from `git status` |

No database is available to you. Real-database verification is listed
under "Maintenance notes" for the repository owner.

## Scope

**In scope** (the only files you should modify):
- `sql/06_top_sql.sql`
- `sql/11_top_sql_ash_breakdown.sql`

**Out of scope** (do NOT touch):
- `sql/fleet/05_topsql.sql` and `sql/06_top_sql.sql:328` — those read the
  text inside a SQL cursor (`DBMS_LOB.SUBSTR(...) AS sql_text_short`), where
  the column is sized by the query (4000 bytes for at most 401 characters);
  not affected.
- `sql/lib/put_clob_chunked.plsql`.
- The demo twins.

## Git workflow

- Branch: `advisor/006-sql-text-multibyte-overflow` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(report): multibyte SQL text no longer overflows 06/11 buffers`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Section 06 — cut the snippet by bytes

In `sql/06_top_sql.sql`, change the assignment at line ~1107 from

```sql
                v_snip := DBMS_LOB.SUBSTR(v_text, 8000, 1);
```

to

```sql
                -- 8000 characters can be up to 32000 bytes in AL32UTF8 and
                -- v_snip holds 8000 BYTES: cut by bytes (SUBSTRB never
                -- returns a partial character). ASCII text is unchanged.
                v_snip := SUBSTRB(DBMS_LOB.SUBSTR(v_text, 8000, 1), 1, 8000);
```

Leave the declaration `v_snip VARCHAR2(8000);` as it is.

**Verify**: `grep -n "v_snip := " sql/06_top_sql.sql` → two lines: the
`'(text not in DBA_HIST_SQLTEXT)'` literal and the new `SUBSTRB(…)` line.

### Step 2: Section 06 — make the "truncated" note follow the real cut

With a byte cut, multibyte text shorter than 8000 characters can now be
truncated; the note must say so. In the `PUT_LINE('<pre class="sql">' …`
statement (line ~1327), change the condition

```sql
                || CASE WHEN v_len > 8000
```

to

```sql
                || CASE WHEN v_len > LENGTH(v_snip)
```

Nothing else in the statement changes. (For ASCII text `LENGTH(v_snip)` is
`LEAST(v_len, 8000)`, so the note appears in exactly the same cases as
today; when `v_text` is NULL, `v_len` is 0 and the note stays off.)

**Verify**:
- `grep -c "v_len > 8000" sql/06_top_sql.sql` → `0`.
- `grep -c "v_len > LENGTH(v_snip)" sql/06_top_sql.sql` → `1`.

### Step 3: Section 11 — size the snippet element for 200 characters

In `sql/11_top_sql_ash_breakdown.sql`, change line ~64 from

```sql
    TYPE t_str_by_str  IS TABLE OF VARCHAR2(256) INDEX BY VARCHAR2(30);
```

to

```sql
    -- 1000 bytes: holds 200 CHARACTERS of SQL text at up to 4 bytes each
    -- (AL32UTF8); 256 raised ORA-06502 on multibyte text.
    TYPE t_str_by_str  IS TABLE OF VARCHAR2(1000) INDEX BY VARCHAR2(30);
```

Then check every other use of the type so nothing depended on 256:
`grep -n "t_str_by_str" sql/11_top_sql_ash_breakdown.sql`.

**Verify**: each variable declared with `t_str_by_str` is only assigned
short strings or this 200-character snippet (read the 5–10 lines around
each assignment). If one of them is concatenated into a buffer declared
smaller than 1000 bytes, STOP and report it.

### Step 4: Lint and demo

**Verify**:
- `./lint.sh` → `lint: clean`, exit 0.
- `python3 demo/gen_demo_report.py` then
  `git status --short docs/examples/demo_busy_db.html` → no output (the demo
  twins did not need to change).
- `git status --short` → only the two in-scope SQL files.

## Test plan

- There are no SQL unit tests and no database here. Verification is lint +
  the greps above + unchanged demo output.
- If `tools/check.sh` exists (plan 003), run it → `check.sh: all checks passed`.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `grep -c "SUBSTRB(DBMS_LOB.SUBSTR(v_text, 8000, 1), 1, 8000)" sql/06_top_sql.sql` → `1`
- [ ] `grep -c "v_len > 8000" sql/06_top_sql.sql` → `0`
- [ ] `grep -c "VARCHAR2(256) INDEX BY VARCHAR2(30)" sql/11_top_sql_ash_breakdown.sql` → `0`
- [ ] Demo output unchanged; `git status --short` shows only the two SQL files
- [ ] `plans/README.md` status row updated (note: "needs owner DB run")

## STOP conditions

- The excerpts above do not match the live files.
- `t_str_by_str` turns out to be used for something that is later copied
  into a fixed buffer smaller than 1000 bytes.
- The demo output changes (it should not).
- You find yourself wanting to widen `v_snip` beyond 8000 — do not; the
  `PUT_LINE` 32767-byte line limit is the reason for the byte budget.

## Maintenance notes

- **Owner verification on a real database (not possible for the executor):**
  1. A normal pinned-window run must be byte-identical before/after for
     sections 06 and 11 apart from their known run-to-run rank-tie noise
     (ASCII SQL text takes the same path as before).
  2. In a scratch session on the test DB, run a statement often enough to
     reach the top-N whose text contains a long multibyte comment, take two
     AWR snapshots around it, and confirm the report completes (rc 0, 20/20
     `AWR-SECTION` pairs) and the statement's `<pre class="sql">` block ends
     with the "truncated" note.
- Known remaining edge, deliberately not addressed: `DBMS_XMLGEN.CONVERT`
  expands `<`, `>`, `&`, quotes into entities (up to 6 bytes each), so a
  snippet that is almost entirely such characters could still exceed the
  32767-byte `PUT_LINE` limit. Realistic SQL text does not get near it; if it
  ever bites, emit the snippet through `sql/lib/put_clob_chunked.plsql`.
- Any new "copy N characters of a CLOB into a VARCHAR2" must size the
  target at 4 × N bytes or cut with `SUBSTRB`.
