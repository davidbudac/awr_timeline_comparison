--
-- sql/fleet/01_row.sql
-- Emits this database's SUMMARY ROW (tr.dbrow) for the ops-console table,
-- then OPENS the hidden detail row (tr.detailrow) and its left column with
-- the ASH timeline block.  Replaces the old 01_db_card.sql: the fleet report
-- is now one dense <table class="fleet"> (opened/closed by the assembler),
-- two <tr>s per DB, not a <section class="db-card">.
--
-- The row's score / severity class / crit-warn pills are NOT knowable here
-- (the Top-SQL points that feed the score are computed later in this same
-- fragment, section 05).  So the row emits unique placeholders that the bash
-- assembler substitutes at assembly time, after it has parsed the two
-- FLEET-COUNTS comments and computed the score (single-sourcing the row pills
-- and the sort order):
--   __FLEET_SCORE__  -> numeric severity score
--   __FLEET_SEV__    -> crit|warn|ok (dot + score color class)
--   __FLEET_CRIT__   -> critical finding count      __FLEET_CPILL__ -> c|z
--   __FLEET_WARN__   -> warning finding count        __FLEET_WPILL__ -> w|z
--
-- A third, independent placeholder is emitted unconditionally in the alias
-- cell, regardless of whether this DB was flagged for a detailed report --
-- this section stays ignorant of that (same wrapper-owned philosophy as
-- timeline markers): __FLEET_DETAIL_CHIP__ -> '' (no detail requested) or a
-- small "report" link / "detail failed" pill, filled in by the assembler
-- from the per-alias detail rc + report file it already knows about.
--
-- None contain a tilde or ampersand; a placeholder that survives assembly is
-- a bug the wrapper greps for.
--
-- Everything else in the row is recomputed in-flight, same "findings are
-- recomputed, not shared" convention as sections 04/05 and the single-DB
-- report's 07/08:
--   * AAS       -- current-window SYSMETRIC 'Average Active Sessions'
--   * DB-time   -- per-window DB-time-per-sec CSV -> the micro sparkline
--   * worst     -- the max-|z| crit/warn row from the unified LOAD/METRIC/
--                  WAIT z-score compute (a green "no metric beyond 2sigma"
--                  when nothing breaches)
--   * ASH       -- a data-ash-of ribbon div (rendered by js_fleet_charts from
--                  window.FLEET_ASH, populated by section 02)
--
-- The section opened here (detailrow / detail-grid / left column) is
-- continued by 02/03 and closed by 06_close.sql.
--
-- Read-only: recomputes everything in-flight from the AWR views.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_01 BEGIN -->'); END;
/

DECLARE
    v_aas_cur   NUMBER;
    v_dbt_csv   VARCHAR2(4000);
    v_wf_dom    VARCHAR2(16);
    v_wf_name   VARCHAR2(256);
    v_wf_z      NUMBER;
    v_wf_bucket VARCHAR2(24);
    v_zbadge    VARCHAR2(40);
    v_zcls      VARCHAR2(4);
    v_wtxt      VARCHAR2(400);
