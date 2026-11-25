# Plan 043: time model breakdown -- DB time by activity

Status: DONE; DB run pending (owner). Round 3, review item 7.
Informational only: no finding, count, pill or severity; nothing touches
`policy_bucket` or `metric_policy.plsql`.

## Why (the DBA question)

"Is the extra DB time SQL execution, parsing, PL/SQL, or logons?" The
report split DB time by wait class and by statement, never by what the
sessions were doing. `DBA_HIST_SYS_TIME_MODEL` (required grant) answers
that; the report read only its `DB time` / `DB CPU` rows. A hard-parse or
logon storm showed only as an indirect rate (`parse count (hard)`,
`logons cumulative`).

## Design as built

1. **Second table in section 02** (`sql/02_load_profile.sql`, after
   `#load-profile`, same anonymous block): `h3#load-tm-h` "Time model:
   what the sessions were doing", `p.tm-intro`, `table#load-time-model.tm-tbl`
   (`data-nocount data-nosort`: a sort would break the tree order). Fixed
   inline list (`tm_targets`, 19 rows, template-INDEPENDENT, no
   `*_targets.sql`, not in `metric_policy`), the two trees of the
   Reference in tree order: DB time > DB CPU, sql execute, parse time >
   hard parse > sharing criteria > bind mismatch, parse time > failed
   parse > out of shared memory, PL/SQL execution, PL/SQL compilation,
   inbound PL/SQL rpc, Java, connection management, sequence load,
   repeated bind; background elapsed > background cpu > RMAN. Read with
   the pairs -> bounds -> deltas shape over `valid_windows` (skipped =
   NULL), summed across instances, `/ 1e6 / MAX(dur_sec)` = AAS, dur_sec
   out of the second GROUP BY. Names matched `LOWER(stat_name) =
   LOWER(t.nm)` (see Names below). Columns: Statistic (indented per depth,
   `tr.tm-l<lvl>`, background rows `tm-bg`, the first `tm-bg1` gets a
   rule), Current (AAS), % of DB time (each row on its own; background
   "&mdash;"), the band cells with a NULL bucket and plain delta (section
   13's call), Trend (`data-spark`, the `','||token` LISTAGG), the prior
   windows. Rows carry `id=anchor_id('tm', name)`, `data-lvl`, `data-fg`
   (F / B), `data-par` (parent row id), `data-cur` / `data-mu` (6-decimal
   tokens). Closing `p.tm-drop`: "Not shown, zero in every window: ..." and,
   separately, "Not found in DBA_HIST_SYS_TIME_MODEL ...: ..." (a name with
   no AWR row at all), so a misspelt name never disappears silently. No
   DB time row at all: one `p.tm-none` note, no table. CSS:
   `sql/lib/src/css_timemodel.css` -> `css_timemodel.plsql`, in
   `sql/lib/viz_head.sql` (not `_style.sql`, which the fleet includes;
   the fleet includes neither file). Under 600 px the sticky first
   column wraps at 150 px with smaller indent steps, else the names
   filled the 390-px viewport and no number could be scrolled into view.
2. **DB time card row.** Rule (PL/SQL `tm_rise` / `tm_ok`): among the
   foreground rows of level >= 2 other than DB CPU and SQL execution, the
   largest rise (Current minus prior mean, AAS; ties to the deeper row)
   must be >= 0.01 AAS and >= 5% of a positive DB-time rise (the DB time
   row of this same table). Then, wording only: while a child of the pick
   meets the rule too and carries >= 80% of its rise, cite the child
   (parse time elapsed -> hard parse elapsed time). Emitted as a hidden
   `div#tm-ev-src` holding `div.evr.ev-tm` (dt = the family word: Parse,
   PL/SQL, Connection ...; `ent()` to the table row; "2.263 AAS, was
   0.6853 AAS; 17% of the DB-time rise"; plain delta + hollow band dot +
   "not scored"; `data-tm`, `data-cur`, `data-mu`, `data-rise`) and a
   one-line script that APPENDS it to `#f-dbtime dl.ev` while the page
   parses (07 ran before 02), then removes the source block (also when
   there is no card). The row lands after 07's own rows and before
   js_timeline's Peak / CPU rows (DOMContentLoaded). It folds with the
   card (plan 025) and moves with it into the dashboard's row. JS off:
   hidden. 17's `[data-ev-for]` prepends inside its own `#narr-src`, so
   it did not fit an append; this is the same pattern, one block.
3. **Library row text**: `lib_ls('load', ...)` gets "; time model: <name>
   +x AAS" exactly when the card row qualifies. No `lib_news`.
4. **About** (`sql/19_reference.sql`): "Time model" note after "Load
   profile" (the tree, overlap, background outside DB time, not scored,
   the card rule).
