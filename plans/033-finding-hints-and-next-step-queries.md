# Plan 033: Finding cards say what the pattern usually means and give a copyable read-only next query

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/07_summary.sql sql/18_sqlmon.sql sql/_style.sql sql/23_plan_flame.sql sql/lib/src/js_planflame.js sql/24_blocking.sql sql/lib/src/js_design.js sql/lib/src/css_design.css demo/awrdemo/helpers.py demo/awrdemo/sections/s07_summary.py demo/awrdemo/sections/s18_sqlmon.py demo/verify_report.js`
> Plans 020-032 are executed before this one and edit several of these
> files (020 / 025 the card emission in 07, 025 / 026 / 032 CSS and
> verify_report block 6, 029 / 030 section 18). Those changes are expected.
> Compare only the excerpts quoted under "Current state": each must still be
> present (possibly with those plans' additions). An excerpt that is gone or
> restructured is a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW-MED (new wording the owner must accept; read-only queries only)
- **Depends on**: plans/026-cause-next-to-effect-io-card.md (soft: execute after it; 025 too, it hides the hint on folded cards)
- **Category**: direction (report UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: still valid. `07`, `18`,
  `helpers.py` and the s07 / s18 twins are unchanged; `_style.sql` and
  `00_params.sql` lines moved (+7 / +12). New since the first draft: the
  report designs (quiet / dashboard move the cards, but the hint travels
  inside its card; the design's table copy menu touches only `.tbl-tools`
  buttons, never `.copy-btn`) and sections 23 (Plan shape: adds its own
  "Plan shape" link to the plan card's footer) and 24 (Blocking: who
  blocked whom). Edits: keep the plan card's footer `span.evl` intact for
  23; the `ROW_LOCK` sentence points at the Blocking section (one link,
  one CSS rule; wording still the owner's call); `DISPLAY_AWR` needs the
  optional `DBA_HIST_SQL_PLAN` grant (noted); three demo pages,
  verify_report on classic and dashboard, refreshed DB-run pins and the
  section-pair count (29).

## Why this matters

The report says WHAT moved ("Physical reads 5.4x normal", "db file
scattered read x20.6", "table scans (long tables) x29.7") but leaves the
reader to know what that combination usually means and what to run next.
An experienced DBA reads "scattered reads + long-table scans" as "full
scans, look at the plans"; a less experienced reader does not. This plan
adds to each finding card one short, hedged, rule-based line "What this
usually means" and, where it helps, a copyable read-only SQL query for
the next step, filled with the exact DBID and snapshot range of the
Current window (and, on a plan-change card, the two plan hashes for
`DBMS_XPLAN.DISPLAY_AWR`). The rules are a small table in one include
file; nothing is free prose and nothing is guessed: a line appears only
when the measured rows match its rule.

## Current state

Background the executor needs:

- The report is produced by SQL\*Plus scripts: PL/SQL blocks print HTML
  with `DBMS_OUTPUT.PUT_LINE('...')`; a single quote inside a PL/SQL string
  is written `''`. Shared PL/SQL lives in `sql/lib/*.plsql` files that are
  `@@`-included inside a section's `DECLARE` block (they may declare only
  functions / procedures, and must come AFTER every plain variable; lint
  check 14).
- `sql/07_summary.sql` scores every LOAD (SYSSTAT), METRIC (SYSMETRIC) and
  WAIT (wait-class) metric once into the collection `v_findings` and
  prints one finding card per card group (`'IO'`, `'DBTIME'`, `'NET'`,
  `'COMMIT'`, `'PARSE'`, `'WRITE'`, `'WAIT:<class>'`), in
  `PROCEDURE emit_card(p_g VARCHAR2, p_pos PLS_INTEGER)` (lines 337-458).
  A row's `change_bucket` is `'large'` / `'moderate'` when it is a finding,
  and `cur_val` / `prior_mean` are its Current value and prior mean.
- For the cards' evidence, 07 also collects the top 2 foreground events of
  every wait class into `v_evs` (record `ev_rec`: `wclass`, `event`,
  `cur_val`, `mu`, `sd`, `n`, `shr`; lines 70-79), only when a wait class
  is flagged (`IF v_wait_flag THEN ... BULK COLLECT INTO v_evs ...`,
  lines 839-898). An event row is scored with `policy_bucket('WAIT',
  event, wclass, cur_val, mu, sd, n, shr)`, as `emit_card` does at line 372.
- `time_split(...)` (`sql/lib/finding_cards.plsql`) returns `'c'` (mostly
  CPU) / `'m'` (CPU and wait alike) / `'w'` / `'W'` (wait) for where the
  extra DB time went; `v_dbt` / `v_cpu` index the `DB time` / `DB CPU`
  rows in `v_findings`.
- `sql/18_sqlmon.sql` prints a plan-change card (`article.fc.chg`,
  id `f-plan-<sql_id>`) per statement whose plan changed into the Current
  window; its record `v_pc(c)` carries `sql_id`, `prior_ph` (the prior
  windows' usual plan hash) and `cur_ph` (the Current plan hash).
- `demo/` is a docs-only Python twin that renders
  `docs/examples/demo_busy_db.html`; `demo/awrdemo/helpers.py` twins every
  shared PL/SQL include (it even PARSES `sql/lib/metric_policy.plsql` with
  regexes, `helpers.py:385-415`, so the demo can never drift from it).
  `./tools/check.sh` fails on a stale demo.

Where the hint goes in `emit_card`, `sql/07_summary.sql:441-443`:

```sql
        DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>');
        IF v_nrel + v_ntw > 0 THEN
            DBMS_OUTPUT.PUT_LINE('<details class="rel"><summary>'
```

(the `</div>` closes the card body `div.fc-b`; the hint goes after it,
before the related-metrics fold.)

The includes of 07, lines 116-125 (the last one is
`@@sql/lib/timeline.plsql`); the last plain variable before them is
`v_meta       VARCHAR2(4000);` (line 115).

The plan card's last body line, `sql/18_sqlmon.sql:906-911`:

```sql
            DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>'
                || '<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
                || anchor_id('sm', v_id) || '">Timeline &rarr;</a>'
                || '<span class="evl"><a href="#topsql">Top SQL</a><a href="#sqlmon">SQL Monitor</a></span>'
                || '</footer></article>');
```

and 18's include list ends at line 150 with `@@sql/lib/timeline.plsql`
(line 151 is `BEGIN`).

Section 23 (Plan shape, `sql/23_plan_flame.sql`, client
`sql/lib/src/js_planflame.js`) adds, on `DOMContentLoaded`, a link
`a.pf-cl` "Plan shape" into the plan card's footer `span.evl`
(`#f-plan-<sql_id> .evl`). Step 4 below splits the PUT_LINE around that
footer: the `<span class="evl">...</span>` must stay exactly as it is.

Section 24 (Blocking, `sql/24_blocking.sql`) is ALWAYS emitted as
`<section id="blocking" ...>` (an evidence-library row in Summary, a full
section in All sections) and draws, for the Current window, who blocked
whom from ASH. The `ROW_LOCK` hint links to it (`#blocking`): a plain
in-page link to an id that always exists, which `demo/verify_report.js`
checks (every `href="#..."` must hit exactly one id).

The copyable-SQL pattern to reuse (section 18's drill line,
`sql/18_sqlmon.sql:604-609`; the click handler is the chrome's delegated
`.copy-btn` handler, `sql/00_params.sql:783-791`, which copies the text of
the element named in `data-copy`):

```sql
        DBMS_OUTPUT.PUT_LINE('<div class="codewrap" style="position:relative">');
        DBMS_OUTPUT.PUT_LINE('<button type="button" class="copy-btn" '
            || 'data-copy="#sqlmon-drill-' || s.sql_id || '">Copy</button>');
        DBMS_OUTPUT.PUT_LINE('<pre id="sqlmon-drill-' || s.sql_id || '" class="sql">'
            || DBMS_XMLGEN.CONVERT('SELECT DBMS_AUTO_REPORT.REPORT_REPOSITORY_DETAIL(rid=>'
               || TO_CHAR(s.drill_report_id) || ', type=>''ACTIVE'') FROM dual;')
            || '</pre></div>');
```

How 07 / 18 read the compared windows: `WITH @@sql/lib/windows_cte.sql`
followed directly by a `SELECT ... FROM valid_windows ...` (as in
`sql/18_sqlmon.sql:766-782`). `valid_windows` has one row per
(`week_offset`, `instance_number`) with `dbid`, `begin_snap_id`,
`end_snap_id`; `week_offset = 0` is the Current window. The window's
deltas are the snapshots `begin_snap_id + 1 .. end_snap_id` (06 / 18 join
`s.snap_id BETWEEN w.begin_snap_id + 1 AND w.end_snap_id`).

Repo rules that apply to every edit here:

- **Never type a tilde** in any `sql/` file, not even in a comment (every
  section runs under `SET DEFINE '~'`; lint 3). Write the DEFINE references
  `~inst_num` / `~dbid` ONLY where Step 3 / Step 5 say so — they are real
  substitutions, not prose.
- **Emitted text pure ASCII** (lint 25): use HTML entities (`&quot;`,
  `&middot;`). Do not type non-ASCII quotes or dashes in hint wording.
- `PUT_LINE` source lines under 2499 characters: each hint / template
  line in the include must stay under that (they are about 400-700).
- Never START a source line with `#`: it is SQL\*Plus's default
  SQLPREFIX and would run the rest of the line as a SQL\*Plus command
  while the block is being read. The `#TOKEN#` placeholders below always
  sit inside indented string literals, which is safe.
- AWR filters: `dbid IN (~dbid_list)` is the rule for the report's OWN
  queries (lint 4). The copyable queries are TEXT for the reader, filled
  with the Current window's single DBID; they never run inside the report.
- `DBMS_XMLGEN.CONVERT` on the query text (it escapes `'` and `<`); the
  copy button copies the decoded text.
- `sql/_style.sql` is also included by the fleet chrome: scope the new CSS
  under `.fc .fc-hint` (single-DB only).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Twin parser | `PYTHONPATH=demo python3 -c "from awrdemo import helpers as h; print(sorted(h.HINT_TEXT), sorted(h.HINT_SQL))"` | the rule ids of Step 1 |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote ...docs/examples/demo_busy_db*.html (... KB)` lines (classic, quiet, dashboard) |
| Demo fresh | `python3 demo/gen_demo_report.py --check` | exit 0, three `up to date:` lines |
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | last line `verify: OK` for each (about 3 min each; one at a time) |
| ASCII | `grep -nP '[^\x00-\x7F]' sql/lib/finding_hints.plsql sql/07_summary.sql sql/18_sqlmon.sql sql/_style.sql` | no output |

No database is available to you; owner checks are in "Maintenance notes".

## Scope

**In scope** (the only files you should modify or create):
- `sql/lib/finding_hints.plsql` (create)
- `sql/07_summary.sql` (variables, include, one Current-window query, rule
  selection functions, one emission in `emit_card`)
- `sql/18_sqlmon.sql` (include, plan-card hint)
- `sql/_style.sql` (CSS)
- `demo/awrdemo/helpers.py`, `demo/awrdemo/sections/s07_summary.py`, `demo/awrdemo/sections/s18_sqlmon.py`
- `demo/verify_report.js` (block 6)
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
  `demo_busy_db_dashboard.html` (regenerated)
- `CHANGELOG.md`, `CLAUDE.md`

**Out of scope** (do NOT touch):
- Scoring, card grouping, card order (`metric_policy.plsql`,
  `finding_cards.plsql`): rules only READ the scored rows.
- Running any of the next-step queries inside the report (they are text).
- Free-text or "AI" wording: only the fixed table of Step 1.
- `sql/17_narrative.sql`, the verdict, the fleet report.
- The design files (`sql/lib/src/js_design.js`, `css_design.css`) and the
  visualization sections 20-28: the hint only LINKS to `#blocking`.

## Git workflow

- Branch: `advisor/033-finding-hints` from `main`, which must contain
  `5594f2c` (`git merge-base --is-ancestor 5594f2c HEAD` exits 0; if not,
  STOP: the checkout predates the designs and sections 20-28).
- Conventional commits, e.g.
  `feat(report): finding cards say what the pattern usually means, with a read-only next query`.
- Do NOT push or open a PR unless the operator instructed it.

## Target UI (inside a finding card, under its evidence, above "N related metrics")

```
 ------------------------------------------------------------------------
 What this usually means. Scattered or direct-path reads rising together
 with long-table scans usually mean more full scans: a changed plan, an
 index that is no longer used, or a new statement. The statements reading
 the most blocks in the Current window are the place to start.
 Next step (read-only):
 +--------------------------------------------------------------- [COPY]+
 | SELECT sql_id, SUM(disk_reads_delta) AS disk_reads, ...               |
 | FROM   dba_hist_sqlstat                                               |
 | WHERE  dbid = 1483726519 AND snap_id BETWEEN 43201 AND 43201          |
 | ...                                                                   |
 +-----------------------------------------------------------------------+
```

## The rules (the whole table)

| Rule id | Card group | Fires when (all from rows 07 already scored) | Query |
|---|---|---|---|
| `IO_SCANS` | `IO` | `table scans (long tables)` flagged up, OR event `db file scattered read` / `direct path read` flagged up | top statements by blocks read |
| `IO_SINGLE` | `IO` | not `IO_SCANS`, and event `db file sequential read` flagged up | top statements by blocks read |
| `COMMIT_LAT` | `COMMIT` | event `log file sync` flagged up AND `user commits` NOT flagged up | `log file parallel write` average ms per snapshot |
| `NET_PAYLOAD` | `NET` | event `SQL*Net more data to client` flagged up, OR `bytes sent via SQL*Net to client` flagged up | top statements by rows processed |
| `HARD_PARSE` | `PARSE` | `parse count (hard)` flagged up | statements sharing a force-matching signature (literals) |
| `DBTIME_CPU` | `DBTIME` | `time_split` is `'c'` or `'m'` | top statements by CPU |
| `ROW_LOCK` | `WAIT:Application` | event `enq: TX - row lock contention` flagged up | ASH: blocking sessions and statements |
| `PLAN` | plan-change card (18) | always (the card exists only for a plan change) | `DBMS_XPLAN.DISPLAY_AWR` of both plans |

"Flagged up" = the row's bucket is `large` or `moderate` AND its Current
value is above its prior mean. An event is only known when it is among the
top 2 events of its class (`v_evs`); that is enough for these rules.

## Steps

### Step 1: Create `sql/lib/finding_hints.plsql`

Create the file with exactly this content (ASCII only; every `WHEN` line is
ONE source line because the demo twin parses them; no space directly
before a `#NL#` token, because SQL\*Plus trims trailing spaces of spooled
lines and the report would then differ from the demo):

```sql
--
-- sql/lib/finding_hints.plsql
--
-- Rule-based "What this usually means" lines and copyable read-only "Next
-- step" queries for the Summary view's finding cards (07) and plan-change
-- cards (18).  Plan 033 (2026-11-17).
--
-- THE TABLE.  One hint per rule id.  07's pick_hint() decides which rule a
-- card gets from the scored rows on that card; 18 always uses PLAN.  Every
-- WHEN line below is ONE source line of the shape
--     WHEN <the rule id, quoted> THEN <the text, quoted>
-- because the demo twin (demo/awrdemo/helpers.py, HINT_TEXT / HINT_SQL)
-- parses them with a regular expression.
-- Wording: hedged ("usually"), names nothing the report did not measure,
-- plain ASCII (HTML entities only), no tilde.  A text may link to a
-- section that is ALWAYS emitted (ROW_LOCK -> #blocking, section 24);
-- never to a row that depends on top-N.
--
-- Query templates: read-only SELECTs over DBA_HIST views the report already
-- reads.  Placeholders, filled by hint_fill():
--   #DBID#   the Current window's DBID      #B0#  its begin snapshot id
--   #B#      its first delta snapshot (begin + 1)   #E#  its end snapshot id
--   #INST#   ' AND instance_number = n' when the report is filtered to one
--            instance, else nothing
--   #SQLID#  #PH1#  #PH2#   the plan card's sql_id and the two plan hashes
--   #NL#: a line break (never put a space right before it)
-- A rule without a query has no WHEN line in hint_sql (it returns NULL).
--
-- To add a rule: one WHEN line in hint_text, optionally one in hint_sql,
-- one condition in pick_hint() in sql/07_summary.sql and in the demo twin's
-- _pick_hint (demo/awrdemo/sections/s07_summary.py), then regenerate the
-- demo (helpers.py reads the two tables from this file).
--
-- Include inside a DECLARE block after every plain variable.  Declares only
-- functions (no TYPE).
--

    FUNCTION hint_text(p_rule VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_rule
            WHEN 'IO_SCANS' THEN 'Scattered or direct-path reads rising together with long-table scans usually mean more full scans: a changed plan, an index that is no longer used, or a new statement. The statements reading the most blocks in the Current window are the place to start.'
            WHEN 'IO_SINGLE' THEN 'More single-block reads usually mean index or rowid access touching more blocks: a less selective plan, more rows per call, or a colder buffer cache. The statements reading the most blocks in the Current window are the place to start.'
            WHEN 'COMMIT_LAT' THEN 'Commit waits rose while the commit rate did not, so each commit waited longer. That usually points to slower redo writes (log file parallel write) or a busy log writer rather than to the application.'
            WHEN 'NET_PAYLOAD' THEN 'More &quot;SQL*Net more data to client&quot; or more bytes sent to clients usually means larger result sets or a smaller fetch (array) size in a client. Compare bytes sent per user call with the prior windows.'
            WHEN 'HARD_PARSE' THEN 'More hard parses usually mean statements built with literals instead of bind variables, or cursors invalidated by DDL or statistics gathering.'
            WHEN 'DBTIME_CPU' THEN 'DB time grew mostly on CPU: more work per call (plans, rows) or more calls. The statements using the most CPU in the Current window are the place to start.'
            WHEN 'ROW_LOCK' THEN 'Row lock waits (enq: TX - row lock contention) mean sessions waiting for rows that other sessions changed and have not committed yet: usually application locking or long transactions. The <a href="#blocking">Blocking</a> view shows who blocked whom in the Current window.'
            WHEN 'PLAN' THEN 'A new plan usually follows new optimizer statistics, a different bind value at hard parse, a new or changed index, or an optimizer parameter change. Comparing the two plans shows which step changed.'
        END;
    END hint_text;

    FUNCTION hint_sql(p_rule VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_rule
            WHEN 'IO_SCANS' THEN 'SELECT sql_id, SUM(disk_reads_delta) AS disk_reads, SUM(buffer_gets_delta) AS gets,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY disk_reads DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'IO_SINGLE' THEN 'SELECT sql_id, SUM(disk_reads_delta) AS disk_reads, SUM(buffer_gets_delta) AS gets,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY disk_reads DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'COMMIT_LAT' THEN 'SELECT snap_id, instance_number,#NL#       ROUND((time_waited_micro - LAG(time_waited_micro) OVER (PARTITION BY instance_number ORDER BY snap_id))#NL#             / NULLIF(total_waits - LAG(total_waits) OVER (PARTITION BY instance_number ORDER BY snap_id), 0)#NL#             / 1000, 3) AS avg_write_ms#NL#FROM   dba_hist_bg_event_summary#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B0# AND #E##INST##NL#AND    event_name = ''log file parallel write''#NL#ORDER  BY instance_number, snap_id;'
            WHEN 'NET_PAYLOAD' THEN 'SELECT sql_id, SUM(rows_processed_delta) AS rows_processed, SUM(fetches_delta) AS fetches,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY rows_processed DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'HARD_PARSE' THEN 'SELECT force_matching_signature, COUNT(DISTINCT sql_id) AS sql_ids,#NL#       SUM(executions_delta) AS execs, MIN(sql_id) AS one_sql_id#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#AND    force_matching_signature <> 0#NL#GROUP  BY force_matching_signature#NL#HAVING COUNT(DISTINCT sql_id) > 5#NL#ORDER  BY sql_ids DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'DBTIME_CPU' THEN 'SELECT sql_id, ROUND(SUM(cpu_time_delta) / 1e6, 1) AS cpu_s,#NL#       SUM(executions_delta) AS execs#NL#FROM   dba_hist_sqlstat#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#GROUP  BY sql_id#NL#ORDER  BY cpu_s DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'ROW_LOCK' THEN 'SELECT blocking_inst_id, blocking_session, sql_id, COUNT(*) AS samples#NL#FROM   dba_hist_active_sess_history#NL#WHERE  dbid = #DBID# AND snap_id BETWEEN #B# AND #E##INST##NL#AND    event = ''enq: TX - row lock contention''#NL#GROUP  BY blocking_inst_id, blocking_session, sql_id#NL#ORDER  BY samples DESC#NL#FETCH  FIRST 10 ROWS ONLY;'
            WHEN 'PLAN' THEN 'SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR(''#SQLID#'', #PH1#, #DBID#));#NL#SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR(''#SQLID#'', #PH2#, #DBID#));'
        END;
    END hint_sql;

    -- fill a template; p_begin = the window's begin snapshot id
    FUNCTION hint_fill(p_tpl   VARCHAR2,
                       p_dbid  NUMBER,
                       p_begin NUMBER,
                       p_end   NUMBER,
                       p_inst  NUMBER,
                       p_sqlid VARCHAR2 DEFAULT NULL,
                       p_ph1   NUMBER   DEFAULT NULL,
                       p_ph2   NUMBER   DEFAULT NULL) RETURN VARCHAR2 IS
        v VARCHAR2(4000) := p_tpl;
    BEGIN
        IF v IS NULL THEN RETURN NULL; END IF;
        v := REPLACE(v, '#INST#', CASE WHEN p_inst > 0 THEN ' AND instance_number = ' || TO_CHAR(p_inst) END);
        v := REPLACE(v, '#SQLID#', p_sqlid);
        v := REPLACE(v, '#PH1#', TO_CHAR(p_ph1));
        v := REPLACE(v, '#PH2#', TO_CHAR(p_ph2));
        v := REPLACE(v, '#DBID#', TO_CHAR(p_dbid));
        v := REPLACE(v, '#B0#', TO_CHAR(p_begin));
        v := REPLACE(v, '#B#', TO_CHAR(p_begin + 1));
        v := REPLACE(v, '#E#', TO_CHAR(p_end));
        RETURN REPLACE(v, '#NL#', CHR(10));
    END hint_fill;

    -- a card's hint block: the hedged line and, when p_sql is given, a
    -- copyable read-only "Next step" (the .codewrap / .copy-btn pattern of
    -- sections 01 and 18); p_key keeps the pre id unique (the card id)
    FUNCTION hint_block(p_rule VARCHAR2, p_key VARCHAR2, p_sql VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_rule IS NULL OR hint_text(p_rule) IS NULL THEN RETURN NULL; END IF;
        RETURN '<div class="fc-hint" data-hint="' || p_rule || '"><p><b>What this usually means.</b> '
            || hint_text(p_rule) || '</p>'
            || CASE WHEN p_sql IS NOT NULL THEN
                   '<p class="fc-next">Next step (read-only):</p>'
                   || '<div class="codewrap" style="position:relative">'
                   || '<button type="button" class="copy-btn" data-copy="#hq-' || p_key || '">Copy</button>'
                   || '<pre id="hq-' || p_key || '" class="sql">' || DBMS_XMLGEN.CONVERT(p_sql) || '</pre></div>'
               END
            || '</div>';
    END hint_block;
```

**Verify**: `grep -nP '[^\x00-\x7F]' sql/lib/finding_hints.plsql` → no output.
`grep -c "WHEN '" sql/lib/finding_hints.plsql` → `16`.
`grep -nP '^(?!\s*--).* #NL#' sql/lib/finding_hints.plsql` → no output (no code line has a space before `#NL#`).
`awk 'length($0) > 2400' sql/lib/finding_hints.plsql | wc -l` → `0`.

### Step 2: Twin the include in `demo/awrdemo/helpers.py`

After the metric-policy parser block (it ends around line 470, before
`def policy_bucket`), add:

```python
# ---------------------------------------------------------------------
# sql/lib/finding_hints.plsql (plan 033) -- the two tables are parsed from
# the SQL include itself, like the metric policy above.
# ---------------------------------------------------------------------

_HINTS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                           "sql", "lib", "finding_hints.plsql")
_HINT_RE = re.compile(r"WHEN\s+'([A-Z0-9_]+)'\s+THEN\s+'((?:[^']|'')*)'")


def _load_hints():
    text, sql, cur = {}, {}, None
    with open(_HINTS_PATH, encoding="utf-8") as fh:
        for line in fh:
            if "FUNCTION hint_text" in line:
                cur = text
            elif "FUNCTION hint_sql" in line:
                cur = sql
            elif "FUNCTION " in line:
                cur = None
            if cur is None:
                continue
            m = _HINT_RE.search(line)
            if m:
                cur[m.group(1)] = m.group(2).replace("''", "'")
    return text, sql


HINT_TEXT, HINT_SQL = _load_hints()


def hint_fill(tpl, dbid, begin, end, inst, sqlid=None, ph1=None, ph2=None):
    """hint_fill() of sql/lib/finding_hints.plsql."""
    if tpl is None:
        return None
    s = lambda v: "" if v is None else str(v)
    v = tpl.replace("#INST#", " AND instance_number = " + str(inst) if inst and inst > 0 else "")
    v = v.replace("#SQLID#", s(sqlid)).replace("#PH1#", s(ph1)).replace("#PH2#", s(ph2))
    v = v.replace("#DBID#", s(dbid)).replace("#B0#", s(begin))
    v = v.replace("#B#", s(None if begin is None else begin + 1)).replace("#E#", s(end))
    return v.replace("#NL#", "\n")


def hint_block(rule, key, sql) -> str:
    """hint_block() of sql/lib/finding_hints.plsql."""
    if rule is None or rule not in HINT_TEXT:
        return ""
    return ('<div class="fc-hint" data-hint="' + rule + '"><p><b>What this usually means.</b> '
            + HINT_TEXT[rule] + '</p>'
            + (('<p class="fc-next">Next step (read-only):</p>'
                '<div class="codewrap" style="position:relative">'
                '<button type="button" class="copy-btn" data-copy="#hq-' + key + '">Copy</button>'
                '<pre id="hq-' + key + '" class="sql">' + esc(sql) + '</pre></div>') if sql else '')
            + '</div>')
```

(`os`, `re` and `esc` already exist in `helpers.py`; check the imports at
the top of the file.) The PL/SQL `hint_block` returns NULL when there is no
rule; the twin returns `""` and callers only append it when a rule exists.

**Verify**: the "Twin parser" command from the Commands table prints
`['COMMIT_LAT', 'DBTIME_CPU', 'HARD_PARSE', 'IO_SCANS', 'IO_SINGLE', 'NET_PAYLOAD', 'PLAN', 'ROW_LOCK']`
twice (both tables have all 8 ids).

### Step 3: Choose and print the hint on 07's cards

In `sql/07_summary.sql`:

1. Next to `v_meta` (line 115, BEFORE the includes) add:

   ```sql
       v_cw_dbid    NUMBER;   -- plan 033: the Current window's DBID and snapshot range,
       v_cw_b       NUMBER;   --   for the cards' read-only "Next step" queries
       v_cw_e       NUMBER;
   ```

2. After `@@sql/lib/timeline.plsql` (the last include, line 125) add
   `    @@sql/lib/finding_hints.plsql`.

3. Directly ABOVE `PROCEDURE emit_card` (and above plan 025's `head_txt`
   if it is there), add:

   ```sql
       -- plan 033: a scored row moved up AND is a finding (large / moderate)
       FUNCTION f_up(p_dom VARCHAR2, p_name VARCHAR2) RETURN BOOLEAN IS
       BEGIN
           FOR i IN 1 .. v_findings.COUNT LOOP
               IF v_findings(i).metric_domain = p_dom AND v_findings(i).metric_name = p_name THEN
                   IF v_findings(i).change_bucket IN ('large', 'moderate')
                      AND v_findings(i).cur_val > v_findings(i).prior_mean THEN
                       RETURN TRUE;
                   END IF;
                   RETURN FALSE;
               END IF;
           END LOOP;
           RETURN FALSE;
       END f_up;

       -- plan 033: one of the card evidence events (the top 2 of a class,
       -- v_evs) moved up and is a finding by the wait policy
       FUNCTION ev_up(p_event VARCHAR2) RETURN BOOLEAN IS
           v_b VARCHAR2(40);
       BEGIN
           FOR e IN 1 .. v_evs.COUNT LOOP
               IF v_evs(e).event = p_event THEN
                   v_b := policy_bucket('WAIT', v_evs(e).event, v_evs(e).wclass, v_evs(e).cur_val,
                                        v_evs(e).mu, v_evs(e).sd, v_evs(e).n, v_evs(e).shr);
                   IF v_b IN ('large', 'moderate') AND v_evs(e).cur_val > NVL(v_evs(e).mu, 0) THEN
                       RETURN TRUE;
                   END IF;
               END IF;
           END LOOP;
           RETURN FALSE;
       END ev_up;

       -- plan 033: which rule of sql/lib/finding_hints.plsql a card gets
       -- (NULL = none); the table of rules is in that file's header
       FUNCTION pick_hint(p_g VARCHAR2) RETURN VARCHAR2 IS
           v_split VARCHAR2(1);
       BEGIN
           IF p_g = 'IO' THEN
               IF f_up('LOAD', 'table scans (long tables)') OR ev_up('db file scattered read')
                  OR ev_up('direct path read') THEN
                   RETURN 'IO_SCANS';
               END IF;
               IF ev_up('db file sequential read') THEN RETURN 'IO_SINGLE'; END IF;
           ELSIF p_g = 'COMMIT' THEN
               IF ev_up('log file sync') AND NOT f_up('LOAD', 'user commits') THEN
                   RETURN 'COMMIT_LAT';
               END IF;
           ELSIF p_g = 'NET' THEN
               IF ev_up('SQL*Net more data to client')
                  OR f_up('LOAD', 'bytes sent via SQL*Net to client') THEN
                   RETURN 'NET_PAYLOAD';
               END IF;
           ELSIF p_g = 'PARSE' THEN
               IF f_up('LOAD', 'parse count (hard)') THEN RETURN 'HARD_PARSE'; END IF;
           ELSIF p_g = 'DBTIME' THEN
               IF v_dbt IS NOT NULL AND v_cpu IS NOT NULL THEN
                   v_split := time_split(v_findings(v_dbt).cur_val, v_findings(v_dbt).prior_mean,
                                         v_findings(v_cpu).cur_val, v_findings(v_cpu).prior_mean);
                   IF v_split IN ('c', 'm') THEN RETURN 'DBTIME_CPU'; END IF;
               END IF;
           ELSIF p_g = 'WAIT:Application' THEN
               IF ev_up('enq: TX - row lock contention') THEN RETURN 'ROW_LOCK'; END IF;
           END IF;
           RETURN NULL;
       END pick_hint;
   ```

   (`f_up` / `ev_up` return only TRUE or FALSE, never NULL, so `NOT f_up(...)`
   is safe.)

4. In the main block, directly BEFORE the `IF v_order.COUNT > 0 THEN` that
   prints the cards (line 940; plan 025 may have put the triage list right
   after it — insert above that `IF`), add:

   ```sql
    -- plan 033: the Current window's DBID and snapshot range, for the
    -- cards' read-only "Next step" queries (one row: MIN / MAX over the
    -- instances; all NULL when the Current window is not valid)
    IF v_order.COUNT > 0 THEN
        FOR cw IN (
            WITH
            @@sql/lib/windows_cte.sql
            SELECT MIN(dbid) AS dbid, MIN(begin_snap_id) AS b, MAX(end_snap_id) AS e
            FROM   valid_windows
            WHERE  week_offset = 0
        ) LOOP
            v_cw_dbid := cw.dbid;
            v_cw_b    := cw.b;
            v_cw_e    := cw.e;
        END LOOP;
    END IF;
   ```

5. In `emit_card`, add a local variable `v_rule VARCHAR2(20);` to its
   declarations (with the others, e.g. after `v_eb VARCHAR2(40);`), and
   right AFTER the line
   `DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>');`
   add:

   ```sql
        -- plan 033: what this usually means, and a read-only next query
        v_rule := pick_hint(p_g);
        IF v_rule IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE(hint_block(v_rule, v_id,
                CASE WHEN v_cw_b IS NOT NULL
                     THEN hint_fill(hint_sql(v_rule), v_cw_dbid, v_cw_b, v_cw_e, ~inst_num) END));
        END IF;
   ```

**Verify**: `./lint.sh` → clean (checks 13 / 14 / 16 / 17 / 22 cover
include order and declarations). `grep -c 'pick_hint(p_g)' sql/07_summary.sql` → `1`.

### Step 4: The plan-change card's hint (section 18)

In `sql/18_sqlmon.sql`:

1. After `@@sql/lib/timeline.plsql` (line 150, the last include before
   `BEGIN`) add `    @@sql/lib/finding_hints.plsql`.
2. Split the plan card's last body `PUT_LINE` (lines 906-911, quoted above)
   into three statements: the evidence list, the hint, the footer (the
   footer text is unchanged, character for character: section 23's script
   looks for its `span.evl`):

   ```sql
            DBMS_OUTPUT.PUT_LINE('<dl class="ev">' || v_ev || '</dl></div>');
            -- plan 033: what a plan change usually means, and both plans
            DBMS_OUTPUT.PUT_LINE(hint_block('PLAN', v_cid,
                CASE WHEN v_pc(c).prior_ph IS NOT NULL AND v_pc(c).cur_ph IS NOT NULL
                     THEN hint_fill(hint_sql('PLAN'), ~dbid, NULL, NULL, 0, v_id,
                                    v_pc(c).prior_ph, v_pc(c).cur_ph) END));
            DBMS_OUTPUT.PUT_LINE('<footer class="fc-f"><a class="jump" href="#timeline" data-tl="tl-'
                || anchor_id('sm', v_id) || '">Timeline &rarr;</a>'
                || '<span class="evl"><a href="#topsql">Top SQL</a><a href="#sqlmon">SQL Monitor</a></span>'
                || '</footer></article>');
   ```

   `~dbid` is the report's primary DBID (the one of the latest snapshot),
   which holds the Current window. (If plans 029 / 030 changed this
   statement, keep their changes and only insert the hint between the
   `</dl></div>` and the `<footer`.)

**Verify**: `./lint.sh` → clean. `grep -c "hint_block('PLAN'" sql/18_sqlmon.sql` → `1`.

### Step 5: CSS

In `sql/_style.sql`, after the `.fc` block's last line
`DBMS_OUTPUT.PUT_LINE('.fc .cfg-more{margin:0;padding:var(--s2) 0 0;font-size:12.5px;color:var(--muted)}');`
(line 1368) and after any lines plans 025 / 026 added right there, add:

```sql
    -- plan 033: a card's "What this usually means" line and read-only next
    -- query (sql/lib/finding_hints.plsql); hidden on a folded card (025)
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint{margin:var(--s4) 0 0;padding:var(--s3) 0 0;border-top:1px solid var(--line-soft);font-size:13.5px;line-height:1.5;color:var(--ink-soft)}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint p{margin:0;max-width:110ch}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint b{color:var(--ink);font-weight:600}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint .fc-next{margin:var(--s3) 0 var(--s2);font-size:12.5px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint pre.sql{margin:0}');
    DBMS_OUTPUT.PUT_LINE('.fc .fc-hint p a{color:inherit;text-decoration:underline dotted;text-underline-offset:2px}');
    DBMS_OUTPUT.PUT_LINE('.fc.fold > .fc-hint{display:none}');
```

(The report has no global link colour: without the `p a` rule the
`#blocking` link would render browser-blue, which `demo/verify_report.js`
fails. No quiet / dashboard rule is needed: every token used here exists
in both stylesheets, and the design's table copy menu (`js_design.js`
`toolMenus()`) only moves `.tbl-tools > .tool-btn`, never a `.copy-btn`.)

**Verify**: `./lint.sh` → clean; `grep -nP '[^\x00-\x7F]' sql/_style.sql` → no output.

### Step 6: Re-port the demo twins

1. `demo/awrdemo/sections/s07_summary.py`:
   - Add `_f_up(findings, dom, name)`, `_ev_up(evs, event)` and
     `_pick_hint(g, findings, evs, dbt, cpu)` mirroring Step 3 exactly
     (`h.policy_bucket('WAIT', e["event"], e["wclass"], e["cur"], e["mu"],
     e["sd"], e["n"], e["shr"])` for events, as `_card` does;
     `f.bucket in ("large", "moderate") and f.cur > f.mu` for rows, with
     `f.cur` / `f.mu` not None; `h.time_split(dbt.cur, dbt.mu, cpu.cur, cpu.mu)`).
   - In `emit`, compute the Current window like Step 3.4:
     `cw = next((x for x in w.valid_windows if x.week_offset == 0), None)`
     and `(cw.dbid, cw.begin_snap_id, cw.end_snap_id)` when `cw` is not
     None (only when there is at least one card).
   - In `_card`, right after `out.append('<dl class="ev">' + ev + '</dl></div>')`,
     append `h.hint_block(rule, cid, sql)` when `rule` is not None, where
     `sql = h.hint_fill(h.HINT_SQL.get(rule), dbid, b, e, w.inst_num)` when
     `b` is not None else `None`. Pass whatever `_card` needs as new
     parameters (keep its existing ones).
2. `demo/awrdemo/sections/s18_sqlmon.py`, plan card (around line 241): split
   the `put('<dl class="ev">' + ev + "</dl></div>" + '<footer ...')` the same
   way as Step 4 and put
   `H.hint_block("PLAN", cid, H.hint_fill(H.HINT_SQL["PLAN"], w.dbid, None, None, 0, sid, c["prior_ph"], c["cur_ph"]) if c["prior_ph"] is not None and c["cur_ph"] is not None else None)`
   between them. (Check the twin's names for the DBID (`w.dbid`, set from
   `model.DBID`) and the record keys `prior_ph` / `cur_ph` — they are used a
   few lines above, in the `whereln` title.)
3. Regenerate twice (same md5).

**Verify**: `python3 demo/gen_demo_report.py --check` → exit 0.
`grep -o 'data-hint="[A-Z_]*"' docs/examples/demo_busy_db.html | sort | uniq -c`
lists at least `IO_SCANS` and `PLAN` (on the demo at the planned commit
also `NET_PAYLOAD` and `COMMIT_LAT`); the same command on
`docs/examples/demo_busy_db_dashboard.html` prints the same lines (the
markup is design-independent).
`grep -c 'id="hq-f-io"' docs/examples/demo_busy_db.html` → `1`.
`grep -nP '[^\x00-\x7F]' docs/examples/demo_busy_db*.html | wc -l` → `0`.

### Step 7: Extend the browser smoke test

In `demo/verify_report.js` block 6, inside the `page.evaluate` callback
before `window.AWR_setView('all', false);`, add:

```js
      // plan 033: rule-based hints; a next-step query is a copyable SELECT
      const hints = [...document.querySelectorAll('article.fc .fc-hint[data-hint]')];
      out.hints = hints.map(x => x.closest('article.fc').id + ':' + x.getAttribute('data-hint')).join(',');
      out.hintsOk = hints.every(x => {
        const pre = x.querySelector('pre.sql'), btn = x.querySelector('.copy-btn[data-copy]');
        return x.querySelector('p b') && (!pre || (btn && document.querySelector(btn.getAttribute('data-copy')) === pre
          && /^SELECT /.test(pre.textContent) && !/#[A-Z0-9]+#/.test(pre.textContent)));
      });
      // the plan card keeps section 23's "Plan shape" link in its footer
      out.hintPfl = [...document.querySelectorAll('article.fc.chg[id^="f-plan-"]')].every(c => c.querySelector('.fc-f .evl a[href="#topsql"]'));
      // dashboard design: the plan card's query never widens the side column
      const side = document.querySelector('aside.dside');
      out.hintSide = side ? side.scrollWidth <= side.clientWidth + 1 : true;
```

and next to the other `fail(...)` lines:

```js
    if (!p4.hintsOk) fail('card hints: a hint without its line, or a next-step query not copyable / with an unfilled placeholder: ' + p4.hints);
    if (!p4.hintPfl) fail('card hints: a plan card lost its footer links (section 23 adds "Plan shape" there)');
    if (!p4.hintSide) fail('card hints: the dashboard side column is wider than its box');
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/f-io:IO_SCANS/.test(p4.hints)) fail('demo: the Physical I/O card should carry the IO_SCANS hint, got ' + p4.hints);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/f-plan-[a-z0-9]+:PLAN/.test(p4.hints)) fail('demo: the plan-change card should carry the PLAN hint, got ' + p4.hints);
```

(Section 6 runs in every design. In the dashboard the side column is
measured while Summary is shown; `pre.sql` wraps (`white-space:pre-wrap`)
and scrolls on its own (`overflow-x:auto`), so it should pass as is.) Add
to the header comment's phase 4 bullet: "card hints (rule id, line,
copyable read-only query with no unfilled placeholder; the plan card keeps
its footer links; the dashboard side column does not overflow)".

**Verify**: the browser smoke test → `verify: OK`; the `phase 4` JSON has
`"hintsOk":true` and `"hints"` containing `f-io:IO_SCANS` and a
`f-plan-...:PLAN`.

### Step 8: Documentation

1. `CHANGELOG.md`, `## Unreleased` → `### Report`: "**What a finding
   usually means.** Finding and plan-change cards carry one hedged,
   rule-based line (full scans, single-block reads, commit latency, result
   size, hard parses, CPU, row locks, plan change) and, where useful, a
   copyable read-only query for the next step, filled with the Current
   window's DBID and snapshot range (or `DBMS_XPLAN.DISPLAY_AWR` for both
   plans). The rules are one table in `sql/lib/finding_hints.plsql`."
2. `CLAUDE.md`: in the `sql/lib/` tree list add
   `finding_hints.plsql   -- plan 033: hint_text / hint_sql rule tables + hint_fill / hint_block (07, 18); one-line WHEN rows parsed by helpers.py`;
   in "Summary view pieces" add that a card may carry `div.fc-hint[data-hint]`
   (07's `pick_hint`, 18's `PLAN`), with the "to add a rule" recipe from the
   include's header.

**Verify**: `./tools/check.sh` → `check.sh: all checks passed`.

## Test plan

- `./lint.sh`; the twin-parser command (both tables complete); demo
  regenerated twice (same md5 for each of the three pages), `--check`.
- Browser smoke test with the Step 7 checks on the classic and the
  dashboard demo (every hint has its line; every query is a `SELECT` in a
  `pre` its copy button points at; no `#...#` placeholder left; the demo's
  I/O and plan cards carry their hints; the plan card keeps its footer
  links; the dashboard side column does not overflow).
- Manual (optional): Summary view, click "Copy" on the I/O card's query and
  paste it: one statement, the demo's DBID and snapshot ids, ends in `;`.
  In the dashboard demo, open the Physical I/O row: the hint is inside the
  card; the plan card in "What changed around it" shows its query wrapped
  inside the narrow column and still has its "Plan shape" footer link.

## Done criteria

- [ ] `sql/lib/finding_hints.plsql` exists, ASCII only, 16 `WHEN` lines, no space before `#NL#`
- [ ] `./lint.sh` exits 0
- [ ] `python3 demo/gen_demo_report.py --check` exits 0 (three pages); two runs give the same md5s
- [ ] `./tools/check.sh` prints `check.sh: all checks passed`
- [ ] `demo/verify_report.js` ends with `verify: OK`, with the Step 7 checks, on `demo_busy_db.html` AND `demo_busy_db_dashboard.html`
- [ ] `git status` shows only in-scope files modified / created
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `v_evs`, `v_findings`, `v_dbt`, `v_cpu` or `emit_card`'s
  `'<dl class="ev">' || v_ev || '</dl></div>'` line are not found as quoted.
- `section#blocking` is no longer emitted unconditionally by
  `sql/24_blocking.sql` (then the `ROW_LOCK` link could dangle; report it,
  do not drop the link on your own).
- lint check 14 / 16 / 17 / 22 fails after adding the include and you cannot
  fix it by moving ONLY the new lines (variables up, include last).
- The demo's I/O card gets no `IO_SCANS` hint: the rule data differs from
  what this plan assumed (`table scans (long tables)` large on the demo,
  `db file scattered read` x20.6) — report the actual buckets.
- A hint wording change seems necessary: wording is the owner's call
  (see Maintenance notes); report the proposal instead.

## Maintenance notes

- **Owner decision, DECIDED 2026-11-19:** the eight sentences in
  `hint_text` are approved as written (changing one later is a one-line
  edit; the demo follows through the parser). The PLAN sentence stays as is
  and does not mention the `DBA_HIST_SQL_PLAN` grant.
- Next-step queries reference the Current window only, single DBID; a
  report spanning a DBID change has a valid Current window in exactly one
  DBID (windows straddling a change are invalid), so that is correct.
  `DBMS_XPLAN.DISPLAY_AWR` needs the Diagnostic Pack, which the report
  already requires, AND read access to `DBA_HIST_SQL_PLAN`, which is NOT
  in the README's required grant list (section 23 reads it only through
  dynamic SQL and shows a "needs SELECT on" note without it; lint 35). The
  copied query is text the reader runs, so it cannot break the report, but
  an analyst without that grant gets ORA-00942 from it; the owner may want
  the PLAN sentence to say so.
- Overlaps worth knowing: section 23 (Plan shape) already draws the old
  and new plan line by line from ASH, and its script adds a "Plan shape"
  link to the plan card's footer; section 24 (Blocking) draws who blocked
  whom, which is what the `ROW_LOCK` query lists. The hints keep their
  queries because they work without those sections' optional grants and
  outside the report.
- Captured-SQL caveat: `DBA_HIST_SQLSTAT` holds only the statements AWR
  captured (top-N per snapshot), so "top 10" queries list the captured ones.
  `HARD_PARSE`'s literal check sees only captured statements too; a heavy
  literal workload may show few rows. Worth stating in `19_reference.sql`'s
  About notes if the owner wants (not in this plan).
- A rule that fires on an event outside the top 2 of its class will not see
  it (`v_evs`); widening `v_evs` costs one bounded scan's row count only.
- Reviewer focus: `hint_fill` replacement order (`#B0#` before `#B#`), no
  space before `#NL#`, the twin's regex reading all 16 lines, the
  `~inst_num` / `~dbid` substitutions written exactly as shown.
- **Needs owner DB run** (the executor has no database). On dbmint (`ssh -p
  2200 oracle@dbmint`, never 2201; rsync without `--delete`). dbmint keeps
  only 35 days of AWR: probe first for a restart-free stretch (CLAUDE.md,
  "dbmint keeps 35 days of AWR"); on 2026-11-19 that was 2026-11-07 14:45
  to 2026-11-09 16:15, and these runs fit it: the plan-change hour
  `./run_awr_trend.sh <connect> "2026-11-08 11:00" 1 8 10 0 1 h` (expect
  `PLAN` on the `b84c2ncqhcw23` card) and the heavy blocking hour
  `"2026-11-08 15:00" 1 8 10 0 1 h` (expect `ROW_LOCK` when its card
  shows `enq: TX - row lock contention`; its link opens the Blocking
  section), the second once more with `DESIGN=dashboard`. Look for a
  "mostly CPU" window in the same stretch for `DBTIME_CPU` if one exists.
  Each: rc 0, 29/29 `AWR-SECTION` pairs, no `ORA-` / `SP2-` outside
  captured SQL text. Copy each printed query into SQL\*Plus as the
  report's read-only user: every one parses and runs (no ORA-00904 /
  ORA-00942; for `PLAN`, ORA-00942 means the user lacks the optional
  `DBA_HIST_SQL_PLAN` grant, see above). Then `demo/verify_report.js` on
  each report, one at a time.
