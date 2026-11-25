# Plan 041: the peak inside the window, next to the average

Status: DONE; DB run pending (owner). Round 3, review item 3. Informational
only: no finding, count, pill or severity; nothing touches `policy_bucket`.

## Why (the DBA question)

"Was it bad for the whole hour, or for five minutes?" Every number in the
report is a window average (counter deltas / span, SYSMETRIC `AVERAGE`, ASH
samples / window). A five-minute stall at 40 active sessions is diluted to a
mild rise; a window whose average is normal can hide a short outage.

## Design as built

1. **System metrics (03)**: two cells after the band cells, "Peak (1 min)"
   and "vs prior peaks". `per_snap` adds `MAX(sm.maxval)` and
   `COUNT(DISTINCT sm.instance_number)`; `facts` takes their MAX per window;
   the final SELECT returns scalars only (`cur_peak`, `cur_inst`, `mu_peak`,
   `n_peak` over the valid prior windows): no per-window peak string, the
   existing CSVs untouched, the average aggregation untouched. Peak = the
   largest single-instance value for EVERY metric (a per-instance maximum is
   not additive); with more than one instance in the Current window the cell
   says "max per instance" (`data-pkinst`). The delta is
   `delta_span(cur_peak, mu_peak, NULL, 'Y')` (`s-plain`), the priors' mean in
   its title. `td.pk[data-pk]` carries the raw value (6 decimals).
2. **Busiest minute (09)**: the scan loop also fills `v_fm` (minute -> samples
   over every class). Per valid window inside the fine reach, the minute with
   the most samples (earliest on a tie) / 6. Emitted as `AWR_DATA.ashx.pk =
   [[week_offset, aas, "YYYY-MM-DD HH24:MI"], ...]` oldest first, between
   `winfg` and `fine` (lines flushed under 30000 bytes), `[k,null,null]` =
   unknown (skipped, outside the fine reach, no ASH at all), never 0; and as
   the always-emitted table `#ash-peaks` "Busiest minute per window"
   (window, start, average AAS, busiest minute, at, x the average), Current
   first, `data-nocount`, the reason in a muted span when unknown.
   **Deviation from the brief:** the timestamp is the full minute, not
   "HH24:MI" (daily / weekly windows of 24 h or more need the day); the table
   and the card show HH24:MI under 24-hour windows.
3. **Summary / Timeline** (`js_timeline` section 5b): pure
   `AWR_TL.pkInfo(pk, AWR_WIN.w)` + `pkText(i, wh)` (unit-tested). `pkCard()`
   appends `div.evr.ev-pk` to the DB time card's evidence list (last, after
   17's / 07's rows): "Busiest minute: 53.7 active sessions at 09:19; prior
   windows' busiest minutes 19.5-50.5" + a plain delta vs the priors' mean;
   only when `#f-dbtime` and a Current value exist; title "ASH, all sessions,
   one sample every 10 s ...". `pkTip(o)` adds "Busiest minute, all sessions:
   x AAS at hh:mm" to the window-stripe tooltip of both Activity charts. No
   Timeline lane row.
4. **About**: a "Peaks" note after "System metrics" (what each peak is, not
   scored, steps of 1/6, the RAC caveat).
5. **Demo twins**: s09 derives `pk` and the table from its synthetic minutes
   (same fine reach and tie rule); s03 synthesizes peaks = average x (1 +
   spread x (0.3 + 1.2 u)), u from the seeded `w.rng` (no libm), percentages
   capped at 100, AAS spread 1.2 so it sits near 09's busiest minutes; built
   in s03 (the shared `_pivot.row_cells` of 02 / 13 is unchanged).
