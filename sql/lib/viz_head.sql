--
-- sql/lib/viz_head.sql -- the stylesheets of the visualization sections
-- (20-29), <head> part.
--
-- @@-included by awr_trend.sql right after sql/_style.sql and BEFORE the
-- design's stylesheet (design_head), so the quiet / dashboard designs can
-- override these rules.  One generated stylesheet per section, each from
-- sql/lib/src/css_<name>.css (tools/js2plsql.sh).  Single-DB only: the
-- fleet chrome includes sql/_style.sql but not this file.  Nested @@
-- paths resolve against the driver.
--
@@sql/lib/css_loadresp.plsql
@@sql/lib/css_volcost.plsql
@@sql/lib/css_waithist.plsql
@@sql/lib/css_planflame.plsql
@@sql/lib/css_blocking.plsql
@@sql/lib/css_onset.plsql
@@sql/lib/css_winsim.plsql
@@sql/lib/css_instmap.plsql
@@sql/lib/css_reldelta.plsql
@@sql/lib/css_baseconf.plsql
@@sql/lib/css_timemodel.plsql
@@sql/lib/css_sqlsplit.plsql
@@sql/lib/css_who.plsql
