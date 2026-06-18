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
- **The connect string** (`user/pw@svc` below) is any SQL\*Plus connect
  identifier — a TNS alias, an EZConnect `user/pw@host:1521/service`, or `/` for
  OS authentication.

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

## Shell (`run_awr_trend.sh`)

Inline markers ride in the `MARKERS` env var (not a positional arg), so prefix
the command with them. The positional slots are
`<connect> target_end win_hours weeks_back top_n inst_num step step_unit template`:

```bash
MARKERS='2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild' \
  ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w dev
```

- `AUTO 1 4` → current full hour, 1-hour window, 4 prior windows.
- `10 0` → Top-10 SQL, aggregate across RAC instances.
- `1 w` → step back 1 week at a time.
- `dev` → the developer template.
- Each marker is `WHEN|LABEL`; join multiple with `;;`. Labels must not contain
  a straight `'`, `|`, `;;`, `~`, or `&`.

---

## Pure SQL\*Plus

Load the defaults, override the three things that differ, set `markers`, then
run the driver as a **separate** start command (heredoc):

```bash
sqlplus -S -L user/pw@svc <<'SQL'
@sql/defaults.sql
DEFINE target_end = 'AUTO'
DEFINE weeks_back = 4
DEFINE template   = 'dev'
DEFINE markers    = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
@awr_trend.sql
EXIT
SQL
```

If you set every `DEFINE` by hand instead of loading `@sql/defaults.sql`, also
include the empty `DEFINE marker_file = ''` and `DEFINE echarts = ''` lines — the
driver references both, and an unset value stops for an "Enter value" prompt.

> **Never** put `@sql/defaults.sql @awr_trend.sql` on one line — SQL\*Plus runs
> only the first `@file` and treats the second as a parameter, so the driver
> silently never runs. Keep them on separate lines (as above).

---

## Variant — last 4 Saturdays, 09:00–18:00

A 9-hour window (`09:00 → 18:00`, so `win_hours=9`, `target_end` = `…18:00`)
on the most recent Saturday plus the 3 prior Saturdays (`weeks_back=3` → 4
windows total): **2026-06-13, 06-06, 05-30, 05-23**.

```bash
MARKERS='2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild' \
  ./run_awr_trend.sh user/pw@svc '2026-06-13 18:00' 9 3 10 0 1 w dev
```

```bash
sqlplus -S -L user/pw@svc <<'SQL'
@sql/defaults.sql
DEFINE target_end = '2026-06-13 18:00'
DEFINE win_hours  = 9
DEFINE weeks_back = 3
DEFINE template   = 'dev'
DEFINE markers    = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
@awr_trend.sql
EXIT
SQL
```

---

## Variant — last 4 Sunday mornings, 09:00–13:00

A 4-hour window (`09:00 → 13:00`, so `win_hours=4`, `target_end` = `…13:00`)
on the most recent Sunday plus the 3 prior Sundays (`weeks_back=3` → 4 windows
total): **2026-06-14, 06-07, 05-31, 05-24**.

```bash
MARKERS='2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild' \
  ./run_awr_trend.sh user/pw@svc '2026-06-14 13:00' 4 3 10 0 1 w dev
```

```bash
sqlplus -S -L user/pw@svc <<'SQL'
@sql/defaults.sql
DEFINE target_end = '2026-06-14 13:00'
DEFINE win_hours  = 4
DEFINE weeks_back = 3
DEFINE template   = 'dev'
DEFINE markers    = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
@awr_trend.sql
EXIT
SQL
```

> Want the current Saturday/Sunday plus **4** prior (5 windows)? Use
> `weeks_back=4` instead of `3`. AWR retention must then cover ~5 weeks.

---

## Variant — fully self-contained / offline HTML

By default the report pulls the ECharts chart library from a public CDN. For an
air-gapped box (or a report you want to email and have render with **zero**
network), point the `echarts` var at a **local** copy of `echarts.min.js`; the
shell wrapper then inlines its bytes into the finished HTML, producing one
single file that draws every chart offline. A pinned copy (Apache-2.0, v5.6.0)
**ships with the repo** at `vendor/echarts.min.js`, so this works out of a fresh
clone — nothing to download.

In the wrapper the source travels in the `ECHARTS` env var (like `MARKERS`):

```bash
MARKERS='2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild' \
ECHARTS=vendor/echarts.min.js \
  ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w dev
```

The finished file lands in `reports/` (adds ~1 MB) and needs no network at all.

**Pure SQL\*Plus** can't do the inlining itself (that splice lives only in the
wrapper). Two options:

```bash
sqlplus -S -L user/pw@svc <<'SQL'
@sql/defaults.sql
DEFINE target_end = 'AUTO'
DEFINE weeks_back = 4
DEFINE template   = 'dev'
DEFINE markers    = '2026-06-10 09:00|Release 2.0;;2026-06-11 03:00|Patch 19.22;;2026-06-15 22:00|Index rebuild'
DEFINE echarts    = 'vendor/echarts.min.js'   -- emits <script src="vendor/echarts.min.js">
@awr_trend.sql
EXIT
SQL
```

That emits a `<script src="vendor/echarts.min.js">` tag, so the report renders
offline **only if you keep that `.js` beside it**. To collapse it into one truly
self-contained file, run the same splice the wrapper does, from the repo root,
right after generation:

```bash
html="$(ls -t reports/*.html | head -1)"
lib='vendor/echarts.min.js'                              # same path as DEFINE echarts
line="$(grep -nF "src=\"$lib\"" "$html" | head -1 | cut -d: -f1)"
{ head -n $((line-1)) "$html"; echo '<script>'; cat "$lib"; echo '</script>'; tail -n +$((line+1)) "$html"; } \
  > "$html.tmp" && mv "$html.tmp" "$html"
```

(If you instead point `echarts` at an `https://` internal-mirror URL, you get a
single file that renders wherever that mirror is reachable — no inlining and it
works on the pure-SQL\*Plus path too.)

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