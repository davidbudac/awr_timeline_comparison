--
-- fleet/ddl/00_drop.sql
--
-- DROPS every fleet object and ALL collected history. Dev/test re-install only.
-- Run as the warehouse owner: sqlplus awrwh/pw @ddl/00_drop.sql
--
SET ECHO ON
WHENEVER SQLERROR CONTINUE

BEGIN DBMS_SCHEDULER.drop_job('AWRW_PIPELINE', force => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
/

DROP PACKAGE awrw_schedule;
DROP PACKAGE awrw_notify;
DROP PACKAGE awrw_analyze;
DROP PACKAGE awrw_score;
DROP PACKAGE awrw_admin;
DROP PACKAGE awrw_collect;

DROP VIEW awrv_snapshot;
DROP VIEW awrv_sysstat;
DROP VIEW awrv_sysmetric_summary;
DROP VIEW awrv_system_event;
DROP VIEW awrv_bg_event_summary;
DROP VIEW awrv_sqlstat;
DROP VIEW awrv_sqltext;
DROP VIEW awrv_seg_stat;
DROP VIEW awrv_seg_stat_obj;
DROP VIEW awrv_filestatxs;
DROP VIEW awrv_tempstatxs;
DROP VIEW awrv_iostat_filetype;

DROP TABLE awrw_digest PURGE;
DROP TABLE awrw_findings PURGE;
DROP TABLE awrw_alert_state PURGE;
DROP TABLE awrw_sysstat PURGE;
DROP TABLE awrw_sysmetric PURGE;
DROP TABLE awrw_wait_event PURGE;
DROP TABLE awrw_sqlstat PURGE;
DROP TABLE awrw_seg_stat PURGE;
DROP TABLE awrw_filestat PURGE;
DROP TABLE awrw_iostat_filetype PURGE;
DROP TABLE awrw_snapshot PURGE;
DROP TABLE awrw_sqltext PURGE;
DROP TABLE awrw_segment PURGE;
DROP TABLE awrw_file PURGE;
DROP TABLE awrw_profile_metric PURGE;
DROP TABLE awrw_profile CASCADE CONSTRAINTS PURGE;   -- awrw_target_profile_fk references this
DROP TABLE awrw_target_health PURGE;
DROP TABLE awrw_analysis_hwm PURGE;
DROP TABLE awrw_hwm PURGE;
DROP TABLE awrw_run_log PURGE;
DROP TABLE awrw_error_log PURGE;
DROP TABLE awrw_dbid PURGE;
DROP TABLE awrw_target PURGE;

DROP TYPE awrw_win_tab;
DROP TYPE awrw_win_row;
