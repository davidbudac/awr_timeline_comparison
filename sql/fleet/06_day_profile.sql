--
-- sql/fleet/06_day_profile.sql
-- Optional "Day profile" band in this database's detail row: every hour of
-- the 24 h ending at target_end scored against the SAME hour-of-day on the
-- profile_days prior days (1-day cadence, independent of step/step_unit).
-- Rendered by js_fleet_charts.plsql (renderProfile) as an inline-SVG
-- heatmap (24 hour columns x 9 stat rows, cell = signed z-score) from the
-- window.FLEET_PROFILE[<alias>] payload emitted here -- no ECharts, offline
-- by construction, same as the ASH bands.
--
-- The matrix comes from the shared sql/lib/day_profile_cte.sql chain (also
-- consumed by the single-DB section 16), so the fleet band and the detailed
-- report can never disagree.  profile_days = 0 (the default, i.e. the
-- FLEET_PROFILE_DAYS env knob unset) emits nothing but the two AWR-SECTION
-- markers, keeping every existing fragment byte-identical.
--
-- Informational only: this band does NOT emit a FLEET-COUNTS comment and
-- never changes the row score / sort order (10*crit + 3*warn + top-SQL
-- points stay as documented) -- it is a drill-down aid, not a ranking input.
--
-- Payload shape (all numbers NLS-pinned, NULL cells as the literal null):
--   window.FLEET_PROFILE["<alias>"] = {ndays:N, hours:["HH:MM",...24],
--       stats:["label",...], z:[[24]...], cur:[[24]...], mu:[[24]...],
--       n:[[24]...], pct:[[24]...], sev:[["bucket",...24]...]}
-- Row order = stat order (dp_targets.ord); hours chronological (oldest
-- first, the hour ending at target_end last).  Labels are JS-string escaped
-- (backslash + double quote), same as 02_ash.sql.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06 BEGIN -->'); END;
/

DECLARE
    TYPE str_t IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
    v_days     NUMBER := ~profile_days;
    v_nstat    PLS_INTEGER := 0;
    v_last_ord NUMBER := -1;
    v_hours    VARCHAR2(4000);
    v_names    str_t; v_z str_t; v_cur str_t; v_mu str_t; v_n str_t; v_pct str_t; v_sev str_t;
    v_crit     NUMBER := 0;
    v_warn     NUMBER := 0;
    v_has_cur  BOOLEAN := FALSE;   -- any current-day cell populated?

    FUNCTION jn(p NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p IS NULL THEN RETURN 'null'; END IF;
        RETURN TO_CHAR(p, 'FM99999999990D000000', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END;
    FUNCTION js(p VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '"' || REPLACE(REPLACE(p, '\', '\\'), '"', '\"') || '"';
    END;
    PROCEDURE emit_matrix(p_key VARCHAR2, p_arr IN OUT NOCOPY str_t) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_key || ':[');
        FOR o IN 1 .. v_nstat LOOP
            DBMS_OUTPUT.PUT_LINE(CASE WHEN o > 1 THEN ',' ELSE '' END
                || '[' || SUBSTR(p_arr(o), 2) || ']');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(']');
    END;
BEGIN
    IF v_days <= 0 THEN
        RETURN;
    END IF;

    FOR c IN (
        WITH
        @@sql/lib/day_profile_cte.sql
        SELECT ord, label, hour_slot, hour_label, cur_val, mu, n, z_score,
               pct_delta, change_bucket
        FROM   dp_scored
        ORDER BY ord, hour_slot DESC
    ) LOOP
        IF c.cur_val IS NOT NULL THEN v_has_cur := TRUE; END IF;
        IF c.ord <> v_last_ord THEN
            v_nstat := v_nstat + 1;
            v_last_ord := c.ord;
            v_names(v_nstat) := c.label;
            v_z(v_nstat) := ''; v_cur(v_nstat) := ''; v_mu(v_nstat) := '';
            v_n(v_nstat) := ''; v_pct(v_nstat) := ''; v_sev(v_nstat) := '';
        END IF;
        IF v_nstat = 1 THEN
            v_hours := v_hours || ',' || js(c.hour_label);
        END IF;
        v_z(v_nstat)   := v_z(v_nstat)   || ',' || jn(ROUND(c.z_score, 3));
        v_cur(v_nstat) := v_cur(v_nstat) || ',' || jn(c.cur_val);
        v_mu(v_nstat)  := v_mu(v_nstat)  || ',' || jn(c.mu);
        v_n(v_nstat)   := v_n(v_nstat)   || ',' || NVL(c.n, 0);
        v_pct(v_nstat) := v_pct(v_nstat) || ',' || jn(ROUND(c.pct_delta, 1));
        v_sev(v_nstat) := v_sev(v_nstat) || ',' || js(c.change_bucket);
        IF c.change_bucket = 'large' THEN v_crit := v_crit + 1;
        ELSIF c.change_bucket = 'moderate' THEN v_warn := v_warn + 1;
        END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('<div class="detail-block timeline-box">');
    DBMS_OUTPUT.PUT_LINE('<div class="panel-h">Day profile &mdash; each hour of the last 24 h vs '
        || 'the same hour on the ' || v_days || ' prior day'
        || CASE WHEN v_days = 1 THEN '' ELSE 's' END
        || ' &middot; ' || v_crit || ' large &middot; ' || v_warn || ' moderate</div>');
    IF NOT v_has_cur THEN
        DBMS_OUTPUT.PUT_LINE('<div class="detail-link muted">No usable snapshot pairs in the '
            || 'last 24 h &mdash; no profile.</div></div>');
        RETURN;
    END IF;
    DBMS_OUTPUT.PUT_LINE('<div class="day-profile" data-profile-of="'
        || DBMS_XMLGEN.CONVERT('~fleet_alias') || '"></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="tl-caption"></div>');
    DBMS_OUTPUT.PUT_LINE('</div>');

    DBMS_OUTPUT.PUT_LINE('<script>window.FLEET_PROFILE=window.FLEET_PROFILE||{};');
    DBMS_OUTPUT.PUT_LINE('window.FLEET_PROFILE["' || '~fleet_alias' || '"]={ndays:' || v_days
        || ',hours:[' || SUBSTR(v_hours, 2) || '],');
    DBMS_OUTPUT.PUT_LINE('stats:[');
    FOR o IN 1 .. v_nstat LOOP
        DBMS_OUTPUT.PUT_LINE(CASE WHEN o > 1 THEN ',' ELSE '' END || js(v_names(o)));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('],');
    emit_matrix('z',   v_z);   DBMS_OUTPUT.PUT_LINE(',');
    emit_matrix('cur', v_cur); DBMS_OUTPUT.PUT_LINE(',');
    emit_matrix('mu',  v_mu);  DBMS_OUTPUT.PUT_LINE(',');
    emit_matrix('n',   v_n);   DBMS_OUTPUT.PUT_LINE(',');
    emit_matrix('pct', v_pct); DBMS_OUTPUT.PUT_LINE(',');
    emit_matrix('sev', v_sev);
    DBMS_OUTPUT.PUT_LINE('};</script>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_06 END -->'); END;
/
