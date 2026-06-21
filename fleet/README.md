# AWR Fleet Warehouse

Collect AWR history from many Oracle databases into one central 19c warehouse,
analyse the whole fleet on a schedule, and notify only about the databases where
something interesting changed.

This is the implementation of [`docs/fleet-architecture.md`](../docs/fleet-architecture.md);
the domain vocabulary it uses is the glossary in [`../CONTEXT.md`](../CONTEXT.md).
It builds on the single-database report at the repo root (which stays unchanged
and serves as the drill-down).

## Status

| Layer | State |
|---|---|
| Schema (control plane, dimensions, facts, findings) | **implemented + validated on 19c** — `ddl/` |
| `AWRV_*` seam views | **implemented + validated** — `ddl/50_awrv_views.sql` |
| Collector (incremental PL/SQL pull) | **implemented + validated** — `collect/` |
| Default Metric Profile | **implemented** — `seed/profile_default.sql` |
| Admin helpers (register Target) | **implemented** — `admin/` |
| Analyzer — seasonal Detector → `AWRW_FINDINGS` + Alert State | **implemented + validated** — `analyze/awrw_analyze.*`, `awrw_score.sql` |
| Analyzer — regression Detector (top SQL / wait / segment, plan-flip flagged) | **implemented + validated on 19c** — `analyze/awrw_analyze.pkb` |
| Analyzer — headline Detector (marquee hero-six health strip) | **implemented + validated on 19c** — `analyze/awrw_analyze.pkb` |
| Notifier / Digest (firing alerts + headline movers) | **implemented + validated** — `analyze/awrw_notify.sql` |
| Orchestration — DBMS_SCHEDULER pipeline job (collect→analyze→digest) | **implemented + validated on 19c** — `schedule/awrw_schedule.sql` |
| Delivery — filesystem (Digest written to the warehouse host) | **implemented + validated on 19c** — `awrw_notify.deliver_to_files` |
| Delivery — email/Slack (mailer drains `awrw_digest`) | **next** — seam in place, site-specific |

The collect → analyze → notify pipeline runs end-to-end. It was validated on a
live Oracle 19c (CDB1) over a loopback DB link: full incremental collection of
all facts, idempotent re-runs, all three Detectors producing correct Findings
(seasonal z-score; SQL/wait/segment regressions ranked by impact with plan-flip
detection; the marquee headline strip), Alert-State edge+hysteresis across every
subject type, and a rendered HTML Digest (`examples/digest_sample.html`).
`score_period` runs all three Detectors over one Period sharing a single window
derivation — the pipelined `awrw_analyze.windows()`, the warehouse equivalent of
the report's `windows_cte.sql` — and `awrw_schedule` runs the whole cycle
(collect → analyze → digest) as one DBMS_SCHEDULER job, archiving each Digest to
`awrw_digest` and writing it to the warehouse filesystem (`deliver_to_files`).
Still to build: email/Slack delivery (a mailer drains `awrw_digest`; left unbuilt
because the SMTP relay + ACL are site-specific).

## Read-only invariant

Sources are only ever **read** — the collector is `INSERT … SELECT@link`, so the
DB-link account needs `SELECT` only. The **Warehouse is the only writer.** This
extends the project's core invariant: `awr_trend.sql` and the 15 sections remain
`SELECT`-only and untouched; every fleet writer (collector, future analyzer,
future notifier) is a separate warehouse-side script.

## Install

On the central 19c **Warehouse**, as the warehouse owner (e.g. `AWRWH`):

```sh
cd fleet
sqlplus awrwh/pw@warehouse @install_warehouse.sql
```

Re-install from scratch (dev/test — destroys collected history):

```sh
sqlplus awrwh/pw@warehouse @ddl/00_drop.sql
sqlplus awrwh/pw@warehouse @install_warehouse.sql
```

## Register a Target

