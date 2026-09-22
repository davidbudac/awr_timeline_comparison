# Handoff: v1.5.0 UI/UX + scoring-policy branch

Branch: `claude/ui-ux-improvements-buwjzo` (11 commits on top of `main`,
67 files, +6079/-2529). Status on 2026-09-22: **every change is written,
lint-clean, exercised on the synthetic demo and the server test suite, and
pushed. None of the PL/SQL has run against an Oracle database.** The
session that built it had no route to dbmint (cloud container, no SSH).
The next agent runs on a machine where `ssh -p 2200 oracle@dbmint` works.

Read `CLAUDE.md` first (it was kept current with every phase), then this
file, then `design/UI_UX_IMPROVEMENT_PLAN.md` for the full audit and the
per-phase notes.

## 1. What is on the branch (one line each)

| Phase | Commit | Change |
|---|---|---|
| plan | c094e61 | audit + plan (`design/UI_UX_IMPROVEMENT_PLAN.md`) |
| 1 | 31ce9dd | findings rollup: families, sigma floor, materiality, improved tier, shift rollups (04/05/16) |
| 2 | 02114e6 | table scroll wrappers, phone View popover, chart labels in-plot |
| 3 | b01ba62 | row/card anchors, cross-links, dated window chips, hash view state |
| 4 | c0386e0 | visual DOM order, `<main>`, tab/sort roles, focus ring, tap-to-pin tips, chart decals |
| 5 | 295ab27 | empty-state remedies, terminology/units, SQL Monitor folding |
| 6 | 444a450 | fleet a11y, server dark toggle + sortable/filterable tables |
| 7 | c5b65b2 | **`sql/lib/metric_policy.plsql`** (per-metric direction + floors, `policy_bucket()`), Normal / Full views |
| 7b | 2f7c903 | fleet 04/01/03 through the policy; fixed 08 + fleet 03 not projecting `src, key` |
| 8 | 8b8a5a9 | structured "What changed", folded window chips, Detailed renamed Full, Application-only filter removed, `docs/metric_policy.html` |
| 8b | 2f539b8 | fleet 06 day-profile band through the policy |

## 2. First job: run it on dbmint

```sh
git fetch origin && git checkout claude/ui-ux-improvements-buwjzo
rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex ./ \
  oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2200'

# single-DB: pinned hourly window (dbmint's AUTO+weekly usually has no valid
# windows -- see the "dbmint default-window trap" in CLAUDE.md), then AUTO
ssh -p 2200 oracle@dbmint 'cd ~/awr_timeline_comparison && \
  ./run_awr_trend.sh "/ as sysdba" "2026-09-04 12:00" 1 4 10 0 1 h comprehensive Y "" 7 3 && \
  ./run_awr_trend.sh "/ as sysdba" "2026-09-04 12:00" 1 4 10 0 1 h simple        Y "" 7 3 && \
  ./run_awr_trend.sh "/ as sysdba" "2026-09-04 12:00" 1 4 10 0 1 h dev           Y "" 7 3 && \
  ./run_awr_trend.sh "/ as sysdba" AUTO 1 4 10 0 1 w comprehensive Y "" 7 3'

# fleet, with per-DB detailed reports and the day-profile band
ssh -p 2200 oracle@dbmint 'cd ~/awr_timeline_comparison && \
  FLEET_DETAIL=all FLEET_PROFILE_DAYS=7 ./run_awr_fleet.sh fleet.conf "2026-09-04 12:00" 1 4 10 1 h'
```

If a pinned `target_end` newer than 2026-09-04 has better history, use it;
the point is a restart-free stretch with 15-min snaps.

### What "pass" looks like

```sh
grep -c "ORA-\|SP2-" reports/*.html reports/*/*.html          # must be 0 everywhere
for f in reports/awr_trend_*.html reports/*/detail_*.html; do
  echo "== $f"
  grep -o 'AWR-SECTION: [0-9a-z_]* \(BEGIN\|END\)' "$f" | sort | uniq -c | awk '$1!=1'
done                                                           # prints nothing
grep -c '__FLEET_' reports/awr_fleet_*/index.html              # 0: no unfilled placeholder
```

Every section must have exactly one `BEGIN` and one `END` marker. A
section that aborted leaves a `BEGIN` without an `END`; the `debug=Y`
(the `Y` positional above) progress markers on stdout tell you which
block died, and the `.log` next to the report carries the ORA- text.

