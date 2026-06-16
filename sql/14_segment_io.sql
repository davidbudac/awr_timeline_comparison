--
-- 14_segment_io.sql
-- Segment I/O trend: the segments (and segment types) with the most I/O
-- activity per compared window, from DBA_HIST_SEG_STAT joined to
-- DBA_HIST_SEG_STAT_OBJ for owner / object / type names.  Four
-- dimensions: physical reads and writes (blocks) and physical read and
-- write requests (I/O calls).  Per dimension: a line chart (one series
-- per top segment across windows, toggleable to a per-object-type
-- rollup) plus a collapsed detail table carrying every number.
--
-- Template-INDEPENDENT on purpose, like section 13 (utilization): the
-- segment I/O view should look the same no matter which triage template
-- the caller picked, so there is no targets file under templates/.
--
-- DBA_HIST_SEG_STAT exposes pre-computed *_DELTA columns (like
-- DBA_HIST_SQLSTAT, and unlike DBA_HIST_SYSTEM_EVENT), so deltas are
-- summed directly -- no begin/end pair math needed.  Segments are
-- identified by NAME (owner.object.subobject), not by obj#: that keeps
-- one series per logical segment across a DBID change and collapses RAC
-- instances naturally.  Rows whose object metadata never made it into
-- DBA_HIST_SEG_STAT_OBJ surface as "(unknown).OBJ#<n>" rather than
-- being dropped.  Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 14_segment_io BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_weeks_json VARCHAR2(4000);
    v_weeks_iso_json VARCHAR2(4000);
    v_cur_dim    VARCHAR2(10);
    v_val        NUMBER;
    v_val_s      VARCHAR2(64);
    v_rnk_s      VARCHAR2(64);
    v_chart_vals VARCHAR2(8000);
    v_new_entry  VARCHAR2(8000);

    -- Hard cap for the per-dimension JSON accumulators below, same
    -- rationale as section 06: PL/SQL VARCHAR2 maxes out at 32767 bytes
    -- and the per-dim emit concatenates a short prefix/suffix around the
    -- accumulator, so leave headroom.
    c_json_cap   CONSTANT PLS_INTEGER := 32500;

    -- Per-dimension JSON payloads accumulated while rendering the detail
    -- tables; emitted once at the end as AWR_DATA.segIo.dims so each
    -- dimension drives its own line chart.  Two parallel breakdowns: one
    -- series per top-N segment, one series per object type (the rollup).
    TYPE t_dim_str  IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(10);
    TYPE t_dim_meta IS TABLE OF VARCHAR2(80)    INDEX BY VARCHAR2(10);
    TYPE t_dim_num  IS TABLE OF NUMBER          INDEX BY VARCHAR2(10);
    v_dim_segs_json   t_dim_str;
    v_dim_types_json  t_dim_str;
    v_dim_label       t_dim_meta;
    v_dim_unit        t_dim_meta;
    -- "kept vs total" counters driving the truncation footnote, bumped
    -- exactly like section 06's: total on every cursor row, kept only
    -- when the entry actually fit under c_json_cap.
    v_dim_segs_kept   t_dim_num;
    v_dim_segs_total  t_dim_num;
    v_dim_types_kept  t_dim_num;
    v_dim_types_total t_dim_num;
    v_dim             VARCHAR2(10);
    v_first_dim       BOOLEAN;

    @@sql/lib/nth_csv.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="segment-io"><h2>Segment I/O (top ' || v_top_n
        || ' per dimension, per window)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Segments with the most I/O activity per window, from '
        || 'DBA_HIST_SEG_STAT <code>*_DELTA</code> joined to '
        || 'DBA_HIST_SEG_STAT_OBJ for names. Reads/writes are blocks; '
        || 'requests are I/O calls. Chart per dimension: each line = one '
        || 'segment across windows, oldest &rarr; current; toggle to roll '
        || 'the same totals up by object type (the rollup covers <b>all</b> '
        || 'segments, not just the charted top-' || v_top_n || '). '
        || 'Detail tables collapsed; click to expand.</p>');

    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - (~step_hours/24)*week_offset, '~period_axis_fmt') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);

    -- Parallel full-ISO timestamps for the same windows (week_offset DESC
    -- order), fed to AWR_markLine so markers snap to the nearest window
    -- while the visible x-axis keeps the compact period_axis_fmt label.
    SELECT '['
        || LISTAGG('"' || TO_CHAR(
               CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
               - (~step_hours/24)*week_offset, 'YYYY-MM-DD HH24:MI') || '"', ',')
               WITHIN GROUP (ORDER BY week_offset DESC)
        || ']'
    INTO   v_weeks_iso_json
    FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1);


    -- Per-dimension detail tables, packed into one big cursor. ------------
    v_cur_dim := NULL;
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- Pre-aggregate per (window, physical segment key) BEFORE the name
        -- join so dba_hist_seg_stat_obj is probed once per segment, not
        -- once per snap row.
        seg_raw AS (
            SELECT w.week_offset,
                   ss.dbid, ss.ts#, ss.obj#, ss.dataobj#,
                   SUM(NVL(ss.physical_reads_delta, 0))          AS phys_reads,
                   SUM(NVL(ss.physical_writes_delta, 0))         AS phys_writes,
                   SUM(NVL(ss.physical_read_requests_delta, 0))  AS read_reqs,
                   SUM(NVL(ss.physical_write_requests_delta, 0)) AS write_reqs
            FROM   valid_windows w
            JOIN   dba_hist_seg_stat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND ss.instance_number = w.instance_number
            GROUP BY w.week_offset, ss.dbid, ss.ts#, ss.obj#, ss.dataobj#
        ),
        -- Name lookup is deduped to one row per (dbid, ts#, obj#, dataobj#):
        -- the underlying WRH$ table is additionally keyed by con_dbid, so a
        -- bare join could fan out in a CDB and double the sums.  ORDER BY
        -- NULL, not ROWID: DBA_HIST_SEG_STAT_OBJ is a join view in a PDB
        -- and selecting ROWID raises ORA-01445 (same caveat as the
        -- dba_hist_sqltext lookups in section 06).
        obj_names AS (
            SELECT dbid, ts#, obj#, dataobj#, owner, object_name,
                   subobject_name, tablespace_name, object_type
            FROM (
                SELECT o.dbid, o.ts#, o.obj#, o.dataobj#, o.owner,
                       o.object_name, o.subobject_name, o.tablespace_name,
                       o.object_type,
                       ROW_NUMBER() OVER (PARTITION BY o.dbid, o.ts#, o.obj#,
                                          o.dataobj# ORDER BY NULL) AS rn
                FROM   dba_hist_seg_stat_obj o
                WHERE  o.dbid IN (~dbid_list)
            ) WHERE rn = 1
        ),
        named AS (
            SELECT r.week_offset,
                   NVL(o.owner, '(unknown)') || '.'
                       || NVL(o.object_name, 'OBJ#' || TO_CHAR(r.obj#))
                       || CASE WHEN o.subobject_name IS NOT NULL
                               THEN '.' || o.subobject_name ELSE '' END AS seg_name,
                   NVL(o.object_type, '(unknown)')     AS object_type,
                   NVL(o.tablespace_name, '(unknown)') AS tablespace_name,
                   r.phys_reads, r.phys_writes, r.read_reqs, r.write_reqs
            FROM   seg_raw r
            LEFT JOIN obj_names o
                ON o.dbid     = r.dbid
               AND o.ts#      = r.ts#
               AND o.obj#     = r.obj#
               AND o.dataobj# = r.dataobj#
        ),
        -- Group by NAME, not obj#: one row per logical segment per window
        -- even when the underlying obj#/dbid differs across windows
        -- (rebuild, truncate-reset dataobj#, DBID change).
        agg AS (
            SELECT week_offset, seg_name,
                   MAX(object_type)     AS object_type,
                   MAX(tablespace_name) AS tablespace_name,
                   SUM(phys_reads)      AS phys_reads,
                   SUM(phys_writes)     AS phys_writes,
                   SUM(read_reqs)       AS read_reqs,
                   SUM(write_reqs)      AS write_reqs
            FROM   named
            GROUP BY week_offset, seg_name
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY phys_reads DESC, seg_name)  AS r_pr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY phys_writes DESC, seg_name) AS r_pw,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_reqs DESC, seg_name)   AS r_rr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_reqs DESC, seg_name)  AS r_wr
            FROM   agg a
        ),
        picked AS (
            SELECT 'PREADS' AS dim, week_offset, seg_name, object_type, tablespace_name,
                   phys_reads AS metric_value, r_pr AS rnk
            FROM ranked WHERE r_pr <= (SELECT top_n FROM run_params) AND phys_reads > 0
            UNION ALL
            SELECT 'PWRITES', week_offset, seg_name, object_type, tablespace_name,
                   phys_writes, r_pw
            FROM ranked WHERE r_pw <= (SELECT top_n FROM run_params) AND phys_writes > 0
            UNION ALL
            SELECT 'RREQ', week_offset, seg_name, object_type, tablespace_name,
                   read_reqs, r_rr
            FROM ranked WHERE r_rr <= (SELECT top_n FROM run_params) AND read_reqs > 0
            UNION ALL
            SELECT 'WREQ', week_offset, seg_name, object_type, tablespace_name,
                   write_reqs, r_wr
            FROM ranked WHERE r_wr <= (SELECT top_n FROM run_params) AND write_reqs > 0
        ),
        dims AS (
            SELECT 'PREADS' code, 1 ord, 'By physical reads'  label, 'blocks' unit FROM dual UNION ALL
            SELECT 'PWRITES', 2,    'By physical writes',            'blocks'      FROM dual UNION ALL
            SELECT 'RREQ',    3,    'By physical read requests',     'reqs'        FROM dual UNION ALL
            SELECT 'WREQ',    4,    'By physical write requests',    'reqs'        FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        segs AS (
            SELECT dim, seg_name,
                   MAX(object_type)     AS object_type,
                   MAX(tablespace_name) AS tablespace_name
            FROM   picked
            GROUP BY dim, seg_name
        ),
        grid AS (
            SELECT q.dim, q.seg_name, q.object_type, q.tablespace_name,
                   w.week_offset, p.metric_value, p.rnk
            FROM   segs q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.seg_name = q.seg_name AND p.week_offset = w.week_offset
        ),
        per_seg AS (
            SELECT dim, seg_name,
                   MAX(object_type)     AS object_type,
                   MAX(tablespace_name) AS tablespace_name,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END) AS cur_val,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)          AS cur_rnk,
                   MIN(rnk) AS best_rank,
                   MAX(metric_value) AS best_value,
                   LISTAGG(CASE WHEN metric_value IS NULL THEN ''
                                ELSE TO_CHAR(metric_value, 'FM99999999999999990',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals,
                   LISTAGG(CASE WHEN rnk IS NULL THEN '' ELSE TO_CHAR(rnk) END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_rnks
            FROM   grid
            GROUP BY dim, seg_name
        )
        SELECT d.code AS dim, d.ord AS dim_ord, d.label AS dim_label,
               d.unit AS dim_unit,
               ps.seg_name, ps.object_type, ps.tablespace_name,
               ps.cur_val, ps.cur_rnk, ps.week_vals, ps.week_rnks
        FROM   dims d
        JOIN   per_seg ps ON ps.dim = d.code
        ORDER BY d.ord,
            CASE WHEN ps.cur_rnk IS NULL THEN 1 ELSE 0 END,
            ps.cur_rnk NULLS LAST,
            ps.best_rank,
            ps.best_value DESC,
            ps.seg_name
    ) LOOP
        IF v_cur_dim IS NULL OR v_cur_dim <> s.dim THEN
            IF v_cur_dim IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
            END IF;
            v_cur_dim := s.dim;
            v_dim_label(s.dim)       := s.dim_label;
            v_dim_unit(s.dim)        := s.dim_unit;
            v_dim_segs_json(s.dim)   := NULL;
            v_dim_segs_kept(s.dim)   := 0;
            v_dim_segs_total(s.dim)  := 0;
            v_dim_types_kept(s.dim)  := 0;
            v_dim_types_total(s.dim) := 0;

            DBMS_OUTPUT.PUT_LINE('<h3 style="margin-top:18px">' || s.dim_label || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<div class="topsql-toggle" data-segio-target="' || s.dim || '">'
                || '<span>Break down by:</span>'
                || '<button type="button" data-mode="segs" class="active">Segment</button>'
                || '<button type="button" data-mode="types">Object type</button>'
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="segio-chart-'
                || s.dim || '"></div>');

            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>' || s.dim_label || ' &mdash; detail table</summary>');

            v_header := '<thead><tr><th>Segment</th><th>Type</th>'
                || '<th class="num">Current (' || s.dim_unit || ')</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                v_header := v_header || '<th class="num">&minus;'
                    || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
            END LOOP;
            v_header := v_header || '</tr></thead>';
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
        END IF;

        -- Build oldest->newest values array for this segment (chart series).
        -- week_vals slot 1 = current (week_offset 0), slot N+1 = oldest;
        -- iterate in reverse so the chart x-axis (oldest-first) lines up.
        v_chart_vals := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := nth_csv(s.week_vals, k);
            IF v_chart_vals IS NOT NULL AND LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
            ELSE
                v_chart_vals := v_chart_vals || v_val_s;
            END IF;
        END LOOP;
        v_new_entry := '{"name":"' || REPLACE(s.seg_name, '"', '\"')
            || '","type":"' || REPLACE(s.object_type, '"', '\"')
            || '","cur":' || NVL(TO_CHAR(s.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        v_dim_segs_total(s.dim) := v_dim_segs_total(s.dim) + 1;
        IF v_dim_segs_json(s.dim) IS NULL THEN
            v_dim_segs_json(s.dim) := v_new_entry;
            v_dim_segs_kept(s.dim) := v_dim_segs_kept(s.dim) + 1;
        ELSIF LENGTH(v_dim_segs_json(s.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_segs_json(s.dim) :=
                v_dim_segs_json(s.dim) || ',' || v_new_entry;
            v_dim_segs_kept(s.dim) := v_dim_segs_kept(s.dim) + 1;
        END IF;

        v_row := '<tr>'
            || '<td class="mono"><span title="tablespace '
            || DBMS_XMLGEN.CONVERT(s.tablespace_name) || '">'
            || DBMS_XMLGEN.CONVERT(s.seg_name) || '</span></td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(s.object_type) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN s.cur_val IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.cur_val, 'FM999G999G999G999G990') END
            || CASE WHEN s.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || s.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(s.week_vals, k + 1);
            v_rnk_s := nth_csv(s.week_rnks, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || TO_CHAR(v_val, 'FM999G999G999G999G990');
            END IF;
            IF v_rnk_s IS NOT NULL AND v_rnk_s <> '' THEN
                v_row := v_row || ' <span class="badge skip">#' || v_rnk_s || '</span>';
            END IF;
            v_row := v_row || '</td>';
        END LOOP;

        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    IF v_cur_dim IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
    ELSE
        DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
            || 'No segment-level I/O recorded for any compared window '
            || '(DBA_HIST_SEG_STAT empty for these snapshots, or no valid '
            || 'windows).</p>');
    END IF;

    -- Second pass: per-object-type rollup for the chart toggle. Same
    -- valid_windows + DBA_HIST_SEG_STAT scan, aggregated over ALL segments
    -- of each type (not just the charted top-N), so the rollup is the true
    -- per-type total. No detail table -- chart only, like section 06's
    -- per-schema breakdown.
    FOR tc IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        seg_raw AS (
            SELECT w.week_offset,
                   ss.dbid, ss.ts#, ss.obj#, ss.dataobj#,
                   SUM(NVL(ss.physical_reads_delta, 0))          AS phys_reads,
                   SUM(NVL(ss.physical_writes_delta, 0))         AS phys_writes,
                   SUM(NVL(ss.physical_read_requests_delta, 0))  AS read_reqs,
                   SUM(NVL(ss.physical_write_requests_delta, 0)) AS write_reqs
            FROM   valid_windows w
            JOIN   dba_hist_seg_stat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND ss.instance_number = w.instance_number
            GROUP BY w.week_offset, ss.dbid, ss.ts#, ss.obj#, ss.dataobj#
        ),
        -- Same deduped name lookup as the per-segment cursor above (the
        -- WRH$ table is additionally keyed by con_dbid; ORDER BY NULL to
        -- stay PDB-join-view-safe).
        obj_names AS (
            SELECT dbid, ts#, obj#, dataobj#, object_type
            FROM (
                SELECT o.dbid, o.ts#, o.obj#, o.dataobj#, o.object_type,
                       ROW_NUMBER() OVER (PARTITION BY o.dbid, o.ts#, o.obj#,
                                          o.dataobj# ORDER BY NULL) AS rn
                FROM   dba_hist_seg_stat_obj o
                WHERE  o.dbid IN (~dbid_list)
            ) WHERE rn = 1
        ),
        typed AS (
            SELECT r.week_offset,
                   NVL(o.object_type, '(unknown)') AS object_type,
                   r.phys_reads, r.phys_writes, r.read_reqs, r.write_reqs
            FROM   seg_raw r
            LEFT JOIN obj_names o
                ON o.dbid     = r.dbid
               AND o.ts#      = r.ts#
               AND o.obj#     = r.obj#
               AND o.dataobj# = r.dataobj#
        ),
        agg AS (
            SELECT week_offset, object_type,
                   SUM(phys_reads)  AS phys_reads,
                   SUM(phys_writes) AS phys_writes,
                   SUM(read_reqs)   AS read_reqs,
                   SUM(write_reqs)  AS write_reqs
            FROM   typed
            GROUP BY week_offset, object_type
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY phys_reads DESC, object_type)  AS r_pr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY phys_writes DESC, object_type) AS r_pw,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_reqs DESC, object_type)   AS r_rr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_reqs DESC, object_type)  AS r_wr
            FROM   agg a
        ),
        picked AS (
            SELECT 'PREADS' AS dim, week_offset, object_type,
                   phys_reads AS metric_value, r_pr AS rnk
            FROM ranked WHERE r_pr <= (SELECT top_n FROM run_params) AND phys_reads > 0
            UNION ALL
            SELECT 'PWRITES', week_offset, object_type, phys_writes, r_pw
            FROM ranked WHERE r_pw <= (SELECT top_n FROM run_params) AND phys_writes > 0
            UNION ALL
            SELECT 'RREQ', week_offset, object_type, read_reqs, r_rr
            FROM ranked WHERE r_rr <= (SELECT top_n FROM run_params) AND read_reqs > 0
            UNION ALL
            SELECT 'WREQ', week_offset, object_type, write_reqs, r_wr
            FROM ranked WHERE r_wr <= (SELECT top_n FROM run_params) AND write_reqs > 0
        ),
        dims AS (
            SELECT 'PREADS' code, 1 ord FROM dual UNION ALL
            SELECT 'PWRITES', 2 FROM dual UNION ALL
            SELECT 'RREQ',    3 FROM dual UNION ALL
            SELECT 'WREQ',    4 FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        types AS (
            SELECT DISTINCT dim, object_type FROM picked
        ),
        grid AS (
            SELECT q.dim, q.object_type, w.week_offset, p.metric_value, p.rnk
            FROM   types q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.object_type = q.object_type
                  AND p.week_offset = w.week_offset
        ),
        per_type AS (
            SELECT dim, object_type,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END) AS cur_rnk,
                   MIN(rnk)          AS best_rank,
                   MAX(metric_value) AS best_value,
                   LISTAGG(CASE WHEN metric_value IS NULL THEN ''
                                ELSE TO_CHAR(metric_value, 'FM99999999999999990',
                                             'NLS_NUMERIC_CHARACTERS=''.,''') END, ',')
                       WITHIN GROUP (ORDER BY week_offset ASC) AS week_vals
            FROM   grid
            GROUP BY dim, object_type
        )
        SELECT d.code AS dim, pt.object_type, pt.cur_rnk, pt.week_vals
        FROM   dims d
        JOIN   per_type pt ON pt.dim = d.code
        ORDER BY d.ord,
            CASE WHEN pt.cur_rnk IS NULL THEN 1 ELSE 0 END,
            pt.cur_rnk NULLS LAST,
            pt.best_rank,
            pt.best_value DESC,
            pt.object_type
    ) LOOP
        v_chart_vals := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := nth_csv(tc.week_vals, k);
            IF LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
            ELSE
                v_chart_vals := v_chart_vals || v_val_s;
            END IF;
        END LOOP;
        v_new_entry := '{"name":"' || REPLACE(tc.object_type, '"', '\"')
            || '","cur":' || NVL(TO_CHAR(tc.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        -- Defensive init: a dim with type rows but no top-N segments would
        -- skip the segment loop's per-dim init. Treat as zeroed.
        IF NOT v_dim_types_total.EXISTS(tc.dim) THEN
            v_dim_types_total(tc.dim) := 0;
            v_dim_types_kept(tc.dim)  := 0;
        END IF;
        v_dim_types_total(tc.dim) := v_dim_types_total(tc.dim) + 1;
        IF NOT v_dim_types_json.EXISTS(tc.dim)
           OR v_dim_types_json(tc.dim) IS NULL THEN
            v_dim_types_json(tc.dim) := v_new_entry;
            v_dim_types_kept(tc.dim) := v_dim_types_kept(tc.dim) + 1;
        ELSIF LENGTH(v_dim_types_json(tc.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_types_json(tc.dim) :=
                v_dim_types_json(tc.dim) || ',' || v_new_entry;
            v_dim_types_kept(tc.dim) := v_dim_types_kept(tc.dim) + 1;
        END IF;
    END LOOP;

    -- One ECharts line chart per dimension. Skipped silently when the CDN
    -- is unreachable; the detail tables still carry every value.
    IF v_dim_label.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<script>(function(){');
        DBMS_OUTPUT.PUT_LINE('AWR_DATA.segIo={weeks:' || v_weeks_json
            || ',weeksIso:' || v_weeks_iso_json
            || ',topN:' || v_top_n || ',dims:{');
        v_first_dim := TRUE;
        v_dim := v_dim_label.FIRST;
        WHILE v_dim IS NOT NULL LOOP
            -- Emit each dim in three PUT_LINE calls so no single concat
            -- ever holds both accumulators at once (same ORA-06502 guard
            -- as section 06).
            IF NOT v_first_dim THEN
                DBMS_OUTPUT.PUT_LINE(',');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"' || v_dim || '":{"label":"' || v_dim_label(v_dim)
                || '","unit":"' || v_dim_unit(v_dim)
                || '","segsKept":' || NVL(TO_CHAR(v_dim_segs_kept(v_dim)), '0')
                || ',"segsTotal":' || NVL(TO_CHAR(v_dim_segs_total(v_dim)), '0')
                || ',"typesKept":'
                    || CASE WHEN v_dim_types_kept.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_types_kept(v_dim))
                            ELSE '0' END
                || ',"typesTotal":'
                    || CASE WHEN v_dim_types_total.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_types_total(v_dim))
                            ELSE '0' END
                || ',');
            DBMS_OUTPUT.PUT_LINE(
                '"segs":[' || NVL(v_dim_segs_json(v_dim), '') || '],');
            DBMS_OUTPUT.PUT_LINE(
                '"types":[' ||
                    CASE WHEN v_dim_types_json.EXISTS(v_dim)
                         THEN NVL(v_dim_types_json(v_dim), '') ELSE '' END
                || ']}');
            v_first_dim := FALSE;
            v_dim := v_dim_label.NEXT(v_dim);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('}};');
        -- Truncation footnote when c_json_cap clamped either accumulator;
        -- runs before the echarts guard so it shows offline too.
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.segIo.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("segio-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.segIo.dims[dim]; var bits=[];');
        DBMS_OUTPUT.PUT_LINE('  if(d.segsKept<d.segsTotal){ bits.push("first "+d.segsKept+" of "+d.segsTotal+" segments"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.typesKept<d.typesTotal){ bits.push("first "+d.typesKept+" of "+d.typesTotal+" object types"); }');
        DBMS_OUTPUT.PUT_LINE('  if(!bits.length) return;');
        DBMS_OUTPUT.PUT_LINE('  var note=document.createElement("p");');
        DBMS_OUTPUT.PUT_LINE('  note.className="trunc-note";');
        DBMS_OUTPUT.PUT_LINE('  note.style.cssText="font-size:11px;color:var(--muted);margin:-2px 0 6px;font-style:italic";');
        DBMS_OUTPUT.PUT_LINE('  note.textContent="Chart truncated to fit the 32 KB per-dimension JSON budget: showing "+bits.join(", ")+". The detail table below carries every value.";');
        DBMS_OUTPUT.PUT_LINE('  el.parentNode.insertBefore(note, el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
        DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
        DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
        DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
        DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
        DBMS_OUTPUT.PUT_LINE('var fmt=function(v){return v==null?"—":(+v).toLocaleString(undefined,{maximumFractionDigits:0});};');
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.segIo.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("segio-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.segIo.dims[dim];');
        DBMS_OUTPUT.PUT_LINE('  var weeks=AWR_DATA.segIo.weeks;');
        DBMS_OUTPUT.PUT_LINE('  var mark=window.AWR_markLine&&window.AWR_markLine(weeks,AWR_DATA.segIo.weeksIso);');
        DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
        DBMS_OUTPUT.PUT_LINE('  function render(mode){');
        DBMS_OUTPUT.PUT_LINE('    var rows=(mode==="types"?d.types:d.segs)||[];');
        DBMS_OUTPUT.PUT_LINE('    chart.setOption({');
        DBMS_OUTPUT.PUT_LINE('      tooltip:{trigger:"axis",axisPointer:{type:"line"},formatter:function(ps){var hdr="<b>"+ps[0].axisValue+"</b>";var rs=ps.filter(function(p){return p.value!=null;}).sort(function(a,b){return (b.value||0)-(a.value||0);}).map(function(p){return p.marker+" "+p.seriesName+": <b>"+fmt(p.value)+" "+d.unit+"</b>";}).join("<br/>");return hdr+"<br/>"+rs;}},');
        DBMS_OUTPUT.PUT_LINE('      legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
        DBMS_OUTPUT.PUT_LINE('      grid:{left:50,right:110,top:10,bottom:44,containLabel:true},');
        DBMS_OUTPUT.PUT_LINE('      xAxis:{type:"category",data:weeks,axisLabel:{color:fg,fontWeight:600},splitLine:{show:true,lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      yAxis:{type:"value",name:d.unit,nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (+v).toLocaleString(undefined,{maximumFractionDigits:0});}},splitLine:{lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      series:rows.map(function(s,i){var o={name:s.name,type:"line",connectNulls:false,showSymbol:true,symbolSize:6,itemStyle:{color:palette[i%palette.length]},lineStyle:{width:2},emphasis:{focus:"series",lineStyle:{width:3}},endLabel:{show:true,formatter:"{a}",color:fg,fontSize:10,distance:6},data:s.vals};if(i===0&&mark)o.markLine=mark;return o;})');
        DBMS_OUTPUT.PUT_LINE('    }, true);');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  render("segs");');
        DBMS_OUTPUT.PUT_LINE('  var toggle=document.querySelector(''[data-segio-target="''+dim+''"]'');');
        DBMS_OUTPUT.PUT_LINE('  if(toggle){');
        DBMS_OUTPUT.PUT_LINE('    if(!d.types || !d.types.length){');
        DBMS_OUTPUT.PUT_LINE('      var tb=toggle.querySelector(''[data-mode="types"]'');');
        DBMS_OUTPUT.PUT_LINE('      if(tb) tb.style.display="none";');
        DBMS_OUTPUT.PUT_LINE('    }');
        DBMS_OUTPUT.PUT_LINE('    toggle.addEventListener("click",function(ev){');
        DBMS_OUTPUT.PUT_LINE('      var btn=ev.target.closest("button"); if(!btn) return;');
        DBMS_OUTPUT.PUT_LINE('      var mode=btn.getAttribute("data-mode"); if(!mode) return;');
        DBMS_OUTPUT.PUT_LINE('      Array.prototype.forEach.call(toggle.querySelectorAll("button"),function(b){ b.classList.toggle("active", b===btn); });');
        DBMS_OUTPUT.PUT_LINE('      render(mode);');
        DBMS_OUTPUT.PUT_LINE('    });');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){chart.resize();}).observe(el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
    END IF;

    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 14_segment_io END -->'); END;
/
