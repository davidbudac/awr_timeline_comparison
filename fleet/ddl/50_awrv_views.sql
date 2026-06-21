--
-- fleet/ddl/50_awrv_views.sql
--
-- The AWRV_* seam: views over the warehouse facts that expose the SAME column
-- shape as the DBA_HIST_* views the single-DB sections read. The analyzer (and,
-- for old-window drill-down, the existing report) runs against AWRV_* scoped by
-- `dbid IN (<the Target's DBID set>)`, exactly as it filters `dbid IN
-- (~dbid_list)` live. Because storage is RAW cumulative, these are thin
-- pass-throughs and windows_cte's begin/end pairing + restart guard work
-- unchanged -- no delta logic lives here.
--

CREATE OR REPLACE VIEW awrv_snapshot AS
SELECT dbid, instance_number, snap_id,
       begin_interval_time, end_interval_time, startup_time
  FROM awrw_snapshot;

CREATE OR REPLACE VIEW awrv_sysstat AS
SELECT dbid, instance_number, snap_id, stat_name, value
  FROM awrw_sysstat;

CREATE OR REPLACE VIEW awrv_sysmetric_summary AS
SELECT dbid, instance_number, snap_id, metric_name, average, metric_unit
  FROM awrw_sysmetric;

-- Foreground and background waits re-split back to their two DBA_HIST_* shapes.
CREATE OR REPLACE VIEW awrv_system_event AS
SELECT dbid, instance_number, snap_id, event_name, wait_class,
       total_waits, time_waited_micro
  FROM awrw_wait_event
 WHERE is_bg = 'N';

CREATE OR REPLACE VIEW awrv_bg_event_summary AS
SELECT dbid, instance_number, snap_id, event_name, wait_class,
       total_waits, time_waited_micro
  FROM awrw_wait_event
 WHERE is_bg = 'Y';

CREATE OR REPLACE VIEW awrv_sqlstat AS
SELECT dbid, instance_number, snap_id, sql_id, plan_hash_value,
       parsing_schema_name, module, action,
       executions_delta, elapsed_time_delta, cpu_time_delta,
       buffer_gets_delta, disk_reads_delta
  FROM awrw_sqlstat;

CREATE OR REPLACE VIEW awrv_sqltext AS
SELECT dbid, sql_id, sql_text
  FROM awrw_sqltext;

CREATE OR REPLACE VIEW awrv_seg_stat AS
SELECT dbid, instance_number, snap_id, ts#, obj#, dataobj#,
       physical_reads_delta, physical_writes_delta,
       physical_read_requests_delta, physical_write_requests_delta
  FROM awrw_seg_stat;

CREATE OR REPLACE VIEW awrv_seg_stat_obj AS
SELECT dbid, ts#, obj#, dataobj#, owner, object_name, subobject_name,
       object_type, tablespace_name
  FROM awrw_segment;

CREATE OR REPLACE VIEW awrv_filestatxs AS
SELECT dbid, instance_number, snap_id, file#, creation_change#,
       phyrds, phywrts, phyblkrd, phyblkwrt
  FROM awrw_filestat
 WHERE ftag = 'data';

CREATE OR REPLACE VIEW awrv_tempstatxs AS
SELECT dbid, instance_number, snap_id, file#, creation_change#,
       phyrds, phywrts, phyblkrd, phyblkwrt
  FROM awrw_filestat
 WHERE ftag = 'temp';

CREATE OR REPLACE VIEW awrv_iostat_filetype AS
SELECT dbid, instance_number, snap_id, filetype_id, filetype_name,
       small_read_megabytes, large_read_megabytes,
       small_write_megabytes, large_write_megabytes,
       small_read_reqs, large_read_reqs, small_write_reqs, large_write_reqs
  FROM awrw_iostat_filetype;
