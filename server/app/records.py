"""Run records: JSON-on-disk state for every fleet/detail job, plus the
tolerant parser for run_awr_fleet.sh's stdout summary.

Every record transition is a full-file atomic write (tempfile + os.replace)
so a crash mid-write can never leave a half-written / corrupt record --
readers either see the old value or the new one, never a torn file.
"""

import json
import os
import re
import tempfile
import time
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# States
# ---------------------------------------------------------------------------
STATE_QUEUED = "queued"
STATE_RUNNING = "running"
STATE_SUCCESS = "success"
STATE_PARTIAL = "partial"
STATE_FAILED = "failed"
STATE_SKIPPED = "skipped"

TERMINAL_STATES = frozenset([STATE_SUCCESS, STATE_PARTIAL, STATE_FAILED, STATE_SKIPPED])

KIND_FLEET = "fleet"
KIND_DETAIL = "detail"

_counter = 0


def new_run_id():
    """Sortable, unique-enough run id: <millis>-<8 hex>. Not a security
    token -- just needs to not collide within one process's lifetime and to
    sort chronologically for free."""
    global _counter
    _counter += 1
    return "%d-%s" % (int(time.time() * 1000), uuid.uuid4().hex[:8])


def record_path(data_dir, run_id):
    return Path(data_dir) / "runs" / ("%s.json" % run_id)


def log_path(data_dir, run_id):
    return Path(data_dir) / "runs" / ("%s.log" % run_id)


def new_record(run_id, kind, trigger, alias=None, params=None):
    now = time.time()
    return {
        "run_id": run_id,
        "kind": kind,  # 'fleet' | 'detail'
        "trigger": trigger,  # 'schedule' | 'manual'
        "alias": alias,  # only for kind='detail'
        "state": STATE_QUEUED,
        "queued_at": now,
        "started_at": None,
        "ended_at": None,
        "duration_s": None,
        "exit_code": None,
        "params": params or {},
        "report_path": None,
        "wrapper_run_id": None,
        "workdir": None,
        "databases": [],
        "error": None,
        "warnings": [],
    }


def save_record(data_dir, record):
    """Atomic write: tmp file in the same dir, then os.replace."""
    rdir = Path(data_dir) / "runs"
    rdir.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = record_path(data_dir, record["run_id"])
    fd, tmp_name = tempfile.mkstemp(dir=str(rdir), prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_name, str(target))
    finally:
        try:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        except OSError:
            pass


def load_record(data_dir, run_id):
    p = record_path(data_dir, run_id)
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def list_records(data_dir):
    """All records, newest (by queued_at) first. Corrupt files are skipped."""
    rdir = Path(data_dir) / "runs"
    if not rdir.is_dir():
        return []
    out = []
    for p in rdir.glob("*.json"):
        try:
            with open(p, "r", encoding="utf-8") as f:
                out.append(json.load(f))
        except (OSError, json.JSONDecodeError, ValueError):
            continue
    out.sort(key=lambda r: r.get("queued_at") or 0, reverse=True)
    return out


def recover_stuck_running(data_dir):
    """Startup recovery: any record left in 'running' (server died mid-run)
    flips to 'failed'. Returns the list of run_ids that were recovered."""
    recovered = []
    for rec in list_records(data_dir):
        if rec.get("state") == STATE_RUNNING:
            rec["state"] = STATE_FAILED
            rec["error"] = "server restarted mid-run"
            rec["ended_at"] = rec.get("ended_at") or time.time()
            if rec.get("started_at"):
                rec["duration_s"] = rec["ended_at"] - rec["started_at"]
            save_record(data_dir, rec)
            recovered.append(rec["run_id"])
    return recovered


# ---------------------------------------------------------------------------
# Summary parsing -- run_awr_fleet.sh:1053-1059
#
#   %-24s ERROR  rc=%-5s detail=%-7s %s
#   %-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s detail=%s
#   Report: reports/awr_fleet_<YYYYMMDDHHMM>_run<RUN_ID>/index.html
#
# The report path is the per-run folder's index.html (current wrapper,
# v0.4.0+ folder-per-run layout); _REPORT_RE also still matches the OLD flat
# form, reports/awr_fleet_<ts>_run<id>.html, so a workdir/log predating the
# folder layout still parses -- there is no live code path that emits the
# flat form anymore, this is parser-side back-compat only.
#
# printf '%-Ns' left-pads with spaces to width N, so runs of whitespace
# between fields are variable-width -- match with \s+, never a fixed count.
# ---------------------------------------------------------------------------

