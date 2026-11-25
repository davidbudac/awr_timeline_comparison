# Plan 047: object changes around a plan change

Status: DONE; DB run pending (owner). Round 3, review item 9. Informational
only: no finding, count, pill or severity; nothing touches `policy_bucket`
or `metric_policy.plsql`.

## Why (the DBA question)

"The plan flipped -- what happened to the objects it touches?" Section 18
shows the plan change, section 23 where the time goes inside the old and
the new plan. The next manual checks are: were optimizer statistics
gathered on those tables just before the flip, was there DDL, is an index
of the old plan now unusable, invisible or gone? The report said nothing.

## Design as built

- `sql/23_plan_flame.sql`, changed plans only (`v_mode = 'chg'`). Step 5b,
  before any markup: every table / index line of a statement's old and new
  plan (plan line `OBJECT_TYPE` `TABLE*` / `INDEX*`, now also selected from
  `DBA_HIST_SQL_PLAN`; else the operation; FIXED / TEMP types, `SYS_TEMP%`
  names and views are left out). The union over the (at most 3) statements
  is read ONCE from four optional dictionary views through dynamic SQL,
  owners and names bound as two `sys.odcivarchar2list` (a superset, matched
  exactly on kind / owner / name in PL/SQL), each read in its own plan-046
  handler: ORA-00942 / ORA-01031 -> "needs SELECT on <view>", any other
  error -> "could not read <view>: <message>"; the report carries on.
