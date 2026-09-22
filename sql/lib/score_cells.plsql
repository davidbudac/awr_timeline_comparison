-- sql/lib/score_cells.plsql
-- Local functions shared by the per-row scoring consumers (04/05 wait
-- tables, 18 SQL Monitor):
--   score_z(cur, mu, sd)                         -> z with the sigma floor
--   score_bucket(cur, mu, sd, n, share, domain, name, class, demote)
--                                                -> change bucket
--   score_cells(... same ...)                    -> three <td> cells
-- The rule (sigma floor, per-metric materiality floors, direction) is
-- sql/lib/metric_policy.plsql's policy_bucket -- include that file FIRST.
-- CSS classes: large -> crit, moderate -> warn, typical -> ok,
-- improved -> info (muted, never highlighted), noted -> note,
-- insufficient / flat / n/a -> skip.
-- The functions are unit-invariant: z and pct cancel units, so callers can
-- pass raw counters (microseconds, gets, executions) without unit
-- conversion -- but a policy min_abs floor is compared against the raw
-- value the caller passes, so 04/05 pass wait rows with their SHARE.
-- Display-only rules (B5/F5, do not affect scoring/severity above):
--   - |z| > 99 is clamped to "&gt;+99" / "&lt;&minus;99".
--   - When the prior baseline barely moved (sd < 1% of |mean|, or both
--     are exactly 0) a sigma-approx-0 badge is appended after the z value
--     and the %-delta cell is rendered bold, nudging the reader toward
--     %-delta instead of a floored z.
--   - The %-delta cell always carries a leading direction glyph (up/down
--     triangle) instead of a signed number; no per-direction color class is
--     used (severity color stays on .badge only).
    FUNCTION score_z(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER) RETURN NUMBER IS
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
    END score_z;

    -- Thin wrapper: the rule itself lives in sql/lib/metric_policy.plsql
    -- (policy_bucket), which must be included BEFORE this file.  The
    -- domain / name / class pick the per-metric policy (direction and
    -- materiality floors); 'SQL' / 'SEG' / 'FILE' callers pass no name.
    FUNCTION score_bucket(p_cur    NUMBER,
                          p_mu     NUMBER,
                          p_sd     NUMBER,
                          p_n      NUMBER,
                          p_share  NUMBER   DEFAULT NULL,
                          p_domain VARCHAR2 DEFAULT 'SQL',
                          p_name   VARCHAR2 DEFAULT NULL,
                          p_class  VARCHAR2 DEFAULT NULL,
                          p_demote VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
    BEGIN
        RETURN policy_bucket(p_domain, p_name, p_class,
                             p_cur, p_mu, p_sd, p_n, p_share, p_demote);
    END score_bucket;

    FUNCTION score_cells(p_cur    NUMBER,
                         p_mu     NUMBER,
                         p_sd     NUMBER,
                         p_n      NUMBER,
                         p_share  NUMBER   DEFAULT NULL,
                         p_domain VARCHAR2 DEFAULT 'SQL',
                         p_name   VARCHAR2 DEFAULT NULL,
                         p_class  VARCHAR2 DEFAULT NULL,
                         p_demote VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        v_z       NUMBER;
        v_pct     NUMBER;
        v_bucket  VARCHAR2(40);
        v_cls     VARCHAR2(10);
        v_sig     VARCHAR2(1) := 'N';
        v_imm     VARCHAR2(1) := 'N';
        v_z_txt   VARCHAR2(40);
        v_pct_txt VARCHAR2(80);
    BEGIN
        v_z := score_z(p_cur, p_mu, p_sd);
        v_pct := CASE WHEN p_cur IS NULL OR p_mu IS NULL OR p_mu = 0
                      THEN NULL
                      ELSE (p_cur - p_mu) / ABS(p_mu) * 100 END;
        v_bucket := score_bucket(p_cur, p_mu, p_sd, p_n, p_share,
                                 p_domain, p_name, p_class, p_demote);
        v_cls := CASE v_bucket
                     WHEN 'large'    THEN 'crit'
                     WHEN 'moderate' THEN 'warn'
                     WHEN 'typical'  THEN 'ok'
                     WHEN 'improved' THEN 'imp'
                     WHEN 'noted'    THEN 'note'
                     ELSE                 'skip'
                 END;
        -- "immaterial": |z| cleared 2 but the materiality gate held it back.
        IF v_bucket = 'typical' AND v_z IS NOT NULL AND ABS(v_z) > 2 THEN
            v_imm := 'Y';
        END IF;

        -- B5: baseline-barely-moved flag (display-only, no scoring impact).
        IF p_mu IS NOT NULL AND p_sd IS NOT NULL THEN
            IF (p_mu = 0 AND p_sd = 0)
               OR (p_mu <> 0 AND p_sd < 0.01 * ABS(p_mu)) THEN
                v_sig := 'Y';
            END IF;
        END IF;

        v_z_txt := CASE
            WHEN v_z IS NULL THEN '&mdash;'
            WHEN v_z > 99    THEN '&gt;+99'
            WHEN v_z < -99   THEN '&lt;&minus;99'
            ELSE TO_CHAR(v_z, 'FMS99990D00', 'NLS_NUMERIC_CHARACTERS=''.,''')
        END;

        -- F5: direction glyph instead of a signed number, no color class.
        v_pct_txt := CASE
            WHEN v_pct IS NULL THEN '&mdash;'
            WHEN v_pct < 0     THEN '&#9660; ' || TO_CHAR(ABS(v_pct), 'FM99990D0',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') || '%'
            ELSE '&#9650; ' || TO_CHAR(v_pct, 'FM99990D0',
                                        'NLS_NUMERIC_CHARACTERS=''.,''') || '%'
        END;

        RETURN '<td><span class="badge ' || v_cls || '"'
            || CASE WHEN p_demote = 'Y' AND v_bucket = 'moderate'
                    THEN ' title="part of a table-wide shift; see the note above the table"'
                    ELSE '' END
            || '>' || v_bucket
            || '</span></td>'
            || '<td class="num">'
            || v_z_txt
            || CASE WHEN v_sig = 'Y' THEN
                   ' <span class="badge sig" title="baseline barely moved: '
                   || '&sigma; below 1% of mean (floored to 2% for z); read the % delta instead">'
                   || '&sigma;&approx;0</span>'
               END
            || CASE WHEN v_imm = 'Y' THEN
                   ' <span class="badge sig" title="|z| above 2 but the move is below this '
                   || 'metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">'
                   || 'immaterial</span>'
               END
            || '</td>'
            || '<td class="num">'
            || CASE WHEN v_sig = 'Y' THEN '<b>' || v_pct_txt || '</b>'
                    ELSE v_pct_txt END
            || '</td>';
    END score_cells;
