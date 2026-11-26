# Plan 046: host, memory, undo and temp -- a new section 30

Status: DONE; run on dbmint 2026-11-25 (commit `3ea5315`, see round3-dbmint-runbook.md). Round 3, review items 4 (host half)
and 8. Informational only: no finding, count, pill or severity; nothing
touches `policy_bucket` or `metric_policy.plsql`.

## Why (the DBA questions)

1. Was the HOST out of CPU or swapping, and was it this database? (plan 042
   gave DB CPU against `cpu_count`, nothing about the host.)
2. Did memory change under the workload (a smaller buffer cache explains
   more physical reads; PGA over-allocation explains temp and paging)?
3. Any ORA-01555 or undo pressure?
4. Which statement used the temp space / the PGA?

## Design as built

- `sql/30_host_memory.sql`, `section#host-memory.vw.in-s.in-a.lib`
  (`--os:20`), driver right after 13 (with its `debug_log` line), rail link
  next to Utilization (`data-nodot`), All-sections order 18 (DOM after
  13), CSS `sql/lib/src/css_hostmem.css` via `viz_head.sql`, no script.
  `AWR-SECTION` pairs 30 -> 31.
- A window is KNOWN only when every instance row is valid (plan 042's
  rule); unknown = empty slot, never 0, not in the mean.
