--
-- 17_narrative.sql
-- The cross-section half of the Summary view's verdict hero (v1.6.0):
-- rules that JOIN findings across sections (I/O <-> file <-> segment <->
-- SQL, DB time vs DB CPU, throughput ratios, configuration drift, baseline
-- health, SQL Monitor) so the reader gets the story, not just the numbers.
-- No free prose: every piece is a fixed phrase around numbers and names.
--
-- Placement.  The pieces belong in the hero 00_params.sql opens at the top
-- of <main>, but they need data that only becomes cheap to collect once
-- the whole report has run, and this section must not depend on any other
-- section's PL/SQL state ("findings are recomputed, not shared").  So it
-- runs LAST, emits one hidden block (#narr-src) and a tiny inline script
-- moves each piece into place:
--   "Likely source:" line  -> #because-slot (reads "Worth a look:" when
--                             the verdict is quiet)
--   count pills            -> #pills, before "N metrics normal"
--   one-line notes         -> #narrative-slot (ul.hnotes); a note whose
--                             story a Summary card already tells carries
--                             data-dup=<card id> and is dropped when that
--                             card exists
--   ", most of it on SEG"  -> the verdict's .vx[data-vx="io"] clause
--   Segment / File / SQL   -> evidence rows at the top of the Physical I/O
--                             card (07, id f-io; data-ev-for)
-- With JavaScript disabled the block simply stays hidden -- every number it
-- quotes is also rendered in the sections it links to.
--
-- Rules (each is a separate cheap SELECT):
--   R1  physical reads moved LARGE  -> note (dup f-io) with the file /
--                                      segment / SQL it landed on; the
--                                      same three as I/O card evidence
--   R5  (retired: the verdict and the DB time card say wait vs CPU)
--   R2  bytes-to-client vs user calls, redo vs commits -> note: per-call /
--                                      per-commit payload grew or shrank
--   R3  init parameters differing inside the baseline -> note (dup
--                                      f-config) + "N parameters differ" pill
--   R4  invalid (skipped) prior windows -> "N of M skipped" pill (the
--                                      reason in its title)
--   R6  SQL Monitor: plan change in the Current window  -> pill
--   R7  SQL Monitor: DOP downgrade in the Current window -> pill
--   R8  SQL Monitor: DONE (ERROR) in the Current window  -> pill
--   R9  SQL Monitor: sql_ids first seen in the Current window -> pill
--   Likely source: a plan change INTO the Current window by section 18's
--                  test (Current plan vs the prior modal plan; the one
--                  with the largest Current max elapsed), else R1's
--                  newcomer SQL, else R9's first statement, else R1's top
--                  segment.
-- Entity names link (a.ent) to their rows: fl-<file>, sg-<segment>,
-- sq-preads-<sql_id>, sm-<sql_id>, #f-config; a target that was never
-- emitted is unwrapped to plain text by sql/lib/js_wingrid.plsql.
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
    v_file_aid  VARCHAR2(200);   -- its row id in 15: file_anchor(full path)
    v_file_cur  NUMBER;
    v_file_mu   NUMBER;
    v_seg       VARCHAR2(600);
    v_seg_cur   NUMBER;
    v_seg_mu    NUMBER;
    v_sqlid     VARCHAR2(13);
    v_sql_rd    NUMBER;
    v_big_pr    BOOLEAN := FALSE;

    -- v1.6.0 Summary pieces (relocated by the script at the end): pills,
    -- the likely-source line, the I/O card's evidence rows, the verdict's
    -- segment clause
    v_pills     VARCHAR2(32767);
    v_because   VARCHAR2(32767);
    v_ev_io     VARCHAR2(32767);
    v_vx_io     VARCHAR2(4000);
    v_dup       VARCHAR2(40);

    -- R3 / R4 carriers
    v_p_names   VARCHAR2(4000);
    v_p_shown   PLS_INTEGER := 0;
    v_p_total   PLS_INTEGER := 0;

    -- Every plain variable must sit ABOVE these includes: they declare
    -- functions, and PL/SQL forbids a variable after a subprogram.
    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql

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
        RETURN '&minus;' || off_label(p_k);
    END off_lbl;

    FUNCTION esc(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_XMLGEN.CONVERT(p);
    END esc;

    -- One structured row per finding (v1.5.0: the block is a compact
    -- list, not prose): label | headline number | from -> to | one short
    -- "why" clause | a link to the section that has the detail.  Empty
    -- parts are omitted.
    -- v1.6.0: rendered as one calm line in the verdict hero (#narrative-slot);
    -- p_dup names the Summary card that already tells the same story -- the
    -- relocation script drops the line when that card exists.
    PROCEDURE add_item(p_label VARCHAR2, p_num VARCHAR2, p_sub VARCHAR2,
                       p_why VARCHAR2, p_href VARCHAR2, p_link VARCHAR2,
                       p_dup VARCHAR2 DEFAULT NULL) IS
    BEGIN
        v_n := v_n + 1;
        v_sent(v_n) := '<li' || CASE WHEN p_dup IS NOT NULL THEN ' data-dup="' || p_dup || '"' END || '>'
            || '<span class="hl">' || p_label || '</span>'
            || CASE WHEN p_num IS NOT NULL THEN '<span class="hn">' || p_num || '</span>' END
            || CASE WHEN p_sub IS NOT NULL THEN '<span class="hs">' || p_sub || '</span>' END
            || CASE WHEN p_why IS NOT NULL THEN '<span class="hw">' || p_why || '</span>' END
            || CASE WHEN p_href IS NOT NULL
                    THEN '<a class="go" href="' || p_href || '">' || p_link || ' &rarr;</a>' END
            || '</li>';
    END add_item;

    FUNCTION pill(p_href VARCHAR2, p_n NUMBER, p_txt VARCHAR2, p_title VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<li><a href="' || p_href || '"'
            || CASE WHEN p_title IS NOT NULL THEN ' title="' || p_title || '"' END
            || '><b>' || p_n || '</b> ' || p_txt || '</a></li>';
    END pill;

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

    -- "LARGE": section 07's bucket through the per-metric policy
    -- (sql/lib/metric_policy.plsql): |z| > 3 over the floored sigma AND a
    -- material move past the stat's own floors AND in the bad direction
    -- (a drop in physical reads is 'improved', not a story).
    FUNCTION big(p VARCHAR2) RETURN BOOLEAN IS
        r stat_rec;
    BEGIN
        IF NOT has(p) THEN RETURN FALSE; END IF;
        r := v_stats(p);
        RETURN policy_bucket('LOAD', p, NULL, r.cur, r.mu, r.sd, r.n) = 'large';
    END big;

    FUNCTION went_up(p VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN has(p) AND v_stats(p).cur >= v_stats(p).mu;
    END went_up;

    -- "[glyph] xN.NN" -- the headline number for a stat that moved,
    -- degrading to a plain arrow when the baseline mean is zero.
    FUNCTION numtxt(p_stat VARCHAR2) RETURN VARCHAR2 IS
        v_ratio NUMBER := ratio(p_stat);
    BEGIN
        RETURN dirg(went_up(p_stat))
            || CASE WHEN v_ratio IS NULL THEN '' ELSE ' &times;' || fmt3(v_ratio) END;
    END numtxt;

    -- "mu -> cur unit" -- the from / to range for a stat.
    FUNCTION rng(p_stat VARCHAR2, p_unit VARCHAR2, p_scale NUMBER DEFAULT 1) RETURN VARCHAR2 IS
    BEGIN
        RETURN fmt3(v_stats(p_stat).mu * p_scale) || ' &rarr; '
            || fmt3(v_stats(p_stat).cur * p_scale) || ' ' || p_unit;
    END rng;

    -- "[glyph] N%" for a %-delta.
    FUNCTION pcttxt(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN dirg(p >= 0) || ' ' || fmt3(ABS(p)) || '%';
    END pcttxt;
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
        v_txt := '';
        v_big_pr := TRUE;

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
                       filename, cur_mb, mu_mb
                FROM   nf_piv
                WHERE  cur_mb > 0
                ORDER  BY cur_mb DESC, filename
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_file     := f.short_name;
                -- the link target is 15's row id, a pure function of the
                -- FULL path (sql/lib/anchor_id.plsql): the short name alone
                -- repeats across containers (every PDB has a users01.dbf)
                v_file_aid := file_anchor(f.filename);
                v_file_cur := f.cur_mb;
                v_file_mu  := f.mu_mb;
            END LOOP;
        END;

        -- Top segment by physical reads in the CURRENT window, with its mean
        -- over the prior windows it appears in (same deduped name lookup as
        -- section 14, partition included, so the name is 14's row anchor).
        BEGIN
            FOR g IN (
                WITH
                @@sql/lib/windows_cte.sql
                ,
                ns_raw AS (
                    SELECT w.week_offset, ss.dbid, ss.ts#, ss.obj#, ss.dataobj#,
                           SUM(NVL(ss.physical_reads_delta, 0)) AS phys_reads
                    FROM   valid_windows w
                    JOIN   dba_hist_seg_stat ss
                        ON ss.dbid = w.dbid
                       AND ss.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
                       AND ss.instance_number = w.instance_number
                    GROUP BY w.week_offset, ss.dbid, ss.ts#, ss.obj#, ss.dataobj#
                ),
                ns_names AS (
                    SELECT dbid, ts#, obj#, dataobj#, owner, object_name, subobject_name
                    FROM (
                        SELECT o.dbid, o.ts#, o.obj#, o.dataobj#,
                               o.owner, o.object_name, o.subobject_name,
                               ROW_NUMBER() OVER (PARTITION BY o.dbid, o.ts#,
                                   o.obj#, o.dataobj# ORDER BY NULL) AS rn
                        FROM   dba_hist_seg_stat_obj o
                        WHERE  o.dbid IN (~dbid_list)
                    ) WHERE rn = 1
                ),
                ns_named AS (
                    SELECT r.week_offset,
                           NVL(o.owner, '(unknown)') || '.'
                               || NVL(o.object_name, 'OBJ#' || TO_CHAR(r.obj#))
                               || CASE WHEN o.subobject_name IS NOT NULL
                                       THEN '.' || o.subobject_name ELSE '' END AS seg_name,
                           r.phys_reads
                    FROM   ns_raw r
                    LEFT JOIN ns_names o
                        ON o.dbid     = r.dbid
                       AND o.ts#      = r.ts#
                       AND o.obj#     = r.obj#
                       AND o.dataobj# = r.dataobj#
                ),
                ns_piv AS (
                    SELECT seg_name,
                           SUM(CASE WHEN week_offset = 0 THEN phys_reads END) AS cur_rd,
                           SUM(CASE WHEN week_offset > 0 THEN phys_reads END)
                               / NULLIF(COUNT(DISTINCT CASE WHEN week_offset > 0 THEN week_offset END), 0) AS mu_rd
                    FROM   ns_named
                    GROUP BY seg_name
                )
                SELECT seg_name, cur_rd, mu_rd
                FROM   ns_piv
                WHERE  cur_rd > 0
                ORDER  BY cur_rd DESC, seg_name
                FETCH FIRST 1 ROWS ONLY
            ) LOOP
                v_seg     := g.seg_name;
                v_seg_cur := g.cur_rd;
                v_seg_mu  := g.mu_rd;
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
                SELECT c.sql_id, c.disk_reads
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
                v_sqlid  := q.sql_id;
                v_sql_rd := q.disk_reads;
            END LOOP;
        END;

        -- The "why" clause: file (MB read), top segment, a newcomer SQL.
        -- NB: an empty VARCHAR2 IS NULL in Oracle, so every guard is a
        -- plain IS NOT NULL -- `v <> ''''` evaluates to NULL.
        v_tail := '';
        IF v_file IS NOT NULL THEN
            v_tail := 'file ' || ent(esc(v_file), v_file_aid, 'file') || ' '
                || CASE WHEN v_file_mu IS NULL THEN '' ELSE fmt3(v_file_mu) || ' &rarr; ' END
                || fmt3(v_file_cur) || ' MB';
        END IF;
        IF v_seg IS NOT NULL THEN
            v_tail := v_tail || CASE WHEN v_tail IS NULL THEN '' ELSE ' &middot; ' END
                || 'segment ' || ent(esc(v_seg), anchor_id('sg', v_seg), 'segment');
        END IF;
        IF v_sqlid IS NOT NULL THEN
            v_tail := v_tail || CASE WHEN v_tail IS NULL THEN '' ELSE ' &middot; ' END
                || 'new in top-' || TO_CHAR(v_top_n) || ': '
                || ent('<code>' || v_sqlid || '</code>', anchor_id('sq-preads', v_sqlid), 'sql');
        END IF;
        add_item('Physical reads', numtxt('physical reads'), rng('physical reads', '/s'),
                 v_tail, '#file-io', 'File I/O', 'f-io');

        -- v1.6.0: the same facts as evidence rows on the Physical I/O card
        -- (07, id f-io) -- ranked, not scored: a plain ratio -- and the
        -- verdict's ", most of it on <segment>" clause.
        IF v_seg IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>Segment</dt><dd><span class="id">'
                || ent(esc(v_seg), anchor_id('sg', v_seg), 'segment') || '</span><span class="de">'
                || fmt_num(v_seg_cur) || ' blocks read'
                || CASE WHEN v_seg_mu IS NOT NULL THEN ', normal ' || fmt_num(v_seg_mu) END
                || '</span></dd><div class="m" title="Ranked, not scored">'
                || delta_span(v_seg_cur, v_seg_mu, NULL, 'Y') || '<span class="ns">not scored</span></div></div>';
            v_vx_io := ', most of it on ' || ent('<code>' || esc(v_seg) || '</code>', anchor_id('sg', v_seg), 'segment');
        END IF;
        IF v_file IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>File</dt><dd><span class="id">'
                || ent(esc(v_file), v_file_aid, 'file') || '</span><span class="de">'
                || fmt_num(v_file_cur) || ' MB read'
                || CASE WHEN v_file_mu IS NOT NULL THEN ', normal ' || fmt_num(v_file_mu) END
                || '</span></dd><div class="m" title="Ranked, not scored">'
                || delta_span(v_file_cur, v_file_mu, NULL, 'Y') || '<span class="ns">not scored</span></div></div>';
        END IF;
        IF v_sqlid IS NOT NULL THEN
            v_ev_io := v_ev_io || '<div class="evr"><dt>SQL</dt><dd><span class="id">'
                || ent(v_sqlid, anchor_id('sq-preads', v_sqlid), 'sql') || '</span><span class="de">'
                || fmt_num(v_sql_rd) || ' blocks read; new in the top ' || TO_CHAR(v_top_n)
                || '</span></dd><div class="m"><span class="d s-plain">&#10010; new</span></div></div>';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- R5 (DB time moved LARGE up -> wait-bound vs CPU-bound) is carried by
    -- the Summary view itself since v1.6.0: the verdict (00) and the DB
    -- time card (07) append "all / mostly wait" or "mostly CPU"
    -- (sql/lib/finding_cards.plsql time_split) from the LOAD 'DB time' /
    -- 'DB CPU' rows, which sql/lib/load_pairs_cte.sql reads from
    -- DBA_HIST_SYS_TIME_MODEL (SYSSTAT has no 'DB CPU' row).  A note here
    -- would only repeat the card.
    ------------------------------------------------------------------

    ------------------------------------------------------------------
    -- R2: throughput ratios.  A payload counter that moves while its call
    -- counter stays flat means the size per call/commit changed, not the
    -- volume of calls.  At most one paragraph; both clauses may appear.
    ------------------------------------------------------------------
    IF pctd('bytes sent via SQL*Net to client') IS NOT NULL
       AND ABS(pctd('bytes sent via SQL*Net to client')) >= 10
       AND pctd('user calls') IS NOT NULL
       AND ABS(pctd('user calls')) <= 3 THEN
        add_item('Bytes to client', pcttxt(pctd('bytes sent via SQL*Net to client')),
                 'user calls ' || pcttxt(pctd('user calls')),
                 'payload per call '
                 || CASE WHEN pctd('bytes sent via SQL*Net to client') >= 0
                         THEN 'grew' ELSE 'shrank' END || ', not call volume',
                 '#load', 'Load profile');
    END IF;
    IF pctd('redo size') IS NOT NULL
       AND ABS(pctd('redo size')) >= 20
       AND pctd('user commits') IS NOT NULL
       AND ABS(pctd('user commits')) <= 5 THEN
        add_item('Redo', pcttxt(pctd('redo size')),
                 'commits ' || pcttxt(pctd('user commits')),
                 'redo per commit '
                 || CASE WHEN pctd('redo size') >= 0 THEN 'grew' ELSE 'shrank' END
                 || ': transaction size, not count',
                 '#load', 'Load profile');
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
        -- Phase 5: a contiguous run of offsets collapses to "-5w to -12w",
        -- and every prior window to "every prior window", instead of a
        -- twelve-item list.
        DECLARE
            v_k      PLS_INTEGER := 1;
            v_off    VARCHAR2(20);
            v_acc    VARCHAR2(400) := '';
            v_first  NUMBER;
            v_last   NUMBER;
            v_prev   NUMBER;
            v_contig BOOLEAN := TRUE;
        BEGIN
            LOOP
                v_off := REGEXP_SUBSTR(p.offs, '[^,]+', 1, v_k);
                EXIT WHEN v_off IS NULL;
                IF v_k = 1 THEN v_first := TO_NUMBER(v_off);
                ELSIF TO_NUMBER(v_off) <> v_prev + 1 THEN v_contig := FALSE;
                END IF;
                v_prev := TO_NUMBER(v_off);
                v_last := v_prev;
                v_acc := v_acc || CASE WHEN v_k = 1 THEN '' ELSE ', ' END
                      || off_lbl(TO_NUMBER(v_off));
                v_k := v_k + 1;
            END LOOP;
            IF v_k - 1 = ~weeks_back AND v_contig THEN
                v_acc := 'every prior window';
            ELSIF v_contig AND v_k - 1 >= 3 THEN
                v_acc := off_lbl(v_first) || ' to ' || off_lbl(v_last);
            END IF;
            v_p_names := v_p_names || v_acc;
        END;
    END LOOP;

    IF v_p_shown > 0 THEN
        add_item('Configuration',
                 TO_CHAR(v_p_total) || ' parameter' || CASE WHEN v_p_total = 1 THEN '' ELSE 's' END
                 || ' differ' || CASE WHEN v_p_total = 1 THEN 's' ELSE '' END,
                 NULL,
                 v_p_names
                 || CASE WHEN v_p_total > v_p_shown
                         THEN ' (+' || TO_CHAR(v_p_total - v_p_shown) || ' more)' ELSE '' END,
                 '#param-changes', 'Parameters', 'f-config');
        -- the configuration card (12, id f-config) exists whenever this
        -- rule fires: section 12 uses the same changed-parameter test
        v_pills := v_pills || pill('#f-config', v_p_total,
            'parameter' || CASE WHEN v_p_total = 1 THEN ' differs' ELSE 's differ' END);
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
            v_pills := v_pills || pill('#windows', b.n_bad,
                'of ' || TO_CHAR(b.n_all) || ' prior window' || CASE WHEN b.n_all = 1 THEN '' ELSE 's' END
                || ' skipped', CASE WHEN b.reason IS NOT NULL THEN esc(b.reason) END);
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
        v_sm_src        VARCHAR2(64);        -- the likely-source plan change
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

        -- R6, the likely-source statement: a plan change by section 18's
        -- own test (its Plan hash column / plan_changed), not merely "more
        -- than one plan somewhere in the span" -- a statement alternating
        -- between two plans for weeks that runs its usual plan now is not
        -- the cause.  cur = the plan of the Current window's slowest
        -- non-zero-plan execution; prior = the most frequent non-zero plan
        -- across the prior VALID windows (tie -> most recent), both over
        -- executions attributed to a valid window, exactly 18's cur_plan /
        -- prior_plan CTEs.  Deterministic pick by impact: the largest
        -- Current-window max elapsed, then sql_id.  The pill above keeps
        -- its broader count (its title says what it counts).
        FOR m IN (
            WITH
            @@sql/lib/windows_cte.sql
            ,
            ls_base AS (
                SELECT r.report_id, r.key1 AS sql_id,
                       TO_DATE(r.key3 DEFAULT NULL ON CONVERSION ERROR, 'MM:DD:YYYY HH24:MI:SS') AS exec_start,
                       x.plan_hash, NVL(x.elapsed_us, 0) AS elapsed_us
                FROM   dba_hist_reports r,
                       XMLTABLE('/report_repository_summary/sql'
                           PASSING XMLTYPE(r.report_summary)
                           COLUMNS
                               plan_hash  NUMBER PATH 'plan_hash',
                               elapsed_us NUMBER PATH 'stats[@type="monitor"]/stat[@name="elapsed_time"]'
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
            ls_off AS (
                SELECT b.report_id, b.sql_id, b.exec_start, b.plan_hash, b.elapsed_us,
                       wr.week_offset
                FROM   ls_base b
                JOIN   windows_rollup wr
                    ON  wr.valid_flag = 'Y'
                   AND  b.exec_start >= wr.win_start_ts
                   AND  b.exec_start <  wr.win_end_ts
            ),
            ls_cur AS (
                SELECT sql_id, plan_hash AS cur_ph, max_ela
                FROM (
                    SELECT sql_id, plan_hash,
                           MAX(elapsed_us) OVER (PARTITION BY sql_id) AS max_ela,
                           ROW_NUMBER() OVER (PARTITION BY sql_id
                               ORDER BY CASE WHEN plan_hash <> 0 THEN 0 ELSE 1 END,
                                        elapsed_us DESC NULLS LAST, report_id) AS rn
                    FROM   ls_off
                    WHERE  week_offset = 0
                )
                WHERE  rn = 1 AND plan_hash <> 0
            ),
            ls_prior AS (
                SELECT sql_id, plan_hash AS prior_ph
                FROM (
                    SELECT sql_id, plan_hash,
                           ROW_NUMBER() OVER (PARTITION BY sql_id
                               ORDER BY COUNT(*) DESC, MAX(exec_start) DESC) AS rn
                    FROM   ls_off
                    WHERE  week_offset > 0 AND plan_hash <> 0
                    GROUP BY sql_id, plan_hash
                )
                WHERE  rn = 1
            )
            SELECT c.sql_id
            FROM   ls_cur c
            JOIN   ls_prior p ON p.sql_id = c.sql_id
            WHERE  c.cur_ph <> p.prior_ph
            ORDER  BY c.max_ela DESC, c.sql_id
            FETCH FIRST 1 ROWS ONLY
        ) LOOP
            v_sm_src := m.sql_id;
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

        -- v1.6.0: counts as quiet pills in the verdict hero; the details
        -- are one click away in SQL Monitor (18).  A plan change links to
        -- its first statement's row (18 always lists a sql_id that ran with
        -- more than one plan).  The plan-change pill goes first, right
        -- after the finding counts (Mock D's order).
        IF v_sm_plan_n > 0 THEN
            v_pills := pill('#sm-' || REGEXP_SUBSTR(v_sm_plan_ids, '[^, ]+', 1, 1), v_sm_plan_n,
                'plan change' || CASE WHEN v_sm_plan_n = 1 THEN '' ELSE 's' END,
                'ran with more than one plan, including in the Current window: ' || esc(v_sm_plan_ids)
                || CASE WHEN v_sm_plan_n > 3 THEN ' (+' || TO_CHAR(v_sm_plan_n - 3) || ' more)' END) || v_pills;
        END IF;
        IF v_sm_new_n > 0 THEN
            v_pills := v_pills || pill('#sqlmon', v_sm_new_n, 'new SQL',
                'first seen in SQL Monitor this window: ' || esc(v_sm_new_ids)
                || CASE WHEN v_sm_new_n > 3 THEN ' (+' || TO_CHAR(v_sm_new_n - 3) || ' more)' END);
        END IF;
        IF v_sm_dop_n > 0 THEN
            v_pills := v_pills || pill('#sqlmon', v_sm_dop_n,
                'DOP downgrade' || CASE WHEN v_sm_dop_n = 1 THEN '' ELSE 's' END,
                'fewer parallel servers than requested in the Current window');
        END IF;
        IF v_sm_err_n > 0 THEN
            v_pills := v_pills || pill('#sqlmon', v_sm_err_n,
                'SQL error' || CASE WHEN v_sm_err_n = 1 THEN '' ELSE 's' END,
                'executions that ended DONE (ERROR) in the Current window');
        END IF;

        -- The likely-source line (rule-based, no free prose): a plan change
        -- into the Current window first (v_sm_src, 18's test), then a newcomer in the top-N by
        -- physical reads, then a statement first seen this window, then the
        -- segment the extra reads land on.  "Likely source:" reads "Worth a
        -- look:" in a quiet report (the relocation script decides).
        IF v_sm_src IS NOT NULL THEN
            v_because := ent('<code>' || esc(v_sm_src) || '</code>', 'sm-' || v_sm_src, 'sql')
                || ' ran with a new plan in the Current window'
                || '<span data-mk-at="0" data-mk-pre=", after " hidden></span>'
                || CASE WHEN v_sqlid = v_sm_src
                        THEN ', and is new in the top ' || TO_CHAR(v_top_n) || ' by physical reads' END;
        ELSIF v_sqlid IS NOT NULL THEN
            v_because := ent('<code>' || v_sqlid || '</code>', anchor_id('sq-preads', v_sqlid), 'sql')
                || ', new in the top ' || TO_CHAR(v_top_n) || ' by physical reads ('
                || fmt_num(v_sql_rd) || ' blocks)'
                || CASE WHEN v_seg IS NOT NULL
                        THEN '; most reads land on ' || ent('<code>' || esc(v_seg) || '</code>',
                                                             anchor_id('sg', v_seg), 'segment') END;
        ELSIF v_sm_new_n > 0 THEN
            v_because := '<code>' || esc(REGEXP_SUBSTR(v_sm_new_ids, '[^, ]+', 1, 1)) || '</code>'
                || ', first seen in SQL Monitor in the Current window';
        ELSIF v_big_pr AND v_seg IS NOT NULL THEN
            v_because := 'the reads land on ' || ent('<code>' || esc(v_seg) || '</code>',
                                                     anchor_id('sg', v_seg), 'segment')
                || CASE WHEN v_file IS NOT NULL
                        THEN ' (file ' || ent(esc(v_file), v_file_aid, 'file') || ')' END;
        END IF;
    END;

    ------------------------------------------------------------------
    -- Emit.  Nothing to say => nothing at all (not even an empty div).
    ------------------------------------------------------------------
    -- v1.6.0: every piece lands in the verdict hero that 00_params.sql
    -- opened (#because-slot, #pills, #narrative-slot, the verdict's
    -- .vx[data-vx] clause) or on a finding card of 07 (data-ev-for).  A
    -- note whose story a card already tells (data-dup) is dropped.  With
    -- JavaScript off the block stays hidden; every number it quotes is in
    -- the sections it links to.
    IF v_n > 0 OR v_pills IS NOT NULL OR v_because IS NOT NULL OR v_ev_io IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('<div id="narr-src" hidden>');
        IF v_because IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<p class="because-src"><span class="bl">Likely source:</span> '
                || v_because || '.</p>');
        END IF;
        IF v_pills IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<ul class="pills-src">' || v_pills || '</ul>');
        END IF;
        IF v_n > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<ul class="notes-src">');
            FOR i IN 1 .. v_n LOOP
                DBMS_OUTPUT.PUT_LINE(v_sent(i));
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('</ul>');
        END IF;
        IF v_vx_io IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<span data-vx-src="io">' || v_vx_io || '</span>');
        END IF;
        IF v_ev_io IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('<div data-ev-for="f-io">' || v_ev_io || '</div>');
        END IF;
        DBMS_OUTPUT.PUT_LINE('</div>');
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var d=document,src=d.getElementById("narr-src");if(!src)return;');
        DBMS_OUTPUT.PUT_LINE('var b=d.getElementById("because-slot"),bs=src.querySelector(".because-src");');
        DBMS_OUTPUT.PUT_LINE('if(b&&bs){if(d.querySelector("h1.verdict.quiet")){var l=bs.querySelector(".bl");if(l)l.textContent="Worth a look:";}');
        DBMS_OUTPUT.PUT_LINE('while(bs.firstChild)b.appendChild(bs.firstChild);b.hidden=false;}');
        DBMS_OUTPUT.PUT_LINE('var pl=d.getElementById("pills"),nn=pl?pl.querySelector(".pl-normal"):null;');
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll(".pills-src > li").forEach(function(li){if(pl)pl.insertBefore(li,nn);});');
        DBMS_OUTPUT.PUT_LINE('var ns=d.getElementById("narrative-slot");');
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll(".notes-src > li").forEach(function(li){var u=li.getAttribute("data-dup");if(u&&d.getElementById(u))return;if(ns){ns.appendChild(li);ns.hidden=false;}});');
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll("[data-vx-src]").forEach(function(x){var t=d.querySelector(''.vx[data-vx="''+x.getAttribute("data-vx-src")+''"]'');if(t){t.innerHTML=x.innerHTML;t.hidden=false;}});');
        DBMS_OUTPUT.PUT_LINE('src.querySelectorAll("[data-ev-for]").forEach(function(x){var c=d.getElementById(x.getAttribute("data-ev-for")),dl=c?c.querySelector("dl.ev"):null;if(!dl)return;var f=dl.firstChild;while(x.firstChild)dl.insertBefore(x.firstChild,f);});');
        DBMS_OUTPUT.PUT_LINE('src.parentNode.removeChild(src);})();</script>');
    END IF;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 17_narrative END -->'); END;
/
