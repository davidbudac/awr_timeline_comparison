--
-- 06_top_sql.sql
-- Top-N SQL per window from DBA_HIST_SQLSTAT using the pre-computed *_DELTA
-- columns.  Ranks the same SQLs five times: by elapsed_time_delta,
-- cpu_time_delta, buffer_gets_delta, disk_reads_delta, executions_delta.
-- Plus two change rankings over the same read: per-exec regression and
-- "Biggest change" (Current total elapsed minus the prior-window mean).
-- The "Values: Total | Per execution | Top per execution" switch (mode values
-- total, perexec, pe-rank) of the Elapsed / CPU / Buffer gets / Physical reads
-- tabs has two parts that must not be mixed up:
--   * perexec = a client-side SWAP inside the Total view: the same statements,
--     row order and ranks (the window TOTAL's), every shown value divided by
--     its executions (span.tsv data-pe, the "Pe" payload arrays);
--   * pe-rank = a SECOND RANKING in SQL, four more dimensions (ELAPSED_PE,
--     CPU_PE, GETS_PE, PREADS_PE: each window's top N by value per completed
--     execution), the view div.tsv-view[data-val="pe-rank"] of the tab.
-- Joins DBA_HIST_SQLTEXT for a short text snippet.  Read-only: no scratch
-- table.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 06_top_sql BEGIN -->'); END;
/

DECLARE
    v_weeks_back NUMBER := ~weeks_back;
    v_top_n      NUMBER := ~top_n;
    -- Any window count: nothing below is a SQL LISTAGG (4000 bytes, ORA-01489
    -- past about 200 windows); the header and the detail rows (about 45 /
    -- 80 bytes a window) are streamed through wg_buf, one cell at a time;
    -- the per-statement window values arrive one row per window (v_wv / v_wr
    -- / v_wp, key = week_offset).
    v_header     VARCHAR2(32767);
    v_row        VARCHAR2(32767);
    v_cell       VARCHAR2(1200);   -- a value cell with its per-execution span and badges
    v_buf        VARCHAR2(32767);
    v_weeks_json VARCHAR2(32767);
    v_weeks_iso_json VARCHAR2(32767);
    v_cur_dim    VARCHAR2(10);
    v_val        NUMBER;
    v_val_s      VARCHAR2(64);
    v_rnk_s      VARCHAR2(64);
    v_phv_s      VARCHAR2(64);
    v_chart_vals VARCHAR2(32767);
    v_new_entry  VARCHAR2(32767);
    TYPE t_tok_tab IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
    v_wv         t_tok_tab;     -- the statement's value token per window
    v_wr         t_tok_tab;     -- its rank per window
    v_wp         t_tok_tab;     -- its plan_hash_value per window
    -- Values: Total | Per execution | Top per execution (the Elapsed, CPU,
    -- Buffer gets and Physical reads tabs).  Each of the four tabs carries two
    -- rankings, the window TOTAL (ELAPSED ...) and the value per completed
    -- execution (ELAPSED_PE, CPU_PE, GETS_PE, PREADS_PE), each a view of the
    -- one tabpanel.  The collections below are keyed by dimension,
    -- VARCHAR2(10) (the longest code, ELAPSED_PE, fills it exactly), and the
    -- group ones by 'DIM|schema' in VARCHAR2(20) (ELAPSED_PE|schema = 17).
    -- Two booleans, never to be confused:
    --   v_is_rank  = the dimension is one of the four *_PE rankings (the
    --                "Top per execution" view);
    --   v_swap_dim = the dimension is one of the four TOTAL metric dims
    --                (ELAPSED / CPU / GETS / PREADS) whose cells carry the
    --                "Per execution" swap (span.tsv, the "Pe" payload).  It is
    --                FALSE for every *_PE dimension, CHANGE, EXEC and PEREXEC.
    v_base       VARCHAR2(10);  -- the tab's own code: ELAPSED_PE -> ELAPSED
    v_is_rank    BOOLEAN;
    v_swap_dim   BOOLEAN;
    -- The swap: the statement's (or group's) executions per window, key =
    -- week_offset, NULL = AWR kept no row.  The ranking, the row order and the
    -- rank badges stay those of the window TOTAL; only the shown value is
    -- divided (client side) and the chart reads the parallel "Pe" arrays.
    TYPE t_nump_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_wexe       t_nump_tab;
    v_chart_swap VARCHAR2(32767);   -- the per-execution twin of v_chart_vals
    v_new_swap   VARCHAR2(32767);   -- its payload element: [v,v,...]
    v_keep       BOOLEAN;

    -- "Compared windows" table of every opened Per-SQL row: what AWR kept for
    -- the statement in each compared window, taken from the main cursor's
    -- agg join (valid windows only, so a missing key = AWR kept no row, or
    -- the window was skipped).  Key = sql_id, a bar, week_offset.  Filled
    -- in the cursor loop before its CONTINUE: no second DBA_HIST_SQLSTAT read.
    TYPE t_wa_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(60);
    v_wa_exec    t_wa_tab;      -- executions in the window
    v_wa_ela     t_wa_tab;      -- elapsed microseconds in the window
    v_wa_phv     t_wa_tab;      -- plan_hash_value (last snapshot of the window)
    -- plan 044, the same rows' time split and work (same key): CPU and the
    -- four wait timers in microseconds, rows processed, gets, disk reads
    v_wa_cpu     t_wa_tab;
    v_wa_io      t_wa_tab;
    v_wa_cc      t_wa_tab;
    v_wa_ap      t_wa_tab;
    v_wa_cl      t_wa_tab;
    v_wa_rows    t_wa_tab;
    v_wa_gets    t_wa_tab;
    v_wa_rds     t_wa_tab;
    -- skip reason per skipped window (key = week_offset), from windows_rollup
    TYPE t_wskip_tab IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
    v_wskip      t_wskip_tab;

    -- Hard cap for the per-dimension JSON accumulators below. PL/SQL
    -- VARCHAR2 maxes out at 32767 bytes; the per-dim emit at the end of
    -- this section concatenates the accumulator with a short prefix/suffix
    -- ("sqls":[ ... ], / "schemas":[ ... ]}) so we leave headroom for that.
    -- Busy DBs with many parsing schemas in top-N can otherwise overflow
    -- the slot or the emit, raising ORA-06502 at the PUT_LINE call.
    c_json_cap   CONSTANT PLS_INTEGER := 32500;
    -- the mask that reads a window token back: 9 decimals (the per-execution
    -- tokens carry 9, the totals 6; a longer mask reads a shorter number)
    c_tok_fmt    CONSTANT VARCHAR2(40) := 'FM99999999999999990D000000000';

    TYPE t_sqlid_tab IS TABLE OF BOOLEAN INDEX BY VARCHAR2(30);
    v_seen_sqls t_sqlid_tab;
    v_flip_sqls t_sqlid_tab;
    v_plan_flip BOOLEAN;
    -- Oracle-maintained ("system") flag per sql_id, populated in the detail
    -- loop from each SQL's parsing schema and reused when emitting the
    -- per-SQL detail <details> blocks below. Drives the data-sys="Y|N"
    -- markers (informational since v1.5.0; the "Application only" filter is gone).
    v_sys_sqls  t_sqlid_tab;
    v_is_sys    VARCHAR2(1);

    -- C1: SQL pool table support. v_sql_dim_seen/top3 key = sql_id||'|'||dim
    -- (dim restricted to the five ranking dims E/C/G/R/X and the four
    -- per-execution ones behind the P chip, not CHANGE / PEREXEC) and
    -- record whether the SQL ever made that dim's top-N pool, and whether
    -- it is in that dim's current-window top-3 ("chip on"). v_sql_elapsed_cur
    -- is the current-window elapsed value (or NULL), used only to order the
    -- pool table (current-window elapsed desc) and pick the first 8 rows.
    TYPE t_flag_tab IS TABLE OF VARCHAR2(1) INDEX BY VARCHAR2(40);
    v_sql_dim_seen  t_flag_tab;
    v_sql_dim_top3  t_flag_tab;
    TYPE t_num_tab  IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
    v_sql_elapsed_cur t_num_tab;

    -- Per-dimension JSON payloads accumulated while we render the detail
    -- tables; emitted once at the end as AWR_DATA.topSql.dims so each
    -- dimension can drive its own line-chart of metric value across windows.
    -- Parallel breakdowns the browser toggles between: one series per top-N
    -- SQL_ID, plus three group-by views (parsing_schema_name / module /
    -- action) each carrying one series per top-N group value.
    TYPE t_dim_str  IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(10);
    TYPE t_dim_meta IS TABLE OF VARCHAR2(80)    INDEX BY VARCHAR2(10);
    TYPE t_dim_num  IS TABLE OF NUMBER          INDEX BY VARCHAR2(10);
    v_dim_sqls_json    t_dim_str;
    v_dim_label        t_dim_meta;
    v_dim_unit         t_dim_meta;
    -- The swap's twins (only the four total metric dims have an entry): the
    -- per-execution unit word, and the parallel arrays of the SQL_ID series
    -- (the three group views are v_grp_swap below).  Element i of an array is
    -- entry i of the series array it twins, because both are appended under
    -- ONE keep decision.
    v_dim_unit_swap    t_dim_meta;
    v_dim_sqls_swap    t_dim_str;
    -- Per-dim "kept vs total" counters that drive the truncation footnote
    -- shown above each dim's chart. kept is bumped only when an entry was
    -- actually appended to the accumulator; total is bumped on every row
    -- the cursor returns, so kept < total <=> the c_json_cap kicked in.
    v_dim_sqls_kept     t_dim_num;
    v_dim_sqls_total    t_dim_num;
    -- Group-by accumulators, keyed by dim||'|'||grp_type (e.g. 'ELAPSED|module')
    -- so one set of arrays covers all three group views (schema/module/action).
    -- Same kept/total truncation bookkeeping as the SQL_ID accumulators above.
    TYPE t_grp_str IS TABLE OF VARCHAR2(32767) INDEX BY VARCHAR2(20);
    TYPE t_grp_num IS TABLE OF NUMBER          INDEX BY VARCHAR2(20);
    v_grp_json   t_grp_str;
    v_grp_swap   t_grp_str;
    v_grp_kept   t_grp_num;
    v_grp_total  t_grp_num;
    v_gkey       VARCHAR2(20);
    v_dim              VARCHAR2(10);
    v_first_dim        BOOLEAN;
    -- v1.6.0 Timeline: the SQL lane's rows (the first six statements of
    -- the elapsed ranking), collected in the ELAPSED pass below
    TYPE t_tl_rows IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    v_tl               t_tl_rows;
    v_tl_n             PLS_INTEGER := 0;
    v_tl_csv           VARCHAR2(32767);
    v_tl_mu            NUMBER;
    v_tl_first         NUMBER;
    -- one Y / N per compared window, character k + 1 = week_offset k
    -- (windows_rollup): tl_first never calls a row "new" after a skipped one
    v_tl_valid         VARCHAR2(32767) := RPAD('N', ~weeks_back + 1, 'N');
    v_tl_note          VARCHAR2(400);
    v_tl_gw            NUMBER;
    v_tl_gl            VARCHAR2(400);
    v_ls               VARCHAR2(2000);    -- the evidence library's row text
    v_news             VARCHAR2(40);      -- plan 040: the statement that row text is about
    v_panel_on         BOOLEAN := FALSE;  -- the first emitted tabpanel is the open one
    v_chg_seen         BOOLEAN := FALSE;  -- the CHANGE dimension had rows

    @@sql/lib/is_oracle_schema.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/band_glyph.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
    @@sql/lib/timeline.plsql

    -- Per execution.  pe_val: a value divided by its executions, NULL when
    -- none completed (a long-running statement can have elapsed time and 0
    -- executions in a window: a division by zero would raise ORA-01476 and end
    -- the report, and "0 per execution" would be a lie).  pe_json: a
    -- per-execution number for the chart payload with about 4 significant
    -- digits and trailing zeros trimmed ('null' for NULL; a per-execution time
    -- of a few microseconds needs more than the 6 fixed decimals of the
    -- totals).  tsv_span: the number of a value cell of a TOTAL table in a
    -- span that carries the per-execution text in data-pe (and a title text in
    -- data-pt: p_full 'Y' = the full-precision value like the Current cell's
    -- title, a NULL value = why there is none); the script swaps the text and
    -- the title and restores them, so the cell keeps its badges and every row,
    -- id and total in the markup is the one it always was.
    FUNCTION pe_val(p_v NUMBER, p_x NUMBER) RETURN NUMBER IS
    BEGIN
        IF p_v IS NULL OR p_x IS NULL OR p_x <= 0 THEN
            RETURN NULL;
        END IF;
        RETURN p_v / p_x;
    END pe_val;

    FUNCTION pe_json(p_v NUMBER) RETURN VARCHAR2 IS
        v_a NUMBER;
    BEGIN
        IF p_v IS NULL THEN
            RETURN 'null';
        END IF;
        v_a := LEAST(ABS(p_v), 99999999999);
        IF v_a = 0 THEN
            RETURN '0';
        END IF;
        RETURN CASE WHEN p_v < 0 THEN '-' END
            || RTRIM(TO_CHAR(ROUND(v_a, GREATEST(0, LEAST(9, 3 - FLOOR(LOG(10, v_a))))),
                             'FM99999999990D999999999',
                             'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END pe_json;

    FUNCTION tsv_span(p_txt VARCHAR2, p_pe NUMBER, p_full VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<span class="tsv" data-pe="' || fmt_num(p_pe) || '"'
            || CASE WHEN p_pe IS NULL
                    THEN ' data-pt="no completed execution in this window"'
                    WHEN p_full = 'Y'
                    THEN REPLACE(fmt_num_title(p_pe), ' title="', ' data-pt="')
               END
            || '>' || p_txt || '</span>';
    END tsv_span;

    -- The "Values: Total | Per execution | Top per execution" switch of the
    -- panel of dimension p_dim.  Every one of the seven panels carries it (same
    -- markup, one shared state, see the script after the section's heading);
    -- CSS shows it only when that script ran.  Its own data attribute and no
    -- data-mode: the chart script's "Break down by" handler binds through
    -- data-topsql-target / data-mode and must never see these buttons.  The
    -- button values are the mode values: total, perexec (the swap inside the
    -- Total view), pe-rank (the separate ranking).
    FUNCTION tsv_switch(p_dim VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="topsql-toggle topsql-val" data-tsv="' || p_dim
            || '" role="group" aria-label="Values: total, per execution, or top per execution">'
            || '<span>Values:</span>'
            || '<button type="button" data-val="total" class="active" aria-pressed="true"'
            || ' title="Each window''s top statements by the window total">Total</button>'
            || '<button type="button" data-val="perexec" aria-pressed="false"'
            || ' title="The same statements and order as Total, each value divided by the statement''s executions">Per execution</button>'
            || '<button type="button" data-val="pe-rank" aria-pressed="false"'
            || ' title="A different statement set: each window''s top statements by value per completed execution">Top per execution</button>'
            || '</div>';
    END tsv_switch;

    -- What a tab with no per-execution form of its own says in the other modes
    -- (a one-line note, shown by CSS: tsv-n-other in per execution and top per
    -- execution mode, tsv-n-total in total mode only).
    FUNCTION tsv_note(p_dim VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_dim
            WHEN 'CHANGE' THEN
                '<p class="tsv-note tsv-n-other">Biggest change compares total elapsed time, whatever the switch says.'
                || ' Its per-execution counterpart is the <button type="button" class="tsv-go" data-tsv-goto="PEREXEC">'
                || 'Per-exec regression</button> tab.</p>'
            WHEN 'EXEC' THEN
                '<p class="tsv-note tsv-n-other">Executions is a count, so it has no per-execution form:'
                || ' this tab reads the same in every mode.</p>'
            WHEN 'PEREXEC' THEN
                '<p class="tsv-note tsv-n-total">Per-exec regression always ranks the change in elapsed time per execution,'
                || ' whatever the switch says. Its total counterpart is the <button type="button" class="tsv-go"'
                || ' data-tsv-goto="CHANGE">Biggest change</button> tab.</p>'
        END;
    END tsv_note;

    -- The "Top per execution" view of a tab whose ranking has no row at all
    -- (no statement completed an execution with a non-zero value in any
    -- window): its heading and a note, so the panel stays complete.
    FUNCTION tsv_empty_view(p_base VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<div class="tsv-view" data-val="pe-rank"><h3>' || v_dim_label(p_base)
            || ' per execution</h3><p class="note">No statement completed an execution with a'
            || ' non-zero value in any compared window, so there is no per-execution ranking.</p></div>';
    END tsv_empty_view;

    -- Closes what the dimension v_cur_dim has open: its table and details
    -- block, its view (or, for Biggest change / Executions / Per-exec
    -- regression, its panel).  The total ranking of one of the four metric
    -- tabs is followed by its per-execution ranking when that has rows
    -- (p_next = ELAPSED_PE ...), else by the empty "Top per execution" view;
    -- that view ends the panel.  p_next NULL = no dimension follows.  Right
    -- after a total view the swap is applied to that table (the state
    -- script's AWR_topsqlSync(table): a saved "perexec" must not paint the
    -- totals first).
    PROCEDURE tsv_close(p_next VARCHAR2) IS
    BEGIN
        IF v_cur_dim IS NULL THEN
            RETURN;
        END IF;
        DBMS_OUTPUT.PUT_LINE('</tbody></table></details></div>');
        IF v_cur_dim IN ('ELAPSED', 'CPU', 'GETS', 'PREADS') THEN
            DBMS_OUTPUT.PUT_LINE('<script>if(window.AWR_topsqlSync)AWR_topsqlSync(document.getElementById("topsql-detail-'
                || v_cur_dim || '"));</script>');
            IF p_next IS NULL OR p_next <> v_cur_dim || '_PE' THEN
                DBMS_OUTPUT.PUT_LINE(tsv_empty_view(v_cur_dim) || '</div>');
            END IF;
        ELSIF SUBSTR(v_cur_dim, -3) = '_PE' THEN
            DBMS_OUTPUT.PUT_LINE('</div>');
        END IF;
    END tsv_close;
BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="topsql" class="vw in-s in-a lib lopen" style="--os:1"><h2>Top SQL'
        || '<small class="h2sub">Top ' || v_top_n
        || ' statements per ranking and window; ranked, not scored</small></h2>');

    -- Values: Total | Per execution | Top per execution.  The ONE shared state
    -- of the switches of all seven panels, set BEFORE the panels are parsed
    -- (so the page never paints the other view first): `mode`, one of
    --   total    each window's top N by the window total, as ever;
    --   perexec  the SAME statements, row order and ranks (the Total view),
    --            every value of its tables and charts divided by its
    --            executions: a client-side swap of the cell text (span.tsv
    --            data-pe / data-pt, the th data-pe), the rank badges stay;
    --   pe-rank  the separate ranking: each window's top N by value per
    --            completed execution (the tsv-view[data-val=pe-rank] of the
    --            tab, ELAPSED_PE ... in SQL).
    -- Read from localStorage awr-topsql-val (anything else = Total) and written
    -- there on an explicit click only; the classes on #topsql do all the
    -- showing and hiding in CSS (tsv-js = this script ran: the switches show
    -- and the pe-rank views hide, tsv-pe = mode perexec, tsv-rank = mode
    -- pe-rank).  Without JavaScript no class is set: no switch, no notes, the
    -- cells show the totals, both views stacked.  Not inside the chart script:
    -- the switch and the swap work with the chart library missing.
    -- AWR_topsqlVal() = the mode, AWR_topsqlSync(table) = paint the switch
    -- buttons and, in mode perexec, swap that table (called after each switch
    -- and after each Total table, once parsed), AWR_topsqlReveal(el) = the
    -- chrome's reveal() hook: show the view that holds el only when the mode
    -- hides it, never saved.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){ /* Top SQL: Values switch (Total | Per execution | Top per execution) */');
    DBMS_OUTPUT.PUT_LINE('var KEY="awr-topsql-val",root=document.getElementById("topsql");');
    DBMS_OUTPUT.PUT_LINE('if(!root) return;');
    DBMS_OUTPUT.PUT_LINE('var mode="total";');
    DBMS_OUTPUT.PUT_LINE('try{ var sv=window.localStorage.getItem(KEY); if(sv==="perexec"||sv==="pe-rank") mode=sv; }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('root.classList.add("tsv-js"); root.classList.toggle("tsv-pe",mode==="perexec"); root.classList.toggle("tsv-rank",mode==="pe-rank");');
    DBMS_OUTPUT.PUT_LINE('function each(l,f){ Array.prototype.forEach.call(l,f); }');
    -- one number or header: the text from data-pe, the cell's title from
    -- data-pt (the td keeps its own title in data-pot while swapped)
    DBMS_OUTPUT.PUT_LINE('function swap(el,on){');
    DBMS_OUTPUT.PUT_LINE('  var pe=el.getAttribute("data-pe"); if(pe===null) return;');
    DBMS_OUTPUT.PUT_LINE('  var pt=el.getAttribute("data-pt"), td=el.tagName==="SPAN"?el.closest("td"):null;');
    DBMS_OUTPUT.PUT_LINE('  if(on){');
    DBMS_OUTPUT.PUT_LINE('    if(!el.hasAttribute("data-po")) el.setAttribute("data-po",el.textContent);');
    DBMS_OUTPUT.PUT_LINE('    el.textContent=pe;');
    DBMS_OUTPUT.PUT_LINE('    if(td&&pt!==null){');
    DBMS_OUTPUT.PUT_LINE('      if(!td.hasAttribute("data-ptm")){ td.setAttribute("data-ptm","1"); if(td.hasAttribute("title")) td.setAttribute("data-pot",td.getAttribute("title")); }');
    DBMS_OUTPUT.PUT_LINE('      td.setAttribute("title",pt);');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  } else {');
    DBMS_OUTPUT.PUT_LINE('    if(el.hasAttribute("data-po")){ el.textContent=el.getAttribute("data-po"); el.removeAttribute("data-po"); }');
    DBMS_OUTPUT.PUT_LINE('    if(td&&td.hasAttribute("data-ptm")){');
    DBMS_OUTPUT.PUT_LINE('      if(td.hasAttribute("data-pot")){ td.setAttribute("title",td.getAttribute("data-pot")); td.removeAttribute("data-pot"); } else td.removeAttribute("title");');
    DBMS_OUTPUT.PUT_LINE('      td.removeAttribute("data-ptm");');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function swapIn(scope,on){ each(scope.querySelectorAll("table.tsv-tbl [data-pe]"),function(el){ swap(el,on); }); }');
    DBMS_OUTPUT.PUT_LINE('function sync(scope){');
    DBMS_OUTPUT.PUT_LINE('  each(root.querySelectorAll("div[data-tsv] button[data-val]"),function(b){');
    DBMS_OUTPUT.PUT_LINE('    var a=b.getAttribute("data-val")===mode; b.classList.toggle("active",a); b.setAttribute("aria-pressed",a?"true":"false");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(scope&&mode==="perexec") swapIn(scope,true);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function set(m,save){');
    DBMS_OUTPUT.PUT_LINE('  if(m!=="total"&&m!=="perexec"&&m!=="pe-rank") return;');
    DBMS_OUTPUT.PUT_LINE('  var was=mode, ch=m!==mode; mode=m;');
    DBMS_OUTPUT.PUT_LINE('  root.classList.toggle("tsv-pe",m==="perexec"); root.classList.toggle("tsv-rank",m==="pe-rank");');
    DBMS_OUTPUT.PUT_LINE('  if(ch&&(m==="perexec"||was==="perexec")) swapIn(root,m==="perexec");');
    DBMS_OUTPUT.PUT_LINE('  sync();');
    DBMS_OUTPUT.PUT_LINE('  if(save){ try{ window.localStorage.setItem(KEY,m); }catch(e){} }');
    DBMS_OUTPUT.PUT_LINE('  if(!ch) return;');
    DBMS_OUTPUT.PUT_LINE('  if(window.AWR_fitTables) setTimeout(window.AWR_fitTables,50);');
    DBMS_OUTPUT.PUT_LINE('  try{ document.dispatchEvent(new CustomEvent("awr:topsqlval",{detail:{mode:m}})); }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_topsqlVal=function(){ return mode; };');
    DBMS_OUTPUT.PUT_LINE('window.AWR_topsqlSync=sync;');
    -- a Total row shows in total and perexec mode, a pe-rank row in pe-rank
    -- mode only: switch (unsaved) only when the mode hides the target's view
    DBMS_OUTPUT.PUT_LINE('window.AWR_topsqlReveal=function(el){');
    DBMS_OUTPUT.PUT_LINE('  var v=el&&el.closest?el.closest("#topsql .tsv-view"):null; if(!v) return;');
    DBMS_OUTPUT.PUT_LINE('  var rk=v.getAttribute("data-val")==="pe-rank";');
    DBMS_OUTPUT.PUT_LINE('  if(rk&&mode!=="pe-rank") set("pe-rank",false);');
    DBMS_OUTPUT.PUT_LINE('  else if(!rk&&mode==="pe-rank") set("total",false);');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('root.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target; if(!t||!t.closest) return;');
    DBMS_OUTPUT.PUT_LINE('  var b=t.closest("div[data-tsv] button[data-val]");');
    DBMS_OUTPUT.PUT_LINE('  if(b){ set(b.getAttribute("data-val"),true); return; }');
    DBMS_OUTPUT.PUT_LINE('  var g=t.closest("button[data-tsv-goto]");');
    DBMS_OUTPUT.PUT_LINE('  if(g){ var tab=document.getElementById("tab-topsql-"+g.getAttribute("data-tsv-goto")); if(tab) tab.click(); }');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- C1: one tab group for the seven per-dimension blocks below (each
    -- wrapped in a matching .tabpanel as its <h3> is emitted). Dim codes
    -- and order are hardcoded here to match the `dims` CTE inside the
    -- cursor below -- they are static, not derived per-DB.
    DBMS_OUTPUT.PUT_LINE('<div class="tabs" data-tabs="topsql" role="tablist" aria-label="Top SQL ranking dimension">'
        || '<button type="button" role="tab" aria-selected="true" class="on" data-t="CHANGE" id="tab-topsql-CHANGE"'
        || ' title="Current window total elapsed minus the prior-window mean">Biggest change</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="ELAPSED" id="tab-topsql-ELAPSED">Elapsed time</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="CPU" id="tab-topsql-CPU">CPU time</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="GETS" id="tab-topsql-GETS">Buffer gets</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PREADS" id="tab-topsql-PREADS">Physical reads</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="EXEC" id="tab-topsql-EXEC">Executions</button>'
        || '<button type="button" role="tab" aria-selected="false" tabindex="-1" data-t="PEREXEC" id="tab-topsql-PEREXEC">Per-exec regression</button>'
        || '</div>');

    -- The windows' chart labels, oldest first (week_offset DESC), and the
    -- parallel full-ISO timestamps fed to AWR_markLine as the time source so
    -- user markers snap to the nearest window even though the visible x-axis
    -- labels are the compact period_axis_fmt form.  Built in this loop, not
    -- a LISTAGG: about 20 bytes a window passed SQL's 4000 near 200 windows.
    FOR r IN (
        SELECT TO_CHAR(
                   CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
                   - (~step_hours/24)*week_offset, '~period_axis_fmt', 'NLS_DATE_LANGUAGE=ENGLISH') AS lab,
               TO_CHAR(
                   CAST(TO_TIMESTAMP('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') AS DATE)
                   - (~step_hours/24)*week_offset, 'YYYY-MM-DD HH24:MI') AS iso
        FROM   (SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1)
        ORDER BY week_offset DESC
    ) LOOP
        v_weeks_json     := v_weeks_json || CASE WHEN v_weeks_json IS NOT NULL THEN ',' END
                         || '"' || r.lab || '"';
        v_weeks_iso_json := v_weeks_iso_json || CASE WHEN v_weeks_iso_json IS NOT NULL THEN ',' END
                         || '"' || r.iso || '"';
    END LOOP;
    v_weeks_json     := '[' || v_weeks_json || ']';
    v_weeks_iso_json := '[' || v_weeks_iso_json || ']';


    -- Window validity for the Timeline's "first seen" glyph (tl_first).
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag, skip_reason FROM windows_rollup
    ) LOOP
        IF r.valid_flag = 'Y' AND r.week_offset BETWEEN 0 AND ~weeks_back THEN
            v_tl_valid := SUBSTR(v_tl_valid, 1, r.week_offset) || 'Y'
                       || SUBSTR(v_tl_valid, r.week_offset + 2);
        ELSIF r.week_offset BETWEEN 0 AND ~weeks_back THEN
            v_wskip(r.week_offset) := NVL(SUBSTR(r.skip_reason, 1, 200), 'no valid snapshot pair');
        END IF;
    END LOOP;

    -- Per-dimension detail tables, packed into one big cursor. ------------
    v_cur_dim := NULL;
    FOR s IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        agg AS (
            SELECT w.week_offset, s.sql_id,
                   MAX(s.plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS plan_hash_value,
                   MAX(s.parsing_schema_name) KEEP (DENSE_RANK LAST ORDER BY s.snap_id) AS parsing_schema,
                   SUM(NVL(s.executions_delta, 0))     AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0))   AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0))       AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0))    AS buffer_gets_delta,
                   SUM(NVL(s.disk_reads_delta, 0))     AS disk_reads_delta,
                   -- plan 044, the Per-SQL detail's "where the time went":
                   -- the wait timers of the same rows (microseconds) and the
                   -- rows processed; read by the final SELECT only
                   SUM(NVL(s.iowait_delta, 0))         AS iowait_us,
                   SUM(NVL(s.ccwait_delta, 0))         AS ccwait_us,
                   SUM(NVL(s.apwait_delta, 0))         AS apwait_us,
                   SUM(NVL(s.clwait_delta, 0))         AS clwait_us,
                   SUM(NVL(s.rows_processed_delta, 0)) AS rows_proc
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
            GROUP BY w.week_offset, s.sql_id
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY elapsed_time_delta_us DESC, sql_id) AS r_ela,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY cpu_time_delta_us DESC, sql_id)     AS r_cpu,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY buffer_gets_delta DESC, sql_id)     AS r_gets,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY disk_reads_delta DESC, sql_id)      AS r_preads,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY executions_delta DESC, sql_id)      AS r_exec
            FROM   agg a
        ),
        --
        -- Per execution (the Values: Total | Per execution switch of the
        -- Elapsed, CPU, Buffer gets and Physical reads tabs): per window, each
        -- statement's value over its COMPLETED executions, ranked.  A
        -- statement with elapsed time and no completed execution has nothing
        -- to divide by (NULL, never 0 and never a division by zero): Oracle
        -- sorts NULL first under DESC, so NULLS LAST keeps such rows behind
        -- every real value, and picked below also asks for a value above 0.
        -- The ranks of the rows kept therefore run 1, 2, 3 without a gap.
        -- Same agg as every other dimension: no extra DBA_HIST_SQLSTAT read.
        --
        ranked_pe AS (
            SELECT p.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY ela_pe DESC NULLS LAST, sql_id)    AS r_ela_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY cpu_pe DESC NULLS LAST, sql_id)    AS r_cpu_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY gets_pe DESC NULLS LAST, sql_id)   AS r_gets_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset
                                      ORDER BY reads_pe DESC NULLS LAST, sql_id)  AS r_reads_pe
            FROM (
                SELECT week_offset, sql_id, plan_hash_value,
                       CASE WHEN executions_delta > 0
                            THEN elapsed_time_delta_us / executions_delta END AS ela_pe,
                       CASE WHEN executions_delta > 0
                            THEN cpu_time_delta_us / executions_delta END     AS cpu_pe,
                       CASE WHEN executions_delta > 0
                            THEN buffer_gets_delta / executions_delta END     AS gets_pe,
                       CASE WHEN executions_delta > 0
                            THEN disk_reads_delta / executions_delta END      AS reads_pe
                FROM   agg
            ) p
        ),
        --
        -- Per-execution elapsed time per (window, sql_id), in microseconds.
        -- NULL when the SQL had no executions in that window so the bump
        -- chart renders the missing point as a gap (connectNulls:false).
        --
        per_exec AS (
            SELECT week_offset, sql_id, plan_hash_value, executions_delta,
                   CASE WHEN executions_delta > 0
                        THEN elapsed_time_delta_us / executions_delta
                   END AS per_exec_us
            FROM   agg
        ),
        --
        -- Delta elapsed-per-exec ranking: single global ROW_NUMBER (NOT
        -- partitioned by window) over the regression delta. Catches
        -- "got slower per call" -- invisible to total-elapsed rankings
        -- when execution count drops.
        --
        -- Filters:
        --   * cur_pe and prior_pe both non-NULL (need a baseline to compare)
        --   * cur_pe > prior_pe (only regressions; improvements drop out)
        --   * cur_execs >= 3 (cuts noise from one-off slow parses)
        --
        delta_ranked AS (
            SELECT sql_id, cur_pe, prior_pe, n_prior_pe,
                   cur_pe - prior_pe AS delta_pe,
                   ROW_NUMBER() OVER (ORDER BY (cur_pe - prior_pe) DESC NULLS LAST,
                                               sql_id) AS r_delta
            FROM (
                SELECT sql_id,
                       MAX(CASE WHEN week_offset = 0 THEN per_exec_us       END) AS cur_pe,
                       AVG(CASE WHEN week_offset > 0 THEN per_exec_us       END) AS prior_pe,
                       COUNT(CASE WHEN week_offset > 0 AND per_exec_us IS NOT NULL
                                  THEN 1 END)                                     AS n_prior_pe,
                       MAX(CASE WHEN week_offset = 0 THEN executions_delta  END) AS cur_execs
                FROM   per_exec
                GROUP BY sql_id
            )
            WHERE cur_pe   IS NOT NULL
              AND prior_pe IS NOT NULL
              AND n_prior_pe >= 1
              AND cur_pe   > prior_pe
              AND cur_execs >= 3
        ),
        --
        -- Biggest change: the Current window's total elapsed minus the mean
        -- over the prior VALID windows (a valid window in which AWR kept no
        -- row for the statement counts as 0; a skipped window is not a
        -- window here at all).  Regressions only.  Same agg as every other
        -- dimension: no extra DBA_HIST_SQLSTAT read.
        --
        n_prior_valid AS (
            SELECT COUNT(DISTINCT week_offset) AS n
            FROM   valid_windows
            WHERE  week_offset > 0
        ),
        -- n_prior_rows: the prior valid windows that HAVE a row for the
        -- statement (agg is valid windows only, one row per window): 0 =
        -- "new"; rows with 0 s elapsed are a zero baseline, not new
        chg_ranked AS (
            SELECT sql_id, cur_ela, prior_mean, n_prior_rows,
                   ROW_NUMBER() OVER (ORDER BY cur_ela - prior_mean DESC, sql_id) AS r_chg
            FROM (
                SELECT a.sql_id,
                       SUM(CASE WHEN a.week_offset = 0 THEN a.elapsed_time_delta_us END) AS cur_ela,
                       NVL(SUM(CASE WHEN a.week_offset > 0 THEN a.elapsed_time_delta_us END), 0)
                           / NULLIF((SELECT n FROM n_prior_valid), 0) AS prior_mean,
                       COUNT(CASE WHEN a.week_offset > 0 THEN 1 END) AS n_prior_rows
                FROM   agg a
                GROUP BY a.sql_id
            )
            WHERE  cur_ela > prior_mean
        ),
        picked AS (
            SELECT 'ELAPSED' AS dim, week_offset, sql_id, plan_hash_value,
                   elapsed_time_delta_us AS metric_value, r_ela AS rnk
            FROM ranked WHERE r_ela <= (SELECT top_n FROM run_params) AND elapsed_time_delta_us > 0
            UNION ALL
            SELECT 'CPU', week_offset, sql_id, plan_hash_value,
                   cpu_time_delta_us, r_cpu
            FROM ranked WHERE r_cpu <= (SELECT top_n FROM run_params) AND cpu_time_delta_us > 0
            UNION ALL
            SELECT 'GETS', week_offset, sql_id, plan_hash_value,
                   buffer_gets_delta, r_gets
            FROM ranked WHERE r_gets <= (SELECT top_n FROM run_params) AND buffer_gets_delta > 0
            UNION ALL
            SELECT 'PREADS', week_offset, sql_id, plan_hash_value,
                   disk_reads_delta, r_preads
            FROM ranked WHERE r_preads <= (SELECT top_n FROM run_params) AND disk_reads_delta > 0
            UNION ALL
            SELECT 'EXEC', week_offset, sql_id, plan_hash_value,
                   executions_delta, r_exec
            FROM ranked WHERE r_exec <= (SELECT top_n FROM run_params) AND executions_delta > 0
            UNION ALL
            -- the four per-execution rankings (value / completed executions,
            -- microseconds or counts per execution): own top N per window
            SELECT 'ELAPSED_PE', week_offset, sql_id, plan_hash_value,
                   ela_pe, r_ela_pe
            FROM ranked_pe WHERE r_ela_pe <= (SELECT top_n FROM run_params) AND ela_pe > 0
            UNION ALL
            SELECT 'CPU_PE', week_offset, sql_id, plan_hash_value,
                   cpu_pe, r_cpu_pe
            FROM ranked_pe WHERE r_cpu_pe <= (SELECT top_n FROM run_params) AND cpu_pe > 0
            UNION ALL
            SELECT 'GETS_PE', week_offset, sql_id, plan_hash_value,
                   gets_pe, r_gets_pe
            FROM ranked_pe WHERE r_gets_pe <= (SELECT top_n FROM run_params) AND gets_pe > 0
            UNION ALL
            SELECT 'PREADS_PE', week_offset, sql_id, plan_hash_value,
                   reads_pe, r_reads_pe
            FROM ranked_pe WHERE r_reads_pe <= (SELECT top_n FROM run_params) AND reads_pe > 0
            UNION ALL
            -- PEREXEC: per-window rows for the top-N most regressed SQLs.
            -- rnk is set only at week_offset = 0 (the ranking is global,
            -- not per-window; surfacing the same rank in every prior cell
            -- would clutter the detail table). per_exec_us in microseconds
            -- so it can share the dim_div=1e6 conversion path.
            SELECT 'PEREXEC' AS dim, pe.week_offset, pe.sql_id, pe.plan_hash_value,
                   pe.per_exec_us AS metric_value,
                   CASE WHEN pe.week_offset = 0 THEN dr.r_delta END AS rnk
            FROM   per_exec pe
            JOIN   delta_ranked dr ON dr.sql_id = pe.sql_id
            WHERE  dr.r_delta <= (SELECT top_n FROM run_params)
              AND  pe.per_exec_us IS NOT NULL
            UNION ALL
            -- CHANGE: per-window total elapsed for the top-N statements by
            -- the change above, rnk only at week_offset 0 (like PEREXEC)
            SELECT 'CHANGE' AS dim, a.week_offset, a.sql_id, a.plan_hash_value,
                   a.elapsed_time_delta_us AS metric_value,
                   CASE WHEN a.week_offset = 0 THEN cr.r_chg END AS rnk
            FROM   agg a
            JOIN   chg_ranked cr ON cr.sql_id = a.sql_id
            WHERE  cr.r_chg <= (SELECT top_n FROM run_params)
        ),
        dims AS (
            SELECT 'ELAPSED' code, 1 ord, 'By elapsed time'         label, 's'      unit, 1e6 divs FROM dual UNION ALL
            SELECT 'ELAPSED_PE', 1.5, 'By elapsed time per execution',     's/exec',     1e6      FROM dual UNION ALL
            SELECT 'CPU',      2,     'By CPU time',                       's',          1e6      FROM dual UNION ALL
            SELECT 'CPU_PE',   2.5,   'By CPU time per execution',         's/exec',     1e6      FROM dual UNION ALL
            SELECT 'GETS',     3,     'By buffer gets',                    'gets',       1        FROM dual UNION ALL
            SELECT 'GETS_PE',  3.5,   'By buffer gets per execution',      'gets/exec',  1        FROM dual UNION ALL
            SELECT 'PREADS',   4,     'By physical reads',                 'reads',      1        FROM dual UNION ALL
            SELECT 'PREADS_PE', 4.5,  'By physical reads per execution',   'reads/exec', 1        FROM dual UNION ALL
            SELECT 'EXEC',     5,     'By executions',                     'exec',       1        FROM dual UNION ALL
            SELECT 'PEREXEC',  6,     'By per-exec regression',            's/exec',     1e6      FROM dual UNION ALL
            SELECT 'CHANGE',   0,     'By change in elapsed time (Current vs the prior mean)', 's', 1e6 FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        sqls AS (
            SELECT DISTINCT dim, sql_id FROM picked
        ),
        grid AS (
            SELECT q.dim, q.sql_id, w.week_offset,
                   p.metric_value, p.rnk, p.plan_hash_value
            FROM   sqls q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.sql_id = q.sql_id AND p.week_offset = w.week_offset
        ),
        per_sql AS (
            -- one row per (dim, statement, window), every window (grid);
            -- the statement's own values ride on each of its rows.  No
            -- per-window LISTAGG CSV: it passed SQL's 4000 bytes (ORA-01489,
            -- the run aborted) once a statement had values in about 200
            -- windows, and Biggest change has a value in every window the
            -- statement ran in.  The loop collects the windows instead.
            SELECT dim, sql_id, week_offset, metric_value, rnk, plan_hash_value,
                   MAX(CASE WHEN week_offset = 0 THEN metric_value END)
                       OVER (PARTITION BY dim, sql_id)                      AS cur_val,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)
                       OVER (PARTITION BY dim, sql_id)                      AS cur_rnk,
                   MAX(CASE WHEN week_offset = 0 THEN plan_hash_value END)
                       OVER (PARTITION BY dim, sql_id)                      AS cur_phv,
                   MIN(rnk)          OVER (PARTITION BY dim, sql_id)        AS best_rank,
                   MAX(metric_value) OVER (PARTITION BY dim, sql_id)        AS best_value
            FROM   grid
        ),
        text_snips AS (
            SELECT sql_id, sql_text_short FROM (
                SELECT sql_id,
                       DBMS_LOB.SUBSTR(sql_text, 401, 1) AS sql_text_short,
                       -- ORDER BY NULL, not ROWID: DBA_HIST_SQLTEXT is a join
                       -- view in a PDB and selecting ROWID raises ORA-01445.
                       -- PARTITION BY sql_id only (NOT dbid): when dbid_list
                       -- spans a migration the same sql_id can exist under both
                       -- DBIDs with identical text; collapsing on sql_id keeps
                       -- one row so the join to the per-SQL rows stays 1:1.
                       ROW_NUMBER() OVER (PARTITION BY sql_id ORDER BY NULL) AS rn
                FROM   dba_hist_sqltext
                WHERE  dbid IN (~dbid_list)
            ) WHERE rn = 1
        ),
        -- One parsing schema per sql_id (current window wins on ties) so each
        -- top SQL can be tagged Oracle-maintained vs application for the
        -- "Application only" filter. Derived from agg (already window-scoped)
        -- so it adds no extra DBA_HIST_SQLSTAT scan.
        sql_sys AS (
            SELECT sql_id,
                   MAX(parsing_schema) KEEP (DENSE_RANK LAST ORDER BY week_offset DESC)
                       AS parsing_schema
            FROM   agg
            GROUP BY sql_id
        )
        SELECT d.code AS dim, d.ord AS dim_ord, d.label AS dim_label,
               d.unit AS dim_unit, d.divs AS dim_div,
               ps.sql_id, ps.cur_val, ps.cur_rnk, ps.cur_phv,
               ps.week_offset,
               -- the per-execution rankings carry 9 decimals (a value per
               -- execution is not a whole number), the totals 6 as ever
               TO_CHAR(ps.metric_value,
                       CASE WHEN SUBSTR(d.code, -3) = '_PE'
                            THEN 'FM99999999999999990D000000000'
                            ELSE 'FM99999999999999990D000000' END,
                       'NLS_NUMERIC_CHARACTERS=''.,''')    AS week_val,
               TO_CHAR(ps.rnk)                            AS week_rnk,
               TO_CHAR(ps.plan_hash_value)                AS week_phv,
               -- read on the statement's last window only (the loop renders
               -- it there): no 400-character text on every window row
               CASE WHEN ps.week_offset = v_weeks_back THEN ts.sql_text_short END AS sql_text_short,
               ss.parsing_schema,
               ch.prior_mean AS chg_mu_us,
               ch.n_prior_rows AS chg_n_prior,
               -- what AWR kept for this statement in this window (agg: valid
               -- windows only, one row per window): all NULL = no row.  Feeds
               -- the Compared windows table of the Per-SQL detail.
               ag.executions_delta     AS agg_exec,
               ag.elapsed_time_delta_us AS agg_ela_us,
               ag.plan_hash_value      AS agg_phv,
               -- plan 044: the rest of the same agg row
               ag.cpu_time_delta_us    AS agg_cpu_us,
               ag.iowait_us            AS agg_io_us,
               ag.ccwait_us            AS agg_cc_us,
               ag.apwait_us            AS agg_ap_us,
               ag.clwait_us            AS agg_cl_us,
               ag.rows_proc            AS agg_rows,
               ag.buffer_gets_delta    AS agg_gets,
               ag.disk_reads_delta     AS agg_reads
        FROM   dims d
        JOIN   per_sql ps ON ps.dim = d.code
        LEFT JOIN text_snips ts ON ts.sql_id = ps.sql_id
        LEFT JOIN sql_sys   ss ON ss.sql_id = ps.sql_id
        LEFT JOIN chg_ranked ch ON d.code = 'CHANGE' AND ch.sql_id = ps.sql_id
        LEFT JOIN agg ag ON ag.sql_id = ps.sql_id AND ag.week_offset = ps.week_offset
        ORDER BY d.ord,
            CASE WHEN ps.cur_rnk IS NULL THEN 1 ELSE 0 END,
            ps.cur_rnk NULLS LAST,
            ps.best_rank,
            ps.best_value DESC,
            ps.sql_id,
            ps.week_offset
    ) LOOP
        -- A statement's windows arrive together, week_offset 0 .. N: keep
        -- each window's tokens and render the statement on its last one
        -- (every key 0 .. N is set again for each statement: grid has them all).
        v_wv(s.week_offset) := s.week_val;
        v_wr(s.week_offset) := s.week_rnk;
        v_wp(s.week_offset) := s.week_phv;
        -- its executions in this window (the swap's divisor; NULL = no row)
        v_wexe(s.week_offset) := s.agg_exec;
        -- the statement's row of this window in the AWR data (agg), once per
        -- statement and window whatever the dimension: executions_delta is
        -- never NULL on an agg row, so a NULL means no row
        IF s.agg_exec IS NOT NULL THEN
            v_wa_exec(s.sql_id || '|' || s.week_offset) := s.agg_exec;
            v_wa_ela(s.sql_id || '|' || s.week_offset)  := s.agg_ela_us;
            v_wa_phv(s.sql_id || '|' || s.week_offset)  := s.agg_phv;
            -- plan 044: where the time went (same row, no further read)
            v_wa_cpu(s.sql_id || '|' || s.week_offset)  := s.agg_cpu_us;
            v_wa_io(s.sql_id || '|' || s.week_offset)   := s.agg_io_us;
            v_wa_cc(s.sql_id || '|' || s.week_offset)   := s.agg_cc_us;
            v_wa_ap(s.sql_id || '|' || s.week_offset)   := s.agg_ap_us;
            v_wa_cl(s.sql_id || '|' || s.week_offset)   := s.agg_cl_us;
            v_wa_rows(s.sql_id || '|' || s.week_offset) := s.agg_rows;
            v_wa_gets(s.sql_id || '|' || s.week_offset) := s.agg_gets;
            v_wa_rds(s.sql_id || '|' || s.week_offset)  := s.agg_reads;
        END IF;
        CONTINUE WHEN s.week_offset < v_weeks_back;

        IF v_cur_dim IS NULL OR v_cur_dim <> s.dim THEN
            -- the previous dimension's table, view and, when nothing else
            -- follows in its tab, the tabpanel (see tsv_close)
            tsv_close(s.dim);
            v_base    := REPLACE(s.dim, '_PE');
            v_is_rank := s.dim <> v_base;
            -- only the four TOTAL metric dims carry the swap (never a *_PE
            -- dimension, CHANGE, EXEC or PEREXEC)
            v_swap_dim := s.dim IN ('ELAPSED', 'CPU', 'GETS', 'PREADS');
            v_cur_dim := s.dim;
            v_dim_label(s.dim)         := s.dim_label;
            v_dim_unit(s.dim)          := s.dim_unit;
            v_dim_sqls_json(s.dim)     := NULL;
            v_dim_sqls_kept(s.dim)     := 0;
            v_dim_sqls_total(s.dim)    := 0;
            IF v_swap_dim THEN
                v_dim_unit_swap(s.dim) := CASE WHEN s.dim IN ('ELAPSED', 'CPU') THEN 's/exec'
                                               WHEN s.dim = 'GETS' THEN 'gets/exec'
                                               ELSE 'reads/exec' END;
                v_dim_sqls_swap(s.dim) := NULL;
            END IF;

            IF NOT v_is_rank THEN
                -- C1: open this dim's tabpanel (first one starts visible).
                DBMS_OUTPUT.PUT_LINE('<div class="tabpanel'
                    || CASE WHEN NOT v_panel_on THEN ' on' ELSE '' END
                    || '" data-tabs="topsql" data-t="' || s.dim || '" role="tabpanel"'
                    || ' aria-labelledby="tab-topsql-' || s.dim || '">');
                v_panel_on := TRUE;
                IF s.dim = 'CHANGE' THEN v_chg_seen := TRUE; END IF;
                -- Values: Total | Per execution | Top per execution, in every
                -- panel (CSS shows it once the script after the heading ran);
                -- the script after the switch paints its buttons for the saved
                -- mode.  The four metric tabs then open their Total view (the
                -- pre-switch markup of the panel, heading to detail table);
                -- the other three say what they show in the other modes.
                DBMS_OUTPUT.PUT_LINE(tsv_switch(s.dim));
                DBMS_OUTPUT.PUT_LINE('<script>if(window.AWR_topsqlSync)AWR_topsqlSync();</script>');
                IF v_swap_dim THEN
                    DBMS_OUTPUT.PUT_LINE('<div class="tsv-view" data-val="total">');
                ELSE
                    DBMS_OUTPUT.PUT_LINE(tsv_note(s.dim));
                END IF;
            ELSE
                -- the "Top per execution" view of the panel the total ranking
                -- opened just above: a per-execution row implies a total row
                -- (a value above 0 needs a total above 0, and the window's
                -- top total statement has one), so that panel is always open
                DBMS_OUTPUT.PUT_LINE('<div class="tsv-view" data-val="pe-rank">');
            END IF;
            DBMS_OUTPUT.PUT_LINE('<h3>' || s.dim_label || '</h3>');
            IF v_is_rank THEN
                DBMS_OUTPUT.PUT_LINE('<p class="tsv-rank-note">Top per execution: a different statement set from the'
                    || ' Total view. Each window''s top ' || v_top_n
                    || ' statements by value per completed execution (the window''s value divided by its'
                    || ' executions), ranked on their own. A statement with no completed execution in a window is'
                    || ' not ranked in it; a dash means it is not in that window''s top ' || v_top_n || '.</p>');
            ELSIF v_swap_dim THEN
                -- shown by CSS in mode perexec only (the swap)
                DBMS_OUTPUT.PUT_LINE('<p class="tsv-swap-note">Per execution: the same statements, still picked and'
                    || ' ordered by the window total (the #n badges are ranks by total). Each value is that'
                    || ' window''s total divided by its executions; a dash is a window where the statement is not'
                    || ' in the top ' || v_top_n || ' or completed no execution.</p>');
            END IF;
            DBMS_OUTPUT.PUT_LINE('<div class="topsql-toggle" data-topsql-target="' || s.dim || '">'
                || '<span>Break down by:</span>'
                || '<button type="button" data-mode="sqls" class="active">SQL ID</button>'
                || '<button type="button" data-mode="schemas">Schema</button>'
                || '<button type="button" data-mode="modules">Module</button>'
                || '<button type="button" data-mode="actions">Action</button>'
                || '</div>');
            DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" id="topsql-chart-'
                || s.dim || '"></div>');

            DBMS_OUTPUT.PUT_LINE('<details>');
            DBMS_OUTPUT.PUT_LINE('<summary>Detail table</summary>');

            -- one th (about 45 bytes) per window, through wg_buf
            v_header := '<table id="topsql-detail-' || v_cur_dim || '"'
                -- a "Top per execution" table is a second view of its tab:
                -- its plan badges stay out of the section-header counts (the
                -- pool rows of its statements still count there); a total
                -- metric table carries the swap (class tsv-tbl)
                || CASE WHEN v_is_rank THEN ' data-nocount'
                        WHEN v_swap_dim THEN ' class="tsv-tbl"' END || '>'
                || '<thead><tr><th>SQL ID</th><th class="num" title="plan_hash_value of the Current window&#39;s execution plan">Plan hash (Current)</th>'
                || '<th class="num" data-w="0"'
                || CASE WHEN v_swap_dim THEN ' data-pe="Current (' || v_dim_unit_swap(s.dim) || ')"' END
                || '>Current (' || s.dim_unit || ')</th>';
            FOR k IN 1 .. v_weeks_back LOOP
                wg_buf(v_header, '<th class="num" data-w="' || k || '">&minus;'
                    || off_label(k) || '</th>');
            END LOOP;
            wg_buf(v_header, '<th>SQL</th></tr></thead><tbody>');
            DBMS_OUTPUT.PUT_LINE(v_header);
        END IF;

        v_seen_sqls(s.sql_id) := TRUE;

        -- C1: chip tracking for the SQL pool table (E/C/G/R/X dims, and the
        -- four per-execution rankings behind the one P chip) plus the
        -- current-window elapsed value used to order that table.
        IF s.dim IN ('ELAPSED', 'CPU', 'GETS', 'PREADS', 'EXEC',
                     'ELAPSED_PE', 'CPU_PE', 'GETS_PE', 'PREADS_PE') THEN
            v_sql_dim_seen(s.sql_id || '|' || s.dim) := 'Y';
            IF s.cur_rnk IS NOT NULL AND s.cur_rnk <= 3 THEN
                v_sql_dim_top3(s.sql_id || '|' || s.dim) := 'Y';
            END IF;
        END IF;
        IF s.dim = 'ELAPSED' THEN
            v_sql_elapsed_cur(s.sql_id) := NVL(s.cur_val, 0);
        END IF;

        -- Oracle-maintained vs application: tag this SQL by its parsing
        -- schema so the row, its chart series, and its per-SQL detail block
        -- below can all be hidden together when the "Application only"
        -- toggle is on. Remembered per sql_id for the detail loop.
        v_is_sys := is_oracle_schema(s.parsing_schema);
        v_sys_sqls(s.sql_id) := (v_is_sys = 'Y');

        -- Plan-change detection for this row: scan prior-week PHVs (keys
        -- 1..N of v_wp; key 0 is the current window) and flag
        -- the SQL when any non-null prior PHV differs from s.cur_phv. The
        -- per-cell plan-up badge below uses the same comparison; this loop
        -- gives us a single boolean for the SQL_ID column badge and feeds
        -- the cross-dim rollup paragraph emitted after the bump charts.
        v_plan_flip := FALSE;
        IF s.cur_phv IS NOT NULL THEN
            FOR k IN 1 .. v_weeks_back LOOP
                v_phv_s := v_wp(k);
                IF v_phv_s IS NOT NULL
                   AND TO_NUMBER(v_phv_s) <> s.cur_phv THEN
                    v_plan_flip := TRUE;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        IF v_plan_flip THEN
            v_flip_sqls(s.sql_id) := TRUE;
        END IF;

        -- Build oldest->newest values array for this SQL (chart series).
        -- v_wv is keyed by week_offset (0 = current, N = oldest). Iterate in
        -- reverse so the chart x-axis (which is oldest-first) lines up.
        v_chart_vals := '';
        v_chart_swap := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := v_wv(k - 1);
            IF v_chart_vals IS NOT NULL AND LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap || ',';
                END IF;
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap || 'null';
                END IF;
            ELSE
                v_val := TO_NUMBER(v_val_s, c_tok_fmt,
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                -- a "Top per execution" value keeps about 4 significant
                -- digits (a few microseconds per call is not 0.000002 s to 6
                -- places); the totals keep 6 decimals as ever
                v_chart_vals := v_chart_vals
                    || CASE WHEN v_is_rank THEN pe_json(v_val/s.dim_div)
                            ELSE TO_CHAR(v_val/s.dim_div, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END;
                -- the swap's twin of the entry: the same value over the
                -- statement's executions in that window ('null' when none
                -- completed)
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap
                        || pe_json(pe_val(v_val/s.dim_div, v_wexe(k - 1)));
                END IF;
            END IF;
        END LOOP;
        v_new_entry := '{"sql_id":"' || s.sql_id
            || '","cur":' || NVL(TO_CHAR(s.cur_rnk), 'null')
            || ',"sys":' || CASE WHEN v_is_sys = 'Y' THEN 'true' ELSE 'false' END
            || ',"vals":[' || v_chart_vals || ']}';
        v_new_swap := CASE WHEN v_swap_dim THEN '[' || v_chart_swap || ']' END;
        v_dim_sqls_total(s.dim) := v_dim_sqls_total(s.dim) + 1;
        -- one keep decision for the entry and its per-execution twin, so
        -- element i of "sqlsPe" is entry i of "sqls"
        IF v_dim_sqls_json(s.dim) IS NULL THEN
            v_keep := TRUE;
        ELSE
            v_keep := LENGTH(v_dim_sqls_json(s.dim)) + LENGTH(v_new_entry) + 1
                      <= c_json_cap;
            IF v_keep AND v_swap_dim THEN
                v_keep := LENGTH(v_dim_sqls_swap(s.dim)) + LENGTH(v_new_swap) + 1
                          <= c_json_cap;
            END IF;
        END IF;
        IF v_keep THEN
            IF v_dim_sqls_json(s.dim) IS NULL THEN
                v_dim_sqls_json(s.dim) := v_new_entry;
                IF v_swap_dim THEN
                    v_dim_sqls_swap(s.dim) := v_new_swap;
                END IF;
            ELSE
                v_dim_sqls_json(s.dim) :=
                    v_dim_sqls_json(s.dim) || ',' || v_new_entry;
                IF v_swap_dim THEN
                    v_dim_sqls_swap(s.dim) := v_dim_sqls_swap(s.dim) || ',' || v_new_swap;
                END IF;
            END IF;
            v_dim_sqls_kept(s.dim) := v_dim_sqls_kept(s.dim) + 1;
        END IF;

        -- SQL_ID links to its detail block in the Per-SQL detail section
        -- below (the chrome's goTo opens it via AWR_openSqlRow).  v1.6.0:
        -- the row itself is the entity anchor sq-<dim>-<sql_id>
        -- (sql/lib/anchor_id.plsql); sq-elapsed-<sql_id> is what a link to
        -- a statement targets.
        -- the kind drops the underscore of the per-execution dimensions
        -- (sq-elapsedpe-<sql_id>): a prefix match on sq-elapsed- never
        -- reaches a per-execution row
        v_row := '<tr id="' || anchor_id('sq-' || LOWER(REPLACE(s.dim, '_')), s.sql_id)
            || '" data-sys="' || v_is_sys || '">'
            || '<td class="mono"><a href="#sql-' || s.sql_id || '">'
            || s.sql_id || '</a>'
            || CASE WHEN v_plan_flip
                    THEN ' <span class="badge warn" title="Plan changed between current and a prior compared window">plan&#8593;</span>'
                    ELSE '' END
            || '</td>'
            || '<td class="num mono">' ||
                CASE WHEN s.cur_phv IS NULL THEN '&mdash;'
                     ELSE TO_CHAR(s.cur_phv) END
            || '</td>'
            || '<td class="num" data-w="0"' || fmt_num_title(s.cur_val/s.dim_div) || '><b>'
                || CASE WHEN v_swap_dim AND s.cur_val IS NOT NULL
                        THEN tsv_span(fmt_num(s.cur_val/s.dim_div),
                                      pe_val(s.cur_val/s.dim_div, v_wexe(0)), 'Y')
                        ELSE fmt_num(s.cur_val/s.dim_div) END
            || CASE WHEN s.cur_rnk IS NOT NULL
                    THEN ' <span class="badge info">#' || s.cur_rnk || '</span>' ELSE '' END
            || '</b>'
            || CASE WHEN s.dim = 'CHANGE' THEN ' '
                    || CASE WHEN NVL(s.chg_n_prior, 0) = 0
                            THEN '<span class="d s-plain" title="no row in any prior valid window">new</span>'
                            WHEN NVL(s.chg_mu_us, 0) = 0
                            THEN '<span class="d s-plain" title="0 s elapsed in every prior valid window">from 0</span>'
                            ELSE delta_span(s.cur_val, s.chg_mu_us, NULL, 'Y') END END
            || '</td>';

        -- the prior windows' cells, one at a time through wg_buf (about 80
        -- bytes a cell, up to 170 with a plan badge): a row of many windows
        -- spans several output lines, the usual 13 stay on one
        FOR k IN 1 .. v_weeks_back LOOP
            v_val_s := v_wv(k);
            v_rnk_s := v_wr(k);
            v_phv_s := v_wp(k);
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_cell := '<td class="num" data-w="' || k || '">&mdash;';
            ELSE
                v_val := TO_NUMBER(v_val_s, c_tok_fmt,
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_cell := '<td class="num" data-w="' || k || '">'
                      || CASE WHEN v_swap_dim
                              THEN tsv_span(fmt_num(v_val/s.dim_div),
                                            pe_val(v_val/s.dim_div, v_wexe(k)), 'N')
                              ELSE fmt_num(v_val/s.dim_div) END;
            END IF;
            IF v_rnk_s IS NOT NULL THEN
                v_cell := v_cell || ' <span class="badge skip">#' || v_rnk_s || '</span>';
            END IF;
            IF v_phv_s IS NOT NULL AND s.cur_phv IS NOT NULL
               AND TO_NUMBER(v_phv_s) <> s.cur_phv THEN
                v_cell := v_cell || ' <span class="badge warn" title="Plan changed. Prior PHV '
                      || v_phv_s || '">plan&#8593;</span>';
            END IF;
            wg_buf(v_row, v_cell || '</td>');
        END LOOP;

        wg_buf(v_row, '<td class="mono sqltext">'
            || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(s.sql_text_short, ''), 1, 400))
            || CASE WHEN LENGTH(NVL(s.sql_text_short, '')) > 400 THEN '&hellip;' END
            || '</td></tr>');
        DBMS_OUTPUT.PUT_LINE(v_row);

        -- v1.6.0 Timeline: this statement's row in the SQL lane (ranked,
        -- not scored: a plain ratio vs the mean of the prior windows it made
        -- the top list in; a plan change puts a diamond on Current, a first
        -- appearance after the oldest window a cross on that window).
        IF s.dim = 'ELAPSED' AND v_tl_n < 6 THEN
            v_tl_n     := v_tl_n + 1;
            v_tl_csv   := tl_csv(v_chart_vals);
            v_tl_mu    := tl_mu(v_tl_csv);
            v_tl_first := tl_first(v_tl_csv, v_tl_valid);
            v_tl_gw    := NULL;
            v_tl_gl    := NULL;
            v_tl_note  := CASE WHEN s.cur_rnk IS NOT NULL THEN '#' || s.cur_rnk || ' by elapsed'
                              ELSE 'not in the Current top ' || v_top_n END;
            IF v_plan_flip THEN
                v_tl_gw   := 0;
                v_tl_gl   := '<b class="glf gp" title="Plan changed: the Current plan_hash_value '
                    || s.cur_phv || ' differs from a prior window''s">&#9670;</b>';
                v_tl_note := '<b>&#9670;</b> new plan';
            ELSIF v_tl_first IS NOT NULL THEN
                v_tl_gw   := v_tl_first;
                v_tl_gl   := '<b class="glf gn" title="First seen in the top ' || v_top_n || ': '
                    || wg_title(v_tl_first) || '">&#10010;</b>';
                v_tl_note := '<b>&#10010;</b> new ' || CASE WHEN v_tl_first = 0 THEN 'in Current'
                                                           ELSE wg_date(v_tl_first) END;
            END IF;
            -- the library row text: the Current top statement by elapsed
            IF v_tl_n = 1 THEN
                IF s.cur_rnk IS NOT NULL THEN v_news := 'sql:' || s.sql_id; END IF;
                v_ls := CASE WHEN s.cur_rnk IS NULL
                             THEN 'no statement in the Current top ' || v_top_n
                             ELSE '<code>' || s.sql_id || '</code> #' || s.cur_rnk || ' by elapsed'
                                  || CASE WHEN v_tl_mu IS NOT NULL
                                          THEN ', ' || delta_span(tl_val(v_tl_csv, 0), v_tl_mu, NULL, 'Y') END
                                  || CASE WHEN v_plan_flip THEN ', new plan'
                                          WHEN v_tl_first IS NOT NULL
                                          THEN ', new ' || CASE WHEN v_tl_first = 0 THEN 'in Current'
                                                                ELSE wg_date(v_tl_first) END END END;
            END IF;
            v_tl(v_tl_n) := tl_bars(v_tl_csv, v_tl_mu, NULL, NULL,
                tl_lab(ent(s.sql_id, anchor_id('sq-elapsed', s.sql_id), 'sql'),
                       DBMS_XMLGEN.CONVERT(NVL(s.parsing_schema, '?')) || ' <span class="sq">'
                       || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(s.sql_text_short, ''), 1, 90)) || '</span>',
                       DBMS_XMLGEN.CONVERT(SUBSTR(NVL(s.sql_text_short, ''), 1, 300))),
                tl_gutp(tl_val(v_tl_csv, 0), v_tl_mu, v_tl_note),
                'tl-' || anchor_id('sq-elapsed', s.sql_id), 'q', s.sql_id, 's elapsed',
                v_tl_gw, v_tl_gl);
        END IF;
    END LOOP;

    -- the last dimension's table, view and panel
    tsv_close(NULL);
    IF NOT v_chg_seen THEN
        -- no statement got slower (or no prior valid window): drop the
        -- empty tab (removed, not hidden: the chrome's Home / arrow keys
        -- and a shared #...!tab=CHANGE link click every [data-t] of the
        -- bar) and select the tab of the panel that is open
        DBMS_OUTPUT.PUT_LINE('<script>(function(){var c=document.getElementById("tab-topsql-CHANGE"),'
            || 'p=document.querySelector(".tabpanel.on[data-tabs=topsql]");if(!c)return;c.parentNode.removeChild(c);'
            || 'if(!p)return;var b=document.getElementById("tab-topsql-"+p.getAttribute("data-t"));'
            || 'if(b){b.classList.add("on");b.setAttribute("aria-selected","true");b.removeAttribute("tabindex");}})();</script>');
    END IF;
    -- a note's link to a tab (or a panel) this report does not have is plain
    -- text: Biggest change is dropped above when nothing got slower, and a
    -- ranking with no row has a tab and no panel
    IF v_panel_on THEN
        DBMS_OUTPUT.PUT_LINE('<script>(function(){ /* Top SQL: notes link only to tabs that exist */');
        DBMS_OUTPUT.PUT_LINE('var r=document.getElementById("topsql"); if(!r) return;');
        DBMS_OUTPUT.PUT_LINE('Array.prototype.forEach.call(r.querySelectorAll("button[data-tsv-goto]"),function(g){');
        DBMS_OUTPUT.PUT_LINE('  var k=g.getAttribute("data-tsv-goto");');
        DBMS_OUTPUT.PUT_LINE('  if(document.getElementById("tab-topsql-"+k)&&r.querySelector(".tabpanel[data-t=\""+k+"\"]")) return;');
        DBMS_OUTPUT.PUT_LINE('  var t=document.createElement("span"); t.textContent=g.textContent; g.parentNode.replaceChild(t,g);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
    END IF;
    FOR i IN 1 .. v_tl_n LOOP
        DBMS_OUTPUT.PUT_LINE(CASE WHEN i = 1 THEN tl_open('sql') END || v_tl(i)
            || CASE WHEN i = v_tl_n THEN tl_close END);
    END LOOP;

    -- Second pass: per-group breakdowns for the chart toggle (schema /
    -- module / action). Uses the same valid_windows + DBA_HIST_SQLSTAT scan,
    -- grouped by parsing_schema_name / module / action instead of sql_id.
    -- One SQLSTAT scan feeds a MATERIALIZE-d (schema,module,action) base that
    -- is rolled up three ways tagged with a grp_type discriminator, so the
    -- ranking machinery (top-N per window) runs once across all three views.
    -- Top-N group values per (dimension, grp_type) are picked the same way
    -- as SQL_IDs (best rank across windows). No detail table -- chart only.
    FOR sc IN (
        WITH
        @@sql/lib/windows_cte.sql
        ,
        base AS (
            SELECT /*+ MATERIALIZE */ w.week_offset,
                   NVL(s.parsing_schema_name, '(unknown)') AS schema_name,
                   NVL(s.module, '(none)')                 AS module_name,
                   NVL(s.action, '(none)')                 AS action_name,
                   SUM(NVL(s.executions_delta, 0))   AS executions_delta,
                   SUM(NVL(s.elapsed_time_delta, 0)) AS elapsed_time_delta_us,
                   SUM(NVL(s.cpu_time_delta, 0))     AS cpu_time_delta_us,
                   SUM(NVL(s.buffer_gets_delta, 0))  AS buffer_gets_delta,
                   SUM(NVL(s.disk_reads_delta, 0))   AS disk_reads_delta
            FROM   valid_windows w
            JOIN   dba_hist_sqlstat s
                ON s.dbid = w.dbid
               AND s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
               AND s.instance_number = w.instance_number
            GROUP BY w.week_offset,
                     NVL(s.parsing_schema_name, '(unknown)'),
                     NVL(s.module, '(none)'),
                     NVL(s.action, '(none)')
        ),
        -- Roll the shared base up three ways. grp_type is CAST to VARCHAR2 so
        -- the UNION's CHAR-literal blank-padding trap can't pad the shorter
        -- 'schema'/'module'/'action' tokens to a fixed CHAR width and break
        -- the grp_type tests / 'dim|grp_type' keying downstream (the same
        -- trap section 11's ash_raw documents).
        agg AS (
            SELECT week_offset, CAST('schema' AS VARCHAR2(8)) AS grp_type,
                   schema_name AS grp_value,
                   SUM(executions_delta)      AS executions_delta,
                   SUM(elapsed_time_delta_us) AS elapsed_time_delta_us,
                   SUM(cpu_time_delta_us)     AS cpu_time_delta_us,
                   SUM(buffer_gets_delta)     AS buffer_gets_delta,
                   SUM(disk_reads_delta)      AS disk_reads_delta
            FROM   base GROUP BY week_offset, schema_name
            UNION ALL
            SELECT week_offset, CAST('module' AS VARCHAR2(8)), module_name,
                   SUM(executions_delta), SUM(elapsed_time_delta_us),
                   SUM(cpu_time_delta_us), SUM(buffer_gets_delta), SUM(disk_reads_delta)
            FROM   base GROUP BY week_offset, module_name
            UNION ALL
            SELECT week_offset, CAST('action' AS VARCHAR2(8)), action_name,
                   SUM(executions_delta), SUM(elapsed_time_delta_us),
                   SUM(cpu_time_delta_us), SUM(buffer_gets_delta), SUM(disk_reads_delta)
            FROM   base GROUP BY week_offset, action_name
        ),
        ranked AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY elapsed_time_delta_us DESC, grp_value) AS r_ela,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY cpu_time_delta_us DESC, grp_value)     AS r_cpu,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY buffer_gets_delta DESC, grp_value)     AS r_gets,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY disk_reads_delta DESC, grp_value)      AS r_preads,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY executions_delta DESC, grp_value)      AS r_exec
            FROM   agg a
        ),
        -- Per execution (the Values: Total | Per execution switch): the
        -- group's summed value over its summed executions, ranked per
        -- window and group view; a group with no completed execution in the
        -- window has nothing to divide by and is not ranked (see ranked_pe
        -- of the statement cursor above)
        ranked_pe AS (
            SELECT p.*,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY ela_pe DESC NULLS LAST, grp_value)   AS r_ela_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY cpu_pe DESC NULLS LAST, grp_value)   AS r_cpu_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY gets_pe DESC NULLS LAST, grp_value)  AS r_gets_pe,
                   ROW_NUMBER() OVER (PARTITION BY week_offset, grp_type
                                      ORDER BY reads_pe DESC NULLS LAST, grp_value) AS r_reads_pe
            FROM (
                SELECT week_offset, grp_type, grp_value,
                       CASE WHEN executions_delta > 0
                            THEN elapsed_time_delta_us / executions_delta END AS ela_pe,
                       CASE WHEN executions_delta > 0
                            THEN cpu_time_delta_us / executions_delta END     AS cpu_pe,
                       CASE WHEN executions_delta > 0
                            THEN buffer_gets_delta / executions_delta END     AS gets_pe,
                       CASE WHEN executions_delta > 0
                            THEN disk_reads_delta / executions_delta END      AS reads_pe
                FROM   agg
            ) p
        ),
        -- execs: the group's summed executions in the window, carried along
        -- for the swap of the four TOTAL dims (per execution = the group's
        -- summed metric / its summed executions; the ranking stays the
        -- total's).  The four *_PE branches have no use for it (NULL: they
        -- are not swapped, their value already is per execution).
        picked AS (
            SELECT 'ELAPSED' AS dim, week_offset, grp_type, grp_value,
                   elapsed_time_delta_us AS metric_value, r_ela AS rnk,
                   executions_delta AS execs
            FROM ranked WHERE r_ela <= (SELECT top_n FROM run_params) AND elapsed_time_delta_us > 0
            UNION ALL
            SELECT 'CPU', week_offset, grp_type, grp_value, cpu_time_delta_us, r_cpu,
                   executions_delta
            FROM ranked WHERE r_cpu <= (SELECT top_n FROM run_params) AND cpu_time_delta_us > 0
            UNION ALL
            SELECT 'GETS', week_offset, grp_type, grp_value, buffer_gets_delta, r_gets,
                   executions_delta
            FROM ranked WHERE r_gets <= (SELECT top_n FROM run_params) AND buffer_gets_delta > 0
            UNION ALL
            SELECT 'PREADS', week_offset, grp_type, grp_value, disk_reads_delta, r_preads,
                   executions_delta
            FROM ranked WHERE r_preads <= (SELECT top_n FROM run_params) AND disk_reads_delta > 0
            UNION ALL
            SELECT 'EXEC', week_offset, grp_type, grp_value, executions_delta, r_exec,
                   executions_delta
            FROM ranked WHERE r_exec <= (SELECT top_n FROM run_params) AND executions_delta > 0
            UNION ALL
            SELECT 'ELAPSED_PE', week_offset, grp_type, grp_value, ela_pe, r_ela_pe,
                   CAST(NULL AS NUMBER)
            FROM ranked_pe WHERE r_ela_pe <= (SELECT top_n FROM run_params) AND ela_pe > 0
            UNION ALL
            SELECT 'CPU_PE', week_offset, grp_type, grp_value, cpu_pe, r_cpu_pe,
                   CAST(NULL AS NUMBER)
            FROM ranked_pe WHERE r_cpu_pe <= (SELECT top_n FROM run_params) AND cpu_pe > 0
            UNION ALL
            SELECT 'GETS_PE', week_offset, grp_type, grp_value, gets_pe, r_gets_pe,
                   CAST(NULL AS NUMBER)
            FROM ranked_pe WHERE r_gets_pe <= (SELECT top_n FROM run_params) AND gets_pe > 0
            UNION ALL
            SELECT 'PREADS_PE', week_offset, grp_type, grp_value, reads_pe, r_reads_pe,
                   CAST(NULL AS NUMBER)
            FROM ranked_pe WHERE r_reads_pe <= (SELECT top_n FROM run_params) AND reads_pe > 0
        ),
        dims AS (
            SELECT 'ELAPSED' code, 1 ord, 1e6 divs FROM dual UNION ALL
            SELECT 'ELAPSED_PE', 1.5,     1e6      FROM dual UNION ALL
            SELECT 'CPU',      2,     1e6      FROM dual UNION ALL
            SELECT 'CPU_PE',   2.5,   1e6      FROM dual UNION ALL
            SELECT 'GETS',     3,     1        FROM dual UNION ALL
            SELECT 'GETS_PE',  3.5,   1        FROM dual UNION ALL
            SELECT 'PREADS',   4,     1        FROM dual UNION ALL
            SELECT 'PREADS_PE', 4.5,  1        FROM dual UNION ALL
            SELECT 'EXEC',     5,     1        FROM dual
        ),
        all_weeks AS (
            SELECT LEVEL - 1 AS week_offset FROM dual CONNECT BY LEVEL <= ~weeks_back + 1
        ),
        groups AS (
            SELECT DISTINCT dim, grp_type, grp_value FROM picked
        ),
        grid AS (
            SELECT q.dim, q.grp_type, q.grp_value, w.week_offset, p.metric_value, p.rnk,
                   p.execs
            FROM   groups q CROSS JOIN all_weeks w
            LEFT JOIN picked p
                   ON p.dim = q.dim AND p.grp_type = q.grp_type
                  AND p.grp_value = q.grp_value AND p.week_offset = w.week_offset
        ),
        -- one row per (dim, group, window), like per_sql above (no
        -- per-window LISTAGG: any window count)
        per_group AS (
            SELECT dim, grp_type, grp_value, week_offset, metric_value, execs,
                   MAX(CASE WHEN week_offset = 0 THEN rnk END)
                       OVER (PARTITION BY dim, grp_type, grp_value)   AS cur_rnk,
                   MIN(rnk)          OVER (PARTITION BY dim, grp_type, grp_value) AS best_rank,
                   MAX(metric_value) OVER (PARTITION BY dim, grp_type, grp_value) AS best_value
            FROM   grid
        )
        SELECT d.code AS dim, d.divs AS dim_div, ps.grp_type, ps.grp_value,
               ps.cur_rnk, ps.week_offset,
               TO_CHAR(ps.metric_value,
                       CASE WHEN SUBSTR(d.code, -3) = '_PE'
                            THEN 'FM99999999999999990D000000000'
                            ELSE 'FM99999999999999990D000000' END,
                       'NLS_NUMERIC_CHARACTERS=''.,''') AS week_val,
               ps.execs AS week_exec
        FROM   dims d
        JOIN   per_group ps ON ps.dim = d.code
        ORDER BY d.ord, ps.grp_type,
            CASE WHEN ps.cur_rnk IS NULL THEN 1 ELSE 0 END,
            ps.cur_rnk NULLS LAST,
            ps.best_rank,
            ps.best_value DESC,
            ps.grp_value,
            ps.week_offset
    ) LOOP
        -- a group's windows arrive together (week_offset 0 .. N), as above
        v_wv(sc.week_offset) := sc.week_val;
        v_wexe(sc.week_offset) := sc.week_exec;
        CONTINUE WHEN sc.week_offset < v_weeks_back;
        v_is_rank  := SUBSTR(sc.dim, -3) = '_PE';
        v_swap_dim := sc.dim IN ('ELAPSED', 'CPU', 'GETS', 'PREADS');
        v_chart_vals := '';
        v_chart_swap := '';
        FOR k IN REVERSE 1 .. v_weeks_back + 1 LOOP
            v_val_s := v_wv(k - 1);
            IF LENGTH(v_chart_vals) > 0 THEN
                v_chart_vals := v_chart_vals || ',';
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap || ',';
                END IF;
            END IF;
            IF v_val_s IS NULL OR v_val_s = '' THEN
                v_chart_vals := v_chart_vals || 'null';
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap || 'null';
                END IF;
            ELSE
                v_val := TO_NUMBER(v_val_s, c_tok_fmt,
                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                v_chart_vals := v_chart_vals
                    || CASE WHEN v_is_rank THEN pe_json(v_val/sc.dim_div)
                            ELSE TO_CHAR(v_val/sc.dim_div, 'FM99999999990D000000',
                                         'NLS_NUMERIC_CHARACTERS=''.,''') END;
                -- the group's summed value over its summed executions
                IF v_swap_dim THEN
                    v_chart_swap := v_chart_swap
                        || pe_json(pe_val(v_val/sc.dim_div, v_wexe(k - 1)));
                END IF;
            END IF;
        END LOOP;
        -- module/action are app-set free text; escape backslash, quote, and
        -- stray CR/LF so the JS string literal and one-line PUT_LINE both stay
        -- well-formed (schema names are tame, but route them through the same
        -- escape for uniformity). A less-than sign becomes the JSON escape
        -- \u003c so the value can not end the script element (same rule as
        -- sql/lib/json_escape.plsql)
        v_new_entry := '{"name":"'
            || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(sc.grp_value,
                   '\', '\\'), '"', '\"'), CHR(13), ' '), CHR(10), ' '),
                   '<', '\u003c')
            || '","cur":' || NVL(TO_CHAR(sc.cur_rnk), 'null')
            -- Tag system-ness only for the schema breakdown (module/action are
            -- app-set free text, not schema-derived). Informational since
            -- v1.5.0 (the "Application only" filter is gone).
            || ',"sys":' || CASE WHEN sc.grp_type = 'schema'
                                  AND is_oracle_schema(sc.grp_value) = 'Y'
                                 THEN 'true' ELSE 'false' END
            || ',"vals":[' || v_chart_vals || ']}';
        -- Accumulate into the (dim, grp_type) bucket. Lazily initialized here:
        -- the SQL_ID loop only seeds the sqls accumulators, so the group
        -- buckets are created on first sight of each dim|grp_type pair.
        v_gkey := sc.dim || '|' || sc.grp_type;
        IF NOT v_grp_total.EXISTS(v_gkey) THEN
            v_grp_total(v_gkey) := 0;
            v_grp_kept(v_gkey)  := 0;
        END IF;
        v_grp_total(v_gkey) := v_grp_total(v_gkey) + 1;
        -- one keep decision for the entry and its per-execution twin (the
        -- parallel "...Pe" array), as for the SQL_ID series above
        v_new_swap := CASE WHEN v_swap_dim THEN '[' || v_chart_swap || ']' END;
        IF NOT v_grp_json.EXISTS(v_gkey) OR v_grp_json(v_gkey) IS NULL THEN
            v_keep := TRUE;
        ELSE
            v_keep := LENGTH(v_grp_json(v_gkey)) + LENGTH(v_new_entry) + 1
                      <= c_json_cap;
            IF v_keep AND v_swap_dim THEN
                v_keep := LENGTH(v_grp_swap(v_gkey)) + LENGTH(v_new_swap) + 1
                          <= c_json_cap;
            END IF;
        END IF;
        IF v_keep THEN
            IF NOT v_grp_json.EXISTS(v_gkey) OR v_grp_json(v_gkey) IS NULL THEN
                v_grp_json(v_gkey) := v_new_entry;
                IF v_swap_dim THEN
                    v_grp_swap(v_gkey) := v_new_swap;
                END IF;
            ELSE
                v_grp_json(v_gkey) := v_grp_json(v_gkey) || ',' || v_new_entry;
                IF v_swap_dim THEN
                    v_grp_swap(v_gkey) := v_grp_swap(v_gkey) || ',' || v_new_swap;
                END IF;
            END IF;
            v_grp_kept(v_gkey) := v_grp_kept(v_gkey) + 1;
        END IF;
    END LOOP;

    -- One ECharts line chart per dimension, plotting metric value (in the
    -- dimension's display unit) per top SQL across windows.  Skipped
    -- silently when the CDN is unreachable; tables still carry every value.
    IF v_dim_label.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<script>(function(){');
        -- the two window lists (about 15 and 19 bytes a window) through
        -- wg_buf: one line for the usual counts, split past 32000 bytes
        v_buf := 'AWR_DATA.topSql={weeks:';
        wg_buf(v_buf, v_weeks_json);
        wg_buf(v_buf, ',weeksIso:');
        wg_buf(v_buf, v_weeks_iso_json);
        wg_buf(v_buf, ',topN:' || v_top_n || ',dims:{');
        DBMS_OUTPUT.PUT_LINE(v_buf);
        v_first_dim := TRUE;
        v_dim := v_dim_label.FIRST;
        WHILE v_dim IS NOT NULL LOOP
            -- Emit each dim across several PUT_LINE calls so no single concat
            -- ever holds more than one VARCHAR2(32767) accumulator at once;
            -- their slots can otherwise sum past PL/SQL's 32767-byte
            -- expression limit and raise ORA-06502. The newlines the splits
            -- inject sit inside a JS object literal and are ignored by the
            -- parser. Group counts come from v_grp_kept/v_grp_total keyed by
            -- dim||'|'||grp_type; missing keys (a dim with no rows for that
            -- group view) read as 0.
            IF NOT v_first_dim THEN
                DBMS_OUTPUT.PUT_LINE(',');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"' || v_dim || '":{"label":"' || v_dim_label(v_dim)
                || '","unit":"' || v_dim_unit(v_dim)
                || '","sqlsKept":' || NVL(TO_CHAR(v_dim_sqls_kept(v_dim)), '0')
                || ',"sqlsTotal":' || NVL(TO_CHAR(v_dim_sqls_total(v_dim)), '0')
                || ',"schemasKept":'
                    || CASE WHEN v_grp_kept.EXISTS(v_dim || '|schema')
                            THEN TO_CHAR(v_grp_kept(v_dim || '|schema')) ELSE '0' END
                || ',"schemasTotal":'
                    || CASE WHEN v_grp_total.EXISTS(v_dim || '|schema')
                            THEN TO_CHAR(v_grp_total(v_dim || '|schema')) ELSE '0' END
                || ',"modulesKept":'
                    || CASE WHEN v_grp_kept.EXISTS(v_dim || '|module')
                            THEN TO_CHAR(v_grp_kept(v_dim || '|module')) ELSE '0' END
                || ',"modulesTotal":'
                    || CASE WHEN v_grp_total.EXISTS(v_dim || '|module')
                            THEN TO_CHAR(v_grp_total(v_dim || '|module')) ELSE '0' END
                || ',"actionsKept":'
                    || CASE WHEN v_grp_kept.EXISTS(v_dim || '|action')
                            THEN TO_CHAR(v_grp_kept(v_dim || '|action')) ELSE '0' END
                || ',"actionsTotal":'
                    || CASE WHEN v_grp_total.EXISTS(v_dim || '|action')
                            THEN TO_CHAR(v_grp_total(v_dim || '|action')) ELSE '0' END
                -- the four total metric dims name their per-execution unit
                -- (the swap): a *_PE dimension, Biggest change, Executions and
                -- Per-exec regression carry none of the "Pe" keys
                || CASE WHEN v_dim_unit_swap.EXISTS(v_dim)
                        THEN ',"unitPe":"' || v_dim_unit_swap(v_dim) || '"' END
                || ',');
            DBMS_OUTPUT.PUT_LINE(
                '"sqls":[' || NVL(v_dim_sqls_json(v_dim), '') || '],');
            -- "...Pe": the per-execution values, element i = entry i of the
            -- series array of the same name (own line: it is about as long)
            IF v_dim_unit_swap.EXISTS(v_dim) THEN
                DBMS_OUTPUT.PUT_LINE(
                    '"sqlsPe":[' || NVL(v_dim_sqls_swap(v_dim), '') || '],');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"schemas":[' ||
                    CASE WHEN v_grp_json.EXISTS(v_dim || '|schema')
                         THEN NVL(v_grp_json(v_dim || '|schema'), '') ELSE '' END
                || '],');
            IF v_dim_unit_swap.EXISTS(v_dim) THEN
                DBMS_OUTPUT.PUT_LINE(
                    '"schemasPe":[' ||
                        CASE WHEN v_grp_swap.EXISTS(v_dim || '|schema')
                             THEN NVL(v_grp_swap(v_dim || '|schema'), '') ELSE '' END
                    || '],');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"modules":[' ||
                    CASE WHEN v_grp_json.EXISTS(v_dim || '|module')
                         THEN NVL(v_grp_json(v_dim || '|module'), '') ELSE '' END
                || '],');
            IF v_dim_unit_swap.EXISTS(v_dim) THEN
                DBMS_OUTPUT.PUT_LINE(
                    '"modulesPe":[' ||
                        CASE WHEN v_grp_swap.EXISTS(v_dim || '|module')
                             THEN NVL(v_grp_swap(v_dim || '|module'), '') ELSE '' END
                    || '],');
            END IF;
            DBMS_OUTPUT.PUT_LINE(
                '"actions":[' ||
                    CASE WHEN v_grp_json.EXISTS(v_dim || '|action')
                         THEN NVL(v_grp_json(v_dim || '|action'), '') ELSE '' END
                || CASE WHEN v_dim_unit_swap.EXISTS(v_dim) THEN '],' ELSE ']}' END);
            IF v_dim_unit_swap.EXISTS(v_dim) THEN
                DBMS_OUTPUT.PUT_LINE(
                    '"actionsPe":[' ||
                        CASE WHEN v_grp_swap.EXISTS(v_dim || '|action')
                             THEN NVL(v_grp_swap(v_dim || '|action'), '') ELSE '' END
                    || ']}');
            END IF;
            v_first_dim := FALSE;
            v_dim := v_dim_label.NEXT(v_dim);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('}};');
        -- Truncation footnote: when c_json_cap clamped either accumulator,
        -- inject a small <p> above the matching chart-wrap so the user
        -- knows the chart doesn't reflect every top SQL / schema. Runs
        -- before the echarts guard so the note still shows in offline mode
        -- (chart-wrap is empty there, but the detail table below carries
        -- every value).
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.topSql.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("topsql-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.topSql.dims[dim]; var bits=[];');
        DBMS_OUTPUT.PUT_LINE('  if(d.sqlsKept<d.sqlsTotal){ bits.push("first "+d.sqlsKept+" of "+d.sqlsTotal+" SQL"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.schemasKept<d.schemasTotal){ bits.push("first "+d.schemasKept+" of "+d.schemasTotal+" parsing schemas"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.modulesKept<d.modulesTotal){ bits.push("first "+d.modulesKept+" of "+d.modulesTotal+" modules"); }');
        DBMS_OUTPUT.PUT_LINE('  if(d.actionsKept<d.actionsTotal){ bits.push("first "+d.actionsKept+" of "+d.actionsTotal+" actions"); }');
        DBMS_OUTPUT.PUT_LINE('  if(!bits.length) return;');
        DBMS_OUTPUT.PUT_LINE('  var note=document.createElement("p");');
        DBMS_OUTPUT.PUT_LINE('  note.className="trunc-note";');
        DBMS_OUTPUT.PUT_LINE('  note.style.cssText="font-size:11px;color:var(--muted);margin:-2px 0 6px;font-style:italic";');
        DBMS_OUTPUT.PUT_LINE('  note.textContent="Chart truncated to fit the 32 KB per-dimension JSON budget: showing "+bits.join(", ")+". The detail table below carries every value.";');
        DBMS_OUTPUT.PUT_LINE('  el.parentNode.insertBefore(note, el);');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('if(!window.echarts) return;');
        DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
        DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
        DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
        DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
        DBMS_OUTPUT.PUT_LINE('var fmt=function(v){return v==null?"\u2014":(+v).toLocaleString(undefined,{maximumFractionDigits:3});};');
        -- per execution (the swap of the four total dims and the *_PE
        -- rankings): about 4 significant digits (a few microseconds per call
        -- would print as 0 with three decimals), whole numbers from 1000 up
        DBMS_OUTPUT.PUT_LINE('var fmtPe=function(v){if(v==null)return "\u2014";v=+v;return Math.abs(v)>=1000?v.toLocaleString(undefined,{maximumFractionDigits:0}):v.toLocaleString(undefined,{maximumSignificantDigits:4});};');
        DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.topSql.dims).forEach(function(dim){');
        DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("topsql-chart-"+dim); if(!el) return;');
        DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.topSql.dims[dim], isRank=dim.slice(-3)==="_PE";');
        DBMS_OUTPUT.PUT_LINE('  var weeks=AWR_DATA.topSql.weeks;');
        DBMS_OUTPUT.PUT_LINE('  var mark=window.AWR_markLine&&window.AWR_markLine(weeks,AWR_DATA.topSql.weeksIso);');
        DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
        DBMS_OUTPUT.PUT_LINE('  function rowName(s){ return s.name || s.sql_id || "?"; }');
        -- currentMode persists across renders (window highlight re-renders).
        DBMS_OUTPUT.PUT_LINE('  var currentMode="sqls";');
        -- X2: window-axis highlight state. hiSlot: 0=current, 1=first prior...
        DBMS_OUTPUT.PUT_LINE('  var hiSlot=null;');
        DBMS_OUTPUT.PUT_LINE('  function render(mode){');
        DBMS_OUTPUT.PUT_LINE('    if(mode) currentMode=mode;');
        -- the theme colours are read again on every draw: a redraw after a
        -- theme flip (the Values switch, Break down by, the window highlight)
        -- must not bring back the colours of the first paint
        DBMS_OUTPUT.PUT_LINE('    var c0=getComputedStyle(document.body); fg=c0.getPropertyValue("--fg").trim()||"#333"; mu=c0.getPropertyValue("--muted").trim()||"#888"; gr=c0.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('    var rows=(d[currentMode]||d.sqls)||[];');
        -- Values: Total | Per execution | Top per execution
        -- (window.AWR_topsqlVal).  In mode perexec the chart of a TOTAL dim
        -- (d.unitPe is only there for those four) draws the same statements /
        -- groups in the same order with the values of the parallel "...Pe"
        -- array (element i = row i) and the unit d.unitPe; a *_PE dimension
        -- (the Top per execution view) always draws its own values per
        -- execution.  F / U: the number format and the unit of the tooltip
        -- and the y axis.
        DBMS_OUTPUT.PUT_LINE('    var pa=(!isRank&&window.AWR_topsqlVal&&window.AWR_topsqlVal()==="perexec"&&d.unitPe)?d[(d[currentMode]?currentMode:"sqls")+"Pe"]:null;');
        DBMS_OUTPUT.PUT_LINE('    if(pa&&pa.length!==rows.length) pa=null;');
        DBMS_OUTPUT.PUT_LINE('    if(pa) rows=rows.map(function(s,i){return {name:s.name,sql_id:s.sql_id,vals:pa[i]};});');
        DBMS_OUTPUT.PUT_LINE('    var F=(pa||isRank)?fmtPe:fmt,U=pa?d.unitPe:d.unit;');
        -- B2: only end-label the 3 series with the largest current-window
        -- value; the rest get a dimmed line and no label so the labelled
        -- ones read first. labelLayout shifts any remaining collisions.
        DBMS_OUTPUT.PUT_LINE('    var lastVal=function(a){for(var k=a.length-1;k>=0;k--){if(a[k]!=null)return a[k];}return null;};');
        DBMS_OUTPUT.PUT_LINE('    var top3=rows.map(function(s,i){return i;}).sort(function(a,b){return (lastVal(rows[b].vals)==null?-Infinity:lastVal(rows[b].vals))-(lastVal(rows[a].vals)==null?-Infinity:lastVal(rows[a].vals));}).slice(0,3);');
        DBMS_OUTPUT.PUT_LINE('    chart.setOption({');
        DBMS_OUTPUT.PUT_LINE('      labelLayout:{moveOverlap:"shiftY"},');
        DBMS_OUTPUT.PUT_LINE('      tooltip:{trigger:"axis",axisPointer:{type:"line"},formatter:function(ps){var hdr="<b>"+ps[0].axisValue+"</b>";var rs=ps.filter(function(p){return p.value!=null;}).sort(function(a,b){return (b.value||0)-(a.value||0);}).map(function(p){return p.marker+" "+String(p.seriesName).replace(/&/g,"&amp;").replace(/</g,"&lt;")+": <b>"+F(p.value)+" "+U+"</b>";}).join("<br/>");return hdr+"<br/>"+rs;}},');
        DBMS_OUTPUT.PUT_LINE('      legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
        DBMS_OUTPUT.PUT_LINE('      grid:{left:50,right:128,top:10,bottom:44,containLabel:true},');
        DBMS_OUTPUT.PUT_LINE('      xAxis:{type:"category",data:weeks,axisLabel:{color:fg,fontWeight:600},splitLine:{show:true,lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      yAxis:{type:"value",name:U,nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (pa||isRank)?fmtPe(v):(+v).toLocaleString(undefined,{maximumFractionDigits:2});}},splitLine:{lineStyle:{color:gr}}},');
        DBMS_OUTPUT.PUT_LINE('      series:rows.map(function(s,i){var isTop=top3.indexOf(i)>=0;var o={name:rowName(s),type:"line",connectNulls:false,showSymbol:true,symbolSize:6,itemStyle:{color:palette[i%palette.length]},lineStyle:{width:isTop?2:1.25,opacity:isTop?1:.45},emphasis:{focus:"series",lineStyle:{width:3,opacity:1}},endLabel:isTop?{show:true,formatter:"{a}",color:fg,fontSize:10,distance:6,width:112,overflow:"truncate",labelLine:{show:true,length2:4}}:{show:false},data:s.vals};if(i===0&&mark)o.markLine=mark;if(i===0&&hiSlot!=null){var idx=weeks.length-1-hiSlot;if(idx>=0&&idx<weeks.length)o.markArea={silent:true,itemStyle:{color:"rgba(37,99,235,0.14)"},data:[[{xAxis:idx},{xAxis:idx}]]};}return o;})');
        DBMS_OUTPUT.PUT_LINE('    }, true);');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  render("sqls");');
        -- X2: highlight the compared-window column for slot w; null clears.
        DBMS_OUTPUT.PUT_LINE('  document.addEventListener("awr:window",function(e){hiSlot=e.detail?e.detail.w:null;render();});');
        -- the Values switch changed: a TOTAL dim (d.unitPe) draws again
        -- (render() reads the mode: it swaps its values in mode perexec and
        -- back), the others keep their drawing (and their legend state); every
        -- chart is sized again (one in the view just hidden measured 0 wide)
        DBMS_OUTPUT.PUT_LINE('  document.addEventListener("awr:topsqlval",function(){if(d.unitPe) render(); chart.resize();});');
        DBMS_OUTPUT.PUT_LINE('  var toggle=document.querySelector(''[data-topsql-target="''+dim+''"]'');');
        DBMS_OUTPUT.PUT_LINE('  if(toggle){');
        -- Hide any group-view button whose dim carries no meaningful rows:
        -- either no rows at all (e.g. PEREXEC, which only has a SQL_ID
        -- breakdown) or only the "(none)"/"(unknown)" placeholder (every SQL
        -- left module/action/schema unset). Same idea as section 11's
        -- per-card toggle that hid empty module/action stacks.
        DBMS_OUTPUT.PUT_LINE('    ["schemas","modules","actions"].forEach(function(m){');
        DBMS_OUTPUT.PUT_LINE('      var rows=d[m]||[];');
        DBMS_OUTPUT.PUT_LINE('      var real=rows.some(function(s){return s.name!=="(none)"&&s.name!=="(unknown)";});');
        DBMS_OUTPUT.PUT_LINE('      if(!real){');
        DBMS_OUTPUT.PUT_LINE('        var mb=toggle.querySelector(''[data-mode="''+m+''"]'');');
        DBMS_OUTPUT.PUT_LINE('        if(mb) mb.style.display="none";');
        DBMS_OUTPUT.PUT_LINE('      }');
        DBMS_OUTPUT.PUT_LINE('    });');
        DBMS_OUTPUT.PUT_LINE('    toggle.addEventListener("click",function(ev){');
        DBMS_OUTPUT.PUT_LINE('      var btn=ev.target.closest("button"); if(!btn) return;');
        DBMS_OUTPUT.PUT_LINE('      var mode=btn.getAttribute("data-mode"); if(!mode) return;');
        DBMS_OUTPUT.PUT_LINE('      Array.prototype.forEach.call(toggle.querySelectorAll("button"),function(b){ b.classList.toggle("active", b===btn); });');
        DBMS_OUTPUT.PUT_LINE('      render(mode);');
        DBMS_OUTPUT.PUT_LINE('    });');
        DBMS_OUTPUT.PUT_LINE('  }');
        DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){chart.resize();}).observe(el);');
        -- Re-apply axis/legend colors from the CSS vars on theme flip (F14).
        DBMS_OUTPUT.PUT_LINE('  document.addEventListener("awr:theme",function(){var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888",gr2=c2.getPropertyValue("--border").trim()||"#e0e0e0";');
        DBMS_OUTPUT.PUT_LINE('  chart.setOption({legend:{textStyle:{color:fg2}},xAxis:{axisLabel:{color:fg2},splitLine:{lineStyle:{color:gr2}}},yAxis:{nameTextStyle:{color:mu2},axisLabel:{color:mu2},splitLine:{lineStyle:{color:gr2}}}});});');
        DBMS_OUTPUT.PUT_LINE('});');
        DBMS_OUTPUT.PUT_LINE('})();</script>');
    END IF;

    -- Cross-dim plan-change rollup. v_seen_sqls is populated for every
    -- SQL_ID that appeared in any dimension's top-N detail table above;
    -- v_flip_sqls is the subset whose current PHV differs from a non-null
    -- prior PHV. One badge + one sentence: lets a reader scan the section
    -- and immediately tell whether plan changes are even in scope.
    IF v_seen_sqls.COUNT > 0 THEN
        IF v_flip_sqls.COUNT > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<p style="margin-top:18px">'
                || '<span class="badge warn">plan&#8593;</span> '
                || v_flip_sqls.COUNT || ' of ' || v_seen_sqls.COUNT
                || ' top SQL had a plan_hash_value change between current and a prior '
                || 'compared window. Look for the <span class="badge warn">plan&#8593;</span> '
                || 'badges in the SQL ID column and the per-window cells above.</p>');
        ELSE
            DBMS_OUTPUT.PUT_LINE('<p style="margin-top:18px">'
                || '<span class="badge ok">plan stable</span> '
                || 'No plan_hash_value changes detected for any of the '
                || v_seen_sqls.COUNT || ' top SQL across the compared windows.</p>');
        END IF;
    END IF;

    -- Per-SQL detail: full text + AWR retention range + plan timeline ----
    -- C1: one <table id="sql-pool"> with a summary row per SQL (SQL_ID,
    -- Ranked-in chips, schema, plan/exec/snap counts, first seen, a short
    -- text snippet) and a paired hidden detail row carrying the full
    -- metadata strip, per-PHV summary table, timeline chart, and full SQL
    -- text -- previously one <details> block per SQL. Ordered by
    -- current-window elapsed time desc; rows beyond the first 8 are
    -- tagged data-tail="Y" and collapsed behind an expander.
    -- All sections only (class "vw in-a"): the per-SQL pool.
    DBMS_OUTPUT.PUT_LINE('<h3 class="vw in-a">Per-SQL detail</h3>');
    DBMS_OUTPUT.PUT_LINE('<p class="vw in-a" style="font-size:12.5px;color:var(--muted)">'
        || 'Click a row for the full text, plan summary and per-snapshot timeline '
        || '(a colour change = a plan switch). <b>Ranked in</b>: '
        || '<b>E</b>lapsed, <b>C</b>PU, <b>G</b>ets, <b>R</b>eads, e<b>X</b>ecutions, '
        || '<b>P</b> = Top per execution (any of the four per-execution rankings; the chip names them); '
        || 'solid = in that ranking''s current top 3. '
        || 'Plans, Executions, Snapshots and First seen cover the whole AWR retention, '
        || 'not only the compared windows; open a row for its numbers per compared window.</p>');

    -- One JS namespace bucket per SQL; populated below, consumed by the
    -- single ECharts init pass at the end of the section.
    DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.sqlDetails = AWR_DATA.sqlDetails || {};</script>');

    DBMS_OUTPUT.PUT_LINE('<table id="sql-pool" class="vw in-a"><thead><tr>'
        || '<th>SQL ID</th><th>Ranked in</th><th>Schema</th>'
        || '<th class="num" title="distinct non-zero plan_hash_values in all of the AWR retention, not only the compared windows">Plans</th><th class="num">Executions</th>'
        || '<th class="num" title="AWR snapshots in which the SQL appeared">Snapshots</th><th>First seen</th><th>Text</th>'
        || '</tr></thead><tbody>');

    DECLARE
        v_sql_id          VARCHAR2(30);
        v_text            CLOB;
        v_len             NUMBER;
        v_snip            VARCHAR2(8000);
        -- v_snip escaped for the <pre> block, built 500 characters at a
        -- time (see the loop before the PUT_LINE), and how many characters
        -- of v_snip it covers.
        v_snip_esc        VARCHAR2(32767);
        v_snip_part       VARCHAR2(4000);
        v_snip_shown      PLS_INTEGER;
        v_first_seen      VARCHAR2(30);
        v_last_seen       VARCHAR2(30);
        v_phv_count       NUMBER;
        v_total_exec      NUMBER;
        v_total_snap      NUMBER;
        v_first_pt        BOOLEAN;

        -- Per-SQL identity / context metadata, captured across the full AWR
        -- retention range. For values that can vary across snapshots
        -- (module/action/optimizer_mode), we keep the most recent non-null
        -- via KEEP (DENSE_RANK LAST ORDER BY <non_null_flag, snap_id>);
        -- if all snaps have NULL, the result is NULL and the strip shows
        -- a muted dash.
        v_parsing_schema  VARCHAR2(128);
        v_last_module     VARCHAR2(64);
        v_last_action     VARCHAR2(64);
        v_last_opt_mode   VARCHAR2(32);
        v_module_distinct NUMBER;
        v_force_sig       NUMBER;
        v_sql_profile     VARCHAR2(64);

        -- Ordered (sql_id, elapsed) list, current-window elapsed desc
        -- (0/NULL sorts last), so the pool table's row order and its
        -- first-8 / data-tail split match the "By elapsed time" ranking.
        TYPE t_ord_rec IS RECORD (sid VARCHAR2(30), ela NUMBER);
        TYPE t_ord_tab IS TABLE OF t_ord_rec;
        v_order   t_ord_tab := t_ord_tab();
        v_swap    t_ord_rec;
        v_idx     PLS_INTEGER := 0;
        v_dim_key VARCHAR2(40);
        v_chip    VARCHAR2(1);

        -- Compared windows table: the key into v_wa_*, the row being built,
        -- the prior mean (n windows with a row, their totals) and the
        -- current window's plan.
        v_wk      VARCHAR2(60);
        v_wrow    VARCHAR2(32767);
        v_wlab    VARCHAR2(600);
        v_wn      PLS_INTEGER;
        v_wsx     NUMBER;
        v_wse     NUMBER;
        v_wx      NUMBER;          -- executions of the window being shown
        v_we      NUMBER;          -- its elapsed seconds
        v_wpe     NUMBER;          -- its seconds per execution
        v_wph     NUMBER;          -- its plan hash
        -- Plan change marks: v_wchg(k) exists when window k (valid, with an
        -- AWR row, non-zero plan hash) ran a different plan than the nearest
        -- OLDER such window, and holds that older plan hash.  Built once per
        -- statement over all windows 0 .. weeks_back, oldest first.
        TYPE t_wchg_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        v_wchg    t_wchg_tab;
        v_wlast   NUMBER;          -- plan of the nearest older window with a plan
        v_wcur    NUMBER;          -- plan of the window being looked at
        v_mu_x    NUMBER;          -- prior mean executions
        v_mu_e    NUMBER;          -- prior mean elapsed seconds
        v_mu_pe   NUMBER;          -- prior total elapsed / total executions
        -- Chart payload: plan hash -> its index in the phv list, in order
        -- of first appearance
        TYPE t_pidx_tab IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
        v_pidx    t_pidx_tab;
        v_pn      PLS_INTEGER;
        v_pi      PLS_INTEGER;
        v_plist   VARCHAR2(32767);
        v_pkey    VARCHAR2(40);
        -- Runs of the same state among the displayed prior windows collapse
        -- into one row: v_wmax = last displayed window, v_wskipto = last
        -- window already shown by a collapsed row, v_wst / v_wbs = the state
        -- of the window being looked at / of the one after it, v_wb = the
        -- run's oldest window.
        v_wmax    PLS_INTEGER;
        v_wskipto PLS_INTEGER;
        v_wb      PLS_INTEGER;
        v_wst     VARCHAR2(400);
        v_wbs     VARCHAR2(400);

        -- Plan 044, "Per execution: where the time went" (after the Compared
        -- windows table).  Index of the rows: 1 elapsed, 2 CPU, 3 I/O wait,
        -- 4 concurrency, 5 application, 6 cluster, 7 other (elapsed minus
        -- 2-6, never below 0), 8 rows processed, 9 buffer gets, 10 physical
        -- reads, 11 buffer gets per row (shown values only).  v_xc = the
        -- Current window's totals, v_xp = the summed totals of the prior
        -- valid windows WITH a row (the tfoot's windows), so per execution =
        -- total / executions on both sides and the parts add up.  Ranked
        -- evidence, never scored.
        TYPE t_x_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        v_xc      t_x_tab;
        v_xp      t_x_tab;
        v_xcv     t_x_tab;         -- Current value shown (per execution, or the total)
        v_xmv     t_x_tab;         -- prior value shown (NULL = none)
        v_xmode   VARCHAR2(8);     -- pe | tot | new | noprx | nocur
        v_xrule   VARCHAR2(8);     -- the Reads-as rule picked (NULL = no sentence)
        v_xrd     VARCHAR2(2000);  -- the Reads-as sentence
        v_xrise   NUMBER;          -- Current minus prior elapsed (shown unit)
        v_xbig    PLS_INTEGER;     -- the part (2-7) with the largest share of the rise
        v_xre     NUMBER;          -- per-run elapsed ratio
        v_xrr     NUMBER;          -- rows per run ratio
        v_xgr     NUMBER;          -- buffer gets per run ratio
        v_xdr     NUMBER;          -- physical reads per run ratio
        v_xpr     NUMBER;          -- gets per row ratio
        v_xrf     VARCHAR2(1);     -- rows per run flat (Y / N)
        v_xrow    VARCHAR2(4000);
        -- The fixed thresholds of the "Reads as" sentence (the About note,
        -- "Per-SQL detail", states the same).  Only when the per-run elapsed
        -- is at least c_sqx_gate x the prior mean, the first rule that holds:
        --   harder  gets per run >= c_sqx_up x, rows per run flat, and CPU
        --           plus I/O wait carry >= c_sqx_part of the per-run rise
        --   data    rows per run >= c_sqx_up x and gets per row flat
        --   ap      application wait carries >= c_sqx_part of the rise
        --   cc      concurrency wait carries >= c_sqx_part
        --   cl      cluster wait carries >= c_sqx_part
        --   slowio  I/O wait carries >= c_sqx_part, gets, rows and physical
        --           reads per run flat
        --   cold    I/O wait carries >= c_sqx_part, gets per run flat,
        --           physical reads per run >= c_sqx_up x
        --   mixed   none of these: name the largest part
        -- "flat" = within c_sqx_flat (+/-20%) of the prior per run; a share
        -- = (Current - prior) of the part / (Current - prior) of elapsed.
        -- Below the gate, when the window total rose at least c_sqx_gate x
        -- the prior mean total (rule often): it ran more often.
        c_sqx_gate CONSTANT NUMBER := 1.5;
        c_sqx_part CONSTANT NUMBER := 0.6;
        c_sqx_flat CONSTANT NUMBER := 0.2;
        c_sqx_up   CONSTANT NUMBER := 1.5;

        -- Plain change of Current against the prior mean, for the Current
        -- row of the Compared windows table: "new" when no prior window had
        -- a row, "from 0" on a zero mean, else the report's one Delta rule
        -- (plain, never coloured: Top SQL is ranked, not scored).
        FUNCTION sqd_chg(p_cur NUMBER, p_mu NUMBER, p_n PLS_INTEGER, p_what VARCHAR2)
            RETURN VARCHAR2 IS
            v_t VARCHAR2(400);
        BEGIN
            IF p_cur IS NULL THEN
                RETURN NULL;
            END IF;
            IF NVL(p_n, 0) = 0 THEN
                RETURN ' <span class="d s-plain" title="no row in any prior valid window">new</span>';
            END IF;
            IF p_mu IS NOT NULL AND p_mu = 0 THEN
                IF p_cur = 0 THEN
                    RETURN NULL;
                END IF;
                RETURN ' <span class="d s-plain" title="' || p_what
                    || ' was 0 in the prior mean">from 0</span>';
            END IF;
            v_t := delta_span(p_cur, p_mu, NULL, 'Y');
            RETURN ' ' || REPLACE(v_t, '<span class="d s-plain">',
                '<span class="d s-plain" title="' || p_what
                || ', Current vs the prior mean of ' || p_n
                || CASE WHEN p_n = 1 THEN ' window' ELSE ' windows' END || '">');
        END sqd_chg;

        -- Whole execution counts below 10000 print as integers, anything
        -- else exactly as fmt_num does.
        FUNCTION sqd_cnt(p_n NUMBER) RETURN VARCHAR2 IS
        BEGIN
            IF p_n IS NOT NULL AND p_n = TRUNC(p_n) AND p_n < 10000 THEN
                RETURN fmt_int(p_n);
            END IF;
            RETURN fmt_num(p_n);
        END sqd_cnt;

        -- State of window p_k of statement p_sid, for the run collapsing:
        -- S plus the skip reason (skipped window), N (valid window, AWR kept
        -- no row), V (a row with values).
        FUNCTION sqd_state(p_sid VARCHAR2, p_k PLS_INTEGER) RETURN VARCHAR2 IS
        BEGIN
            IF SUBSTR(v_tl_valid, p_k + 1, 1) <> 'Y' THEN
                RETURN 'S' || CASE WHEN v_wskip.EXISTS(p_k) THEN v_wskip(p_k)
                                   ELSE 'no valid snapshot pair' END;
            ELSIF NOT v_wa_exec.EXISTS(p_sid || '|' || p_k) THEN
                RETURN 'N';
            END IF;
            RETURN 'V';
        END sqd_state;

        -- plan 044 helpers.  A raw number for a data-* attribute (the page's
        -- check recomputes the block from them), the decimal point pinned.
        FUNCTION sqx_tok(p NUMBER) RETURN VARCHAR2 IS
        BEGIN
            RETURN CASE WHEN p IS NOT NULL
                        THEN TO_CHAR(p, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''') END;
        END sqx_tok;

        -- Current over prior, NULL when the prior is missing or 0
        FUNCTION sqx_r(p_k PLS_INTEGER) RETURN NUMBER IS
        BEGIN
            IF v_xcv.EXISTS(p_k) AND v_xmv.EXISTS(p_k) AND v_xcv(p_k) IS NOT NULL
               AND v_xmv(p_k) IS NOT NULL AND v_xmv(p_k) <> 0 THEN
                RETURN v_xcv(p_k) / v_xmv(p_k);
            END IF;
            RETURN NULL;
        END sqx_r;

        -- share of the elapsed rise carried by part p_k (NULL: no rise)
        FUNCTION sqx_s(p_k PLS_INTEGER) RETURN NUMBER IS
        BEGIN
            IF v_xrise IS NULL OR v_xrise <= 0 OR v_xmv(p_k) IS NULL THEN
                RETURN NULL;
            END IF;
            RETURN (v_xcv(p_k) - v_xmv(p_k)) / v_xrise;
        END sqx_s;

        -- a ratio as text: "x1.4" (x = the times sign)
        FUNCTION sqx_x(p_r NUMBER) RETURN VARCHAR2 IS
        BEGIN
            RETURN '&times;' || CASE WHEN p_r >= 100 THEN TO_CHAR(ROUND(p_r), 'FM999999999990')
                                     ELSE TO_CHAR(p_r, 'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') END;
        END sqx_x;

        -- a share as a whole percentage
        FUNCTION sqx_pct(p_s NUMBER) RETURN VARCHAR2 IS
        BEGIN
            IF p_s IS NULL THEN
                RETURN NULL;
            END IF;
            RETURN CASE WHEN ROUND(p_s * 100) < 0 THEN '&minus;' END
                || TO_CHAR(ABS(ROUND(p_s * 100)), 'FM999999999990') || '%';
        END sqx_pct;

        -- the row label of index p_k (p_s = the short form for a sentence)
        FUNCTION sqx_nm(p_k PLS_INTEGER, p_s VARCHAR2 DEFAULT 'N') RETURN VARCHAR2 IS
        BEGIN
            RETURN CASE p_k
                WHEN 1 THEN CASE WHEN p_s = 'Y' THEN 'elapsed' ELSE 'Elapsed (s)' END
                WHEN 2 THEN CASE WHEN p_s = 'Y' THEN 'CPU' ELSE 'CPU (s)' END
                WHEN 3 THEN CASE WHEN p_s = 'Y' THEN 'I/O wait' ELSE 'I/O wait (s)' END
                WHEN 4 THEN CASE WHEN p_s = 'Y' THEN 'concurrency wait' ELSE 'Concurrency (s)' END
                WHEN 5 THEN CASE WHEN p_s = 'Y' THEN 'application wait' ELSE 'Application, locks (s)' END
                WHEN 6 THEN CASE WHEN p_s = 'Y' THEN 'cluster wait' ELSE 'Cluster (s)' END
                WHEN 7 THEN CASE WHEN p_s = 'Y' THEN 'other time' ELSE 'Other (s)' END
                WHEN 8 THEN 'Rows'
                WHEN 9 THEN 'Buffer gets'
                WHEN 10 THEN 'Physical reads'
                ELSE 'Buffer gets per row' END;
        END sqx_nm;

        -- "flat": within c_sqx_flat of the prior per run ('Y' / 'N')
        FUNCTION sqx_flat(p_r NUMBER) RETURN VARCHAR2 IS
        BEGIN
            RETURN CASE WHEN p_r IS NOT NULL AND p_r >= 1 - c_sqx_flat AND p_r <= 1 + c_sqx_flat
                        THEN 'Y' ELSE 'N' END;
        END sqx_flat;
    BEGIN
        v_sql_id := v_seen_sqls.FIRST;
        WHILE v_sql_id IS NOT NULL LOOP
            v_order.EXTEND;
            v_order(v_order.LAST).sid := v_sql_id;
            v_order(v_order.LAST).ela :=
                CASE WHEN v_sql_elapsed_cur.EXISTS(v_sql_id)
                     THEN v_sql_elapsed_cur(v_sql_id) ELSE 0 END;
            v_sql_id := v_seen_sqls.NEXT(v_sql_id);
        END LOOP;
        FOR i IN 1 .. v_order.COUNT - 1 LOOP
            FOR j IN i + 1 .. v_order.COUNT LOOP
                IF v_order(j).ela > v_order(i).ela
                   OR (v_order(j).ela = v_order(i).ela AND v_order(j).sid < v_order(i).sid) THEN
                    v_swap := v_order(i); v_order(i) := v_order(j); v_order(j) := v_swap;
                END IF;
            END LOOP;
        END LOOP;

        FOR oi IN 1 .. v_order.COUNT LOOP
            v_sql_id := v_order(oi).sid;
            v_idx    := oi;
            -- Aggregate metadata across full AWR retention for this SQL.
            BEGIN
                SELECT TO_CHAR(MIN(s.begin_interval_time), 'YYYY-MM-DD HH24:MI'),
                       TO_CHAR(MAX(s.end_interval_time),   'YYYY-MM-DD HH24:MI'),
                       COUNT(DISTINCT NULLIF(st.plan_hash_value, 0)),
                       SUM(NVL(st.executions_delta, 0)),
                       COUNT(*),
                       MAX(st.parsing_schema_name)
                           KEEP (DENSE_RANK LAST ORDER BY st.snap_id),
                       MAX(st.module)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.module IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       MAX(st.action)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.action IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       MAX(st.optimizer_mode)
                           KEEP (DENSE_RANK LAST ORDER BY
                               CASE WHEN st.optimizer_mode IS NOT NULL THEN 1 ELSE 0 END,
                               st.snap_id),
                       COUNT(DISTINCT st.module),
                       MAX(st.force_matching_signature),
                       MAX(st.sql_profile)
                INTO   v_first_seen, v_last_seen,
                       v_phv_count, v_total_exec, v_total_snap,
                       v_parsing_schema, v_last_module, v_last_action,
                       v_last_opt_mode, v_module_distinct,
                       v_force_sig, v_sql_profile
                FROM   dba_hist_sqlstat st
                JOIN   dba_hist_snapshot s
                  ON   s.dbid = st.dbid
                 AND   s.snap_id = st.snap_id
                 AND   s.instance_number = st.instance_number
                WHERE  st.dbid   IN (~dbid_list)
                  AND  st.sql_id = v_sql_id
                  AND  (~inst_num = 0 OR st.instance_number = ~inst_num);
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_first_seen := NULL; v_last_seen  := NULL;
                v_phv_count  := 0;    v_total_exec := 0; v_total_snap := 0;
                v_parsing_schema := NULL; v_last_module := NULL;
                v_last_action    := NULL; v_last_opt_mode := NULL;
                v_module_distinct := 0;
                v_force_sig := NULL; v_sql_profile := NULL;
            END;

            -- Full SQL text (single source of truth, same lookup as before).
            BEGIN
                SELECT sql_text
                INTO   v_text
                FROM (
                    SELECT sql_text,
                           -- ORDER BY NULL, not ROWID: avoids ORA-01445 on the
                           -- DBA_HIST_SQLTEXT join view under a PDB. PARTITION
                           -- BY sql_id only so a sql_id present under both a
                           -- pre- and post-migration DBID collapses to one row.
                           ROW_NUMBER() OVER (PARTITION BY sql_id ORDER BY NULL) AS rn
                    FROM   dba_hist_sqltext
                    WHERE  dbid IN (~dbid_list) AND sql_id = v_sql_id
                ) WHERE rn = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_text := NULL;
            END;

            IF v_text IS NULL THEN
                v_len  := 0;
                v_snip := '(text not in DBA_HIST_SQLTEXT)';
            ELSE
                v_len  := DBMS_LOB.GETLENGTH(v_text);
                -- 8000 characters can be up to 32000 bytes in AL32UTF8 and
                -- v_snip holds 8000 BYTES: cut by bytes (SUBSTRB never
                -- returns a partial character). ASCII text is unchanged.
                v_snip := SUBSTRB(DBMS_LOB.SUBSTR(v_text, 8000, 1), 1, 8000);
            END IF;

            -- C1: summary row. The <tr> id is the link target for SQL_ID
            -- anchors in the top-N tables above (and the hashchange handler
            -- at the end of this section); the paired detail row (emitted
            -- after this SQL's body below) carries the full breakdown.
            DBMS_OUTPUT.PUT_LINE('<tr class="sql-row" id="sql-' || v_sql_id || '"'
                || ' data-sys="'
                || CASE WHEN v_sys_sqls.EXISTS(v_sql_id) AND v_sys_sqls(v_sql_id)
                        THEN 'Y' ELSE 'N' END || '"'
                || CASE WHEN v_idx > 8 THEN ' data-tail="Y" hidden' ELSE '' END
                || '>');
            -- Phase 3 cross-links: the chrome JS hides an .xlink whose
            -- target id does not exist (no ASH card / no SQL Monitor row).
            DBMS_OUTPUT.PUT_LINE('<td class="mono sqlid-cell">'
                || '<span id="sqlid-' || v_sql_id || '">' || v_sql_id || '</span> '
                || '<button type="button" class="copy-btn" '
                || 'data-copy="#sqlid-' || v_sql_id || '">&#10687;</button>'
                || '<span class="xlinks">'
                || '<a class="xlink" href="#ash-card-' || v_sql_id
                || '" title="ASH breakdown of this SQL" onclick="event.stopPropagation()">ASH</a>'
                || '<a class="xlink" href="#sm-' || v_sql_id
                || '" title="SQL Monitor row for this SQL" onclick="event.stopPropagation()">MON</a>'
                || '</span>'
                || '</td>');
            -- Ranked-in chips: E/C/G/R/X, solid ("on") when the SQL is in
            -- that dimension's current-window top-3, plain when it merely
            -- made that dimension's top-N pool in some window, absent when
            -- it never appeared in that dimension at all.
            DECLARE
                v_chips VARCHAR2(1000) := '';
                v_pe_names VARCHAR2(100);
                v_pe_on    BOOLEAN := FALSE;
            BEGIN
                FOR c IN (
                    SELECT 'E' AS letter, 'ELAPSED' AS dim FROM dual UNION ALL
                    SELECT 'C', 'CPU' FROM dual UNION ALL
                    SELECT 'G', 'GETS' FROM dual UNION ALL
                    SELECT 'R', 'PREADS' FROM dual UNION ALL
                    SELECT 'X', 'EXEC' FROM dual
                ) LOOP
                    v_dim_key := v_sql_id || '|' || c.dim;
                    IF v_sql_dim_seen.EXISTS(v_dim_key) THEN
                        v_chip := CASE WHEN v_sql_dim_top3.EXISTS(v_dim_key)
                                       THEN 'Y' ELSE 'N' END;
                        v_chips := v_chips || '<span class="chip'
                            || CASE WHEN v_chip = 'Y' THEN ' on' ELSE '' END
                            || '" title="' || c.dim || '">' || c.letter || '</span>';
                    END IF;
                END LOOP;
                -- P: the one chip of the four per-execution rankings (Values:
                -- Per execution), its tooltip names the metrics, solid when
                -- the statement is in a Current top 3 of any of them
                FOR c IN (
                    SELECT 'elapsed' AS metric, 'ELAPSED_PE' AS dim FROM dual UNION ALL
                    SELECT 'CPU', 'CPU_PE' FROM dual UNION ALL
                    SELECT 'gets', 'GETS_PE' FROM dual UNION ALL
                    SELECT 'reads', 'PREADS_PE' FROM dual
                ) LOOP
                    v_dim_key := v_sql_id || '|' || c.dim;
                    IF v_sql_dim_seen.EXISTS(v_dim_key) THEN
                        v_pe_names := v_pe_names || CASE WHEN v_pe_names IS NOT NULL THEN ', ' END
                                      || c.metric;
                        IF v_sql_dim_top3.EXISTS(v_dim_key) THEN
                            v_pe_on := TRUE;
                        END IF;
                    END IF;
                END LOOP;
                IF v_pe_names IS NOT NULL THEN
                    v_chips := v_chips || '<span class="chip' || CASE WHEN v_pe_on THEN ' on' END
                        || '" title="in a per-execution ranking: ' || v_pe_names || '">P</span>';
                END IF;
                DBMS_OUTPUT.PUT_LINE('<td>' || v_chips || '</td>');
            END;

            DBMS_OUTPUT.PUT_LINE('<td class="mono">'
                || CASE WHEN v_parsing_schema IS NULL THEN '&mdash;'
                        ELSE DBMS_XMLGEN.CONVERT(v_parsing_schema) END
                || '</td>'
                || '<td class="num">' || NVL(v_phv_count, 0)
                || CASE WHEN NVL(v_phv_count, 0) > 2
                        THEN ' <span class="badge warn">plan flip</span>' ELSE '' END
                || '</td>'
                || '<td class="num">' || fmt_int(NVL(v_total_exec, 0)) || '</td>'
                || '<td class="num">' || fmt_int(NVL(v_total_snap, 0)) || '</td>'
                || '<td>' || NVL(v_first_seen, '?') || '</td>'
                || '<td class="mono sqltext">'
                || DBMS_XMLGEN.CONVERT(SUBSTR(NVL(v_snip, ''), 1, 90))
                || CASE WHEN LENGTH(NVL(v_snip, '')) > 90 THEN '&hellip;' ELSE '' END
                || '</td>');
            DBMS_OUTPUT.PUT_LINE('</tr>');

            -- Paired (initially hidden) detail row: full metadata strip,
            -- per-PHV summary table, timeline chart, and full SQL text.
            -- data-sql names the SQL_ID so the row-toggle script can find
            -- and lazily (re)size this row's ECharts instance.
            DBMS_OUTPUT.PUT_LINE('<tr class="sql-detail" data-sql="' || v_sql_id || '" hidden><td colspan="8">');

            -- Per-SQL identity / context strip. Built from the metadata SELECT
            -- above; muted dash when a field is null across all snapshots.
            DBMS_OUTPUT.PUT_LINE('<dl class="sql-meta">'
                || '<dt>Parsing schema</dt><dd class="mono">'
                || CASE WHEN v_parsing_schema IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_parsing_schema) END
                || '</dd>'
                || '<dt>Module</dt><dd>'
                || CASE WHEN v_last_module IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_module)
                             || CASE WHEN v_module_distinct > 1
                                     THEN ' <span class="muted">('
                                          || v_module_distinct
                                          || ' distinct seen)</span>'
                                     ELSE '' END END
                || '</dd>'
                || '<dt>Action</dt><dd>'
                || CASE WHEN v_last_action IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_action) END
                || '</dd>'
                || '<dt>Optimizer mode</dt><dd class="mono">'
                || CASE WHEN v_last_opt_mode IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_last_opt_mode) END
                || '</dd>'
                || '<dt>Force-match sig</dt><dd class="mono">'
                || CASE WHEN v_force_sig IS NULL OR v_force_sig = 0
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE TO_CHAR(v_force_sig) END
                || '</dd>'
                || '<dt>SQL profile</dt><dd>'
                || CASE WHEN v_sql_profile IS NULL
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE DBMS_XMLGEN.CONVERT(v_sql_profile) END
                || '</dd>'
                || '<dt>Text length</dt><dd>'
                || CASE WHEN NVL(v_len, 0) = 0
                        THEN '<span class="muted">&mdash;</span>'
                        ELSE TO_CHAR(v_len, 'FM999G999G990') || ' chars' END
                || '</dd>'
                || '</dl>');

            -- Compared windows: this statement in every compared window, from
            -- the main cursor's agg join (v_wa_*), no further read.  Current
            -- first, then the 29 most recent prior windows; the prior mean
            -- covers every valid prior window in which AWR kept a row.
            v_wn := 0; v_wsx := 0; v_wse := 0;
            FOR k IN 1 .. v_weeks_back LOOP
                v_wk := v_sql_id || '|' || k;
                IF v_wa_exec.EXISTS(v_wk) THEN
                    v_wn  := v_wn + 1;
                    v_wsx := v_wsx + v_wa_exec(v_wk);
                    v_wse := v_wse + NVL(v_wa_ela(v_wk), 0);
                END IF;
            END LOOP;
            v_mu_x  := CASE WHEN v_wn > 0 THEN v_wsx / v_wn END;
            v_mu_e  := CASE WHEN v_wn > 0 THEN v_wse / v_wn / 1e6 END;
            v_mu_pe := CASE WHEN v_wn > 0 AND v_wsx > 0 THEN v_wse / v_wsx / 1e6 END;
            -- plan change marks: skipped, not captured and plan-0 windows are
            -- passed over (no mark, and they do not break the comparison)
            v_wchg.DELETE;
            v_wlast := NULL;
            FOR k IN REVERSE 0 .. v_weeks_back LOOP
                v_wk := v_sql_id || '|' || k;
                IF v_wa_phv.EXISTS(v_wk) THEN
                    v_wcur := v_wa_phv(v_wk);
                    IF NVL(v_wcur, 0) <> 0 THEN
                        IF v_wlast IS NOT NULL AND v_wcur <> v_wlast THEN
                            v_wchg(k) := v_wlast;
                        END IF;
                        v_wlast := v_wcur;
                    END IF;
                END IF;
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('<h4 class="sqd-h">Compared windows</h4>'
                || '<p class="sqd-sub">This statement in each of the report&#39;s '
                || (v_weeks_back + 1) || ' window' || CASE WHEN v_weeks_back = 0 THEN '' ELSE 's' END
                || ' (totals per window).</p>'
                || '<div class="sqd-tw"><table id="win-' || v_sql_id
                || '" class="sqd-win" data-nosort data-nocount data-notools><thead><tr>'
                || '<th>Window</th><th class="num">Executions</th><th class="num">Elapsed (s)</th>'
                || '<th class="num">s / exec</th><th class="num">Plan hash</th>'
                || '</tr></thead><tbody>');
            v_wmax    := LEAST(v_weeks_back, 29);
            v_wskipto := -1;
            FOR k IN 0 .. v_wmax LOOP
                CONTINUE WHEN k <= v_wskipto;
                v_wk   := v_sql_id || '|' || k;
                -- two or more consecutive prior windows skipped for the same
                -- reason, or not captured, are one row
                v_wst := sqd_state(v_sql_id, k);
                IF k > 0 AND v_wst <> 'V' THEN
                    v_wb := k;
                    WHILE v_wb < v_wmax LOOP
                        v_wbs := sqd_state(v_sql_id, v_wb + 1);
                        EXIT WHEN v_wbs <> v_wst;
                        v_wb := v_wb + 1;
                    END LOOP;
                    IF v_wb > k THEN
                        v_wskipto := v_wb;
                        v_wlab := '&minus;' || off_label(k) || ' &ndash; &minus;' || off_label(v_wb)
                                  || ' <span class="sqd-dt">' || (v_wb - k + 1) || ' windows</span>';
                        IF SUBSTR(v_wst, 1, 1) = 'S' THEN
                            v_wrow := '<tr class="skip" title="Skipped windows: not compared and not in the mean">'
                                || '<td>' || v_wlab || '</td>'
                                || '<td colspan="4" title="Skipped windows: not compared and not in the mean">skipped: '
                                || DBMS_XMLGEN.CONVERT(SUBSTR(v_wst, 2))
                                || '</td></tr>';
                        ELSE
                            v_wrow := '<tr class="sqd-nocap"><td>' || v_wlab || '</td>'
                                || '<td colspan="4" class="sqd-mu" title="AWR kept no row for this statement in these windows: it ran too little to be captured, or not at all.">not captured</td></tr>';
                        END IF;
                        DBMS_OUTPUT.PUT_LINE(v_wrow);
                        CONTINUE;
                    END IF;
                END IF;
                v_wlab := CASE WHEN k = 0 THEN '<b>Current</b>' ELSE '&minus;' || off_label(k) END
                          || ' <span class="sqd-dt">' || wg_title(k) || '</span>';
                IF SUBSTR(v_tl_valid, k + 1, 1) <> 'Y' THEN
                    -- skipped window: not compared, not in the mean
                    v_wrow := '<tr class="skip" title="Skipped window: not compared and not in the mean">'
                        || '<td data-w="' || k || '">' || v_wlab || '</td>'
                        || '<td colspan="4" data-w="' || k
                        || '" title="Skipped window: not compared and not in the mean">skipped: '
                        || DBMS_XMLGEN.CONVERT(CASE WHEN v_wskip.EXISTS(k) THEN v_wskip(k)
                                                    ELSE 'no valid snapshot pair' END)
                        || '</td></tr>';
                ELSIF NOT v_wa_exec.EXISTS(v_wk) THEN
                    -- valid window, AWR kept no row for the statement: never a 0
                    v_wrow := '<tr class="sqd-nocap"><td data-w="' || k || '">' || v_wlab || '</td>'
                        || '<td colspan="4" class="sqd-mu" data-w="' || k
                        || '" title="AWR kept no row for this statement in this window: it ran too little to be captured, or not at all.">not captured</td></tr>';
                ELSE
                    v_wx  := v_wa_exec(v_wk);
                    v_we  := NVL(v_wa_ela(v_wk), 0) / 1e6;
                    v_wph := v_wa_phv(v_wk);
                    v_wpe := CASE WHEN v_wx > 0 THEN v_we / v_wx END;
                    v_wrow := '<tr' || CASE WHEN k = 0 THEN ' class="cur"' END || '>'
                        || '<td data-w="' || k || '">' || v_wlab || '</td>'
                        || '<td class="num" data-w="' || k || '"' || fmt_num_title(v_wx) || '>'
                        || sqd_cnt(v_wx)
                        || CASE WHEN k = 0 THEN sqd_chg(v_wx, v_mu_x, v_wn, 'Executions') END
                        || '</td>'
                        || '<td class="num" data-w="' || k || '"' || fmt_num_title(v_we) || '>'
                        || fmt_num(v_we)
                        || CASE WHEN k = 0 THEN sqd_chg(v_we, v_mu_e, v_wn, 'Elapsed') END
                        || '</td>';
                    IF v_wpe IS NULL THEN
                        v_wrow := v_wrow || '<td class="num" data-w="' || k
                            || '" title="No execution completed in this window, so s / exec is undefined, not 0.">&mdash;</td>';
                    ELSE
                        v_wrow := v_wrow || '<td class="num" data-w="' || k || '"'
                            || fmt_num_title(v_wpe) || '>' || fmt_num(v_wpe)
                            || CASE WHEN k = 0 THEN sqd_chg(v_wpe, v_mu_pe, v_wn, 's / exec') END
                            || '</td>';
                    END IF;
                    v_wrow := v_wrow || '<td class="num mono" data-w="' || k || '">'
                        || CASE WHEN NVL(v_wph, 0) = 0
                                THEN '<span class="sqd-mu" title="No plan hash: a PL/SQL call, or another statement without an execution plan">&mdash;</span>'
                                ELSE TO_CHAR(v_wph)
                                     || CASE WHEN v_wchg.EXISTS(k)
                                             THEN ' <span class="badge sqd-pc" title="Plan changed in this window. The window before it with a plan ran '
                                                  || v_wchg(k) || '">plan&#8593;</span>' END
                           END
                        || '</td></tr>';
                END IF;
                DBMS_OUTPUT.PUT_LINE(v_wrow);
            END LOOP;
            -- the prior mean over every valid prior window with a row
            v_wrow := '</tbody><tfoot><tr><td>Prior mean <span class="sqd-dt">('
                || CASE WHEN v_wn = 0 THEN 'no prior window with a row'
                        ELSE v_wn || CASE WHEN v_wn = 1 THEN ' window' ELSE ' windows' END
                             || ' with a row' END
                || ')</span></td>';
            IF v_wn = 0 THEN
                v_wrow := v_wrow || '<td class="num"><span class="sqd-mu">&mdash;</span></td>'
                    || '<td class="num"><span class="sqd-mu">&mdash;</span></td>'
                    || '<td class="num"><span class="sqd-mu">&mdash;</span></td>';
            ELSE
                v_wrow := v_wrow
                    || '<td class="num"' || fmt_num_title(v_mu_x) || '>' || sqd_cnt(v_mu_x) || '</td>'
                    || '<td class="num"' || fmt_num_title(v_mu_e) || '>' || fmt_num(v_mu_e) || '</td>'
                    || '<td class="num"' || fmt_num_title(v_mu_pe) || '>' || fmt_num(v_mu_pe) || '</td>';
            END IF;
            v_wrow := v_wrow || '<td class="num"><span class="sqd-mu">&mdash;</span></td></tr></tfoot></table></div>';
            DBMS_OUTPUT.PUT_LINE(v_wrow);
            DBMS_OUTPUT.PUT_LINE('<p class="sqd-sub sqd-fn">Current vs the prior mean is a plain change, not a score: Top SQL is ranked, not scored.</p>');
            IF v_weeks_back > 29 THEN
                DBMS_OUTPUT.PUT_LINE('<p class="sqd-sub sqd-fn">Showing Current and the 29 most recent of '
                    || v_weeks_back || ' prior windows; the mean covers every valid one.</p>');
            END IF;

            -- Plan 044: Per execution, where the time went.  The Current
            -- window's row against the prior windows of the tfoot above (the
            -- same agg rows, no further read).  Modes: pe (both sides have
            -- completed executions), tot (no completed execution in Current:
            -- window totals against the prior mean per window), new (no
            -- prior window with a row), noprx (prior rows, no completed prior
            -- execution), nocur (no Current row: a note only).
            v_wk := v_sql_id || '|0';
            v_xrule := NULL; v_xrd := NULL; v_xrise := NULL;
            IF SUBSTR(v_tl_valid, 1, 1) <> 'Y' OR NOT v_wa_exec.EXISTS(v_wk) THEN
                DBMS_OUTPUT.PUT_LINE('<div class="sqx" data-sid="' || v_sql_id || '" data-sqx="nocur">'
                    || '<p class="sqd-sub sqd-fn">Where the time went: no Current row for this statement, nothing to split.</p></div>');
            ELSE
                v_xc(1) := NVL(v_wa_ela(v_wk), 0);
                v_xc(2) := NVL(v_wa_cpu(v_wk), 0);
                v_xc(3) := NVL(v_wa_io(v_wk), 0);
                v_xc(4) := NVL(v_wa_cc(v_wk), 0);
                v_xc(5) := NVL(v_wa_ap(v_wk), 0);
                v_xc(6) := NVL(v_wa_cl(v_wk), 0);
                v_xc(8) := NVL(v_wa_rows(v_wk), 0);
                v_xc(9) := NVL(v_wa_gets(v_wk), 0);
                v_xc(10) := NVL(v_wa_rds(v_wk), 0);
                FOR i IN 1 .. 10 LOOP
                    v_xp(i) := 0;
                END LOOP;
                FOR k IN 1 .. v_weeks_back LOOP
                    v_wk := v_sql_id || '|' || k;
                    IF v_wa_exec.EXISTS(v_wk) THEN
                        v_xp(1) := v_xp(1) + NVL(v_wa_ela(v_wk), 0);
                        v_xp(2) := v_xp(2) + NVL(v_wa_cpu(v_wk), 0);
                        v_xp(3) := v_xp(3) + NVL(v_wa_io(v_wk), 0);
                        v_xp(4) := v_xp(4) + NVL(v_wa_cc(v_wk), 0);
                        v_xp(5) := v_xp(5) + NVL(v_wa_ap(v_wk), 0);
                        v_xp(6) := v_xp(6) + NVL(v_wa_cl(v_wk), 0);
                        v_xp(8) := v_xp(8) + NVL(v_wa_rows(v_wk), 0);
                        v_xp(9) := v_xp(9) + NVL(v_wa_gets(v_wk), 0);
                        v_xp(10) := v_xp(10) + NVL(v_wa_rds(v_wk), 0);
                    END IF;
                END LOOP;
                -- the separate timers can overlap or leave a remainder: Other
                -- is what elapsed has beyond the five, never below 0
                v_xc(7) := GREATEST(0, v_xc(1) - v_xc(2) - v_xc(3) - v_xc(4) - v_xc(5) - v_xc(6));
                v_xp(7) := GREATEST(0, v_xp(1) - v_xp(2) - v_xp(3) - v_xp(4) - v_xp(5) - v_xp(6));
                v_wx := v_wa_exec(v_sql_id || '|0');
                v_xmode := CASE WHEN NVL(v_wx, 0) <= 0 THEN 'tot'
                                WHEN v_wn = 0 THEN 'new'
                                WHEN v_wsx <= 0 THEN 'noprx'
                                ELSE 'pe' END;
                -- the shown values: time in seconds, work as counts
                FOR i IN 1 .. 10 LOOP
                    v_xcv(i) := CASE WHEN v_xmode = 'tot' THEN v_xc(i) ELSE v_xc(i) / v_wx END
                                / CASE WHEN i <= 7 THEN 1e6 ELSE 1 END;
                    v_xmv(i) := CASE WHEN v_xmode = 'pe' THEN v_xp(i) / v_wsx
                                     WHEN v_xmode = 'tot' AND v_wn > 0 THEN v_xp(i) / v_wn
                                END / CASE WHEN i <= 7 THEN 1e6 ELSE 1 END;
                END LOOP;
                v_xcv(11) := CASE WHEN v_xcv(8) > 0 THEN v_xcv(9) / v_xcv(8) END;
                v_xmv(11) := CASE WHEN v_xmv(8) > 0 THEN v_xmv(9) / v_xmv(8) END;
                IF v_xmv(1) IS NOT NULL THEN
                    v_xrise := v_xcv(1) - v_xmv(1);
                END IF;
                -- the part with the largest share of the rise (ties: the
                -- earlier row)
                v_xbig := NULL;
                IF v_xrise > 0 THEN
                    FOR i IN 2 .. 7 LOOP
                        IF v_xbig IS NULL OR sqx_s(i) > sqx_s(v_xbig) THEN
                            v_xbig := i;
                        END IF;
                    END LOOP;
                END IF;

                -- Reads as (per execution only; thresholds at the top)
                IF v_xmode = 'pe' AND v_xmv(1) > 0 THEN
                    v_xre := v_xcv(1) / v_xmv(1);
                    v_xrr := sqx_r(8);
                    v_xgr := sqx_r(9);
                    v_xdr := sqx_r(10);
                    v_xpr := sqx_r(11);
                    v_xrf := CASE WHEN sqx_flat(v_xrr) = 'Y' OR (v_xcv(8) = 0 AND v_xmv(8) = 0)
                                  THEN 'Y' ELSE 'N' END;
                    IF v_xre >= c_sqx_gate THEN
                        IF v_xgr >= c_sqx_up AND v_xrf = 'Y'
                           AND NVL(sqx_s(2), 0) + NVL(sqx_s(3), 0) >= c_sqx_part THEN
                            v_xrule := 'harder';
                            v_xrd := 'each run read ' || sqx_x(v_xgr) || ' the buffer gets for about the same rows ('
                                || CASE WHEN v_xrr IS NULL THEN 'none either side' ELSE sqx_x(v_xrr) END
                                || '), and ' || CASE WHEN sqx_s(3) >= sqx_s(2) THEN 'I/O wait' ELSE 'CPU' END
                                || ' carries ' || sqx_pct(GREATEST(sqx_s(2), sqx_s(3)))
                                || ' of the per-run rise: it works harder for the same result, which usually points at the plan or the access path.';
                        ELSIF v_xrr >= c_sqx_up AND sqx_flat(v_xpr) = 'Y' THEN
                            v_xrule := 'data';
                            v_xrd := 'rows per run rose ' || sqx_x(v_xrr) || ' and buffer gets per run '
                                || sqx_x(v_xgr) || ', so the gets per row held: more data per call (more volume, or a wider predicate) rather than a worse plan, usually.';
                        ELSIF sqx_s(5) >= c_sqx_part THEN
                            v_xrule := 'ap';
                            v_xrd := 'application wait carries ' || sqx_pct(sqx_s(5))
                                || ' of the per-run rise: that is row-lock waits, usually, so it points at sessions blocking this one (the Blocking view names them) rather than at the statement itself.';
                        ELSIF sqx_s(4) >= c_sqx_part THEN
                            v_xrule := 'cc';
                            v_xrd := 'concurrency wait carries ' || sqx_pct(sqx_s(4))
                                || ' of the per-run rise: it points at contention (latches, mutexes, buffer busy waits) rather than at the plan.';
                        ELSIF sqx_s(6) >= c_sqx_part THEN
                            v_xrule := 'cl';
                            v_xrd := 'cluster wait carries ' || sqx_pct(sqx_s(6))
                                || ' of the per-run rise: it points at global cache transfers between RAC instances.';
                        ELSIF sqx_s(3) >= c_sqx_part AND sqx_flat(v_xgr) = 'Y' AND v_xrf = 'Y'
                              AND sqx_flat(v_xdr) = 'Y' THEN
                            v_xrule := 'slowio';
                            v_xrd := 'I/O wait carries ' || sqx_pct(sqx_s(3))
                                || ' of the per-run rise while gets, rows and physical reads per run held: each read got slower, which usually points at storage rather than at the statement.';
                        ELSIF sqx_s(3) >= c_sqx_part AND sqx_flat(v_xgr) = 'Y' AND v_xdr >= c_sqx_up THEN
                            v_xrule := 'cold';
                            v_xrd := 'I/O wait carries ' || sqx_pct(sqx_s(3))
                                || ' of the per-run rise and physical reads per run rose ' || sqx_x(v_xdr)
                                || ' on about the same gets: more of its blocks came from disk (a colder buffer cache, usually) rather than a worse plan.';
                        ELSE
                            v_xrule := 'mixed';
                            v_xrd := 'no single reading fits: the largest part of the per-run rise is '
                                || sqx_nm(v_xbig, 'Y') || ' (' || sqx_pct(sqx_s(v_xbig)) || ').';
                        END IF;
                        v_xrd := 'Each run took ' || sqx_x(v_xre) || ' as long as the prior mean; ' || v_xrd;
                    ELSIF v_xp(1) > 0 AND v_xc(1) >= c_sqx_gate * v_xp(1) / v_wn THEN
                        -- per run under the gate, the window total rose: it ran more often
                        v_xrule := 'often';
                        v_xrd := CASE WHEN sqx_flat(v_xre) = 'Y'
                                      THEN 'Each run took about as long as before (' || sqx_x(v_xre) || ' per run)'
                                      ELSE 'Per run ' || sqx_x(v_xre) || ', under the ' || sqx_x(c_sqx_gate)
                                           || ' line for a per-run reading' END
                            || '; the total rose ' || sqx_x(v_xc(1) / (v_xp(1) / v_wn))
                            || ' because it ran ' || sqx_x(v_wx / (v_wsx / v_wn)) || ' as often.';
                    END IF;
                END IF;

                DBMS_OUTPUT.PUT_LINE('<div class="sqx" data-sid="' || v_sql_id || '" data-sqx="' || v_xmode
                    || '" data-cx="' || sqx_tok(v_wx) || '" data-px="' || sqx_tok(v_wsx) || '" data-pn="' || v_wn
                    || '" data-rule="' || v_xrule || '">'
                    || '<h4 class="sqd-h">Per execution: where the time went</h4>'
                    || '<p class="sqd-sub">'
                    || CASE v_xmode
                         WHEN 'pe' THEN 'The Current window per execution against the prior mean per execution (the prior windows with a row above: their totals over their executions).'
                         WHEN 'tot' THEN 'No execution completed in the Current window (a long-running call), so these are window TOTALS: Current against the prior mean per window.'
                         WHEN 'new' THEN 'The Current window per execution; no prior window has a row for this statement (new).'
                         ELSE 'The Current window per execution; no execution completed in the prior windows with a row, so there is no prior value per execution.' END
                    || ' Ranked evidence, not scored.</p>'
                    || '<div class="sqd-tw"><table class="sqx-tbl" data-nosort data-nocount data-notools><thead><tr>'
                    || '<th title="CPU and the four waits are separate timers of DBA_HIST_SQLSTAT: they can overlap or leave a remainder, and include the time of parallel execution servers. Other = elapsed beyond the five, never below 0.">'
                    || CASE WHEN v_xmode = 'tot' THEN 'Window total' ELSE 'Per execution' END || '</th>'
                    || '<th class="num">Current</th><th class="num">Prior mean</th><th class="num">Change</th>'
                    || '<th class="num" title="The part&#39;s change over the change of elapsed: its share of the rise. The parts are separate timers, so the shares need not add up to 100%.">Share of the rise</th>'
                    || '</tr></thead><tbody>');
                FOR i IN 1 .. 11 LOOP
                    v_xrow := '<tr class="' || CASE WHEN i = 1 THEN 'sqx-e' WHEN i <= 7 THEN 'sqx-p'
                                                    WHEN i = 8 THEN 'sqx-w sqx-w1' ELSE 'sqx-w' END
                        || '" data-k="' || i || '"'
                        || CASE WHEN i <= 10 THEN ' data-xc="' || sqx_tok(v_xc(i)) || '" data-xp="' || sqx_tok(v_xp(i)) || '"' END
                        || '><td>' || sqx_nm(i) || '</td>'
                        || '<td class="num">' || fmt_num(v_xcv(i)) || '</td>'
                        || '<td class="num">' || CASE WHEN v_xmv(i) IS NULL THEN '<span class="sqd-mu">&mdash;</span>'
                                                      ELSE fmt_num(v_xmv(i)) END || '</td>'
                        || '<td class="num">'
                        || CASE WHEN v_xmode IN ('pe', 'tot', 'new') AND v_xcv(i) IS NOT NULL
                                THEN sqd_chg(v_xcv(i), v_xmv(i), v_wn, sqx_nm(i)) END
                        || '</td><td class="num">'
                        || CASE WHEN i BETWEEN 2 AND 7 THEN sqx_pct(sqx_s(i)) END
                        || '</td></tr>';
                    DBMS_OUTPUT.PUT_LINE(v_xrow);
                END LOOP;
                DBMS_OUTPUT.PUT_LINE('</tbody></table></div>'
                    || CASE WHEN v_xrd IS NOT NULL
                            THEN '<p class="sqx-rd" data-rule="' || v_xrule || '"><b>Reads as:</b> ' || v_xrd || '</p>' END
                    || '</div>');
            END IF;

            -- Per-plan summary table + timeline chart over the whole AWR
            -- retention.  Rendered whenever the statement has any SQLSTAT
            -- row.  A statement with at least one non-zero plan_hash_value
            -- keeps its plan-0 rows out (as always); one with none (a PL/SQL
            -- call) shows its plan-0 rows as a single "no plan" plan.
            IF NVL(v_total_snap, 0) > 0 THEN
                DBMS_OUTPUT.PUT_LINE('<h4 class="sqd-h">Whole AWR retention, by plan</h4>'
                    || '<p class="sqd-sub">Every snapshot AWR still holds for this statement; '
                    || 'the compared windows are marked in the chart.</p>');
                DBMS_OUTPUT.PUT_LINE('<table id="phv-summary-' || v_sql_id || '"><thead><tr>'
                    || '<th class="num" title="plan_hash_value">Plan hash</th>'
                    || '<th>First seen</th><th>Last seen</th>'
                    || '<th class="num">Snapshots</th>'
                    || '<th class="num">Executions</th>'
                    || '<th class="num">Avg s/exec</th>'
                    || '<th class="num">Avg gets/exec</th>'
                    || '</tr></thead><tbody>');
                FOR p IN (
                    SELECT st.plan_hash_value AS phv,
                           TO_CHAR(MIN(s.begin_interval_time), 'YYYY-MM-DD HH24:MI') AS first_seen,
                           TO_CHAR(MAX(s.end_interval_time),   'YYYY-MM-DD HH24:MI') AS last_seen,
                           COUNT(*)                           AS snaps,
                           SUM(NVL(st.executions_delta, 0))   AS execs,
                           SUM(NVL(st.elapsed_time_delta, 0)) AS ela_us,
                           SUM(NVL(st.buffer_gets_delta, 0))  AS gets
                    FROM   dba_hist_sqlstat st
                    JOIN   dba_hist_snapshot s
                      ON   s.dbid = st.dbid
                     AND   s.snap_id = st.snap_id
                     AND   s.instance_number = st.instance_number
                    WHERE  st.dbid   IN (~dbid_list)
                      AND  st.sql_id = v_sql_id
                      AND  (~inst_num = 0 OR st.instance_number = ~inst_num)
                      AND  (st.plan_hash_value > 0 OR NVL(v_phv_count, 0) = 0)
                    GROUP BY st.plan_hash_value
                    ORDER BY MIN(s.begin_interval_time)
                ) LOOP
                    DBMS_OUTPUT.PUT_LINE('<tr>'
                        || '<td class="num mono">'
                        || CASE WHEN NVL(p.phv, 0) = 0
                                THEN '<span class="sqd-mu" title="No plan hash: a PL/SQL call, or another statement without an execution plan">no plan</span>'
                                ELSE TO_CHAR(p.phv) END
                        || '</td>'
                        || '<td>' || p.first_seen || '</td>'
                        || '<td>' || p.last_seen  || '</td>'
                        || '<td class="num">' || fmt_int(p.snaps) || '</td>'
                        || '<td class="num">' || fmt_int(p.execs) || '</td>'
                        || '<td class="num">'
                        || CASE WHEN p.execs > 0
                                THEN fmt_num(p.ela_us / p.execs / 1e6)
                                ELSE '&mdash;' END
                        || '</td>'
                        || '<td class="num">'
                        || CASE WHEN p.execs > 0
                                THEN fmt_num(p.gets / p.execs)
                                ELSE '&mdash;' END
                        || '</td>'
                        || '</tr>');
                END LOOP;
                DBMS_OUTPUT.PUT_LINE('</tbody></table>');

                -- Timeline chart container; rendered by the ECharts init pass.
                DBMS_OUTPUT.PUT_LINE('<div class="chart-wrap chart-medium" '
                    || 'id="sqltl-' || v_sql_id || '"></div>');

                -- Snap-level points feeding the timeline chart, oldest to
                -- newest: one point per (snapshot, plan), compact form
                -- [minutes since t0, plan index, executions, seconds per
                -- execution or null].  t0 = the first point's snapshot end
                -- time (to the minute); the plan index points into the phv
                -- list emitted after the points, in order of first
                -- appearance.  Numbers use '.,' so JS parses them under any
                -- session NLS.
                v_pidx.DELETE;
                v_pn    := 0;
                v_plist := NULL;
                v_first_pt := TRUE;
                FOR r IN (
                    SELECT tm, phv, execs, ela_us,
                           ROUND((tm - MIN(tm) OVER ()) * 1440) AS mins,
                           TO_CHAR(MIN(tm) OVER (), 'YYYY-MM-DD HH24:MI') AS t0
                    FROM (
                        SELECT TRUNC(CAST(s.end_interval_time AS DATE), 'MI') AS tm,
                               st.plan_hash_value AS phv,
                               SUM(NVL(st.executions_delta, 0))   AS execs,
                               SUM(NVL(st.elapsed_time_delta, 0)) AS ela_us,
                               s.end_interval_time AS endts
                        FROM   dba_hist_sqlstat st
                        JOIN   dba_hist_snapshot s
                          ON   s.dbid = st.dbid
                         AND   s.snap_id = st.snap_id
                         AND   s.instance_number = st.instance_number
                        WHERE  st.dbid   IN (~dbid_list)
                          AND  st.sql_id = v_sql_id
                          AND  (~inst_num = 0 OR st.instance_number = ~inst_num)
                          AND  (st.plan_hash_value > 0 OR NVL(v_phv_count, 0) = 0)
                        GROUP BY s.end_interval_time, st.plan_hash_value
                    )
                    ORDER BY endts, phv
                ) LOOP
                    v_pkey := TO_CHAR(NVL(r.phv, 0));
                    IF NOT v_pidx.EXISTS(v_pkey) THEN
                        -- more plans than the payload line can name: leave
                        -- the later ones out rather than mislabel them
                        CONTINUE WHEN v_pn >= 1500;
                        v_pidx(v_pkey) := v_pn;
                        v_plist := v_plist || CASE WHEN v_pn > 0 THEN ',' END
                                   || '"' || v_pkey || '"';
                        v_pn := v_pn + 1;
                    END IF;
                    v_pi := v_pidx(v_pkey);
                    IF v_first_pt THEN
                        DBMS_OUTPUT.PUT_LINE('<script>AWR_DATA.sqlDetails["' || v_sql_id
                            || '"]={t0:"' || r.t0 || '",p:[');
                    END IF;
                    DBMS_OUTPUT.PUT_LINE(
                        CASE WHEN v_first_pt THEN '[' ELSE ',[' END
                        || TO_CHAR(r.mins, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''')
                        || ',' || v_pi
                        || ',' || TO_CHAR(NVL(r.execs, 0), 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''')
                        || ',' || CASE WHEN r.execs > 0
                                       THEN RTRIM(TO_CHAR(ROUND(LEAST(r.ela_us / r.execs / 1e6, 99999999), 6),
                                                          'FM9999999990D999999',
                                                          'NLS_NUMERIC_CHARACTERS=''.,'''), '.')
                                       ELSE 'null' END
                        || ']');
                    v_first_pt := FALSE;
                END LOOP;
                IF NOT v_first_pt THEN
                    DBMS_OUTPUT.PUT_LINE('],phv:[' || v_plist || ']};</script>');
                END IF;
            END IF;

            -- DBMS_XMLGEN.CONVERT raises ORA-19011 when the escaped text
            -- outgrows its internal buffer (667 quotes are enough), which
            -- under WHENEVER SQLERROR EXIT ends the whole report. Escaping
            -- is per character, so 500-character pieces give the same
            -- bytes and can not overflow (500 x 6 = 3000). The pieces stop
            -- before the PUT_LINE limit of 32767 bytes -- only text that is
            -- mostly quotes or angle brackets gets there -- and the note
            -- below then reports the cut.
            v_snip_esc   := NULL;
            v_snip_shown := 0;
            WHILE v_snip_shown < NVL(LENGTH(v_snip), 0) LOOP
                v_snip_part := DBMS_XMLGEN.CONVERT(SUBSTR(v_snip, v_snip_shown + 1, 500));
                EXIT WHEN NVL(LENGTHB(v_snip_esc), 0) + LENGTHB(v_snip_part) > 32000;
                v_snip_esc   := v_snip_esc || v_snip_part;
                v_snip_shown := LEAST(v_snip_shown + 500, LENGTH(v_snip));
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('<pre class="sql">'
                || v_snip_esc
                || CASE WHEN v_len > v_snip_shown
                        THEN CHR(10) || '... (truncated, ' || v_len || ' chars total)'
                        ELSE '' END
                || '</pre>');

            DBMS_OUTPUT.PUT_LINE('</td></tr>');
        END LOOP;
    END;
    DBMS_OUTPUT.PUT_LINE('</tbody></table>');
    -- C1: expander for rows beyond the first 8 (by current-window elapsed
    -- desc); a generic .expander[data-for] handler (chrome-owned) reveals
    -- every [data-tail="Y"] row in the target table's <tbody>.
    IF v_seen_sqls.COUNT > 8 THEN
        DBMS_OUTPUT.PUT_LINE('<span class="expander vw in-a" data-for="sql-pool" data-n="'
            || (v_seen_sqls.COUNT - 8) || '" data-noun="more statements">'
            || '&#9656; Show ' || (v_seen_sqls.COUNT - 8) || ' more statements</span>');
    END IF;

    -- Single ECharts init pass: render a per-SQL timeline (scatter, x=snap
    -- end time, y=s/exec, one series per PHV). Skipped silently when the
    -- ECharts CDN is unreachable; the per-PHV table still carries every
    -- number. Charts inside collapsed <details> are (re)sized when the
    -- user opens them so they don't render at 0x0.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('if(!window.echarts || !AWR_DATA.sqlDetails) return;');
    DBMS_OUTPUT.PUT_LINE('var cs=getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('var fg=cs.getPropertyValue("--fg").trim()||"#333";');
    DBMS_OUTPUT.PUT_LINE('var mu=cs.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('var palette=["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1","#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"];');
    -- Every time in this chart is the DB's wall clock, read as UTC on
    -- purpose (section 18's scatter and the Activity charts do the same): a
    -- browser-local parse breaks on a DST boundary in the reader's zone.
    -- useUTC below makes the axis print that same wall clock; the tooltip
    -- builds its text with the getUTC* methods to match.
    DBMS_OUTPUT.PUT_LINE('function ts(s){return Date.parse(String(s).replace(" ","T")+"Z");}');
    DBMS_OUTPUT.PUT_LINE('function p2(n){return n<10?"0"+n:""+n;}');
    DBMS_OUTPUT.PUT_LINE('function fmtT(t){var d=new Date(t);return d.getUTCFullYear()+"-"+p2(d.getUTCMonth()+1)+"-"+p2(d.getUTCDate())+" "+p2(d.getUTCHours())+":"+p2(d.getUTCMinutes());}');
    -- The compared windows from AWR_WIN (00): Current in the accent, prior
    -- windows a faint neutral, skipped ones not drawn.  A one-hour window is
    -- narrower than a pixel on a months-long axis, so each window's start
    -- also gets a thin line (the prior ones only up to 40 windows).  The
    -- colours are read from the CSS tokens on every call, so the theme
    -- listener can re-apply them.
    DBMS_OUTPUT.PUT_LINE('function marks(){');
    DBMS_OUTPUT.PUT_LINE('  var c=getComputedStyle(document.body),acc=c.getPropertyValue("--acc").trim()||"#5a43df",nu=c.getPropertyValue("--muted").trim()||"#888";');
    DBMS_OUTPUT.PUT_LINE('  var W=(window.AWR_WIN&&window.AWR_WIN.w)||[],many=W.length<=40,area=[],lines=[];');
    DBMS_OUTPUT.PUT_LINE('  W.forEach(function(w){');
    DBMS_OUTPUT.PUT_LINE('    if(w.v!=="Y") return;');
    DBMS_OUTPUT.PUT_LINE('    var cur=w.o===0,a=ts(w.s),b=ts(w.e);');
    DBMS_OUTPUT.PUT_LINE('    if(isNaN(a)||isNaN(b)) return;');
    DBMS_OUTPUT.PUT_LINE('    area.push([{xAxis:a,itemStyle:{color:cur?acc:nu,opacity:cur?0.3:0.12}},{xAxis:b}]);');
    DBMS_OUTPUT.PUT_LINE('    if(cur||many) lines.push({xAxis:a,lineStyle:{color:cur?acc:nu,opacity:cur?0.9:0.4,width:cur?1.5:1}});');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return {markArea:{silent:true,data:area},markLine:{silent:true,symbol:["none","none"],label:{show:false},lineStyle:{type:"solid",width:1},data:lines}};');
    DBMS_OUTPUT.PUT_LINE('}');
    -- Payload (see above): {t0:"YYYY-MM-DD HH24:MI", p:[[minutes since t0,
    -- plan index, executions, s/exec or null], ...], phv:["hash", ...]};
    -- plan "0" = a statement without a plan hash.
    DBMS_OUTPUT.PUT_LINE('function build(el,sqlId){');
    DBMS_OUTPUT.PUT_LINE('  var d=AWR_DATA.sqlDetails[sqlId]||{},P=d.p||[],phv=d.phv||[];');
    DBMS_OUTPUT.PUT_LINE('  if(!P.length||!phv.length||!d.t0) return null;');
    DBMS_OUTPUT.PUT_LINE('  var t0=ts(d.t0),data=phv.map(function(){return [];});');
    DBMS_OUTPUT.PUT_LINE('  P.forEach(function(r){if(data[r[1]]) data[r[1]].push([t0+r[0]*60000,r[3],r[2],phv[r[1]]]);});');
    DBMS_OUTPUT.PUT_LINE('  var ci=0;');
    DBMS_OUTPUT.PUT_LINE('  var series=phv.map(function(h,i){var none=h==="0";return {name:none?"no plan":"PHV "+h,type:"scatter",symbolSize:7,itemStyle:{color:none?"#9AA3AD":palette[(ci++)%palette.length]},data:data[i]};});');
    DBMS_OUTPUT.PUT_LINE('  var mk=marks(); series.push({id:"winmarks",type:"scatter",data:[],silent:true,markArea:mk.markArea,markLine:mk.markLine});');
    DBMS_OUTPUT.PUT_LINE('  var chart=echarts.init(el);');
    DBMS_OUTPUT.PUT_LINE('  chart.setOption({');
    DBMS_OUTPUT.PUT_LINE('    useUTC:true,');
    DBMS_OUTPUT.PUT_LINE('    tooltip:{trigger:"item",formatter:function(p){var v=p.value;if(!v) return "";return "<b>"+fmtT(v[0])+"</b><br/>PHV: <b>"+(v[3]==="0"?"none":v[3])+"</b><br/>s/exec: <b>"+(v[1]==null?"&mdash;":(+v[1]).toLocaleString(undefined,{maximumSignificantDigits:4}))+"</b><br/>execs: <b>"+(+v[2]).toLocaleString()+"</b>";}},');
    DBMS_OUTPUT.PUT_LINE('    legend:{type:"scroll",bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:10,itemHeight:6},');
    DBMS_OUTPUT.PUT_LINE('    grid:{left:50,right:30,top:14,bottom:48,containLabel:true},');
    DBMS_OUTPUT.PUT_LINE('    xAxis:{type:"time",axisLabel:{color:mu,fontSize:10},splitLine:{show:false}},');
    DBMS_OUTPUT.PUT_LINE('    yAxis:{type:"value",name:"s/exec",nameTextStyle:{color:mu,fontSize:10},axisLabel:{color:mu,formatter:function(v){return (+v).toLocaleString(undefined,{maximumSignificantDigits:4});}},splitLine:{lineStyle:{color:gr}}},');
    DBMS_OUTPUT.PUT_LINE('    series:series');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return chart;');
    DBMS_OUTPUT.PUT_LINE('}');
    -- C1: the chart's container lives inside a <tr class="sql-detail hidden">
    -- rather than a <details>, so there is no native "toggle" event. Register
    -- an ensure() function per SQL_ID on a shared registry that the sql-pool
    -- row-toggle delegate (below) and the hash-nav opener both call after
    -- unhiding the row (unhiding a `hidden` row still renders at 0 width
    -- until the next paint, but the ResizeObserver below catches that).
    DBMS_OUTPUT.PUT_LINE('window.AWR_sqlChartEnsure = window.AWR_sqlChartEnsure || {};');
    DBMS_OUTPUT.PUT_LINE('Object.keys(AWR_DATA.sqlDetails).forEach(function(sqlId){');
    DBMS_OUTPUT.PUT_LINE('  var el=document.getElementById("sqltl-"+sqlId); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var chart=null;');
    DBMS_OUTPUT.PUT_LINE('  var row=el.closest("tr.sql-detail");');
    DBMS_OUTPUT.PUT_LINE('  function ensure(){ if(!chart){chart=build(el,sqlId);} if(chart){chart.resize();} }');
    DBMS_OUTPUT.PUT_LINE('  window.AWR_sqlChartEnsure[sqlId]=ensure;');
    DBMS_OUTPUT.PUT_LINE('  if(row && !row.hidden) ensure();');
    DBMS_OUTPUT.PUT_LINE('  new ResizeObserver(function(){ if(chart) chart.resize(); }).observe(el);');
    -- Re-apply axis/legend colors on theme flip (F14). chart is created lazily
    -- by ensure(), so guard with if(chart) -- the closure sees the latest value.
    DBMS_OUTPUT.PUT_LINE('  document.addEventListener("awr:theme",function(){if(!chart)return;var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888",gr2=c2.getPropertyValue("--border").trim()||"#e0e0e0";');
    DBMS_OUTPUT.PUT_LINE('  var mk2=marks();');
    DBMS_OUTPUT.PUT_LINE('  chart.setOption({legend:{textStyle:{color:fg2}},xAxis:{axisLabel:{color:mu2}},yAxis:{nameTextStyle:{color:mu2},axisLabel:{color:mu2},splitLine:{lineStyle:{color:gr2}}},series:[{id:"winmarks",markArea:mk2.markArea,markLine:mk2.markLine}]});});');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- C1: delegated click handler for the sql-pool table -- toggles a
    -- summary row's paired detail row, ensures/resizes that row's chart
    -- when it becomes visible, and handles the SQL_ID copy button. One
    -- listener on the table (not per-row) since rows can number in the
    -- hundreds. Also used by openHash() below.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('var table=document.getElementById("sql-pool"); if(!table) return;');
    DBMS_OUTPUT.PUT_LINE('function openDetail(row){');
    DBMS_OUTPUT.PUT_LINE('  var det=row.nextElementSibling;');
    DBMS_OUTPUT.PUT_LINE('  if(!det || !det.classList || !det.classList.contains("sql-detail")) return;');
    DBMS_OUTPUT.PUT_LINE('  det.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('  var sid=det.getAttribute("data-sql");');
    DBMS_OUTPUT.PUT_LINE('  if(sid && window.AWR_sqlChartEnsure && window.AWR_sqlChartEnsure[sid]) setTimeout(window.AWR_sqlChartEnsure[sid],0);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('table.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var copy=ev.target.closest(".copy-btn");');
    DBMS_OUTPUT.PUT_LINE('  if(copy){');
    DBMS_OUTPUT.PUT_LINE('    ev.stopPropagation();');
    DBMS_OUTPUT.PUT_LINE('    var sel=copy.getAttribute("data-copy"), src=sel&&document.querySelector(sel);');
    DBMS_OUTPUT.PUT_LINE('    if(src && navigator.clipboard) navigator.clipboard.writeText(src.textContent||"");');
    DBMS_OUTPUT.PUT_LINE('    return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var row=ev.target.closest("tr.sql-row"); if(!row) return;');
    DBMS_OUTPUT.PUT_LINE('  var det=row.nextElementSibling;');
    DBMS_OUTPUT.PUT_LINE('  if(!det || !det.classList.contains("sql-detail")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(det.hidden) openDetail(row); else det.hidden=true;');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('window.AWR_openSqlRow=openDetail;');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- Hash navigation: SQL_IDs in the top-N tables are anchors of the form
    -- #sql-XXXXXXXXXXXXX pointing at the pool table's summary <tr>. This
    -- listener opens the matching row's detail row on initial load and on
    -- every hashchange (i.e. every click of an in-page SQL_ID link).
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('function openHash(){');
    DBMS_OUTPUT.PUT_LINE('  var h=(window.location.hash||"").split("!")[0];');
    DBMS_OUTPUT.PUT_LINE('  if(!h || h.length<2) return;');
    DBMS_OUTPUT.PUT_LINE('  var el; try{ el=document.querySelector(h); } catch(e){ return; }');
    DBMS_OUTPUT.PUT_LINE('  if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var row=(el.classList&&el.classList.contains("sql-row"))?el:(el.closest&&el.closest("tr.sql-row"));');
    DBMS_OUTPUT.PUT_LINE('  if(row){ row.hidden=false; if(window.AWR_openSqlRow) window.AWR_openSqlRow(row); }');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){ el.scrollIntoView({behavior:"smooth",block:"start"}); }, 50);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("hashchange", openHash);');
    DBMS_OUTPUT.PUT_LINE('if(window.location.hash) setTimeout(openHash, 0);');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- the evidence library's row text (Summary view)
    DBMS_OUTPUT.PUT_LINE(lib_ls('topsql', NVL(v_ls, 'no SQL captured in the compared windows'))
        || lib_news('topsql', v_news) || '</section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 06_top_sql END -->'); END;
/
