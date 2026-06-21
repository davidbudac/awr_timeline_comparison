--
-- fleet/ddl/20_dimensions.sql
--
-- Dimension tables: the Snapshot join-driver (the warehouse twin of
-- DBA_HIST_SNAPSHOT, carrying startup_time so windows_cte's restart guard
-- works unchanged) plus the name-lookup dimensions for SQL, segments, files.
--
-- All keyed on (DBID, ...) because snap_id resets per DBID. A Target's
-- target_id is carried for cheap per-Target pruning.
--
-- Partitioning: the snap_day column is present so production can RANGE/INTERVAL
-- partition these and the facts on it and purge by dropping partitions
-- (see fleet/README.md "Retention"). Base DDL ships unpartitioned so it runs
-- on any 19c (including the dbmint test DB).
--

-- The atomic unit of collection (CONTEXT.md: Snapshot). One row per
-- (dbid, instance_number, snap_id). startup_time is load-bearing: it lets the
-- analyzer reproduce windows_cte's restart + DBID-straddle invalidation.
CREATE TABLE awrw_snapshot (
    dbid                NUMBER    NOT NULL,
    instance_number     NUMBER    NOT NULL,
    snap_id             NUMBER    NOT NULL,
    begin_interval_time TIMESTAMP NOT NULL,
    end_interval_time   TIMESTAMP NOT NULL,
    startup_time        TIMESTAMP NOT NULL,
    snap_day            DATE      NOT NULL,   -- TRUNC(end_interval_time): partition key
    target_id           NUMBER    NOT NULL,
    loaded_ts           TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT awrw_snapshot_pk PRIMARY KEY (dbid, instance_number, snap_id)
);
CREATE INDEX awrw_snapshot_time_ix ON awrw_snapshot (end_interval_time);
CREATE INDEX awrw_snapshot_tgt_ix  ON awrw_snapshot (target_id, end_interval_time);

-- SQL text, deduped one row per (dbid, sql_id). Loaded lazily for sql_ids that
-- appear in AWRW_SQLSTAT and aren't already present.
CREATE TABLE awrw_sqltext (
    dbid       NUMBER        NOT NULL,
    sql_id     VARCHAR2(13)  NOT NULL,
    sql_text   CLOB,
    loaded_ts  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT awrw_sqltext_pk PRIMARY KEY (dbid, sql_id)
);

-- Segment name dimension (DBA_HIST_SEG_STAT_OBJ). seg_name is the STABLE logical
-- key for trending; obj#/dataobj# drift on rebuild/truncate.
CREATE TABLE awrw_segment (
    dbid            NUMBER        NOT NULL,
    ts#             NUMBER        NOT NULL,
    obj#            NUMBER        NOT NULL,
    dataobj#        NUMBER        NOT NULL,
    owner           VARCHAR2(128),
    object_name     VARCHAR2(128),
    subobject_name  VARCHAR2(128),
    object_type     VARCHAR2(24),
    tablespace_name VARCHAR2(30),
    seg_name        VARCHAR2(400),   -- owner.object[.subobject], the logical trend key
    loaded_ts       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT awrw_segment_pk PRIMARY KEY (dbid, ts#, obj#, dataobj#)
);

-- File dimension. filename is the stable logical key (file# is reused).
CREATE TABLE awrw_file (
    dbid             NUMBER       NOT NULL,
    file#            NUMBER       NOT NULL,
    creation_change# NUMBER       NOT NULL,
    ftag             VARCHAR2(8)  NOT NULL,   -- 'data' | 'temp'
    filename         VARCHAR2(513),
    tsname           VARCHAR2(30),
    block_size       NUMBER,
    loaded_ts        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT awrw_file_pk PRIMARY KEY (dbid, file#, creation_change#, ftag)
);
