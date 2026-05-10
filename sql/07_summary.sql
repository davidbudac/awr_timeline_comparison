--
-- 07_summary.sql
-- For every scalar metric rendered by sections 02-04, compute the z-score
-- of the current window against the mean/stddev of the prior valid windows,
-- bucket the change magnitude (large / moderate / typical) and render the
-- findings heatmap + detail table.  Buckets describe how far the current
-- value sits from its baseline of prior comparison windows; "large" is not
-- a value judgement, just a |z| > 3 outlier.
-- Read-only: recomputes everything in-flight from the AWR views; does NOT
-- persist anything.
--
-- Implementation note: the same set of findings drives two views (the
-- heatmap and the detail table), each with a different ORDER BY.  We
-- BULK COLLECT the unified LOAD/METRIC/WAIT recompute exactly once into a
-- PL/SQL collection, attach both view positions via ROW_NUMBER(), and then
-- walk the collection twice -- first emitting the heatmap JSON in heatmap
-- order, then the table rows in detail-table order via an index array.
-- This keeps the (substantial) recompute single-pass while preserving the
-- two distinct sort orders the report expects.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    TYPE finding_rec IS RECORD (
        metric_domain  VARCHAR2(16),
        metric_name    VARCHAR2(120),
        cur_val        NUMBER,
        prior_mean     NUMBER,
        prior_sd       NUMBER,
        n_prior        NUMBER,
        z_score        NUMBER,
        pct_delta      NUMBER,
        change_bucket  VARCHAR2(40),
        vals_csv       VARCHAR2(4000),
        row_max        NUMBER,
        heat_pos       NUMBER,
        table_pos      NUMBER
    );
    TYPE findings_t  IS TABLE OF finding_rec INDEX BY PLS_INTEGER;
    TYPE idx_t       IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;

    v_findings   findings_t;
    v_table_idx  idx_t;
    f            finding_rec;

    v_total      NUMBER := 0;
    v_crit       NUMBER := 0;
    v_warn       NUMBER := 0;
    v_heat_json  CLOB;
    v_row        VARCHAR2(32767);
    v_sev        VARCHAR2(40);
    v_cls        VARCHAR2(10);
    v_weeks_back NUMBER := ~weeks_back;

    @@sql/lib/nth_csv.plsql

    -- Adaptive decimal format based on the row's max magnitude.  Mirrors
    -- the formatter used by the load/metrics tables: 0 decimals when the
    -- max is large, 2 decimals otherwise so small values still resolve.
    FUNCTION fmt_cell(p_val NUMBER, p_row_max NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN RETURN '&mdash;'; END IF;
        IF NVL(p_row_max, 0) >= 1000 THEN
            RETURN TO_CHAR(p_val, 'FM999G999G990');
        ELSIF NVL(p_row_max, 0) >= 10 THEN
            RETURN TO_CHAR(p_val, 'FM999G990D0');
        ELSIF NVL(p_row_max, 0) >= 1 THEN
            RETURN TO_CHAR(p_val, 'FM990D00');
        ELSIF NVL(p_row_max, 0) >= 0.001 THEN
            RETURN TO_CHAR(p_val, 'FM990D0000');
        ELSE
            RETURN TO_CHAR(p_val, 'FM990D000000');
        END IF;
    END;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="findings"><h2 id="findings-heading">Findings summary</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'z-score of the current window vs prior valid windows. '
        || '|z|&gt;3 = large change, |z|&gt;2 = moderate change, otherwise typical. '
        || 'Insufficient history (n&lt;3) shows only %-delta. '
        || 'Heatmap rows show per-window values; the rightmost cell is the current window.</p>');

    --
    -- Recompute LOAD / METRIC / WAIT values per (week_offset, metric) from
    -- the AWR views, pivot to cur vs prior AVG/STDDEV, derive the change
    -- bucket, and tag each row with both view positions via ROW_NUMBER.
    -- Bulk-collected once; both report views below iterate the collection.
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    -- LOAD domain: DBA_HIST_SYSSTAT cumulative counters, per-sec deltas.
    load_targets AS (
        @@sql/lib/sysstat_load_targets.sql
    ),
    load_pairs AS (
        SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
               ss.snap_id, ss.value,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_sysstat ss
            ON ss.dbid = w.dbid
           AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND ss.instance_number = w.instance_number
           AND ss.stat_name IN (SELECT stat_name FROM load_targets)
    ),
    load_bounds AS (
        SELECT week_offset, dur_sec, stat_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   load_pairs
        GROUP BY week_offset, dur_sec, stat_name, instance_number
    ),
    load_rows AS (
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / dur_sec
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, dur_sec, stat_name
    ),
    -- METRIC domain: DBA_HIST_SYSMETRIC_SUMMARY averages over window.
    -- Per-snap cluster value: SUM across instances for additive metrics,
    -- AVG for ratios. See sql/lib/sysmetric_targets.sql for the rationale.
    metric_targets AS (
        @@sql/lib/sysmetric_targets.sql
    ),
    metric_per_snap AS (
        SELECT w.week_offset, t.metric_name, sm.snap_id,
               t.is_additive,
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
        SELECT 'METRIC' AS metric_domain,
               metric_name,
               week_offset,
               AVG(snap_value) AS metric_value
        FROM   metric_per_snap
        GROUP BY week_offset, metric_name
    ),
    -- WAIT domain: DBA_HIST_SYSTEM_EVENT time-waited per wait_class, as rate.
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.event_name,
               se.snap_id,
               se.time_waited_micro,
               se.instance_number,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, event_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, event_name, instance_number
    ),
    wait_rows AS (
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN dur_sec > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / dur_sec / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, dur_sec, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    ),
    -- Expand to a full grid (every distinct metric x every comparison week)
    -- so LISTAGG below produces one CSV slot per week even when a week is
    -- missing data. The LEFT JOIN preserves NULL slots for missing weeks.
    base_metrics AS (
        SELECT DISTINCT metric_domain, metric_name FROM unified
    ),
    all_weeks AS (
        SELECT LEVEL - 1 AS week_offset
        FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
    ),
    metric_grid AS (
        SELECT b.metric_domain, b.metric_name, w.week_offset, u.metric_value
        FROM   base_metrics b
        CROSS JOIN all_weeks w
        LEFT JOIN unified u ON u.metric_domain = b.metric_domain
                           AND u.metric_name   = b.metric_name
                           AND u.week_offset   = w.week_offset
    ),
    pivoted AS (
        SELECT metric_domain, metric_name,
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)  AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)  AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END) AS n,
               MAX(ABS(metric_value)) AS row_max,
               -- Per-window value CSV, oldest -> current (week_offset DESC).
               -- Empty token between commas marks a missing window.
               LISTAGG(
                   CASE WHEN metric_value IS NULL THEN ''
                        ELSE TO_CHAR(metric_value, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''') END,
                   ',') WITHIN GROUP (ORDER BY week_offset DESC) AS vals_csv
        FROM   metric_grid
        GROUP BY metric_domain, metric_name
    ),
    scored AS (
        SELECT metric_domain, metric_name,
               cur_val,
               mu       AS prior_mean,
               sd       AS prior_sd,
               n        AS n_prior,
               vals_csv,
               row_max,
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
                   WHEN cur_val IS NULL THEN 'insufficient history'
                   WHEN n < 3           THEN 'insufficient history'
                   WHEN sd IS NULL OR sd = 0 THEN 'flat baseline'
                   WHEN ABS((cur_val - mu) / sd) > 3 THEN 'large'
                   WHEN ABS((cur_val - mu) / sd) > 2 THEN 'moderate'
                   ELSE 'typical'
               END AS change_bucket
        FROM   pivoted
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    ),
    ranked AS (
        SELECT metric_domain, metric_name,
               cur_val, prior_mean, prior_sd, n_prior,
               z_score, pct_delta, change_bucket,
               vals_csv, row_max,
               ROW_NUMBER() OVER (
                   ORDER BY CASE change_bucket
                                WHEN 'large'                THEN 1
                                WHEN 'moderate'             THEN 2
                                WHEN 'insufficient history' THEN 3
                                WHEN 'flat baseline'        THEN 4
                                ELSE 5
                            END,
                            ABS(NVL(z_score, 0)) DESC,
                            ABS(NVL(pct_delta, 0)) DESC,
                            metric_name) AS heat_pos,
               ROW_NUMBER() OVER (
                   ORDER BY CASE change_bucket
                                WHEN 'large'                THEN 1
                                WHEN 'moderate'             THEN 2
                                WHEN 'insufficient history' THEN 3
                                WHEN 'flat baseline'        THEN 4
                                ELSE 5
                            END,
                            ABS(NVL(z_score, 0)) DESC,
                            ABS(NVL(pct_delta, 0)) DESC,
                            metric_name) AS table_pos
        FROM   scored
    )
    SELECT metric_domain, metric_name,
           cur_val, prior_mean, prior_sd, n_prior,
           z_score, pct_delta, change_bucket,
           vals_csv, row_max,
           heat_pos, table_pos
    BULK COLLECT INTO v_findings
    FROM   ranked
    ORDER  BY heat_pos;

    --
    -- Counters for the heading (large / moderate / total).
    --
    FOR i IN 1 .. v_findings.COUNT LOOP
        f := v_findings(i);
        v_total := v_total + 1;
        IF f.change_bucket = 'large'    THEN v_crit := v_crit + 1;
        ELSIF f.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
        END IF;
    END LOOP;

    -- Rewrite the heading now that we have the counters.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var h=document.getElementById("findings-heading");'
        || 'if(h)h.innerHTML=''Findings summary &mdash; '
        || '<span class="badge crit">' || v_crit || ' large</span> '
        || '<span class="badge warn">' || v_warn || ' moderate</span> '
        || '<span class="badge ok">'   || v_total || ' total</span>'';})();</script>');

    --
    -- CSS-grid heatmap: 1 metric label column + (weeks_back+1) value
    -- columns + 1 z-score column.  Header row first, then one data row
    -- per finding (severity-ordered by heat_pos == bulk-collect order).
    -- The grid sets its column template inline so a single CSS rule covers
    -- any weeks_back the caller chose.
    --
    DECLARE
        v_cols_template VARCHAR2(200);
        v_off_lbl       VARCHAR2(40);
        v_val_s         VARCHAR2(64);
        v_val_n         NUMBER;
        v_cell_cls      VARCHAR2(40);
        v_lab_cls       VARCHAR2(40);
        v_z_cls         VARCHAR2(40);
        v_z_text        VARCHAR2(40);
        v_metric_disp   VARCHAR2(180);
    BEGIN
        v_cols_template := 'grid-template-columns:minmax(180px,260px) repeat('
            || (v_weeks_back + 1) || ',minmax(0,1fr)) 70px;';

        DBMS_OUTPUT.PUT_LINE('<div class="heatmap" style="' || v_cols_template || '">');

        -- Header row: Metric / -Nw .. -1w / now / z
        DBMS_OUTPUT.PUT_LINE('  <div class="h">Metric</div>');
        FOR k IN REVERSE 1 .. v_weeks_back LOOP
            v_off_lbl := REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k);
            IF v_off_lbl IS NULL THEN v_off_lbl := k || 'p'; END IF;
            DBMS_OUTPUT.PUT_LINE('  <div class="h col">&minus;' || v_off_lbl || '</div>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('  <div class="h col">now</div>');
        DBMS_OUTPUT.PUT_LINE('  <div class="h z-h">z</div>');

        -- Data rows
        FOR i IN 1 .. v_findings.COUNT LOOP
            f := v_findings(i);
            v_sev := f.change_bucket;
            v_cls := CASE v_sev WHEN 'large'    THEN 'crit'
                                WHEN 'moderate' THEN 'warn'
                                WHEN 'typical'  THEN 'ok'
                                ELSE 'skip' END;

            -- Skip-row gets muted text (insufficient history / flat baseline)
            v_lab_cls := CASE WHEN v_cls = 'skip' THEN 'lab skip' ELSE 'lab' END;

            v_metric_disp := DBMS_XMLGEN.CONVERT(f.metric_name);
            DBMS_OUTPUT.PUT_LINE('  <div class="' || v_lab_cls
                || '" data-metric="' || REPLACE(v_metric_disp, '"', '&quot;')
                || '" title="' || f.metric_domain || ' &middot; ' || v_sev || '">'
                || v_metric_disp || '</div>');

            -- Per-week cells: oldest -> current.  Slot k+1 = week_offset k.
            -- Render in column order -Nw, -(N-1)w, ..., -1w, now.
            FOR k IN REVERSE 1 .. v_weeks_back LOOP
                v_val_s := nth_csv(f.vals_csv, v_weeks_back - k + 1);
                IF v_val_s IS NULL OR v_val_s = '' THEN
                    DBMS_OUTPUT.PUT_LINE('  <div class="cell skip">&mdash;</div>');
                ELSE
                    v_val_n := TO_NUMBER(v_val_s, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''');
                    DBMS_OUTPUT.PUT_LINE('  <div class="cell">'
                        || fmt_cell(v_val_n, f.row_max) || '</div>');
                END IF;
            END LOOP;

            -- "now" cell takes the row severity color so the eye lands
            -- on the row's verdict.
            v_val_s := nth_csv(f.vals_csv, v_weeks_back + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                DBMS_OUTPUT.PUT_LINE('  <div class="cell skip">&mdash;</div>');
            ELSE
                v_val_n := TO_NUMBER(v_val_s, 'FM99999999990D000000',
                                     'NLS_NUMERIC_CHARACTERS=''.,''');
                v_cell_cls := CASE WHEN v_cls IN ('crit','warn','ok','skip')
                                   THEN 'cell ' || v_cls
                                   ELSE 'cell' END;
                DBMS_OUTPUT.PUT_LINE('  <div class="' || v_cell_cls || '">'
                    || fmt_cell(v_val_n, f.row_max) || '</div>');
            END IF;

            -- z-score column: signed, colored only when crit/warn
            IF f.z_score IS NULL THEN
                v_z_text := CASE WHEN f.n_prior < 3 THEN 'insuf.' ELSE 'flat' END;
                v_z_cls  := 'z skip';
            ELSE
                v_z_text := TO_CHAR(f.z_score, 'FMS990D00');
                v_z_cls  := CASE WHEN v_cls IN ('crit','warn') THEN 'z ' || v_cls ELSE 'z' END;
            END IF;
            DBMS_OUTPUT.PUT_LINE('  <div class="' || v_z_cls || '">' || v_z_text || '</div>');
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('</div>');  -- .heatmap
    END;

    DBMS_OUTPUT.PUT_LINE('<p style="font-size:11px;color:var(--muted);margin-top:6px">'
        || 'Read-only run: nothing persisted. Re-run <code>awr_trend.sql</code> to refresh.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/
