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
-- CDB: DBA_HIST_PARAMETER also carries one row per container (con_id /
-- con_dbid) for the same (dbid, snap_id, instance_number).  We collapse to
-- the LOWEST con_id (0 / the root -- the instance-level value a DBA means
-- by "the init parameter") via KEEP (DENSE_RANK FIRST ORDER BY con_id,
-- con_dbid), same tiebreak as section 17 rule R3 -- keep in lockstep. A
-- non-CDB has a single con_id, so this is a no-op there.
--
-- Read-only: pure SELECT against DBA_HIST_PARAMETER, no scratch table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 12_param_changes BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_header     VARCHAR2(32767);   -- one th (about 45 bytes) per window
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
    v_seen_pa    CLOB;              -- anchor_uniq memo (sql/lib/anchor_id.plsql)

    -- Render one parameter value cell.  p_is_cur marks the reference
    -- (current) column; p_chg adds the change highlight class; p_w is the
    -- window offset (0 = current, k = k-th prior window) exposed as
    -- data-w for the chrome's window-highlight wiring (X2).
    FUNCTION cell_html(p_has BOOLEAN, p_val VARCHAR2,
                       p_is_cur BOOLEAN, p_chg BOOLEAN, p_w PLS_INTEGER) RETURN VARCHAR2 IS
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
        -- Phase 4: a changed cell also carries a glyph (not colour-only).
        RETURN '<td class="' || v_cls || '" data-w="' || p_w || '">'
            || CASE WHEN p_chg THEN '<span class="g" title="differs from the Current value">&ne;</span> ' ELSE '' END
            || v_body || '</td>';
    END cell_html;
    @@sql/lib/anchor_id.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql

    -- A parameter's row id (table row, card links, Timeline row): the
    -- pure-function param_anchor (leading underscores kept apart), unique
    -- in the page via anchor_uniq -- every emitter here goes through this.
    FUNCTION pa_id(p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN anchor_uniq(param_anchor(p_name), p_name, v_seen_pa);
    END pa_id;

    -- a parameter value for the configuration card's step line: a byte
    -- count (all digits, 1 MB or more) reads as MB / GB, anything else is
    -- shown as recorded (the cell ellipsizes; the title keeps it whole)
    FUNCTION pv_txt(p_v VARCHAR2) RETURN VARCHAR2 IS
        v_n NUMBER;
    BEGIN
        IF p_v IS NULL THEN RETURN '(unset)'; END IF;
        IF REGEXP_LIKE(p_v, '^[0-9]{7,}$') THEN
            v_n := TO_NUMBER(p_v);
            IF v_n >= 1073741824 THEN
                RETURN TO_CHAR(ROUND(v_n / 1073741824, 1), 'FM999999990D9', 'NLS_NUMERIC_CHARACTERS=''.,''')
                    || ' GB';
            ELSIF v_n >= 1048576 THEN
                RETURN TO_CHAR(ROUND(v_n / 1048576, 1), 'FM999999990D9', 'NLS_NUMERIC_CHARACTERS=''.,''')
                    || ' MB';
            END IF;
        END IF;
        RETURN p_v;
    END pv_txt;

    -- the value of parameter p_name at window p_k ('__NONE__' = not present)
    FUNCTION pv_at(p_name VARCHAR2, p_k PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        IF NOT v_cells.EXISTS(p_name || '|' || p_k) THEN RETURN '__NONE__'; END IF;
        RETURN NVL(v_cells(p_name || '|' || p_k), '__NULL__');
    END pv_at;

    FUNCTION pv_html(p_v VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_v WHEN '__NONE__' THEN '&ndash;' WHEN '__NULL__' THEN '(unset)'
                        ELSE DBMS_XMLGEN.CONVERT(pv_txt(p_v)) END;
    END pv_html;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="param-changes" class="vw in-s in-a lib" style="--os:9"><h2>Parameters'
        || '<small class="h2sub">Initialization parameters whose value differs across the windows</small></h2>');

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
            -- One value per (window, parameter), taken from the LOWEST con_id
            -- (0 in a non-CDB, the root in a CDB) -- i.e. the instance-level
            -- value a DBA means by "the init parameter".  In a CDB
            -- DBA_HIST_PARAMETER carries one row per container for the same
            -- (dbid, snap_id, instance_number), so a bare join fans out: it
            -- would invent phantom changes when the arbitrary per-window pick
            -- alternates between the root value and a PDB's. (Verified on
            -- dbmint: sga_target reads 1610612736 in the root and 0 in both
            -- PDBs at EVERY compared snapshot, so it never changed.) Same
            -- tiebreak as section 17 rule R3 -- keep in lockstep. A non-CDB
            -- has a single con_id, so this is a no-op there.
            SELECT w.week_offset, p.parameter_name,
                   MAX(p.value) KEEP (DENSE_RANK FIRST
                       ORDER BY p.con_id, p.con_dbid) AS value
            FROM   win w
            JOIN   dba_hist_parameter p
              ON   p.dbid = w.dbid
             AND   p.snap_id = w.end_snap_id
             AND   p.instance_number = (SELECT inst FROM param_inst)
            GROUP BY w.week_offset, p.parameter_name
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
            || 'changed across the compared windows.</p>' || lib_ls('param-changes', 'none differ') || '</section>');
        RETURN;
    END IF;

    -- v1.6.0: a parameter that differs across the compared windows is shown
    -- in the Summary view by the configuration card (emitted below and moved
    -- into 07's "What changed around it" slot), so this table stays in All
    -- sections only.

    -- Header: Parameter | Current | -1w | -2w | ...
    v_header := '<thead><tr><th>Parameter</th><th data-w="0">Current</th>';
    FOR k IN 1 .. v_weeks_back LOOP
        v_header := v_header || '<th data-w="' || k || '">&minus;'
            || off_label(k) || '</th>';
    END LOOP;
    v_header := v_header || '</tr></thead>';
    DBMS_OUTPUT.PUT_LINE('<table id="param-changes-table">' || v_header || '<tbody>');

    FOR i IN 1 .. v_names.COUNT LOOP
        v_cur_key := v_names(i) || '|0';
        v_cur_has := v_cells.EXISTS(v_cur_key);
        IF v_cur_has THEN v_cur_val := v_cells(v_cur_key);
                     ELSE v_cur_val := NULL; END IF;

        -- entity anchor pa-<parameter> (sql/lib/anchor_id.plsql)
        v_row := '<tr id="' || pa_id(v_names(i)) || '"><td class="pname"><code>'
              || DBMS_XMLGEN.CONVERT(v_names(i)) || '</code></td>';

        -- Current column (the reference; never highlighted).
        v_row := v_row || cell_html(v_cur_has, v_cur_val, TRUE, FALSE, 0);

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

            v_cell := cell_html(v_cell_has, v_cell_val, FALSE, v_changed, k);
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

    --
    -- v1.6.0 Summary: the configuration card.  One step line per changed
    -- parameter on the window component (sql/lib/wingrid.plsql), so each
    -- change lines up under the release flag of the interval it happened
    -- in; the gutter names the window of the latest change and the marker
    -- on that boundary (filled client-side, js_wingrid.plsql).  Emitted
    -- hidden, then moved into 07's #changes-slot, which unhides the
    -- "What changed around it" section.  At most 8 rows; the table above
    -- lists every one.
    --
    DECLARE
        v_cur_n   PLS_INTEGER := 0;       -- parameters that changed INTO the Current window
        v_cur_one VARCHAR2(128);
        v_first   VARCHAR2(128);
        v_last    PLS_INTEGER;
        v_v       VARCHAR2(4000);
        v_prev    VARCHAR2(4000);
        v_base    VARCHAR2(4000);
        v_start   BOOLEAN;
        v_lvl     VARCHAR2(2);
        v_cells_h VARCHAR2(32767);
        v_gut     VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. v_names.COUNT LOOP
            IF v_weeks_back >= 1 AND pv_at(v_names(i), 0) <> pv_at(v_names(i), 1) THEN
                v_cur_n := v_cur_n + 1;
                v_cur_one := v_names(i);
            END IF;
        END LOOP;
        -- the evidence library's row text (Summary view)
        DBMS_OUTPUT.PUT_LINE(lib_ls('param-changes', '<b>' || v_n_changed || '</b>'
            || CASE WHEN v_n_changed = 1 THEN ' differs' ELSE ' differ' END || ', '
            || CASE WHEN v_cur_n = 0 THEN 'none' ELSE TO_CHAR(v_cur_n) END || ' in Current'));
        DBMS_OUTPUT.PUT_LINE('<article class="panel fc chg" id="f-config" aria-labelledby="f-config-h" hidden>'
            || '<header class="fc-h"><div class="fc-k"><span class="sv"><b class="gk">&ne;</b>'
            || 'Configuration</span></div></header>'
            || '<h3 id="f-config-h">' || v_n_changed || ' parameter'
            || CASE WHEN v_n_changed = 1 THEN ' differs' ELSE 's differ' END
            || ' across the compared windows</h3>'
            || '<p class="takeaway">'
            || CASE WHEN v_cur_n = 1
                    THEN 'Only ' || ent('<code>' || DBMS_XMLGEN.CONVERT(v_cur_one) || '</code>',
                                        pa_id(v_cur_one), 'parameter')
                         || ' changed into the Current window.'
                    WHEN v_cur_n > 1
                    THEN v_cur_n || ' of them changed into the Current window.'
                    ELSE 'None changed into the Current window: every change is older.' END
            || '</p>');
        wg_ruler_put('<div class="cfg-wg"><div class="wg fit"' || wg_attr
            || ' role="table" aria-label="Parameter values per compared window">',
            '<span class="ct">Parameter</span>', '<span class="gt">Changed</span>');
        FOR i IN 1 .. LEAST(8, v_names.COUNT) LOOP
            IF v_first IS NULL THEN v_first := v_names(i); END IF;
            v_base := pv_at(v_names(i), v_weeks_back);
            v_prev := NULL;
            v_last := NULL;
            v_cells_h := NULL;
            -- the row head first: the cells below go through wg_buf, which
            -- may flush part of them to the output before the loop ends
            DBMS_OUTPUT.PUT_LINE('<div class="r p" data-name="' || DBMS_XMLGEN.CONVERT(v_names(i)) || '" role="row">'
                || '<div class="l" role="rowheader"><span class="nm">'
                || ent('<code>' || DBMS_XMLGEN.CONVERT(v_names(i)) || '</code>', pa_id(v_names(i)), 'parameter')
                || '</span><span class="sub">'
                || pv_html(v_base) || ' &rarr; ' || pv_html(pv_at(v_names(i), 0))
                || '</span></div>');
            FOR k IN REVERSE 0 .. v_weeks_back LOOP
                v_v := pv_at(v_names(i), k);
                v_start := (k = v_weeks_back) OR (v_v <> v_prev);
                IF v_start AND k < v_weeks_back THEN v_last := k; END IF;
                v_lvl := CASE WHEN v_v = v_base THEN 'lo' ELSE 'hi' END;
                wg_buf(v_cells_h, '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                    || '" data-w="' || k || '"><i class="st ' || v_lvl
                    || CASE WHEN v_start AND k < v_weeks_back THEN ' rise' END || '" aria-hidden="true"></i>'
                    || CASE WHEN v_start AND k < v_weeks_back THEN '<i class="nd" aria-hidden="true"></i>' END
                    || CASE WHEN v_start OR k = 0
                            THEN '<span class="pv ' || v_lvl || '" title="'
                                 || DBMS_XMLGEN.CONVERT(CASE v_v WHEN '__NONE__' THEN 'not recorded'
                                                                 WHEN '__NULL__' THEN '(unset)' ELSE v_v END)
                                 || '">' || pv_html(v_v) || '</span>' END
                    || '</div>');
                v_prev := v_v;
            END LOOP;
            v_gut := '<div class="g" role="cell"><div class="gl1"><span class="d1">'
                || CASE WHEN v_last IS NULL THEN 'varies'
                        WHEN v_last = 0 THEN 'changed in Current'
                        ELSE 'changed ' || wg_date(v_last) END
                || '</span></div>'
                || CASE WHEN v_last IS NOT NULL
                        THEN '<div class="gx"><span data-mk-at="' || v_last || '" data-mk-icon hidden></span></div>' END
                || '</div>';
            DBMS_OUTPUT.PUT_LINE(v_cells_h);
            DBMS_OUTPUT.PUT_LINE(v_gut || '</div>');
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('</div></div>'
            || CASE WHEN v_names.COUNT > 8
                    THEN '<p class="cfg-more">and ' || (v_names.COUNT - 8) || ' more in '
                         || '<a href="#param-changes">Parameters</a></p>' END
            || '<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
            || pa_id(v_first) || '">Timeline &rarr;</a>'
            || '<span class="evl"><a href="#param-changes">Parameters</a></span></footer></article>');
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var s=document.getElementById("changes-slot"),'
            || 'c=document.getElementById("f-config");if(!s||!c)return;s.appendChild(c);c.hidden=false;'
            || 'var x=document.getElementById("s-changes");if(x)x.hidden=false;})();</script>');

        -- v1.6.0 Timeline: the "Configuration" lane, the same step lines
        -- for every changed parameter (at most 20), id tl-pa-<parameter>
        -- (the config card's "Timeline ->" target); each cell carries its
        -- value for the hover tooltip (sql/lib/timeline.plsql).
        -- Every cell carries its full value (data-pv), so a row of long
        -- values over many windows goes out through wg_buf (several lines
        -- when needed) instead of one VARCHAR2 / PUT_LINE.
        FOR i IN 1 .. LEAST(20, v_names.COUNT) LOOP
            v_base := pv_at(v_names(i), v_weeks_back);
            v_prev := NULL;
            v_last := NULL;
            v_cells_h := CASE WHEN i = 1 THEN tl_open('config') END
                || '<div class="r p" id="tl-' || pa_id(v_names(i)) || '" data-name="'
                || DBMS_XMLGEN.CONVERT(v_names(i)) || '" role="row">'
                || tl_lab(ent(DBMS_XMLGEN.CONVERT(v_names(i)), pa_id(v_names(i)), 'parameter'),
                          pv_html(v_base) || ' &rarr; ' || pv_html(pv_at(v_names(i), 0)));
            FOR k IN REVERSE 0 .. v_weeks_back LOOP
                v_v := pv_at(v_names(i), k);
                v_start := (k = v_weeks_back) OR (v_v <> v_prev);
                IF v_start AND k < v_weeks_back THEN v_last := k; END IF;
                v_lvl := CASE WHEN v_v = v_base THEN 'lo' ELSE 'hi' END;
                wg_buf(v_cells_h, '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                    || '" data-w="' || k || '" data-pv="' || pv_html(v_v) || '"><i class="st ' || v_lvl
                    || CASE WHEN v_start AND k < v_weeks_back THEN ' rise' END || '" aria-hidden="true"></i>'
                    || CASE WHEN v_start AND k < v_weeks_back THEN '<i class="nd" aria-hidden="true"></i>' END
                    || CASE WHEN v_start OR k = 0
                            THEN '<span class="pv ' || v_lvl || '">' || pv_html(v_v) || '</span>' END
                    || '</div>');
                v_prev := v_v;
            END LOOP;
            wg_buf(v_cells_h, '<div class="g" role="cell"><div class="gl1"><span class="d1">'
                || CASE WHEN v_last IS NULL THEN 'varies'
                        WHEN v_last = 0 THEN 'changed in Current'
                        ELSE 'changed ' || wg_date(v_last) END
                || '</span></div>'
                || CASE WHEN v_last IS NOT NULL
                        THEN '<div class="gx"><span data-mk-at="' || v_last || '" data-mk-icon hidden></span></div>' END
                || '</div></div>'
                || CASE WHEN i = LEAST(20, v_names.COUNT) THEN tl_close END);
            DBMS_OUTPUT.PUT_LINE(v_cells_h);
        END LOOP;
    END;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 12_param_changes END -->'); END;
/
