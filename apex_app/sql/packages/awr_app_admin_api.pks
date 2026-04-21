CREATE OR REPLACE PACKAGE awr_app_admin_api AS
    PROCEDURE sync_schedules;
    PROCEDURE run_schedule_now(p_schedule_id IN NUMBER);
END awr_app_admin_api;
/