A **Target** is one monitored database (CONTEXT.md). Each needs a **read-only DB
link to exactly one container** (a PDB or non-CDB — never a CDB root).

1. On the **Source**, ensure the link account has Diagnostic Pack + `SELECT` on
   AWR. Least-privilege grant (run in the monitored container):
   ```sql
   CREATE USER awr_reader IDENTIFIED BY ...;
   GRANT CREATE SESSION TO awr_reader;
   GRANT SELECT_CATALOG_ROLE TO awr_reader;   -- covers the DBA_HIST_* views
   ```
2. On the **Warehouse**, create the link to that container's service and register:
   ```sql
   CREATE DATABASE LINK prod01 CONNECT TO awr_reader IDENTIFIED BY ...
       USING '//host:1521/PROD01_SVC';
   BEGIN
       awrw_admin.add_target(p_name => 'PROD01', p_db_link => 'PROD01',
                             p_snap_interval_min => 60);
   END;
   /
   ```
   The Target's **DBID set is auto-discovered** through the link on first
   collection — including the old DBID after a non-CDB→PDB migration. A DBID
   already owned by another Target is logged as a collision, never merged.

**One-call shortcut.** `awrw_admin.add_target_dblink` collapses the link + registry
steps into a single call — it creates the read-only link, probes it
(`SELECT 1 FROM dual@link`, so a bad link/credential fails fast), then registers
the Target. Ideal for a bootstrap loop over a list of databases:

```sql
EXEC awrw_admin.add_target_dblink('PROD01', '//host:1521/PROD01_SVC', 'awr_reader', '<pw>');
-- p_password => NULL for a wallet/external-auth link.
```

The warehouse owner needs `CREATE DATABASE LINK` granted **directly** (definer-rights
PL/SQL ignores roles). See `GUIDE.html` §6 for the 50-database bootstrap loop.

## Collect

```sql
EXEC awrw_collect.collect_target('...');   -- by target_id, or:
EXEC awrw_collect.collect_all;             -- every enabled Target
EXEC awrw_collect.refresh_health;          -- recompute CURRENT/LAGGING/STALE
```

First run backfills whatever AWR each Source still retains (HWM starts at 0);
later runs pull only new Snapshots. Collection is **Snapshot-atomic per DBID**:
all facts for the new range commit together and the high-water mark advances only
on success, so a partial pull simply re-runs next cycle.

## Run the whole cycle on a schedule

`awrw_schedule` orchestrates the full fleet cycle — **collect → health → analyze
→ digest** — as one DBMS_SCHEDULER job. Each phase is isolated (one bad Source or
Target never aborts the cycle) and bookended in `awrw_run_log`. The warehouse
owner needs `CREATE JOB` (`GRANT CREATE JOB TO <owner>;`).

```sql
EXEC awrw_schedule.run_pipeline;                      -- one cycle, now (manual)
EXEC awrw_schedule.create_jobs;                       -- schedule it: hourly at :05
EXEC awrw_schedule.create_jobs('FREQ=MINUTELY;INTERVAL=30');  -- or any interval
EXEC awrw_schedule.drop_jobs;                          -- unschedule
```

Each cycle renders the Digest and archives it to `awrw_digest` (with
`delivered_ts` NULL = pending), stamping Alert State as notified. Need different
cadences for collect vs the digest? Create separate jobs over
`awrw_collect.collect_all`, `awrw_analyze.analyze_all`, and
`awrw_notify.run_digest` instead of the single pipeline.

## Deliver the Digest

Delivery is **decoupled** from rendering: the pipeline only *archives* each Digest
to `awrw_digest`. A delivery method then drains the rows where `delivered_ts IS
NULL` and stamps them. `awrw_notify.build_digest` (read-only) returns the same
HTML for an ad-hoc preview without archiving or notifying.

**Filesystem (built in).** The pipeline calls `awrw_notify.deliver_to_files` every
cycle, which writes each pending Digest to an HTML file on the **warehouse host**:

