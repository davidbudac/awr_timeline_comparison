--
-- sql/lib/put_clob_chunked.plsql
--
-- Local PL/SQL helper for sections that build JSON or other long
-- payloads into a CLOB to avoid PL/SQL's 32767-byte VARCHAR2 hard
-- cap (which manifests as ORA-06502 "character string buffer too
-- small" on naive concat accumulation). DBMS_OUTPUT.PUT_LINE still
-- has a per-line 32767 limit, so this helper walks the CLOB in
-- 32500-char chunks and emits each via PUT_LINE.
--
-- Newlines between chunks are valid whitespace inside JSON array
-- literals AND inside JavaScript source text, so callers can sandwich
-- this between PUT_LINE calls that emit the surrounding prefix/suffix
-- (e.g. "times:" before, "," after) without worrying about chunk
-- boundaries.
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
    BEGIN
        IF v_len = 0 THEN
            RETURN;
        END IF;
        WHILE v_pos <= v_len LOOP
            DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_clob, c_chunk, v_pos));
            v_pos := v_pos + c_chunk;
        END LOOP;
    END put_clob_chunked;
