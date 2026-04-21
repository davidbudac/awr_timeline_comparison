# Page Map

## App overview

Application name: `AWR Trend Central`

Application alias: `AWR_TREND_CENTRAL`

Suggested application ID: `100`

## Pages

### Page 1: Home

- Type: Cards + report dashboard
- Purpose: select a target and see the latest health state per target
- Main source: `AWR_APP_TARGET_STATUS_V`

### Page 2: Runs

- Type: Interactive Report
- Purpose: browse all runs for the selected target
- Main source: `AWR_APP_RUN_SUMMARY_V`
- Filters: target, status, time range

### Page 3: Run Overview

- Type: Dashboard
- Purpose: KPIs, run metadata, aligned windows, and quick actions
- Sources:
  - `AWR_APP_RUN_SUMMARY_V`
  - `AWR_TREND_WINDOWS`
  - `AWR_TREND_FINDINGS`

### Page 4: Findings Explorer

- Type: Faceted Search / Interactive Report
- Purpose: filter findings by severity, domain, and metric
- Source: `AWR_TREND_FINDINGS`

### Page 5: Metrics Dashboard

- Type: Oracle JET charts + Interactive Report
- Purpose: visualize load profile and system metrics
- Source: `AWR_APP_METRIC_SERIES_V`

### Page 6: Waits Dashboard

- Type: Oracle JET charts + Interactive Report
- Purpose: foreground, background, and wait-class comparison
- Sources:
  - `AWR_TREND_WAITS`
  - `AWR_APP_METRIC_SERIES_V`

### Page 7: Top SQL Explorer

- Type: Interactive Report with modal detail
- Purpose: analyze top SQL by dimension and week offset
- Source: `AWR_APP_TOP_SQL_V`

### Page 8: Targets Admin

- Type: Interactive Grid
- Purpose: maintain monitored targets and DB link mapping
- Source: `AWR_APP_TARGETS`

### Page 9: Schedules Admin

- Type: Interactive Grid
- Purpose: maintain recurring run definitions
- Source: `AWR_APP_SCHEDULES`

### Page 10: Run Log

- Type: Interactive Report
- Purpose: inspect execution progress and failures
- Source: `AWR_APP_RUN_LOG_V`

### Page 11: Run Visualizations

- Type: Oracle JET chart page + Interactive Report
- Purpose: give an at-a-glance visual summary for one collected run
- Sources:
  - `AWR_TREND_FINDINGS`
  - `AWR_TREND_WINDOWS`
  - `AWR_APP_METRIC_SERIES_V`
  - `AWR_TREND_WAITS`
  - `AWR_APP_RUN_SUMMARY_V`
- Visuals:
  - findings by domain
  - aligned-window health
  - key load trend across week offsets
  - wait-class trend across week offsets
  - strongest deviations by absolute z-score

## Key page items

- `P1_TARGET_ID`
  Selected target on the home page.
- `P2_TARGET_ID`
  Filter for runs page.
- `P3_RUN_ID`
  Run context item for all downstream detail pages.
- `P5_METRIC_DOMAIN`
  Metric type filter on the metrics page.
- `P7_DIMENSION`
  SQL ranking dimension on the top SQL page.
- `P11_RUN_ID`
  Run context item for the visual summary page.

## Main actions

- `Run Now`
  Calls `AWR_APP_RUN_API.SUBMIT_RUN` then `AWR_APP_RUN_API.ENQUEUE_RUN`.
- `Sync Schedules`
  Calls `AWR_APP_ADMIN_API.SYNC_SCHEDULES`.
- `Run Schedule Now`
  Calls `AWR_APP_ADMIN_API.RUN_SCHEDULE_NOW`.
