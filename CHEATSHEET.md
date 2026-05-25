# Cheat sheet

Ready-to-paste recipes for `run_awr_trend.sh`. All commands assume your
working directory is the repo root and the wrapper is executable.

## Argument order (positional)

```
./run_awr_trend.sh <connect> [target_end] [win_hours] [weeks_back] \
                              [top_n] [inst_num] [step] [step_unit] \
                              [template] [debug]
```

| Pos | Name         | Default          | Notes                                            |
|-----|--------------|------------------|--------------------------------------------------|
| 1   | connect      | —                | `user/pw@svc`, `/`, or any sqlplus connect string |
| 2   | target_end   | `AUTO`           | `AUTO` = prior full hour, or `'YYYY-MM-DD HH24:MI'` |
| 3   | win_hours    | `1`              | Width of every compared window                    |
| 4   | weeks_back   | `4`              | How many prior windows to include (count, not weeks) |
| 5   | top_n        | `10`             | Top-N rows in Top-SQL / wait tables               |
| 6   | inst_num     | `0`              | RAC: `0` = aggregate, `>0` = filter to one instance |
| 7   | step         | `1`              | Cadence count between adjacent windows            |
| 8   | step_unit    | `w`              | `h` hours, `d` days, `w` weeks                    |
| 9   | template     | `comprehensive`  | `comprehensive` (full lists) or `simple` (triage subset) |
| 10  | debug        | `N`              | `Y` prints one-line timestamped progress markers to stdout (one per section). HTML report is unaffected |

Trailing args you don't care about can be omitted. To pin step / step_unit /
template you must also supply every preceding arg — use `AUTO`/`0` etc. as
placeholders (see examples).

The total compared span is `weeks_back × step + win_hours` of `step_unit`.

---

## Weekly cadence (the original behaviour)

### Default — last 4 same-hour-of-week windows
```bash
./run_awr_trend.sh user/pw@svc
```
Compares `now-1h → now`, `7d ago`, `14d ago`, `21d ago`, `28d ago`.

### Specific Monday morning vs the four prior Mondays
```bash
./run_awr_trend.sh user/pw@svc '2026-04-13 09:00'
```

### Monday 09:00–13:00 across the last 4 Mondays
```bash
./run_awr_trend.sh user/pw@svc '2026-05-25 13:00' 4 3 10 0 1 w
```
Four 4-hour windows ending Mon 13:00 each, stepping back weekly:
2026-05-25, 05-18, 05-11, 05-04 (current + 3 prior). Use
`weeks_back=4` instead of `3` if you'd rather frame it as "current
Monday vs 4 prior Mondays" (5 windows total). If you're running before
13:00 on a Monday, push `target_end` back one week so the current
window is fully populated:
```bash
./run_awr_trend.sh user/pw@svc '2026-05-18 13:00' 4 3 10 0 1 w
```
AWR retention must cover ~29 days for this — see the retention check
at the bottom.

### Two-hour window over twelve weeks of history
```bash
./run_awr_trend.sh user/pw@svc AUTO 2 12
```
Wider window, longer history, still weekly.

### Every other week (fortnightly), 6 windows back
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 6 10 0 2 w
```
Spans 12 weeks; useful when alternating weeks have different workloads
(payroll Tue, batch Wed, …).

### Approximate monthly comparison — every 4th week, 6 windows
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 6 10 0 4 w
```
Spans ~24 weeks. AWR retention must cover that range.

---

## Daily cadence

### Each of the last 7 days at this hour
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 7 10 0 1 d
```
Detects "today is unusual vs the rest of the week".

### Same hour, every other day for 14 days
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 7 10 0 2 d
```

### Daily 09:00 → 10:00 windows for the past 5 business days
```bash
./run_awr_trend.sh user/pw@svc '2026-05-08 10:00' 1 4 10 0 1 d
```
Run on a Friday morning to compare Fri/Thu/Wed/Tue/Mon at 09:00.

### Daily 4-hour batch window for a week
```bash
./run_awr_trend.sh user/pw@svc '2026-05-08 06:00' 4 6 10 0 1 d
```
Six prior days at 02:00–06:00 vs today.

---

## Hourly cadence (straight line back)

### Last 4 hours, hour by hour
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h
```
Five 1-hour windows: current hour + 4 hours back.

### Last 12 hours, hour by hour
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 11 10 0 1 h
```
Twelve 1-hour windows = 12-hour span. Good for "what happened this
morning?" walk-throughs.

### 2-hour windows over the past day
```bash
./run_awr_trend.sh user/pw@svc AUTO 2 11 10 0 2 h
```
Twelve 2-hour windows ending at `target_end` and stepping back every 2 hours.

### Every 4 hours for the past 24 hours
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 5 10 0 4 h
```
Six 1-hour windows separated by 4 hours each — sample points across the day.

### Pin the comparison to a specific hour
```bash
./run_awr_trend.sh user/pw@svc '2026-05-08 14:00' 1 6 10 0 1 h
```
The 14:00 hour vs 13:00, 12:00, 11:00, 10:00, 09:00, 08:00 of the same day.

---

## RAC / multi-instance

### Aggregate across all RAC instances (default)
```bash
./run_awr_trend.sh user/pw@svc
```
`inst_num=0` sums per-instance values for cumulative stats and averages
SYSMETRIC.

### Just instance 1
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 1
```

