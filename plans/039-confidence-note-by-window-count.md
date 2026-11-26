# Plan 039: confidence note by window count (display only)

Status: DONE; run on dbmint 2026-11-25 (commit `3ea5315`, see round3-dbmint-runbook.md). Round 3, review item 1 ("state the
confidence"; the thresholds are NOT changed, see `plans/README.md` "Not
implemented"). No new AWR read, so no new Oracle name.

## Why (the DBA question)

"How much should I trust a finding scored against only 4 prior windows?" The
rule (`policy_bucket`): z = (Current - mean) / max(sd, 2% of |mean|) over the
n valid prior windows, mean and SAMPLE sd from the same n values. The default
run has `weeks_back = 4`. For a normal metric that did not change,
z / sqrt(1 + 1/n) is Student's t with n - 1 degrees of freedom, so the nominal
chance of |z| > 2 or > 3 is far above the 4.6% / 0.3% people assume. The report
never said so.

## The table (tools/gen_baseline_conf.py, numeric integration of the t density)

Two-sided, per metric, before the size floors and the direction rule (a
rise-only metric is about half). Percent outside +/-2 sigma / +/-3 sigma, and
"1 in k":

| n | > 2 sigma | > 3 sigma | 1 in | 1 in |
|---|---|---|---|---|
| 3 | 22.54 | 12.17 | 4 | 8 |
| 4 | 17.16 | 7.48 | 6 | 13 |
| 5 | 14.19 | 5.20 | 7 | 19 |
| 6 | 12.33 | 3.90 | 8 | 26 |
| 8 | 10.13 | 2.55 | 10 | 39 |
| 12 | 8.09 | 1.49 | 12 | 67 |
| 26 | 6.09 | 0.69 | 16 | 145 |
| 52 | 5.30 | 0.45 | 19 | 222 |
| 60 and more | 5.2 | 0.4 | 19 | 236 |

The full list n = 3..60 is in `sql/lib/baseline_conf.plsql` (the file is the
single source; `python3 tools/gen_baseline_conf.py` prints the table, `--emit`
the WHEN rows, `--check` compares the file with the integration, tolerance
0.01 points; `tools/check.sh` runs it). More than 60 windows read the n = 60
row (the limit is 4.6% / 0.3%; the card title says "Rates shown for 60
windows"). Values match the review's figures (22.5/12.2, 17.2/7.5, 12.3/3.9,
10.1/2.5, 8.1/1.5, 6.1/0.7, 5.3/0.5).

## Design as built

- **One shared lookup**: new `sql/lib/baseline_conf.plsql` (functions only,
  included after `off_label` in 00 and 07; no fleet file includes it):
  `conf_mod(n)`, `conf_large(n)` (percent, NULL below 3), `conf_pct_txt`,
  `conf_every` ("1 in 6"), `conf_title(n)` and `conf_verdict(n)`. Python twin
  in `demo/awrdemo/helpers.py` parses the same WHEN rows (cannot drift).
- **Verdict note, only for a thin baseline**: 00 emits `li.hn-conf[data-n]`
  inside `ul#narrative-slot` as a static li (the slot is then not `hidden`; JS
  off shows it) when scoring happened and the number of VALID prior windows
  (`v_n_valid`) is 3 to 5. "Thin baseline: 4 prior windows. With so few, a
  metric that did not really change still lands outside +/-2 sigma about 1
  time in 6 and outside +/-3 sigma about 1 in 13 (before the size floors).
  Read a lone moderate finding as a hint; more windows (weeks_back) tighten
  this. How scoring works ->" (link to `#about`). Fewer than 3 valid priors
  has its own "too little history" hero: no note. 6 or more: no note.
  Order in the list: 17's notes, this one, then 038's `li.hn-base`. 17's
  relocation now inserts before the first of `li.hn-conf, li.hn-base` (one
  selector); 26's script appends.
- **Cards say their n**: `.nrm` and `.fc-sum` of every finding card carry
  `data-n` = the LEAD row's `n_prior`; the `.nrm` title appends the two rates.
  The visible "n = 4" is CSS generated content
  (`.fc .big .nrm[data-n]::after`, new `sql/lib/src/css_baseconf.css`
  -> `css_baseconf.plsql`, included from `viz_head.sql`; `_style.sql` is shared
  with the fleet chrome and stays untouched). It is never text, so Copy
  summary, the dashboard's KPI context and its table "Normal" cell, and the
  palette are unchanged. The dashboard hides the card's `.big`, so
  `js_design` copies `data-n` and the title onto the lead row's `.dnr` cell and
  `css_design.css` shows a small second line "n = 4".
- **About note**: `19_reference.sql` "Scoring" gained the rule of thumb and
  the n list (3, 4, 6, 8, 12, 26, 52); the twin lifts it.
- **Copy summary** reads `#narrative-slot li` textContent, so the note copies
  as "- Thin baseline: 4 prior windows. With so few, ... How scoring works ->".
- **Demo**: 12 prior windows, so the verdict note is absent and the cards say
  n = 12 (8.1% / 1.5%). The twins (`s00`, `s07`, helpers) implement the rule;
  a scratch generation with `model.WEEKS_BACK = 4` shows the note.
- **verify_report** (phase 4): per card `data-n` on `.nrm` and `.fc-sum`
  equal, equal to the `n` cell of the lead row's Findings table row, the title
  has the two rates of that n (known values above), no "n =" in the text; the
  note exists <=> 3 to 5 valid priors in `AWR_WIN`, with the rates of that n,
  after 17's notes and before `li.hn-base`, link to `#about`.

## Files touched

`sql/lib/baseline_conf.plsql` (new), `sql/lib/src/css_baseconf.css` +
`sql/lib/css_baseconf.plsql` (new), `sql/lib/viz_head.sql`, `sql/00_params.sql`,
`sql/07_summary.sql`, `sql/17_narrative.sql` (one selector, a comment),
`sql/19_reference.sql`, `sql/lib/src/js_design.js` + `css_design.css` and their
generated `.plsql`, `tools/gen_baseline_conf.py` (new), `tools/check.sh`,
`demo/awrdemo/helpers.py`, `s00_params.py`, `s07_summary.py`,
`demo/gen_demo_report.py` (VIZ_CSS), `demo/verify_report.js`, `CLAUDE.md`,
`CHANGELOG.md`, `plans/README.md`, this file, the three demo pages.

## Not covered

- No change to thresholds, flags, counts, order or the fleet report.
- The rates ignore the 2% sd floor, the size floors and the direction rule, and
  assume a normal metric (many AWR metrics are skewed; the note says
  "nominal").
- No new column in the All sections tables (they keep Normal range / z / n).
- The "n < 3" band glyph note is unchanged; a card never shows n below 3 (an
  insufficient-history row is never flagged).
- Cards for n above 60 show the n = 60 rates.

## Names to check on dbmint (DESC / SELECT DISTINCT)

None: no new view, column or statistic. Only `v_n_valid` and the lead row's
`n_prior`, both existing.

## dbmint checklist (owner)

1. `"2026-11-09 16:00" 1 4 10 0 1 h` style run (4 priors): verdict shows
   "Thin baseline: 4 prior windows ... 1 time in 6 ... 1 in 13", before any
   "Baseline check", after 17's notes (when it has some); each card reads
   "normal ... . n = 4" and its hover shows 17% / 7.5%.
2. Run with `weeks_back` 12 or more: no verdict note, cards say n = 12 etc.
3. A run with exactly 3 valid priors (skipped windows): note says 3 (22.5% =
   1 in 4, 1 in 8). A run with 2 valid priors: the "too little history" hero
   only.
4. A card whose lead metric is missing in one window: its n is one less than
   the window count (compare with the `n` column of the Findings table).
5. Copy summary: the note line is there, the cards' "normal ..." lines carry no
   "n =". Quiet and dashboard designs: n shows on the card line / second line in
   the lead row; the KPI cards have no "n =".
6. JS off: the note is visible in the verdict, the cards read as before.
7. `grep -c 'hn-conf'` of the HTML: no `ORA-`, no `SP2-`; the About "Scoring"
   note lists the rates.
