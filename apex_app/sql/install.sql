SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT
PROMPT ============================================================
PROMPT Installing standalone AWR APEX application objects
PROMPT ============================================================
PROMPT

@@schema/01_awr_trend_compat.sql
@@schema/02_app_metadata.sql
@@schema/03_app_views.sql

@@packages/awr_app_collect_pkg.pks
@@packages/awr_app_collect_pkg.pkb
@@packages/awr_app_run_api.pks
@@packages/awr_app_run_api.pkb
@@packages/awr_app_admin_api.pks
@@packages/awr_app_admin_api.pkb

PROMPT
PROMPT ============================================================
PROMPT Installation complete
PROMPT
PROMPT Next steps:
PROMPT   1. Register monitored databases in AWR_APP_TARGETS.
PROMPT   2. Import the APEX app from apex_app/apex/f100.sql.
PROMPT   3. Call AWR_APP_ADMIN_API.SYNC_SCHEDULES after defining schedules.
PROMPT ============================================================
PROMPT
