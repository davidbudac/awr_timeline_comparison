--
-- 15_file_io.sql
-- File I/O trend: the data/temp files with the most I/O activity per
-- compared window, from DBA_HIST_FILESTATXS + DBA_HIST_TEMPSTATXS, plus
-- the AWR-report-style "IOStat by Filetype" breakdown from
-- DBA_HIST_IOSTAT_FILETYPE.  Four dimensions: data read and written
-- (MB, blocks scaled by each file's block size) and read and write
-- requests (I/O calls).  Per dimension: a line chart (one series per
-- top file across windows, toggleable to the per-file-type view) plus
-- a collapsed detail table carrying every number; one extra combined
-- detail table carries the file-type numbers so the offline (no-CDN)
-- report still shows them.
--
-- Template-INDEPENDENT on purpose, like sections 13 and 14: the file
-- I/O view should look the same no matter which triage template the
-- caller picked, so there is no targets file under templates/.
--
-- Unlike DBA_HIST_SEG_STAT, none of these views expose *_DELTA columns
-- -- all counters are cumulative since instance startup -- so deltas
-- are computed begin/end-pair style: join each window's two bounding
-- snaps, sum end-minus-begin per (instance, file) and only keep pairs
-- where both bounds exist (HAVING COUNT(*) = 2).  valid_windows already
-- excludes windows with an instance restart, so the counters are
-- monotonic inside every surviving window.  Files are identified by
-- FILENAME, not file#: that keeps one series per file across a DBID
-- change and across datafile-number reuse (creation_change# differing
-- between bounds simply drops the pair).  The file-type view is NOT a
-- rollup of the file view: DBA_HIST_IOSTAT_FILETYPE covers ALL database
-- I/O (control file, redo log, archive log, data pump, ...), exactly
-- like the AWR report's "IOStat by Filetype" table, so the two modes'
-- totals legitimately differ.  Read-only: no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 15_file_io BEGIN -->'); END;
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
    v_ft_table   BOOLEAN := FALSE;

    -- Hard cap for the per-dimension JSON accumulators below, same
    -- rationale as sections 06 and 14: PL/SQL VARCHAR2 maxes out at
    -- 32767 bytes and the per-dim emit concatenates a short
    -- prefix/suffix around the accumulator, so leave headroom.
    c_json_cap   CONSTANT PLS_INTEGER := 32500;

    -- Per-dimension JSON payloads accumulated while rendering the detail
    -- tables; emitted once at the end as AWR_DATA.fileIo.dims so each
    -- dimension drives its own line chart.  Two parallel breakdowns: one
    -- series per top-N file, one series per file type.
    TYPE t_dim_str  IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(10);
    TYPE t_dim_meta IS TABLE OF VARCHAR2(80)    INDEX BY VARCHAR2(10);
    TYPE t_dim_num  IS TABLE OF NUMBER          INDEX BY VARCHAR2(10);
    v_dim_files_json   t_dim_str;
    v_dim_ftypes_json  t_dim_str;
    v_dim_label        t_dim_meta;
    v_dim_unit         t_dim_meta;
    -- "kept vs total" counters driving the truncation footnote, bumped
    -- exactly like section 14's: total on every cursor row, kept only
    -- when the entry actually fit under c_json_cap.
    v_dim_files_kept    t_dim_num;
    v_dim_files_total   t_dim_num;
    v_dim_ftypes_kept   t_dim_num;
    v_dim_ftypes_total  t_dim_num;
    v_dim               VARCHAR2(10);
    v_first_dim         BOOLEAN;

    @@sql/lib/nth_csv.plsql
    @@sql/lib/json_escape.plsql
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="file-io"><h2>File I/O (top ' || v_top_n
        || ' per dimension, per window)</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || 'Data and temp files with the most I/O per window, from '
        || 'DBA_HIST_FILESTATXS / DBA_HIST_TEMPSTATXS (end snap minus '
        || 'begin snap; blocks scaled to MB by each file''s block size). '
        || 'Chart per dimension: each line = one file across windows, '
        || 'oldest &rarr; current; toggle to the per-file-type view from '
        || 'DBA_HIST_IOSTAT_FILETYPE &mdash; the AWR report''s '
        || '&quot;IOStat by Filetype&quot; &mdash; which covers <b>all</b> '
        || 'database I/O (control file, redo log, archive log, &hellip;), '
        || 'so the two modes'' totals legitimately differ. '
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


    -- Per-dimension detail tables (top-N files), packed into one cursor. --
    v_cur_dim := NULL;
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        -- Datafiles and tempfiles share the view shape but number their
        -- files in separate namespaces, so the source tag is part of the
        -- delta key below.
        file_stats AS (
            SELECT 'data' AS ftag, f.snap_id, f.dbid, f.instance_number,
                   f.file#, f.creation_change#, f.filename, f.tsname,
                   f.block_size, f.phyrds, f.phywrts, f.phyblkrd, f.phyblkwrt
            FROM   dba_hist_filestatxs f
            WHERE  f.dbid IN (~dbid_list)
            UNION ALL
            SELECT 'temp', t.snap_id, t.dbid, t.instance_number,
                   t.file#, t.creation_change#, t.filename, t.tsname,
                   t.block_size, t.phyrds, t.phywrts, t.phyblkrd, t.phyblkwrt
            FROM   dba_hist_tempstatxs t
            WHERE  t.dbid IN (~dbid_list)
        ),
        bounds AS (
            SELECT w.week_offset,
                   CASE WHEN fs.snap_id = w.end_snap_id THEN 1 ELSE -1 END AS sgn,
                   fs.ftag, fs.dbid, fs.instance_number,
                   fs.file#, fs.creation_change#, fs.filename, fs.tsname,
                   NVL(fs.phyrds, 0)    AS phyrds,
                   NVL(fs.phywrts, 0)   AS phywrts,
                   NVL(fs.phyblkrd, 0)  * NVL(fs.block_size, 8192) / 1048576 AS read_mb,
                   NVL(fs.phyblkwrt, 0) * NVL(fs.block_size, 8192) / 1048576 AS write_mb
            FROM   valid_windows w
            JOIN   file_stats fs
                ON fs.dbid = w.dbid
               AND fs.instance_number = w.instance_number
               AND fs.snap_id IN (w.begin_snap_id, w.end_snap_id)
        ),
        -- end minus begin per (instance, physical file); a file missing at
        -- either bound (added/dropped/recreated inside the window) fails
        -- the COUNT(*) = 2 guard and is dropped for that window.
        deltas AS (
            SELECT week_offset, filename,
                   MAX(tsname)        AS tsname,
                   SUM(sgn * phyrds)   AS read_reqs,
                   SUM(sgn * phywrts)  AS write_reqs,
                   SUM(sgn * read_mb)  AS read_mb,
                   SUM(sgn * write_mb) AS write_mb
            FROM   bounds
            GROUP BY week_offset, ftag, dbid, instance_number,
                     file#, creation_change#, filename
            HAVING COUNT(*) = 2
        ),
        -- Group by FILENAME: one row per logical file per window across
        -- RAC instances and across a DBID change.
        agg AS (
            SELECT week_offset, filename,
                   MAX(tsname)     AS tsname,
                   SUM(read_mb)    AS read_mb,
                   SUM(write_mb)   AS write_mb,
                   SUM(read_reqs)  AS read_reqs,
                   SUM(write_reqs) AS write_reqs
            FROM   deltas
            GROUP BY week_offset, filename
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_mb DESC, filename)    AS r_rmb,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_mb DESC, filename)   AS r_wmb,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_reqs DESC, filename)  AS r_rr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_reqs DESC, filename) AS r_wr
            FROM   agg a
        ),
        picked AS (
            SELECT 'READMB' AS dim, week_offset, filename, tsname,
                   read_mb AS metric_value, r_rmb AS rnk
            FROM ranked WHERE r_rmb <= (SELECT top_n FROM run_params) AND read_mb > 0
            UNION ALL
            SELECT 'WRITEMB', week_offset, filename, tsname, write_mb, r_wmb
            FROM ranked WHERE r_wmb <= (SELECT top_n FROM run_params) AND write_mb > 0
            UNION ALL
            SELECT 'RREQ', week_offset, filename, tsname, read_reqs, r_rr
            FROM ranked WHERE r_rr <= (SELECT top_n FROM run_params) AND read_reqs > 0
            UNION ALL
            SELECT 'WREQ', week_offset, filename, tsname, write_reqs, r_wr
            FROM ranked WHERE r_wr <= (SELECT top_n FROM run_params) AND write_reqs > 0
        ),
        dims AS (
            SELECT 'READMB' code, 1 ord, 'By data read (MB)' label, 'MB' unit FROM dual UNION ALL
            SELECT 'WRITEMB', 2,    'By data written (MB)',         'MB'      FROM dual UNION ALL
            SELECT 'RREQ',    3,    'By read requests',             'reqs'    FROM dual UNION ALL
            SELECT 'WREQ',    4,    'By write requests',            'reqs'    FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        files AS (
            SELECT dim, filename, MAX(tsname) AS tsname
            FROM   picked
            GROUP BY dim, filename
        ),
        grid AS (
            SELECT q.dim, q.filename, q.tsname,
                   w.week_offset, p.metric_value, p.rnk
            FROM   files q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.filename = q.filename
                  AND p.week_offset = w.week_offset
        ),
        per_file AS (
            SELECT dim, filename,
                   MAX(tsname) AS tsname,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END) AS cur_val,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)          AS cur_rnk,
                   MIN(rnk) AS best_rank,
                   MAX(metric_value) AS best_value,
                   -- ','||token + SUBSTR: LISTAGG drops NULL measures (and
                   -- their delimiter), which would left-compact the CSV and
                   -- misalign the positional slots; ','||NULL = ',' keeps
                   -- the empty slot.
                   SUBSTR(LISTAGG(',' || RTRIM(TO_CHAR(ROUND(metric_value, 1),
                                               'FM99999999999999990D9',
                                               'NLS_NUMERIC_CHARACTERS=''.,'''), '.'))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals,
                   SUBSTR(LISTAGG(',' || TO_CHAR(rnk))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_rnks
            FROM   grid
            GROUP BY dim, filename
        )
        SELECT d.code AS dim, d.ord AS dim_ord, d.label AS dim_label,
               d.unit AS dim_unit,
               pf.filename, pf.tsname,
               SUBSTR(pf.filename,
                      GREATEST(INSTR(pf.filename, '/', -1),
                               INSTR(pf.filename, '\', -1)) + 1) AS file_short,
               pf.cur_val, pf.cur_rnk, pf.week_vals, pf.week_rnks
        FROM   dims d
        JOIN   per_file pf ON pf.dim = d.code
        ORDER BY d.ord,
            CASE WHEN pf.cur_rnk IS NULL THEN 1 ELSE 0 END,
            pf.cur_rnk NULLS LAST,
            pf.best_rank,
            pf.best_value DESC,
            pf.filename
    ) LOOP
        IF v_cur_dim IS NULL OR v_cur_dim <> s.dim THEN
            IF v_cur_dim IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
            END IF;
            v_cur_dim := s.dim;
            v_dim_label(s.dim)        := s.dim_label;
            v_dim_unit(s.dim)         := s.dim_unit;
            v_dim_files_json(s.dim)   := NULL;
            v_dim_files_kept(s.dim)   := 0;
            v_dim_files_total(s.dim)  := 0;
            v_dim_ftypes_kept(s.dim)  := 0;
            v_dim_ftypes_total(s.dim) := 0;

            DBMS_OUTPUT.PUT_LINE('<h3>' || s.dim_label || '</h3>');
            DBMS_OUTPUT.PUT_LINE('<div class="topsql-toggle" data-fileio-target="' || s.dim || '">'
                || '<span>Break down by:</span>'
                || '<button type="button" data-mode="files" class="active">File</button>'
                || '<button type="button" data-mode="ftypes">File type</button>'
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="fileio-chart-'
                || s.dim || '"></div>');

            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>Detail table</summary>');

            v_header := '<thead><tr><th>File</th><th>Tablespace</th>'
                || '<th class="num">Current (' || s.dim_unit || ')</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                v_header := v_header || '<th class="num">&minus;'
                    || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
            END LOOP;
            v_header := v_header || '</tr></thead>';
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
        END IF;

        -- Build oldest->newest values array for this file (chart series).
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
        v_new_entry := '{"name":"' || json_escape(s.file_short)
            || '","cur":' || NVL(TO_CHAR(s.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        v_dim_files_total(s.dim) := v_dim_files_total(s.dim) + 1;
        IF v_dim_files_json(s.dim) IS NULL THEN
            v_dim_files_json(s.dim) := v_new_entry;
            v_dim_files_kept(s.dim) := v_dim_files_kept(s.dim) + 1;
        ELSIF LENGTH(v_dim_files_json(s.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_files_json(s.dim) :=
                v_dim_files_json(s.dim) || ',' || v_new_entry;
            v_dim_files_kept(s.dim) := v_dim_files_kept(s.dim) + 1;
        END IF;

        v_row := '<tr>'
            || '<td class="mono"><span title="'
            || DBMS_XMLGEN.CONVERT(s.filename) || '">'
            || DBMS_XMLGEN.CONVERT(s.file_short) || '</span></td>'
            || '<td>' || DBMS_XMLGEN.CONVERT(NVL(s.tsname, '(unknown)')) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN s.cur_val IS NULL THEN '&mdash;'
                     ELSE RTRIM(TO_CHAR(s.cur_val, 'FM999G999G999G999G990D9',
                                'NLS_NUMERIC_CHARACTERS=''.,'''), '.') END
            || CASE WHEN s.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || s.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(s.week_vals, k + 1);
            v_rnk_s := nth_csv(s.week_rnks, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990D9',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || RTRIM(TO_CHAR(v_val, 'FM999G999G999G999G990D9',
                               'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
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
            || 'No per-file I/O recorded for any compared window '
            || '(DBA_HIST_FILESTATXS empty for these snapshots, or no valid '
            || 'windows).</p>');
    END IF;

    -- Second pass: per-file-type breakdown for the chart toggle, straight
    -- from DBA_HIST_IOSTAT_FILETYPE (small + large I/O summed per type).
    -- Unlike section 14's chart-only rollup, this one ALSO emits a single
    -- combined detail table at the end, because the file-type numbers are
    -- not derivable from the per-file tables (different source view) and
    -- the offline report must still carry every number.
    FOR tc IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        ft_bounds AS (
            SELECT w.week_offset,
                   CASE WHEN f.snap_id = w.end_snap_id THEN 1 ELSE -1 END AS sgn,
                   f.dbid, f.instance_number, f.filetype_id, f.filetype_name,
                   NVL(f.small_read_megabytes, 0)
                       + NVL(f.large_read_megabytes, 0)  AS read_mb,
                   NVL(f.small_write_megabytes, 0)
                       + NVL(f.large_write_megabytes, 0) AS write_mb,
                   NVL(f.small_read_reqs, 0)
                       + NVL(f.large_read_reqs, 0)       AS read_reqs,
                   NVL(f.small_write_reqs, 0)
                       + NVL(f.large_write_reqs, 0)      AS write_reqs
            FROM   valid_windows w
            JOIN   dba_hist_iostat_filetype f
                ON f.dbid = w.dbid
               AND f.instance_number = w.instance_number
               AND f.snap_id IN (w.begin_snap_id, w.end_snap_id)
        ),
        ft_deltas AS (
            SELECT week_offset, filetype_name,
                   SUM(sgn * read_mb)    AS read_mb,
                   SUM(sgn * write_mb)   AS write_mb,
                   SUM(sgn * read_reqs)  AS read_reqs,
                   SUM(sgn * write_reqs) AS write_reqs
            FROM   ft_bounds
            GROUP BY week_offset, dbid, instance_number,
                     filetype_id, filetype_name
            HAVING COUNT(*) = 2
        ),
        agg AS (
            SELECT week_offset, filetype_name,
                   SUM(read_mb)    AS read_mb,
                   SUM(write_mb)   AS write_mb,
                   SUM(read_reqs)  AS read_reqs,
                   SUM(write_reqs) AS write_reqs
            FROM   ft_deltas
            GROUP BY week_offset, filetype_name
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_mb DESC, filetype_name)    AS r_rmb,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_mb DESC, filetype_name)   AS r_wmb,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY read_reqs DESC, filetype_name)  AS r_rr,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY write_reqs DESC, filetype_name) AS r_wr
            FROM   agg a
        ),
        picked AS (
            SELECT 'READMB' AS dim, week_offset, filetype_name,
                   read_mb AS metric_value, r_rmb AS rnk
            FROM ranked WHERE r_rmb <= (SELECT top_n FROM run_params) AND read_mb > 0
            UNION ALL
            SELECT 'WRITEMB', week_offset, filetype_name, write_mb, r_wmb
            FROM ranked WHERE r_wmb <= (SELECT top_n FROM run_params) AND write_mb > 0
            UNION ALL
            SELECT 'RREQ', week_offset, filetype_name, read_reqs, r_rr
            FROM ranked WHERE r_rr <= (SELECT top_n FROM run_params) AND read_reqs > 0
            UNION ALL
            SELECT 'WREQ', week_offset, filetype_name, write_reqs, r_wr
            FROM ranked WHERE r_wr <= (SELECT top_n FROM run_params) AND write_reqs > 0
        ),
        dims AS (
            SELECT 'READMB' code, 1 ord, 'Data read (MB)' label, 'MB' unit FROM dual UNION ALL
            SELECT 'WRITEMB', 2,    'Data written (MB)',         'MB'      FROM dual UNION ALL
            SELECT 'RREQ',    3,    'Read requests',             'reqs'    FROM dual UNION ALL
            SELECT 'WREQ',    4,    'Write requests',            'reqs'    FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        ftypes AS (
            SELECT DISTINCT dim, filetype_name FROM picked
        ),
        grid AS (
            SELECT q.dim, q.filetype_name, w.week_offset, p.metric_value, p.rnk
            FROM   ftypes q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.filetype_name = q.filetype_name
                  AND p.week_offset = w.week_offset
        ),
        per_type AS (
            SELECT dim, filetype_name,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END) AS cur_val,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)          AS cur_rnk,
                   MIN(rnk)          AS best_rank,
                   MAX(metric_value) AS best_value,
                   -- ','||token + SUBSTR: keeps empty slots (see per_file).
                   SUBSTR(LISTAGG(',' || RTRIM(TO_CHAR(ROUND(metric_value, 1),
                                               'FM99999999999999990D9',
                                               'NLS_NUMERIC_CHARACTERS=''.,'''), '.'))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_vals,
                   SUBSTR(LISTAGG(',' || TO_CHAR(rnk))
                       WITHIN GROUP (ORDER BY week_offset ASC), 2) AS week_rnks
            FROM   grid
            GROUP BY dim, filetype_name
        )
        SELECT d.code AS dim, d.label AS dim_label, d.unit AS dim_unit,
               pt.filetype_name, pt.cur_val, pt.cur_rnk,
               pt.week_vals, pt.week_rnks
        FROM   dims d
        JOIN   per_type pt ON pt.dim = d.code
        ORDER BY d.ord,
            CASE WHEN pt.cur_rnk IS NULL THEN 1 ELSE 0 END,
            pt.cur_rnk NULLS LAST,
            pt.best_rank,
            pt.best_value DESC,
            pt.filetype_name
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
        v_new_entry := '{"name":"' || json_escape(tc.filetype_name)
            || '","cur":' || NVL(TO_CHAR(tc.cur_rnk), 'null')
            || ',"vals":[' || v_chart_vals || ']}';
        -- Defensive init: a dim with file-type rows but no top-N files
        -- would skip the file loop's per-dim init. Treat as zeroed.
        IF NOT v_dim_ftypes_total.EXISTS(tc.dim) THEN
            v_dim_ftypes_total(tc.dim) := 0;
            v_dim_ftypes_kept(tc.dim)  := 0;
        END IF;
        v_dim_ftypes_total(tc.dim) := v_dim_ftypes_total(tc.dim) + 1;
        IF NOT v_dim_ftypes_json.EXISTS(tc.dim)
           OR v_dim_ftypes_json(tc.dim) IS NULL THEN
            v_dim_ftypes_json(tc.dim) := v_new_entry;
            v_dim_ftypes_kept(tc.dim) := v_dim_ftypes_kept(tc.dim) + 1;
        ELSIF LENGTH(v_dim_ftypes_json(tc.dim)) + LENGTH(v_new_entry) + 1
              <= c_json_cap THEN
            v_dim_ftypes_json(tc.dim) :=
                v_dim_ftypes_json(tc.dim) || ',' || v_new_entry;
            v_dim_ftypes_kept(tc.dim) := v_dim_ftypes_kept(tc.dim) + 1;
        END IF;

        -- Combined file-type detail table, opened lazily on the first row.
        IF NOT v_ft_table THEN
            v_ft_table := TRUE;
            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>I/O by file type &mdash; detail table'
                || ' (all four dimensions)</summary>');
            v_header := '<thead><tr><th>Metric</th><th>File type</th>'
                || '<th class="num">Current</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                v_header := v_header || '<th class="num">&minus;'
                    || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
            END LOOP;
            v_header := v_header || '</tr></thead>';
            DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');
        END IF;

        v_row := '<tr>'
            || '<td>' || tc.dim_label || '</td>'
            || '<td class="mono">' || DBMS_XMLGEN.CONVERT(tc.filetype_name) || '</td>'
            || '<td class="num"><b>' ||
                CASE WHEN tc.cur_val IS NULL THEN '&mdash;'
                     ELSE RTRIM(TO_CHAR(tc.cur_val, 'FM999G999G999G999G990D9',
                                'NLS_NUMERIC_CHARACTERS=''.,'''), '.') END
            || CASE WHEN tc.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || tc.cur_rnk || '</span>' ELSE '' END
            || '</b></td>';

        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := nth_csv(tc.week_vals, k + 1);
            v_rnk_s := nth_csv(tc.week_rnks, k + 1);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_row := v_row || '<td class="num">&mdash;';
            ELSE
                v_val := TO_NUMBER(v_val_s, 'FM99999999999999990D9',
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_row := v_row || '<td class="num">'
                      || RTRIM(TO_CHAR(v_val, 'FM999G999G999G999G990D9',
                               'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
            END IF;
            IF v_rnk_s IS NOT NULL AND v_rnk_s <> '' THEN
                v_row := v_row || ' <span class="badge skip">#' || v_rnk_s || '</span>';
            END IF;
            v_row := v_row || '</td>';
        END LOOP;

        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    IF v_ft_table THEN
        DBMS_OUTPUT.PUT_LINE('</tbody></table></details>');
    END IF;

    -- One ECharts line chart per dimension. Skipped silently when the CDN
    -- is unreachable; the detail tables still carry every value.
    IF v_dim_label.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<script>(function(){');
        DBMS_OUTPUT.PUT_LINE('AWR_DATA.fileIo={weeks:' || v_weeks_json
            || ',weeksIso:' || v_weeks_iso_json
            || ',topN:' || v_top_n || ',dims:{');
        v_first_dim := TRUE;
        v_dim := v_dim_label.FIRST;
        WHILE v_dim IS NOT NULL LOOP
            -- Emit each dim in three PUT_LINE calls so no single concat
            -- ever holds both accumulators at once (same ORA-06502 guard
            -- as sections 06 and 14).
            IF NOT v_first_dim THEN
                DBMS_OUTPUT.PUT_LINE(',');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"' || v_dim || '":{"label":"' || v_dim_label(v_dim)
                || '","unit":"' || v_dim_unit(v_dim)
                || '","filesKept":' || NVL(TO_CHAR(v_dim_files_kept(v_dim)), '0')
                || ',"filesTotal":' || NVL(TO_CHAR(v_dim_files_total(v_dim)), '0')
                || ',"ftypesKept":'
                    || CASE WHEN v_dim_ftypes_kept.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_ftypes_kept(v_dim))
                            ELSE '0' END
                || ',"ftypesTotal":'
                    || CASE WHEN v_dim_ftypes_total.EXISTS(v_dim)
                            THEN TO_CHAR(v_dim_ftypes_total(v_dim))
                            ELSE '0' END
                || ',');
            DBMS_OUTPUT.PUT_LINE(
                '"files":[' || NVL(v_dim_files_json(v_dim), '') || '],');
            DBMS_OUTPUT.PUT_LINE(
                '"ftypes":[' ||
                    CASE WHEN v_dim_ftypes_json.EXISTS(v_dim)
                         THEN NVL(v_dim_ftypes_json(v_dim), '') ELSE '' END
                || ']}');
            v_first_dim := FALSE;
            v_dim := v_dim_label.NEXT(v_dim);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('}};');
        -- Truncation footnote when c_json_cap clamped either accumulator;
        -- runs before the echarts guard so it shows offline too.
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.fileIo.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("fileio-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.fileIo.dims[dim]; var bits=[];');
        DBMS_OUTPUT.PUT_LINE('  if(d.filesKept<d.filesTotal){ bits.push("first "+d.filesKept+" of "+d.filesTotal+" files"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.ftypesKept<d.ftypesTotal){ bits.push("first "+d.ftypesKept+" of "+d.ftypesTotal+" file types"); }');
        DBMS_OUTPUT.PUT_LINE('  if(!bits.length) return;');
        DBMS_OUTPUT.PUT_LINE('  var note=document.createElement("p");');
        DBMS_OUTPUT.PUT_LINE('  note.className="trunc-note";');
        DBMS_OUTPUT.PUT_LINE('  note.style.cssText="font-size:11px;color:var(--muted);margin:-2px 0 6px;font-style:italic";');
        DBMS_OUTPUT.PUT_LINE('  note.textContent="Chart truncated to fit the 32 KB per-dimension JSON budget: showing "+bits.join(", ")+". The detail tables below carry every value.";');
        DBMS_OUTPUT.PUT_LINE('  el.parentNode.insertBefore(note, el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
        DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
        DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
        DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
        DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
        DBMS_OUTPUT.PUT_LINE('var fmt=function(v){return v==null?"—":(+v).toLocaleString(undefined,{maximumFractionDigits:1});};');
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.fileIo.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("fileio-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.fileIo.dims[dim];');
        DBMS_OUTPUT.PUT_LINE('  var weeks=AWR_DATA.fileIo.weeks;');
        DBMS_OUTPUT.PUT_LINE('  var mark=window.AWR_markLine&&window.AWR_markLine(weeks,AWR_DATA.fileIo.weeksIso);');
        DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
        DBMS_OUTPUT.PUT_LINE('  function render(mode){');
        DBMS_OUTPUT.PUT_LINE('    var rows=(mode==="ftypes"?d.ftypes:d.files)||[];');
        DBMS_OUTPUT.PUT_LINE('    chart.setOption({');
        DBMS_OUTPUT.PUT_LINE('      tooltip:{trigger:"axis",axisPointer:{type:"line"},formatter:function(ps){var hdr="<b>"+ps[0].axisValue+"</b>";var rs=ps.filter(function(p){return p.value!=null;}).sort(function(a,b){return (b.value||0)-(a.value||0);}).map(function(p){return p.marker+" "+p.seriesName+": <b>"+fmt(p.value)+" "+d.unit+"</b>";}).join("<br/>");return hdr+"<br/>"+rs;}},');
        DBMS_OUTPUT.PUT_LINE('      legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
        DBMS_OUTPUT.PUT_LINE('      grid:{left:50,right:110,top:10,bottom:44,containLabel:true},');
        DBMS_OUTPUT.PUT_LINE('      xAxis:{type:"category",data:weeks,axisLabel:{color:fg,fontWeight:600},splitLine:{show:true,lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      yAxis:{type:"value",name:d.unit,nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (+v).toLocaleString(undefined,{maximumFractionDigits:1});}},splitLine:{lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      series:rows.map(function(s,i){var o={name:s.name,type:"line",connectNulls:false,showSymbol:true,symbolSize:6,itemStyle:{color:palette[i%palette.length]},lineStyle:{width:2},emphasis:{focus:"series",lineStyle:{width:3}},endLabel:{show:true,formatter:"{a}",color:fg,fontSize:10,distance:6},data:s.vals};if(i===0&&mark)o.markLine=mark;return o;})');
        DBMS_OUTPUT.PUT_LINE('    }, true);');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  render("files");');
        DBMS_OUTPUT.PUT_LINE('  var toggle=document.querySelector(''[data-fileio-target="''+dim+''"]'');');
        DBMS_OUTPUT.PUT_LINE('  if(toggle){');
        DBMS_OUTPUT.PUT_LINE('    if(!d.ftypes || !d.ftypes.length){');
        DBMS_OUTPUT.PUT_LINE('      var tb=toggle.querySelector(''[data-mode="ftypes"]'');');
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

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 15_file_io END -->'); END;
/
