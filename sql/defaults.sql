--
-- sql/defaults.sql
-- Canonical default values for awr_trend.sql substitution variables.
-- awr_trend.sql does NOT load this file itself, so an explicit caller
-- override (DEFINE before @-loading the driver) is never clobbered.
-- Callers that want defaults must @-load this file first, e.g.:
--   sqlplus user/pw@svc @sql/defaults.sql @awr_trend.sql
-- The run_awr_trend.sh wrapper sets DEFINEs in its own heredoc instead
-- of loading this file.
--
-- Edit these per environment if you want site-wide defaults.
--

DEFINE target_end = 'AUTO'
DEFINE win_hours  = 1
DEFINE weeks_back = 4
DEFINE top_n      = 10
DEFINE inst_num   = 0
DEFINE step       = 1
DEFINE step_unit  = 'w'
DEFINE template   = 'comprehensive'
