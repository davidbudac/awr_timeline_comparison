--
-- fleet/analyze/awrw_analyze.pks
--
-- The headless analyzer: scores each unscored Period once (per-Target analysis
-- high-water mark), writes notable Scores as Findings, and maintains Alert State
-- (edge + hysteresis). Reads the AWRV_*/AWRW_* facts through the same window
-- logic as the single-DB report (windows_cte), scoped to a Target by its DBID
-- set. A separate warehouse-side writer -- the read-only sections stay untouched.
--
-- score_period runs all three Detectors over one Period, sharing one window
-- derivation (the pipelined windows() function below):
--   SEASONAL   z-score over the curated Metric Profile (LOAD/METRIC/WAIT) -> alerts
--   REGRESSION top SQL / wait event / segment movers vs Baseline, plan-flip flagged
--   HEADLINE   the marquee hero-six executive health strip (snapshot, no alert state)
--
CREATE OR REPLACE PACKAGE awrw_analyze AS

    -- The single window derivation shared by every Detector: returns one row per
    -- valid (week_offset, instance) begin/end snap pairing for a Target's Period
    -- (restart / DBID-straddle / same-snap pairs already excluded). SQL-callable
    -- via TABLE(awrw_analyze.windows(...)). Warehouse equivalent of windows_cte.sql.
    FUNCTION windows(p_target_id IN NUMBER, p_period_end IN TIMESTAMP, p_weeks IN NUMBER,
                     p_win_h IN NUMBER, p_step_days IN NUMBER) RETURN awrw_win_tab PIPELINED;

    -- Score exactly one Period for one Target (all Detectors).
    PROCEDURE score_period(p_target_id IN NUMBER, p_period_end IN TIMESTAMP);

    -- Score every unscored Period for one Target from its analysis HWM up to the
    -- latest complete hour (capped per run), advancing the HWM.
    PROCEDURE analyze_target(p_target_id IN NUMBER, p_max_periods IN NUMBER DEFAULT 168);

    -- Analyze every enabled Target. One Target's failure never stops the fleet.
    PROCEDURE analyze_all;

END awrw_analyze;
/
