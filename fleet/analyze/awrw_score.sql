--
-- fleet/analyze/awrw_score.sql
--
-- The single numeric source of truth for the z-score model -- the de-duplicated
-- form of the formula currently copied four ways (score_cells.plsql returns
-- HTML; 07/08 inline it). Scalar, DETERMINISTIC, callable from SQL so the
-- analyzer scores set-based while sharing one definition.
--
--   z      = (cur - mu) / sd          (NULL if cur/mu/sd null or sd=0)
--   pct    = (cur - mu) / |mu| * 100  (NULL if cur/mu null or mu=0)
--   bucket: INSUFFICIENT_HISTORY  cur null OR n<3
--           FLAT_BASELINE         sd null or 0   (n>=3)
--           CRITICAL              |z| > z_crit
--           WARN                  |z| > z_warn
--           OK                    otherwise
--
CREATE OR REPLACE PACKAGE awrw_score AS
    FUNCTION zscore(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER) RETURN NUMBER DETERMINISTIC;
    FUNCTION pct   (p_cur NUMBER, p_mu NUMBER)              RETURN NUMBER DETERMINISTIC;
    FUNCTION bucket(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER, p_n NUMBER,
                    p_z_crit NUMBER DEFAULT 3, p_z_warn NUMBER DEFAULT 2) RETURN VARCHAR2 DETERMINISTIC;
END awrw_score;
/

CREATE OR REPLACE PACKAGE BODY awrw_score AS

    FUNCTION zscore(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER) RETURN NUMBER DETERMINISTIC IS
    BEGIN
        RETURN CASE WHEN p_cur IS NULL OR p_mu IS NULL OR p_sd IS NULL OR p_sd = 0
                    THEN NULL ELSE (p_cur - p_mu) / p_sd END;
    END zscore;

    FUNCTION pct(p_cur NUMBER, p_mu NUMBER) RETURN NUMBER DETERMINISTIC IS
    BEGIN
        RETURN CASE WHEN p_cur IS NULL OR p_mu IS NULL OR p_mu = 0
                    THEN NULL ELSE (p_cur - p_mu) / ABS(p_mu) * 100 END;
    END pct;

    FUNCTION bucket(p_cur NUMBER, p_mu NUMBER, p_sd NUMBER, p_n NUMBER,
                    p_z_crit NUMBER DEFAULT 3, p_z_warn NUMBER DEFAULT 2) RETURN VARCHAR2 DETERMINISTIC IS
        v_z NUMBER := zscore(p_cur, p_mu, p_sd);
    BEGIN
        RETURN CASE
            WHEN p_cur IS NULL            THEN 'INSUFFICIENT_HISTORY'
            WHEN NVL(p_n,0) < 3           THEN 'INSUFFICIENT_HISTORY'
            WHEN p_sd IS NULL OR p_sd = 0 THEN 'FLAT_BASELINE'
            WHEN ABS(v_z) > p_z_crit      THEN 'CRITICAL'
            WHEN ABS(v_z) > p_z_warn      THEN 'WARN'
            ELSE                               'OK'
        END;
    END bucket;

END awrw_score;
/
