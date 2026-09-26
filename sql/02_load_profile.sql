--
-- 02_load_profile.sql
-- Per-window deltas from DBA_HIST_SYSSTAT for a curated set of stats that
-- make up the classic AWR Load Profile (redo, DB time, CPU, reads, parses,
-- transactions, sorts, etc.).  Renders as a pivot: metric x week.
--
-- For cumulative counters we compute end - begin.  Rates are derived from
-- the window duration in seconds.  Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 02_load_profile BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_label      VARCHAR2(120);
    v_per_sec    NUMBER;
    v_per_sec_s  VARCHAR2(64);
    v_row_max    NUMBER;
    v_pct        NUMBER;

    v_unit       VARCHAR2(16);
    v_bucket     VARCHAR2(40);
    v_nrows      PLS_INTEGER := 0;
    -- Subprogram includes go LAST, metric_policy first (it opens with a
    -- TYPE; lint checks 14 / 16), fmt_num before band_glyph (check 17).
    @@sql/lib/metric_policy.plsql
    @@sql/lib/nth_csv.plsql
    @@sql/lib/is_essential.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="load" class="vw in-s in-a lib" style="--os:7"><h2>Load profile'
        || '<small class="h2sub">System statistics per second, Current against its normal range</small></h2>');

    -- v1.6.0: Current, then the baseline band (normal range | band | z |
    -- Delta, sql/lib/band_glyph.plsql) scored by the per-metric policy --
    -- the same bucket 07 gives the row -- then the trend and the prior
    -- windows (plain values; the heat tints are gone).
    v_header := '<thead><tr><th>Metric</th><th>Unit</th><th class="num" data-w="0">Current</th>'
        || band_head || '<th class="trend">Trend</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th class="num" data-w="' || k || '">&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table id="load-profile">' || v_header || '<tbody>');

    FOR m IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        targets AS (
            @@~template_dir/sysstat_load_targets.sql
        ),
        pairs AS (
            SELECT
                w.week_offset, w.dur_sec,
                ss.stat_name, ss.instance_number,
                ss.snap_id, ss.value,
                w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND ss.instance_number = w.instance_number
               AND ss.stat_name IN (SELECT stat_name FROM targets)
        ),
        bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        deltas AS (
            -- Sum the cross-instance delta, then divide by ONE window span.
            -- dur_sec is per-instance (each instance's resolved snaps jitter);
            -- MAX collapses them to the full wall-clock span covered.  Grouping
            -- no longer keys on dur_sec, else differing per-instance spans would
            -- split a RAC week into partial rows.  Single-instance: dur_sec is
            -- constant, so MAX and the narrower GROUP BY are byte-identical.
            SELECT week_offset, stat_name,
                   SUM(NVL(end_val, 0) - NVL(beg_val, 0)) AS stat_value,
                   MAX(dur_sec) AS dur_sec
            FROM   bounds
            GROUP BY week_offset, stat_name
        ),
        facts AS (
            SELECT week_offset, stat_name,
                   CASE WHEN dur_sec > 0 THEN stat_value / dur_sec END AS per_sec
            FROM   deltas
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset
            FROM   dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        grid AS (
            SELECT t.stat_name, w.week_offset, f.per_sec
            FROM   targets t
            CROSS JOIN all_weeks w
            LEFT JOIN facts f
                   ON f.stat_name   = t.stat_name
                  AND f.week_offset = w.week_offset
        )
        SELECT stat_name,
               MAX(CASE WHEN week_offset = 0 THEN per_sec END) AS cur_ps,
               MAX(per_sec) AS row_max,
               -- prior-window baseline for the band (valid windows only:
               -- facts come from valid_windows, so a skipped window is NULL)
               AVG(CASE WHEN week_offset > 0 THEN per_sec END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN per_sec END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN per_sec END)  AS n_prior,
               -- ','||token + SUBSTR: LISTAGG drops NULL measures (and their
               -- delimiter), which would left-compact the CSV and misalign
               -- the positional slots; ','||NULL = ',' keeps the empty slot.
               SUBSTR(LISTAGG(',' || TO_CHAR(per_sec, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset DESC), 2) AS spark_vals,
               SUBSTR(LISTAGG(',' || TO_CHAR(per_sec, 'FM99999999990D000000',
                                             'NLS_NUMERIC_CHARACTERS=''.,'''))
                   WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals
        FROM   grid
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
            v_unit := 'bytes/s';
        ELSIF m.stat_name IN ('DB time', 'DB CPU', 'CPU used by this session') THEN
            v_unit := 'cs/s';
        ELSE
            v_unit := '/s';
        END IF;

        v_row := '<tr id="' || anchor_id('load', m.stat_name)
              || '" data-imp="' || is_essential('LOAD', m.stat_name)
              || '"><td>' || DBMS_XMLGEN.CONVERT(v_label) || '</td>'
              || '<td' || CASE WHEN v_unit = 'cs/s'
                               THEN ' title="centiseconds per second (1/100 s of DB time per elapsed second)"'
                               ELSE '' END
              || '>' || v_unit || '</td>';

        v_row_max := NVL(m.row_max, 0);

        IF v_row_max > 0 AND m.cur_ps IS NOT NULL THEN
            v_pct := LEAST(100, ABS(m.cur_ps) / v_row_max * 100);
        ELSE
            v_pct := 0;
        END IF;

        v_row := v_row || '<td class="num cell-bar" data-w="0"' || fmt_num_title(m.cur_ps) || '>'
              || '<span class="bg" style="width:' || TO_CHAR(v_pct, 'FM990D0') || '%"></span>'
              || '<span class="v"><b>' || fmt_num(m.cur_ps)
              || '</b></span></td>';

        v_bucket := policy_bucket('LOAD', m.stat_name, NULL, m.cur_ps, m.mu, m.sd, m.n_prior);
        v_row := v_row || band_cells(m.cur_ps, m.mu, m.sd, m.n_prior, v_bucket);

        v_row := v_row || '<td class="trend" data-spark="'
              || NVL(m.spark_vals, '') || '" data-spark-title="'
              || DBMS_XMLGEN.CONVERT(v_label) || '"></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_per_sec_s := nth_csv(m.week_vals, k + 1);
            IF v_per_sec_s IS NULL OR v_per_sec_s = '' THEN
                v_row := v_row || '<td class="num" data-w="' || k || '">&mdash;</td>';
            ELSE
                v_per_sec := TO_NUMBER(v_per_sec_s, 'FM99999999990D000000',
                                       'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num" data-w="' || k || '">'
                      || fmt_num(v_per_sec) || '</td>';
            END IF;
        END LOOP;
        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
        v_nrows := v_nrows + 1;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    -- the evidence library's row text (Summary view)
    DBMS_OUTPUT.PUT_LINE(lib_ls('load', v_nrows || ' counters per second') || '</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 02_load_profile END -->'); END;
/
