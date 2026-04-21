CREATE OR REPLACE PACKAGE awr_app_run_api AS
    FUNCTION submit_run(
        p_target_id       IN NUMBER,
        p_target_end_ts   IN TIMESTAMP DEFAULT NULL,
        p_win_hours       IN NUMBER DEFAULT NULL,
        p_weeks_back      IN NUMBER DEFAULT NULL,
        p_top_n           IN NUMBER DEFAULT NULL,
        p_inst_num        IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    PROCEDURE enqueue_run(p_run_id IN NUMBER);

    PROCEDURE execute_run(p_run_id IN NUMBER);

    PROCEDURE execute_schedule(p_schedule_id IN NUMBER);
END awr_app_run_api;
/
