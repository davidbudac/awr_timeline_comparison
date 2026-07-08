# Handoff — review fixes F1–F16 (branch `fix/review-f1-f16`)

All 16 findings from `REVIEW_FIX_PLAN.md` (the full-project audit) are
implemented, lint-clean, and verified on dbmint 19c as far as a **headless /
no-browser** environment allows. Released as **v1.2.0**. This doc is the
handoff for the remaining **live-browser** verification (dark mode / theme
toggle / skipped ASH bands) plus the checks that need a **real, busy, or
migrated DB**.

## Commit map (on this branch, ahead of `origin/main`)

| Commit | Scope |
|---|---|
| `fix(waits,windows)` | **F1** wait z-score baseline uncensored · **F2** rates use resolved snap span + 15-min misalignment guard + per-instance `dur_sec`/`MAX(dur_sec)` |
| `fix(report) F3-F8` | **F3** `#` overflow masks · **F4** ASH final bucket (`ROUND`→`CEIL`) · **F5** JSON backslash escape (`sql/lib/json_escape.plsql`) · **F6** 04 rollup wait filter · **F7** section 12 overflow · **F8** section 10 caption |
| `fix(wrapper) F9-F12` | **F9** positional validation · **F10** calendar check + fractional win/step · **F11** `/` vs `/ as sysdba` copy · **F12** `is_url`/echarts-quote/marker_file guards |
| `fix(report) F13-F16` | **F13** dark-mode ribbon/banner tokens · **F14** `awr:theme` chart re-styling · **F15** skipped ASH bands + right-edge clamp · **F16** `n/a` vs `insufficient history` |
| `docs` | v1.2.0, CHANGELOG, CLAUDE.md, removed the plan |

## Already verified (dbmint 19.27, `target_end='2026-06-30 14:00'` win=1h weeks_back=4)

- Clean runs, 16 sections, no `ORA-`/`SP2-`; version stamp `v1.2.0`.
- **F1**: wait-table em-dash cells 100→21; a suppressed `direct path write`
  crit (z +16.78) now surfaces.
- **F2**: resolved span 3603 s vs nominal 3600 s; aligned window stays valid
  (35/38-s edge gaps « 15 min); HEAD-vs-fix diff confined to sections
  00/02/04/05/07/08.
- **F3**: 10 `######%` cells → real numbers, zero `#` remain.
- **F4/F5/F6/F7**: byte-identical on the aligned grid.
- **F14** (headless DOM stub): all 86 chart instances re-`setOption` a
  dark-palette color on `awr:theme`; all 90 inline scripts parse.
- **F16**: findings split into `n/a` (cur NULL) vs `insufficient history` (n<3).

## TODO — needs a live browser

Generate a fresh report (recipe below) and open it in Chrome.

1. **F14 — theme toggle restyles every chart.** Load in light → click the
   sun/moon toggle in the rail brand row → confirm **every** ECharts chart
   (masthead, waits 04/05, Top-SQL bump 06, findings heatmap 07, ASH 09,
   DB-time 10, per-SQL ASH 11, segment/file I/O 14/15) adapts its axis labels,
   gridlines, legend, and fill/band colors. Toggle back. Reload while dark
   (persisted via `localStorage awr-theme`) — still correct, no light flash.
2. **F13 — dark-mode legibility.** In dark mode, check the section-01 window
   ribbon: axis line, the date/status labels, and any skipped-window box are
   all readable. Then force `document.body.classList.add('no-charts')` in
   devtools and confirm the amber offline-charts banner (`.cdn-warn`) is
   legible (was `#7c5b00` on near-black before).
3. **F15 — skipped ASH bands + right edge.** Needs a report containing an
   **invalid window** — pick a `target_end` whose span includes a known
   instance restart (dbmint was restarted ~2026-07-07). In sections 09 and 11,
   the skipped window should shade muted grey with a "skipped" label (not a
   normal blue band), and the **current** window's band should reach the
   chart's right edge (not stop short).
4. Re-confirm `body.no-charts` path and the <980px stacked fallback are
   unaffected.

## TODO — needs a real / busy / migrated DB (not browser)

- **F2**: the misalignment **skip path** (deliberately off-grid `target_end`,
  e.g. 30 min off an hourly snap grid) and RAC **per-instance `dur_sec`**.
- **F5**: a series name containing a backslash (`A\B"C` → `A\\B\"C`) — dbmint
  has no such names.
- **F6**: `template=simple` — class-rollup totals should now match section 07's
  class findings (byte-identical under `comprehensive`).
- **F9/F10/F12** wrapper edge cases are already unit-tested locally, but a real
  `"/ as sysdba"` run is the end-to-end check (done on dbmint).

## Gotchas for whoever verifies

- **Sections 06 and 11 are non-deterministic run-to-run on idle dbmint**
  (Top-SQL rank ties, no unique tiebreaker). Two runs of identical code differ
  by ~150 lines *inside section 06*. **Exclude 06/11 when byte-diffing**
  (`awk` between the section markers). Everything else is deterministic.
- **dbmint default-window trap**: `AUTO` + weekly cadence usually yields no
  valid windows on the idle test DB. Pin `target_end` into a restart-free
  15-min-snap stretch and use `step_unit='h'`.

## dbmint recipe

```sh
# sync
rsync -az --exclude=.git --exclude=reports --exclude=.claude --exclude=.codex \
  ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2201'
# run (env preamble is mandatory over non-interactive SSH)
ssh -p 2201 oracle@dbmint 'export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; \
  cd ~/awr_timeline_comparison && \
  ./run_awr_trend.sh "/ as sysdba" "2026-06-30 14:00" 1 4 10 0 1 h comprehensive N'
# pull the report back
rsync -az -e 'ssh -p 2201' oracle@dbmint:~/awr_timeline_comparison/reports/ ./reports/
```

Headless JS re-check (no browser, catches syntax + confirms theme re-apply):
see the node DOM-stub snippet used during implementation — stub
`getComputedStyle`/`echarts`, run every `<script>`, dispatch `awr:theme`,
assert each chart re-`setOption`s a dark color.

Delete this file once the browser checks pass (fold anything durable into
CLAUDE.md's "Verified on dbmint" list).
