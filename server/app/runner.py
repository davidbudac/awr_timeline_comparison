"""Job queue + worker thread: the one place that shells out to
run_awr_fleet.sh.

Serialization model (see CLAUDE.md-adjacent plan doc): a single
queue.Queue consumed by exactly one worker thread, so at most one wrapper
subprocess ever runs at a time. A manual duplicate enqueue (fleet, or a
detail regen for an alias already queued/running) is refused with a
Conflict; a *scheduled* duplicate is recorded as a visible 'skipped' run
instead of raising, so schedule-triggered callers never need to handle an
exception.
"""

import os
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from . import fleetconf, paths, records

WRAPPER_ENV_VAR = "AWRSERVE_WRAPPER"
DEFAULT_WRAPPER = "run_awr_fleet.sh"


class ConflictError(Exception):
    """A manual run was requested while an equivalent job is already
    queued or running."""


class NotFoundError(Exception):
    """Requested alias/run does not exist."""


def _tail_error(exit_code, log_text, n=20):
    lines = [l for l in log_text.splitlines() if l.strip()]
    tail = lines[-n:]
    prefix = "wrapper exited %s without a usable 'Report:' line" % (
        exit_code if exit_code is not None else "?"
    )
    if tail:
        return prefix + "\n" + "\n".join(tail)
    return prefix


