--
-- sql/lib/score_cells.plsql
-- Local function returning three HTML <td> cells: change pill, z-score,
-- % delta. Same scoring mechanism as sql/07_summary.sql: z = (cur - mu)/sd
-- over prior valid windows, bucket by |z| (>3 large, >2 moderate, else
-- typical); n<3 -> insufficient history; sd in {NULL, 0} -> flat baseline.
-- CSS classes match the rest of the report (large->crit, moderate->warn,
-- typical->ok, insufficient/flat -> skip).
--
-- Designed to be @@-included into a DECLARE block. The function is unit-
-- invariant: z and pct cancel units, so callers can pass raw counters
-- (microseconds, gets, executions) without unit conversion.
--
    FUNCTION score_cells(p_cur NUMBER,
                         p_mu  NUMBER,
                         p_sd  NUMBER,
                         p_n   NUMBER) RETURN VARCHAR2 IS
        v_z      NUMBER;
        v_pct    NUMBER;
        v_bucket VARCHAR2(40);
        v_cls    VARCHAR2(10);
    BEGIN
        v_z := CASE WHEN p_cur IS NULL OR p_mu IS NULL
                      OR p_sd IS NULL OR p_sd = 0
                    THEN NULL
                    ELSE (p_cur - p_mu) / p_sd END;
        v_pct := CASE WHEN p_cur IS NULL OR p_mu IS NULL OR p_mu = 0
                      THEN NULL
                      ELSE (p_cur - p_mu) / ABS(p_mu) * 100 END;
        v_bucket := CASE
            WHEN p_cur IS NULL                 THEN 'insufficient history'
            WHEN NVL(p_n, 0) < 3               THEN 'insufficient history'
            WHEN p_sd IS NULL OR p_sd = 0      THEN 'flat baseline'
            WHEN ABS(v_z) > 3                  THEN 'large'
            WHEN ABS(v_z) > 2                  THEN 'moderate'
            ELSE                                    'typical'
        END;
        v_cls := CASE v_bucket
                     WHEN 'large'    THEN 'crit'
                     WHEN 'moderate' THEN 'warn'
                     WHEN 'typical'  THEN 'ok'
                     ELSE                 'skip'
                 END;
        RETURN '<td><span class="badge ' || v_cls || '">'
            || v_bucket
            || '</span></td>'
            || '<td class="num">'
            || CASE WHEN v_z IS NULL THEN '&mdash;'
                    ELSE TO_CHAR(v_z, 'FMS99990D00',
                                 'NLS_NUMERIC_CHARACTERS=''.,''') END
            || '</td>'
            || '<td class="num">'
            || CASE WHEN v_pct IS NULL THEN '&mdash;'
                    ELSE TO_CHAR(v_pct, 'FMS99990D0',
                                 'NLS_NUMERIC_CHARACTERS=''.,''') || '%' END
            || '</td>';
    END score_cells;
