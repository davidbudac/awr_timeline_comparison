--
-- sql/lib/nth_csv.plsql
--
-- Local PL/SQL helper used by sections that emit per-row CSV via
-- LISTAGG(... ORDER BY week_offset ASC) and then parse it back inside
-- a render loop to emit one <td> per week.  INSTR-based (not
-- REGEXP_SUBSTR) so empty tokens between commas are preserved.
--
-- EMITTER CONTRACT: LISTAGG drops NULL measures outright -- no token,
-- no delimiter -- so LISTAGG(nullable_token, ',') left-compacts the CSV
-- and silently shifts every later slot.  Emitters must fold the
-- delimiter into the measure and strip the leading one:
--
--   SUBSTR(LISTAGG(',' || nullable_token) WITHIN GROUP (...), 2)
--
-- because ','||NULL = ',' still contributes the empty slot.  lint.sh
-- rejects the bare LISTAGG(CASE...) form.
--
-- Usage: include this file *inside* a section's DECLARE block, BEFORE
-- the BEGIN keyword:
--
--   DECLARE
--       v_foo NUMBER;
--       @@sql/lib/nth_csv.plsql
--   BEGIN
--       ...
--       v_per_sec_s := nth_csv(m.week_vals, k + 1);
--       ...
--   END;
--   /
--
-- Slot k+1 corresponds to week_offset = k (since LISTAGG ASC puts
-- week_offset=0 first; the caller's convention is to keep the spark
-- payload DESC for the trend chart and the week_vals payload ASC for
-- column rendering, so callers usually pass k+1 here).
--
-- Returns NULL when p_str/p_n are missing or when the requested slot
-- doesn't exist.  Empty slot ('') is returned as a zero-length string,
-- which the caller renders as &mdash;.
--
    FUNCTION nth_csv(p_str VARCHAR2, p_n POSITIVE) RETURN VARCHAR2 IS
        v_start PLS_INTEGER := 1;
        v_end   PLS_INTEGER;
        v_cnt   PLS_INTEGER := 0;
    BEGIN
        IF p_str IS NULL OR p_n IS NULL OR p_n < 1 THEN
            RETURN NULL;
        END IF;
        LOOP
            v_end := INSTR(p_str, ',', v_start);
            v_cnt := v_cnt + 1;
            IF v_cnt = p_n THEN
                IF v_end = 0 THEN
                    RETURN SUBSTR(p_str, v_start);
                ELSE
                    RETURN SUBSTR(p_str, v_start, v_end - v_start);
                END IF;
            END IF;
            EXIT WHEN v_end = 0;
            v_start := v_end + 1;
        END LOOP;
        RETURN NULL;
    END nth_csv;
