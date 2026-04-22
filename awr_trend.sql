--
-- awr_trend.sql -- AWR Timeline Comparison (driver)
-- =====================================================================
--
-- Oracle 19c only (Diagnostic + Tuning Pack licensed).  Pure SQL*Plus.
--
-- Usage (two modes):
--
--   1. Defaults:
--        sqlplus user/pw@svc @awr_trend.sql
--
--   2. Override via DEFINE before calling (recommended for custom windows):
--        sqlplus user/pw@svc
--        SQL> DEFINE target_end = '2026-04-15 09:00'
--        SQL> DEFINE win_hours  = 2
--        SQL> DEFINE weeks_back = 6
--        SQL> @awr_trend.sql
--
-- Substitution variables (with defaults):
--   target_end   'AUTO' (prior full hour) or 'YYYY-MM-DD HH24:MI'
--   win_hours    1
--   weeks_back   4
--   top_n        10
--   inst_num     0 = aggregate across RAC; otherwise the instance number
--
-- Prerequisite (run once per target database, as the owner user):
--   sqlplus user/pw@svc @sql/setup_schema.sql
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

-- Allocate run_id and build report path --------------------------------
COLUMN run_id       NEW_VALUE run_id       NOPRINT
COLUMN report_path  NEW_VALUE report_path  NOPRINT

SELECT awr_trend_run_seq.NEXTVAL AS run_id FROM dual;

SELECT 'reports/awr_trend_'
       || (SELECT dbid FROM v$database) || '_'
       || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MI') || '_run'
       || ~run_id || '.html' AS report_path
FROM dual;

SPOOL ~report_path

-- -------------------------------------------------------------------
-- HTML prologue
-- -------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('<!DOCTYPE html>');
    DBMS_OUTPUT.PUT_LINE('<html lang="en"><head><meta charset="utf-8">');
    DBMS_OUTPUT.PUT_LINE('<meta name="viewport" content="width=device-width, initial-scale=1">');
    DBMS_OUTPUT.PUT_LINE('<title>AWR Timeline Comparison &mdash; run '
        || ~run_id || '</title>');
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
-- Sections (order matters: 07 must run last because it reads facts
-- inserted by 02-06).  Section 00 inserts the AWR_TREND_RUNS row.
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
    DBMS_OUTPUT.PUT_LINE('Generated by awr_trend.sql &mdash; run ' || ~run_id
        || ' &mdash; raw data preserved in the AWR_TREND_* scratch tables.');
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
PROMPT
PROMPT  Query scratch schema for this run:
PROMPT    SELECT severity, metric_name, current_value, prior_mean, z_score
PROMPT    FROM   awr_trend_findings
PROMPT    WHERE  run_id = ~run_id
PROMPT    ORDER BY
PROMPT      CASE severity
PROMPT        WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2
PROMPT        WHEN 'INSUFFICIENT_HISTORY' THEN 3
PROMPT        WHEN 'FLAT_BASELINE' THEN 4 ELSE 5 END,
PROMPT      ABS(NVL(z_score,0)) DESC;
PROMPT ============================================================
PROMPT

WHENEVER SQLERROR CONTINUE
