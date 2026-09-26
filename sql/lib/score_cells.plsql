-- sql/lib/score_cells.plsql
-- Local functions shared by the per-row scoring consumers (04/05 wait
-- tables, 18 SQL Monitor):
--   score_z(cur, mu, sd)                         -> z with the sigma floor
--   score_bucket(cur, mu, sd, n, share, domain, name, class, demote)
--                                                -> change bucket
--   score_cells(... same ...)                    -> the four band cells
-- The rule (sigma floor, per-metric materiality floors, direction) is
-- sql/lib/metric_policy.plsql's policy_bucket -- include that file FIRST.
-- v1.6.0: score_cells() draws the bucket with the shared baseline band
-- (sql/lib/band_glyph.plsql's band_cells: Normal range | band | z | Delta);
-- the header is band_head().  Include order: metric_policy, fmt_num,
-- band_glyph, then this file (lint checks 13 and 17).
-- The functions are unit-invariant: z and pct cancel units, so callers can
-- pass raw counters (microseconds, gets, executions) without unit
-- conversion -- but a policy min_abs floor is compared against the raw
-- value the caller passes, so 04/05 pass wait rows with their SHARE.  The
-- Normal-range text is in the unit the caller passes, so callers pass the
-- DISPLAY unit (seconds, milliseconds) to score_cells.
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
        v_bucket  VARCHAR2(40);
    BEGIN
        v_bucket := score_bucket(p_cur, p_mu, p_sd, p_n, p_share,
                                 p_domain, p_name, p_class, p_demote);
        RETURN band_cells(p_cur, p_mu, p_sd, p_n, v_bucket, 'N',
                          CASE WHEN p_demote = 'Y' AND v_bucket = 'moderate'
                               THEN '<span class="imm" title="part of a table-wide shift; '
                                    || 'see the note above the table">table-wide shift</span>'
                          END);
    END score_cells;
