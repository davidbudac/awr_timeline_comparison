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
-- The run_awr_trend.sh wrapper loads this file first (as a prompt-safety
-- net) and then sets its own DEFINEs in the same heredoc.
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
-- profile_days optional "Day profile" section: every hour of the 24 h
-- ending at target_end is scored against the SAME hour-of-day on the N
-- prior days (1-day cadence, independent of step / step_unit) -- a
-- hour-of-day x metric heatmap that shows WHICH hour of the day changed.
-- 0 (the default) disables the section entirely (report byte-identical to
-- before the feature); a positive whole number is the number of prior
-- days to compare against (z-scores need at least 3).  Section 16 /
-- sql/lib/day_profile_cte.sql.
DEFINE profile_days = 0
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
-- sqlmon_detail optional "Plan-line drift" phase 2 of the SQL Monitor
-- section (sql/18_sqlmon.sql): 0 (the default) disables it entirely (the
-- section stays phase-1-only, report byte-identical to before the
-- feature). A positive whole number N renders a plan-line drift block for
-- up to N regressed sql_ids, diffing a Current-window execution's plan
-- lines (starts/rows/duration/memory) against a prior-window baseline via
-- DBA_HIST_REPORTS_DETAILS' per-execution XML. Reads at most 2*N CLOBs, so
-- keep N small. See design/SQLMON_DESIGN.md.
DEFINE sqlmon_detail = 0
