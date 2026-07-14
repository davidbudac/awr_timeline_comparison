--
-- sql/fleet/defaults.sql
-- Safety-net defaults for the fleet-only substitution variables.  The
-- per-DB run_one_db() job in run_awr_fleet.sh always overrides these with
-- real values (alias from fleet.conf, a workdir path, a password-masked
-- connect-string display), but declaring them here means a caller who
-- invokes awr_fleet_extract.sql directly (bypassing the wrapper) gets an
-- empty-but-defined value instead of an interactive "Enter value for..."
-- prompt, and it registers the var names with lint.sh's known_vars scan
-- (built from every DEFINE / COLUMN ... NEW_VALUE across sql_files(), which
-- already walks sql/ recursively and so picks up this file automatically).
--
-- Load order in run_one_db(): @sql/defaults.sql (single-DB defaults, incl.
-- template='comprehensive') -> @sql/fleet/defaults.sql (this file) ->
-- explicit per-run DEFINEs -> @@awr_fleet_extract.sql.  template is
-- re-defined below to 'fleet' so a bare invocation (no explicit override)
-- resolves the lean fleet target lists instead of the comprehensive
-- firehose; the wrapper's FLEET_TEMPLATE env var (default 'fleet') still
-- wins because its DEFINE runs after this file.
--
DEFINE fleet_alias     = ''
DEFINE fleet_workdir   = ''
DEFINE fleet_conn_disp = ''
DEFINE template         = 'fleet'
