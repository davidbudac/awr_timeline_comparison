# Plan 007: `target_end` snaps to the snapshot grid whenever the window rule would otherwise reject the Current window

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- awr_trend.sql awr_fleet_extract.sql sql/lib/windows_cte.sql CLAUDE.md`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW-MED (logic is small and additive, but it can only be proven on a real database, which the executor does not have)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The report compares a time window ending at `target_end` with earlier
windows. Each window needs an AWR snapshot near its start and near its end.
Two pieces of code decide whether the requested end is usable, and they
disagree:

- The **driver** keeps the requested end as-is when the last snapshot at or
  before it is at most 15 minutes **earlier** (window `[req − 15 min, req + 5 min]`).
- The **window rule** (`windows_cte`) accepts an end snapshot only in
  `[req − 5 min, req + 15 min]`.

So when the nearest snapshot is 6–15 minutes *before* the requested end and
the next one is more than 15 minutes after it (any hourly snapshot schedule
that fires at :45–:54, or a request a few minutes after a snapshot), the
driver keeps the request, the window rule then rejects **every** window, and
the report comes out empty — on every run, including the default `AUTO`. The
driver has a "snap back to the last real snapshot" path built for exactly
this; it just is not taken. This plan makes the driver keep the request
only when the window rule will also accept it.

## Current state

### The driver's rule — `awr_trend.sql:356-380`

```sql
    SELECT
        rs.req_ts                                                  AS req_ts,
        CASE
            WHEN rs.last_snap_ts IS NULL THEN rs.req_ts
            WHEN rs.req_ts - rs.last_snap_ts <= 15/1440 THEN rs.req_ts
            ELSE TRUNC(rs.last_snap_ts, 'MI')
        END                                                        AS eff_ts
    FROM (
        SELECT
            req.req_ts                                             AS req_ts,
            (SELECT MAX(CAST(end_interval_time AS DATE))
             FROM   dba_hist_snapshot
             WHERE  CAST(end_interval_time AS DATE) <= req.req_ts + 5/1440)
                                                                    AS last_snap_ts
        FROM (
            SELECT
                CASE
                    WHEN UPPER('~target_end') IN ('AUTO','NOW','')
                        THEN TRUNC(SYSDATE, 'HH24')
                    ELSE TO_DATE('~target_end', 'YYYY-MM-DD HH24:MI')
                END AS req_ts
            FROM dual
        ) req
    ) rs
) snp
```

The comment above it (`awr_trend.sql:338-355`) describes the three cases;
its middle bullet reads:

```sql
    --   - a snapshot already within the 15-min edge guard -> keep req_ts
    --     verbatim (byte-identical to current behavior for every request
    --     that already resolves valid windows)
```

### The deliberate lockstep copy — `awr_fleet_extract.sql:223-246`

The same `SELECT … FROM ( … ) rs` block, textually identical from
`SELECT` / `rs.req_ts` down to `) req`, with a shorter comment above it
(`:218-222`) that points at `awr_trend.sql` for the rationale. The project
rule is that these two blocks stay **textually parallel**.

### The window rule — `sql/lib/windows_cte.sql` (read-only for this plan)

End snapshot selection (`:117-125`) and the validity guard (`:179-180`):

```sql
        end_snap AS (
            SELECT week_offset, instance_number,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   ...
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
            GROUP BY week_offset, instance_number
        ),
...
                    WHEN ip.begin_end_ts < CAST(w.win_start_dt AS TIMESTAMP) - INTERVAL '15' MINUTE THEN 'N'
                    WHEN ip.end_end_ts   > CAST(w.win_end_dt   AS TIMESTAMP) + INTERVAL '15' MINUTE THEN 'N'
