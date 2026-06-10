--
-- sql/lib/templates/dev/sysmetric_targets.sql
--
-- Body of a "metric_targets AS (...)" CTE: the
-- DBA_HIST_SYSMETRIC_SUMMARY metric_names tracked under the DEV
-- template, each tagged with an is_additive flag (see the
-- comprehensive variant for the SUM-vs-AVG cross-instance semantics).
--
-- DEV is an application-developer's view: response time and
-- throughput rates the developer can move by changing application
-- behaviour (commit cadence, cursor reuse, query shape), plus the two
-- ratios that frame "is the database busy or waiting".  The host/OS
-- and storage-IO metrics a DBA watches (Host CPU Utilization, Physical
-- *, Redo Generated, IO requests/bytes, single-block read latency,
-- network volume) are intentionally omitted.
--
-- Retains the two METRIC names section 08's hero strip
-- hard-references -- 'Average Active Sessions' and 'Database Wait Time
-- Ratio' -- so those hero cards keep rendering.
--
-- is_additive: 'Y' = SUM across instances within a snapshot (rates,
-- counters); 'N' = AVG across instances (ratios, response times).
--
-- Consumers write the include as
--   @@~template_dir/sysmetric_targets.sql
--
            SELECT 'Database CPU Time Ratio'                   AS metric_name, 'N' AS is_additive FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio'                               , 'N'                FROM dual UNION ALL
            SELECT 'Average Active Sessions'                                , 'Y'                FROM dual UNION ALL
            SELECT 'SQL Service Response Time'                              , 'N'                FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec'                                  , 'Y'                FROM dual UNION ALL
            SELECT 'User Calls Per Sec'                                     , 'Y'                FROM dual UNION ALL
            SELECT 'User Commits Per Sec'                                   , 'Y'                FROM dual UNION ALL
            SELECT 'User Rollbacks Per Sec'                                 , 'Y'                FROM dual UNION ALL
            SELECT 'Executions Per Sec'                                     , 'Y'                FROM dual UNION ALL
            SELECT 'Hard Parse Count Per Sec'                               , 'Y'                FROM dual UNION ALL
            SELECT 'Total Parse Count Per Sec'                              , 'Y'                FROM dual UNION ALL
            SELECT 'Logons Per Sec'                                         , 'Y'                FROM dual UNION ALL
            SELECT 'Session Count'                                          , 'Y'                FROM dual