- Four blocks, each an h3 + a table in section 13's style (Current, band
  cells with a NULL bucket, plain delta, Trend, one column per prior
  window): **Host CPU and paging**, **Memory** (+ resize operations of the
  Current window), **Undo** (+ the longest query's sql_id),
  **Temp and PGA by statement** (peaks + Current top 5 by temp and by PGA,
  each with the median of its prior per-window maxima).
- Every optional view is read through dynamic SQL with binds, per known
  instance row, in its own handler: -942 / -1031 -> "needs SELECT on
  <view>", ANY other error -> "could not read <view>: <message>"
  (deliberate exception: cosmetic numbers must not abort the report).
  All reads happen before any markup.
- Container fan-out: OSSTAT / PGASTAT / MEM_DYNAMIC_COMP lowest `con_id`
  wins (`KEEP (DENSE_RANK FIRST ORDER BY NVL(con_id, 0))`); UNDOSTAT rows
  deduped per (begin_time, con_id) then SUMMED over containers (local
  undo: one undo tablespace per PDB). Check on dbmint (below).
- ASH temp / PGA: a statement's value at a sample = the sum over its
  sessions (PX slaves together); window value = the largest such sum; the
  peak = the largest total at one sample instant, per instance summed.
- "Reads as:" + `lib_ls` from the readable blocks. `lopen` (fixed rules,
  `section[data-open]` names them): host busy >= 90%, a swap-out of at
  least `c_swap` = 0.01 MB/s in the Current window (about 36 MB an hour;
  the first dbmint pass read "swapping" at 0.000026 MB/s), host
  CPUs / memory changed, a resize op in Current, buffer cache <= 90% of the
  prior mean, PGA over-allocation > 0, ORA-01555 or out-of-space > 0.
- Card pointers (one hidden source + one append script, plan 043's
  pattern): `#f-io` "Memory: buffer cache x GB, was y GB" (buffer cache
  rule); `#f-dbtime` "Host: host CPU n% busy" (>= 90%) and "Host:
  swapping" (VM_OUT >= c_swap). Both kept: together they cost one script.
  The sentence: "swapping, x MB/s paged out" at or above `c_swap`, "little
  paging out (x MB/s)" below it and above 0, "no swapping" at 0; `lib_ls`
  names "swapping" only at or above it. The table row is unchanged.
- "Host resized" (`p.hm-chg`, the sentence) names each window by its START
  with the time, "between Sat 07 Nov 11:00 and Sat 07 Nov 15:00"
  (`Dy DD Mon HH24:MI`, English): hourly windows all read the same day.

## Classification (gauge / counter / configuration)

| Source | Name | Kind | Read |
|---|---|---|---|
| OSSTAT | BUSY_TIME, IDLE_TIME, USER_TIME, SYS_TIME, NICE_TIME, IOWAIT_TIME, RSRC_MGR_CPU_WAIT_TIME | counter (1/100 s, over all CPUs) | end - begin, summed over instances |
| OSSTAT | VM_IN_BYTES, VM_OUT_BYTES | counter (bytes) | end - begin, per second |
| OSSTAT | LOAD | gauge | end snapshot, max over instances |
| OSSTAT | FREE_MEMORY_BYTES | gauge | end snapshot (only when reported) |
| OSSTAT | NUM_CPUS, NUM_CPU_CORES, NUM_CPU_SOCKETS, PHYSICAL_MEMORY_BYTES | configuration | end snapshot, change across windows |
| PGASTAT | total PGA allocated, total PGA inuse | gauge | end snapshot |
| PGASTAT | aggregate PGA target parameter | configuration | end snapshot |
| PGASTAT | over allocation count | counter (since startup) | end - begin |
| PGASTAT | cache hit percentage, maximum PGA allocated | since startup | left out |
| MEM_DYNAMIC_COMP | CURRENT_SIZE of the components | gauge | end snapshot |
| MEMORY_RESIZE_OPS | GROW / SHRINK rows | events | START_TIME in Current |
| UNDOSTAT | UNDOBLKS, TXNCOUNT, SSOLDERRCNT, NOSPACEERRCNT | per 10-min row | summed over overlapping rows |
| UNDOSTAT | MAXQUERYLEN (+ MAXQUERYSQLID), MAXCONCURRENCY | per-row maxima | max |
| UNDOSTAT | TUNED_UNDORETENTION | per-row gauge | min |
| ASH | TEMP_SPACE_ALLOCATED, PGA_ALLOCATED | per-sample gauge | see above |

## Files touched

New: `sql/30_host_memory.sql`, `sql/lib/src/css_hostmem.css` +
`sql/lib/css_hostmem.plsql`, `demo/awrdemo/sections/s30_host_memory.py`,
this file. Edited: `awr_trend.sql`, `sql/00_params.sql` (rail),
`sql/_style.sql` (All order), `sql/lib/viz_head.sql`, `sql/19_reference.sql`
(About note), `lint.sh` (35), `README.md`, `s00_params.py`,
`demo/gen_demo_report.py`, `demo/verify_report.js` (block 6h, section 8),
the three demo pages, `CLAUDE.md`, `CHANGELOG.md`, `plans/README.md`.

## Not covered

No finding, scoring, Timeline lane, fleet change, V$ view,
`DBA_HIST_SGASTAT` pools, alert log. `OS_CPU_WAIT_TIME`, `NUM_VCPUS` /
`NUM_LCPUS` not read. The demo fires no card pointer and no `lopen` (a
scratch variant did, see verify). Unexercised: every database path, RAC,
multi-DBID, per-container rows, a resize op, the error notes.

## Names to check on dbmint (DESC / SELECT DISTINCT)

Pages under https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/
- `DBA_HIST_OSSTAT.html`: SNAP_ID, DBID, INSTANCE_NUMBER, STAT_NAME, VALUE,
  CON_ID. Statistic names and units from `V-OSSTAT.html` (Table 8-3):
  all confirmed except **FREE_MEMORY_BYTES (not in the 19c Reference)**.
  The page does not say which statistics are CUMULATIVE:
  `SELECT stat_name, cumulative, comments FROM v$osstat`.
- `DBA_HIST_PGASTAT.html` / `V-PGASTAT.html`: NAME, VALUE, CON_ID; the four
  names confirmed (over allocation count "cumulative since instance startup").
- `DBA_HIST_MEM_DYNAMIC_COMP.html`: COMPONENT, CURRENT_SIZE, CON_ID
  confirmed. **Component names are not listed in the Reference**; only
  'DEFAULT buffer cache' appears in the Administrator's Guide (6.5.2). The
  match is case-insensitive: `SELECT DISTINCT component FROM
  dba_hist_mem_dynamic_comp`.
- `DBA_HIST_MEMORY_RESIZE_OPS.html`: COMPONENT, OPER_TYPE, OPER_MODE,
  INITIAL_SIZE, TARGET_SIZE, FINAL_SIZE, STATUS, START_TIME (DATE),
  END_TIME (DATE), CON_ID confirmed.
- `DBA_HIST_UNDOSTAT.html`: BEGIN_TIME / END_TIME (DATE), UNDOBLKS,
  TXNCOUNT, MAXQUERYLEN, MAXQUERYSQLID, MAXCONCURRENCY, SSOLDERRCNT,
  NOSPACEERRCNT, TUNED_UNDORETENTION, CON_ID confirmed.
- `DBA_HIST_ACTIVE_SESS_HISTORY.html`: TEMP_SPACE_ALLOCATED, PGA_ALLOCATED
  (bytes), SQL_ID, SAMPLE_ID, SAMPLE_TIME confirmed (static SQL).
- Fan-out: `SELECT con_id, COUNT(*) FROM <view> WHERE snap_id = <end> GROUP
  BY con_id` for OSSTAT, PGASTAT, MEM_DYNAMIC_COMP and UNDOSTAT; does
  UNDOSTAT carry one row per PDB per 10 minutes (then the sum is right) or
  a con_id 0 total besides them (then it double counts)?
- Duplicates: `SELECT begin_time, COUNT(*) FROM dba_hist_undostat GROUP BY
  begin_time HAVING COUNT(*) > 1` (captured once per snapshot?).

## dbmint checklist (owner)

1. Hourly run (`"2026-11-08 15:00" 1 8 10 0 1 h`): rc 0, **31 / 31**
   `AWR-SECTION` pairs, no `ORA-` / `SP2-` / `PLS-`; no "could not read"
   note in Host and memory (if one shows, its text names the wrong name).
2. Cross-check the Current row "Host CPU busy" with `SELECT stat_name,
   value FROM dba_hist_osstat WHERE snap_id IN (<begin>, <end>) AND
   stat_name IN ('BUSY_TIME', 'IDLE_TIME')`; buffer cache with the end
   snapshot's `dba_hist_mem_dynamic_comp` row; ORA-01555 with
   `SUM(ssolderrcnt)` of the window's `dba_hist_undostat` rows.
3. Is busy = user + system + nice on dbmint (verify_report prints it as
   info on a real report)?
4. verify_report on that report: block 6h `plan 046 {...}`, section 8.
5. A user without SELECT on the five views: rc 0, five "needs SELECT on"
   notes, the ASH block still shown.
6. 168 hourly windows: every line < 32767 bytes, section time in the
   debug markers (about 5 x 169 small dynamic queries).
