--
-- fleet/ddl/15_types.sql
--
-- SQL object/collection types for the analyzer. awrw_win_row carries one valid
-- Comparison-Window pairing (begin/end snap per (week_offset, instance)); the
-- pipelined awrw_analyze.windows() returns awrw_win_tab so all three Detectors
-- (seasonal, regression, headline) source the SAME window derivation -- the
-- warehouse equivalent of the single-DB report's @@sql/lib/windows_cte.sql.
--
-- Pure SQL types (no table dependency); created before the packages that use
-- them. Warehouse-side only.
--
CREATE OR REPLACE TYPE awrw_win_row AS OBJECT (
    week_offset     NUMBER,   -- 0 = current Period; >0 = prior Baseline windows
    dbid            NUMBER,
    instance_number NUMBER,
    begin_snap_id   NUMBER,
    end_snap_id     NUMBER,
    dur_sec         NUMBER    -- window width in seconds (for per-second rates)
);
/

CREATE OR REPLACE TYPE awrw_win_tab AS TABLE OF awrw_win_row;
/
