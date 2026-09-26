--
-- sql/lib/wingrid.plsql
--
-- The ONE window component (v1.6.0, "Mock D" .wg): one column per compared
-- window, oldest on the left, the Current window last and wider, release
-- flags on the column boundaries.  The Summary hero strip (08), the finding
-- card charts (07) and the configuration card (12) use it today; the
-- Timeline view's grid (phase 3) reuses the same markup, ruler and JS.
--
-- Markup contract (the client half is sql/lib/js_wingrid.plsql, the CSS
-- is the ".wg" block in sql/_style.sql):
--   <div class="wg [bare] [fit] [allv] [hov]" data-wg style="--np:N">
--     [ruler]  <div class="ruler"><div class="rin"> corner | .flags | .h x
--              (N+1) | .gh </div></div>                    (wg_ruler_put)
--     [flags]  <div class="r fr ..."><div class="flags"></div></div>  (wg_flags)
--     [rows]   <div class="r bars" data-v="csv" data-mu data-sd data-sev>
--              [.l label] .c x (N+1) [.g gutter]</div>            (wg_bars)
--     [dates]  <div class="r dr"> .h x (N+1) </div>               (wg_dates)
--   </div>
--   N = weeks_back (prior windows); every column carries data-w = its
--   week_offset (0 = Current), the report-wide window key (X2 highlight).
--   "bare" = no label / gutter columns (card charts).  data-v is the
--   positional CSV of the row's values, OLDEST first, '' for a window
--   with no value; data-mu / data-sd are the prior mean / sd in the same
--   (display) unit; data-sev the change bucket of the Current value.
--
-- Values come in as offset-keyed pairs 'k:v;k:v' (the LISTAGG shape 07
-- builds, see wg_tok), so a skipped window can never shift a slot.
--
-- Include inside a DECLARE block AFTER sql/lib/fmt_num.plsql (uses
-- fmt_num) and sql/lib/off_label.plsql (uses off_label; lint check 29).
-- Declares only functions (no TYPE), reads the run DEFINEs
-- target_end_resolved / step_hours / win_hours / weeks_back.
-- No tilde-words in comments below.
-- Twin: demo/awrdemo/helpers.py (wg_* functions).
--

    -- one value as a compact, NLS-proof token: 7 significant digits,
    -- text-minimum format, dot decimal; NULL -> ''.
    FUNCTION wg_tok(p_v NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_v IS NULL THEN RETURN NULL; END IF;
        IF p_v = 0 THEN RETURN '0'; END IF;
        RETURN TO_CHAR(ROUND(p_v, 6 - FLOOR(LOG(10, ABS(p_v)))), 'TM9',
                       'NLS_NUMERIC_CHARACTERS=''.,''');
    END wg_tok;

    -- the value for window p_off out of 'k:v;k:v' pairs (NULL = none)
    FUNCTION wg_val(p_pairs VARCHAR2, p_off NUMBER) RETURN NUMBER IS
        v_s   VARCHAR2(32767) := ';' || p_pairs || ';';
        v_key VARCHAR2(20)    := ';' || TO_CHAR(p_off) || ':';
        v_i   PLS_INTEGER;
        v_j   PLS_INTEGER;
    BEGIN
        IF p_pairs IS NULL THEN RETURN NULL; END IF;
        v_i := INSTR(v_s, v_key);
        IF v_i = 0 THEN RETURN NULL; END IF;
        v_i := v_i + LENGTH(v_key);
        v_j := INSTR(v_s, ';', v_i);
        IF v_j <= v_i THEN RETURN NULL; END IF;
        -- the driver pins NLS_NUMERIC_CHARACTERS to '.,' (see CLAUDE.md), and
        -- wg_tok writes a dot decimal, so the plain TO_NUMBER round-trips
        RETURN TO_NUMBER(SUBSTR(v_s, v_i, v_j - v_i));
    END wg_val;

    FUNCTION wg_end(p_off NUMBER) RETURN DATE IS
    BEGIN
        RETURN TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') - p_off * (~step_hours/24);
    END wg_end;

    FUNCTION wg_start(p_off NUMBER) RETURN DATE IS
    BEGIN
        RETURN wg_end(p_off) - ~win_hours/24;
    END wg_start;

    -- column label: the date for a daily / weekly cadence, the clock time
    -- for a sub-day one
    FUNCTION wg_date(p_off NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF ~step_hours >= 24 THEN
            RETURN TO_CHAR(wg_start(p_off), 'FMDD Mon', 'NLS_DATE_LANGUAGE=ENGLISH');
        END IF;
        RETURN TO_CHAR(wg_start(p_off), 'HH24:MI');
    END wg_date;

    FUNCTION wg_off(p_off NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_off = 0 THEN RETURN 'current'; END IF;
        RETURN '&minus;' || off_label(p_off);
    END wg_off;

    FUNCTION wg_title(p_off NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(wg_start(p_off), 'Dy DD Mon, HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH') || '&ndash;'
            || TO_CHAR(wg_end(p_off), 'HH24:MI');
    END wg_title;

    -- the column keeps its date label when the grid is tight: the oldest,
    -- every 4th after it (every n-th past 48 windows, about 12 labels in
    -- all), and Current
    FUNCTION wg_keep(p_off NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p_off = 0
                      OR MOD(~weeks_back - p_off, GREATEST(4, CEIL((~weeks_back + 1) / 12))) = 0
                    THEN ' keep' END;
    END wg_keep;

    -- the attributes every .wg root carries
    FUNCTION wg_attr RETURN VARCHAR2 IS
    BEGIN
        -- data-many (more than 30 prior windows): the Summary's fitted
        -- grids shrink their column minimum so they stay inside the page
        -- (the Timeline grid, #tl, keeps its minimum and scrolls)
        RETURN ' data-wg' || CASE WHEN ~weeks_back > 30 THEN ' data-many' END
            || ' style="--np:' || TO_CHAR(~weeks_back) || '"';
    END wg_attr;

    -- positional CSV (oldest first) of pairs x scale
    FUNCTION wg_csv(p_pairs VARCHAR2, p_scale NUMBER DEFAULT 1) RETURN VARCHAR2 IS
        v_out VARCHAR2(32767);
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_out := v_out || CASE WHEN k < ~weeks_back THEN ',' END
                  || wg_tok(wg_val(p_pairs, k) * p_scale);
        END LOOP;
        RETURN v_out;
    END wg_csv;

    FUNCTION wg_flags(p_bare BOOLEAN DEFAULT TRUE) RETURN VARCHAR2 IS
    BEGIN
        IF p_bare THEN
            RETURN '<div class="r fr t2" aria-hidden="true"><div class="flags"></div></div>';
        END IF;
        RETURN '<div class="r fr"><div class="l"></div><div class="flags"'
            || ' aria-label="Release and patch markers"></div><div class="g"></div></div>';
    END wg_flags;

    FUNCTION wg_dates(p_bare BOOLEAN DEFAULT TRUE) RETURN VARCHAR2 IS
        v_out VARCHAR2(32767) := '<div class="r dr" aria-hidden="true">';
    BEGIN
        IF NOT p_bare THEN v_out := v_out || '<div class="l"></div>'; END IF;
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_out := v_out || '<div class="h' || CASE WHEN k = 0 THEN ' cur' END || wg_keep(k)
                || '" data-w="' || k || '"><span class="hd">' || wg_date(k) || '</span>'
                || CASE WHEN NOT p_bare THEN '<span class="ho">' || wg_off(k) || '</span>' END
                || '</div>';
        END LOOP;
        IF NOT p_bare THEN v_out := v_out || '<div class="g"></div>'; END IF;
        RETURN v_out || '</div>';
    END wg_dates;

    -- Output line buffer (any window count): append p_s to p_buf, first
    -- flushing p_buf as its own DBMS_OUTPUT line when the two together
    -- would pass 32000 bytes (a PUT_LINE holds at most 32767 bytes and a
    -- VARCHAR2 32767).  Markup may break between any two elements, so a
    -- long ruler or lane row simply spans several lines; the usual 13
    -- windows stay on one line.  The caller PUT_LINEs what is left.
    PROCEDURE wg_buf(p_buf IN OUT NOCOPY VARCHAR2, p_s VARCHAR2) IS
    BEGIN
        IF NVL(LENGTHB(p_buf), 0) + NVL(LENGTHB(p_s), 0) > 32000 THEN
            DBMS_OUTPUT.PUT_LINE(p_buf);
            p_buf := p_s;
        ELSE
            p_buf := p_buf || p_s;
        END IF;
    END wg_buf;

    -- the window ruler: corner | flags over the dates | gutter head,
    -- EMITTED (not returned: about 240 bytes a window, so 138 or more
    -- windows would overflow one VARCHAR2) between p_pre and p_post
    -- through wg_buf.  p_btn 'Y' (the Timeline grid): each date is a
    -- button that pins its window as the comparison target
    -- (sql/lib/js_timeline.plsql).
    PROCEDURE wg_ruler_put(p_pre    VARCHAR2,
                           p_corner VARCHAR2,
                           p_gh     VARCHAR2,
                           p_btn    VARCHAR2 DEFAULT 'N',
                           p_post   VARCHAR2 DEFAULT NULL) IS
        v_buf VARCHAR2(32767);
        v_tag VARCHAR2(8) := CASE WHEN p_btn = 'Y' THEN 'button' ELSE 'div' END;
    BEGIN
        wg_buf(v_buf, p_pre);
        wg_buf(v_buf, '<div class="ruler"><div class="rin" role="row">'
            || '<div class="corner" role="columnheader">' || p_corner || '</div>'
            || '<div class="flags" aria-label="Release and patch markers"></div>');
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            wg_buf(v_buf, '<' || v_tag || ' class="h' || CASE WHEN k = 0 THEN ' cur' END || wg_keep(k)
                || '"' || CASE WHEN p_btn = 'Y' THEN ' type="button" aria-pressed="false"' END
                || ' data-w="' || k || '" role="columnheader" title="' || wg_title(k)
                || CASE WHEN p_btn = 'Y' AND k > 0 THEN '. Click to pin as the comparison target'
                        WHEN p_btn = 'Y' THEN '. The Current window' END || '">'
                || '<span class="hd">' || wg_date(k) || '</span>'
                || '<span class="ho">' || wg_off(k) || '</span></' || v_tag || '>');
        END LOOP;
        wg_buf(v_buf, '<div class="gh" role="columnheader">' || p_gh || '</div></div></div>');
        wg_buf(v_buf, p_post);
        DBMS_OUTPUT.PUT_LINE(v_buf);
    END wg_ruler_put;

    -- one bars row: every window's value as a grey column (Current in the
    -- accent), the prior normal zone behind them and a severity dot on the
    -- Current bar (drawn client-side from data-v / data-mu / data-sd).
    FUNCTION wg_bars(p_pairs VARCHAR2,
                     p_scale NUMBER,
                     p_mu    NUMBER,
                     p_sd    NUMBER,
                     p_sev   VARCHAR2,
                     p_lab   VARCHAR2 DEFAULT NULL,
                     p_gut   VARCHAR2 DEFAULT NULL,
                     p_id    VARCHAR2 DEFAULT NULL,
                     p_cls   VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        v_out VARCHAR2(32767);
        v_v   NUMBER;
    BEGIN
        v_out := '<div class="r bars' || CASE WHEN p_cls IS NOT NULL THEN ' ' || p_cls END || '"'
            || CASE WHEN p_id IS NOT NULL THEN ' id="' || p_id || '"' END
            || ' data-v="' || wg_csv(p_pairs, p_scale) || '"'
            || ' data-mu="' || wg_tok(p_mu * p_scale) || '"'
            || ' data-sd="' || wg_tok(p_sd * p_scale) || '"'
            || ' data-sev="' || p_sev || '" role="row">'
            || p_lab;
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_v := wg_val(p_pairs, k) * p_scale;
            v_out := v_out || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                || '" data-w="' || k || '">'
                || CASE WHEN v_v IS NULL
                        THEN '<span class="v nil" aria-label="no value">&ndash;</span>'
                        ELSE '<span class="v">' || fmt_num(v_v) || '</span>' END
                || '</div>';
        END LOOP;
        RETURN v_out || p_gut || '</div>';
    END wg_bars;
