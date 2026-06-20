# Fleet AWR: design proposal

How to scale the single-DB AWR comparison report into a **fleet system** that
collects continuously from many databases, stores everything centrally in
Oracle, analyzes the whole dataset on a schedule, and notifies only about the
databases where something interesting is happening.

This is a proposal, not yet an implementation. It was produced by a multi-agent
design pass (read every metric section + the z-score logic + the run surface;
surveyed Oracle AWR Warehouse, Statspack consolidation, robust anomaly
detection) and then **refined against the actual fleet constraints** below.

## Fleet constraints (these drove the design)

- **Dozens of databases, all Oracle 19c, one exact same version, on AIX,
  uniform licensing, spread across many servers.** → No version skew. No
  Standard Edition members. One fixed column set.
- **DB links allowed: a central warehouse may pull from each source.** → Pure
  `SELECT`-only pull; no agent/shell on the AIX sources.
- **"Interesting" = seasonal anomalies (z-score) + top regressions + a curated
  metric set.** (Not absolute SLA thresholds — can add later.)
- **Goal: the stored data becomes a queryable dataset that grows over time.**

---

## TL;DR

**Single-phase, purpose-built thin-extract warehouse, pulled by pure PL/SQL over
DB links.** The homogeneous 19c fleet removes the one thing that previously
justified a staged "native-AWR-first" approach (per-source version mapping), so
there is no reason to build a throwaway native-consolidation phase.

- **Collect:** one central 19c warehouse DB runs `DBMS_SCHEDULER` jobs that do
  `INSERT … SELECT … FROM dba_hist_*@source WHERE snap_id > :hwm` per source,
  incremental by a per-`(source,dbid)` high-water mark, `MERGE`-idempotent. The
  source side is **read-only** (a `SELECT`-only link account) — same privilege
  posture as running the tool live, works against a physical standby. No shell on
  AIX, no Data Pump dumps, no file transfer, no staging schema.
- **Store:** a clean `FACT_*`/`DIM_*` schema (the queryable dataset you asked
  for), keyed `(dbid, instance_number, snap_id)` with a `db_key` spanning a
  migrated DB's old+new DBIDs, partitioned by time + dbid.
