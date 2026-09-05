--
-- sql/lib/dev_bucket.plsql
--
-- Local PL/SQL helper returning the ` data-dev="1|2|3"` attribute (or ''
-- for no attribute) for a per-window PRIOR value cell, based on how far
-- that prior value deviates from the row's Current value:
--   |prior - current| / |current| < 10%  -> no attribute
--                                 < 25%  -> data-dev="1"
--                                 < 50%  -> data-dev="2"
--                                >= 50%  -> data-dev="3"
-- Current = 0 or NULL: prior also 0/NULL -> no attribute, else data-dev="3".
-- A NULL prior (the cell itself renders as &mdash;) always gets no
-- attribute -- there is nothing to tint.
--
-- Chrome/CSS consumes the attribute; this file only computes the bucket
-- from values already resolved at the call site (no new SQL).
--
-- Usage: include inside a section's DECLARE block, alongside nth_csv:
--   DECLARE
--       @@sql/lib/nth_csv.plsql
--       @@sql/lib/dev_bucket.plsql
--   BEGIN
--       v_row := v_row || '<td class="num" data-w="' || k || '"'
--             || dev_attr(m.cur_ps, v_per_sec) || '>' ...
--
    FUNCTION dev_attr(p_cur NUMBER, p_prior NUMBER) RETURN VARCHAR2 IS
        v_ratio NUMBER;
    BEGIN
        IF p_prior IS NULL THEN
            RETURN '';
        END IF;
        IF p_cur IS NULL OR p_cur = 0 THEN
            IF p_prior = 0 THEN
                RETURN '';
            ELSE
                RETURN ' data-dev="3"';
            END IF;
        END IF;
        v_ratio := ABS(p_prior - p_cur) / ABS(p_cur);
        RETURN CASE
            WHEN v_ratio < 0.10 THEN ''
            WHEN v_ratio < 0.25 THEN ' data-dev="1"'
            WHEN v_ratio < 0.50 THEN ' data-dev="2"'
            ELSE                     ' data-dev="3"'
        END;
    END dev_attr;
