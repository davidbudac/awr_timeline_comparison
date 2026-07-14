--
-- sql/lib/templates/fleet/sysmetric_targets.sql
--
-- Body of a "metric_targets AS (...)" CTE: the same 11-metric curated
-- subset of DBA_HIST_SYSMETRIC_SUMMARY metric_names as the METRIC domain of
-- sql/lib/is_essential.plsql, used as the FLEET template's triage list.
-- is_additive flags copied verbatim from the matching rows in
-- sql/lib/templates/comprehensive/sysmetric_targets.sql -- see that file
-- for the cross-instance aggregation semantics.
--
-- Includes 'Average Active Sessions' and 'Database Wait Time Ratio' so the
-- matching headline hero cards keep rendering.
--
            SELECT 'Host CPU Utilization (%)'                  AS metric_name, 'N' AS is_additive FROM dual UNION ALL
            SELECT 'Database CPU Time Ratio'                                 , 'N'                FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio'                                , 'N'                FROM dual UNION ALL
            SELECT 'Average Active Sessions'                                 , 'Y'                FROM dual UNION ALL
            SELECT 'Average Synchronous Single-Block Read Latency'           , 'N'                FROM dual UNION ALL
            SELECT 'Executions Per Sec'                                      , 'Y'                FROM dual UNION ALL
            SELECT 'User Calls Per Sec'                                      , 'Y'                FROM dual UNION ALL
            SELECT 'User Commits Per Sec'                                    , 'Y'                FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec'                                   , 'Y'                FROM dual UNION ALL
            SELECT 'Hard Parse Count Per Sec'                                , 'Y'                FROM dual UNION ALL
            SELECT 'SQL Service Response Time'                               , 'N'                FROM dual
