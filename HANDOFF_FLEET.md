# HANDOFF: fleet report

## fleet v0.2.0 — "ops console" redesign (2026-07-22, implemented + verified)

The fleet report was redesigned from stacked `<section class="db-card">`s into
one dense **ops-console table**: a masthead (stat badges + wait-class legend +
timeline-marker legend + in-page theme toggle) over a single
`<table class="fleet">` with a collapsed summary `tr.dbrow` + a hidden
`tr.detailrow` per DB (all collapsed by default; click a row to expand its ASH
timeline, headline metric cards, findings, Top-SQL, and drill-down). The visual
spec is `design/fleet_mock_b_ops_console.html`.

**What changed vs v0.1.0**

- **Fragment contract v2**: each `<alias>.frag.html` is now **two `<tr>`s**
  (dbrow + detailrow), NOT a `<section class="db-card">`. The assembler wraps
  frags in the `<table>` it emits. Sentinel is still the frag's last line; both
  `<!-- FLEET-COUNTS … -->` comments are byte-exact and still drive scoring.
- **Row placeholder injection**: `01_row.sql` emits `__FLEET_SCORE__` /
  `__FLEET_SEV__` / `__FLEET_CRIT__` / `__FLEET_WARN__` / `__FLEET_CPILL__` /
  `__FLEET_WPILL__`; the assembler `sed`-substitutes them at assembly time
  (after parsing FLEET-COUNTS + computing the score) and greps for any survivor.
- **New ASH section `02_ash.sql`**: emits `window.FLEET_ASH[<alias>]` (24 hourly
  buckets from `DBA_HIST_ACTIVE_SESS_HISTORY`); the chrome renderer
  (`sql/fleet/js_fleet_charts.plsql`, inline SVG, no ECharts) draws ribbon +
  timeline charts, positions markers, wires row-expand + theme toggle.
- **Markers**: wrapper-owned `MARKERS` / `MARKER_FILE` env vars →
  `window.FLEET_MARKERS` + masthead legend (extract SQL never sees them).
- **Theme toggle** now present in the masthead (`#themeToggle`, flips
  `body.dark`, persists localStorage `"awr-theme"`).
- Section files renumbered: `00_fleet_chrome`, `01_row`, `02_ash`,
  `03_headline`, `04_findings`, `05_topsql`, `06_close`, plus
  `js_fleet_charts.plsql`. Old `01_db_card/02_headline/03_findings/04_topsql/
  05_close` deleted. **Zero single-DB files touched** (verify with `git diff`).

**Verified on dbmint (2026-07-22, 19.27, window `target_end='2026-07-20 12:00'`
win=1h weeks_back=4 step=1h)**: `./lint.sh` clean (56 files), `bash -n` clean;
synthetic `--assemble` (placeholder substitution, sentinel-missing demotion,
ordering, exit code); full run exit 0, masthead `4 db / 3 crit / 0 warn / 0
quiet / 1 unreach`, three OK rows identical score=16 conf-order, deadbox error
row first with ORA-12514, sentinels present, 0 surviving `__FLEET_`, FLEET_ASH
24-slot arrays for all three, both FLEET_MARKERS, 0 external resources, fake
`scottx/<pw>@svc` password absent everywhere (masked display), drill masked;
live-browser render (no console errors, ribbons/timelines/sparklines/metric
cards render, row-expand + theme flip work); single-DB smoke 16 sections 0 ORA-.
**Still pending**: a real multi-DB / RAC / migrated-PDB fleet.

To re-verify quickly, follow the v0.1.0 runbook below but with the v0.2.0
assertions above (and add `MARKERS='2026-07-19 18:00|test marker;;2026-07-20
03:00|second marker'` to exercise marker rendering inside the 24h ASH span).

---

# HANDOFF: verify the fleet report end-to-end on dbmint (v0.1.0, historical)

You are picking up a feature that is **implemented, reviewed, and lint-clean
but not yet verified against a live database**. Your job is the live
verification on dbmint, then the doc updates. Do NOT re-implement or
restructure anything; fix only what verification proves broken.

## What was built (2026-07-14, uncommitted work tree)

A multi-database "fleet report": `run_awr_fleet.sh` reads `fleet.conf`
(`alias|connect` per line), runs the lean per-DB extractor
`awr_fleet_extract.sql` against every entry in parallel (sqlplus heredoc,
`FLEET_PAR` capped), each run spooling two fragments into
`reports/fleet_work_<run_id>/`:

- `<alias>.chrome.html` — page head/CSS/JS (every DB spools its own; the
  assembler keeps the first successful one)