```

So the end snapshot is the **first** snapshot at or after `end − 5 min`, and
it is valid only if it is at most `end + 15 min`. Equivalent statement: the
Current window's end is acceptable **iff a snapshot exists in
`[req − 5 min, req + 15 min]`**.

### Truth table (L = last snapshot at or before `req + 5 min`)

| Where L is | Snapshot in `[req−5, req+15]`? | Today | After this plan |
|---|---|---|---|
| no snapshot at all | — | keep `req` | keep `req` (unchanged) |
| `req − L > 15 min` | any | snap to `TRUNC(L)` | snap to `TRUNC(L)` (unchanged) |
| `req − L ≤ 15 min` | yes | keep `req` | keep `req` (unchanged, byte-identical) |
| `req − L ≤ 15 min` | **no** | keep `req` → every window invalid | **snap to `TRUNC(L)`** (the fix) |

The second row must stay as it is: a schedule firing at :06–:15 past the
hour has a snapshot inside `[req−5, req+15]` but its *start* side would be
invalid if `req` were kept; today's snap-back handles it. That is why the
new test is an **additional** condition, not a replacement.

After snapping to `TRUNC(L, 'MI')`, the window ends on a real snapshot, so
the end rule holds by construction.

### Documentation of the rule — `CLAUDE.md`

Section "### `target_end` snap-to-snapshot-grid" contains these sentences
(the file is a long Markdown guide; `AGENTS.md` is a symlink to it):

> … if a snapshot exists within 15 min of the
> requested instant (mirroring `windows_cte`'s edge guard), the request is kept
> **verbatim** (byte-identical to pre-feature behavior); otherwise it snaps back
> to `TRUNC(last snapshot at or before request + 5 min tolerance, 'MI')` …

and, at the end of the paragraph:

> Dense snap grids (≤15-min spacing) can never trigger the snap, by design.

### Rules that apply to these edits (each has caused a production abort)

- Both blocks are inside a **top-level SQL statement**. SQL\*Plus ends the
  statement at a `;` that is the **last character of a line — even when
  that line is a `--` comment**. Never end a comment line with `;` here
  (simplest: write no `;` at all in the comments you add).
- **Never type a tilde** in these files, not even in a comment
  (`SET DEFINE '~'`). The existing `'~target_end'` tokens are substitution
  variables — leave them untouched.
- Pure ASCII only.
- The two blocks (driver and fleet extract) must receive the **same** edit.
- Do not edit `sql/lib/windows_cte.sql`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Lockstep check | see step 3 | `diff` prints nothing |

No database is available to you. The logic is verified by the lockstep
diff, lint, and the owner's database run described in "Maintenance notes".

## Scope

**In scope** (the only files you should modify):
- `awr_trend.sql` (the `snp` inline view and the comment above it)
- `awr_fleet_extract.sql` (the lockstep copy)
- `CLAUDE.md` (the two sentences quoted above)

**Out of scope** (do NOT touch):
- `sql/lib/windows_cte.sql` — the window rule is correct and many sections
  depend on it byte-for-byte.
- The `UPPER('~target_end') IN ('AUTO','NOW','')` line. (Its `''` member can
  never match in Oracle; that is a separate, known, low-priority item.)
- `sql/00_params.sql` / `sql/fleet/07_close.sql` — they already print a
  "Requested end … snapped to last snapshot …" note whenever the two values
  differ; no change needed.
- README / CHEATSHEET wording — see step 5.

## Git workflow

- Branch: `advisor/007-target-end-snap-rule` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(report): snap target_end when no snapshot satisfies the window end rule`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Edit the driver block

In `awr_trend.sql`, inside the `snp` inline view, make two changes.

(a) Add a second scalar subquery next to `last_snap_ts` — note the comma
added after the `last_snap_ts` alias:

```sql
        SELECT
            req.req_ts                                             AS req_ts,
            (SELECT MAX(CAST(end_interval_time AS DATE))
             FROM   dba_hist_snapshot
             WHERE  CAST(end_interval_time AS DATE) <= req.req_ts + 5/1440)
                                                                    AS last_snap_ts,
            (SELECT COUNT(*)
             FROM   dba_hist_snapshot
             WHERE  CAST(end_interval_time AS DATE) >= req.req_ts - 5/1440
               AND  CAST(end_interval_time AS DATE) <= req.req_ts + 15/1440)
                                                                    AS edge_snaps
        FROM (
```

(b) Extend the middle `WHEN` of the `CASE`:

```sql
        CASE
            WHEN rs.last_snap_ts IS NULL THEN rs.req_ts
            WHEN rs.req_ts - rs.last_snap_ts <= 15/1440
                 AND rs.edge_snaps > 0 THEN rs.req_ts
            ELSE TRUNC(rs.last_snap_ts, 'MI')
        END                                                        AS eff_ts
```

(c) In the comment above the block, replace the middle bullet (quoted in
"Current state") with:

```sql
    --   - the last snapshot is within 15 min before req_ts AND a snapshot
    --     exists in [req_ts - 5 min, req_ts + 15 min] (exactly what
    --     windows_cte accepts as the end snapshot) -> keep req_ts verbatim
    --     (byte-identical for every request that already resolved valid
    --     windows)
    --   - the last snapshot is 6-15 min before req_ts and none follows
    --     within 15 min (hourly snaps at :45-:54, or a request made just
    --     before the next snapshot is taken) -> snap back, else windows_cte
    --     would reject every window
```

Keep the following "otherwise -> snap back to last_snap_ts" bullet as is.
No `;` and no tilde anywhere in the comment.

**Verify**:
- `grep -c "edge_snaps" awr_trend.sql` → `2` or more.
- `awk 'NR>=300 && NR<=420 && /--.*;[[:space:]]*$/' awr_trend.sql` → no output
  (no comment line in this statement ends with a semicolon).
- `./lint.sh` → clean.

### Step 2: Apply the identical edit to the fleet extract

In `awr_fleet_extract.sql`, make changes (a) and (b) from step 1 in the
lockstep block (`:223-246`). In its short comment above the block, append
one sentence: "The request is kept only when a snapshot also exists in
[req_ts - 5 min, req_ts + 15 min], the window rule's end test" (wrapped as
`--` comment lines, no `;`, no tilde).

