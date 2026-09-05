# SQL Monitor section — design notes (2026-09-05)

Status: phase 1 implemented 2026-09-05 (`sql/18_sqlmon.sql`, narrative R6-R9);
phase 2 (plan-line drift, opt-in `sqlmon_detail`) + the fleet band
(`sql/fleet/06b_sqlmon.sql`) implemented 2026-09-05. Census run against
dbmint (19.27) the same day; phase 2 + fleet band tested against a window
with a real Current + prior-window monitored execution the same session.

Implementation notes that differ from / refine the proposal below:
- Noise floor is at the sql_id level (any capture >= 1 s, errored, or >1 plan
  in the span includes the whole sql_id); the scatter ignores the floor.
- `new` = no capture anywhere in the span *before* the Current window starts
  (not "absent from the prior compared windows" — sparse capture makes that
  fire for statements that run all day).
- A sql_id whose every capture sits in a skipped window still gets a row
  (empty window cells) so its error flag and drill line survive.
- `key3` is parsed with `DEFAULT NULL ON CONVERSION ERROR`: other
  `component_name`s share the table and Oracle may evaluate the TO_DATE
  before the component filter.
- Scatter markers sit at their exact timestamp (real time axis), not snapped
  through `AWR_markLine`.

## Source data (verified on dbmint)