6. **verify_report block 6d**: pk length / order / null for skipped windows;
   Current pk = the Current window's busiest minute recomputed from
   `ashx.fine` (classes summed per minute, / 6, same minute); `#ash-peaks`
   rows and Current cell agree; the card row exists <=> card + Current
   value, with no band and a plain delta; every 03 row (not "max per
   instance") has peak >= the Current average (last `data-spark` slot); a
   Current-stripe hover shows "Busiest minute". The demo must run all parts;
   a report without `pk` / peak cells skips them.

## Files touched

`sql/03_sysmetric.sql`, `sql/09_ash_timeline.sql`, `sql/19_reference.sql`,
`sql/lib/src/js_timeline.js` + generated `sql/lib/js_timeline.plsql` (header
lists pkInfo / pkText), `tools/js_unit_tests.js`,
`demo/awrdemo/sections/s03_sysmetric.py`, `s09_ash_timeline.py` (s19 lifts
the note), `demo/verify_report.js`, the three demo pages, `CLAUDE.md`,
`CHANGELOG.md`, `plans/README.md`, this file. No CSS change (`.evr`, `.tr2`,
`.d.s-plain`, `span.imm` exist).

## Not covered

- Peaks for LOAD (SYSSTAT) rows, wait events or Top SQL: counters have no
  inside-the-interval maximum in AWR.
- A peak per prior window as columns (string limits; Current + the priors'
  mean only). The Timeline has no peak row.
- SYSMETRIC peaks across instances are never combined; on RAC an ASH minute
  is cluster-wide while 03's peak is per instance (said in the note).
- A window partly cut by the fine cap (one window longer than 40000 minutes)
  gets the busiest minute of its covered part.
- 07's cards other than DB time, the dashboard's KPI cards, Copy summary and
  the findings JSON do not carry the peak.

## Names to check on dbmint (DESC / SELECT DISTINCT)

- `DBA_HIST_SYSMETRIC_SUMMARY.MAXVAL` (NUMBER, NOT NULL, "Maximum value
  observed"); `INSTANCE_NUMBER` (already read). 19c Database Reference 5.74
  `DBA_HIST_SYSMETRIC_SUMMARY`:
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SYSMETRIC_SUMMARY.html
  ("statistical summary of all metric values in the System Metrics Long
  Duration group"). The long-duration group is the 60-second one: 19c
  `V$SYSMETRIC` ("long duration (60-second) and short duration (15-second)")
  and `DBA_HIST_CON_SYSMETRIC_SUMM` ("long duration (60-second) group"),
  same reference. `DESC dba_hist_sysmetric_summary` should list `MAXVAL`.
- ASH: no new column (`sample_time`, `session_state`, ... already read).

## dbmint checklist (owner)

1. Hourly run, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h` (the blocking hour):
   rc 0, 29 / 29 `AWR-SECTION` pairs, no `ORA-` / `SP2-` / `PLS-`.
   System metrics has "Peak (1 min)" / "vs prior peaks"; every peak >= its
   Current average (single instance). Spot-check one metric:
   `SELECT MAX(maxval) FROM dba_hist_sysmetric_summary WHERE metric_name =
   'Average Active Sessions' AND snap_id BETWEEN <begin+1> AND <end>`.
2. Active sessions (All sections): "Busiest minute per window" has one row per
   window, skipped windows say "skipped window". Cross-check the Current row:
   `SELECT TRUNC(CAST(sample_time AS DATE), 'MI') m, COUNT(*) / 6 FROM
   dba_hist_active_sess_history WHERE sample_time >= <window start> AND
   sample_time < <end> AND (session_state = 'ON CPU' OR wait_class <> 'Idle')
   GROUP BY TRUNC(CAST(sample_time AS DATE), 'MI') ORDER BY 2 DESC`.
3. A run with a DB time card: the card's last evidence row reads "Busiest
   minute: ... active sessions at hh:mm; prior windows' busiest minutes a-b"
   and its delta has no colour; hover a window stripe in the Activity chart:
   "Busiest minute, all sessions".
4. 168 hourly windows (`... 1 168 10 0 1 h`) and a 15-minute cadence: the
   `pk` line(s) under 32767 bytes, table complete.
5. `verify_report` on the hourly report (block 6d prints `plan 041 {...}`).
6. `DESIGN=dashboard`: the card row inside the findings table's lead row.
