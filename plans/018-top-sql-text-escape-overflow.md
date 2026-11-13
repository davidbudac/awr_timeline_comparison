# Plan 018: A top statement with many quotes can not abort the report (section 06, ORA-19011)

> **Executor instructions**: Follow this plan step by step. Run each step's
> Verify before the next step. If anything in "STOP conditions" occurs, stop
> and report. When done, update this plan's status row in `plans/README.md`
> — unless a reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8d5103d..HEAD -- sql/06_top_sql.sql`
> must be empty. If it is not, compare the "Current state" excerpts with the
> live file; a mismatch is a STOP condition.

## Status

- **Priority**: P1 (aborts the whole report; data-dependent)
- **Effort**: S
- **Risk**: LOW (output is byte-identical for every statement that renders today)
- **Depends on**: 006 (already executed: it changed the `v_snip` assignment quoted below)
- **Category**: bug
- **Planned at**: commit `8d5103d`, 2026-11-13. Found by plan 017's shape-C run
  (see `plans/017-results.md`, "Defect found"); reproduced on the tree before
  plans 001-017 as well (exit code 67), so it is not a regression.

## Why this matters

Section 06 prints every pool statement's SQL text (up to 8000 bytes) inside
`<pre class="sql">` through one `DBMS_XMLGEN.CONVERT(v_snip)` call. On
Oracle 19c that function raises `ORA-19011: Character string buffer too
small` when the escaped result outgrows an internal buffer of roughly
`max(4000, 4/3 x input bytes)`. Measured on 19.27 with pure function calls
(`'` becomes `&apos;`, 6 bytes):

| Input | Escaped size | Result |
|---|---|---|
| 666 quotes | 3996 | ok |
| 667 quotes | 4002 | ORA-19011 |
| 500 quotes + 1000 plain | 4000 | ok |
| 500 quotes + 2000 plain | 5000 | ORA-19011 |
| 1000 quotes + 7000 plain | 13000 | ORA-19011 |
| 100 quotes + 7900 plain | 8500 | ok |
| 8000 plain | 8000 | ok |

So any top statement whose text holds a few hundred `'`, `"`, `<`, `>` or
`&` (a long `IN ('a','b',...)` list, generated SQL, XML/JSON literals) can
trip it. Under `WHENEVER SQLERROR EXIT` the whole run ends with exit code
67 and a report cut off in the middle of section 06. It was hit for real:
a 2943-character statement with 216 single quotes, on a 168-window run.

Escaping in pieces is exact: `CONVERT` works character by character, so
`CONVERT(a) || CONVERT(b)` equals `CONVERT(a || b)` (verified), and a piece
of 500 characters can never exceed 3000 escaped bytes.

A second limit sits right behind the first: the line goes out through one
`DBMS_OUTPUT.PUT_LINE`, which holds 32767 bytes. 8000 bytes of text can
escape to 48000. The fix therefore also stops adding pieces before the
line would pass 32000 bytes and says so in the existing "truncated" note.

## Current state

`sql/06_top_sql.sql`, the nested `DECLARE` of the per-SQL pool loop (about
line 983):

```sql
    DECLARE
        v_sql_id          VARCHAR2(30);
        v_text            CLOB;
        v_len             NUMBER;
        v_snip            VARCHAR2(8000);
        v_first_seen      VARCHAR2(30);
```

The text is loaded once per statement (about line 1105):

```sql
            IF v_text IS NULL THEN
                v_len  := 0;
                v_snip := '(text not in DBA_HIST_SQLTEXT)';
            ELSE
                v_len  := DBMS_LOB.GETLENGTH(v_text);
                -- 8000 characters can be up to 32000 bytes in AL32UTF8 and
                -- v_snip holds 8000 BYTES: cut by bytes (SUBSTRB never
                -- returns a partial character). ASCII text is unchanged.
                v_snip := SUBSTRB(DBMS_LOB.SUBSTR(v_text, 8000, 1), 1, 8000);
            END IF;
```

