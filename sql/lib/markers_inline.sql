--
-- sql/lib/markers_inline.sql -- emit timeline markers from the inline
-- ~markers substitution variable, with NO separate marker file on disk.
--
-- Used when the caller sets `markers` (and leaves marker_file empty); the
-- driver resolves marker_include to this file (see awr_trend.sql).  It is
-- the file-free twin of sql/lib/marker.sql: instead of one @@-included
-- line per milestone, all milestones travel in one substitution variable
-- so a self-contained SQL*Plus session (or `MARKERS=... run_awr_trend.sh`)
-- needs nothing on disk.
--
-- Format -- a list of milestones, each "WHEN|LABEL", separated by ";;":
--
--     DEFINE markers = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22'
--
--   WHEN   'YYYY-MM-DD HH24:MI' (24-hour clock)
--   LABEL  text shown next to the line
--
-- Each milestone pushes a {t,label} object onto window.AWR_MARKERS -- the
-- byte-for-byte same <script> sql/lib/marker.sql emits -- so the
-- calendar-timeline charts (sections 00/09/10/11) render inline markers
-- identically to the file path.  js_markers.plsql has already initialised
-- the array (it runs first in the prologue).
--
-- Constraints (documented; the configurator enforces them for you):
--   * LABEL must not contain a straight single quote (') -- the value is
--     substituted into a PL/SQL string literal here, and also rides
--     through a shell single-quoted env var on the wrapper path.  Use a
--     typographic apostrophe (’) or the marker_file path for such labels.
--   * '|' separates WHEN from LABEL and ';;' separates milestones, so a
--     LABEL cannot contain either token.
--   * The driver runs under SET DEFINE '~', so a literal '~' in a LABEL is
--     parsed as a substitution -- write it out (same caveat as marker.sql).
--
-- A malformed milestone is skipped with an HTML comment rather than
-- aborting the run (this file is @@-included after SPOOL has started, so
-- an unhandled error here would truncate the report).
--
SET DEFINE '~'
DECLARE
    v_raw   VARCHAR2(32767) := '~markers';
    v_pos   PLS_INTEGER := 1;
    v_sep   PLS_INTEGER;
    v_bar   PLS_INTEGER;
    v_item  VARCHAR2(32767);

    -- Mirror of the emit in sql/lib/marker.sql: parse the instant, then
    -- push {t,label} with JS-safe escaping of \ " and </.
    PROCEDURE emit_marker(p_when IN VARCHAR2, p_label IN VARCHAR2) IS
        l_t DATE;
    BEGIN
        l_t := TO_DATE(TRIM(p_when), 'YYYY-MM-DD HH24:MI');
        DBMS_OUTPUT.PUT_LINE('<script>window.AWR_MARKERS.push({t:"'
            || TO_CHAR(l_t, 'YYYY-MM-DD HH24:MI') || '",label:"'
            || REPLACE(REPLACE(REPLACE(p_label, '\', '\\'), '"', '\"'), '</', '<\/')
            || '"});</script>');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('<!-- awr_trend: skipped invalid marker instant ['
                || p_when || '] (expected YYYY-MM-DD HH24:MI) -->');
    END emit_marker;
BEGIN
    IF v_raw IS NULL OR TRIM(v_raw) IS NULL THEN
        RETURN;
    END IF;

    LOOP
        v_sep := INSTR(v_raw, ';;', v_pos);
        IF v_sep = 0 THEN
            v_item := SUBSTR(v_raw, v_pos);
        ELSE
            v_item := SUBSTR(v_raw, v_pos, v_sep - v_pos);
        END IF;

        IF TRIM(v_item) IS NOT NULL THEN
            v_bar := INSTR(v_item, '|');
            IF v_bar = 0 THEN
                DBMS_OUTPUT.PUT_LINE('<!-- awr_trend: skipped marker without "|" ['
                    || v_item || '] (expected WHEN|LABEL) -->');
            ELSE
                emit_marker(SUBSTR(v_item, 1, v_bar - 1), SUBSTR(v_item, v_bar + 1));
            END IF;
        END IF;

        EXIT WHEN v_sep = 0;
        v_pos := v_sep + 2;   -- step past the ';;' separator
    END LOOP;
END;
/
