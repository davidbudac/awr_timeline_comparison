--
-- sql/fleet/02_ash.sql
-- Computes this database's full-report-span ASH buckets (from the start of
-- the earliest compared window through target_end) and emits them as TWO JS
-- payloads that share an identical shape:
--   * window.FLEET_ASH[<alias>]    -- stacked BY WAIT CLASS (ON-CPU -> 'CPU',
--                                     Idle excluded); drives the summary-row
--                                     ribbon and the first detail-row timeline.
--   * window.FLEET_ASH_EV[<alias>] -- stacked BY WAIT EVENT: the top 14 events
--                                     by total samples (CPU counts as a normal
--                                     series and almost always ranks top;
--                                     deterministic tie-break by name asc),
--                                     with every remaining event rolled into a
--                                     synthetic "Other events" series emitted
--                                     LAST.  Series are ordered biggest-total
--                                     first so the largest contributor stacks
--                                     at the bottom.  Drives the second detail-
--                                     row timeline (data-ash-src="ev").
-- The js_fleet_charts renderer (in the chrome) reads both payloads; the class
-- sums in FLEET_ASH are unchanged by the added per-event grouping (the event
-- rows re-aggregate to the same class totals).
--
-- Bucketing mirrors sql/09_ash_timeline.sql's math but with an ADAPTIVE grid
-- instead of a fixed 24 x 1h one: the span covers every compared window, i.e.
-- [target_end - (weeks_back * step_hours + win_hours) hours, target_end),
-- capped to at most 168 buckets with a 15-minute floor per bucket so a long
-- multi-week span still renders as a manageable number of points; bucket_key
-- = FLOOR((sample - span_start) in hours / bucket_hours); ON-CPU rows ->
-- 'CPU', Idle excluded; all instances (fleet pins inst_num=0 = aggregate).
-- ASH persists 1-in-10 ten-second samples, so a fully-busy session
-- contributes 360 rows/hour -> AAS = sample_count / (360 * bucket_hours).
--
-- The <script> blocks are emitted INSIDE the detail row (opened by
-- 01_row.sql, before the headline strip added by 03_headline.sql), which is
-- valid: a <script> is legal inside a <div> inside a <td>.  Render order does
-- not matter -- the renderer runs on DOMContentLoaded, after every payload
-- and every [data-ash-of] div has parsed.
--
-- Number formatting pins NLS_NUMERIC_CHARACTERS='.,' in TO_CHAR so the JSON
-- parses under any session locale; class/event names are escaped for the JS
-- string context (backslash + double-quote), NOT XML-converted (that would
-- turn '&' into '&amp;' and break the JS).
--
-- Read-only: pulls aggregated ASH into in-memory collections and renders.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 BEGIN -->'); END;
/

DECLARE
    v_range_start DATE;
    v_span_h      NUMBER;
    v_bh          NUMBER;
    v_nb          PLS_INTEGER;
    TYPE t_cell IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
    v_cells   t_cell;
    TYPE t_cls IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_cls     t_cls;
    v_ck      VARCHAR2(200);
    v_wc      VARCHAR2(64);
    v_classes VARCHAR2(4000) := '';
    v_vals    VARCHAR2(8000);
    v_first   BOOLEAN;
    v_n       NUMBER;
    -- event-level structures (second payload: top-14 events + rolled "Other")
    TYPE t_ecell IS TABLE OF NUMBER INDEX BY VARCHAR2(280);
    v_ecells  t_ecell;                     -- bucket|event -> sample count
    TYPE t_ev IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_ev      t_ev;                         -- event -> total samples
    TYPE t_seen IS TABLE OF BOOLEAN INDEX BY VARCHAR2(64);
    v_evseen  t_seen;                       -- events already picked into top-N
    TYPE t_names IS TABLE OF VARCHAR2(64);
    v_top     t_names := t_names();         -- picked events, biggest-total first
    TYPE t_ob IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_other   t_ob;                         -- bucket -> rolled "Other events" sum
    v_has_other BOOLEAN := FALSE;
    v_maxtop  PLS_INTEGER := 14;
    v_eck     VARCHAR2(280);
    v_ename   VARCHAR2(64);
    v_best    VARCHAR2(64);
    v_bestval NUMBER;
    v_evclasses VARCHAR2(4000) := '';
    v_evvals  VARCHAR2(8000);
