--
-- 17_narrative.sql
-- "What changed" narrative: 2-5 auto-generated plain-English sentences that
-- JOIN findings across sections (I/O <-> file <-> segment <-> SQL, DB time
-- vs DB CPU, throughput ratios, configuration drift, baseline health) so
-- the reader gets the story, not just the numbers.
--
-- Placement.  The narrative belongs directly under the masthead verdict,
-- but it needs data that only becomes cheap to collect once the whole
-- report has run (top files, top segments, top SQL, parameter drift), and
-- it must not depend on any other section's PL/SQL state ("findings are
-- recomputed, not shared").  So the section runs LAST, emits its block
-- into the document flow, and a tiny inline script relocates the node into
-- the empty <div id="narrative-slot"> that 00_params.sql emitted in the
-- masthead.  The block ships with the `hidden` attribute and the script
-- clears it after the move, so a mid-page flash is impossible.  With
-- JavaScript disabled the block simply stays hidden -- acceptable: every
-- statement it makes is derived from numbers that are also rendered in the
-- sections it links to, so nothing is lost.  (A <noscript> fallback would
-- have to duplicate the markup in a place the layout does not want it.)
--
-- Rules (each is a separate cheap SELECT; each emits 0 or 1 <p>):
--   R1  physical reads moved LARGE  -> ratio + the file / segment / SQL it
--                                      landed on
--   R5  DB time moved LARGE up      -> wait-bound vs CPU-bound
--   R2  bytes-to-client vs user calls, redo vs commits -> per-call /
--                                      per-commit payload grew or shrank
--   R3  init parameters differing inside the baseline
--   R4  invalid (skipped) prior windows -> the baseline is thin
--   R6  SQL Monitor: statements with a plan change in the Current window
--                                      -> #sqlmon
--   R7  SQL Monitor: statements with a DOP downgrade in the Current window
--                                      -> #sqlmon
--   R8  SQL Monitor: DONE (ERROR) executions in the Current window
--                                      -> #sqlmon
--   R9  SQL Monitor: sql_ids first seen in the Current window
--                                      -> #sqlmon
--   R10 SQL Monitor: plan-line drift lede for the top regressed statement
--                     (opt-in, sqlmon_detail>0 only; emits nothing at 0)
--                                      -> #sqlmon
-- Emitted in the order R1, R5, R2, R3, R4, R6, R7, R8, R9, R10.
--
-- "LARGE" mirrors section 07's `scored` CASE (recomputed here, not shared,
-- for the handful of stats used below): |z| > 3 against the prior valid
-- windows; when the baseline sigma is degenerate (sd = 0 or below 1% of
-- the mean) z is meaningless, so a 2x ratio test stands in.
--
-- R6-R9 recompute their own bounded DBA_HIST_REPORTS scan (component_name =
-- 'sqlmonitor', dbid IN (dbid_list), span bounded by the earliest compared
-- window's start through target_end) rather than sharing section 18's PL/SQL
-- state -- same "findings are recomputed, not shared" convention as R1-R5.
--
-- R10 additionally reads exactly ONE pair of DBA_HIST_REPORTS_DETAILS CLOBs
-- (the same top candidate section 18's phase 2 would rank first) when
-- sqlmon_detail>0, to state the single biggest plan-line mover; at
-- sqlmon_detail=0 no such query runs at all, so the narrative -- and the
-- whole report -- is byte-identical to a run without the feature.
--
-- Nothing to say => the section emits ONLY its two AWR-SECTION markers:
-- no <div>, no <script>.
--
-- Read-only.  Every query is bounded by the resolved window snap ids from
-- sql/lib/windows_cte.sql and filtered with dbid IN (dbid_list), so no
-- full-history scan is ever issued.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 17_narrative BEGIN -->'); END;
/

DECLARE
    TYPE stat_rec IS RECORD (
        cur NUMBER,
        mu  NUMBER,
        sd  NUMBER,
        n   NUMBER
    );
    TYPE stats_t IS TABLE OF stat_rec INDEX BY VARCHAR2(64);
    TYPE sent_t  IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;

    v_stats  stats_t;
    v_sent   sent_t;
    v_n      PLS_INTEGER := 0;
    v_top_n  NUMBER := ~top_n;

    v_txt    VARCHAR2(32767);
    v_tail   VARCHAR2(32767);
    v_r      stat_rec;

    -- R1 detail carriers
    v_file      VARCHAR2(600);
    v_file_cur  NUMBER;
    v_file_mu   NUMBER;
    v_seg       VARCHAR2(600);
    v_sqlid     VARCHAR2(13);

    -- R3 / R4 carriers
    v_p_names   VARCHAR2(4000);
    v_p_shown   PLS_INTEGER := 0;
    v_p_total   PLS_INTEGER := 0;

    ------------------------------------------------------------------
    -- Formatting helpers
    ------------------------------------------------------------------

    -- 3 significant digits, dot decimal regardless of client NLS.
    FUNCTION fmt3(p NUMBER) RETURN VARCHAR2 IS
        v NUMBER;
    BEGIN
        IF p IS NULL THEN RETURN '&mdash;'; END IF;
        IF p = 0     THEN RETURN '0';       END IF;
        v := ROUND(p, 2 - FLOOR(LOG(10, ABS(p))));
        RETURN TO_CHAR(v, 'FM999G999G999G990D999999',
                       'NLS_NUMERIC_CHARACTERS=''.,''');
    END fmt3;

    -- Direction glyph only; no color class (severity color stays on badges).
    FUNCTION dirg(p_up BOOLEAN) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p_up THEN '&#9650;' ELSE '&#9660;' END;
    END dirg;

    -- Compact offset label for prior window k, e.g. "-1h" / "-2w".
    FUNCTION off_lbl(p_k NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN '&minus;' || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, p_k);
    END off_lbl;

    FUNCTION esc(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_XMLGEN.CONVERT(p);
    END esc;

    PROCEDURE add_sentence(p VARCHAR2) IS
    BEGIN
        v_n := v_n + 1;
        v_sent(v_n) := p;
    END add_sentence;

    ------------------------------------------------------------------
    -- Scoring helpers over v_stats (section 07's rules, recomputed)
    ------------------------------------------------------------------
    FUNCTION has(p VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF NOT v_stats.EXISTS(p) THEN RETURN FALSE; END IF;
        RETURN v_stats(p).cur IS NOT NULL AND v_stats(p).mu IS NOT NULL;
    END has;

    -- Percent delta of the current window vs the prior-window mean.
    FUNCTION pctd(p VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF NOT has(p)          THEN RETURN NULL; END IF;
        IF v_stats(p).mu = 0   THEN RETURN NULL; END IF;
        RETURN (v_stats(p).cur - v_stats(p).mu) / ABS(v_stats(p).mu) * 100;
    END pctd;

    -- Current / prior-mean ratio (NULL when the baseline mean is zero).
    FUNCTION ratio(p VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF NOT has(p)        THEN RETURN NULL; END IF;
        IF v_stats(p).mu = 0 THEN RETURN NULL; END IF;
        RETURN v_stats(p).cur / v_stats(p).mu;
    END ratio;

    -- "LARGE": section 07's |z| > 3, with a 2x ratio stand-in when the
    -- baseline sigma is degenerate and z would be meaningless / infinite.
    FUNCTION big(p VARCHAR2) RETURN BOOLEAN IS
        r stat_rec;
    BEGIN
        IF NOT has(p) THEN RETURN FALSE; END IF;
        r := v_stats(p);
        IF r.n IS NULL OR r.n < 3 THEN RETURN FALSE; END IF;
        IF r.sd IS NOT NULL AND r.sd > 0 AND r.sd >= 0.01 * ABS(r.mu) THEN
            RETURN ABS((r.cur - r.mu) / r.sd) > 3;
        END IF;
        IF r.mu  = 0 THEN RETURN r.cur <> 0; END IF;
        IF r.cur = 0 THEN RETURN TRUE;       END IF;
        RETURN GREATEST(r.cur / r.mu, r.mu / r.cur) >= 2;
    END big;

    FUNCTION went_up(p VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN has(p) AND v_stats(p).cur >= v_stats(p).mu;
    END went_up;

    -- "<b>Name</b> [glyph] xN.NN (mu -> cur unit)" -- the shared lede shape
    -- for a stat that moved, degrading to a plain arrow when the baseline
    -- mean is zero (no meaningful ratio).
    FUNCTION lede(p_label VARCHAR2, p_stat VARCHAR2, p_unit VARCHAR2,
                  p_scale NUMBER DEFAULT 1) RETURN VARCHAR2 IS
        v_ratio NUMBER := ratio(p_stat);
        v_up    BOOLEAN := went_up(p_stat);
    BEGIN
        RETURN '<b>' || p_label || '</b> ' || dirg(v_up)
            || CASE WHEN v_ratio IS NULL THEN ''
                    ELSE ' &times;' || fmt3(v_ratio) END
            || ' (' || fmt3(v_stats(p_stat).mu * p_scale)
            || ' &rarr; ' || fmt3(v_stats(p_stat).cur * p_scale)
            || ' ' || p_unit || ').';
    END lede;
BEGIN
    ------------------------------------------------------------------
    -- One scan for every SYSSTAT counter the rules below need.  Same
    -- pairs -> bounds -> deltas shape as sql/02_load_profile.sql (these
    -- views carry no *_DELTA columns), then pivoted to cur / mu / sd / n
    -- exactly like section 07's `pivoted`.  The stat list is hardcoded on
    -- purpose: the narrative is template-independent, so it must NOT pull
    -- the template's sysstat_load_targets.sql.
    ------------------------------------------------------------------
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        narr_targets AS (
            SELECT 'physical reads'                   AS stat_name FROM dual UNION ALL
            SELECT 'bytes sent via SQL*Net to client'              FROM dual UNION ALL
            SELECT 'user calls'                                    FROM dual UNION ALL
            SELECT 'redo size'                                     FROM dual UNION ALL
            SELECT 'user commits'                                  FROM dual
        ),
        narr_pairs AS (
            SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
                   ss.snap_id, ss.value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sysstat ss
                ON ss.dbid = w.dbid
               AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND ss.instance_number = w.instance_number
               AND ss.stat_name IN (SELECT stat_name FROM narr_targets)
        ),
        narr_bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   narr_pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        -- DB time / DB CPU are TIME MODEL statistics, not SYSSTAT ones:
        -- v$sysstat has no 'DB CPU' row at all, so R5 has to read
        -- DBA_HIST_SYS_TIME_MODEL.  Same cumulative pairs -> bounds ->
        -- deltas shape; values are MICROseconds.  They are keyed with a
        -- 'TM:' prefix below so the SYSSTAT namespace stays clean.
        tm_pairs AS (
            SELECT w.week_offset, w.dur_sec, tm.stat_name, tm.instance_number,
                   tm.snap_id, tm.value, w.begin_snap_id, w.end_snap_id
            FROM   valid_windows w
            JOIN   dba_hist_sys_time_model tm
                ON tm.dbid = w.dbid
               AND tm.snap_id IN (w.begin_snap_id, w.end_snap_id)
               AND tm.instance_number = w.instance_number
               AND tm.stat_name IN ('DB time', 'DB CPU')
        ),
        tm_bounds AS (
            SELECT week_offset, dur_sec, stat_name, instance_number,
                   SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
                   SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
            FROM   tm_pairs
            GROUP BY week_offset, dur_sec, stat_name, instance_number
        ),
        narr_rows AS (
            -- Cross-instance delta over ONE window span (MAX(dur_sec)), with
            -- dur_sec out of the second-level GROUP BY -- the RAC-safe divisor
            -- convention used by sections 02 / 07 / 08.
            SELECT stat_name, week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END AS metric_value
            FROM   narr_bounds
            GROUP BY week_offset, stat_name
            UNION ALL
            SELECT 'TM:' || stat_name, week_offset,
                   CASE WHEN MAX(dur_sec) > 0
                        THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
                   END
            FROM   tm_bounds
            GROUP BY week_offset, stat_name
        )
        SELECT stat_name,
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)    AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END)  AS n
        FROM   narr_rows
        WHERE  metric_value IS NOT NULL
        GROUP BY stat_name
    ) LOOP
        v_r.cur := r.cur_val;
        v_r.mu  := r.mu;
        v_r.sd  := r.sd;
        v_r.n   := r.n;
        v_stats(r.stat_name) := v_r;
    END LOOP;

    ------------------------------------------------------------------
    -- R1: physical reads moved LARGE.  Join the finding down to the file,
    -- the segment and (if any) the SQL that is new in the current top-N.
    ------------------------------------------------------------------
    IF big('physical reads') THEN
        v_txt := lede('Physical reads', 'physical reads', '/s');

        -- Top data/temp file by MB read in the CURRENT window, with the
        -- prior-window mean for the same file (same delta shape as 15).
        BEGIN
            FOR f IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                nf_stats AS (
                    SELECT 'data' AS ftag, f.snap_id, f.dbid, f.instance_number,
                           f.file#, f.creation_change#, f.filename,
                           f.block_size, f.phyblkrd
                    FROM   dba_hist_filestatxs f
                    WHERE  f.dbid IN (~dbid_list)
                    UNION ALL
                    SELECT 'temp', t.snap_id, t.dbid, t.instance_number,
                           t.file#, t.creation_change#, t.filename,
                           t.block_size, t.phyblkrd
                    FROM   dba_hist_tempstatxs t
                    WHERE  t.dbid IN (~dbid_list)
                ),
                nf_bounds AS (
                    SELECT w.week_offset,
                           CASE WHEN fs.snap_id = w.end_snap_id THEN 1 ELSE -1 END AS sgn,
                           fs.ftag, fs.dbid, fs.instance_number,
                           fs.file#, fs.creation_change#, fs.filename,
                           NVL(fs.phyblkrd, 0) * NVL(fs.block_size, 8192) / 1048576 AS read_mb
                    FROM   valid_windows w
                    JOIN   nf_stats fs
                        ON fs.dbid = w.dbid
                       AND fs.instance_number = w.instance_number
                       AND fs.snap_id IN (w.begin_snap_id, w.end_snap_id)
                ),
                nf_deltas AS (
                    SELECT week_offset, filename, SUM(sgn * read_mb) AS read_mb
                    FROM   nf_bounds
                    GROUP BY week_offset, ftag, dbid, instance_number,
                             file#, creation_change#, filename
                    HAVING COUNT(*) = 2
                ),
                nf_agg AS (
                    SELECT week_offset, filename, SUM(read_mb) AS read_mb
                    FROM   nf_deltas
                    GROUP BY week_offset, filename
                ),
                nf_piv AS (
                    SELECT filename,
                           MAX(CASE WHEN week_offset = 0 THEN read_mb END) AS cur_mb,
                           AVG(CASE WHEN week_offset > 0 THEN read_mb END) AS mu_mb
                    FROM   nf_agg
                    GROUP BY filename
                )
                SELECT REGEXP_REPLACE(filename, '^.*[/\]', '') AS short_name,
                       cur_mb, mu_mb
                FROM   nf_piv
                WHERE  cur_mb > 0
                ORDER  BY cur_mb DESC, filename
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_file     := f.short_name;
                v_file_cur := f.cur_mb;
                v_file_mu  := f.mu_mb;
            END LOOP;
        END;

        -- Top segment by physical reads in the CURRENT window (same
        -- deduped name lookup as section 14).
        BEGIN
            FOR g IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                ns_raw AS (
                    SELECT ss.dbid, ss.ts#, ss.obj#, ss.dataobj#,
                           SUM(NVL(ss.physical_reads_delta, 0)) AS phys_reads
                    FROM   valid_windows w
                    JOIN   dba_hist_seg_stat ss
                        ON ss.dbid = w.dbid
                       AND ss.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                       AND ss.instance_number = w.instance_number
                    WHERE  w.week_offset = 0
                    GROUP BY ss.dbid, ss.ts#, ss.obj#, ss.dataobj#
                ),
                ns_names AS (
                    SELECT dbid, ts#, obj#, dataobj#, owner, object_name
                    FROM (
                        SELECT o.dbid, o.ts#, o.obj#, o.dataobj#,
                               o.owner, o.object_name,
                               ROW_NUMBER() OVER (PARTITION BY o.dbid, o.ts#,
                                   o.obj#, o.dataobj# ORDER BY NULL) AS rn
                        FROM   dba_hist_seg_stat_obj o
                        WHERE  o.dbid IN (~dbid_list)
                    ) WHERE rn = 1
                )
                SELECT NVL(o.owner, '(unknown)') || '.'
                           || NVL(o.object_name, 'OBJ#' || TO_CHAR(r.obj#)) AS seg_name,
                       SUM(r.phys_reads) AS phys_reads
                FROM   ns_raw r
                LEFT JOIN ns_names o
                    ON o.dbid     = r.dbid
                   AND o.ts#      = r.ts#
                   AND o.obj#     = r.obj#
                   AND o.dataobj# = r.dataobj#
                GROUP BY NVL(o.owner, '(unknown)') || '.'
                           || NVL(o.object_name, 'OBJ#' || TO_CHAR(r.obj#))
                HAVING SUM(r.phys_reads) > 0
                ORDER  BY SUM(r.phys_reads) DESC, 1
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_seg := g.seg_name;
            END LOOP;
        END;

        -- A SQL_ID in the current window's top-N by physical reads that is
        -- in NO prior window's top-N (a newcomer, not a regular).
        BEGIN
            FOR q IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                nq_agg AS (
                    SELECT w.week_offset, s.sql_id,
                           SUM(NVL(s.disk_reads_delta, 0)) AS disk_reads
                    FROM   valid_windows w
                    JOIN   dba_hist_sqlstat s
                        ON s.dbid = w.dbid
                       AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                       AND s.instance_number = w.instance_number
                    GROUP BY w.week_offset, s.sql_id
                ),
                nq_ranked AS (
                    SELECT week_offset, sql_id, disk_reads,
                           ROW_NUMBER() OVER (PARTITION BY week_offset
                               ORDER BY disk_reads DESC, sql_id) AS rn
                    FROM   nq_agg
                    WHERE  disk_reads > 0
                )
                SELECT c.sql_id
                FROM   nq_ranked c
                WHERE  c.week_offset = 0
                  AND  c.rn <= (SELECT top_n FROM run_params)
                  AND  NOT EXISTS (
                           SELECT 1 FROM nq_ranked p
                           WHERE  p.week_offset > 0
                             AND  p.rn <= (SELECT top_n FROM run_params)
                             AND  p.sql_id = c.sql_id)
                ORDER  BY c.disk_reads DESC, c.sql_id
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_sqlid := q.sql_id;
            END LOOP;
        END;

        v_tail := '';
        IF v_file IS NOT NULL THEN
            v_tail := v_tail || ' The reads land on <a href="#file-io">'
                || esc(v_file) || '</a> ('
                || CASE WHEN v_file_mu IS NULL THEN 'no prior baseline; '
                        ELSE fmt3(v_file_mu) || ' &rarr; ' END
                || fmt3(v_file_cur) || ' MB read this window)';
        END IF;
        IF v_seg IS NOT NULL THEN
            v_tail := v_tail || CASE WHEN v_tail IS NULL THEN ' T' ELSE '; t' END
                || 'op read segment is <a href="#segment-io">' || esc(v_seg) || '</a>';
        END IF;
        IF v_sqlid IS NOT NULL THEN
            v_tail := v_tail || CASE WHEN v_tail IS NULL THEN ' S' ELSE '; S' END
                || 'QL <a href="#sql-' || v_sqlid || '"><code>' || v_sqlid
                || '</code></a> is in the top-' || TO_CHAR(v_top_n)
                || ' by reads only in the current window';
        END IF;
        -- NB: an empty VARCHAR2 IS NULL in Oracle, so the guard must be a
        -- plain IS NOT NULL -- `v_tail <> ''''` evaluates to NULL and the
        -- branch would never be taken.
        IF v_tail IS NOT NULL THEN
            v_txt := v_txt || v_tail || '.';
        END IF;

        add_sentence(v_txt);
    END IF;

    ------------------------------------------------------------------
    -- R5: DB time moved LARGE upward -- is the extra time CPU or wait?
    ------------------------------------------------------------------
    IF big('TM:DB time') AND went_up('TM:DB time') AND has('TM:DB CPU') THEN
        -- Time model values are microseconds/second; dividing by 1e6 renders
        -- them as average active sessions, which is what a DBA reads.
        v_txt := lede('DB time', 'TM:DB time', 'avg active sessions', 1/1000000);
        IF pctd('TM:DB CPU') IS NOT NULL AND ABS(pctd('TM:DB CPU')) < 20 THEN
            v_txt := v_txt || ' DB CPU barely moved ('
                || dirg(pctd('TM:DB CPU') >= 0) || ' '
                || fmt3(ABS(pctd('TM:DB CPU'))) || '%), so the extra DB time is '
                || 'wait, not CPU &mdash; see <a href="#waits-fg">foreground '
                || 'waits</a>.';
        ELSIF pctd('TM:DB CPU') IS NOT NULL THEN
            v_txt := v_txt || ' DB CPU moved with it ('
                || dirg(pctd('TM:DB CPU') >= 0) || ' '
                || fmt3(ABS(pctd('TM:DB CPU'))) || '%): CPU-bound growth.';
        END IF;
        add_sentence(v_txt);
    END IF;

    ------------------------------------------------------------------
    -- R2: throughput ratios.  A payload counter that moves while its call
    -- counter stays flat means the size per call/commit changed, not the
    -- volume of calls.  At most one paragraph; both clauses may appear.
    ------------------------------------------------------------------
    v_txt := '';
    IF pctd('bytes sent via SQL*Net to client') IS NOT NULL
       AND ABS(pctd('bytes sent via SQL*Net to client')) >= 10
       AND pctd('user calls') IS NOT NULL
       AND ABS(pctd('user calls')) <= 3 THEN
        v_txt := '<b>Network bytes to client</b> '
            || dirg(pctd('bytes sent via SQL*Net to client') >= 0) || ' '
            || fmt3(ABS(pctd('bytes sent via SQL*Net to client')))
            || '% with user calls flat ('
            || dirg(pctd('user calls') >= 0) || ' '
            || fmt3(ABS(pctd('user calls'))) || '%), so payload per call '
            || CASE WHEN pctd('bytes sent via SQL*Net to client') >= 0
                    THEN 'grew' ELSE 'shrank' END
            || ', not call volume.';
    END IF;
    IF pctd('redo size') IS NOT NULL
       AND ABS(pctd('redo size')) >= 20
       AND pctd('user commits') IS NOT NULL
       AND ABS(pctd('user commits')) <= 5 THEN
        v_txt := v_txt || CASE WHEN v_txt IS NULL THEN '' ELSE ' ' END
            || '<b>Redo</b> ' || dirg(pctd('redo size') >= 0) || ' '
            || fmt3(ABS(pctd('redo size'))) || '% with commits flat ('
            || dirg(pctd('user commits') >= 0) || ' '
            || fmt3(ABS(pctd('user commits'))) || '%), so redo per commit '
            || CASE WHEN pctd('redo size') >= 0 THEN 'grew' ELSE 'shrank' END
            || ' &mdash; transaction size changed, not transaction count.';
    END IF;
    IF v_txt IS NOT NULL THEN
        add_sentence(v_txt);
    END IF;

    ------------------------------------------------------------------
    -- R3: configuration drift inside the baseline.  Same source as
    -- section 12 (dba_hist_parameter at each window's END snap, one
    -- instance), reduced to "which parameters differ from the current
    -- window, and in which prior windows".
    ------------------------------------------------------------------
    v_p_names := '';
    FOR p IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        np_win AS (
            SELECT week_offset, dbid, end_snap_id
            FROM   windows_rollup
            WHERE  end_snap_id IS NOT NULL
        ),
        np_n AS (
            SELECT COUNT(*) AS cnt FROM np_win
        ),
        np_inst AS (
            SELECT CASE WHEN ~inst_num = 0 THEN MIN(p.instance_number)
                        ELSE ~inst_num END AS inst
            FROM   dba_hist_parameter p
            JOIN   np_win w ON w.end_snap_id = p.snap_id
                           AND w.dbid        = p.dbid
        ),
        np_pv AS (
            -- One value per (window, parameter), taken from the LOWEST con_id
            -- (0 in a non-CDB, the root in a CDB) -- i.e. the instance-level
            -- value a DBA means by "the init parameter".  In a CDB
            -- DBA_HIST_PARAMETER carries one row per container for the same
            -- (dbid, snap_id, instance_number), so a bare join fans out: it
            -- would repeat every window label once per container in the LISTAGG
            -- below AND, worse, invent phantom changes when the arbitrary
            -- per-window pick alternates between the root value and a PDB's.
            -- (Verified on dbmint: sga_target reads 1610612736 in the root and
            -- 0 in both PDBs at EVERY compared snapshot, so it never changed.)
            -- A non-CDB has a single con_id, so this is a no-op there.
            SELECT w.week_offset, p.parameter_name,
                   MAX(p.value) KEEP (DENSE_RANK FIRST
                       ORDER BY p.con_id, p.con_dbid) AS value
            FROM   np_win w
            JOIN   dba_hist_parameter p
              ON   p.dbid = w.dbid
             AND   p.snap_id = w.end_snap_id
             AND   p.instance_number = (SELECT inst FROM np_inst)
            GROUP BY w.week_offset, p.parameter_name
        ),
        np_changed AS (
            SELECT parameter_name
            FROM   np_pv
            GROUP BY parameter_name
            HAVING COUNT(DISTINCT NVL(value, '__NULL__')) > 1
                OR COUNT(*) < (SELECT cnt FROM np_n)
        ),
        np_cur AS (
            SELECT parameter_name, value FROM np_pv WHERE week_offset = 0
        ),
        np_diff AS (
            SELECT c.parameter_name,
                   LISTAGG(TO_CHAR(d.week_offset), ',')
                       WITHIN GROUP (ORDER BY d.week_offset) AS offs,
                   COUNT(*) AS n_diff
            FROM   np_changed c
            JOIN   np_pv d ON d.parameter_name = c.parameter_name
                          AND d.week_offset > 0
            LEFT JOIN np_cur k ON k.parameter_name = c.parameter_name
            WHERE  k.parameter_name IS NULL
               OR  NVL(d.value, '__NULL__') <> NVL(k.value, '__NULL__')
            GROUP BY c.parameter_name
        )
        SELECT parameter_name, offs,
               COUNT(*) OVER () AS n_total
        FROM   np_diff
        ORDER  BY n_diff DESC, parameter_name
        FETCH FIRST 3 ROWS ONLY
    ) LOOP
        v_p_total := p.n_total;
        v_p_shown := v_p_shown + 1;
        v_p_names := v_p_names
            || CASE WHEN v_p_shown = 1 THEN '' ELSE '; ' END
            || '<code>' || esc(p.parameter_name) || '</code> in ';
        -- Map the raw offsets to the report's compact window labels.
        DECLARE
            v_k   PLS_INTEGER := 1;
            v_off VARCHAR2(20);
            v_acc VARCHAR2(400) := '';
        BEGIN
            LOOP
                v_off := REGEXP_SUBSTR(p.offs, '[^,]+', 1, v_k);
                EXIT WHEN v_off IS NULL;
                v_acc := v_acc || CASE WHEN v_k = 1 THEN '' ELSE ', ' END
                      || off_lbl(TO_NUMBER(v_off));
                v_k := v_k + 1;
            END LOOP;
            v_p_names := v_p_names || v_acc;
        END;
    END LOOP;

    IF v_p_shown > 0 THEN
        add_sentence('<b>Configuration differs inside the baseline:</b> '
            || v_p_names
            || CASE WHEN v_p_total > v_p_shown
                    THEN ' (and ' || TO_CHAR(v_p_total - v_p_shown)
                         || ' more)' ELSE '' END
            || '. Treat those windows as a different configuration &mdash; see '
            || '<a href="#param-changes">parameter changes</a>.');
    END IF;

    ------------------------------------------------------------------
    -- R4: baseline health -- how many compared prior windows were skipped.
    ------------------------------------------------------------------
    FOR b IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        nb_prior AS (
            SELECT week_offset, valid_flag, skip_reason
            FROM   windows_rollup
            WHERE  week_offset > 0
        )
        SELECT (SELECT COUNT(*) FROM nb_prior WHERE valid_flag = 'N') AS n_bad,
               (SELECT COUNT(*) FROM nb_prior)                        AS n_all,
               (SELECT skip_reason FROM (
                    SELECT skip_reason
                    FROM   nb_prior
                    WHERE  valid_flag = 'N'
                    GROUP BY skip_reason
                    ORDER BY COUNT(*) DESC, skip_reason
                ) WHERE ROWNUM = 1)                                   AS reason
        FROM dual
    ) LOOP
        IF b.n_bad > 0 THEN
            add_sentence('<b>' || TO_CHAR(b.n_bad) || ' of ' || TO_CHAR(b.n_all)
                || ' prior window' || CASE WHEN b.n_all = 1 THEN '' ELSE 's' END
                || '</b>'
                || CASE WHEN b.n_bad = 1 THEN ' was' ELSE ' were' END
                || ' skipped'
                || CASE WHEN b.reason IS NULL THEN ''
                        ELSE ' (' || esc(b.reason) || ')' END
                || ', so the baseline is thin &mdash; see '
                || '<a href="#windows">compared windows</a>.');
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- R6-R9: SQL Monitor (dba_hist_reports, component_name='sqlmonitor').
    -- Bounded scan: dbid IN (dbid_list), inst_num filter, parsed exec_start
    -- (key3) within [earliest compared window start, target_end). R6-R8
    -- look only at executions that started inside the Current window; R9
    -- compares Current against every prior *valid* window. Recomputed here
    -- rather than shared with section 18's PL/SQL state (see header note).
    ------------------------------------------------------------------
    DECLARE
        v_sm_span_start DATE;
        v_sm_span_end   DATE;
        v_sm_plan_n     PLS_INTEGER := 0;
        v_sm_plan_ids   VARCHAR2(4000) := '';
        v_sm_dop_n      PLS_INTEGER := 0;
        v_sm_err_n      PLS_INTEGER := 0;
        v_sm_new_n      PLS_INTEGER := 0;
        v_sm_new_ids    VARCHAR2(4000) := '';
    BEGIN
        SELECT MIN(win_start_ts), MAX(win_end_ts)
        INTO   v_sm_span_start, v_sm_span_end
        FROM (
            WITH
            @@sql/lib/windows_cte.sql
            SELECT week_offset, win_start_ts, win_end_ts FROM windows_rollup
        );

        -- R6/R7/R8: plan change / DOP downgrade / error, scoped to
        -- executions that started inside the CURRENT window.
        FOR m IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            cur_win AS (
                SELECT win_start_ts, win_end_ts FROM windows_rollup
                WHERE  week_offset = 0 AND valid_flag = 'Y'
            ),
            base AS (
                SELECT r.key1 AS sql_id,
                       TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                       x.status, x.plan_hash, x.px_req, x.px_alloc
                FROM   dba_hist_reports r,
                       XMLTABLE('/report_repository_summary/sql'
                           PASSING XMLTYPE(r.report_summary)
                           COLUMNS
                               status    VARCHAR2(30) PATH 'status',
                               plan_hash NUMBER       PATH 'plan_hash',
                               px_req    NUMBER       PATH 'px_servers_requested',
                               px_alloc  NUMBER       PATH 'px_servers_allocated'
                       ) x
                WHERE  r.component_name = 'sqlmonitor'
                  AND  r.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
                  AND  r.report_summary IS NOT NULL
                  AND  r.key1 IS NOT NULL
                  AND  r.period_start_time >= CAST(v_sm_span_start AS TIMESTAMP) - INTERVAL '1' DAY
                  AND  r.period_start_time <= CAST(v_sm_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_sm_span_start
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_sm_span_end
            ),
            cur_execs AS (
                SELECT b.* FROM base b, cur_win w
                WHERE  b.exec_start >= w.win_start_ts AND b.exec_start < w.win_end_ts
            ),
            plan_counts AS (
                SELECT sql_id,
                       COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) AS n_plans
                FROM   base
                GROUP  BY sql_id
                HAVING COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) > 1
            )
            SELECT
                (SELECT COUNT(*) FROM plan_counts pc
                  WHERE EXISTS (SELECT 1 FROM cur_execs c WHERE c.sql_id = pc.sql_id)) AS plan_n,
                (SELECT LISTAGG(sql_id, ', ') WITHIN GROUP (ORDER BY sql_id) FROM (
                     SELECT DISTINCT pc.sql_id FROM plan_counts pc
                     WHERE EXISTS (SELECT 1 FROM cur_execs c WHERE c.sql_id = pc.sql_id)
                     ORDER BY pc.sql_id FETCH FIRST 3 ROWS ONLY)) AS plan_ids,
                (SELECT COUNT(DISTINCT sql_id) FROM cur_execs WHERE px_alloc < px_req) AS dop_n,
                (SELECT COUNT(*) FROM cur_execs WHERE status = 'DONE (ERROR)') AS err_n
            FROM dual
        ) LOOP
            v_sm_plan_n   := m.plan_n;
            v_sm_plan_ids := m.plan_ids;
            v_sm_dop_n    := m.dop_n;
            v_sm_err_n    := m.err_n;
        END LOOP;

        -- R9: sql_ids with an execution in Current but none in any prior
        -- valid window. No XML parsing needed -- key1/key3 only.
        FOR m IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            base AS (
                SELECT r.key1 AS sql_id,
                       TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start
                FROM   dba_hist_reports r
                WHERE  r.component_name = 'sqlmonitor'
                  AND  r.dbid IN (~dbid_list)
                  AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
                  AND  r.report_summary IS NOT NULL
                  AND  r.key1 IS NOT NULL
                  AND  r.period_start_time >= CAST(v_sm_span_start AS TIMESTAMP) - INTERVAL '1' DAY
                  AND  r.period_start_time <= CAST(v_sm_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_sm_span_start
                  AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_sm_span_end
            ),
            -- "new" = no capture anywhere in the span BEFORE the Current
            -- window starts (same definition as section 18's `new` chip;
            -- "absent from the prior compared windows" would be the
            -- sampling trap the section's caption warns about).
            cur_win AS (
                SELECT win_start_ts, win_end_ts FROM windows_rollup
                WHERE  week_offset = 0 AND valid_flag = 'Y'
            ),
            per_sql AS (
                SELECT b.sql_id,
                       SUM(CASE WHEN b.exec_start >= c.win_start_ts
                                 AND b.exec_start <  c.win_end_ts THEN 1 ELSE 0 END) AS n_cur,
                       SUM(CASE WHEN b.exec_start <  c.win_start_ts THEN 1 ELSE 0 END) AS n_prior
                FROM   base b CROSS JOIN cur_win c
                GROUP BY b.sql_id
            )
            -- Both columns as independent scalar subqueries, not an outer
            -- COUNT(*) alongside one: Oracle raises ORA-00937 on
            -- `SELECT COUNT(*), (SELECT <agg> FROM ...) FROM t` even when the
            -- subquery is uncorrelated -- verified live on dbmint.
            SELECT
                (SELECT COUNT(*) FROM per_sql WHERE n_cur > 0 AND n_prior = 0) AS new_n,
                (SELECT LISTAGG(sql_id, ', ') WITHIN GROUP (ORDER BY sql_id) FROM (
                     SELECT sql_id FROM per_sql WHERE n_cur > 0 AND n_prior = 0
                     ORDER BY sql_id FETCH FIRST 3 ROWS ONLY)) AS new_ids
            FROM   dual
        ) LOOP
            v_sm_new_n   := m.new_n;
            v_sm_new_ids := m.new_ids;
        END LOOP;

        IF v_sm_plan_n > 0 THEN
            add_sentence('<b>' || TO_CHAR(v_sm_plan_n) || ' monitored statement'
                || CASE WHEN v_sm_plan_n = 1 THEN '' ELSE 's' END
                || '</b> ran with more than one execution plan in the compared span, '
                || 'including the Current window: ' || esc(v_sm_plan_ids)
                || CASE WHEN v_sm_plan_n > 3
                        THEN ' (and ' || TO_CHAR(v_sm_plan_n - 3) || ' more)' ELSE '' END
                || ' &mdash; see <a href="#sqlmon">SQL Monitor</a>.');
        END IF;

        IF v_sm_dop_n > 0 THEN
            add_sentence('<b>' || TO_CHAR(v_sm_dop_n) || ' statement'
                || CASE WHEN v_sm_dop_n = 1 THEN '' ELSE 's' END
                || '</b> got fewer parallel servers than requested in the Current window '
                || '(DOP downgrade) &mdash; see <a href="#sqlmon">SQL Monitor</a>.');
        END IF;

        IF v_sm_err_n > 0 THEN
            add_sentence('<b>' || TO_CHAR(v_sm_err_n) || ' SQL Monitor execution'
                || CASE WHEN v_sm_err_n = 1 THEN '' ELSE 's' END
                || '</b> ended <code>DONE (ERROR)</code> in the Current window &mdash; see '
                || '<a href="#sqlmon">SQL Monitor</a>.');
        END IF;

        IF v_sm_new_n > 0 THEN
            add_sentence('<b>' || TO_CHAR(v_sm_new_n) || ' sql_id'
                || CASE WHEN v_sm_new_n = 1 THEN '' ELSE 's' END
                || '</b> appeared in SQL Monitor for the first time in the Current window: '
                || esc(v_sm_new_ids)
                || CASE WHEN v_sm_new_n > 3
                        THEN ' (and ' || TO_CHAR(v_sm_new_n - 3) || ' more)' ELSE '' END
                || ' &mdash; see <a href="#sqlmon">SQL Monitor</a>.');
        END IF;
    END;

    ------------------------------------------------------------------
    -- R10: SQL Monitor plan-line drift (opt-in, sqlmon_detail>0 only) ->
    -- #sqlmon. At sqlmon_detail=0 this block does nothing at all (no query
    -- runs), so the narrative is byte-identical to before this rule. Bounded
    -- to exactly ONE candidate pair (the same top candidate section 18 would
    -- rank first) so the narrative's cost stays fixed regardless of
    -- sqlmon_detail's value; recomputed independently of section 18's PL/SQL
    -- state (see header note).
    ------------------------------------------------------------------
    IF ~sqlmon_detail > 0 THEN
        DECLARE
            v_r10_span_start DATE;
            v_r10_span_end   DATE;
            v_r10_sql_id       VARCHAR2(13);
            v_r10_cur_report   NUMBER;
            v_r10_cur_dbid     NUMBER;
            v_r10_base_report  NUMBER;
            v_r10_base_dbid    NUMBER;
            v_r10_cur_total_s  NUMBER;
            v_r10_base_total_s NUMBER;
            v_r10_cur_clob     CLOB;
            v_r10_base_clob    CLOB;
            v_r10_best_line    NUMBER;
            v_r10_best_op      VARCHAR2(200);
            v_r10_best_base    NUMBER;
            v_r10_best_cur     NUMBER;
            v_r10_best_delta   NUMBER := 0;
            v_r10_found        BOOLEAN := FALSE;
        BEGIN
            SELECT MIN(win_start_ts), MAX(win_end_ts)
            INTO   v_r10_span_start, v_r10_span_end
            FROM (
                WITH
                @@sql/lib/windows_cte.sql
                SELECT week_offset, win_start_ts, win_end_ts FROM windows_rollup
            );

            FOR d IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                base_execs AS (
                    SELECT r.report_id, r.dbid, r.key1 AS sql_id, r.instance_number,
                           TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                           x.status, x.plan_hash, NVL(x.elapsed_us, 0) AS elapsed_us
                    FROM   dba_hist_reports r,
                           XMLTABLE('/report_repository_summary/sql'
                               PASSING XMLTYPE(r.report_summary)
                               COLUMNS
                                   status     VARCHAR2(30) PATH 'status',
                                   plan_hash  NUMBER       PATH 'plan_hash',
                                   elapsed_us NUMBER       PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]'
                           ) x
                    WHERE  r.component_name = 'sqlmonitor'
                      AND  r.dbid IN (~dbid_list)
                      AND  (~inst_num = 0 OR r.instance_number = ~inst_num)
                      AND  r.report_summary IS NOT NULL
                      AND  r.key1 IS NOT NULL
                      AND  r.period_start_time >= CAST(v_r10_span_start AS TIMESTAMP) - INTERVAL '1' DAY
                      AND  r.period_start_time <= CAST(v_r10_span_end   AS TIMESTAMP) + INTERVAL '1' DAY
                      AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') >= v_r10_span_start
                      AND  TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') <  v_r10_span_end
                ),
                with_offset AS (
                    SELECT e.*, wr.week_offset
                    FROM   base_execs e
                    LEFT JOIN windows_rollup wr
                        ON  wr.valid_flag = 'Y'
                       AND  e.exec_start >= wr.win_start_ts
                       AND  e.exec_start <  wr.win_end_ts
                ),
                sqlid_span_stats AS (
                    SELECT sql_id,
                           MAX(CASE WHEN elapsed_us >= 1000000 THEN 1 ELSE 0 END) AS has_long,
                           MAX(CASE WHEN status = 'DONE (ERROR)' THEN 1 ELSE 0 END) AS has_error,
                           COUNT(DISTINCT CASE WHEN plan_hash <> 0 THEN plan_hash END) AS distinct_plans
                    FROM   with_offset
                    GROUP BY sql_id
                ),
                included AS (
                    SELECT sql_id FROM sqlid_span_stats
                    WHERE  has_long = 1 OR has_error = 1 OR distinct_plans > 1
                ),
                cur_best AS (
                    SELECT sql_id, report_id, dbid, elapsed_us,
                           ROW_NUMBER() OVER (PARTITION BY sql_id
                               ORDER BY elapsed_us DESC NULLS LAST, report_id) AS rn
                    FROM   with_offset
                    WHERE  week_offset = 0 AND plan_hash <> 0
                ),
                prior_stats AS (
                    SELECT sql_id, MEDIAN(elapsed_us) AS med_elapsed
                    FROM   with_offset
                    WHERE  week_offset > 0 AND plan_hash <> 0
                    GROUP BY sql_id
                ),
                prior_best AS (
                    SELECT w.sql_id, w.report_id, w.dbid, w.elapsed_us,
                           ROW_NUMBER() OVER (PARTITION BY w.sql_id
                               ORDER BY ABS(w.elapsed_us - ps.med_elapsed) ASC, w.exec_start DESC) AS rn
                    FROM   with_offset w
                    JOIN   prior_stats ps ON ps.sql_id = w.sql_id
                    WHERE  w.week_offset > 0 AND w.plan_hash <> 0
                ),
                per_window AS (
                    SELECT sql_id, week_offset, MAX(elapsed_us) / 1e6 AS max_elapsed_s
                    FROM   with_offset
                    WHERE  week_offset IS NOT NULL
                      AND  sql_id IN (SELECT sql_id FROM included)
                    GROUP BY sql_id, week_offset
                ),
                pivoted AS (
                    SELECT sql_id,
                           MAX(CASE WHEN week_offset = 0 THEN max_elapsed_s END) AS cur_val,
                           AVG(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS mu,
                           STDDEV(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS sd,
                           COUNT(CASE WHEN week_offset > 0 THEN max_elapsed_s END) AS n_prior
                    FROM   per_window
                    GROUP BY sql_id
                )
                SELECT i.sql_id,
                       cb.report_id AS cur_report_id, cb.dbid AS cur_dbid, cb.elapsed_us AS cur_elapsed_us,
                       pb.report_id AS base_report_id, pb.dbid AS base_dbid, pb.elapsed_us AS base_elapsed_us
                FROM   included i
                JOIN   cur_best   cb ON cb.sql_id = i.sql_id AND cb.rn = 1
                JOIN   prior_best pb ON pb.sql_id = i.sql_id AND pb.rn = 1
                LEFT JOIN pivoted p  ON p.sql_id  = i.sql_id
                ORDER BY
                    CASE WHEN p.n_prior >= 3 AND p.sd IS NOT NULL AND p.sd <> 0
                              AND ABS((p.cur_val - p.mu) / p.sd) > 3 THEN 1
                         WHEN p.n_prior >= 3 AND p.sd IS NOT NULL AND p.sd <> 0
                              AND ABS((p.cur_val - p.mu) / p.sd) > 2 THEN 2
                         ELSE 3 END,
                    cb.elapsed_us DESC NULLS LAST
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_r10_sql_id       := d.sql_id;
                v_r10_cur_report   := d.cur_report_id;
                v_r10_cur_dbid     := d.cur_dbid;
                v_r10_base_report  := d.base_report_id;
                v_r10_base_dbid    := d.base_dbid;
                v_r10_cur_total_s  := d.cur_elapsed_us / 1e6;
                v_r10_base_total_s := d.base_elapsed_us / 1e6;
            END LOOP;

            IF v_r10_sql_id IS NOT NULL THEN
                BEGIN
                    SELECT report INTO v_r10_cur_clob FROM dba_hist_reports_details
                    WHERE  report_id = v_r10_cur_report AND dbid = v_r10_cur_dbid;
                    SELECT report INTO v_r10_base_clob FROM dba_hist_reports_details
                    WHERE  report_id = v_r10_base_report AND dbid = v_r10_base_dbid;

                    FOR ln IN (
                        SELECT COALESCE(cl.line_id, bl.line_id) AS line_id,
                               NVL(cl.op, bl.op)
                                   || CASE WHEN NVL(cl.options, bl.options) IS NOT NULL
                                           THEN ' (' || NVL(cl.options, bl.options) || ')' END AS op_txt,
                               bl.act_rows AS base_rows, cl.act_rows AS cur_rows,
                               CASE WHEN bl.line_id IS NOT NULL AND v_r10_base_total_s > 0
                                    THEN bl.dur_s / v_r10_base_total_s * 100 END AS base_share,
                               CASE WHEN cl.line_id IS NOT NULL AND v_r10_cur_total_s > 0
                                    THEN cl.dur_s / v_r10_cur_total_s * 100 END AS cur_share
                        FROM (
                            SELECT x.* FROM
                                XMLTABLE('/report/sql_monitor_report/plan_monitor/operation'
                                    PASSING XMLTYPE(v_r10_cur_clob)
                                    COLUMNS
                                        line_id  NUMBER       PATH '@id',
                                        op       VARCHAR2(64) PATH '@name',
                                        options  VARCHAR2(64) PATH '@options',
                                        act_rows NUMBER       PATH 'stats[@type="plan_monitor"]/stat[@name="cardinality"]',
                                        dur_s    NUMBER       PATH 'stats[@type="plan_monitor"]/stat[@name="duration"]'
                                ) x
                        ) cl
                        FULL OUTER JOIN (
                            SELECT x.* FROM
                                XMLTABLE('/report/sql_monitor_report/plan_monitor/operation'
                                    PASSING XMLTYPE(v_r10_base_clob)
                                    COLUMNS
                                        line_id  NUMBER       PATH '@id',
                                        op       VARCHAR2(64) PATH '@name',
                                        options  VARCHAR2(64) PATH '@options',
                                        act_rows NUMBER       PATH 'stats[@type="plan_monitor"]/stat[@name="cardinality"]',
                                        dur_s    NUMBER       PATH 'stats[@type="plan_monitor"]/stat[@name="duration"]'
                                ) x
                        ) bl
                        ON cl.line_id = bl.line_id AND NVL(cl.op, '-') = NVL(bl.op, '-')
                    ) LOOP
                        IF ln.cur_share IS NOT NULL AND ln.base_share IS NOT NULL
                           AND ln.cur_share - ln.base_share > v_r10_best_delta THEN
                            v_r10_best_delta := ln.cur_share - ln.base_share;
                            v_r10_best_line  := ln.line_id;
                            v_r10_best_op    := ln.op_txt;
                            v_r10_best_base  := ln.base_share;
                            v_r10_best_cur   := ln.cur_share;
                            v_r10_found      := TRUE;
                        END IF;
                    END LOOP;
                EXCEPTION WHEN OTHERS THEN
                    v_r10_found := FALSE;
                END;
            END IF;

            IF v_r10_found AND v_r10_best_delta >= 5 THEN
                add_sentence('SQL Monitor plan-line drift: <b>' || esc(v_r10_sql_id) || '</b> spends '
                    || TO_CHAR(ROUND(v_r10_best_cur)) || '% of its time on line '
                    || v_r10_best_line || ' ' || esc(v_r10_best_op) || ', up from '
                    || TO_CHAR(ROUND(v_r10_best_base)) || '% in the baseline &mdash; see '
                    || '<a href="#sqlmon">SQL Monitor</a>.');
            END IF;
        END;
    END IF;

    ------------------------------------------------------------------
    -- Emit.  Nothing to say => nothing at all (not even an empty div).
    ------------------------------------------------------------------
    IF v_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<div id="narrative-src" class="narr" hidden>');
        FOR i IN 1 .. v_n LOOP
            DBMS_OUTPUT.PUT_LINE('<p>' || v_sent(i) || '</p>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div>');
        -- Relocate into the masthead slot 00_params.sql reserved.  If
        -- JavaScript is off the block just stays hidden (see the header
        -- comment); every number it quotes is also in the linked sections.
        DBMS_OUTPUT.PUT_LINE('<script>(function(){'
            || 'var s=document.getElementById("narrative-slot"),'
            || 'n=document.getElementById("narrative-src");'
            || 'if(s&&n){s.appendChild(n);n.hidden=false;}'
            || '})();</script>');
    END IF;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 17_narrative END -->'); END;
/
