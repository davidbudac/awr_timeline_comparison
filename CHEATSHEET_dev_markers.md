# Cheat sheet — current hour vs 4 weeks back, `dev` template, custom markers

A focused recipe for the most common developer triage run:

- **current hour** — `target_end=AUTO` (the prior full hour), `win_hours=1`
- **compared 4 weeks back** — `weeks_back=4`, `step=1`, `step_unit=w`
  (this hour + the same hour on each of the 4 prior weeks = 5 windows)
- **`dev` template** — the app-developer metric/wait subset
- **a few custom markers** — file-free milestones drawn as vertical lines on
  the dated charts

Run from the repo root. For the full menu of recipes see [CHEATSHEET.md](CHEATSHEET.md).

---

## Before you start

- **Where to run it:** from the repo root (so `run_awr_trend.sh`, `sql/`, and
  `awr_trend.sql` resolve). Make the wrapper executable once: `chmod +x run_awr_trend.sh`.
- **What you need:** Oracle 19c with the Diagnostic & Tuning Pack, and an
  account that can `SELECT` the `DBA_HIST_*` views (read-only is enough — the
  tool issues no DDL/DML). `sqlplus` on your PATH.
- **The connect string** is shown below as `/ as sysdba` (OS authentication);
  swap in any SQL\*Plus connect identifier — `user/pw@svc`, a TNS alias, or an
  EZConnect `user/pw@host:1521/service`.

---

## Where's my report?

Every run writes one self-contained HTML file into the `reports/` directory and
prints its path at the end. Open the newest one:

```bash
open "$(ls -t reports/*.html | head -1)"     # macOS;  Linux: xdg-open
```

The file is portable — copy it anywhere and open it in a browser. The only thing
it fetches from the network is the chart library (see the offline recipe below);
all numbers render even with no network.

---

## The calls

Each variant has two forms: the **shell wrapper** (connection shown as
`/ as sysdba` — swap in any connect string) and **straight SQL\*Plus** (assumes
you're already at a `SQL>` prompt).

All four use the **`dev` template** and the **same three markers**. Set those
once so the per-variant cells stay short:

**Shell** — export the markers (the wrapper reads `MARKERS` from the env):

```bash
export MARKERS='2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
```

**SQL\*Plus** — load the defaults, then pin the template + markers once:

```sql
@sql/defaults.sql
DEFINE template = 'dev'
DEFINE markers  = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
```

Then run any variant below:

| Variant | Shell call | SQL\*Plus call |
|---|---|---|
| **Current hour vs 4 weeks back**<br>1-hour window — this hour + same hour on each of the 4 prior weeks | `./run_awr_trend.sh "/ as sysdba" AUTO 1 4 10 0 1 w dev` | `DEFINE target_end = 'AUTO'`<br>`DEFINE win_hours  = 1`<br>`DEFINE weeks_back = 4`<br>`@awr_trend.sql` |
| **Last 4 Saturdays, 09:00–18:00**<br>9-hour window — most recent Sat + 3 prior (06-13, 06-06, 05-30, 05-23) | `./run_awr_trend.sh "/ as sysdba" '2026-06-13 18:00' 9 3 10 0 1 w dev` | `DEFINE target_end = '2026-06-13 18:00'`<br>`DEFINE win_hours  = 9`<br>`DEFINE weeks_back = 3`<br>`@awr_trend.sql` |
| **Last 4 Sunday mornings, 09:00–13:00**<br>4-hour window — most recent Sun + 3 prior (06-14, 06-07, 05-31, 05-24) | `./run_awr_trend.sh "/ as sysdba" '2026-06-14 13:00' 4 3 10 0 1 w dev` | `DEFINE target_end = '2026-06-14 13:00'`<br>`DEFINE win_hours  = 4`<br>`DEFINE weeks_back = 3`<br>`@awr_trend.sql` |
| **Self-contained offline HTML**<br>same window as row 1, but inline the chart library so the file needs no network | `ECHARTS=vendor/echarts.min.js ./run_awr_trend.sh "/ as sysdba" AUTO 1 4 10 0 1 w dev` | `DEFINE echarts    = 'vendor/echarts.min.js'`<br>`DEFINE target_end = 'AUTO'`<br>`DEFINE win_hours  = 1`<br>`DEFINE weeks_back = 4`<br>`@awr_trend.sql` |

Reading the table:

- **Shell positional slots** are
  `<connect> target_end win_hours weeks_back top_n inst_num step step_unit template`,
  so `10 0 1 w dev` = Top-10, aggregate across RAC, weekly cadence, dev template.
- **SQL\*Plus** cells assume the shared prelude above ran in the same session.
  Re-run `@awr_trend.sql` after changing the DEFINEs to render the next variant.
  Each cell sets every window var, so you can also jump straight to a row — but
  after the offline row, reset `DEFINE echarts = ''` to go back to the CDN.
- **Markers:** each is `WHEN|LABEL`, joined by `;;`. Labels must not contain a
  straight `'`, `|`, `;;`, `~`, or `&`.
- **"Last 4"** = the target window + 3 prior (`weeks_back=3`). Want the current
  Sat/Sun **plus** 4 prior (5 windows)? Use `weeks_back=4` (needs ~5 weeks of
  retention).
- **Offline, SQL\*Plus caveat:** `DEFINE echarts='vendor/echarts.min.js'` emits a
  `<script src="vendor/echarts.min.js">` tag but does **not** inline the bytes —
  only the shell wrapper splices them in for a single self-contained file. From
  SQL\*Plus, either keep that `.js` beside the report or point `echarts` at an
  `https://` mirror URL. The full manual-splice recipe is in
  [CHEATSHEET.md](CHEATSHEET.md). A pinned `vendor/echarts.min.js` (Apache-2.0,
  v5.6.0) ships in the repo, so the local-path form works from a fresh clone.

---

## Notes

- `marker_file` (a `.sql` config file) wins over `markers` if both are set; here
  we use the file-free `markers` var so nothing extra lives on disk.
- A marker outside a chart's time span is dropped for that chart; otherwise it
  snaps to the nearest point on the axis. A malformed datetime is skipped, not
  fatal.
- Markers only draw on the **dated** charts (masthead strip, ASH timeline,
  DB-time summary, per-SQL ASH cards). Sparklines and value-axis charts are
  undated and show none.
- AWR retention must cover ~29 days for the 4-weeks-back lookback:
  `SELECT retention FROM dba_hist_wr_control;`
```