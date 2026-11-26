# Plan 042: CPU capacity -- "x of n CPUs"

Status: DONE; run on dbmint 2026-11-25 (commit `3ea5315`, see round3-dbmint-runbook.md). Round 3, review item 4 (first half;
host numbers are plan 046's). Informational only: no finding, count, pill
or severity; nothing touches `policy_bucket`.

## Why (the DBA question)

"Is 8.6 sessions on CPU a lot?" The report showed DB CPU and ASH "CPU" in
active sessions but never the number of CPUs, so 50 % busy and saturated
looked alike. It also never used the classic cross-check: ASH counts a
session ON CPU while it runs OR waits in the run queue, the time model's
`DB CPU` only the CPU actually used, so foreground ASH on CPU clearly above
DB CPU means sessions queued for a CPU.

## Design as built

1. **Section 09 computes and tabulates.** One more read inside 09's nested
   block (windows_cte + four CTEs): per VALID instance of each window,
   `cpu_count` at the END snapshot (`DBA_HIST_PARAMETER`, lowest `con_id`
   via `KEEP (DENSE_RANK FIRST ORDER BY con_id, con_dbid)` as section 12;
   `REGEXP_LIKE(value, '^[0-9]+$')` before `TO_NUMBER`) and the `DB CPU`
   delta (`DBA_HIST_SYS_TIME_MODEL`, 08's pairs -> bounds idiom); per window
   the sums, DB CPU / `MAX(dur_sec)` / 1e6 = AAS. A window is known only
   when every per-instance row of `windows` is valid (RAC: the ASH scan
   filters on `inst_num` only, so a partly valid window would compare all
   instances' ASH with fewer instances' DB CPU -- a false run queue).
   Payload `AWR_DATA.ashx.cpu = {n:[...], used:[...], cur:{n, used, pct,
   ash}}` between `pk` and `fine`, oldest first, `null` = unknown, lines
   flushed under 30000 bytes (no LISTAGG). `cur.ash` = `winfg`'s Current
   CPU value (foreground ASH), null unless the Current window is fully
   valid. Table `#ash-cpu` "CPU capacity per window" after `#ash-peaks`
   (`data-nocount`, Current first; window, start, cpu_count, DB CPU, % of
   cpu_count, ASH on CPU foreground, ASH minus DB CPU; reason in `span.imm`:
   "skipped window", "an instance skipped", "no cpu_count row", "no DB CPU
   row").
2. **Activity chart line** (`js_timeline` section 5c, `cpuMark`): on the
   by-wait-class chart only, both layouts and the compact Summary mode, a
   dashed `line.xcpu` at the Current `cpu_count` with `text.xcpt`
   "cpu_count 16" (", changed" when the windows' values differ) at its
   right end, above the line or below it when that leaves the plot or meets
   the highlight note. Drawn ONLY when `n <= ymax`; the y axis is never
   stretched. The line strip and the label box are passed to `dlab` as
   extra `avoid` boxes. Above the range, `span.axcpu` after `#ax-range`
   reads "cpu_count 64, above this scale" (`cpuHead`, updated on every
   class-chart draw: legend rescale, strong highlight re-fit, zoom). Without
   `ashx.cpu` both charts emit byte-identical SVG to before (checked against
   HEAD's demo page with the payload removed, 1440 / 390 px, All / Summary).
3. **DB time card row** (`cpuCard`): `div.evr.ev-cpu` "CPU" / "Capacity"
   after plan 041's "Peak" row: "DB CPU 8.6 of cpu_count 16 (54%)", then
   "; ASH saw 12.1 on CPU, so about 3.5 sessions were waiting for a CPU"
   when ASH exceeds DB CPU by >= 10 % AND >= 0.5 AAS, then "; CPU-bound" at
   >= 90 %. No delta, no band, no colour. Pure `AWR_TL.cpuInfo` / `cpuText`,
   unit-tested in `tools/js_unit_tests.js`.
4. **About** (`sql/19_reference.sql`): "CPU capacity" note (threads /
   instance caging, not the host's cores, other software and background CPU
   not in DB CPU, the run-queue cross-check, ASH is a 10-s sample).
5. **Demo twin** (`s09`): `CPU_COUNT = 16` local to the twin (the model's
   busiest hour has about 10 AAS of DB CPU and 25 AAS in all; the class
   chart's axis tops at 30, so the line shows at load and the note after
   hiding the large classes); DB CPU = the model's time-model `DB CPU` /
   the window's span (the card reads 8.6 of 16, 54 %, as 07's DB CPU row);
   ASH on CPU = `winfg`. The demo's ASH equals DB CPU, so no queue clause.
6. **verify_report block 6e**: payload shape (skipped windows null, `cur`
   = the last entries), `#ash-cpu` one row per window with Current = `cur`
   and no severity, the card row exists <=> card + `cur.n` + `cur.used`
   with the numbers and the queue / CPU-bound rule of `cur`, the line
   present <=> `n <= ymax` (ymax from the axis labels, pointer parked off
   the chart) after load, after hiding the largest classes until the axis
   drops below `n`, and after restoring them. The demo must hit both states.

## Files touched

`sql/09_ash_timeline.sql`, `sql/_style.sql` (`.ashx .xcpu`, `.xcpt`,
`.axcpu`), `sql/lib/src/js_timeline.js` + generated
`sql/lib/js_timeline.plsql` (header lists cpuInfo / cpuText),
`sql/19_reference.sql`, `tools/js_unit_tests.js`,
`demo/awrdemo/sections/s09_ash_timeline.py` (s19 lifts the note),
`demo/verify_report.js`, the three demo pages, `CLAUDE.md`, `CHANGELOG.md`,
`plans/README.md`, this file.

## Not covered

- Host CPUs, load average, OS busy time (`DBA_HIST_OSSTAT`: plan 046).
  CPU used by other databases or software on the host is invisible here.
- A per-window line: the chart draws the Current value only; a change
  across windows is said in the label (", changed") and in the card row's
  title, and section 12 lists the parameter change.
- PDB-level `cpu_count` (modifiable in a PDB, Resource Manager per PDB):
  the lowest `con_id` row is the instance's value, as in 12.
- No Timeline lane row, no dashboard KPI, Copy summary or findings JSON.
- Unexercised: RAC (summed `cpu_count`, the "an instance skipped" path),
  multi-DBID, a real run queue (the demo's ASH equals DB CPU; the rule is
  unit-tested), a CPU-bound database.

## Names to check on dbmint (DESC / SELECT DISTINCT)

- `DBA_HIST_PARAMETER`: `SNAP_ID`, `DBID`, `INSTANCE_NUMBER`,
  `PARAMETER_NAME` (VARCHAR2(64)), `VALUE` (VARCHAR2(512)), `CON_DBID`,
  `CON_ID` -- 19c Database Reference 5.17:
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_PARAMETER.html
  Parameter name `cpu_count`: the case of `PARAMETER_NAME` is not stated
  on the doc page (V$ parameter names are lower case in practice); the
  filter accepts `IN ('cpu_count', 'CPU_COUNT')`, because a wrong case
  would not abort, every row would just read "no cpu_count row". Check:
  `SELECT DISTINCT parameter_name FROM dba_hist_parameter WHERE
  LOWER(parameter_name) LIKE 'cpu%'`. Semantics (threads; instance caging;
  modifiable in a PDB): Reference 1.59 CPU_COUNT,
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/CPU_COUNT.html
- `DBA_HIST_SYS_TIME_MODEL`: `SNAP_ID`, `DBID`, `INSTANCE_NUMBER`,
  `STAT_NAME`, `VALUE` -- Reference 5.72:
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SYS_TIME_MODEL.html
  Statistic `DB CPU` ("Amount of CPU time (in microseconds) spent on
  database user-level calls ... does not include ... background
  processes"), Table 9-1 of V$SESS_TIME_MODEL:
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-SESS_TIME_MODEL.html
  (already read by 00 / 02 / 07 / 08 / 10).
- ASH: no new column.

## dbmint checklist (owner)

1. Hourly run, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h`: rc 0, 29 / 29
   `AWR-SECTION` pairs, no `ORA-` / `SP2-` / `PLS-` in the log.
2. Active sessions (All sections): "CPU capacity per window" has one row
   per window. Cross-check the Current row: `SELECT instance_number,
   con_id, value FROM dba_hist_parameter WHERE parameter_name =
   'cpu_count' AND snap_id = <end snap>` (the lowest con_id is the cell),
   and `SELECT (e.value - b.value) / 1e6 / <span s> FROM
   dba_hist_sys_time_model b JOIN dba_hist_sys_time_model e ON
   e.stat_name = b.stat_name AND e.instance_number = b.instance_number AND
   e.dbid = b.dbid WHERE b.stat_name = 'DB CPU' AND b.snap_id = <begin> AND
   e.snap_id = <end>` = the DB CPU cell (and the DB time card's DB CPU row).
3. The DB time card (a run that has one): "CPU / Capacity: DB CPU x of
   cpu_count n (p%)". The Activity chart: dashed "cpu_count n" line when n
   is under the axis top, else "cpu_count n, above this scale" in the header
   (dbmint is idle: expect the header note).
4. 168 hourly windows (`... 1 168 10 0 1 h`): the `cpu` lines under 32767
   bytes, the table complete; a run with a restart inside a window: that
   row reads "skipped window".
5. `verify_report` on the hourly report (block 6e prints `plan 042 {...}`).