- **Table-level only**: `DBA_OBJECTS` `subobject_name IS NULL`,
  `DBA_TAB_STATISTICS` / `DBA_TAB_STATS_HISTORY` partition NULL. A
  partitioned index has `STATUS` `N/A` (shown, not abnormal; "partitions not
  checked"). Enough to answer the question for the common case; a stale or
  unusable PARTITION is not seen (stated in the section).
- **Interval** ("around the plan change"): from the start of the most
  recent VALID prior window whose window plan (23's existing `wplan`, the
  last non-zero SQLSTAT plan of the window) is the old plan, to the nominal
  end of the Current window. No new AWR scan: `lastold` is one more CTE over
  `wplan`, the window starts come from 23's existing `windows_rollup` loop.
- **Honesty rules** (section, About note, CLAUDE.md): (1) the dictionary is
  the CURRENT container's CURRENT state: no row = "no dictionary row in this
  container (dropped, or not visible here)", never "dropped"; every object
  invisible -> "These objects are not visible from this container". (2) Only
  `CREATED`, `LAST_DDL_TIME`, `LAST_ANALYZED` and the statistics history are
  past times, and only a time inside the interval is called around the
  change. A latest-only time AFTER the interval can hide an earlier event:
  the sentence says so. The history keeps 31 days by default: named when
  the interval starts earlier. `STATS_UPDATE_TIME` means statistics changed
  (gathered, set, restored, imported): worded "new statistics". A weekly
  cadence's interval always holds the routine weekly gather, so the first
  named table also quotes its (at most 2) earlier history times: a Saturday
  06:00 routine reads differently from a Tuesday 22:35 after a release.
- Per block (after the plan tables): `div.pf-obj#pfo-<sql_id>` with the
  interval as `data-t0` / `data-t1`, an h4, `p.pf-ord` "Reads as:"
  (hedged: "the plan may have followed them"), the interval sentence, the
  read notes, `table.pf-ob[data-nocount]`: object, type ("index on T"), in
  old / new / both, statistics now (last analyzed + rows), new statistics in
  the interval (at most 3, newest first, "+ n more"), last DDL, created,
  state now, "Around the change" markers (`span.pf-om`, neutral classes:
  new statistics, DDL, created, UNUSABLE / INVISIBLE / INVALID / no
  dictionary row, "later DDL"). At most 30 rows, tables first.
- Plan-change card: one "Objects" evidence row (plain, "not scored")
  linking the object row, when the sentence names something inside the
  interval or an abnormal state; moved from a hidden `#pfo-ev-src` by an
  inline script, only onto the card whose `data-ph0` / `data-ph1` equal 23's
  old / new plan (18 and 23 pick plans by different rules). The card is
  targeted by id, so 17's move under the I/O card and the dashboard's side
  column keep it. JS off: hidden.
- `lib_ls` gains "; new statistics on X around the change" (interval items
  only). `lopen` unchanged.

## Files touched

`sql/23_plan_flame.sql`, `sql/lib/src/css_planflame.css` (+ generated
`sql/lib/css_planflame.plsql`), `sql/19_reference.sql` (About note "Objects
around a plan change"), `lint.sh` (35), `README.md`,
`demo/awrdemo/sections/s23_plan_flame.py`, `demo/verify_report.js` (block
6i), the three demo pages, `CLAUDE.md`, `CHANGELOG.md`, `plans/README.md`,
this file.

## Not covered

No finding or scoring; no `DBA_OPTSTAT_OPERATIONS`, baselines / profiles,
column statistics / histograms, partition-level rows, `CDB_` views, index
statistics history, fleet change. A plan of more than 60 lines lists all of
its lines' objects (not only the sampled ones). Unexercised: every database
path, a CDB-root run, partitioned objects, an index on another owner's
table, the error notes.

## Names to check on dbmint (DESC / SELECT DISTINCT)

Pages under https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/
(DBA_ views share the ALL_ page's columns, as each page states):
- `ALL_OBJECTS.html`: OWNER, OBJECT_NAME, SUBOBJECT_NAME, OBJECT_TYPE
  (VARCHAR2(23)), CREATED (DATE), LAST_DDL_TIME (DATE), STATUS (VALID /
  INVALID / N/A) confirmed.
- `ALL_TAB_STATISTICS.html`: OWNER, TABLE_NAME, PARTITION_NAME, OBJECT_TYPE
  (TABLE / PARTITION / SUBPARTITION), LAST_ANALYZED, NUM_ROWS, STALE_STATS
  (YES / NO), STATTYPE_LOCKED (DATA / CACHE / ALL) confirmed.
- `ALL_TAB_STATS_HISTORY.html`: OWNER, TABLE_NAME, PARTITION_NAME,
  SUBPARTITION_NAME, STATS_UPDATE_TIME (TIMESTAMP(6) WITH TIME ZONE)
  confirmed.
- `ALL_INDEXES.html`: OWNER, INDEX_NAME, TABLE_OWNER, TABLE_NAME, STATUS
  (VALID / UNUSABLE, nonpartitioned), VISIBILITY (VISIBLE / INVISIBLE),
  PARTITIONED, LAST_ANALYZED, NUM_ROWS confirmed.
- `DBA_HIST_SQL_PLAN.html`: OBJECT_TYPE (VARCHAR2(20)) confirmed; values not
  listed: `SELECT DISTINCT object_type FROM dba_hist_sql_plan`.
- Time zone: does `CAST(stats_update_time AS DATE)` equal `last_analyzed`
  for a table's latest gather (`SELECT ... FROM dba_tab_stats_history h JOIN
  dba_tab_statistics s ...`)? It must, or the interval test is off by the
  zone offset against AWR's wall clock.

## dbmint checklist (owner)

1. A plan-change run (find one: `"2026-11-08 11:00" 1 8 10 0 1 h` had
   b84c2ncqhcw23): rc 0, 31 / 31 `AWR-SECTION` pairs, no `ORA-` / `SP2-` /
   `PLS-`; Plan shape shows "Objects in these plans" and no "could not
   read" note (if one shows, its text names the wrong name).
2. From the CDB root (dbmint's usual connect): the objects of a PDB
   statement should read "not visible from this container"; run once in the
   PDB too and compare.
3. Cross-check one row: `SELECT last_analyzed, num_rows FROM
   dba_tab_statistics WHERE owner = :o AND table_name = :t AND object_type
   = 'TABLE'` and the stats history rows inside the stated interval.
4. Force an interval hit on a scratch table (gather statistics on it, run a
   statement twice with different plans) only if the owner wants it: the
   report itself must stay read-only.
5. verify_report on that report: block 6i `plan 047 {...}`, section 8.
6. A user without SELECT on the four views: rc 0, the "needs SELECT on"
   note, the plan tables still shown.
