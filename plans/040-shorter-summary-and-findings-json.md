# Plan 040: a shorter Summary, and a machine-readable findings block

Status: DONE; run on dbmint 2026-11-25 (commit `3ea5315`, see round3-dbmint-runbook.md). Round 3, review item 11. Two independent
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

## Follow-up (2026-11-25): four more library rows start shut when a card already says their news

### Why

The later plans of this round added library rows and card rows, and the
classic demo's Summary grew back to about 19,640 px at 1440 px. Four open rows
only repeated what a card or a verdict note already says: `who` (2205 px),
`plan-flame` (1020), `win-sim` (1449) and `volume-cost` (2253).

### Design as built

Same mechanism, no new behaviour for the reader. Each of the four sections
keeps its own `lopen` rule and ADDS a `lib_news` call; `libNews()` shuts the
row only when every token is satisfied; a row with no `data-news` is as before.
Two new token kinds in `libNews()` (`sql/00_params.sql`); an unknown kind is
never satisfied (the row stays open).

| Row | Token | Satisfied when |
|---|---|---|
| `who` (29) | `who:<x_id>`, emitted next to the DB time card's Who row, only when that row's value carries at least half of the rise (the row's own `lopen` condition) | `#f-dbtime .ev-who[data-who=<id>]` exists and is shown |
| `plan-flame` (23) | one `sql:<sql_id>` per statement block, mode `chg` only (at most 3) | the existing `sql:` rule: `#f-plan-<id>` or a card link to that statement |
| `volume-cost` (21) | one `sql:<sql_id>` per statement slower per run (category `s` or `b`, the `lopen` rule); `event:slower` added when an event is slower per wait | `sql:` as above; `event:slower` is never on a card, so the row stays open |
| `win-sim` (26) | `note:hn-base`, emitted only together with plan 038's Baseline check note | `#narrative-slot li.hn-base` exists and is shown |

Decisions:

- `who`: the demo has four dominant values (service, module, program, user:
  one load seen along four dimensions) but the card's Who row names one (the
  module, first in its module / service / machine / user order). A token per
  dominant value would never be satisfied, so the news is "the card's Who
  row names a dominant value". A rise whose dominant value is a program or PDB
  the card does not name, or a card row below half (30 to 50 %) while another
  dimension is dominant, keeps the row open.
- `volume-cost`: the `lopen` rule looks at statements only; an event slower
  per wait is news no card carries, so it keeps the row open (conservative).
- `win-sim`: odd windows without a bucket-changing drop have no note, so no
  token: the row stays open as before.
- Token strings: 29 and 26 emit one short token; 23 at most 3 statements; 21
  at most 60 statements x 19 characters, `v_news VARCHAR2(2000)`; no new
  declaration follows an include.

Files: `sql/00_params.sql`, `sql/21_volume_cost.sql`, `sql/23_plan_flame.sql`,
`sql/26_window_similarity.sql`, `sql/29_who.sql`, `sql/19_reference.sql` (About
note), twins `s21`, `s23`, `s26`, `s29`, `demo/verify_report.js` (block 6c:
the same shut-iff-satisfied assertion for every row with `data-news`, a header
click opens each shut row, a jump into it opens it; the demo must have all six
rows with news and shut), `README.md`, `CLAUDE.md`, `CHANGELOG.md`, the three
demo pages. `instance-map`, `onset`, `wait-hist`, `sqlmon` and the other rows
are untouched. No new AWR read, no new Oracle name.

### Summary height, 1440 px (Summary view, after load)

| design | before | after |
|---|---|---|
| classic | 19,640 px | 12,934 px |
| quiet | 19,793 px | 12,921 px |
| dashboard | 18,200 px | 11,429 px |

Open rows after, on all three: instance map, trend breaks, wait histograms,
SQL Monitor (nothing else). Verified with `demo/verify_report.js` on all three
demo pages (block 6c: every row with `data-news` is shut exactly when its
tokens are satisfied, a header click opens each shut row, a jump into it opens
it). The plan 045 `lopen` check now accepts a row that carries `data-news`
as open (the chrome shuts it after PL/SQL marked it open).

### dbmint checklist additions (owner)

1. The incident hour with a plan change: `plan-flame` and `volume-cost` shut
   when the changed statement has its plan-change card; open when it has none.
2. A window with a dominant module / service above half of the rise: `who`
   shut and the DB time card shows the Who row; a dominant program or PDB
   (no card row): `who` stays open.
3. A window with a Baseline check note in the verdict: `win-sim` shut; odd
   windows whose drop changes no bucket (no note): `win-sim` open.
4. A statement slower per run with no plan change: `volume-cost` open.
5. Quiet window with no finding card: all six rows as marked, as before.
