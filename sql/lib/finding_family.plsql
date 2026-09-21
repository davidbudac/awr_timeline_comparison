--
-- sql/lib/finding_family.plsql
--
-- Local PL/SQL helpers that group the scored LOAD / METRIC / WAIT names
-- into "families" (one physical quantity or one story per family), pick
-- the one canonical name per quantity, and say whether a rise in the
-- name is bad news.  Used by the findings consumers (00 verdict, 07
-- findings summary, 08 hero cards) so that:
--   - a SYSSTAT counter and its SYSMETRIC rate twin (physical reads vs
--     Physical Reads Per Sec) count as ONE finding, not two;
--   - complementary ratios (Database CPU Time Ratio + Database Wait Time
--     Ratio = 100) count once;
--   - a family's related counters (read bytes, read requests, User I/O
--     wait, read latency) are listed under one lead row;
--   - a drop in a cost-type metric (waits, latency, hard parses) is an
--     "improved" finding, not a critical one.
-- Purely presentational -- no DB access, no query change, a plain
-- case-sensitive name test.  Unknown names (and every wait class) fall
-- through to a safe default: their own family, canonical, direction
-- unknown -- so a template-specific name is never folded or hidden.
--
-- Usage: include inside a DECLARE block, before BEGIN, exactly like
-- sql/lib/is_essential.plsql (two at-signs + sql/lib/finding_family.plsql).
--
--   finding_family('LOAD', 'physical reads')          -> 'READ_IO'
--   is_canonical('METRIC', 'Physical Reads Per Sec')  -> 'N'  (twin)
--   higher_is_worse('WAIT', 'Wait class: User I/O')   -> 'Y'
--
-- Keep the three lists in lockstep with the comprehensive template's
-- sysstat_load_targets.sql / sysmetric_targets.sql (lint.sh check 12
-- verifies every template name is mapped).
--
    FUNCTION finding_family(p_domain IN VARCHAR2,
                            p_name   IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_name IS NULL THEN
            RETURN 'OTHER';
        END IF;
        IF p_domain = 'WAIT' THEN
            -- 'Wait class: User I/O' -> 'WAIT:User I/O'; one family per class.
            RETURN 'WAIT:' || REGEXP_REPLACE(p_name, '^Wait class: ', '');
        END IF;
        IF p_domain = 'LOAD' THEN
            RETURN CASE p_name
                WHEN 'DB time'                         THEN 'DB_TIME'
                WHEN 'DB CPU'                          THEN 'CPU'
                WHEN 'CPU used by this session'        THEN 'CPU'
                WHEN 'session logical reads'           THEN 'LOGICAL_IO'
                WHEN 'physical reads'                  THEN 'READ_IO'
                WHEN 'physical read total bytes'       THEN 'READ_IO'
                WHEN 'table scans (long tables)'       THEN 'SCANS'
                WHEN 'table fetch by rowid'            THEN 'LOGICAL_IO'
                WHEN 'physical writes'                 THEN 'WRITE_IO'
                WHEN 'physical write total bytes'      THEN 'WRITE_IO'
                WHEN 'redo size'                       THEN 'REDO'
                WHEN 'redo size for lost write detection' THEN 'REDO'
                WHEN 'redo writes'                     THEN 'REDO'
                WHEN 'user calls'                      THEN 'CALLS'
                WHEN 'execute count'                   THEN 'EXEC'
                WHEN 'user commits'                    THEN 'COMMIT'
                WHEN 'user rollbacks'                  THEN 'ROLLBACK'
                WHEN 'parse count (total)'             THEN 'PARSE'
                WHEN 'parse count (hard)'              THEN 'HARD_PARSE'
                WHEN 'parse count (failures)'          THEN 'HARD_PARSE'
                WHEN 'sorts (memory)'                  THEN 'SORTS'
                WHEN 'sorts (rows)'                    THEN 'SORTS'
                WHEN 'sorts (disk)'                    THEN 'SORTS_DISK'
                WHEN 'logons cumulative'               THEN 'SESSIONS'
                WHEN 'opened cursors cumulative'       THEN 'CURSORS'
                WHEN 'bytes sent via SQL*Net to client'       THEN 'NETWORK'
                WHEN 'bytes received via SQL*Net from client' THEN 'NETWORK'
                ELSE 'OTHER'
            END;
        END IF;
        IF p_domain = 'METRIC' THEN
            RETURN CASE p_name
                WHEN 'Average Active Sessions'         THEN 'DB_TIME'
                WHEN 'Host CPU Utilization (%)'        THEN 'CPU'
                WHEN 'Database CPU Time Ratio'         THEN 'CPU_WAIT_RATIO'
                WHEN 'Database Wait Time Ratio'        THEN 'CPU_WAIT_RATIO'
                WHEN 'Logical Reads Per Sec'           THEN 'LOGICAL_IO'
                WHEN 'Physical Reads Per Sec'          THEN 'READ_IO'
                WHEN 'Physical Read Total IO Requests Per Sec'  THEN 'READ_IO'
                WHEN 'Physical Read Total Bytes Per Sec'        THEN 'READ_IO'
                WHEN 'Average Synchronous Single-Block Read Latency' THEN 'READ_IO'
                WHEN 'Physical Writes Per Sec'         THEN 'WRITE_IO'
                WHEN 'Physical Write Total IO Requests Per Sec' THEN 'WRITE_IO'
                WHEN 'Physical Write Total Bytes Per Sec'       THEN 'WRITE_IO'
                WHEN 'Redo Generated Per Sec'          THEN 'REDO'
                WHEN 'User Calls Per Sec'              THEN 'CALLS'
                WHEN 'Executions Per Sec'              THEN 'EXEC'
                WHEN 'User Commits Per Sec'            THEN 'COMMIT'
                WHEN 'User Rollbacks Per Sec'          THEN 'ROLLBACK'
                WHEN 'Total Parse Count Per Sec'       THEN 'PARSE'
                WHEN 'Hard Parse Count Per Sec'        THEN 'HARD_PARSE'
                WHEN 'Logons Per Sec'                  THEN 'SESSIONS'
                WHEN 'Session Count'                   THEN 'SESSIONS'
                WHEN 'Network Traffic Volume Per Sec'  THEN 'NETWORK'
                WHEN 'SQL Service Response Time'       THEN 'RESPONSE'
                ELSE 'OTHER'
            END;
        END IF;
        RETURN 'OTHER';
    END finding_family;

    -- 'N' only for the SYSMETRIC rate twin of a SYSSTAT counter that is
    -- always present (the counter is canonical: primary source, kept by
    -- every shipped template), and for the CPU-time ratio (the wait-time
    -- ratio is the canonical half of that complementary pair).
    FUNCTION is_canonical(p_domain IN VARCHAR2,
                          p_name   IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_domain = 'METRIC' AND p_name IN (
               'Average Active Sessions',            -- twin of DB time
               'Logical Reads Per Sec',              -- session logical reads
               'Physical Reads Per Sec',             -- physical reads
               'Physical Read Total Bytes Per Sec',  -- physical read total bytes
               'Physical Writes Per Sec',            -- physical writes
               'Physical Write Total Bytes Per Sec', -- physical write total bytes
               'Redo Generated Per Sec',             -- redo size
               'User Calls Per Sec',                 -- user calls
               'Executions Per Sec',                 -- execute count
               'User Commits Per Sec',               -- user commits
               'User Rollbacks Per Sec',             -- user rollbacks
               'Total Parse Count Per Sec',          -- parse count (total)
               'Hard Parse Count Per Sec',           -- parse count (hard)
               'Logons Per Sec',                     -- logons cumulative
               'Database CPU Time Ratio')            -- 100 - wait time ratio
        THEN
            RETURN 'N';
        END IF;
        RETURN 'Y';
    END is_canonical;

    -- 'Y' = a rise is bad and a fall is an improvement (cost-type names);
    -- '-' = either direction is a finding (throughput: a drop can be an
    -- outage; ratios and everything unknown).
    FUNCTION higher_is_worse(p_domain IN VARCHAR2,
                             p_name   IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_domain = 'WAIT' THEN
            RETURN 'Y';
        END IF;
        IF p_domain = 'LOAD' AND p_name IN (
               'parse count (hard)', 'parse count (failures)',
               'sorts (disk)', 'user rollbacks', 'table scans (long tables)')
        THEN
            RETURN 'Y';
        END IF;
        IF p_domain = 'METRIC' AND p_name IN (
               'Average Synchronous Single-Block Read Latency',
               'SQL Service Response Time', 'Database Wait Time Ratio',
               'Hard Parse Count Per Sec', 'User Rollbacks Per Sec')
        THEN
            RETURN 'Y';
        END IF;
        RETURN '-';
    END higher_is_worse;
