--
-- fleet/collect/awrw_collect.pkb
--
-- Body of the fleet collector. Link names vary per Target and cannot be bind
-- variables, so every cross-Connection pull is native dynamic SQL with the link
-- concatenated and (dbid, hwm) bound. target_id is inlined as a trusted NUMBER.
--
CREATE OR REPLACE PACKAGE BODY awrw_collect AS

    g_run_id NUMBER;

    --------------------------------------------------------------- run logging
    PROCEDURE start_run(p_target_id NUMBER, p_phase VARCHAR2) IS
    BEGIN
        INSERT INTO awrw_run_log (target_id, phase, status)
        VALUES (p_target_id, p_phase, 'RUNNING')
        RETURNING run_id INTO g_run_id;
        COMMIT;
    END start_run;

    PROCEDURE end_run(p_status VARCHAR2, p_rows NUMBER DEFAULT NULL,
                      p_detail VARCHAR2 DEFAULT NULL) IS
    BEGIN
        UPDATE awrw_run_log
           SET ended_ts = SYSTIMESTAMP, status = p_status,
               rows_loaded = p_rows, detail = p_detail
         WHERE run_id = g_run_id;
        COMMIT;
    END end_run;

    PROCEDURE log_err(p_target_id NUMBER, p_phase VARCHAR2,
                      p_code NUMBER DEFAULT NULL, p_text VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        -- SQLCODE/SQLERRM/FORMAT_ERROR_BACKTRACE are PL/SQL-only; capture into
        -- locals first -- they cannot appear inside a SQL INSERT (ORA-00984).
        v_code NUMBER       := NVL(p_code, SQLCODE);
        v_text VARCHAR2(4000) := SUBSTR(NVL(p_text,
                                    SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE), 1, 4000);
    BEGIN
        INSERT INTO awrw_error_log (run_id, target_id, phase, ora_code, err_text)
        VALUES (g_run_id, p_target_id, p_phase, v_code, v_text);
        COMMIT;
    END log_err;

    ------------------------------------------------------- DBID auto-discovery
    -- Union any new DBID on the Connection into this Target's set. The PK on
    -- awrw_dbid means a DBID already owned by ANOTHER Target is a collision
    -- (clone without NID, or mis-pointed Connection): log it, never merge.
    PROCEDURE discover_dbids(p_target_id NUMBER, p_link VARCHAR2) IS
        TYPE t_ids IS TABLE OF NUMBER;
        v_ids   t_ids;
        v_owner NUMBER;
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT DISTINCT dbid FROM dba_hist_snapshot@' || p_link
            BULK COLLECT INTO v_ids;
        FOR i IN 1 .. v_ids.COUNT LOOP
            BEGIN
                SELECT target_id INTO v_owner FROM awrw_dbid WHERE dbid = v_ids(i);
                IF v_owner = p_target_id THEN
                    UPDATE awrw_dbid SET last_seen_ts = SYSTIMESTAMP
                     WHERE dbid = v_ids(i);
                ELSE
                    log_err(p_target_id, 'DISCOVER', -20001,
                        'DBID ' || v_ids(i) || ' already owned by target ' ||
                        v_owner || ' -- skipped (clone without NID?)');
                END IF;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                INSERT INTO awrw_dbid (dbid, target_id) VALUES (v_ids(i), p_target_id);
            END;
        END LOOP;
        COMMIT;
    END discover_dbids;

    ------------------------------------------------------ per-DBID collection
    -- Pulls the new snap range for ONE DBID atomically: snapshots first (they
    -- carry snap_day for the facts), then every fact, then the dimensions, then
    -- advance the HWM. One transaction -- commit on success only.
    PROCEDURE collect_dbid(p_target_id NUMBER, p_dbid NUMBER,
                           p_link VARCHAR2, p_top_n NUMBER) IS
        v_hwm  NUMBER;
        v_max  NUMBER;
        v_tgt  VARCHAR2(40) := TO_CHAR(p_target_id);
        v_lk   VARCHAR2(140) := '@' || p_link;
        v_rows NUMBER := 0;

        -- uniform pull: WHERE x.dbid=:1 AND x.snap_id>:2
        PROCEDURE pull(p_sql VARCHAR2) IS
        BEGIN
            EXECUTE IMMEDIATE p_sql USING p_dbid, v_hwm;
            v_rows := v_rows + SQL%ROWCOUNT;
        END pull;
    BEGIN
        -- resume point
        BEGIN
            SELECT last_snap_id INTO v_hwm
              FROM awrw_hwm WHERE target_id = p_target_id AND dbid = p_dbid;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            v_hwm := 0;
            INSERT INTO awrw_hwm (target_id, dbid, last_snap_id)
            VALUES (p_target_id, p_dbid, 0);
        END;

        EXECUTE IMMEDIATE
            'SELECT NVL(MAX(snap_id),0) FROM dba_hist_snapshot' || v_lk ||
            ' WHERE dbid = :1' INTO v_max USING p_dbid;
        IF v_max <= v_hwm THEN
            RETURN;                          -- nothing new for this DBID
        END IF;

        -- 1) Snapshots (the join driver; carries snap_day forward)
        pull('INSERT INTO awrw_snapshot (dbid,instance_number,snap_id,'||
             'begin_interval_time,end_interval_time,startup_time,snap_day,target_id) '||
             'SELECT s.dbid,s.instance_number,s.snap_id,s.begin_interval_time,'||
             's.end_interval_time,s.startup_time,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_snapshot'||v_lk||' s WHERE s.dbid=:1 AND s.snap_id>:2');

        -- 2) LOAD: SYSSTAT (raw cumulative)
        pull('INSERT INTO awrw_sysstat (dbid,instance_number,snap_id,stat_name,value,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,x.stat_name,x.value,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_sysstat'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 3) METRIC: SYSMETRIC_SUMMARY (per-snap aggregate; dedup one row/metric)
        pull('INSERT INTO awrw_sysmetric (dbid,instance_number,snap_id,metric_name,average,metric_unit,snap_day,target_id) '||
             'SELECT dbid,instance_number,snap_id,metric_name,average,metric_unit,snap_day,'||v_tgt||' FROM ('||
               'SELECT x.dbid,x.instance_number,x.snap_id,x.metric_name,x.average,x.metric_unit,'||
               'TRUNC(s.end_interval_time) snap_day,'||
               'ROW_NUMBER() OVER (PARTITION BY x.dbid,x.instance_number,x.snap_id,x.metric_name ORDER BY x.group_id) rn '||
               'FROM dba_hist_sysmetric_summary'||v_lk||' x '||
               'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
               'WHERE x.dbid=:1 AND x.snap_id>:2) WHERE rn=1');

        -- 4) WAIT foreground: SYSTEM_EVENT (raw cumulative)
        pull('INSERT INTO awrw_wait_event (dbid,instance_number,snap_id,is_bg,event_name,wait_class,total_waits,time_waited_micro,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,''N'',x.event_name,x.wait_class,x.total_waits,x.time_waited_micro,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_system_event'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 5) WAIT background: BG_EVENT_SUMMARY (raw cumulative; wait_class may be NULL)
        pull('INSERT INTO awrw_wait_event (dbid,instance_number,snap_id,is_bg,event_name,wait_class,total_waits,time_waited_micro,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,''Y'',x.event_name,x.wait_class,x.total_waits,x.time_waited_micro,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_bg_event_summary'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 6) SQLSTAT (native deltas; top-N per Snapshot by elapsed)
        pull('INSERT INTO awrw_sqlstat (dbid,instance_number,snap_id,sql_id,plan_hash_value,parsing_schema_name,module,action,'||
             'executions_delta,elapsed_time_delta,cpu_time_delta,buffer_gets_delta,disk_reads_delta,snap_day,target_id) '||
             'SELECT dbid,instance_number,snap_id,sql_id,plan_hash_value,parsing_schema_name,module,action,'||
             'executions_delta,elapsed_time_delta,cpu_time_delta,buffer_gets_delta,disk_reads_delta,snap_day,'||v_tgt||' FROM ('||
               'SELECT x.dbid,x.instance_number,x.snap_id,x.sql_id,x.plan_hash_value,x.parsing_schema_name,x.module,x.action,'||
               'x.executions_delta,x.elapsed_time_delta,x.cpu_time_delta,x.buffer_gets_delta,x.disk_reads_delta,'||
               'TRUNC(s.end_interval_time) snap_day,'||
               'ROW_NUMBER() OVER (PARTITION BY x.dbid,x.instance_number,x.snap_id ORDER BY x.elapsed_time_delta DESC NULLS LAST) rn '||
               'FROM dba_hist_sqlstat'||v_lk||' x '||
               'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
               'WHERE x.dbid=:1 AND x.snap_id>:2) WHERE rn <= '||TO_CHAR(p_top_n));

        -- 7) SEG_STAT (native deltas)
        pull('INSERT INTO awrw_seg_stat (dbid,instance_number,snap_id,ts#,obj#,dataobj#,'||
             'physical_reads_delta,physical_writes_delta,physical_read_requests_delta,physical_write_requests_delta,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,x.ts#,x.obj#,x.dataobj#,'||
             'x.physical_reads_delta,x.physical_writes_delta,x.physical_read_requests_delta,x.physical_write_requests_delta,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_seg_stat'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 8) FILE I/O data: FILESTATXS (raw cumulative)
        pull('INSERT INTO awrw_filestat (dbid,instance_number,snap_id,ftag,file#,creation_change#,phyrds,phywrts,phyblkrd,phyblkwrt,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,''data'',x.file#,x.creation_change#,x.phyrds,x.phywrts,x.phyblkrd,x.phyblkwrt,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_filestatxs'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 9) FILE I/O temp: TEMPSTATXS (raw cumulative)
        pull('INSERT INTO awrw_filestat (dbid,instance_number,snap_id,ftag,file#,creation_change#,phyrds,phywrts,phyblkrd,phyblkwrt,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,''temp'',x.file#,x.creation_change#,x.phyrds,x.phywrts,x.phyblkrd,x.phyblkwrt,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_tempstatxs'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 10) IOSTAT_FILETYPE (raw cumulative)
        pull('INSERT INTO awrw_iostat_filetype (dbid,instance_number,snap_id,filetype_id,filetype_name,'||
             'small_read_megabytes,large_read_megabytes,small_write_megabytes,large_write_megabytes,'||
             'small_read_reqs,large_read_reqs,small_write_reqs,large_write_reqs,snap_day,target_id) '||
             'SELECT x.dbid,x.instance_number,x.snap_id,x.filetype_id,x.filetype_name,'||
             'x.small_read_megabytes,x.large_read_megabytes,x.small_write_megabytes,x.large_write_megabytes,'||
             'x.small_read_reqs,x.large_read_reqs,x.small_write_reqs,x.large_write_reqs,TRUNC(s.end_interval_time),'||v_tgt||' '||
             'FROM dba_hist_iostat_filetype'||v_lk||' x '||
             'JOIN dba_hist_snapshot'||v_lk||' s ON s.dbid=x.dbid AND s.snap_id=x.snap_id AND s.instance_number=x.instance_number '||
             'WHERE x.dbid=:1 AND x.snap_id>:2');

        -- 11-13) DIMENSIONS (best-effort: a name-lookup failure must never lose
        -- the facts -- it is caught and logged, the facts still commit).
        BEGIN
            -- SQLTEXT: a remote CLOB cannot be INSERT...SELECT'd over a DB link
            -- (ORA-22992), so fetch each new sql_text INTO a local CLOB var.
            -- Scans all kept sql_ids missing text, so a transient miss self-heals.
            DECLARE
                TYPE t_ids IS TABLE OF VARCHAR2(13);
                v_ids t_ids;
                v_txt CLOB;
            BEGIN
                SELECT DISTINCT q.sql_id BULK COLLECT INTO v_ids
                  FROM awrw_sqlstat q
                 WHERE q.dbid = p_dbid
                   AND NOT EXISTS (SELECT 1 FROM awrw_sqltext w
                                    WHERE w.dbid = q.dbid AND w.sql_id = q.sql_id);
                FOR i IN 1 .. v_ids.COUNT LOOP
                    BEGIN
                        EXECUTE IMMEDIATE
                            'SELECT sql_text FROM (SELECT sql_text FROM dba_hist_sqltext'||v_lk||
                            ' WHERE dbid=:1 AND sql_id=:2) WHERE ROWNUM=1'
                            INTO v_txt USING p_dbid, v_ids(i);
                        INSERT INTO awrw_sqltext (dbid, sql_id, sql_text)
                        VALUES (p_dbid, v_ids(i), v_txt);
                    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;   -- text gone; skip
                    END;
                END LOOP;
            END;

            -- SEGMENT names (no LOB; con_dbid fan-out guarded by ROW_NUMBER dedup)
            EXECUTE IMMEDIATE
                'INSERT INTO awrw_segment (dbid,ts#,obj#,dataobj#,owner,object_name,subobject_name,object_type,tablespace_name,seg_name) '||
                'SELECT dbid,ts#,obj#,dataobj#,owner,object_name,subobject_name,object_type,tablespace_name,'||
                       'owner||''.''||object_name||CASE WHEN subobject_name IS NOT NULL THEN ''.''||subobject_name END FROM ('||
                  'SELECT o.dbid,o.ts#,o.obj#,o.dataobj#,o.owner,o.object_name,o.subobject_name,o.object_type,o.tablespace_name,'||
                         'ROW_NUMBER() OVER (PARTITION BY o.dbid,o.ts#,o.obj#,o.dataobj# ORDER BY NULL) rn '||
                  'FROM dba_hist_seg_stat_obj'||v_lk||' o '||
                  'WHERE o.dbid=:1 AND (o.ts#,o.obj#,o.dataobj#) IN (SELECT ts#,obj#,dataobj# FROM awrw_seg_stat WHERE dbid=:2 AND snap_id>:3)) v '||
                'WHERE v.rn=1 AND NOT EXISTS (SELECT 1 FROM awrw_segment w WHERE w.dbid=v.dbid AND w.ts#=v.ts# AND w.obj#=v.obj# AND w.dataobj#=v.dataobj#)'
                USING p_dbid, p_dbid, v_hwm;

            -- FILE names (data files; latest name wins)
            EXECUTE IMMEDIATE
                'INSERT INTO awrw_file (dbid,file#,creation_change#,ftag,filename,tsname,block_size) '||
                'SELECT dbid,file#,creation_change#,''data'',filename,tsname,block_size FROM ('||
                  'SELECT f.dbid,f.file#,f.creation_change#,f.filename,f.tsname,f.block_size,'||
                         'ROW_NUMBER() OVER (PARTITION BY f.dbid,f.file#,f.creation_change# ORDER BY f.snap_id DESC) rn '||
                  'FROM dba_hist_filestatxs'||v_lk||' f WHERE f.dbid=:1 AND f.snap_id>:2) v '||
                'WHERE v.rn=1 AND NOT EXISTS (SELECT 1 FROM awrw_file w WHERE w.dbid=v.dbid AND w.file#=v.file# AND w.creation_change#=v.creation_change# AND w.ftag=''data'')'
                USING p_dbid, v_hwm;
        EXCEPTION WHEN OTHERS THEN
            log_err(p_target_id, 'COLLECT-DIM');   -- keep the facts; names retry next run
        END;

        -- 14) advance the HWM -- atomically with all of the above
        UPDATE awrw_hwm
           SET last_snap_id = v_max,
               last_snap_end_ts = (SELECT MAX(end_interval_time) FROM awrw_snapshot WHERE dbid = p_dbid),
               updated_ts = SYSTIMESTAMP
         WHERE target_id = p_target_id AND dbid = p_dbid;

        COMMIT;                              -- Snapshot-complete or nothing
    END collect_dbid;

    --------------------------------------------------------------- per Target
    PROCEDURE collect_target(p_target_id IN NUMBER) IS
        v_link    awrw_target.db_link%TYPE;
        v_profile awrw_target.profile_name%TYPE;
        v_top_n   awrw_profile.sql_top_n%TYPE;
    BEGIN
        SELECT db_link, profile_name INTO v_link, v_profile
          FROM awrw_target WHERE target_id = p_target_id;
        SELECT sql_top_n INTO v_top_n
          FROM awrw_profile WHERE profile_name = v_profile;

        start_run(p_target_id, 'COLLECT');
        BEGIN
            discover_dbids(p_target_id, v_link);
            FOR d IN (SELECT dbid FROM awrw_dbid WHERE target_id = p_target_id) LOOP
                collect_dbid(p_target_id, d.dbid, v_link, v_top_n);
            END LOOP;

            MERGE INTO awrw_target_health h
            USING (SELECT p_target_id tid FROM dual) s ON (h.target_id = s.tid)
            WHEN MATCHED THEN UPDATE SET
                last_collect_ok_ts = SYSTIMESTAMP, consecutive_fail = 0,
                collect_status = 'CURRENT', updated_ts = SYSTIMESTAMP,
                last_snap_end_ts = (SELECT MAX(end_interval_time) FROM awrw_snapshot WHERE target_id = p_target_id)
            WHEN NOT MATCHED THEN INSERT (target_id, last_collect_ok_ts, consecutive_fail, collect_status, last_snap_end_ts)
                VALUES (p_target_id, SYSTIMESTAMP, 0, 'CURRENT',
                        (SELECT MAX(end_interval_time) FROM awrw_snapshot WHERE target_id = p_target_id));
            COMMIT;
            end_run('OK');
        EXCEPTION WHEN OTHERS THEN
            ROLLBACK;
            log_err(p_target_id, 'COLLECT');
            MERGE INTO awrw_target_health h
            USING (SELECT p_target_id tid FROM dual) s ON (h.target_id = s.tid)
            WHEN MATCHED THEN UPDATE SET
                consecutive_fail = h.consecutive_fail + 1,
                collect_status = 'UNREACHABLE', updated_ts = SYSTIMESTAMP
            WHEN NOT MATCHED THEN INSERT (target_id, consecutive_fail, collect_status)
                VALUES (p_target_id, 1, 'UNREACHABLE');
            COMMIT;
            end_run('ERROR', NULL, SUBSTR(SQLERRM, 1, 400));
        END;
    END collect_target;

    PROCEDURE collect_all IS
    BEGIN
        FOR t IN (SELECT target_id FROM awrw_target WHERE enabled = 'Y' ORDER BY target_id) LOOP
            BEGIN
                collect_target(t.target_id);
            EXCEPTION WHEN OTHERS THEN
                NULL;   -- already logged inside collect_target; never block the fleet
            END;
        END LOOP;
    END collect_all;

    -------------------------------------------------------------- health pass
    -- CURRENT if the newest collected Snapshot is younger than 2 expected
    -- intervals; LAGGING up to 6; STALE beyond. UNREACHABLE is left as set by a
    -- failed collection (this pass never overwrites it upward to STALE/CURRENT
    -- unless fresh data arrived, which collect_target already flips to CURRENT).
    PROCEDURE refresh_health IS
    BEGIN
        UPDATE awrw_target_health h
           SET collect_status =
               CASE
                 WHEN h.last_snap_end_ts IS NULL THEN 'STALE'
                 WHEN h.last_snap_end_ts >= SYSTIMESTAMP - NUMTODSINTERVAL(2 * (SELECT t.snap_interval_min FROM awrw_target t WHERE t.target_id = h.target_id), 'MINUTE') THEN 'CURRENT'
                 WHEN h.last_snap_end_ts >= SYSTIMESTAMP - NUMTODSINTERVAL(6 * (SELECT t.snap_interval_min FROM awrw_target t WHERE t.target_id = h.target_id), 'MINUTE') THEN 'LAGGING'
                 ELSE 'STALE'
               END,
               updated_ts = SYSTIMESTAMP
         WHERE h.collect_status IS NULL
            OR h.collect_status <> 'UNREACHABLE';   -- UNREACHABLE persists until a successful collect flips it to CURRENT
        COMMIT;
    END refresh_health;

END awrw_collect;
/
