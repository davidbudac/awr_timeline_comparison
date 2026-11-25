# Plan 045: "Who added the load" -- a new section 29

Status: DONE; DB run pending (owner). Round 3, review item 6.
Informational only: no finding, count, pill or severity; nothing touches
`policy_bucket` or `metric_policy.plsql`.

## Why (the DBA question)

"Which application, service, host or user is behind the extra active
sessions?" The report split the extra DB time by wait class (verdict),
wait event (Activity charts) and statement (Top SQL; 06 groups its top-N
statements by schema / module / action). Nothing answered WHO for the
whole workload, statements outside every top N included. ASH carries the
service, module, machine, program, user and container of every sample.

## Design as built

1. **New section** `sql/29_who.sql`, `section#who.vw.in-s.in-a.lib`
   (`--os:19`), driver right after 28 (with its `debug_log` line), rail
   Diagnosis link (`data-nodot`), All-sections order 5 (DOM after 28),
   demo `SECTIONS` slot. CSS `sql/lib/src/css_who.css` ->
   `css_who.plsql` via `viz_head.sql`; no client script (plain HTML
   tables + CSS bars: works with JS off and in every design).
2. **One ASH scan**: `valid_windows` joined per instance (24's snap range +
   sample time), `session_type = 'FOREGROUND'`, 09's non-idle predicate,
   `inst_num`, `dbid IN (dbid_list)`. Grouped to (window, 6 keys) first,
   then a 6-row generator (not GROUPING SETS). Per dimension
   `DENSE_RANK` by samples over all windows keeps 40 values; the rest is
   one "(n others)" value. Fetch <= 6 x 41 x (weeks_back + 1) rows.
3. **Program folding** in the SQL, before the cut: `REGEXP_REPLACE(program,
   '\(([A-Z])([0-9]{3}|[A-Z][0-9]{2})\)$', '(\1nnn)')` -- `(P003)`,
   `(J001)`, `(PZ99)` -> `(Pnnn)` / `(Jnnn)`; `(TNS V1-V3)` untouched.
   Twin `norm_program` in `s29_who.py`. (The brief asked for "one small
   function": a block-local PL/SQL function cannot be called from SQL, and
   folding after the cut would let 80 PX slaves take the 40 slots.)
4. **Numbers**: AAS = samples / (360 x win_hours); a sample counts toward
   every window holding it; valid windows only (a valid window with no
   sample for a value = 0, a skipped one = an empty Trend slot). Rise =
   Current - mean of the valid prior windows, the same denominator for
   every value, so a dimension's rises sum to the total rise. Per
   dimension: the 8 largest positive rises in the table, the rest in
   `details.who-more` "+ n more" (nothing rose: the 8 largest by Current).
   Columns: value (`DBMS_XMLGEN.CONVERT`), Current, prior mean, rise, plain
   delta, share of the total rise (number + bar, `data-shr` 0..100), Trend
   (`data-spark`, PL/SQL loop, no LISTAGG); `tfoot` "All foreground".
   Row ids `anchor_uniq(anchor_id('who', '<code>-<name>'))`; tables
   `data-nocount`, no crit / warn class, no band.
5. **Names**: users through `ALL_USERS` (24's `usr_name`); service names
   (`DBA_HIST_SERVICE_NAME`) and PDB names (`DBA_HIST_PDB_INSTANCE`, the
   latest `open_time` per `con_id`) are OPTIONAL grants: dynamic SQL in an
   ORA-00942 / ORA-01031 handler, lint 35, README optional block. Without
   them: "service hash n", "con_id n" and a "needs SELECT on" sentence in
   the method note. PDB dimension only when more than one `con_id` shows.
6. **Reads as / library row / lopen**: skipped Current, no samples, fewer
   than 3 valid priors, no rise, a rise under 0.1 AAS each say so. Else the
   total rise, then per dimension the value (not "others") carrying >= 50%
   ("+6.843 of it came from service ORDERS_SVC; module OrderService
   +6.570; ..."), the others "spread" with their largest. `lopen` exactly
   when such a value exists.
7. **DB time card row**: module, else service, machine, user (a real name:
   no placeholder, no "others") carrying >= 30% of a rise >= 0.1 AAS ->
   `div#who-ev-src` + the plan 043 one-line append script ->
   `#f-dbtime dl.ev .evr.ev-who` "Who: module OrderService +6.570 AAS (73%
   of the rise in foreground activity)", plain delta, hollow dot, "not
   scored", link to the row. It lands before 02's time model row.
8. **About** note "Who added the load" (`19_reference.sql`).
9. **Demo twin** `s29_who.py`: each hour's foreground count is exactly
   s09's, split over 14 fixed clients by largest remainder (statements'
   ASH by module / schema, the residual by fixed shares); window totals =
   `ashx.winfg`. The story: OrderService doubles after Release 4.2 (+6.6 of
   +9.0 AAS), LoyaltyService since 4.1; the two OrderService app servers
   share it, so machine reads "spread".
