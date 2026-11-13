# Plan 019: A parameter that differs in many windows can not abort the report (section 17, ORA-06502)

> **Executor instructions**: Follow this plan step by step. Run each step's
> Verify before the next step. If anything in "STOP conditions" occurs, stop
> and report. When done, update this plan's status row in `plans/README.md`
> — unless a reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5d7361b..HEAD -- sql/17_narrative.sql`
> must be empty. If it is not, compare the "Current state" excerpts with the
> live file; a mismatch is a STOP condition.

## Status

- **Priority**: P1 (aborts the whole report at its last section; data-dependent)
- **Effort**: S
- **Risk**: LOW (two buffer sizes; output is byte-identical for every run that completes today)
- **Depends on**: none (found right behind plan 018's defect: the same
  168-window run that used to stop in section 06 now reaches section 17)
- **Category**: bug
- **Planned at**: commit `50c7044`, 2026-11-13

## Why this matters

Section 17 (the verdict's notes, the LAST section of the report) builds, for
each of the up to three most-changed parameters, the list of windows in
which the parameter's value differs from the Current window: "`x` in -2h,
-5h, -9h". A contiguous run collapses to "-5h to -12h" and all windows to
"every prior window", but a **non-contiguous** list is written out in full
into `v_acc VARCHAR2(400)`. One label costs about 7 bytes (", -168h"), so
roughly 57 scattered windows overflow it: `ORA-06502: PL/SQL: numeric or
value error: character string buffer too small`. Under `WHENEVER SQLERROR
EXIT` the run ends with exit code 102 and the report lacks its epilogue.

Hit for real on the test database: `AUTO 1 168 10 0 1 h` (169 windows, 117
valid) on a database that was restarted with different parameters several
times in the span. The error stack points at the `v_acc := v_acc || ...`
line. This is the project's known rule "per-window strings must not assume
13 windows" (`CLAUDE.md`, gotchas) missed in one place.

The three per-parameter lists are then concatenated into
`v_p_names VARCHAR2(4000)`, which would overflow next (3 x ~1200 bytes fit
at 168 windows, but 3 x ~2600 at 365 daily windows do not).

## Current state

`sql/17_narrative.sql`, outer `DECLARE` (about line 116):

```sql
    v_p_names   VARCHAR2(4000);
```

and the nested block of rule R3 (about line 670):

```sql
        DECLARE
            v_k      PLS_INTEGER := 1;
            v_off    VARCHAR2(20);
            v_acc    VARCHAR2(400) := '';
            v_first  NUMBER;
            v_last   NUMBER;
            v_prev   NUMBER;
            v_contig BOOLEAN := TRUE;
        BEGIN
            LOOP
                v_off := REGEXP_SUBSTR(p.offs, '[^,]+', 1, v_k);
                EXIT WHEN v_off IS NULL;
                ...
                v_acc := v_acc || CASE WHEN v_k = 1 THEN '' ELSE ', ' END
                      || off_lbl(TO_NUMBER(v_off));
                v_k := v_k + 1;
            END LOOP;
```

`v_p_names` ends up as the `p_why` argument of `add_item`, whose line is
stored in `v_sent`, a table of `VARCHAR2(32767)`, and printed with one
`PUT_LINE` (limit 32767 bytes).

`p.offs` is a SQL `LISTAGG` of the offsets (`'1,2,5,...'`, at most about
4 bytes per window), safe up to roughly 1000 windows; leave it.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (76 files checked)` |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |

## Scope

**In scope**: `sql/17_narrative.sql` (the two declarations below and one
comment). Nothing else.

**Out of scope**: shortening long window lists ("-2h, -5h and 40 more") —
that changes what today's reports print and is a presentation decision for
the owner; the demo twin `demo/awrdemo/sections/s17_narrative.py` (output
unchanged); `CLAUDE.md` (the rule is already documented there).

## Git workflow

- Branch: `advisor/019-narrative-param-window-list-overflow` (or the branch
  your dispatcher names).
- One commit: `fix(report): window list of a changed parameter no longer overflows (ORA-06502 in section 17)`.
- Do NOT push.

## Steps

### Step 1: Size the two buffers for any window count

1. In the outer `DECLARE`, change

   ```sql
       v_p_names   VARCHAR2(4000);
   ```

   to

   ```sql
       v_p_names   VARCHAR2(32767);   -- up to 3 parameters x a per-window list (v_acc below)
   ```

2. In R3's nested `DECLARE`, change

   ```sql
               v_acc    VARCHAR2(400) := '';
   ```

   to

   ```sql
               -- one label per differing window (about 7 bytes each): a
               -- per-window string, so sized for hundreds of windows, not 13
               v_acc    VARCHAR2(8000) := '';
   ```

Both are plain variable declarations that stay where they are, so the
declaration-order rule (variables before includes / subprograms, lint
check 14) is not affected.

Size check: 3 x 8000 bytes plus three parameter names and markup stays
under `v_p_names`' 32767 and under the `PUT_LINE` limit that the finished
line must respect.

**Verify**:
- `./lint.sh` → clean.
- `grep -c "v_acc    VARCHAR2(8000)" sql/17_narrative.sql` → `1`.
- `grep -c "v_p_names   VARCHAR2(32767)" sql/17_narrative.sql` → `1`.
- `git diff --stat` → `sql/17_narrative.sql` only, 2 lines changed plus the
  2 comment lines.

### Step 2: Final checks

**Verify**: `./tools/check.sh` → `check.sh: all checks passed` (the demo
must not change); `git status --short` → only `sql/17_narrative.sql` (plus
whatever your dispatcher told you to ignore).

## Test plan

Static checks only for the executor. The reviewer verifies on the test
database: `AUTO 1 168 10 0 1 h comprehensive Y` ends with exit code 0, 20
`AWR-SECTION` END markers and the line `all sections rendered; writing HTML
epilogue` in the log (it ends with exit code 102 and 19 markers today); a
pinned 4-window run is byte-identical in section 17.

## Done criteria

- [ ] `./tools/check.sh` exits 0
- [ ] Both greps of step 1 return `1`
- [ ] `git status --short` shows only the in-scope file
- [ ] `plans/README.md` status row updated (or left to the reviewer)

## STOP conditions

- The excerpts under "Current state" do not match the live file.
- You find another string in section 17 that grows by one token per
  compared window and is smaller than 4000 bytes — report it; do not fix
  it here.

## Maintenance notes

- Needs the reviewer's database run above before release.
- A list of 100 scattered windows is correct but hard to read in the
  verdict; capping it ("... and N more windows") is a possible follow-up
  for the owner to decide (it changes existing output).
- Beyond roughly 1000 windows `p.offs` (a SQL `LISTAGG`, 4000 bytes) is the
  next limit; the wrapper's realistic maximum is far below that.
