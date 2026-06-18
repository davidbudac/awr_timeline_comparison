--
-- awr_trend.sql -- AWR Timeline Comparison (driver)
-- =====================================================================
--
-- Oracle 19c only (Diagnostic + Tuning Pack licensed). Pure SQL*Plus.
--
-- READ-ONLY against the target database. The script does not create
-- schemas, tables, sequences, packages or any other object, and never
-- issues INSERT / UPDATE / DELETE / COMMIT.  Everything is computed
-- in-flight from the DBA_HIST_* views and the result is emitted as a
-- single self-contained HTML file.  It only needs SELECT access to the
-- AWR views (see README).
--
-- Usage (two modes):
--
--   1. Defaults:
--        sqlplus user/pw@svc @awr_trend.sql
--
--   2. Override via DEFINE before calling:
--        sqlplus user/pw@svc
--        SQL> DEFINE target_end = '2026-04-15 09:00'
--        SQL> DEFINE win_hours  = 2
--        SQL> DEFINE weeks_back = 6
--        SQL> @awr_trend.sql
--
-- Substitution variables (with defaults in sql/defaults.sql):
--   target_end   'AUTO' (prior full hour) or 'YYYY-MM-DD HH24:MI'
--   win_hours    1
--   weeks_back   4
--   top_n        10
--   inst_num     0 = aggregate across RAC; otherwise the instance number
--   step         1     -- cadence count between comparison windows
--   step_unit    'w'   -- 'h' | 'd' | 'w'  (hours, days, weeks)
--   template     'comprehensive' (default, full lists), 'simple'
--                  (small triage-friendly subset), or 'dev'
--                  (application-developer view: SQL/throughput/contention,
--                  no host/OS/storage-engine internals).  Selects which
--                  directory under sql/lib/templates/<name>/ supplies
--                  the sysstat / sysmetric / wait-event target lists.
--   debug        'Y' (default) or 'N' -- per-section stdout progress markers.
--   marker_file  '' (default) or path to an optional timeline-marker config
--                  file (datetime + label milestones) drawn as vertical
--                  marker lines on the dated charts.  See markers.example.sql.
--
-- The cadence between adjacent comparison windows is step*step_unit.
-- Default step=1, step_unit='w' reproduces the original "same hour-of-week,
-- N prior weeks" behaviour.  Examples:
--   step=1 step_unit='h'  -- the last weeks_back+1 consecutive 1-hour windows
--   step=2 step_unit='d'  -- every other day, weeks_back+1 windows total
--   step=3 step_unit='w'  -- every third week, weeks_back+1 windows total
--
-- Output: reports/awr_trend_<DBID>_<YYYYMMDDHH24MI>_run<run_id>.html
--

SET ECHO          OFF
SET VERIFY        OFF
SET FEEDBACK      OFF
SET HEADING       OFF
SET TERMOUT       OFF
SET TRIMSPOOL     ON
SET TRIMOUT       ON
SET PAGESIZE      0
SET LINESIZE      32767
SET LONG          200000
SET LONGCHUNKSIZE 200000
SET NUMWIDTH      20
SET DEFINE        '~'
SET SQLBLANKLINES ON
SET SERVEROUTPUT  ON SIZE UNLIMITED FORMAT WRAPPED

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE

-- Pin a period decimal separator (and comma group separator) for the whole
-- session.  Numeric values that round-trip through SQL*Plus substitution
-- variables are rendered with a literal '.' (e.g. step_hours via
-- TO_CHAR(1,'FM...0.999999') yields the string '1.') and later re-parsed with
-- a bare TO_NUMBER('~step_hours').  Bare TO_NUMBER uses the *session's*
-- NLS_NUMERIC_CHARACTERS, so on a client whose locale makes ',' the decimal
-- separator (e.g. Czech/German) '.' becomes the group separator and
-- TO_NUMBER('1.') raises ORA-01722 ("invalid number"), aborting the run.
-- Forcing '.,' makes the render and the parse agree regardless of the
-- caller's locale.  ALTER SESSION SET NLS_* writes nothing to the database,
-- so the read-only invariant (and physical-standby safety) is preserved; and
-- it matches the rest of the report, which already forces '.,' on every
-- chart-CSV TO_CHAR.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