10. **verify_report** block 6g (sums of Current and rise per dimension vs
    the stated total, shares 0..100, no severity, 09 winfg Current match,
    the card row both ways, lopen both ways, JS off) and section 8 (`who`
    added, optional for older reports).

## Files touched

`sql/29_who.sql` (new), `sql/lib/src/css_who.css` + generated
`sql/lib/css_who.plsql`, `sql/lib/viz_head.sql`, `awr_trend.sql`,
`sql/00_params.sql` (rail), `sql/_style.sql` (All order), `sql/19_reference.sql`,
`lint.sh` (35), `README.md`, `demo/awrdemo/sections/s29_who.py` (new),
`s00_params.py`, `demo/gen_demo_report.py`, `demo/verify_report.js`, the
three demo pages, `CLAUDE.md`, `CHANGELOG.md`, `plans/README.md`, this file.

## Not covered

No finding, scoring, Timeline lane, filter, `sql_id` / action dimension,
fleet change. Unexercised: RAC (per-instance validity), multi-DBID, a CDB
with several PDBs, the missing-grant notes, more than 40 values, the
skipped-Current / no-sample / few-priors sentences (the demo shows the
attributed case only).

## Names to check on dbmint (DESC / SELECT DISTINCT)

- `DBA_HIST_ACTIVE_SESS_HISTORY` (19c Reference,
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_ACTIVE_SESS_HISTORY.html):
  `SNAP_ID`, `DBID`, `INSTANCE_NUMBER`, `SAMPLE_TIME` TIMESTAMP(3),
  `SESSION_TYPE` VARCHAR2(10) (FOREGROUND / BACKGROUND), `USER_ID`,
  `SERVICE_HASH` NUMBER, `PROGRAM` VARCHAR2(64), `MODULE` VARCHAR2(64),
  `MACHINE` VARCHAR2(64), `CON_ID`; `SESSION_STATE`, `WAIT_CLASS` as
  section 09 uses them. Confirmed on that page.
- `DBA_HIST_SERVICE_NAME` (https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SERVICE_NAME.html):
  `DBID`, `SERVICE_NAME_HASH`, `SERVICE_NAME`, `CON_ID`. Confirmed.
  **Not confirmable from the docs:** that ASH `SERVICE_HASH` joins to
  `SERVICE_NAME_HASH`. Check: `SELECT a.service_hash, s.service_name,
  COUNT(*) FROM dba_hist_active_sess_history a LEFT JOIN
  dba_hist_service_name s ON s.dbid = a.dbid AND s.service_name_hash =
  a.service_hash WHERE a.session_type = 'FOREGROUND' GROUP BY
  a.service_hash, s.service_name` -- no NULL name expected.
- `DBA_HIST_PDB_INSTANCE` (https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_PDB_INSTANCE.html):
  `DBID`, `CON_ID`, `PDB_NAME` VARCHAR2(128), `OPEN_TIME`. Confirmed.
- The program suffixes the fold assumes: `SELECT
  REGEXP_SUBSTR(program, '\([^)]+\)$') s, COUNT(*) FROM
  dba_hist_active_sess_history WHERE session_type = 'FOREGROUND' GROUP BY
  REGEXP_SUBSTR(program, '\([^)]+\)$') ORDER BY 2 DESC`.

## dbmint checklist (owner)

1. Hourly run, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h`: rc 0, **30 / 30**
   `AWR-SECTION` pairs (29_who is new), no `ORA-` / `SP2-` / `PLS-`.
2. All sections > Who added the load: service names resolved (not
   hashes); cdb1 has PDBs -- does the PDB table show, with names? A
   cross-check: `SELECT module, COUNT(*) / 360 FROM
   dba_hist_active_sess_history WHERE session_type = 'FOREGROUND' AND
   (session_state = 'ON CPU' OR NVL(wait_class, 'x') <> 'Idle') AND
   sample_time >= <Current start> AND sample_time < <end> GROUP BY module`
   = the Module table's Current column.
3. verify_report on that report: block 6g `plan 045 {...}`, `ash` should be
   ok (info only when a RAC instance's window was skipped).
4. A run as a user without SELECT on `DBA_HIST_SERVICE_NAME`: rc 0, the
   note, hashes shown.
5. 168 hourly windows (`... 1 168 10 0 1 h`): every line < 32767 bytes
   (the Trend CSV is about 9 bytes a window), section time in the debug
   markers.
