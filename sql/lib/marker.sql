--
-- sql/lib/marker.sql -- emit one user-defined timeline marker.
--
-- Called once per milestone from a marker config file (the file passed as
-- the marker_file argument):
--
--     @@sql/lib/marker '2026-04-20 14:00' 'Applied patch 19.22'
--
-- ~1 = instant 'YYYY-MM-DD HH24:MI' (24-hour clock)
-- ~2 = label text shown next to the line
--
-- Pushes a {t,label} object onto the global window.AWR_MARKERS array that
-- the calendar-timeline charts (sections 00/09/10/11) read at render time
-- via window.AWR_markLine (see sql/lib/js_markers.plsql).
--
-- The driver runs with SET DEFINE '~', so positional parameters are
-- referenced as ~1 / ~2 (not &1 / &2).  A malformed instant is skipped
-- with an HTML comment rather than aborting the whole run (this file is
-- @@-included after SPOOL has started, so an unhandled error here would
-- truncate the report).  Labels containing a single quote must double it
-- ('Bob''s change').
--
SET DEFINE '~'
DECLARE
    v_t DATE;
BEGIN
    v_t := TO_DATE('~1', 'YYYY-MM-DD HH24:MI');
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_MARKERS.push({t:"'
        || TO_CHAR(v_t, 'YYYY-MM-DD HH24:MI') || '",label:"'
        || REPLACE(REPLACE(REPLACE('~2', '\', '\\'), '"', '\"'), '</', '<\/')
        || '"});</script>');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('<!-- awr_trend: skipped invalid marker instant ['
            || '~1' || '] (expected YYYY-MM-DD HH24:MI) -->');
END;
/
