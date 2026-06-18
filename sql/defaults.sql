--
-- sql/defaults.sql
-- Canonical default values for awr_trend.sql substitution variables.
-- awr_trend.sql does NOT load this file itself, so an explicit caller
-- override (DEFINE before @-loading the driver) is never clobbered.
-- Callers that want defaults must @-load this file first, then run the
-- driver as a SEPARATE start command (a heredoc, or two SQL> commands) --
-- NOT both @files on one command line: SQL*Plus runs only the first @file
-- and treats @awr_trend.sql as a parameter to it, so the driver silently
-- never runs (exit 0, no report).  e.g.:
--   sqlplus user/pw@svc <<'SQL'
--   @sql/defaults.sql
--   @awr_trend.sql
--   SQL
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
-- debug = 'Y' prints one-line, timestamped progress markers to standard
-- output as each section begins (e.g. "[awr_trend 09:42:18.123] section
-- 06 top_sql ...").  Useful for spotting slow sections on large DBs.
-- Markers are written to stdout only; the HTML report is unaffected.
-- Any value other than 'Y' (case-insensitive) disables the markers.
-- Enabled by default; pass debug='N' (or any non-truthy value) to silence.
DEFINE debug      = 'Y'
-- marker_file optional path to a timeline-marker config file (datetime +
-- label milestones drawn as vertical lines on the dated charts).  Empty =
-- no markers.  See markers.example.sql for the format.
DEFINE marker_file = ''
-- markers optional file-free timeline markers: a list of milestones
-- "WHEN|LABEL" separated by ";;", e.g.
--   DEFINE markers = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch'
-- Parsed in-session by sql/lib/markers_inline.sql, so no file on disk is
-- needed.  Ignored when marker_file is set (the file wins).  LABEL must not
-- contain a straight single quote, '|', ';;', or '~'; see that file's
-- header.  Empty = no inline markers.
DEFINE markers = ''
-- echarts selects where the report loads the Apache ECharts library from.
-- Empty (the default) keeps the public CDN
-- (https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js).  A URL
-- (http.../https...) is used verbatim as the <script src> -- point it at an
-- internal mirror on an air-gapped network.  A local filesystem path (e.g.
-- 'vendor/echarts.min.js') is used as the src here, and run_awr_trend.sh
-- then INLINES the file's bytes into the report after generation, producing
-- a single self-contained HTML file that renders charts with no network at
-- all.  (Pure-SQL*Plus callers get the URL/CDN behaviour; the inline step
-- lives in the wrapper -- see CLAUDE.md.)  A pinned copy ships in the repo at
-- vendor/echarts.min.js (Apache-2.0), so echarts='vendor/echarts.min.js' is
-- turnkey offline out of a fresh clone.  The value must not contain a " .
DEFINE echarts = ''
