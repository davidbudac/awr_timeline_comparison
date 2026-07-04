--
-- sql/lib/is_essential.plsql
--
-- Local PL/SQL helper that classifies a stat / metric / wait-event name as
-- "essential" (part of the short curated triage list) or not.  Used by the
-- per-name table sections (02 Load profile, 03 System metrics, 04 Foreground
-- waits, 05 Background waits) to tag each data row with a data-imp="Y|N"
-- marker so the report's "Essential rows" toggle can collapse the tables to
-- the handful of rows a DBA scans first.  Purely presentational: the CSS
-- hide rule keeps crit/warn-scored rows visible regardless, and charts are
-- untouched.  No DB access: a pure name test against curated lists.
--
-- Usage: include this file *inside* a section's DECLARE block, BEFORE the
-- BEGIN keyword (exactly like sql/lib/nth_csv.plsql).  Nested include paths
-- resolve against the OUTERMOST caller (the driver at project root), so the
-- include line is always: two at-signs followed by sql/lib/is_essential.plsql
--
--   DECLARE
--       ...
--       (include line here)
--   BEGIN
--       ...
--       v_imp := is_essential('WAIT', v_event_name);   -- 'Y' or 'N'
--       ...
--   END;
--   /
--
-- Domains: 'LOAD' (DBA_HIST_SYSSTAT stat_name), 'METRIC'
-- (DBA_HIST_SYSMETRIC_SUMMARY metric_name), 'WAIT' (wait event_name,
-- shared by foreground and background -- events that only exist on the
-- other side simply never match).  Exact, case-sensitive name match;
-- unknown names (and NULL) return 'N'.
--
    FUNCTION is_essential(p_domain IN VARCHAR2,
                          p_name   IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_name IS NULL THEN
            RETURN 'N';
        END IF;
        IF p_domain = 'LOAD' AND p_name IN (
               'DB time', 'DB CPU', 'redo size', 'session logical reads',
               'physical reads', 'physical writes', 'execute count',
               'user commits', 'parse count (hard)')
        THEN
            RETURN 'Y';
        ELSIF p_domain = 'METRIC' AND p_name IN (
               'Average Active Sessions', 'SQL Service Response Time',
               'Database CPU Time Ratio', 'Database Wait Time Ratio',
               'Host CPU Utilization (%)',
               'Average Synchronous Single-Block Read Latency',
               'Executions Per Sec', 'User Calls Per Sec',
               'User Commits Per Sec', 'Logical Reads Per Sec',
               'Hard Parse Count Per Sec')
        THEN
            RETURN 'Y';
        ELSIF p_domain = 'WAIT' AND p_name IN (
               'db file sequential read', 'db file scattered read',
               'direct path read', 'direct path read temp',
               'direct path write temp', 'log file sync',
               'log file parallel write', 'buffer busy waits',
               'read by other session', 'free buffer waits',
               'enq: TX - row lock contention', 'library cache: mutex X',
               'cursor: pin S wait on X', 'latch: cache buffers chains',
               'latch: shared pool', 'resmgr:cpu quantum',
               'log file switch (checkpoint incomplete)',
               'db file parallel write', 'db file async I/O submit',
               'gc buffer busy acquire', 'gc buffer busy release',
               'gc cr block busy', 'gc current block busy')
        THEN
            RETURN 'Y';
        END IF;
        RETURN 'N';
    END is_essential;
