# Agent Handoff

This document is the working summary for the next agent who continues the Oracle APEX work in this repo.

It focuses on:

- what was actually deployed and validated
- what local environments exist right now
- how the runtime and collection flow works
- what was changed during live testing
- what remains incomplete

## Current State

The app is no longer just a scaffold.

It now exists in three forms:

1. Backend installer and PL/SQL implementation under `apex_app/sql/`
2. A live imported APEX application in the local APEX instance
3. A refreshed export at [f100.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/f100.sql) generated from the live instance after validation and page rebuilds

The live APEX app uses native APEX regions. Pages `1-10` are primarily Interactive Reports, and page `11` is now a real JET-chart visualization page for a selected run. It is structurally real, importable, and functional.

## Local Runtime Environment

### Local Oracle / APEX stack

- ORDS / APEX URL: [http://localhost:8023/ords/apex](http://localhost:8023/ords/apex)
- APEX app URL: [http://localhost:8023/ords/r/awr_trend/awr_trend_central/login](http://localhost:8023/ords/r/awr_trend/awr_trend_central/login)
- ORDS is served from Docker container `23cfree`
- Docker image: `container-registry.oracle.com/database/free:latest`
- Database listener on host: `localhost:8521 -> container 1521`
- Database service used locally: `FREEPDB1`

### Local database / workspace users

- APEX workspace: `AWR_TREND`
- APEX developer user: `AWRADMIN`
- APEX developer password: `AwrTrend2026#Dev1`
- Parsing schema: `AWR_APEX`
- Schema password: `AwrApex2026#Local1`

### Existing local validation target

A loopback target was created against the same local container DB.

- Target name: `LOCAL_FREEPDB1`
- DB link: `FREEPDB1_AWR`
- Remote user: `AWR_MON`
- Remote password: `AwrMon2026#Local1`

This was used to validate that collection and UI wiring worked end-to-end.

## Remote Target Added During This Session

The user provided a remote database:

- service: `cdb1`
- host: `192.168.178.90`
- port: `11521`
- bootstrap login used for setup: `sys/password as sysdba`

### Remote read-only collector user

A dedicated common user was created on the remote CDB:

- user: `C##AWR_MON`
- password: `AwrMon2026#Remote1`

Granted:

- `CREATE SESSION`
- `SELECT` on:
  - `SYS.DBA_HIST_SNAPSHOT`
  - `SYS.DBA_HIST_SYSSTAT`
  - `SYS.DBA_HIST_SYSTEM_EVENT`
  - `SYS.DBA_HIST_BG_EVENT_SUMMARY`
  - `SYS.DBA_HIST_SYSMETRIC_SUMMARY`
  - `SYS.DBA_HIST_SQLSTAT`
  - `SYS.DBA_HIST_SQLTEXT`
  - `SYS.V_$DATABASE`

### Local DB link for remote target

- DB link name: `CDB1_AWR`
- local owner: `AWR_APEX`
- connect string used: `//192.168.178.90:11521/cdb1`

### Registered APEX target

- target name: `CDB1_192.168.178.90`
- `TARGET_ID = 2`

## Runtime / Deployment Logic

The runtime flow is:

1. Target exists in `AWR_APP_TARGETS`
2. A run is submitted via `AWR_APP_RUN_API.SUBMIT_RUN`
3. A row is created in `AWR_TREND_RUNS`
4. Execution is done by `AWR_APP_RUN_API.EXECUTE_RUN`
5. Collector calls in order:
   - `PURGE_RUN_DATA`
   - `INITIALIZE_RUN`
   - `COLLECT_WINDOWS`
   - `COLLECT_LOAD_PROFILE`
   - `COLLECT_SYSMETRIC`
   - `COLLECT_WAITS`
   - `COLLECT_TOP_SQL`
   - `COLLECT_FINDINGS`
6. All APEX pages read only local repository data, never remote DB links directly

## Current Page Inventory

- `1` Home
- `2` Runs
- `3` Run Overview
- `4` Findings Explorer
- `5` Metrics Dashboard
- `6` Waits Dashboard
- `7` Top SQL Explorer
- `8` Targets Admin
- `9` Schedules Admin
- `10` Run Log
- `11` Run Visualizations

### Page 11 details

Page `11` / alias `RUN_VISUALIZATIONS` was added after the original `1-10` native-page rebuild.

It contains:

- `P11_RUN_ID` selector item
- quick navigation buttons back to overview/findings/metrics/waits/top SQL/log
- JET chart regions:
  - `Findings By Domain`
  - `Window Health`
  - `Key Load Trend`
  - `Wait Class Trend`
  - `Strongest Deviations`
- a `Run Snapshot` Interactive Report at the bottom

Page `3` now includes an `OPEN_VISUALIZATIONS` button that redirects to page `11` for the current run.

### Important repository objects

- `AWR_TREND_RUNS`
- `AWR_TREND_WINDOWS`
- `AWR_TREND_LOAD_PROFILE`
- `AWR_TREND_SYSMETRIC`
- `AWR_TREND_WAITS`
- `AWR_TREND_TOP_SQL`
- `AWR_TREND_FINDINGS`
- `AWR_APP_TARGETS`
- `AWR_APP_SCHEDULES`
- `AWR_APP_RUN_LOG`

### Main APEX-facing views

- `AWR_APP_TARGET_STATUS_V`
- `AWR_APP_RUN_SUMMARY_V`
- `AWR_APP_METRIC_SERIES_V`
- `AWR_APP_TOP_SQL_V`
- `AWR_APP_RUN_LOG_V`

## Live Validation Performed

### APEX import / app validation

The app export was imported into the live local APEX instance and validated in metadata.

The final page shape in the live instance is:

- Page 1: `Target Status` as `Interactive Report`
- Page 2: `Recent Runs` as `Interactive Report`
- Page 3: `Run Summary` and `Aligned Windows` as `Interactive Report`
- Page 4: `Findings` as `Interactive Report`
- Page 5: `Metric Series` as `Interactive Report`
- Page 6: `Wait Events` as `Interactive Report`
- Page 7: `Top SQL` as `Interactive Report`
- Page 8: `Target Registry` as `Interactive Report`
- Page 9: `Schedules` as `Interactive Report`
- Page 10: `Log Entries` as `Interactive Report`

The app is real APEX now, but still very report-oriented. It is not yet a polished cards / JET chart application.

### Successful local validation runs

Local loopback target:

- `RUN_ID = 3`
- status: `OK`

### Successful remote validation runs

Remote target `CDB1_192.168.178.90`:

- `RUN_ID = 6`
  - `1` hour current-window run
  - status: `OK`
  - loaded:
    - `26` load profile rows
    - `23` sysmetric rows
    - `28` waits rows
    - `40` top SQL rows
    - `57` findings rows

- `RUN_ID = 8`
  - broader comparison run
  - target end: `2026-04-09 16:00:00`
  - `4` hour window
  - `2` weekly offsets back
  - `top_n = 20`
  - status: `OK`
  - valid windows: `3`
  - loaded:
    - `78` load profile rows
    - `69` sysmetric rows
    - `145` waits rows
    - `240` top SQL rows
    - `58` findings rows

### Important failed runs and why they matter

- `RUN_ID = 4`
  - failed due to remote LOB locator issue in top SQL collection
- `RUN_ID = 5`
  - failed due to duplicate `RANK_IN_WINDOW` values in top SQL
- `RUN_ID = 7`
  - technically `OK`, but all windows invalid because the chosen weekly comparison windows had no usable snapshot coverage and one current-period restart

These failures led directly to code fixes listed below.

## Code Changes Made During Live Testing

### `AWR_APP_RUN_API`

File:

- [awr_app_run_api.pkb](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/sql/packages/awr_app_run_api.pkb)

Changes made:

- moved `current_requester` / `current_source` evaluation into PL/SQL variables before the `INSERT`
- moved `SQLERRM` handling into local variables before `UPDATE` statements

Reason:

- Oracle rejected local PL/SQL functions and `SQLERRM` usage directly inside SQL statements

### `AWR_APP_COLLECT_PKG`

File:

- [awr_app_collect_pkg.pkb](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/sql/packages/awr_app_collect_pkg.pkb)

Changes made:

1. Fixed top SQL join shape to avoid `ORA-01799`
2. Removed remote `SQL_TEXT` fetch from `DBA_HIST_SQLTEXT` because of remote CLOB locator failure `ORA-22992`
3. Switched top SQL ranking from `RANK()` to `ROW_NUMBER()` to avoid PK collisions on `(RUN_ID, WEEK_OFFSET, DIMENSION, RANK_IN_WINDOW)`

Current consequence:

- `AWR_TREND_TOP_SQL.SQL_TEXT_SHORT` is currently stored as `NULL`
- top SQL rankings and numeric deltas still collect correctly

This is the main known compromise in the collector right now.

## APEX Export / Patch Scripts

These files were used to rebuild the live app pages and are kept as local operational artifacts:

- [patch_page2_native_ir.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/patch_page2_native_ir.sql)
- [patch_pages_1_3_native.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/patch_pages_1_3_native.sql)
- [patch_pages_4_10_native.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/patch_pages_4_10_native.sql)

They were applied against the live app, then the application was exported again to:

- [f100.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/f100.sql)

SQLcl export command that worked:

```text
apex export -applicationid 100 -exporiginalids -dir /Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex -overwrite-files -skipexportdate
```

## What Is Still Incomplete

### UI / UX

The app is structurally native APEX, but not yet a polished interactive dashboard.

Still missing:

- real Oracle JET chart regions for metrics and waits
- cards region on Home instead of report-only presentation
- modal SQL detail experience
- editable Interactive Grids or proper forms for Targets / Schedules
- richer navigation and filters

### Collector quality

Still missing:

- safe remote SQL text retrieval for `AWR_TREND_TOP_SQL.SQL_TEXT_SHORT`
- better handling for sparse-history targets
- more robust window matching when restart / snapshot gaps exist
- findings logic that is more useful with only 2 prior windows

### Scheduling

The scheduling package exists and page `9` has the sync action, but recurring scheduling against the remote target was not configured in this session.

## Recommended Next Steps

If another agent picks this up, the highest-value order is:

1. Convert Home, Metrics, and Waits into true APEX visual pages:
   - cards for Home
   - JET charts for metrics and waits
2. Turn Targets and Schedules into editable admin pages
3. Restore SQL text display safely:
   - either pre-stage remote SQL text into a helper object
   - or fetch text outside the direct remote CLOB path
4. Add a scheduling UX and define at least one recurring run for target `2`
5. Improve findings logic for low-history targets

## Practical Notes For Another Agent

- The user is an Oracle DBA, not an APEX developer. Prefer concrete DBA-style instructions over APEX jargon.
- The live app in the local container is the source of truth right now, not the original scaffold.
- If page edits are made in the live app, re-export `f100.sql` immediately so the repo stays aligned.
- Do not assume the latest run is the best run for remote target `2`. `RUN_ID = 8` is the best broad validated comparison from this session.
- `RUN_ID = 7` is an example of a formally successful but analytically useless run because all windows were invalid.

## Context Summary

This repo started with a backend-heavy APEX scaffold.

During this session, the following happened:

- local APEX and DB were discovered and used directly
- schema `AWR_APEX` and workspace `AWR_TREND` were created
- the app export was imported and validated live
- the placeholder PL/SQL UI regions were replaced with native Interactive Report pages
- the app was re-exported from the live instance
- a remote target at `192.168.178.90:11521/cdb1` was onboarded through a dedicated DB link user
- the collector package was debugged against real remote AWR data until remote runs succeeded

If another agent needs a stable baseline to continue from, use:

- app `100`
- workspace `AWR_TREND`
- parsing schema `AWR_APEX`
- target `CDB1_192.168.178.90`
- reference run `8`