- `<alias>.frag.html` — one `<section class="db-card">`: identity strip,
  hero-six headline sparkline cards, findings table (only |z| > 2 rows,
  section-07 z-model, `templates/fleet/` curated targets), gated top-SQL
  regressions (ELAPSED + PEREXEC dims, 5 s / 0.1 s-per-exec floors, top 5
  each, plan-flip badge), drill-down command, and — the very last spooled
  line — the sentinel `<!-- AWR-DB: <alias> OK -->`.

The wrapper's assembler classifies each alias (rc != 0 OR frag missing OR
sentinel absent ⇒ red error card with masked connect + last 15 log lines),
parses the two machine-readable comments
`<!-- FLEET-COUNTS findings crit=X warn=Y suppressed=Z -->` and
`<!-- FLEET-COUNTS topsql n=N pts=P -->`, computes
`score = 10*crit + 3*warn + min(25, pts)`, and emits
`reports/awr_fleet_<ts>_run<run_id>.html`: masthead counts → error cards
(conf order) → OK cards sorted score DESC (ties = conf order) → footer.
No ECharts anywhere — inline-SVG sparklines only, fully offline.

New files: `run_awr_fleet.sh`, `fleet.conf.example`, `awr_fleet_extract.sql`,
`sql/fleet/{defaults,00_fleet_chrome,01_db_card,02_headline,03_findings,04_topsql,05_close}.sql`,
`sql/lib/templates/fleet/{sysstat_load_targets,sysmetric_targets,wait_event_targets}.sql`.
Modified: `lint.sh` (additive), `.gitignore` (`/fleet.conf`). **Zero
changes to any single-DB file** (`awr_trend.sql`, `run_awr_trend.sh`,
numbered sections, `sql/lib/` shared files) — verify that stays true.

The full design/verification plan is at
`/Users/davidbudac/.claude/plans/1-yes-2-roughly-ethereal-octopus.md`.

## Already done — do not redo

- `./lint.sh` clean (54 files), `bash -n run_awr_fleet.sh` clean.
- Assembler exercised against synthetic fragments (score math,
  error/quiet/truncated classification, sort + tie-break, HTML escaping of
  log tails, exit codes 0/2/3, FLEET_PAR fan-out via a sqlplus stub,
  FLEET_KEEP_WORK semantics).
- Review fixes already in the tree: 04_topsql re-grids its positional
  CSVs onto the full week grid (`agg_grid` CTE) before LISTAGG; sql_id is
  plain text (no dead anchor); 05_close trims target_end to minute
  precision and passes `0 <step> <step_unit>` so the drill-down command is
  actually accepted by run_awr_trend.sh.
- dbmint recon (2026-07-14): cdb1 19.27 reachable, 274 snapshots.
  2026-07-11 06:00–12:45 was a clean 15-min grid with NO restart
  (startup_time constant at 2026-07-10 17:23). A restart happened
  2026-07-14 12:11, and 09/12/13-Jul have NO snapshots — useful for
  exercising skip machinery, poison for a clean baseline.
- An rsync of the repo to `oracle@dbmint:~/awr_timeline_comparison/` plus
  creation of a test `~/awr_timeline_comparison/fleet.conf` was STARTED but
  its completion was never confirmed — re-run both (idempotent).

## dbmint access (from the dbmint-oracle-test skill — invoke it for full details)

- `ssh -p 2201 oracle@dbmint`; every remote sqlplus call needs
  `export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1;`
  first (non-interactive SSH has no Oracle env → ORA-12162 otherwise).
- Auth on the box: `sqlplus / as sysdba`. When passing a connect string to
  a wrapper, quote it as ONE arg: `"/ as sysdba"`.
- **Claude Code sandbox gotcha:** the Bash sandbox blocks ssh to dbmint
  with what looks like a DNS failure. Run every ssh/rsync with
  `dangerouslyDisableSandbox: true`. Only diagnose the network if the
  unsandboxed attempt also fails (then David is likely off VPN — stop and
  tell him).

## Verification steps

0. **Pick the window FIRST.** The 2026-07-11 12:00 pin above is only valid
   while AWR retention still holds those snaps. Re-check:
   `select trunc(end_interval_time), count(*) from dba_hist_snapshot where end_interval_time > sysdate-10 group by trunc(end_interval_time) order by 1;`
   and confirm your chosen stretch has a constant `startup_time`. You need
   ≥ 5 consecutive hourly-coverable hours (4 priors + current). If Jul 11
   has aged out, find a fresh dense restart-free stretch the same way.

