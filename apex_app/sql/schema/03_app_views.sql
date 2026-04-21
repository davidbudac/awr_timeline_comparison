SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT Creating AWR_APP_* views for APEX regions ...

CREATE OR REPLACE VIEW awr_app_target_status_v AS
WITH latest_run AS (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY r.target_id ORDER BY r.generated_at DESC, r.run_id DESC) AS rn
    FROM   awr_trend_runs r
    WHERE  r.target_id IS NOT NULL
),
finding_counts AS (
    SELECT f.run_id,
           SUM(CASE WHEN f.severity = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_count,
           SUM(CASE WHEN f.severity = 'WARN' THEN 1 ELSE 0 END) AS warn_count
    FROM   awr_trend_findings f
    GROUP BY f.run_id
)
SELECT t.target_id,
       t.target_name,
       t.db_link_name,
       t.description,
       t.default_win_hours,
       t.default_weeks_back,
       t.default_top_n,
       t.default_inst_num,
       t.enabled_flag,
       r.run_id AS latest_run_id,
       r.generated_at AS latest_generated_at,
       r.started_at AS latest_started_at,
       r.finished_at AS latest_finished_at,
       r.status AS latest_status,
       r.target_end_ts AS latest_target_end_ts,
       r.error_text AS latest_error_text,
       NVL(fc.critical_count, 0) AS latest_critical_count,
       NVL(fc.warn_count, 0) AS latest_warn_count
FROM   awr_app_targets t
LEFT JOIN latest_run r
       ON r.target_id = t.target_id
      AND r.rn = 1
LEFT JOIN finding_counts fc
       ON fc.run_id = r.run_id;

CREATE OR REPLACE VIEW awr_app_run_summary_v AS
WITH finding_counts AS (
    SELECT run_id,
           SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_count,
           SUM(CASE WHEN severity = 'WARN' THEN 1 ELSE 0 END) AS warn_count,
           SUM(CASE WHEN severity = 'OK' THEN 1 ELSE 0 END) AS ok_count
    FROM   awr_trend_findings
    GROUP BY run_id
),
window_counts AS (
    SELECT run_id,
           SUM(CASE WHEN valid_flag = 'Y' THEN 1 ELSE 0 END) AS valid_windows,
           SUM(CASE WHEN valid_flag = 'N' THEN 1 ELSE 0 END) AS skipped_windows
    FROM   awr_trend_windows
    GROUP BY run_id
)
SELECT r.run_id,
       r.target_id,
       t.target_name,
       t.db_link_name,
       r.dbid,
       r.db_name,
       r.instance_number,
       r.target_end_ts,
       r.win_hours,
       r.weeks_back,
       r.top_n,
       r.scope,
       r.generated_at,
       r.started_at,
       r.finished_at,
       r.status,
       r.error_text,
       r.requested_by,
       r.request_source,
       r.scheduler_job_name,
       NVL(fc.critical_count, 0) AS critical_count,
       NVL(fc.warn_count, 0) AS warn_count,
       NVL(fc.ok_count, 0) AS ok_count,
       NVL(wc.valid_windows, 0) AS valid_windows,
       NVL(wc.skipped_windows, 0) AS skipped_windows
FROM   awr_trend_runs r
LEFT JOIN awr_app_targets t
       ON t.target_id = r.target_id
LEFT JOIN finding_counts fc
       ON fc.run_id = r.run_id
LEFT JOIN window_counts wc
       ON wc.run_id = r.run_id;

CREATE OR REPLACE VIEW awr_app_metric_series_v AS
SELECT r.target_id,
       r.run_id,
       r.target_end_ts,
       lp.week_offset,
       'LOAD' AS metric_domain,
       lp.stat_name AS metric_name,
       lp.per_sec AS metric_value,
       CAST(NULL AS VARCHAR2(40)) AS metric_unit
FROM   awr_trend_load_profile lp
JOIN   awr_trend_runs r
       ON r.run_id = lp.run_id
UNION ALL
SELECT r.target_id,
       r.run_id,
       r.target_end_ts,
       sm.week_offset,
       'METRIC' AS metric_domain,
       sm.metric_name,
       sm.avg_value,
       sm.metric_unit
FROM   awr_trend_sysmetric sm
JOIN   awr_trend_runs r
       ON r.run_id = sm.run_id
UNION ALL
SELECT r.target_id,
       r.run_id,
       r.target_end_ts,
       w.week_offset,
       'WAIT' AS metric_domain,
       'Wait class: ' || w.wait_class AS metric_name,
       CASE
           WHEN (CAST(win.win_end_ts AS DATE) - CAST(win.win_start_ts AS DATE)) * 86400 = 0 THEN NULL
           ELSE w.time_waited_us / ((CAST(win.win_end_ts AS DATE) - CAST(win.win_start_ts AS DATE)) * 86400 * 1e6)
       END AS metric_value,
       'seconds per second' AS metric_unit
FROM   awr_trend_waits w
JOIN   awr_trend_runs r
       ON r.run_id = w.run_id
JOIN   awr_trend_windows win
       ON win.run_id = w.run_id
      AND win.week_offset = w.week_offset
WHERE  w.scope = 'CLASS';

CREATE OR REPLACE VIEW awr_app_top_sql_v AS
SELECT r.target_id,
       r.run_id,
       r.target_end_ts,
       ts.week_offset,
       ts.dimension,
       ts.rank_in_window,
       ts.sql_id,
       ts.plan_hash_value,
       ts.executions_delta,
       ts.elapsed_time_delta_us,
       ts.cpu_time_delta_us,
       ts.buffer_gets_delta,
       ts.disk_reads_delta,
       ts.rows_processed_delta,
       ts.sql_text_short
FROM   awr_trend_top_sql ts
JOIN   awr_trend_runs r
       ON r.run_id = ts.run_id;

CREATE OR REPLACE VIEW awr_app_run_log_v AS
SELECT l.log_id,
       l.run_id,
       r.target_id,
       t.target_name,
       l.step_name,
       l.log_level,
       l.status,
       l.message,
       l.details,
       l.created_at
FROM   awr_app_run_log l
JOIN   awr_trend_runs r
       ON r.run_id = l.run_id
LEFT JOIN awr_app_targets t
       ON t.target_id = r.target_id;
