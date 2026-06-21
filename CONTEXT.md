# AWR Fleet Warehouse

The domain of collecting AWR performance history from many Oracle databases into
one central store, analysing it across the whole fleet, and surfacing only the
databases where something has changed. (Glossary for the design in
[docs/fleet-architecture.md](docs/fleet-architecture.md). The single-database
report it builds on is described in the root `CLAUDE.md`.)

## Language

**Target**:
A monitored database — the unit of identity, tracked continuously over its whole
life by a stable, registry-assigned key, independent of physical incarnation. A
Target owns one or more DBIDs. All history, findings, and notifications hang off
the Target, never off a DBID or name.
_Avoid_: database (ambiguous), instance, host, node.

**DBID**:
The physical AWR identity of one database incarnation. A Target acquires a new
DBID on migration (non-CDB→PDB) or clone-with-NID, so a Target may own several
over time. Used only as an internal storage key — never as the unit of identity
or notification.
_Avoid_: db_id, database id (when you mean the logical Target).

**DBID set**:
The collection of DBIDs a Target owns. Every fact query filters on membership in
this set (`dbid IN (…)`), so a Target's history stays continuous across a DBID
change.
_Avoid_: dbid_list (that name is the single-DB tool's substitution variable, not
the fleet concept).

**Source**:
The live database behind a Target that the warehouse reads from. Read-only,
always — the warehouse never writes to a Source.
_Avoid_: production DB, monitored instance.

**Warehouse**:
The single central Oracle database that stores every Target's collected history
and is the only thing the system writes to.
_Avoid_: repository (collides with Oracle's "AWR repository"), central DB.

**Connection**:
The single read-only link from the Warehouse to a Target's Source, whose service
resolves to exactly one container (a PDB or non-CDB) — never a CDB root — and
follows the live primary across RAC and Data Guard. A Target's DBID set is
auto-discovered through its Connection.
_Avoid_: DB link (that's the Oracle mechanism, not the per-Target concept),
datasource.

**Snapshot**:
One AWR snapshot — the atomic unit of collection, identified by
(DBID, snap_id) with one row per instance. A Snapshot present in the Warehouse
is always *complete*: every fact table for it is loaded, or none is.
_Avoid_: snap, sample (a sample is the finer ASH grain).

**High-water mark**:
The highest fully-collected `snap_id` for one (Target, DBID) — the boundary the
collector resumes from. One per DBID sequence, never per view or per instance.
_Avoid_: checkpoint, offset, watermark (spelling).

**Comparison Window**:
A contiguous time span of `win_hours` ending at a chosen instant, resolved to a
begin/end Snapshot pair. *Valid* only if both snaps exist, differ, share one
DBID, and span no restart; an invalid Window contributes nothing. Facts are
read raw and the delta is `SUM(end − begin)` over the Window.
_Avoid_: interval (collides with AWR's snapshot interval), period (a Period is
the analysis output unit, not the input span).

**Period**:
One scored Comparison Window for one Target, identified by
(target_id, window_end_ts). The unit a Finding is about and a notification
refers to. Each Period is scored exactly once, tracked by a per-Target analysis
high-water mark; a Period whose seasonal baseline isn't fully present yet is
deferred, not failed.
_Avoid_: run, cycle, scoring pass (those name the scheduled job, not the unit).

**Baseline**:
The set of *valid* prior Comparison Windows at the same phase as the Period being
scored — by default the same hour-of-week for the previous `weeks_back` weeks.
A metric's z-score and %-delta are measured against the mean/stddev of its
Baseline values; fewer than 3 valid Baseline windows = no signal.
_Avoid_: history, reference window, normal.

**Score**:
The result of scoring one metric for one Period — its current value, z-score,
%-delta, and severity bucket against the Baseline. Computed for every profile
metric each Period; transient (recomputed from raw facts on demand, not stored
for OK metrics).
_Avoid_: result, measurement, reading.

**Finding**:
A notable observation about one Subject on one Target at one Period — a seasonal
anomaly (severity ≥ WARN, surviving the gates) or a ranked regression. Persisted
append-only; carries `subject_type` + `subject_id` so all Detectors share one
record, one Alert State, and one Digest.
_Avoid_: alert (an Alert is the lifecycle), anomaly, event.

**Detector**:
A rule that produces Findings from the stored facts. Three to start: seasonal
metric anomaly (z-score over the Metric Profile), top regression (SQL/wait/
segment ranked by impact), and headline metrics. All feed the same Finding
pipeline.
_Avoid_: rule, check, analyzer (the analyzer is the job that runs the Detectors).

**Subject**:
The thing a Finding is about, named by `subject_type` (`metric` | `sql` | `wait`
| `segment`) + `subject_id`. Lets one anomaly and one SQL regression coexist in
one Finding stream and one Alert.
_Avoid_: target (that's the database), object, entity.

**Target Health**:
A Target's collection and analysis freshness — Current / Lagging / Stale /
Unreachable — kept separate from Findings. Every Digest carries a coverage
section listing non-Current Targets and Targets with no valid windows (and why),
so a Target's absence from the highlights means "Current, scored, quiet" and
nothing else.
_Avoid_: status, uptime, availability.

**Alert**:
The lifecycle of one condition firing then clearing on a (Target, metric) across
consecutive Periods — what is actually notified, after edge-detection and
hysteresis collapse a run of Findings into one fire and one clear.
_Avoid_: notification (the delivered message), finding.

**Alert State**:
The per-(Target, metric) record driving Alerts: current firing/normal state,
consecutive-anomalous and consecutive-normal counts, and last-transition Period.
Updated every Period — including normal ones, which is how a condition clears.
_Avoid_: status, alert history.

**Metric Profile**:
The named, per-metric configuration the analyzer scores against — for each
metric: domain, `is_additive` (RAC roll-up), absolute floor, percent floor, and
optional polarity. The single surface for tuning fleet noise; a Target runs one
profile. Supersedes the single-DB tool's flat template metric lists.
_Avoid_: template (that's the report's term), metric list, watchlist.

**Digest**:
The periodic fleet message (default daily) listing only Targets with a new,
ongoing, or recovered Alert in the window, grouped by Target with their top
Findings, a health line, and drill-down links. The primary delivery surface.
_Avoid_: report (that's the single-DB HTML), email, summary.

**Notification**:
A single delivered message conveying one or more Alerts — usually a Digest,
optionally an immediate per-condition message for CRITICALs. The act of
delivery, distinct from the Alert it carries.
_Avoid_: alert, page.
