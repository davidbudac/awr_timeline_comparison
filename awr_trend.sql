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
COLUMN report_path         NEW_VALUE report_path         NOPRINT

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
) t;

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
    --
    -- Tiny dependency-free sparkline renderer.  Each numeric table that needs
    -- an inline trend column emits <td class="trend" data-spark="v,v,v"></td>;
    -- this script swaps the attribute for a viewBox-scaled SVG path.  No
    -- charting library needed, so trends render even if the ECharts CDN is
    -- blocked.  Cell stays empty (but the numbers are right next to it) if
    -- JS itself is disabled.
    --
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s).replace(/[&<>]/g,function(c){return({"&":"&amp;","<":"&lt;",">":"&gt;"})[c];});}');
    DBMS_OUTPUT.PUT_LINE('function spark(raw, klass, title){');
    DBMS_OUTPUT.PUT_LINE('  var W=110,H=24,PAD=2;');
    DBMS_OUTPUT.PUT_LINE('  var arr=String(raw||"").split(",").map(function(s){s=s.trim();return s===""?null:+s;});');
    DBMS_OUTPUT.PUT_LINE('  var vs=arr.filter(function(v){return v!=null&&!isNaN(v);});');
    DBMS_OUTPUT.PUT_LINE('  if(vs.length===0)return "<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\"></svg>";');
    DBMS_OUTPUT.PUT_LINE('  var mn=Math.min.apply(null,vs), mx=Math.max.apply(null,vs);');
    -- Flatness guard: if the relative swing vs. the mean magnitude is below
    -- 2%, autoscaling would turn imperceptible noise into a dramatic zigzag.
    -- Collapse to a flat midline in that case so the eye reads "steady".
    DBMS_OUTPUT.PUT_LINE('  var sum=0; vs.forEach(function(v){sum+=v;}); var mean=sum/vs.length;');
    DBMS_OUTPUT.PUT_LINE('  var flat=(mx===mn)||(Math.abs(mean)>0 && (mx-mn)/Math.abs(mean)<0.02)||(mean===0 && mx-mn<1e-9);');
    DBMS_OUTPUT.PUT_LINE('  var rng=flat?1:(mx-mn);');
    DBMS_OUTPUT.PUT_LINE('  var step=(W-2*PAD)/Math.max(arr.length-1,1);');
    DBMS_OUTPUT.PUT_LINE('  var pts=[];');
    DBMS_OUTPUT.PUT_LINE('  arr.forEach(function(v,i){if(v==null||isNaN(v))return;var y=flat?(H/2):(H-PAD-(v-mn)/rng*(H-2*PAD));pts.push({x:PAD+i*step,y:y});});');
    DBMS_OUTPUT.PUT_LINE('  if(pts.length===0)return "<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\"></svg>";');
    DBMS_OUTPUT.PUT_LINE('  var line=pts.map(function(p){return p.x.toFixed(1)+","+p.y.toFixed(1);}).join(" L ");');
    DBMS_OUTPUT.PUT_LINE('  var fx=pts[0].x.toFixed(1), last=pts[pts.length-1];');
    DBMS_OUTPUT.PUT_LINE('  var out="<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\""+(title?" aria-label=\""+esc(title)+"\"":"")+">";');
    DBMS_OUTPUT.PUT_LINE('  if(title) out+="<title>"+esc(title)+"</title>";');
    DBMS_OUTPUT.PUT_LINE('  if(pts.length>=2){out+="<path class=\"fill\" d=\"M "+fx+","+(H-PAD)+" L "+line+" L "+last.x.toFixed(1)+","+(H-PAD)+" Z\"/>";}');
    DBMS_OUTPUT.PUT_LINE('  out+="<path class=\"line\" d=\"M "+line+"\"/>";');
    DBMS_OUTPUT.PUT_LINE('  out+="<circle class=\"dot\" cx=\""+last.x.toFixed(1)+"\" cy=\""+last.y.toFixed(1)+"\" r=\"2.5\"/>";');
    DBMS_OUTPUT.PUT_LINE('  return out+"</svg>";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.__awrSpark=spark;');
    DBMS_OUTPUT.PUT_LINE('function render(){document.querySelectorAll("[data-spark]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('  if(el.__sparked) return;');
    DBMS_OUTPUT.PUT_LINE('  el.innerHTML=spark(el.getAttribute("data-spark"), el.getAttribute("data-spark-cls")||"spark", el.getAttribute("data-spark-title")||"");');
    DBMS_OUTPUT.PUT_LINE('  el.__sparked=true;});}');
    DBMS_OUTPUT.PUT_LINE('if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",render); else render();');
    DBMS_OUTPUT.PUT_LINE('window.__awrRenderSparks=render;');
    DBMS_OUTPUT.PUT_LINE('})();</script>');
END;
/

-- -------------------------------------------------------------------
-- Sections.  Each section is compute+render in one anonymous block;
-- none of them write to the database.  Run order matters: the findings
-- (07) read z-score inputs derived from the same AWR views sections
-- 02-04 already rendered, and overview (08) derives severity from 07's
-- logic, so they are emitted in this order.
-- -------------------------------------------------------------------
@@sql/00_params.sql
@@sql/01_windows.sql
@@sql/02_load_profile.sql
@@sql/03_sysmetric.sql
@@sql/04_waits_fg.sql
@@sql/05_waits_bg.sql
@@sql/06_top_sql.sql
@@sql/07_summary.sql
@@sql/08_overview.sql
@@sql/09_ash_timeline.sql

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