_ERROR_RE = re.compile(
    r"^(?P<alias>\S+)\s+ERROR\s+rc=(?P<rc>\S+)\s+detail=(?P<detail>\S+)\s+(?P<reason>.*)$"
)
_OK_RE = re.compile(
    r"^(?P<alias>\S+)\s+OK\s+score=(?P<score>\S+)\s+crit=(?P<crit>\S+)\s+warn=(?P<warn>\S+)"
    r"\s+suppressed=(?P<suppressed>\S+)\s+topsql_n=(?P<topsql_n>\S+)\s+topsql_pts=(?P<topsql_pts>\S+)"
    r"\s+detail=(?P<detail>\S+)$"
)
_REPORT_RE = re.compile(
    r"^Report:\s+(?P<path>reports/awr_fleet_(?P<ts>\d+)_run(?P<run_id>\d+)(?:/index\.html|\.html))\s*$"
)


def parse_fleet_summary(text):
    """Tolerant line-by-line parse of run_awr_fleet.sh stdout.

    Returns a dict: {databases: [...], report_path, wrapper_run_id}.
    Unknown lines are ignored. A missing 'Report:' line leaves report_path
    and wrapper_run_id as None -- the caller (runner.py) treats that as a
    failed run regardless of exit code.
    """
    databases = []
    report_path = None
    wrapper_run_id = None

    for line in text.splitlines():
        line = line.rstrip("\n")
        m = _ERROR_RE.match(line)
        if m:
            databases.append(
                {
                    "alias": m.group("alias"),
                    "status": "ERROR",
                    "rc": m.group("rc"),
                    "detail": m.group("detail"),
                    "reason": m.group("reason"),
                }
            )
            continue
        m = _OK_RE.match(line)
        if m:
            databases.append(
                {
                    "alias": m.group("alias"),
                    "status": "OK",
                    "score": m.group("score"),
                    "crit": m.group("crit"),
                    "warn": m.group("warn"),
                    "suppressed": m.group("suppressed"),
                    "topsql_n": m.group("topsql_n"),
                    "topsql_pts": m.group("topsql_pts"),
                    "detail": m.group("detail"),
                }
            )
            continue
        m = _REPORT_RE.match(line)
        if m:
            report_path = m.group("path")
            wrapper_run_id = m.group("run_id")
            continue
        # unknown line: ignored (tolerant parsing)

    return {
        "databases": databases,
        "report_path": report_path,
        "wrapper_run_id": wrapper_run_id,
    }


def detail_report_filename(alias, wrapper_run_id, report_path=None):
    """Path (relative to reports/) to alias's detail report for a wrapper run.

    Current (v0.4.0+) folder-per-run layout: the console report and every
    requested detail report share one folder,
    reports/awr_fleet_<ts>_run<id>/, with the detail file named
    detail_<alias>.html -- port of run_awr_fleet.sh's run_one_detail `dest`
    / detail_state `dpath` naming. This function has no independent way to
    learn report_ts, so when the caller has already parsed the console
    report_path (e.g. from parse_fleet_summary()'s "Report: ..." line,
    itself in the new folder form), pass it and the detail path is derived
    from its parent folder -- the only way to construct the new path
    without re-deriving report_ts by hand.

    Falls back to the OLD flat naming,
    awr_fleet_detail_<alias>_run<wrapper_run_id>.html, when report_path is
    absent or still in the pre-folder flat form -- back-compat for older
    callers/records that never learned a (new-form) report_path.
    """
    if report_path and report_path.endswith("/index.html"):
        folder = report_path.rsplit("/", 1)[0]
        if folder.startswith("reports/"):
            folder = folder[len("reports/") :]
        return "%s/detail_%s.html" % (folder, alias)
    return "awr_fleet_detail_%s_run%s.html" % (alias, wrapper_run_id)


def fleet_workdir_name(wrapper_run_id):
    """reports/fleet_work_<wrapper_run_id>/ -- port of run_awr_fleet.sh:1131."""
    return "fleet_work_%s" % (wrapper_run_id,)
