--
-- sql/lib/metric_policy.plsql
--
-- THE per-metric scoring policy: one line per scored name, editable by a
-- human.  Every consumer that turns "Current vs prior windows" into a
-- change bucket (00 verdict, 07 findings, 08 hero cards, 16 day profile,
-- 17 narrative, and 04/05/06/14/15/18 through sql/lib/score_cells.plsql)
-- reads this table, so editing a line here changes the whole report.
--
-- Columns of pol(family, canonical, dir, min_pct, min_abs):
--
--   family     one physical quantity or one story per family; a SYSSTAT
--              counter and its SYSMETRIC rate twin share a family and
--              count as ONE finding
--   canonical  'Y' = counted; 'N' = a twin of a counted name (scored and
--              rendered muted, never counted in the verdict / heading)
--   dir        which direction is bad news:
--                UP    a rise is a finding, a drop is "improved" (cost-type
--                      names: waits, latency, hard parses, I/O, CPU)
--                DOWN  a drop is a finding, a rise is "improved" (e.g. the
--                      CPU-time ratio: less CPU share means more waiting)
--                ANY   both directions are findings, neither is an
--                      improvement (throughput: a drop can be an outage)
--                INFO  never a finding; a material move renders as "noted"
--                      (bookkeeping counters nobody should page on)
--              "improved" and "noted" are never highlighted: no row tint,
--              not in Biggest movers, not in the verdict count.
--   min_pct    minimum |%-delta| for a move to be material (a 3-sigma move
--              of 4% is still 4%)
--   min_abs    value floor in the metric's OWN unit: when neither Current
--              nor the prior mean reaches it the move is immaterial, so a
--              hard-parse rate going 0.1 -> 0.5 /s (+400%) is never a
--              finding.  NULL = no floor.
--              Units: LOAD rows are per-second rates of the raw SYSSTAT
--              counter (DB time / DB CPU / CPU used by this session are
--              CENTISECONDS per second, so 100 = one busy CPU or one
--              average active session; bytes stats are bytes/s); METRIC
--              rows are the SYSMETRIC unit (%, ms, /s, bytes/s, cs per
--              call); WAIT rows use min_abs as the minimum SHARE (0..1)
--              of the Current window's total non-idle wait time.
--
-- Name lookup: domain 'LOAD' (DBA_HIST_SYSSTAT names), 'METRIC'
-- (DBA_HIST_SYSMETRIC_SUMMARY names), 'WAIT' (an event name with its
-- wait_class, or 'Wait class: <class>' for the class rollups): a per-event
-- override wins, then the class policy, then the WAIT default.  Any other
-- domain ('SQL' 06/18, 'SEG' 14, 'FILE' 15) or an unmapped name falls
-- through to the conservative defaults at the bottom (own family,
-- canonical, both directions, 10%, no floor) so a template-specific name
-- is never folded, hidden or mis-directed.
--
-- Usage: include inside a DECLARE block, before BEGIN (and BEFORE
-- sql/lib/score_cells.plsql, which calls policy_bucket):
--     two at-signs + sql/lib/metric_policy.plsql
-- lint.sh check 12 verifies every template LOAD/METRIC name has a line
-- here; demo/awrdemo/helpers.py parses this file, so keep the one-line
-- "WHEN 'name' THEN RETURN pol(...)" shape.
--
    TYPE policy_rec IS RECORD (
        family    VARCHAR2(64),
        canonical VARCHAR2(1),
        dir       VARCHAR2(4),
        min_pct   NUMBER,
        min_abs   NUMBER
    );

    FUNCTION pol(p_family VARCHAR2, p_canonical VARCHAR2, p_dir VARCHAR2,
                 p_min_pct NUMBER, p_min_abs NUMBER) RETURN policy_rec IS
        r policy_rec;
    BEGIN
        r.family    := p_family;
        r.canonical := p_canonical;
        r.dir       := p_dir;
        r.min_pct   := p_min_pct;
        r.min_abs   := p_min_abs;
        RETURN r;
    END pol;

    -- Wait rows: family is always the wait class; min_abs is a share.
    FUNCTION wpol(p_class VARCHAR2, p_dir VARCHAR2,
                  p_min_pct NUMBER, p_min_share NUMBER) RETURN policy_rec IS
    BEGIN
        RETURN pol('WAIT:' || p_class, 'Y', p_dir, p_min_pct, p_min_share);
    END wpol;

    FUNCTION metric_policy(p_domain IN VARCHAR2,
                           p_name   IN VARCHAR2,
                           p_class  IN VARCHAR2 DEFAULT NULL) RETURN policy_rec IS
        v_class VARCHAR2(64);
    BEGIN
        IF p_domain = 'LOAD' THEN
            -- ======================= LOAD (DBA_HIST_SYSSTAT, per second) =======================
            --    name                                          family        canon dir     min%  min_abs
            CASE p_name
            WHEN 'DB time'                              THEN RETURN pol('DB_TIME',       'Y', 'UP',   15, 20);      -- cs/s; 20 = 0.2 avg active sessions
            WHEN 'DB CPU'                               THEN RETURN pol('CPU',           'Y', 'UP',   15, 10);      -- cs/s; 10 = 0.1 CPU busy
            WHEN 'CPU used by this session'             THEN RETURN pol('CPU',           'N', 'UP',   15, 10);      -- twin of DB CPU
            WHEN 'session logical reads'                THEN RETURN pol('LOGICAL_IO',    'Y', 'UP',   20, 1000);    -- blocks/s
            WHEN 'physical reads'                       THEN RETURN pol('READ_IO',       'Y', 'UP',   20, 50);      -- blocks/s
            WHEN 'physical read total bytes'            THEN RETURN pol('READ_IO',       'Y', 'UP',   20, 1048576); -- 1 MB/s
            WHEN 'physical writes'                      THEN RETURN pol('WRITE_IO',      'Y', 'UP',   20, 20);      -- blocks/s
            WHEN 'physical write total bytes'           THEN RETURN pol('WRITE_IO',      'Y', 'UP',   20, 1048576); -- 1 MB/s
            WHEN 'redo size'                            THEN RETURN pol('REDO',          'Y', 'UP',   20, 10240);   -- 10 KB/s
            WHEN 'redo size for lost write detection'   THEN RETURN pol('REDO',          'N', 'INFO', 20, NULL);    -- bookkeeping
            WHEN 'redo writes'                          THEN RETURN pol('REDO',          'Y', 'UP',   20, 1);       -- writes/s
            WHEN 'user calls'                           THEN RETURN pol('CALLS',         'Y', 'ANY',  20, 10);      -- a drop can be an outage
            WHEN 'user commits'                         THEN RETURN pol('COMMIT',        'Y', 'ANY',  20, 1);
            WHEN 'user rollbacks'                       THEN RETURN pol('ROLLBACK',      'Y', 'UP',   25, 0.5);
            WHEN 'execute count'                        THEN RETURN pol('EXEC',          'Y', 'ANY',  20, 10);
            WHEN 'parse count (total)'                  THEN RETURN pol('PARSE',         'Y', 'UP',   20, 10);
            WHEN 'parse count (hard)'                   THEN RETURN pol('HARD_PARSE',    'Y', 'UP',   25, 2);       -- below 2/s nobody cares
            WHEN 'parse count (failures)'               THEN RETURN pol('HARD_PARSE',    'Y', 'UP',   25, 0.5);
            WHEN 'sorts (memory)'                       THEN RETURN pol('SORTS',         'Y', 'INFO', 20, NULL);    -- workload shape, not a problem
            WHEN 'sorts (disk)'                         THEN RETURN pol('SORTS_DISK',    'Y', 'UP',   25, 0.5);
            WHEN 'sorts (rows)'                         THEN RETURN pol('SORTS',         'Y', 'INFO', 20, NULL);
            WHEN 'logons cumulative'                    THEN RETURN pol('SESSIONS',      'Y', 'UP',   25, 1);       -- logon storms
            WHEN 'opened cursors cumulative'            THEN RETURN pol('CURSORS',       'Y', 'INFO', 20, NULL);
            WHEN 'table scans (long tables)'            THEN RETURN pol('SCANS',         'Y', 'UP',   25, 0.5);
            WHEN 'table fetch by rowid'                 THEN RETURN pol('LOGICAL_IO',    'Y', 'INFO', 20, NULL);    -- access-path mix, see logical reads
            WHEN 'bytes sent via SQL*Net to client'     THEN RETURN pol('NETWORK',       'Y', 'UP',   30, 102400);  -- 100 KB/s
            WHEN 'bytes received via SQL*Net from client' THEN RETURN pol('NETWORK',     'Y', 'UP',   30, 102400);
            ELSE NULL;
            END CASE;
        ELSIF p_domain = 'METRIC' THEN
            -- ================= METRIC (DBA_HIST_SYSMETRIC_SUMMARY, metric unit) =================
            --    name                                          family        canon dir     min%  min_abs
            CASE p_name
            WHEN 'Host CPU Utilization (%)'             THEN RETURN pol('CPU',           'Y', 'UP',   20, 10);      -- % points
            WHEN 'Database CPU Time Ratio'              THEN RETURN pol('CPU_WAIT_RATIO','N', 'DOWN', 20, 10);      -- less CPU share = more waiting
            WHEN 'Database Wait Time Ratio'             THEN RETURN pol('CPU_WAIT_RATIO','Y', 'UP',   20, 10);      -- % points
            WHEN 'Average Active Sessions'              THEN RETURN pol('DB_TIME',       'N', 'UP',   15, 0.2);     -- twin of DB time
            WHEN 'Average Synchronous Single-Block Read Latency' THEN RETURN pol('READ_IO', 'Y', 'UP', 25, 1);     -- ms; sub-ms is noise
            WHEN 'Physical Reads Per Sec'               THEN RETURN pol('READ_IO',       'N', 'UP',   20, 50);      -- twin of physical reads
            WHEN 'Physical Writes Per Sec'              THEN RETURN pol('WRITE_IO',      'N', 'UP',   20, 20);      -- twin of physical writes
            WHEN 'Physical Read Total IO Requests Per Sec'  THEN RETURN pol('READ_IO',   'Y', 'UP',   20, 50);      -- IOPS
            WHEN 'Physical Write Total IO Requests Per Sec' THEN RETURN pol('WRITE_IO',  'Y', 'UP',   20, 20);      -- IOPS
            WHEN 'Physical Read Total Bytes Per Sec'    THEN RETURN pol('READ_IO',       'N', 'UP',   20, 1048576); -- twin
            WHEN 'Physical Write Total Bytes Per Sec'   THEN RETURN pol('WRITE_IO',      'N', 'UP',   20, 1048576); -- twin
            WHEN 'Redo Generated Per Sec'               THEN RETURN pol('REDO',          'N', 'UP',   20, 10240);   -- twin of redo size
            WHEN 'Logons Per Sec'                       THEN RETURN pol('SESSIONS',      'N', 'UP',   25, 1);       -- twin of logons cumulative
            WHEN 'Logical Reads Per Sec'                THEN RETURN pol('LOGICAL_IO',    'N', 'UP',   20, 1000);    -- twin
            WHEN 'User Calls Per Sec'                   THEN RETURN pol('CALLS',         'N', 'ANY',  20, 10);      -- twin
            WHEN 'User Commits Per Sec'                 THEN RETURN pol('COMMIT',        'N', 'ANY',  20, 1);       -- twin
            WHEN 'User Rollbacks Per Sec'               THEN RETURN pol('ROLLBACK',      'N', 'UP',   25, 0.5);     -- twin
            WHEN 'Executions Per Sec'                   THEN RETURN pol('EXEC',          'N', 'ANY',  20, 10);      -- twin
            WHEN 'Hard Parse Count Per Sec'             THEN RETURN pol('HARD_PARSE',    'N', 'UP',   25, 2);       -- twin
            WHEN 'Total Parse Count Per Sec'            THEN RETURN pol('PARSE',         'N', 'UP',   20, 10);      -- twin
            WHEN 'Session Count'                        THEN RETURN pol('SESSIONS',      'Y', 'ANY',  20, 10);      -- storm or app gone
            WHEN 'Network Traffic Volume Per Sec'       THEN RETURN pol('NETWORK',       'N', 'UP',   30, 102400);  -- twin of the SQL*Net bytes
            WHEN 'SQL Service Response Time'            THEN RETURN pol('RESPONSE',      'Y', 'UP',   25, 0.1);     -- cs per user call; 0.1 = 1 ms
            ELSE NULL;
            END CASE;
        ELSIF p_domain = 'WAIT' THEN
            v_class := COALESCE(p_class, REGEXP_REPLACE(p_name, '^Wait class: ', ''), 'Other');
            -- ============ WAIT, per-event overrides (min_abs = share of Current wait) ============
            --    event                                                     dir    min%  min_share
            CASE p_name
            WHEN 'enq: TX - row lock contention'         THEN RETURN wpol(v_class, 'UP',   10, 0.01);  -- locks matter even when small
            WHEN 'enq: TM - contention'                  THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'enq: TX - index contention'            THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'library cache lock'                    THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'library cache: mutex X'                THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'cursor: pin S wait on X'               THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'row cache lock'                        THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'log file switch (checkpoint incomplete)' THEN RETURN wpol(v_class, 'UP', 10, 0.01);  -- configuration faults
            WHEN 'log file switch (archiving needed)'    THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'log buffer space'                      THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'free buffer waits'                     THEN RETURN wpol(v_class, 'UP',   10, 0.01);
            WHEN 'SQL*Net more data from client'         THEN RETURN wpol(v_class, 'UP',   30, 0.05);  -- application payload
            WHEN 'SQL*Net more data to client'           THEN RETURN wpol(v_class, 'UP',   30, 0.05);
            WHEN 'SQL*Net message to client'             THEN RETURN wpol(v_class, 'UP',   30, 0.05);
            WHEN 'PX Deq Credit: send blkd'              THEN RETURN wpol(v_class, 'UP',   25, 0.05);  -- parallel plumbing
            WHEN 'PX Deq: Slave Session Stats'           THEN RETURN wpol(v_class, 'UP',   25, 0.05);
            WHEN 'os thread creation'                    THEN RETURN wpol(v_class, 'UP',   25, 0.05);
            ELSE NULL;
            END CASE;
            -- ====================== WAIT, per-class policy (class rollups too) ======================
            --    wait class                dir    min%  min_share
            CASE v_class
            WHEN 'Application'   THEN RETURN wpol(v_class, 'UP',   10, 0.01);  -- locks, app-side serialization
            WHEN 'Configuration' THEN RETURN wpol(v_class, 'UP',   10, 0.01);  -- log switch / buffer / space issues
            WHEN 'Concurrency'   THEN RETURN wpol(v_class, 'UP',   15, 0.02);
            WHEN 'Commit'        THEN RETURN wpol(v_class, 'UP',   15, 0.02);
            WHEN 'User I/O'      THEN RETURN wpol(v_class, 'UP',   15, 0.02);
            WHEN 'Cluster'       THEN RETURN wpol(v_class, 'UP',   15, 0.02);
            WHEN 'System I/O'    THEN RETURN wpol(v_class, 'UP',   20, 0.03);  -- background, mostly LGWR/DBWR/ARCH
            WHEN 'Scheduler'     THEN RETURN wpol(v_class, 'UP',   20, 0.03);
            WHEN 'Network'       THEN RETURN wpol(v_class, 'UP',   25, 0.05);  -- driven by the application
            WHEN 'Other'         THEN RETURN wpol(v_class, 'UP',   25, 0.05);  -- noisy catch-all
            WHEN 'Administrative' THEN RETURN wpol(v_class, 'UP',  25, 0.05);
            WHEN 'Queueing'      THEN RETURN wpol(v_class, 'UP',   25, 0.05);
            ELSE                      RETURN wpol(v_class, 'UP',   15, 0.02);  -- any other class
            END CASE;
        ELSIF p_domain = 'SQL' THEN
            RETURN pol('SQL', 'Y', 'UP', 15, NULL);     -- 06 / 18: elapsed, CPU, I/O per statement
        ELSIF p_domain IN ('SEG', 'FILE') THEN
            RETURN pol(p_domain, 'Y', 'UP', 20, NULL);  -- 14 / 15: segment and file I/O
        END IF;
        -- Unmapped name (template-specific, or a new stat): own family,
        -- counted, both directions, the old 10% floor, no value floor.
        RETURN pol('OTHER', 'Y', 'ANY', 10, NULL);
    END metric_policy;

    -- Compatibility wrappers (00 / 07 / 08 read family and canonical).
    FUNCTION finding_family(p_domain IN VARCHAR2, p_name IN VARCHAR2,
                            p_class IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        r policy_rec := metric_policy(p_domain, p_name, p_class);
    BEGIN
        IF r.family = 'OTHER' THEN
            RETURN SUBSTR('OTHER:' || p_name, 1, 64);
        END IF;
        RETURN r.family;
    END finding_family;

    FUNCTION is_canonical(p_domain IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN metric_policy(p_domain, p_name).canonical;
    END is_canonical;

    -- The scoring rule (v1.5.0), applied through the policy above:
    --   z = (cur - mu) / GREATEST(sd, 2% of |mu|) over prior valid windows;
    --   |z| > 3 large, |z| > 2 moderate, else typical -- but only when the
    --   move is MATERIAL: |%-delta| >= min_pct and the value clears min_abs
    --   (share >= min_abs for WAIT rows when a share is given), otherwise
    --   typical (callers badge it "immaterial" when |z| cleared 2);
    --   then the direction: INFO -> 'noted'; a move in the good direction
    --   (drop for UP, rise for DOWN) -> 'improved'; p_demote = 'Y' turns
    --   large into moderate (04/05's table-wide-shift note).
    -- Other returns: 'n/a' (no Current), 'insufficient history' (n < 3),
    -- 'flat baseline' (no usable sigma).
    FUNCTION policy_bucket(p_domain VARCHAR2,
                           p_name   VARCHAR2,
                           p_class  VARCHAR2,
                           p_cur    NUMBER,
                           p_mu     NUMBER,
                           p_sd     NUMBER,
                           p_n      NUMBER,
                           p_share  NUMBER   DEFAULT NULL,
                           p_demote VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        r     policy_rec;
        v_den NUMBER;
        v_z   NUMBER;
        v_pct NUMBER;
        v_raw VARCHAR2(40);
    BEGIN
        IF p_cur IS NULL THEN
            RETURN 'n/a';
        ELSIF NVL(p_n, 0) < 3 THEN
            RETURN 'insufficient history';
        ELSIF p_mu IS NULL OR p_sd IS NULL THEN
            RETURN 'flat baseline';
        END IF;
        v_den := GREATEST(p_sd, 0.02 * ABS(p_mu));
        IF v_den = 0 THEN
            RETURN 'flat baseline';
        END IF;
        v_z := (p_cur - p_mu) / v_den;
        IF ABS(v_z) <= 2 THEN
            RETURN 'typical';
        END IF;
        r := metric_policy(p_domain, p_name, p_class);
        v_pct := CASE WHEN p_mu = 0 THEN NULL ELSE (p_cur - p_mu) / ABS(p_mu) * 100 END;
        IF v_pct IS NOT NULL AND ABS(v_pct) < NVL(r.min_pct, 10) THEN
            RETURN 'typical';
        END IF;
        IF r.min_abs IS NOT NULL THEN
            IF p_domain = 'WAIT' THEN
                IF p_share IS NOT NULL AND p_share < r.min_abs THEN
                    RETURN 'typical';
                END IF;
            ELSIF GREATEST(ABS(p_cur), ABS(p_mu)) < r.min_abs THEN
                RETURN 'typical';
            END IF;
        ELSIF p_domain = 'WAIT' AND p_share IS NOT NULL AND p_share < 0.02 THEN
            RETURN 'typical';
        END IF;
        IF r.dir = 'INFO' THEN
            RETURN 'noted';
        END IF;
        IF (r.dir = 'UP' AND p_cur < p_mu) OR (r.dir = 'DOWN' AND p_cur > p_mu) THEN
            RETURN 'improved';
        END IF;
        v_raw := CASE WHEN ABS(v_z) > 3 THEN 'large' ELSE 'moderate' END;
        IF p_demote = 'Y' AND v_raw = 'large' THEN
            RETURN 'moderate';
        END IF;
        RETURN v_raw;
    END policy_bucket;
