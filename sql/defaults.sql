--
-- sql/defaults.sql
-- Canonical default values for awr_trend.sql substitution variables.
-- Loaded by awr_trend.sql only if a variable is NOT already defined by
-- the caller (via DEFINE, a wrapper script, or an earlier @ of this file).
--
-- Edit these per environment if you want site-wide defaults.
--

DEFINE target_end = 'AUTO'
DEFINE win_hours  = 1
DEFINE weeks_back = 4
DEFINE top_n      = 10
DEFINE inst_num   = 0
