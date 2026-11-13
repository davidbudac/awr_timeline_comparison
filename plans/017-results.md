# Results of plan 017 — ASH pruning and per-SQL lookups

- Investigated at commit: `8d5103d`
- Date: 2026-11-13
- Database: Oracle 19.27 EE, single instance, CDB root, one DBID, open
  read-write (primary). AWR retention 35 days, snapshot interval 15 min,
  1,346 snapshots (2026-10-08 18:15 to 2026-11-13 08:15).
  `DBA_HIST_ACTIVE_SESS_HISTORY`: **61,018 rows** (segment 27 MB).
  `DBA_HIST_SQLSTAT`: 108,680 rows, 7,017 distinct `sql_id` (segment 42 MB).
  `WRH$_ACTIVE_SESSION_HISTORY` and `WRH$_SQLSTAT` are RANGE partitioned on
  `(DBID, SNAP_ID)`: 7 partitions each (6 for this DBID, 336 snapshots
  = 3.5 days per partition, plus the empty `MXDB_MXSN` one).
  Indexes: `WRH$_ACTIVE_SESSION_HISTORY_PK (DBID, SNAP_ID, INSTANCE_NUMBER,
  SAMPLE_ID, SESSION_ID, CON_DBID)`, `WRH$_SQLSTAT_INDEX (SQL_ID, DBID,
  CON_DBID)` (local), `WRH$_SQLSTAT_PK`.
  Source: the step-1 queries plus `DBA_PART_KEY_COLUMNS`,
  `DBA_TAB_PARTITIONS`, `DBA_INDEXES` / `DBA_IND_COLUMNS`, `DBA_SEGMENTS`.

> **This database is too small to show the effect.** ASH holds 61 k rows
> (the plan's threshold is about 100 k) and the whole ASH segment is
> 27 MB, about 3,200 blocks. The timings below are a **floor**, not an
> estimate for production. The history (36 days) is long enough.

## Timings

Wrapper `./run_awr_trend.sh '<connect>' <args> ` with `debug=Y`; section
time = next marker minus the section's marker (`grep "^\[awr_trend"` on
each log); total = wall time of the wrapper. All in seconds. Section 18
(SQL Monitor) is listed because it is what dominates every run.

| Shape (args) | Run | rc | Total | s09 | s06 | s11 | s18 |
|---|---|---|---|---|---|---|---|
| A `AUTO 1 4 10 0 1 w comprehensive Y` | 1 | 0 | 183.7 | 0.33 | 1.23 | 0.42 | 163.3 |
| A | 2 | 0 | 180.9 | 0.33 | 1.23 | 0.41 | 160.3 |
| B `AUTO 1 52 10 0 1 w comprehensive Y` | 1 | 0 | 221.0 | 1.23 | 1.55 | 4.21 | 191.2 |
| B | 2 | 0 | 216.8 | 1.08 | 1.50 | 4.07 | 187.7 |
| B (extra run 3, plan capture during s18) | 3 | 0 | 218.0 | 1.09 | 1.51 | 4.23 | 188.4 |
| C `AUTO 1 168 10 0 1 h comprehensive Y` | 1 | **67** | 67.5 | 0.55 | ~30.3 (failed) | not reached | not reached |
| C | 2 | not run | | | | | |

- Every rc-0 run logged `all sections rendered; writing HTML epilogue`.
- Windows: A = 5 windows, 3 valid (2 skipped over restarts / snapshot
  gaps); B = 53 windows, the same 3 valid (the other 50 lie outside the
  35-day retention or in gaps); C = 169 windows, 117 valid. Counted from
  `window.AWR_WIN` (`"v":"Y"` / `"v":"N"`) in each report.
- **Shape C run 1 failed in section 06** with `ORA-19011: Character string
  buffer too small` at `SYS.DBMS_XMLGEN` (exit code 67 = 19011 mod 256);
  see "Defect found" below. Per the plan's STOP condition, shape C was not
  measured further (no run 2). Section 06's ~30.3 s is from its marker to
  the end of the wrapper (the failure), not a complete section.
