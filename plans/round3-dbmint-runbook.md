# Round 3 (plans 038-047): first database run

Nothing in round 3 has been parsed, compiled or run by Oracle. It was built
against the synthetic demo, lint and two independent read-throughs of the
SQL (commit `f1c1ca0`). This runbook is the order to test it in on dbmint
(`ssh -p 2200 oracle@dbmint`, `cdb1` primary, `sqlplus / as sysdba`). Do not
write "verified on dbmint" for any round 3 plan until its part below ran.

The run uses `WHENEVER SQLERROR EXIT`: the first error ends the report.
Sections run in the driver's order, so with `debug=Y` the last progress
marker names the section that failed.

## 0. Copy the branch

```sh
rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex \
  --exclude=fleet.conf ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'
# never --delete: it wipes the untracked fleet.conf on dbmint
```

## 1. Preflight: names (read-only, a few seconds, before any report)

**1a. Columns.** Expected result: no rows. A row names a column the new code
reads that this database does not have.

```sql
SELECT x.column_value AS missing_column
FROM   TABLE(sys.odcivarchar2list(
  'DBA_HIST_SYSMETRIC_SUMMARY.MAXVAL',
  'DBA_HIST_PARAMETER.PARAMETER_NAME', 'DBA_HIST_PARAMETER.VALUE',
  'DBA_HIST_PARAMETER.CON_ID', 'DBA_HIST_PARAMETER.CON_DBID',
  'DBA_HIST_SYS_TIME_MODEL.STAT_NAME', 'DBA_HIST_SYS_TIME_MODEL.VALUE',
  'DBA_HIST_SQLSTAT.IOWAIT_DELTA', 'DBA_HIST_SQLSTAT.CLWAIT_DELTA',
  'DBA_HIST_SQLSTAT.APWAIT_DELTA', 'DBA_HIST_SQLSTAT.CCWAIT_DELTA',
  'DBA_HIST_SQLSTAT.ROWS_PROCESSED_DELTA',
  'DBA_HIST_ACTIVE_SESS_HISTORY.SESSION_TYPE', 'DBA_HIST_ACTIVE_SESS_HISTORY.SESSION_STATE',
  'DBA_HIST_ACTIVE_SESS_HISTORY.SERVICE_HASH', 'DBA_HIST_ACTIVE_SESS_HISTORY.MODULE',
  'DBA_HIST_ACTIVE_SESS_HISTORY.MACHINE', 'DBA_HIST_ACTIVE_SESS_HISTORY.PROGRAM',
  'DBA_HIST_ACTIVE_SESS_HISTORY.USER_ID', 'DBA_HIST_ACTIVE_SESS_HISTORY.CON_ID',
  'DBA_HIST_ACTIVE_SESS_HISTORY.SAMPLE_ID', 'DBA_HIST_ACTIVE_SESS_HISTORY.SQL_ID',
  'DBA_HIST_ACTIVE_SESS_HISTORY.TEMP_SPACE_ALLOCATED', 'DBA_HIST_ACTIVE_SESS_HISTORY.PGA_ALLOCATED',
  'DBA_HIST_SQL_PLAN.OBJECT_TYPE',
  'DBA_HIST_SERVICE_NAME.SERVICE_NAME_HASH', 'DBA_HIST_SERVICE_NAME.SERVICE_NAME',
  'DBA_HIST_PDB_INSTANCE.CON_ID', 'DBA_HIST_PDB_INSTANCE.PDB_NAME', 'DBA_HIST_PDB_INSTANCE.OPEN_TIME',
  'DBA_HIST_OSSTAT.STAT_NAME', 'DBA_HIST_OSSTAT.VALUE', 'DBA_HIST_OSSTAT.CON_ID',
  'DBA_HIST_PGASTAT.NAME', 'DBA_HIST_PGASTAT.VALUE',
  'DBA_HIST_MEM_DYNAMIC_COMP.COMPONENT', 'DBA_HIST_MEM_DYNAMIC_COMP.CURRENT_SIZE',
  'DBA_HIST_MEMORY_RESIZE_OPS.COMPONENT', 'DBA_HIST_MEMORY_RESIZE_OPS.OPER_TYPE',
  'DBA_HIST_MEMORY_RESIZE_OPS.INITIAL_SIZE', 'DBA_HIST_MEMORY_RESIZE_OPS.TARGET_SIZE',
  'DBA_HIST_MEMORY_RESIZE_OPS.FINAL_SIZE', 'DBA_HIST_MEMORY_RESIZE_OPS.STATUS',
  'DBA_HIST_MEMORY_RESIZE_OPS.START_TIME', 'DBA_HIST_MEMORY_RESIZE_OPS.END_TIME',
  'DBA_HIST_UNDOSTAT.BEGIN_TIME', 'DBA_HIST_UNDOSTAT.END_TIME', 'DBA_HIST_UNDOSTAT.UNDOBLKS',
  'DBA_HIST_UNDOSTAT.TXNCOUNT', 'DBA_HIST_UNDOSTAT.MAXQUERYLEN', 'DBA_HIST_UNDOSTAT.MAXQUERYSQLID',
  'DBA_HIST_UNDOSTAT.MAXCONCURRENCY', 'DBA_HIST_UNDOSTAT.SSOLDERRCNT',
  'DBA_HIST_UNDOSTAT.NOSPACEERRCNT', 'DBA_HIST_UNDOSTAT.TUNED_UNDORETENTION',
  'DBA_OBJECTS.SUBOBJECT_NAME', 'DBA_OBJECTS.CREATED', 'DBA_OBJECTS.LAST_DDL_TIME', 'DBA_OBJECTS.STATUS',
  'DBA_TAB_STATISTICS.PARTITION_NAME', 'DBA_TAB_STATISTICS.OBJECT_TYPE',
  'DBA_TAB_STATISTICS.LAST_ANALYZED', 'DBA_TAB_STATISTICS.NUM_ROWS',
  'DBA_TAB_STATISTICS.STALE_STATS', 'DBA_TAB_STATISTICS.STATTYPE_LOCKED',
  'DBA_TAB_STATS_HISTORY.PARTITION_NAME', 'DBA_TAB_STATS_HISTORY.SUBPARTITION_NAME',
  'DBA_TAB_STATS_HISTORY.STATS_UPDATE_TIME',
  'DBA_INDEXES.TABLE_OWNER', 'DBA_INDEXES.TABLE_NAME', 'DBA_INDEXES.STATUS',
  'DBA_INDEXES.VISIBILITY', 'DBA_INDEXES.PARTITIONED', 'DBA_INDEXES.LAST_ANALYZED',
  'DBA_INDEXES.NUM_ROWS')) x
WHERE  NOT EXISTS (SELECT 1 FROM dba_tab_columns t
                   WHERE  t.owner = 'SYS'
                   AND    t.table_name || '.' || t.column_name = x.column_value);
```