### Instance 2, hourly cadence, last 6 hours
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 6 10 2 1 h
```

---

## Templates (which metrics & waits to render)

Templates pick the curated set of stats, metrics, and wait events the
report renders. They do not change cadence or compared windows — they
just trim or expand the rows.

### `comprehensive` (default) — every curated metric and the full firehose of waits
```bash
./run_awr_trend.sh user/pw@svc
```
27 load stats, 23 SYSMETRIC metrics, all wait events ranked by time.
Byte-identical to the pre-template report.

### `simple` — triage-friendly subset for a quick glance
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple
```
9 load stats, 8 SYSMETRIC metrics, ~10 commonly-watched wait events.
Section 00 also renders a small `template: simple` pill so you can tell
templates apart at a glance.

### Simple template + hourly cadence — fast walkthrough of the last few hours
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h simple
```

### Roll your own
Drop a directory under `sql/lib/templates/<name>/` with three files —
`sysstat_load_targets.sql`, `sysmetric_targets.sql`,
`wait_event_targets.sql` — and add the name to the whitelist `CASE`
in `awr_trend.sql`. A single `'*'` row in `wait_event_targets.sql` is a
sentinel meaning "no filter, top-N firehose"; any other rows form an
allowlist.

---

## Progress markers (`debug=Y`)

On a busy DB some sections take minutes; with no terminal output it
looks hung. `debug=Y` prints one timestamped line per section to
**stdout** (the HTML report is byte-identical with debug on or off).

### Defaults + debug
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive Y
```

### Simple template + debug (the lightest combo)
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple Y
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

### Tee into a log so you keep the timings
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive Y \
  | tee reports/last_run_markers.log
```

### Pure-sqlplus alternative
If you don't want to type all the positional slots, drive the
substitution variable directly:
```bash
sqlplus -S -L user/pw@svc <<'SQL'
@sql/defaults.sql
DEFINE template = 'simple'
DEFINE debug    = 'Y'
@awr_trend.sql
SQL
```

---

## Legacy — wrapper without the debug slot
The 10th positional arg was added later; older invocations that stop
at slot 9 (template) still work and run with `debug=N`.

---

## Larger Top-N

### Top-25 SQL with default weekly comparison
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 25
```
Useful when the top-10 doesn't capture a noisy outlier.

### Top-50 SQL, hourly straight-back
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 6 50 0 1 h
```

---

## Invocation patterns without the wrapper

If you can't run a shell script (Windows shop, restricted host), drive
sqlplus directly:

```sql
SQL> @sql/defaults.sql
SQL> DEFINE step      = 1
SQL> DEFINE step_unit = 'h'
SQL> DEFINE weeks_back = 6
SQL> DEFINE template  = 'simple'
SQL> @awr_trend.sql
```

Or in one shot, embedded in a sqlplus heredoc:

```bash
sqlplus -S -L user/pw@svc <<'SQL'
DEFINE target_end = '2026-05-08 14:00'
DEFINE win_hours  = 1
DEFINE weeks_back = 6
DEFINE top_n      = 10
DEFINE inst_num   = 0
DEFINE step       = 1
DEFINE step_unit  = 'h'
DEFINE template   = 'comprehensive'
DEFINE debug      = 'N'
@@awr_trend.sql
EXIT
SQL
```

---

## Scheduling & comparison playbooks

### "What's different this morning vs my normal Monday?"
```bash
# Compare the current hour vs four prior Mondays at this hour.
./run_awr_trend.sh user/pw@svc
```

### "Walk me through the last 12 hours hour by hour"
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 12 10 0 1 h
```
Open the report, focus on the **ASH timeline** and **DB time** stacked
areas — those cover the full span at native snap resolution.

### "Did yesterday's batch differ from the previous five Tuesdays?"
```bash
# Set target_end to the end of the batch window.
./run_awr_trend.sh user/pw@svc '2026-05-12 06:00' 4 5 25 0 1 w
```
4-hour windows ending at 06:00, current Tue plus the 5 prior Tuesdays.

### "Quarter-end vs the last three quarter-ends"
```bash
./run_awr_trend.sh user/pw@svc '2026-03-31 23:00' 1 3 25 0 13 w
```
Steps back 13 weeks at a time (≈ quarter). AWR retention must cover ~9
months of history.

### "Is this hour unusually slow compared to its immediate neighbors?"
```bash
./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h
```

---

## Defaults reset

The canonical defaults live in `sql/defaults.sql`. Editing them changes
the site-wide behaviour for every wrapper invocation that omits the
matching positional argument. Keep the original values committed unless
you really want to flip the default cadence:

```sql
DEFINE target_end = 'AUTO'
DEFINE win_hours  = 1
DEFINE weeks_back = 4
DEFINE top_n      = 10
DEFINE inst_num   = 0
DEFINE step       = 1
DEFINE step_unit  = 'w'
DEFINE template   = 'comprehensive'
DEFINE debug      = 'N'
```

---

## AWR retention check

Before you run any of the longer-lookback recipes, verify your AWR
retention covers the span you ask for:

```sql
SELECT retention FROM dba_hist_wr_control;
```

Default retention is 8 days on 19c — long enough for the default weekly
report (28 days won't fit) but you'll need 30+ days for monthly cadence
recipes. Bump it with:

```sql
EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 60*24*60); -- 60 days
```