- The second run of each shape was not faster: nothing here is I/O-bound
  enough for the cache to matter.

## What the database did

Statement figures from `V$SQL` (`SQL_FULLTEXT` searched, because the
section 09 / 11 statements name `DBA_HIST_ACTIVE_SESS_HISTORY` past the
first 1,000 characters that `SQL_TEXT` holds), per-run counts from a
`V$SQL` snapshot taken before and after run B2 and C1. Plans from
`DBMS_XPLAN.DISPLAY_CURSOR(..., 'BASIC +PARTITION +PREDICATE +ROWS')`.
The ASH plans had to be captured **while section 18 ran** (run B3): after
a run, section 18's XML parsing had already evicted them from
`V$SQL_PLAN` (the cursors stayed in `V$SQL` without a plan).
The DBID literal is written as `<dbid>` below.

### ASH, section 09 (`SELECT BUCKET_KEY, WAIT_CLASS, EVENT_NAME, J_LO, J_HI, FG, MK, COUNT(*) ...`)

- Shape B: `62kcfms84caq6`, 1 execution per run, 0.096–0.105 s, 3,254–3,424
  buffer gets, 3,215 physical reads (the whole segment), 4,546 rows.
- Shape C: `4uqu0j0bh9ft6`, 1 execution, 0.072 s, 3,632 gets, 3,223 reads.
- Shape A: the cursor had aged out before it could be read; its scan is
  the same full scan (the 4-week span covers 28 of the 36 retained days).

```
| 1 |  HASH GROUP BY                |                             | 46315 |       |       |
| 4 |     HASH JOIN RIGHT OUTER    |                             | 46315 |       |       |
| 5 |      TABLE ACCESS FULL       | WRH$_EVENT_NAME             |  2062 |       |       |
| 6 |      PARTITION RANGE ITERATOR|                             | 46315 |     1 |     6 |
| 7 |       TABLE ACCESS FULL      | WRH$_ACTIVE_SESSION_HISTORY | 46315 |     1 |     6 |
   7 - filter(("ASH"."DBID"=<dbid> AND "ASH"."SAMPLE_TIME">=CAST(:B2 AS TIMESTAMP) ...
```

**Pruning: no.** `Pstart 1 / Pstop 6` is every partition of this DBID
(the DBID literal only drops the empty `MXDB_MXSN` partition); the
`sample_time` predicates are a filter on a full scan. Shape C (span 7 days
of 36) reads the same 6 partitions as shape B (span larger than the
retention); ideally it would need about 3.

### ASH, section 11 (one `WITH RUN_PARAMS AS ...` statement holding `pool_ranked` and `ash_raw`)

- Shape B: `a8dpdnumd7vsk`, 1 execution, 0.125 s, 63,645 gets, 7,284 reads.
- Shape A: `as7c5mg6tcsz0`, 1 execution, 0.088 s.

The statement scans ASH **twice**, both without pruning:

```
| 84 |   PARTITION RANGE ITERATOR|                             | 46315 |     1 |     6 |   (pool_ranked)
| 85 |    TABLE ACCESS FULL      | WRH$_ACTIVE_SESSION_HISTORY | 46315 |     1 |     6 |
| 86 |  PARTITION RANGE ITERATOR |                             | 29061 |     1 |     6 |   (ash_raw)
| 87 |   TABLE ACCESS FULL       | WRH$_ACTIVE_SESSION_HISTORY | 29061 |     1 |     6 |
  85 - filter(("ASH"."DBID"=<dbid> AND "ASH"."SAMPLE_TIME"<CAST(:B1 AS TIMESTAMP) AND ...
```

So a single-DB run does three full ASH scans (09 once, 11 twice).

### Per-SQL lookups (section 06 x3, section 11 x1)

