CREATE OR REPLACE PACKAGE awr_app_collect_pkg AS
    PROCEDURE log_event(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_status    IN VARCHAR2,
        p_message   IN VARCHAR2,
        p_log_level IN VARCHAR2 DEFAULT 'INFO',
        p_details   IN CLOB DEFAULT NULL
    );

    PROCEDURE initialize_run(p_run_id IN NUMBER);
    PROCEDURE purge_run_data(p_run_id IN NUMBER);
    PROCEDURE collect_windows(p_run_id IN NUMBER);
    PROCEDURE collect_load_profile(p_run_id IN NUMBER);
    PROCEDURE collect_sysmetric(p_run_id IN NUMBER);
    PROCEDURE collect_waits(p_run_id IN NUMBER);
    PROCEDURE collect_top_sql(p_run_id IN NUMBER);
    PROCEDURE collect_findings(p_run_id IN NUMBER);
END awr_app_collect_pkg;
/
