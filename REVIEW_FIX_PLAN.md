# Review fix plan (2026-07-07)

Actionable findings from a full-project review (4 parallel reviewers + manual
verification of every high-priority claim against the code; Oracle view/column
assumptions were validated live on dbmint 19c). Work through the phases in
order. Findings F1–F2 were verified line-by-line and are definitely real; the
rest were verified by at least one reviewer against the actual code.

**Before touching anything, read `CLAUDE.md` in full.** It documents the
invariants you must not break: read-only SELECT-only rule, the tilde
substitution gotcha (no literal `~x` even in comments), `@@sql/lib/...`
include-path resolution, the LISTAGG folded-delimiter positional-CSV contract,
`dbid IN (dbid_list)` (never `=`), and the `~step_hours/24` cadence rule.

**Verification loop for every phase:**
1. `./lint.sh` must stay clean.
2. For output-affecting SQL changes, run a report on dbmint (see
   `CLAUDE.md` → "Verification & testing" for the rsync command, the
   dbmint default-window trap, and the byte-identity md5 recipe). Pin
   `target_end` into a known-good stretch; do NOT use AUTO on dbmint.
3. Changes marked *byte-identical-when-aligned* below must produce a
   byte-identical report (post-normalization md5) on dbmint's gap-free
   hourly windows; only misaligned/edge-case inputs may differ.

---

## Phase 1 — accuracy bugs (highest value)

### F1 (bug-high): per-event wait z-score baseline is censored by the top-N filter
- **Where:** `sql/04_waits_fg.sql` (~lines 218–292, the `events`/`grid` CTEs
  and the aggregate that computes `mu_us/sd_us/n_us` and `mu_ms/sd_ms/n_ms`);
  identical shape in `sql/05_waits_bg.sql` (~lines 248–321).
- **Defect:** `grid` is `events CROSS JOIN all_weeks LEFT JOIN top_n_events`.
  Because the measures come from `top_n_events` (rank-filtered) rather than
  `deltas` (full history), any prior window where the event ranked below
  `top_n` contributes NULL to the baseline. An event that newly spikes into
  the top-N gets `n=0` prior samples → `score_cells` renders "insufficient
  history" instead of a crit/warn finding. This suppresses exactly the
  newly-spiking events the report exists to flag, and biases baselines high
  for events hovering around the cutoff.
- **Fix:** keep `top_n_events` for *selecting which events to display*
  (`events` CTE and `cur_rnk`/`week_rnk_vals`, which are genuinely about
  rank), but LEFT JOIN the `grid` measures (`time_waited_us`,
  `total_waits`) from `deltas` keyed on `(event_name, week_offset)`. `rnk`
  can still come from `ranked`/`top_n_events` (NULL when below cutoff is
  correct for the rank CSV). Apply the same change to both 04 and 05.
- **Watch out:** the six positional LISTAGG CSVs in the same aggregate
  (`spark_vals`, `spark_ms_vals`, `week_us_vals`, `week_ms_vals`,
  `week_rnk_vals`) will now carry real values in weeks that previously
  emitted empty slots — that is the *intended* behavior change (sparklines
  and per-week columns become complete), but keep the folded-delimiter
  `','||token` + `SUBSTR` idiom intact for genuinely-NULL tokens.
- **Verify:** on dbmint, compare pre/post reports: rows whose event was in
  top-N in every window must keep identical mu/sd/z; rows with below-cutoff
  prior weeks must gain history (em-dashes → numbers). Cross-check one event
  by hand with a manual query against `DBA_HIST_SYSTEM_EVENT`. Confirm the
  wait-class rollup (unchanged) now agrees directionally with per-event rows.

### F2 (bug-high): per-second rates divide by the requested window length, not the resolved snap span
- **Where:** `sql/lib/windows_cte.sql` line ~180:
  `dur_sec = (CAST(win_end_ts AS DATE) - CAST(win_start_ts AS DATE)) * 86400`
  — this is the *requested* span (`win_hours*3600`). Consumers:
  `sql/02_load_profile.sql` (~line 80), `sql/07_summary.sql` (~178, 247),
  `sql/08_overview.sql` (~93).
- **Defect:** begin/end snaps are resolved with only a one-sided ±5-minute
  tolerance (`begin ≤ win_start+5min`, `end ≥ win_end−5min`, candidates
  gathered ±1 day), so the resolved snap-to-snap span can far exceed the
  nominal one. Counter deltas span the actual snaps; the denominator stays
  nominal. Hourly snaps at :30 vs a 1-hour window at :00 → all LOAD rates 2×
  reality. A 15-min window on hourly snaps → ~4×, still marked "valid".
  Section 03 (SYSMETRIC, per-snap averages) is immune, so 02 and 03 visibly
  disagree.