BEGIN
    -- --- AAS current + DB-time-per-window CSV (one round trip) -----------
    -- The WITH lives at statement level so the two scalar subqueries below
    -- can reference the aas_rows / dbt_grid CTEs (they would be out of scope
    -- if the WITH were nested inside an inline view).
    WITH
    @@sql/lib/windows_cte.sql
    ,
    dbt_pairs AS (
        SELECT w.week_offset, w.dur_sec, ss.snap_id, ss.value,
               ss.instance_number, w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_sysstat ss
            ON ss.dbid = w.dbid
           AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND ss.instance_number = w.instance_number
           AND ss.stat_name = 'DB time'
    ),
    dbt_bounds AS (
        SELECT week_offset, dur_sec, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   dbt_pairs
        GROUP BY week_offset, dur_sec, instance_number
    ),
    dbt_rows AS (
        SELECT week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS val
        FROM   dbt_bounds
        GROUP BY week_offset
    ),
    all_weeks AS (
        SELECT LEVEL - 1 AS week_offset
        FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
    ),
    dbt_grid AS (
        SELECT aw.week_offset, r.val
        FROM   all_weeks aw
        LEFT JOIN dbt_rows r ON r.week_offset = aw.week_offset
    ),
    aas_per_snap AS (
        SELECT w.week_offset, sm.snap_id, SUM(sm.average) AS snap_value
        FROM   valid_windows w
        JOIN   dba_hist_sysmetric_summary sm
            ON sm.dbid = w.dbid
           AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
           AND sm.instance_number = w.instance_number
           AND sm.metric_name = 'Average Active Sessions'
        GROUP BY w.week_offset, sm.snap_id
    ),
    aas_rows AS (
        SELECT week_offset, AVG(snap_value) AS val
        FROM   aas_per_snap
        GROUP BY week_offset
    )
    SELECT
        (SELECT val FROM aas_rows WHERE week_offset = 0),
        (SELECT SUBSTR(LISTAGG(',' || TO_CHAR(val, 'FM99999999990D000000',
                                 'NLS_NUMERIC_CHARACTERS=''.,'''))
                    WITHIN GROUP (ORDER BY week_offset DESC), 2)
         FROM dbt_grid)
    INTO v_aas_cur, v_dbt_csv
    FROM dual;

    -- --- worst finding: top crit/warn row of the unified z-score compute --
    BEGIN
        SELECT metric_domain, metric_name, z_score, change_bucket
        INTO   v_wf_dom, v_wf_name, v_wf_z, v_wf_bucket
        FROM (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            load_targets AS (
                @@~template_dir/sysstat_load_targets.sql
            ),
            load_pairs AS (
                SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                       ss.snap_id, ss.value, w.begin_snap_id, w.end_snap_id
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
                SELECT w.week_offset, t.metric_name, sm.snap_id, t.is_additive,
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
                SELECT 'WAIT' AS metric_domain,
                       'Wait class: ' || wait_class AS metric_name, week_offset,
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
            ),
            pivoted AS (
                SELECT metric_domain, metric_name,
                       MAX(CASE WHEN week_offset = 0 THEN metric_value END)   AS cur_val,
                       AVG(CASE WHEN week_offset > 0 THEN metric_value END)   AS mu,
                       STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
                       COUNT(CASE WHEN week_offset > 0 THEN metric_value END) AS n
                FROM   unified
                GROUP BY metric_domain, metric_name
            ),
            scored AS (
                SELECT metric_domain, metric_name,
                       CASE WHEN cur_val IS NULL OR mu IS NULL THEN NULL
                            WHEN sd IS NULL OR sd = 0 THEN NULL
                            ELSE (cur_val - mu) / sd END AS z_score,
                       CASE
                           WHEN cur_val IS NULL THEN 'n/a'
                           WHEN n < 3           THEN 'insufficient history'
                           WHEN sd IS NULL OR sd = 0 THEN 'flat baseline'
                           WHEN ABS((cur_val - mu) / sd) > 3 THEN 'large'
                           WHEN ABS((cur_val - mu) / sd) > 2 THEN 'moderate'
                           ELSE 'typical'
                       END AS change_bucket
                FROM   pivoted
            )
            SELECT metric_domain, metric_name, z_score, change_bucket
            FROM   scored
            WHERE  change_bucket IN ('large', 'moderate')
            ORDER BY ABS(NVL(z_score, 0)) DESC, metric_name
        )
        WHERE ROWNUM = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_wf_dom := NULL; v_wf_name := NULL; v_wf_z := NULL; v_wf_bucket := NULL;
    END;

    -- --- worst-finding cell content -------------------------------------
    IF v_wf_name IS NULL THEN
        v_zbadge := '&mdash;';
        v_zcls   := 'o';
        v_wtxt   := 'No metric beyond 2&sigma;';
    ELSE
        v_zcls   := CASE WHEN v_wf_bucket = 'large' THEN 'c' ELSE 'w' END;
        v_zbadge := TO_CHAR(v_wf_z, 'FMS9990D0') || '&sigma;';
        v_wtxt   := DBMS_XMLGEN.CONVERT(v_wf_name);
    END IF;

    -- --- summary row (8 cells, matches the assembler's <thead>) ----------
    DBMS_OUTPUT.PUT_LINE('<tr class="dbrow" data-db="'
        || DBMS_XMLGEN.CONVERT('~fleet_alias') || '">');
    DBMS_OUTPUT.PUT_LINE('<td><svg class="chev" viewBox="0 0 16 16">'
        || '<path d="M6 4l5 4-5 4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></td>');
    DBMS_OUTPUT.PUT_LINE('<td><span class="alias-cell"><span class="dot __FLEET_SEV__"></span>'
        || '<span class="alias">' || DBMS_XMLGEN.CONVERT('~fleet_alias')
        || ' <span class="role">' || DBMS_XMLGEN.CONVERT('~db_name') || '</span></span>'
        || '__FLEET_DETAIL_CHIP__</span></td>');
    DBMS_OUTPUT.PUT_LINE('<td><span class="score s-__FLEET_SEV__">__FLEET_SCORE__</span></td>');
    DBMS_OUTPUT.PUT_LINE('<td style="text-align:center"><span class="cw" style="justify-content:center">'
        || '<span class="pill __FLEET_CPILL__">__FLEET_CRIT__C</span>'
        || '<span class="pill __FLEET_WPILL__">__FLEET_WARN__W</span></span></td>');
    DBMS_OUTPUT.PUT_LINE('<td class="aas">'
        || CASE WHEN v_aas_cur IS NULL THEN '&mdash;'
                ELSE TO_CHAR(v_aas_cur, 'FM99990D0') || '<span class="u">AAS</span>' END
        || '</td>');
    DBMS_OUTPUT.PUT_LINE('<td><span class="finding"><span class="zbadge ' || v_zcls || '">'
        || v_zbadge || '</span><span class="txt">' || v_wtxt || '</span></span></td>');
    DBMS_OUTPUT.PUT_LINE('<td class="spark-cell"><span class="trend" data-spark="'
        || NVL(v_dbt_csv, '') || '" data-spark-title="DB time per sec"></span></td>');
    DBMS_OUTPUT.PUT_LINE('<td class="ribbon-cell"><div class="ash-ribbon" data-ash-of="'
        || DBMS_XMLGEN.CONVERT('~fleet_alias') || '" data-ash-mode="ribbon"></div></td>');
    DBMS_OUTPUT.PUT_LINE('</tr>');

    -- --- open the detail row + left column + ASH timeline block ----------
    DBMS_OUTPUT.PUT_LINE('<tr class="detailrow hidden"><td colspan="8">');
    DBMS_OUTPUT.PUT_LINE('<div class="detail"><div class="detail-grid">');
    DBMS_OUTPUT.PUT_LINE('<div class="detail-col-left">');
    DBMS_OUTPUT.PUT_LINE('<div class="detail-block timeline-box">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h">ASH by wait class &mdash; 24h hourly (AAS) &middot; '
        || 'Host ' || DBMS_XMLGEN.CONVERT('~host_name')
        || ' &middot; ' || DBMS_XMLGEN.CONVERT('~db_version')
        || ' &middot; DBID ' || '~dbid' || '</div>');
    DBMS_OUTPUT.PUT_LINE('<div class="ash-timeline" data-ash-of="'
        || DBMS_XMLGEN.CONVERT('~fleet_alias') || '" data-ash-mode="timeline"></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="tl-caption"></div>');
    DBMS_OUTPUT.PUT_LINE('</div>');   -- .detail-block timeline-box
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_01 END -->'); END;
/
