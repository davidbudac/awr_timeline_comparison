--
-- sql/lib/design_tail.sql -- the quiet / dashboard design, script part.
--
-- @@-included by awr_trend.sql after the footer, right before </body>,
-- when the design substitution variable is quiet or dashboard
-- (design_tail; classic includes the empty sql/lib/no_design.sql).  Sets
-- window.AWR_DESIGN to the resolved design name, then emits
-- sql/lib/js_design.plsql (generated from sql/lib/src/js_design.js),
-- whose DOMContentLoaded handler is therefore the page's last one.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_DESIGN="~design_name";</script>');
END;
/
@@sql/lib/js_design.plsql
