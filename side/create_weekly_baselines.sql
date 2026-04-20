--
-- side/create_weekly_baselines.sql
--
-- Optional helper, NOT called by awr_trend.sql.  Creates an AWR baseline
-- covering each of the past N ISO weeks (Mon 00:00 -> next Mon 00:00) so
-- that awrddrpt.sql / OEM can later reference them directly.
--
-- Requires: EXECUTE on DBMS_WORKLOAD_REPOSITORY; Diagnostic Pack license.
--
-- Usage:
--   sqlplus user/pw@svc @side/create_weekly_baselines.sql
--   (or DEFINE weeks_back = 4 / prefix = 'WK_' / expire_days = 365 first.)
--
-- Idempotent: baselines that already exist (matched by name) are skipped.
--

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
SET DEFINE '~'

DEFINE weeks_back  = 1
DEFINE prefix      = 'WK_'
DEFINE expire_days = 365

DECLARE
    v_weeks_back   NUMBER := ~weeks_back;
    v_prefix       VARCHAR2(20) := '~prefix';
    v_expire_days  NUMBER := ~expire_days;
    v_dbid         NUMBER;
    v_inst         NUMBER;
    v_name         VARCHAR2(128);
    v_start_dt     DATE;
    v_end_dt       DATE;
    v_begin_snap   NUMBER;
    v_end_snap     NUMBER;
    v_exists       NUMBER;
    v_created      NUMBER := 0;
    v_skipped      NUMBER := 0;
    v_failed       NUMBER := 0;
BEGIN
    SELECT dbid INTO v_dbid FROM v$database;
    SELECT instance_number INTO v_inst FROM v$instance;

    FOR k IN 1 .. v_weeks_back LOOP
        -- Find the Monday 00:00 of the target ISO week.
        -- TRUNC(SYSDATE, 'IW') is Monday-of-current-ISO-week at 00:00.
        v_end_dt   := TRUNC(SYSDATE, 'IW') - 7 * (k - 1);   -- current-week Monday, minus k-1 weeks
        v_start_dt := v_end_dt - 7;                          -- previous Monday
        v_name     := v_prefix
                   || TO_CHAR(v_start_dt, 'IYYY') || '_'
                   || LPAD(TO_CHAR(v_start_dt, 'IW'), 2, '0');

        -- Idempotency check.
        SELECT COUNT(*) INTO v_exists
        FROM   dba_hist_baseline
        WHERE  dbid = v_dbid AND baseline_name = v_name;

        IF v_exists > 0 THEN
            DBMS_OUTPUT.PUT_LINE('skip  : ' || v_name || '  (already exists)');
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- Resolve snap bounds with the same tolerance used by the main tool.
        SELECT MAX(snap_id)
        INTO   v_begin_snap
        FROM   dba_hist_snapshot
        WHERE  dbid = v_dbid
        AND    instance_number = v_inst
        AND    end_interval_time <= CAST(v_start_dt + 5/1440 AS TIMESTAMP);

        SELECT MIN(snap_id)
        INTO   v_end_snap
        FROM   dba_hist_snapshot
        WHERE  dbid = v_dbid
        AND    instance_number = v_inst
        AND    end_interval_time >= CAST(v_end_dt - 5/1440 AS TIMESTAMP);

        IF v_begin_snap IS NULL OR v_end_snap IS NULL OR v_begin_snap >= v_end_snap THEN
            DBMS_OUTPUT.PUT_LINE('skip  : ' || v_name
                || '  (no bounding snapshots; AWR may have been purged for '
                || TO_CHAR(v_start_dt, 'YYYY-MM-DD') || ')');
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        BEGIN
            DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE(
                start_snap_id  => v_begin_snap,
                end_snap_id    => v_end_snap,
                baseline_name  => v_name,
                dbid           => v_dbid,
                expiration     => v_expire_days
            );
            v_created := v_created + 1;
            DBMS_OUTPUT.PUT_LINE('create: ' || v_name
                || '  (snap ' || v_begin_snap || ' -> ' || v_end_snap
                || ', ' || TO_CHAR(v_start_dt, 'YYYY-MM-DD') || ' -> '
                || TO_CHAR(v_end_dt, 'YYYY-MM-DD') || ')');
        EXCEPTION
            WHEN OTHERS THEN
                v_failed := v_failed + 1;
                DBMS_OUTPUT.PUT_LINE('FAIL  : ' || v_name || '  [' || SQLERRM || ']');
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Summary: ' || v_created || ' created, '
        || v_skipped || ' skipped, ' || v_failed || ' failed.');
    DBMS_OUTPUT.PUT_LINE('List baselines:  SELECT baseline_name, start_snap_id, end_snap_id, creation_time'
        || ' FROM dba_hist_baseline ORDER BY start_snap_id;');
END;
/

SET FEEDBACK ON
