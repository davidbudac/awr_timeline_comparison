CREATE OR REPLACE PACKAGE BODY awr_app_run_api AS
    TYPE t_target_defaults IS RECORD (
        target_id          awr_app_targets.target_id%TYPE,
        target_name        awr_app_targets.target_name%TYPE,
        db_link_name       awr_app_targets.db_link_name%TYPE,
        default_win_hours  awr_app_targets.default_win_hours%TYPE,
        default_weeks_back awr_app_targets.default_weeks_back%TYPE,
        default_top_n      awr_app_targets.default_top_n%TYPE,
        default_inst_num   awr_app_targets.default_inst_num%TYPE,
        enabled_flag       awr_app_targets.enabled_flag%TYPE
    );

    FUNCTION current_requester RETURN VARCHAR2 IS
        l_apex_user VARCHAR2(255);
        l_db_user   VARCHAR2(255);
    BEGIN
        l_apex_user := SYS_CONTEXT('APEX$SESSION', 'APP_USER');
        l_db_user := SYS_CONTEXT('USERENV', 'SESSION_USER');
        RETURN NVL(l_apex_user, l_db_user);
    END current_requester;

    FUNCTION current_source RETURN VARCHAR2 IS
    BEGIN
        IF SYS_CONTEXT('APEX$SESSION', 'APP_USER') IS NOT NULL THEN
            RETURN 'APEX';
        ELSIF SYS_CONTEXT('USERENV', 'BG_JOB_ID') IS NOT NULL THEN
            RETURN 'SCHEDULER';
        ELSE
            RETURN 'API';
        END IF;
    END current_source;

    FUNCTION job_exists(p_job_name IN VARCHAR2) RETURN BOOLEAN IS
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO   l_count
        FROM   user_scheduler_jobs
        WHERE  job_name = UPPER(p_job_name);

        RETURN l_count > 0;
    END job_exists;

    FUNCTION get_target_defaults(p_target_id IN NUMBER) RETURN t_target_defaults IS
        l_target t_target_defaults;
    BEGIN
        SELECT target_id,
               target_name,
               db_link_name,
               default_win_hours,
               default_weeks_back,
               default_top_n,
               default_inst_num,
               enabled_flag
        INTO   l_target
        FROM   awr_app_targets
        WHERE  target_id = p_target_id;

        RETURN l_target;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20100, 'Unknown target_id ' || p_target_id);
    END get_target_defaults;

    FUNCTION submit_run(
        p_target_id       IN NUMBER,
        p_target_end_ts   IN TIMESTAMP DEFAULT NULL,
        p_win_hours       IN NUMBER DEFAULT NULL,
        p_weeks_back      IN NUMBER DEFAULT NULL,
        p_top_n           IN NUMBER DEFAULT NULL,
        p_inst_num        IN NUMBER DEFAULT NULL
    ) RETURN NUMBER IS
        l_target        t_target_defaults;
        l_run_id        NUMBER;
        l_target_end_ts TIMESTAMP;
        l_win_hours     NUMBER;
        l_weeks_back    NUMBER;
        l_top_n         NUMBER;
        l_inst_num      NUMBER;
        l_requester     VARCHAR2(255);
        l_source        VARCHAR2(30);
    BEGIN
        l_target := get_target_defaults(p_target_id);

        IF l_target.enabled_flag <> 'Y' THEN
            RAISE_APPLICATION_ERROR(-20101, 'Target ' || l_target.target_name || ' is disabled.');
        END IF;

        l_target_end_ts := NVL(p_target_end_ts, CAST(TRUNC(SYSDATE, 'HH24') AS TIMESTAMP));
        l_win_hours := NVL(p_win_hours, l_target.default_win_hours);
        l_weeks_back := NVL(p_weeks_back, l_target.default_weeks_back);
        l_top_n := NVL(p_top_n, l_target.default_top_n);
        l_inst_num := NVL(p_inst_num, l_target.default_inst_num);
        l_requester := current_requester;
        l_source := current_source;
        l_run_id := awr_trend_run_seq.NEXTVAL;

        INSERT INTO awr_trend_runs (
            run_id,
            dbid,
            db_name,
            instance_number,
            target_end_ts,
            win_hours,
            weeks_back,
            top_n,
            scope,
            generated_at,
            report_path,
            caller_user,
            status,
            error_text,
            target_id,
            requested_by,
            request_source,
            started_at,
            finished_at,
            scheduler_job_name
        ) VALUES (
            l_run_id,
            0,
            NULL,
            CASE WHEN l_inst_num = 0 THEN NULL ELSE l_inst_num END,
            l_target_end_ts,
            l_win_hours,
            l_weeks_back,
            l_top_n,
            CASE WHEN l_inst_num = 0 THEN 'ALL' ELSE 'INSTANCE' END,
            SYSTIMESTAMP,
            NULL,
            USER,
            'QUEUED',
            NULL,
            p_target_id,
            l_requester,
            l_source,
            NULL,
            NULL,
            NULL
        );

        COMMIT;

        awr_app_collect_pkg.log_event(
            p_run_id    => l_run_id,
            p_step_name => 'submit_run',
            p_status    => 'INFO',
            p_message   => 'Queued run for target ' || l_target.target_name
                           || ' window ending ' || TO_CHAR(l_target_end_ts, 'YYYY-MM-DD HH24:MI'),
            p_log_level => 'INFO'
        );

        RETURN l_run_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END submit_run;

    PROCEDURE enqueue_run(p_run_id IN NUMBER) IS
        l_job_name VARCHAR2(128) := 'AWR_APP_RUN_' || TO_CHAR(p_run_id);
    BEGIN
        IF job_exists(l_job_name) THEN
            DBMS_SCHEDULER.DROP_JOB(job_name => l_job_name, force => TRUE);
        END IF;

        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => l_job_name,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'BEGIN awr_app_run_api.execute_run(' || TO_CHAR(p_run_id) || '); END;',
            start_date      => SYSTIMESTAMP,
            enabled         => FALSE,
            auto_drop       => TRUE,
            comments        => 'One-off AWR trend run ' || TO_CHAR(p_run_id)
        );
        DBMS_SCHEDULER.ENABLE(l_job_name);

        UPDATE awr_trend_runs
        SET    scheduler_job_name = l_job_name
        WHERE  run_id = p_run_id;

        COMMIT;

        awr_app_collect_pkg.log_event(
            p_run_id    => p_run_id,
            p_step_name => 'enqueue_run',
            p_status    => 'INFO',
            p_message   => 'Enqueued scheduler job ' || l_job_name,
            p_log_level => 'INFO'
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            awr_app_collect_pkg.log_event(
                p_run_id    => p_run_id,
                p_step_name => 'enqueue_run',
                p_status    => 'FAILED',
                p_message   => 'Unable to enqueue scheduler job: ' || SQLERRM,
                p_log_level => 'ERROR',
                p_details   => DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END enqueue_run;

    PROCEDURE execute_run(p_run_id IN NUMBER) IS
        l_error_text VARCHAR2(4000);
    BEGIN
        UPDATE awr_trend_runs
        SET    status     = 'RUNNING',
               started_at = SYSTIMESTAMP,
               finished_at = NULL,
               error_text = NULL
        WHERE  run_id = p_run_id;
        COMMIT;

        awr_app_collect_pkg.log_event(
            p_run_id    => p_run_id,
            p_step_name => 'execute_run',
            p_status    => 'STARTED',
            p_message   => 'Run execution started.'
        );

        awr_app_collect_pkg.purge_run_data(p_run_id);
        awr_app_collect_pkg.initialize_run(p_run_id);
        awr_app_collect_pkg.collect_windows(p_run_id);
        awr_app_collect_pkg.collect_load_profile(p_run_id);
        awr_app_collect_pkg.collect_sysmetric(p_run_id);
        awr_app_collect_pkg.collect_waits(p_run_id);
        awr_app_collect_pkg.collect_top_sql(p_run_id);
        awr_app_collect_pkg.collect_findings(p_run_id);

        UPDATE awr_trend_runs
        SET    status      = 'OK',
               finished_at = SYSTIMESTAMP,
               error_text  = NULL
        WHERE  run_id = p_run_id;
        COMMIT;

        awr_app_collect_pkg.log_event(
            p_run_id    => p_run_id,
            p_step_name => 'execute_run',
            p_status    => 'OK',
            p_message   => 'Run execution completed successfully.'
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            l_error_text := SUBSTR(SQLERRM, 1, 4000);

            UPDATE awr_trend_runs
            SET    status      = 'FAILED',
                   finished_at = SYSTIMESTAMP,
                   error_text  = l_error_text
            WHERE  run_id = p_run_id;
            COMMIT;

            awr_app_collect_pkg.log_event(
                p_run_id    => p_run_id,
                p_step_name => 'execute_run',
                p_status    => 'FAILED',
                p_message   => 'Run execution failed: ' || SQLERRM,
                p_log_level => 'ERROR',
                p_details   => DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END execute_run;

    PROCEDURE execute_schedule(p_schedule_id IN NUMBER) IS
        l_run_id NUMBER;
        l_sched  awr_app_schedules%ROWTYPE;
        l_error_text VARCHAR2(4000);
    BEGIN
        SELECT *
        INTO   l_sched
        FROM   awr_app_schedules
        WHERE  schedule_id = p_schedule_id;

        IF l_sched.enabled_flag <> 'Y' THEN
            RAISE_APPLICATION_ERROR(-20102, 'Schedule ' || l_sched.schedule_name || ' is disabled.');
        END IF;

        UPDATE awr_app_schedules
        SET    last_requested_at = SYSTIMESTAMP,
               last_status       = 'QUEUED',
               last_error_text   = NULL,
               updated_at        = SYSTIMESTAMP
        WHERE  schedule_id = p_schedule_id;
        COMMIT;

        l_run_id := submit_run(
            p_target_id     => l_sched.target_id,
            p_target_end_ts => l_sched.override_target_end_ts,
            p_win_hours     => l_sched.override_win_hours,
            p_weeks_back    => l_sched.override_weeks_back,
            p_top_n         => l_sched.override_top_n,
            p_inst_num      => l_sched.override_inst_num
        );

        UPDATE awr_trend_runs
        SET    request_source = 'SCHEDULER'
        WHERE  run_id = l_run_id;

        UPDATE awr_app_schedules
        SET    last_run_id     = l_run_id,
               last_started_at = SYSTIMESTAMP,
               last_status     = 'RUNNING',
               updated_at      = SYSTIMESTAMP
        WHERE  schedule_id = p_schedule_id;
        COMMIT;

        BEGIN
            execute_run(l_run_id);

            UPDATE awr_app_schedules
            SET    last_finished_at = SYSTIMESTAMP,
                   last_status      = 'OK',
                   last_error_text  = NULL,
                   last_run_id      = l_run_id,
                   updated_at       = SYSTIMESTAMP
            WHERE  schedule_id = p_schedule_id;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_text := SUBSTR(SQLERRM, 1, 4000);
                UPDATE awr_app_schedules
                SET    last_finished_at = SYSTIMESTAMP,
                       last_status      = 'FAILED',
                       last_error_text  = l_error_text,
                       last_run_id      = l_run_id,
                       updated_at       = SYSTIMESTAMP
                WHERE  schedule_id = p_schedule_id;
                COMMIT;
                RAISE;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            IF l_run_id IS NULL THEN
                l_error_text := SUBSTR(SQLERRM, 1, 4000);
                UPDATE awr_app_schedules
                SET    last_finished_at = SYSTIMESTAMP,
                       last_status      = 'FAILED',
                       last_error_text  = l_error_text,
                       updated_at       = SYSTIMESTAMP
                WHERE  schedule_id = p_schedule_id;
                COMMIT;
            END IF;
            RAISE;
    END execute_schedule;
END awr_app_run_api;
/
