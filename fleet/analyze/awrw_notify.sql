--
-- fleet/analyze/awrw_notify.sql
--
-- The notifier: renders the periodic fleet Digest from Alert State + Findings +
-- Target Health. Only Targets with a FIRING (new or ongoing) or just-recovered
-- Alert appear; a Coverage section lists non-Current Targets so silence can
-- never read as healthy. build_digest is read-only (safe to preview);
-- mark_notified records what a Digest has carried so the next one shows
-- new-vs-ongoing correctly. Delivery (UTL_SMTP/UTL_MAIL) is site-specific and
-- left to the caller.
--
CREATE OR REPLACE PACKAGE awrw_notify AS
    FUNCTION  build_digest RETURN CLOB;     -- read-only HTML digest (safe to preview)
    FUNCTION  run_digest   RETURN NUMBER;   -- build + archive to awrw_digest + mark_notified; returns digest_id
    -- Filesystem delivery: write every undelivered awrw_digest row to an HTML file
    -- in p_dir (an Oracle DIRECTORY on the warehouse host), stamping delivered_ts +
    -- file_name. No-op until the directory object exists (see schedule/digest_dir.sql).
    PROCEDURE deliver_to_files(p_dir VARCHAR2 DEFAULT 'AWRW_DIGEST_DIR');
    PROCEDURE mark_notified;                -- stamp notified_fired/cleared timestamps
END awrw_notify;
/

