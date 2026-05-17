--
-- sql/lib/templates/simple/wait_event_targets.sql
--
-- Body of a "wait_targets AS (...)" CTE: a small triage-friendly
-- subset of wait event_names for the SIMPLE template.  Consumers
-- intersect this list with DBA_HIST_SYSTEM_EVENT (section 04, 07
-- WAIT) and DBA_HIST_BG_EVENT_SUMMARY (section 05); names that only
-- exist in the other view filter out naturally via the IN-list.
--
-- The standard top-N rank by time_waited still applies on top of this
-- subset; in practice 'simple' usually shows fewer than top_n rows.
--
            SELECT 'db file sequential read'         AS event_name FROM dual UNION ALL
            SELECT 'db file scattered read'                        FROM dual UNION ALL
            SELECT 'direct path read'                              FROM dual UNION ALL
            SELECT 'log file sync'                                 FROM dual UNION ALL
            SELECT 'log file parallel write'                       FROM dual UNION ALL
            SELECT 'enq: TX - row lock contention'                 FROM dual UNION ALL
            SELECT 'library cache: mutex X'                        FROM dual UNION ALL
            SELECT 'cursor: pin S wait on X'                       FROM dual UNION ALL
            SELECT 'latch: shared pool'                            FROM dual UNION ALL
            SELECT 'gc cr block 2-way'                             FROM dual