class RunManager:
    def __init__(self, config, data_dir=None, cwd=None, wrapper_path=None, popen=subprocess.Popen):
        self.config = config
        self.data_dir = Path(data_dir) if data_dir else paths.DATA_DIR
        self.cwd = str(Path(cwd)) if cwd else str(paths.REPO_ROOT)
        self.reports_dir = Path(self.cwd) / "reports"
        self.wrapper_path = wrapper_path or os.environ.get(WRAPPER_ENV_VAR, DEFAULT_WRAPPER)
        self._popen = popen
        self._queue = queue.Queue()
        self._lock = threading.RLock()
        self._current_job = None
        self._queued_jobs = []
        self._worker_thread = None
        self._stop = threading.Event()

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------
    def start(self):
        paths.ensure_data_dirs(self.data_dir)
        self.reports_dir.mkdir(parents=True, exist_ok=True)
        recovered = records.recover_stuck_running(self.data_dir)
        self._worker_thread = threading.Thread(
            target=self._worker_loop, name="awrserve-worker", daemon=True
        )
        self._worker_thread.start()
        return recovered

    def stop(self, timeout=5):
        self._stop.set()
        self._queue.put(None)
        if self._worker_thread:
            self._worker_thread.join(timeout=timeout)

    # ------------------------------------------------------------------
    # enqueue
    # ------------------------------------------------------------------
    def _fleet_params_dict(self):
        p = self.config.fleet
        return {
            "target_end": p.target_end,
            "win_hours": p.win_hours,
            "weeks_back": p.weeks_back,
            "top_n": p.top_n,
            "step": p.step,
            "step_unit": p.step_unit,
        }

    def _has_pending_fleet_locked(self):
        if self._current_job and self._current_job["kind"] == records.KIND_FLEET:
            return True
        return any(j["kind"] == records.KIND_FLEET for j in self._queued_jobs)

    def _has_pending_detail_locked(self, alias):
        if (
            self._current_job
            and self._current_job["kind"] == records.KIND_DETAIL
            and self._current_job.get("alias") == alias
        ):
            return True
        return any(
            j["kind"] == records.KIND_DETAIL and j.get("alias") == alias
            for j in self._queued_jobs
        )

    def enqueue_fleet(self, trigger):
        with self._lock:
            if self._has_pending_fleet_locked():
                if trigger == "manual":
                    raise ConflictError("a fleet run is already queued or running")
                rec = records.new_record(
                    records.new_run_id(), records.KIND_FLEET, trigger, params=self._fleet_params_dict()
                )
                rec["state"] = records.STATE_SKIPPED
                rec["error"] = "skipped: a fleet run was already queued or running"
                rec["ended_at"] = rec["queued_at"]
                records.save_record(self.data_dir, rec)
                return rec

            run_id = records.new_run_id()
            rec = records.new_record(
                run_id, records.KIND_FLEET, trigger, params=self._fleet_params_dict()
            )
            records.save_record(self.data_dir, rec)
            job = {"kind": records.KIND_FLEET, "trigger": trigger, "run_id": run_id, "alias": None}
            self._queued_jobs.append(job)
            self._queue.put(job)
            return rec

    def enqueue_detail(self, alias, trigger):
        try:
            entries = fleetconf.parse_fleet_conf(self.config.fleet.conf_path)
        except fleetconf.FleetConfError as exc:
            raise NotFoundError("cannot read fleet.conf: %s" % exc)
        if alias not in entries:
            raise NotFoundError("unknown alias: %s" % alias)

        with self._lock:
            if self._has_pending_detail_locked(alias):
                if trigger == "manual":
                    raise ConflictError(
                        "a detail run for '%s' is already queued or running" % alias
                    )
                rec = records.new_record(
                    records.new_run_id(),
                    records.KIND_DETAIL,
                    trigger,
                    alias=alias,
                    params=self._fleet_params_dict(),
                )
                rec["state"] = records.STATE_SKIPPED
                rec["error"] = "skipped: a detail run for '%s' was already queued or running" % alias
                rec["ended_at"] = rec["queued_at"]
                records.save_record(self.data_dir, rec)
                return rec

            run_id = records.new_run_id()
            rec = records.new_record(
                run_id, records.KIND_DETAIL, trigger, alias=alias, params=self._fleet_params_dict()
            )
            records.save_record(self.data_dir, rec)
            job = {
                "kind": records.KIND_DETAIL,
                "trigger": trigger,
                "run_id": run_id,
                "alias": alias,
            }
            self._queued_jobs.append(job)
            self._queue.put(job)
            return rec

    # ------------------------------------------------------------------
    # status
    # ------------------------------------------------------------------
    def status(self):
        with self._lock:
            current = None
            if self._current_job:
                current = dict(self._current_job)
                rec = records.load_record(self.data_dir, current["run_id"])
                if rec:
                    current["state"] = rec.get("state")
                    if rec.get("kind") == records.KIND_FLEET and rec.get("state") == records.STATE_RUNNING:
                        current["progress"] = self._progress_probe(
                            current.get("started_wall") or rec.get("started_at") or time.time()
                        )
            queued = [dict(j) for j in self._queued_jobs]
        return {"current": current, "queued": queued, "queue_length": len(queued)}

    def _progress_probe(self, started_at):
        """Read-only best-effort 'N/M done' probe from the newest
        reports/fleet_work_* dir with mtime >= job start. Never raises,
        never affects the final record -- ambiguity (0 or >1 candidate
        workdirs) just sets a flag, never fails the run."""
        try:
            if not self.reports_dir.is_dir():
                return None
            candidates = []
            for p in self.reports_dir.glob("fleet_work_*"):
                try:
                    if p.is_dir() and p.stat().st_mtime >= started_at - 5:
                        candidates.append(p)
                except OSError:
                    continue
            if not candidates:
                return {"ambiguous": False, "done": None, "total": None, "workdir": None}
            candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            ambiguous = len(candidates) > 1
            chosen = candidates[0]
            manifest = chosen / "manifest.tsv"
            total = None
            done = 0
            if manifest.is_file():
                lines = [
                    l
                    for l in manifest.read_text(encoding="utf-8", errors="replace").splitlines()
                    if l.strip()
                ]
                total = len(lines)
                for line in lines:
                    alias = line.split("\t")[0] if line else None
                    if alias and (chosen / ("%s.rc" % alias)).exists():
                        done += 1
            return {"ambiguous": ambiguous, "done": done, "total": total, "workdir": str(chosen)}
        except OSError:
            return None

    # ------------------------------------------------------------------
    # worker
    # ------------------------------------------------------------------
    def _worker_loop(self):
        while True:
            job = self._queue.get()
            if job is None:
                self._queue.task_done()
                if self._stop.is_set():
                    return
                continue
            with self._lock:
                if job in self._queued_jobs:
                    self._queued_jobs.remove(job)
                job["started_wall"] = time.time()
                self._current_job = job
            try:
                self._run_job(job)
            finally:
                with self._lock:
                    self._current_job = None
                self._queue.task_done()

    def _fleet_argv(self, conf_path):
        p = self.config.fleet
        return ["bash", self.wrapper_path, conf_path] + p.argv_tail()

    def _build_env(self, extra=None):
        env = dict(os.environ)
        env.update(self.config.env)
        if extra:
            env.update(extra)
        return env

    def _make_detail_conf(self, alias):
        entries = fleetconf.parse_fleet_conf(self.config.fleet.conf_path)
        entry = entries[alias]
        line = fleetconf.detail_conf_line(entry)
        tmp_dir = self.data_dir / "tmp"
        tmp_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=str(tmp_dir), prefix="detail_%s_" % alias, suffix=".conf")
        try:
            os.close(fd)
            os.chmod(tmp_path, 0o600)
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        return tmp_path

    def _run_subprocess(self, argv, env, log_path, max_run_minutes):
        """Run argv, capturing combined stdout+stderr to log_path. Enforces
        max_run_minutes: SIGTERM the process group, wait 30s, SIGKILL."""
        timed_out = False
        with open(log_path, "wb") as logf:
            proc = self._popen(
                argv,
                cwd=self.cwd,
                env=env,
                stdout=logf,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            timeout_s = max_run_minutes * 60 if max_run_minutes else None
            try:
                exit_code = proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                timed_out = True
                self._killpg(proc.pid, "SIGTERM")
                try:
                    exit_code = proc.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self._killpg(proc.pid, "SIGKILL")
                    exit_code = proc.wait()
        return exit_code, timed_out

    @staticmethod
    def _killpg(pid, signame):
        import signal

        sig = getattr(signal, signame)
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError, OSError):
            pass

    def _finalize_fleet(self, rec, exit_code, summary, timed_out, log_text):
        rec["exit_code"] = exit_code
        rec["databases"] = summary["databases"]
        rec["report_path"] = summary["report_path"]
        rec["wrapper_run_id"] = summary["wrapper_run_id"]
        # The wrapper deletes the workdir on a clean success and only keeps it
        # when something needs inspecting. The summary can't tell us which
        # happened, so only record a workdir that actually exists on disk --
        # otherwise the run page would advertise a directory that's gone.
        rec["workdir"] = None
        if summary["wrapper_run_id"]:
            wd_name = records.fleet_workdir_name(summary["wrapper_run_id"])
            if (self.reports_dir / wd_name).is_dir():
                rec["workdir"] = wd_name
        if timed_out:
            rec["warnings"].append(
                "run exceeded max_run_minutes=%d and was terminated"
                % self.config.fleet.max_run_minutes
            )
        if summary["report_path"] and exit_code == 0:
            any_error = any(d.get("status") == "ERROR" for d in summary["databases"])
            rec["state"] = records.STATE_PARTIAL if any_error else records.STATE_SUCCESS
        else:
            rec["state"] = records.STATE_FAILED
            rec["error"] = _tail_error(exit_code, log_text)

    def _finalize_detail(self, rec, exit_code, summary, timed_out, alias, log_text):
        rec["exit_code"] = exit_code
        rec["databases"] = summary["databases"]
        entry = None
        for d in summary["databases"]:
            if d.get("alias") == alias:
                entry = d
                break
        detail_path_str = None
        if summary["wrapper_run_id"]:
            fname = records.detail_report_filename(alias, summary["wrapper_run_id"])
            full = self.reports_dir / fname
            if full.is_file():
                detail_path_str = "reports/%s" % fname
        rec["report_path"] = detail_path_str
        if timed_out:
            rec["warnings"].append(
                "run exceeded max_run_minutes=%d and was terminated"
                % self.config.fleet.max_run_minutes
            )
        ok = (
            exit_code == 0
            and entry is not None
            and entry.get("status") == "OK"
            and entry.get("detail") == "ok"
            and detail_path_str is not None
        )
        rec["state"] = records.STATE_SUCCESS if ok else records.STATE_FAILED
        if not ok:
            rec["error"] = _tail_error(exit_code, log_text)

    def _run_job(self, job):
        run_id = job["run_id"]
        kind = job["kind"]
        alias = job.get("alias")

        rec = records.load_record(self.data_dir, run_id)
        if rec is None:
            rec = records.new_record(run_id, kind, job["trigger"], alias=alias)
        rec["state"] = records.STATE_RUNNING
        rec["started_at"] = time.time()
        records.save_record(self.data_dir, rec)

        log_path_ = records.log_path(self.data_dir, run_id)
        tmp_conf = None
        summary = {"databases": [], "report_path": None, "wrapper_run_id": None}

        try:
            if kind == records.KIND_FLEET:
                conf_path = self.config.fleet.conf_path
                env = self._build_env()
            else:
                try:
                    tmp_conf = self._make_detail_conf(alias)
                except (fleetconf.FleetConfError, KeyError) as exc:
                    rec["state"] = records.STATE_FAILED
                    rec["error"] = "could not prepare detail conf: %s" % exc
                    return
                conf_path = tmp_conf
                # Force per-line honoring: a fleet-wide FLEET_DETAIL=none in
                # [env] must never silently swallow an explicit per-alias
                # regen request.
                env = self._build_env({"FLEET_DETAIL": ""})

            argv = self._fleet_argv(conf_path)
            exit_code, timed_out = self._run_subprocess(
                argv, env, str(log_path_), self.config.fleet.max_run_minutes
            )

            try:
                log_text = log_path_.read_text(encoding="utf-8", errors="replace")
            except OSError:
                log_text = ""
            summary = records.parse_fleet_summary(log_text)

            if kind == records.KIND_FLEET:
                self._finalize_fleet(rec, exit_code, summary, timed_out, log_text)
            else:
                self._finalize_detail(rec, exit_code, summary, timed_out, alias, log_text)

        except Exception as exc:  # pragma: no cover - last-resort safety net
            rec["state"] = records.STATE_FAILED
            rec["error"] = "internal server error running job: %s" % exc

        finally:
            rec["ended_at"] = time.time()
            if rec.get("started_at"):
                rec["duration_s"] = rec["ended_at"] - rec["started_at"]
            records.save_record(self.data_dir, rec)

            if kind == records.KIND_DETAIL:
                byproduct = summary.get("report_path")
                if byproduct:
                    bp_path = Path(self.cwd) / byproduct
                    try:
                        if bp_path.is_file():
                            bp_path.unlink()
                    except OSError:
                        pass
                if tmp_conf:
                    try:
                        os.unlink(tmp_conf)
                    except OSError:
                        pass
