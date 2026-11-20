--
-- sql/lib/fmt_num.plsql
-- T7: consistent human-readable number formatting for report VALUE cells
-- (Current / prior-window / prior-mean / prior-sd / hero headline & range
-- text). NOT for %-delta or z-score cells (score_cells.plsql owns those),
-- NOT for data-spark/CSV or window.AWR_DATA JSON payloads (those stay raw
-- numbers under the driver's pinned NLS_NUMERIC_CHARACTERS='.,'), and NOT
-- for naturally-integer counts (n, snap ids, ranks, plan counts).
--
-- Designed to be @@-included into a DECLARE block, same pattern as
-- score_cells.plsql / band_glyph.plsql:
--   DECLARE
--       @@sql/lib/fmt_num.plsql
--   BEGIN
--       v_row := v_row || '<td class="num"' || fmt_num_title(m.cur)
--             || '>' || fmt_num(m.cur) || '</td>';
--
-- fmt_num(p) rules:
--   NULL            -> '&mdash;'
--   0               -> '0'
--   |v| >= 1e9      -> v/1e9, formatted per the brackets below, + ' G'
--   |v| >= 1e6      -> v/1e6, formatted per the brackets below, + ' M'
--   |v| >= 1e4      -> v/1e3, formatted per the brackets below, + ' k'
--   otherwise, format the (possibly already-scaled) magnitude as roughly
--   four significant digits with thousands separators:
--     >= 1000            -> no decimals                  (e.g. "4,398")
--     100   <= v < 1000   -> 1 decimal                    (e.g. "418.3")
--     10    <= v < 100    -> 2 decimals                   (e.g. "41.83")
--     1     <= v < 10     -> 3 decimals                   (e.g. "4.183")
--     0     <  v < 1      -> true 4 significant digits, decimal places
--                            computed from magnitude (3 - floor(log10(v))),
--                            capped at 6 and trailing zeros trimmed via an
--                            optional-digit ('9') format model, e.g.
--                            0.0236, 0.000282; a value that still rounds
--                            to 0 at 6 decimals shows '<0.000001' instead
--                            of switching to scientific notation.
-- The sign is preserved on negative values; the k/M/G suffix always uses
-- a single literal space before the letter (matches 00_params.sql's
-- click-to-sort numOf() parser, which strips whitespace before matching
-- the trailing k/M/G multiplier -- keep that letter set and case in sync
-- if this ever changes).
--
-- fmt_num_title(p) returns a ready-to-splice ` title="..."` attribute
-- carrying the full-precision raw value (grouped, 4 fixed decimals), or ''
-- when p IS NULL. Intended for the Current-value cell only, to keep HTML
-- size sane on wide detail tables.
--
-- fmt_dur(p, short) -- a duration in seconds as words of time (see the
-- function).
--
    FUNCTION fmt_num(p NUMBER) RETURN VARCHAR2 IS
        v_sign VARCHAR2(1) := '';
        v_abs  NUMBER;
        v_val  NUMBER;
        v_suf  VARCHAR2(2) := '';
        v_dec  NUMBER;
        v_txt  VARCHAR2(100);
    BEGIN
        IF p IS NULL THEN
            RETURN '&mdash;';
        END IF;
        IF p = 0 THEN
            RETURN '0';
        END IF;

        v_abs := ABS(p);
        IF p < 0 THEN
            v_sign := '-';
        END IF;

        IF v_abs >= 1e9 THEN
            v_val := v_abs / 1e9;
            v_suf := ' G';
        ELSIF v_abs >= 1e6 THEN
            v_val := v_abs / 1e6;
            v_suf := ' M';
        ELSIF v_abs >= 1e4 THEN
            v_val := v_abs / 1e3;
            v_suf := ' k';
        ELSE
            v_val := v_abs;
        END IF;

        IF v_val >= 1000 THEN
            v_txt := TO_CHAR(ROUND(v_val), 'FM999G999G999G999G990',
                              'NLS_NUMERIC_CHARACTERS=''.,''');
        ELSIF v_val >= 100 THEN
            v_txt := TO_CHAR(v_val, 'FM999G990D0',
                              'NLS_NUMERIC_CHARACTERS=''.,''');
        ELSIF v_val >= 10 THEN
            v_txt := TO_CHAR(v_val, 'FM999G990D00',
                              'NLS_NUMERIC_CHARACTERS=''.,''');
        ELSIF v_val >= 1 THEN
            v_txt := TO_CHAR(v_val, 'FM990D000',
                              'NLS_NUMERIC_CHARACTERS=''.,''');
        ELSE
            -- 0 < v_val < 1: true 4 significant digits, capped at 6
            -- decimal places; '<0.000001' if it still rounds to zero there.
            v_dec := LEAST(6, 3 - FLOOR(LOG(10, v_val)));
            IF ROUND(v_val, 6) = 0 THEN
                RETURN v_sign || '<0.000001';
            END IF;
            v_txt := TO_CHAR(ROUND(v_val, v_dec), 'FM0D999999',
                              'NLS_NUMERIC_CHARACTERS=''.,''');
        END IF;

        RETURN v_sign || v_txt || v_suf;
    END fmt_num;

    FUNCTION fmt_num_title(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN
            RETURN '';
        END IF;
        RETURN ' title="' || TO_CHAR(p, 'FM999G999G999G990D0999',
                    'NLS_NUMERIC_CHARACTERS=''.,''') || '"';
    END fmt_num_title;

    -- Plain integer counts (executions, snapshots): thousands-grouped, no
    -- decimals, no SI suffix -- a count of 583 must read "583", not "583.0".
    FUNCTION fmt_int(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN
            RETURN '&mdash;';
        END IF;
        RETURN TO_CHAR(ROUND(p), 'FM999G999G999G999G990',
                    'NLS_NUMERIC_CHARACTERS=''.,''');
    END fmt_int;

    -- fmt_dur(p_sec, p_short): a duration given in seconds, as words of
    -- time, for Summary-view text (the plan-change card, evidence rows).
    -- NOT for table cells (they keep seconds with the unit in the header:
    -- precise, sortable, exportable) and NOT for data-v / data-spark /
    -- AWR_DATA payloads (raw numbers).
    --   NULL          -> '&mdash;'          0           -> '0 s'
    --   under 1 s     -> '950 ms' (whole ms from 10 ms, '4.2 ms' below,
    --                    '<0.1 ms' when it rounds to zero)
    --   under 60 s    -> '8.0 s' (one decimal)
    --   under 1 h     -> '1 m 54 s' ('2 m' when the seconds round to 0)
    --   under 48 h    -> '7 h 45 m' ('7 h')
    --   otherwise     -> '3 d 4 h'  ('3 d')
    -- p_short = 'Y', for narrow window-bar labels: one unit only --
    -- '950 ms', '8.0 s', '38 m', '7.8 h', '31 h', '2.3 d'.
    -- A negative input keeps its sign.
    FUNCTION fmt_dur(p_sec NUMBER, p_short VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_sign VARCHAR2(1);
        v_a    NUMBER;
        v_r    NUMBER;
        v_hi   NUMBER;
        v_lo   NUMBER;
    BEGIN
        IF p_sec IS NULL THEN RETURN '&mdash;'; END IF;
        IF p_sec = 0 THEN RETURN '0 s'; END IF;
        v_sign := CASE WHEN p_sec < 0 THEN '-' END;
        v_a    := ABS(p_sec);
        v_r    := v_a * 1000;                                -- milliseconds
        IF ROUND(v_r) < 1000 THEN
            IF v_r >= 9.95 THEN
                RETURN v_sign || TO_CHAR(ROUND(v_r)) || ' ms';
            ELSIF ROUND(v_r, 1) = 0 THEN
                RETURN v_sign || '<0.1 ms';
            END IF;
            RETURN v_sign || TO_CHAR(ROUND(v_r, 1), 'FM999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' ms';
        END IF;
        IF ROUND(v_a, 1) < 60 THEN
            RETURN v_sign || TO_CHAR(ROUND(v_a, 1), 'FM999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' s';
        END IF;
        IF p_short = 'Y' THEN
            IF ROUND(v_a / 60) < 60 THEN
                RETURN v_sign || TO_CHAR(ROUND(v_a / 60)) || ' m';
            END IF;
            v_r := v_a / 3600;
            IF ROUND(v_r, 1) < 10 THEN
                RETURN v_sign || TO_CHAR(ROUND(v_r, 1), 'FM999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' h';
            ELSIF ROUND(v_r) < 48 THEN
                RETURN v_sign || TO_CHAR(ROUND(v_r)) || ' h';
            END IF;
            v_r := v_a / 86400;
            RETURN v_sign || CASE WHEN ROUND(v_r, 1) < 10
                                  THEN TO_CHAR(ROUND(v_r, 1), 'FM999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                                  ELSE TO_CHAR(ROUND(v_r)) END || ' d';
        END IF;
        v_r := ROUND(v_a);                                   -- whole seconds
        IF v_r < 3600 THEN
            v_hi := TRUNC(v_r / 60);
            v_lo := MOD(v_r, 60);
            RETURN v_sign || TO_CHAR(v_hi) || ' m' || CASE WHEN v_lo > 0 THEN ' ' || TO_CHAR(v_lo) || ' s' END;
        END IF;
        v_r := ROUND(v_a / 60);                              -- whole minutes
        IF v_r < 2880 THEN
            v_hi := TRUNC(v_r / 60);
            v_lo := MOD(v_r, 60);
            RETURN v_sign || TO_CHAR(v_hi) || ' h' || CASE WHEN v_lo > 0 THEN ' ' || TO_CHAR(v_lo) || ' m' END;
        END IF;
        v_r := ROUND(v_a / 3600);                            -- whole hours
        v_hi := TRUNC(v_r / 24);
        v_lo := MOD(v_r, 24);
        RETURN v_sign || TO_CHAR(v_hi) || ' d' || CASE WHEN v_lo > 0 THEN ' ' || TO_CHAR(v_lo) || ' h' END;
    END fmt_dur;
