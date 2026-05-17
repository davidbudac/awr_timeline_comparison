--
-- sql/lib/templates/simple/sysmetric_targets.sql
--
-- Body of a "metric_targets AS (...)" CTE: a small triage-friendly
-- subset of DBA_HIST_SYSMETRIC_SUMMARY metric_names for the SIMPLE
-- template.  Each row is tagged with an is_additive flag; see the
-- comprehensive variant for the semantics.
--
-- Includes 'Average Active Sessions' and 'Database Wait Time Ratio'
-- so the matching section 08 hero cards keep rendering.
--
            SELECT 'Host CPU Utilization (%)'                  AS metric_name, 'N' AS is_additive FROM dual UNION ALL
            SELECT 'Database CPU Time Ratio'                                 , 'N'                FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio'                                , 'N'                FROM dual UNION ALL
            SELECT 'Average Active Sessions'                                 , 'Y'                FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec'                                   , 'Y'                FROM dual UNION ALL
            SELECT 'User Commits Per Sec'                                    , 'Y'                FROM dual UNION ALL
            SELECT 'Session Count'                                           , 'Y'                FROM dual UNION ALL
            SELECT 'SQL Service Response Time'                               , 'N'                FROM dual