- `DBA_HIST_REPORTS` (`component_name='sqlmonitor'`): one row per persisted
  execution. `key1`=sql_id, `key2`=sql_exec_id, `key3`=sql_exec_start as
  `'MM:DD:YYYY HH24:MI:SS'` **string** (colons, US order — parse with that
  mask, don't trust it as a DATE). `report_summary` is a VARCHAR2 XML:
  ```
  /report_repository_summary/sql[@sql_id,@sql_exec_start,@sql_exec_id]
    status              DONE | DONE (ALL ROWS) | DONE (FIRST N ROWS) | DONE (ERROR)
    sql_text            first ~100 chars
    first/last_refresh_time, refresh_count
    inst_id, session_id, session_serial, user_id, user
    con_id, con_name, module, action, service, program
    plan_hash           (0 for PL/SQL blocks)
    is_cross_instance, dop, instances, px_servers_requested, px_servers_allocated
    stats[@type=monitor]/stat[@name=...]  (microseconds / counts):
      duration (s), elapsed_time, cpu_time, user_io_wait_time,
      application_wait_time, concurrency_wait_time, cluster_wait_time,
      plsql_exec_time, other_wait_time, user_fetch_count, buffer_gets,
      disk_reads, read_reqs, read_bytes, write_reqs, write_bytes
  ```
  Also `snap_id`, `instance_number`, `period_start/end_time`,
  `generation_time`, `con_dbid`, `con_id`. `dbid` is the CDB dbid, so the
  `dbid IN (dbid_list)` filter applies unchanged.
- `DBA_HIST_REPORTS_DETAILS`: **no `component_name` column** (join on
  `report_id`, `dbid`). `report` CLOB ~25–45 KB per execution on dbmint
  (`report_compressed` BLOB alongside). Root `<report>` →
  `<sql_monitor_report>` with `target` (plan_hash, full_plan_hash,
  servers_requested/allocated, optimizer_env), `stats`, `parallel_info`
  (per-PX-session stats), `plan` (`operation[@id,@name,@pos]` with `card`,
  `object`, …) and the per-line runtime stats block (exact XPath for
  starts/output rows/activity % still to be pinned — first guess returned
  NULL, see open items).
- Capture policy (hidden params on dbmint): cycle 60 s, `dbtime_percent_cutoff`
  50, timeband 1 h, recharge window 10. Practically: per minute MMON keeps the
  monitored executions that completed and account for ≥ the cutoff share of DB
  time; parallel statements are always monitored, so tiny 10-ms DOP-2 emagent
  queries dominate dbmint's set (3648 rows, Aug 11 → Sep 5, ~200–370/day).
- Retention = AWR retention. Multitenant: rows from both CDB$ROOT (3262) and
  PDB1 (386) are visible from the root.
- Drill: `DBMS_AUTO_REPORT.REPORT_REPOSITORY_DETAIL(rid=>report_id,
  type=>'TEXT'|'HTML'|'ACTIVE')` — read-only function, SELECT-able.

## Sampling caveats (must be stated in the section's caption)

- Only completed, "expensive enough" or parallel executions are persisted.
  Absence ≠ fast; row counts ≠ execution counts. Per-execution elapsed / IO /
  DOP / status are trustworthy; rates and counts are not — never z-score a
  count.
- An execution still running at `target_end` has no final report → the current
  window can under-report its slowest statement. Say so.
- Window attribution by `sql_exec_start` (parsed from key3); long executions
  can straddle windows.

## Proposed section 18 `sql/18_sqlmon.sql` — "SQL Monitor"

Template-independent (like 13–16), always on, summaries only (no CLOB).
Nav link + `AWR-SECTION` markers as every other section.

1. **Per-SQL comparison table** — for every sql_id captured in any compared
   window: per window `n captured`, `max elapsed`, `median elapsed`, `max IO
   bytes`, `DOP (req/alloc)`, distinct `plan_hash`, error count. Score
   `max elapsed` with section 07's `scored` CASE verbatim (Current vs prior
   windows). Sparkline of max elapsed across windows (`data-spark`, same
   LISTAGG-positional contract, `nth_csv`). Rows tagged `data-sys` via
   `is_oracle_schema.plsql` on `<user>` so "Application only" hides emagent /
   SYS noise (on dbmint that's nearly everything — good test of the toggle).
   Rank by Current-window max elapsed, `top_n` rows, rest behind an expander.
2. **Execution scatter over the full span** (ECharts, calendar axis, markers
   attach with the one-arg `AWR_markLine`): x = exec start, y = elapsed (log
   scale), color = sql_id (top-N) / grey other, symbol = plan_hash change or
   error, size ∝ DOP. Answers "one outlier or everything shifted", which
   06's SQLSTAT averages can't. Compared windows shaded like 09/10.
   Degrades via `body.no-charts`; the table carries every number.
3. **Flags feeding 07/17** (cheap, from the same cursor): plan_hash changed vs
   prior windows; DOP downgrade (`px_servers_allocated < requested`);
   `DONE (ERROR)` executions; sql_id first seen in Current. Emit as narrative
   rules R-sqlmon-1..4 in `17_narrative.sql` linking to `#sqlmon`.
4. **Drill line per row** — copyable `SELECT DBMS_AUTO_REPORT
   .REPORT_REPOSITORY_DETAIL(rid=>NNN, type=>'ACTIVE') FROM dual;` in a
   `.codewrap` with `.copy-btn`. No embedding (ACTIVE needs Oracle's CDN, HTML
   is huge).

## Phase 2 (opt-in, `sqlmon_detail=N`, default 0): plan-line drift -- IMPLEMENTED

For the top-N regressed sql_ids only (same noise-floor `included` set as
phase 1, `plan_hash <> 0`, a Current-window execution AND a prior-*valid*-
window execution; ranked by change bucket then Current max elapsed DESC):
pick one baseline execution (prior window, elapsed closest to the prior
median, tie -> most recent) and the Current window's slowest; `XMLTABLE`
both CLOBs' plan lines (see the verified XPath below); diff actual rows /
starts / duration / memory per `(line id, operation name+options,
owner.object)`; render "line 7 HASH JOIN: 10% -> 70% of execution time;
actual rows 1.2k -> 40M". Gated hard: 2 CLOBs x N sql_ids via `FETCH FIRST N
ROWS ONLY` on the candidate list, and each pair's CLOB read + XML parse is
wrapped in its own `BEGIN/EXCEPTION WHEN OTHERS` so a corrupt/oversized
report can never abort the run. `sql/17_narrative.sql` R10 recomputes just
the single top candidate (one CLOB pair, bounded regardless of N) and states
its lede when `sqlmon_detail>0`; at 0 no such query runs.

**Verified detail XML shape** (`DBA_HIST_REPORTS_DETAILS.report`, joined on
`report_id`+`dbid` -- no `component_name` column there): root
`/report/sql_monitor_report/plan_monitor/operation[@id,@parent_id,@name,
@options,@depth,@position,@skp,@px_type]`, with `object/owner` + `object/name`
(absent on non-object lines), `optimizer/cardinality` (estimated rows,
absent on some lines), and `stats[@type="plan_monitor"]/stat[@name=...]` for
`starts` / `cardinality` (ACTUAL rows) / `duration` (seconds) / `max_memory`
(bytes) / `dop` / `first_active` / `last_active` / `max_card` / `max_starts`.
**There is no activity-% / ASH block in the stored XML** (the first-guess
XPaths from the "Open items" below never existed), so the drift diff is
necessarily limited to starts/rows/duration/memory -- "duration share" (a
line's `duration` divided by the whole execution's `elapsed_time` from the
summary XML) stands in for the activity-% signal SQL Monitor's live report
shows. `plan_hash = 0` executions (PL/SQL blocks) have no plan lines and are
excluded as drift candidates by the `plan_hash <> 0` filter above.

## Fleet band -- IMPLEMENTED (`sql/fleet/06b_sqlmon.sql`)

Always on (no opt-in var; cheap DBA_HIST_REPORTS-only aggregates, no CLOB
reads ever). Emits `<!-- FLEET-COUNTS sqlmon cur=A span=B err=X planchg=Y
downgrade=Z -->`; informational only -- the assembler's scoring regexes
match only `FLEET-COUNTS findings` and `FLEET-COUNTS topsql`, so this
comment can never move the row score or sort order, same as the Day profile
band. `FLEET_SQLMON_DETAIL` (default 0) rides `sqlmon_detail` into the
optional per-DB detailed report ONLY, never the lean extract.

## Open items (resolved)

- ~~Pin the XPath for per-line runtime stats in the detail XML~~ -- pinned
  above; there is no `rwsstats`/`activity_sampled` block, only
  `stats[@type="plan_monitor"]`.
- ~~Decide whether tiny parallel executions get a floor filter~~ -- phase 1's
  sql_id-level floor (elapsed >= 1s OR error OR >1 plan) already covers this;
  phase 2 candidates are drawn from that same `included` set.
- ~~`key3` parse mask under a non-US NLS_DATE_LANGUAGE~~ -- confirmed safe,
  used verbatim by both phase 1 and phase 2 (`TO_DATE(key3 DEFAULT NULL ON
  CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS')`).
- Still open: verify `period_start_time` vs `sql_exec_start` for attribution
  on a long run (dbmint has none > 30 s) -- unchanged from phase 1, not
  exercised by phase 2 either.
