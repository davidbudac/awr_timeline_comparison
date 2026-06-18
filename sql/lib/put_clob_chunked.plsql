--
-- sql/lib/put_clob_chunked.plsql
--
-- Local PL/SQL helper for sections that build JSON or other long
-- payloads into a CLOB to avoid PL/SQL's 32767-byte VARCHAR2 hard
-- cap (which manifests as ORA-06502 "character string buffer too
-- small" on naive concat accumulation). DBMS_OUTPUT.PUT_LINE still
-- has a per-line 32767 limit, so this helper walks the CLOB in
-- chunks of up to 32500 chars and emits each via PUT_LINE.
--
-- Each PUT_LINE injects a newline at the chunk boundary. That newline
-- is harmless whitespace ONLY between tokens -- if a fixed-offset split
-- landed inside a quoted string ("2026-...\n...12:15") or a number
-- (12\n34), the emitted JS/JSON breaks (string literals can't span a
-- raw line terminator; two numbers need a comma). So every chunk is
-- backed off to end on the last comma in its window, guaranteeing the
-- newline always lands between array elements. Callers therefore pass
-- comma-separated payloads (JSON arrays, CSV value lists) and can
-- sandwich this between PUT_LINE calls that emit the surrounding
-- prefix/suffix (e.g. "times:" before, "," after) without worrying
-- about chunk boundaries.
--
-- Usage: include this file *inside* a section's DECLARE block, BEFORE
-- the BEGIN keyword (same pattern as sql/lib/nth_csv.plsql):
--
--   DECLARE
--       v_json CLOB;
--       @@sql/lib/put_clob_chunked.plsql
--   BEGIN
--       DBMS_LOB.CREATETEMPORARY(v_json, TRUE);
--       ... DBMS_LOB.WRITEAPPEND(v_json, ...) ...
--       DBMS_OUTPUT.PUT_LINE('times:');
--       put_clob_chunked(v_json);
--       DBMS_OUTPUT.PUT_LINE(',');
--       DBMS_LOB.FREETEMPORARY(v_json);
--   END;
--   /
--
-- Returns silently when p_clob is NULL or zero-length so callers can
-- pass an uninitialized CLOB without a guard.
--
    PROCEDURE put_clob_chunked(p_clob IN CLOB) IS
        c_chunk CONSTANT PLS_INTEGER := 32500;
        v_len   PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
        v_pos   PLS_INTEGER := 1;
        v_take  PLS_INTEGER;
        v_cut   PLS_INTEGER;
    BEGIN
        IF v_len = 0 THEN
            RETURN;
        END IF;
        WHILE v_pos <= v_len LOOP
            v_take := LEAST(c_chunk, v_len - v_pos + 1);
            -- Not the final chunk: back off to the last comma in this
            -- window so the newline PUT_LINE injects lands between array
            -- elements, never inside a string literal or a number. v_cut=0
            -- (no comma in 32500 chars) is impossible for the small tokens
            -- callers emit; if it ever happened we'd fall back to the hard
            -- split rather than loop forever.
            IF v_pos + v_take - 1 < v_len THEN
                v_cut := INSTR(DBMS_LOB.SUBSTR(p_clob, v_take, v_pos), ',', -1);
                IF v_cut > 0 THEN
                    v_take := v_cut;   -- include the comma; next chunk starts after it
                END IF;
            END IF;
            DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_clob, v_take, v_pos));
            v_pos := v_pos + v_take;
        END LOOP;
    END put_clob_chunked;
