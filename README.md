# AWR Timeline Comparison

Pure-SQL Oracle 19c toolkit that compares AWR snapshots of **the same hour
across weeks** (e.g. Mon 09:00–10:00 today vs the four prior Mondays
09:00–10:00), flags drastic changes via z-score, renders a readable HTML
report, and persists every fact into a scratch schema for ad-hoc analysis.

Requirements: Oracle Database 19c with the **Diagnostic + Tuning Pack**
licensed (needed for `DBA_HIST_*` and `DBA_HIST_SQLSTAT`).

## Install

Run once per target database as the user that will own the scratch tables:

```bash
sqlplus user/pw@svc @sql/setup_schema.sql
```

This creates (idempotently):

| Object | Purpose |
|---|---|
| `AWR_TREND_RUN_SEQ` | Sequence for `run_id` |
| `AWR_TREND_RUNS` | One row per report execution |
| `AWR_TREND_WINDOWS` | Current + aligned prior windows with snap_id pairs |
| `AWR_TREND_LOAD_PROFILE` | Per-window deltas from `DBA_HIST_SYSSTAT` |
| `AWR_TREND_SYSMETRIC` | Per-window averages from `DBA_HIST_SYSMETRIC_SUMMARY` |
| `AWR_TREND_WAITS` | Top FG + BG waits and wait-class rollup |
| `AWR_TREND_TOP_SQL` | Top-N SQL per window by 4 dimensions |
| `AWR_TREND_ASH_TIMELINE` | Hourly ASH sample counts by wait class across the full compare span |
| `AWR_TREND_FINDINGS` | Ranked findings with z-score + severity |

Required grants on the owning user (if not already granted by `DBA` role):

```sql
GRANT SELECT ON DBA_HIST_SNAPSHOT         TO <user>;
GRANT SELECT ON DBA_HIST_SYSSTAT          TO <user>;
GRANT SELECT ON DBA_HIST_SYSTEM_EVENT     TO <user>;
GRANT SELECT ON DBA_HIST_BG_EVENT_SUMMARY TO <user>;
GRANT SELECT ON DBA_HIST_SYSMETRIC_SUMMARY TO <user>;
GRANT SELECT ON DBA_HIST_SQLSTAT          TO <user>;
GRANT SELECT ON DBA_HIST_SQLTEXT          TO <user>;
GRANT SELECT ON DBA_HIST_BASELINE         TO <user>;
GRANT SELECT ON DBA_HIST_ACTIVE_SESS_HISTORY TO <user>;
GRANT SELECT ON V_$DATABASE               TO <user>;
GRANT SELECT ON V_$INSTANCE               TO <user>;
-- Only if you use side/create_weekly_baselines.sql:
GRANT EXECUTE ON DBMS_WORKLOAD_REPOSITORY TO <user>;
```

## Run

Easiest — the shell wrapper (sets all substitution vars for you):

```bash
./run_awr_trend.sh user/pw@svc                              # defaults
./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0  # full form
```

Arguments: `connect_string [target_end [win_hours [weeks_back [top_n [inst_num]]]]]`
Defaults: current 1-hour window (prior full hour), 4 aligned prior weeks,
top-10 SQL/waits, aggregated across RAC instances.

Pure SQL\*Plus (no bash) — you must pre-DEFINE the variables or load the
canonical defaults first:

```sql
SQL> @sql/defaults.sql
SQL> @awr_trend.sql
-- or, to customize one-off:
SQL> DEFINE target_end = '2026-04-15 09:00'
SQL> DEFINE win_hours  = 2
SQL> DEFINE weeks_back = 6
SQL> DEFINE top_n      = 20
SQL> DEFINE inst_num   = 1
SQL> @awr_trend.sql
```

Output: `reports/awr_trend_<DBID>_<YYYYMMDDHH24MI>_run<run_id>.html`. Open
it in a browser. The report is self-contained (no external CSS/JS).

## Read the report

The header card at the top lists **which windows were compared** —
the current window plus the aligned prior windows (same hour-of-week,
stepping back 7 days at a time) with explicit start → end timestamps,
so you always know exactly what baseline is driving the z-scores.

1. **Overview** — hero strip with the six headline load/metric numbers.
2. **ASH timeline** — hourly stacked-area chart of Active Sessions by wait
   class from `DBA_HIST_ACTIVE_SESS_HISTORY`, covering the full compare
   span; compared windows are highlighted as background bands.
3. **Findings** — top of the page. Each metric with `|z|>3` is CRITICAL,
   `|z|>2` is WARN. Metrics with fewer than 3 valid prior windows fall back
   to a `%`-delta only.
4. **Windows** — the aligned windows used, with begin/end snap_ids. Weeks
   where the instance restarted mid-window are SKIPPED and excluded from
   the baseline.
5. **Load profile** — per-second rates for the classic AWR "Load Profile"
   stats incl. redo size.