Then open each report in a browser (the headless demo checks cannot
replace this for JS emitted by PL/SQL):

- Normal view opens by default; the rail shows "+ N more in Full"; the
  Full button reveals everything and every chart in a previously hidden
  section has a real width (no zero-width canvases).
- "What changed" renders as rows, not paragraphs; every link lands.
- Compared windows: summary line + chart; "show all windows" folds out
  the chips; clicking the Current chip highlights without folding.
- Findings: Biggest movers lists only large/moderate leads; detail tables
  (Full view) show `improved` / `noted` as outlined badges without row tint.
  dbmint is idle, so expect mostly `insufficient history` / `typical`.
- 04/05 wait tables: Change column badges; the table-wide-shift note if
  it triggers.
- Day profile (`profile_days=7`): shifts table + heatmap in Normal, hour
  table only in Full.
- Fleet console: rows expand, the findings band prints large then
  moderate, the worst-finding cell and the mini-card badges agree with
  the band, the day-profile band renders.

## 3. Where it is most likely to break (read these first if a run fails)

All of this is unexecuted PL/SQL. Ordered by how much new code sits behind it:

1. **`sql/lib/metric_policy.plsql`** -- declares a RECORD type and two
   functions with `CASE p_name WHEN ... THEN RETURN pol(...); ... ELSE NULL;
   END CASE;` bodies. Included in DECLARE sections of 00, 04, 05, 07, 08,
   16, 17, 18 and fleet 01, 03, 04, 06. A compile error here breaks every
   one of those blocks at once, so fix it first. A `policy_rec` variable
   must be declared AFTER the include (00 and 07 do this; check any new
   use).
2. **`sql/07_summary.sql`** -- the `scored` CTE no longer computes the
   bucket (`CAST(NULL AS VARCHAR2(40)) AS change_bucket`, plus a `share`
   column threaded through `ranked` into the BULK COLLECT record; the
   record gained `dir VARCHAR2(4)` and `share NUMBER`). Pass 1 assigns the
   bucket via `policy_bucket()`; family leads are only large/moderate rows.
3. **`sql/00_params.sql`** -- same shape as 07 for the verdict (record
   gained `prior_sd`, `share`). Also the largest JS change: Normal/Full
   mode, rail dimming, mode note, `revealHash` mode switch. JS errors show
   only in a browser console.
4. **`sql/fleet/04_findings.sql`** -- rewritten from a cursor loop to
   BULK COLLECT + two passes, with a nested `DECLARE ... BEGIN ... END`
   inside the loop using `CONTINUE`. `score_cells_dir` signature changed
   to `(bucket, z, pct)`.
5. **`sql/fleet/01_row.sql`** -- worst finding moved from `SELECT INTO ...
   WHERE ROWNUM = 1` (with NO_DATA_FOUND) to a cursor FOR loop with EXIT.
6. **`sql/08_overview.sql` / `sql/fleet/03_headline.sql`** -- the grouped
   cards query now projects `src, key` (it referenced them without
   selecting them since phase 1; fixed in 2f7c903).
7. **`sql/17_narrative.sql`** -- every sentence builder rewritten to
   `add_item(label, num, sub, why, href, link)`; `lede()` replaced by
   `numtxt()` / `rng()` / `pcttxt()`. Check R1 (physical reads) and R3
   (configuration) rows on a run where they fire.
8. **`sql/04_waits_fg.sql` / `05_waits_bg.sql`** -- new scalar query for the
   Current total (`v_tot_cur_us`), the shift pre-pass, and
   `score_cells(..., share, 'WAIT', event, wait_class, demote)`.
9. **`sql/16_day_profile.sql`** -- per-cell re-bucket in pass 1; day-wide
   shift rollup; `<table class="full-only">` for the hour table; the inline
   `data-normal` script.
10. **`sql/18_sqlmon.sql`** -- the `v_normal` opt-in script; tail rule with
    `v_tail_cnt` / `v_nocur_cnt`.
11. **`awr_trend.sql`** -- section include order changed to the visual
    order; `</main>` emitted in the epilogue before `<footer>`.

Known-safe: `sql/_style.sql` (CSS only), `sql/lib/anchor_id.plsql` (a
REGEXP_REPLACE), `sql/lib/score_cells.plsql` (thin wrapper).

