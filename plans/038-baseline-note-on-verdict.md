# Plan 038: the verdict says when the baseline has an odd window

Status: DONE; DB run pending (owner). Round 3, review item 2. No new AWR
read, so no new Oracle name.

## Why (the DBA question)

"Can I trust 'normal' here?" Every finding is scored against the mean and
sigma of the prior windows. One incident inside a prior window inflates
sigma, so Current reads normal. Section 26 (Window similarity) already finds
the prior windows unlike the rest and re-scores the report without them
(`score_set`, the `sug` suggestions with `chg` / `ca` / `cb`), but nothing
outside section 26 said so: the verdict hero never told the reader the
baseline is suspect.

## Design as built

- **Only a pointer.** One `li.hn-base` in the verdict's notes list
  (`ul#narrative-slot.hnotes`): one `span.hw` holding `b.hl` "Baseline
  check:", one sentence and a link "Window similarity ->" (`a.go`, already
  styled inside `.hero .hnotes`) to `#win-sim`; a single flex item, so the
  label, the sentence and the link wrap as one paragraph. A NOTE, not a finding: no count, pill, severity, card or order
  changes. No baseline switch on the cards (plan 028 stays dropped).
- **Source of truth is section 26's PL/SQL.** After the winsim payload,
  26 picks the suggestion `v_bs`: the one with the largest `v_schg` (metrics
  whose bucket changes; the first on a tie), with `v_schg > 0` and at least
  3 valid priors left after the drop (with fewer, every metric turns
  "insufficient history", which says nothing about the baseline). The
  sentence uses 26's own `wname` / `grp_txt` / `set_names` and its numbers
  (`v_schg`, `v_cbn`, `v_sca`); nothing is recomputed in the browser and no
  second scoring pass exists.
- **Sentence.** Subject by kind: one odd window ("The prior window -5w (Thu
  3 Sep) is unlike the other prior windows."), 2-6 odd windows named, more
  than 6 only counted with their offsets, a group ("The 4 most recent prior
  windows (-4w to -1w, Thu 13 Aug to Thu 3 Sep) form a group unlike the older
  ones."). Then "Scored without it/them, N metrics change bucket and the
  findings rise from A to B" / "fall from A to B" / ", though the findings
  stay at A". The direction is stated, never implied.
- **Relocation pattern.** The li sits in a hidden `div#base-src` inside
  `section#win-sim`; a one-line inline script moves it into `#narrative-slot`
  and unhides the slot while the page parses (before any DOMContentLoaded
  handler), then removes the source div. JS off: stays hidden, the fact is in
  section 26's "Reads as" and what-if.
- **Order with 17.** 26 runs before 17, so the baseline note arrives first.
  17's relocation now inserts its notes before `li.hn-base` when it exists
  (`insertBefore(li, bn)`, `bn` null = append), so the baseline note is the
  LAST note. Both orders of arrival are fine: 17 with nothing to say emits
  nothing and the note is simply the only one.
- **Contract for later work:** the li carries `data-sug` (0-based index into
  `AWR_DATA.winsim.sug`), `data-chg`, `data-cb`, `data-ca`; they equal that
  suggestion's `chg`, the payload's `cb` and the suggestion's `ca`.
- **Copy summary** reads `#narrative-slot li` through `textContent`, so it
  copies as "- Baseline check: ... Window similarity ->", after 17's notes. Quiet and dashboard designs restyle `.hnotes`
  through `css_design.css` (font size only); nothing else is needed.
- **Demo.** The demo's windows -4w..-1w form a group; dropping them changes 9
  metrics and the findings go 5 -> 8, so the note shows on the demo. The
  twin `s26_window_similarity.py` ports the rule and lifts the relocation
  script from the SQL.
- `sql/19_reference.sql` About note "Window similarity" gained the sentence
  that explains the note.

## Files touched

`sql/26_window_similarity.sql`, `sql/17_narrative.sql` (one line pair),
`sql/19_reference.sql`, `demo/awrdemo/sections/s26_window_similarity.py`,
`demo/verify_report.js`, `CLAUDE.md`, `CHANGELOG.md`, this file,
`plans/README.md`, the three regenerated demo pages.

## Not covered

- No note when no suggestion changes any bucket (an odd window that moves
  nothing is already in section 26's row text).
- No note when fewer than 3 valid priors would remain after the drop (a
  rule added beyond the brief: with fewer, every metric turns "insufficient
  history", which says nothing about the baseline).
- A report generated before this change has no `li.hn-base`; verify_report's
  new check then fails on it when a suggestion changes a bucket.
- One note only (the suggestion that changes the most); the others stay in
  section 26.
- No change to the fleet report, to `policy_bucket` or to any threshold.

## Names to check on dbmint (DESC / SELECT DISTINCT)

None: no new view, column or statistic. The numbers are section 26's
existing `v_schg` / `v_sca` / `v_cbn`.

## dbmint checklist (owner)

1. A run where section 26 reports an odd window (an incident inside a prior
   window, e.g. `"2026-11-09 16:00" 1 24 10 0 1 h` style windows around the
   blocking hour): the verdict shows "Baseline check:" as the last note; the
   numbers equal section 26's "Reads as" sentence for the same suggestion.
2. A run with no odd window (alike priors): no note, no empty list.
3. A run where 17 also has notes (plan change, parameter change): the
   baseline note is below them.
4. Run with `win_hours` / `weeks_back` giving only 3 valid priors where the
   odd window is one of them: no note (fewer than 3 would remain).
5. Click the link: Summary opens the Window similarity library row; All
   sections scrolls to it. Copy summary contains the line.
6. `grep -c "Baseline check"` on the HTML is 1 per report; no `ORA-`.
