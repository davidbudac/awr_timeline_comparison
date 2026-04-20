--
-- 04_waits_fg.sql
-- Foreground wait-event deltas from DBA_HIST_SYSTEM_EVENT.
-- The view stores CUMULATIVE counters per snapshot, so delta per window =
-- value_at_end_snap - value_at_begin_snap.  We filter out 'Idle' waits and
-- keep the top-N per window, plus one row per wait_class for the rollup.
--

SET DEFINE ON

--
-- Per-event FG deltas (TOP-N per window).
--
INSERT INTO awr_trend_waits (run_id, week_offset, scope, event_name, wait_class,
                             total_waits, time_waited_us, avg_wait_ms, rank_in_window)
WITH run AS (
    SELECT run_id, dbid, instance_number, top_n
    FROM   awr_trend_runs WHERE run_id = &run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows
    WHERE  run_id = &run_id AND valid_flag = 'Y'
),
pairs AS (
    SELECT
        w.run_id, w.week_offset,
        se.event_name, se.wait_class,
        se.snap_id, se.instance_number,
        se.total_waits,
        se.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_system_event se
        ON se.dbid = r.dbid
       AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
       AND se.wait_class <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, instance_number, event_name, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, instance_number, event_name, wait_class
),
deltas AS (
    -- Aggregate across instances for scope=ALL, or flat-through for scope=INSTANCE.
    SELECT run_id, week_offset, event_name, wait_class,
           SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
           SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
    FROM   bounds
    GROUP BY run_id, week_offset, event_name, wait_class
),
ranked AS (
    SELECT d.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   deltas d
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'FG', event_name, wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
       rnk
FROM   ranked
WHERE  rnk <= (SELECT top_n FROM run);

--
-- Wait-class rollup (scope='CLASS'), ALL non-Idle classes.
--
INSERT INTO awr_trend_waits (run_id, week_offset, scope, event_name, wait_class,
                             total_waits, time_waited_us, avg_wait_ms, rank_in_window)
WITH run AS (
    SELECT run_id, dbid, instance_number FROM awr_trend_runs WHERE run_id = &run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows WHERE run_id = &run_id AND valid_flag = 'Y'
),
pairs AS (
    SELECT
        w.run_id, w.week_offset,
        se.wait_class, se.snap_id, se.instance_number,
        se.total_waits, se.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_system_event se
        ON se.dbid = r.dbid
       AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR se.instance_number = r.instance_number)
       AND se.wait_class <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, instance_number, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END)       AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END)       AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, instance_number, wait_class
),
class_deltas AS (
    SELECT run_id, week_offset, wait_class,
           SUM(NVL(end_waits, 0) - NVL(beg_waits, 0)) AS total_waits,
           SUM(NVL(end_us,    0) - NVL(beg_us,    0)) AS time_waited_us
    FROM   bounds
    GROUP BY run_id, week_offset, wait_class
),
ranked AS (
    SELECT c.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   class_deltas c
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'CLASS',
       wait_class AS event_name,
       wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END,
       rnk
FROM   ranked;

COMMIT;

--
-- Render the FG waits table: columns = current + each prior week.  Rows =
-- distinct event names that appeared in at least one window's top-N.
-- Additionally a wait-class rollup table below.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_us         NUMBER;
    v_rank       NUMBER;
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = &run_id;

    DBMS_OUTPUT.PUT_LINE('<section id="waits-fg"><h2>Foreground wait events (top '
        || (SELECT top_n FROM awr_trend_runs WHERE run_id = &run_id) || ' by time waited)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">Time waited shown in seconds. Rank in each window shown as a badge.</p>');

    -- Per-event pivot table ------------------------------------------------
    v_header := '<thead><tr><th>Event</th><th>Class</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR e IN (
        SELECT event_name, MAX(wait_class) AS wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us,
               MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) AS cur_rnk
        FROM   awr_trend_waits
        WHERE  run_id = &run_id AND scope = 'FG'
        GROUP BY event_name
        ORDER BY
            CASE WHEN MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) IS NULL THEN 1 ELSE 0 END,
            MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) NULLS LAST,
            MAX(time_waited_us) DESC
    ) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(e.event_name) || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(e.wait_class, '')) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN e.cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(e.cur_us/1e6, 'FM999G999G990D00') END
            || CASE WHEN e.cur_rnk IS NOT NULL
                THEN ' <span class="badge info">#' || e.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(time_waited_us), MAX(rank_in_window)
            INTO   v_us, v_rank
            FROM   awr_trend_waits
            WHERE  run_id = &run_id AND scope = 'FG'
            AND    event_name = e.event_name AND week_offset = k;

            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_us/1e6, 'FM999G999G990D00') END
                || CASE WHEN v_rank IS NOT NULL
                    THEN ' <span class="badge skip">#' || v_rank || '</span>' ELSE '' END
                || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');

    -- Wait-class rollup ----------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('<h3>Wait-class rollup</h3>');
    v_header := '<thead><tr><th>Wait class</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR c IN (
        SELECT wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) AS cur_us
        FROM   awr_trend_waits
        WHERE  run_id = &run_id AND scope = 'CLASS'
        GROUP BY wait_class
        ORDER BY MAX(CASE WHEN week_offset = 0 THEN time_waited_us END) DESC NULLS LAST
    ) LOOP
        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(c.wait_class) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN c.cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(c.cur_us/1e6, 'FM999G999G990D00') END
            || '</b></td>';
        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(time_waited_us)
            INTO   v_us
            FROM   awr_trend_waits
            WHERE  run_id = &run_id AND scope = 'CLASS'
            AND    wait_class = c.wait_class AND week_offset = k;
            v_row := v_row || '<td class="num">' ||
                CASE WHEN v_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(v_us/1e6, 'FM999G999G990D00') END || '</td>';
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
