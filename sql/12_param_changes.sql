--
-- 12_param_changes.sql
-- System (initialization) parameters whose value differs across the
-- compared windows.  For every window (current + ~weeks_back prior) we
-- read the parameter value as recorded at that window's END snapshot in
-- DBA_HIST_PARAMETER, then list only the parameters that are NOT constant
-- across all those snapshots -- i.e. the parameters that "changed between
-- the specified snapshots".  Rendered as a pivot: parameter x window.
--
-- Why the window END snap (not begin), and why windows_rollup (not
-- valid_windows):
--   * Each numbered data section shows one value per window; the END snap
--     is the value in effect at the close of the window, so the current
--     column is "now" and the prior columns are the historical values.
--     A change that happened mid-window still surfaces because the
--     resulting end-snap value will differ from the neighbouring window.
--   * Parameters most often change at instance startup -- which is exactly
--     the case windows_cte flags as valid_flag='N' (startup_time differs
--     across the window).  valid_windows DROPS those windows, which would
--     hide the most interesting changes.  windows_rollup keeps the
--     begin/end snap range for every window regardless of validity, so we
--     use it here.
--
-- RAC: snap_id is global per dbid (identical across instances at a point
-- in time), and parameters are normally uniform across instances.  To keep
-- one value per (parameter, window) cell we read a single instance:
-- ~inst_num when a specific instance was requested, otherwise the lowest
-- instance number present (param_inst CTE).  Per-instance parameter
-- differences in aggregate mode are out of scope for this pivot.
--
-- Read-only: pure SELECT against DBA_HIST_PARAMETER, no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 12_param_changes BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_header     VARCHAR2(4000);
    v_row        VARCHAR2(32767);
    v_cell       VARCHAR2(32767);
    v_n_changed  PLS_INTEGER := 0;

    -- (parameter_name || '|' || week_offset) -> value at that window's
    -- end snap.  A key with a NULL element means "present but unset";
    -- a missing key means "parameter not present at that window's snap".
    TYPE t_cells IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(160);
    v_cells      t_cells;

    -- Distinct changed parameter names in display (alphabetical) order.
    TYPE t_names IS TABLE OF VARCHAR2(128);
    v_names      t_names := t_names();
    v_prev_name  VARCHAR2(128);

    v_key        VARCHAR2(160);
    v_cur_key    VARCHAR2(160);
    v_cur_has    BOOLEAN;
    v_cur_val    VARCHAR2(4000);
    v_cell_has   BOOLEAN;
    v_cell_val   VARCHAR2(4000);
    v_changed    BOOLEAN;

    -- Render one parameter value cell.  p_is_cur marks the reference
    -- (current) column; p_chg adds the change highlight class.
    FUNCTION cell_html(p_has BOOLEAN, p_val VARCHAR2,
                       p_is_cur BOOLEAN, p_chg BOOLEAN) RETURN VARCHAR2 IS
        v_cls  VARCHAR2(40) := 'pval';
        -- 32767, not 24000: a 4000-char value can entity-escape to roughly
        -- 24000 and the <code> wrapper pushes it past 24000 -> ORA-06502 (F7).
        v_body VARCHAR2(32767);
    BEGIN
        IF p_is_cur THEN v_cls := v_cls || ' cur'; END IF;
        IF p_chg    THEN v_cls := v_cls || ' chg'; END IF;
        IF NOT p_has THEN
            v_body := '<span class="muted">&mdash;</span>';
        ELSIF p_val IS NULL THEN
            v_body := '<span class="muted">(unset)</span>';
        ELSE
            v_body := '<code>' || DBMS_XMLGEN.CONVERT(p_val) || '</code>';
        END IF;
        RETURN '<td class="' || v_cls || '">' || v_body || '</td>';
    END cell_html;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="param-changes"><h2>Parameter changes</h2>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
        || 'Initialization parameters from <code>dba_hist_parameter</code> whose '
        || 'value differs across the compared windows (value as of each '
        || 'window&rsquo;s end snapshot). Only changed parameters are listed; '
        || 'highlighted cells differ from the <b>Current</b> value. '
        || '&mdash; = not present at that snapshot; (unset) = present but '
        || 'empty.</p>');

    -- Load every (changed parameter, window) value into v_cells and build
    -- the ordered name list.  Single cursor; the changed-parameter filter
    -- and the per-window values come from the same scan.  We do NOT use a
    -- comma-CSV LISTAGG here because parameter values legitimately contain
    -- commas (e.g. control_files), which would corrupt CSV parsing.
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        win AS (
            -- carry the per-window DBID so the dba_hist_parameter join is
            -- qualified by (dbid, snap_id): across a non-CDB->PDB migration the
            -- same snap_id exists under both DBIDs, so snap_id alone would
            -- match the wrong window's parameters.
            SELECT week_offset, dbid, end_snap_id
            FROM   windows_rollup
            WHERE  end_snap_id IS NOT NULL
        ),
        n_win AS (
            SELECT COUNT(*) AS cnt FROM win
        ),
        param_inst AS (
            SELECT CASE WHEN ~inst_num = 0 THEN MIN(p.instance_number)
                        ELSE ~inst_num END AS inst
            FROM   dba_hist_parameter p
            JOIN   win w ON w.end_snap_id = p.snap_id
                       AND w.dbid        = p.dbid
        ),
        pv AS (
            SELECT w.week_offset, p.parameter_name, p.value
            FROM   win w
            JOIN   dba_hist_parameter p
              ON   p.dbid = w.dbid
             AND   p.snap_id = w.end_snap_id
             AND   p.instance_number = (SELECT inst FROM param_inst)
        ),
        changed AS (
            SELECT parameter_name
            FROM   pv
            GROUP BY parameter_name
            HAVING COUNT(DISTINCT NVL(value, '__NULL__')) > 1
                OR COUNT(*) < (SELECT cnt FROM n_win)
        )
        SELECT pv.parameter_name, pv.week_offset, pv.value
        FROM   pv
        JOIN   changed c ON c.parameter_name = pv.parameter_name
        ORDER  BY pv.parameter_name, pv.week_offset
    ) LOOP
        v_cells(r.parameter_name || '|' || r.week_offset) := r.value;
        IF v_prev_name IS NULL OR r.parameter_name <> v_prev_name THEN
            v_names.EXTEND;
            v_names(v_names.COUNT) := r.parameter_name;
            v_prev_name := r.parameter_name;
        END IF;
    END LOOP;

    v_n_changed := v_names.COUNT;

    IF v_n_changed = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<p style="color:var(--muted)">No system parameters '
            || 'changed across the compared windows.</p></section>');
        RETURN;
    END IF;

    -- Header: Parameter | Current | -1w | -2w | ...
    v_header := '<thead><tr><th>Parameter</th><th>Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th>&minus;'
            || REGEXP_SUBSTR('~offset_labels', '[^,]+', 1, k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table>' || v_header || '<tbody>');

    FOR i IN 1 .. v_names.COUNT LOOP
        v_cur_key := v_names(i) || '|0';
        v_cur_has := v_cells.EXISTS(v_cur_key);
        IF v_cur_has THEN v_cur_val := v_cells(v_cur_key);
                     ELSE v_cur_val := NULL; END IF;

        v_row := '<tr><td class="pname"><code>'
              || DBMS_XMLGEN.CONVERT(v_names(i)) || '</code></td>';

        -- Current column (the reference; never highlighted).
        v_row := v_row || cell_html(v_cur_has, v_cur_val, TRUE, FALSE);

        -- Prior windows: highlight when the value differs from current.
        -- A parameter value can be up to 4000 chars and entity-escaping can
        -- expand it up to 6-fold, so many long values across windows overflow both
        -- v_row (VARCHAR2(32767) -> ORA-06502) and the DBMS_OUTPUT single-line
        -- cap (32767 -> ORU-10028).  We flush the accumulated markup to its own
        -- line whenever the next cell would breach a safe threshold; a single
        -- escaped cell always fits under it, so no cell is ever split.  Normal
        -- short-value rows stay on one line and are byte-identical (F7).
        FOR k IN 1 .. v_weeks_back LOOP
            v_key := v_names(i) || '|' || k;
            v_cell_has := v_cells.EXISTS(v_key);
            IF v_cell_has THEN v_cell_val := v_cells(v_key);
                         ELSE v_cell_val := NULL; END IF;

            -- NULL-safe change test (presence and value both matter).
            IF v_cell_has <> v_cur_has THEN
                v_changed := TRUE;
            ELSIF NOT v_cell_has AND NOT v_cur_has THEN
                v_changed := FALSE;
            ELSE
                v_changed := (NVL(v_cell_val, '__NULL__')
                              <> NVL(v_cur_val, '__NULL__'));
            END IF;

            v_cell := cell_html(v_cell_has, v_cell_val, FALSE, v_changed);
            IF LENGTH(v_row) + LENGTH(v_cell) > 30000 THEN
                DBMS_OUTPUT.PUT_LINE(v_row);
                v_row := NULL;
            END IF;
            v_row := v_row || v_cell;
        END LOOP;

        v_row := v_row || '</tr>';
        DBMS_OUTPUT.PUT_LINE(v_row);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    DBMS_OUTPUT.PUT_LINE('<p style="font-size:12px;color:var(--muted)">'
        || TO_CHAR(v_n_changed) || ' parameter'
        || CASE WHEN v_n_changed = 1 THEN '' ELSE 's' END
        || ' changed across the compared windows.</p>');
    DBMS_OUTPUT.PUT_LINE('</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 12_param_changes END -->'); END;
/
