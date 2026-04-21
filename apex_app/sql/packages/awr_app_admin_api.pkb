CREATE OR REPLACE PACKAGE BODY awr_app_admin_api AS
    FUNCTION job_exists(p_job_name IN VARCHAR2) RETURN BOOLEAN IS
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO   l_count
        FROM   user_scheduler_jobs
        WHERE  job_name = UPPER(p_job_name);

        RETURN l_count > 0;
    END job_exists;

    PROCEDURE ensure_schedule_job(
        p_schedule_id     IN NUMBER,
        p_repeat_interval IN VARCHAR2,
        p_job_name        IN VARCHAR2
    ) IS
    BEGIN
        IF job_exists(p_job_name) THEN
            DBMS_SCHEDULER.DROP_JOB(job_name => p_job_name, force => TRUE);
        END IF;

        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => p_job_name,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'BEGIN awr_app_run_api.execute_schedule(' || TO_CHAR(p_schedule_id) || '); END;',
            start_date      => SYSTIMESTAMP,
            repeat_interval => p_repeat_interval,
            enabled         => TRUE,
            auto_drop       => FALSE,
            comments        => 'Recurring AWR schedule ' || TO_CHAR(p_schedule_id)
        );
    END ensure_schedule_job;

    PROCEDURE sync_schedules IS
        l_job_name VARCHAR2(128);
    BEGIN
        FOR s IN (
            SELECT s.schedule_id,
                   s.repeat_interval,
                   s.enabled_flag,
                   t.enabled_flag AS target_enabled_flag
            FROM   awr_app_schedules s
            JOIN   awr_app_targets t
                   ON t.target_id = s.target_id
        ) LOOP
            l_job_name := 'AWR_APP_SCHED_' || TO_CHAR(s.schedule_id);

            IF s.enabled_flag = 'Y' AND s.target_enabled_flag = 'Y' THEN
                ensure_schedule_job(
                    p_schedule_id     => s.schedule_id,
                    p_repeat_interval => s.repeat_interval,
                    p_job_name        => l_job_name
                );

                UPDATE awr_app_schedules
                SET    scheduler_job_name = l_job_name,
                       updated_at         = SYSTIMESTAMP
                WHERE  schedule_id = s.schedule_id;
            ELSE
                IF job_exists(l_job_name) THEN
                    DBMS_SCHEDULER.DROP_JOB(job_name => l_job_name, force => TRUE);
                END IF;

                UPDATE awr_app_schedules
                SET    scheduler_job_name = NULL,
                       updated_at         = SYSTIMESTAMP
                WHERE  schedule_id = s.schedule_id;
            END IF;
        END LOOP;

        FOR j IN (
            SELECT job_name
            FROM   user_scheduler_jobs
            WHERE  job_name LIKE 'AWR_APP_SCHED_%'
            MINUS
            SELECT scheduler_job_name
            FROM   awr_app_schedules
            WHERE  scheduler_job_name IS NOT NULL
        ) LOOP
            DBMS_SCHEDULER.DROP_JOB(job_name => j.job_name, force => TRUE);
        END LOOP;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END sync_schedules;

    PROCEDURE run_schedule_now(p_schedule_id IN NUMBER) IS
    BEGIN
        awr_app_run_api.execute_schedule(p_schedule_id);
    END run_schedule_now;
END awr_app_admin_api;
/