and printed at the end of the statement's detail row (about line 1331):

```sql
            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || DBMS_XMLGEN.CONVERT(v_snip)
                || CASE WHEN v_len > LENGTH(v_snip)
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');
```

Every other `DBMS_XMLGEN.CONVERT` call in `sql/` takes a short value (a
name, a 512-byte parameter value, a snippet cut to at most 400 characters:
400 x 6 = 2400 bytes), so this is the only call that can overflow. Do not
change the others.

Conventions that apply (from `CLAUDE.md`): `~` is the live SQL*Plus
substitution character, even in comments — write no tilde; emitted text is
pure ASCII; inside this nested `DECLARE` only plain variables are declared
(no include, no subprogram), so new variables simply go next to `v_snip`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (76 files checked)` |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Demo unchanged | `python3 demo/gen_demo_report.py --check` | `up to date: ...` |

## Scope

**In scope**:
- `sql/06_top_sql.sql` (the three places below, nothing else)
- `CLAUDE.md` (one gotcha bullet)

**Out of scope**: every other `DBMS_XMLGEN.CONVERT` call; the demo twin
`demo/awrdemo/sections/s06_top_sql.py` (Python's escape has no such limit
and the output for ordinary text does not change); section 11; a shared
`sql/lib` helper (one call site does not justify one).

## Git workflow

- Branch: `advisor/018-top-sql-text-escape-overflow` (or the branch your
  dispatcher names).
- One commit: `fix(report): escape long SQL text in pieces (ORA-19011 in section 06)`.
- Do NOT push.

## Steps

### Step 1: Declare the working variables

In the nested `DECLARE`, directly after the line
`        v_snip            VARCHAR2(8000);`, add:

```sql
        -- v_snip escaped for the <pre> block, built 500 characters at a
        -- time (see the loop before the PUT_LINE), and how many characters
        -- of v_snip it covers.
        v_snip_esc        VARCHAR2(32767);
        v_snip_part       VARCHAR2(4000);
        v_snip_shown      PLS_INTEGER;
```

**Verify**: `./lint.sh` → clean.

### Step 2: Escape in pieces and cap the line

Replace the whole `DBMS_OUTPUT.PUT_LINE('<pre class="sql">' ... '</pre>');`
statement quoted under "Current state" with:

```sql
            -- DBMS_XMLGEN.CONVERT raises ORA-19011 when the escaped text
            -- outgrows its internal buffer (667 quotes are enough), which
            -- under WHENEVER SQLERROR EXIT ends the whole report. Escaping
            -- is per character, so 500-character pieces give the same
            -- bytes and can not overflow (500 x 6 = 3000). The pieces stop
            -- before the PUT_LINE limit of 32767 bytes -- only text that is
            -- mostly quotes or angle brackets gets there -- and the note
            -- below then reports the cut.
            v_snip_esc   := NULL;
            v_snip_shown := 0;
            WHILE v_snip_shown < NVL(LENGTH(v_snip), 0) LOOP
                v_snip_part := DBMS_XMLGEN.CONVERT(SUBSTR(v_snip, v_snip_shown + 1, 500));
                EXIT WHEN NVL(LENGTHB(v_snip_esc), 0) + LENGTHB(v_snip_part) > 32000;
                v_snip_esc   := v_snip_esc || v_snip_part;
                v_snip_shown := LEAST(v_snip_shown + 500, LENGTH(v_snip));
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || v_snip_esc
                || CASE WHEN v_len > v_snip_shown
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');
```

Why this is byte-identical for text that renders today:
- `v_snip_esc` equals `DBMS_XMLGEN.CONVERT(v_snip)` whenever the loop runs
  to the end, and then `v_snip_shown = LENGTH(v_snip)`, so the `CASE` is
  the old `v_len > LENGTH(v_snip)`.
- The placeholder case (`v_text IS NULL`): `v_len` is 0, the note is not
  printed, as before.
- The note's text is unchanged.

**Verify**:
- `./lint.sh` → clean.
- `grep -c "DBMS_XMLGEN.CONVERT(v_snip)" sql/06_top_sql.sql` → `0`.
- `grep -c "v_snip_shown" sql/06_top_sql.sql` → 6 or more.
- `awk 'length($0) > 2400' sql/06_top_sql.sql | wc -l` → the same number
  as before your edit (run it on `git show HEAD:sql/06_top_sql.sql` to
  compare).
- `LC_ALL=C grep -n '[^ -~]' sql/06_top_sql.sql | grep -c "v_snip_"` → `0`
  (no non-ASCII byte in the lines you added; a tab is fine only if the file
  already uses tabs there, which it does not).

### Step 3: Record the gotcha

In `CLAUDE.md`, section "Gotchas from the v1.5.0 / v1.6.0 passes", add one
bullet at the END of that list (before the `### \`echarts\` var` heading):