-- The caller MUST have set target_end / win_hours / weeks_back / top_n /
-- inst_num before invoking this driver.  For the canonical defaults, do:
--     @sql/defaults.sql
-- before @awr_trend.sql.  The shell wrapper run_awr_trend.sh does this
-- automatically, so a bare `./run_awr_trend.sh user/pw@svc` works too.
-- We do NOT DEFINE them here to avoid clobbering an explicit caller override.

-- --------------------------------------------------------------------
-- Resolve run_id + database identity + target_end, once, up front.
-- Downstream sections consume these as SQL*Plus substitution variables
-- so we never have to round-trip through a scratch table.
--
--   run_id              17-digit timestamp, unique per invocation
--   dbid                DBID owning the freshest snapshot VISIBLE in the
--                       current container (data-driven; see the `dbo` inline
--                       view below).  Deliberately NOT v$database.dbid: in a
--                       PDB that returns the CDB root's DBID, but the AWR rows
--                       a PDB can see live under the PDB's CON_DBID when
--                       PDB-level AWR is enabled and under the CDB DBID when it
--                       is not -- so the correct DBID can only be discovered
--                       from the data.  Matches v$database.dbid in a non-CDB
--                       and in the CDB root, so existing output is unchanged
--                       there.  Used as dbid for the report path + masthead
--                       label and as the fallback element of dbid_list.
--   dbid_list           comma-separated set of ALL DBIDs owning snapshots
--                       visible in the container (data-driven; see the `dbl`
--                       inline view below).  Every DBA_HIST_* filter uses
--                       `dbid IN (dbid_list)` so AWR that spans a DBID change
--                       (non-CDB -> PDB migration) is continuous.  Equals
--                       {dbid} in a single-DBID database (output unchanged).
--   db_name             v$database.name (trimmed); when connected to a PDB,
--                       suffixed with " / <CON_NAME>" so the report header
--                       identifies the container whose AWR is shown
--   host_name           v$instance.host_name
--   db_version          v$instance.version
--   caller_user         USER
--   generated_at_s      'YYYY-MM-DD HH24:MI:SS TZR'
--   target_end_resolved 'YYYY-MM-DD HH24:MI:SS'   (AUTO -> prior full hour)
--   dow_name            target_end day-of-week (trimmed)
--   step_hours          numeric cadence between adjacent windows in hours
--                       (= step * 1|24|168 depending on step_unit)
--   period_unit_short   'h' | 'd' | 'w'   used in compact headers like -1w
--   period_unit_long    'hour' | 'day' | 'week'   used in copy / titles
--   period_unit_title   'Hour' | 'Day' | 'Week'   used in <th> headers
--   period_step_label   'h' | 'd' | 'w' when step=1; '<step>h/d/w' otherwise
--   period_axis_fmt     TO_CHAR fmt mask for chart x-axis labels
--                       ('Mon DD' for d/w, 'Mon DD HH24:MI' for h)
--   report_path         reports/awr_trend_<db_name>_<dbid>_<YYYYMMDDHH24MI>_run<run_id>.html
--                       (<db_name> = bare CDB/PDB name, non-alphanumerics -> '_')
--   template_name       lower-cased + trimmed ~template (used in headers)
--   template_dir        sql/lib/templates/<template_name> (path used by
--                       every section's @@~template_dir/<file>.sql include)
--   debug_termout       'ON' if ~debug='Y' (any case), else 'OFF'.  Used
--                       by sql/lib/debug_log.sql to gate per-section
--                       progress markers; see that file for details.
-- --------------------------------------------------------------------
COLUMN run_id              NEW_VALUE run_id              NOPRINT
COLUMN dbid                NEW_VALUE dbid                NOPRINT
-- dbid_list is the comma-separated set of EVERY DBID that owns snapshots
-- visible in the current container (data-driven; see the `dbl` inline view
-- below).  dbid stays the single freshest DBID (used for the report path,
-- the masthead label, and as the always-present fallback element here); but
-- every DBA_HIST_* time-range / point-lookup filter uses `dbid IN (dbid_list)`
-- so AWR history that spans a DBID change -- e.g. a non-CDB migrated into a
-- PDB, where pre-migration snaps live under the old non-CDB DBID and
-- post-migration snaps under the new CON_DBID -- is reported continuously
-- instead of silently truncated at the boundary.  In a DB with a single DBID
-- this resolves to exactly `dbid`, so `dbid IN (dbid_list)` is equivalent
-- to the old `dbid = dbid` and output is unchanged.
COLUMN dbid_list           NEW_VALUE dbid_list           NOPRINT
COLUMN db_name             NEW_VALUE db_name             NOPRINT
COLUMN host_name           NEW_VALUE host_name           NOPRINT
COLUMN db_version          NEW_VALUE db_version          NOPRINT
COLUMN caller_user         NEW_VALUE caller_user         NOPRINT
COLUMN generated_at_s      NEW_VALUE generated_at_s      NOPRINT
COLUMN target_end_resolved NEW_VALUE target_end_resolved NOPRINT
COLUMN dow_name            NEW_VALUE dow_name            NOPRINT
COLUMN step_hours          NEW_VALUE step_hours          NOPRINT
COLUMN period_unit_short   NEW_VALUE period_unit_short   NOPRINT
COLUMN period_unit_long    NEW_VALUE period_unit_long    NOPRINT
COLUMN period_unit_title   NEW_VALUE period_unit_title   NOPRINT
COLUMN period_step_label   NEW_VALUE period_step_label   NOPRINT
COLUMN period_axis_fmt     NEW_VALUE period_axis_fmt     NOPRINT
COLUMN report_path         NEW_VALUE report_path         NOPRINT
COLUMN template_name       NEW_VALUE template_name       NOPRINT
COLUMN template_dir        NEW_VALUE template_dir        NOPRINT
COLUMN debug_termout       NEW_VALUE debug_termout       NOPRINT
-- marker_include is the file @@-included in the prologue to load optional
-- user-defined timeline markers.  Resolved (see the mk inline view below)
-- to the caller's marker_file path, else sql/lib/markers_inline.sql when the
-- file-free markers var is set, else the no-op stub sql/lib/no_markers.sql.
COLUMN marker_include      NEW_VALUE marker_include      NOPRINT
-- dbg_ts is refreshed inside sql/lib/debug_log.sql before each marker.
-- Declaring the COLUMN once here keeps the helper from re-declaring it
-- on every call.  NOPRINT suppresses the value from any visible output
-- (the helper depends on that to stay silent when debug is off).
-- Identifier must NOT start with an underscore (ORA-00911).
COLUMN dbg_ts              NEW_VALUE dbg_ts              NOPRINT
-- Derived labels for compact, unit-aware UI strings. Computed once after
-- step_hours is resolved so every section can reference identical text:
--   win_label       compact width of one comparison window     ("15m" / "1h")
--   step_label      compact cadence between adjacent windows   ("15m" / "1w")
--   offset_labels   CSV of compact offsets k*step_hours, k=1..weeks_back
--                   (e.g. "15m,30m,45m" or "1w,2w,3w") - parsed via REGEXP_SUBSTR
--   bucket_hours    LEAST(step_hours, 1) - bucket width (in hours) for the
--                   ASH stacked-area timeline; 0.25 for 15-min cadences,
--                   1 for hourly+; allows fractional buckets when step<1h.
COLUMN win_label           NEW_VALUE win_label           NOPRINT
COLUMN step_label          NEW_VALUE step_label          NOPRINT
COLUMN offset_labels       NEW_VALUE offset_labels       NOPRINT
COLUMN bucket_hours        NEW_VALUE bucket_hours        NOPRINT

SELECT
    t.run_id                                                       AS run_id,
    dbo.dbid                                                       AS dbid,
    dbl.dbid_list                                                  AS dbid_list,
    -- Show the CDB/database name, and append the container name when we are
    -- connected to a PDB (CON_ID not in 0=non-CDB, 1=root) so the header makes
    -- it unambiguous that the report reflects the PDB's own AWR, not the root's.
    TRIM(d.name)
        || CASE WHEN TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID')) NOT IN (0,1)
                THEN ' / ' || SYS_CONTEXT('USERENV','CON_NAME')
                ELSE '' END                                        AS db_name,
    i.host_name                                                    AS host_name,
    i.version                                                      AS db_version,
    USER                                                           AS caller_user,
    t.generated_at_s                                               AS generated_at_s,
    TO_CHAR(
        CASE
            WHEN UPPER('~target_end') IN ('AUTO','NOW','')
                THEN TRUNC(SYSDATE, 'HH24')
            ELSE TO_DATE('~target_end', 'YYYY-MM-DD HH24:MI')
        END,
        'YYYY-MM-DD HH24:MI:SS'
    )                                                              AS target_end_resolved,
    TRIM(TO_CHAR(
        CASE
            WHEN UPPER('~target_end') IN ('AUTO','NOW','')
                THEN TRUNC(SYSDATE, 'HH24')
            ELSE TO_DATE('~target_end', 'YYYY-MM-DD HH24:MI')
        END,
        'Day'))                                                    AS dow_name,
    -- step / step_unit -> step_hours.  step_unit is validated to be one of
    -- 'h','d','w' (case-insensitive); anything else triggers ORA-01722
    -- ("invalid number") on purpose so the run aborts before producing a
    -- nonsense report.
    -- Allow fractional step_hours so step values like 0.25 (15 min) survive
    -- the COLUMN ... NEW_VALUE round-trip; the integer-only mask used to
    -- silently round 0.25 to 0 and collapse all windows onto target_end.
    TO_CHAR(p.step_hours, 'FM99999999990.999999')                  AS step_hours,
    p.period_unit_short                                            AS period_unit_short,
    p.period_unit_long                                             AS period_unit_long,
    INITCAP(p.period_unit_long)                                    AS period_unit_title,
    CASE WHEN p.step_n = 1 THEN p.period_unit_short
         ELSE TO_CHAR(p.step_n) || p.period_unit_short
    END                                                            AS period_step_label,
    CASE WHEN p.period_unit_short = 'h' THEN 'Mon DD HH24:MI'
         ELSE 'Mon DD'
    END                                                            AS period_axis_fmt,
    -- Filename carries a filesystem-safe DB name (non-alphanumerics -> '_',
    -- collapsed) before the DBID so reports are identifiable at a glance.  Uses
    -- the bare CDB/PDB name only (no " / CON_NAME" suffix) to keep it tidy.
    'reports/awr_trend_'
        || REGEXP_REPLACE(TRIM(d.name), '[^A-Za-z0-9]+', '_') || '_'
        || dbo.dbid || '_'
        || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MI')
        || '_run' || t.run_id
        || '.html'                                                 AS report_path,
    tpl.template_name                                              AS template_name,
    tpl.template_dir                                               AS template_dir,
    dbg.debug_termout                                              AS debug_termout,
    mk.marker_include                                              AS marker_include
FROM v$database d
CROSS JOIN v$instance i
CROSS JOIN (
    -- DBID resolution must be data-driven, NOT v$database.dbid.  In a PDB,
    -- v$database.dbid returns the CDB root's DBID; whether the AWR rows the
    -- current container can see are stored under that DBID or under the PDB's
    -- own CON_DBID depends on whether PDB-level AWR (autoflush) is enabled:
    --   * PDB with local AWR  -> rows live under the PDB's CON_DBID, and the
    --     root's repository is NOT visible inside the PDB.
    --   * PDB without local AWR -> the only DBA_HIST_* rows visible inside the
    --     PDB are the root's, stored under the CDB DBID (== v$database.dbid).
    -- So neither v$database.dbid nor CON_DBID alone is correct in every case.
    -- Resolve to whichever DBID actually has the freshest snapshot visible in
    -- the current container -- that is, by construction, the dataset every
    -- DBA_HIST_* query in this report should trend.  Falls back to CON_DBID
    -- only when AWR is completely empty (brand-new DB) so dbid is never NULL.
    -- In a non-CDB and in the CDB root this picks the same DBID as
    -- v$database.dbid, so existing output is unchanged there.
    SELECT NVL(
             (SELECT dbid FROM (
                  SELECT dbid
                  FROM   dba_hist_snapshot
                  GROUP BY dbid
                  ORDER BY MAX(end_interval_time) DESC
              ) WHERE ROWNUM = 1),
             TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID'))
           ) AS dbid
    FROM dual
) dbo
CROSS JOIN (
    -- Every DBID that owns snapshots visible in this container, as a comma
    -- list for `dbid IN (dbid_list)`.  DBA_HIST_SNAPSHOT is already
    -- container-scoped (it shows only the current container's AWR rows), so
    -- in a migrated PDB this set is exactly {old non-CDB DBID, new CON_DBID}
    -- and in an ordinary single-DBID database it is a one-element list equal
    -- to dbid.  NVL to CON_DBID keeps the list non-empty (so the generated
    -- `IN (...)` never degenerates to invalid `IN ()`) when AWR is empty.
    SELECT NVL(
             (SELECT LISTAGG(dbid, ',') WITHIN GROUP (ORDER BY dbid)
              FROM   (SELECT DISTINCT dbid FROM dba_hist_snapshot)),
             TO_CHAR(SYS_CONTEXT('USERENV','CON_DBID'))
           ) AS dbid_list
    FROM dual
) dbl
CROSS JOIN (
    SELECT
        TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3')      AS run_id,
        TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZR') AS generated_at_s
    FROM dual
) t
CROSS JOIN (
    SELECT
        TO_NUMBER('~step') AS step_n,
        LOWER(TRIM('~step_unit')) AS period_unit_short,
        CASE LOWER(TRIM('~step_unit'))
            WHEN 'h' THEN 'hour'
            WHEN 'd' THEN 'day'
            WHEN 'w' THEN 'week'
        END AS period_unit_long,
        TO_NUMBER('~step') *
        CASE LOWER(TRIM('~step_unit'))
            WHEN 'h' THEN 1
            WHEN 'd' THEN 24
            WHEN 'w' THEN 168
            ELSE TO_NUMBER('x')   -- force ORA-01722 on invalid step_unit
        END AS step_hours
    FROM dual
) p
CROSS JOIN (
    -- Validate ~template against the supported whitelist; an unknown
    -- name forces ORA-01722 via TO_NUMBER('x'), aborting the run before
    -- any HTML is spooled.  Same trick used for step_unit above.  To
    -- add a new template, drop a directory under sql/lib/templates/ and
    -- extend the CASE.
    SELECT
        LOWER(TRIM('~template')) AS template_name,
        'sql/lib/templates/' ||
            CASE LOWER(TRIM('~template'))
                WHEN 'comprehensive' THEN 'comprehensive'
                WHEN 'simple'        THEN 'simple'
                WHEN 'dev'           THEN 'dev'
                ELSE TO_CHAR(TO_NUMBER('x'))   -- force ORA-01722 on unknown template
            END
            AS template_dir
    FROM dual
) tpl
CROSS JOIN (
    -- Any case-insensitive truthy form enables debug progress markers.
    -- Falsy / unrecognised values silently disable (no error) so an old
    -- caller that omits the var still works against the new driver.
    SELECT
        CASE WHEN UPPER(TRIM('~debug')) IN ('Y','YES','1','ON','TRUE','T')
             THEN 'ON' ELSE 'OFF' END AS debug_termout
    FROM dual
) dbg
CROSS JOIN (
    -- Resolve which file the prologue @@-includes for optional timeline
    -- markers (datetime + label milestones), so it can always include
    -- exactly one.  Three sources, in priority order:
    --   1. marker_file  -- an on-disk config (one @@sql/lib/marker line per
    --                      milestone); the original, escape-hatch path.
    --   2. markers      -- file-free inline list ("WHEN|LABEL;;...") parsed
    --                      by sql/lib/markers_inline.sql.  Lets a single
    --                      self-contained SQL*Plus session (or
    --                      MARKERS=... run_awr_trend.sh) carry markers with
    --                      nothing on disk.
    --   3. neither      -- the no-op stub sql/lib/no_markers.sql.
    -- TRIM of '' is NULL in Oracle, so an empty/unset var is "absent".
    SELECT
        CASE
            WHEN TRIM('~marker_file') IS NOT NULL
                THEN TRIM('~marker_file')
            WHEN TRIM('~markers') IS NOT NULL
                THEN 'sql/lib/markers_inline.sql'
            ELSE 'sql/lib/no_markers.sql'
        END AS marker_include
    FROM dual
) mk;

-- -------------------------------------------------------------------
-- Derived labels (win_label, step_label, offset_labels, bucket_hours)
--
-- A compact, unit-aware label for any value of "hours":
--   < 1h with whole-minute value  -> "Nm"   (e.g. 15m, 30m)
--   multiple of 168               -> "Nw"   (e.g. 1w, 2w)
--   multiple of 24                -> "Nd"   (e.g. 1d, 3d)
--   multiple of 1                 -> "Nh"   (e.g. 1h, 4h)
--   anything else                 -> "X.YYh"  (decimal hours, dot decimal)
--
-- offset_labels is a CSV of 16 entries (1..16 * step_hours). Sections only
-- consume the first weeks_back of them via REGEXP_SUBSTR(... ,k).
-- 16 is well above any realistic weeks_back; if a caller exceeds it, the
-- per-section header REGEXP_SUBSTR returns NULL and the column header
-- renders as just "&minus;" (silent visual bug, not an ORA).
-- -------------------------------------------------------------------
WITH FUNCTION fmt_one(h IN NUMBER) RETURN VARCHAR2 IS
BEGIN
    IF h IS NULL THEN
        RETURN '';
    ELSIF h < 1 AND MOD(h * 60, 1) = 0 THEN
        RETURN TO_CHAR(ROUND(h * 60)) || 'm';
    ELSIF MOD(h, 168) = 0 THEN
        RETURN TO_CHAR(ROUND(h / 168)) || 'w';
    ELSIF MOD(h, 24) = 0 THEN
        RETURN TO_CHAR(ROUND(h / 24)) || 'd';
    ELSIF MOD(h, 1) = 0 THEN
        RETURN TO_CHAR(ROUND(h)) || 'h';
    ELSE
        RETURN TO_CHAR(h, 'FM999990.99', 'NLS_NUMERIC_CHARACTERS=''.,''') || 'h';
    END IF;
END;
SELECT
    fmt_one(TO_NUMBER('~win_hours'))                                  AS win_label,
    fmt_one(TO_NUMBER('~step_hours'))                                 AS step_label,
       fmt_one(1  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(2  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(3  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(4  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(5  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(6  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(7  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(8  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(9  * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(10 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(11 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(12 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(13 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(14 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(15 * TO_NUMBER('~step_hours'))
    || ',' || fmt_one(16 * TO_NUMBER('~step_hours'))                  AS offset_labels,
    TO_CHAR(LEAST(TO_NUMBER('~step_hours'), 1),
            'FM99999999990.999999')                                   AS bucket_hours
FROM dual
/

SPOOL ~report_path

-- -------------------------------------------------------------------
-- HTML prologue
-- -------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('<!DOCTYPE html>');
    DBMS_OUTPUT.PUT_LINE('<html lang="en"><head><meta charset="utf-8">');
    DBMS_OUTPUT.PUT_LINE('<meta name="viewport" content="width=device-width, initial-scale=1">');
    DBMS_OUTPUT.PUT_LINE('<title>AWR Timeline Comparison &mdash; run '
        || '~run_id' || '</title>');
END;
/

@@sql/_style.sql

BEGIN
    DBMS_OUTPUT.PUT_LINE('</head><body>');
    -- ECharts source: the `echarts` var picks where the library loads from.
    -- Empty (the default) keeps the public CDN -- byte-identical to before.
    -- A non-empty value is used verbatim as the <script src>: a URL points at
    -- an internal mirror, while a local file path is left here as the src and
    -- then INLINED into this report by run_awr_trend.sh after generation
    -- (yielding a single, offline-capable, self-contained HTML file).  Either
    -- way `onerror` flips body.no-charts so tables still render if the script
    -- fails to load (TRIM('') is NULL in Oracle, so empty => CDN branch).
    DBMS_OUTPUT.PUT_LINE('<script src="'
        || CASE WHEN TRIM('~echarts') IS NULL
                THEN 'https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js'
                ELSE '~echarts' END
        || '" onerror="document.body.classList.add(''no-charts'')"></script>');
    -- Fallback banner shown (via body.no-charts) only if the script fails to
    -- load.  Keep the CDN-specific wording when `echarts` is empty so the
    -- default output stays byte-identical; use generic wording otherwise so a
    -- mirror/inline run doesn't misleadingly blame cdn.jsdelivr.net.
    DBMS_OUTPUT.PUT_LINE('<div class="cdn-warn">Charts hidden: '
        || CASE WHEN TRIM('~echarts') IS NULL
                THEN 'the ECharts CDN (cdn.jsdelivr.net) could not be reached.'
                ELSE 'the ECharts library could not be loaded.' END
        || ' Tables still show every number.</div>');
    -- Namespace for per-section data handoff from PL/SQL to ECharts init blocks.
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA = window.AWR_DATA || {};</script>');
END;
/

-- Render-runtime JS shared across sections.  Each file is a standalone
-- BEGIN/END/ block that emits one <script>; loaded in order so later
-- sections can rely on globals defined here.
@@sql/lib/js_wait_colors.plsql
@@sql/lib/js_sparkline.plsql

-- Optional user-defined timeline markers (milestones).  js_markers.plsql
-- inits window.AWR_MARKERS=[] and defines window.AWR_markLine(); the
-- resolved marker_include file then pushes one marker per milestone --
-- from an on-disk marker_file, from the file-free inline markers var
-- (sql/lib/markers_inline.sql), or nothing (the no-op stub).  The dated
-- charts (sections 00/09/10/11) read these at render time.
@@sql/lib/js_markers.plsql
@@~marker_include

-- -------------------------------------------------------------------
-- Sections.  Each section is compute+render in one anonymous block;
-- none of them write to the database.  Run order matters: the findings
-- (07) read z-score inputs derived from the same AWR views sections
-- 02-04 already rendered, and overview (08) reuses the same change-bucket
-- logic from 07, so they are emitted in this order.
--
-- Each section is preceded by a DEFINE _dbg_msg + @@sql/lib/debug_log.sql
-- pair that prints a one-line progress marker to standard output when
-- ~debug='Y'.  Enabled by default; see sql/defaults.sql / the wrapper
-- usage banner.  The helper file documents the mechanism in detail.
-- -------------------------------------------------------------------
DEFINE _dbg_msg = 'section 00 params (header + nav)'
@@sql/lib/debug_log.sql
@@sql/00_params.sql
DEFINE _dbg_msg = 'section 01 windows (aligned begin/end snap pairs)'
@@sql/lib/debug_log.sql
@@sql/01_windows.sql
DEFINE _dbg_msg = 'section 02 load_profile (SYSSTAT deltas)'
@@sql/lib/debug_log.sql
@@sql/02_load_profile.sql
DEFINE _dbg_msg = 'section 03 sysmetric (SYSMETRIC_SUMMARY averages)'
@@sql/lib/debug_log.sql
@@sql/03_sysmetric.sql
DEFINE _dbg_msg = 'section 04 waits_fg (foreground waits)'
@@sql/lib/debug_log.sql
@@sql/04_waits_fg.sql
DEFINE _dbg_msg = 'section 05 waits_bg (background waits)'
@@sql/lib/debug_log.sql
@@sql/05_waits_bg.sql
DEFINE _dbg_msg = 'section 06 top_sql (Top-N SQL ranked 5 ways + regression)'
@@sql/lib/debug_log.sql
@@sql/06_top_sql.sql
DEFINE _dbg_msg = 'section 07 summary (z-score findings + heatmap)'
@@sql/lib/debug_log.sql
@@sql/07_summary.sql
DEFINE _dbg_msg = 'section 08 overview (hero strip; recomputes z-scores)'
@@sql/lib/debug_log.sql
@@sql/08_overview.sql
DEFINE _dbg_msg = 'section 09 ash_timeline (ASH stacked-area; often the slowest)'
@@sql/lib/debug_log.sql
@@sql/09_ash_timeline.sql
DEFINE _dbg_msg = 'section 10 db_time_summary (DB time over the full span)'
@@sql/lib/debug_log.sql
@@sql/10_db_time_summary.sql
DEFINE _dbg_msg = 'section 11 top_sql_ash_breakdown (per-SQL ASH; one cursor per pool)'
@@sql/lib/debug_log.sql
@@sql/11_top_sql_ash_breakdown.sql
DEFINE _dbg_msg = 'section 12 param_changes (parameters that differ across windows)'
@@sql/lib/debug_log.sql
@@sql/12_param_changes.sql
DEFINE _dbg_msg = 'section 13 utilization (application usage profile)'
@@sql/lib/debug_log.sql
@@sql/13_utilization.sql
DEFINE _dbg_msg = 'section 14 segment_io (top segments by I/O per window)'
@@sql/lib/debug_log.sql
@@sql/14_segment_io.sql
DEFINE _dbg_msg = 'section 15 file_io (per-file and file-type I/O deltas)'
@@sql/lib/debug_log.sql
@@sql/15_file_io.sql
DEFINE _dbg_msg = 'all sections rendered; writing HTML epilogue'
@@sql/lib/debug_log.sql

-- -------------------------------------------------------------------
-- HTML epilogue
-- -------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('<footer class="report">');
    DBMS_OUTPUT.PUT_LINE('Generated by awr_trend.sql &mdash; run ' || '~run_id'
        || ' &mdash; read-only against the source database, no scratch schema.');
    DBMS_OUTPUT.PUT_LINE('</footer>');
    DBMS_OUTPUT.PUT_LINE('</body></html>');
END;
/

SPOOL OFF

SET TERMOUT  ON
SET FEEDBACK ON
SET HEADING  ON
SET PAGESIZE 14

PROMPT
PROMPT ============================================================
PROMPT  Report written to: ~report_path
PROMPT  Run id: ~run_id
PROMPT  (read-only run -- no database objects created or modified)
PROMPT ============================================================
PROMPT

WHENEVER SQLERROR CONTINUE
