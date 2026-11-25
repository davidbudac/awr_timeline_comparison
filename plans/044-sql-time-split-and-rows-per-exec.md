# Plan 044: why one statement got slower -- time split and rows per execution

Status: DONE; DB run pending (owner). Round 3, review item 5.
Informational only: no finding, count, pill or severity; nothing touches
`policy_bucket` or `metric_policy.plsql`.

## Why (the DBA question)

"This statement takes 4x longer per run -- worse plan, more data, slower
I/O, or was it blocked?" Section 06 showed per statement and window the
executions, elapsed, elapsed per execution and the plan hash, never the
other columns of the SAME `DBA_HIST_SQLSTAT` rows that answer it: the I/O,
concurrency, application and cluster wait timers and the rows processed.

## Design as built

1. **Where.** Every opened Per-SQL pool row (`tr.sql-detail`), right after
   the Compared windows table and its notes: `div.sqx[data-sid][data-sqx]`
   "Per execution: where the time went". `table.sqx-tbl` (`data-nosort
   data-nocount data-notools`), 11 rows `tr[data-k]`: Elapsed, then CPU,
   I/O wait, Concurrency, Application (locks), Cluster, Other (elapsed
   beyond the five, never below 0, on the summed totals); then Rows, Buffer
   gets, Physical reads, Buffer gets per row. Columns: Current, Prior mean,
   Change (`sqd_chg`, plain), Share of the rise (the part's change over
   elapsed's change, whole %, empty when per-run elapsed did not rise). The
   header's title says the timers are separate (overlap or remainder, PX
   servers included).
2. **Definition.** Current per execution = the Current window's totals over
   its executions; prior mean = the summed totals of the prior VALID
   windows WITH a row over their summed executions (the tfoot's definition),
   so the parts add up. Modes (`data-sqx`): `pe`; `tot` (0 Current
   executions: window totals against the prior mean per window); `new` (no
   prior row: Current only, "new"); `noprx` (prior rows, 0 prior
   executions); `nocur` (no Current row, or the Current window skipped: one
   note line, no table). Skipped windows never count.
3. **Reads as** (`p.sqx-rd[data-rule]`, mode `pe` only, PL/SQL). Gate: each
   run took at least 1.5x the prior mean. Then the first that holds
   (constants `c_sqx_gate 1.5`, `c_sqx_part 0.6`, `c_sqx_flat 0.2`,
   `c_sqx_up 1.5`):
   - `harder`: gets per run >= 1.5x, rows per run within +/-20% (or 0 on
     both sides), CPU + I/O wait carry >= 60% of the per-run rise --
     "works harder for the same result ... plan or access path";
   - `data`: rows per run >= 1.5x, gets per row within +/-20% -- "more data
     per call";
   - `ap` / `cc` / `cl`: application / concurrency / cluster wait carries
     >= 60% -- blocked (row locks) / contention / global cache;
   - `slowio`: I/O wait >= 60%, gets, rows and physical reads per run
     within +/-20% -- "each read got slower ... storage";
   - `cold`: I/O wait >= 60%, gets per run within +/-20%, physical reads
     per run >= 1.5x -- "a colder buffer cache" (added: physical reads up
     on the same gets is not slower storage);
   - `mixed`: none -- names the largest part and its share.
   Below the gate, when the window total rose >= 1.5x the prior mean total:
   `often` ("each run took about as long ...; it ran x3.0 as often").
   Hedged wording ("points at", "usually"), as plan 033's hints.
4. **No extra AWR scan.** The main cursor's `agg` CTE got `iowait_us`,
   `ccwait_us`, `apwait_us`, `clwait_us`, `rows_proc`; the final SELECT
   carries them (and CPU / gets / reads) as `agg_*`, the loop keeps them in
   `v_wa_cpu` / `_io` / `_cc` / `_ap` / `_cl` / `_rows` / `_gets` / `_rds`
   next to `v_wa_exec` (same key, same `IF s.agg_exec IS NOT NULL`). No
   per-window string.
5. **Plan-change card (18).** Its bounded SQLSTAT read now also sums
   `IOWAIT_DELTA` and `ROWS_PROCESSED_DELTA`; one evidence row `Rows, I/O`
   ("rows per run x1.0", "I/O wait is 86% of the per-run rise"; plain
   delta of rows per run, no glyph: there is no sigma) with the SAME
   totals-over-executions definition as 06 (not the card's per-window mean
   of "Per exec"), only from SQLSTAT data with Current and prior
   executions. About 25 lines.
6. **Values switch.** The block has no `span.tsv` / `data-pe` / `tsv-*`
   markup and lives in the pool, which the switch does not touch; the div
   uses `data-sid` / `data-sqx`, never `data-sql` / `data-mode` (06's
   row-toggle and Break down by handlers read those).
7. **About note** (`sql/19_reference.sql`): "Where the time went" after
   "Per-SQL detail": the parts and their columns, separate timers, the
   definition, every threshold, the card line, "ranked evidence".
8. **CSS** `sql/lib/src/css_sqlsplit.css` -> `css_sqlsplit.plsql`, in
   `sql/lib/viz_head.sql` (`_style.sql` is in the fleet chrome). It also
   turns off the sticky header inside the pool row's `.sqd-tw` wrappers:
   `.sqd-tw` scrolls sideways, so the sticky `th` stuck to the wrapper and
   sat over the first row -- the existing Compared windows table's Current
   row was covered too (found in the screenshots; pre-existing).
9. **Demo twin.** The model's `SqlHour` already carries `rows`,
   `iowait_us` and the wait split (event -> us), so `s06._agg` takes I/O
   from `iowait_us`, concurrency / application by wait class
   (`math.fsum`), cluster 0; `s18` the same I/O and rows. Nothing invented,
   no `w.rng`. Only 7k2m9dx4qp1zb passes the gate in Current: `harder`,
   x4.4 per run, gets x18.4, rows x1.0, I/O wait 86% of the rise; its plan
   card reads "rows per run x1.0 / I/O wait is 86%". The lock statement
   2yq9jv7c5hm3d shows Application as its biggest part but no rise (the
   row-lock day is Aug 12), so no sentence. No statement has a rows-per-run
   rise in the model, so "more data per call" does not show in the demo.
   Every mode and rule was exercised on a scratch variant (bent agg rows;
   verify_report OK on it, see below).
10. **verify_report block 10b**: one block per pool row, known mode, nocur
    <=> no Current values row; no severity / Values-switch markup; raw
    totals vs the Compared windows Current row and tfoot (titles, 4
    decimals); Other = elapsed beyond the parts; parts <= elapsed (demo:
    fail, real report: info); shares recomputed; the rule recomputed from
    the block's data-* (06's thresholds; within 1e-6 of a threshold:
    logged); Reads-as present <=> rule; demo 7k2m9dx4qp1zb = `harder`; the
    plan card's line agrees with the block; the three Values modes leave
    every block's text unchanged.

