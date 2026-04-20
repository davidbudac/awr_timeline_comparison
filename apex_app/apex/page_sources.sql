PROMPT ============================================================
PROMPT AWR Trend Central - Page SQL and Process Catalog
PROMPT ============================================================

PROMPT
PROMPT Page 1 - Home / Target selector
PROMPT --------------------------------
PROMPT Cards region source:

SELECT target_id,
       target_name AS card_title,
       db_link_name AS card_subtitle,
       'Latest status: ' || NVL(latest_status, 'NO RUNS') AS card_text,
       latest_run_id,
       latest_generated_at,
       latest_critical_count,
       latest_warn_count
FROM   awr_app_target_status_v
ORDER BY target_name;

PROMPT
PROMPT Page 2 - Runs
PROMPT -------------
PROMPT Interactive Report source:

SELECT *
FROM   awr_app_run_summary_v
WHERE  (:P2_TARGET_ID IS NULL OR target_id = :P2_TARGET_ID)
ORDER BY generated_at DESC, run_id DESC;

PROMPT
PROMPT Page 3 - Run overview
PROMPT ---------------------
PROMPT Header region source:

SELECT *
FROM   awr_app_run_summary_v
WHERE  run_id = :P3_RUN_ID;

PROMPT Windows report:

SELECT week_offset,
       win_start_ts,
       win_end_ts,
       begin_snap_id,
       end_snap_id,
       valid_flag,
       skip_reason
FROM   awr_trend_windows
WHERE  run_id = :P3_RUN_ID
ORDER BY week_offset;

PROMPT KPI badges:

SELECT severity,
       COUNT(*) AS finding_count
FROM   awr_trend_findings
WHERE  run_id = :P3_RUN_ID
GROUP BY severity
ORDER BY CASE severity
             WHEN 'CRITICAL' THEN 1
             WHEN 'WARN' THEN 2
             WHEN 'OK' THEN 3
             ELSE 4
         END;

PROMPT Run Now button process:

DECLARE
    l_run_id NUMBER;
BEGIN
    l_run_id := awr_app_run_api.submit_run(
        p_target_id     => :P3_TARGET_ID,
        p_target_end_ts => :P3_TARGET_END_TS,
        p_win_hours     => :P3_WIN_HOURS,
        p_weeks_back    => :P3_WEEKS_BACK,
        p_top_n         => :P3_TOP_N,
        p_inst_num      => :P3_INST_NUM
    );

    awr_app_run_api.enqueue_run(l_run_id);
    :P3_RUN_ID := l_run_id;
END;

PROMPT
PROMPT Page 4 - Findings explorer
PROMPT --------------------------
PROMPT Faceted search source:

SELECT run_id,
       metric_domain,
       metric_name,
       severity,
       current_value,
       prior_mean,
       prior_sd,
       n_prior,
       z_score,
       pct_delta
FROM   awr_trend_findings
WHERE  run_id = :P3_RUN_ID;

PROMPT
PROMPT Page 5 - Metrics dashboard
PROMPT --------------------------
PROMPT Chart/report source:

SELECT metric_domain,
       metric_name,
       week_offset,
       metric_value,
       metric_unit
FROM   awr_app_metric_series_v
WHERE  run_id = :P3_RUN_ID
AND    (:P5_METRIC_DOMAIN IS NULL OR metric_domain = :P5_METRIC_DOMAIN)
ORDER BY metric_domain, metric_name, week_offset;

PROMPT
PROMPT Page 6 - Waits dashboard
PROMPT ------------------------
PROMPT Foreground/background waits report:

SELECT scope,
       week_offset,
       event_name,
       wait_class,
       total_waits,
       time_waited_us,
       avg_wait_ms,
       rank_in_window
FROM   awr_trend_waits
WHERE  run_id = :P3_RUN_ID
ORDER BY scope, week_offset, rank_in_window, event_name;

PROMPT Wait class trend chart:

SELECT metric_name,
       week_offset,
       metric_value
FROM   awr_app_metric_series_v
WHERE  run_id = :P3_RUN_ID
AND    metric_domain = 'WAIT'
ORDER BY metric_name, week_offset;

PROMPT
PROMPT Page 7 - Top SQL explorer
PROMPT -------------------------
PROMPT Interactive Report source:

SELECT dimension,
       week_offset,
       rank_in_window,
       sql_id,
       plan_hash_value,
       executions_delta,
       elapsed_time_delta_us,
       cpu_time_delta_us,
       buffer_gets_delta,
       disk_reads_delta,
       rows_processed_delta,
       sql_text_short
FROM   awr_app_top_sql_v
WHERE  run_id = :P3_RUN_ID
AND    (:P7_DIMENSION IS NULL OR dimension = :P7_DIMENSION)
ORDER BY dimension, week_offset, rank_in_window;

PROMPT
PROMPT Page 8 - Targets admin
PROMPT ----------------------
PROMPT Interactive Grid source:

SELECT target_id,
       target_name,
       db_link_name,
       description,
       default_target_end_mode,
       default_win_hours,
       default_weeks_back,
       default_top_n,
       default_inst_num,
       enabled_flag,
       last_validated_at,
       created_at,
       updated_at,
       created_by,
       notes
FROM   awr_app_targets
ORDER BY target_name;

PROMPT
PROMPT Page 9 - Schedules admin
PROMPT ------------------------
PROMPT Interactive Grid source:

SELECT schedule_id,
       target_id,
       schedule_name,
       repeat_interval,
       override_target_end_ts,
       override_win_hours,
       override_weeks_back,
       override_top_n,
       override_inst_num,
       enabled_flag,
       scheduler_job_name,
       last_requested_at,
       last_started_at,
       last_finished_at,
       last_run_id,
       last_status,
       last_error_text,
       created_at,
       updated_at,
       created_by
FROM   awr_app_schedules
ORDER BY target_id, schedule_name;

PROMPT Sync Schedules button process:

BEGIN
    awr_app_admin_api.sync_schedules;
END;

PROMPT Run Schedule Now button process:

BEGIN
    awr_app_admin_api.run_schedule_now(:P9_SCHEDULE_ID);
END;

PROMPT
PROMPT Page 10 - Run log
PROMPT -----------------
PROMPT Interactive Report source:

SELECT log_id,
       run_id,
       target_name,
       step_name,
       log_level,
       status,
       message,
       created_at
FROM   awr_app_run_log_v
WHERE  (:P10_RUN_ID IS NULL OR run_id = :P10_RUN_ID)
ORDER BY created_at DESC, log_id DESC;

PROMPT
PROMPT Shared LOV - Targets
PROMPT --------------------

SELECT target_name AS display_value,
       target_id   AS return_value
FROM   awr_app_targets
WHERE  enabled_flag = 'Y'
ORDER BY target_name;

PROMPT
PROMPT Shared LOV - SQL dimensions
PROMPT ---------------------------

SELECT 'ELAPSED' AS display_value, 'ELAPSED' AS return_value FROM dual
UNION ALL
SELECT 'CPU', 'CPU' FROM dual
UNION ALL
SELECT 'GETS', 'GETS' FROM dual
UNION ALL
SELECT 'EXEC', 'EXEC' FROM dual;
