"""Retention: prune old fleet and detail run artifacts, but ONLY what the
server has a record for. Never glob-deletes reports/awr_* -- ad-hoc CLI
reports are not the server's to touch; only paths the server itself recorded in a run's
JSON are candidates for deletion.
"""

import re
import time
from pathlib import Path

from . import paths, records

# A fleet run's per-run output folder (run_awr_fleet.sh v0.4.0+): shares
# index.html and every detail_<alias>.html for that run. Matches
# paths._RUN_FOLDER_RE -- kept as a separate constant (not imported) so this
# module's safety logic doesn't depend on paths' HTTP-serving concerns.
_RUN_FOLDER_RE = re.compile(r"^awr_fleet_\d+_run\d+$")


def _record_sort_key(rec):
    return rec.get("started_at") or rec.get("queued_at") or 0


def _recorded_artifact_paths(rec, reports_dir):
    """Every on-disk path this record claims responsibility for, already
    filtered to ones that (a) are set and (b) resolve inside reports_dir.

    A report/detail file that lives directly inside an
    "awr_fleet_<ts>_run<id>/" folder is expanded to the WHOLE folder --
    the per-run folder is the deletable unit, since index.html and every
    requested detail_<alias>.html for that run share it (and a detail
    report carries no separate "workdir"-style record field of its own to
    prune individually). An old flat report file (no such folder) and the
    extract's own fleet_work_<id> workdir are deleted as themselves,
    unchanged from before. Deduplicated so a run whose report_path and
    workdir happen to collapse to the same folder isn't double-counted.
    """
    out = []
    seen = set()
    candidates = []
    if rec.get("report_path"):
        candidates.append(rec["report_path"])
    for db in rec.get("databases") or []:
        detail = db.get("detail_report")
        if detail:
            candidates.append(detail)
    workdir = rec.get("workdir")
    if workdir:
        candidates.append(workdir)

    base = Path(reports_dir).resolve()
    for c in candidates:
        # report_path is stored as "reports/<file>" (or "reports/<run
        # folder>/<file>"); workdir as "fleet_work_<id>" (bare name,
        # relative to reports/).
        c_str = str(c)
        if c_str.startswith("reports/"):
            c_str = c_str[len("reports/") :]
        p = (Path(reports_dir) / c_str)
        try:
            resolved = p.resolve()
            resolved.relative_to(base)
        except (ValueError, OSError):
            continue
        if resolved == base:
            # "reports/", "reports/." or a workdir of "." resolve to the
            # reports directory itself -- never a deletable artifact.
            continue
        parent = resolved.parent
        if (
            resolved.is_file()
            and parent != base
            and _RUN_FOLDER_RE.fullmatch(parent.name)
        ):
            try:
                parent.resolve().relative_to(base)
            except (ValueError, OSError):
                pass
            else:
                resolved = parent
        if resolved in seen:
            continue
        seen.add(resolved)
        out.append(resolved)
    return out


def _delete_path(p):
    try:
        if p.is_dir():
            import shutil

            shutil.rmtree(p, ignore_errors=True)
        elif p.exists():
            p.unlink()
    except OSError:
        pass


def _latest_detail_ids(all_records):
    """run_ids of the newest successful detail record per alias -- the report
    the home page links for that database, so it is never pruned."""
    best = {}
    for r in all_records:
        if (
            r.get("kind") == records.KIND_DETAIL
            and r.get("state") == records.STATE_SUCCESS
            and r.get("report_path")
        ):
            cur = best.get(r.get("alias"))
            if cur is None or _record_sort_key(r) > _record_sort_key(cur):
                best[r.get("alias")] = r
    return set(r["run_id"] for r in best.values())


def _prune_artifacts(data_dir, rec, reports_dir):
    """Delete rec's recorded artifacts and mark it. Returns how many paths
    were deleted (0 when already pruned)."""
    if rec.get("artifacts_pruned"):
        return 0
    n = 0
    for p in _recorded_artifact_paths(rec, reports_dir):
        _delete_path(p)
        n += 1
    rec["artifacts_pruned"] = True
    records.save_record(data_dir, rec)
    return n


def prune_runs(data_dir, reports_dir=None, keep_fleet_runs=14, keep_days=30, keep_run_records=200, now=None):
    """Prune terminal run artifacts + thin old records/logs.

    Three passes:
      1. Among terminal-state 'fleet' records, keep the newest
         `keep_fleet_runs` OR anything younger than `keep_days`; for the
         rest, delete their recorded report/detail-report/workdir paths
         (marking the record `artifacts_pruned=True`, record itself kept).
      2. Among terminal-state 'detail' records, keep the newest successful
         one per alias (the report the home page links) and anything
         younger than `keep_days`; delete the artifacts of the rest.
      3. Across ALL terminal records (any kind), keep only the newest
         `keep_run_records`; anything older loses its artifacts (if not
         pruned yet), its .json record and its .log file. Queued/running
         records and the newest successful detail per alias are never
         dropped.

    Returns a summary dict for tests/observability.
    """
    now = now if now is not None else time.time()
    reports_dir = Path(reports_dir) if reports_dir else paths.REPORTS_DIR
    data_dir = Path(data_dir)

    all_records = records.list_records(data_dir)  # newest first already
    cutoff = now - keep_days * 86400
    latest_detail = _latest_detail_ids(all_records)

    # ---- pass 1: fleet artifact pruning --------------------------------
    fleet_terminal = [
        r
        for r in all_records
        if r.get("kind") == records.KIND_FLEET and r.get("state") in records.TERMINAL_STATES
    ]
    fleet_terminal.sort(key=_record_sort_key, reverse=True)

    keep_ids = set()
    for r in fleet_terminal[:keep_fleet_runs]:
        keep_ids.add(r["run_id"])
    for r in fleet_terminal:
        if _record_sort_key(r) >= cutoff:
            keep_ids.add(r["run_id"])

    pruned_artifacts = 0
    for r in fleet_terminal:
        if r["run_id"] in keep_ids:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)

    # ---- pass 2: detail artifact pruning -------------------------------
    for r in all_records:
        if r.get("kind") != records.KIND_DETAIL or r.get("state") not in records.TERMINAL_STATES:
            continue
        if r["run_id"] in latest_detail or _record_sort_key(r) >= cutoff:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)

    # ---- pass 3: thin records/logs beyond keep_run_records -------------
    all_records_sorted = sorted(all_records, key=_record_sort_key, reverse=True)
    thinned = 0
    for r in all_records_sorted[keep_run_records:]:
        if r.get("state") not in records.TERMINAL_STATES:
            continue
        if r["run_id"] in latest_detail:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)
        rp = records.record_path(data_dir, r["run_id"])
        lp = records.log_path(data_dir, r["run_id"])
        for p in (rp, lp):
            try:
                if p.exists():
                    p.unlink()
                    thinned += 1
            except OSError:
                pass

    return {
        "fleet_terminal_considered": len(fleet_terminal),
        "fleet_kept": len(keep_ids),
        "artifacts_pruned": pruned_artifacts,
        "records_thinned": thinned,
    }
