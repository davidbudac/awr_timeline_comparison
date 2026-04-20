--
-- setup_schema.sql
-- One-time DDL for the AWR Timeline Comparison scratch schema.
-- Idempotent: safe to re-run. Each CREATE is guarded against ORA-00955 /
-- ORA-02260 so missing objects get created, existing ones are left alone.
--
-- Required privileges (grant to the owning user):
--   SELECT ON DBA_HIST_SNAPSHOT, DBA_HIST_SYSSTAT, DBA_HIST_SYSTEM_EVENT,
--          DBA_HIST_BG_EVENT_SUMMARY, DBA_HIST_SYSMETRIC_SUMMARY,
--          DBA_HIST_SQLSTAT, DBA_HIST_SQLTEXT, DBA_HIST_BASELINE, V_$DATABASE,
--          V_$INSTANCE, V_$EVENT_NAME
--   EXECUTE ON DBMS_WORKLOAD_REPOSITORY (only for side/create_weekly_baselines.sql)
--
-- Run as the user that will own the AWR_TREND_* objects:
--   sqlplus user/pw@svc @sql/setup_schema.sql
--

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

PROMPT Creating AWR_TREND_* objects (idempotent) ...

DECLARE
    PROCEDURE exec_ignore(p_sql VARCHAR2, p_ignore_codes VARCHAR2 DEFAULT '-955,-1430,-2260,-2275,-1442') IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  OK  : ' || SUBSTR(p_sql, 1, 70));
    EXCEPTION
        WHEN OTHERS THEN
            IF INSTR(',' || p_ignore_codes || ',', ',' || TO_CHAR(SQLCODE) || ',') > 0 THEN
                DBMS_OUTPUT.PUT_LINE('  skip: ' || SUBSTR(p_sql, 1, 70) || '  [' || SQLCODE || ']');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  FAIL: ' || SUBSTR(p_sql, 1, 200) || '  [' || SQLERRM || ']');
                RAISE;
            END IF;
    END;
BEGIN
    -- Sequence ------------------------------------------------------------
    exec_ignore('CREATE SEQUENCE awr_trend_run_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE');

    -- Runs ----------------------------------------------------------------
    exec_ignore(q'[
        CREATE TABLE awr_trend_runs (
            run_id           NUMBER       NOT NULL,
            dbid             NUMBER       NOT NULL,
            db_name          VARCHAR2(30),
            instance_number  NUMBER,
            target_end_ts    TIMESTAMP    NOT NULL,
            win_hours        NUMBER       NOT NULL,
            weeks_back       NUMBER       NOT NULL,
            top_n            NUMBER       NOT NULL,
            scope            VARCHAR2(10) NOT NULL,
            generated_at     TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
            report_path      VARCHAR2(500),
            caller_user      VARCHAR2(128),
            status           VARCHAR2(10) DEFAULT 'RUNNING' NOT NULL,
            error_text       VARCHAR2(4000),
            CONSTRAINT awr_trend_runs_pk PRIMARY KEY (run_id),
            CONSTRAINT awr_trend_runs_scope_ck CHECK (scope IN ('INSTANCE','ALL')),
            CONSTRAINT awr_trend_runs_status_ck CHECK (status IN ('RUNNING','OK','FAILED'))
        )
    ]');
    exec_ignore('CREATE INDEX awr_trend_runs_dbid_ts_ix ON awr_trend_runs (dbid, target_end_ts)');

    -- Windows -------------------------------------------------------------
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

    -- Load profile --------------------------------------------------------
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

    -- System metrics ------------------------------------------------------
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

    -- Wait events ---------------------------------------------------------
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

    -- Top SQL -------------------------------------------------------------
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

    -- Findings ------------------------------------------------------------
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
            CONSTRAINT awr_trend_findings_sev_ck CHECK (severity IN
                ('CRITICAL','WARN','OK','INSUFFICIENT_HISTORY','FLAT_BASELINE'))
        )
    ]');

    DBMS_OUTPUT.PUT_LINE('Setup complete.');
END;
/

SET FEEDBACK ON