**Verify**:
- `grep -c "edge_snaps" awr_fleet_extract.sql` → `2` or more.
- `awk 'NR>=180 && NR<=280 && /--.*;[[:space:]]*$/' awr_fleet_extract.sql` → no output.
- `./lint.sh` → clean.

### Step 3: Prove the two blocks are still textually parallel

Run:

```bash
blk() { awk '/rs\.req_ts +AS req_ts,/{on=1} on{print} on && /\) req$/{exit}' "$1" | sed 's/^[[:space:]]*//'; }
diff <(blk awr_trend.sql) <(blk awr_fleet_extract.sql) && echo PARALLEL
```

**Verify**: prints `PARALLEL` and nothing else. (Run the same command on
`git stash`-ed sources first if you want to see that it also printed
`PARALLEL` before your edit.)

### Step 4: Update `CLAUDE.md`

In the "### `target_end` snap-to-snapshot-grid" section:

1. Replace "if a snapshot exists within 15 min of the requested instant
   (mirroring `windows_cte`'s edge guard), the request is kept **verbatim**
   (byte-identical to pre-feature behavior)" with:
   "if the last snapshot is at most 15 min before the requested instant
   **and** a snapshot exists in `[request − 5 min, request + 15 min]` (the
   exact range `windows_cte` accepts for the end snapshot), the request is
   kept **verbatim** (byte-identical for every request that already
   resolved valid windows)".
2. Replace the sentence "Dense snap grids (≤15-min spacing) can never
   trigger the snap, by design." with:
   "A dense snap grid (≤15-min spacing) triggers the snap only when the
   request falls 6–15 min after the last snapshot and the next one has not
   been taken yet (an `AUTO` run just after the hour); the window then ends
   on that last real snapshot instead of leaving the Current window empty."

Change nothing else in the file.

**Verify**: `git diff --stat -- CLAUDE.md` → 1 file changed;
`grep -c "can never trigger the snap" CLAUDE.md` → `0`.

### Step 5: Find other statements of the old rule (report, do not edit)

Run: `grep -rn "within 15 min" --include='*.md' --include='*.html' . | grep -v '^./plans/' | grep -v '^./CLAUDE.md'`

**Verify**: list the hits (file:line) in your final report so the owner can
decide whether user-facing docs need the same wording change. Do not edit
them in this plan.

## Test plan

- No SQL unit tests exist and no database is available. Machine checks:
  lint, the `edge_snaps` greps, the comment-semicolon check, the lockstep
  diff.
- If `tools/check.sh` exists (plan 003), run it → `check.sh: all checks passed`.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] `grep -c "edge_snaps" awr_trend.sql awr_fleet_extract.sql` → each ≥ 2
- [ ] Step 3 prints `PARALLEL`
- [ ] `grep -c "can never trigger the snap" CLAUDE.md` → `0`
- [ ] `git status --short` shows only `awr_trend.sql`, `awr_fleet_extract.sql`, `CLAUDE.md`
- [ ] `plans/README.md` status row updated with "needs owner DB run"

## STOP conditions

- The two SQL blocks are not textually identical before your edit (step 3
  on the unmodified tree does not print `PARALLEL`) — the lockstep already
  drifted; report instead of choosing one.
- The live `CASE` no longer has exactly the three branches shown.
- `./lint.sh` reports a finding in either edited file.
- You believe the window rule in `windows_cte.sql` must change to make this
  work — it must not; report your reasoning.

## Maintenance notes

- **Owner verification on the test database (required before release; not
  possible for the executor).** All runs must end rc 0 with 20/20
  `AWR-SECTION` pairs:
  1. Byte-identity: a pinned window that was valid before (the usual
     `target_end='2026-09-18 12:00'`, 1 h, 4 back, hourly) must produce the
     same normalised md5 before and after (exclude sections 06/11, which
     have rank-tie noise).
  2. The fix: pick a real snapshot time `T` from `dba_hist_snapshot` in a
     stretch where snapshots are ≥ 30 min apart, request `T + 10 min`.
     Before: every window skipped. After: the hero shows the "Requested end
     … snapped to last snapshot …" note and the Current window is valid.
  3. Unchanged snap-back: request `T + 40 min` in the same stretch → snapped
     to `T` both before and after.
  4. One fleet run (`run_awr_fleet.sh`) for the same request as 2 → the
     drill panel shows the same snapped instant.
- The rule now exists in three places that must agree: `awr_trend.sql`,
  `awr_fleet_extract.sql` and the end-snapshot test in
  `sql/lib/windows_cte.sql`. Changing the 5-minute or 15-minute tolerances
  in one requires the others.
- Follow-up not in this plan: an empty `target_end` on the pure-SQL\*Plus
  path (the `''` member of the `IN` list never matches, so the value falls
  through to `TO_DATE('')`).
