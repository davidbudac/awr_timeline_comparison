SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT Ensuring compatible AWR_TREND_* repository objects exist ...

DECLARE
    PROCEDURE exec_ignore(
        p_sql          IN CLOB,
        p_ignore_codes IN VARCHAR2 DEFAULT '-955,-1430,-1442,-2260,-2275,-01430,-01442'
    ) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  OK  : ' || SUBSTR(REPLACE(p_sql, CHR(10), ' '), 1, 120));
    EXCEPTION
        WHEN OTHERS THEN
            IF INSTR(',' || p_ignore_codes || ',', ',' || TO_CHAR(SQLCODE) || ',') > 0 THEN
                DBMS_OUTPUT.PUT_LINE('  skip: ' || SUBSTR(REPLACE(p_sql, CHR(10), ' '), 1, 120)
                    || ' [' || SQLCODE || ']');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  FAIL: ' || SUBSTR(REPLACE(p_sql, CHR(10), ' '), 1, 160)
                    || ' [' || SQLERRM || ']');
                RAISE;
            END IF;
    END;

    FUNCTION column_exists(p_table_name IN VARCHAR2, p_column_name IN VARCHAR2) RETURN BOOLEAN IS
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO   l_count
        FROM   user_tab_cols
        WHERE  table_name = UPPER(p_table_name)
        AND    column_name = UPPER(p_column_name);

        RETURN l_count > 0;
    END;

    FUNCTION constraint_exists(p_constraint_name IN VARCHAR2) RETURN BOOLEAN IS
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO   l_count
        FROM   user_constraints
        WHERE  constraint_name = UPPER(p_constraint_name);

        RETURN l_count > 0;
    END;
