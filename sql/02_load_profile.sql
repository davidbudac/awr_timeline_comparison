--
-- 02_load_profile.sql
-- Per-window deltas from DBA_HIST_SYSSTAT for a curated set of stats that
-- make up the classic AWR Load Profile (redo, DB time, CPU, reads, parses,
-- transactions, sorts, etc.).  Renders as a pivot: metric x week.
--
-- For cumulative counters we compute end - begin.  Rates are derived from
-- the window duration in seconds and from the DB 'user commits' +
-- 'user rollbacks' delta (transactions).
--

SET DEFINE '~'

--
-- Insert the facts.
--
INSERT INTO awr_trend_load_profile (run_id, week_offset, stat_name, stat_value, per_sec, per_txn)
WITH run AS (
    SELECT run_id, dbid, instance_number
    FROM   awr_trend_runs
    WHERE  run_id = ~run_id
),
wins AS (
    SELECT w.*, (CAST(w.win_end_ts AS DATE) - CAST(w.win_start_ts AS DATE)) * 86400 AS dur_sec
    FROM   awr_trend_windows w
    WHERE  w.run_id = ~run_id
    AND    w.valid_flag = 'Y'
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
        w.run_id, w.week_offset, w.dur_sec,
        ss.stat_name, ss.instance_number,
        ss.snap_id, ss.value,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run r ON 1=1
    JOIN   dba_hist_sysstat ss
        ON ss.dbid = r.dbid
       AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR ss.instance_number = r.instance_number)
       AND ss.stat_name IN (SELECT stat_name FROM targets)
),
bounds AS (
    SELECT run_id, week_offset, dur_sec, stat_name, instance_number,
           SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
           SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
    FROM   pairs
    GROUP BY run_id, week_offset, dur_sec, stat_name, instance_number
),
deltas AS (
    SELECT run_id, week_offset, dur_sec, stat_name,
           SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS stat_value
    FROM   bounds
    GROUP BY run_id, week_offset, dur_sec, stat_name
),
txns AS (
    SELECT run_id, week_offset,
           SUM(CASE WHEN stat_name IN ('user commits','user rollbacks')
                    THEN stat_value END) AS txn_delta
    FROM   deltas
    GROUP BY run_id, week_offset
)
SELECT
    d.run_id,
    d.week_offset,
    d.stat_name,
    d.stat_value,
    CASE WHEN d.dur_sec > 0 THEN d.stat_value / d.dur_sec END AS per_sec,
    CASE WHEN NVL(t.txn_delta, 0) > 0 THEN d.stat_value / t.txn_delta END AS per_txn
FROM   deltas d
LEFT JOIN txns t ON t.run_id = d.run_id AND t.week_offset = d.week_offset;

COMMIT;

--
-- Render the pivoted HTML table.  Columns: metric, cur, -1w, ..., -Nw.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back  NUMBER;
    v_header      VARCHAR2(4000);
    v_row         VARCHAR2(32767);
    v_label       VARCHAR2(120);
    v_per_sec     NUMBER;
    v_points      VARCHAR2(4000);
    v_token       VARCHAR2(80);
    TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_vals        t_num_tab;
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = ~run_id;

    -- Units lookup: most stats shown as per-second; a few always as totals.
    DBMS_OUTPUT.PUT_LINE('<section id="load"><h2>Load profile &mdash; per-second rates</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Cumulative DBA_HIST_SYSSTAT deltas divided by window duration. '
        || 'Per-transaction rates available in the scratch table AWR_TREND_LOAD_PROFILE.per_txn.</p>');

    -- Build header row.
    v_header := '<thead><tr><th>Metric</th><th>Trend</th><th class="num">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR m IN (
        -- One row per stat, with JSON-ish aggregation across week_offset values.
        SELECT stat_name,
               MAX(CASE WHEN week_offset = 0 THEN per_sec END) AS cur_ps,
               MAX(CASE WHEN week_offset = 0 THEN stat_value END) AS cur_val
        FROM   awr_trend_load_profile
        WHERE  run_id = ~run_id
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

        v_vals.DELETE;
        v_points := NULL;

        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(per_sec)
            INTO   v_vals(k)
            FROM   awr_trend_load_profile
            WHERE  run_id = ~run_id
            AND    stat_name = m.stat_name
            AND    week_offset = k;

            v_token := CASE
                WHEN v_vals(k) IS NULL THEN 'null'
                ELSE TO_CHAR(v_vals(k), 'FM99999999999999999990D999999',
                    'NLS_NUMERIC_CHARACTERS=''.,''')
            END;

            IF v_points IS NULL THEN
                v_points := v_token;
            ELSE
                v_points := v_token || '|' || v_points;
            END IF;
        END LOOP;

        v_token := CASE
            WHEN m.cur_ps IS NULL THEN 'null'
            ELSE TO_CHAR(m.cur_ps, 'FM99999999999999999990D999999',
                'NLS_NUMERIC_CHARACTERS=''.,''')
        END;
        IF v_points IS NULL THEN
            v_points := v_token;
        ELSE
            v_points := v_points || '|' || v_token;
        END IF;

        v_row := '<tr><td>' || DBMS_XMLGEN.CONVERT(v_label) || '</td>'
            || '<td class="trend-cell"><span class="sparkline" data-points="' || v_points || '"></span></td>';
        v_row := v_row || '<td class="num"><b>' ||
            TO_CHAR(NVL(m.cur_ps, 0), 'FM999G999G999G990D00') || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_per_sec := v_vals(k);

            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_per_sec IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_per_sec, 'FM999G999G999G990D00') END || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
