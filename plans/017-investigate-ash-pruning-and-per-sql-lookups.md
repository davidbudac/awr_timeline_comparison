# Plan 017 (investigation): Measure whether the ASH scans and the per-SQL history lookups are worth optimising, and write down the answer

> **Executor instructions**: This is an **investigation** plan. Its
> deliverable is a results file under `plans/`, **not** a code change. Follow
> it step by step, run only read-only commands against the test database,
> and stop at the "STOP conditions". When done, update the status row for
> this plan in `plans/README.md` — unless a reviewer dispatched you and told
> you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- sql/09_ash_timeline.sql sql/11_top_sql_ash_breakdown.sql sql/06_top_sql.sql sql/fleet/02_ash.sql`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code; if the quoted predicates
> are gone, the question may already be answered — report that instead.

## Status

- **Priority**: P3
- **Effort**: S–M (measurement and write-up; no implementation)
- **Risk**: LOW for the investigation itself (read-only); MED for any later fix
- **Depends on**: none. **Requires read access to an Oracle 19c database with AWR history** — the repository owner's test database. An executor without database access cannot do this plan (see STOP conditions).
- **Category**: perf
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

Two query shapes in the report look expensive on a database with a long
AWR history, but the audit could only read the SQL, not run it:

1. **ASH scans filter on `sample_time` only.** The AWR table behind
   `DBA_HIST_ACTIVE_SESS_HISTORY` is partitioned by `(dbid, snap_id)`. A
   predicate on `sample_time` alone gives the optimizer nothing to prune
   partitions with, so each scan may read the whole retained ASH history
   and then discard most of it. Three sections do this (09, 11 twice, and
   the fleet's ASH band).
2. **Per-statement lookups over the whole AWR retention.** For every
   statement in the Top SQL pool, section 06 runs three separate queries
   against `DBA_HIST_SQLSTAT` filtered by `sql_id` with **no snapshot
   bound** (and section 11 one more). With five ranking dimensions the pool
   can hold dozens of statements, so this is "N statements × 3 scans of the
   statement history".

On the small, idle lab database these sections are fast, so the cost is
invisible there; on a production database with 30–400 days of retention
they may dominate the run time (the project's own notes already call the
ASH section "often the slowest"). A wrong guess in either direction is
costly: optimising blind risks changing numbers in a report whose value is
its correctness, and not optimising may leave multi-minute runs. This plan
produces evidence and a recommendation; the fix, if any, is a separate plan.

## Current state

### ASH scans (sample_time only)

`sql/09_ash_timeline.sql:391-398`:

```sql
                SELECT (CAST(ash.sample_time AS DATE) - v_range_start) * 24 AS h,
                       ash.session_state, ash.wait_class, ash.event, ash.session_type
                FROM   dba_hist_active_sess_history ash
                WHERE  ash.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR ash.instance_number = ~inst_num)
                  AND  ash.sample_time >= CAST(v_range_start AS TIMESTAMP)
                  AND  ash.sample_time <  CAST(v_range_end   AS TIMESTAMP)
                  AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
```

`sql/11_top_sql_ash_breakdown.sql:268-274` (ranking the pool) and
`:287-293` (the per-SQL buckets) use the same four predicates plus a join
on `sql_id`. `sql/fleet/02_ash.sql:104-108` is the fleet's copy.

(`~dbid_list`, `~inst_num` are SQL\*Plus substitution variables resolved by
the driver; `v_range_start` / `v_range_end` are PL/SQL DATE variables
holding the start of the oldest compared window and the report's end.)

### Per-statement lookups without a snapshot bound

`sql/06_top_sql.sql`, inside `FOR oi IN 1 .. v_order.COUNT LOOP` (`:1035`):

- `:1040-1074` — first/last seen, plan count, executions, last
  module/action/optimizer mode (one aggregate over all snapshots):

```sql
                FROM   dba_hist_sqlstat st
                JOIN   dba_hist_snapshot s
                  ON   s.dbid = st.dbid
                 AND   s.snap_id = st.snap_id
                 AND   s.instance_number = st.instance_number
                WHERE  st.dbid   IN (~dbid_list)
                  AND  st.sql_id = v_sql_id
                  AND  (~inst_num = 0 OR st.instance_number = ~inst_num);