| sql_id | Lookup | Execs per run (A/B) | Execs (C, up to the failure) | Avg per exec |
|---|---|---|---|---|
| `7uw5txjcaw0uz` | 06 metadata aggregate (`SELECT TO_CHAR(MIN(S.BEGIN_INTERVAL_TIME) ...`) | 78 (one per pool statement) | 499 | 1.4 ms (A/B), 0.29 ms (C) |
| `9xbp43b42cj4h` | 06 plan-history table (`GROUP BY ST.PLAN_HASH_VALUE`) | 59 (only when the statement has a plan) | 377 | 0.64 ms (B2 delta: 59 execs, 0.038 s) |
| `35gtd8u7z2hcm` | 06 plan timeline points | 59 | 377 | 0.83–0.98 ms (A/B), 0.25 ms (C) |
| `6hkttmtscsq1v` | 11 latest parsing schema | 30 (the `v_max_charts` cap) | not reached | 1.4 ms (B2 delta: 30 execs, 0.043 s) |

Pool size 78 (A, B) and at least 499 (C) counted from `<tr class="sql-row"`
in the reports; 59 = `id="phv-summary-` tables. `7uw5txjcaw0uz` and
`35gtd8u7z2hcm` changed child cursors during the runs (adaptive cursor
sharing: "Bind mismatch" in `V$SQL_SHARED_CURSOR`), so their per-run
figures are execution counts from the report times the per-execution
average, not a clean before/after delta.

Plan of the metadata aggregate (the other three have the same access to
`WRH$_SQLSTAT`, then a hash join to a full scan of `WRM$_SNAPSHOT`, 1,383
rows):

```
|  6 |    PARTITION RANGE ITERATOR                  |                    | 7 | 1 | 6 |
|  7 |     TABLE ACCESS BY LOCAL INDEX ROWID BATCHED| WRH$_SQLSTAT       | 7 | 1 | 6 |
|* 8 |      INDEX RANGE SCAN                        | WRH$_SQLSTAT_INDEX | 7 | 1 | 6 |
|* 9 |     INDEX UNIQUE SCAN                        | WRM$_SNAPSHOT_PK   | 1 |   |   |
   8 - access("SQL_ID"=:B1 AND "SQL"."DBID"=<dbid>)
```

Access path: an index range scan of the local `WRH$_SQLSTAT_INDEX` on
`sql_id` in each of the 6 partitions, then table access by rowid; the
cost follows the statement's own history rows, not the size of SQLSTAT.

