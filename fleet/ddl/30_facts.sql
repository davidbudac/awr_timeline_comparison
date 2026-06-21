--
-- fleet/ddl/30_facts.sql
--
-- Fact tables. Storage form follows the source faithfully (CONTEXT.md decision,
-- see docs/adr once written):
--   * CUMULATIVE counters stored RAW (value as-is per snap) -- SYSSTAT, wait
--     events, file I/O, IOSTAT_FILETYPE. The delta is SUM(end-begin) over a
--     Comparison Window, computed by windows_cte at analysis time. NO ingest
--     delta, NO streaming restart guard -- windows_cte already guards restarts.
--   * NATIVELY-DELTA views stored as their deltas -- SQLSTAT, SEG_STAT (that IS
--     their faithful raw form; only these expose *_DELTA in the source).
--   * SYSMETRIC stored as-is (already a per-snap aggregate).
--
-- Every fact keyed on (dbid, instance_number, snap_id, <subject>) -- snap_id is
-- NEVER a key alone (resets per DBID). target_id + snap_day carried for pruning
-- and partition-by-time retention. ASH is deliberately NOT collected (Q11).
--

------------------------------------------------------------------- LOAD (raw)
-- DBA_HIST_SYSSTAT: cumulative counter, no *_DELTA. delta = end.value-begin.value
CREATE TABLE awrw_sysstat (
    dbid            NUMBER        NOT NULL,
    instance_number NUMBER        NOT NULL,
    snap_id         NUMBER        NOT NULL,
    stat_name       VARCHAR2(128) NOT NULL,
    value           NUMBER,                  -- RAW cumulative
    snap_day        DATE          NOT NULL,
    target_id       NUMBER        NOT NULL,
    CONSTRAINT awrw_sysstat_pk PRIMARY KEY (dbid, instance_number, snap_id, stat_name)
);

----------------------------------------------------------------- METRIC (agg)
-- DBA_HIST_SYSMETRIC_SUMMARY: already a per-snap aggregate. is_additive (on the
-- profile) decides SUM vs AVG across RAC instances at analysis time.
CREATE TABLE awrw_sysmetric (
    dbid            NUMBER        NOT NULL,
    instance_number NUMBER        NOT NULL,
    snap_id         NUMBER        NOT NULL,
    metric_name     VARCHAR2(128) NOT NULL,
    average         NUMBER,
    metric_unit     VARCHAR2(64),
    snap_day        DATE          NOT NULL,
    target_id       NUMBER        NOT NULL,
    CONSTRAINT awrw_sysmetric_pk PRIMARY KEY (dbid, instance_number, snap_id, metric_name)
);

------------------------------------------------------------------- WAIT (raw)
-- DBA_HIST_SYSTEM_EVENT (is_bg='N') + DBA_HIST_BG_EVENT_SUMMARY (is_bg='Y'),
-- merged into one fact with an fg/bg flag. Both cumulative (no *_DELTA).
-- AWRV_* re-splits them back to the two DBA_HIST_* shapes the sections expect.
CREATE TABLE awrw_wait_event (
    dbid              NUMBER        NOT NULL,
    instance_number   NUMBER        NOT NULL,
    snap_id           NUMBER        NOT NULL,
    is_bg             CHAR(1)       NOT NULL,   -- 'N' foreground, 'Y' background
    event_name        VARCHAR2(64)  NOT NULL,
    wait_class        VARCHAR2(64),
    total_waits       NUMBER,                   -- RAW cumulative
    time_waited_micro NUMBER,                   -- RAW cumulative
    snap_day          DATE          NOT NULL,
    target_id         NUMBER        NOT NULL,
    CONSTRAINT awrw_wait_event_pk PRIMARY KEY (dbid, instance_number, snap_id, is_bg, event_name),
    CONSTRAINT awrw_wait_event_bg_ck CHECK (is_bg IN ('Y','N'))
);

