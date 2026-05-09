--
-- 01_windows.sql
-- Resolve the current window and ~weeks_back prior windows (each one is
-- step*step_unit earlier than the next; defaults to one week earlier)
-- from dba_hist_snapshot and render them as a timeline ribbon + detail
-- table.  Read-only: no scratch table.
--
-- The windows CTE used here is also duplicated by every downstream
-- numbered section that needs per-window snap_id pairs.  Section-local
-- duplication is the least-bad way to share that CTE across SQL*Plus
-- files without creating a helper object.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_slots      NUMBER;
    v_margin     NUMBER := 20;
    v_gap        NUMBER := 10;
    v_slot_w     NUMBER;
    v_box_w      NUMBER;
    v_slot_idx   NUMBER;
    v_x          NUMBER;
    v_is_current BOOLEAN;
    v_box_y      NUMBER;
    v_box_h      NUMBER;
    v_status     VARCHAR2(120);
BEGIN
    v_slots  := v_weeks_back + 1;
    v_slot_w := (1000 - 2 * v_margin) / v_slots;
    v_box_w  := v_slot_w - v_gap;

    DBMS_OUTPUT.PUT_LINE('<section id="windows"><h2>Aligned windows</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Ribbon shows valid vs skipped baseline windows at a glance. '
        || 'Skipped windows are excluded from the z-score baseline.</p>');

    DBMS_OUTPUT.PUT_LINE('<div class="ribbon">'
        || '<svg viewBox="0 0 1000 72" preserveAspectRatio="none" role="img" aria-label="Baseline windows timeline">');
    DBMS_OUTPUT.PUT_LINE('<line x1="0" y1="56" x2="1000" y2="56" stroke="#c8d0dc" stroke-width="1"/>');

    -- Emit one <g> per window, oldest on the left.
    FOR w IN (
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
            FROM   raw_windows w
            LEFT JOIN begin_snap bs ON bs.week_offset = w.week_offset
            LEFT JOIN end_snap   es ON es.week_offset = w.week_offset
        )
        SELECT week_offset, win_end_ts, begin_snap_id, end_snap_id,
               valid_flag, skip_reason
        FROM   windows
        ORDER BY week_offset DESC
    ) LOOP
        v_slot_idx   := v_weeks_back - w.week_offset;       -- 0 = leftmost (oldest)
        v_x          := v_margin + v_slot_idx * v_slot_w + v_gap/2;
        v_is_current := (w.week_offset = 0);
        v_box_y      := CASE WHEN v_is_current THEN 14 ELSE 20 END;
        v_box_h      := CASE WHEN v_is_current THEN 34  ELSE 26 END;

        IF w.valid_flag = 'Y' THEN
            v_status := 'valid &middot; snaps '
                     || w.begin_snap_id || '&rarr;' || w.end_snap_id;
        ELSE
            v_status := 'skipped';
            IF w.skip_reason IS NOT NULL THEN
                v_status := v_status || ' &middot; ' ||
                    DBMS_XMLGEN.CONVERT(SUBSTR(w.skip_reason, 1, 40));
            END IF;
        END IF;

        DBMS_OUTPUT.PUT_LINE('<g>');
        IF w.valid_flag = 'Y' THEN
            DBMS_OUTPUT.PUT_LINE('<rect x="' || TO_CHAR(v_x, 'FM999990D0')
                || '" y="' || v_box_y || '" width="' || TO_CHAR(v_box_w, 'FM999990D0')
                || '" height="' || v_box_h || '" rx="4" fill="#2563eb" opacity="'
                || CASE WHEN v_is_current THEN '1.0' ELSE '0.55' END || '"/>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<rect x="' || TO_CHAR(v_x, 'FM999990D0')
                || '" y="' || v_box_y || '" width="' || TO_CHAR(v_box_w, 'FM999990D0')
                || '" height="' || v_box_h || '" rx="4" fill="#9aa3af"'
                || ' fill-opacity="0.18" stroke="#9aa3af"'
                || ' stroke-dasharray="4,3"/>');
        END IF;

        DBMS_OUTPUT.PUT_LINE('<text x="' || TO_CHAR(v_x + v_box_w/2, 'FM999990D0')
            || '" y="10" text-anchor="middle" font-size="10" fill="#666">'
            || TO_CHAR(w.win_end_ts, '~period_axis_fmt') || '</text>');

        IF v_is_current THEN
            DBMS_OUTPUT.PUT_LINE('<text x="' || TO_CHAR(v_x + v_box_w/2, 'FM999990D0')
                || '" y="35" text-anchor="middle" font-size="11" font-weight="600" fill="#ffffff">current</text>');
        END IF;

        DBMS_OUTPUT.PUT_LINE('<text x="' || TO_CHAR(v_x + v_box_w/2, 'FM999990D0')
            || '" y="68" text-anchor="middle" font-size="10" fill="#666">'
            || v_status || '</text>');
        DBMS_OUTPUT.PUT_LINE('</g>');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</svg></div>');

    DBMS_OUTPUT.PUT_LINE('<table>');
    DBMS_OUTPUT.PUT_LINE('<thead><tr>'
        || '<th>~period_unit_title</th>'
        || '<th>Window start</th>'
        || '<th>Window end</th>'
        || '<th class="num">Begin snap</th>'
        || '<th class="num">End snap</th>'
        || '<th>Status</th>'
        || '<th>Detail</th>'
        || '</tr></thead><tbody>');

    FOR w IN (
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
            FROM   raw_windows w
            LEFT JOIN begin_snap bs ON bs.week_offset = w.week_offset
            LEFT JOIN end_snap   es ON es.week_offset = w.week_offset
        )
        SELECT week_offset, win_start_ts, win_end_ts,
               begin_snap_id, end_snap_id, valid_flag, skip_reason
        FROM   windows
        ORDER BY week_offset
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(
            '<tr class="' || CASE WHEN w.valid_flag = 'N' THEN 'skip' ELSE 'ok' END || '">'
            || '<td>' || CASE WHEN w.week_offset = 0 THEN '<b>Current</b>'
                              ELSE '&minus;'
                                   || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, w.week_offset)
                              END || '</td>'
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
