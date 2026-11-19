--
-- 28_release_delta.sql
-- Before and after a release (v1.7.0 visualization 9).
--
-- The question of the application team and the release manager: "we
-- shipped Release 4.2 on Tuesday -- WHAT MOVED across it, and is each move
-- bigger than this metric's usual wobble?"  The rest of the report
-- compares Current with ALL prior windows, so a release in the middle of
-- the span mixes windows before and after it into one baseline; this view
-- splits the compared windows at one instant instead:
--   before     valid windows that END at or before the split instant
--   after      valid windows that START at or after it (Current included)
--   straddles  a window containing the instant (neither side)
-- and draws, per metric, the change of the AFTER mean relative to the
-- BEFORE mean (a lollipop) against the before windows' own variation
-- (mean +- 2 sd, sd floored at 2% of the mean, as a percent of the mean).
--
-- The split instants come from the release markers, which exist only on
-- the client (window.AWR_MARKERS, sql/lib/js_markers.plsql), or from a
-- window boundary the reader picks; so this block emits the per-window
-- VALUES of every canonical LOAD / METRIC row of the run's template plus
-- the wait-class rollups (07's recompute: sql/lib/load_pairs_cte.sql, the
-- SYSMETRIC additive rule, the per-class SYSTEM_EVENT deltas) and the
-- script (sql/lib/js_reldelta.plsql, source sql/lib/src/js_reldelta.js)
-- computes the split statistics, the chart, the split table, the "Reads
-- as" sentence and the upgraded evidence-library row text.
--
-- Payload: window.AWR_DATA.reldelta = {m:[{d, n, l, u, s, dir, mp, ma,
-- id, v:{"<week_offset>":value, ...}}, ...]} -- d = domain letter (L / M /
-- W), n = the AWR name, l = metric_label, u = metric_unit, s =
-- metric_scale (display = value x s), dir / mp / ma = metric_policy's
-- direction / min_pct / min_abs (WAIT: min share), id = the 07 detail
-- row (finding_anchor), v = the stored value per VALID window that has
-- one.  Built in a PL/SQL loop, flushed in lines under 30000 bytes (any
-- window count).
--
-- This is an explanation aid, not a second verdict: nothing here is
-- called a finding and the large / moderate words are not used.  JS off:
-- a note and a compact table (Current vs mean / sd of ALL prior windows).
-- Read-only: one bounded SELECT over the compared windows' snapshots.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 28_release_delta BEGIN -->'); END;
/