- **Analyze:** a headless, scheduled producer writes `AWRW_FINDINGS` using **three
  detectors** — (1) seasonal **z-score** over a **curated metric profile**
  (reuses section 07's logic), (2) a fleet **top-regression** leaderboard for
  SQL / waits / I/O, (3) the curated **headline metrics**.
- **Notify:** a noise-gated digest (edge + hysteresis, idle-DB floor) emails only
  the DBs with a surviving finding, each linking to a drill-down.
- **Drill-down:** the **existing `awr_trend.sql` report, unchanged** — run *live
  against the source* for current windows, or against the warehouse for older
  ones.

**Read-only invariant preserved exactly:** sources are only read. Every writer
(collector, findings producer, notifier) lives on the central warehouse as a
separate side-script, modeled on `side/create_weekly_baselines.sql`.
`awr_trend.sql` and all 15 sections stay `SELECT`-only and untouched.

### Why not native AWR consolidation (`awrextr`/`awrload`)?

It was the front-runner *only* under version-skew uncertainty. Given a uniform
19c fleet it loses on every axis that now matters: it stores into SYS-owned
`WRH$` (a poor queryable substrate — you want clean tables), it still suffers
SYSAUX bloat in one tablespace, manual `awrload` silently collides on cloned
DBIDs, and range-based extract couples your loop to each source's AWR retention.
Its one advantage (zero column mapping) is irrelevant when there's nothing to
map. **Keep it in your back pocket for one thing only:** a possible one-time
*history seed* — but even that is unnecessary here, because the first
incremental pull with `HWM = 0` already backfills whatever AWR each source still
retains.

---

## The key insight (still the foundation)

The toolkit was, almost by accident, built fleet-ready:

- **Every AWR filter already uses `dbid IN (~dbid_list)`**, not `dbid = ~dbid`.
- `sql/lib/windows_cte.sql` resolves snapshot windows **by time across the DBID
  list** and carries each snap's own `dbid` forward.
- The whole philosophy is **"store nothing derived; recompute from raw each run."**

A central store of N databases is therefore just **N distinct `dbid_list`s over
the same SQL.** Co-resident DBIDs never alias because every key is already
`(dbid, instance_number, snap_id)` (snap_id resets per DBID). The same-hour-of-
week comparison (`week_offset`) *is* the optimal seasonality baseline for
anomaly detection. Most of the analysis work already exists.

---

## Architecture

```
   SOURCE DBs (19c, AIX, read-only)        CENTRAL WAREHOUSE (19c Oracle)        OUT
 ┌────────────────────────┐
 │ DB #1  DBA_HIST_*       │◀─ SELECT@dblink ─┐   ┌──────────────────────────┐
 │ (SELECT-only link acct) │   INSERT…SELECT  ├──▶│ STORAGE: FACT_*/DIM_*     │
 └────────────────────────┘   incremental by  │   │ clean, queryable, by-time │
 ┌────────────────────────┐   per-(src,dbid)  │   │ + by-dbid partitioned     │
 │ DB #2 ...              │◀─ high-water mark ─┤   └────────────┬─────────────┘
 └────────────────────────┘                   │                │ AWRV_* views
        ... dozens ...                         │   ┌────────────▼─────────────┐
 ┌────────────────────────┐                    │   │ ANALYSIS (scheduled)      │
 │ DB #N ...              │◀─ SELECT@dblink ───┘   │ 1 z-score (curated profile)│
 └────────────────────────┘                       │ 2 top-regression leaderbd  │
                                                   │ 3 curated headline metrics │
   CONTROL PLANE (all PL/SQL, warehouse-resident)  │ → AWRW_FINDINGS table      │
   AWRW_TARGET registry · AWRW_HWM ·               └────────────┬─────────────┘
   AWRW_RUN_LOG / ERROR_LOG · concurrency cap       ┌───────────▼─────────────┐   ┌─────────┐
   · "what's happening" dashboard                   │ NOTIFY (noise-gated)    │──▶│ email / │
                                                    │ edge + hysteresis digest│   │ Slack   │
                                                    └───────────┬─────────────┘   └─────────┘
                                          ┌─────────────────────▼──────────────────────┐
                                          │ DRILL-DOWN: the EXISTING awr_trend.sql,     │
                                          │ unchanged — run LIVE against the source for │
                                          │ current windows, or vs the warehouse for old│
                                          └─────────────────────────────────────────────┘
```

### 1. Collection — pure PL/SQL pull (source stays read-only)

A `DBMS_SCHEDULER` job per source, on a cadence ≥ the source's snapshot interval:

1. Read the **high-water mark** = `MAX(snap_id)` already loaded for that DBID in
   the warehouse (per instance for RAC).
2. For each `DBA_HIST_*` view, `INSERT /*+ APPEND */ … SELECT … @source_link
   WHERE snap_id > :hwm` (or `MERGE` for idempotency). The source issues only
   `SELECT` — a read-only analyst account, identical to running the tool live.
3. **Push aggregation across the link, not raw rows.** ASH especially: do the
   bucketing in the *remote* `SELECT` (`GROUP BY` over
   `dba_hist_active_sess_history@src`) so only bucketed counts cross the network,
   not 1-in-10 raw samples. SQLSTAT can be stored in full (rich, queryable) or
   top-N per window (lean) — your call.
4. Advance the HWM only on a committed load → a mid-run failure simply re-pulls
   the same range next cycle (idempotent), no duplicates, no gaps.

First run with `HWM = 0` backfills whatever AWR each source still retains — free
history seed, no `awrload` needed.

> **One parameter to confirm:** the multi-week comparison needs ≥ `weeks_back`
> weeks of history. If sources keep the 8-day AWR default, the *live* tool can't
> see 4 weeks back today — which is precisely why the warehouse matters: set the
> **warehouse** retention long (e.g. 90 days – 1 year) and the comparison works
> fleet-wide regardless of each source's short retention.

### 2. Storage — the queryable dataset

Purpose-built schema, all facts keyed `(dbid, instance_number, snap_id)` with a
`db_key` that spans a migrated DB's old+new DBIDs, partitioned `BY RANGE`
(time) + by dbid for pruned fleet scans and cheap retention drop.

- `DIM_DATABASE(db_key, db_name, host_name, db_version, edition)` — identity is
  captured at extract (the warehouse has no live `v$database`/`v$instance` for a
  source).
- `DIM_SNAPSHOT(dbid, instance_number, snap_id, begin/end_interval_time,
  startup_time)` — the central time/restart dimension; reproduces `windows_cte`
  validity (restart via `startup_time`, DBID-straddle) generically.
- `DIM_METRIC(metric_name, is_additive)` — **load-bearing:** SYSMETRIC RAC
  roll-up is `SUM` for additive rates/counters, `AVG` for ratios/latencies.
- Facts: `FACT_SYSSTAT` (raw cumulative `value`), `FACT_SYSMETRIC` (`average`),
  `FACT_WAIT_EVENT` (raw cumulative `total_waits` + `time_waited_micro`, fg/bg
  flag), `FACT_SQLSTAT` (stored `*_delta`), `FACT_ASH_BUCKET` (pre-bucketed
  `sample_count` by `wait_class`/`event`/`sql_id`), `FACT_SEG_STAT` (stored
  delta), `FACT_FILE_IO` + `FACT_IOSTAT_FILETYPE` (raw cumulative, kept distinct
  — file-type is **not** a roll-up of per-file).
- `METRIC_PROFILE(profile_name, domain, metric_name)` — the per-template curated
  lists become **metadata** (this is also where your "curated metric set" lives).

**Storage decisions encoded from the toolkit (don't get these wrong):**
- `snap_id` is **not** globally unique — any key on `snap_id` alone is a bug.
- Cumulative counters (`SYSSTAT`, `SYSTEM_EVENT`, `BG_EVENT_SUMMARY`,
  `FILESTATXS`/`TEMPSTATXS`, `IOSTAT_FILETYPE`) have **no `*_DELTA` columns**.
  Delta = end − begin, computed **per instance** and **guarded by `startup_time`**
  (a restart resets the counter; treat `begin > end` as a reset → NULL, never a
  negative). Only `SQLSTAT` and `SEG_STAT` expose `*_DELTA`. *(This is the one
  genuinely new correctness surface vs. the live tool: `windows_cte`'s
  window-pair invalidation must become a streaming `LAG`-by-instance guard.)*
- `DBA_HIST_SQLTEXT` / `DBA_HIST_SEG_STAT_OBJ` are PDB join views: dedup with
  `ROW_NUMBER() OVER (PARTITION BY key ORDER BY NULL)` — a naive `SEG_STAT_OBJ`
  join **doubles** segment I/O. Trend by *logical* name (`owner.object`,
  `filename`); `obj#`/`file#` are reused on rebuild.
- ASH `AAS = samples / (bucket_seconds / 10)`. Keep `event`+`sql_id` cardinality
  in the bucket or section 11 (per-SQL ASH) loses resolution.

### 3. Analysis — three detectors → `AWRW_FINDINGS`

A **new, separate writer script** (modeled on `side/create_weekly_baselines.sql`,
never folded into `awr_trend.sql`) loops every registered DBID on a schedule,
reading through the `AWRV_*` seam, and writes
`AWRW_FINDINGS(dbid, db_key, db_name, detector, metric_domain, metric_name,
period_end_ts, cur_val, prior_mean, prior_sd, n_prior, z_score, pct_delta,
impact, severity)`.

1. **Seasonal z-score (curated metric profile).** Lift section 07's `scored` CTE
   (the `load_rows`/`metric_rows`/`wait_rows` → `pivoted` → `scored` chain). Mean
   /stddev over the **prior** windows (`week_offset > 0`); current value scored
   against them; `|z|>3` CRITICAL, `|z|>2` WARN, `n<3` INSUFFICIENT_HISTORY,
   `sd∈{NULL,0}` FLAT_BASELINE. **Run it over a curated `METRIC_PROFILE`, not the
   full comprehensive list** — this directly implements your "curated metric set"
   choice and keeps anomaly noise low.
2. **Top-regression leaderboard.** Per `(dbid, sql_id)`: current-window total
   `elapsed_time_delta` (≈ DB time) vs the mean of prior windows → rank by
   *absolute* increase; same for wait classes and segment/file I/O. This is the
   "what got worse this week, ranked by impact" view, independent of the
   statistical model — it catches a SQL/plan regression a metric-anomaly model
   would miss. Reuses `FACT_SQLSTAT` / `FACT_WAIT_EVENT` / `FACT_SEG_STAT`.
3. **Curated headline metrics.** The section 08 "hero six" (DB time, redo size,
   session logical reads, AAS, DB Wait Time Ratio, hard parse count) as a compact
   per-DB health rollup for the digest header.

> **Small refactor to budget:** the z-score formula is currently duplicated
> **four** ways — `sql/lib/score_cells.plsql` (returns HTML `<td>`, used by
> 04/05), inline SQL in `07`, inline PL/SQL in `08`. The headless producer needs
> a **numeric** score, so factor a single numeric `score()` function that all
> four call. *(The `CLAUDE.md` note that 07/08 are the only copies is stale —
> there are four.)*

**Pointing the analysis SQL at the warehouse** needs only an identity shim:
`DEFINE` `dbid`/`dbid_list`/`db_name`/`host_name`/`db_version` from the registry
(the prologue's auto-resolution would otherwise collapse the whole fleet into one
bogus `dbid_list`), and **always pin `target_end`** (never `AUTO` — that reads
the warehouse clock). The `AWRV_*` views supply the `DBA_HIST_*` shape the
sections expect.

### 4. Notification — only interesting *changes*

- **Per-DB "interesting?"** reuse 07's `v_crit`/`v_warn` counters: a DB qualifies
  only with ≥1 finding **surviving the noise gates**.
- **Noise gates (in from day one — weekly cadence means `n_prior ≈ 3–4`, so plain
  mean+stddev *will* storm):** INSUFFICIENT_HISTORY/FLAT_BASELINE = no-signal
  (route "no valid windows / why" to a health channel, not alerts); **idle-DB
  floor** (`mu ≈ 0` yields huge z *and* pct on a trivial change — require an
  absolute min-`mu`); require `z` **and** a pct/absolute co-threshold; cap top-K
  per DB.
- **Flap suppression**, pure SQL over `AWRW_FINDINGS` history: emit on a
  `FALSE→TRUE` edge via `LAG(is_anomaly) OVER (PARTITION BY db_key, metric ORDER
  BY period_end_ts)` in `AWRW_ALERT_STATE`; require 2–3 consecutive anomalous
  periods to fire, 3 normal to clear. Don't re-page a still-firing condition.
- **Delivery:** one fleet digest grouped by DB; each interesting DB links to a
  drill-down. *(Robust MAD z-score — `0.6745·(x−median)/MAD`, `|z|>3.5` — is a
  drop-in upgrade once the warehouse retention supplies ~10 baseline samples per
  cell; defer it, the curated profile keeps Phase-1 noise manageable without it.)*

### 5. Drill-down — the existing report, unchanged

Because every source is reachable by link, the richest reuse is to run the
**existing `awr_trend.sql` live against the source** for the flagged (current)
window — zero changes, full fidelity. For windows older than the source's AWR
retention, run the *same* report against the warehouse via the identity shim +
`AWRV_*`. `report_path` is deterministic, so the digest links straight to the
artifact.

### 6. Orchestration / "see what's happening" — all PL/SQL

- Three decoupled `DBMS_SCHEDULER` cadences: **collect** (frequent) → **analyze**
  (hourly/daily) → **notify** (after analyze). Per-target jobs independent, with a
  concurrency cap so dozens of links don't stampede the warehouse, and per-phase
  retries with backoff.
- **Control-plane tables:** `AWRW_TARGET` (registry: link, profile, schedule,
  enabled), `AWRW_HWM` (per `target`/`dbid`/`view` high-water mark),
  `AWRW_RUN_LOG` + `AWRW_ERROR_LOG`.
- **Status dashboard** (your "control"): which targets are current vs. stale,
  last error per target, lag per view, fleet coverage, and which DBs have **no
  valid windows and why** (surface `windows_cte`'s `skip_reason`) — so silence
  reads as "no signal / restart / migration," never a hidden failure.
- Python is **optional**, only if you want a nicer dashboard or a non-SMTP
  notification channel. The core needs none.

---

## What's reused vs. built new

**Reused, largely unchanged:** `windows_cte.sql` (window validity); the section
07 `scored` recompute (lifted into the producer); the entire `awr_trend.sql`
report (the drill-down — live against the source); per-template curated lists +
`is_additive` → `METRIC_PROFILE`; the `create_weekly_baselines.sql` separate-
writer discipline.

**Built new:** the `FACT_*`/`DIM_*` schema + control-plane tables; the PL/SQL
incremental pull collector (with the streaming delta/restart guard + remote ASH
bucketing + PDB-join dedup); a numeric `score()` (de-duplicating the four copies);
the top-regression detector; the `AWRW_FINDINGS` producer; the noise-gated
edge/hysteresis notifier; the `AWRV_*` seam + identity shim; the dashboard.

---

## Suggested build order (increments, not a substrate migration)

| Step | What | ~Effort |
|---|---|---|
| **0** | Provision the 19c warehouse; create `SELECT`-only link accounts + links; set long warehouse retention; confirm source AWR retention | days |
| **1** | `FACT_*`/`DIM_*` + control-plane DDL; PL/SQL pull collector for 1 source (HWM, idempotent MERGE, streaming delta/restart guard, remote ASH bucketing, PDB dedup); prove with the **byte-identity test** vs the live tool on that source | ~1.5–2 wk |
| **2** | Scale collector to the fleet (`DBMS_SCHEDULER` fan-out, concurrency cap, retries, run/error log) + status dashboard | ~1 wk |
| **3** | `AWRV_*` seam + identity shim; headless `AWRW_FINDINGS` producer = numeric `score()` + lifted 07 logic over a curated `METRIC_PROFILE` + top-regression queries | ~1 wk |
| **4** | Noise-gated, edge/hysteresis notifier + digest; drill-down = live report against the source (warehouse fallback) | ~0.5–1 wk |
| **5** *(later)* | MAD robust z-score once retention is deep; absolute-threshold detector if you later want SLAs; single-source the score thresholds | as needed |

---

## Top risks (and mitigation)

- **False positives / alert fatigue** — weekly `n_prior ≈ 3–4`; idle DBs throw
  false "large." → noise gates from day one (Step 4); curated profile limits
  surface area; MAD later.
- **Streaming delta/restart guard** — `windows_cte`'s window-pair invalidation
  does not transfer to continuous ingest. → delta per instance via `LAG`, guarded
  by `startup_time` / non-monotonic reset; never aggregate raw cumulative across
  instances before delta'ing. (The single subtlest new correctness surface.)
- **Identity collapse against the warehouse** — auto-resolution picks the
  globally-freshest DBID and `LISTAGG`s *every* DBID. → mandatory per-source
  identity shim + pinned `target_end`; the seam absorbs every live-`v$` read.
- **DB-link credential sprawl** — dozens of links/accounts to manage. → a single
  fixed `SELECT`-only schema per source, provisioned by one script; centralize
  wallet/credentials.
- **Source AWR retention < `weeks_back`** — short-retention sources can't drive a
  4-week comparison live. → the warehouse's long retention is the fix; live
  drill-down only for windows still on the source.
- **Operability** — the no-install ethos is gone; the warehouse is a stateful
  asset (backup, capacity, partitions). → keep all writers as separate side-
  scripts so the read-only driver + 15 sections stay `SELECT`-only and the report
  stays the unchanged drill-down.

---

## Resolved decisions (from fleet refinement)

- **Substrate:** single-phase thin-extract `FACT_*`/`DIM_*` (no native phase, no
  migration) — homogeneous 19c makes thin-extract cheap and the queryable goal
  rules out SYS `WRH$`.
- **Transport:** central pull via `SELECT`-only DB links; pure PL/SQL collector,
  no shell on AIX sources.
- **Detectors:** seasonal z-score over a curated metric profile + fleet top-
  regression leaderboard + curated headline metrics. (Absolute SLA thresholds
  deferred.)
- **Orchestration:** all-Oracle `DBMS_SCHEDULER`; Python optional for dashboard/
  notifications only.

### Still open / to confirm
- Exact `weeks_back` / cadence and the **warehouse retention** target.
- The **curated `METRIC_PROFILE`** contents (start from the section 08 hero six?).
- Whether to store **full** `FACT_SQLSTAT` (richer queryable history) or **top-N
  per window** (leaner).
- Notification channel (SMTP from the warehouse vs. external mailer/Slack).
