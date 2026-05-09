--
-- side/baselines_defaults.sql
-- Canonical defaults for side/create_weekly_baselines.sql substitution
-- variables. Loaded automatically by that script only when the caller
-- has not already DEFINEd the variable. Mirrors the pattern used by
-- sql/defaults.sql for the main driver.
--
-- Edit these per environment if you want site-wide defaults.
--

DEFINE weeks_back  = 1
DEFINE prefix      = 'WK_'
DEFINE expire_days = 365