DECLARE
    TYPE val_rec IS RECORD (
        dom   VARCHAR2(16),
        nm    VARCHAR2(120),
        wo    NUMBER,
        val   NUMBER
    );
    TYPE val_t  IS TABLE OF val_rec INDEX BY PLS_INTEGER;
    TYPE line_t IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;

    v_rows     val_t;
    v_tbl      line_t;
    v_buf      VARCHAR2(32767);
    v_vals     VARCHAR2(32767);
    v_nvalid   PLS_INTEGER := 0;
    v_nprior   PLS_INTEGER := 0;
    v_nmet     PLS_INTEGER := 0;
    v_first    BOOLEAN := TRUE;
    v_vfirst   BOOLEAN;
    v_canon    VARCHAR2(1);
    v_dir      VARCHAR2(4);
    v_mp       NUMBER;
    v_ma       NUMBER;
    v_cur      NUMBER;
    v_sum      NUMBER;
    v_sq       NUMBER;
    v_n        PLS_INTEGER;
    v_mu       NUMBER;
    v_sd       NUMBER;
    v_s        NUMBER;
    v_u        VARCHAR2(20);
    i          PLS_INTEGER;
    j          PLS_INTEGER;

    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/json_escape.plsql

    -- append to the payload line; flush past 30000 bytes (tokens never split)
    PROCEDURE put(p_s VARCHAR2) IS
    BEGIN
        IF LENGTHB(v_buf) + LENGTHB(p_s) > 30000 THEN
            DBMS_OUTPUT.PUT_LINE(v_buf);
            v_buf := NULL;
        END IF;
        v_buf := v_buf || p_s;
    END put;

    -- a raw value as an NLS-safe JSON number (7 significant digits)
    FUNCTION jnum(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        IF p = 0 THEN RETURN '0'; END IF;
        RETURN TO_CHAR(ROUND(p, 6 - FLOOR(LOG(10, ABS(p)))), 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END jnum;
BEGIN
    SELECT COUNT(CASE WHEN valid_flag = 'Y' THEN 1 END),
           COUNT(CASE WHEN valid_flag = 'Y' AND week_offset > 0 THEN 1 END)
    INTO   v_nvalid, v_nprior
    FROM (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag FROM windows_rollup
    );

    -- 07's unified recompute, one row per (metric, valid window); same
    -- CTE shapes (pairs -> bounds -> deltas, additive SYSMETRIC rule).
    WITH
    @@sql/lib/windows_cte.sql
    ,
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    @@sql/lib/load_pairs_cte.sql
    ,
    load_bounds AS (
        SELECT week_offset, dur_sec, stat_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   load_pairs
        GROUP BY week_offset, dur_sec, stat_name, instance_number
    ),
    load_rows AS (
        SELECT 'LOAD' AS metric_domain, stat_name AS metric_name, week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, stat_name
    ),
    metric_targets AS (
        @@~template_dir/sysmetric_targets.sql
    ),
    metric_per_snap AS (
        SELECT w.week_offset, t.metric_name, sm.snap_id,
               CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                             ELSE AVG(sm.average) END AS snap_value
        FROM   valid_windows w
        JOIN   metric_targets t ON 1 = 1
        JOIN   dba_hist_sysmetric_summary sm
            ON sm.dbid = w.dbid
           AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
           AND sm.instance_number = w.instance_number
           AND sm.metric_name = t.metric_name
        GROUP BY w.week_offset, t.metric_name, t.is_additive, sm.snap_id
    ),
    metric_rows AS (
        SELECT 'METRIC' AS metric_domain, metric_name, week_offset,
               AVG(snap_value) AS metric_value
        FROM   metric_per_snap
        GROUP BY week_offset, metric_name
    ),
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec, se.wait_class, se.event_name,
               se.snap_id, se.time_waited_micro, se.instance_number,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
           AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                 OR se.event_name IN (SELECT event_name FROM wait_targets) )
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, event_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
    ),
    wait_rows AS (
        SELECT 'WAIT' AS metric_domain, 'Wait class: ' || wait_class AS metric_name, week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    )
    SELECT metric_domain, metric_name, week_offset, metric_value
    BULK COLLECT INTO v_rows
    FROM   unified
    ORDER  BY metric_domain, metric_name, week_offset;

    DBMS_OUTPUT.PUT_LINE('<section id="release-delta" class="vw in-s in-a lib" style="--os:18"><h2>Before and after a release'
        || '<small class="h2sub">Each metric''s mean after a release against its mean and usual variation before it</small></h2>');

    IF v_rows.COUNT = 0 OR v_nvalid < 3 THEN
        DBMS_OUTPUT.PUT_LINE('<p class="note">'
            || CASE WHEN v_rows.COUNT = 0 THEN 'No metric values: no valid compared window.'
                    ELSE 'Only ' || v_nvalid || ' valid compared window' || CASE WHEN v_nvalid <> 1 THEN 's' END
                         || ': a split needs at least two windows before it and one after it.' END
            || '</p>');
        DBMS_OUTPUT.PUT_LINE(lib_ls('release-delta',
            CASE WHEN v_rows.COUNT = 0 THEN 'no valid compared window'
                 ELSE 'too few valid windows to split (' || v_nvalid || ')' END));
        DBMS_OUTPUT.PUT_LINE('</section>');
    ELSE
        -- payload + the JS-off table, one metric at a time
        v_buf := '<script>window.AWR_DATA=window.AWR_DATA||{};window.AWR_DATA.reldelta={"nv":'
            || v_nvalid || ',"m":[';
        i := 1;
        WHILE i <= v_rows.COUNT LOOP
            j := i;
            WHILE j < v_rows.COUNT AND v_rows(j + 1).dom = v_rows(i).dom
                  AND v_rows(j + 1).nm = v_rows(i).nm LOOP
                j := j + 1;
            END LOOP;
            DECLARE
                v_pol policy_rec;
            BEGIN
                v_pol := metric_policy(v_rows(i).dom, v_rows(i).nm);
                v_canon := v_pol.canonical;
                v_dir   := v_pol.dir;
                v_mp    := v_pol.min_pct;
                v_ma    := v_pol.min_abs;
            END;
            IF v_canon = 'Y' THEN
                v_nmet := v_nmet + 1;
                v_s := metric_scale(v_rows(i).dom, v_rows(i).nm);
                v_u := metric_unit(v_rows(i).dom, v_rows(i).nm);
                put(CASE WHEN NOT v_first THEN ',' END
                    || '{"d":"' || SUBSTR(v_rows(i).dom, 1, 1) || '"'
                    || ',"n":"' || json_escape(v_rows(i).nm) || '"'
                    || ',"l":"' || json_escape(metric_label(v_rows(i).dom, v_rows(i).nm)) || '"'
                    || ',"u":"' || json_escape(v_u) || '"'
                    || ',"s":' || jnum(v_s)
                    || ',"dir":"' || v_dir || '"'
                    || ',"mp":' || jnum(v_mp)
                    || ',"ma":' || jnum(v_ma)
                    || ',"id":"' || finding_anchor(v_rows(i).dom, v_rows(i).nm) || '"'
                    || ',"v":{');
                v_first := FALSE;
                v_vfirst := TRUE;
                v_cur := NULL; v_sum := 0; v_sq := 0; v_n := 0;
                FOR k IN i .. j LOOP
                    put(CASE WHEN NOT v_vfirst THEN ',' END
                        || '"' || v_rows(k).wo || '":' || jnum(v_rows(k).val));
                    v_vfirst := FALSE;
                    IF v_rows(k).wo = 0 THEN
                        v_cur := v_rows(k).val;
                    ELSE
                        v_n := v_n + 1;
                        v_sum := v_sum + v_rows(k).val;
                    END IF;
                END LOOP;
                put('}}');
                -- mean / sample sd of the prior windows (the JS-off table)
                v_mu := CASE WHEN v_n > 0 THEN v_sum / v_n END;
                v_sd := NULL;
                IF v_n > 1 THEN
                    FOR k IN i .. j LOOP
                        IF v_rows(k).wo > 0 THEN
                            v_sq := v_sq + POWER(v_rows(k).val - v_mu, 2);
                        END IF;
                    END LOOP;
                    v_sd := SQRT(v_sq / (v_n - 1));
                END IF;
                v_tbl(v_tbl.COUNT + 1) := '<tr><td>'
                    || ent(DBMS_XMLGEN.CONVERT(metric_label(v_rows(i).dom, v_rows(i).nm)),
                           finding_anchor(v_rows(i).dom, v_rows(i).nm), 'metric')
                    || '</td><td class="num" data-w="0"' || fmt_num_title(v_cur * v_s) || '>' || fv(v_cur * v_s, v_u) || '</td>'
                    || '<td class="num">' || fv(v_mu * v_s, v_u) || '</td>'
                    || '<td class="num">' || fv(v_sd * v_s, v_u) || '</td>'
                    || '<td class="num">' || v_n || '</td></tr>';
            END IF;
            i := j + 1;
        END LOOP;
        put(']};</script>');
        DBMS_OUTPUT.PUT_LINE(v_buf);

        DBMS_OUTPUT.PUT_LINE(lib_ls('release-delta', v_nmet || ' metrics over ' || v_nvalid
            || ' valid windows; pick a release marker or a window boundary to split them'));

        DBMS_OUTPUT.PUT_LINE('<p class="note rd-nojs">The split before / after a release is computed by the page '
            || 'script, so it needs JavaScript. The table compares Current with the mean and sd of all '
            || v_nprior || ' valid prior windows.</p>');

        -- the client view (hidden until the script fills it)
        DBMS_OUTPUT.PUT_LINE('<div class="rd-app" hidden>'
            || '<div class="rd-pick"><span class="rd-pl">Split at</span><span class="rd-mks" role="group" '
            || 'aria-label="Release markers"></span><label class="rd-bl">or a window boundary '
            || '<select class="rd-sel" aria-label="Split at a window boundary"></select></label></div>'
            || '<p class="rd-why" hidden></p>'
            || '<p class="rd-side"></p>'
            || '<div class="rd-body">'
            || '<div class="rd-lg" aria-hidden="true">'
            || '<span><i class="k s-worse"></i>worse</span>'
            || '<span><i class="k s-better"></i>better</span>'
            || '<span><i class="k s-changed"></i>changed (either direction matters)</span>'
            || '<span><i class="k s-inside"></i>inside its usual variation</span>'
            || '<span><i class="kb"></i>usual variation before (&plusmn;2&sigma;)</span>'
            || '<span><i class="kh"></i>one window after</span>'
            || '<span><i class="kt"></i>each window after</span></div>'
            || '<div class="rd-chart" role="list" aria-label="Change of each metric after the split"></div>'
            || '<details class="rd-more"><summary></summary><div class="rd-chart rd-chart2" role="list" '
            || 'aria-label="Metrics within their usual variation"></div></details>'
            || '<p class="rd-reads"></p>'
            || '<details class="rd-tf"><summary>The numbers of this split</summary><div class="tblwrap">'
            || '<table class="rd-tbl" data-nocount><thead><tr><th>Metric</th><th class="num">Before mean</th>'
            || '<th class="num">Before sd</th><th class="num">n before</th><th class="num">After mean</th>'
            || '<th class="num">n after</th><th class="num">Change</th><th class="num">Usual variation</th>'
            || '<th>Status</th></tr></thead><tbody></tbody></table></div></details>'
            || '</div></div>');

        -- JS off (and every view): Current vs all priors, no split
        DBMS_OUTPUT.PUT_LINE('<details class="rd-all"><summary>Current against all ' || v_nprior
            || ' prior windows (no split), ' || v_nmet || ' metrics</summary><div class="tblwrap">'
            || '<table class="rd-tall" data-nocount><thead><tr><th>Metric</th><th class="num cur-col" data-w="0">Current</th>'
            || '<th class="num">Prior mean</th><th class="num">Prior sd</th><th class="num">n</th></tr></thead><tbody>');
        FOR k IN 1 .. v_tbl.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE(v_tbl(k));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></div></details></section>');
    END IF;
END;
/

@@sql/lib/js_reldelta.plsql

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 28_release_delta END -->'); END;
/
