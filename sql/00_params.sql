--
-- 00_params.sql
-- Emits the page chrome (top bar, <nav> rail, chrome JS), opens <main>
-- and emits the Summary view's verdict hero (v1.6.0) and window.AWR_WIN,
-- using substitution variables already resolved by the driver.
-- No DML, no tables.
--
-- Also recomputes z-scores in-flight to produce the one-line
-- verdict sentence at the top of the Summary view. The recompute
-- mirrors the LOAD / METRIC / WAIT shape from sql/07_summary.sql:
-- per the "Findings are recomputed, not shared" convention in
-- CLAUDE.md, every consumer of findings owns its own recompute.
-- The verdict needs to be visible before section 07 runs, so we
-- duplicate the relevant query here (narrower projection -- just
-- z_score, pct_delta and n_prior per metric).
--
-- Expects these substitution variables from awr_trend.sql:
--   ~run_id               17-digit timestamp run identifier
--   dbid                 current container DBID via SYS_CONTEXT CON_DBID (int)
--   ~db_name              v$database.name (trimmed; + " / <CON_NAME>" in a PDB)
--   ~host_name            v$instance.host_name
--   ~db_version           v$instance.version
--   ~caller_user          USER
--   ~generated_at_s       'YYYY-MM-DD HH24:MI:SS TZR'
--   ~target_end_resolved  'YYYY-MM-DD HH24:MI:SS'
--   ~dow_name             trimmed day-of-week name of target_end
--   ~step_hours           cadence between adjacent windows, in hours
--   ~period_unit_long     'hour' | 'day' | 'week'
--   ~period_step_label    e.g. 'w', '2d', '6h'
--   ~win_label            compact width of one window (e.g. '15m', '1h')
--   ~step_label           compact cadence between windows (e.g. '15m', '1w')
--   ~report_path          output filename (relative)
--   ~template_name        active template name ('comprehensive', 'simple')
--   ~template_dir         path under sql/lib/templates/ for the active template
--
-- Run parameters (from defaults.sql or caller):
--   ~target_end, ~win_hours, ~weeks_back, ~top_n, ~inst_num,
--   ~step, ~step_unit, ~template
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Section boundary marker (HTML comment, invisible in browser).  Lets a
-- failed run be localized: grep the spool for the last "BEGIN" marker
-- without a matching "END" -- that section is the one that aborted.
BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 00_params BEGIN -->'); END;
/

DECLARE
    TYPE mover_rec IS RECORD (
        metric_domain VARCHAR2(16),
        metric_name   VARCHAR2(120),
        z_score       NUMBER,
        pct_delta     NUMBER,
        n_prior       NUMBER,
        change_bucket VARCHAR2(40),
        cur_val       NUMBER,
        prior_mean    NUMBER,
        family        VARCHAR2(64),
        canonical     VARCHAR2(1),
        prior_sd      NUMBER,
        shr         NUMBER
    );
    TYPE mover_t IS TABLE OF mover_rec INDEX BY PLS_INTEGER;
    TYPE seen_t  IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(64);

    v_scored     mover_t;
    v_n_moved    PLS_INTEGER := 0;   -- canonical large / moderate rows
    v_n_impr     PLS_INTEGER := 0;   -- canonical improved
    v_n_normal   PLS_INTEGER := 0;   -- canonical rows scored and not flagged
    v_n_usable   PLS_INTEGER := 0;
    v_max_n      NUMBER      := 0;
    v_n_valid    PLS_INTEGER := 0;   -- valid prior windows

    -- v1.6.0 verdict: one finding CARD per card group of metric_policy
    -- families (sql/lib/finding_cards.plsql card_group); g_* are indexed by
    -- the group key, v_order holds the groups in card order.
    v_glead      seen_t;        -- group -> index (v_scored) of its lead row
    v_gsev       seen_t;        -- group -> 2 large / 1 moderate
    TYPE gz_t    IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
    v_gz         gz_t;          -- group -> largest |z| of any member
    TYPE ord_t   IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;
    v_order      ord_t;
    v_g          VARCHAR2(64);
    v_tmp        VARCHAR2(64);
    v_j          PLS_INTEGER;
    v_dbt        PLS_INTEGER;   -- index of the LOAD 'DB time' row
    v_cpu        PLS_INTEGER;   -- index of the LOAD 'DB CPU' row
    v_verdict    VARCHAR2(32767);
    v_win_json   VARCHAR2(32767);   -- window validity flags, |k=Y|k=N|...
    -- Subprogram includes go LAST: PL/SQL forbids a variable / TYPE
    -- declaration after a subprogram in the same DECLARE section.
    @@sql/lib/metric_policy.plsql
    @@sql/lib/fmt_num.plsql
    @@sql/lib/anchor_id.plsql
    @@sql/lib/finding_cards.plsql
    @@sql/lib/off_label.plsql
    @@sql/lib/wingrid.plsql