The first 24 entries (through the ASH columns) are read by STATIC SQL, and
`DBA_HIST_SQL_PLAN.OBJECT_TYPE` by section 23's dynamic plan read, which
re-raises anything but a missing grant: a missing one of those 25 aborts
the report, fix it before going on. The rest are optional reads in
tolerant handlers: a missing one only empties a block or shows a "could
not read" note.

**1b. Statistic names** (a wrong name aborts nothing, it shows an empty or
"Not found" row). Compare each list with the names the plan records quote:

```sql
SELECT DISTINCT stat_name FROM dba_hist_sys_time_model ORDER BY 1;          -- plan 043: 19 names
SELECT DISTINCT parameter_name FROM dba_hist_parameter
WHERE  LOWER(parameter_name) LIKE 'cpu%';                                    -- plan 042: cpu_count
SELECT stat_name, cumulative, comments FROM v$osstat ORDER BY 1;             -- plan 046: names and which are cumulative
SELECT DISTINCT name FROM dba_hist_pgastat ORDER BY 1;                       -- plan 046
SELECT DISTINCT component FROM dba_hist_mem_dynamic_comp ORDER BY 1;         -- plan 046
SELECT DISTINCT object_type FROM dba_hist_sql_plan ORDER BY 1;               -- plan 047: TABLE* / INDEX* assumed
```

The remaining data questions (does ASH `SERVICE_HASH` join to
`SERVICE_NAME_HASH`; program suffixes; per-container fan-out and duplicates
in OSSTAT / PGASTAT / MEM_DYNAMIC_COMP / UNDOSTAT; the time zone of
`STATS_UPDATE_TIME`) have their queries under "Names to check on dbmint" in
plans 045, 046 and 047.

## 2. Pick a window

dbmint keeps 35 days of AWR and is idle most of the time, so every pinned
date expires. Probe first (snapshots per day and per `startup_time`, ASH
rows per hour) and pin inside a restart-free stretch with 15-minute
snapshots. On 2026-11-19 the usable stretch was 2026-11-07 14:45 to
2026-11-09 16:15; the two windows quoted below are from it and are gone
after about 2026-12-12.

## 3. Runs, in this order

Every run: exit code 0, no `ORA-` / `SP2-` / `PLS-` in the log (hits inside
captured SQL text are false positives, look at the context), **31 of 31**
`AWR-SECTION` BEGIN / END pairs (29 before round 3; sections 29 and 30 are
new), longest line under 32767 bytes.