```sql
-- one-time, as a privileged user: create + grant the target directory
@@schedule/digest_dir.sql        -- edit the server path + owner first
```

After that, each cycle drops `awr_fleet_digest_<id>_<timestamp>.html` (plus a
stable `awr_fleet_digest_latest.html`) into that directory, and sets
`delivered_ts` + `file_name`. Until the directory exists, `deliver_to_files` is a
silent no-op — file delivery is strictly opt-in. Drive it by hand with
`EXEC awrw_notify.deliver_to_files;`.

**Email / Slack (seam).** Site-specific (SMTP relay + network ACL), so left to the
caller — read pending rows and send, then stamp:

```sql
SELECT digest_id, html FROM awrw_digest
 WHERE delivered_ts IS NULL ORDER BY digest_id;     -- pick up pending digests
-- ... send html as an HTML email (UTL_SMTP needs a network ACL) or hand off
--     to an external mailer ...
UPDATE awrw_digest SET delivered_ts = SYSTIMESTAMP WHERE digest_id = :id;
```

## See what's happening

```sql
-- collection freshness per Target
SELECT t.target_name, h.collect_status, h.last_snap_end_ts, h.consecutive_fail
  FROM awrw_target t JOIN awrw_target_health h ON h.target_id = t.target_id
 ORDER BY h.collect_status, t.target_name;

-- recent runs and errors
SELECT * FROM awrw_run_log   ORDER BY started_ts DESC FETCH FIRST 50 ROWS ONLY;
SELECT * FROM awrw_error_log ORDER BY err_ts     DESC FETCH FIRST 50 ROWS ONLY;

-- per-(Target,DBID) high-water marks
SELECT t.target_name, m.dbid, m.last_snap_id, m.last_snap_end_ts
  FROM awrw_hwm m JOIN awrw_target t ON t.target_id = m.target_id ORDER BY 1,2;
```

## Storage notes

- **Raw cumulative** counters are stored as-is; deltas are `SUM(end−begin)` over a
  Comparison Window at analysis time (so `windows_cte`'s restart/DBID-straddle
  guard works unchanged — no ingest delta logic). `SQLSTAT`/`SEG_STAT` store their
  native `*_DELTA`. **ASH is not collected** (no Detector needs it; recent
  drill-downs read live ASH from the Source).
- **SQL breadth:** top-N per Snapshot by elapsed (`profile.sql_top_n`, default 50).
- **Retention:** facts carry `snap_day`; in production, RANGE/INTERVAL-partition the
  fact tables on it and purge by dropping partitions. Floor: never below
  `weeks_back+1` weeks. (Base DDL ships unpartitioned so it runs on any 19c.)
- **`awrw_findings` / `awrw_alert_state` are append-style.** Findings grow with
  Periods × anomalies; Alert State carries one row per distinct Subject ever seen
  (the clear sweep bounds only the firing/streak rows, not one-time movers). At
  fleet scale, schedule a purge alongside the analyze job — e.g. delete Findings
  older than the retention floor and Alert-State rows in `NORMAL` with
  `consecutive_anom=0` whose `last_period_ts` is older than `weeks_back` weeks.
  (Shipped as a documented step, not yet a job — see the DBMS_SCHEDULER work.)

## What's not built yet

The collect → analyze → notify pipeline and its DBMS_SCHEDULER orchestration are
complete and validated. Remaining:

- **Email/Slack delivery wiring** — filesystem delivery ships and is wired into the
  pipeline; an actual UTL_SMTP (or external) mailer that drains `awrw_digest` is
  left unbuilt because the SMTP relay + network ACL are site-specific (the seam is
  in place — see *Deliver the Digest*).
- **Retention purge job** — the documented Findings / Alert-State / fact-partition
  purge as a scheduled job (see *Storage notes*).

See `docs/fleet-architecture.md` for the overall design.
