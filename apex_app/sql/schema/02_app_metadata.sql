SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT Creating AWR_APP_* metadata objects ...

DECLARE
    PROCEDURE exec_ignore(
        p_sql          IN CLOB,
        p_ignore_codes IN VARCHAR2 DEFAULT '-955,-1430,-1442,-2260,-2275,-01442'
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
    exec_ignore('CREATE SEQUENCE awr_app_target_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE');
    exec_ignore('CREATE SEQUENCE awr_app_schedule_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE');
    exec_ignore('CREATE SEQUENCE awr_app_run_log_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE');

    exec_ignore(q'[
        CREATE TABLE awr_app_targets (
            target_id              NUMBER         NOT NULL,
            target_name            VARCHAR2(128)  NOT NULL,
            db_link_name           VARCHAR2(128)  NOT NULL,
            description            VARCHAR2(1000),
            default_target_end_mode VARCHAR2(10) DEFAULT 'AUTO' NOT NULL,
            default_win_hours      NUMBER         DEFAULT 1 NOT NULL,
            default_weeks_back     NUMBER         DEFAULT 4 NOT NULL,
            default_top_n          NUMBER         DEFAULT 10 NOT NULL,
            default_inst_num       NUMBER         DEFAULT 0 NOT NULL,
            enabled_flag           VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
            created_at             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            updated_at             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            created_by             VARCHAR2(255),
            notes                  CLOB,
            CONSTRAINT awr_app_targets_pk PRIMARY KEY (target_id),
            CONSTRAINT awr_app_targets_uk UNIQUE (target_name),
            CONSTRAINT awr_app_targets_link_uk UNIQUE (db_link_name),
            CONSTRAINT awr_app_targets_enabled_ck CHECK (enabled_flag IN ('Y','N')),
            CONSTRAINT awr_app_targets_mode_ck CHECK (default_target_end_mode IN ('AUTO','EXPLICIT'))
        )
    ]');

    exec_ignore(q'[
        CREATE TABLE awr_app_schedules (
            schedule_id            NUMBER         NOT NULL,
            target_id              NUMBER         NOT NULL,
            schedule_name          VARCHAR2(128)  NOT NULL,
            repeat_interval        VARCHAR2(4000) NOT NULL,
            override_target_end_ts TIMESTAMP,
            override_win_hours     NUMBER,
            override_weeks_back    NUMBER,
            override_top_n         NUMBER,
            override_inst_num      NUMBER,
            enabled_flag           VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
            scheduler_job_name     VARCHAR2(128),
            last_requested_at      TIMESTAMP,
            last_started_at        TIMESTAMP,
            last_finished_at       TIMESTAMP,
            last_run_id            NUMBER,
            last_status            VARCHAR2(10),
            last_error_text        VARCHAR2(4000),
            created_at             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            updated_at             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            created_by             VARCHAR2(255),
            CONSTRAINT awr_app_schedules_pk PRIMARY KEY (schedule_id),
            CONSTRAINT awr_app_schedules_target_fk FOREIGN KEY (target_id)
                REFERENCES awr_app_targets (target_id) ON DELETE CASCADE,
            CONSTRAINT awr_app_schedules_enabled_ck CHECK (enabled_flag IN ('Y','N')),
            CONSTRAINT awr_app_schedules_status_ck CHECK (
                last_status IN ('QUEUED','RUNNING','OK','FAILED') OR last_status IS NULL
            )
        )
    ]');
    exec_ignore('CREATE INDEX awr_app_sched_target_ix ON awr_app_schedules (target_id, enabled_flag)');

    exec_ignore(q'[
        CREATE TABLE awr_app_run_log (
            log_id                 NUMBER         NOT NULL,
            run_id                 NUMBER         NOT NULL,
            step_name              VARCHAR2(100)  NOT NULL,
            log_level              VARCHAR2(10)   DEFAULT 'INFO' NOT NULL,
            status                 VARCHAR2(20)   DEFAULT 'INFO' NOT NULL,
            message                VARCHAR2(4000),
            details                CLOB,
            created_at             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT awr_app_run_log_pk PRIMARY KEY (log_id),
            CONSTRAINT awr_app_run_log_run_fk FOREIGN KEY (run_id)
                REFERENCES awr_trend_runs (run_id) ON DELETE CASCADE,
            CONSTRAINT awr_app_run_log_level_ck CHECK (log_level IN ('INFO','WARN','ERROR')),
            CONSTRAINT awr_app_run_log_status_ck CHECK (status IN ('STARTED','OK','FAILED','INFO'))
        )
    ]');
    exec_ignore('CREATE INDEX awr_app_run_log_run_ix ON awr_app_run_log (run_id, created_at)');

    IF NOT constraint_exists('AWR_TREND_RUNS_TARGET_FK') THEN
        BEGIN
            EXECUTE IMMEDIATE q'[
                ALTER TABLE awr_trend_runs ADD CONSTRAINT awr_trend_runs_target_fk
                FOREIGN KEY (target_id) REFERENCES awr_app_targets (target_id)
            ]';
            DBMS_OUTPUT.PUT_LINE('  OK  : added awr_trend_runs_target_fk');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  skip: could not add awr_trend_runs_target_fk [' || SQLERRM || ']');
        END;
    END IF;

    IF NOT column_exists('AWR_APP_TARGETS', 'LAST_VALIDATED_AT') THEN
        exec_ignore('ALTER TABLE awr_app_targets ADD (last_validated_at TIMESTAMP)');
    END IF;
END;
/
