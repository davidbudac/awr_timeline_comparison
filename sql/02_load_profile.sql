--
-- 02_load_profile.sql
-- Per-window deltas from DBA_HIST_SYSSTAT for a curated set of stats that
-- make up the classic AWR Load Profile (redo, DB time, CPU, reads, parses,
-- transactions, sorts, etc.).  Renders as a pivot: metric x week.
--
-- For cumulative counters we compute end - begin.  Rates are derived from
-- the window duration in seconds.  Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_label      VARCHAR2(120);
    v_per_sec    NUMBER;
    v_per_sec_s  VARCHAR2(64);
    v_row_max    NUMBER;
    v_pct        NUMBER;
    v_fmt        VARCHAR2(40);

    FUNCTION nth_csv(p_str VARCHAR2, p_n POSITIVE) RETURN VARCHAR2 IS
        v_start PLS_INTEGER := 1;
        v_end   PLS_INTEGER;
        v_cnt   PLS_INTEGER := 0;
    BEGIN
        IF p_str IS NULL OR p_n IS NULL OR p_n < 1 THEN
            RETURN NULL;
        END IF;
        LOOP
            v_end := INSTR(p_str, ',', v_start);
            v_cnt := v_cnt + 1;
            IF v_cnt = p_n THEN
                IF v_end = 0 THEN
                    RETURN SUBSTR(p_str, v_start);
                ELSE
                    RETURN SUBSTR(p_str, v_start, v_end - v_start);
                END IF;
            END IF;
            EXIT WHEN v_end = 0;
            v_start := v_end + 1;
        END LOOP;
        RETURN NULL;
    END nth_csv;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="load"><h2>Load profile &mdash; per-second rates</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Cumulative DBA_HIST_SYSSTAT deltas divided by window duration. '
        || 'The <b>Trend</b> column shows the per-~period_unit_long series (oldest &rarr; current); '
        || 'the bar behind <b>Current</b> shows each value relative to its row max.</p>');

    v_header := '<thead><tr><th>Metric</th><th class="trend">Trend</th><th class="num">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || '~period_unit_short</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR m IN (
        WITH run_params AS (
            SELECT ~dbid AS dbid,
                   CASE WHEN ~inst_num = 0 THEN NULL ELSE ~inst_num END AS instance_number,
                   TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS target_end_ts,
                   ~win_hours  AS win_hours,
                   ~weeks_back AS weeks_back
            FROM dual
        ),
        offsets AS (
            SELECT LEVEL - 1 AS week_offset
            FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        raw_windows AS (
            SELECT r.dbid, r.instance_number, o.week_offset,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset - r.win_hours/24 AS win_start_dt,
                   CAST(r.target_end_ts AS DATE) - (~step_hours/24)*o.week_offset                   AS win_end_dt
            FROM run_params r CROSS JOIN offsets o
        ),
        snaps AS (
            SELECT w.week_offset, w.win_start_dt, w.win_end_dt, w.instance_number, w.dbid,
                   s.snap_id, s.end_interval_time, s.startup_time
            FROM   raw_windows w
            JOIN   dba_hist_snapshot s
              ON   s.dbid = w.dbid
             AND   (w.instance_number IS NULL OR s.instance_number = w.instance_number)
             AND   s.end_interval_time BETWEEN
                        CAST(w.win_start_dt - 1 AS TIMESTAMP)
                    AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
        ),
        begin_snap AS (
            SELECT week_offset,
                   MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS snap_id,
                   MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
            GROUP BY week_offset
        ),
        end_snap AS (
            SELECT week_offset,
                   MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                   MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
            FROM   snaps
            WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
            GROUP BY week_offset
        ),
        windows AS (
            SELECT
                w.week_offset,
                w.dbid, w.instance_number,
                CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
                CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts,
                bs.snap_id AS begin_snap_id,
                es.snap_id AS end_snap_id,
                CASE
                    WHEN bs.snap_id IS NULL OR es.snap_id IS NULL THEN 'N'
                    WHEN bs.snap_id = es.snap_id                  THEN 'N'
                    WHEN bs.startup_time <> es.startup_time       THEN 'N'
                    ELSE 'Y'
                END AS valid_flag
            FROM   raw_windows w
            LEFT JOIN begin_snap bs ON bs.week_offset = w.week_offset
            LEFT JOIN end_snap   es ON es.week_offset = w.week_offset
        ),
        valid_windows AS (
            SELECT week_offset, dbid, instance_number,
                   begin_snap_id, end_snap_id,
                   (CAST(win_end_ts AS DATE) - CAST(win_start_ts AS DATE)) * 86400 AS dur_sec
            FROM windows
            WHERE valid_flag = 'Y'
        ),
        targets AS (
            SELECT 'redo size'                              stat_name FROM dual UNION ALL
            SELECT 'redo size for lost write detection'               FROM dual UNION ALL
            SELECT 'DB time'                                          FROM dual UNION ALL
            SELECT 'DB CPU'                                           FROM dual UNION ALL
            SELECT 'CPU used by this session'                         FROM dual UNION ALL
            SELECT 'session logical reads'                            FROM dual UNION ALL
            SELECT 'physical reads'                                   FROM dual UNION ALL
            SELECT 'physical read total bytes'                        FROM dual UNION ALL
            SELECT 'physical writes'                                  FROM dual UNION ALL
            SELECT 'physical write total bytes'                       FROM dual UNION ALL
            SELECT 'user calls'                                       FROM dual UNION ALL
            SELECT 'user commits'                                     FROM dual UNION ALL
            SELECT 'user rollbacks'                                   FROM dual UNION ALL
            SELECT 'execute count'                                    FROM dual UNION ALL
            SELECT 'parse count (total)'                              FROM dual UNION ALL
            SELECT 'parse count (hard)'                               FROM dual UNION ALL
            SELECT 'parse count (failures)'                           FROM dual UNION ALL
            SELECT 'sorts (memory)'                                   FROM dual UNION ALL
            SELECT 'sorts (disk)'                                     FROM dual UNION ALL
            SELECT 'sorts (rows)'                                     FROM dual UNION ALL
            SELECT 'logons cumulative'                                FROM dual UNION ALL
            SELECT 'opened cursors cumulative'                        FROM dual UNION ALL
            SELECT 'redo writes'                                      FROM dual UNION ALL
            SELECT 'table scans (long tables)'                        FROM dual UNION ALL
            SELECT 'table fetch by rowid'                             FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'                 FROM dual UNION ALL
            SELECT 'bytes received via SQL*Net from client'           FROM dual
        ),
        pairs AS (
            SELECT
                w.week_offset, w.dur_sec,
                ss.stat_name, ss.instance_number,
                ss.snap_id, ss.value,
                w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND (w.instance_number IS NULL OR ss.instance_number = w.instance_number)
               AND ss.stat_name IN (SELECT stat_name FROM targets)
        ),
        bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        deltas AS (
            SELECT week_offset, dur_sec, stat_name,
                   SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS stat_value
            FROM   bounds
            GROUP BY week_offset, dur_sec, stat_name
        ),
        facts AS (
            SELECT week_offset, stat_name,
                   CASE WHEN dur_sec > 0 THEN stat_value / dur_sec END AS per_sec
            FROM   deltas
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT t.stat_name, w.week_offset, f.per_sec
            FROM   targets t
            CROSS JOIN all_weeks w
            LEFT JOIN facts f
                   ON f.stat_name   = t.stat_name
                  AND f.week_offset = w.week_offset
        )
        SELECT stat_name,
               MAX(CASE WHEN week_offset = 0 THEN per_sec END) AS cur_ps,
               MAX(per_sec) AS row_max,
               LISTAGG(CASE WHEN per_sec IS NULL THEN ''
                            ELSE TO_CHAR(per_sec, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset DESC) AS spark_vals,
               LISTAGG(CASE WHEN per_sec IS NULL THEN ''
                            ELSE TO_CHAR(per_sec, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                   WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals
        FROM   grid
        GROUP BY stat_name
        ORDER BY CASE stat_name
            WHEN 'DB time'                    THEN 1
            WHEN 'DB CPU'                     THEN 2
            WHEN 'redo size'                  THEN 3
            WHEN 'session logical reads'      THEN 4
            WHEN 'physical reads'             THEN 5
            WHEN 'physical read total bytes'  THEN 6
            WHEN 'physical writes'            THEN 7
            WHEN 'physical write total bytes' THEN 8
            WHEN 'user calls'                 THEN 9
            WHEN 'execute count'              THEN 10
            WHEN 'user commits'               THEN 11
            WHEN 'user rollbacks'             THEN 12
            WHEN 'parse count (total)'        THEN 13
            WHEN 'parse count (hard)'         THEN 14
            WHEN 'parse count (failures)'     THEN 15
            WHEN 'logons cumulative'          THEN 16
            WHEN 'opened cursors cumulative'  THEN 17
            WHEN 'redo writes'                THEN 18
            WHEN 'sorts (memory)'             THEN 19
            WHEN 'sorts (disk)'               THEN 20
            WHEN 'sorts (rows)'               THEN 21
            WHEN 'table scans (long tables)'  THEN 22
            WHEN 'table fetch by rowid'       THEN 23
            ELSE 99 END,
            stat_name
    ) LOOP
        v_label := m.stat_name;
        IF m.stat_name IN ('redo size', 'physical read total bytes', 'physical write total bytes',
                           'bytes sent via SQL*Net to client', 'bytes received via SQL*Net from client') THEN
            v_label := v_label || ' (bytes/s)';
        ELSIF m.stat_name IN ('DB time', 'DB CPU', 'CPU used by this session') THEN
            v_label := v_label || ' (cs/s, 1/100s)';
        ELSE
            v_label := v_label || ' (/s)';
        END IF;

        v_row := '<tr><td>' || DBMS_XMLGEN.CONVERT(v_label) || '</td>';

        v_row := v_row || '<td class="trend" data-spark="'
              || NVL(m.spark_vals, '') || '" data-spark-title="'
              || DBMS_XMLGEN.CONVERT(v_label) || '"></td>';

        v_row_max := NVL(m.row_max, 0);
        v_fmt := CASE
            WHEN v_row_max = 0 OR v_row_max >= 1   THEN 'FM999G999G999G990D00'
            WHEN v_row_max >= 0.01                  THEN 'FM990D0000'
            WHEN v_row_max >= 0.0001                THEN 'FM990D000000'
            ELSE                                         'FM0D00EEEE'
        END;

        IF v_row_max > 0 AND m.cur_ps IS NOT NULL THEN
            v_pct := LEAST(100, ABS(m.cur_ps) / v_row_max * 100);
        ELSE
            v_pct := 0;
        END IF;

        v_row := v_row || '<td class="num cell-bar">'
              || '<span class="bg" style="width:' || TO_CHAR(v_pct, 'FM990D0') || '%"></span>'
              || '<span class="v"><b>' ||
                CASE WHEN m.cur_ps IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(m.cur_ps, v_fmt) END
              || '</b></span></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_per_sec_s := nth_csv(m.week_vals, k + 1);
            IF v_per_sec_s IS NULL OR v_per_sec_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;</td>';
            ELSE
                v_per_sec := TO_NUMBER(v_per_sec_s, 'FM99999999990D000000',
                                       'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_per_sec, v_fmt) || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