For comparison, section 06's two pool-building statements (`WITH
RUN_PARAMS AS ...`, one execution each) took 0.24 s + 0.09 s at shape B
and 1.59 s + 0.79 s at shape C.

## Answers

1. **ASH**: the scan does **not** prune partitions today: every ASH
   statement reads all 6 partitions of the DBID (`PARTITION RANGE
   ITERATOR 1..6`, `TABLE ACCESS FULL`), whatever the span; a run does
   three such scans. Here each scan is the whole 27 MB segment and costs
   0.07–0.13 s. Section 09 takes 0.33 s (A), 1.1–1.2 s (B), 0.55 s (C) =
   0.2 % / 0.5 % / n.a. of the run; section 11 takes 0.42 s (A) and
   4.1–4.2 s (B) = 0.2 % / 1.9 %. Of section 11's 4.2 s at shape B only
   0.13 s is the ASH statement; the rest is PL/SQL work that grows with
   the bucket count (the 52-week span has ~8,700 hourly buckets x up to 30
   cards), not the scan. Likewise section 09's growth from A to B is its
   payload building (the statement itself is ~0.1 s in both).
2. **Per-SQL lookups**: per run, 78 + 59 + 59 = 196 executions of the
   three section-06 lookups at shapes A/B (about 0.11 + 0.04 + 0.05 =
   **0.2 s, roughly 15 % of section 06's 1.2–1.5 s**, 0.1 % of the run),
   plus 30 executions of the section-11 lookup (0.04 s, 1 % of section
   11). At shape C, up to the failure: 1,253 executions, 0.35 s of ~30 s
   spent in section 06 (about 1 %). One execution costs 0.25–1.4 ms, an
   index range scan per partition.

## Recommendation

1. **ASH: cannot tell on this database.** The missing pruning is
   confirmed, but the whole ASH here is 3,200 blocks, so each scan costs
   ~0.1 s and pruning could save at most ~0.2 s a run (and nothing at
   shapes A/B, whose spans already cover most or all of the retained
   history). The saving only exists when the report span is much shorter
   than the retained ASH. A production-size check: on a database with
   millions of ASH rows and a retention much longer than the span (for
   example 30+ days retention with shape C, or 90+ days with shape A),
   run steps 1–3 and read the section-09 / section-11 ASH statements'
   elapsed time and `Pstart`/`Pstop` from `V$SQL`. If they take several
   seconds, write the fix plan with the candidate approach (a redundant
   superset `snap_id` filter over the snapshots overlapping the range
   plus or minus one hour, `sample_time` kept as the exact filter); it
   fits this evidence, since the partition key is `(DBID, SNAP_ID)` and
   the predicates already pin the DBID. Any optimisation of section 11
   should look at its per-bucket PL/SQL first, which costs ~30x more than
   its scans at shape B.
2. **Per-SQL lookups: not worth changing.** They are index-driven
   (`WRH$_SQLSTAT_INDEX` on `sql_id`), about 1 ms each, and total ~0.2 s
   per run at the default shape and ~0.35 s at 169 windows, against runs
   of 180–220 s that section 18 dominates (160–191 s). Batching them into
   one `BULK COLLECT` pass would save a fraction of a second while
   touching the "whole retention" output of section 06. Even a 10x
   per-execution cost on a long-retention database (more partitions to
   probe, a larger `WRM$_SNAPSHOT` to hash-join) would add only seconds.

## Defect found (not part of the plan's questions)

Shape C aborted the run in section 06: `ORA-19011: Character string buffer
too small` / `ORA-06512: at "SYS.DBMS_XMLGEN"`, raised by
`DBMS_XMLGEN.CONVERT(v_snip)` for the `<pre class="sql">` full-text block
(`sql/06_top_sql.sql`, the `CONVERT` after the `AWR_DATA.sqlDetails`
script). The statement that triggered it (`sql_id` `bus4fcfbz3v4j`, a
captured application statement) is 2,943 characters with 298 characters
that need escaping (216 of them single quotes). Pure-function tests of
`DBMS_XMLGEN.CONVERT` on a `VARCHAR2` (no database writes): plain text of
8,000 bytes passes unchanged, but escaping that grows the result past
4,000 bytes fails depending on the growth (2,500 -> 4,500 bytes fails,
5,100 -> 9,100 fails, 4,600 -> 5,000 passes, 5,001 -> 5,005 passes). Under
`WHENEVER SQLERROR EXIT` this ends the whole report (rc 67, the HTML
stops mid-section). Shapes A/B passed only because their 78-statement pool
held no such text; the bug predates this commit (the `CONVERT` call was
not changed by the multibyte fix). It needs its own fix plan (for example
the `CLOB` overload of `DBMS_XMLGEN.CONVERT` or a `REPLACE` chain, with
byte-identity on ordinary text).

## Limits of this measurement

- ASH is 61 k rows / 27 MB: far too small to make a full scan cost
  anything; every ASH timing here is a floor.
- One DBID and one instance: the `dbid IN (...)` list prunes nothing
  here; RAC and multi-DBID (migrated PDB) were not exercised.
- The default weekly shapes have only 3 valid windows (restart gaps), and
  shape B's span is longer than the 35-day retention, so shapes A and B
  scan practically the same data.
- Shape C stopped in section 06 (ORA-19011), so it has no section-11 or
  total-run figure and no second run.
- The VM has 2 CPUs and an unrelated long-running session of another
  workload was busy on CPU during all runs; absolute times are noisy.
- Child-cursor churn (adaptive cursor sharing) and cursors aged out of the
  shared pool made some per-run `V$SQL` counts unusable; those figures
  are execution counts from the report times the per-execution average.
- No `EXPLAIN PLAN`, no statistics: plans are the cursors' actual plans
  from `DISPLAY_CURSOR`, without run-time row counts (`STATISTICS_LEVEL`
  was not changed).
