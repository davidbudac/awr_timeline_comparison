--
-- fleet/analyze/awrw_analyze.pkb
--
-- Body of the seasonal analyzer. The big cursor ports windows_cte.sql (begin/end
-- snap pairing + restart/DBID-straddle invalidation) and section 07's LOAD /
-- METRIC / WAIT recompute onto the warehouse facts, scoped to the Target via its
-- DBID set (awrw_dbid). Scores via awrw_score (the shared formula), applies the
-- Metric Profile gates, writes Findings, and advances Alert State.
--
CREATE OR REPLACE PACKAGE BODY awrw_analyze AS

    PROCEDURE log_err(p_target_id NUMBER, p_phase VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_code NUMBER         := SQLCODE;   -- capture before the INSERT (PL/SQL-only in SQL)
        v_text VARCHAR2(4000) := SUBSTR(SQLERRM||' '||DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
    BEGIN
        INSERT INTO awrw_error_log (target_id, phase, ora_code, err_text)
        VALUES (p_target_id, p_phase, v_code, v_text);
        COMMIT;
    END log_err;

    -- Advance Alert State for one (Target, Subject) by one Period.
    PROCEDURE bump_alert(p_target_id NUMBER, p_subj_type VARCHAR2, p_subj_id VARCHAR2,
                         p_period TIMESTAMP, p_severity VARCHAR2, p_signal VARCHAR2,
                         p_fire_consec NUMBER, p_clear_consec NUMBER, p_finding_id NUMBER) IS
        -- p_signal: ANOM | NORMAL | NONE  (NONE = no-signal: insufficient/flat/gated)
    BEGIN
        MERGE INTO awrw_alert_state a
        USING (SELECT p_target_id tid, p_subj_type st, p_subj_id si FROM dual) s
           ON (a.target_id=s.tid AND a.subject_type=s.st AND a.subject_id=s.si)
        WHEN NOT MATCHED THEN INSERT (target_id, subject_type, subject_id, state, severity,
                consecutive_anom, consecutive_normal, last_period_ts, last_finding_id, fired_period_ts)
            VALUES (p_target_id, p_subj_type, p_subj_id,
                -- a new subject can fire on its first Period iff fire_consec=1
                CASE WHEN p_signal='ANOM' AND 1 >= p_fire_consec THEN 'FIRING' ELSE 'NORMAL' END,
                CASE WHEN p_signal='ANOM' THEN p_severity END,
                CASE WHEN p_signal='ANOM' THEN 1 ELSE 0 END,
                CASE WHEN p_signal='NORMAL' THEN 1 ELSE 0 END,
                p_period, p_finding_id,
                CASE WHEN p_signal='ANOM' AND 1 >= p_fire_consec THEN p_period END)
        WHEN MATCHED THEN UPDATE SET
            consecutive_anom   = CASE WHEN p_signal='ANOM'   THEN a.consecutive_anom+1
                                      WHEN p_signal='NORMAL' THEN 0 ELSE a.consecutive_anom END,
            consecutive_normal = CASE WHEN p_signal='NORMAL' THEN a.consecutive_normal+1
                                      WHEN p_signal='ANOM'   THEN 0 ELSE a.consecutive_normal END,
            severity = CASE WHEN p_signal='ANOM' THEN p_severity ELSE a.severity END,
            last_period_ts  = p_period,
            last_finding_id = NVL(p_finding_id, a.last_finding_id),
            -- fire edge
            state = CASE
                      WHEN a.state='NORMAL' AND p_signal='ANOM'
                           AND a.consecutive_anom+1 >= p_fire_consec THEN 'FIRING'
                      WHEN a.state='FIRING' AND p_signal='NORMAL'
                           AND a.consecutive_normal+1 >= p_clear_consec THEN 'NORMAL'
                      ELSE a.state END,
            fired_period_ts = CASE WHEN a.state='NORMAL' AND p_signal='ANOM'
                                        AND a.consecutive_anom+1 >= p_fire_consec
                                   THEN p_period ELSE a.fired_period_ts END,
            cleared_period_ts = CASE WHEN a.state='FIRING' AND p_signal='NORMAL'
                                          AND a.consecutive_normal+1 >= p_clear_consec
                                     THEN p_period ELSE a.cleared_period_ts END,
            updated_ts = SYSTIMESTAMP;
    END bump_alert;

    ------------------------------------------------------------------- windows
    -- The single Comparison-Window derivation shared by all Detectors: one row
    -- per valid (week_offset, instance) begin/end snap pairing. Restart,
    -- DBID-straddle and same-snap pairs are excluded here so no Detector re-checks
    -- them. Ported from windows_cte.sql; pipelined so SQL can TABLE() it.
    FUNCTION windows(p_target_id IN NUMBER, p_period_end IN TIMESTAMP, p_weeks IN NUMBER,
                     p_win_h IN NUMBER, p_step_days IN NUMBER) RETURN awrw_win_tab PIPELINED IS
    BEGIN
        FOR v IN (
            WITH
            offsets AS (
                SELECT LEVEL-1 AS week_offset FROM dual CONNECT BY LEVEL <= p_weeks+1
            ),
            raw_windows AS (
                SELECT o.week_offset,
                       CAST(p_period_end AS DATE) - p_step_days*o.week_offset - p_win_h/24 AS win_start_dt,
                       CAST(p_period_end AS DATE) - p_step_days*o.week_offset              AS win_end_dt
                FROM offsets o
            ),
            snaps AS (
                SELECT w.week_offset, w.win_start_dt, w.win_end_dt,
                       s.dbid, s.instance_number, s.snap_id, s.end_interval_time, s.startup_time
                FROM raw_windows w
                JOIN awrw_snapshot s
                  ON s.dbid IN (SELECT dbid FROM awrw_dbid WHERE target_id = p_target_id)
                 AND s.end_interval_time BETWEEN CAST(w.win_start_dt - 1 AS TIMESTAMP)
                                             AND CAST(w.win_end_dt   + 1 AS TIMESTAMP)
            ),
            begin_snap AS (
                SELECT week_offset, instance_number,
                       MAX(snap_id)      KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS snap_id,
                       MAX(dbid)         KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS dbid,
                       MAX(startup_time) KEEP (DENSE_RANK LAST ORDER BY end_interval_time) AS startup_time
                FROM snaps WHERE end_interval_time <= CAST(win_start_dt + 5/1440 AS TIMESTAMP)
                GROUP BY week_offset, instance_number
            ),
            end_snap AS (
                SELECT week_offset, instance_number,
                       MIN(snap_id)      KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS snap_id,
                       MIN(dbid)         KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS dbid,
                       MIN(startup_time) KEEP (DENSE_RANK FIRST ORDER BY end_interval_time) AS startup_time
                FROM snaps WHERE end_interval_time >= CAST(win_end_dt - 5/1440 AS TIMESTAMP)
                GROUP BY week_offset, instance_number
            ),
            instance_pairs AS (
                SELECT NVL(bs.week_offset, es.week_offset) AS week_offset,
                       NVL(bs.instance_number, es.instance_number) AS instance_number,
                       bs.snap_id AS begin_snap_id, bs.dbid AS begin_dbid, bs.startup_time AS begin_startup_time,
                       es.snap_id AS end_snap_id,   es.dbid AS end_dbid,   es.startup_time AS end_startup_time
                FROM begin_snap bs
                FULL OUTER JOIN end_snap es ON es.week_offset=bs.week_offset AND es.instance_number=bs.instance_number
            ),
            valid AS (
                SELECT ip.week_offset, NVL(ip.begin_dbid, ip.end_dbid) AS dbid, ip.instance_number,
                       ip.begin_snap_id, ip.end_snap_id,
                       (CAST(w.win_end_dt AS DATE) - CAST(w.win_start_dt AS DATE)) * 86400 AS dur_sec
                FROM raw_windows w
                JOIN instance_pairs ip ON ip.week_offset = w.week_offset
                WHERE ip.begin_snap_id IS NOT NULL AND ip.end_snap_id IS NOT NULL
                  AND ip.begin_snap_id <> ip.end_snap_id
                  AND ip.begin_dbid = ip.end_dbid
                  AND ip.begin_startup_time = ip.end_startup_time
            )
            SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
            FROM valid
        ) LOOP
            PIPE ROW(awrw_win_row(v.week_offset, v.dbid, v.instance_number,
                                  v.begin_snap_id, v.end_snap_id, v.dur_sec));
        END LOOP;
        RETURN;
    END windows;

    ------------------------------------------------------------ detect_regressions
    -- REGRESSION Detector: the top SQL / wait event / segment movers whose current
    -- Period impact regressed vs their own seasonal Baseline (cur > mu AND |z|
    -- breach AND above a per-domain magnitude floor). Ranked by impact, capped at
    -- reg_top_n per subject_type. SQL plan flips (current dominant plan differs
    -- from any prior window's) are flagged. Each regressor drives Alert State with
    -- the same fire/clear hysteresis as seasonal; a previously-FIRING subject that
    -- is no longer a regressor this Period is nudged toward clearing (clear sweep).
    PROCEDURE detect_regressions(p_target_id NUMBER, p_period_end TIMESTAMP,
                     p_weeks NUMBER, p_win_h NUMBER, p_step_days NUMBER, p_zc NUMBER, p_zw NUMBER,
                     p_fire NUMBER, p_clear NUMBER, p_top_n NUMBER,
                     p_sql_min_sec NUMBER, p_wait_min_sec NUMBER, p_seg_min_blk NUMBER) IS
        v_dbid NUMBER;
        v_fid  NUMBER;
        v_anom SYS.ODCIVARCHAR2LIST;

        -- Clear sweep: FIRING subjects of this type not anomalous this Period get a
        -- NORMAL signal so they eventually clear (their workload may have vanished
        -- entirely, so they never appear in the impact series).
        PROCEDURE clear_sweep(p_subj_type VARCHAR2, p_keep SYS.ODCIVARCHAR2LIST) IS
        BEGIN
            -- Touch every FIRING subject (so it can clear) and every subject mid
            -- anomaly streak (so the streak resets to truly-consecutive) that did
            -- NOT regress this Period. Bounded: only state=FIRING or anom>0 rows.
            FOR c IN (SELECT a.subject_id FROM awrw_alert_state a
                       WHERE a.target_id=p_target_id AND a.subject_type=p_subj_type
                         AND (a.state='FIRING' OR a.consecutive_anom > 0)
                         AND NOT EXISTS (SELECT 1 FROM TABLE(p_keep) k
                                          WHERE k.column_value = a.subject_id)) LOOP
                bump_alert(p_target_id, p_subj_type, c.subject_id, p_period_end,
                           NULL, 'NORMAL', p_fire, p_clear, NULL);
            END LOOP;
        END clear_sweep;
    BEGIN
        SELECT MIN(dbid) INTO v_dbid FROM awrw_dbid WHERE target_id = p_target_id;

        ----------------------------------------------------------------- SQL
        v_anom := SYS.ODCIVARCHAR2LIST();
        FOR r IN (
            WITH valid AS (
                SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
                FROM TABLE(awrw_analyze.windows(p_target_id, p_period_end, p_weeks, p_win_h, p_step_days))
            ),
            plan_agg AS (   -- sum native elapsed delta per (window, sql_id, plan)
                SELECT v.week_offset, x.sql_id, x.plan_hash_value,
                       SUM(NVL(x.elapsed_time_delta,0)) AS ela_us
                FROM valid v
                JOIN awrw_sqlstat x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                   AND x.snap_id BETWEEN v.begin_snap_id+1 AND v.end_snap_id
                GROUP BY v.week_offset, x.sql_id, x.plan_hash_value
            ),
            sql_agg AS (    -- collapse plans: total elapsed + the dominant (most-elapsed) plan
                SELECT week_offset, sql_id, SUM(ela_us) AS ela_us,
                       MAX(plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY ela_us NULLS FIRST) AS dom_phv
                FROM plan_agg GROUP BY week_offset, sql_id
            ),
            sql_pivot AS (
                SELECT sql_id,
                       MAX   (CASE WHEN week_offset=0 THEN ela_us END) AS cur_us,
                       AVG   (CASE WHEN week_offset>0 THEN ela_us END) AS mu_us,
                       STDDEV(CASE WHEN week_offset>0 THEN ela_us END) AS sd_us,
                       COUNT (CASE WHEN week_offset>0 THEN ela_us END) AS n,
                       MAX   (CASE WHEN week_offset=0 THEN dom_phv END) AS cur_phv
                FROM sql_agg GROUP BY sql_id
            ),
            plan_flip AS (  -- did the dominant plan differ in any prior window?
                SELECT sp.sql_id,
                       MAX(CASE WHEN sa.week_offset>0 AND sa.dom_phv IS NOT NULL
                                 AND sp.cur_phv IS NOT NULL AND sa.dom_phv <> sp.cur_phv
                                THEN 'Y' ELSE 'N' END) AS plan_changed
                FROM sql_pivot sp JOIN sql_agg sa ON sa.sql_id=sp.sql_id
                GROUP BY sp.sql_id
            )
            SELECT * FROM (
                SELECT q.* FROM (
                    SELECT sp.sql_id, sp.cur_us, sp.mu_us, sp.sd_us, sp.n, pf.plan_changed,
                           awrw_score.zscore(sp.cur_us, sp.mu_us, sp.sd_us) AS z,
                           awrw_score.pct   (sp.cur_us, sp.mu_us)           AS pct,
                           awrw_score.bucket(sp.cur_us, sp.mu_us, sp.sd_us, sp.n, p_zc, p_zw) AS bkt
                    FROM sql_pivot sp JOIN plan_flip pf ON pf.sql_id=sp.sql_id
                ) q
                WHERE q.cur_us > q.mu_us
                  AND q.cur_us >= p_sql_min_sec * 1e6
                  AND q.bkt IN ('CRITICAL','WARN')
                ORDER BY q.cur_us DESC
            ) WHERE ROWNUM <= p_top_n
        ) LOOP
            INSERT INTO awrw_findings (target_id, dbid, detector, subject_type, subject_id,
                   period_end_ts, cur_val, prior_mean, prior_sd, n_prior, z_score, pct_delta,
                   impact, direction, severity, plan_changed)
            VALUES (p_target_id, v_dbid, 'REGRESSION', 'sql', r.sql_id, p_period_end,
                   r.cur_us/1e6, r.mu_us/1e6, r.sd_us/1e6, r.n, r.z, r.pct,
                   r.cur_us/1e6, 'UP', r.bkt, r.plan_changed)
            RETURNING finding_id INTO v_fid;
            bump_alert(p_target_id, 'sql', r.sql_id, p_period_end, r.bkt, 'ANOM', p_fire, p_clear, v_fid);
            v_anom.EXTEND; v_anom(v_anom.LAST) := r.sql_id;
        END LOOP;
        clear_sweep('sql', v_anom);

        ----------------------------------------------------------------- WAIT (foreground events)
        v_anom := SYS.ODCIVARCHAR2LIST();
        FOR r IN (
            WITH valid AS (
                SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
                FROM TABLE(awrw_analyze.windows(p_target_id, p_period_end, p_weeks, p_win_h, p_step_days))
            ),
            ev_delta AS (   -- cumulative time_waited_micro: end-begin per instance, summed across instances
                SELECT week_offset, event_name, SUM(delta_us) AS us
                FROM (
                    SELECT v.week_offset, v.instance_number, x.event_name,
                           SUM(CASE WHEN x.snap_id=v.end_snap_id   THEN x.time_waited_micro
                                    WHEN x.snap_id=v.begin_snap_id THEN -x.time_waited_micro END) AS delta_us
                    FROM valid v
                    JOIN awrw_wait_event x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                          AND x.is_bg='N' AND NVL(x.wait_class,'x') <> 'Idle'
                                          AND x.snap_id IN (v.begin_snap_id, v.end_snap_id)
                    GROUP BY v.week_offset, v.instance_number, x.event_name
                )
                GROUP BY week_offset, event_name
            ),
            ev_pivot AS (
                SELECT event_name,
                       MAX   (CASE WHEN week_offset=0 THEN us END) AS cur_us,
                       AVG   (CASE WHEN week_offset>0 THEN us END) AS mu_us,
                       STDDEV(CASE WHEN week_offset>0 THEN us END) AS sd_us,
                       COUNT (CASE WHEN week_offset>0 THEN us END) AS n
                FROM ev_delta GROUP BY event_name
            )
            SELECT * FROM (
                SELECT q.* FROM (
                    SELECT event_name, cur_us, mu_us, sd_us, n,
                           awrw_score.zscore(cur_us, mu_us, sd_us) AS z,
                           awrw_score.pct   (cur_us, mu_us)        AS pct,
                           awrw_score.bucket(cur_us, mu_us, sd_us, n, p_zc, p_zw) AS bkt
                    FROM ev_pivot
                ) q
                WHERE q.cur_us > q.mu_us
                  AND q.cur_us >= p_wait_min_sec * 1e6
                  AND q.bkt IN ('CRITICAL','WARN')
                ORDER BY q.cur_us DESC
            ) WHERE ROWNUM <= p_top_n
        ) LOOP
            INSERT INTO awrw_findings (target_id, dbid, detector, subject_type, subject_id,
                   period_end_ts, cur_val, prior_mean, prior_sd, n_prior, z_score, pct_delta,
                   impact, direction, severity)
            VALUES (p_target_id, v_dbid, 'REGRESSION', 'wait', r.event_name, p_period_end,
                   r.cur_us/1e6, r.mu_us/1e6, r.sd_us/1e6, r.n, r.z, r.pct,
                   r.cur_us/1e6, 'UP', r.bkt)
            RETURNING finding_id INTO v_fid;
            bump_alert(p_target_id, 'wait', r.event_name, p_period_end, r.bkt, 'ANOM', p_fire, p_clear, v_fid);
            v_anom.EXTEND; v_anom(v_anom.LAST) := r.event_name;
        END LOOP;
        clear_sweep('wait', v_anom);

        ----------------------------------------------------------------- SEGMENT
        v_anom := SYS.ODCIVARCHAR2LIST();
        FOR r IN (
            WITH valid AS (
                SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
                FROM TABLE(awrw_analyze.windows(p_target_id, p_period_end, p_weeks, p_win_h, p_step_days))
            ),
            seg_agg AS (    -- native physical I/O deltas, keyed by stable seg_name
                SELECT v.week_offset, sd.seg_name,
                       SUM(NVL(x.physical_reads_delta,0) + NVL(x.physical_writes_delta,0)) AS io_blk
                FROM valid v
                JOIN awrw_seg_stat x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                    AND x.snap_id BETWEEN v.begin_snap_id+1 AND v.end_snap_id
                JOIN awrw_segment sd ON sd.dbid=x.dbid AND sd.ts#=x.ts#
                                    AND sd.obj#=x.obj# AND sd.dataobj#=x.dataobj#
                WHERE sd.seg_name IS NOT NULL   -- never key a Subject on NULL (alert_state.subject_id NOT NULL)
                GROUP BY v.week_offset, sd.seg_name
            ),
            seg_pivot AS (
                SELECT seg_name,
                       MAX   (CASE WHEN week_offset=0 THEN io_blk END) AS cur_blk,
                       AVG   (CASE WHEN week_offset>0 THEN io_blk END) AS mu_blk,
                       STDDEV(CASE WHEN week_offset>0 THEN io_blk END) AS sd_blk,
                       COUNT (CASE WHEN week_offset>0 THEN io_blk END) AS n
                FROM seg_agg GROUP BY seg_name
            )
            SELECT * FROM (
                SELECT q.* FROM (
                    SELECT seg_name, cur_blk, mu_blk, sd_blk, n,
                           awrw_score.zscore(cur_blk, mu_blk, sd_blk) AS z,
                           awrw_score.pct   (cur_blk, mu_blk)         AS pct,
                           awrw_score.bucket(cur_blk, mu_blk, sd_blk, n, p_zc, p_zw) AS bkt
                    FROM seg_pivot
                ) q
                WHERE q.cur_blk > q.mu_blk
                  AND q.cur_blk >= p_seg_min_blk
                  AND q.bkt IN ('CRITICAL','WARN')
                ORDER BY q.cur_blk DESC
            ) WHERE ROWNUM <= p_top_n
        ) LOOP
            INSERT INTO awrw_findings (target_id, dbid, detector, subject_type, subject_id,
                   period_end_ts, cur_val, prior_mean, prior_sd, n_prior, z_score, pct_delta,
                   impact, direction, severity)
            VALUES (p_target_id, v_dbid, 'REGRESSION', 'segment', SUBSTR(r.seg_name,1,256), p_period_end,
                   r.cur_blk, r.mu_blk, r.sd_blk, r.n, r.z, r.pct,
                   r.cur_blk, 'UP', r.bkt)
            RETURNING finding_id INTO v_fid;
            bump_alert(p_target_id, 'segment', SUBSTR(r.seg_name,1,256), p_period_end,
                       r.bkt, 'ANOM', p_fire, p_clear, v_fid);
            v_anom.EXTEND; v_anom(v_anom.LAST) := SUBSTR(r.seg_name,1,256);
        END LOOP;
        clear_sweep('segment', v_anom);
    END detect_regressions;

    --------------------------------------------------------------- detect_headline
    -- HEADLINE Detector: the marquee hero-six (the headline='Y' Metric Profile
    -- rows -- LOAD rates + key SYSMETRIC) as an executive health strip. Emits a
    -- per-Period snapshot Finding for each marquee metric that is CRITICAL/WARN.
    -- DELIBERATELY UNGATED (no abs_floor / pct_floor / polarity) -- it shows the
    -- raw statistical deviation of the marquee metrics, exactly as the single-DB
    -- report's section 08 hero strip shows all six cards regardless of the
    -- section-07 gates. So a metric can appear here as a "headline mover" without
    -- a seasonal alert (e.g. a large but below-floor or wrong-polarity move).
    -- Informational: it does NOT drive Alert State (seasonal already owns the
    -- firing lifecycle for these metrics), so it never double-alerts. The Digest
    -- renders the latest Period's headline Findings per Target.
    PROCEDURE detect_headline(p_target_id NUMBER, p_period_end TIMESTAMP, p_pf VARCHAR2,
                     p_weeks NUMBER, p_win_h NUMBER, p_step_days NUMBER, p_zc NUMBER, p_zw NUMBER) IS
        v_dbid NUMBER;
    BEGIN
        SELECT MIN(dbid) INTO v_dbid FROM awrw_dbid WHERE target_id = p_target_id;

        FOR r IN (
            WITH valid AS (
                SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
                FROM TABLE(awrw_analyze.windows(p_target_id, p_period_end, p_weeks, p_win_h, p_step_days))
            ),
            load_rows AS (
                SELECT week_offset, 'LOAD' AS domain, stat_name AS metric_name,
                       SUM(delta) / MAX(dur_sec) AS metric_value
                FROM (
                    SELECT v.week_offset, v.dur_sec, v.instance_number, x.stat_name,
                           SUM(CASE WHEN x.snap_id=v.end_snap_id THEN x.value
                                    WHEN x.snap_id=v.begin_snap_id THEN -x.value END) AS delta
                    FROM valid v
                    JOIN awrw_sysstat x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                       AND x.snap_id IN (v.begin_snap_id, v.end_snap_id)
                    WHERE x.stat_name IN (SELECT metric_name FROM awrw_profile_metric
                                           WHERE profile_name=p_pf AND domain='LOAD' AND headline='Y')
                    GROUP BY v.week_offset, v.dur_sec, v.instance_number, x.stat_name
                )
                GROUP BY week_offset, stat_name
            ),
            metric_rows AS (
                SELECT week_offset, 'METRIC' AS domain, metric_name, AVG(snap_value) AS metric_value
                FROM (
                    SELECT v.week_offset, x.metric_name, x.snap_id,
                           CASE WHEN MAX(pm.is_additive)='Y' THEN SUM(x.average) ELSE AVG(x.average) END AS snap_value
                    FROM valid v
                    JOIN awrw_sysmetric x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                         AND x.snap_id BETWEEN v.begin_snap_id+1 AND v.end_snap_id
                    JOIN awrw_profile_metric pm ON pm.profile_name=p_pf AND pm.domain='METRIC'
                                               AND pm.metric_name=x.metric_name AND pm.headline='Y'
                    GROUP BY v.week_offset, x.metric_name, x.snap_id
                )
                GROUP BY week_offset, metric_name
            ),
            unified AS (
                SELECT * FROM load_rows UNION ALL SELECT * FROM metric_rows
            ),
            pivoted AS (
                SELECT domain, metric_name,
                       MAX   (CASE WHEN week_offset=0 THEN metric_value END) AS cur_val,
                       AVG   (CASE WHEN week_offset>0 THEN metric_value END) AS mu,
                       STDDEV(CASE WHEN week_offset>0 THEN metric_value END) AS sd,
                       COUNT (CASE WHEN week_offset>0 THEN metric_value END) AS n
                FROM unified GROUP BY domain, metric_name
            )
            SELECT domain, metric_name, cur_val, mu, sd, n,
                   awrw_score.zscore(cur_val,mu,sd) AS z,
                   awrw_score.pct   (cur_val,mu)    AS pct,
                   awrw_score.bucket(cur_val,mu,sd,n,p_zc,p_zw) AS bkt
            FROM pivoted
        ) LOOP
            IF r.bkt IN ('CRITICAL','WARN') THEN
                INSERT INTO awrw_findings (target_id, dbid, detector, subject_type, subject_id,
                       metric_domain, period_end_ts, cur_val, prior_mean, prior_sd, n_prior,
                       z_score, pct_delta, direction, severity)
                VALUES (p_target_id, v_dbid, 'HEADLINE', 'headline', r.metric_name, r.domain, p_period_end,
                       r.cur_val, r.mu, r.sd, r.n, r.z, r.pct,
                       CASE WHEN r.z >= 0 THEN 'UP' ELSE 'DOWN' END, r.bkt);
            END IF;
        END LOOP;
    END detect_headline;

    --------------------------------------------------------------- score_period
    PROCEDURE score_period(p_target_id IN NUMBER, p_period_end IN TIMESTAMP) IS
        v_pf        awrw_profile.profile_name%TYPE;
        v_weeks     NUMBER;
        v_win_h     NUMBER;
        v_zc        NUMBER;
        v_zw        NUMBER;
        v_pctfloor  NUMBER;
        v_fire      NUMBER;
        v_clear     NUMBER;
        v_step_days NUMBER;               -- cadence between windows (profile.step_days)
        v_reg_top_n        NUMBER;        -- regression Detector knobs (profile)
        v_reg_sql_min_sec  NUMBER;
        v_reg_wait_min_sec NUMBER;
        v_reg_seg_min_blk  NUMBER;
        v_dbid      NUMBER;                -- representative DBID for the Target (cached once)
        v_fid       NUMBER;
        v_signal    VARCHAR2(8);
        v_is_find   BOOLEAN;
    BEGIN
        SELECT t.profile_name, p.weeks_back, p.win_hours, p.z_crit, p.z_warn,
               p.pct_floor, p.fire_consec, p.clear_consec, p.step_days,
               p.reg_top_n, p.reg_sql_min_sec, p.reg_wait_min_sec, p.reg_seg_min_blk
          INTO v_pf, v_weeks, v_win_h, v_zc, v_zw, v_pctfloor, v_fire, v_clear, v_step_days,
               v_reg_top_n, v_reg_sql_min_sec, v_reg_wait_min_sec, v_reg_seg_min_blk
          FROM awrw_target t JOIN awrw_profile p ON p.profile_name = t.profile_name
         WHERE t.target_id = p_target_id;

        SELECT MIN(dbid) INTO v_dbid FROM awrw_dbid WHERE target_id = p_target_id;

        FOR r IN (
            WITH
            valid AS (   -- shared window derivation (begin/end pairs, restart/DBID guards applied)
                SELECT week_offset, dbid, instance_number, begin_snap_id, end_snap_id, dur_sec
                FROM TABLE(awrw_analyze.windows(p_target_id, p_period_end, v_weeks, v_win_h, v_step_days))
            ),
            -- LOAD: SYSSTAT cumulative, per-second rate, summed across instances
            load_rows AS (
                SELECT week_offset, 'LOAD' AS domain, stat_name AS metric_name,
                       SUM(delta) / MAX(dur_sec) AS metric_value
                FROM (
                    SELECT v.week_offset, v.dur_sec, v.instance_number, x.stat_name,
                           SUM(CASE WHEN x.snap_id=v.end_snap_id THEN x.value
                                    WHEN x.snap_id=v.begin_snap_id THEN -x.value END) AS delta
                    FROM valid v
                    JOIN awrw_sysstat x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                       AND x.snap_id IN (v.begin_snap_id, v.end_snap_id)
                    WHERE x.stat_name IN (SELECT metric_name FROM awrw_profile_metric
                                           WHERE profile_name=v_pf AND domain='LOAD')
                    GROUP BY v.week_offset, v.dur_sec, v.instance_number, x.stat_name
                )
                GROUP BY week_offset, stat_name
            ),
            -- METRIC: SYSMETRIC per-snap (SUM additive / AVG ratio across instances), AVG over snaps
            metric_rows AS (
                SELECT week_offset, 'METRIC' AS domain, metric_name, AVG(snap_value) AS metric_value
                FROM (
                    SELECT v.week_offset, x.metric_name, x.snap_id,
                           CASE WHEN MAX(pm.is_additive)='Y' THEN SUM(x.average) ELSE AVG(x.average) END AS snap_value
                    FROM valid v
                    JOIN awrw_sysmetric x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                         AND x.snap_id BETWEEN v.begin_snap_id+1 AND v.end_snap_id
                    JOIN awrw_profile_metric pm ON pm.profile_name=v_pf AND pm.domain='METRIC' AND pm.metric_name=x.metric_name
                    GROUP BY v.week_offset, x.metric_name, x.snap_id
                )
                GROUP BY week_offset, metric_name
            ),
            -- WAIT: foreground time_waited_micro cumulative, rolled per wait_class, sec-of-wait/sec
            wait_rows AS (
                SELECT week_offset, 'WAIT' AS domain, wait_class AS metric_name,
                       SUM(delta) / MAX(dur_sec) / 1e6 AS metric_value
                FROM (
                    SELECT v.week_offset, v.dur_sec, v.instance_number, x.wait_class, x.event_name,
                           SUM(CASE WHEN x.snap_id=v.end_snap_id THEN x.time_waited_micro
                                    WHEN x.snap_id=v.begin_snap_id THEN -x.time_waited_micro END) AS delta
                    FROM valid v
                    JOIN awrw_wait_event x ON x.dbid=v.dbid AND x.instance_number=v.instance_number
                                          AND x.is_bg='N' AND x.snap_id IN (v.begin_snap_id, v.end_snap_id)
                    WHERE x.wait_class IN (SELECT metric_name FROM awrw_profile_metric
                                            WHERE profile_name=v_pf AND domain='WAIT')
                    GROUP BY v.week_offset, v.dur_sec, v.instance_number, x.wait_class, x.event_name
                )
                GROUP BY week_offset, wait_class
            ),
            unified AS (
                SELECT * FROM load_rows UNION ALL
                SELECT * FROM metric_rows UNION ALL
                SELECT * FROM wait_rows
            ),
            pivoted AS (
                SELECT domain, metric_name,
                       MAX   (CASE WHEN week_offset=0 THEN metric_value END) AS cur_val,
                       AVG   (CASE WHEN week_offset>0 THEN metric_value END) AS mu,
                       STDDEV(CASE WHEN week_offset>0 THEN metric_value END) AS sd,
                       COUNT (CASE WHEN week_offset>0 THEN metric_value END) AS n
                FROM unified GROUP BY domain, metric_name
            )
            SELECT p.domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n,
                   awrw_score.zscore(p.cur_val,p.mu,p.sd) AS z,
                   awrw_score.pct   (p.cur_val,p.mu)      AS pct,
                   awrw_score.bucket(p.cur_val,p.mu,p.sd,p.n,v_zc,v_zw) AS bkt,
                   pm.abs_floor, NVL(pm.pct_floor, v_pctfloor) AS pct_floor_eff, pm.polarity
            FROM pivoted p
            JOIN awrw_profile_metric pm
              ON pm.profile_name=v_pf AND pm.domain=p.domain AND pm.metric_name=p.metric_name
        ) LOOP
            v_fid     := NULL;
            v_is_find := FALSE;

            IF r.bkt IN ('CRITICAL','WARN') THEN
                -- gates: magnitude floor, percent floor, polarity
                IF r.cur_val >= r.abs_floor
                   AND ABS(NVL(r.pct,0)) >= r.pct_floor_eff
                   AND (r.polarity='BOTH'
                        OR (r.polarity='UP'   AND r.z > 0)
                        OR (r.polarity='DOWN' AND r.z < 0))
                THEN
                    v_is_find := TRUE;
                END IF;
            END IF;

            IF v_is_find THEN
                INSERT INTO awrw_findings (target_id, dbid, detector, subject_type, subject_id,
                       metric_domain, period_end_ts, cur_val, prior_mean, prior_sd, n_prior,
                       z_score, pct_delta, direction, severity)
                VALUES (p_target_id, v_dbid,
                       'SEASONAL', 'metric', r.metric_name, r.domain, p_period_end,
                       r.cur_val, r.mu, r.sd, r.n, r.z, r.pct,
                       CASE WHEN r.z >= 0 THEN 'UP' ELSE 'DOWN' END, r.bkt)
                RETURNING finding_id INTO v_fid;
                v_signal := 'ANOM';
            ELSIF r.bkt = 'OK' OR (r.bkt IN ('CRITICAL','WARN')) THEN
                v_signal := 'NORMAL';     -- scored, not anomalous (incl. gated-out)
            ELSE
                v_signal := 'NONE';       -- INSUFFICIENT_HISTORY / FLAT_BASELINE: no signal
            END IF;

            bump_alert(p_target_id, 'metric', r.metric_name, p_period_end,
                       r.bkt, v_signal, v_fire, v_clear, v_fid);
        END LOOP;

        -- REGRESSION + HEADLINE Detectors share this Period's windows and transaction
        detect_regressions(p_target_id, p_period_end, v_weeks, v_win_h, v_step_days,
                           v_zc, v_zw, v_fire, v_clear, v_reg_top_n,
                           v_reg_sql_min_sec, v_reg_wait_min_sec, v_reg_seg_min_blk);
        detect_headline(p_target_id, p_period_end, v_pf, v_weeks, v_win_h, v_step_days, v_zc, v_zw);

        -- advance the analysis HWM to this Period
        MERGE INTO awrw_analysis_hwm h
        USING (SELECT p_target_id tid FROM dual) s ON (h.target_id=s.tid)
        WHEN MATCHED THEN UPDATE SET last_period_end_ts = p_period_end, updated_ts = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (target_id, last_period_end_ts) VALUES (p_target_id, p_period_end);
        COMMIT;
    END score_period;

    -------------------------------------------------------------- analyze_target
    PROCEDURE analyze_target(p_target_id IN NUMBER, p_max_periods IN NUMBER DEFAULT 168) IS
        v_latest  TIMESTAMP;
        v_hwm     TIMESTAMP;
        v_period  TIMESTAMP;
        v_count   NUMBER := 0;
    BEGIN
        -- latest complete clock hour with a Snapshot for this Target
        SELECT CAST(TRUNC(CAST(MAX(end_interval_time) AS DATE), 'HH24') AS TIMESTAMP)
          INTO v_latest
          FROM awrw_snapshot
         WHERE dbid IN (SELECT dbid FROM awrw_dbid WHERE target_id = p_target_id);
        IF v_latest IS NULL THEN RETURN; END IF;

        BEGIN
            SELECT last_period_end_ts INTO v_hwm FROM awrw_analysis_hwm WHERE target_id = p_target_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_hwm := NULL;
        END;

        -- first run: score only the latest Period; otherwise march hour-by-hour
        v_period := CASE WHEN v_hwm IS NULL THEN v_latest
                         ELSE CAST(v_hwm AS DATE) + 1/24 END;
        WHILE v_period <= v_latest AND v_count < p_max_periods LOOP
            score_period(p_target_id, v_period);
            v_period := CAST(v_period AS DATE) + 1/24;
            v_count  := v_count + 1;
        END LOOP;
    END analyze_target;

    PROCEDURE analyze_all IS
    BEGIN
        FOR t IN (SELECT target_id FROM awrw_target WHERE enabled='Y' ORDER BY target_id) LOOP
            BEGIN
                analyze_target(t.target_id);
            EXCEPTION WHEN OTHERS THEN
                log_err(t.target_id, 'ANALYZE');   -- never block the fleet
            END;
        END LOOP;
    END analyze_all;

END awrw_analyze;
/
