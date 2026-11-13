# Plan 012: The docs list every view the report needs and stop stating things that are no longer true

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- README.md CHEATSHEET.md CHANGELOG.md docs/cheatsheet.html docs/configurator.html awr_trend.sql sql/defaults.sql`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (documentation only)
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The README tells a site with a least-privilege analyst account exactly
which views to grant. Two views the report reads are missing from that
list, so a user who follows the README gets `ORA-00942: table or view does
not exist` on the first run — and because the report aborts on any SQL
error, no report at all. The cheat sheet also states the wrong default for
`debug` and shows a section order that changed two releases ago, two site
pages still carry the previous version number, and two user-visible changes
that shipped after the last release are not in the changelog. Docs that are
actively wrong cost more than missing docs.

## Current state

### 1. Grant list — `README.md:44-66`

```sql
GRANT SELECT ON DBA_HIST_SNAPSHOT            TO <user>;
GRANT SELECT ON DBA_HIST_SYSSTAT             TO <user>;
GRANT SELECT ON DBA_HIST_SYSTEM_EVENT        TO <user>;
GRANT SELECT ON DBA_HIST_BG_EVENT_SUMMARY    TO <user>;
GRANT SELECT ON DBA_HIST_SYSMETRIC_SUMMARY   TO <user>;
GRANT SELECT ON DBA_HIST_SQLSTAT             TO <user>;
GRANT SELECT ON DBA_HIST_SQLTEXT             TO <user>;
GRANT SELECT ON DBA_HIST_SEG_STAT            TO <user>;
GRANT SELECT ON DBA_HIST_SEG_STAT_OBJ        TO <user>;
GRANT SELECT ON DBA_HIST_FILESTATXS          TO <user>;
GRANT SELECT ON DBA_HIST_TEMPSTATXS          TO <user>;
GRANT SELECT ON DBA_HIST_IOSTAT_FILETYPE     TO <user>;
GRANT SELECT ON DBA_HIST_ACTIVE_SESS_HISTORY TO <user>;
GRANT SELECT ON DBA_HIST_PARAMETER           TO <user>;
GRANT SELECT ON V_$DATABASE                  TO <user>;
GRANT SELECT ON V_$INSTANCE                  TO <user>;
-- Only if you use side/create_weekly_baselines.sql (optional, writes baselines):
GRANT EXECUTE ON DBMS_WORKLOAD_REPOSITORY    TO <user>;
```

Views actually queried by the report's SQL (counted with
`grep -ohiE "\b(dba_hist_[a-z_]+|v\$[a-z_]+)\b" awr_trend.sql awr_fleet_extract.sql sql/*.sql sql/lib/* sql/fleet/*.sql`):
every view above **plus**

- `DBA_HIST_SYS_TIME_MODEL` — 11 references. Read on every run (DB time /
  DB CPU come from the time model via `sql/lib/load_pairs_cte.sql`,
  sections 00 / 02 / 07 / 08 and the day profile).
- `DBA_HIST_REPORTS` — 26 references. Read by the SQL Monitor section
  (`sql/18_sqlmon.sql`), four rules in `sql/17_narrative.sql`, and the fleet
  band `sql/fleet/06b_sqlmon.sql`. On the single-DB report it is skipped
  only when the run sets `SQLMON=N` (README.md:96 and :122 already document
  that switch).

Names that appear in the SQL sources but are **comments only** and need no
grant: `DBA_HIST_REPORTS_DETAILS` (the code states it is never read),
`DBA_USERS`.

`CLAUDE.md` (the contributor guide) says "Don't widen the `README.md`
grant list without a concrete reason". The concrete reason here: the code
already reads these two views; the list is being corrected, not widened.

### 2. Cheat sheet — `CHEATSHEET.md:248-260`

```
You'll see output like:
```
[awr_trend 08:38:42.369] section 00 params (header + nav)
[awr_trend 08:38:42.594] section 01 windows (aligned begin/end snap pairs)
[awr_trend 08:38:42.600] section 02 load_profile (SYSSTAT deltas)
[awr_trend 08:38:44.188] section 03 sysmetric (SYSMETRIC_SUMMARY averages)
…
[awr_trend 08:38:45.142] all sections rendered; writing HTML epilogue
```

Diff two consecutive timestamps to see which section is your slowest.
Any case-insensitive truthy value enables debug (`Y`, `YES`, `1`, `ON`,
`TRUE`, `T`); everything else (including the default `N`) disables it.
```

Facts:

- The default is **`Y`**: `sql/defaults.sql:34-35` reads
  `-- Enabled by default; pass debug='N' (or any non-truthy value) to silence.`
  / `DEFINE debug      = 'Y'`, and `run_awr_trend.sh:84` has `DEF_DEBUG='Y'`.
- The driver's real marker order (`awr_trend.sql:605-665`,
  `DEFINE _dbg_msg = '…'` lines) starts:

```
section 00 params (header + nav)
section 10 db_time_summary (DB time over the full span)
section 08 overview (hero strip; recomputes z-scores)
section 09 ash_timeline (ASH stacked-area; often the slowest)
```

  and ends with `all sections rendered; writing HTML epilogue`.
- A few lines above (`CHEATSHEET.md:230-234`) the section intro says
  "`debug=Y` prints one timestamped line per section" — still correct.

### 3. Site pages still say v1.6.0

The released version is 1.6.1 (`awr_trend.sql:112`:
`DEFINE awr_version = '1.6.1'`; `docs/index.html` already says v1.6.1).
Stale occurrences:

```
docs/cheatsheet.html:37:      <span>AWR Timeline Comparison</span><span class="rev">v1.6.0</span>
docs/cheatsheet.html:67:    <span class="kicker">Cheat sheet &middot; run_awr_trend.sh &middot; v1.6.0, fleet 0.7.0</span>
docs/cheatsheet.html:599:    <span>AWR Timeline Comparison v1.6.0, fleet 0.7.0</span>
docs/configurator.html:299:      <span>AWR Timeline Comparison</span><span class="rev">v1.6.0</span>
docs/configurator.html:329:    <span class="kicker">Configurator &middot; runs in your browser &middot; v1.6.0</span>
docs/configurator.html:632:    <span>AWR Timeline Comparison v1.6.0, fleet 0.7.0</span>
```

(The fleet version `0.7.0` is current: `run_awr_fleet.sh:113`.)

### 4. Changelog — `CHANGELOG.md`

Top of the file: a short intro, then `## 1.6.1 — 2026-09-27` (line 8), then
`## 1.6.0 — 2026-09-27`. Two user-visible commits are newer than 1.6.1 and
have no entry:

- `eacf8ad` 2026-09-29 `fix(wrappers): fail fast when sqlplus is not on PATH`
- `b68902e` 2026-10-08 `feat(report): SQLMON=N skips the SQL Monitor section`

Entry style in this file: a `## <version> — <date>` heading, an optional
intro paragraph, then bullets that start with a bold lead sentence
(`- **Series highlight on the Activity charts.** Hover …`).

### Conventions

- The Markdown docs are hand-written; keep the surrounding tone and line
  wrapping (~75 columns).
- `docs/*.html` are hand-maintained static pages (deployed by
  `.github/workflows/pages.yml`); edit only the version strings.
- Do not bump `awr_version` — releasing is the owner's call.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint (unaffected, sanity) | `./lint.sh` | exit 0 |
| Views referenced by code | `grep -ohiE "\bdba_hist_[a-z_]+\b" awr_trend.sql awr_fleet_extract.sql sql/*.sql sql/lib/* sql/fleet/*.sql 2>/dev/null \| tr 'a-z' 'A-Z' \| sort -u` | list to compare with the README |

## Scope

**In scope** (the only files you should modify):
- `README.md` (grant list only)
- `CHEATSHEET.md` (the sample output block and the default sentence)
- `docs/cheatsheet.html`, `docs/configurator.html` (the six version strings)
- `CHANGELOG.md` (a new "Unreleased" section)

**Out of scope** (do NOT touch):
- `awr_trend.sql`, `sql/defaults.sql`, the wrappers — the code is right; the docs are wrong.
- `awr_exec_intro.html`, `CHEATSHEET_dev_markers.confluence.txt`,
  `WEEKLY_FLEET_CHECK.*`, `design/*` — reported as possibly stale during the
  audit but not verified line by line; listed in `plans/README.md` for the
  owner.
- `CLAUDE.md`.
- `docs/index.html` (already current) and the example reports under `docs/examples/`.

## Git workflow

- Branch: `advisor/012-docs-grants-and-stale-facts` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `docs: add the two missing grants; fix debug default, section order, site version`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Complete the grant list

In `README.md`, inside the grant code block:

1. Insert after the `DBA_HIST_SYSSTAT` line:
   `GRANT SELECT ON DBA_HIST_SYS_TIME_MODEL      TO <user>;`
2. Insert after the `DBA_HIST_PARAMETER` line:

```sql
-- SQL Monitor section (skip it with SQLMON=N and this grant is not needed):
GRANT SELECT ON DBA_HIST_REPORTS             TO <user>;
```

Keep the `TO <user>;` column aligned with the neighbouring lines.

**Verify**: this prints nothing (every `DBA_HIST_*` view the code queries is
in the README, ignoring the two comment-only names):

```bash
for v in $(grep -ohiE "\bdba_hist_[a-z_]+\b" awr_trend.sql awr_fleet_extract.sql sql/*.sql sql/lib/* sql/fleet/*.sql 2>/dev/null \
           | tr 'a-z' 'A-Z' | sort -u | grep -v -x -e 'DBA_HIST_' -e 'DBA_HIST_REPORTS_DETAILS'); do
  grep -q "GRANT SELECT ON $v " README.md || echo "missing grant: $v"
done
```

### Step 2: Fix the cheat sheet's debug section

In `CHEATSHEET.md`:

1. Replace the four sample `section …` lines with the driver's real first
   four markers, keeping the timestamps' format:

```
[awr_trend 08:38:42.369] section 00 params (header + nav)
[awr_trend 08:38:42.594] section 10 db_time_summary (DB time over the full span)
[awr_trend 08:38:42.600] section 08 overview (hero strip; recomputes z-scores)
[awr_trend 08:38:44.188] section 09 ash_timeline (ASH stacked-area; often the slowest)
```

   Leave the `…` line and the final `all sections rendered` line as they are.
2. Directly under the sample block add one sentence: "Sections run in the
   report's page order (00, 10, 08, 09, 07, 01, …), not in numeric order."
3. Replace "everything else (including the default `N`) disables it." with
   "everything else disables it. Debug is **on by default** (`Y`); pass `N`
   as the 10th argument to silence it."

**Verify**:
- `grep -c 'including the default `N`' CHEATSHEET.md` → `0`.
- `grep -c 'section 10 db_time_summary' CHEATSHEET.md` → `1`.
- Each sample text exists in the driver:
  `for m in 'section 00 params (header + nav)' 'section 10 db_time_summary (DB time over the full span)' 'section 08 overview (hero strip; recomputes z-scores)' 'section 09 ash_timeline (ASH stacked-area; often the slowest)'; do grep -qF "$m" awr_trend.sql || echo "not in driver: $m"; done`
  → no output.

Then check the rest of `CHEATSHEET.md` for the same wrong default:
`grep -n -i "debug" CHEATSHEET.md` — if another sentence says debug is off
by default, fix it the same way; list what you changed in your report.

### Step 3: Bring the two site pages to v1.6.1

In `docs/cheatsheet.html` and `docs/configurator.html`, change `v1.6.0` to
`v1.6.1` on exactly the six lines listed in "Current state".

**Verify**:
- `grep -c "v1\.6\.0" docs/cheatsheet.html docs/configurator.html` → `0` for both.
- `grep -c "v1\.6\.1" docs/cheatsheet.html docs/configurator.html` → `3` for each.
- `git diff --stat -- docs/` → 2 files changed, 6 insertions, 6 deletions.

If either file contains other `1.6.0` text that is **not** a version badge
(for example prose such as "new in v1.6.0"), leave it and mention it in your
report.

### Step 4: Record the two unreleased changes

In `CHANGELOG.md`, insert a new section **above** `## 1.6.1 — 2026-09-27`:

```markdown
## Unreleased

Changes on `main` since 1.6.1 (the footer still says v1.6.1 until the next
release bumps `awr_version`).

- **`SQLMON=N` skips the SQL Monitor section.** Env var `SQLMON` (wrapper)
  / DEFINE `sqlmon` (SQL\*Plus), default `Y`. A falsy value (`N`, `no`, `0`,
  `off`) leaves out section 18 and the verdict's SQL Monitor pills, so
  `DBA_HIST_REPORTS` is never read — its XML parsing can take minutes on a
  busy database. The About line notes the skip. The fleet report's SQL
  Monitor band is unaffected.
- **Wrappers fail fast when `sqlplus` is not on `PATH`.** Both
  `run_awr_trend.sh` and `run_awr_fleet.sh` check for a runnable `sqlplus`
  before doing any work and exit with a clear message instead of failing
  per database.
```

Before writing, confirm both descriptions against the code so the entry is
accurate: `git show --stat b68902e` and `git show --stat eacf8ad`, and read
`README.md:122` (the `SQLMON` row). Adjust wording to match what you find;
do not invent behaviour.

**Verify**: `grep -n "^## " CHANGELOG.md | head -3` → first heading is
`## Unreleased`, second `## 1.6.1 — 2026-09-27`.

### Step 5: Final check

**Verify**: `./lint.sh` → exit 0; `git status --short` → only the five in-scope files.

## Test plan

Documentation only. The step verifications (grant coverage loop, marker
texts present in the driver, version-string counts) are the tests.

## Done criteria

- [ ] Step 1 coverage loop prints nothing
- [ ] `grep -c 'including the default `N`' CHEATSHEET.md` → `0`
- [ ] `grep -c "v1\.6\.0" docs/cheatsheet.html docs/configurator.html` → both `0`
- [ ] `CHANGELOG.md` starts its sections with `## Unreleased`
- [ ] `git status --short` shows only the five in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- `awr_trend.sql`'s `awr_version` is no longer `1.6.1` (a release happened;
  the version strings and the "Unreleased" section must follow the new
  state — report).
- The coverage loop reports a missing view other than the two named here
  (the code gained a new dependency; add nothing without reporting it).
- `git show b68902e` / `eacf8ad` do not exist or do not match the
  descriptions in step 4.

## Maintenance notes

- When a section starts reading a new `DBA_HIST_*` / `V$` view, add the
  grant to `README.md` in the same change. The loop in step 1 is a cheap
  check that could be added to `lint.sh` later (it is not in scope here:
  `lint.sh` changes need the owner's review).
- At the next release, rename "Unreleased" to the new version and bump
  `awr_version`.
- Not verified in this audit (owner to review): `awr_exec_intro.html` may
  describe features that were removed in v1.5.0–1.6.0;
  `CHEATSHEET_dev_markers.confluence.txt` and `design/UI_UX_IMPROVEMENT_PLAN.md`
  may carry stale statements.