1. **Sync + test conf:**
   ```sh
   rsync -az --delete --exclude='.git/' --exclude='reports/' --exclude='.claude/' \
     --exclude='.codex/' --exclude='fleet.conf' \
     ./ oracle@dbmint:~/awr_timeline_comparison/ -e 'ssh -p 2201'
   ssh -p 2201 oracle@dbmint 'cat > ~/awr_timeline_comparison/fleet.conf <<EOF
   cdb_a|/ as sysdba
   cdb_b|/ as sysdba
   cdb_c|/ as sysdba
   deadbox|baduser/badpw@//localhost:1521/no_such_svc
   EOF'
   ```

2. **Full run** (substitute your verified window):
   ```sh
   ssh -p 2201 oracle@dbmint '<oraenv preamble>; cd ~/awr_timeline_comparison && \
     ./run_awr_fleet.sh fleet.conf "2026-07-11 12:00" 1 4 10 1 h; echo RC=$?'
   ```
   Assert: RC=0; masthead reads 4 databases / 1 unreachable; three
   cdb_* cards with IDENTICAL scores and conf-order (proves stable
   tie-break); deadbox error card FIRST with ORA-/TNS- text visible in the
   escaped log tail; workdir `reports/fleet_work_*` KEPT (an error is
   present); every cdb frag ends with its sentinel; both FLEET-COUNTS
   comments present per frag.

3. **Sentinel/truncation path:** copy the workdir, delete the last line of
   one `<alias>.frag.html`, then
   `./run_awr_fleet.sh --assemble <workdir-copy>` → that alias must demote
   to an error card ("sentinel missing"), exit still 0 (others OK).

4. **Quiet-vs-noisy:** dbmint is idle, so expect mostly quiet/low scores —
   verify the MECHANICS, not drama: suppressed-count line matches the
   template row count, "all quiet" one-liner when zero breaches, sort
   order consistent with printed scores. If every findings table is empty,
   also do one run with `weeks_back=2` into a window adjacent to the
   2026-07-14 12:11 restart to see skip/verdict behavior flow through.

5. **Offline + theme:** pull the report back
   (`rsync -az -e 'ssh -p 2201' oracle@dbmint:~/awr_timeline_comparison/reports/ ./reports/`),
   then `grep -c 'src="http' <report>` must be 0; open it in the browser
   preview: sparklines render, OS dark mode flips `body.dark`, error card
   legible in both themes.

6. **Timeout + parallelism:** `FLEET_TIMEOUT=1 ./run_awr_fleet.sh ...` →
   every DB becomes an error card (rc=124), exit 3, no hang.
   `FLEET_PAR=2` normal run still correct.

7. **Credential masking:** temporarily add a `user/pw@svc`-style line
   (fake creds), run, then grep the workdir + report for the password —
   must appear NOWHERE; display must be `user/***@svc`. Remove the line.

8. **Single-DB regression:** `git status` must show no modification to any
   single-DB SQL/wrapper file; plus one smoke run
   `./run_awr_trend.sh "/ as sysdba" "<same window>" 1 4 10 0 1 h` on
   dbmint completing clean (byte-identity is NOT required — no shared file
   changed — but the run must succeed).

9. **`./lint.sh`** still clean after any fixes you make.

## After verification passes

- Update docs per the plan: README.md (Fleet report section: usage, conf
  format, score semantics, env vars, v1 limits — no theme toggle button,
  no ECharts, inst_num pinned 0), CLAUDE.md (fragment/sentinel/FLEET-COUNTS
  contract, chrome-per-extract rationale, "never touch single-DB files for
  fleet features" rule, verified-on-dbmint note with date + window),
  CHANGELOG.md (fleet v0.1.0).
- Update the usage artifact (drop its "verification in progress" chip):
  it lives at https://claude.ai/code/artifact/419197ba-f77b-47bb-a1fd-40d2dd29ad29 —
  from a new conversation you must pass that URL as the `url` param of the
  Artifact tool or you'll mint a new address.
- Do NOT commit or push unless David asks.
- Clean up dbmint: remove the test fleet.conf and any FLEET_KEEP_WORK
  debris under ~/awr_timeline_comparison/reports/.

## Known environment traps (bitten before — see CLAUDE.md)

- Tilde is the live substitution char in every fleet SQL file; never add a
  literal tilde-word to comments while fixing things.
- dbmint AUTO + weekly cadence ⇒ usually zero valid windows (em-dash
  city). Always pin target_end + hourly cadence there.
- Two `@files` on one sqlplus command line silently runs only the first.
- dbmint is too idle for z-score drama and sections 06/11 are
  non-deterministic run-to-run there (rank ties) — don't byte-diff top-SQL
  output across runs.