------------------------------------------------------------- SQLSTAT (delta)
-- DBA_HIST_SQLSTAT: stored as the native *_DELTA values. Top-N per Snapshot by
-- elapsed_time_delta (profile.sql_top_n) -- not the full firehose.
CREATE TABLE awrw_sqlstat (
    dbid                NUMBER        NOT NULL,
    instance_number     NUMBER        NOT NULL,
    snap_id             NUMBER        NOT NULL,
    sql_id              VARCHAR2(13)  NOT NULL,
    plan_hash_value     NUMBER        NOT NULL,
    parsing_schema_name VARCHAR2(128),
    module              VARCHAR2(64),
    action              VARCHAR2(64),
    executions_delta    NUMBER,
    elapsed_time_delta  NUMBER,   -- microseconds
    cpu_time_delta      NUMBER,   -- microseconds
    buffer_gets_delta   NUMBER,
    disk_reads_delta    NUMBER,
    snap_day            DATE          NOT NULL,
    target_id           NUMBER        NOT NULL,
    CONSTRAINT awrw_sqlstat_pk PRIMARY KEY (dbid, instance_number, snap_id, sql_id, plan_hash_value)
);
CREATE INDEX awrw_sqlstat_sql_ix ON awrw_sqlstat (dbid, sql_id, snap_id);

---------------------------------------------------------- SEG_STAT (delta)
-- DBA_HIST_SEG_STAT: stored as native *_DELTA values. Top-N handled at analysis.
CREATE TABLE awrw_seg_stat (
    dbid                          NUMBER NOT NULL,
    instance_number               NUMBER NOT NULL,
    snap_id                       NUMBER NOT NULL,
    ts#                           NUMBER NOT NULL,
    obj#                          NUMBER NOT NULL,
    dataobj#                      NUMBER NOT NULL,
    physical_reads_delta          NUMBER,
    physical_writes_delta         NUMBER,
    physical_read_requests_delta  NUMBER,
    physical_write_requests_delta NUMBER,
    snap_day                      DATE   NOT NULL,
    target_id                     NUMBER NOT NULL,
    CONSTRAINT awrw_seg_stat_pk PRIMARY KEY (dbid, instance_number, snap_id, ts#, obj#, dataobj#)
);

------------------------------------------------------------- FILE I/O (raw)
-- DBA_HIST_FILESTATXS + DBA_HIST_TEMPSTATXS (ftag 'data'/'temp'). Cumulative.
CREATE TABLE awrw_filestat (
    dbid             NUMBER        NOT NULL,
    instance_number  NUMBER        NOT NULL,
    snap_id          NUMBER        NOT NULL,
    ftag             VARCHAR2(8)   NOT NULL,   -- 'data' | 'temp'
    file#            NUMBER        NOT NULL,
    creation_change# NUMBER        NOT NULL,
    phyrds           NUMBER,                   -- RAW cumulative
    phywrts          NUMBER,
    phyblkrd         NUMBER,
    phyblkwrt        NUMBER,
    snap_day         DATE          NOT NULL,
    target_id        NUMBER        NOT NULL,
    CONSTRAINT awrw_filestat_pk PRIMARY KEY (dbid, instance_number, snap_id, ftag, file#, creation_change#)
);

-- DBA_HIST_IOSTAT_FILETYPE: cumulative; covers ALL db I/O, NOT a rollup of
-- per-file. Kept distinct from awrw_filestat.
CREATE TABLE awrw_iostat_filetype (
    dbid                  NUMBER       NOT NULL,
    instance_number       NUMBER       NOT NULL,
    snap_id               NUMBER       NOT NULL,
    filetype_id           NUMBER       NOT NULL,
    filetype_name         VARCHAR2(50),
    small_read_megabytes  NUMBER,
    large_read_megabytes  NUMBER,
    small_write_megabytes NUMBER,
    large_write_megabytes NUMBER,
    small_read_reqs       NUMBER,
    large_read_reqs       NUMBER,
    small_write_reqs      NUMBER,
    large_write_reqs      NUMBER,
    snap_day              DATE         NOT NULL,
    target_id             NUMBER       NOT NULL,
    CONSTRAINT awrw_iostat_ft_pk PRIMARY KEY (dbid, instance_number, snap_id, filetype_id)
);
