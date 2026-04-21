--
-- 05_waits_bg.sql
-- Background wait-event deltas from DBA_HIST_BG_EVENT_SUMMARY.
-- This view exposes per-snapshot cumulative wait counters for background
-- processes (DBWR, LGWR, ARCn, etc.) in 19c.  We compute end - begin, keep
-- the top-N per window, and render them as a pivot table.
--

SET DEFINE '~'

INSERT INTO awr_trend_waits (run_id, week_offset, scope, event_name, wait_class,
                             total_waits, time_waited_us, avg_wait_ms, rank_in_window)
WITH run AS (
    SELECT run_id, dbid, instance_number, top_n
    FROM   awr_trend_runs WHERE run_id = ~run_id
),
wins AS (
    SELECT run_id, week_offset, begin_snap_id, end_snap_id
    FROM   awr_trend_windows
    WHERE  run_id = ~run_id AND valid_flag = 'Y'
),
pairs AS (
    SELECT
        w.run_id, w.week_offset,
        bg.event_name,
        bg.wait_class,
        bg.snap_id,
        bg.total_waits,
        bg.time_waited_micro,
        w.begin_snap_id, w.end_snap_id
    FROM   wins w
    JOIN   run  r ON 1=1
    JOIN   dba_hist_bg_event_summary bg
        ON bg.dbid = r.dbid
       AND bg.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND (r.instance_number IS NULL OR bg.instance_number = r.instance_number)
       AND NVL(bg.wait_class, 'Other') <> 'Idle'
),
bounds AS (
    SELECT run_id, week_offset, event_name, wait_class,
           SUM(CASE WHEN snap_id = begin_snap_id THEN total_waits END) AS beg_waits,
           SUM(CASE WHEN snap_id = end_snap_id   THEN total_waits END) AS end_waits,
           SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
           SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
    FROM   pairs
    GROUP BY run_id, week_offset, event_name, wait_class
),
deltas AS (
    SELECT run_id, week_offset, event_name, wait_class,
           NVL(end_waits, 0) - NVL(beg_waits, 0) AS total_waits,
           NVL(end_us,    0) - NVL(beg_us,    0) AS time_waited_us
    FROM   bounds
),
ranked AS (
    SELECT d.*,
           RANK() OVER (PARTITION BY run_id, week_offset ORDER BY time_waited_us DESC) AS rnk
    FROM   deltas d
    WHERE  time_waited_us > 0
)
SELECT run_id, week_offset, 'BG', event_name, wait_class,
       total_waits, time_waited_us,
       CASE WHEN total_waits > 0 THEN time_waited_us / total_waits / 1000 END AS avg_wait_ms,
       rnk
FROM   ranked
WHERE  rnk <= (SELECT top_n FROM run);

COMMIT;

--
-- Render.
--
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_cnt        NUMBER;
    v_us         NUMBER;
    v_rank       NUMBER;
    v_points     VARCHAR2(4000);
    v_token      VARCHAR2(80);
    TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_vals       t_num_tab;
BEGIN
    SELECT weeks_back INTO v_weeks_back FROM awr_trend_runs WHERE run_id = ~run_id;
    SELECT COUNT(*) INTO v_cnt FROM awr_trend_waits WHERE run_id = ~run_id AND scope = 'BG';

    DBMS_OUTPUT.PUT_LINE('<section id="waits-bg"><h2>Background wait events</h2>');

    IF v_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No background wait activity captured in DBA_HIST_BG_EVENT_SUMMARY for any valid window.</p>');
        DBMS_OUTPUT.PUT_LINE('</section>');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">From DBA_HIST_BG_EVENT_SUMMARY. Idle waits filtered out. Time in seconds.</p>');

    v_header := '<thead><tr><th>Event</th><th>Class</th><th>Trend</th><th class="num">Current (s)</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num">&minus;' || k || 'w (s)</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR e IN (
        SELECT event_name, MAX(wait_class) AS wait_class,
               MAX(CASE WHEN week_offset = 0 THEN time_waited_us END)   AS cur_us,
               MAX(CASE WHEN week_offset = 0 THEN rank_in_window END)   AS cur_rnk
        FROM   awr_trend_waits
        WHERE  run_id = ~run_id AND scope = 'BG'
        GROUP BY event_name
        ORDER BY
            CASE WHEN MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) IS NULL THEN 1 ELSE 0 END,
            MAX(CASE WHEN week_offset = 0 THEN rank_in_window END) NULLS LAST,
            MAX(time_waited_us) DESC
    ) LOOP
        v_vals.DELETE;
        v_points := NULL;

        FOR k IN 1 .. v_weeks_back LOOP
            SELECT MAX(time_waited_us)
            INTO   v_us
            FROM   awr_trend_waits
            WHERE  run_id = ~run_id AND scope = 'BG'
            AND    event_name = e.event_name AND week_offset = k;

            v_vals(k) := CASE WHEN v_us IS NULL THEN NULL ELSE v_us / 1e6 END;
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
            WHEN e.cur_us IS NULL THEN 'null'
            ELSE TO_CHAR(e.cur_us / 1e6, 'FM99999999999999999990D999999',
                'NLS_NUMERIC_CHARACTERS=''.,''')
        END;
        IF v_points IS NULL THEN
            v_points := v_token;
        ELSE
            v_points := v_points || '|' || v_token;
        END IF;

        v_row := '<tr>'
            || '<td>' || DBMS_XMLGEN.CONVERT(e.event_name) || '</td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(e.wait_class, '')) || '</td>'
            || '<td class="trend-cell"><span class="sparkline" data-points="' || v_points || '"></span></td>'
            || '<td class="num"><b>' ||
                CASE WHEN e.cur_us IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(e.cur_us/1e6, 'FM999G999G990D00') END
            || CASE WHEN e.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || e.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_us := CASE WHEN v_vals(k) IS NULL THEN NULL ELSE v_vals(k) * 1e6 END;
            SELECT MAX(rank_in_window)
            INTO   v_rank
            FROM   awr_trend_waits
            WHERE  run_id = ~run_id AND scope = 'BG'
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

    DBMS_OUTPUT.PUT_LINE('</tbody></table></section>');
END;
/
