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
--   dbid                v$database.dbid (integer, used by every AWR query)
--   db_name             v$database.name (trimmed)
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
--   report_path         reports/awr_trend_<dbid>_<YYYYMMDDHH24MI>_run<run_id>.html
-- --------------------------------------------------------------------
COLUMN run_id              NEW_VALUE run_id              NOPRINT
COLUMN dbid                NEW_VALUE dbid                NOPRINT
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
    d.dbid                                                         AS dbid,
    TRIM(d.name)                                                   AS db_name,
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
    'reports/awr_trend_' || d.dbid || '_'
        || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MI')
        || '_run' || t.run_id
        || '.html'                                                 AS report_path
FROM v$database d
CROSS JOIN v$instance i
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
) p;

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
    -- Load Apache ECharts from CDN; fall back gracefully if offline.
    -- CSS `.no-charts` class hides chart containers; tables still render.
    DBMS_OUTPUT.PUT_LINE('<script src="https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js"'
        || ' onerror="document.body.classList.add(''no-charts'')"></script>');
    DBMS_OUTPUT.PUT_LINE('<div class="cdn-warn">Charts hidden: the ECharts CDN '
        || '(cdn.jsdelivr.net) could not be reached. Tables still show every number.</div>');
    -- Namespace for per-section data handoff from PL/SQL to ECharts init blocks.
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DATA = window.AWR_DATA || {};</script>');
END;
/

-- Render-runtime JS shared across sections.  Each file is a standalone
-- BEGIN/END/ block that emits one <script>; loaded in order so later
-- sections can rely on globals defined here.
@@sql/lib/js_wait_colors.plsql
@@sql/lib/js_sparkline.plsql

-- -------------------------------------------------------------------
-- Sections.  Each section is compute+render in one anonymous block;
-- none of them write to the database.  Run order matters: the findings
-- (07) read z-score inputs derived from the same AWR views sections
-- 02-04 already rendered, and overview (08) reuses the same change-bucket
-- logic from 07, so they are emitted in this order.
-- -------------------------------------------------------------------
@@sql/00_params.sql
@@sql/01_windows.sql
@@sql/02_load_profile.sql
@@sql/03_sysmetric.sql

-- Foreground waits + Top SQL ride together in a 2-column row at >=1100px.
-- The wrapper div is what CSS positions via .fg-topsql-row { order:6 };
-- emit them DOM-adjacent so the grid can lay them out side by side.
BEGIN DBMS_OUTPUT.PUT_LINE('<div class="fg-topsql-row">'); END;
/
@@sql/04_waits_fg.sql
@@sql/06_top_sql.sql
BEGIN DBMS_OUTPUT.PUT_LINE('</div>'); END;
/

@@sql/05_waits_bg.sql
@@sql/07_summary.sql
@@sql/08_overview.sql
@@sql/09_ash_timeline.sql
@@sql/10_db_time_summary.sql

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