```markdown
- **`DBMS_XMLGEN.CONVERT` on a long `VARCHAR2` can raise ORA-19011**: the
  escaped result must fit an internal buffer of about `max(4000, 4/3 x
  input)` bytes, so 667 quotes fail while 8000 plain bytes pass. Fine for
  names and snippets cut to a few hundred characters (400 x 6 = 2400);
  anything longer is escaped in 500-character pieces, as 06 does for the
  full SQL text (which also stops before `PUT_LINE`'s 32767 bytes). Bit a
  168-window run on dbmint, 2026-11-13: a top statement with 216 quotes
  ended the report with exit code 67.
```

**Verify**: `grep -c "can raise ORA-19011" CLAUDE.md` → `1`.

### Step 4: Final checks

**Verify**: `./tools/check.sh` → `check.sh: all checks passed` (this
includes the demo freshness check: the demo must NOT change);
`git status --short` → only `sql/06_top_sql.sql` and `CLAUDE.md` (plus
whatever your dispatcher told you to ignore).

## Test plan

No database is available to the executor, and the project has no SQL unit
tests; the checks are static. The reviewer verifies on the test database:

1. Shape C (`AUTO 1 168 10 0 1 h comprehensive Y`) ends with exit code 0
   and 20 `AWR-SECTION` END markers (it ends with 67 and 12 today).
2. A pinned run (`'2026-11-08 18:00' 1 4 10 0 1 h comprehensive N '' 7`)
   is byte-identical in section 06 before and after.

## Done criteria

- [ ] `./tools/check.sh` exits 0
- [ ] `grep -c "DBMS_XMLGEN.CONVERT(v_snip)" sql/06_top_sql.sql` → `0`
- [ ] `grep -c "can raise ORA-19011" CLAUDE.md` → `1`
- [ ] `git status --short` shows only the two in-scope files
- [ ] `plans/README.md` status row updated (or left to the reviewer)

## STOP conditions

- The excerpts under "Current state" do not match the live file.
- The nested `DECLARE` turns out to contain a subprogram or an
  `@@sql/lib/*.plsql` include before the place where step 1 adds variables
  (a variable declared after a subprogram does not compile, lint check 14).
- `./lint.sh` reports a finding you can not fix inside the two in-scope
  files.
- You find another `DBMS_XMLGEN.CONVERT` call whose argument can exceed
  about 660 characters — report it; do not fix it here.

## Maintenance notes

- Needs the reviewer's two database runs above before release.
- `v_snip_part` is `VARCHAR2(4000)`: a 500-character piece escapes to at
  most 3000 bytes when every character is ASCII, and a multibyte character
  is never escaped (500 x 4 = 2000 bytes), so 4000 always suffices.
- If section 11 or the fleet ever print more than a few hundred characters
  of SQL text, they need the same loop.
