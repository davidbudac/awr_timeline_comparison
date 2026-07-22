--
-- awr_fleet_extract.sql -- per-database extractor for the AWR fleet report
-- =====================================================================
--
-- Oracle 19c only (Diagnostic + Tuning Pack licensed). Pure SQL*Plus.
--
-- READ-ONLY against the target database, exactly like awr_trend.sql: no
-- DDL/DML/COMMIT, everything recomputed in-flight from DBA_HIST_* views.
-- Lives at the repo root (not under sql/) so every @@sql/... include below
-- resolves correctly -- nested SQL*Plus @@ paths resolve against the
-- OUTERMOST caller's directory, and this file IS the outermost caller when
-- run_awr_fleet.sh invokes it directly per database.
--
-- Companion driver to awr_trend.sql, purpose-built for the fleet report:
-- run once per database (by run_awr_fleet.sh's run_one_db()), spools a
-- shared page-chrome fragment and a compact per-DB report fragment (no
-- masthead, no </body></html>) to deterministic paths under fleet_workdir,
-- and exits.  The bash wrapper assembles every DB's fragment plus one
-- surviving chrome copy into a single self-contained HTML file.  Unlike
-- awr_trend.sql this never spools a full standalone report and never loads
-- ECharts -- inline-SVG sparklines only, so the fleet report is offline-
-- complete by construction.
--
-- Usage: invoked by run_awr_fleet.sh's run_one_db() as a two-command
-- heredoc (never two @files on one line -- see the CLAUDE.md heredoc trap):
--
--   sqlplus -s "$connect" <<SQL
--   @sql/defaults.sql
--   @sql/fleet/defaults.sql
--   DEFINE fleet_alias     = 'dbA'
--   DEFINE fleet_workdir   = 'reports/fleet_work_20260714120000'
--   DEFINE fleet_conn_disp = 'user/***@svc'
--   DEFINE target_end = '...'  DEFINE win_hours = ...  DEFINE weeks_back = ...
--   DEFINE top_n = ...  DEFINE step = ...  DEFINE step_unit = ...
--   DEFINE inst_num = 0
--   @@awr_fleet_extract.sql
--   SQL
--
-- Substitution variables consumed: the same twelve-ish single-DB vars
-- (target_end, win_hours, weeks_back, top_n, inst_num, step, step_unit,
-- template) plus the three fleet-only vars from sql/fleet/defaults.sql
-- (fleet_alias, fleet_workdir, fleet_conn_disp).  markers/echarts/debug are
-- NOT consumed here (see "Dropped vs awr_trend.sql" below).
--
-- Output: two files under fleet_workdir, both named from fleet_alias:
--   <fleet_workdir>/<fleet_alias>.chrome.html  -- shared <head>/CSS/<body>
--                                                  open; every DB spools its
--                                                  own copy (pure
--                                                  DBMS_OUTPUT, no race
--                                                  under parallel fan-out);
--                                                  the assembler keeps only
--                                                  the first successful one.
--   <fleet_workdir>/<fleet_alias>.frag.html    -- the actual per-DB report
--                                                  fragment (fleet v0.2.0):
--                                                  TWO table rows -- a summary
--                                                  tr.dbrow and a hidden
--                                                  tr.detailrow (ASH timeline,
--                                                  headline metric cards,
--                                                  findings, top-SQL, drill).
--                                                  The assembler wraps every
--                                                  frag in the <table
--                                                  class="fleet"> it emits.
--                                                  Ends with the sentinel
--                                                  comment the assembler
--                                                  requires to treat a spool
--                                                  as complete (a truncated
--                                                  spool -- crash, OOM,
--                                                  ORA- mid-section -- omits
--                                                  it and the wrapper
--                                                  demotes the DB to an
--                                                  error card).
--
-- Dropped vs awr_trend.sql (deliberately, per CLAUDE.md "never touch
-- single-DB files for fleet features"):
--   markers      -- no dated ECharts axis exists in the fleet report to
--                    attach a markLine to.
--   echarts      -- no ECharts anywhere; sparklines are CDN-free by design.
--   report_path  -- the fleet report is assembled by the wrapper from many
--                    fragments, not spooled as one file by this script.
--   debug_log    -- couples to the single-spool model (SPOOL OFF / silent
--                    SELECT / SPOOL APPEND dance); fleet per-DB progress
--                    lives in the wrapper's own $alias.log instead.
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
-- session, exactly as awr_trend.sql does and for the identical reason:
-- step_hours round-trips through a SQL*Plus substitution variable as a
-- trailing-dot string (e.g. '1.') and is later re-parsed with a bare
-- TO_NUMBER('~step_hours'), which honors the session's NLS_NUMERIC_
-- CHARACTERS.  On a ','-decimal locale that turns '.' into the group
-- separator and TO_NUMBER raises ORA-01722, aborting the run under
-- WHENEVER SQLERROR EXIT.  ALTER SESSION SET NLS_* writes nothing to the
-- database, so the read-only invariant holds.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

-- --------------------------------------------------------------------
-- Resolve run_id + database identity + target_end + template_dir, once,
-- up front -- the same pattern as awr_trend.sql's derived-vars SELECT
-- (COLUMN ... NEW_VALUE), trimmed to only what the fleet sections need.
-- windows_cte.sql and the adapted section bodies consume dbid / dbid_list /
-- target_end_resolved / step_hours under the SAME names as the single-DB
-- driver, so they work unmodified.
-- --------------------------------------------------------------------
COLUMN run_id              NEW_VALUE run_id              NOPRINT
COLUMN dbid                NEW_VALUE dbid                NOPRINT
-- dbid_list: comma set of every DBID owning snapshots visible in this
-- container -- see awr_trend.sql for the full non-CDB->PDB migration
-- rationale. Every DBA_HIST_* filter here uses dbid IN (dbid_list), never
-- dbid = dbid.
COLUMN dbid_list           NEW_VALUE dbid_list           NOPRINT
COLUMN db_name             NEW_VALUE db_name             NOPRINT
COLUMN host_name           NEW_VALUE host_name           NOPRINT
COLUMN db_version          NEW_VALUE db_version          NOPRINT
COLUMN target_end_resolved NEW_VALUE target_end_resolved NOPRINT
-- target_end_requested is the literal requested instant, BEFORE any
-- snap-to-last-snapshot adjustment (see the snp inline view below, a
-- deliberate lockstep copy of awr_trend.sql's). 06_close's drill panel
-- compares it against target_end_resolved to decide whether to print a
-- "snapped to last snapshot" note.
COLUMN target_end_requested NEW_VALUE target_end_requested NOPRINT
COLUMN dow_name            NEW_VALUE dow_name            NOPRINT
COLUMN step_hours          NEW_VALUE step_hours          NOPRINT
COLUMN period_unit_short   NEW_VALUE period_unit_short   NOPRINT
COLUMN period_unit_long    NEW_VALUE period_unit_long    NOPRINT
COLUMN period_unit_title   NEW_VALUE period_unit_title   NOPRINT
COLUMN period_step_label   NEW_VALUE period_step_label   NOPRINT
COLUMN template_name       NEW_VALUE template_name       NOPRINT
COLUMN template_dir        NEW_VALUE template_dir        NOPRINT
COLUMN chrome_path         NEW_VALUE chrome_path         NOPRINT
COLUMN frag_path           NEW_VALUE frag_path           NOPRINT

SELECT
    t.run_id                                                       AS run_id,
    dbo.dbid                                                       AS dbid,
    dbl.dbid_list                                                  AS dbid_list,
    TRIM(d.name)
        || CASE WHEN TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID')) NOT IN (0,1)
                THEN ' / ' || SYS_CONTEXT('USERENV','CON_NAME')
                ELSE '' END                                        AS db_name,
    i.host_name                                                    AS host_name,
    i.version                                                      AS db_version,
    TO_CHAR(snp.eff_ts, 'YYYY-MM-DD HH24:MI:SS')                   AS target_end_resolved,
    TRIM(TO_CHAR(snp.eff_ts, 'Day'))                                AS dow_name,
    TO_CHAR(snp.req_ts, 'YYYY-MM-DD HH24:MI:SS')                   AS target_end_requested,
    -- step / step_unit -> step_hours, identical formula to awr_trend.sql
    -- (an invalid step_unit forces ORA-01722 on purpose).
    -- NB: keep inline comments inside this top-level SELECT free of a
    -- trailing ';' -- SQL*Plus treats a semicolon in a '--' comment as the
    -- statement terminator and cuts the SELECT short here (ORA-00936). The
    -- same ';' is harmless inside a PL/SQL block (those end on '/'), which is
    -- why the section emitters can carry it but this resolving SELECT cannot.
    TO_CHAR(p.step_hours, 'FM99999999990.999999')                  AS step_hours,
    p.period_unit_short                                            AS period_unit_short,
    p.period_unit_long                                             AS period_unit_long,
    INITCAP(p.period_unit_long)                                    AS period_unit_title,
    CASE WHEN p.step_n = 1 THEN p.period_unit_short
         ELSE TO_CHAR(p.step_n) || p.period_unit_short
    END                                                            AS period_step_label,
    tpl.template_name                                              AS template_name,
    tpl.template_dir                                               AS template_dir,
    -- chrome_path / frag_path: deterministic per-alias paths under the
    -- wrapper-supplied workdir.  fleet_alias is validated by the wrapper
    -- against [A-Za-z0-9_.-]{1,30} before this script ever runs, so no
    -- path-traversal or quoting concerns here.
    '~fleet_workdir' || '/' || '~fleet_alias' || '.chrome.html'    AS chrome_path,
    '~fleet_workdir' || '/' || '~fleet_alias' || '.frag.html'      AS frag_path
FROM v$database d
CROSS JOIN v$instance i
CROSS JOIN (
    -- DBID resolution, verbatim from awr_trend.sql: data-driven (the DBID
    -- owning the freshest visible snapshot), NOT v$database.dbid, so a PDB
    -- with local AWR resolves correctly. Falls back to CON_DBID only when
    -- AWR is completely empty.
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
    -- Every DBID that owns snapshots visible in this container, verbatim
    -- from awr_trend.sql -- see that file for the full migrated-PDB
    -- rationale.
    SELECT NVL(
             (SELECT LISTAGG(dbid, ',') WITHIN GROUP (ORDER BY dbid)
              FROM   (SELECT DISTINCT dbid FROM dba_hist_snapshot)),
             TO_CHAR(SYS_CONTEXT('USERENV','CON_DBID'))
           ) AS dbid_list
    FROM dual
) dbl
CROSS JOIN (
    -- Snap the requested target_end down to the DB's actual snapshot grid,
    -- verbatim (deliberate lockstep copy) from awr_trend.sql's snp inline
    -- view -- see that file for the full rationale. req_ts is the literal
    -- requested instant (the original, unmodified CASE); eff_ts is what
    -- every downstream section actually sees as target_end_resolved.
    SELECT
        rs.req_ts                                                  AS req_ts,
        CASE
            WHEN rs.last_snap_ts IS NULL THEN rs.req_ts
            WHEN rs.req_ts - rs.last_snap_ts <= 15/1440 THEN rs.req_ts
            ELSE TRUNC(rs.last_snap_ts, 'MI')
        END                                                        AS eff_ts
    FROM (
        SELECT
            req.req_ts                                             AS req_ts,
            (SELECT MAX(CAST(end_interval_time AS DATE))
             FROM   dba_hist_snapshot
             WHERE  CAST(end_interval_time AS DATE) <= req.req_ts + 5/1440)
                                                                    AS last_snap_ts
        FROM (
            SELECT
                CASE
                    WHEN UPPER('~target_end') IN ('AUTO','NOW','')
                        THEN TRUNC(SYSDATE, 'HH24')
                    ELSE TO_DATE('~target_end', 'YYYY-MM-DD HH24:MI')
                END AS req_ts
            FROM dual
        ) req
    ) rs
) snp
CROSS JOIN (
    SELECT TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3') AS run_id
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
    -- LOCAL template whitelist -- deliberately a separate copy from
    -- awr_trend.sql's CASE (zero-touch on that file). Adds 'fleet' (the
    -- lean triage template seeded from sql/lib/is_essential.plsql) to the
    -- same three single-DB templates. sql/fleet/defaults.sql already
    -- DEFINEs template='fleet' as the fleet-side default; an explicit
    -- override (e.g. FLEET_TEMPLATE=simple) still resolves through here.
    -- An unknown name forces ORA-01722, aborting before any HTML spools.
    SELECT
        LOWER(TRIM('~template')) AS template_name,
        'sql/lib/templates/' ||
            CASE LOWER(TRIM('~template'))
                WHEN 'fleet'         THEN 'fleet'
                WHEN 'comprehensive' THEN 'comprehensive'
                WHEN 'simple'        THEN 'simple'
                WHEN 'dev'           THEN 'dev'
                ELSE TO_CHAR(TO_NUMBER('x'))   -- force ORA-01722 on unknown template
            END
            AS template_dir
    FROM dual
) tpl;

-- -------------------------------------------------------------------
-- Chrome fragment: shared <head>/CSS/<body> open. Every DB spools its own
-- copy of this file (cheap, and race-free under FLEET_PAR>1); the wrapper
-- keeps only the first one it finds when assembling the final report.
-- -------------------------------------------------------------------
SPOOL ~chrome_path
@@sql/fleet/00_fleet_chrome.sql
SPOOL OFF

-- -------------------------------------------------------------------
-- Per-DB report fragment (fleet v0.2.0): a summary tr.dbrow + a hidden
-- tr.detailrow, emitted across 01_row (row + open detail scaffold + ASH
-- timeline block), 02_ash (window.FLEET_ASH payload), 03_headline (metric
-- cards, closes left col / opens right col), 04_findings, 05_topsql, and
-- 06_close (drill + close scaffold + sentinel).  01/04/05 each recompute
-- their own z-scores from the AWR views directly (same "findings are
-- recomputed, not shared" convention as the single-DB report's 07/08), so
-- nothing here depends on an earlier section's PL/SQL state.
-- -------------------------------------------------------------------
SPOOL ~frag_path
@@sql/fleet/01_row.sql
@@sql/fleet/02_ash.sql
@@sql/fleet/03_headline.sql
@@sql/fleet/04_findings.sql
@@sql/fleet/05_topsql.sql
@@sql/fleet/06_close.sql
SPOOL OFF

SET TERMOUT  ON
SET FEEDBACK ON
SET HEADING  ON
SET PAGESIZE 14

PROMPT
PROMPT ============================================================
PROMPT  Fragment written to: ~frag_path
PROMPT  Chrome written to:   ~chrome_path
PROMPT  Run id: ~run_id
PROMPT  (read-only run -- no database objects created or modified)
PROMPT ============================================================
PROMPT

WHENEVER SQLERROR CONTINUE
