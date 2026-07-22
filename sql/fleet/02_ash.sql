--
-- sql/fleet/02_ash.sql
-- Computes this database's 24 hourly ASH buckets (ending at the resolved
-- target_end) and emits them as a window.FLEET_ASH[<alias>] JS payload.  The
-- js_fleet_charts renderer (in the chrome) reads that payload to draw both
-- the summary-row ribbon (data-ash-mode="ribbon") and the detail-row timeline
-- (data-ash-mode="timeline") for this alias.
--
-- Bucketing mirrors sql/09_ash_timeline.sql's math but pinned to a fixed 24 x
-- 1h grid (no ECharts, no dataZoom, no window bands): span =
-- [target_end - 24h, target_end); bucket_key = FLOOR((sample - span_start) in
-- hours); ON-CPU rows -> 'CPU', Idle excluded; all instances (fleet pins
-- inst_num=0 = aggregate).  ASH persists 1-in-10 ten-second samples, so a
-- fully-busy session contributes 360 rows/hour -> AAS = sample_count / 360.
--
-- The <script> is emitted INSIDE the detail row's left column (opened by
-- 01_row.sql, before the headline strip added by 03_headline.sql), which is
-- valid: a <script> is legal inside a <div> inside a <td>.  Render order does
-- not matter -- the renderer runs on DOMContentLoaded, after every payload
-- and every [data-ash-of] div has parsed.
--
-- Number formatting pins NLS_NUMERIC_CHARACTERS='.,' in TO_CHAR so the JSON
-- parses under any session locale; class names are Oracle-fixed but escaped
-- for the JS string context anyway (backslash + double-quote), NOT
-- XML-converted (that would turn '&' into '&amp;' and break the JS).
--
-- Read-only: pulls aggregated ASH into an in-memory collection and renders.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 BEGIN -->'); END;
/

DECLARE
    v_range_start DATE;
    TYPE t_cell IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    v_cells   t_cell;
    TYPE t_cls IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_cls     t_cls;
    v_ck      VARCHAR2(200);
    v_wc      VARCHAR2(64);
    v_classes VARCHAR2(4000) := '';
    v_vals    VARCHAR2(4000);
    v_first   BOOLEAN;
    v_n       NUMBER;
BEGIN
    SELECT CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE) - 1
    INTO   v_range_start
    FROM   dual;

    FOR r IN (
        SELECT FLOOR((CAST(ash.sample_time AS DATE) - v_range_start) * 24) AS bucket_key,
               CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                    ELSE NVL(ash.wait_class, 'Other') END AS wait_class,
               COUNT(*) AS sample_count
        FROM   dba_hist_active_sess_history ash
        WHERE  ash.dbid IN (~dbid_list)
          AND  ash.sample_time >= CAST(v_range_start     AS TIMESTAMP)
          AND  ash.sample_time <  CAST(v_range_start + 1 AS TIMESTAMP)
          AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
        GROUP BY FLOOR((CAST(ash.sample_time AS DATE) - v_range_start) * 24),
                 CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                      ELSE NVL(ash.wait_class, 'Other') END
    ) LOOP
        IF r.bucket_key >= 0 AND r.bucket_key <= 23 THEN
            v_ck := TO_CHAR(r.bucket_key) || '|' || r.wait_class;
            v_cells(v_ck) := r.sample_count;
            IF v_cls.EXISTS(r.wait_class) THEN
                v_cls(r.wait_class) := v_cls(r.wait_class) + r.sample_count;
            ELSE
                v_cls(r.wait_class) := r.sample_count;
            END IF;
        END IF;
    END LOOP;

    -- classes list (JS string array body), iterated in stable key order
    v_wc := v_cls.FIRST;
    v_first := TRUE;
    WHILE v_wc IS NOT NULL LOOP
        v_classes := v_classes
            || CASE WHEN v_first THEN '' ELSE ',' END
            || '"' || REPLACE(REPLACE(v_wc, '\', '\\'), '"', '\"') || '"';
        v_first := FALSE;
        v_wc := v_cls.NEXT(v_wc);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('<script>window.FLEET_ASH=window.FLEET_ASH||{};');
    DBMS_OUTPUT.PUT_LINE('window.FLEET_ASH["' || '~fleet_alias' || '"]={t0:"'
        || TO_CHAR(v_range_start, 'YYYY-MM-DD HH24:MI') || '",bh:1,classes:['
        || v_classes || '],vals:[');

    -- per-class 24-value AAS arrays, iterated in the SAME key order as classes
    -- so vals[k] lines up with classes[k]
    v_wc := v_cls.FIRST;
    v_first := TRUE;
    WHILE v_wc IS NOT NULL LOOP
        v_vals := '';
        FOR b IN 0 .. 23 LOOP
            v_ck := TO_CHAR(b) || '|' || v_wc;
            IF v_cells.EXISTS(v_ck) THEN
                v_n := v_cells(v_ck);
            ELSE
                v_n := 0;
            END IF;
            v_vals := v_vals
                || CASE WHEN b = 0 THEN '' ELSE ',' END
                || TO_CHAR(v_n / 360, 'FM99999990D0000', 'NLS_NUMERIC_CHARACTERS=''.,''');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(CASE WHEN v_first THEN '' ELSE ',' END || '[' || v_vals || ']');
        v_first := FALSE;
        v_wc := v_cls.NEXT(v_wc);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(']};</script>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 END -->'); END;
/
