# Architecture

## Goal

Provide a central Oracle APEX application that orchestrates AWR timeline comparisons across multiple monitored databases and stores all results in one repository schema.

## Runtime flow

1. A user selects a target in APEX and submits a run.
2. APEX calls `AWR_APP_RUN_API.SUBMIT_RUN(...)`.
3. The app immediately calls `AWR_APP_RUN_API.ENQUEUE_RUN(...)` for async execution.
4. The scheduler job invokes `AWR_APP_RUN_API.EXECUTE_RUN(...)`.
5. `EXECUTE_RUN` calls the collector package in order:
   - `PURGE_RUN_DATA`
   - `INITIALIZE_RUN`
   - `COLLECT_WINDOWS`
   - `COLLECT_LOAD_PROFILE`
   - `COLLECT_SYSMETRIC`
   - `COLLECT_WAITS`
   - `COLLECT_TOP_SQL`
   - `COLLECT_FINDINGS`
6. Each collector step reads remote AWR data through the configured DB link and persists results into the local `AWR_TREND_*` tables.
7. APEX pages query only local repository tables and views.

## Schema roles

- `AWR_TREND_*`
  Fact repository reused from the original toolkit. These tables hold one run plus all derived facts.
- `AWR_APP_TARGETS`
  Registry of monitored databases and their DB links.
- `AWR_APP_SCHEDULES`
  Recurring run definitions that materialize into `DBMS_SCHEDULER` jobs.
- `AWR_APP_RUN_LOG`
  Step-level execution log for APEX diagnostics.

## Package responsibilities

- `AWR_APP_RUN_API`
  Public entrypoint for manual runs, async job submission, and schedule execution.
- `AWR_APP_COLLECT_PKG`
  Remote-aware collector logic that mirrors the original SQL\*Plus sections.
- `AWR_APP_ADMIN_API`
  Scheduler synchronization for recurring schedules.

## APEX-facing views

- `AWR_APP_TARGET_STATUS_V`
  Latest run summary per target.
- `AWR_APP_RUN_SUMMARY_V`
  Run-level overview with finding counts and window counts.
- `AWR_APP_METRIC_SERIES_V`
  Chart-friendly metric union across load, sysmetric, and wait-class data.
- `AWR_APP_TOP_SQL_V`
  Top SQL facts with run and target context.
- `AWR_APP_RUN_LOG_V`
  Run log with target context.

## Operational notes

- DB links are validated at run start, not at target creation time.
- Logs are written through an autonomous transaction so failures survive rollbacks.
- Reruns of the same `run_id` are safe because the collector purges child facts first.
- The repository stays query-first: once a run finishes, APEX reads only local data and does not fan back out to remote targets.
