--
-- sql/lib/sysmetric_targets.sql
--
-- Body of a "metric_targets AS (...)" CTE: the curated list of
-- DBA_HIST_SYSMETRIC_SUMMARY metric_names tracked by the report,
-- each tagged with an is_additive flag.
--
-- Used by section 03 (system-metrics pivot), section 07 (findings
-- z-score, METRIC domain), and section 08 (hero strip). Single source
-- of truth so all three consumers stay aligned.
--
-- is_additive semantics for cross-instance (RAC) aggregation:
--   'Y' = cluster-wide value is the SUM across instances within a
--         snapshot (e.g. counters and rates: AAS, *_Per_Sec,
--         Session Count). For these, doing AVG(sm.average) across
--         instances silently undercounts cluster activity.
--   'N' = cluster-wide value is the AVG across instances within a
--         snapshot (e.g. percentages, ratios, latencies, response
--         times). AVG is the existing well-defined behavior.
--
-- Consumers compute snap_value = SUM(average) for additive, AVG(average)
-- for non-additive, then AVG(snap_value) across snaps in the window.
-- On single-instance, SUM and AVG over one row are identical, so this
-- is a no-op for non-RAC databases.
--
-- Usage (note path is from awr_trend.sql's directory):
--
--   WITH @@sql/lib/windows_cte.sql,
--        metric_targets AS (
--            @@sql/lib/sysmetric_targets.sql
--        ),
--        ...
--
            SELECT 'Host CPU Utilization (%)'                  AS metric_name, 'N' AS is_additive FROM dual UNION ALL
            SELECT 'Database CPU Time Ratio'                                 , 'N'                FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio'                                , 'N'                FROM dual UNION ALL
            SELECT 'Average Active Sessions'                                 , 'Y'                FROM dual UNION ALL
            SELECT 'Average Synchronous Single-Block Read Latency'           , 'N'                FROM dual UNION ALL
            SELECT 'Physical Reads Per Sec'                                  , 'Y'                FROM dual UNION ALL
            SELECT 'Physical Writes Per Sec'                                 , 'Y'                FROM dual UNION ALL
            SELECT 'Physical Read Total IO Requests Per Sec'                 , 'Y'                FROM dual UNION ALL
            SELECT 'Physical Write Total IO Requests Per Sec'                , 'Y'                FROM dual UNION ALL
            SELECT 'Physical Read Total Bytes Per Sec'                       , 'Y'                FROM dual UNION ALL
            SELECT 'Physical Write Total Bytes Per Sec'                      , 'Y'                FROM dual UNION ALL
            SELECT 'Redo Generated Per Sec'                                  , 'Y'                FROM dual UNION ALL
            SELECT 'Logons Per Sec'                                          , 'Y'                FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec'                                   , 'Y'                FROM dual UNION ALL
            SELECT 'User Calls Per Sec'                                      , 'Y'                FROM dual UNION ALL
            SELECT 'User Commits Per Sec'                                    , 'Y'                FROM dual UNION ALL
            SELECT 'User Rollbacks Per Sec'                                  , 'Y'                FROM dual UNION ALL
            SELECT 'Executions Per Sec'                                      , 'Y'                FROM dual UNION ALL
            SELECT 'Hard Parse Count Per Sec'                                , 'Y'                FROM dual UNION ALL
            SELECT 'Total Parse Count Per Sec'                               , 'Y'                FROM dual UNION ALL
            SELECT 'Session Count'                                           , 'Y'                FROM dual UNION ALL
            SELECT 'Network Traffic Volume Per Sec'                          , 'Y'                FROM dual UNION ALL
            SELECT 'SQL Service Response Time'                               , 'N'                FROM dual