## Files touched

`sql/06_top_sql.sql`, `sql/18_sqlmon.sql`, `sql/19_reference.sql`,
`sql/lib/viz_head.sql`, `sql/lib/src/css_sqlsplit.css` + generated
`sql/lib/css_sqlsplit.plsql`, `demo/awrdemo/sections/s06_top_sql.py`,
`demo/awrdemo/sections/s18_sqlmon.py`, `demo/gen_demo_report.py`
(`VIZ_CSS`), `demo/verify_report.js`, the three demo pages, `CLAUDE.md`,
`CHANGELOG.md`, `plans/README.md`, this file.

## Not covered

- `PLSEXEC_TIME_DELTA`, `JAVEXEC_TIME_DELTA`, `FETCHES_DELTA`,
  `PX_SERVERS_EXECS_DELTA`: left out (PL/SQL time overlaps elapsed of the
  calling statement; PX is noted in the header title instead).
- No minimum execution count for "Reads as" (06's Per-exec regression
  ranking asks for 3 Current executions): a batch statement that runs once
  an hour is exactly where a per-run reading matters, so a single Current
  execution still gets a sentence. Owner's call if that proves noisy (the
  guard would go into 06, the twin, verify 10b and the About note).
- No per-window time split (Current vs prior mean only), no Timeline row,
  no chart, no finding / card / Copy summary / findings JSON field.
- Size: about 3 KB per pool statement (11 rows); dbmint's 169-window run
  had 846 pool statements, so about +2.5 MB on a 52 MB page.
- Unexercised: RAC (cluster wait), multi-DBID, a real `tot` / `noprx`
  statement, every rule but `harder` outside the scratch variant.

## Names to check on dbmint (DESC / SELECT DISTINCT)

`DBA_HIST_SQLSTAT` (required grant): `IOWAIT_DELTA`, `CLWAIT_DELTA`,
`APWAIT_DELTA`, `CCWAIT_DELTA` (microseconds), `ROWS_PROCESSED_DELTA`;
already used: `CPU_TIME_DELTA`, `ELAPSED_TIME_DELTA`, `BUFFER_GETS_DELTA`,
`DISK_READS_DELTA`, `EXECUTIONS_DELTA`. All confirmed in the 19c Database
Reference 5.66 DBA_HIST_SQLSTAT,
https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SQLSTAT.html
Check: `DESC dba_hist_sqlstat`.

## dbmint checklist (owner)

1. Hourly run, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h`, and the plan-change
   window `"2026-11-08 11:00" 1 8 10 0 1 h`: rc 0, 29 / 29 `AWR-SECTION`
   pairs, no `ORA-` / `SP2-` / `PLS-` in the log, max line < 32767.
2. Open a pool row: the block sits under Compared windows; its Current s per
   exec equals the table's. Cross-check one statement:
   `SELECT SUM(elapsed_time_delta), SUM(cpu_time_delta), SUM(iowait_delta),
   SUM(ccwait_delta), SUM(apwait_delta), SUM(clwait_delta),
   SUM(rows_processed_delta), SUM(executions_delta) FROM dba_hist_sqlstat
   WHERE sql_id = '<id>' AND snap_id BETWEEN <begin + 1> AND <end>` = the
   rows' `data-xc` / the div's `data-cx`.
3. The plan card of b84c2ncqhcw23 (plan-change window): a "Rows, I/O" line;
   its I/O % equals the block's I/O share.
4. A 168-window run: the page size grows by about 3 KB per pool statement.
5. verify_report on both reports (block 10b; "separate timers overlap" info
   lines are expected on a real database).
