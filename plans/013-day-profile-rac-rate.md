# Plan 013: The Day profile reports the cluster-wide rate on RAC instead of the per-instance average

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- sql/lib/day_profile_cte.sql sql/16_day_profile.sql sql/fleet/06_day_profile.sql`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED (shared include used by two reports; RAC can not be tested in the owner's lab, so correctness on RAC rests on review)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The "Day profile" (single-DB section 16 and the fleet's day-profile band)
shows nine workload rates per hour of the day — DB time as average active
sessions, executions per second, redo bytes per second, and so on. Its
header says the value is "summed across instances". The SQL divides the
summed deltas of all instances by the summed **seconds of all instances**:
on a 2-node RAC an hour contributes 7200 seconds, so every rate is half the
real cluster rate (one third on 3 nodes). Besides showing wrong numbers,
the scoring floors (for example "ignore DB time below N active sessions")
are then applied to values that are too small, so real findings on RAC are
suppressed as immaterial. On a single-instance database the result is
unchanged, which is why the lab never showed it.

## Current state

File `sql/lib/day_profile_cte.sql` — a shared chain of SQL common table
expressions (CTEs), `@@`-included right after `WITH` by
`sql/16_day_profile.sql` and `sql/fleet/06_day_profile.sql`.

The relevant part of the header comment (`:27-33`):

```sql
--   dp_cells   one cell per (stat, day_off 0..N, hour_slot 0..23): the pair
--              lands in the cell that contains its midpoint; the cell value
--              is the per-second rate SUM(delta)/SUM(span), summed across
--              instances (additive counters, like section 02).
--              COVERAGE GUARD: a cell whose pairs cover < 30 min of the hour
--              is NULL (2-h snap intervals, snapshot gaps, restart-dropped
--              pairs) -- never a misleading 0.
```

How the inputs are built (context, not edited): `dp_snaps` reads
`dba_hist_snapshot` with a `LAG` per `(dbid, instance_number)`; `dp_pairs`
is one row per consecutive snapshot pair **per instance** with
`span_sec = (end_dt - prev_end_dt) * 86400` (always > 0) and its midpoint;
`dp_deltas` is the counter delta per `(dbid, instance, stat, snapshot)`.

The two CTEs to change (`:121-144`):

```sql
dp_cells_raw AS (
    SELECT d.stat_name,
           FLOOR(p.t_end - pr.mid_dt)                               AS day_off,
           FLOOR((p.t_end - pr.mid_dt) * 24)
             - 24 * FLOOR(p.t_end - pr.mid_dt)                      AS hour_slot,
           GREATEST(d.delta, 0)                                     AS delta,
           pr.span_sec
    FROM   dp_deltas d
    JOIN   dp_pairs pr
      ON   pr.dbid = d.dbid
     AND   pr.snap_id = d.snap_id
     AND   pr.instance_number = d.instance_number
     AND   pr.prev_snap_id = d.prev_snap_id
    CROSS JOIN dp_params p
    WHERE  pr.mid_dt <  p.t_end
      AND  pr.mid_dt >= p.t_end - (p.n_days + 1)
),
dp_cells AS (
    SELECT stat_name, day_off, hour_slot,
           CASE WHEN SUM(span_sec) >= 1800
                THEN SUM(delta) / SUM(span_sec) END                 AS rate
    FROM   dp_cells_raw
    GROUP BY stat_name, day_off, hour_slot
),
```

`dp_cells` is consumed only by the next CTE in the same file (`dp_grid` /
`dp_pivot` join it as `dp_cells c`, `:164`); nothing else names
`dp_cells_raw` (`grep -n "dp_cells" sql/` → this file only).

The rule the rest of the report uses for the same situation (documented in
`CLAUDE.md`, "Window validity (per-instance in RAC)"): per-second rates
"sum the cross-instance delta and divide by `MAX(dur_sec)`" — i.e. the
deltas add up across instances, the time does not.

### The fix, and why single-instance output stays byte-identical

1. First aggregate **per instance** within the cell: `delta_i = SUM(delta)`,
   `span_i = SUM(span_sec)` (an hour usually holds several snapshot pairs).
2. Then across instances: `rate = SUM(delta_i) / MAX(span_i)`, guarded by
   `MAX(span_i) >= 1800`.

With one instance there is one `(delta_1, span_1)` row per cell, so the
result is `SUM(delta) / SUM(span_sec)` exactly as today — same operands,
same operation. On N instances with equal coverage the divisor is one
hour instead of N hours. Grouping is by `instance_number` only (not
`dbid`), so an hour that straddles a DBID change still adds its two
time-contiguous halves for the same instance.

The coverage guard changes meaning on RAC only: today two instances with
15 minutes each (1800 s in total) pass; after the fix a cell needs one
instance with at least 30 minutes of coverage, which is what the comment
always described.

### Rules of this codebase that apply to this edit

- **Never type a tilde** in a `sql/` file, even in a comment (`SET DEFINE
  '~'`). The file already contains substitution tokens such as
  `~profile_days` — leave them untouched; add none.
- Pure ASCII; do not end a `--` comment line with `;`.
- This file is a fragment inside a `WITH` clause: every CTE ends with `),`
  and there must be no statement terminator.
- It is a shared include (`sql/lib/`); the fleet band uses it too. Editing a
  shared include to fix a bug that affects both is allowed; do **not** edit
  `sql/16_day_profile.sql` or `sql/fleet/06_day_profile.sql`.
- The stat list in `dp_targets` is fixed inline on purpose — do not move it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Demo unchanged | `python3 demo/gen_demo_report.py && git status --short docs/examples/demo_busy_db.html` | no output from `git status` |

No database is available to you. Real-database verification is described
under "Maintenance notes" for the repository owner.

## Scope

**In scope** (the only file you should modify):
- `sql/lib/day_profile_cte.sql`

**Out of scope** (do NOT touch):
- `sql/16_day_profile.sql`, `sql/fleet/06_day_profile.sql` (consumers).
- The `dp_scored` CASE at the end of the include (documented as unused by
  consumers but kept as the CTE's contract).
- The demo twin `demo/awrdemo/sections/s16_day_profile.py` — it computes
  from a single-instance synthetic model and does not port this CTE.

## Git workflow

- Branch: `advisor/013-day-profile-rac-rate` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(report): day profile rate is cluster-wide on RAC (per-instance spans no longer summed)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Carry the instance through `dp_cells_raw`

In `sql/lib/day_profile_cte.sql`, add `d.instance_number,` as the second
select-list item of `dp_cells_raw`:

```sql
dp_cells_raw AS (
    SELECT d.stat_name,
           d.instance_number,
           FLOOR(p.t_end - pr.mid_dt)                               AS day_off,
```

Nothing else in `dp_cells_raw` changes.

### Step 2: Aggregate per instance, then across instances

Replace the `dp_cells` CTE with these two CTEs:

```sql
-- Per instance first: an hour usually holds several snapshot pairs, and
-- each instance covers its own seconds.
dp_cells_inst AS (
    SELECT stat_name, day_off, hour_slot, instance_number,
           SUM(delta)                                               AS delta,
           SUM(span_sec)                                            AS span_sec
    FROM   dp_cells_raw
    GROUP BY stat_name, day_off, hour_slot, instance_number
),
-- Across instances the deltas add up, the time does not: divide by the
-- longest per-instance coverage (the rule sections 00/02/07/08 use with
-- MAX(dur_sec)).  Summing the seconds of N instances made every RAC rate
-- 1/N of the cluster rate.  Single instance: identical to the old
-- SUM(delta) / SUM(span_sec).
dp_cells AS (
    SELECT stat_name, day_off, hour_slot,
           CASE WHEN MAX(span_sec) >= 1800
                THEN SUM(delta) / MAX(span_sec) END                 AS rate
    FROM   dp_cells_inst
    GROUP BY stat_name, day_off, hour_slot
),
```

**Verify**:
- `grep -c "dp_cells_inst" sql/lib/day_profile_cte.sql` → `3` (definition,
  one `FROM`, one mention in the header after step 3) or `2` before step 3.
- `grep -c "SUM(delta) / SUM(span_sec)" sql/lib/day_profile_cte.sql` → `1`
  (only inside the new comment) — the expression itself is gone.
- `./lint.sh` → clean.

### Step 3: Update the header comment

In the header's method list, replace the `dp_cells` paragraph (quoted in
"Current state") with:

```sql
--   dp_cells   one cell per (stat, day_off 0..N, hour_slot 0..23): the pair
--              lands in the cell that contains its midpoint.  dp_cells_inst
--              sums each instance's deltas and covered seconds; the cell
--              value is the cross-instance delta divided by the longest
--              per-instance coverage (additive counters summed across
--              instances, like section 02 -- the seconds are not summed).
--              COVERAGE GUARD: a cell in which no instance covers at least
--              30 min of the hour is NULL (2-h snap intervals, snapshot
--              gaps, restart-dropped pairs) -- never a misleading 0.
```

**Verify**: `./lint.sh` → clean;
`awk '/--.*;[[:space:]]*$/' sql/lib/day_profile_cte.sql` → no output.

### Step 4: Structural sanity without a database

Run:

```bash
awk '/^dp_[a-z_]+ AS \(/{print $1}' sql/lib/day_profile_cte.sql
```

**Verify**: the list is, in order: `dp_params`, `dp_targets`, `dp_snaps`,
`dp_pairs`, `dp_src`, `dp_deltas`, `dp_cells_raw`, `dp_cells_inst`,
`dp_cells`, `dp_grid`, then the CTEs that were already after `dp_grid`
(compare with `git show e755b97:sql/lib/day_profile_cte.sql | awk '/^dp_[a-z_]+ AS \(/{print $1}'`
— the only difference must be the added `dp_cells_inst`).

Then: `python3 demo/gen_demo_report.py` and
`git status --short docs/examples/demo_busy_db.html` → no output.

## Test plan

- No SQL tests exist and no database is available; checks are lint, the
  CTE-order comparison, and unchanged demo output.
- If `tools/check.sh` exists (plan 003), run it → `check.sh: all checks passed`.

## Done criteria

- [ ] `./lint.sh` exits 0
- [ ] CTE list differs from the planned-at commit only by `dp_cells_inst`
- [ ] `git status --short` shows only `sql/lib/day_profile_cte.sql`
- [ ] `plans/README.md` status row updated with "needs owner DB run"

## STOP conditions

- `dp_cells` or `dp_cells_raw` is referenced anywhere outside this file
  (`grep -rn "dp_cells" sql/ awr_trend.sql awr_fleet_extract.sql` shows
  another file).
- The live CTEs differ from the excerpts (for example `dp_cells_raw`
  already selects `instance_number`).
- `./lint.sh` reports a finding in the edited file.

## Maintenance notes

- **Owner verification on the test database (required before release; not
  possible for the executor).** The lab is single-instance, so the check is
  byte-identity:
  1. Single-DB: run the usual pinned window with `profile_days=7` before and
     after; section 16 (between its two `AWR-SECTION` markers) must be
     byte-identical.
  2. Fleet: one run with `FLEET_PROFILE_DAYS=7`; the
     `window.FLEET_PROFILE[...]` payload must be byte-identical before and
     after.
  3. Both runs rc 0, no ORA-/SP2- in the logs.
- **RAC remains unexercised.** The first RAC user should compare one hour of
  the Day profile's "DB time (avg active sessions)" row against the Load
  profile's DB time for a window covering the same hour; they should agree.
- Semantics on an hour where one instance has little coverage (it restarted
  mid-hour): that instance's delta is still added, the divisor is the
  longest coverage. This mirrors section 02 and slightly under-reports the
  restarted instance — accepted for consistency.
- The fleet band and section 16 share this include by design; never fork it.
