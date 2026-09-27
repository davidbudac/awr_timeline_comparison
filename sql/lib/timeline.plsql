--
-- sql/lib/timeline.plsql
--
-- The Timeline view's grid rows (v1.6.0, Mock D "Timeline" = mock C's
-- aligned window grid).  One row per metric / wait class / event /
-- segment / file / statement / parameter, on the SAME window component as
-- the Summary charts (sql/lib/wingrid.plsql markup, .wg CSS, the client
-- half in sql/lib/js_wingrid.plsql + sql/lib/js_timeline.plsql).
--
-- Every section that owns a lane emits its rows from the cursor that
-- builds its own table (never a separate slice), wrapped in an inert
-- <template class="tl-src" data-lane="lane-X"> that an inline script
-- moves into the lane the Timeline skeleton (00_params.sql) reserved:
--   tl_open('metrics') || rows || tl_close
-- Lanes: activity (09), metrics (07), waits (07 class rows, 04 events),
-- objects (14 segments, 15 files), sql (06 statements, 18 SQL Monitor
-- sub-rows), config (12).  With JavaScript off the templates stay inert:
-- the Timeline then shows its header and a note, and every number is in
-- the All sections tables.
--
-- Row id = 'tl-' || the id of the row's detail row (tl-fr-l-physical-reads,
-- tl-we-<event>, tl-pa-<parameter> ...), the target of the finding cards'
-- "Timeline ->" links (data-tl); the row label is an entity link (ent()) to
-- that detail row.
--
-- Values: p_csv is the row's positional CSV, OLDEST window first, one
-- wg_tok() token per window ('' = no value) -- tl_csv() converts the
-- LISTAGG shapes the sections already build.  Only the Current value is
-- printed server-side; the prior values are filled client-side from
-- data-v (hover / pin shows them), like the mock, to keep the file small.
-- The gutter is the band + Delta of the Summary for a scored row
-- (tl_gut), or a plain ratio for a ranked, unscored one (tl_gutp).
--
-- Include inside a DECLARE block AFTER sql/lib/fmt_num.plsql,
-- sql/lib/band_glyph.plsql, sql/lib/anchor_id.plsql,
-- sql/lib/finding_cards.plsql (ent) and sql/lib/wingrid.plsql (wg_tok,
-- wg_date) -- lint check 22.  Declares only functions (no TYPE).  Reads
-- the weeks_back DEFINE.  No tilde-words in comments below.
-- Twin: demo/awrdemo/helpers.py (tl_* functions).
--

    -- a section's rows ride in an inert template; the script right after
    -- it moves them into the lane (sql/lib/js_timeline.plsql AWR_TL.take)
    FUNCTION tl_open(p_lane VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<template class="tl-src" data-lane="lane-' || p_lane || '">';
    END tl_open;

    FUNCTION tl_close RETURN VARCHAR2 IS
    BEGIN
        RETURN '</template><script>if(window.AWR_TL)AWR_TL.take();</script>';
    END tl_close;

    -- token p_k (1-based) of a comma-separated list; '' / 'null' -> NULL
    FUNCTION tl_nth(p_csv VARCHAR2, p_k PLS_INTEGER) RETURN VARCHAR2 IS
        v_s PLS_INTEGER := 1;
        v_e PLS_INTEGER;
        v_t VARCHAR2(200);
    BEGIN
        IF p_csv IS NULL THEN RETURN NULL; END IF;
        FOR i IN 2 .. p_k LOOP
            v_s := INSTR(p_csv, ',', v_s);
            IF v_s = 0 THEN RETURN NULL; END IF;
            v_s := v_s + 1;
        END LOOP;
        v_e := INSTR(p_csv, ',', v_s);
        v_t := CASE WHEN v_e = 0 THEN SUBSTR(p_csv, v_s) ELSE SUBSTR(p_csv, v_s, v_e - v_s) END;
        RETURN CASE WHEN v_t = 'null' THEN NULL ELSE v_t END;
    END tl_nth;

    -- A section's LISTAGG CSV (dot-decimal, '' or 'null' for a window with
    -- no value) as the Timeline's data-v: oldest window first, value
    -- divided by p_div, one wg_tok() token each.  p_asc 'Y' = the input is
    -- ORDER BY week_offset ASC (token 1 = Current), else DESC (oldest first).
    -- The driver pins NLS_NUMERIC_CHARACTERS to '.,', so TO_NUMBER parses.
    FUNCTION tl_csv(p_csv VARCHAR2, p_asc VARCHAR2 DEFAULT 'N', p_div NUMBER DEFAULT 1) RETURN VARCHAR2 IS
        v_out VARCHAR2(32767);
        v_t   VARCHAR2(200);
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_t := tl_nth(p_csv, CASE WHEN p_asc = 'Y' THEN k + 1 ELSE ~weeks_back - k + 1 END);
            v_out := v_out || CASE WHEN k < ~weeks_back THEN ',' END
                || CASE WHEN v_t IS NOT NULL THEN wg_tok(TO_NUMBER(v_t) / p_div) END;
        END LOOP;
        RETURN v_out;
    END tl_csv;

    -- the value of window p_off in a Timeline CSV (oldest first)
    FUNCTION tl_val(p_csv VARCHAR2, p_off NUMBER) RETURN NUMBER IS
        v_t VARCHAR2(200) := tl_nth(p_csv, ~weeks_back - p_off + 1);
    BEGIN
        RETURN CASE WHEN v_t IS NOT NULL THEN TO_NUMBER(v_t) END;
    END tl_val;

    -- the mean of the prior windows that have a value (ranked rows)
    FUNCTION tl_mu(p_csv VARCHAR2) RETURN NUMBER IS
        v_s NUMBER := 0;
        v_n PLS_INTEGER := 0;
        v_v NUMBER;
    BEGIN
        FOR k IN 1 .. ~weeks_back LOOP
            v_v := tl_val(p_csv, k);
            IF v_v IS NOT NULL THEN v_s := v_s + v_v; v_n := v_n + 1; END IF;
        END LOOP;
        RETURN CASE WHEN v_n > 0 THEN v_s / v_n END;
    END tl_mu;

    -- The oldest window offset with a value, when the row was ABSENT from
    -- at least one older VALID window (a statement "first seen" there);
    -- NULL otherwise.  p_valid holds one Y / N per window, character k + 1
    -- = week_offset k (built from windows_rollup by the caller).  A skipped
    -- window (invalid, restart, no snapshots) has no value because nothing
    -- was measured there, not because the row was absent: it counts as
    -- unknown, so a row is never "new" merely because the oldest compared
    -- windows were skipped (e.g. weekly cadence past AWR retention).
    FUNCTION tl_first(p_csv VARCHAR2, p_valid VARCHAR2) RETURN NUMBER IS
        v_first NUMBER;
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            IF tl_val(p_csv, k) IS NOT NULL THEN v_first := k; EXIT; END IF;
        END LOOP;
        IF v_first IS NULL THEN RETURN NULL; END IF;
        FOR k IN v_first + 1 .. ~weeks_back LOOP
            IF SUBSTR(p_valid, k + 1, 1) = 'Y' THEN RETURN v_first; END IF;
        END LOOP;
        RETURN NULL;
    END tl_first;

    -- the row label: name (an entity link) + one muted line; p_wc paints a
    -- wait-class swatch (colour from AWR_WAIT_COLORS, client-side)
    FUNCTION tl_lab(p_nm   VARCHAR2,
                    p_sub  VARCHAR2 DEFAULT NULL,
                    p_ttl  VARCHAR2 DEFAULT NULL,
                    p_wc   VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="l" role="rowheader"'
            || CASE WHEN p_ttl IS NOT NULL THEN ' title="' || p_ttl || '"' END || '>'
            || '<span class="nm">'
            || CASE WHEN p_wc IS NOT NULL
                    THEN '<i class="sw" data-wc="' || DBMS_XMLGEN.CONVERT(p_wc) || '" aria-hidden="true"></i>' END
            || p_nm || '</span>'
            || CASE WHEN p_sub IS NOT NULL THEN '<span class="sub">' || p_sub || '</span>' END
            || '</div>';
    END tl_lab;

    -- scored gutter: Delta (bold) and z on one line, the small band under
    -- it; the z is left out when the band pins and prints it itself
    -- (beyond +8 / below -4 sigma), and p_note replaces it (a glyph note)
    FUNCTION tl_gut(p_cur    NUMBER,
                    p_mu     NUMBER,
                    p_sd     NUMBER,
                    p_bucket VARCHAR2,
                    p_note   VARCHAR2 DEFAULT NULL,
                    p_twin   VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_z NUMBER := band_z(p_cur, p_mu, p_sd);
    BEGIN
        RETURN '<div class="g" role="cell"><div class="gl1">'
            || REPLACE(delta_span(p_cur, p_mu, p_bucket), 'class="d ', 'class="d d1 ')
            || CASE WHEN p_note IS NOT NULL THEN p_note
                    WHEN v_z IS NOT NULL AND v_z BETWEEN -4 AND 8
                         AND NVL(p_bucket, 'x') NOT IN ('flat baseline', 'insufficient history', 'n/a')
                    THEN '<span class="z">z ' || band_ztxt(v_z) || '</span>' END
            || '</div>' || band_span(v_z, p_bucket, 'sm', p_twin) || '</div>';
    END tl_gut;

    -- ranked, not scored: a plain Delta vs the prior mean and one note
    FUNCTION tl_gutp(p_cur NUMBER, p_mu NUMBER, p_note VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="g" role="cell" title="Ranked, not scored"><div class="gl1">'
            || REPLACE(delta_span(p_cur, p_mu, NULL, 'Y'), 'class="d ', 'class="d d1 ')
            || '</div><div class="gx">' || p_note || '</div></div>';
    END tl_gutp;

    -- One grid row: data-v (oldest first), the prior normal (mu / sd, NULL
    -- for a ranked row), the Current bucket (the severity dot), the label,
    -- one cell per window (Current printed) and the gutter.  p_gw / p_gl put
    -- one glyph (plan change, first seen, DOP downgrade) in window p_gw;
    -- p_after = the id of the row this one belongs under (18 under 06).
    FUNCTION tl_bars(p_csv   VARCHAR2,
                     p_mu    NUMBER,
                     p_sd    NUMBER,
                     p_sev   VARCHAR2,
                     p_lab   VARCHAR2,
                     p_gut   VARCHAR2,
                     p_id    VARCHAR2,
                     p_cls   VARCHAR2 DEFAULT NULL,
                     p_name  VARCHAR2 DEFAULT NULL,
                     p_unit  VARCHAR2 DEFAULT NULL,
                     p_gw    NUMBER   DEFAULT NULL,
                     p_gl    VARCHAR2 DEFAULT NULL,
                     p_after VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        v_out VARCHAR2(32767);
        v_cur NUMBER := tl_val(p_csv, 0);
    BEGIN
        v_out := '<div class="r bars' || CASE WHEN p_cls IS NOT NULL THEN ' ' || p_cls END || '"'
            || ' id="' || p_id || '" data-v="' || p_csv || '"'
            || ' data-mu="' || wg_tok(p_mu) || '" data-sd="' || wg_tok(p_sd) || '"'
            || ' data-sev="' || p_sev || '"'
            || CASE WHEN p_name IS NOT NULL THEN ' data-name="' || p_name || '"' END
            || CASE WHEN p_unit IS NOT NULL THEN ' data-unit="' || p_unit || '"' END
            || CASE WHEN p_after IS NOT NULL THEN ' data-after="' || p_after || '"' END
            || ' role="row">' || p_lab;
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_out := v_out || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                || '" data-w="' || k || '">'
                || CASE WHEN k = 0 THEN
                        CASE WHEN v_cur IS NULL
                             THEN '<span class="v nil" aria-label="no value">&ndash;</span>'
                             ELSE '<span class="v">' || fmt_num(v_cur) || '</span>' END END
                || CASE WHEN k = p_gw THEN p_gl END
                || '</div>';
        END LOOP;
        RETURN v_out || p_gut || '</div>';
    END tl_bars;