5. **Demo twin** (`s02_load_profile.py`, `tm_rows` / `_tm_window`): the
   model has only DB time, DB CPU and the two background rows; the rest
   is derived per window (hard parse ~6.2 ms each from `parse count
   (hard)` plus 0.9 x the model's Release 4.0 storm extra, connection
   management 21 ms a logon, SQL execution = statements' elapsed + 55% of
   the unattributed rest, PL/SQL 16% of it ...), `w.rng("timemodel", ts)`
   noise through `q10`. Java, inbound RPC, OOSM parse and RMAN are 0, so
   the demo shows the "zero in every window" note. Window -10 (2 Jul,
   Release 4.0's storm) shows hard parse at 0.73 AAS against 0.02. The
   Current rise is SQL execution (8.5 of 9.0 AAS); the largest other rise
   is PL/SQL execution, 0.28 AAS = 3% < 5%, so **the demo honestly shows
   no card row**. The card path was tested on scratch variants (Current
   PL/SQL +1.3 AAS: the row fires, classic and dashboard) and once with a
   broken cited number (verify fails as it should).
6. **verify_report block 6f**: table present, unscored, data-nocount /
   nosort, parents exist, shown in All sections; tree containment in the
   Current column (demo: fail; real report: "info", the counters flush up
   to 5 s apart); card row <=> card + a row meeting the rule (both ways),
   its numbers = the cited row's, it is the largest rise or a descendant
   carrying 80% of it, link, share text, no severity, before Peak / CPU,
   library row text, source block gone; JS off (a context without JS):
   table shown, source hidden.

## Files touched

`sql/02_load_profile.sql`, `sql/19_reference.sql`, `sql/lib/viz_head.sql`,
`sql/lib/src/css_timemodel.css` + generated `sql/lib/css_timemodel.plsql`,
`sql/lib/anchor_id.plsql` (comment: the `tm` kind),
`demo/awrdemo/sections/s02_load_profile.py`, `demo/gen_demo_report.py`
(`VIZ_CSS`), `demo/verify_report.js`, the three demo pages, `CLAUDE.md`,
`CHANGELOG.md`, `plans/README.md`, this file.

## Not covered

- Per-PDB time model (`DBA_HIST_CON_SYS_TIME_MODEL`): the table reads the
  same view and rows as `load_pairs_cte.sql`, so DB time here equals the
  Load profile's DB time.
- OLAP engine rows (listed in Table 9-1 but not in the Reference's tree).
- No Timeline lane row, no scoring, no dashboard KPI, Copy summary or
  findings JSON field.
- Unexercised: RAC, multi-DBID, a real card row (dbmint is idle), the
  "not found" note. The descend-to-child wording ran on scratch variants
  only (one step: parse -> hard parse; two steps: -> sharing criteria;
  verify OK on both).

## Names to check on dbmint (DESC / SELECT DISTINCT)

- `DBA_HIST_SYS_TIME_MODEL`: `SNAP_ID`, `DBID`, `INSTANCE_NUMBER`,
  `STAT_ID`, `STAT_NAME` VARCHAR2(64), `VALUE`, `CON_DBID`, `CON_ID` --
  19c Reference 5.72,
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SYS_TIME_MODEL.html
- Statistic names and the two trees -- 19c Reference 9.16
  V$SESS_TIME_MODEL, Table 9-1 and the tree under it,
  https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-SESS_TIME_MODEL.html :
  `DB time`, `DB CPU`, `sql execute elapsed time`, `parse time elapsed`,
  `hard parse elapsed time`, `hard parse (sharing criteria) elapsed time`,
  `hard parse (bind mismatch) elapsed time`, `failed parse elapsed time`,
  `failed parse (out of shared memory) elapsed time`, `PL/SQL execution
  elapsed time`, `PL/SQL compilation elapsed time`, `inbound PL/SQL rpc
  elapsed time`, `Java execution elapsed time`, `connection management
  call elapsed time`, `sequence load elapsed time`, `repeated bind elapsed
  time`, `background elapsed time`, `background cpu time`, `RMAN cpu time
  (backup/restore)`. **Not confirmed character for character:** the page
  spells two of them differently in its table and its tree (`SQL execute
  elapsed time` / `sql execute elapsed time`, `background CPU time` /
  `background cpu time`); the match is case-insensitive for that reason.
  Check: `SELECT DISTINCT stat_name FROM dba_hist_sys_time_model ORDER BY 1`
  -- every name of the list must appear (else the table's "Not found"
  note names it).

## dbmint checklist (owner)

1. Hourly run, e.g. `"2026-11-08 15:00" 1 8 10 0 1 h`: rc 0, 29 / 29
   `AWR-SECTION` pairs, no `ORA-` / `SP2-` / `PLS-` in the log.
2. All sections > Load profile: the second table; no "Not found" note.
   Cross-check one row: `SELECT (e.value - b.value) / 1e6 / <span s>
   FROM dba_hist_sys_time_model b JOIN dba_hist_sys_time_model e ON
   e.dbid = b.dbid AND e.instance_number = b.instance_number AND
   e.stat_id = b.stat_id WHERE b.stat_name = 'parse time elapsed' AND
   b.snap_id = <begin> AND e.snap_id = <end>` = its Current cell; the DB
   time row = the Load profile's DB time / 100.
3. A run with a busy, flagged DB time card: does the card get a time
   model row, and is it the row with the largest rise in the table?
4. 168 hourly windows (`... 1 168 10 0 1 h`): every line < 32767 bytes.
5. `verify_report` on the hourly report (block 6f prints `plan 043 {...}`;
   a `tree` "info" line lists counters that flushed apart).