```

- `:1248-1258` — the plan-history table (`GROUP BY st.plan_hash_value`),
  same `FROM` / `WHERE` plus `st.plan_hash_value > 0`.
- `:1296-1306` — the plan timeline points
  (`GROUP BY s.end_interval_time, st.plan_hash_value`), same shape.

`sql/11_top_sql_ash_breakdown.sql:410-415` — latest parsing schema per
statement, same unbounded shape.

These are **by design unbounded in time**: the per-SQL detail shows a
statement's whole recorded history ("first seen", every plan ever used).
Any optimisation must keep that output identical.

### How to measure

- The wrapper prints one timestamped marker per section to stdout when
  `debug` is `Y` (the default): lines like
  `[awr_trend 08:38:42.369] section 09 ash_timeline (ASH stacked-area; often the slowest)`.
  The time a section took is the difference to the next marker. The markers
  for the sections of interest are named `section 09 ash_timeline`,
  `section 06 top_sql`, `section 11 top_sql_ash_breakdown`.
- Run form (positional arguments: connect, target_end, win_hours,
  weeks_back, top_n, inst_num, step, step_unit, template, debug):
  `./run_awr_trend.sh '<connect>' AUTO 1 4 10 0 1 w comprehensive Y`
  The report goes to `reports/` (git-ignored).
- The report is **read-only by design**: `SELECT` only, no DDL/DML. Your
  investigation queries must respect the same rule.
- The repository owner's test database is reached as described in the
  project's contributor guide (`CLAUDE.md`, "Verification & testing": an
  `ssh` to the lab host, `connect / as sysdba`, project synced with `rsync`
  **without `--delete`**). Follow that guide and any database-testing skill
  available in your environment; never run against any other database.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| AWR retention and volume | SQL in step 1 | numbers for the results file |
| Timed report run | `./run_awr_trend.sh '<connect>' <args…> Y 2>&1 \| tee run.log` | rc 0; marker lines in `run.log` |
| Section durations | `grep -n "^\[awr_trend" run.log` | one line per section |
| Plans of the heavy statements | SQL in step 3 | plan text for the results file |

## Scope

**In scope** (the only files you may create or modify):
- `plans/017-results.md` (create)
- `plans/README.md` (status row)

**Out of scope** (do NOT do):
- Any change to any file outside `plans/`. No SQL edits, not even
  "obviously safe" ones — a follow-up plan will carry the fix with its own
  byte-identity verification.
- `EXPLAIN PLAN`, `CREATE`, `ALTER SYSTEM/SESSION` that changes optimizer
  behaviour, gathering statistics, taking AWR snapshots, purging AWR,
  changing AWR retention, opening the standby — nothing that writes to or
  reconfigures the database. Reading `V$SQL`, `V$SQL_PLAN` and
  `DBMS_XPLAN.DISPLAY_CURSOR` is fine.
- Running against anything but the owner's designated test database.

## Git workflow

- Branch: `advisor/017-investigate-ash-and-sqlstat` from `main`.
- One commit: `docs(plans): results of the ASH pruning / per-SQL lookup investigation`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Describe the test database's AWR volume

Run (read-only) and record the output:

```sql
SELECT dbid, MIN(begin_interval_time) AS oldest, MAX(end_interval_time) AS newest,
       COUNT(*) AS snaps, COUNT(DISTINCT instance_number) AS instances
FROM   dba_hist_snapshot GROUP BY dbid;

SELECT COUNT(*) AS ash_rows FROM dba_hist_active_sess_history;
SELECT COUNT(*) AS sqlstat_rows, COUNT(DISTINCT sql_id) AS sql_ids FROM dba_hist_sqlstat;

SELECT retention, snap_interval FROM dba_hist_wr_control;
```

**Verify**: you have the retention (days), snapshot count, ASH row count and
SQLSTAT row count. If ASH holds fewer than about 100 000 rows or the
history is shorter than about 14 days, note prominently in the results
that this database is **too small to show the effect** and that timings
below are a floor, not an estimate for production.

### Step 2: Time the three sections on three report shapes

Run each shape **twice** (the second run shows the cached case) and extract
the durations of sections 09, 06 and 11 from the markers:

| Shape | Arguments after the connect string |
|---|---|
| A — default weekly | `AUTO 1 4 10 0 1 w comprehensive Y` |
| B — long span | `AUTO 1 52 10 0 1 w comprehensive Y` |
| C — many windows | `AUTO 1 168 10 0 1 h comprehensive Y` |

For each run record: total wall time, and seconds spent in `section 09`,
`section 06`, `section 11` (difference between that section's marker and
the next marker).

**Verify**: every run ended with exit code 0 and its log contains the line
`all sections rendered; writing HTML epilogue`. A run that fails → record
the error and continue with the others; do not "fix" the report.

### Step 3: Capture what the database actually did

Right after a shape-B run, in the same database, find the report's heavy
statements and their plans (read-only):

```sql
SELECT sql_id, child_number, executions, ROUND(elapsed_time/1e6, 2) AS ela_s,
       buffer_gets, disk_reads, SUBSTR(sql_text, 1, 90) AS txt
FROM   v$sql
WHERE  (UPPER(sql_text) LIKE '%DBA_HIST_ACTIVE_SESS_HISTORY%'
        OR UPPER(sql_text) LIKE '%DBA_HIST_SQLSTAT%')
  AND  sql_text NOT LIKE '%v$sql%'
  AND  last_active_time > SYSDATE - 15/1440
