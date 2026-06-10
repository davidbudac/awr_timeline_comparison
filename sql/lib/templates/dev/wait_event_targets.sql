--
-- sql/lib/templates/dev/wait_event_targets.sql
--
-- Body of a "wait_targets AS (...)" CTE: the wait event_names tracked
-- under the DEV template.  Consumers intersect this list with
-- DBA_HIST_SYSTEM_EVENT (sections 04, 07 WAIT) and
-- DBA_HIST_BG_EVENT_SUMMARY (section 05); names that exist only in the
-- other view filter out naturally via the IN-list.
--
-- DEV is an application-developer's view: it keeps the waits an
-- application/SQL change can actually move -- index vs full-scan IO,
-- temp spill from oversized sorts/hashes, commit latency, row/index/TM
-- lock contention from the app's own DML, hot-block buffer busy, and
-- the library-cache/cursor/shared-pool contention that bad cursor
-- reuse (hard parsing) drives.  Background/storage-engine waits (redo
-- writer, DBWR, control file, log file parallel write, RAC GC
-- internals) are intentionally excluded.
--
-- The standard top-N rank by time_waited still applies on top of this
-- subset; in practice 'dev' usually shows fewer than top_n rows.
--
            SELECT 'db file sequential read'         AS event_name FROM dual UNION ALL
            SELECT 'db file scattered read'                        FROM dual UNION ALL
            SELECT 'direct path read'                              FROM dual UNION ALL
            SELECT 'direct path read temp'                         FROM dual UNION ALL
            SELECT 'direct path write temp'                        FROM dual UNION ALL
            SELECT 'read by other session'                         FROM dual UNION ALL
            SELECT 'buffer busy waits'                             FROM dual UNION ALL
            SELECT 'log file sync'                                 FROM dual UNION ALL
            SELECT 'enq: TX - row lock contention'                 FROM dual UNION ALL
            SELECT 'enq: TX - index contention'                    FROM dual UNION ALL
            SELECT 'enq: TM - contention'                          FROM dual UNION ALL
            SELECT 'library cache: mutex X'                        FROM dual UNION ALL
            SELECT 'cursor: pin S wait on X'                       FROM dual UNION ALL
            SELECT 'latch: shared pool'                            FROM dual