- **Fix (two parts):**
  1. Carry the resolved span into `valid_windows`: `dur_sec =
     (CAST(es.end_ts AS DATE) - CAST(bs.end_ts AS DATE)) * 86400` — the
     `begin_snap`/`end_snap` CTEs already expose `end_ts`; thread it through
     `instance_pairs`/`windows` to `valid_windows`. Keep `win_start_ts` /
     `win_end_ts` unchanged (labels/markers/time-axis sections use them).
  2. Add a window-validity guard: if the resolved begin or end snap sits more
     than some tolerance from the requested edge (suggest: half the window
     length, or a fixed 15 min — pick one and document it), set
     `valid_flag='N'` with `skip_reason` like `'no snapshot near window
     edge'`. This surfaces the misalignment in section 01 instead of
     silently normalizing it away.
- **Watch out:** `windows_rollup` and section 01's ribbon display
  `skip_reason` — the new reason string flows through automatically but
  check it renders (it passes through `DBMS_XMLGEN.CONVERT`). RAC: the fix
  is per-instance (each instance has its own resolved snaps) — `dur_sec`
  is already per-instance in `valid_windows`, keep it that way.
- **Verify:** *byte-identical-when-aligned* — on dbmint with snaps aligned to
  the window edges, pre/post reports must be byte-identical (md5 recipe in
  CLAUDE.md). Then pick a deliberately misaligned `target_end` (e.g. off by
  30 min from the snap grid with hourly snaps) and confirm the window is
  either skipped with the new reason or its rates use the actual span.

## Phase 2 — small accuracy fixes (each ~1 line)

### F3: %Δ renders as `###` at ≥1000%
- **Where:** `sql/07_summary.sql:126` (`FMS990D0`), `sql/08_overview.sql:224,
  256, 260` (`FMS990D0`), also `08:230` (`z` chip, `FMS990D0`).
- **Fix:** widen to at least `FMS99990D0` (5 digits, matching the heatmap
  tooltip at `07:354`); align `score_cells.plsql:54` (`FMS9990D0`) to the
  same width so 04/05/07/08 all agree. Consider clamping display at some
  ceiling (e.g. `&gt;9999%` → `+9999%`) rather than ever emitting `#`.
- **Verify:** eyeball; grep the generated HTML for `#%` / `>#<` — must be 0.

### F4: ASH timelines drop the trailing partial bucket
- **Where:** `sql/09_ash_timeline.sql:78` and
  `sql/11_top_sql_ash_breakdown.sql:117`:
  `v_total_buckets := GREATEST(ROUND(v_total_hours / v_bucket_hours), 1)`
  but bucket assignment uses `FLOOR`, so a fractional final bucket
  (`frac < 0.5`) gets index `>= v_total_buckets` and is dropped.
- **Fix:** `ROUND` → `CEIL` in both files.
- **Verify:** *byte-identical-when-aligned* (integer h/d/w cadences give the
  same count); a fractional cadence (e.g. `step=45`, `step_unit='h'`… use
  `win_hours` fractions) gains a final bucket.

### F5: JSON backslash-escaping gap in sections 14/15
- **Where:** `sql/14_segment_io.sql:315-316,507`;
  `sql/15_file_io.sql:318,509` — series names escaped with
  `REPLACE(x,'"','\"')` only.
- **Fix:** copy section 06's escape chain (`sql/06_top_sql.sql:626-627`):
  escape `\` first, then `"`, then CR/LF. Consider extracting a tiny shared
  `sql/lib/json_escape.plsql` include if it stays SELECT-only and simple;
  otherwise duplicate the 06 idiom verbatim.
- **Verify:** *byte-identical* on dbmint (no backslash names there); unit-style
  check: a name like `A\B"C` must emit `A\\B\"C`.

### F6: section 04 wait-class rollup ignores the template wait filter
- **Where:** `sql/04_waits_fg.sql` rollup `pairs` CTE (~lines 389–399) —
  filters only `wait_class <> 'Idle'`, missing the `wait_targets`
  EXISTS/IN idiom used at 04:199-200 and 07:232-233.
