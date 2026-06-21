--
-- fleet/seed/profile_default.sql
--
-- Seeds the DEFAULT Metric Profile: a curated triage set (not the full
-- comprehensive firehose) to keep fleet alert volume low. The six headline
-- metrics ('Y') form the per-Target health line; the rest broaden seasonal
-- coverage. is_additive follows the RAC roll-up rule: SUM rates/counters,
-- AVG ratios/percentages/latencies. abs_floor/pct_floor start permissive --
-- tune them as you observe real alert volume.
--
-- Re-runnable: MERGE upserts so editing + re-running just updates rows.
--

MERGE INTO awrw_profile p USING (
    SELECT 'DEFAULT' profile_name FROM dual
) s ON (p.profile_name = s.profile_name)
WHEN NOT MATCHED THEN INSERT (profile_name, description)
    VALUES ('DEFAULT', 'Curated fleet triage profile: headline-six + key load/wait metrics');

-- domain, metric_name, is_additive, abs_floor, pct_floor(NULL=profile default), polarity, headline
MERGE INTO awrw_profile_metric t USING (
    SELECT 'DEFAULT' pn, c.* FROM (
        -- LOAD (DBA_HIST_SYSSTAT counters; additive across RAC)
        SELECT 'LOAD'   domain, 'DB time'                       metric_name, 'Y' is_additive, 0 abs_floor, CAST(NULL AS NUMBER) pct_floor, 'UP'   polarity, 'Y' headline FROM dual UNION ALL
        SELECT 'LOAD','redo size'                  ,'Y',0,NULL,'BOTH','Y' FROM dual UNION ALL
        SELECT 'LOAD','session logical reads'      ,'Y',0,NULL,'UP'  ,'Y' FROM dual UNION ALL
        SELECT 'LOAD','parse count (hard)'         ,'Y',0,NULL,'UP'  ,'Y' FROM dual UNION ALL
        SELECT 'LOAD','physical reads'             ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'LOAD','physical writes'            ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'LOAD','user commits'               ,'Y',0,NULL,'BOTH','N' FROM dual UNION ALL
        SELECT 'LOAD','user calls'                 ,'Y',0,NULL,'BOTH','N' FROM dual UNION ALL
        SELECT 'LOAD','execute count'              ,'Y',0,NULL,'BOTH','N' FROM dual UNION ALL
        SELECT 'LOAD','parse count (total)'        ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        -- METRIC (DBA_HIST_SYSMETRIC_SUMMARY)
        SELECT 'METRIC','Average Active Sessions'  ,'Y',0,NULL,'UP'  ,'Y' FROM dual UNION ALL
        SELECT 'METRIC','Database Wait Time Ratio' ,'N',0,NULL,'UP'  ,'Y' FROM dual UNION ALL
        SELECT 'METRIC','Database CPU Time Ratio'  ,'N',0,NULL,'BOTH','N' FROM dual UNION ALL
        SELECT 'METRIC','Host CPU Utilization (%)' ,'N',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'METRIC','Buffer Cache Hit Ratio'   ,'N',0,NULL,'DOWN','N' FROM dual UNION ALL
        SELECT 'METRIC','Hard Parse Count Per Sec' ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'METRIC','Executions Per Sec'       ,'Y',0,NULL,'BOTH','N' FROM dual UNION ALL
        -- WAIT (rolled up per non-idle wait_class; seconds-of-wait/sec, additive)
        SELECT 'WAIT','User I/O'                   ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'WAIT','Concurrency'                ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'WAIT','Cluster'                    ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'WAIT','Commit'                     ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'WAIT','Application'                ,'Y',0,NULL,'UP'  ,'N' FROM dual UNION ALL
        SELECT 'WAIT','System I/O'                 ,'Y',0,NULL,'UP'  ,'N' FROM dual
    ) c
) src ON (t.profile_name = src.pn AND t.domain = src.domain AND t.metric_name = src.metric_name)
WHEN MATCHED THEN UPDATE SET
    t.is_additive = src.is_additive, t.abs_floor = src.abs_floor,
    t.pct_floor = src.pct_floor, t.polarity = src.polarity, t.headline = src.headline
WHEN NOT MATCHED THEN INSERT (profile_name, domain, metric_name, is_additive, abs_floor, pct_floor, polarity, headline)
    VALUES (src.pn, src.domain, src.metric_name, src.is_additive, src.abs_floor, src.pct_floor, src.polarity, src.headline);

COMMIT;