ORDER  BY elapsed_time DESC FETCH FIRST 15 ROWS ONLY;
```

For the top ASH statement and the top per-statement SQLSTAT lookup (the
ones with `executions` in the dozens — one execution per pool statement),
get the plan:

```sql
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('<sql_id>', <child_number>, 'BASIC +PARTITION +PREDICATE'));
```

**Verify**: for the ASH statement, note whether the `Pstart` / `Pstop`
columns show a bounded range or `1` … `1048575` / `KEY` / all partitions
(`PARTITION RANGE ALL` = no pruning). For the SQLSTAT lookup, note the
access path (index range scan on which index, or full partition scans) and
the number of executions × average elapsed.

### Step 4: Answer the two questions

Using steps 1–3, write the answers:

1. **ASH**: does the scan prune partitions today? How long does section 09
   (and 11) take at shapes A/B/C, and what fraction of the run is that?
2. **Per-SQL lookups**: how many executions of the three section-06
   lookups (and the section-11 one) per run, what does one cost, and what
   fraction of section 06's time is that?

Then give a recommendation per question, one of:

- **Not worth changing** — with the measurement that shows it.
- **Worth a fix plan** — with the expected saving, and which of the
  candidate approaches below fits the evidence.
- **Cannot tell on this database** — with what a production-size check
  would need (the owner can then run steps 1–3 on a larger system).

Candidate approaches to evaluate **on paper only** (do not implement):

- *ASH*: add a redundant, superset filter on `snap_id` so partitions can be
  pruned, keeping the `sample_time` predicates as the exact filter — for
  example restricting `(dbid, snap_id)` to the snapshots whose interval
  overlaps `[v_range_start − 1 hour, v_range_end + 1 hour]` (the margin
  covers samples flushed under a neighbouring snapshot). Because it is only
  a superset filter, the result set must be identical; the follow-up plan
  would prove that with the project's byte-identity test.
- *Per-SQL lookups*: replace the three per-statement queries in section 06
  with one query over all pool `sql_id`s (`BULK COLLECT` into PL/SQL
  collections keyed by `sql_id`, the pattern section 07 already uses), so
  the statement history is scanned once instead of 3 × N times; same for
  the section-11 lookup. Output must stay identical, including the
  "whole retention" semantics.

### Step 5: Write `plans/017-results.md`

Create the file with these sections:

```markdown
# Results of plan 017 — ASH pruning and per-SQL lookups

- Investigated at commit: <git rev-parse --short HEAD>
- Date: <YYYY-MM-DD>
- Database: version, single-instance or RAC, AWR retention, snapshot count,
  ASH rows, SQLSTAT rows (no host names, no connect strings)

## Timings
(table: shape × run 1/run 2 × total, section 09, section 06, section 11)

## What the database did
(for each of the two statements: sql_id, executions, elapsed, the plan's
relevant lines, pruning yes/no)

## Answers
1. ASH: …
2. Per-SQL lookups: …

## Recommendation
(per question: not worth changing / worth a fix plan / cannot tell here,
with the reasoning in two or three sentences)

## Limits of this measurement
(what this database cannot show)
```

Do **not** include connect strings, passwords, host names, SQL text of
application statements, or anything from `fleet.conf` in the file.

**Verify**: `git status --short` → only `plans/017-results.md` and
`plans/README.md`; `grep -n -i "password\|@.*:15[0-9][0-9]" plans/017-results.md` → no output.

## Test plan

Not applicable (no code change). The deliverable is checked by its
completeness: all five sections of the results file are filled, every
number has its source command, and both questions have an explicit
recommendation.

## Done criteria

- [ ] `plans/017-results.md` exists with all sections filled
- [ ] Six timed runs (three shapes × two) are recorded, or the reason a run is missing
- [ ] Both questions have one of the three recommendations
- [ ] No file outside `plans/` is modified (`git status --short`)
- [ ] `plans/README.md` status row updated (DONE with the one-line verdict, e.g. "ASH: worth a fix; lookups: not worth it")

## STOP conditions

- You have no access to the owner's test database, or the connection
  fails — set the status to `BLOCKED (needs database access)` and stop. Do
  not substitute reasoning for measurement.
- Any step would require a statement that writes to or reconfigures the
  database.
- A report run fails with an ORA- error in sections 06, 09 or 11 — record
  it (it may be a real defect) and stop measuring that shape.
- The database is the mounted physical standby (the report cannot run
  there) — stop; never open it.

## Maintenance notes

- If the recommendation is "worth a fix plan", the follow-up plan must
  include the project's byte-identity test (a report before and after the
  change at the same `target_end`, normalised md5 equal, sections 06/11
  compared with their known rank-tie caveat) on single-DBID **and** must
  state that RAC / multi-DBID remain unexercised in the lab.
- The fleet's ASH scan (`sql/fleet/02_ash.sql`) is a fleet-owned copy;
  a single-DB fix does not reach it and must not be "shared" into it.
- Whatever the outcome, record it in `plans/README.md` so the question is
  not re-audited.
