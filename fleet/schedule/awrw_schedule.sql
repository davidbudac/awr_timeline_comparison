--
-- fleet/schedule/awrw_schedule.sql
--
-- Orchestration: one DBMS_SCHEDULER job that runs the whole fleet cycle
-- collect -> health -> analyze -> digest, end to end, on a cadence. This is the
-- "schedule / loop" the toolkit is built around -- unattended, the warehouse
-- keeps itself current and re-renders the Digest each cycle.
--
-- run_pipeline is phase-isolated: collect_all and analyze_all already swallow
-- per-Target failures (one bad DB never blocks the fleet), and the digest step is
-- wrapped here too, so a single phase erroring never aborts the cycle. Each phase
-- bookends a row in awrw_run_log so "what is happening" is queryable.
--
-- The warehouse owner needs CREATE JOB (GRANT CREATE JOB TO <owner>) to create
-- the job. Delivery (email/Slack) is intentionally NOT in the job: a mailer reads
-- the latest awrw_digest row (see fleet/README.md). Warehouse-side only.
--
CREATE OR REPLACE PACKAGE awrw_schedule AS
    -- One full cycle, phase-isolated. Safe to call directly or from the job.
    PROCEDURE run_pipeline;
    -- Create (or replace) the recurring pipeline job. Default: top of every hour.
    PROCEDURE create_jobs(p_repeat_interval VARCHAR2 DEFAULT 'FREQ=HOURLY;BYMINUTE=5');
    -- Drop the pipeline job.
    PROCEDURE drop_jobs;
END awrw_schedule;
/

CREATE OR REPLACE PACKAGE BODY awrw_schedule AS

    c_job CONSTANT VARCHAR2(30) := 'AWRW_PIPELINE';

    -- bookend a phase in awrw_run_log; never let logging failure abort the cycle
    PROCEDURE phase(p_phase VARCHAR2, p_status VARCHAR2, p_detail VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO awrw_run_log (phase, status, detail,
               started_ts, ended_ts)
        VALUES (p_phase, p_status, p_detail,
               SYSTIMESTAMP, CASE WHEN p_status <> 'RUNNING' THEN SYSTIMESTAMP END);
        COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END phase;

    PROCEDURE run_pipeline IS
        v_id NUMBER;
    BEGIN
        phase('PIPELINE', 'RUNNING');

        BEGIN
            awrw_collect.collect_all;
            awrw_collect.refresh_health;
            phase('COLLECT', 'OK');
        EXCEPTION WHEN OTHERS THEN phase('COLLECT', 'ERROR', SUBSTR(SQLERRM,1,400));
        END;

        BEGIN
            awrw_analyze.analyze_all;
            phase('ANALYZE', 'OK');
        EXCEPTION WHEN OTHERS THEN phase('ANALYZE', 'ERROR', SUBSTR(SQLERRM,1,400));
        END;

        BEGIN
            v_id := awrw_notify.run_digest;
            phase('NOTIFY', 'OK', 'digest_id='||v_id);
        EXCEPTION WHEN OTHERS THEN phase('NOTIFY', 'ERROR', SUBSTR(SQLERRM,1,400));
        END;

        phase('PIPELINE', 'OK');
    END run_pipeline;

    PROCEDURE create_jobs(p_repeat_interval VARCHAR2 DEFAULT 'FREQ=HOURLY;BYMINUTE=5') IS
    BEGIN
        drop_jobs;
        DBMS_SCHEDULER.create_job(
            job_name        => c_job,
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'BEGIN awrw_schedule.run_pipeline; END;',
            repeat_interval => p_repeat_interval,
            enabled         => TRUE,
            comments        => 'AWR fleet: collect -> health -> analyze -> digest');
    END create_jobs;

    PROCEDURE drop_jobs IS
    BEGIN
        DBMS_SCHEDULER.drop_job(c_job, force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;   -- not present yet
    END drop_jobs;

END awrw_schedule;
/
