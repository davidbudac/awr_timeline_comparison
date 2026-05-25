--
-- sql/lib/debug_log.sql
-- Emit a single-line progress marker to standard output without
-- corrupting the HTML spool.
--
-- Caller contract (the driver follows this; if you call this file from
-- a section, mirror the same pattern):
--
--     DEFINE _dbg_msg = 'short label for the upcoming section'
--     @@sql/lib/debug_log.sql
--
-- Required substitution variables (resolved once in awr_trend.sql):
--     ~debug_termout   'ON'  -> message reaches the terminal
--                      'OFF' -> PROMPT is silently dropped
--     ~report_path     active SPOOL file; we re-open it APPEND after the
--                      message so the HTML continues uninterrupted
--
-- Mechanism: SPOOL is paused around the marker so it cannot land in the
-- report; TERMOUT is toggled on (only when ~debug_termout='ON') so PROMPT
-- reaches the terminal.  The timestamp SELECT runs AFTER SPOOL OFF and
-- BEFORE TERMOUT ON so it produces zero visible bytes in either
-- destination regardless of NOPRINT / HEADING / FEEDBACK settings.
--
-- Cost when debug is disabled: one round-trip for the SYSTIMESTAMP
-- SELECT plus one SPOOL OFF / SPOOL APPEND pair per call.  Trivial.
--

SPOOL OFF
-- Capture wall-clock time into the substitution slot. SPOOL is off and
-- TERMOUT is still OFF here so the SELECT is completely silent.  The
-- COLUMN dbg_ts NEW_VALUE NOPRINT declaration is in awr_trend.sql so
-- a single SELECT per call is all that is needed.
--
-- NOTE on the alias: Oracle identifiers cannot start with an underscore,
-- so we use dbg_ts (not _dbg_ts) -- the latter raises ORA-00911 and the
-- WHENEVER SQLERROR EXIT in the driver would abort the run.
SELECT TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS.FF3') AS dbg_ts FROM dual;
SET TERMOUT ~debug_termout
PROMPT [awr_trend ~dbg_ts] ~_dbg_msg
SET TERMOUT OFF
SPOOL ~report_path APPEND
