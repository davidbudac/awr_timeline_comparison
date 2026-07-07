--
-- sql/lib/json_escape.plsql
--
-- Local PL/SQL helper that escapes a free-text string for embedding in a
-- JSON string literal emitted on a single DBMS_OUTPUT.PUT_LINE.  Escapes
-- in the correct order -- backslash FIRST (so it doesn't double-escape the
-- backslashes introduced by the quote step), then the double-quote, then
-- CR/LF to spaces so the one-line PUT_LINE stays well-formed.  This mirrors
-- the inline chain in sql/06_top_sql.sql; sections 14/15 route their
-- app-set names (segment/object/file/filetype) through it so a name
-- containing a backslash (e.g. a Windows-style path or an odd object name)
-- can't emit `\"` -> broken JSON.  SELECT-only, no DB access.
--
-- Usage: include this file *inside* a section's DECLARE block, BEFORE the
-- BEGIN keyword, then call json_escape(x) wherever a raw string goes into a
-- JSON string literal:
--
--   DECLARE
--       @@sql/lib/json_escape.plsql
--   BEGIN
--       ... '{"name":"' || json_escape(s.seg_name) || '"' ...
--   END;
--   /
--
-- Returns NULL unchanged (callers guard with NVL where a literal is needed).
--
    FUNCTION json_escape(p_str VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(REPLACE(p_str,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' ');
    END json_escape;