BEGIN
    --
    -- Recompute LOAD / METRIC / WAIT z-scores. Same query shape as
    -- sql/07_summary.sql, just a narrower projection (we only need
    -- z_score, pct_delta, n_prior). Ordered by |z| DESC so the first
    -- usable rows are the top movers; we walk in PL/SQL to count
    -- movers above |z| > 2 and slice the first 3.
    --
    WITH
    @@sql/lib/windows_cte.sql
    ,
    load_targets AS (
        @@~template_dir/sysstat_load_targets.sql
    ),
    -- SYSSTAT counters, with DB time / DB CPU from the time model
    @@sql/lib/load_pairs_cte.sql
    ,
    load_bounds AS (
        SELECT week_offset, dur_sec, stat_name, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN value END) AS beg_val,
               SUM(CASE WHEN snap_id = end_snap_id   THEN value END) AS end_val
        FROM   load_pairs
        GROUP BY week_offset, dur_sec, stat_name, instance_number
    ),
    load_rows AS (
        -- Cross-instance delta over ONE window span (MAX(dur_sec)); dur_sec out
        -- of the GROUP BY so per-instance resolved-span jitter can't split a RAC
        -- week.  Single-instance byte-identical (dur_sec constant).  Mirrors 07.
        SELECT 'LOAD' AS metric_domain,
               stat_name AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_val, 0) - NVL(beg_val, 0)) / MAX(dur_sec)
               END AS metric_value
        FROM   load_bounds
        GROUP BY week_offset, stat_name
    ),
    metric_targets AS (
        @@~template_dir/sysmetric_targets.sql
    ),
    metric_per_snap AS (
        SELECT w.week_offset, t.metric_name, sm.snap_id,
               t.is_additive,
               CASE WHEN t.is_additive = 'Y' THEN SUM(sm.average)
                                             ELSE AVG(sm.average) END AS snap_value
        FROM   valid_windows w
        JOIN   metric_targets t ON 1 = 1
        JOIN   dba_hist_sysmetric_summary sm
            ON sm.dbid = w.dbid
           AND sm.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id
           AND sm.instance_number = w.instance_number
           AND sm.metric_name = t.metric_name
        GROUP BY w.week_offset, t.metric_name, t.is_additive, sm.snap_id
    ),
    metric_rows AS (
        SELECT 'METRIC' AS metric_domain,
               metric_name,
               week_offset,
               AVG(snap_value) AS metric_value
        FROM   metric_per_snap
        GROUP BY week_offset, metric_name
    ),
    -- The template's wait-event allow-list, with the same idiom as 07's
    -- wait_pairs: the verdict names the lead of 07's finding cards and its
    -- pills print 07's counts, so both must sum the SAME events.  The
    -- comprehensive template's '*' sentinel keeps every non-idle event.
    wait_targets AS (
        @@~template_dir/wait_event_targets.sql
    ),
    wait_pairs AS (
        SELECT w.week_offset, w.dur_sec,
               se.wait_class,
               se.snap_id,
               se.time_waited_micro,
               se.instance_number,
               w.begin_snap_id, w.end_snap_id
        FROM   valid_windows w
        JOIN   dba_hist_system_event se
            ON se.dbid = w.dbid
           AND se.snap_id IN (w.begin_snap_id, w.end_snap_id)
           AND se.instance_number = w.instance_number
           AND se.wait_class <> 'Idle'
           AND ( EXISTS (SELECT 1 FROM wait_targets WHERE event_name = '*')
                 OR se.event_name IN (SELECT event_name FROM wait_targets) )
    ),
    wait_bounds AS (
        SELECT week_offset, dur_sec, wait_class, instance_number,
               SUM(CASE WHEN snap_id = begin_snap_id THEN time_waited_micro END) AS beg_us,
               SUM(CASE WHEN snap_id = end_snap_id   THEN time_waited_micro END) AS end_us
        FROM   wait_pairs
        GROUP BY week_offset, dur_sec, wait_class, instance_number
    ),
    wait_rows AS (
        -- Same single-span divisor as load_rows; MAX(dur_sec), dur_sec dropped
        -- from the GROUP BY.
        SELECT 'WAIT' AS metric_domain,
               'Wait class: ' || wait_class AS metric_name,
               week_offset,
               CASE WHEN MAX(dur_sec) > 0
                    THEN SUM(NVL(end_us, 0) - NVL(beg_us, 0)) / MAX(dur_sec) / 1e6
               END AS metric_value
        FROM   wait_bounds
        GROUP BY week_offset, wait_class
    ),
    unified AS (
        SELECT * FROM load_rows   WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM metric_rows WHERE metric_value IS NOT NULL
        UNION ALL
        SELECT * FROM wait_rows   WHERE metric_value IS NOT NULL
    ),
    pivoted AS (
        SELECT metric_domain, metric_name,
               MAX(CASE WHEN week_offset = 0 THEN metric_value END)    AS cur_val,
               AVG(CASE WHEN week_offset > 0 THEN metric_value END)    AS mu,
               STDDEV(CASE WHEN week_offset > 0 THEN metric_value END) AS sd,
               COUNT(CASE WHEN week_offset > 0 THEN metric_value END)  AS n
        FROM   unified
        GROUP BY metric_domain, metric_name
    ),
    -- Same sigma floor + materiality rule as sql/07_summary.sql (kept in
    -- sync by inspection): z over max(sd, 2% of |mu|); large / moderate
    -- only when |pct| >= 10 and, for wait classes, share of the Current
    -- window's total wait >= 2%.
    wait_total AS (
        SELECT SUM(metric_value) AS tot
        FROM   wait_rows
        WHERE  week_offset = 0
    ),
    measured AS (
        SELECT p.metric_domain, p.metric_name, p.cur_val, p.mu, p.sd, p.n,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.sd IS NULL THEN NULL
                   WHEN p.n < 3 THEN NULL
                   WHEN GREATEST(p.sd, 0.02 * ABS(p.mu)) = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / GREATEST(p.sd, 0.02 * ABS(p.mu))
               END AS z_score,
               CASE
                   WHEN p.cur_val IS NULL OR p.mu IS NULL OR p.mu = 0 THEN NULL
                   ELSE (p.cur_val - p.mu) / ABS(p.mu) * 100
               END AS pct_delta,
               CASE
                   WHEN p.metric_domain = 'WAIT' AND t.tot > 0 THEN p.cur_val / t.tot
               END AS shr
        FROM   pivoted p
        CROSS JOIN wait_total t
    ),
    scored AS (
        -- the bucket is assigned by policy_bucket() in the PL/SQL pass
        -- below (per-metric direction and floors, sql/lib/metric_policy.plsql)
        SELECT metric_domain, metric_name, z_score, pct_delta,
               n AS n_prior,
               CAST(NULL AS VARCHAR2(40)) AS change_bucket,
               cur_val, mu AS prior_mean, sd AS prior_sd, shr
        FROM   measured
        WHERE  cur_val IS NOT NULL OR mu IS NOT NULL
    )
    SELECT metric_domain, metric_name, z_score, pct_delta, n_prior,
           change_bucket, cur_val, prior_mean,
           CAST(NULL AS VARCHAR2(64)) AS family,
           CAST(NULL AS VARCHAR2(1))  AS canonical,
           prior_sd, shr
    BULK COLLECT INTO v_scored
    FROM   scored
    ORDER  BY ABS(NVL(z_score, 0)) DESC, metric_name;

    -- Single pass: per-metric policy (family / canonical) and the change
    -- bucket per row; counts (canonical rows only: large / moderate =
    -- "metrics moved", improved apart, scored-and-not-flagged = "normal");
    -- max n_prior; and, per finding CARD (a card group of metric_policy
    -- families, sql/lib/finding_cards.plsql), its lead row, its severity
    -- and its loudest |z| -- the same grouping section 07 draws as cards.
    FOR i IN 1 .. v_scored.COUNT LOOP
      DECLARE
        -- policy_rec lives in the include, which also declares functions,
        -- so a variable of that type can only be declared in a nested block.
        v_pol policy_rec;
      BEGIN
        v_pol := metric_policy(v_scored(i).metric_domain, v_scored(i).metric_name);
        v_scored(i).family    := finding_family(v_scored(i).metric_domain, v_scored(i).metric_name);
        v_scored(i).canonical := v_pol.canonical;
      END;
        v_scored(i).change_bucket :=
            policy_bucket(v_scored(i).metric_domain, v_scored(i).metric_name, NULL,
                          v_scored(i).cur_val, v_scored(i).prior_mean,
                          v_scored(i).prior_sd, v_scored(i).n_prior, v_scored(i).shr);
        IF NVL(v_scored(i).n_prior, 0) > v_max_n THEN
            v_max_n := v_scored(i).n_prior;
        END IF;
        IF v_scored(i).metric_domain = 'LOAD' AND v_scored(i).metric_name = 'DB time' THEN
            v_dbt := i;
        ELSIF v_scored(i).metric_domain = 'LOAD' AND v_scored(i).metric_name = 'DB CPU' THEN
            v_cpu := i;
        END IF;
        IF v_scored(i).z_score IS NOT NULL THEN
            v_n_usable := v_n_usable + 1;
        END IF;
        IF v_scored(i).canonical = 'Y' THEN
            IF v_scored(i).change_bucket IN ('large', 'moderate') THEN
                v_n_moved := v_n_moved + 1;
                v_g := card_group(v_scored(i).family);
                IF NOT v_glead.EXISTS(v_g) THEN
                    v_glead(v_g) := i;
                    v_gsev(v_g)  := 0;
                    v_gz(v_g)    := 0;
                ELSIF lead_better(v_g, v_scored(i).change_bucket, v_scored(i).family, v_scored(i).z_score,
                                  v_scored(v_glead(v_g)).change_bucket, v_scored(v_glead(v_g)).family,
                                  v_scored(v_glead(v_g)).z_score,
                                  metric_label(v_scored(i).metric_domain, v_scored(i).metric_name),
                                  metric_label(v_scored(v_glead(v_g)).metric_domain,
                                               v_scored(v_glead(v_g)).metric_name)) THEN
                    v_glead(v_g) := i;
                END IF;
                v_gsev(v_g) := GREATEST(v_gsev(v_g), sev_rank(v_scored(i).change_bucket));
                v_gz(v_g)   := GREATEST(v_gz(v_g), ABS(NVL(v_scored(i).z_score, 0)));
            ELSIF v_scored(i).change_bucket IN ('typical', 'improved', 'noted', 'flat baseline') THEN
                v_n_normal := v_n_normal + 1;
                IF v_scored(i).change_bucket = 'improved' THEN
                    v_n_impr := v_n_impr + 1;
                END IF;
            END IF;
        END IF;
    END LOOP;

    -- Card order (same two steps as 07): large before moderate, then the
    -- loudest |z| (insertion sort); then a flagged DB time card moves up
    -- to second place.
    v_g := v_glead.FIRST;
    WHILE v_g IS NOT NULL LOOP
        v_j := v_order.COUNT;
        WHILE v_j >= 1 AND card_before(v_gsev(v_g), v_gz(v_g), v_gsev(v_order(v_j)), v_gz(v_order(v_j))) LOOP
            v_order(v_j + 1) := v_order(v_j);
            v_j := v_j - 1;
        END LOOP;
        v_order(v_j + 1) := v_g;
        v_g := v_glead.NEXT(v_g);
    END LOOP;
    FOR k IN 3 .. v_order.COUNT LOOP
        IF v_order(k) = 'DBTIME' THEN
            FOR m IN REVERSE 3 .. k LOOP
                v_tmp := v_order(m); v_order(m) := v_order(m - 1); v_order(m - 1) := v_tmp;
            END LOOP;
            EXIT;
        END IF;
    END LOOP;

    -- The compared windows' validity ('|k=Y|k=N|...') for window.AWR_WIN
    -- (emitted after <main> opens, below) and the valid-prior count.
    FOR r IN (
        WITH
        @@sql/lib/windows_cte.sql
        SELECT week_offset, valid_flag FROM windows_rollup
    ) LOOP
        v_win_json := v_win_json || '|' || r.week_offset || '=' || r.valid_flag;
        IF r.week_offset > 0 AND r.valid_flag = 'Y' THEN
            v_n_valid := v_n_valid + 1;
        END IF;
    END LOOP;

    -- =========================================================
    -- Page chrome before <main>: theme, view, top bar, rail
    -- =========================================================
    -- Early theme script: must run before any chart initializes (charts
    -- read --accent/--muted via getComputedStyle at init) so they pick up
    -- the correct palette at first paint.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){try{var s=localStorage.getItem("awr-theme");var d=s?s==="dark":(window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches);if(d)document.body.classList.add("dark");}catch(e){}})();</script>');
    -- Views (v1.6.0): Summary (default) / Timeline / All sections.  One
    -- of body.vs / body.vt / body.va (+ data-view) is set before first
    -- paint: a "#view=summary|timeline|all" hash wins, else localStorage
    -- "awr-view" (written only on an explicit click), else Summary.  A
    -- v1.5.0 shared link's "!v=f" (Full) opens All sections.  With JS off
    -- no class exists and the CSS shows everything stacked.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){var v="summary",h=location.hash||"",m,i;try{var s=localStorage.getItem("awr-view");if(s==="timeline"||s==="all")v=s;}catch(e){}m=/view=(summary|timeline|all)/.exec(h);if(m)v=m[1];else{i=h.indexOf("!v=");if(i>=0&&h.slice(i+3).split("&")[0].split(",").indexOf("f")>=0)v="all";}document.body.classList.add({summary:"vs",timeline:"vt",all:"va"}[v]);document.body.setAttribute("data-view",v);})();</script>');
    -- Phase 4: skip link (visible on keyboard focus only) to the <main>
    -- landmark that opens right after this section's scripts and closes
    -- in the driver's epilogue, just before the footer.
    -- v1.6.0 evidence library: window.AWR_ls(id, html) puts a section's
    -- one-line status (span.ls, "27 counters per second") into its h2,
    -- the row text of the Summary view's library.  Each library section
    -- calls it from an inline script once it knows its numbers.
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_ls=function(id,h){var s=document.getElementById(id),t=s&&s.querySelector("h2");if(!t)return;var e=t.querySelector(".ls");if(!e){e=document.createElement("span");e.className="ls";t.insertBefore(e,t.querySelector(".h2sub,.meta"));}e.innerHTML=h;};</script>');
    DBMS_OUTPUT.PUT_LINE('<a class="skip" href="#main-start">Skip to report</a>');
    -- v1.6.0 top bar (sticky): who / which window / the view switch / the
    -- theme toggle.  The Current chip is the page's one indigo accent.
    DBMS_OUTPUT.PUT_LINE('<div class="topbar" id="topbar">'
        || '<div class="db"><b>' || DBMS_XMLGEN.CONVERT('~db_name') || '</b>'
        || '<span>' || DBMS_XMLGEN.CONVERT('~host_name') || ' &middot; '
        || DBMS_XMLGEN.CONVERT('~db_version') || ' &middot; DBID ' || TRIM('~dbid')
        -- A report spanning more than one DBID (non-CDB -> PDB migration: a
        -- comma in dbid_list) names the full set; single-DBID emits nothing.
        || CASE WHEN INSTR('~dbid_list', ',') > 0
                THEN ' &middot; all DBIDs ' || REPLACE('~dbid_list', ',', ', ')
                ELSE '' END
        || '</span></div>'
        || '<div class="win"><span class="cchip">Current</span><b>'
        || TO_CHAR(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS') - ~win_hours/24,
                   'Dy DD Mon, HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH')
        || '&ndash;'
        || TO_CHAR(TO_DATE('~target_end_resolved', 'YYYY-MM-DD HH24:MI:SS'), 'HH24:MI')
        || '</b><span>vs ' || TO_CHAR(~weeks_back) || ' prior window'
        || CASE WHEN ~weeks_back = 1 THEN '' ELSE 's' END
        || ', every ~step_label'
        -- A curated template names itself, so reports can be told apart
        -- at a glance (the v1.5.0 windows strip carried the same note).
        || CASE WHEN '~template_name' = 'comprehensive' THEN ''
                ELSE ' &middot; template <code>' || DBMS_XMLGEN.CONVERT('~template_name') || '</code>'
           END
        || '</span></div>'
        || '<span class="sp"></span>'
        || '<div class="seg" role="group" aria-label="View">'
        || '<button type="button" data-v="summary" aria-pressed="true"'
        || ' title="The answer: verdict, finding cards, what changed, checked and normal">Summary</button>'
        || '<button type="button" data-v="timeline" aria-pressed="false"'
        || ' title="The compared windows side by side">Timeline</button>'
        || '<button type="button" data-v="all" aria-pressed="false"'
        || ' title="Every section and every scored row">All sections</button>'
        || '</div>'
        -- Dark mode toggle: flips body.dark, which (via _style.sql) swaps
        -- every color token to the dark palette.  Both icons ship inline;
        -- CSS shows only the one for the mode you would switch TO.
        || '<button type="button" id="theme-toggle" class="theme-icon-btn"'
        || ' aria-pressed="false"'
        || ' aria-label="Toggle dark mode"'
        || ' title="Switch between light and dark color theme">'
        || '<svg class="icon-sun" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">'
        || '<circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/>'
        || '<path d="M12 2.5v3M12 18.5v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1'
        || 'M2.5 12h3M18.5 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"'
        || ' stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
        || '</svg>'
        || '<svg class="icon-moon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">'
        || '<path d="M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5a8.5 8.5 0 1 0 11.2 11.2z" fill="currentColor"/>'
        || '</svg>'
        || '</button>'
        || '</div>');
    -- v1.6.0: the v1.5.0 masthead (header.report: brand line, headline,
    -- run metadata, verdict banner, all-movers list, compared-windows
    -- strip and its full-span DB-time chart) is retired.  The verdict hero
    -- opens <main> below; the run metadata lives in the top bar, the About
    -- fold (19) and the footer; the full-span DB time is section 10 and
    -- the compared windows are section 01 (All sections).

    -- =========================================================
    -- Sticky table-of-contents nav. Same anchor IDs the dense
    -- design used; numerals match the per-section h2::before
    -- counters in _style.sql.
    -- =========================================================
    -- Grouped to match the visual section order set in _style.sql
    -- (Triage / Workload / SQL / Storage and config), so the scrollspy
    -- walks the rail top-to-bottom.  The hrefs are load-bearing: the
    -- view dimming (railViews, .vdim) resolves each link's target.
    DBMS_OUTPUT.PUT_LINE('<nav class="toc">'
        || '<div class="rail-brand"><span>AWR &middot; Timeline comparison</span>'
        || '</div>'
        -- B8 (narrow layout only, display:none on desktop): the current
        -- section name, kept in sync by the scrollspy, plus the hamburger
        -- that drops nav.toc .rail-list down as a panel.
        || '<span class="rail-cur"></span>'
        || '<button type="button" class="rail-menu-btn" id="rail-menu-btn"'
        || ' aria-expanded="false" aria-label="Show section list">&#9776;</button>'
        -- T4: row filter.  Narrows every section table to the rows whose
        -- first two cells match; Cmd/Ctrl-K focuses it, Esc clears it.
        || '<div class="rail-filter">'
        || '<input type="text" id="row-filter" autocomplete="off"'
        || ' placeholder="Filter rows&#8230;"'
        || ' aria-label="Filter table rows across the report">'
        || '<span class="kbd">&#8984;K</span>'
        || '</div>'
        -- The section links live in .rail-list so the narrow layout can
        -- turn them into a dropdown.  Every existing selector that targets
        -- them (nav.toc a / nav.toc b, the rail JS)
        -- is a descendant match, so desktop rendering is unchanged.
        || '<div class="rail-list">'
        -- v1.6.0: the Activity charts sit at the top of every view
        || '<b>Overview</b>'
        || '<a href="#activity" data-nodot>Activity, whole span</a>'
        -- v1.6.0 Summary view: the verdict hero, the finding cards, what
        -- changed around them (12 relocates its card there and unhides the
        -- link) and the checked-and-normal grid.
        || '<b>Summary</b>'
        || '<a href="#verdict" data-nodot>Verdict</a>'
        || '<a href="#findings">Findings</a>'
        || '<a href="#s-changes" data-nodot hidden>What changed around it</a>'
        || '<a href="#s-normal" data-nodot>Checked and normal</a>'
        -- the evidence library (every other section, one row each); 07
        -- adds one sub-link per finding card under Findings
        || '<a href="#s-lib" data-nodot>Evidence library</a>'
        -- v1.6.0: the Timeline view -- the grid's lanes (a lane with no
        -- rows hides its link, js_timeline); dimmed in the other views
        -- like every out-of-view link.
        || '<b>Timeline</b>'
        || '<a href="#lane-activity" data-nodot>Activity</a>'
        || '<a href="#lane-metrics">Headline and load</a>'
        || '<a href="#lane-waits">Waits</a>'
        || '<a href="#lane-objects" data-nodot>Where the reads land</a>'
        || '<a href="#lane-sql">SQL</a>'
        || '<a href="#lane-config" data-nodot>Configuration</a>'
        -- The All sections view's order (_style.sql "All sections order"):
        -- load and waits, SQL, storage and config, then the whole span.
        || '<b>Workload</b>'
        || '<a href="#load">Load profile</a>'
        || '<a href="#metrics">Metrics</a>'
        || '<a href="#waits-fg">Waits &mdash; foreground</a>'
        || '<a href="#waits-bg">Waits &mdash; background</a>'
        || '<b>SQL</b>'
        || '<a href="#topsql">Top SQL</a>'
        || '<a href="#topsql-ash">Top SQL &mdash; ASH</a>'
        || '<a href="#sqlmon">SQL Monitor</a>'
        || '<b>Storage &amp; config</b>'
        || '<a href="#segment-io">Segment I/O</a>'
        || '<a href="#file-io">File I/O</a>'
        || '<a href="#param-changes">Parameters</a>'
        || '<b>Whole span</b>'
        || '<a href="#ash-timeline">ASH timeline</a>'
        || '<a href="#db-time-summary">DB time</a>'
        || '<a href="#utilization">Utilization</a>'
        || '<a href="#windows">Windows</a>'
        -- Day profile link only when the section exists (profile_days > 0);
        -- '' otherwise keeps the nav byte-identical.
        || CASE WHEN ~profile_days > 0
                THEN '<a href="#day-profile">Day profile</a>' ELSE '' END
        -- Shown in every view (sql/19_reference.sql).
        || '<b id="rail-ref">Reference</b>'
        || '<a href="#guide" data-nodot>Reading the charts</a>'
        || '<a href="#about" data-nodot>About this report</a>'
        || '</div>'
        || '<div class="rail-foot">'
        -- Narrow-screen "View" button: opens .view-panel (next-finding)
        -- as a popover; display:none on desktop, where .view-panel is
        -- display:contents.  (The view switch lives in the top bar.)
        || '<button type="button" class="view-btn" id="view-btn"'
        || ' aria-expanded="false" aria-controls="view-panel"'
        || ' title="Report view options">View &#9662;</button>'
        || '<div class="view-panel" id="view-panel">'
        -- C2: jump to the next crit finding (J / K also work from anywhere
        -- outside a text field).
        || '<button type="button" id="next-finding" class="next-finding"'
        || ' title="Jump to the next large (critical) finding">'
        || '<span>&darr; next large finding</span>'
        || '<span class="keys">J K</span>'
        || '</button>'
        || '</div>'
        || '</div>'
        || '</nav>');

    -- Wire the dark-mode toggle. The early theme script (before
    -- header.report) already applied body.dark from localStorage/OS
    -- preference at load; this just syncs the button state and persists
    -- future clicks. Icon visibility (sun vs moon) is pure CSS off
    -- body.dark, so there's no label/markup to swap here.
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('var btn=document.getElementById("theme-toggle"); if(!btn) return;');
    DBMS_OUTPUT.PUT_LINE('function sync(on){btn.setAttribute("aria-pressed",on?"true":"false");}');
    DBMS_OUTPUT.PUT_LINE('sync(document.body.classList.contains("dark"));');
    DBMS_OUTPUT.PUT_LINE('btn.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('  var on=document.body.classList.toggle("dark");');
    DBMS_OUTPUT.PUT_LINE('  try{localStorage.setItem("awr-theme",on?"dark":"light");}catch(e){}');
    DBMS_OUTPUT.PUT_LINE('  sync(on);');
    -- ECharts read their axis/label colors from the CSS vars once at init, so
    -- a theme flip leaves every chart on the old palette.  Broadcast awr:theme
    -- (a document-level CustomEvent); each chart-init listens and re-applies its
    -- var-derived colors via setOption (F14).
    DBMS_OUTPUT.PUT_LINE('  document.dispatchEvent(new CustomEvent("awr:theme",{detail:{dark:on}}));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('})();</script>');

    -- Live status rail. Runs on DOMContentLoaded because this script is
    -- emitted before the data sections exist in the DOM.  Two jobs:
    --   1. Status dots: prepend a span.st to every rail link, graded from
    --      the severity classes the target section already carries in its
    --      HTML (worst wins: .crit > .warn > ok; td.chg counts as warn so
    --      changed parameters surface).  Sections whose only rows are
    --      skip/insufficient stay "na" (neutral dot).  Pure client-side --
    --      no extra SQL pass, and the dots always agree with the tables.
    --   2. Scrollspy: highlight the rail link of the last section whose
    --      top has passed the upper quarter of the viewport.  A plain
    --      throttled scroll listener, NOT IntersectionObserver or
    --      requestAnimationFrame: embedded webviews (and the Claude
    --      preview browser) throttle both to a standstill, and at 16
    --      sections the scan is trivially cheap.  Sections hidden by the
    --      Normal view (offsetParent null) are skipped.
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("DOMContentLoaded",function(){');
    DBMS_OUTPUT.PUT_LINE('var nav=document.querySelector("nav.toc"); if(!nav) return;');
    DBMS_OUTPUT.PUT_LINE('var pairs=[];');
    DBMS_OUTPUT.PUT_LINE('nav.querySelectorAll(''a[href^="#"]'').forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('  var sec=document.getElementById(a.getAttribute("href").slice(1));');
    DBMS_OUTPUT.PUT_LINE('  if(!sec) return;');
    -- Capture the pristine link label BEFORE the status dot and the C2
    -- count pills are appended; the narrow-screen top bar (B8) shows it as
    -- the current-section name.
    DBMS_OUTPUT.PUT_LINE('  a.setAttribute("data-label",(a.textContent||"").trim());');
    DBMS_OUTPUT.PUT_LINE('  pairs.push([a,sec]);');
    DBMS_OUTPUT.PUT_LINE('  if(a.hasAttribute("data-nodot")) return;');
    DBMS_OUTPUT.PUT_LINE('  var dot=document.createElement("span"); dot.className="st";');
    -- skip/insufficient rows don't count as data: a findings table made
    -- entirely of INSUFFICIENT_HISTORY rows keeps the neutral dot.
    DBMS_OUTPUT.PUT_LINE('  if(sec.querySelector(".crit, .bd.s-large")) dot.className+=" crit";');
    DBMS_OUTPUT.PUT_LINE('  else if(sec.querySelector(".warn, td.chg, .bd.s-moderate")) dot.className+=" warn";');
    DBMS_OUTPUT.PUT_LINE('  else if(sec.querySelector("tbody tr:not(.skip) td, .ash-sql-card:not(.insufficient)")) dot.className+=" ok";');
    DBMS_OUTPUT.PUT_LINE('  a.insertBefore(dot,a.firstChild);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var pending=false;');
    DBMS_OUTPUT.PUT_LINE('function spy(){');
    DBMS_OUTPUT.PUT_LINE('  pending=false;');
    DBMS_OUTPUT.PUT_LINE('  var y=window.scrollY+window.innerHeight*0.25;');
    DBMS_OUTPUT.PUT_LINE('  var best=null, bestTop=-1, firstVis=null;');
    DBMS_OUTPUT.PUT_LINE('  pairs.forEach(function(p){');
    DBMS_OUTPUT.PUT_LINE('    if(p[1].offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    if(!firstVis) firstVis=p;');
    DBMS_OUTPUT.PUT_LINE('    var t=p[1].offsetTop;');
    DBMS_OUTPUT.PUT_LINE('    if(t<=y && t>bestTop){ best=p; bestTop=t; }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(!best) best=firstVis;');
    DBMS_OUTPUT.PUT_LINE('  pairs.forEach(function(p){ p[0].classList.toggle("on",p===best); });');
    -- B8: mirror the active section name into the narrow-screen top bar.
    DBMS_OUTPUT.PUT_LINE('  var cur=nav.querySelector(".rail-cur");');
    DBMS_OUTPUT.PUT_LINE('  if(cur) cur.textContent=best?(best[0].getAttribute("data-label")||""):"";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function onScroll(){ if(!pending){ pending=true; setTimeout(spy,80); } }');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("scroll",onScroll,{passive:true});');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",onScroll);');
    -- Fallback for embedded webviews that suppress scroll events
    -- entirely (observed in in-app preview browsers): poll scrollY and
    -- re-run the spy only when it actually changed.  One number
    -- comparison per 400ms; the scroll listener above still gives
    -- instant updates in normal browsers.
    DBMS_OUTPUT.PUT_LINE('var lastY=-1;');
    DBMS_OUTPUT.PUT_LINE('setInterval(function(){');
    DBMS_OUTPUT.PUT_LINE('  if(window.scrollY!==lastY){ lastY=window.scrollY; spy(); }');
    DBMS_OUTPUT.PUT_LINE('},400);');
    DBMS_OUTPUT.PUT_LINE('spy();');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('</script>');

    -- =========================================================
    -- Report chrome: the page-level JS half of the facelift hook
    -- contract.  Everything here is delegated / injected at
    -- DOMContentLoaded (this script is emitted before the data
    -- sections exist), CDN-free, and degrades to a plain readable
    -- report when it does not run.  What it wires up:
    --   T1  .expander[data-for] toggles .open on its table
    --       (tr[data-tail="Y"] rows are CSS-hidden until then)
    --   T2  --navh so the sticky thead clears the sticky top bar
    --   T3  click-to-sort on section table thead th (data-nosort
    --       opts out; th[data-w] drives the window highlight instead)
    --   T4  #row-filter narrows every table by its first two cells
    --   H1  the uniform section header: crit / warn counts (span.meta)
    --       appended to every section h2
    --   C1  .tabs[data-tabs] / .tabpanel switching (+ ECharts resize)
    --   C2  crit/warn count pills on the rail links, J / K jumping
    --   C4  copy buttons: .copy-btn, per-table CSV / MD toolbars,
    --       the h2 permalink anchor
    --   X2  window highlight: click a th[data-w] or a masthead
    --       .wchip to toggle .hl on every [data-w] element and
    --       broadcast the awr:window CustomEvent for chart sections
    --   V1  the Summary / Timeline / All sections views (body.vs / vt /
    --       va): the top-bar switch, rail dimming, goTo / reveal for
    --       every in-page link (view switch, details, tabs, folded rows,
    --       scroll, flash) and the same for a #hash on load
    --   B8  the narrow-screen hamburger dropdown
    -- No literal tilde anywhere below: this file runs under
    -- SET DEFINE tilde (see the CLAUDE.md tilde gotcha).
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener("DOMContentLoaded",function(){');
    DBMS_OUTPUT.PUT_LINE('var doc=document, bd=doc.body, nav=doc.querySelector("nav.toc");');
    DBMS_OUTPUT.PUT_LINE('function closest(t,sel){return (t&&t.closest)?t.closest(sel):null;}');
    DBMS_OUTPUT.PUT_LINE('function cellText(td){');
    DBMS_OUTPUT.PUT_LINE('  var c=td.cloneNode(true);');
    DBMS_OUTPUT.PUT_LINE('  c.querySelectorAll("svg").forEach(function(s){s.parentNode.removeChild(s);});');
    DBMS_OUTPUT.PUT_LINE('  return (c.textContent||"").replace(/\s+/g," ").trim();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- clipboard (async API, hidden-textarea fallback) ---- */');
    DBMS_OUTPUT.PUT_LINE('function paste(s){');
    DBMS_OUTPUT.PUT_LINE('  try{');
    DBMS_OUTPUT.PUT_LINE('    var ta=doc.createElement("textarea");');
    DBMS_OUTPUT.PUT_LINE('    ta.value=s; ta.setAttribute("readonly","");');
    DBMS_OUTPUT.PUT_LINE('    ta.style.position="fixed"; ta.style.top="-1000px"; ta.style.opacity="0";');
    DBMS_OUTPUT.PUT_LINE('    bd.appendChild(ta); ta.select(); doc.execCommand("copy"); bd.removeChild(ta);');
    DBMS_OUTPUT.PUT_LINE('  }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function flash(el,done){');
    DBMS_OUTPUT.PUT_LINE('  if(!el||el.getAttribute("data-busy")) return;');
    DBMS_OUTPUT.PUT_LINE('  var old=el.textContent;');
    DBMS_OUTPUT.PUT_LINE('  el.setAttribute("data-busy","1");');
    DBMS_OUTPUT.PUT_LINE('  el.textContent=done||"Copied";');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){el.textContent=old;el.removeAttribute("data-busy");},1200);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function copyText(s,el,done){');
    DBMS_OUTPUT.PUT_LINE('  var ok=function(){flash(el,done);};');
    DBMS_OUTPUT.PUT_LINE('  try{');
    DBMS_OUTPUT.PUT_LINE('    if(navigator.clipboard&&navigator.clipboard.writeText){');
    DBMS_OUTPUT.PUT_LINE('      navigator.clipboard.writeText(s).then(ok,function(){paste(s);ok();});');
    DBMS_OUTPUT.PUT_LINE('      return;');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('  paste(s); ok();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: permalink anchor on every section heading ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section > h2").forEach(function(h2){');
    DBMS_OUTPUT.PUT_LINE('  var sec=h2.parentNode; if(!sec.id) return;');
    DBMS_OUTPUT.PUT_LINE('  var a=doc.createElement("a");');
    DBMS_OUTPUT.PUT_LINE('  a.className="permalink"; a.href="#"+sec.id; a.textContent="#";');
    DBMS_OUTPUT.PUT_LINE('  a.title="Copy a link to this section";');
    DBMS_OUTPUT.PUT_LINE('  a.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('    ev.preventDefault();');
    DBMS_OUTPUT.PUT_LINE('    var st=stateStr();');
    DBMS_OUTPUT.PUT_LINE('    copyText(location.href.split("#")[0]+"#"+sec.id+(st?"!"+st:""),a,"\u2713");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  h2.appendChild(a);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: per-table CSV / Markdown copy toolbar ---- */');
    DBMS_OUTPUT.PUT_LINE('function visRows(tb){');
    DBMS_OUTPUT.PUT_LINE('  var out=[];');
    DBMS_OUTPUT.PUT_LINE('  tb.querySelectorAll("tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(tr.hidden) return;');
    DBMS_OUTPUT.PUT_LINE('    if(getComputedStyle(tr).display==="none") return;');
    DBMS_OUTPUT.PUT_LINE('    out.push(tr);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function tableRows(tb){');
    DBMS_OUTPUT.PUT_LINE('  var hr=tb.querySelectorAll("thead tr"), rows=[];');
    DBMS_OUTPUT.PUT_LINE('  if(hr.length){');
    DBMS_OUTPUT.PUT_LINE('    rows.push(Array.prototype.map.call(hr[hr.length-1].cells,cellText));');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  visRows(tb).forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    rows.push(Array.prototype.map.call(tr.cells,cellText));');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return rows;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function toCSV(tb){');
    DBMS_OUTPUT.PUT_LINE('  return tableRows(tb).map(function(r){');
    DBMS_OUTPUT.PUT_LINE('    return r.map(function(v){');
    DBMS_OUTPUT.PUT_LINE('      return /[",\n]/.test(v)?"\""+v.replace(/"/g,"\"\"")+"\"":v;');
    DBMS_OUTPUT.PUT_LINE('    }).join(",");');
    DBMS_OUTPUT.PUT_LINE('  }).join("\n");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function toMD(tb){');
    DBMS_OUTPUT.PUT_LINE('  var rows=tableRows(tb); if(!rows.length) return "";');
    DBMS_OUTPUT.PUT_LINE('  var esc=function(v){return v.replace(/\|/g,"\\|");};');
    DBMS_OUTPUT.PUT_LINE('  var out=["| "+rows[0].map(esc).join(" | ")+" |",');
    DBMS_OUTPUT.PUT_LINE('           "|"+rows[0].map(function(){return " --- |";}).join("")];');
    DBMS_OUTPUT.PUT_LINE('  rows.slice(1).forEach(function(r){');
    DBMS_OUTPUT.PUT_LINE('    out.push("| "+r.map(esc).join(" | ")+" |");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out.join("\n");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  if(!tb.querySelector("thead")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.hasAttribute("data-notools")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.closest("tr.sql-detail")||tb.closest("details")) return;');
    DBMS_OUTPUT.PUT_LINE('  if(tb.querySelectorAll("tbody tr").length<4) return;');
    DBMS_OUTPUT.PUT_LINE('  var bar=doc.createElement("div");');
    DBMS_OUTPUT.PUT_LINE('  var vc=Array.prototype.filter.call(tb.classList,function(c){return c==="vw"||c.indexOf("in-")===0;}).join(" ");');
    DBMS_OUTPUT.PUT_LINE('  bar.className="tbl-tools"+(vc?" "+vc:"");');
    DBMS_OUTPUT.PUT_LINE('  var mk=function(label,fn){');
    DBMS_OUTPUT.PUT_LINE('    var b=doc.createElement("button");');
    DBMS_OUTPUT.PUT_LINE('    b.type="button"; b.className="tool-btn"; b.textContent=label;');
    DBMS_OUTPUT.PUT_LINE('    b.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('      ev.stopPropagation();');
    DBMS_OUTPUT.PUT_LINE('      copyText(fn(tb),b,"Copied");');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('    bar.appendChild(b);');
    DBMS_OUTPUT.PUT_LINE('  };');
    DBMS_OUTPUT.PUT_LINE('  mk("\u29C9 CSV",toCSV); mk("\u29C9 MD",toMD);');
    DBMS_OUTPUT.PUT_LINE('  tb.parentNode.insertBefore(bar,tb);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C4: delegated .copy-btn (pre / code blocks) ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var b=closest(ev.target,".copy-btn"); if(!b) return;');
    DBMS_OUTPUT.PUT_LINE('  var sel=b.getAttribute("data-copy");');
    DBMS_OUTPUT.PUT_LINE('  var target=sel?doc.querySelector(sel):b.parentNode;');
    DBMS_OUTPUT.PUT_LINE('  if(!target) return;');
    DBMS_OUTPUT.PUT_LINE('  var c=target.cloneNode(true);');
    DBMS_OUTPUT.PUT_LINE('  c.querySelectorAll(".copy-btn").forEach(function(x){x.parentNode.removeChild(x);});');
    DBMS_OUTPUT.PUT_LINE('  copyText((c.textContent||"").replace(/^\s+|\s+$/g,""),b,"Copied");');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T1: long-tail expanders ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var e=closest(ev.target,".expander"); if(!e) return;');
    DBMS_OUTPUT.PUT_LINE('  var id=e.getAttribute("data-for");');
    DBMS_OUTPUT.PUT_LINE('  var tb=id?doc.getElementById(id):null; if(!tb) return;');
    DBMS_OUTPUT.PUT_LINE('  var on=tb.classList.toggle("open");');
    DBMS_OUTPUT.PUT_LINE('  var n=e.getAttribute("data-n")||"";');
    DBMS_OUTPUT.PUT_LINE('  var noun=e.getAttribute("data-noun")||"rows";');
    DBMS_OUTPUT.PUT_LINE('  e.textContent=(on?"\u25BE Hide ":"\u25B8 Show ")+n+" "+noun;');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- C1: tabs ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=closest(ev.target,".tabs [data-t]"); if(!t) return;');
    DBMS_OUTPUT.PUT_LINE('  var bar=closest(t,".tabs"); if(!bar) return;');
    DBMS_OUTPUT.PUT_LINE('  var g=bar.getAttribute("data-tabs"), key=t.getAttribute("data-t");');
    DBMS_OUTPUT.PUT_LINE('  bar.querySelectorAll("[data-t]").forEach(function(x){var on=(x===t);x.classList.toggle("on",on);x.setAttribute("aria-selected",on?"true":"false");x.setAttribute("tabindex",on?"0":"-1");});');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll(".tabpanel[data-tabs=\""+g+"\"]").forEach(function(p){');
    DBMS_OUTPUT.PUT_LINE('    var on=p.getAttribute("data-t")===key;');
    DBMS_OUTPUT.PUT_LINE('    p.classList.toggle("on",on);');
    DBMS_OUTPUT.PUT_LINE('    if(on&&window.echarts){');
    DBMS_OUTPUT.PUT_LINE('      p.querySelectorAll("[_echarts_instance_]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('        var inst=echarts.getInstanceByDom(el); if(inst) inst.resize();');
    DBMS_OUTPUT.PUT_LINE('      });');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- P2: wide tables scroll inside their panel ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  var p=tb.parentNode; if(p&&p.classList&&p.classList.contains("tblwrap")) return;');
    DBMS_OUTPUT.PUT_LINE('  var w=doc.createElement("div"); w.className="tblwrap";');
    DBMS_OUTPUT.PUT_LINE('  p.insertBefore(w,tb); w.appendChild(tb);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('function fitTables(){');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll(".tblwrap").forEach(function(w){');
    DBMS_OUTPUT.PUT_LINE('    var tb=w.firstElementChild; if(!tb||w.offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    w.classList.remove("scroll");');
    DBMS_OUTPUT.PUT_LINE('    if(tb.scrollWidth>w.clientWidth+1) w.classList.add("scroll");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_fitTables=fitTables;');
    DBMS_OUTPUT.PUT_LINE('fitTables(); setTimeout(fitTables,400);');
    DBMS_OUTPUT.PUT_LINE('var ft=null;');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",function(){ if(ft) clearTimeout(ft); ft=setTimeout(fitTables,150); });');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){ if(closest(ev.target,".expander,.tabs [data-t],details > summary")) setTimeout(fitTables,50); });');
    DBMS_OUTPUT.PUT_LINE('/* ---- P2: narrow-screen "View" popover ---- */');
    DBMS_OUTPUT.PUT_LINE('var vb=doc.getElementById("view-btn"), vf=vb?closest(vb,".rail-foot"):null;');
    DBMS_OUTPUT.PUT_LINE('function closeView(){ if(vf){ vf.classList.remove("open"); vb.setAttribute("aria-expanded","false"); } }');
    DBMS_OUTPUT.PUT_LINE('if(vb&&vf){');
    DBMS_OUTPUT.PUT_LINE('  vb.addEventListener("click",function(ev){ ev.stopPropagation(); var on=vf.classList.toggle("open"); vb.setAttribute("aria-expanded",on?"true":"false"); if(nav) nav.classList.remove("menu-open"); });');
    DBMS_OUTPUT.PUT_LINE('  doc.addEventListener("click",function(ev){ if(vf.classList.contains("open")&&!closest(ev.target,".rail-foot")) closeView(); });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- X2: cross-report window highlight ---- */');
    DBMS_OUTPUT.PUT_LINE('var curW=null;');
    DBMS_OUTPUT.PUT_LINE('function applyW(){');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("[data-w]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    el.classList.toggle("hl",curW!==null&&el.getAttribute("data-w")===curW);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  doc.dispatchEvent(new CustomEvent("awr:window",');
    DBMS_OUTPUT.PUT_LINE('    {detail:{w:curW===null?null:Number(curW)}}));');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function setW(w){ curW=(w===curW)?null:w; applyW(); }');
    DBMS_OUTPUT.PUT_LINE('function clearW(){ if(curW!==null){ curW=null; applyW(); } }');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var el=closest(ev.target,"th[data-w],.wchip[data-w]"); if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  if(closest(el,"summary")) ev.preventDefault();');
    DBMS_OUTPUT.PUT_LINE('  setW(el.getAttribute("data-w"));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T3: click-to-sort ---- */');
    DBMS_OUTPUT.PUT_LINE('function numOf(s){');
    DBMS_OUTPUT.PUT_LINE('  var t=s.replace(/\u2212/g,"-")');
    DBMS_OUTPUT.PUT_LINE('         .replace(/[\u25B2\u25BC\u25B8\u25BE\u2191\u2193\u00A0]/g,"")');
    DBMS_OUTPUT.PUT_LINE('         .replace(/,/g,"").replace(/%/g,"").replace(/\+/g,"").replace(/\s/g,"");');
    DBMS_OUTPUT.PUT_LINE('  if(!t) return null;');
    DBMS_OUTPUT.PUT_LINE('  var m=/^(-?(?:\d+\.?\d*|\.\d+))([kMG])?$/.exec(t);');
    DBMS_OUTPUT.PUT_LINE('  if(!m) return null;');
    DBMS_OUTPUT.PUT_LINE('  var v=parseFloat(m[1]);');
    DBMS_OUTPUT.PUT_LINE('  if(m[2]==="k") v*=1e3; else if(m[2]==="M") v*=1e6; else if(m[2]==="G") v*=1e9;');
    DBMS_OUTPUT.PUT_LINE('  return v;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  if(closest(ev.target,".tool-btn")) return;');
    DBMS_OUTPUT.PUT_LINE('  var th=closest(ev.target,"section table thead th"); if(!th) return;');
    DBMS_OUTPUT.PUT_LINE('  if(th.hasAttribute("data-w")||th.classList.contains("c-band")) return;');
    DBMS_OUTPUT.PUT_LINE('  var tb=closest(th,"table");');
    DBMS_OUTPUT.PUT_LINE('  if(!tb||tb.hasAttribute("data-nosort")) return;');
    DBMS_OUTPUT.PUT_LINE('  var body=tb.tBodies[0]; if(!body) return;');
    DBMS_OUTPUT.PUT_LINE('  var hr=th.parentNode;');
    DBMS_OUTPUT.PUT_LINE('  var idx=Array.prototype.indexOf.call(hr.cells,th);');
    DBMS_OUTPUT.PUT_LINE('  var desc=!th.classList.contains("desc");');
    DBMS_OUTPUT.PUT_LINE('  hr.querySelectorAll("th").forEach(function(x){x.classList.remove("asc","desc");x.removeAttribute("aria-sort");});');
    DBMS_OUTPUT.PUT_LINE('  th.classList.add(desc?"desc":"asc"); th.setAttribute("aria-sort",desc?"descending":"ascending");');
    DBMS_OUTPUT.PUT_LINE('  var dec=Array.prototype.slice.call(body.rows).map(function(r,i){');
    DBMS_OUTPUT.PUT_LINE('    var c=r.cells[idx], s=c?cellText(c):"";');
    DBMS_OUTPUT.PUT_LINE('    return {r:r,i:i,s:s,n:c?numOf(s):null};');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  var blank=function(d){return !d.s||d.s==="\u2014"||d.s==="\u2013"||d.s==="-";};');
    DBMS_OUTPUT.PUT_LINE('  dec.sort(function(a,b){');
    DBMS_OUTPUT.PUT_LINE('    var ab=blank(a), bb=blank(b);');
    DBMS_OUTPUT.PUT_LINE('    if(ab!==bb) return ab?1:-1;');
    DBMS_OUTPUT.PUT_LINE('    if(ab&&bb) return a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('    if(a.n!==null&&b.n!==null){');
    DBMS_OUTPUT.PUT_LINE('      if(a.n!==b.n) return desc?b.n-a.n:a.n-b.n;');
    DBMS_OUTPUT.PUT_LINE('      return a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('    if(a.n!==null) return -1;');
    DBMS_OUTPUT.PUT_LINE('    if(b.n!==null) return 1;');
    DBMS_OUTPUT.PUT_LINE('    var c=a.s.localeCompare(b.s);');
    DBMS_OUTPUT.PUT_LINE('    return c?(desc?-c:c):a.i-b.i;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  dec.forEach(function(d){body.appendChild(d.r);});');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- T4: row filter ---- */');
    DBMS_OUTPUT.PUT_LINE('var fi=doc.getElementById("row-filter");');
    DBMS_OUTPUT.PUT_LINE('function dimRail(){');
    DBMS_OUTPUT.PUT_LINE('  if(!nav) return;');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll("a[href^=\"#\"]").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    var sec=doc.getElementById(a.getAttribute("href").slice(1));');
    DBMS_OUTPUT.PUT_LINE('    if(!sec){ a.classList.remove("dim"); return; }');
    DBMS_OUTPUT.PUT_LINE('    var rows=sec.querySelectorAll("tbody tr");');
    DBMS_OUTPUT.PUT_LINE('    if(!rows.length){ a.classList.remove("dim"); return; }');
    DBMS_OUTPUT.PUT_LINE('    var vis=0;');
    DBMS_OUTPUT.PUT_LINE('    rows.forEach(function(r){ if(!r.hidden) vis++; });');
    DBMS_OUTPUT.PUT_LINE('    a.classList.toggle("dim",vis===0);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function applyFilter(){');
    DBMS_OUTPUT.PUT_LINE('  var q=((fi&&fi.value)||"").trim().toLowerCase();');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("section tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(!q){ tr.hidden=false; return; }');
    DBMS_OUTPUT.PUT_LINE('    var s="", n=Math.min(2,tr.cells.length);');
    DBMS_OUTPUT.PUT_LINE('    for(var i=0;i<n;i++) s+=" "+cellText(tr.cells[i]);');
    DBMS_OUTPUT.PUT_LINE('    tr.hidden=s.toLowerCase().indexOf(q)<0;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  dimRail();');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('if(fi) fi.addEventListener("input",applyFilter);');
    DBMS_OUTPUT.PUT_LINE('/* ---- C2 + H1: per-section large / moderate row counts, on the rail links and in the section header ---- */');
    DBMS_OUTPUT.PUT_LINE('function isCrit(tr){ return tr.classList.contains("crit")||!!tr.querySelector(".badge.crit, td.c-band .bd.s-large"); }');
    DBMS_OUTPUT.PUT_LINE('function isWarn(tr){ return tr.classList.contains("warn")||!!tr.querySelector(".badge.warn, td.c-band .bd.s-moderate"); }');
    DBMS_OUTPUT.PUT_LINE('function secCounts(sec){');
    DBMS_OUTPUT.PUT_LINE('  var c=0,w=0;');
    DBMS_OUTPUT.PUT_LINE('  sec.querySelectorAll("tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(tr.closest("table[data-nocount]")) return;');
    DBMS_OUTPUT.PUT_LINE('    if(tr.classList.contains("twin")||tr.classList.contains("member")) return;');
    DBMS_OUTPUT.PUT_LINE('    if(isCrit(tr)) c++; else if(isWarn(tr)) w++;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return [c,w];');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('if(nav){');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll("a[href^=\"#\"]").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    var id=a.getAttribute("href").slice(1);');
    DBMS_OUTPUT.PUT_LINE('    if(id==="overview"||a.hasAttribute("data-nodot")) return;');
    DBMS_OUTPUT.PUT_LINE('    var sec=doc.getElementById(id); if(!sec) return;');
    DBMS_OUTPUT.PUT_LINE('    var n=secCounts(sec);');
    DBMS_OUTPUT.PUT_LINE('    if(n[0]){ var p=doc.createElement("span"); p.className="cnt c"; p.textContent=n[0]; a.appendChild(p); }');
    DBMS_OUTPUT.PUT_LINE('    if(n[1]){ var q=doc.createElement("span"); q.className="cnt w"; q.textContent=n[1]; a.appendChild(q); }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("main > section > h2").forEach(function(h2){');
    DBMS_OUTPUT.PUT_LINE('  var sec=h2.parentNode; if(sec.id==="overview"||sec.id==="guide"||h2.querySelector(".meta")) return;');
    DBMS_OUTPUT.PUT_LINE('  var n=secCounts(sec); if(!n[0]&&!n[1]) return;');
    DBMS_OUTPUT.PUT_LINE('  var m=doc.createElement("span"); m.className="meta";');
    DBMS_OUTPUT.PUT_LINE('  if(n[0]) m.innerHTML+="<span><i class=\"dotk large\"></i>"+n[0]+" large</span>";');
    DBMS_OUTPUT.PUT_LINE('  if(n[1]) m.innerHTML+="<span><i class=\"dotk moderate\"></i>"+n[1]+" moderate</span>";');
    DBMS_OUTPUT.PUT_LINE('  h2.insertBefore(m,h2.querySelector(".permalink"));');
    DBMS_OUTPUT.PUT_LINE('});');

    DBMS_OUTPUT.PUT_LINE('/* ---- C2: next / previous large finding (J / K) ---- */');
    DBMS_OUTPUT.PUT_LINE('var jIdx=-1;');
    DBMS_OUTPUT.PUT_LINE('function findingRows(){');
    DBMS_OUTPUT.PUT_LINE('  var out=[];');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("section tbody tr").forEach(function(tr){');
    DBMS_OUTPUT.PUT_LINE('    if(tr.hidden||tr.offsetParent===null) return;');
    DBMS_OUTPUT.PUT_LINE('    if(tr.classList.contains("twin")||tr.classList.contains("member")) return;');
    DBMS_OUTPUT.PUT_LINE('    if(isCrit(tr)) out.push(tr);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return out;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function jump(d){');
    DBMS_OUTPUT.PUT_LINE('  var list=findingRows(); if(!list.length) return;');
    DBMS_OUTPUT.PUT_LINE('  jIdx=(jIdx+d+list.length*2)%list.length;');
    DBMS_OUTPUT.PUT_LINE('  var tr=list[jIdx];');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("tr.jump-hi").forEach(function(x){x.classList.remove("jump-hi");});');
    DBMS_OUTPUT.PUT_LINE('  tr.scrollIntoView({block:"center"});');
    DBMS_OUTPUT.PUT_LINE('  tr.classList.add("jump-hi");');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){tr.classList.remove("jump-hi");},1600);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var nf=doc.getElementById("next-finding");');
    DBMS_OUTPUT.PUT_LINE('if(nf) nf.addEventListener("click",function(){jump(1);});');
    -- V1: the views.  inView(el, v) walks every .vw ancestor (a
    -- section may be in-s in-a while a table inside it is in-a only);
    -- viewOf(el) keeps the current view when el is visible there, else
    -- picks the first view that shows it.  railViews() dims every rail
    -- link whose target is hidden in the current view (a click on one
    -- switches view via goTo), counts the sections only All sections
    -- has, and feeds the "+ N more" rail line and the Summary note at
    -- the end of <main>.  setView() flips the body class, syncs the
    -- top-bar switch, persists only when asked (an explicit click),
    -- and re-measures everything that was display:none (sticky offsets,
    -- table scroll wrappers, every ECharts instance).
    DBMS_OUTPUT.PUT_LINE('/* ---- V1: Summary / Timeline / All sections ---- */');
    DBMS_OUTPUT.PUT_LINE('var VIEWS={summary:"vs",timeline:"vt",all:"va"}, VNAME={summary:"Summary",timeline:"Timeline",all:"All sections"};');
    DBMS_OUTPUT.PUT_LINE('function curView(){ return bd.getAttribute("data-view")||"summary"; }');
    DBMS_OUTPUT.PUT_LINE('function inView(el,v){ var k="in-"+v.charAt(0), x=el; while(x&&x!==bd&&x.nodeType===1){ if(x.classList.contains("vw")&&!x.classList.contains(k)) return false; x=x.parentNode; } return true; }');
    DBMS_OUTPUT.PUT_LINE('function viewOf(el){ var c=curView(), o=["summary","timeline","all"]; if(inView(el,c)) return c; for(var i=0;i<o.length;i++){ if(inView(el,o[i])) return o[i]; } return c; }');
    DBMS_OUTPUT.PUT_LINE('var hiddenSecs=[], moreLink=null;');
    DBMS_OUTPUT.PUT_LINE('function railViews(){');
    DBMS_OUTPUT.PUT_LINE('  if(!nav) return;');
    DBMS_OUTPUT.PUT_LINE('  var list=nav.querySelector(".rail-list")||nav, grp=null, gAll=true, v=curView();');
    DBMS_OUTPUT.PUT_LINE('  hiddenSecs=[];');
    DBMS_OUTPUT.PUT_LINE('  Array.prototype.slice.call(list.children).forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    if(el.tagName==="B"){ if(grp) grp.classList.toggle("vdim",gAll); grp=el; gAll=true; return; }');
    DBMS_OUTPUT.PUT_LINE('    if(el.tagName!=="A"||el===moreLink||el.hidden) return;');
    DBMS_OUTPUT.PUT_LINE('    var id=(el.getAttribute("href")||"").slice(1), t=id?doc.getElementById(id):null, off=!!t&&!inView(t,v);');
    DBMS_OUTPUT.PUT_LINE('    el.classList.toggle("vdim",off);');
    DBMS_OUTPUT.PUT_LINE('    if(!off){ gAll=false; return; }');
    DBMS_OUTPUT.PUT_LINE('    if(v==="summary"&&t.tagName==="SECTION"&&inView(t,"all")){ var cl=el.cloneNode(true); cl.querySelectorAll("span").forEach(function(x){x.parentNode.removeChild(x);}); hiddenSecs.push((cl.textContent||id).trim()); }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(grp) grp.classList.toggle("vdim",gAll);');
    DBMS_OUTPUT.PUT_LINE('  if(!moreLink){ moreLink=doc.createElement("a"); moreLink.className="more-sections"; moreLink.href="#view=all"; moreLink.addEventListener("click",function(ev){ ev.preventDefault(); setView("all",true); window.scrollTo(0,0); }); list.insertBefore(moreLink,doc.getElementById("rail-ref")); }');
    DBMS_OUTPUT.PUT_LINE('  moreLink.textContent="+ "+hiddenSecs.length+" more in All sections"; moreLink.title=hiddenSecs.join(", "); moreLink.hidden=!hiddenSecs.length;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function viewNote(){');
    DBMS_OUTPUT.PUT_LINE('  var mn=doc.getElementById("main-start"); if(!mn) return;');
    DBMS_OUTPUT.PUT_LINE('  var n=doc.getElementById("view-note");');
    DBMS_OUTPUT.PUT_LINE('  if(!n){ n=doc.createElement("p"); n.id="view-note"; n.className="view-note"; var g=doc.getElementById("guide"); if(g&&g.parentNode===mn) mn.insertBefore(n,g); else mn.appendChild(n); }');
    DBMS_OUTPUT.PUT_LINE('  n.innerHTML="";');
    DBMS_OUTPUT.PUT_LINE('  n.appendChild(doc.createTextNode(hiddenSecs.length?("Summary view: "+hiddenSecs.length+" more section"+(hiddenSecs.length===1?"":"s")+" and the per-metric detail tables are in All sections ("+hiddenSecs.join(", ")+")."):"Summary view: the per-metric detail tables are in All sections."));');
    DBMS_OUTPUT.PUT_LINE('  var b=doc.createElement("button"); b.type="button"; b.textContent="Show all sections"; b.addEventListener("click",function(){ setView("all",true); }); n.appendChild(b);');
    DBMS_OUTPUT.PUT_LINE('}');
    -- V2: the evidence library.  Every section with class "lib" is, in the
    -- Summary view only, one collapsible row: its h2 (title, the one-line
    -- status span.ls, the counts) toggles .lopen, which shows the rest of
    -- the section in place (CSS in _style.sql "evidence library"; the
    -- row order comes from the section's --os).  Charts built while the
    -- row was closed measure zero width, so opening re-sizes them.  All
    -- sections ignores .lopen and shows every section in full.
    DBMS_OUTPUT.PUT_LINE('/* ---- V2: the evidence library (Summary): one collapsible row per section.lib ---- */');
    DBMS_OUTPUT.PUT_LINE('function libSecs(){ return Array.prototype.slice.call(doc.querySelectorAll("main > section.lib")); }');
    DBMS_OUTPUT.PUT_LINE('function libResize(sec){ if(window.echarts&&echarts.getInstanceByDom){ sec.querySelectorAll("[_echarts_instance_]").forEach(function(el){ var c=echarts.getInstanceByDom(el); if(c) c.resize(); }); } if(window.AWR_WG&&AWR_WG.refit) AWR_WG.refit(); fitTables(); }');
    DBMS_OUTPUT.PUT_LINE('function libOpen(sec,on){ sec.classList.toggle("lopen",on); var h=sec.querySelector("h2"); if(h&&curView()==="summary") h.setAttribute("aria-expanded",on?"true":"false"); if(on) setTimeout(function(){ libResize(sec); },30); }');
    DBMS_OUTPUT.PUT_LINE('function libViews(){');
    DBMS_OUTPUT.PUT_LINE('  var sm=curView()==="summary", vis=[];');
    DBMS_OUTPUT.PUT_LINE('  libSecs().forEach(function(sec){ var h=sec.querySelector("h2"); sec.classList.remove("lib-first","lib-last"); if(sm&&sec.offsetParent!==null) vis.push(sec); if(!h) return;');
    DBMS_OUTPUT.PUT_LINE('    if(sm){ h.setAttribute("tabindex","0"); h.setAttribute("role","button"); h.setAttribute("aria-expanded",sec.classList.contains("lopen")?"true":"false"); }');
    DBMS_OUTPUT.PUT_LINE('    else { h.removeAttribute("tabindex"); h.removeAttribute("role"); h.removeAttribute("aria-expanded"); } });');
    DBMS_OUTPUT.PUT_LINE('  vis.sort(function(a,b){ return a.offsetTop-b.offsetTop; });');
    DBMS_OUTPUT.PUT_LINE('  if(vis.length){ vis[0].classList.add("lib-first"); vis[vis.length-1].classList.add("lib-last"); }');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('libSecs().forEach(function(sec){');
    DBMS_OUTPUT.PUT_LINE('  var h=sec.querySelector("h2"); if(!h) return;');
    DBMS_OUTPUT.PUT_LINE('  var lt=doc.createElement("span"); lt.className="lt"; while(h.firstChild&&h.firstChild.nodeType===3) lt.appendChild(h.firstChild); h.insertBefore(lt,h.firstChild);');
    DBMS_OUTPUT.PUT_LINE('  h.addEventListener("click",function(ev){ if(curView()!=="summary"||closest(ev.target,"a,button")) return; libOpen(sec,!sec.classList.contains("lopen")); });');
    DBMS_OUTPUT.PUT_LINE('  h.addEventListener("keydown",function(ev){ if(curView()!=="summary"||(ev.key!=="Enter"&&ev.key!==" ")) return; ev.preventDefault(); libOpen(sec,!sec.classList.contains("lopen")); });');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('function setView(v,persist){');
    DBMS_OUTPUT.PUT_LINE('  if(!VIEWS[v]) v="summary";');
    DBMS_OUTPUT.PUT_LINE('  bd.classList.remove("vs","vt","va"); bd.classList.add(VIEWS[v]); bd.setAttribute("data-view",v);');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll(".topbar .seg [data-v]").forEach(function(b){ b.setAttribute("aria-pressed",b.getAttribute("data-v")===v?"true":"false"); });');
    DBMS_OUTPUT.PUT_LINE('  if(persist){ try{localStorage.setItem("awr-view",v);}catch(e){} if(/view=/.test(location.hash||"")){ try{history.replaceState(null,"",location.pathname+location.search);}catch(e){} } }');
    DBMS_OUTPUT.PUT_LINE('  railViews(); viewNote(); libViews();');
    DBMS_OUTPUT.PUT_LINE('  measure(); window.dispatchEvent(new Event("resize"));');
    DBMS_OUTPUT.PUT_LINE('  if(window.echarts&&echarts.getInstanceByDom){ doc.querySelectorAll("[_echarts_instance_]").forEach(function(el){ var c=echarts.getInstanceByDom(el); if(c) c.resize(); }); }');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(fitTables,60); closeView();');
    DBMS_OUTPUT.PUT_LINE('  doc.dispatchEvent(new CustomEvent("awr:view",{detail:{view:v}}));');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_setView=setView;');
    DBMS_OUTPUT.PUT_LINE('window.AWR_setMode=function(det){ setView(det?"all":"summary",false); };');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll(".topbar .seg [data-v]").forEach(function(b){ b.addEventListener("click",function(){ setView(b.getAttribute("data-v"),true); window.scrollTo(0,0); }); });');
    DBMS_OUTPUT.PUT_LINE('/* reveal(el): open what hides el inside its view -- a tab, folded tail rows, <details>, a folded Timeline lane */');
    DBMS_OUTPUT.PUT_LINE('function reveal(el){');
    DBMS_OUTPUT.PUT_LINE('  if(window.AWR_TL&&AWR_TL.reveal) AWR_TL.reveal(el);');
    DBMS_OUTPUT.PUT_LINE('  var ls=closest(el,"main > section.lib"); if(ls&&curView()==="summary"&&!ls.classList.contains("lopen")) libOpen(ls,true);');
    DBMS_OUTPUT.PUT_LINE('  var tp=closest(el,".tabpanel");');
    DBMS_OUTPUT.PUT_LINE('  if(tp&&!tp.classList.contains("on")){ var t=doc.querySelector(".tabs[data-tabs=\""+tp.getAttribute("data-tabs")+"\"] [data-t=\""+tp.getAttribute("data-t")+"\"]"); if(t) t.click(); }');
    DBMS_OUTPUT.PUT_LINE('  var tl=closest(el,"[data-tail=\"Y\"]");');
    DBMS_OUTPUT.PUT_LINE('  if(tl){ var box=tl.parentNode, ex=null; while(box&&box!==bd){ if(box.id){ ex=doc.querySelector(".expander[data-for=\""+box.id+"\"]"); if(ex) break; } box=box.parentNode; }');
    DBMS_OUTPUT.PUT_LINE('    if(ex&&!box.classList.contains("open")) ex.click(); }');
    DBMS_OUTPUT.PUT_LINE('  var dt=closest(el,"details"); while(dt){ dt.open=true; dt=dt.parentNode?closest(dt.parentNode,"details"):null; }');
    DBMS_OUTPUT.PUT_LINE('  if(el.tagName==="DETAILS") el.open=true;');
    DBMS_OUTPUT.PUT_LINE('  if(el.id==="about"){ var ab=el.querySelector("details"); if(ab) ab.open=true; }');
    DBMS_OUTPUT.PUT_LINE('  if(el.hidden&&el.tagName==="TR") el.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('  if(el.classList.contains("sql-row")&&window.AWR_openSqlRow) window.AWR_openSqlRow(el);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* goTo(el, flash, persist): switch to el''s view, reveal it, scroll it into view, flash it */');
    DBMS_OUTPUT.PUT_LINE('function goTo(el,flash,persist){');
    DBMS_OUTPUT.PUT_LINE('  if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  var v=viewOf(el); if(v!==curView()) setView(v,persist!==false);');
    DBMS_OUTPUT.PUT_LINE('  reveal(el);');
    DBMS_OUTPUT.PUT_LINE('  setTimeout(function(){');
    DBMS_OUTPUT.PUT_LINE('    el.scrollIntoView({block:el.tagName==="TR"?"center":"start"});');
    DBMS_OUTPUT.PUT_LINE('    if(flash){ el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash"); setTimeout(function(){ el.classList.remove("flash"); },2400); }');
    DBMS_OUTPUT.PUT_LINE('    setTimeout(fitTables,60);');
    DBMS_OUTPUT.PUT_LINE('  },30);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_goTo=goTo;');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  if(ev.defaultPrevented||ev.button||ev.metaKey||ev.ctrlKey||ev.shiftKey) return;');
    DBMS_OUTPUT.PUT_LINE('  var a=closest(ev.target,"a[href^=\"#\"]"); if(!a||a.classList.contains("skip")) return;');
    DBMS_OUTPUT.PUT_LINE('  var h=a.getAttribute("href").slice(1); if(!h) return;');
    DBMS_OUTPUT.PUT_LINE('  var m=/^view=(summary|timeline|all)$/.exec(h);');
    DBMS_OUTPUT.PUT_LINE('  if(m){ ev.preventDefault(); setView(m[1],true); window.scrollTo(0,0); return; }');
    DBMS_OUTPUT.PUT_LINE('  var id=h.split("!")[0], el=id?doc.getElementById(id):null; if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  ev.preventDefault();');
    DBMS_OUTPUT.PUT_LINE('  goTo(el,a.classList.contains("ent")||a.classList.contains("xlink")||el.tagName==="TR",true);');
    DBMS_OUTPUT.PUT_LINE('  try{ history.replaceState(null,"","#"+id); }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('  if(nav) nav.classList.remove("menu-open");');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- B8: narrow-screen section dropdown ---- */');
    DBMS_OUTPUT.PUT_LINE('var mb=doc.getElementById("rail-menu-btn");');
    DBMS_OUTPUT.PUT_LINE('if(mb&&nav){');
    DBMS_OUTPUT.PUT_LINE('  mb.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('    var on=nav.classList.toggle("menu-open");');
    DBMS_OUTPUT.PUT_LINE('    mb.setAttribute("aria-expanded",on?"true":"false");');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  nav.querySelectorAll(".rail-list a").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    a.addEventListener("click",function(){');
    DBMS_OUTPUT.PUT_LINE('      nav.classList.remove("menu-open");');
    DBMS_OUTPUT.PUT_LINE('      mb.setAttribute("aria-expanded","false");');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* ---- T2: sticky offset (--navh): the sticky top bar (desktop) or the rail bar (narrow) ---- */');
    DBMS_OUTPUT.PUT_LINE('function measure(){');
    DBMS_OUTPUT.PUT_LINE('  var navh=0, tb=doc.getElementById("topbar");');
    DBMS_OUTPUT.PUT_LINE('  if(tb&&getComputedStyle(tb).position==="sticky") navh=tb.offsetHeight;');
    DBMS_OUTPUT.PUT_LINE('  else if(nav&&getComputedStyle(nav).position==="sticky") navh=nav.offsetHeight;');
    DBMS_OUTPUT.PUT_LINE('  doc.documentElement.style.setProperty("--navh",navh+"px"); bd.style.setProperty("--navh",navh+"px");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var mt=null;');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",function(){');
    DBMS_OUTPUT.PUT_LINE('  if(mt) clearTimeout(mt);');
    DBMS_OUTPUT.PUT_LINE('  mt=setTimeout(measure,120);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('measure();');
    DBMS_OUTPUT.PUT_LINE('setTimeout(measure,300);');
    DBMS_OUTPUT.PUT_LINE('/* ---- P3: cross-links -- hide a link whose target does not exist, reveal a linked row ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("a.xlink").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('  var id=(a.getAttribute("href")||"").slice(1);');
    DBMS_OUTPUT.PUT_LINE('  if(!id||!doc.getElementById(id)) a.hidden=true;');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var scs=doc.getElementById("s-changes"), scl=nav?nav.querySelector(''a[href="#s-changes"]''):null;');
    DBMS_OUTPUT.PUT_LINE('if(scs&&scl&&!scs.hidden) scl.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('function revealHash(){');
    DBMS_OUTPUT.PUT_LINE('  var h=(location.hash||"").slice(1); if(!h) return;');
    DBMS_OUTPUT.PUT_LINE('  var m=/^view=(summary|timeline|all)/.exec(h);');
    DBMS_OUTPUT.PUT_LINE('  if(m){ if(m[1]!==curView()) setView(m[1],false); return; }');
    DBMS_OUTPUT.PUT_LINE('  var id=h.split("!")[0], el=id?doc.getElementById(id):null; if(!el) return;');
    DBMS_OUTPUT.PUT_LINE('  goTo(el,el.tagName!=="SECTION",false);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("hashchange",revealHash);');
    DBMS_OUTPUT.PUT_LINE('if(location.hash) setTimeout(revealHash,0);');
    DBMS_OUTPUT.PUT_LINE('/* ---- P3: shareable view state in the hash (#anchor!v=f&tab=CPU&w=3) ---- */');
    DBMS_OUTPUT.PUT_LINE('function stateStr(){');
    DBMS_OUTPUT.PUT_LINE('  var parts=[];');
    DBMS_OUTPUT.PUT_LINE('  var tab=doc.querySelector(".tabs[data-tabs=\"topsql\"] [data-t].on");');
    DBMS_OUTPUT.PUT_LINE('  if(tab&&tab.getAttribute("data-t")!=="ELAPSED") parts.push("tab="+tab.getAttribute("data-t"));');
    DBMS_OUTPUT.PUT_LINE('  if(curW!==null&&curW!==undefined) parts.push("w="+curW);');
    DBMS_OUTPUT.PUT_LINE('  return parts.join("&");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var stTimer=null;');
    DBMS_OUTPUT.PUT_LINE('function pushState(){');
    DBMS_OUTPUT.PUT_LINE('  if(stTimer) clearTimeout(stTimer);');
    DBMS_OUTPUT.PUT_LINE('  stTimer=setTimeout(function(){');
    DBMS_OUTPUT.PUT_LINE('    var h=location.hash||"", anchor=h.slice(1).split("!")[0], st=stateStr();');
    DBMS_OUTPUT.PUT_LINE('    var nh=(anchor||st)?("#"+anchor+(st?"!"+st:"")):"";');
    DBMS_OUTPUT.PUT_LINE('    if(nh!==h){ try{ history.replaceState(null,"",location.pathname+location.search+nh); }catch(e){} }');
    DBMS_OUTPUT.PUT_LINE('  },60);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function applyState(){');
    DBMS_OUTPUT.PUT_LINE('  var h=location.hash||"", i=h.indexOf("!"); if(i<0) return;');
    DBMS_OUTPUT.PUT_LINE('  var q={}; h.slice(i+1).split("&").forEach(function(kv){var p=kv.split("="); if(p[0]) q[p[0]]=decodeURIComponent(p[1]||"");});');
    DBMS_OUTPUT.PUT_LINE('  var v=(q.v||"").split(",");');
    DBMS_OUTPUT.PUT_LINE('  if(v.indexOf("f")>=0&&curView()!=="all") setView("all",false);');
    DBMS_OUTPUT.PUT_LINE('  if(q.tab){ var t=doc.querySelector(".tabs[data-tabs=\"topsql\"] [data-t=\""+q.tab+"\"]"); if(t&&!t.classList.contains("on")) t.click(); }');
    DBMS_OUTPUT.PUT_LINE('  if(q.w!==undefined&&q.w!==""){ curW=String(q.w); applyW(); }');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){ if(closest(ev.target,".tabs [data-t]")) pushState(); });');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("awr:window",pushState);');
    DBMS_OUTPUT.PUT_LINE('setView(curView(),false);');
    DBMS_OUTPUT.PUT_LINE('applyState();');
    DBMS_OUTPUT.PUT_LINE('/* ---- P5: on phones the Top SQL detail tables open by default (the bump chart is unreadable there) ---- */');
    DBMS_OUTPUT.PUT_LINE('if(doc.documentElement.clientWidth<=700){ doc.querySelectorAll("#topsql .tabpanel > details").forEach(function(d){ d.open=true; }); }');
    DBMS_OUTPUT.PUT_LINE('/* ---- P4: keyboard-operable tabs, sortable headers and window chips; table captions ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table:not([data-nosort]) thead th").forEach(function(th){');
    DBMS_OUTPUT.PUT_LINE('  th.setAttribute("scope","col");');
    DBMS_OUTPUT.PUT_LINE('  if(!th.hasAttribute("tabindex")) th.setAttribute("tabindex","0");');
    DBMS_OUTPUT.PUT_LINE('  th.setAttribute("role","button");');
    DBMS_OUTPUT.PUT_LINE('  if(!th.getAttribute("title")) th.setAttribute("title",th.hasAttribute("data-w")?"Highlight this window everywhere":"Sort by this column");');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table[data-nosort] thead th").forEach(function(th){ th.setAttribute("scope","col"); });');
    DBMS_OUTPUT.PUT_LINE('doc.querySelectorAll("section table").forEach(function(tb){');
    DBMS_OUTPUT.PUT_LINE('  if(tb.querySelector("caption")) return;');
    DBMS_OUTPUT.PUT_LINE('  var sec=closest(tb,"section"), h2=sec?sec.querySelector(":scope > h2"):null;');
    DBMS_OUTPUT.PUT_LINE('  var p=tb.parentNode&&tb.parentNode.classList.contains("tblwrap")?tb.parentNode:tb, h3=null, x=p.previousElementSibling;');
    DBMS_OUTPUT.PUT_LINE('  while(x&&!h3){ if(x.tagName==="H3") h3=x; else if(x.tagName==="TABLE"||x.classList.contains("tblwrap")) break; x=x.previousElementSibling; }');
    DBMS_OUTPUT.PUT_LINE('  var t=(h2?(h2.firstChild&&h2.firstChild.textContent||h2.textContent):"").trim();');
    DBMS_OUTPUT.PUT_LINE('  if(h3) t+=" \u2014 "+(h3.textContent||"").trim();');
    DBMS_OUTPUT.PUT_LINE('  if(!t) return;');
    DBMS_OUTPUT.PUT_LINE('  var c=doc.createElement("caption"); c.className="sr-only"; c.textContent=t; tb.insertBefore(c,tb.firstChild);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target;');
    DBMS_OUTPUT.PUT_LINE('  if(closest(t,".tabs [data-t]")){');
    DBMS_OUTPUT.PUT_LINE('    var tabs=Array.prototype.slice.call(closest(t,".tabs").querySelectorAll("[data-t]")), i=tabs.indexOf(closest(t,"[data-t]")), j=-1;');
    DBMS_OUTPUT.PUT_LINE('    if(ev.key==="ArrowRight") j=(i+1)%tabs.length; else if(ev.key==="ArrowLeft") j=(i-1+tabs.length)%tabs.length;');
    DBMS_OUTPUT.PUT_LINE('    else if(ev.key==="Home") j=0; else if(ev.key==="End") j=tabs.length-1;');
    DBMS_OUTPUT.PUT_LINE('    if(j>=0){ ev.preventDefault(); tabs[j].click(); tabs[j].focus(); }');
    DBMS_OUTPUT.PUT_LINE('    return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if((ev.key==="Enter"||ev.key===" ")&&t&&t.tagName==="TH"&&t.getAttribute("role")==="button"){ ev.preventDefault(); t.click(); }');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* ---- P4: tap-to-pin tooltip for title-only data (touch / keyboard) ---- */');
    DBMS_OUTPUT.PUT_LINE('var tipEl=null;');
    DBMS_OUTPUT.PUT_LINE('function hideTip(){ if(tipEl&&tipEl.parentNode) tipEl.parentNode.removeChild(tipEl); tipEl=null; }');
    DBMS_OUTPUT.PUT_LINE('function showTip(t){');
    DBMS_OUTPUT.PUT_LINE('  var txt=t.getAttribute("title"); if(!txt) return;');
    DBMS_OUTPUT.PUT_LINE('  hideTip(); tipEl=doc.createElement("div"); tipEl.className="tip"; tipEl.setAttribute("role","status"); tipEl.textContent=txt;');
    DBMS_OUTPUT.PUT_LINE('  bd.appendChild(tipEl);');
    DBMS_OUTPUT.PUT_LINE('  var r=t.getBoundingClientRect(), cw=doc.documentElement.clientWidth;');
    DBMS_OUTPUT.PUT_LINE('  tipEl.style.top=(window.scrollY+r.bottom+6)+"px";');
    DBMS_OUTPUT.PUT_LINE('  tipEl.style.left=Math.max(8,Math.min(window.scrollX+r.left,window.scrollX+cw-tipEl.offsetWidth-8))+"px";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  if(closest(ev.target,".tip")) return;');
    DBMS_OUTPUT.PUT_LINE('  var t=closest(ev.target,"[title]");');
    DBMS_OUTPUT.PUT_LINE('  if(!t||closest(ev.target,"a,button,summary,input,select,th,.tabs,.wchip,tr.sql-row")||!closest(t,"section,header.report")){ hideTip(); return; }');
    DBMS_OUTPUT.PUT_LINE('  showTip(t);');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){ if(ev.key==="Escape") hideTip(); });');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("scroll",function(){ if(tipEl) hideTip(); },{passive:true});');
    DBMS_OUTPUT.PUT_LINE('/* ---- keyboard: Cmd/Ctrl-K focus filter, Esc clears, J / K jump ---- */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("keydown",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target||{}, tag=(t.tagName||"").toLowerCase();');
    DBMS_OUTPUT.PUT_LINE('  var typing=(tag==="input"||tag==="textarea"||tag==="select"||t.isContentEditable);');
    DBMS_OUTPUT.PUT_LINE('  if((ev.metaKey||ev.ctrlKey)&&(ev.key==="k"||ev.key==="K")){');
    DBMS_OUTPUT.PUT_LINE('    ev.preventDefault(); if(fi){ fi.focus(); fi.select(); } return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if(ev.key==="Escape"){');
    DBMS_OUTPUT.PUT_LINE('    clearW(); closeView();');
    DBMS_OUTPUT.PUT_LINE('    if(fi&&fi.value){ fi.value=""; applyFilter(); }');
    DBMS_OUTPUT.PUT_LINE('    if(typing&&t.blur) t.blur();');
    DBMS_OUTPUT.PUT_LINE('    if(nav) nav.classList.remove("menu-open");');
    DBMS_OUTPUT.PUT_LINE('    return;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if(typing||ev.metaKey||ev.ctrlKey||ev.altKey) return;');
    DBMS_OUTPUT.PUT_LINE('  if(ev.key==="j"||ev.key==="J"){ ev.preventDefault(); jump(1); }');
    DBMS_OUTPUT.PUT_LINE('  else if(ev.key==="k"||ev.key==="K"){ ev.preventDefault(); jump(-1); }');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('</script>');
    -- Phase 4: the report body is one <main> landmark (display:contents,
    -- so the body flex layout is unchanged); closed in awr_trend.sql.
    DBMS_OUTPUT.PUT_LINE('<main id="main-start">');
    -- v1.6.0: the compared windows for the window component and the
    -- Timeline (built above): window.AWR_WIN = {np, w:[{o, d, l, s, e, t, v}]}
    -- oldest first; o = week_offset, d = column label, l = offset label,
    -- s / e = window start / end 'YYYY-MM-DD HH24:MI', t = full title,
    -- v = valid (Y / N).  Read by sql/lib/js_wingrid.plsql.
    -- Streamed through wg_buf (about 115 bytes a window): any window count.
    DECLARE
        v_flags VARCHAR2(32767) := v_win_json || '|';
        v_buf   VARCHAR2(32767) := '<script>window.AWR_WIN={"np":' || ~weeks_back || ',"w":[';
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            wg_buf(v_buf, CASE WHEN k < ~weeks_back THEN ',' END
                || '{"o":' || k
                || ',"d":"' || wg_date(k) || '"'
                || ',"l":"' || CASE WHEN k = 0 THEN 'current' ELSE '-' || off_label(k) END || '"'
                || ',"s":"' || TO_CHAR(wg_start(k), 'YYYY-MM-DD HH24:MI') || '"'
                || ',"e":"' || TO_CHAR(wg_end(k), 'YYYY-MM-DD HH24:MI') || '"'
                || ',"t":"' || TO_CHAR(wg_start(k), 'Dy DD Mon, HH24:MI', 'NLS_DATE_LANGUAGE=ENGLISH') || '-'
                            || TO_CHAR(wg_end(k), 'HH24:MI') || '"'
                || ',"v":"' || CASE WHEN INSTR(v_flags, '|' || k || '=Y|') > 0 THEN 'Y' ELSE 'N' END || '"}');
        END LOOP;
        wg_buf(v_buf, ']};</script>');
        DBMS_OUTPUT.PUT_LINE(v_buf);
    END;

    -- =========================================================
    -- v1.6.0 Activity, whole span: the bird's-eye view at the top of EVERY
    -- view (vw in-s in-t in-a), above the verdict.  Two stacked inline-SVG
    -- charts over one time axis -- active sessions by wait class
    -- (AWR_DATA.ashx) and by wait event (AWR_DATA.ashe, the top 14 + Other
    -- events), both payloads from 09's one ASH scan -- drawn by
    -- sql/lib/js_timeline.plsql (one chart factory, two instances; zoom,
    -- hover crosshair and the pinned window are linked).  Skeleton only:
    -- the panel stays hidden until the script runs; JS off shows only the
    -- ax-nojs note (ASH is not scored, every scored number is in the
    -- tables).  No ASH rows = the calm #ax-empty note.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<section id="activity" class="vw in-s in-t in-a ashtop" aria-labelledby="activity-h">'
        || '<h2 id="activity-h">Activity, whole span<small class="h2sub">ASH active sessions across every '
        || 'compared window, by wait class and by wait event</small></h2>'
        || '<p class="ax-nojs">These charts are drawn by the page script, so they need JavaScript. ASH is not '
        || 'scored: every scored number is in the tables below.</p>');
    DBMS_OUTPUT.PUT_LINE('<div class="ashx" id="ashx" role="group" aria-label="Active sessions over the whole span" hidden>'
        || '<div class="axh"><span class="axs" id="ax-range"></span>'
        || '<span class="axk" aria-hidden="true"><span><i class="kw"></i>compared window</span>'
        || '<span><i class="kw cur"></i>Current</span><span><i class="kw pin"></i>pinned</span></span>'
        || '<button type="button" class="axr" id="ax-reset" hidden>Reset zoom</button></div>'
        || '<p class="axe" id="ax-empty" hidden>No ASH samples in DBA_HIST_ACTIVE_SESS_HISTORY across the compared span.</p>');
    DBMS_OUTPUT.PUT_LINE('<div class="axch" id="ax-cls"><div class="axct"><h3>By wait class</h3>'
        || '<div class="axlg" role="group" aria-label="Wait classes: click to show or hide"></div></div>'
        || '<div class="axp"><svg class="axsvg" role="img" aria-label="Active sessions stacked by wait class over the '
        || 'whole compared span, the compared windows shaded and release markers drawn. Drag to zoom."></svg>'
        || '<div class="axbr" hidden></div></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="axch" id="ax-ev"><div class="axct"><h3>By wait event</h3>'
        || '<div class="axlg" role="group" aria-label="Wait events: click to show or hide"></div></div>'
        || '<div class="axp"><svg class="axsvg" role="img" aria-label="Active sessions stacked by wait event (the 14 '
        || 'largest, the rest as Other events) over the same span. Drag to zoom."></svg>'
        || '<div class="axbr" hidden></div></div></div>');
    DBMS_OUTPUT.PUT_LINE('<p class="axn2">Hover for the values; drag across either chart to zoom both '
        || '(6 hours or less shows the compared windows minute by minute), double-click to reset. Click a shaded window to pin it: the Timeline grid compares against it.</p>'
        || '</div></section>');
    -- =========================================================
    -- v1.6.0 Summary view: the verdict hero.  One rule-based sentence
    -- from the finding cards (the first two, in card order: the loudest
    -- card, then DB time when it is flagged), the counts as quiet pills,
    -- and two slots section 17 fills at the end of the run (it needs the
    -- file / segment / SQL / parameter data): the "likely source" line
    -- (#because-slot) and the one-line notes (#narrative-slot).  A quiet
    -- or unscorable window gets a calm sentence instead of an empty hero.
    -- =========================================================
    DBMS_OUTPUT.PUT_LINE('<section id="verdict" class="vw in-s hero" aria-label="Verdict">');
    IF v_n_usable = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<h1 class="verdict quiet">Too little history to score this window.</h1>');
        DBMS_OUTPUT.PUT_LINE('<p class="because">Scoring needs at least 3 valid prior windows; '
            || TO_CHAR(v_n_valid) || ' of ' || TO_CHAR(~weeks_back) || ' '
            || CASE WHEN v_n_valid = 1 THEN 'is' ELSE 'are' END
            || ' valid here (<a href="#windows">Windows</a>). The values are still listed in '
            || '<a href="#findings">Findings</a>.</p>');
    ELSIF v_order.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('<h1 class="verdict quiet">Nothing moved beyond its normal range.</h1>');
        DBMS_OUTPUT.PUT_LINE('<p class="because">All ' || TO_CHAR(v_n_normal) || ' scored metrics sit '
            || 'within their normal range over the prior ' || TO_CHAR(v_max_n) || ' window'
            || CASE WHEN v_max_n = 1 THEN '' ELSE 's' END
            || CASE WHEN v_n_impr > 0
                    THEN '; ' || TO_CHAR(v_n_impr) || ' improved' ELSE '' END
            || '.</p>');
    ELSE
        FOR k IN 1 .. LEAST(2, v_order.COUNT) LOOP
            DECLARE
                r mover_rec := v_scored(v_glead(v_order(k)));
                v_split VARCHAR2(1);
            BEGIN
                v_verdict := v_verdict || CASE WHEN k > 1 THEN '; ' END
                    || ent(DBMS_XMLGEN.CONVERT(metric_label(r.metric_domain, r.metric_name)),
                           finding_anchor(r.metric_domain, r.metric_name), 'metric')
                    || ' ' || move_txt(r.cur_val, r.prior_mean, r.change_bucket);
                IF v_order(k) = 'DBTIME' AND r.metric_name = 'DB time'
                   AND v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
                    v_split := time_split(v_scored(v_dbt).cur_val, v_scored(v_dbt).prior_mean,
                                          v_scored(v_cpu).cur_val, v_scored(v_cpu).prior_mean);
                    v_verdict := v_verdict || CASE v_split WHEN 'W' THEN ', all wait'
                                                           WHEN 'w' THEN ', mostly wait'
                                                           WHEN 'c' THEN ', mostly CPU'
                                                           WHEN 'm' THEN ', CPU and wait alike' END;
                END IF;
                -- 17 fills ", mostly on <segment>" when it knows the top one
                IF v_order(k) = 'IO' THEN
                    v_verdict := v_verdict || '<span class="vx" data-vx="io" hidden></span>';
                END IF;
            END;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('<h1 class="verdict">' || v_verdict || '.</h1>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('<p class="because" id="because-slot" hidden></p>');
    DBMS_OUTPUT.PUT_LINE('<ul class="pills" id="pills" aria-label="Counts">'
        || CASE WHEN v_order.COUNT > 0
                THEN '<li><a href="#findings"><b>' || v_order.COUNT || '</b> finding'
                     || CASE WHEN v_order.COUNT = 1 THEN '' ELSE 's' END || '</a></li>'
                     || '<li><a href="#findings"><b>' || v_n_moved || '</b> metric'
                     || CASE WHEN v_n_moved = 1 THEN '' ELSE 's' END || ' moved</a></li>' END
        || '<li class="pl-normal"><a href="#s-normal"><b>' || v_n_normal || '</b> metric'
        || CASE WHEN v_n_normal = 1 THEN '' ELSE 's' END || ' normal</a></li>'
        || CASE WHEN v_n_impr > 0
                THEN '<li><a href="#s-normal"><b>' || v_n_impr || '</b> improved</a></li>' END
        || '</ul>');
    DBMS_OUTPUT.PUT_LINE('<ul class="hnotes" id="narrative-slot" hidden></ul>');
    -- Only when the requested target_end had no snapshot within the 15-min
    -- edge guard does the resolving SELECT (awr_trend.sql) snap it back to
    -- the last actual snapshot -- flagged here so it is never silent.
    -- Equal strings (the common case) emit nothing.
    IF '~target_end_requested' <> '~target_end_resolved' THEN
        DBMS_OUTPUT.PUT_LINE('<p class="snapnote">Requested end '
            || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_requested', 1, 16))
            || ' had no snapshot within 15 min &mdash; snapped to last snapshot '
            || DBMS_XMLGEN.CONVERT(SUBSTR('~target_end_resolved', 1, 16))
            || '</p>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('</section>');
    -- =========================================================
    -- v1.6.0 Timeline view (Mock D): the skeleton only.  The aligned
    -- window grid (#tl; the whole-span ASH charts moved to the top of
    -- every view, section#activity above): the
    -- shared ruler (sql/lib/wingrid.plsql, dates as pin buttons) over six
    -- lanes the sections fill from their own cursors while the page parses
    -- (sql/lib/timeline.plsql tl_open / tl_close): activity (09),
    -- headline and load (07), waits (07 + 04), where the reads land
    -- (14 + 15), SQL (06 + 18), configuration (12).  A lane with no rows
    -- stays hidden.  With JavaScript off the templates stay inert, so the
    -- section shows its header and the tl-nojs note (every number is in
    -- All sections).  Section 16 (Day profile) joins the view below it.
    -- =========================================================
    DECLARE
        v_cells VARCHAR2(32767);
        v_st    DATE := wg_start(0);
        -- one lane: a head row (fold button, title, caption, counts) and
        -- the empty row box the sections fill
        FUNCTION lane_h(p_id VARCHAR2, p_title VARCHAR2, p_kind VARCHAR2,
                        p_cap VARCHAR2 DEFAULT NULL, p_note VARCHAR2 DEFAULT NULL,
                        p_noun VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        BEGIN
            RETURN '<div class="lane" id="lane-' || p_id || '" data-kind="' || p_kind || '"'
                || CASE WHEN p_note IS NOT NULL THEN ' data-note="' || p_note || '"' END
                || CASE WHEN p_noun IS NOT NULL THEN ' data-noun="' || p_noun || '"' END
                || ' role="rowgroup" hidden><div class="r gh2" role="row">'
                || '<div class="l" role="rowheader"><button class="lt2" type="button" aria-expanded="true">'
                || '<i class="car" aria-hidden="true"></i><span class="lti">' || p_title || '</span></button></div>'
                || v_cells || '<div class="g" role="cell"><span class="meta"></span></div>'
                || CASE WHEN p_cap IS NOT NULL THEN '<div class="cap"><span>' || p_cap || '</span></div>' END
                || '</div><div class="lrows"></div></div>';
        END lane_h;
    BEGIN
        FOR k IN REVERSE 0 .. ~weeks_back LOOP
            v_cells := v_cells || '<div class="c' || CASE WHEN k = 0 THEN ' cur' END
                || '" data-w="' || k || '"></div>';
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('<section id="timeline" class="vw in-t">'
            || '<h2>Timeline<small class="h2sub">Down a column: one window. Across a row: when it started.</small></h2>'
            || '<p class="tl-nojs">The Timeline is drawn by the page script; with JavaScript off it is not '
            || 'drawn, and every number it would show is in the sections below.</p>');
        wg_ruler_put('<div class="panel gridwrap wg hov" id="tl"' || wg_attr
            || ' role="table" aria-label="Current vs ' || ~weeks_back || ' prior windows, one column per window">',
            '<span class="ct">'
                || CASE WHEN ~step_hours = 168 THEN TO_CHAR(v_st, 'FMDay', 'NLS_DATE_LANGUAGE=ENGLISH') || ' '
                        WHEN ~step_hours = 24 THEN 'Daily ' END
                || CASE WHEN ~step_hours IN (24, 168)
                        THEN TO_CHAR(v_st, 'HH24:MI') || '&ndash;' || TO_CHAR(wg_end(0), 'HH24:MI')
                        ELSE 'Every ~step_label, ~win_label windows' END
                || '</span><span class="cs">' || (~weeks_back + 1) || ' windows</span>'
                || '<nav class="jumpnav" aria-label="Jump to lane"><a href="#lane-metrics">Load</a>'
                || '<a href="#lane-waits">Waits</a><a href="#lane-sql">SQL</a><a href="#lane-config">Config</a>'
                || CASE WHEN ~profile_days > 0 THEN '<a href="#day-profile">Day</a>' END || '</nav>',
                '<span class="gt" id="tl-gt">vs prior mean</span><span class="gs" id="tl-gs">click a date to pin</span>',
                'Y',
                '<div class="gbody" id="tl-body"><div class="gin" id="tl-in">');
        DBMS_OUTPUT.PUT_LINE(lane_h('activity', 'Activity', 'ash', NULL, 'ASH, not scored'));
        DBMS_OUTPUT.PUT_LINE(lane_h('metrics', 'Headline and load', 'scored'));
        DBMS_OUTPUT.PUT_LINE(lane_h('waits', 'Waits', 'scored', 'wait classes in AAS, events in seconds waited', NULL, 'events'));
        DBMS_OUTPUT.PUT_LINE(lane_h('objects', 'Where the reads land', 'ranked', NULL, 'ranked, not scored'));
        DBMS_OUTPUT.PUT_LINE(lane_h('sql', 'SQL', 'sql', 'elapsed s; a dash = not in the top ' || ~top_n));
        DBMS_OUTPUT.PUT_LINE(lane_h('config', 'Configuration', 'config'));
        DBMS_OUTPUT.PUT_LINE('</div></div></div></section>');
        -- the All sections view's heading (Mock D); the sections follow it
        -- in the order _style.sql gives them there ("All sections order")
        DBMS_OUTPUT.PUT_LINE('<section id="s-all" class="vw in-a vhead"><h2>All sections'
            || '<small class="h2sub">Every table of the report</small></h2></section>');
    END;
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 00_params END -->'); END;
/