BEGIN
    v_span_h := ~weeks_back * TO_NUMBER('~step_hours') + ~win_hours;
    v_bh     := GREATEST(v_span_h / 168, 0.25);
    v_nb     := CEIL(v_span_h / v_bh - 1e-9);

    SELECT CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - v_span_h / 24
    INTO   v_range_start
    FROM   dual;

    FOR r IN (
        SELECT FLOOR((CAST(ash.sample_time AS DATE) - v_range_start) * 24 / v_bh) AS bucket_key,
               CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                    ELSE NVL(ash.wait_class, 'Other') END AS wait_class,
               CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                    ELSE NVL(ash.event, 'Other') END AS event_bucket,
               COUNT(*) AS sample_count
        FROM   dba_hist_active_sess_history ash
        WHERE  ash.dbid IN (~dbid_list)
          AND  ash.sample_time >= CAST(v_range_start               AS TIMESTAMP)
          AND  ash.sample_time <  CAST(v_range_start + v_span_h / 24 AS TIMESTAMP)
          AND  (ash.session_state = 'ON CPU' OR NVL(ash.wait_class, 'x') <> 'Idle')
        GROUP BY FLOOR((CAST(ash.sample_time AS DATE) - v_range_start) * 24 / v_bh),
                 CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                      ELSE NVL(ash.wait_class, 'Other') END,
                 CASE WHEN ash.session_state = 'ON CPU' THEN 'CPU'
                      ELSE NVL(ash.event, 'Other') END
    ) LOOP
        IF r.bucket_key >= 0 AND r.bucket_key <= v_nb - 1 THEN
            -- class level: sum across events -> byte-identical class totals
            v_ck := TO_CHAR(r.bucket_key) || '|' || r.wait_class;
            IF v_cells.EXISTS(v_ck) THEN
                v_cells(v_ck) := v_cells(v_ck) + r.sample_count;
            ELSE
                v_cells(v_ck) := r.sample_count;
            END IF;
            IF v_cls.EXISTS(r.wait_class) THEN
                v_cls(r.wait_class) := v_cls(r.wait_class) + r.sample_count;
            ELSE
                v_cls(r.wait_class) := r.sample_count;
            END IF;
            -- event level
            v_eck := TO_CHAR(r.bucket_key) || '|' || r.event_bucket;
            IF v_ecells.EXISTS(v_eck) THEN
                v_ecells(v_eck) := v_ecells(v_eck) + r.sample_count;
            ELSE
                v_ecells(v_eck) := r.sample_count;
            END IF;
            IF v_ev.EXISTS(r.event_bucket) THEN
                v_ev(r.event_bucket) := v_ev(r.event_bucket) + r.sample_count;
            ELSE
                v_ev(r.event_bucket) := r.sample_count;
            END IF;
        END IF;
    END LOOP;

    -- ===== by-class payload (window.FLEET_ASH) -- unchanged output =====
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
        || TO_CHAR(v_range_start, 'YYYY-MM-DD HH24:MI') || '",bh:'
        || TO_CHAR(v_bh, 'FM99990D999999', 'NLS_NUMERIC_CHARACTERS=''.,''')
        || ',classes:[' || v_classes || '],vals:[');

    -- per-class v_nb-value AAS arrays, iterated in the SAME key order as
    -- classes so vals[k] lines up with classes[k]
    v_wc := v_cls.FIRST;
    v_first := TRUE;
    WHILE v_wc IS NOT NULL LOOP
        v_vals := '';
        FOR b IN 0 .. v_nb - 1 LOOP
            v_ck := TO_CHAR(b) || '|' || v_wc;
            IF v_cells.EXISTS(v_ck) THEN
                v_n := v_cells(v_ck);
            ELSE
                v_n := 0;
            END IF;
            v_vals := v_vals
                || CASE WHEN b = 0 THEN '' ELSE ',' END
                || TO_CHAR(v_n / (360 * v_bh), 'FM99999990D0000', 'NLS_NUMERIC_CHARACTERS=''.,''');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(CASE WHEN v_first THEN '' ELSE ',' END || '[' || v_vals || ']');
        v_first := FALSE;
        v_wc := v_cls.NEXT(v_wc);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(']};</script>');

    -- ===== by-event payload (window.FLEET_ASH_EV) =====
    -- pick the top v_maxtop events by total samples (tie-break: name asc), via
    -- repeated scan-for-max with a visited flag; v_top ends up biggest-first
    FOR p IN 1 .. v_maxtop LOOP
        v_best := NULL;
        v_bestval := NULL;
        v_ename := v_ev.FIRST;
        WHILE v_ename IS NOT NULL LOOP
            IF NOT v_evseen.EXISTS(v_ename) THEN
                IF v_bestval IS NULL
                   OR v_ev(v_ename) > v_bestval
                   OR (v_ev(v_ename) = v_bestval AND v_ename < v_best) THEN
                    v_bestval := v_ev(v_ename);
                    v_best    := v_ename;
                END IF;
            END IF;
            v_ename := v_ev.NEXT(v_ename);
        END LOOP;
        EXIT WHEN v_best IS NULL;
        v_evseen(v_best) := TRUE;
        v_top.EXTEND;
        v_top(v_top.COUNT) := v_best;
    END LOOP;

    -- roll every remaining (unpicked) event into per-bucket "Other events" sums
    v_ename := v_ev.FIRST;
    WHILE v_ename IS NOT NULL LOOP
        IF NOT v_evseen.EXISTS(v_ename) THEN
            v_has_other := TRUE;
            FOR b IN 0 .. v_nb - 1 LOOP
                v_eck := TO_CHAR(b) || '|' || v_ename;
                IF v_ecells.EXISTS(v_eck) THEN
                    IF v_other.EXISTS(b) THEN
                        v_other(b) := v_other(b) + v_ecells(v_eck);
                    ELSE
                        v_other(b) := v_ecells(v_eck);
                    END IF;
                END IF;
            END LOOP;
        END IF;
        v_ename := v_ev.NEXT(v_ename);
    END LOOP;

    -- event names list, biggest-total first, "Other events" appended last
    v_first := TRUE;
    FOR i IN 1 .. v_top.COUNT LOOP
        v_evclasses := v_evclasses
            || CASE WHEN v_first THEN '' ELSE ',' END
            || '"' || REPLACE(REPLACE(v_top(i), '\', '\\'), '"', '\"') || '"';
        v_first := FALSE;
    END LOOP;
    IF v_has_other THEN
        v_evclasses := v_evclasses
            || CASE WHEN v_first THEN '' ELSE ',' END
            || '"Other events"';
        v_first := FALSE;
    END IF;

    DBMS_OUTPUT.PUT_LINE('<script>window.FLEET_ASH_EV=window.FLEET_ASH_EV||{};');
    DBMS_OUTPUT.PUT_LINE('window.FLEET_ASH_EV["' || '~fleet_alias' || '"]={t0:"'
        || TO_CHAR(v_range_start, 'YYYY-MM-DD HH24:MI') || '",bh:'
        || TO_CHAR(v_bh, 'FM99990D999999', 'NLS_NUMERIC_CHARACTERS=''.,''')
        || ',classes:[' || v_evclasses || '],vals:[');

    -- per-event AAS arrays in the SAME order as the event names (top first),
    -- then the rolled "Other events" row last
    v_first := TRUE;
    FOR i IN 1 .. v_top.COUNT LOOP
        v_evvals := '';
        FOR b IN 0 .. v_nb - 1 LOOP
            v_eck := TO_CHAR(b) || '|' || v_top(i);
            IF v_ecells.EXISTS(v_eck) THEN
                v_n := v_ecells(v_eck);
            ELSE
                v_n := 0;
            END IF;
            v_evvals := v_evvals
                || CASE WHEN b = 0 THEN '' ELSE ',' END
                || TO_CHAR(v_n / (360 * v_bh), 'FM99999990D0000', 'NLS_NUMERIC_CHARACTERS=''.,''');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(CASE WHEN v_first THEN '' ELSE ',' END || '[' || v_evvals || ']');
        v_first := FALSE;
    END LOOP;
    IF v_has_other THEN
        v_evvals := '';
        FOR b IN 0 .. v_nb - 1 LOOP
            IF v_other.EXISTS(b) THEN
                v_n := v_other(b);
            ELSE
                v_n := 0;
            END IF;
            v_evvals := v_evvals
                || CASE WHEN b = 0 THEN '' ELSE ',' END
                || TO_CHAR(v_n / (360 * v_bh), 'FM99999990D0000', 'NLS_NUMERIC_CHARACTERS=''.,''');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(CASE WHEN v_first THEN '' ELSE ',' END || '[' || v_evvals || ']');
        v_first := FALSE;
    END IF;

    DBMS_OUTPUT.PUT_LINE(']};</script>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_02 END -->'); END;
/
