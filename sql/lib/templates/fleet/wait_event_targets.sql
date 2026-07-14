--
-- sql/lib/templates/fleet/wait_event_targets.sql
--
-- Body of a "wait_targets AS (...)" CTE: the same 23-event curated subset
-- of wait event_names as the WAIT domain of sql/lib/is_essential.plsql,
-- used as the FLEET template's triage list.  No '*' sentinel -- unlike the
-- comprehensive template, fleet always filters to this curated set.
--
-- Consumers intersect this list with DBA_HIST_SYSTEM_EVENT (findings WAIT
-- domain) and DBA_HIST_BG_EVENT_SUMMARY; names that only exist on the other
-- side filter out naturally via the IN-list.
--
            SELECT 'db file sequential read'                    AS event_name FROM dual UNION ALL
            SELECT 'db file scattered read'                                   FROM dual UNION ALL
            SELECT 'direct path read'                                        FROM dual UNION ALL
            SELECT 'direct path read temp'                                   FROM dual UNION ALL
            SELECT 'direct path write temp'                                  FROM dual UNION ALL
            SELECT 'log file sync'                                           FROM dual UNION ALL
            SELECT 'log file parallel write'                                 FROM dual UNION ALL
            SELECT 'buffer busy waits'                                       FROM dual UNION ALL
            SELECT 'read by other session'                                   FROM dual UNION ALL
            SELECT 'free buffer waits'                                       FROM dual UNION ALL
            SELECT 'enq: TX - row lock contention'                           FROM dual UNION ALL
            SELECT 'library cache: mutex X'                                  FROM dual UNION ALL
            SELECT 'cursor: pin S wait on X'                                 FROM dual UNION ALL
            SELECT 'latch: cache buffers chains'                             FROM dual UNION ALL
            SELECT 'latch: shared pool'                                      FROM dual UNION ALL
            SELECT 'resmgr:cpu quantum'                                      FROM dual UNION ALL
            SELECT 'log file switch (checkpoint incomplete)'                 FROM dual UNION ALL
            SELECT 'db file parallel write'                                  FROM dual UNION ALL
            SELECT 'db file async I/O submit'                                FROM dual UNION ALL
            SELECT 'gc buffer busy acquire'                                  FROM dual UNION ALL
            SELECT 'gc buffer busy release'                                  FROM dual UNION ALL
            SELECT 'gc cr block busy'                                        FROM dual UNION ALL
            SELECT 'gc current block busy'                                   FROM dual