- **Fix:** add the standard sentinel idiom (see CLAUDE.md "Wait-event filter
  idiom"). No effect under `comprehensive` (the `'*'` sentinel).
- **Verify:** *byte-identical* under `comprehensive`; under `template=simple`
  the class totals shrink to curated events and now match section 07's
  class findings.

### F7: section 12 row buffer can overflow (ORA-06502)
- **Where:** `sql/12_param_changes.sql:43` (`v_row VARCHAR2(32767)`)
  accumulating one `<td>` per window of `DBMS_XMLGEN.CONVERT(value)`
  (values up to 4000 chars, expanded by entity escaping), emitted at ~199.
- **Fix:** emit incrementally — `PUT_LINE` per `<td>` (or per cell chunk)
  instead of accumulating the whole `<tr>`; or truncate displayed values to
  a sane length (e.g. 500 chars + ellipsis + full value in a `title`
  attribute). Incremental emission is safer and keeps full values.
- **Verify:** *byte-identical* on dbmint if you keep per-cell markup
  unchanged (whitespace/line breaks between cells may differ — if so verify
  by eye/diff instead and note it).

### F8: section 10 "Database time" mixes FG-only CPU with all-session waits
- **Where:** `sql/10_db_time_summary.sql:88-104` — DB CPU from
  `DBA_HIST_SYS_TIME_MODEL` (foreground) stacked with waits from
  `DBA_HIST_SYSTEM_EVENT` (includes background: LGWR/DBWR writes etc.).
- **Fix (labeling, not a rewrite):** retitle/caption the chart to something
  honest, e.g. "DB CPU + non-idle wait time (all sessions incl. background)",
  or add a one-line methodology note under the `<h2>`. Do NOT attempt a
  foreground-only wait projection (no such column on that view).
- **Verify:** eyeball only.

## Phase 3 — wrapper robustness (`run_awr_trend.sh`)

### F9: positional args unvalidated; newline breaks out of the heredoc
- **Where:** positional parsing (~213–229) and both heredocs (`DEFINE` blocks
  at ~215–218 and ~429–432) — numeric vars interpolated unquoted; string
  vars break on embedded `'` or newline. A newline in any value adds raw
  SQL*Plus lines (incl. `HOST`) to the script.
- **Fix:** validate on the positional path before building the heredoc:
  numerics (`win_hours`, `weeks_back`, `top_n`, `inst_num`, `step`) against
  `^[0-9]+([.][0-9]+)?$` / `^[0-9]+$` as appropriate; `step_unit` against
  `^[hdw]$`; `target_end` against the `AUTO`/datetime shapes; reject any
  value containing a newline or `'` with a clear one-line error naming the
  argument. Reuse the configurator's `v_*` validators where they exist
  (extract into shared functions rather than duplicating).
- **Verify:** `./run_awr_trend.sh conn abc` → clear error, no sqlplus spawn;
  `./run_awr_trend.sh conn $'1\nHOST id'` → rejected; a normal run is
  unchanged.

### F10: configurator gaps
- **Where:** `run_awr_trend.sh` — `v_target_end` (~276–281) regex accepts
  impossible instants (`2026-06-31`, hour 25); `WIN_HOURS`/custom `STEP`
  (~342–343, ~528) validated with `v_posint`, so fractional `0.25` (which
  the engine supports) cannot be entered.
- **Fix:** (a) add a real calendar check — `date -d "$val" >/dev/null 2>&1`
  is fine on Linux (this wrapper already assumes GNU-ish tooling; if
  portability matters, do the month/day table check in bash); (b) relax the
  win_hours/step validators to accept positive decimals
  (`^([0-9]+([.][0-9]+)?)$` with a > 0 check), and update the prompt help
  text to mention `0.25 = 15 min`.
- **Verify:** configurator run: `2026-06-31 09:00` rejected with a message;
  `0.25` accepted and appears in the printed command; generated command runs.

### F11: misleading "`/` = SYSDBA" help text
- **Where:** `run_awr_trend.sh:41` (usage example comment) and the
  configurator banner (~519).
- **Fix:** correct the copy: plain `/` = OS-authenticated ordinary session;
  for SYSDBA the user must pass `"/ as sysdba"` (quoted). Check whether the
  wrapper actually passes a multi-word connect string through to sqlplus
  intact — if not, fix or document that too. Also update any README /
  CHEATSHEET text repeating the claim (`grep -rn "as sysdba" README.md
  CHEATSHEET*.md docs/` and fix matches that make the same claim).
- **Verify:** `./run_awr_trend.sh "/ as sysdba" …` against dbmint works.

### F12: `echarts` / `marker_file` edge cases
- **Where:** `run_awr_trend.sh` `is_url()` (~169) matches only lowercase
  `http://`/`https://`; nothing enforces the documented `"`-free contract
  for `echarts`; a nonexistent `marker_file` at run time dies with a bare
  `SP2-0310` and produces a markerless report.
- **Fix:** case-insensitive URL match (and treat `//host/…` as URL); reject
  `echarts` values containing `"` with a clear error (wrapper + configurator);
  for `marker_file`, stat the file in the wrapper before launching sqlplus
  and fail fast with a readable error (the pure-SQL*Plus path can keep its
  current behavior — note it in CLAUDE.md if you change semantics).
- **Verify:** `ECHARTS='HTTPS://x/e.js'` treated as URL;
  `ECHARTS='a"b'` rejected; bad `MARKERS`-file path → clear wrapper error.

## Phase 4 — UX / dark-mode polish

### F13: dark-mode legibility
- **Where:** `sql/_style.sql` `.cdn-warn` (~656–660) hardcodes
  `color:#7c5b00; border:…#f0d77a` over `var(--warn-bg)` (near-black in
  dark mode) — the offline-charts banner is illegible exactly when needed.
  `sql/01_windows.sql` ribbon SVG hardcodes `#c8d0dc` axis (~56), `#9aa3af`
  skipped fill (~96), and `fill="#666"` labels (~102, 111) on a
  `var(--panel-2)` background.
- **Fix:** move the hardcoded colors to CSS custom properties with dark
  overrides (SVG `fill` can use `fill="var(--ribbon-label)"` since the SVG
  is inline). Follow the existing variable naming in `_style.sql`.
- **Verify:** open a generated report, toggle dark, check the ribbon labels
  and (with `body.no-charts` forced via devtools) the banner.

### F14: theme toggle doesn't restyle ECharts
- **Where:** `sql/00_params.sql` — masthead chart reads `--accent`/`--muted`
  via `getComputedStyle` once at init (~676–679) and hardcodes light-blue
  fills (`rgba(31,95,168,…)` ~680, 699); the theme toggle handler (~831–840)
  dispatches no event, so *every* ECharts chart keeps the old theme's axis
  colors after a toggle. (Sections 06/09/10/11/14/15 charts have the same
  init-once pattern.)
- **Fix:** minimal-diff approach: have the theme toggle dispatch a
  `CustomEvent('awr:theme')` (mirroring the existing `awr:appfilter`
  pattern), and in each chart-init script re-read the CSS vars and
  `setOption` on that event. Replace the hardcoded rgba fills with values
  derived from the CSS vars (or two constants switched on
  `document.body.classList.contains('dark')`). Keep everything inline —
  no new external JS (CLAUDE.md invariant).
- **Verify:** live browser: load light → toggle dark → axis labels, fills,
  and markArea bands all adapt on every chart; toggle back; reload in dark
  (persisted theme) also correct. Re-check `body.no-charts` path unaffected.

### F15: ASH window bands ignore `valid_flag`; current-window right edge unanchored
- **Where:** `sql/09_ash_timeline.sql` (~164–168, 268) and
  `sql/11_top_sql_ash_breakdown.sql` (~164–168, 577–578): the window-band
  JSON carries `valid_flag` as tuple element `w[3]` but `markAreaData`
  never reads it — skipped windows are shaded like real ones over empty
  space. Separately, band edges are string-matched against bucket-start
  category labels, and the current window's end (= last label + bucket) has
  no exact category anchor — visually confirm the final band isn't dropped
  or short.
- **Fix:** in the markArea builder, skip (or style distinctly — e.g. hatched/
  lower-opacity + "(skipped)" in the label) tuples with `valid_flag !== 'Y'`;
  for the right edge, clamp to the last category label when the exact
  end-label is absent.
- **Verify:** dbmint report containing at least one invalid window (pick a
  `target_end` whose span includes the known restart) — skipped band renders
  distinctly; current-window band spans to the chart's right edge.

### F16: "insufficient history" vs "n/a" label inconsistency
- **Where:** `sql/08_overview.sql:198,229` emits "n/a" where
  `sql/07_summary.sql:285` / `score_cells.plsql:32` say "insufficient
  history" for the same underlying condition.
- **Fix:** make 08 use "insufficient history" when `cur` exists but `n<3`,
  and keep "n/a" only for `cur IS NULL`. (That distinction may already be
  intended — read the code first; if 08 already separates the two cases,
  narrow the fix to whichever case actually mismatches 07.)
- **Verify:** eyeball on dbmint (its sparse history triggers these paths).

---

## Ground rules for the implementing agent

- One phase per commit (or finer); run `./lint.sh` before every commit.
- Sections all run under `SET DEFINE '~'` — never introduce a literal `~x`
  in code or comments.
- Everything must stay `SELECT`-only; no DDL/DML, no scratch objects.
- All user-derived strings entering HTML go through `DBMS_XMLGEN.CONVERT`.
- Byte-identity is the strongest regression signal: for any change marked
  *byte-identical-when-aligned*, produce pre/post reports on dbmint at the
  same wall-clock and md5-compare after the normalization sed in CLAUDE.md.
- If dbmint is unreachable, say so in the commit/PR notes and mark the
  affected verifications as pending — do not claim them done.
- Update `CLAUDE.md` (and `CHANGELOG.md`) where a fix changes documented
  behavior (F2's new skip_reason, F11's connect-string docs, F14's new
  `awr:theme` event alongside `awr:appfilter`).
- Delete this file once all phases are done (or move the residue into
  CLAUDE.md's "Verified on dbmint" section).
