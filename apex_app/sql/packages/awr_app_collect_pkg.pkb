CREATE OR REPLACE PACKAGE BODY awr_app_collect_pkg AS
    TYPE t_run_ctx IS RECORD (
        run_id          awr_trend_runs.run_id%TYPE,
        target_id       awr_trend_runs.target_id%TYPE,
        dbid            awr_trend_runs.dbid%TYPE,
        db_name         awr_trend_runs.db_name%TYPE,
        instance_number awr_trend_runs.instance_number%TYPE,
        target_end_ts   awr_trend_runs.target_end_ts%TYPE,
        win_hours       awr_trend_runs.win_hours%TYPE,
        weeks_back      awr_trend_runs.weeks_back%TYPE,
        top_n           awr_trend_runs.top_n%TYPE,
        db_link_name    awr_app_targets.db_link_name%TYPE
    );

    FUNCTION get_run_ctx(p_run_id IN NUMBER) RETURN t_run_ctx IS
        l_ctx t_run_ctx;
    BEGIN
        SELECT r.run_id,
               r.target_id,
               r.dbid,
               r.db_name,
               r.instance_number,
               r.target_end_ts,
               r.win_hours,
               r.weeks_back,
               r.top_n,
               t.db_link_name
        INTO   l_ctx
        FROM   awr_trend_runs r
        JOIN   awr_app_targets t
               ON t.target_id = r.target_id
        WHERE  r.run_id = p_run_id;

        RETURN l_ctx;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20080, 'Run ' || p_run_id || ' is not registered to an AWR_APP target.');
    END get_run_ctx;

    FUNCTION safe_dblink_name(p_db_link_name IN VARCHAR2) RETURN VARCHAR2 IS
        l_db_link VARCHAR2(128);
    BEGIN
        IF p_db_link_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20081, 'DB link name cannot be null.');
        END IF;

        IF NOT REGEXP_LIKE(p_db_link_name, '^[A-Za-z0-9_.$#]+$') THEN
            RAISE_APPLICATION_ERROR(-20082, 'Unsupported DB link name: ' || p_db_link_name);
        END IF;

        SELECT db_link
        INTO   l_db_link
        FROM (
            SELECT db_link
            FROM   all_db_links
            WHERE  UPPER(db_link) = UPPER(p_db_link_name)
            ORDER BY CASE WHEN owner = USER THEN 1 ELSE 2 END
        )
        WHERE  ROWNUM = 1;

        RETURN l_db_link;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20083, 'DB link not found or not visible: ' || p_db_link_name);
    END safe_dblink_name;

    PROCEDURE log_event(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_status    IN VARCHAR2,
        p_message   IN VARCHAR2,
        p_log_level IN VARCHAR2 DEFAULT 'INFO',
        p_details   IN CLOB DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO awr_app_run_log (
            log_id,
            run_id,
            step_name,
            log_level,
            status,
            message,
            details,
            created_at
        ) VALUES (
            awr_app_run_log_seq.NEXTVAL,
            p_run_id,
            SUBSTR(p_step_name, 1, 100),
            SUBSTR(UPPER(NVL(p_log_level, 'INFO')), 1, 10),
            SUBSTR(UPPER(NVL(p_status, 'INFO')), 1, 20),
            SUBSTR(p_message, 1, 4000),
            p_details,
            SYSTIMESTAMP
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END log_event;

    PROCEDURE run_step_sql(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_message   IN VARCHAR2,
        p_sql       IN CLOB
    ) IS
        l_rows NUMBER;
    BEGIN
        log_event(p_run_id, p_step_name, 'STARTED', p_message);
        EXECUTE IMMEDIATE p_sql;
        l_rows := SQL%ROWCOUNT;
        COMMIT;
        log_event(
            p_run_id    => p_run_id,
            p_step_name => p_step_name,
            p_status    => 'OK',
            p_message   => p_message || ' complete. Rows=' || l_rows
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_event(
                p_run_id    => p_run_id,
                p_step_name => p_step_name,
                p_status    => 'FAILED',
                p_message   => p_message || ' failed: ' || SQLERRM,
                p_log_level => 'ERROR',
                p_details   => DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END run_step_sql;

    PROCEDURE initialize_run(p_run_id IN NUMBER) IS
        l_ctx      t_run_ctx;
        l_dblink   VARCHAR2(128);
        l_dbid     NUMBER;
        l_db_name  VARCHAR2(30);
        l_sql      VARCHAR2(4000);
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        log_event(p_run_id, 'initialize_run', 'STARTED', 'Validating remote connection and refreshing target identity.');

        l_sql := 'SELECT dbid, name FROM v$database@' || l_dblink;
        EXECUTE IMMEDIATE l_sql INTO l_dbid, l_db_name;

        UPDATE awr_trend_runs
        SET    dbid       = l_dbid,
               db_name    = l_db_name,
               generated_at = NVL(generated_at, SYSTIMESTAMP)
        WHERE  run_id = p_run_id;

        UPDATE awr_app_targets
        SET    last_validated_at = SYSTIMESTAMP,
               updated_at        = SYSTIMESTAMP
        WHERE  target_id = l_ctx.target_id;

        COMMIT;

        log_event(
            p_run_id    => p_run_id,
            p_step_name => 'initialize_run',
            p_status    => 'OK',
            p_message   => 'Connected through ' || l_dblink || ' to DBID ' || l_dbid || ' (' || l_db_name || ').'
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_event(
                p_run_id    => p_run_id,
                p_step_name => 'initialize_run',
                p_status    => 'FAILED',
                p_message   => 'Remote target validation failed: ' || SQLERRM,
                p_log_level => 'ERROR',
                p_details   => DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END initialize_run;

    PROCEDURE purge_run_data(p_run_id IN NUMBER) IS
    BEGIN
        log_event(p_run_id, 'purge_run_data', 'STARTED', 'Removing existing facts for rerun safety.');

        DELETE FROM awr_trend_findings     WHERE run_id = p_run_id;
        DELETE FROM awr_trend_top_sql      WHERE run_id = p_run_id;
        DELETE FROM awr_trend_waits        WHERE run_id = p_run_id;
        DELETE FROM awr_trend_sysmetric    WHERE run_id = p_run_id;
        DELETE FROM awr_trend_load_profile WHERE run_id = p_run_id;
        DELETE FROM awr_trend_windows      WHERE run_id = p_run_id;
        COMMIT;

        log_event(p_run_id, 'purge_run_data', 'OK', 'Run data purge complete.');
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_event(
                p_run_id    => p_run_id,
                p_step_name => 'purge_run_data',
                p_status    => 'FAILED',
                p_message   => 'Unable to clear prior run facts: ' || SQLERRM,
                p_log_level => 'ERROR',
                p_details   => DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END purge_run_data;

    PROCEDURE collect_windows(p_run_id IN NUMBER) IS
        l_ctx    t_run_ctx;
        l_dblink VARCHAR2(128);
        l_sql    CLOB;
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        l_sql := q'~INSERT INTO awr_trend_windows (
            run_id, week_offset, win_start_ts, win_end_ts,
            begin_snap_id, end_snap_id, valid_flag, skip_reason
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number, target_end_ts, win_hours, weeks_back
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual
            CONNECT BY LEVEL <= (SELECT weeks_back + 1 FROM run)
        ),
        windows AS (
            SELECT r.run_id,
                   o.week_offset,
                   CAST(r.target_end_ts AS DATE) - 7 * o.week_offset - r.win_hours / 24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - 7 * o.week_offset AS win_end_dt,
                   r.dbid,
                   r.instance_number
            FROM   run r
            CROSS JOIN offsets o
        ),
        snaps AS (
            SELECT w.run_id,
                   w.week_offset,
                   w.win_start_dt,
                   w.win_end_dt,
                   s.snap_id,
                   s.begin_interval_time,
                   s.end_interval_time,
                   s.startup_time,
                   s.instance_number
            FROM   windows w
            JOIN   dba_hist_snapshot@~' || l_dblink || q'~ s
                   ON s.dbid = w.dbid
                  AND (w.instance_number IS NULL OR s.instance_number = w.instance_number)
                  AND s.end_interval_time BETWEEN
                      CAST(w.win_start_dt - 1 AS TIMESTAMP) AND CAST(w.win_end_dt + 1 AS TIMESTAMP)
        ),
        begin_snap AS (
            SELECT run_id,
                   week_offset,
                   MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS snap_id,
                   MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time <= CAST(win_start_dt + 5 / 1440 AS TIMESTAMP)
            GROUP BY run_id, week_offset
        ),
        end_snap AS (
            SELECT run_id,
                   week_offset,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5 / 1440 AS TIMESTAMP)
            GROUP BY run_id, week_offset
        )
        SELECT w.run_id,
               w.week_offset,
               CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
               CAST(w.win_end_dt AS TIMESTAMP) AS win_end_ts,
               bs.snap_id AS begin_snap_id,
               es.snap_id AS end_snap_id,
               CASE
                   WHEN bs.snap_id IS NULL OR es.snap_id IS NULL THEN 'N'
                   WHEN bs.snap_id = es.snap_id THEN 'N'
                   WHEN bs.startup_time <> es.startup_time THEN 'N'
                   ELSE 'Y'
               END AS valid_flag,
               CASE
                   WHEN bs.snap_id IS NULL THEN 'no snapshot at/before window start'
                   WHEN es.snap_id IS NULL THEN 'no snapshot at/after window end'
                   WHEN bs.snap_id = es.snap_id THEN 'begin and end snapshot identical (window shorter than AWR interval)'
                   WHEN bs.startup_time <> es.startup_time THEN 'instance restarted inside window'
                   ELSE NULL
               END AS skip_reason
        FROM   windows w
        LEFT JOIN begin_snap bs
               ON bs.run_id = w.run_id
              AND bs.week_offset = w.week_offset
        LEFT JOIN end_snap es
               ON es.run_id = w.run_id
              AND es.week_offset = w.week_offset~';

        run_step_sql(p_run_id, 'collect_windows', 'Collecting aligned snapshot windows.', l_sql);
    END collect_windows;

    PROCEDURE collect_load_profile(p_run_id IN NUMBER) IS
        l_ctx    t_run_ctx;
        l_dblink VARCHAR2(128);
        l_sql    CLOB;
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        l_sql := q'~INSERT INTO awr_trend_load_profile (
            run_id, week_offset, stat_name, stat_value, per_sec, per_txn
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT w.*,
                   (CAST(w.win_end_ts AS DATE) - CAST(w.win_start_ts AS DATE)) * 86400 AS dur_sec
            FROM   awr_trend_windows w
            WHERE  w.run_id = ~' || p_run_id || q'~
            AND    w.valid_flag = 'Y'
        ),
        targets AS (
            SELECT 'redo size' stat_name FROM dual UNION ALL
            SELECT 'redo size for lost write detection' FROM dual UNION ALL
            SELECT 'DB time' FROM dual UNION ALL
            SELECT 'DB CPU' FROM dual UNION ALL
            SELECT 'CPU used by this session' FROM dual UNION ALL
            SELECT 'session logical reads' FROM dual UNION ALL
            SELECT 'physical reads' FROM dual UNION ALL
            SELECT 'physical read total bytes' FROM dual UNION ALL
            SELECT 'physical writes' FROM dual UNION ALL
            SELECT 'physical write total bytes' FROM dual UNION ALL
            SELECT 'user calls' FROM dual UNION ALL
            SELECT 'user commits' FROM dual UNION ALL
            SELECT 'user rollbacks' FROM dual UNION ALL
            SELECT 'execute count' FROM dual UNION ALL
            SELECT 'parse count (total)' FROM dual UNION ALL
            SELECT 'parse count (hard)' FROM dual UNION ALL
            SELECT 'parse count (failures)' FROM dual UNION ALL
            SELECT 'sorts (memory)' FROM dual UNION ALL
            SELECT 'sorts (disk)' FROM dual UNION ALL
            SELECT 'sorts (rows)' FROM dual UNION ALL
            SELECT 'logons cumulative' FROM dual UNION ALL
            SELECT 'opened cursors cumulative' FROM dual UNION ALL
            SELECT 'redo writes' FROM dual UNION ALL
            SELECT 'table scans (long tables)' FROM dual UNION ALL
            SELECT 'table fetch by rowid' FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client' FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client' FROM dual
        ),
        pairs AS (
            SELECT w.run_id,
                   w.week_offset,
                   w.dur_sec,
                   ss.stat_name,
                   ss.instance_number,
                   ss.snap_id,
                   ss.value,
                   w.begin_snap_id,
                   w.end_snap_id
            FROM   wins w
            JOIN   run r
                   ON 1 = 1
            JOIN   dba_hist_sysstat@~' || l_dblink || q'~ ss
                   ON ss.dbid = r.dbid
                  AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
                  AND (r.instance_number IS NULL OR ss.instance_number = r.instance_number)
                  AND ss.stat_name IN (SELECT stat_name FROM targets)
        ),
        bounds AS (
            SELECT run_id,
                   week_offset,
                   dur_sec,
                   stat_name,
                   instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id THEN value END) AS end_val
            FROM   pairs
            GROUP BY run_id, week_offset, dur_sec, stat_name, instance_number
        ),
        deltas AS (
            SELECT run_id,
                   week_offset,
                   dur_sec,
                   stat_name,
                   SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS stat_value
            FROM   bounds
            GROUP BY run_id, week_offset, dur_sec, stat_name
        ),
        txns AS (
            SELECT run_id,
                   week_offset,
                   SUM(CASE WHEN stat_name IN ('user commits', 'user rollbacks') THEN stat_value END) AS txn_delta
            FROM   deltas
            GROUP BY run_id, week_offset
        )
        SELECT d.run_id,
               d.week_offset,
               d.stat_name,
               d.stat_value,
               CASE WHEN d.dur_sec > 0 THEN d.stat_value / d.dur_sec END AS per_sec,
               CASE WHEN NVL(t.txn_delta, 0) > 0 THEN d.stat_value / t.txn_delta END AS per_txn
        FROM   deltas d
        LEFT JOIN txns t
               ON t.run_id = d.run_id
              AND t.week_offset = d.week_offset~';

        run_step_sql(p_run_id, 'collect_load_profile', 'Collecting SYSSTAT deltas for load profile.', l_sql);
    END collect_load_profile;

    PROCEDURE collect_sysmetric(p_run_id IN NUMBER) IS
        l_ctx    t_run_ctx;
        l_dblink VARCHAR2(128);
        l_sql    CLOB;
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        l_sql := q'~INSERT INTO awr_trend_sysmetric (
            run_id, week_offset, metric_name, metric_unit, avg_value, max_value
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT w.run_id, w.week_offset, w.begin_snap_id, w.end_snap_id
            FROM   awr_trend_windows w
            WHERE  w.run_id = ~' || p_run_id || q'~
            AND    w.valid_flag = 'Y'
        ),
        targets AS (
            SELECT 'Host CPU Utilization (%)' metric_name FROM dual UNION ALL
            SELECT 'Database CPU Time Ratio' FROM dual UNION ALL
            SELECT 'Database Wait Time Ratio' FROM dual UNION ALL
            SELECT 'Average Active Sessions' FROM dual UNION ALL
            SELECT 'Average Synchronous Single-Block Read Latency' FROM dual UNION ALL
            SELECT 'Physical Reads Per Sec' FROM dual UNION ALL
            SELECT 'Physical Writes Per Sec' FROM dual UNION ALL
            SELECT 'Physical Read Total IO Requests Per Sec' FROM dual UNION ALL
            SELECT 'Physical Write Total IO Requests Per Sec' FROM dual UNION ALL
            SELECT 'Physical Read Total Bytes Per Sec' FROM dual UNION ALL
            SELECT 'Physical Write Total Bytes Per Sec' FROM dual UNION ALL
            SELECT 'Redo Generated Per Sec' FROM dual UNION ALL
            SELECT 'Logons Per Sec' FROM dual UNION ALL
            SELECT 'Logical Reads Per Sec' FROM dual UNION ALL
            SELECT 'User Calls Per Sec' FROM dual UNION ALL
            SELECT 'User Commits Per Sec' FROM dual UNION ALL
            SELECT 'User Rollbacks Per Sec' FROM dual UNION ALL
            SELECT 'Executions Per Sec' FROM dual UNION ALL
            SELECT 'Hard Parse Count Per Sec' FROM dual UNION ALL
            SELECT 'Total Parse Count Per Sec' FROM dual UNION ALL
            SELECT 'Session Count' FROM dual UNION ALL
            SELECT 'Network Traffic Volume Per Sec' FROM dual UNION ALL
            SELECT 'SQL Service Response Time' FROM dual
        )
        SELECT w.run_id,
               w.week_offset,
               sm.metric_name,
               MAX(sm.metric_unit) AS metric_unit,
               AVG(sm.average) AS avg_value,
               MAX(sm.maxval) AS max_value
        FROM   wins w
        CROSS JOIN targets t
        JOIN   run r
               ON 1 = 1
        JOIN   dba_hist_sysmetric_summary@~' || l_dblink || q'~ sm
               ON sm.dbid = r.dbid
              AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
              AND (r.instance_number IS NULL OR sm.instance_number = r.instance_number)
              AND sm.metric_name = t.metric_name
        GROUP BY w.run_id, w.week_offset, sm.metric_name~';

        run_step_sql(p_run_id, 'collect_sysmetric', 'Collecting DBA_HIST_SYSMETRIC_SUMMARY aggregates.', l_sql);
    END collect_sysmetric;

    PROCEDURE collect_waits(p_run_id IN NUMBER) IS
        l_ctx    t_run_ctx;
        l_dblink VARCHAR2(128);
        l_sql    CLOB;
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        l_sql := q'~INSERT INTO awr_trend_waits (
            run_id, week_offset, scope, event_name, wait_class,
            total_waits, time_waited_us, avg_wait_ms, rank_in_window
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number, top_n
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT run_id, week_offset, begin_snap_id, end_snap_id
            FROM   awr_trend_windows
            WHERE  run_id = ~' || p_run_id || q'~
            AND    valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.run_id,
                   w.week_offset,
                   se.event_name,
                   se.wait_class,
                   se.snap_id,
                   se.instance_number,
                   se.total_waits,
                   se.time_waited_micro,
                   w.begin_snap_id,
                   w.end_snap_id
            FROM   wins w
            JOIN   run r
                   ON 1 = 1
            JOIN   dba_hist_system_event@~' || l_dblink || q'~ se
                   ON se.dbid = r.dbid
                  AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
                  AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
                  AND se.wait_class <> 'Idle'
        ),
        bounds AS (
            SELECT run_id,
                   week_offset,
                   instance_number,
                   event_name,
                   wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END) AS beg_waits,
                   SUM(CASE WHEN snap_id = end_snap_id THEN total_waits END) AS end_waits,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY run_id, week_offset, instance_number, event_name, wait_class
        ),
        deltas AS (
            SELECT run_id,
                   week_offset,
                   event_name,
                   wait_class,
                   SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
                   SUM(NVL(end_us, 0) - NVL(beg_us, 0)) AS time_waited_us
            FROM   bounds
            GROUP BY run_id, week_offset, event_name, wait_class
        ),
        ranked AS (
            SELECT d.*,
                   RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
            FROM   deltas d
            WHERE  time_waited_us > 0
        )
        SELECT run_id,
               week_offset,
               'FG',
               event_name,
               wait_class,
               total_waits,
               time_waited_us,
               CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
               rnk
        FROM   ranked
        WHERE  rnk <= (SELECT top_n FROM run)~';
        run_step_sql(p_run_id, 'collect_waits_fg', 'Collecting foreground wait events.', l_sql);

        l_sql := q'~INSERT INTO awr_trend_waits (
            run_id, week_offset, scope, event_name, wait_class,
            total_waits, time_waited_us, avg_wait_ms, rank_in_window
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT run_id, week_offset, begin_snap_id, end_snap_id
            FROM   awr_trend_windows
            WHERE  run_id = ~' || p_run_id || q'~
            AND    valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.run_id,
                   w.week_offset,
                   se.wait_class,
                   se.snap_id,
                   se.instance_number,
                   se.total_waits,
                   se.time_waited_micro,
                   w.begin_snap_id,
                   w.end_snap_id
            FROM   wins w
            JOIN   run r
                   ON 1 = 1
            JOIN   dba_hist_system_event@~' || l_dblink || q'~ se
                   ON se.dbid = r.dbid
                  AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
                  AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
                  AND se.wait_class <> 'Idle'
        ),
        bounds AS (
            SELECT run_id,
                   week_offset,
                   instance_number,
                   wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END) AS beg_waits,
                   SUM(CASE WHEN snap_id = end_snap_id THEN total_waits END) AS end_waits,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY run_id, week_offset, instance_number, wait_class
        ),
        class_deltas AS (
            SELECT run_id,
                   week_offset,
                   wait_class,
                   SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
                   SUM(NVL(end_us, 0) - NVL(beg_us, 0)) AS time_waited_us
            FROM   bounds
            GROUP BY run_id, week_offset, wait_class
        ),
        ranked AS (
            SELECT c.*,
                   RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
            FROM   class_deltas c
            WHERE  time_waited_us > 0
        )
        SELECT run_id,
               week_offset,
               'CLASS',
               wait_class AS event_name,
               wait_class,
               total_waits,
               time_waited_us,
               CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END,
               rnk
        FROM   ranked~';
        run_step_sql(p_run_id, 'collect_waits_class', 'Collecting wait class rollups.', l_sql);

        l_sql := q'~INSERT INTO awr_trend_waits (
            run_id, week_offset, scope, event_name, wait_class,
            total_waits, time_waited_us, avg_wait_ms, rank_in_window
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number, top_n
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT run_id, week_offset, begin_snap_id, end_snap_id
            FROM   awr_trend_windows
            WHERE  run_id = ~' || p_run_id || q'~
            AND    valid_flag = 'Y'
        ),
        pairs AS (
            SELECT w.run_id,
                   w.week_offset,
                   bg.event_name,
                   bg.wait_class,
                   bg.snap_id,
                   bg.total_waits,
                   bg.time_waited_micro,
                   w.begin_snap_id,
                   w.end_snap_id
            FROM   wins w
            JOIN   run r
                   ON 1 = 1
            JOIN   dba_hist_bg_event_summary@~' || l_dblink || q'~ bg
                   ON bg.dbid = r.dbid
                  AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
                  AND (r.instance_number IS NULL OR bg.instance_number = r.instance_number)
                  AND NVL(bg.wait_class, 'Other') <> 'Idle'
        ),
        bounds AS (
            SELECT run_id,
                   week_offset,
                   event_name,
                   wait_class,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END) AS beg_waits,
                   SUM(CASE WHEN snap_id = end_snap_id THEN total_waits END) AS end_waits,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
                   SUM(CASE WHEN snap_id = end_snap_id THEN time_waited_micro END) AS end_us
            FROM   pairs
            GROUP BY run_id, week_offset, event_name, wait_class
        ),
        deltas AS (
            SELECT run_id,
                   week_offset,
                   event_name,
                   wait_class,
                   NVL(end_waits, 0) - NVL(beg_waits, 0) AS total_waits,
                   NVL(end_us, 0) - NVL(beg_us, 0) AS time_waited_us
            FROM   bounds
        ),
        ranked AS (
            SELECT d.*,
                   RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
            FROM   deltas d
            WHERE  time_waited_us > 0
        )
        SELECT run_id,
               week_offset,
               'BG',
               event_name,
               wait_class,
               total_waits,
               time_waited_us,
               CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
               rnk
        FROM   ranked
        WHERE  rnk <= (SELECT top_n FROM run)~';
        run_step_sql(p_run_id, 'collect_waits_bg', 'Collecting background wait events.', l_sql);
    END collect_waits;

    PROCEDURE collect_top_sql(p_run_id IN NUMBER) IS
        l_ctx    t_run_ctx;
        l_dblink VARCHAR2(128);
        l_sql    CLOB;
    BEGIN
        l_ctx := get_run_ctx(p_run_id);
        l_dblink := safe_dblink_name(l_ctx.db_link_name);

        l_sql := q'~INSERT INTO awr_trend_top_sql (
            run_id, week_offset, dimension, rank_in_window,
            sql_id, plan_hash_value,
            executions_delta, elapsed_time_delta_us, cpu_time_delta_us,
            buffer_gets_delta, disk_reads_delta, rows_processed_delta,
            sql_text_short
        )
        WITH run AS (
            SELECT run_id, dbid, instance_number, top_n
            FROM   awr_trend_runs
            WHERE  run_id = ~' || p_run_id || q'~
        ),
        wins AS (
            SELECT run_id, week_offset, begin_snap_id, end_snap_id
            FROM   awr_trend_windows
            WHERE  run_id = ~' || p_run_id || q'~
            AND    valid_flag = 'Y'
        ),
        agg AS (
            SELECT w.run_id,
                   w.week_offset,
                   s.sql_id,
                   MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
                   SUM(NVL(s.executions_delta, 0)) AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0)) AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0)) AS buffer_gets_delta,
                   SUM(NVL(s.disk_reads_delta, 0)) AS disk_reads_delta,
                   SUM(NVL(s.rows_processed_delta, 0)) AS rows_processed_delta
            FROM   wins w
            JOIN   run r
                   ON 1 = 1
            JOIN   dba_hist_sqlstat@~' || l_dblink || q'~ s
                   ON s.dbid = r.dbid
                  AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                  AND (r.instance_number IS NULL OR s.instance_number = r.instance_number)
            GROUP BY w.run_id, w.week_offset, s.sql_id
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY run_id, week_offset
                       ORDER BY elapsed_time_delta_us DESC, sql_id
                   ) AS r_ela,
                   ROW_NUMBER() OVER (
                       PARTITION BY run_id, week_offset
                       ORDER BY cpu_time_delta_us DESC, sql_id
                   ) AS r_cpu,
                   ROW_NUMBER() OVER (
                       PARTITION BY run_id, week_offset
                       ORDER BY buffer_gets_delta DESC, sql_id
                   ) AS r_gets,
                   ROW_NUMBER() OVER (
                       PARTITION BY run_id, week_offset
                       ORDER BY executions_delta DESC, sql_id
                   ) AS r_exec
            FROM   agg a
        ),
        picked AS (
            SELECT run_id, week_offset, 'ELAPSED' AS dimension, r_ela AS rnk,
                   sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
                   cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
            FROM   ranked
            WHERE  r_ela <= (SELECT top_n FROM run)
            AND    elapsed_time_delta_us > 0
            UNION ALL
            SELECT run_id, week_offset, 'CPU' AS dimension, r_cpu AS rnk,
                   sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
                   cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
            FROM   ranked
            WHERE  r_cpu <= (SELECT top_n FROM run)
            AND    cpu_time_delta_us > 0
            UNION ALL
            SELECT run_id, week_offset, 'GETS' AS dimension, r_gets AS rnk,
                   sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
                   cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
            FROM   ranked
            WHERE  r_gets <= (SELECT top_n FROM run)
            AND    buffer_gets_delta > 0
            UNION ALL
            SELECT run_id, week_offset, 'EXEC' AS dimension, r_exec AS rnk,
                   sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us,
                   cpu_time_delta_us, buffer_gets_delta, disk_reads_delta, rows_processed_delta
            FROM   ranked
            WHERE  r_exec <= (SELECT top_n FROM run)
            AND    executions_delta > 0
        )
        SELECT p.run_id,
               p.week_offset,
               p.dimension,
               p.rnk,
               p.sql_id,
               p.plan_hash_value,
               p.executions_delta,
               p.elapsed_time_delta_us,
               p.cpu_time_delta_us,
               p.buffer_gets_delta,
               p.disk_reads_delta,
               p.rows_processed_delta,
               CAST(NULL AS VARCHAR2(400)) AS sql_text_short
        FROM   picked p~';

        run_step_sql(p_run_id, 'collect_top_sql', 'Collecting top SQL dimensions.', l_sql);
    END collect_top_sql;

    PROCEDURE collect_findings(p_run_id IN NUMBER) IS
        l_sql CLOB;
    BEGIN
        l_sql := q'~INSERT INTO awr_trend_findings (
            run_id, metric_domain, metric_name,
            current_value, prior_mean, prior_sd, n_prior, z_score, pct_delta, severity
        )
        WITH unified AS (
            SELECT run_id,
                   week_offset,
                   'LOAD' AS metric_domain,
                   stat_name AS metric_name,
                   per_sec AS value
            FROM   awr_trend_load_profile
            WHERE  run_id = ~' || p_run_id || q'~
            AND    per_sec IS NOT NULL
            UNION ALL
            SELECT run_id,
                   week_offset,
                   'METRIC' AS metric_domain,
                   metric_name,
                   avg_value AS value
            FROM   awr_trend_sysmetric
            WHERE  run_id = ~' || p_run_id || q'~
            AND    avg_value IS NOT NULL
            UNION ALL
            SELECT w.run_id,
                   w.week_offset,
                   'WAIT' AS metric_domain,
                   'Wait class: ' || w.wait_class AS metric_name,
                   w.time_waited_us / NULLIF(
                       (CAST(win.win_end_ts AS DATE) - CAST(win.win_start_ts AS DATE)) * 86400 * 1e6,
                       0
                   ) AS value
            FROM   awr_trend_waits w
            JOIN   awr_trend_windows win
                   ON win.run_id = w.run_id
                  AND win.week_offset = w.week_offset
            WHERE  w.run_id = ~' || p_run_id || q'~
            AND    w.scope = 'CLASS'
        ),
        pivoted AS (
            SELECT run_id,
                   metric_domain,
                   metric_name,
                   MAX(CASE WHEN week_offset = 0 THEN value END) AS cur_val,
                   AVG(CASE WHEN week_offset > 0 THEN value END) AS mu,
                   STDDEV(CASE WHEN week_offset > 0 THEN value END) AS sd,
                   COUNT(CASE WHEN week_offset > 0 THEN value END) AS n
            FROM   unified
            GROUP BY run_id, metric_domain, metric_name
        )
        SELECT run_id,
               metric_domain,
               metric_name,
               cur_val,
               mu,
               sd,
               n,
               CASE
                   WHEN cur_val IS NULL OR mu IS NULL THEN NULL
                   WHEN sd IS NULL OR sd = 0 THEN NULL
                   ELSE (cur_val - mu) / sd
               END AS z_score,
               CASE
                   WHEN cur_val IS NULL OR mu IS NULL OR mu = 0 THEN NULL
                   ELSE (cur_val - mu) / ABS(mu) * 100
               END AS pct_delta,
               CASE
                   WHEN cur_val IS NULL THEN 'INSUFFICIENT_HISTORY'
                   WHEN n < 3 THEN 'INSUFFICIENT_HISTORY'
                   WHEN sd IS NULL OR sd = 0 THEN 'FLAT_BASELINE'
                   WHEN ABS((cur_val - mu) / sd) > 3 THEN 'CRITICAL'
                   WHEN ABS((cur_val - mu) / sd) > 2 THEN 'WARN'
                   ELSE 'OK'
               END AS severity
        FROM   pivoted
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL~';

        run_step_sql(p_run_id, 'collect_findings', 'Calculating z-score findings.', l_sql);
    END collect_findings;
END awr_app_collect_pkg;
/