6. **System metrics** — averages from `DBA_HIST_SYSMETRIC_SUMMARY`.
7. **Foreground waits** — top-N events + wait-class rollup.
8. **Background waits** — from `DBA_HIST_BG_EVENT_SUMMARY`.
9. **Top SQL** — ranked 4 ways (elapsed, CPU, buffer gets, executions)
   with plan-change badges and full SQL text.

## Does it write to the database?

Yes — by design. Each run inserts rows into the `AWR_TREND_*` scratch
tables listed above (keyed by `run_id`), and every number in the HTML
report is read back out of those tables on its way to the page. That
is a hard architectural invariant: no section renders from transient
CTEs only, so removing the writes would require a significant rewrite
of sections 02–08. The `DBA_HIST_*` source views are read-only either
way — the writes are confined to the connected user's own schema.

If you want a "leave no trace" run:

```sql
-- run the report, then drop that run's rows (ON DELETE CASCADE wipes
-- all 8 child tables for this run_id):
DELETE FROM awr_trend_runs
 WHERE run_id = (SELECT MAX(run_id) FROM awr_trend_runs);
COMMIT;
```

The scratch tables themselves stay in place. A TRUNCATE of each table,
or dropping the schema entirely, is also safe — `setup_schema.sql` is
idempotent and will recreate them.

## Query the persisted data

Every number in the HTML is also in the scratch tables, keyed by `run_id`:

```sql
-- Latest run's findings, sorted most-critical-first
SELECT severity, metric_domain, metric_name,
       current_value, prior_mean, z_score, pct_delta
FROM   awr_trend_findings
WHERE  run_id = (SELECT MAX(run_id) FROM awr_trend_runs)
ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2
                       WHEN 'INSUFFICIENT_HISTORY' THEN 3
                       WHEN 'FLAT_BASELINE' THEN 4 ELSE 5 END,
         ABS(NVL(z_score,0)) DESC;

-- Trend a single metric across all runs for one DB
SELECT r.target_end_ts, lp.per_sec AS redo_bytes_per_sec
FROM   awr_trend_runs r
JOIN   awr_trend_load_profile lp
       ON lp.run_id = r.run_id AND lp.week_offset = 0
WHERE  lp.stat_name = 'redo size'
ORDER BY r.target_end_ts;

-- SQL that showed up in top-N more than once
SELECT sql_id, COUNT(DISTINCT run_id) AS appearances
FROM   awr_trend_top_sql
GROUP BY sql_id HAVING COUNT(DISTINCT run_id) > 1
ORDER BY appearances DESC;
```

## Side script: weekly AWR baselines (optional)

Creates one `DBA_HIST_BASELINE` entry per ISO week so you can later compare
weeks with `awrddrpt.sql` / OEM directly. Independent from the main report.

```bash
sqlplus user/pw@svc @side/create_weekly_baselines.sql
```

Defaults: creates a baseline for the last completed ISO week, name
`WK_<IYYY>_<IW>` (e.g. `WK_2026_16`). Idempotent.

Override:

```sql
SQL> DEFINE weeks_back  = 4
SQL> DEFINE prefix      = 'WK_'
SQL> DEFINE expire_days = 365
SQL> @side/create_weekly_baselines.sql
```

Schedule weekly:

```sql
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AWR_WEEKLY_BASELINES',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN NULL; END;',  -- replace with a CREATE_BASELINE call
        repeat_interval => 'FREQ=WEEKLY;BYDAY=MON;BYHOUR=6;BYMINUTE=0',
        enabled         => TRUE);
END;
/
```

## File layout

```
.
├── awr_trend.sql                    -- driver
├── sql/
│   ├── setup_schema.sql             -- one-time DDL
│   ├── _style.sql                   -- shared CSS (emitted once)
│   ├── 00_params.sql                -- params + header card
│   ├── 01_windows.sql               -- snapshot window matching
│   ├── 02_load_profile.sql          -- SYSSTAT deltas
│   ├── 03_sysmetric.sql             -- SYSMETRIC averages
│   ├── 04_waits_fg.sql              -- foreground waits
│   ├── 05_waits_bg.sql              -- background waits
│   ├── 06_top_sql.sql               -- Top-N SQL
│   ├── 07_summary.sql               -- z-score findings
│   ├── 08_overview.sql              -- hero strip (headline metrics)
│   └── 09_ash_timeline.sql          -- hourly ASH stacked-area timeline
├── side/
│   └── create_weekly_baselines.sql  -- optional, AWR baselines
└── reports/                         -- generated HTML files
```

## Caveats

- Designed for the default hourly AWR snapshot interval. Shorter intervals
  work; longer intervals may reduce to a 2-snap window per hour.
- Instance restarts inside a window invalidate that window for the
  baseline; the window is still shown but flagged and excluded.
- Results assume RAC nodes were all up for the window (per-instance mode
  filters by `instance_number`; aggregate mode sums across instances).
- Pluggable databases: run as a user in the container you want to analyse.
  The `dbid` is resolved from `v$database` at run time.