CREATE OR REPLACE PACKAGE BODY awrw_notify AS

    FUNCTION build_digest RETURN CLOB IS
        v       CLOB;
        v_any   BOOLEAN;
        PROCEDURE p(s VARCHAR2) IS BEGIN v := v || s || CHR(10); END;
        FUNCTION x(s VARCHAR2) RETURN VARCHAR2 IS BEGIN RETURN DBMS_XMLGEN.CONVERT(NVL(s,'')); END;
        FUNCTION num(n NUMBER, d NUMBER DEFAULT 2) RETURN VARCHAR2 IS
        BEGIN RETURN CASE WHEN n IS NULL THEN '-'
               ELSE TO_CHAR(ROUND(n,d),'FM999999990D000','NLS_NUMERIC_CHARACTERS=''.,''') END; END;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v, TRUE);
        p('<html><head><meta charset="utf-8"><style>'||
          'body{font:14px system-ui,sans-serif;margin:24px;color:#1a1a1a}'||
          'h1{font-size:20px}h2{font-size:16px;margin-top:24px;border-bottom:1px solid #ddd}'||
          'h3{font-size:14px;margin:14px 0 4px}table{border-collapse:collapse;width:100%;font-size:13px}'||
          'td,th{text-align:left;padding:3px 8px;border-bottom:1px solid #eee}'||
          '.crit{color:#c0231b;font-weight:600}.warn{color:#d28a00;font-weight:600}'||
          '.tag{font-size:11px;color:#666}.up{color:#c0231b}.down{color:#2f7d3a}'||
          '.kind{font-size:11px;color:#555;text-transform:uppercase}'||
          '.flip{color:#c0231b;font-size:11px;font-weight:600;margin-left:6px}</style></head><body>');
        p('<h1>AWR Fleet Digest</h1>');
        p('<p class="tag">generated '||TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI TZR')||'</p>');

        ---------------------------------------------------- interesting (FIRING)
        p('<h2>Interesting databases</h2>');
        v_any := FALSE;
        FOR t IN (SELECT DISTINCT a.target_id, tg.target_name
                    FROM awrw_alert_state a JOIN awrw_target tg ON tg.target_id=a.target_id
                   WHERE a.state='FIRING' ORDER BY tg.target_name) LOOP
            v_any := TRUE;
            p('<h3>'||x(t.target_name)||'</h3>');
            p('<table><tr><th>severity</th><th>type</th><th>subject</th><th>current</th><th>baseline</th>'||
              '<th>z</th><th>% chg</th><th>dir</th><th></th></tr>');
            FOR f IN (SELECT a.subject_id, a.subject_type, a.severity, a.fired_period_ts, a.notified_fired_ts,
                             fd.cur_val, fd.prior_mean, fd.z_score, fd.pct_delta, fd.direction, fd.plan_changed
                        FROM awrw_alert_state a
                        LEFT JOIN awrw_findings fd ON fd.finding_id = a.last_finding_id
                       WHERE a.target_id=t.target_id AND a.state='FIRING'
                       ORDER BY CASE a.severity WHEN 'CRITICAL' THEN 0 ELSE 1 END,
                                ABS(NVL(fd.z_score,0)) DESC) LOOP
                p('<tr>'||
                  '<td class="'||CASE WHEN f.severity='CRITICAL' THEN 'crit' ELSE 'warn' END||'">'||f.severity||'</td>'||
                  '<td class="kind">'||x(f.subject_type)||'</td>'||
                  '<td>'||x(f.subject_id)||
                       CASE WHEN f.plan_changed='Y' THEN '<span class="flip">plan changed</span>' ELSE '' END||'</td>'||
                  '<td>'||num(f.cur_val)||'</td>'||
                  '<td>'||num(f.prior_mean)||'</td>'||
                  '<td>'||num(f.z_score)||'</td>'||
                  '<td>'||num(f.pct_delta,1)||'%</td>'||
                  '<td class="'||LOWER(NVL(f.direction,''))||'">'||NVL(f.direction,'')||'</td>'||
                  '<td class="tag">'||CASE WHEN f.notified_fired_ts IS NULL
                       OR f.notified_fired_ts < f.fired_period_ts THEN 'NEW' ELSE 'ongoing' END||'</td>'||
                  '</tr>');
            END LOOP;
            p('</table>');
        END LOOP;
        IF NOT v_any THEN p('<p>None - all Current targets are quiet.</p>'); END IF;

        ---------------------------------------------------- headline strip
        -- The HEADLINE Detector's executive snapshot: each Target's marquee
        -- hero-metrics that deviated in its most recent analysed Period. Read
        -- straight from Findings (not Alert State) -- informational context that
        -- rounds out the firing alerts above.
        p('<h2>Headline movers</h2>');
        DECLARE v_hl BOOLEAN := FALSE; BEGIN
            FOR h IN (
                SELECT tg.target_name, f.subject_id, f.severity,
                       f.cur_val, f.prior_mean, f.z_score, f.pct_delta, f.direction
                  FROM awrw_findings f
                  JOIN awrw_target tg ON tg.target_id = f.target_id
                  JOIN (SELECT target_id, MAX(period_end_ts) mp
                          FROM awrw_findings WHERE detector='HEADLINE' GROUP BY target_id) lp
                    ON lp.target_id = f.target_id AND lp.mp = f.period_end_ts
                 WHERE f.detector='HEADLINE'
                 ORDER BY tg.target_name,
                          CASE f.severity WHEN 'CRITICAL' THEN 0 ELSE 1 END,
                          ABS(NVL(f.z_score,0)) DESC) LOOP
                IF NOT v_hl THEN
                    p('<table><tr><th>target</th><th>metric</th><th>severity</th><th>current</th>'||
                      '<th>baseline</th><th>z</th><th>% chg</th><th>dir</th></tr>');
                    v_hl := TRUE;
                END IF;
                p('<tr><td>'||x(h.target_name)||'</td>'||
                  '<td>'||x(h.subject_id)||'</td>'||
                  '<td class="'||CASE WHEN h.severity='CRITICAL' THEN 'crit' ELSE 'warn' END||'">'||h.severity||'</td>'||
                  '<td>'||num(h.cur_val)||'</td>'||
                  '<td>'||num(h.prior_mean)||'</td>'||
                  '<td>'||num(h.z_score)||'</td>'||
                  '<td>'||num(h.pct_delta,1)||'%</td>'||
                  '<td class="'||LOWER(NVL(h.direction,''))||'">'||NVL(h.direction,'')||'</td></tr>');
            END LOOP;
            IF v_hl THEN p('</table>');
            ELSE p('<p>No headline deviations in the latest analysed period.</p>'); END IF;
        END;

        ------------------------------------------------------------- recovered
        DECLARE v_rec BOOLEAN := FALSE; BEGIN
            FOR r IN (SELECT tg.target_name, a.subject_id, a.cleared_period_ts
                        FROM awrw_alert_state a JOIN awrw_target tg ON tg.target_id=a.target_id
                       WHERE a.state='NORMAL' AND a.cleared_period_ts IS NOT NULL
                         AND (a.notified_cleared_ts IS NULL OR a.notified_cleared_ts < a.cleared_period_ts)
                       ORDER BY tg.target_name, a.subject_id) LOOP
                IF NOT v_rec THEN p('<h2>Recovered</h2><table>'); v_rec := TRUE; END IF;
                p('<tr><td>'||x(r.target_name)||'</td><td>'||x(r.subject_id)||'</td>'||
                  '<td class="tag">cleared '||TO_CHAR(r.cleared_period_ts,'YYYY-MM-DD HH24:MI')||'</td></tr>');
            END LOOP;
            IF v_rec THEN p('</table>'); END IF;
        END;

        ---------------------------------------------------------- coverage
        p('<h2>Coverage</h2>');
        DECLARE v_cov BOOLEAN := FALSE; BEGIN
            FOR h IN (SELECT tg.target_name, hh.collect_status, hh.last_snap_end_ts
                        FROM awrw_target_health hh JOIN awrw_target tg ON tg.target_id=hh.target_id
                       WHERE hh.collect_status IN ('LAGGING','STALE','UNREACHABLE')
                       ORDER BY hh.collect_status, tg.target_name) LOOP
                IF NOT v_cov THEN p('<table><tr><th>target</th><th>status</th><th>last snapshot</th></tr>'); v_cov := TRUE; END IF;
                p('<tr><td>'||x(h.target_name)||'</td><td>'||h.collect_status||'</td>'||
                  '<td>'||NVL(TO_CHAR(h.last_snap_end_ts,'YYYY-MM-DD HH24:MI'),'-')||'</td></tr>');
            END LOOP;
            IF v_cov THEN p('</table>'); ELSE p('<p>All targets Current.</p>'); END IF;
        END;

        p('</body></html>');
        RETURN v;
    END build_digest;

    -- Render the Digest, archive it to awrw_digest, and stamp Alert State as
    -- notified -- the schedulable form. Delivery (email/Slack) is decoupled: a
    -- mailer reads the latest awrw_digest row (delivered_ts IS NULL) and sends it.
    FUNCTION run_digest RETURN NUMBER IS
        v_html  CLOB;
        v_id    NUMBER;
        v_fire  NUMBER;
        v_recov NUMBER;
        v_lag   NUMBER;
    BEGIN
        v_html := build_digest;
        SELECT COUNT(*) INTO v_fire FROM awrw_alert_state WHERE state='FIRING';
        SELECT COUNT(*) INTO v_recov FROM awrw_alert_state
          WHERE state='NORMAL' AND cleared_period_ts IS NOT NULL
            AND (notified_cleared_ts IS NULL OR notified_cleared_ts < cleared_period_ts);
        SELECT COUNT(*) INTO v_lag FROM awrw_target_health
          WHERE collect_status IN ('LAGGING','STALE','UNREACHABLE');
        INSERT INTO awrw_digest (firing_count, recovered_count, lagging_count, html)
        VALUES (v_fire, v_recov, v_lag, v_html)
        RETURNING digest_id INTO v_id;
        mark_notified;   -- stamps notified_fired/cleared and COMMITs (archives the digest too)
        RETURN v_id;
    END run_digest;

    -- Write a CLOB to a server file line-by-line on its own CHR(10) breaks, so no
    -- single PUT exceeds the line buffer (the Digest's lines are all short).
    PROCEDURE write_clob_to_file(p_dir VARCHAR2, p_fname VARCHAR2, p_clob CLOB) IS
        f       UTL_FILE.FILE_TYPE;
        v_len   NUMBER := DBMS_LOB.GETLENGTH(p_clob);
        v_start NUMBER := 1;
        v_nl    NUMBER;
    BEGIN
        f := UTL_FILE.FOPEN(p_dir, p_fname, 'w', 32767);
        WHILE v_len IS NOT NULL AND v_start <= v_len LOOP
            v_nl := DBMS_LOB.INSTR(p_clob, CHR(10), v_start);
            IF v_nl = 0 THEN                          -- final segment, no trailing newline
                UTL_FILE.PUT(f, DBMS_LOB.SUBSTR(p_clob, v_len - v_start + 1, v_start));
                EXIT;
            ELSIF v_nl = v_start THEN                 -- empty line
                UTL_FILE.NEW_LINE(f);
                v_start := v_nl + 1;
            ELSE
                UTL_FILE.PUT_LINE(f, DBMS_LOB.SUBSTR(p_clob, v_nl - v_start, v_start));
                v_start := v_nl + 1;
            END IF;
        END LOOP;
        UTL_FILE.FFLUSH(f);
        UTL_FILE.FCLOSE(f);
    EXCEPTION
        WHEN OTHERS THEN
            IF UTL_FILE.IS_OPEN(f) THEN UTL_FILE.FCLOSE(f); END IF;
            RAISE;
    END write_clob_to_file;

    PROCEDURE deliver_to_files(p_dir VARCHAR2 DEFAULT 'AWRW_DIGEST_DIR') IS
        v_cfg   NUMBER;
        v_fname VARCHAR2(512);
    BEGIN
        -- file delivery stays OFF until the DIRECTORY exists and is granted to us
        SELECT COUNT(*) INTO v_cfg FROM all_directories WHERE directory_name = UPPER(p_dir);
        IF v_cfg = 0 THEN RETURN; END IF;

        FOR d IN (SELECT digest_id, generated_ts, html FROM awrw_digest
                   WHERE delivered_ts IS NULL ORDER BY digest_id) LOOP
            v_fname := 'awr_fleet_digest_'||d.digest_id||'_'||
                       TO_CHAR(d.generated_ts,'YYYYMMDD_HH24MISS')||'.html';
            write_clob_to_file(p_dir, v_fname, d.html);              -- per-cycle archive file
            write_clob_to_file(p_dir, 'awr_fleet_digest_latest.html', d.html); -- stable convenience path
            UPDATE awrw_digest SET delivered_ts = SYSTIMESTAMP, file_name = v_fname
             WHERE digest_id = d.digest_id;
        END LOOP;
        COMMIT;
    END deliver_to_files;

    PROCEDURE mark_notified IS
    BEGIN
        UPDATE awrw_alert_state
           SET notified_fired_ts = fired_period_ts
         WHERE state='FIRING'
           AND (notified_fired_ts IS NULL OR notified_fired_ts < fired_period_ts);
        UPDATE awrw_alert_state
           SET notified_cleared_ts = cleared_period_ts
         WHERE state='NORMAL' AND cleared_period_ts IS NOT NULL
           AND (notified_cleared_ts IS NULL OR notified_cleared_ts < cleared_period_ts);
        COMMIT;
    END mark_notified;

END awrw_notify;
/
