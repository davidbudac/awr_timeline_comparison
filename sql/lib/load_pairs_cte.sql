--
-- sql/lib/load_pairs_cte.sql
--
-- The ONE place a single-DB section reads the LOAD domain's raw
-- cumulative counters.  Body of a "load_pairs AS (...)" CTE, @@-included
-- right after a "load_targets AS (@@<template_dir>/sysstat_load_targets.sql)"
-- CTE, under a WITH that already carries sql/lib/windows_cte.sql:
--
--   WITH
--   @@sql/lib/windows_cte.sql
--   ,
--   load_targets AS (
--       @@<template_dir>/sysstat_load_targets.sql
--   ),
--   @@sql/lib/load_pairs_cte.sql
--   , load_bounds AS ( ... FROM load_pairs ... )
--
-- Columns: week_offset, dur_sec, stat_name, instance_number, snap_id,
-- value, begin_snap_id, end_snap_id -- one row per (valid window,
-- instance, stat, begin|end snap), the pairs -> bounds -> deltas shape of
-- section 02 (these views have no *_DELTA columns).
--
-- 'DB time' and 'DB CPU' are TIME MODEL statistics: DBA_HIST_SYSSTAT has
-- no 'DB CPU' row at all (only a centisecond copy of DB time), so a
-- SYSSTAT read of 'DB CPU' silently returns nothing and every consumer
-- of it (the verdict's and the DB time card's "mostly wait / mostly CPU",
-- the card's CPU evidence row) never fires on a real database.  Both
-- names are therefore read from DBA_HIST_SYS_TIME_MODEL (microseconds)
-- and divided by 1e4, so they stay in the centiseconds the template
-- lists, the metric policy's floors and finding_cards.plsql's AAS scale
-- (x 0.01) assume -- and the CPU / wait split compares like with like.
-- A template still decides whether the rows exist (load_targets).
-- lint check 26 keeps every template-driven LOAD read on this include.
--
load_pairs AS (
    SELECT w.week_offset, w.dur_sec, ss.stat_name, ss.instance_number,
           ss.snap_id, ss.value,
           w.begin_snap_id, w.end_snap_id
    FROM   valid_windows w
    JOIN   dba_hist_sysstat ss
        ON ss.dbid = w.dbid
       AND ss.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND ss.instance_number = w.instance_number
       AND ss.stat_name IN (SELECT stat_name FROM load_targets)
       AND ss.stat_name NOT IN ('DB time', 'DB CPU')
    UNION ALL
    SELECT w.week_offset, w.dur_sec, tm.stat_name, tm.instance_number,
           tm.snap_id, tm.value / 1e4,
           w.begin_snap_id, w.end_snap_id
    FROM   valid_windows w
    JOIN   dba_hist_sys_time_model tm
        ON tm.dbid = w.dbid
       AND tm.snap_id IN (w.begin_snap_id, w.end_snap_id)
       AND tm.instance_number = w.instance_number
       AND tm.stat_name IN ('DB time', 'DB CPU')
       AND tm.stat_name IN (SELECT stat_name FROM load_targets)
)
