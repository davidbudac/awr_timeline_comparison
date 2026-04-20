--
-- 01_windows.sql
-- Resolve the current window and ~weeks_back prior aligned windows (same
-- day-of-week, same hour-of-day) into awr_trend_windows rows, then render
-- them as an HTML table so the reader can see which snapshots were used.
--
-- Algorithm per window k = 0..~weeks_back:
--   win_end   := target_end - 7*k (days)
--   win_start := win_end - ~win_hours/24
--   begin_snap_id := MAX(snap_id) WHERE end_interval_time <= win_start + 5min
--   end_snap_id   := MIN(snap_id) WHERE end_interval_time >= win_end   - 5min
-- A window is invalid if either snap cannot be found, or the startup_time of
-- the two snapshots differs (instance restart happened inside the window).
--

SET DEFINE '~'

INSERT INTO awr_trend_windows (
    run_id, week_offset, win_start_ts, win_end_ts,
    begin_snap_id, end_snap_id, valid_flag, skip_reason
)
WITH run AS (
    SELECT run_id, dbid, instance_number, target_end_ts, win_hours, weeks_back
    FROM   awr_trend_runs
    WHERE  run_id = ~run_id
),
offsets AS (
    SELECT LEVEL - 1 AS week_offset
    FROM   dual
    CONNECT BY LEVEL <= (SELECT weeks_back + 1 FROM run)
),
windows AS (
    SELECT
        r.run_id,
        o.week_offset,
        CAST(r.target_end_ts AS DATE) - 7 * o.week_offset - r.win_hours/24 AS win_start_dt,
        CAST(r.target_end_ts AS DATE) - 7 * o.week_offset                   AS win_end_dt,
        r.dbid,
        r.instance_number
    FROM   run r CROSS JOIN offsets o
),
snaps AS (
    -- Pre-filter snapshots once; pick per-window begin/end with analytics.
    SELECT w.run_id, w.week_offset, w.win_start_dt, w.win_end_dt,
           s.snap_id, s.begin_interval_time, s.end_interval_time,
           s.startup_time, s.instance_number
    FROM   windows w
    JOIN   dba_hist_snapshot s
      ON   s.dbid = w.dbid
     AND   (w.instance_number IS NULL OR s.instance_number = w.instance_number)
     AND   s.end_interval_time BETWEEN
                CAST(w.win_start_dt - 1 AS TIMESTAMP)
            AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
),
begin_snap AS (
    SELECT run_id, week_offset,
           MAX(snap_id) KEEP (DENSE_RANK LAST ORDER BY end_interval_time)  AS snap_id,
           MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
    FROM   snaps
    WHERE  end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
    GROUP BY run_id, week_offset
),
end_snap AS (
    SELECT run_id, week_offset,
           MIN(snap_id) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
           MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
    FROM   snaps
    WHERE  end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
    GROUP BY run_id, week_offset
)
SELECT
    w.run_id,
    w.week_offset,
    CAST(w.win_start_dt AS TIMESTAMP) AS win_start_ts,
    CAST(w.win_end_dt   AS TIMESTAMP) AS win_end_ts,
    bs.snap_id AS begin_snap_id,
    es.snap_id AS end_snap_id,
    CASE
        WHEN bs.snap_id IS NULL OR es.snap_id IS NULL THEN 'N'
        WHEN bs.snap_id = es.snap_id                  THEN 'N'
        WHEN bs.startup_time <> es.startup_time       THEN 'N'
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
LEFT JOIN begin_snap bs ON bs.run_id = w.run_id AND bs.week_offset = w.week_offset
LEFT JOIN end_snap   es ON es.run_id = w.run_id AND es.week_offset = w.week_offset;

COMMIT;

--
-- Render the windows table.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="windows"><h2>Aligned windows</h2>');
    DBMS_OUTPUT.PUT_LINE('<table>');
    DBMS_OUTPUT.PUT_LINE('<thead><tr>'
        || '<th>Week</th>'
        || '<th>Window start</th>'
        || '<th>Window end</th>'
        || '<th class="num">Begin snap</th>'
        || '<th class="num">End snap</th>'
        || '<th>Status</th>'
        || '<th>Detail</th>'
        || '</tr></thead><tbody>');

    FOR w IN (
        SELECT week_offset, win_start_ts, win_end_ts,
               begin_snap_id, end_snap_id, valid_flag, skip_reason
        FROM   awr_trend_windows
        WHERE  run_id = ~run_id
        ORDER BY week_offset
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(
            '<tr class="' || CASE WHEN w.valid_flag = 'N' THEN 'skip' ELSE 'ok' END || '">'
            || '<td>' || CASE WHEN w.week_offset = 0 THEN '<b>Current</b>'
                              ELSE '&minus;' || w.week_offset || 'w' END || '</td>'
            || '<td>' || TO_CHAR(w.win_start_ts, 'YYYY-MM-DD Dy HH24:MI') || '</td>'
            || '<td>' || TO_CHAR(w.win_end_ts,   'YYYY-MM-DD Dy HH24:MI') || '</td>'
            || '<td class="num">' || NVL(TO_CHAR(w.begin_snap_id), '&mdash;') || '</td>'
            || '<td class="num">' || NVL(TO_CHAR(w.end_snap_id),   '&mdash;') || '</td>'
            || '<td>' || CASE WHEN w.valid_flag = 'Y'
                              THEN '<span class="badge ok">valid</span>'
                              ELSE '<span class="badge skip">skipped</span>' END || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(w.skip_reason, '')) || '</td>'
            || '</tr>');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">Skipped windows are excluded from the baseline used to compute z-scores.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