BEGIN
    exec_ignore('CREATE SEQUENCE awr_trend_run_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE');

    exec_ignore(q'[
        CREATE TABLE awr_trend_runs (
            run_id               NUMBER         NOT NULL,
            dbid                 NUMBER         NOT NULL,
            db_name              VARCHAR2(30),
            instance_number      NUMBER,
            target_end_ts        TIMESTAMP      NOT NULL,
            win_hours            NUMBER         NOT NULL,
            weeks_back           NUMBER         NOT NULL,
            top_n                NUMBER         NOT NULL,
            scope                VARCHAR2(10)   NOT NULL,
            generated_at         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            report_path          VARCHAR2(500),
            caller_user          VARCHAR2(128),
            status               VARCHAR2(10)   DEFAULT 'RUNNING' NOT NULL,
            error_text           VARCHAR2(4000),
            target_id            NUMBER,
            requested_by         VARCHAR2(255),
            request_source       VARCHAR2(30),
            started_at           TIMESTAMP,
            finished_at          TIMESTAMP,
            scheduler_job_name   VARCHAR2(128),
            CONSTRAINT awr_trend_runs_pk PRIMARY KEY (run_id),
            CONSTRAINT awr_trend_runs_scope_ck CHECK (scope IN ('INSTANCE','ALL')),
            CONSTRAINT awr_trend_runs_status_ck CHECK (status IN ('QUEUED','RUNNING','OK','FAILED'))
        )
    ]');
    exec_ignore('CREATE INDEX awr_trend_runs_dbid_ts_ix ON awr_trend_runs (dbid, target_end_ts)');
    exec_ignore('CREATE INDEX awr_trend_runs_target_ix ON awr_trend_runs (target_id, generated_at)');

    exec_ignore(q'[
        CREATE TABLE awr_trend_windows (
            run_id           NUMBER       NOT NULL,
            week_offset      NUMBER       NOT NULL,
            win_start_ts     TIMESTAMP    NOT NULL,
            win_end_ts       TIMESTAMP    NOT NULL,
            begin_snap_id    NUMBER,
            end_snap_id      NUMBER,
            valid_flag       VARCHAR2(1)  NOT NULL,
            skip_reason      VARCHAR2(200),
            CONSTRAINT awr_trend_windows_pk PRIMARY KEY (run_id, week_offset),
            CONSTRAINT awr_trend_windows_fk FOREIGN KEY (run_id)
                REFERENCES awr_trend_runs (run_id) ON DELETE CASCADE,
            CONSTRAINT awr_trend_windows_valid_ck CHECK (valid_flag IN ('Y','N'))
        )
    ]');

    exec_ignore(q'[
        CREATE TABLE awr_trend_load_profile (
            run_id           NUMBER         NOT NULL,
            week_offset      NUMBER         NOT NULL,
            stat_name        VARCHAR2(100)  NOT NULL,
            stat_value       NUMBER,
            per_sec          NUMBER,
            per_txn          NUMBER,
            CONSTRAINT awr_trend_load_pk PRIMARY KEY (run_id, week_offset, stat_name),
            CONSTRAINT awr_trend_load_fk FOREIGN KEY (run_id, week_offset)
                REFERENCES awr_trend_windows (run_id, week_offset) ON DELETE CASCADE
        )
    ]');

    exec_ignore(q'[
        CREATE TABLE awr_trend_sysmetric (
            run_id           NUMBER         NOT NULL,
            week_offset      NUMBER         NOT NULL,
            metric_name      VARCHAR2(100)  NOT NULL,
            metric_unit      VARCHAR2(40),
            avg_value        NUMBER,
            max_value        NUMBER,
            CONSTRAINT awr_trend_sysmetric_pk PRIMARY KEY (run_id, week_offset, metric_name),
            CONSTRAINT awr_trend_sysmetric_fk FOREIGN KEY (run_id, week_offset)
                REFERENCES awr_trend_windows (run_id, week_offset) ON DELETE CASCADE
        )
    ]');

    exec_ignore(q'[
        CREATE TABLE awr_trend_waits (
            run_id           NUMBER         NOT NULL,
            week_offset      NUMBER         NOT NULL,
            scope            VARCHAR2(10)   NOT NULL,
            event_name       VARCHAR2(100)  NOT NULL,
            wait_class       VARCHAR2(40),
            total_waits      NUMBER,
            time_waited_us   NUMBER,
            avg_wait_ms      NUMBER,
            rank_in_window   NUMBER,
            CONSTRAINT awr_trend_waits_pk PRIMARY KEY (run_id, week_offset, scope, event_name),
            CONSTRAINT awr_trend_waits_fk FOREIGN KEY (run_id, week_offset)
                REFERENCES awr_trend_windows (run_id, week_offset) ON DELETE CASCADE,
            CONSTRAINT awr_trend_waits_scope_ck CHECK (scope IN ('FG','BG','CLASS'))
        )
    ]');

    exec_ignore(q'[
        CREATE TABLE awr_trend_top_sql (
            run_id                  NUMBER         NOT NULL,
            week_offset             NUMBER         NOT NULL,
            dimension               VARCHAR2(10)   NOT NULL,
            rank_in_window          NUMBER         NOT NULL,
            sql_id                  VARCHAR2(13)   NOT NULL,
            plan_hash_value         NUMBER,
            executions_delta        NUMBER,
            elapsed_time_delta_us   NUMBER,
            cpu_time_delta_us       NUMBER,
            buffer_gets_delta       NUMBER,
            disk_reads_delta        NUMBER,
            rows_processed_delta    NUMBER,
            sql_text_short          VARCHAR2(400),
            CONSTRAINT awr_trend_top_sql_pk PRIMARY KEY (run_id, week_offset, dimension, rank_in_window),
            CONSTRAINT awr_trend_top_sql_fk FOREIGN KEY (run_id, week_offset)
                REFERENCES awr_trend_windows (run_id, week_offset) ON DELETE CASCADE,
            CONSTRAINT awr_trend_top_sql_dim_ck CHECK (dimension IN ('ELAPSED','CPU','GETS','EXEC'))
        )
    ]');
    exec_ignore('CREATE INDEX awr_trend_top_sql_sqlid_ix ON awr_trend_top_sql (sql_id, run_id)');

    exec_ignore(q'[
        CREATE TABLE awr_trend_findings (
            run_id           NUMBER         NOT NULL,
            metric_domain    VARCHAR2(10)   NOT NULL,
            metric_name      VARCHAR2(120)  NOT NULL,
            current_value    NUMBER,
            prior_mean       NUMBER,
            prior_sd         NUMBER,
            n_prior          NUMBER,
            z_score          NUMBER,
            pct_delta        NUMBER,
            severity         VARCHAR2(25)   NOT NULL,
            CONSTRAINT awr_trend_findings_pk PRIMARY KEY (run_id, metric_domain, metric_name),
            CONSTRAINT awr_trend_findings_fk FOREIGN KEY (run_id)
                REFERENCES awr_trend_runs (run_id) ON DELETE CASCADE,
            CONSTRAINT awr_trend_findings_dom_ck CHECK (metric_domain IN ('LOAD','METRIC','WAIT')),
            CONSTRAINT awr_trend_findings_sev_ck CHECK (
                severity IN ('CRITICAL','WARN','OK','INSUFFICIENT_HISTORY','FLAT_BASELINE')
            )
        )
    ]');

    IF NOT column_exists('AWR_TREND_RUNS', 'TARGET_ID') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (target_id NUMBER)');
    END IF;
    IF NOT column_exists('AWR_TREND_RUNS', 'REQUESTED_BY') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (requested_by VARCHAR2(255))');
    END IF;
    IF NOT column_exists('AWR_TREND_RUNS', 'REQUEST_SOURCE') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (request_source VARCHAR2(30))');
    END IF;
    IF NOT column_exists('AWR_TREND_RUNS', 'STARTED_AT') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (started_at TIMESTAMP)');
    END IF;
    IF NOT column_exists('AWR_TREND_RUNS', 'FINISHED_AT') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (finished_at TIMESTAMP)');
    END IF;
    IF NOT column_exists('AWR_TREND_RUNS', 'SCHEDULER_JOB_NAME') THEN
        exec_ignore('ALTER TABLE awr_trend_runs ADD (scheduler_job_name VARCHAR2(128))');
    END IF;

    IF constraint_exists('AWR_TREND_RUNS_STATUS_CK') THEN
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE awr_trend_runs DROP CONSTRAINT awr_trend_runs_status_ck';
            DBMS_OUTPUT.PUT_LINE('  OK  : refreshed awr_trend_runs_status_ck');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  skip: unable to drop awr_trend_runs_status_ck [' || SQLERRM || ']');
        END;
    END IF;

    BEGIN
        EXECUTE IMMEDIATE q'[
            ALTER TABLE awr_trend_runs ADD CONSTRAINT awr_trend_runs_status_ck
            CHECK (status IN ('QUEUED','RUNNING','OK','FAILED'))
        ]';
        DBMS_OUTPUT.PUT_LINE('  OK  : added awr_trend_runs_status_ck');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -2261 THEN
                DBMS_OUTPUT.PUT_LINE('  skip: awr_trend_runs_status_ck already matches');
            ELSE
                RAISE;
            END IF;
    END;
END;
/
