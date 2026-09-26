--
-- sql/lib/band_glyph.plsql
--
-- The ONE current-vs-prior visual of the report (v1.6.0, "Mock D"): the
-- baseline band glyph.  A dot on a fixed z scale shared by the whole page
-- (z -4 .. +8, so +2 sigma sits at exactly 50%) over the prior "normal"
-- zone (mu +/- 1 sigma dark, +/- 2 sigma light, ticks at +/- 2 and +/- 3
-- sigma).  Pure CSS: one span carrying a --x custom property; the zones and
-- ticks are gradients in sql/_style.sql (".bd").  Past +8 sigma the dot pins
-- to the right edge with an arrow and prints its z (".po"), below -4 to the
-- left (".pu").  Filled red / amber dot = large / moderate finding, hollow =
-- normal (or unscored), teal ring = improved.  A flat baseline (mu = sd = 0)
-- is a hatched track with no dot; too little history is a faded track.
--
-- Also here: the single Delta rule of the page (x n when Current is at least
-- twice the prior mean, else a signed percentage), the normal-range text
-- (mu +/- 2 sigma in the metric's own unit) and band_cells(), the four <td>
-- cells every per-window table appends right after its Current cell:
--   Normal range | band | z | Delta vs mean
-- plus band_head(), the matching four <th> cells (the band header carries
-- the shared sigma axis).
--
-- The sigma floor is the policy's: z = (cur - mu) / max(sd, 2% of |mu|), the
-- same denominator as sql/lib/metric_policy.plsql's policy_bucket(), so a
-- dot always sits where the bucket says it does.  The BUCKET itself is the
-- caller's (policy_bucket / score_bucket, or NULL for an unscored table such
-- as 13): this file only draws it.
--
-- Include order (lint check 17): sql/lib/fmt_num.plsql BEFORE this file
-- (range text), and this file BEFORE sql/lib/score_cells.plsql (which
-- delegates its cells here).  Pure functions, no DB access, no DEFINEs.
-- Twin: demo/awrdemo/helpers.py (band_* / delta_span / range_txt).
--
    FUNCTION band_z(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER) RETURN NUMBER IS
        v_den NUMBER;
    BEGIN
        IF p_cur IS NULL OR p_mu IS NULL OR p_sd IS NULL THEN
            RETURN NULL;
        END IF;
        v_den := GREATEST(p_sd, 0.02 * ABS(p_mu));
        IF v_den = 0 THEN
            RETURN NULL;
        END IF;
        RETURN (p_cur - p_mu) / v_den;
    END band_z;

    -- z as display text: one decimal, sigma suffix, clamped beyond 99.
    FUNCTION band_ztxt(p_z NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_z IS NULL THEN '&mdash;'
            WHEN p_z > 99    THEN '&gt;+99&sigma;'
            WHEN p_z < -99   THEN '&lt;&minus;99&sigma;'
            WHEN ROUND(p_z, 1) < 0 THEN '&minus;' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                       'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
            ELSE '+' || TO_CHAR(ABS(p_z), 'FM99990D0',
                                'NLS_NUMERIC_CHARACTERS=''.,''') || '&sigma;'
        END;
    END band_ztxt;

    -- bucket -> severity class shared by the glyph and the Delta text
    FUNCTION band_sev(p_bucket VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_bucket WHEN 'large'    THEN 's-large'
                             WHEN 'moderate' THEN 's-moderate'
                             WHEN 'improved' THEN 's-improved'
                             ELSE 's-typical' END;
    END band_sev;

    -- The glyph.  p_size: NULL (table cell) | 'sm' | 'lg'.  p_twin 'Y' fades
    -- the dot (a non-canonical twin row).  A NULL bucket = unscored: the dot
    -- is drawn hollow wherever z puts it.
    FUNCTION band_span(p_z      NUMBER,
                       p_bucket VARCHAR2,
                       p_size   VARCHAR2 DEFAULT NULL,
                       p_twin   VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_sz  VARCHAR2(8) := CASE WHEN p_size IS NOT NULL THEN ' ' || p_size END;
        v_x   NUMBER;
        v_pin VARCHAR2(4) := '';
        v_ov  VARCHAR2(80) := '';
        v_lab VARCHAR2(80);
    BEGIN
        IF p_bucket = 'flat baseline' THEN
            RETURN '<span class="bd s-flat' || v_sz || '" role="img"'
                || ' aria-label="flat baseline, prior sigma is zero">'
                || '<b class="ov">flat, &sigma; = 0</b></span>';
        END IF;
        IF p_z IS NULL OR p_bucket IN ('insufficient history', 'n/a') THEN
            v_lab := CASE p_bucket WHEN 'insufficient history' THEN 'too little history'
                                   WHEN 'n/a' THEN 'no current value'
                                   ELSE 'not scored' END;
            RETURN '<span class="bd na' || v_sz || '" role="img" aria-label="'
                || v_lab || '"><b class="ov">' || v_lab || '</b></span>';
        END IF;
        v_x := (p_z + 4) / 12;
        IF v_x > 1 THEN
            v_x := 1;
            v_pin := ' po';
            v_ov := '<b class="ov">' || band_ztxt(p_z) || '</b>';
        ELSIF v_x < 0 THEN
            v_x := 0;
            v_pin := ' pu';
            v_ov := '<b class="ov">' || band_ztxt(p_z) || '</b>';
        END IF;
        v_lab := CASE p_bucket WHEN 'large'    THEN 'large finding'
                               WHEN 'moderate' THEN 'moderate finding'
                               WHEN 'improved' THEN 'improved'
                               WHEN 'noted'    THEN 'noted'
                               WHEN 'typical'  THEN 'normal'
                               ELSE 'not scored' END;
        RETURN '<span class="bd ' || band_sev(p_bucket) || v_sz || v_pin
            || CASE WHEN p_twin = 'Y' THEN ' twn' END
            || '" style="--x:' || TO_CHAR(v_x, 'FM0D000', 'NLS_NUMERIC_CHARACTERS=''.,''')
            || '" role="img" aria-label="' || v_lab || ', z ' || band_ztxt(p_z) || '">'
            || '<i></i>' || v_ov || '</span>';
    END band_span;

    -- The page's one Delta rule: x n at 2x or more, else a signed percent.
    -- Coloured only on a finding (p_plain 'Y' = never coloured: unscored).
    FUNCTION delta_span(p_cur    NUMBER,
                        p_mu     NUMBER,
                        p_bucket VARCHAR2,
                        p_plain  VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_q   NUMBER;
        v_pct NUMBER;
        v_txt VARCHAR2(80);
    BEGIN
        IF p_bucket = 'flat baseline' THEN
            RETURN '<span class="d s-flat">&mdash;</span>';
        END IF;
        IF p_cur IS NULL OR p_mu IS NULL OR p_mu = 0 THEN
            RETURN '<span class="d s-na">&mdash;</span>';
        END IF;
        v_q := p_cur / p_mu;
        IF p_mu > 0 AND v_q >= 2 THEN
            v_txt := '&#9650; &times;'
                || CASE WHEN v_q < 100
                        THEN TO_CHAR(v_q, 'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                        ELSE TO_CHAR(ROUND(v_q), 'FM999999999990') END;
        ELSE
            v_pct := (p_cur - p_mu) / ABS(p_mu) * 100;
            v_txt := CASE WHEN v_pct >= 0 THEN '&#9650; ' ELSE '&#9660; ' END
                || TO_CHAR(ABS(v_pct), 'FM999999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
        END IF;
        RETURN '<span class="d '
            || CASE WHEN p_plain = 'Y' THEN 's-plain' ELSE band_sev(p_bucket) END
            || '">' || v_txt || '</span>';
    END delta_span;

    -- Normal range = mu +/- 2 sigma (floored sigma), in the metric's unit.
    FUNCTION range_txt(p_mu NUMBER, p_sd NUMBER) RETURN VARCHAR2 IS
        v_den NUMBER;
    BEGIN
        IF p_mu IS NULL OR p_sd IS NULL THEN
            RETURN '&mdash;';
        END IF;
        v_den := GREATEST(p_sd, 0.02 * ABS(p_mu));
        RETURN fmt_num(GREATEST(0, p_mu - 2 * v_den)) || '&ndash;'
            || fmt_num(p_mu + 2 * v_den);
    END range_txt;

    -- The four header cells matching band_cells().
    FUNCTION band_head RETURN VARCHAR2 IS
    BEGIN
        RETURN '<th class="num c-rng" title="prior mean &plusmn; 2&sigma;, in the row&#39;s own unit">Normal range</th>'
            || '<th class="c-band" title="Current, in &sigma; from the prior mean. Shaded = normal (&plusmn;1&sigma;, &plusmn;2&sigma;); ticks at &plusmn;2&sigma; and &plusmn;3&sigma;.">'
            || 'vs normal, in &sigma;<span class="bd-ax" aria-hidden="true">'
            || '<em style="--x:.167">&minus;2</em><em style="--x:.333">0</em>'
            || '<em style="--x:.500">+2</em><em style="--x:.583">+3</em>'
            || '<em class="end" style="--x:1">+8&sigma;</em></span></th>'
            || '<th class="num c-z">z</th>'
            || '<th class="num c-d">&Delta; vs mean</th>';
    END band_head;

    -- The four cells.  p_note: optional ready-made HTML appended under the
    -- Delta text (e.g. the table-wide-shift note of 04 / 05).  p_plain 'Y':
    -- an unscored table (Delta never coloured).
    FUNCTION band_cells(p_cur    NUMBER,
                        p_mu     NUMBER,
                        p_sd     NUMBER,
                        p_n      NUMBER,
                        p_bucket VARCHAR2,
                        p_twin   VARCHAR2 DEFAULT 'N',
                        p_note   VARCHAR2 DEFAULT NULL,
                        p_plain  VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_z    NUMBER := band_z(p_cur, p_mu, p_sd);
        v_note VARCHAR2(1000) := '';
    BEGIN
        IF p_bucket = 'typical' AND v_z IS NOT NULL AND ABS(v_z) > 2 THEN
            v_note := v_note || '<span class="imm" title="|z| above 2 but the move is below this '
                || 'metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">immaterial</span>';
        ELSIF p_bucket IN ('improved', 'noted') THEN
            v_note := v_note || '<span class="imm">' || p_bucket || '</span>';
        ELSIF p_bucket = 'insufficient history' THEN
            v_note := v_note || '<span class="imm" title="fewer than 3 prior valid windows">'
                || 'n &lt; 3</span>';
        END IF;
        IF p_mu IS NOT NULL AND p_sd IS NOT NULL
           AND ((p_mu = 0 AND p_sd = 0) OR (p_mu <> 0 AND p_sd < 0.01 * ABS(p_mu))) THEN
            v_note := v_note || '<span class="imm" title="baseline barely moved: &sigma; below 1% '
                || 'of mean (floored to 2% for z); read the &Delta; instead">&sigma;&approx;0</span>';
        END IF;
        RETURN '<td class="num c-rng">' || range_txt(p_mu, p_sd) || '</td>'
            || '<td class="c-band">' || band_span(v_z, p_bucket, NULL, p_twin) || '</td>'
            || '<td class="num c-z">' || band_ztxt(v_z) || '</td>'
            || '<td class="num c-d">' || delta_span(p_cur, p_mu, p_bucket, p_plain)
            || v_note || p_note || '</td>';
    END band_cells;
