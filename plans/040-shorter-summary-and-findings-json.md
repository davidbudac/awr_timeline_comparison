# Plan 040: a shorter Summary, and a machine-readable findings block

Status: DONE; DB run pending (owner). Round 3, review item 11. Two independent
parts. No new AWR read, so no new Oracle name. Explain only: no finding, count,
pill or severity changes.

## Part A: evidence-library rows open only when they have news

### Why (the DBA question)

"Where does the triage end?" The Summary is the triage page, but on the demo
(1440 px) it was 19,738 px tall: verdict, cards, "What changed" and "Checked and
normal" end near 4,500 px and the rest is the library, with Top SQL and
Foreground waits open by default. The cards already name the top statement
(plan-change card), its plan change and the flagged wait classes, so those two
open rows mostly repeated them.

### The rule (one sentence)

Top SQL and Foreground waits start open only when their one-line status names
something no finding or plan-change card already names (the top statement, the
wait classes that moved), or when the report has no finding card. It is in the
About note "Evidence library" (`sql/19_reference.sql`), README and CLAUDE.md.

### Design as built

- Sections 04 / 06 cannot see 07's cards, so the browser decides. Both rows
  keep `lopen` in the markup (JS off, no card: as before) and now end with
  `lib_ls(...) || lib_news(id, tokens)`: new `lib_news` in
  `sql/lib/band_glyph.plsql` (twin `helpers.lib_news`), an inline script that
  sets `data-news` on the section. Tokens, space separated, ids only:
  `sql:<sql_id>` (06: the Current top statement by elapsed, none when no
  statement is in the Current top N) and `card:<card id>` (04:
  `card_id(card_group('WAIT:' || class))` for every Table A event scored large
  or moderate, distinct).
- `libNews()` in the chrome (`sql/00_params.sql`, once, right before the h2
  handlers are wired, so before the first `libViews()` and `revealHash()`):
  returns when there is no `#findings article.fc:not(.chg)`; otherwise a row
  that is `lopen` and whose tokens are ALL on a card loses `lopen`. `card:` =
  that finding card exists; `sql:` = `#f-plan-<id>` exists (not inside a
  `[hidden]` ancestor) or an `article.fc a[href]` points at an id ending in
  `-<sql_id>`. An empty list is trivially on cards.
- A click, `reveal()` / `goTo()` (a link into a shut row opens it) and All
  sections (ignores `.lopen`) are untouched; the other rows (SQL Monitor, the
  visualization sections) keep their rules. Runs at DOMContentLoaded: the plan
  cards are moved by parse-time scripts, so a slow parse may paint the open row
  for a moment before it shuts (an inline script after the section cannot know
  the plan cards yet).

### Summary height, classic demo at 1440 px

| design | before | after |
|---|---|---|
| classic | 19,738 px | 16,921 px |
| quiet | 19,858 px | 16,974 px |
| dashboard | 18,190 px | 15,328 px |

Open rows after: instance map, window similarity, trend breaks, wait
histograms, volume vs cost, SQL Monitor, plan shape (Top SQL and Foreground
waits are shut: the top statement `7k2m9dx4qp1zb` has its plan-change card, and
the four moved events are in Physical I/O, Network and Commit, which have cards).

## Part B: the machine-readable findings block

### Why

"Can my scheduler / ticket system read the result without scraping HTML?"

### Design as built

- `sql/07_summary.sql` emits, right after the cards (and when there are none),
  `<script type="application/json" id="awr-findings">`: data, never executed,
  nothing in the page reads it. Schema 1: `report` {version, run_id, db_name,
  dbid, host, target_end, win_hours, step_hours, weeks_back,
  valid_prior_windows, template, inst_num} (the driver's DEFINEs
  `~awr_version ~run_id ~db_name ~dbid ~host_name ~target_end_resolved
  ~win_hours ~step_hours ~weeks_back ~template_name ~inst_num`; the valid prior
  windows are counted from `windows_rollup`, the CTE 07 already uses),
  `counts` {cards, large, moderate} (= `v_order.COUNT`, `v_ncl`, `v_ncm`, the
  verdict pill), `cards` one PUT_LINE each {id, group, label, severity, domain,
  metric, unit, current, mean, sd, n, z, impact_aas, share_pct}.
- Values are the card's own: the lead row x `metric_scale` in its
  `metric_unit` base unit (AAS, B/s, /s, ms, %; not the auto-scaled display),
  `z` = the band's z, `impact_aas` = `data-impact`, `share_pct` = `data-share`
  (`null` where the attribute is empty).
- Safety: strings through `json_escape` (which already writes `<` as `<`);
  numbers through a local `json_num` (`FM999999999999990D999999`, `.,` pin,
  RTRIM of the dot, `null` for NULL or 1e15 and up; TO_CHAR can read `.5`).
- Too little history / no card: `"cards":[]`, report fields kept.
- Not in schema 1: plan-change and configuration cards (18 / 12 / 17). The
  fleet and the server do not read it.
- README "Machine-readable result" has the field list and a `sed` + python
  extraction (tested on the demo).

## Files touched

`sql/lib/band_glyph.plsql`, `sql/00_params.sql`, `sql/04_waits_fg.sql`,
`sql/06_top_sql.sql`, `sql/07_summary.sql`, `sql/19_reference.sql`; twins
`demo/awrdemo/helpers.py`, `sections/s04_waits_fg.py`, `s06_top_sql.py`,
`s07_summary.py` (s00 / s19 lift their lines); `demo/verify_report.js` (block
6c); `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `plans/README.md`, this file; the
three demo pages.

## Not covered

- The fleet report and the server (no change, per the brief).
- Plan-change / configuration cards in the JSON; SQL Monitor and the
  visualization rows (own rules).
- Closing a row because ONE of two news items is on a card: it needs all of them.
- A statement that appears only as evidence of a card whose link target is
  not emitted counts as not on a card (the row stays open).

## Names to check on dbmint

None: no new view, column or statistic.

## dbmint checklist (owner)

1. A busy window with a plan change (`"2026-11-08 11:00" 1 8 10 0 1 h`,
   b84c2ncqhcw23): Summary at 1440 px: Top SQL shut when its top statement has a
   plan-change card; Foreground waits shut when every moved class has a card.
2. A quiet window with no finding card: both rows start open, as before.
3. A window where the top statement has no card: the Top SQL row stays open.
4. Click a shut row's header: it opens; a link from a card into it opens it;
   All sections still shows both in full.
5. `sed -n '/id="awr-findings"/,/<\/script>/p' report.html` parses as JSON;
   `cards` equals the number of finding cards; `impact_aas` / `share_pct` equal
   the cards' `data-impact` / `data-share`; a database name containing `<` or
   `"` stays valid JSON; a run with fewer than 3 valid priors gives
   `"cards":[]` and `valid_prior_windows` below 3.
6. RAC (`inst_num` 0): `valid_prior_windows` counts windows, not instances.
7. No `ORA-` / `PLS-` / `SP2-` in the log; 29 / 29 `AWR-SECTION` pairs.