## 4. After the run passes

1. Update the "v1.5.0 UI/UX pass ... NOT yet run against dbmint" bullet in
   `CLAUDE.md` (Verification & testing) to say what ran and when, in the
   style of the 1.4.0 bullet below it.
2. Tick item 0 of the verification checklist in
   `design/UI_UX_IMPROVEMENT_PLAN.md`.
3. Move the CHANGELOG "Unreleased" block to `## 1.5.0 -- <date>` and
   `## Fleet report 0.7.0 -- <date>`; `awr_version` in `awr_trend.sql` is
   already `1.5.0` and `FLEET_VERSION` in `run_awr_fleet.sh` is `0.7.0`.
4. Byte-identity is NOT expected (markup, CSS and scoring changed by
   design); do not chase md5 differences.
5. Commit, push, open the PR to `main` (none was opened; the user did not
   ask for one).

## 5. Open items that need a human decision

- **Policy floors are the author's judgement**, not tuned to any real
  workload. `docs/metric_policy.html` (generated; regenerate with
  `python3 docs/gen_policy_doc.py`) lists every metric with its direction,
  minimum %, floor, and when it fires. The user asked for these to be
  configured individually and editable; they are, in
  `sql/lib/metric_policy.plsql`. Someone who knows the databases should
  skim the page and adjust. After any edit: `./lint.sh` (check 12 =
  every template name has a line; check 13 = include order), then
  regenerate the policy page and the demo.
- **The demo cannot show `improved` / `noted`**: the synthetic model in
  `demo/awrdemo/model.py` only moves metrics in the bad direction. Either
  accept that or add a metric that drops (e.g. lower hard parses in the
  current window) so the muted badges and the "N improved" verdict text
  appear in `docs/examples/demo_busy_db.html`.
- **`is_essential.plsql` and the `data-imp` row tags** are still emitted
  but nothing reads them since the Essential toggle was removed. Keep (a
  future row filter could use them) or strip; either is a small change.
- **`data-sys="Y|N"` tags and 06's `sys` series flag** likewise remain as
  metadata after the Application-only filter was removed.
- **`day_profile_cte.sql`'s own `change_bucket` CASE** is no longer read by
  any consumer (16 and fleet 06 re-bucket per cell through the policy). It
  could be dropped from the CTE to avoid a second, stale rule; low priority.
- **Fleet `06_day_profile.sql` band** and the single-DB section 16 both
  score `LOAD` stats through the policy; the fleet console's own
  "Compared windows" strip, `part` and snap-mismatch states are still
  unexercised (all dbmint aliases hit one instance) -- pre-existing gap.

## 6. How the pieces fit (orientation for the next agent)

- Scoring: `sql/lib/metric_policy.plsql` = the human-editable table +
  `policy_bucket()`, the only implementation of the rule. Every consumer
  calls it: 00 verdict, 07 findings (PL/SQL pass), 08 hero cards, 16 day
  profile, 17 narrative `big()`, `score_cells.plsql` (04/05/18), fleet
  01/03/04/06. `demo/awrdemo/helpers.py` parses the file (regex over the
  `WHEN 'name' THEN RETURN pol(...)` lines), so keep that one-line shape.
- Views: `body.normal` (default) / `body.full`; `data-normal="Y"` on
  sections that belong to Normal (06, 07, 08, 09 always; 12, 16, 18 via a
  one-line inline script when they have something to say); `.full-only`
  on Full-only content inside a kept section. The mode switch is
  `#mode-normal` / `#mode-full`; state in localStorage `awr-mode` and the
  hash `!v=f`.
- Masthead: `17_narrative.sql` emits `<ul class="narr-list">` rows via
  `add_item()`; the compared-windows chips sit in
  `<details class="windows-more">`.
- Demo: `python3 demo/gen_demo_report.py && node demo/verify_report.js
  docs/examples/demo_busy_db.html` (expects 0 console errors, 45 charts,
  `mode: ok (7 of 17 sections in Normal)`). Every touched section's twin
  under `demo/awrdemo/sections/` was re-ported; the chrome JS/CSS is
  lifted literally from the SQL, so a markup change in 00/_style needs no
  twin edit but a section markup change does.
- Server: `cd server && python3 -m unittest discover -q` (137 tests).