| # | Run | What it is for |
|---|---|---|
| 1 | `"2026-11-08 15:00" 1 8 10 0 1 h`, `debug=Y` | The compile run: every section parses and executes. Fix and repeat until clean before anything else. |
| 2 | the same, `debug=N` | Same md5 as run 1 after the byte-identity `sed` (debug must not change the HTML). |
| 3 | `"2026-11-08 11:00" 1 8 10 0 1 h` | A plan change (b84c2ncqhcw23): plans 044 (the block and the plan card's "Rows, I/O" line) and 047 (objects table, interval, the "Objects" row). |
| 4 | `"2026-11-08 15:00" 1 4 10 0 1 h` | Four prior windows: plan 039's "Thin baseline" verdict note; plan 038 must stay silent when fewer than 3 priors would remain. |
| 5 | run 1 with `DESIGN=quiet`, then `DESIGN=dashboard` | The designs move cards and rows that plans 039, 041-047 add to. |
| 6 | `"2026-11-09 16:00" 1 168 10 0 1 h` | 169 windows: per-window strings (plans 041, 042, 043, 045, 046), time and size against the last 168-window run (219 s, 51.8 MB). |
| 7 | `"2026-11-08 02:00" 1 20 10 0 1 h` | Crosses a restart: skipped windows must read "unknown", never 0 (plans 041, 042, 045, 046). |
| 8 | 2 h windows every 1 h (overlapping) | Plan 045 counts a sample in every window that holds it. |
| 9 | `template=simple`, `template=dev`, `SQLMON=N`, `profile_days=7`, `AUTO` weekly | Options: nothing new may depend on a template list or on section 18. |
| 10 | a user holding ONLY the README's required grants, if one exists on dbmint | Every optional block shows "needs SELECT on ..." and the report still ends with rc 0. If no such user exists, simulate one view at a time (a misspelt view name in a scratch copy on dbmint), as was done for sections 22 / 23. |
| 11 | fleet run, `FLEET_DETAIL=all FLEET_PROFILE_DAYS=7` | Fleet output unchanged (round 3 touched no fleet file; `_style.sql` and `band_glyph.plsql` are shared); the detail reports carry the new sections. |

Then, one Chrome at a time, `demo/verify_report.js` on the reports of runs
1, 3, 4, 5 and 6 (its round 3 blocks are 6c-6i and 10b; each skips what a
real report lacks).

## 4. Per-plan checklist

Each plan record ends with "dbmint checklist (owner)": what to look at and
which number to confirm with an independent read-only query.

| Plan | Record | The one thing to confirm independently |
|---|---|---|
| 038 | `038-baseline-note-on-verdict.md` | the note's counts equal section 26's what-if for the same suggestion |
| 039 | `039-confidence-note-by-window-count.md` | card `n` equals the lead row's prior-window count |
| 040 | `040-shorter-summary-and-findings-json.md` | the JSON block parses; its cards equal the page's cards |
| 041 | `041-peak-inside-the-window.md` | a metric's peak against `MAX(maxval)` for the Current snapshots; the busiest minute against an ASH count for that minute |
| 042 | `042-cpu-capacity.md` | `cpu_count` and DB CPU (AAS) per window against the two views |
| 043 | `043-time-model-breakdown.md` | two rows of the table against time-model deltas; child <= parent |
| 044 | `044-sql-time-split-and-rows-per-exec.md` | b84c2ncqhcw23's I/O wait and rows per run against `DBA_HIST_SQLSTAT` |
| 045 | `045-who-added-the-load.md` | each dimension sums to the foreground ASH total (section 09's `winfg`) |
| 046 | `046-host-memory-undo-temp.md` | host busy % against OSSTAT deltas; the buffer cache size; UNDOSTAT not double counted across containers |
| 047 | `047-object-changes-around-a-plan-change.md` | a `STATS_UPDATE_TIME` shown "inside the interval" really lies in it (time zone) |

## 5. Known gaps (no database, or not testable on dbmint)

- RAC (summed `cpu_count`, "max per instance" peaks, per-instance host
  rows), a migrated PDB (several DBIDs), several PDBs (the PDB dimension of
  section 29, undo per container), a database that is CPU-bound or
  swapping, a real ORA-01031.
- The demo exercises one "Reads as" rule of plan 044 ("works harder for the
  same result") and none of plan 046's `lopen` rules; the others ran only
  on scratch variants of the demo.
- The demo pages were regenerated on macOS only: Docker was not running, so
  the Linux `gen_demo_report.py --check` (CLAUDE.md "Demo report") did not
  run. CI does it on push.
- Not implemented (owner decision): thresholds that widen for a small
  baseline. Plan 039 states the confidence instead.
