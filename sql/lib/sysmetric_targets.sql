--
-- sql/lib/sysmetric_targets.sql
--
-- Body of a "metric_targets AS (...)" CTE: the curated list of
-- DBA_HIST_SYSMETRIC_SUMMARY metric_names tracked by the report.
-- Used by section 03 (system-metrics pivot) and section 07 (findings
-- z-score, METRIC domain).  Single source of truth so the two
-- consumers stay aligned.
--
-- Usage (note path is from awr_trend.sql's directory):
--
--   WITH @@sql/lib/windows_cte.sql,
--        metric_targets AS (
--            @@sql/lib/sysmetric_targets.sql
--        ),
--        ...
--
            SELECT 'Host CPU Utilization (%)'                 metric_name FROM dual UNION ALL
            SELECT 'Database CPU Time Ratio'                              FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio'                             FROM dual UNION ALL
            SELECT 'Average Active Sessions'                              FROM dual UNION ALL
            SELECT 'Average Synchronous Single-Block Read Latency'        FROM dual UNION ALL
            SELECT 'Physical Reads Per Sec'                               FROM dual UNION ALL
            SELECT 'Physical Writes Per Sec'                              FROM dual UNION ALL
            SELECT 'Physical Read Total IO Requests Per Sec'              FROM dual UNION ALL
            SELECT 'Physical Write Total IO Requests Per Sec'             FROM dual UNION ALL
            SELECT 'Physical Read Total Bytes Per Sec'                    FROM dual UNION ALL
            SELECT 'Physical Write Total Bytes Per Sec'                   FROM dual UNION ALL
            SELECT 'Redo Generated Per Sec'                               FROM dual UNION ALL
            SELECT 'Logons Per Sec'                                       FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec'                                FROM dual UNION ALL
            SELECT 'User Calls Per Sec'                                   FROM dual UNION ALL
            SELECT 'User Commits Per Sec'                                 FROM dual UNION ALL
            SELECT 'User Rollbacks Per Sec'                               FROM dual UNION ALL
            SELECT 'Executions Per Sec'                                   FROM dual UNION ALL
            SELECT 'Hard Parse Count Per Sec'                             FROM dual UNION ALL
            SELECT 'Total Parse Count Per Sec'                            FROM dual UNION ALL
            SELECT 'Session Count'                                        FROM dual UNION ALL
            SELECT 'Network Traffic Volume Per Sec'                       FROM dual UNION ALL
            SELECT 'SQL Service Response Time'                            FROM dual
